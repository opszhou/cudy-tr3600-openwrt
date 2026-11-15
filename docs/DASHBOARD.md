# 管理面板（dashboard）部件架构

本包不自己画界面：**框架、样式、拖拽布局全部用官方 `luci-mod-dashboard`**，
我们只负责「数据从哪来、什么时候显示、显示什么」。

## 一、文件分工

```
view/dashboard/
  include/50-cellular.js    入口（3 行）：return registry.build()
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

## 五、新增一个部件

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

## 六、布局页说明

- 每个条目显示为「标题 · 自动隐藏条件」（由 catalog 的 `hint` 生成，改文案只改一处）
- 布局面板顶部会插入一段总说明（`sd/layout-note.js`，幂等；注入失败只丢说明）

## 七、真机上即时看中文（不重新编译固件）

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

## 八、测试

```sh
bash scripts/test-sysdashboard.sh     # rpcd 快照：字段解析、caps、降级
bash scripts/test-dashboard-catalog.sh # 部件目录 + 能力模型 + 注册中心（场景矩阵）
```

两个脚本都是纯离线沙箱：`test-dashboard-catalog.sh` 在 Node 里模拟 LuCI 的
`'require xxx as y'` 语法，用假的官方 include 跑真实代码。
