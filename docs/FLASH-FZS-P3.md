# 蜂助手 FZS 5GCPE P3 刷机与验收清单

> 从**现网 LEDE** 迁到 **OpenWrt 主线 release（openwrt-25.12）**。
> 只适用于 `fzs_5gcpe-p3`；刷前务必核对机型，别把 cudy 的固件刷进来（反之亦然）。

## 0. 刷前（5 分钟，别省）

```sh
# 在现网 LEDE 上
sysupgrade -b /tmp/lede-backup.tar.gz          # 配置备份
cat /proc/mtd > /tmp/lede-mtd.txt              # 分区表（回滚时对照）
cat /proc/cmdline > /tmp/lede-cmdline.txt
lsusb > /tmp/lede-lsusb.txt 2>/dev/null
cat /etc/openwrt_release                      # 记录当前版本
```

把 `/tmp/lede-*.{tar.gz,txt}` 和 `/etc/openwrt_release` 拷到电脑：

```sh
scp root@$LEDE_IP:/tmp/lede-* .
```

顺手把两份关键证据留下（后面调 RK3566 内联口要用）：
```sh
{ ls /sys/class/net; ip -br link; ip -d link show | grep -E 'dsa|master' | head -20; } > /tmp/lede-net.txt
cat /tmp/lede-net.txt
```

## 1. 取固件并校验

从 Actions Artifact（`openwrt-fzs_5gcpe-p3-lite-snapshot`）或 Release 下载：

- `openwrt-mediatek-filogic-fzs_5gcpe-p3-squashfs-sysupgrade.bin`
- `sha256sums` / `*.manifest`

```sh
sha256sum openwrt-mediatek-filogic-fzs_5gcpe-p3-squashfs-sysupgrade.bin
grep -F fzs_5gcpe-p3 sha256sums        # 与上一行输出逐字对照
grep -cE '^qmodem |^luci-app-qmodem-next ' *.manifest   # 应为 2（说明 QModem 进镜像了）
```

## 2. 刷入

```sh
scp openwrt-mediatek-filogic-fzs_5gcpe-p3-squashfs-sysupgrade.bin root@$LEDE_IP:/tmp/
ssh root@$LEDE_IP 'sha256sum /tmp/openwrt-mediatek-filogic-fzs_5gcpe-p3-squashfs-sysupgrade.bin'
ssh root@$LEDE_IP 'sysupgrade -n /tmp/openwrt-mediatek-filogic-fzs_5gcpe-p3-squashfs-sysupgrade.bin'
```

- `-n` 必须加：LEDE 的 `/etc/config` 与主线结构不同，保留只会互相打架
- 不需要中间固件、不需要换 bootloader：分区表与 UBI 布局和原厂/LEDE 完全一致
- 刷完默认 **LAN 192.168.10.1**、主机名 `fzs-p3`、WiFi 默认开启（**无密码**，请自行设 WPA2/WPA3）

## 3. 首刷验收（10 项）

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | 系统起来 | `cat /etc/openwrt_release` 显示 `openwrt-25.12`；`ubus call system board` 里 `board_name=fzs,5gcpe-p3` |
| 2 | 网口 | `ip -br link` 有 `lan1 lan2 wan`；`lan1/2` 插电脑能拿 DHCP；`wan` 插上级能拨号/上网 |
| 3 | 无线 | `iwinfo` 两个 radio 均 up；2.4G `HE20`、5G `HE80` |
| 4 | LED | wifi 灯（运行）、4g、5g 三颗可控：`ls /sys/class/leds` |
| 5 | 按键 | reset 长按恢复出厂；wps 有键值事件：`logread -f` 观察 |
| 6 | 模组探测 | `cat /etc/modem-probe.txt`（首启生成）：USB VID:PID、驱动绑定、ATI 回显 |
| 7 | QModem | `ubus list | grep -i qmodem` 有输出；LuCI → 网络 → QModem 能看到模组 |
| 8 | 拨号 | 在 QModem 里选对厂商/协议（QMI 或 MBIM）→ 连接 → `ip a` 出现 `wwan0`/`usb0` 且有地址；`ping 223.5.5.5` 通 |
| 9 | 断电重启 | `reboot` 后配置保留、模组自动重连、WiFi 自动起 |
| 10 | 诊断脚本 | `fzs-p3-diag` 可跑（输出 `/tmp/fzs-p3-diag.txt`） |

## 4. 出问题怎么退

1. **能进系统**：LuCI「系统 → 备份/升级」刷回 LEDE 的 `sysupgrade.bin`（同样走 UBI 卷，可逆）
2. **起不来**：网线插 `lan1`，U-Boot 网页（常见 `192.168.1.1`）上传 LEDE/原厂固件，或 TFTP 传 initramfs 恢复
3. **极端**：串口 `115200 8N1`（UART0）进 U-Boot，必要时用 `mtk_uboot` 的 nmbm 命令重建分区表（分区表见刷前备份的 `/proc/mtd`）

## 5. 常见现象速查

| 现象 | 原因 | 处理 |
|---|---|---|
| 刷完没有无线信号 | `htmode` 被设成 EHT（本机是 WiFi6） | 默认预设已强制 `HE20/HE80`；若手改过，`uci set wireless.<radio>.htmode=HE80` |
| QModem 看不到模组 | 模组 USB 模式/驱动不匹配 | 看 `/etc/modem-probe.txt` 的 VID:PID；必要时 `usb_modeswitch` 切模式 |
| 拨号成功但没网 | APN/PDP 类型不对 | QModem 里改 APN（国内三大运营商一般 `cmnet`/`3gnet`/`ctnet`） |
| 设备能连但上不了网（iOS 尤其） | 上游 DNS 为空 | 本仓库 `/etc/hotfix.d/10-dns-upstream.sh` 会兜底；`logread -t hotfix` 查看 |
| 想回 LEDE 但没备份 | 用本页第 4 节的 U-Boot 路径 | —— |

## 6. 已知未完成项

- **RK3566 内联口**：设备树只描述 MT7531 的 `port1/2/3 + port6`（`lan1`/`lan2`/`wan`）。若机上 RK3566 走的是
  `port4/5` 或 `gmac1`，现网 LEDE 同样没有描述它 —— 需要 `/tmp/p3-diag.txt`（或 `ls /sys/class/net`）来定
  位，然后补 `devices/fzs_5gcpe-p3/patches/openwrt-25.12/0002-*.patch`。
- **QManager**：可选载荷（`with_qmanager=true`），仅支持 Quectel 模组，且与 QModem 拨号二选一。
