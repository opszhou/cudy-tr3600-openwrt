# 包组合与开机预设

两档包组合的定义、共用开机预设，以及如何自定义。

## 包组合

| 组合 | 定位 | 内容 |
|------|------|------|
| **lite** | 精简实用（默认） | QModem 随身 WiFi 全套 + 中文化 LuCI + Argon 主题（默认）+ turboacc 硬件加速/BBR + nikki 代理 + ddns-go + acme 证书 + UPnP + WOL + SFTP + dufs（网页文件管理 + WebDAV，8080，含 LuCI 面板）+ SQM + nlbwmon 流量统计 + **系统仪表盘**（只读首页）+ USB 存储全驱动（UAS/ext4/exFAT/NTFS3/FAT32 + 自动挂载） |
| **ultimate** | 全能 | lite 全部 + tailscale + travelmate + ttyd + luci-app-statistics 轻量监控 + macvlan + transmission（BT 下载，默认目录 /mnt、开机自启） |

> **上游变更备注（2026-10 实测）**：官方 luci feed 已删除 `luci-app-vnstat` / `luci-app-autoreboot` / `luci-app-socat`，
> 分别以 nlbwmon / crontab 预设 / socat 核心（CLI）替代；turboacc 面板用作者独立 feed；
> wolplus 仓库无 feed 化结构（上游 siwind 2022-10 起停更），改用官方 `luci-app-wol`；
> netspeedtest 依赖的上游 python3 子包已不存在，连同其 feed 一并移除；
> NetPath 已试装后移除（上游无 init/uci 文件，仅 CLI 无面板），多 WAN 暂无面板方案。详见 `common/configs/*.list` 内注释。
>
> **luci-app-dufs（2026-11 起）**：openwrt 官方 luci、kenzok8、small 三个源都没有 dufs 的 LuCI 面板（只有后端 `dufs`）。
> 面板取自 **immortalwrt/luci**，原样 vendored 到 `common/package/luci-app-dufs`（Apache-2.0）；
> `assemble.sh` 在 `REPO=immortalwrt` 时会删掉本地副本，改用该上游 luci feed 自带的同名包，避免 Kconfig 重复符号。
>
> **luci-app-sysdashboard（2026-11 起）**：本仓库自研的**只读**系统仪表盘，不是上游组件。
> 与 FanchmWrt 那类带 DPI 应用识别的看板不同，它只聚合本机已有的公开数据
> （`/proc`、`/sys`、`/tmp/dhcp.leases`），不做流量审计、不识别 App/URL、不需要内核模块，
> 因此 openwrt / immortalwrt 两个上游通用，也不会和硬件加速冲突。详见下方「系统仪表盘」一节。

## 开机预设（两档共用）

`common/files/etc/uci-defaults/99-router-presets`，首次开机自动生效，LuCI 均可改：

- 默认 LAN **192.168.10.1/24**，DHCP 池 **.100~.249**；主机名 **tr3600**
- 时区 **Asia/Shanghai**（CST-8）；LuCI 时间显示 **24 小时制**（`clock_hourcycle=h23`）
- 双频 WiFi 7（EHT）默认：国家码 **CN**（默认 00 会禁掉 5G 149~165 段）、ACS 自动信道（排除 DFS）、2.4G 20MHz / 5G 80MHz / 6G 160MHz；已设密钥接口升级为 **WPA2/WPA3 混合**（sae-mixed + PMF optional，无密钥接口不动避免起不来）
- **无线默认开启**：radio 与 wifi-iface 都置 `disabled=0`（OpenWrt 出厂是关闭的）；无密钥接口显式 `encryption=none` → 默认是**开放热点**
- **USB 网卡自动当 WAN**：`common/files/etc/hotplug.d/net/50-usb-wan`（插拔时建/拉起 `wanusb`）+ `common/files/etc/init.d/usb-wan`（开机兜底扫描，START=95）；预设负责把它 `enable` 进 rc.d。接管范围＝USB 总线上的**以太协议**设备（有线网卡 / 手机共享 / RNDIS·ECM·NCM 免驱上网卡）；名字 `wwan*`·`rmnet*`、或同设备存在 `qmi_wwan*`·`cdc_mbim`·`cdc_wdm` 驱动的（需拨号的 QMI/MBIM 模组）一律不碰，留给 QModem
- **5G SSID 自动加 `_5G` 后缀**（区分双频，幂等）
- dufs 首启预设：**8080 端口**、根目录 `/mnt`、仅第一块 USB 盘（`/mnt/sda1`）可写、其余挂载点只读、删除全局关；LuCI 面板「服务 → Dufs」可在图形界面改这些项
- Transmission 首启预设：**开机自启**，下载/未完成/配置目录从上游默认的 `/tmp`（内存盘，重启即丢）迁到 `/mnt/transmission/`；首启时若已插 U 盘（`/mnt/sda1`）则改落 `/mnt/sda1/transmission/`
- UPnP 默认**安全模式**；BBR 拥塞控制默认启用
- 每周一凌晨 04:30 自动重启（crontab 写入；上游 luci-app-autoreboot 已删除）
- 测试：`scripts/test-router-presets.sh`（开机预设，stub uci/crontab 沙箱）、`scripts/test-usb-wan.sh`（USB 网卡当 WAN 的 10 个判定场景，假 sysfs + stub uci/ubus/ip/ifup）、`scripts/test-hotfix.sh`（运行期补丁：语法、写入、幂等、失败不阻断）

### 运行期补丁（hotfix）

`common/files/etc/hotfix.d/*.sh` + `common/files/etc/init.d/hotfix`（START=98）。

与 `uci-defaults` 的分工：

| | uci-defaults | hotfix |
|---|---|---|
| 执行时机 | 仅首次开机，跑完即删 | 每次开机 |
| 用途 | 一次性初始配置 | 配置被覆盖后自我收敛 |
| 要求 | 幂等更保险 | **必须幂等** |

同一份补丁既是固件内建，也能 `scp` 到设备 `/etc/hotfix.d/` 直接重放，避免"设备上改了、仓库没改"的漂移。

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

包清单按功能拆分在 `common/configs/`：

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

### 源码树内的 vendor 包

非标准「每包一个子目录」布局、或上游 feed 根本没有的包，统一放在 `common/package/`，
由 `assemble.sh` 复制进源码树 `package/`，绕开 scan.mk 对 feed 布局的限制：

| 包 | 原因 |
|----|------|
| `luci-app-dufs` | 三个上游 luci 源都没有（只有 immortalwrt/luci 有）；Makefile 的 `include ../../luci.mk` 已改为 `$(TOPDIR)/feeds/luci/luci.mk`，否则在 `package/` 下解析不到 |
| `luci-app-sysdashboard` | 本仓库自研包，上游不存在；同样改用 `$(TOPDIR)/feeds/luci/luci.mk`。rpcd 脚本必须带可执行位（本机 `core.filemode=false`，提交前需 `git update-index --chmod=+x`） |

> 注意与上游 feed 重名：若某上游 feed 自带同名包（如 immortalwrt 的 luci feed 自带 luci-app-dufs），
> `assemble.sh` 必须跳过本地副本，否则 Kconfig 会出现重复符号。
> `luci-app-sysdashboard` 是自研名，四个 feed（openwrt/luci、immortalwrt/luci、kenzok8、small）均无同名包，无需例外处理。

### 系统仪表盘（luci-app-sysdashboard）

| 项 | 说明 |
|----|------|
| 后端 | `root/usr/libexec/rpcd/sysdashboard` — rpcd 插件，**只读**采一次快照输出 JSON；无常驻进程、无状态、不 sleep、不写文件 |
| 前端 | `htdocs/luci-static/resources/view/sysdashboard.js` — 纯 LuCI JS 视图 + 内联 SVG，零第三方 JS 库；3 秒轮询，对相邻快照差分算速率 / CPU 使用率 |
| 权限 | `root/usr/share/rpcd/acl.d/luci-app-sysdashboard.json` — 只授权 `ubus sysdashboard get` 读 |
| 菜单 | `root/usr/share/luci/menu.d/...json` 注册 `admin/dashboard`，`order=5`（小于 `admin/status` 的 10）→ 登录后默认首页；原生「状态 → 概况」仍在 |
| 翻译 | `po/zh_Hans/sysdashboard.po` → 语言包 `luci-i18n-sysdashboard-zh-cn` |
| 包清单 | `common/configs/lite.list`（lite / ultimate 双组合共用） |

采集项：`uptime`、`loadavg`、`/proc/stat` 原始 jiffies、`meminfo`、`/proc/net/dev` 累加字节（排除 lo）、`nf_conntrack_count`、DHCP 租约、所有 `thermal_zone*/temp`、hwmon 的 `fan*_input` / `pwm*`、`cooling_device*/cur_state`。

降级规则：源不存在时该字段为 `-1` 或空数组，视图显示「不可用 / 暂无数据」而不是伪造 0；无风扇设备照常可用。卡片用半透明中性底色 + 继承文字色，浅色（Bootstrap）与深色（Argon）主题都能读。

⛔ **边界**：不做 DPI / 应用识别 / 上网记录（那是 FanchmWrt `kmod-fwx` + `fwxd` 或 OpenAppFilter 的活，需要内核模块且必须关硬件加速，与本固件的 `kmod-nft-offload` 冲突）。风扇**只显示不控制**：内核 thermal 的 `cooling-maps` 已按 65/72/80/88 °C 四档接管 PWM，再装 `fancontrol` 这类用户态调速器会抢同一个 `pwm1`。

沙箱测试：`bash scripts/test-sysdashboard.sh`。

## 多上游支持（openwrt / immortalwrt）

同一套设备配置可编译两个上游，区别只在三处：

| 项目 | openwrt | immortalwrt |
|---|---|---|
| 补丁目录 | `patches/openwrt-<分支>/` | `patches/immortalwrt-master/`（同补丁，实测零改动可用） |
| feeds 追加 | `common/feeds.append`（含 kenzok8/small、turboacc） | `common/feeds.append.immortalwrt`（只加 qmodem + nikki） |
| 清单差异 | 无 | `upstreams/immortalwrt/exclude.list`（关闭 upstream 缺失的包） |

dispatch 参数：`upstream_owner=immortalwrt`、`upstream_repo=immortalwrt`、`upstream_branch=master`。

**immortalwrt 已知差异**（2026-11-03 容器实测 lite/ultimate 双组合 defconfig + 审计均 missing=0）：

- 自带 argon 主题、ddns-go、ttyd、transmission、travelmate、statistics → 不加 kenzok8 feed
- **无 `luci-app-argon-config`**（argon 主题照常，无调色面板）
- **无 SFE 三件套**（kmod-fast-classifier / kmod-shortcut-fe-{cm,drv}）→ 只关这三个条件子选项，turboacc 面板本体保留（OFFLOADING/BBR 可用）
- **保留了 `kmod-nft-fullcone`**（openwrt main 已删除）→ 全锥形 NAT 在 immortalwrt 版里反而可用，差异清单里显式打开
