# cudy-tr3600-openwrt

基于 GitHub Actions 的 OpenWrt 云编译仓库，当前支持 **Cudy TR3600 v1**（MT7987B + MT7990）。
特点：

- **官方 PR 一键合并**：填 PR 号跑一次「合并官方 PR」工作流，补丁自动落盘入库、自动触发编译
- **多设备架构**：路由器特有配置抽到 `devices/<设备>/`，feeds/包组合/脚本全部共用
- **内置 QModem 随身WiFi 支持**：USB RNDIS/QMI/NCM/MBIM 全驱动 + LuCI 管理界面
- 三档包组合：`minimal` / `standard`（含随身WiFi）/ `full`（再含 Nikki 代理）

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
│   ├── feeds.append       # 追加 feeds（qmodem / nikki）
│   ├── packages/          # 包组合清单（modem.list / proxy.list）
│   ├── customize.sh       # 公共定制脚本
│   └── files/             # 公共 /etc 覆盖
└── scripts/               # 组装/合并/编译脚本（CI 与本地通用）
```

## 快速开始

> 首次编译必须先合并设备支持 PR，否则只会编译出 mediatek/filogic 通用镜像。

1. 把本仓库推送到 GitHub
2. **Actions → 🔀 合并官方 PR → Run workflow**：设备 `cudy_tr3600-v1`、PR 号留空
   （默认合并 `device.yml` 里的 24581 设备支持 + 25996 EEE 修复），补丁入库后自动触发编译
3. **Actions → 🚀 编译固件**：或手动跑，选好设备与包组合
4. 结果在 Run 页面的 **Artifacts**（`openwrt-<设备>-<组合>`），勾选 `create_release` 可发 Release

### 日常添加一个官方 PR

Actions → 🔀 合并官方 PR → 填 PR 号（如 `26012`）→ Run。
成功的 PR 变成 `devices/<设备>/patches/openwrt-<分支>/pr<号>.patch` 入库并自动编译；
失败的 PR 会上传 `failed-pr*.diff` artifact，通常是冲突或上游已合并，人工处理即可。

### PR 组合备忘（TR3600）

| PR | 内容 | 适用分支 | 说明 |
|----|------|----------|------|
| #24581 | TR3600 v1 设备支持 | main | 默认启用 |
| #25860 | TR3600 v1 设备支持（另一实现） | main | 与 #24581 **互斥**，二选一 |
| #24596 | TR3600 v1 设备支持 | openwrt-25.12 | 稳定分支组合时启用它 |
| #25996 | RTL8221B EEE 修复（1G 丢包） | main | TR3600 同款 2.5G PHY，建议启用 |

换用 25.12 稳定分支：`device.yml` 改 `branch: openwrt-25.12`，default_prs 换成 `24596`。

### 包组合

| 组合 | 内容 |
|------|------|
| minimal | 种子配置（中文化 LuCI + HTTPS 管理页） |
| standard | + QModem 全套 USB 上网卡驱动（随身WiFi即插即用） |
| full | + Nikki 透明代理（mihomo）、tailscale、travelmate、SQM |
| ultimate | full 全部 + 全能型全家桶：Argon 主题/ttyd/turboacc加速/ddns-go/acme证书/socat/UPnP/wolplus/SFTP/filebrowser/WebDAV/SQM/vnstat/netdata(轻量化)/autoreboot（含预设与中文界面） |

包清单改 `common/packages/*.list`，种子改 `devices/<设备>/default.seed`。

## 本地编译（可选）

```bash
git clone https://github.com/openwrt/openwrt.git openwrt   # 需完整历史
bash scripts/build-device.sh . cudy_tr3600-v1 standard openwrt
```

## 添加新路由器

见 [docs/ADD-DEVICE.md](docs/ADD-DEVICE.md) —— 复制设备目录、改 3 个文件即可，
workflows 无需改动（`build_all` 会自动发现新设备）。

## 说明

- `patches/optional/` 存放旧实验项目的 TR3600 修正补丁（仅适配 25.12 + PR#24596 组合，默认禁用）
- 上游已正式合并的 PR，删除对应 `pr*.patch` 即可切回官方源码
- 补丁应用顺序按文件名排序：`0xxx` 本地基础 → `pr<号>` 官方 PR → `9xxx` PR 后本地修正
- 本仓库自身内容遵循 GPL-2.0（与 OpenWrt 一致）；QModem 为 MPL-2.0，Nikki 为 GPL-3.0
