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
| 文件服务 | lighttpd + WebDAV + 基础认证 |
| USB 存储 | UAS 高速协议 + ext4 / exFAT / NTFS3 / FAT32 文件系统 + 自动挂载（block-mount） |
| 网络质量 | SQM 智能队列（消除 bufferbloat）+ nlbwmon 按主机流量统计 |

### ultimate（全能 = lite 全部，再加：）

| 分类 | 内容 |
|------|------|
| 组网 | **tailscale**（异地组网）+ **NetPath** 多 WAN 负载均衡/故障切换（mwan3 的 nftables 现代替代）+ macvlan |
| 无线漫游 | travelmate（无线中继/酒店 WiFi 上行管理） |
| 运维工具 | ttyd 网页终端 + filebrowser 网页文件管理器 + 网络测速面板（netspeedtest）+ luci-app-statistics 轻量监控（CPU/内存/接口图表） |
| 网络 | ip-full / yq |

## 下载固件

- **Releases**：勾选发布选项的构建会发布到仓库 [Releases](https://github.com/opszhou/cudy-tr3600-openwrt/releases) 页
- **Artifacts**：每次构建产物为 `openwrt-cudy_tr3600-v1-<组合>-snapshot`（保留 14 天），含固件、manifest 与校验和

## 刷机提醒

1. 原厂固件 → OpenWrt **必须先刷 Cudy 官方中间固件**（见 [Cudy TR3600 v1 下载页](https://www.cudy.com/zh-cn/pages/download-center/tr3600-1-0) 说明），再刷 OpenWrt sysupgrade
2. 跨原厂/社区固件刷机**不保留配置**，刷前备份
3. `sysupgrade.bin` 不能当作原厂升级镜像直接刷入原厂系统
4. 刷前核对 sha256 校验和；变砖救砖请自行了解 failsafe / initramfs 恢复方式

## 📄 许可证

本仓库自身内容遵循 [GPL-2.0](LICENSES/GPL-2.0)。
第三方组件：QModem 为 MPL-2.0，Nikki 为 GPL-3.0，NetPath 为 GPL-2.0（README 另有非商业表述，个人使用无影响），其余以各自仓库为准。
