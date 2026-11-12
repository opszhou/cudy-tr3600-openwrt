# 5G 模组上手指南（QModem · FZS P3）

固件已内置 `qmodem` + `luci-app-qmodem-next` + 全协议驱动（QMI / MBIM / RNDIS / ECM / NCM + AT 串口）。
本页是"从刷完机到 5G 跑通"的最短路径，以及踩坑对照。

## 1. 先看模组是谁（首启自动做过一次）

```sh
cat /etc/modem-probe.txt
```

里面有四段关键信息：

| 段 | 用途 |
|---|---|
| `## USB 设备`（sysfs VID:PID + manufacturer/product） | 判定厂商与型号（Quectel `2c7c`、Fibocom `2dee`、MeiG `2dee`/`3765`、SIMCom `1e0e`、UNISOC `1782` 等） |
| `## USB 驱动绑定` | 是否已绑上 `option`（AT 口）、`qmi_wwan`、`cdc_mbim`、`rndis_host`、`cdc_ether` |
| `## 串口设备` | `/dev/ttyUSB*`、`/dev/cdc-wdm*` 是否存在 |
| `## ATI` | 模组自报型号/固件版本（哪一家、支持哪些制式） |

想重新探测一次：`sh /etc/uci-defaults/95-modem-probe`（脚本是幂等的，只读）。

## 2. 进 QModem 建配置

LuCI → **网络 → QModem**（`luci-app-qmodem-next`，纯 JS 界面）

1. **扫描/刷新**：应能看到一张"物理卡槽"卡片，显示 VID:PID 与识别到的型号
2. **新建配置**：选厂商/型号 → 选**拨号协议**
   - 高通/紫光 UNISOC 模组优先 **QMI**（`qmi_wwan` + `uqmi`）
   - 部分模组只有 **MBIM** 能用（`cdc_mbim` + `umbim`）——典型现象是选 ECM/NCM 后 carrier 恒 0、拿不到地址
3. **APN**：国内三大运营商常用
   | 运营商 | APN |
   |---|---|
   | 移动 | `cmnet` |
   | 联通 | `3gnet` |
   | 电信 | `ctnet` |
   物联网卡/定向卡按运营商给的 APN 填；IPv4/IPv6 双栈选 `ipv4v6`
4. **保存 → 连接**，然后验证：

```sh
ip -br addr                  # 应出现 wwan0 / usb0 / rmnet* 且带地址
ip route | head -5           # default 走模组
ping -c3 223.5.5.5           # 通内网
nslookup openwrt.org         # 通 DNS（不通看第 5 节第 3 条）
```

5. **开机自启**：QModem 配置里勾选自动连接；`/etc/config/qmodem` 会保存

## 3. 和"USB 网卡自动当 WAN"的关系（不会打架）

本仓库的 `/etc/hotplug.d/net/50-usb-wan` 会把**免驱型** USB 上网卡/RNDIS 手机共享自动做成 `wanusb`，
但它有明确让位规则：

- 看到 `qmi_wwan*` / `cdc_mbim` / `cdc_wdm` 驱动接口 → 判定为"需要拨号的模组"，**不接管**（归 QModem）
- `/var/run/qmodem/<bus>_<port>_dir` 已存在 → QModem 已接管，**不接管**
- 该网卡已有 v4 地址 / 已被其它 uci 接口占用 / netifd 已绑定 → **不接管**
- 热插拔后会先等 5 秒让 QModem 先手，再逐条判定

所以：**QMI/MBIM 模组走 QModem 拨号，RNDIS/ECM 的 5G CPE 或手机共享自动当 WAN**，两边井水不犯河水。

## 4. 双路（5G + 有线）同时在线

QModem 拨号默认下发 `AT+QCFG="nat",2`（网桥模式，USB 与网口双路可用）。本仓库在
`common/customize.sh` 里用 `scripts/apply-qmodem-nat2.sh` 把上游 `nat=1` 的写法改掉，
否则每次重拨都会写回 1、双路失效——构建时会自动打这个补丁（幂等，格式不符直接失败）。

路由优先级：`wanusb` 默认 metric 20，比板载 `wan`（eth）低一级；两者都通时优先走有线，拔线自动回落。

## 5. 常见现象对照

| 现象 | 原因 | 处理 |
|---|---|---|
| QModem 里看不到模组 | USB 模式不对（模组还在 `usb-storage` 模式） | `lsusb` 看 VID:PID；`usb_modeswitch -v <vid> -p <pid> -J` 切模式；或用 AT `AT+QCFG="usbnet",1` |
| 有 `/dev/ttyUSB*` 但没有 `/dev/cdc-wdm*` | 只出 AT 口，QMI 未暴露 | 试 MBIM：`AT+QCFG="usbnet",2`，重插 |
| 拨号成功但没网 | APN/PDP 不对 | 改 APN、PDP 类型（IPv4 / IPv4v6） |
| 能 ping IP、域名解析失败 | 上游 DNS 为空 | 本仓库 `/etc/hotfix.d/10-dns-upstream.sh` 每开机会兜底；`logread -t hotfix` 查 |
| 5G 灯不亮/常亮 | 模组厂商各自的状态灯策略不同 | 本机 `green:4g` / `green:5g` 是 GPIO34/35 直驱；若模组自己管灯，改为 QModem 状态脚本控制 |
| 掉线后要重启才恢复 | USB autosuspend | 设备预设已在 `/etc/hotplug.d/usb/20-modem-no-autosuspend` 里对蜂窝 VID 关掉 autosuspend |
| 想用 QManager 而不是 QModem | 两个管理器会抢同一 AT 口 | 二选一；QManager 只支持 Quectel，构建时用 `with_qmanager=true` 才打包 |

## 6. 命令行速查

```sh
ubus list | grep -i qmodem          # 服务是否在
uci show qmodem | head -30          # 配置项
ubus call network.interface.<if> status
logread -f | grep -iE 'qmodem|at-daemon|qmi|mbim'
```

---

# 附：RM500U-CNV 实测流程（本机 2026-11-12 真机数据）

## 已知硬件事实（从本机采集，不是推测）

| 事实 | 值 |
|---|---|
| 型号 | Quectel **RM500U-CNV**（UNISOC 平台），固件 `RM500UCNVAAR03A04M2G` |
| USB 形态 | 5 个串口：`/dev/ttyUSB0`–`ttyUSB4`（`option` 驱动） |
| AT 口 | **`/dev/ttyUSB2`**（`ttyUSB3` 亦响应；其余是 NMEA/DIAG，发 AT 会回 `+CME ERROR: 4`，属正常） |
| 数据口 | `usb0`，由 `cdc_ether` 注册（说明模组当前是 **ECM** composition） |
| `/dev/cdc-wdm*` | **没有**。UNISOC 方案不暴露 QMI 控制口 → **QModem 里不要选 QMI** |
| 初始状态 | `usb0` carrier=0（还没拨号，正常） |

## 按 QModem 官方顺序走（不要跳步）

1. **确认枚举**：`logread -e usb -e tty -e cdc`、`ls -l /dev/ttyUSB*`、`ip -br link`
2. **扫描模组**：LuCI → 网络 → QModem → 扫描（`hotplug_add_delay` 默认 8 秒，插拔后别急着点）
   - 核对识别出的厂商/型号是否 `Quectel RM500U-CNV`
   - AT 端口是否被识别为 `ttyUSB2`
3. **验证 AT 通道**（只读）：

```sh
stty -F /dev/ttyUSB2 115200 raw -echo clocal
for c in 'AT' 'ATI' 'AT+CGMM' 'AT+CPIN?' 'AT+CSQ'; do
  printf '%s\r' "$c" > /dev/ttyUSB2; timeout 2 cat /dev/ttyUSB2 | tr -d '\r'; echo "-- $c"
done
```

   期望：`AT` → `OK`；`AT+CPIN?` → `+CPIN: READY`；`AT+CSQ` → `+CSQ: rssi,99`

4. **配置拨号**：协议 **ECM**，APN 按运营商，PDP `ipv4v6`，认证一般"无"
5. **验证结果**（五条都要成立，不只看页面显示"已连接"）：

```sh
cat /sys/class/net/usb0/carrier          # 应为 1
ip -4 addr show usb0                     # 应有 inet 地址
ip route | head -3                       # default 指向 usb0（或策略路由）
cat /tmp/resolv.conf.d/resolv.conf.auto  # 有 DNS
ping -c3 223.5.5.5 && nslookup openwrt.org
```

## 失败对照（先硬件后配置）

| 现象 | 含义 | 下一步 |
|---|---|---|
| QModem 列表里没有模组 | 扫描时机/驱动 | `ip -br link` 看 `usb0` 是否存在；`logread -e qmodem` 看扫描日志；手动重新扫描 |
| 只有 `ttyUSB*`、没有 `usb0` | composition 不是 ECM | AT：`AT+QCFG="usbnet",1` 后重插模组 |
| 有 `usb0` 但 carrier 恒 0 | **未拨号**（最常见） | 检查启用拨号、APN、PDP 类型；`logread -e qmodem` |
| 拨号后 carrier=1 但没地址 | DHCP/会话问题 | `udhcpc -i usb0 -f -q` 手动试；`AT+QNETDEVCTL?` 查会话 |
| 有地址但 ping 不通 | APN 错/欠费/限速 | 换 APN；`AT+COPS?` 看注册网络 |
| 能 ping IP 不能解析 | DNS 未下发 | 本仓库 `/etc/hotfix.d/10-dns-upstream.sh` 兜底；`logread -t hotfix` |
| `ATI` 回显夹杂 `+CME ERROR` | 打到非 AT 口 | 只用 `ttyUSB2` |

## 想做到"刷完即通"还缺什么

QModem 的模组配置是**运行期按扫描结果生成**的（`/etc/config/qmodem` 初始只有 `main` 段），
所以"预设 APN/协议"无法在编译期静态写入——需要在首启后用 UI 或 `uci` 落一次配置。
把"拨通后的 `uci export qmodem`"发我，我可以固化成设备预设，下一版固件刷完即直连。
