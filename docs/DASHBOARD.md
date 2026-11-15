# 管理面板（dashboard）部件架构

本包不自己画界面：**框架、样式、拖拽布局全部用官方 `luci-mod-dashboard`**，
我们只负责「数据从哪来、什么时候显示、显示什么」。

## 一、文件分工

```
view/dashboard/
  include/99-sd-dashboard.js    入口（3 行）：return registry.build()
  sd/catalog.js             部件清单 —— 唯一声明处
  sd/caps.js                能力模型 —— 唯一「有没有数据」判定入口
  sd/providers.js           网络侧内容（信号/网络状态/流量/上联/在线设备）
  sd/registry.js            注册中心：声明、委派、组装、显隐
  sd/visibility.js          标签页显隐（状态类 + CSS + 自动切激活项）
  sd/layout-note.js         布局页说明注入
  sd/util.js                格式化与 SVG 小工具
```

数据源：`/usr/libexec/rpcd/sysdashboard`（只读快照，含 `caps` 能力表）。

## 二、数据流

```
rpcd 快照 ──► caps.js（能力布尔） ──► catalog 每条 need ──► registry
                                                        ├─ 有数据：node / tab
                                                        └─ 无数据：node=null / tab 加状态类
```

判定全部在 rpcd 侧完成，前端不重复判断，也不读 netifd（QModem 的 wwan0 不在 netifd 里）。

## 三、显隐规则

| 能力 | 含义 | 隐藏的部件 |
|---|---|---|
| `wan` | 默认路由所在设备存在且 operstate 非 down | 互联网卡、WAN 流量图、流量统计卡、互联网标签 |
| `modem` | qmodem 的 ubus 对象存在 | 网络状态卡 |
| `signal` | cell_info 给出有效 RSRP | 信号强度卡 |
| `clients` | 租约 + ARP 合并后 > 0 | DHCP 卡、DHCP 标签 |
| `wifi` | 有射频且存在 AP 接口 | 无线卡、无线标签 |
| `wifiActive` | 无线可用且有客户端 | 无线分布/信号/流量图 |
| `null` | 不依赖数据 | 运行时间、CPU、内存、负载、系统、资源 |

条件恢复后，下一轮轮询（默认 5 秒）自动出现，无需刷新。

### 两种隐藏机制（不能混用）

- **卡片 / 图表**：始终注册 id，无数据时 `node: null`。
  官方在 `collectSections` 里对布局结果做 `.filter(item => item != null)`，null 会被丢掉。
  ⛔ 不能「干脆不返回该 id」——官方记录是后注册覆盖先注册，不返回时官方同 id 的部件会**回填显示**。
- **标签页**：官方对 tabs 不做 null 过滤（会包成对象建空面板），因此用 body 状态类
  `sd-hide-tab-<id>` + CSS 隐藏「标签 + 菜单项」，并把选中项切到第一个可见标签。

## 四、官方 include 的定位

官方 5 个 include 在 `registry.js` 里被降级为**纯内容提供者**：

```js
inc.widgets = [];                  // 不再声明部件（否则默认布局里同一 id 出现两次，卡片渲染两遍）
inc.available = function() { return false; };  // dashboard 不再加载/渲染它们
```

内容仍通过 `inc.load()` / `inc.render()` 由 registry 调用，所以：

- **系统类**（运行时间、CPU、内存、负载、系统负载图、系统/资源标签）内容不重写，只统一注册与显隐；
- **网络类**（互联网、WAN 流量、DHCP、信号、网络状态、流量统计）由 `providers.js` 实现。

## 五、构建集成（扩展点方式）

**不 vendor 官方模块**：`luci-mod-dashboard` 仍由 luci feed 提供，我们只往它扫描的目录里加文件，
并用同 id 覆盖部件。卸载我们的包，面板自动回退成官方原样。

| 项 | 做法 |
|---|---|
| 依赖 | `LUCI_DEPENDS:=+luci-base +luci-mod-dashboard`，并在 `common/configs/lite.list` 显式选包（防被裁剪） |
| 命名空间 | 入口 `include/99-sd-dashboard.js`：`99` 保证最后加载（同 id 覆盖才生效），`sd-` 前缀避免与上游新增 include 撞名；其余自定义文件在 `view/dashboard/sd/`、图标用 `icons/sd-*.svg` |
| 契约校验 | `scripts/verify-dashboard-api.mjs`，在 `build-device.sh` 的 **feeds 安装之后、编译之前**执行：校验 `charts.kpi/card/empty`、`index.js` 的 `found[slot]` + `!=null` 过滤、`widgets` 的 `available/defaults/slots`、官方 16 个 widget id 是否齐全。任一不满足 **构建失败**，不让白屏固件出门。⛔ 匹配前先去掉空白——25.12 是压缩成一行、master 已 pretty-print，靠排版匹配会误报（run#63 实测） |
| 上游版本 | 校验通过时打印 luci feed 的 `git describe`，便于回溯漂移 |
| 例外 | 只有扩展点做不到时才打最小 patch（带目标文件哈希守卫），放 `common/patches/luci/` |

测试：`bash scripts/test-verify-dashboard-api.sh`（5 条断言：正常通过、缺 null 过滤、缺 widget id、目录不存在）。

## 六、三种槽位的分工

面板只有三种槽位：**状态卡（cards）/ 实时图表（charts）/ 详情标签页（tabs）**。
分配原则：能形成时间序列的才配图表；纯状态字段不配图；详情页只给「字段多到一张卡放不下」的主题。

| 主题 | 状态卡 | 实时图表 | 详情标签页 |
|---|---|---|---|
| 上联 / 互联网 | 互联网（IP / 网关 / 承载设备） | WAN 流量 | 互联网（上联 + 信号 + 网络 + 流量） |
| 蜂窝信号 | 信号强度（RSRP / 等级 / RSRQ·SINR） | 信号趋势（RSRP 历史 + 最低/最高） | 同上「信号强度」一节 |
| 网络状态 | 网络状态（运营商 / 制式 / 频段·频率·带宽） | —（运营商、频段没有时间序列意义） | 同上「网络状态」一节 |
| 流量 | 流量统计（累计 + 实时速率 + 今日/昨日/本周） | WAN 流量 | 同上「流量」一节（含峰值、连接时长） |
| 在线设备 | 在线设备（总数 + DHCP/ARP 构成） | 在线设备趋势 | DHCP 设备（表 + 统计摘要） |
| 系统 | 官方 CPU / 内存 / 运行时间 | 系统负载（官方） | 系统 / 资源（官方） |

⛔ 不要为了「凑齐三件套」给纯状态字段硬加图表。

## 七、新增一个部件

只改三处，不要另外写注册代码：

1. `sd/catalog.js` 增加一条：
   ```js
   { id: 'my-widget', slot: 'cards', title: _('My widget'), order: 90,
     need: 'wan', own: true, hint: HINT.offline }
   ```
   - `slot`：`cards` / `charts` / `tabs`
   - `need`：`caps.js` 里的能力键，`null` 表示始终显示
   - `own`：`true` 用 `providers.js`，`false` 用官方 include 的内容
   - `hidden`：默认布局里不显示（用户可在布局页加入）
2. `sd/providers.js` 增加 `card()` / `chart()` / `tab()` 分支（`own: true` 时）
3. `po/zh_Hans/sysdashboard.po` 补中文

## 八、布局页说明

- 每个条目显示为「标题 · 自动隐藏条件」（由 catalog 的 `hint` 生成，改文案只改一处）
- 布局面板顶部会插入一段总说明（`sd/layout-note.js`，幂等；注入失败只丢说明）

## 九、今日 / 昨日 / 本周用量

QModem 只提供「累计收发」（`get_stats`，模组侧持久），没有日统计，所以由我们自己记账：

- `root/usr/libexec/sysdashboard-usage`：采样 QModem 总量，取增量累加到「今天 / 本周」，
  跨天把前一天记为「昨天」，跨周清零；模组统计被清零时只重置基线、不自减
- 采样频率：cron 每 5 分钟一次（`/etc/crontabs/root`，由 uci-defaults 安装），
  页面打开时 rpcd 每次轮询也会顺带推进
- 状态文件：`/etc/sysdashboard-usage.conf`，**默认每 15 分钟才落盘一次**（减少 NAND 写入），
  跨天立即落盘；掉电最多丢 15 分钟
- 首次运行只建立基线：历史累计不会算进「今天」，`since` 字段记录开始统计的时间
- 测试：`bash scripts/test-usage-stats.sh`（15 条断言：增量、清零、跨天、跨周、落盘、非法参数）

⛔ 这是本包唯一会写盘的地方；rpcd 其它逻辑仍然只读。

## 十、真机上即时看中文（不重新编译固件）

译文（`.lmo`）由 `luci.mk` 在**编译固件时**从 `po/zh_Hans/*.po` 生成，所以新加的
msgid 在老固件上会回退成英文。要立刻在真机上看到中文，可以本地编译并推上去：

```sh
python3 scripts/make-lmo.py \
  common/package/luci-app-sysdashboard/po/zh_Hans/sysdashboard.po \
  /tmp/sysdashboard.zh-cn.lmo --verify

scp /tmp/sysdashboard.zh-cn.lmo root@<router>:/usr/lib/lua/luci/i18n/
```

`make-lmo.py` 与上游 `po2lmo` 完全等价（同样的 SuperFastHash 与索引格式），
`--verify` 会按 `lmo.c` 的方式读回来抽查几条。设备上还可以直接用 LuCI 自己的接口验证：

```sh
lua -e 'local i=require "luci.i18n"; i.setlanguage("zh-cn"); print(i.translate("Network status"))'
```

⛔ 这只用于真机临时验证，**不要在构建脚本里调用**——固件里必须由 luci.mk 正常生成，
否则会出现两份不一致的译文来源。

## 十一、测试

```sh
bash scripts/test-sysdashboard.sh     # rpcd 快照：字段解析、caps、降级
bash scripts/test-dashboard-catalog.sh # 部件目录 + 能力模型 + 注册中心（场景矩阵）
```

两个脚本都是纯离线沙箱：`test-dashboard-catalog.sh` 在 Node 里模拟 LuCI 的
`'require xxx as y'` 语法，用假的官方 include 跑真实代码。
