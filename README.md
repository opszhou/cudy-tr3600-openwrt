# OpenWrt 自编译固件（多设备）

<p>
  <img alt="License" src="https://img.shields.io/badge/license-GPL--2.0-blue">
  <img alt="CI" src="https://img.shields.io/badge/CI-GitHub_Actions-2088FF?logo=githubactions&logoColor=white">
  <img alt="Device" src="https://img.shields.io/badge/device-Cudy_TR3600_v1-red">
  <img alt="Device" src="https://img.shields.io/badge/device-FZS_5GCPE_P3-orange">
  <img alt="OpenWrt" src="https://img.shields.io/badge/OpenWrt-mediatek%2Ffilogic-00B5E2">
</p>

> ## ⚠️ 使用前必读
>
> - **本项目仅为个人自用**，不是成熟发行版：**没有做过系统性真机验证**，刷机有变砖风险，请自行评估、自行备份
> - 每台设备只能刷自己的固件，刷前务必核对机型（见下表）
> - 固件以 GitHub Actions 最新成功构建为准，随上游更新滚动变化，不承诺任何稳定性

## 支持设备

| 设备 | 上游分支 | 说明 | 文档 |
|---|---|---|---|
| `cudy_tr3600-v1` | `main`（+ 官方 PR 补丁） | Cudy TR3600 v1（MT7981B + WiFi7 + 风扇） | 本文下方 |
| `fzs_5gcpe-p3` | **ImmortalWrt v25.12.2**（稳定版 tag；补丁目录按 `openwrt-25.12` 分支解析） | 蜂助手 FZS 5GCPE P3（MT7981B + MT7531 + 128MiB NAND + 5G 模组 RM500U-CNV），从 LEDE 迁到 release 分支。走 immortalwrt 是为了 **nftables 全锥形 NAT**（openwrt 官方没有实现 `option fullcone` 的内核模块，immortalwrt 自带完整三件套）。**默认 http://192.168.5.1，用户名 root，密码为空** | [移植说明](docs/DEVICE-FZS-P3.md) · [刷机与验收清单](docs/FLASH-FZS-P3.md) · [5G 模组上手指南](docs/MODEM-FZS-P3.md) · [构建证据](docs/BUILD-EVIDENCE.md) |

两台设备共用同一套 `common/`（QModem、包清单、开机预设）与 CI，但**上游仓库与分支各自独立**：
`device.yml` 里的 `branch` 决定 matrix 每个 job 各自 checkout / 打补丁 / 取缓存 key，`upstream_owner`/`upstream_repo`
决定从哪个仓库取同名分支（缺省 openwrt），互不影响。

## 为什么用这套固件

- **官方 PR 直接合并**：基于 OpenWrt 官方 main + 官方 PR **#25860**（TR3600 v1 设备支持）+ **#25996**（千兆网口 EEE 丢包修复，该问题在原版下丢包率可达 41%–100%）
- **硬件数据校准**：在 PR 基础上按真机实测与 Cudy 官方 GPL 源码修正了 LED 颜色（boot/failsafe/upgrade=红、运行=白）、5G MAC 布局（base+0x10），并补充**风扇四档温控**（65/72/80/88 °C 自动调速）
- **开箱即用的开机预设**（首次开机自动生效，LuCI 均可再改）：
  - LAN 地址 **192.168.10.1/24**，DHCP 池 .100–.249
  - 主机名 **tr3600**；时区 **Asia/Shanghai**，LuCI 时间显示 **24 小时制**
  - 双频 WiFi 7（EHT）默认：国家码 CN、ACS 自动信道、2.4G 20MHz / 5G 80MHz；已设密钥的接口升级为 **WPA2/WPA3 混合**
  - **WiFi 默认开启**（radio 与 AP 都启用，SSID 形如 `OpenWrt` / `OpenWrt_5G`）；未设密钥即**开放热点（无密码）**，需安全性请自行设 WPA2/WPA3
  - **USB 网卡插上自动当 WAN**：自动建 `wanusb`（DHCP）、并入防火墙 wan 区、开机兜底，插上/开机即通，无需手动点连接
  - 5G SSID 自动加 `_5G` 后缀（双频同名会导致终端漫游到错误频段）
  - 每周一凌晨 04:30 自动重启；UPnP 默认安全模式；BBR 拥塞控制默认启用
  - **SMB 文件共享**（samba4，用户态）：共享 `/mnt`（U 盘挂载点），TCP 445，免密可读写，Windows / macOS / 电视直接映射网络驱动器
  - **Transmission**（仅 ultimate）下载目录迁出内存盘（插着 U 盘则落在盘上）并开机自启
  - **管理面板接管为官方框架 + 自研逻辑**：沿用 `luci-mod-dashboard` 的卡片/图表/拖拽布局，网络侧判定改用默认路由与自研能力表（5G 的 `wwan0` 不在 netifd 里，原生会一直显示「未连接」）。未联网 / 接口禁用 / 无模组 / 无客户端时相关部件自动隐藏，恢复后 5 秒内自动出现（详见 `docs/DASHBOARD.md`）
- **全套中文 LuCI** + Argon 主题（默认主题，含 argon-config 配置器）
- **随身 WiFi 场景拉满**：QModem 管理 UI，USB RNDIS / QMI / NCM / MBIM / 串口全驱动，即插即用
- **插件永远新鲜**：所有第三方插件 feed 构建时自动追踪上游最新稳定版（自动跳过 rc/beta 预发布）
- 每次构建输出 sysupgrade 固件 + 完整包清单（manifest）+ sha256 校验和

## 固件里有什么

### lite（精简实用，默认组合）

| 分类 | 内容 |
|------|------|
| 系统基础 | LuCI（HTTPS 管理页）+ 全套中文语言包 + Argon 主题与配置器 + 系统包管理器 + htop / curl |
| 随身 WiFi | **QModem**（luci-app-qmodem-next）+ USB RNDIS / QMI / NCM / MBIM / 串口全驱动 + usb-modeswitch |
| 无线 | wpad-mesh-openssl（Mesh + WPA3，openssl 加密栈） |
| 网络加速 | turboacc（软/硬件流量分载面板）+ SFE/Flow Offload 内核模块 + **BBR** |
| 代理 | **nikki**（mihomo 内核）+ LuCI 管理界面 + TUN / nft-tproxy 内核模块 |
| DDNS 与证书 | ddns-go + acme（acme-acmesh，LuCI 面板） |
| 端口与服务 | UPnP（miniupnpd）+ WOL 网络唤醒 + socat（命令行）+ SFTP |
| 文件服务 | **SMB 共享**（samba4 用户态）：TCP **445**，共享名 `share` → 目录 `/mnt`（U 盘挂载点），**免密可读写**，客户端 `\\<路由器IP>\share`；面板 LuCI「服务 → 网络共享」；见下方「SMB 文件共享」 |
| USB 存储 | UAS 高速协议 + ext4 / exFAT / NTFS3 / FAT32 文件系统 + 自动挂载（block-mount） |
| 网络质量 | SQM 智能队列（消除 bufferbloat）+ nlbwmon 按主机流量统计 |
| 系统界面 | **管理面板**（官方框架 + 自研逻辑，只读）：信号强度 / 网络状态 / 流量统计 / 在线设备 / 实时流量曲线，未联网的部件自动隐藏 |

### ultimate（全能 = lite 全部，再加：）

| 分类 | 内容 |
|------|------|
| 组网 | **tailscale**（异地组网）+ macvlan（单口多拨/虚拟网卡） |
| 无线漫游 | travelmate（无线中继/酒店 WiFi 上行管理） |
| 下载 | **Transmission** BitTorrent 下载（LuCI「服务 → Transmission」+ 自带 WebUI 9091；默认开机自启，下载目录已迁出内存盘，见下方「Transmission 下载」） |
| 运维工具 | ttyd 网页终端 + luci-app-statistics 轻量监控（CPU/内存/接口图表） |
| 网络 | ip-full / yq |

### 管理面板（官方框架 + 自研逻辑）

侧边栏第一项「仪表盘」。视觉、卡片、图表、拖拽布局全部沿用官方 `luci-mod-dashboard`（Apache-2.0），
逻辑与判定由 `luci-app-sysdashboard` 提供，**不自己画样式**。

- **部件**：信号强度（RSRP / 等级 / RSRQ·SINR）、网络状态（运营商 / 制式 / 频段·频率·带宽）、
  流量统计（本次累计收发）、互联网（运营商 + 上联 IP/网关）、在线设备（租约 + ARP 合并）、
  WAN 实时流量；系统类（运行时间 / CPU / 内存 / 负载 / 系统负载图）沿用官方内容。
- **自动显隐**：上联断开 → 互联网卡、WAN 流量图、流量统计卡与「互联网」标签消失；
  无客户端 → 设备卡/标签消失；无模组 → 信号与网络状态卡消失；无线未启用 → 无线相关卡片/标签消失。
  条件恢复后下一轮轮询（5 秒）自动回来。判定集中在 rpcd 的 `caps` 能力表，前端不再各写 if。
- **数据来源**：`luci-app-sysdashboard` 的 rpcd **只读**脚本 —— `/proc`（uptime / loadavg / stat / meminfo /
  net/dev / conntrack）、`/sys`（thermal_zone、hwmon、cooling_device）、`/tmp/dhcp.leases` + `/proc/net/arp`、
  QModem 只读查询（`cell_info` / `get_current_band` / `get_stats` / `get_traffic_reset_schedule`）。
- **不做什么**：不写任何 sysfs、不装常驻守护进程、不识别 App/URL、不记录上网行为。TR3600 风扇仍由内核
  thermal 框架按 65/72/80/88 °C 四档自动调速（见 `9000-tr3600-v1-hw-fixes.patch`），面板只读转速/PWM。
- **测试**：`bash scripts/test-sysdashboard.sh`（rpcd 快照与降级）、
  `bash scripts/test-dashboard-catalog.sh`（部件声明 + 能力模型 + 显隐场景矩阵）。
- **架构与扩展方式**：见 `docs/DASHBOARD.md`（新增部件只改 `sd/catalog.js` 一条 + `sd/providers.js` 一个分支）。

### SMB 文件共享（samba4）

- **怎么连**：
  - Windows：资源管理器地址栏输 `\\192.168.5.1\share`，或「映射网络驱动器」
  - macOS：Finder「前往 → 连接服务器」→ `smb://192.168.5.1/share`
  - 电视 / 播放器 / 手机：协议选 SMB 即可，绝大多数设备原生支持
- **插盘即见**：共享的是 `/mnt`，也就是 block-mount 给 U 盘/移动硬盘分配的挂载点（`/mnt/sda1`、`/mnt/sdb1`…）。
  不用改配置；没插盘时共享是空的
- **Win11 必须用账号**：Windows 11 24H2 起系统级禁止匿名/来宾 SMB，免密共享连不上。在 LuCI
  「服务 → 网络共享」里加用户，或命令行 `smbpasswd -a <用户名>` 建账号（**不能是 root**，
  模板里 `invalid users = root`），然后用这个账号连。老电视盒子仍可走免密
- **改共享目录 / 权限**：同一页面改（底层 `/etc/config/samba4`，预设见
  `common/files/etc/config/samba4`）；改完 `/etc/init.d/samba4 restart` 生效，不需要重启路由器
- **CPU 占用**：空闲为 0（事件驱动，无轮询）。预设里加了 `samba_nice 3`，把 smbd 的调度优先级调低，
  文件传输不会跟拨号、转发抢 CPU —— 这点跟 nikki 不一样，mihomo 是每个包都过用户态，samba 只在有读写时活跃
- **为什么是 samba4 而不是 ksmbd**：ksmbd 在内核态，它的 SMB2 缓冲按内存分档（128–256MB 给 1M），
  在 233MB + ubifs 的机器上读文件会卡死 → 31 秒看门狗复位 → 整机重启，还会连带把 USB 模组搞挂。
  samba4 是用户态进程，崩了只死自己，路由和拨号不受影响。代价是镜像 +10–12MB、常驻 20–40MB 内存
- **不想用**：`/etc/init.d/samba4 disable && /etc/init.d/samba4 stop`

- **端口占用一览**（改动任何一项前先对一遍，80 被抢会让 LuCI 直接失联）：

  | 端口 | 服务 | 说明 |
  |---|---|---|
  | **80 / 443** | uhttpd | **LuCI 管理页面，任何情况下都不要动** |
  | **445** | samba4 | SMB 共享（TCP 445，局域网） |
  | 7681 | ttyd | 网页终端（仅 ultimate） |
  | 9091 | transmission | BT 下载 RPC（仅 ultimate） |
  | 9876 | ddns-go | DDNS 管理页（未启用时不通） |

### Transmission 下载

- 入口：LuCI **服务 → Transmission**；WebUI `http://192.168.10.1:9091`（默认无认证，仅同网段）；开机自启
- 上游默认下载目录是 `/tmp/transmission/done`，**`/tmp` 是内存盘，重启后下载内容全丢**。本固件首启已改为 `/mnt/transmission/`（检测到第一块 USB 盘时落在 `/mnt/sda1/transmission/`），配置与任务列表一并持久化
- 要换目录：面板里改「Download directory」；没插 U 盘时默认落在 overlay，空间有限，建议插盘

### 无线与 USB 上网（默认即用）

- **无线默认开启**：开机会直接放出 2.4G / 5G 热点，SSID 默认 `OpenWrt` 与 `OpenWrt_5G`（5G 自动加 `_5G` 后缀避免终端漫游到错频段）
- **默认无密码（开放热点）**：这是本固件的取舍——开箱即连。要加密码：LuCI → 网络 → 无线 → 编辑对应 SSID → 加密选 WPA2/WPA3 混合并填密码（写入密钥后，下次开机预设会自动把它升级为 `sae-mixed` + PMF optional）
- **USB 网卡自动当 WAN**：插上 USB 有线网卡（RTL8152/8153/8156、AX88179、ASIX、RNDIS/CDC-EEM 等，驱动已内置）、手机 USB 共享、或**免驱型 4G/5G 上网卡与 CPE**（RNDIS/ECM/NCM 模式，自带 DHCP），系统会自动创建 `wanusb` 接口走 DHCP、并入防火墙 `wan` 区、立即 `ifup`——**无需在 LuCI 点任何按钮**
  - `wanusb` 的默认路由 metric 为 20，比板载 WAN（eth0）低一级：两块都通时优先走板载 WAN，拔掉网线自动回落
  - 开机时就已经插着也生效（`/etc/init.d/usb-wan` 兜底扫描）；拔掉只是 `ifdown`，配置留着下次插上复用
  - **不接管的情况**：板载 `eth0/eth1`；`wwan*` / `rmnet*` 名字的接口；USB 设备上存在 `qmi_wwan*` / `cdc_mbim` / `cdc_wdm` 驱动接口（说明这是**需要拨号**的 QMI/MBIM 模组，归 QModem 的 `quectel-CM` 管，抢过来会双拨失败）；netifd 里已有接口绑着该设备；`/var/run/qmodem/<bus>_<port>_dir` 已存在（QModem 已接管）
  - **先等再判，已连通就不动**：热插拔后会先等 5 秒给 QModem/netifd 先手，然后逐条核对——QModem 已接管（`/var/run/qmodem/<bus>_<port>_dir` 存在）、该网卡已有 IPv4 地址、已被其它 uci 接口占用、netifd 已绑定该设备，任一成立就完全不动。避免两边同时建接口抢同一块网卡（表现为 QModem 拨号失败或 `wanusb` 反复 up/down）
  - 也就是说：**QMI/MBIM 模组（你现在这块 RM500U）走 QModem 拨号；RNDIS/ECM/NCM 模式的 5G CPE 或上网卡则自动当 WAN**，两者井水不犯河水
  - 查看状态：`ubus call network.interface.wanusb status` 或 LuCI → 网络 → 接口

### 运行期补丁（hotfix）——不重新编译也能修配置

`uci-defaults` 只在首次开机执行一次，执行完就被删除；之后某个配置项如果被覆盖或改坏，它**不会自愈**。所以「配置级修复」统一放在 `/etc/hotfix.d/*.sh`，由 `/etc/init.d/hotfix` 在**每次开机**重放。

- 补丁约定：**必须幂等**（跑一次和跑十次结果一致），单条失败不会阻断后续，失败会写进 `logread -t hotfix`
- 自带的补丁：
  - `10-dns-upstream.sh` — 兜底上游 DNS。上行是 QModem 模组（`proto='none'`，`quectel-CM` 自己配地址）或 WAN 没插线时，netifd 不提供任何 DNS，`/tmp/resolv.conf.d/resolv.conf.auto` 为空，dnsmasq 会对**所有**查询回 `REFUSED` → 表现是「路由器 ping 得通、手机已连接但无互联网」（iOS 的联网探测就是一次域名解析）
- 不重新编译也能落地——把仓库里这两个文件推到设备即可（内容与固件内置的完全一致）：

  ```sh
  # 在电脑上（仓库根目录）
  scp common/files/etc/init.d/hotfix                root@192.168.10.1:/etc/init.d/hotfix
  scp common/files/etc/hotfix.d/10-dns-upstream.sh  root@192.168.10.1:/etc/hotfix.d/

  # 在路由器上
  chmod +x /etc/init.d/hotfix /etc/hotfix.d/*.sh
  /etc/init.d/hotfix enable && /etc/init.d/hotfix start
  ```

- 加新补丁：在 `common/files/etc/hotfix.d/` 放一个 `NN-名字.sh`（写清「问题现象 + 为什么这样修 + 幂等实现」），固件与设备两端自动共用

## 下载固件
- **Releases**：勾选发布选项的构建会发布到仓库 [Releases](https://github.com/opszhou/cudy-tr3600-openwrt/releases) 页
- **Artifacts**：每次构建产物为 `openwrt-cudy_tr3600-v1-<组合>-snapshot`（保留 14 天），含固件、manifest 与校验和

## 刷机提醒

1. 原厂固件 → OpenWrt **必须先刷 Cudy 官方中间固件**（见 [Cudy TR3600 v1 下载页](https://www.cudy.com/zh-cn/pages/download-center/tr3600-1-0) 说明），再刷 OpenWrt sysupgrade
2. 跨原厂/社区固件刷机**不保留配置**，刷前备份
3. `sysupgrade.bin` 不能当作原厂升级镜像直接刷入原厂系统
4. 刷前核对 sha256 校验和；变砖救砖请自行了解 failsafe / initramfs 恢复方式

## ⚠️ 请不要用「软件包管理器」更新或安装软件

固件已把需要用到的包**全部编译进去**（lite 约 300 个，ultimate 约 350 个）。装好即用，不需要联网装包。

**为什么不建议用 LuCI 的软件包管理器 / `apk` / `opkg`：**

| 风险 | 说明 |
|---|---|
| **内核模块必然不兼容** | 固件内核是构建当天的快照版本，而官方源每天都在滚动。装任何 `kmod-*` 都会因内核版本（vermagic）不匹配而加载失败，严重时破坏依赖链、系统起不来 |
| **第三方包根本装不到** | turboacc、qmodem、nikki、ddns-go 等来自第三方 feed，官方源上没有它们的索引——点击更新只会得到一屏 `unexpected end of file` |
| **升级会覆盖本体** | 用包管理器「升级」已内置的包，可能把经过适配的版本替换成上游新版本，导致行为不一致甚至功能失效 |

**正确做法：需要什么包就重新构建一版**——在 `common/packages/*.list` 里加一行、推一次构建，所有包与内核一同编译，保证 ABI 一致。这比在设备上装包更可靠，也便于回滚。

> 若只是临时装个纯脚本/纯数据类工具（如 `htop`），风险较低，但仍请在刷机后不久、与固件同一快照窗口内操作；**任何带 `kmod-` 前缀的包都请不要安装。**

## 📄 许可证

本仓库自身内容遵循 [GPL-2.0](LICENSES/GPL-2.0)。
第三方组件：QModem 为 MPL-2.0，Nikki 为 GPL-3.0，其余以各自仓库为准。
`common/package/luci-app-sysdashboard` 为本仓库自研组件（Apache-2.0），无第三方代码依赖。
