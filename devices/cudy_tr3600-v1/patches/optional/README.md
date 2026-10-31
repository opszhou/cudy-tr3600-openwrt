# optional/ 可选补丁

此目录补丁**默认不参与编译**（`.disabled` 后缀，`apply-device-patches.sh` 只匹配 `*.patch`）。

## 内容

| 文件 | 说明 |
|------|------|
| `0001-hardware-corrections.patch.disabled` | TR3600 v1 硬件参数修正（mode 按钮极性、PHY 中断、fan 转速中断、2.4G MAC 偏移回 0） |
| `0002-dualslot-package.patch.disabled` | 把 `tr3600-dualslot-upgrade` 包加入镜像 DEVICE_PACKAGES |

## 适用范围

仅适配组合：**上游分支 `openwrt-25.12` + PR #24596**（基于其 DTS 结构 `mt7987b-cudy-tr3600-v1.dts`）。
对 `main` + #24581/#25860 组合**不适用**，需人工 rebase。

## 启用方法

1. `device.yml` 改为 `branch: openwrt-25.12`，default_prs 启用 `24596`
2. 把补丁改名为 `.patch` 并移入 `patches/openwrt-25.12/`（`0001` → `9001-` 前缀，保证在 PR 补丁之后应用；`0002` 可保持 `0002-` 前缀因为它改的是 image.mk 与 PR 无冲突）

   ```bash
   cp patches/optional/0001-hardware-corrections.patch.disabled \
      patches/openwrt-25.12/9001-hardware-corrections.patch
   cp patches/optional/0002-dualslot-package.patch.disabled \
      patches/openwrt-25.12/0002-dualslot-package.patch
   ```

3. `0002` 依赖 `devices/cudy_tr3600-v1/package/tr3600-dualslot-upgrade/`（本仓库已自带）

> 来源：openwrt-cudy-tr3600 实验项目（EXPERIMENTAL，未经真机验证），启用前请自行确认补丁内容。
