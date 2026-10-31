# 包组合与开机预设

两档包组合的定义、共用开机预设，以及如何自定义。

## 包组合

| 组合 | 定位 | 内容 |
|------|------|------|
| **lite** | 精简实用（默认） | QModem 随身 WiFi 全套 + 中文化 LuCI + Argon 主题（默认）+ turboacc 硬件加速/BBR + nikki 代理 + ddns-go + acme 证书 + UPnP + WOL + SFTP + WebDAV + SQM + nlbwmon 流量统计 + USB 存储全驱动（UAS/ext4/exFAT/NTFS3/FAT32 + 自动挂载） |
| **ultimate** | 全能 | lite 全部 + tailscale + travelmate + ttyd + filebrowser + netspeedtest + luci-app-statistics 轻量监控 + NetPath 多 WAN + macvlan |

> **上游变更备注（2026-10 实测）**：官方 luci feed 已删除 `luci-app-vnstat` / `luci-app-autoreboot` / `luci-app-socat`，
> 分别以 nlbwmon / crontab 预设 / socat 核心（CLI）替代；turboacc 与 netspeedtest 改用作者独立 feed；
> wolplus 仓库无 feed 化结构（上游 siwind 2022-10 起停更），改用官方 `luci-app-wol`；
> 多 WAN 由 mwan3 换为 NetPath（见下）。详见 `common/packages/*.list` 内注释。
>
> **NetPath 说明**：Rust + nftables 重写的 mwan3（[HikaruChang/NetPath](https://github.com/HikaruChang/NetPath)，
> 2026-10 仍在活跃开发），明确支持 OpenWrt 24.x/25.x。注意三点：
> ① 依赖 `rust/host` 构建链，首次编译约多花 15~25 分钟；
> ② LuCI 面板暂无中文语言包；③ 项目较新（v1.0.0），README 声明非商业使用，与 LICENSE 的 GPL-2.0 存在表述冲突，
> 个人使用无影响，商用前需自行确认。

## 开机预设（两档共用）

`common/files/etc/uci-defaults/99-router-presets`，首次开机自动生效，LuCI 均可改：

- 默认 LAN **192.168.10.1/24**，DHCP 池 **.100~.249**
- UPnP 默认**安全模式**；BBR 拥塞控制默认启用
- 每周一凌晨 04:30 自动重启（crontab 写入；上游 luci-app-autoreboot 已删除）
- **5G SSID 自动加 `_5G` 后缀**（区分双频）

### WED 关闭（MT7990 稳定性）

`common/files/etc/modules.conf` 固化 `options mt7996 wed_enable=N`。
mt76 当前 main 默认就是 `false`，显式写入防止上游翻转默认值；
同时保证 turboacc 开硬件分载时只有有线走硬件加速，无线不走 WED
（WED 仅在「硬件分载开启 + wed_enable=Y」时激活）。

### wpad 变体

设备种子（`default.seed`）将默认 `wpad-basic-mbedtls` 换为 **`wpad-mesh-openssl`**
（mesh + WPA3，openssl 加密栈）。wpad 各变体互斥，种子中已显式 `wpad-basic-mbedtls=n`。

## 中文化机制

新版 LuCI 必须在设备种子中开启 `CONFIG_LUCI_LANG_zh_Hans=y`（`devices/<设备>/default.seed`），
否则所有 `luci-i18n-*` 语言包不会参与编译——单独写 `CONFIG_PACKAGE_luci-i18n-*-zh-cn` 行是无效的。

## 自定义

### 改包清单

包清单按功能拆分在 `common/packages/`：

| 文件 | 内容 |
|------|------|
| `modem.list` | 随身 WiFi（QModem）相关包，lite/ultimate 共用 |
| `lite.list` | lite 组合基础包 |
| `proxy.list` | 出行代理相关包（tailscale / travelmate 等，ultimate 使用） |
| `extra.list` | ultimate 相对 lite 的增量包 |

直接编辑对应 `.list` 文件即可。若某行包名在 feeds 中已不存在，
`make defconfig` 会静默忽略——编译完成后请核对 `manifest` 文件确认实际入包情况。

### 改基础种子

设备级 `.config` 种子在 `devices/<设备>/default.seed`（目标机型 + 基础包开关 + `LUCI_LANG`）。

### 第三方插件源

feeds 追加配置见 `common/feeds.append`，所有 feed 均标记 `;@latest`：

- **qmodem**（FUjr/QModem）— 随身 WiFi 管理
- **nikki**（mihomo）— 代理内核与管理界面
- **kenzok8/openwrt-packages + small** — argon-config、ddns-go、filebrowser 等
- **turboacc**（chenmozhijin）— 网络加速面板
- **netspeedtest**（sirpdboy）— 网络测速面板
- **netpath**（HikaruChang）— 多 WAN 管理器

`@latest` 语义（构建时由 `assemble.sh` 经 `git ls-remote` 实时解析，日志打印解析结果）：

1. 有 release tag 的仓库 → 追踪**最新稳定版 tag**（自动过滤 `rc/beta/alpha` 等预发布 tag，如 QModem 会选 v3.3.0 而跳过 v3.4.0_rc3）
2. 只有预发布 tag → 取最高 tag
3. 完全无 tag（kenzok8 两个聚合仓库、turboacc、netpath）→ 回退默认分支

### 公共定制脚本

`common/customize.sh` 在 feeds 安装后执行（默认主题 sed 依赖 feeds 目录），可在此追加构建期定制。
