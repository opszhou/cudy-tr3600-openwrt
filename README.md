# cudy-tr3600-openwrt

基于 GitHub Actions 的 OpenWrt 云编译仓库，当前支持 **Cudy TR3600 v1**（MT7987B + MT7990）。

- **官方 PR 一键合并**：填 PR 号跑一次「合并官方 PR」工作流，补丁自动落盘入库、自动触发编译
- **多设备架构**：路由器特有配置抽到 `devices/<设备>/`，feeds/包组合/脚本全部共用
- **内置 QModem 随身WiFi 支持**：USB RNDIS/QMI/NCM/MBIM 全驱动 + LuCI 管理界面（qmodem-next）
- **两档包组合**：`lite`（精简实用，默认）/ `ultimate`（全能）

## 目录结构

```
├── .github/workflows/
│   ├── sync-pr.yml        # 🔀 合并官方 PR（最常用）
│   └── build.yml          # 🚀 编译固件
├── devices/               # ── 路由器特有（每台路由器一个目录）──
│   └── cudy_tr3600-v1/
│       ├── device.yml     # 元数据: target/profile/上游分支/默认PR列表
│       ├── default.seed   # .config 种子（目标机型 + 基础包）
│       ├── patches/       # 补丁（openwrt-<分支>/，由合并PR工作流自动填充）
│       ├── package/       # 设备专属源码包（tr3600-dualslot-upgrade）
│       └── files/         # 设备专属 /etc 覆盖
├── common/                # ── 全部设备共用 ──
│   ├── feeds.append       # 追加 feeds（qmodem / nikki / kenzok8 / small）
│   ├── packages/          # 包清单：modem(随身WiFi) / lite(精简) / proxy(出行) / extra(全能增量)
│   ├── customize.sh       # 公共定制脚本（feeds 安装后执行）
│   └── files/             # 公共 /etc 覆盖（netdata 轻量化配置、开机预设）
└── scripts/               # 组装/合并/编译脚本（CI 与本地通用）
```

## 快速开始

> 首次编译必须先合并设备支持 PR，否则只会编译出 mediatek/filogic 通用镜像。

1. **Actions → 🔀 合并官方 PR → Run workflow**：设备 `cudy_tr3600-v1`、PR 号留空
   （默认合并 `device.yml` 里的 25860 设备支持 + 25996 EEE 修复），补丁入库后自动触发编译
2. **Actions → 🚀 编译固件**：或手动跑，选设备与包组合（默认 `lite`）
3. 结果在 Run 页面的 **Artifacts**（`openwrt-<设备>-<组合>`），勾选 `create_release` 可发 Release
4. 刷机：先刷 Cudy 官方中间固件（官方下载中心 `Develop_files_for_TR3600.zip`），
   再在 LuCI 升级页刷 `openwrt-mediatek-filogic-cudy_tr3600-v1-squashfs-sysupgrade.bin`

### 日常添加一个官方 PR

Actions → 🔀 合并官方 PR → 填 PR 号（如 `26012`）→ Run。
成功的 PR 变成 `devices/<设备>/patches/openwrt-<分支>/pr<号>.patch` 入库并自动编译；
失败的 PR 会上传 `failed-pr*.diff` artifact，通常是冲突或上游已合并，人工处理即可。

### PR 组合备忘（TR3600）

| PR | 内容 | 适用分支 | 状态 |
|----|------|----------|------|
| #25860 | TR3600 v1 设备支持 | main | ✅ 默认启用，对最新 main 干净应用 |
| #25996 | RTL8221B EEE 修复（1G 丢包） | main | ✅ 默认启用，TR3600 同款 2.5G PHY |
| #24581 | TR3600 v1 设备支持（另一实现） | main | ⛔ 与 #25860 **互斥**；实测对最新 main 的 02_network 冲突，待作者 rebase |
| #24596 | TR3600 v1 设备支持 | openwrt-25.12 | 换 25.12 稳定分支时改用它 |

换 25.12 稳定分支：`device.yml` 改 `branch: openwrt-25.12`，default_prs 换成 `24596`。

## 包组合

| 组合 | 定位 | 内容 |
|------|------|------|
| **lite** | 精简实用（默认） | QModem 随身WiFi 全套 + 中文化 LuCI + Argon 主题(默认) + turboacc 硬件加速/BBR + nikki 代理 + ddns-go + acme 证书 + socat + UPnP + SFTP + WebDAV + SQM + vnstat + autoreboot |
| **ultimate** | 全能 | lite 全部 + tailscale + travelmate + ttyd + filebrowser + netspeedtest + netdata(轻量化) + mwan3 多WAN + macvlan + wolplus |

两档共用的**开机预设**（uci-defaults，首次开机自动生效，LuCI 可改）：

- UPnP 默认安全模式；BBR 拥塞控制默认启用
- 每周一凌晨 04:30 自动重启（luci-app-autoreboot）
- netdata 纯 RAM 模式 + 2 小时历史 + 关机器学习/Cloud（512MB 内存防溢出，见 `common/files/etc/netdata/`）

改包清单：`common/packages/*.list`；改基础种子：`devices/<设备>/default.seed`。
第三方插件源：nikki（mihomo）与 kenzok8/small（argon-config、turboacc、ddns-go 等），见 `common/feeds.append`。

## 本地编译（可选）

```bash
git clone https://github.com/openwrt/openwrt.git openwrt   # 需完整历史
bash scripts/build-device.sh . cudy_tr3600-v1 lite openwrt
```

## 添加新路由器

见 [docs/ADD-DEVICE.md](docs/ADD-DEVICE.md) —— 复制设备目录、改 3 个文件即可，
workflows 无需改动（`build_all` 会自动发现新设备）。

## 说明

- `patches/optional/` 存放旧实验项目的 TR3600 修正补丁（仅适配 25.12 + PR#24596 组合，默认禁用）
- 上游已正式合并的 PR，删除对应 `pr*.patch` 即可切回官方源码
- 补丁应用顺序按文件名排序：`0xxx` 本地基础 → `pr<号>` 官方 PR → `9xxx` PR 后本地修正
- 第三方组件许可：QModem 为 MPL-2.0，Nikki 为 GPL-3.0，kenzok8 插件以各自仓库为准；本仓库自身内容遵循 GPL-2.0（见 LICENSE / LICENSES/GPL-2.0）
