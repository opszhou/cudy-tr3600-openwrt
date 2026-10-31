# 编译指南

覆盖云编译（GitHub Actions）与本地编译两条路径：工作流参数、PR 组合备忘、产物获取与刷机步骤。

## 云编译

仓库提供两个手动触发的工作流（`workflow_dispatch`）：

| 工作流 | 文件 | 用途 |
|--------|------|------|
| 🔀 合并官方 PR | `.github/workflows/sync-pr.yml` | 拉取上游 PR → 生成补丁入库 →（可选）自动触发编译 |
| 🚀 编译固件 | `.github/workflows/build.yml` | 组装源码树 → 编译 → 上传 Artifact / 发 Release |

### 1️⃣ 合并官方 PR（sync-pr.yml）

**Actions → 🔀 合并官方 PR → Run workflow**

| 参数 | 说明 |
|------|------|
| `device` | 设备 ID（`devices/` 目录名） |
| `pr_numbers` | 官方 PR 号，空格分隔；**留空则使用 `device.yml` 的 `default_prs`** |
| `auto_build` | 有新补丁时自动触发编译（默认开启） |

执行结果：

- ✅ 成功的 PR 变成 `devices/<设备>/patches/openwrt-<分支>/pr<号>.patch` 入库并自动编译
- ❌ 失败的 PR 上传 `failed-pr-diffs-<设备>` artifact，通常是冲突或上游已合并，人工处理即可

**首次使用**：PR 号留空即可，默认合并设备支持 PR（见下表）。

**日常添加一个官方 PR**：填 PR 号（如 `26012`）→ Run。

### 2️⃣ 编译固件（build.yml）

**Actions → 🚀 编译固件 → Run workflow**

| 参数 | 说明 |
|------|------|
| `device` | 设备 ID |
| `profile` | 包组合：`lite`（默认）/ `ultimate` |
| `upstream_owner` / `upstream_repo` | 上游仓库（默认 `openwrt/openwrt`） |
| `upstream_branch` | 上游分支，留空则用 `device.yml` 的 `branch` |
| `extra_prs` | 临时追加合并的 PR 号（空格分隔，仅本次构建、不入库） |
| `build_all` | 忽略 `device`，编译 `devices/` 下全部设备 |
| `create_release` | 编译成功后创建 Release |

产物在 Run 页面的 **Artifacts**（`openwrt-<设备>-<组合>`，保留 14 天）。

## PR 组合备忘（TR3600）

| PR | 内容 | 适用分支 | 状态 |
|----|------|----------|------|
| #25860 | TR3600 v1 设备支持 | `main` | ✅ 默认启用，对最新 main 干净应用 |
| #25996 | RTL8221B EEE 修复（1G 丢包 41%~100%） | `main` | ✅ 默认启用，TR3600 同款 2.5G PHY |
| #24581 | TR3600 v1 设备支持（另一实现） | `main` | ⛔ 与 #25860 **互斥**；对最新 main 的 02_network 冲突，待作者 rebase |
| #24596 | TR3600 v1 设备支持 | `openwrt-25.12` | 换 25.12 稳定分支时改用它 |

**切换 25.12 稳定分支**：`device.yml` 改 `branch: openwrt-25.12`，`default_prs` 换成 `24596`。

## 刷机（TR3600 v1）

1. 先刷 **Cudy 官方中间固件** —— 官方下载中心下载 `Develop_files_for_TR3600.zip` 并刷入
2. 在 LuCI「系统 → 进阶设置/升级」页刷
   `openwrt-mediatek-filogic-cudy_tr3600-v1-squashfs-sysupgrade.bin`
3. 首次开机自动应用预设（UPnP 安全模式、BBR、周自动重启等，见 [PACKAGES.md](PACKAGES.md)），LuCI 均可改

> ⚠️ 未提供真机验证记录前，建议先在 Artifact 阶段核对固件文件完整性再刷机。

## 本地编译（可选）

与 CI 用同一套脚本：

```bash
git clone https://github.com/openwrt/openwrt.git openwrt   # 需完整历史（fetch-depth: 0）
bash scripts/build-device.sh . cudy_tr3600-v1 lite openwrt
```

## 耗时参考

| 场景 | 耗时 |
|------|------|
| 首次编译（ccache 冷） | 约 90 分钟 |
| 二次编译（ccache 热） | 约 60 分钟 |
