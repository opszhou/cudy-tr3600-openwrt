# Cudy TR3600 v1 OpenWrt 固件

<p>
  <img alt="License" src="https://img.shields.io/badge/license-GPL--2.0-blue">
  <img alt="CI" src="https://img.shields.io/badge/CI-GitHub_Actions-2088FF?logo=githubactions&logoColor=white">
  <img alt="Device" src="https://img.shields.io/badge/device-Cudy_TR3600_v1-red">
  <img alt="OpenWrt" src="https://img.shields.io/badge/OpenWrt-mediatek%2Ffilogic-00B5E2">
</p>

> ## ⚠️ 使用前必读
>
> - **本项目仅为个人自用**，不是成熟发行版：**没有做过系统性真机验证**，刷机有变砖风险，请自行评估、自行备份
> - 仅适用于 Cudy **TR3600 v1**，不适用于 TR3000、WR3600 或任何其他硬件版本，刷前务必核对硬件版本
> - 固件以 GitHub Actions 最新成功构建为准，随上游更新滚动变化，不承诺任何稳定性

## 为什么用这套固件

- **官方 PR 直接合并**：基于 OpenWrt 官方 main + 官方 PR **#25860**（TR3600 v1 设备支持）+ **#25996**（千兆网口 EEE 丢包修复，该问题在原版下丢包率可达 41%~100%）
- **硬件数据校准**：在 PR 基础上按真机实测与 Cudy 官方 GPL 源码修正了 LED 颜色（boot/failsafe/upgrade=红、运行=白）、5G MAC 布局（base+0x10），并补充**风扇四档温控**（65/72/80/88 °C 自动调速）
- **开箱即用的开机预设**（首次开机自动生效，LuCI 均可再改）：
  - LAN 地址 **192.168.10.1/24**，DHCP 池 .100~.249
  - 主机名 **tr3600**；时区 **Asia/Shanghai**，LuCI 时间显示 **24 小时制**
  - 双频 WiFi 7（EHT）默认：国家码 CN、ACS 自动信道、2.4G 20MHz / 5G 80MHz；已设密钥的接口升级为 **WPA2/WPA3 混合**
  - 5G SSID 自动加 `_5G` 后缀（双频同名会导致终端漫游到错误频段）
  - 每周一凌晨 04:30 自动重启；UPnP 默认安全模式；BBR 拥塞控制默认启用
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
| 文件服务 | dufs 网页文件浏览器 + WebDAV 一体（**8080** 端口，80 保留给 LuCI；默认可上传，见下方「dufs 文件服务」） |
| USB 存储 | UAS 高速协议 + ext4 / exFAT / NTFS3 / FAT32 文件系统 + 自动挂载（block-mount） |
| 网络质量 | SQM 智能队列（消除 bufferbloat）+ nlbwmon 按主机流量统计 |

### ultimate（全能 = lite 全部，再加：）

| 分类 | 内容 |
|------|------|
| 组网 | **tailscale**（异地组网）+ macvlan（单口多拨/虚拟网卡） |
| 无线漫游 | travelmate（无线中继/酒店 WiFi 上行管理） |
| 下载 | **Transmission** BitTorrent 下载（LuCI 面板 + 自带 WebUI 9091 端口） |
| 运维工具 | ttyd 网页终端 + luci-app-statistics 轻量监控（CPU/内存/接口图表） |
| 网络 | ip-full / yq |

### dufs 文件服务（网页文件管理 + WebDAV）

- 访问：`http://192.168.10.1:8080`；网页界面与 WebDAV 共用同一路径和端口（不做本地域名——设备不把路由器当 DNS 时解析不了，IP 反正是固定的）
- 默认**可上传**（网页拖拽 / WebDAV PUT）+ 下载、搜索、目录打包 zip；**删除权限默认关**（防误删），要开：

  ```sh
  uci set dufs.config.allow_delete='1'
  uci commit dufs && /etc/init.d/dufs restart
  ```

- 默认无认证（同网段任意设备可写）；介意就加认证：`/etc/config/dufs` 里 `list auth '用户名:密码@/:rw'`，重启生效
- 根目录 `/mnt`（U 盘/移动硬盘自动挂载点）；dufs 的 WebDAV 是 Class 1（无 LOCK），普通文件传输/播放没问题，不保证 Office 在线编辑等高级用法

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
