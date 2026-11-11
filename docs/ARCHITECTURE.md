# 架构与目录结构

多设备设计、补丁机制与脚本职责说明。

## 目录结构

```
├── .github/workflows/
│   ├── sync-pr.yml        # 🔀 合并官方 PR（最常用）
│   └── build.yml          # 🚀 编译固件
├── devices/               # ── 路由器特有（每台路由器一个目录）──
│   └── cudy_tr3600-v1/
│       ├── device.yml     # 元数据：target / profile / 上游分支 / 默认 PR 列表
│       ├── default.seed   # .config 种子（目标机型 + 基础包）
│       ├── configs/       # 设备级差异清单 add.list / remove.list（可选，后写覆盖前写）
│       ├── patches/       # 补丁（<上游仓库名>-<分支>/, 如 openwrt-main/ immortalwrt-master/）
│       ├── package/       # 设备专属源码包（tr3600-dualslot-upgrade）
│       └── files/         # 设备专属 /etc 覆盖
├── upstreams/             # ── 上游层：仅上游不同的东西 ──
│   ├── openwrt/feeds.append
│   └── immortalwrt/{feeds.append, exclude.list}
├── common/                # ── 全局层：所有设备、所有上游共用 ──
│   ├── configs/           # 包清单(.config 片段)：modem(随身WiFi)/lite/proxy/extra
│   ├── customize.sh       # 公共定制脚本（feeds 安装后执行）
│   ├── package/           # 源码树 vendor 包（luci-app-dufs / luci-app-sysdashboard，不走 feed）
│   └── files/             # 公共 /etc 覆盖（开机预设 uci-defaults / hotplug.d / init.d）
└── scripts/               # 组装/合并/编译脚本（CI 与本地通用）
```

## 设计原则

- **不 fork 整个 OpenWrt 源码树** — 编译时实时 checkout 上游，官方 PR 以补丁形式入库
- **设备配置抽离，公共配置共用** — 新增设备 = 复制一个目录，见 [ADD-DEVICE.md](ADD-DEVICE.md)
- **CI 与本地同一套脚本** — workflows 只做调度，全部逻辑在 `scripts/`

## 补丁机制

### 为什么补丁入库而不是构建时实时拉 PR

- **可复现**：补丁内容固化在仓库里，同一 commit 永远编译出同一结果
- **PR 内容漂移可控**：PR 作者 push 更新不影响已入库的补丁
- **平滑回归官方**：上游正式合并某 PR 后，删除对应 `pr*.patch` 即切回官方源码

### 命名与应用顺序

补丁按文件名字典序应用，**首位数字即档位**，字典序天然等于应用顺序：

```
0xxx-<描述>.patch        本地基础补丁（不依赖任何 PR）
1pr<PR号5位补零>.patch   官方 PR 补丁（如 1pr25860.patch，由「合并官方 PR」工作流生成）
9xxx-<描述>.patch        PR 后本地修正
```

> ⚠️ 历史教训（run#13）：`pr*.patch` 以字母 p 开头，ASCII 序里 '9' < 'p'，
> 会导致 9xxx 修正先于其依赖的 PR 补丁应用而失败。
> 脚本内置命名守卫：不符合上述三档格式的补丁名会直接报错拒绝应用。

### 应用前提

上游 checkout 必须 `fetch-depth: 0`（完整历史），否则 `git apply --3way` 缺 preimage blob 会失败。

### optional 补丁

`devices/cudy_tr3600-v1/patches/optional/` 存放旧实验项目的 TR3600 修正补丁，
仅适配 25.12 + PR#24596 组合，默认以 `.disabled` 后缀禁用。
适用范围见该目录下的 README。

## device.yml 字段

```yaml
id: cudy_tr3600-v1        # 设备 ID = devices/ 目录名
target: mediatek/filogic  # OpenWrt target/subtarget
profile: cudy_tr3600-v1   # CONFIG_TARGET_..._DEVICE_<profile>
branch: main              # 上游分支；补丁目录须对应 patches/<上游仓库名>-<branch>
default_prs:              # 「合并官方 PR」未填号时默认合并的 PR（可留空）
  - 25860
```

> ⚠️ 只列**当前仍需要、且上游未吸收**的 PR。已并入上游的 PR 必须从 `default_prs` 删掉，
> 否则 sync-pr 重新拉 diff 时会与现有源码 3-way 冲突（run#34 的 25996 教训）。
> 24581 与 25860 是互斥的设备支持 PR，同一补丁栈只能启用其一。

> ⚠️ `branch` 与补丁目录名 `<上游仓库名>-<branch>` 必须一一对应（上游仓库名即 build.yml 的 upstream_repo）。
> 例外：release 分支名本身已带仓库名前缀（如 `openwrt-25.12`）时，目录直接叫 `patches/openwrt-25.12/`，
> 不再重复成 `patches/openwrt-openwrt-25.12/`——规则实现在 `scripts/apply-device-patches.sh` 与 `verify-device.sh`。

## scripts/ 脚本清单

| 脚本 | 职责 |
|------|------|
| `parse-device.sh` | 解析 device.yml 为环境变量 |
| `list-devices.sh` | 列出全部设备（`--json` 供 build_all 矩阵用） |
| `apply-device-patches.sh` | 按字典序应用设备补丁栈 |
| `apply-pr.sh` | 拉取单个官方 PR 并生成补丁（diff 路径用绝对路径） |
| `sync-pr.sh` | 批量合并 PR（需收集失败而非中断，不用 `set -e`） |
| `verify-device.sh` | 编译**前**的秒级闸门：补丁能否应用（含 3-way 回退）、DTS 结构、filogic.mk 自洽、02_network 端口映射（在临时 worktree 里跑，不改主树） |
| `validate-dts.mjs` | 纯 Node 的设备树结构校验器（语法树/引用/分区/nvmem/gpio/LED/交换端口），CI 与本地同一份 |
| `test-02network.sh` | 把 `02_network` 拉进沙箱跑真分支，断言 board → LAN/WAN 端口映射 |
| `assemble.sh` | 组装源码树：上游 + feeds + 包清单 + files + 补丁 |
| `build-device.sh` | 一条龙：组装 → defconfig → make |
| `test-sysdashboard.sh` | 仪表盘 rpcd 脚本的沙箱冒烟测试（假 /proc、/sys、租约，校验 JSON 与降级） |
| `apply-qmodem-nat2.sh` | feeds 就绪后把 QModem `at_dial()` 的 nat 下发由 1 改为 2（幂等、回读校验、格式不符即构建失败） |
| `test-qmodem-nat2.sh` | 上述补丁的沙箱测试（替换 / 幂等 / 格式不符 / 缺文件） |

> QModem feed 定制走 `common/customize.sh`（`build-device.sh` 在 feeds install 之后调用），
> ⛔ 不放进 `devices/*/patches/` —— 那里只作用于 OpenWrt 源码树，且早于 feeds 就绪。
> 定制脚本必须以自身位置反推仓库根路径，⛔ 不能用调用方传入的相对路径。
