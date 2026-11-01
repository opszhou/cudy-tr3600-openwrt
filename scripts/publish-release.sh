#!/usr/bin/env bash
# 把 fw/ 下已下载的固件 artifact 汇总成单个 Release（lite + ultimate 同页，只发裸文件）。
# 由 build.yml（构建后自动发布）与 release.yml（手动补发指定 run）共用，避免两处逻辑漂移。
#
# 必需环境变量：
#   GH_TOKEN / GH_REPO / RUN（run number）
# 可选：
#   RUN_ATTEMPT 同一 run 重跑时的序号（默认 1，用于避免标签冲突）
#   FW_DIR      artifact 根目录（默认 fw，其下每个 artifact 一个子目录）
#   TAG_DATE    标签中的日期（默认 UTC 今天）
set -euo pipefail

: "${GH_TOKEN:?需要 GH_TOKEN}"
: "${GH_REPO:?需要 GH_REPO (owner/repo)}"
: "${RUN:?需要 RUN (run number)}"
RUN_ATTEMPT=${RUN_ATTEMPT:-1}
FW_DIR=${FW_DIR:-fw}
TAG_DATE=${TAG_DATE:-$(date -u +%Y%m%d)}

cd "$(dirname "$0")/.."

[ -d "$FW_DIR" ] || { echo "找不到 artifact 目录 $FW_DIR"; exit 1; }

TAG="snapshot-${TAG_DATE}-r${RUN}"
if gh release view "$TAG" >/dev/null 2>&1; then
  TAG="${TAG}-a${RUN_ATTEMPT}"   # 重跑同一 run 时不撞已有标签
fi

rm -rf assets && mkdir -p assets
NOTES=$(mktemp)
{
  echo "本页是**同一次构建（run #${RUN}）的全部固件**：lite 与 ultimate 都在这里，资产以组合名作前缀。"
  echo
  echo "| 组合 | 设备 | 主固件 | 包数量 |"
  echo "| --- | --- | --- | --- |"
} > "$NOTES"

found=0
for d in "$FW_DIR"/*/; do
  [ -d "$d" ] || continue
  A=$(basename "$d")                           # openwrt-<device>-<profile>-snapshot
  case "$A" in openwrt-*-snapshot) ;; *) continue ;; esac
  X=${A#openwrt-}; X=${X%-snapshot}
  PROF=${X##*-}; DEV=${X%-*}
  while IFS= read -r f; do
    cp -f "$f" "assets/${PROF}-$(basename "$f")"
  done < <(find "$d" -type f ! -path "*/packages/*" \
             \( -name 'openwrt-*.bin' -o -name 'openwrt-*.itb' -o -name 'openwrt-*.img' \
                -o -name 'openwrt-*.manifest' -o -name '*.buildinfo' \) | sort)
  SYS=$(find "$d" -name 'openwrt-*-sysupgrade.bin' -printf '%f\n' 2>/dev/null | head -n1)
  MF=$(find "$d" -name 'openwrt-*.manifest' | head -n1)
  PKG=$( { [ -n "$MF" ] && grep -c . "$MF"; } || echo "?" )
  echo "| ${PROF} | ${DEV} | \`${PROF}-${SYS:-无}\` | ${PKG} |" >> "$NOTES"
  found=$((found + 1))
done

if [ "$found" -eq 0 ]; then
  echo "未在 $FW_DIR 中找到任何 openwrt-*-snapshot artifact"
  exit 1
fi

( cd assets && sha256sum * > sha256sums )

cat >> "$NOTES" <<'MD'

### 两个组合怎么选
- **lite**：精简实用——路由本职 + 常用网络工具 + 中文界面 + QModem 蜂窝支持
- **ultimate**：全能——额外含 docker、各类插件与诊断工具，体积更大、开机更慢

### 刷机步骤（务必按顺序）
1. 原厂固件 → 先刷 Cudy 官方**中间固件**（见 Cudy 下载页说明），**不要**直接刷 OpenWrt
2. 进入 OpenWrt 后，用「系统 → 备份/升级」刷入 `<组合>-openwrt-…-sysupgrade.bin`
3. 救砖：`<组合>-openwrt-…-initramfs-kernel.bin` 可引导进内存系统抢救

### 校验
```
sha256sum -c sha256sums
```

### 包含内容
- `*-sysupgrade.bin`：主固件（OpenWrt 内升级/刷机）
- `*-initramfs-kernel.bin`：救砖 / 内存调试
- `*.manifest`：包清单（纯文本，精确到每个包的版本）
- `*.buildinfo`：构建配置与 feed 版本（可复现）
- 不提供压缩包，也不提供 `packages/*.apk`

### ⚠️ 声明
本项目为**个人自用构建**，未经系统性真机验证，仅适配 Cudy TR3600 v1。刷机有变砖风险，后果自担。
MD

echo "== 待发布资产 =="
ls -lh assets

gh release create "$TAG" assets/* \
  --title "快照 ${RUN} · ${TAG_DATE}" \
  --notes-file "$NOTES" --latest
echo "已发布: https://github.com/${GH_REPO}/releases/tag/${TAG}"
