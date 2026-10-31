# 包组合与开机预设

两档包组合的定义、共用开机预设，以及如何自定义。

## 包组合

| 组合 | 定位 | 内容 |
|------|------|------|
| **lite** | 精简实用（默认） | QModem 随身 WiFi 全套 + 中文化 LuCI + Argon 主题（默认）+ turboacc 硬件加速/BBR + nikki 代理 + ddns-go + acme 证书 + UPnP + WOL + SFTP + WebDAV + SQM + nlbwmon 流量统计 |
| **ultimate** | 全能 | lite 全部 + tailscale + travelmate + ttyd + filebrowser + netspeedtest + netdata（轻量化）+ mwan3 多 WAN + macvlan |

> **上游变更备注（2026-10 实测）**：官方 luci feed 已删除 `luci-app-vnstat` / `luci-app-autoreboot` / `luci-app-socat`，
> 分别以 nlbwmon / crontab 预设 / socat 核心（CLI）替代；turboacc 与 netspeedtest 改用作者独立 feed；
> wolplus 仓库无 feed 化结构，改用官方 `luci-app-wol`。详见 `common/packages/*.list` 内注释。

## 开机预设（两档共用）

`uci-defaults` 首次开机自动生效，均可改：

- UPnP 默认**安全模式**；BBR 拥塞控制默认启用
- 每周一凌晨 04:30 自动重启（crontab 写入；上游 luci-app-autoreboot 已删除）
- netdata 纯 RAM 模式 + 2 小时历史 + 关机器学习/Cloud（512MB 内存防溢出，配置见 `common/files/etc/netdata/`）

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

feeds 追加配置见 `common/feeds.append`：

- **nikki**（mihomo）— 代理内核与管理界面
- **kenzok8/openwrt-packages + small** — argon-config、ddns-go、filebrowser 等
- **turboacc**（chenmozhijin）— 网络加速面板
- **netspeedtest**（sirpdboy）— 网络测速面板

### 公共定制脚本

`common/customize.sh` 在 feeds 安装后执行（默认主题 sed 依赖 feeds 目录），可在此追加构建期定制。
