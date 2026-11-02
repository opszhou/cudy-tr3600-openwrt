# 包组合与开机预设

两档包组合的定义、共用开机预设，以及如何自定义。

## 包组合

| 组合 | 定位 | 内容 |
|------|------|------|
| **lite** | 精简实用（默认） | QModem 随身 WiFi 全套 + 中文化 LuCI + Argon 主题（默认）+ turboacc 硬件加速/BBR + nikki 代理 + ddns-go + acme 证书 + UPnP + WOL + SFTP + dufs（网页文件管理 + WebDAV，8080）+ SQM + nlbwmon 流量统计 + USB 存储全驱动（UAS/ext4/exFAT/NTFS3/FAT32 + 自动挂载） |
| **ultimate** | 全能 | lite 全部 + tailscale + travelmate + ttyd + luci-app-statistics 轻量监控 + macvlan + transmission（BT 下载） |

> **上游变更备注（2026-10 实测）**：官方 luci feed 已删除 `luci-app-vnstat` / `luci-app-autoreboot` / `luci-app-socat`，
> 分别以 nlbwmon / crontab 预设 / socat 核心（CLI）替代；turboacc 面板用作者独立 feed；
> wolplus 仓库无 feed 化结构（上游 siwind 2022-10 起停更），改用官方 `luci-app-wol`；
> netspeedtest 依赖的上游 python3 子包已不存在，连同其 feed 一并移除；
> NetPath 已试装后移除（上游无 init/uci 文件，仅 CLI 无面板），多 WAN 暂无面板方案。详见 `common/packages/*.list` 内注释。

## 开机预设（两档共用）

`common/files/etc/uci-defaults/99-router-presets`，首次开机自动生效，LuCI 均可改：

- 默认 LAN **192.168.10.1/24**，DHCP 池 **.100~.249**；主机名 **tr3600**
- 时区 **Asia/Shanghai**（CST-8）；LuCI 时间显示 **24 小时制**（`clock_hourcycle=h23`）
- 双频 WiFi 7（EHT）默认：国家码 **CN**（默认 00 会禁掉 5G 149~165 段）、ACS 自动信道（排除 DFS）、2.4G 20MHz / 5G 80MHz / 6G 160MHz；已设密钥接口升级为 **WPA2/WPA3 混合**（sae-mixed + PMF optional，无密钥接口不动避免起不来）
- **5G SSID 自动加 `_5G` 后缀**（区分双频，幂等）
- dufs 首启预设：**8080 端口**、根目录 `/mnt`、仅第一块 USB 盘（`/mnt/sda1`）可写、其余挂载点只读、删除全局关
- UPnP 默认**安全模式**；BBR 拥塞控制默认启用
- 每周一凌晨 04:30 自动重启（crontab 写入；上游 luci-app-autoreboot 已删除）
- 测试：`scripts/test-router-presets.sh`（stub uci/crontab 沙箱实测，CI/local 均可跑）

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
- **kenzok8/openwrt-packages + small** — argon-config、ddns-go 等
- **turboacc**（chenmozhijin）— 网络加速面板

`@latest` 语义（构建时由 `assemble.sh` 经 `git ls-remote` 实时解析，日志打印解析结果）：

1. 有 release tag 的仓库 → 追踪**最新稳定版 tag**（自动过滤 `rc/beta/alpha` 等预发布 tag，如 QModem 会选 v3.3.0 而跳过 v3.4.0_rc3）
2. 只有预发布 tag → 取最高 tag
3. 完全无 tag（kenzok8 两个聚合仓库、turboacc）→ 回退默认分支

### 公共定制脚本

`common/customize.sh` 在 feeds 安装后执行（默认主题 sed 依赖 feeds 目录），可在此追加构建期定制。
