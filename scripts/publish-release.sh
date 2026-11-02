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
RUN=${RUN:-0}   # 仅用于极端情况下的标签去重，不再进标签
RUN_ATTEMPT=${RUN_ATTEMPT:-1}
FW_DIR=${FW_DIR:-fw}
TAG_DATE=${TAG_DATE:-$(date -u +%Y%m%d)}

cd "$(dirname "$0")/.."

[ -d "$FW_DIR" ] || { echo "找不到 artifact 目录 $FW_DIR"; exit 1; }

# 资产命名：组合名紧跟设备名（openwrt-…-cudy_tr3600-v1-lite-squashfs-sysupgrade.bin）；
# 文件名里没有设备名时（如 config.buildinfo），把组合名插在扩展名之前。
asset_name() { # $1=原文件名 $2=设备 $3=组合
  local b="$1" dev="$2" prof="$3" stem ext
  if [[ "$b" == *"-$dev"* ]]; then
    printf '%s' "${b/"-$dev"/"-${dev}-${prof}"}"
    return
  fi
  if [[ "$b" == *.* ]]; then
    stem="${b%.*}"; ext=".${b##*.}"
  else
    stem="$b"; ext=""
  fi
  printf '%s' "${stem}-${prof}${ext}"
}

# 版本标识取 OpenWrt 自己的 version.buildinfo（形如 r37983-382a2109c8），
# 它比 CI 的 run 号更有意义：一眼看出这份固件基于哪个上游 revision。
# 注意：文件在 fw/<artifact>/fw/<target>/<subtarget>/ 下多层深，必须 find，
# 用 "$FW_DIR"/*/version.buildinfo 只扫一层会永远落空（run#28 标签 openwrt-unknown 的教训）
VER=""
while IFS= read -r f; do
  VER=$(head -n1 "$f" | tr -d '[:space:]')
  [ -n "$VER" ] && break
done < <(find "$FW_DIR" -name version.buildinfo | sort)
VER=${VER:-unknown}

TAG="openwrt-${VER}"
if gh release view "$TAG" >/dev/null 2>&1; then
  TAG="openwrt-${VER}-${TAG_DATE}"          # 同一 revision 二次构建：补日期
fi
if gh release view "$TAG" >/dev/null 2>&1; then
  TAG="openwrt-${VER}-${TAG_DATE}-a${RUN_ATTEMPT}"   # 再撞：补尝试号
fi

rm -rf assets && mkdir -p assets
NOTES=$(mktemp)
{
  echo "本页是**同一次构建的全部固件**（OpenWrt \`${VER}\`，${TAG_DATE}）：lite 与 ultimate 都在这里，资产名里的组合名紧跟设备名（如 openwrt-…-cudy_tr3600-v1-lite-squashfs-sysupgrade.bin）。"
  echo
  echo "| 组合 | 设备 | 主固件 | 包数量 |"
  echo "| --- | --- | --- | --- |"
} > "$NOTES"

found=0
for d in "$FW_DIR"/*/; do
  [ -d "$d" ] || continue
  A=$(basename "$d")                           # openwrt-<device>-<profile>-snapshot
  # artifact 目录名由本仓库 workflow 生成（openwrt-<设备>-<组合>-snapshot）；
  # 目录内文件前缀取决于上游（openwrt-* 或 immortalwrt-*），所以下面一律用无前缀 glob
  case "$A" in *-snapshot) ;; *) continue ;; esac
  X=${A#openwrt-}; X=${X%-snapshot}
  PROF=${X##*-}; DEV=${X%-*}
  while IFS= read -r f; do
    cp -f "$f" "assets/$(asset_name "$(basename "$f")" "$DEV" "$PROF")"
  done < <(find "$d" -type f ! -path "*/packages/*" \
             \( -name '*.bin' -o -name '*.itb' -o -name '*.img' \
                -o -name '*.manifest' -o -name '*.buildinfo' \) | sort)
  SYS=$(find "$d" -name '*-sysupgrade.bin' -printf '%f\n' 2>/dev/null | head -n1)
  MF=$(find "$d" -name '*.manifest' | head -n1)
  PKG=$( { [ -n "$MF" ] && grep -c . "$MF"; } || echo "?" )
  SYS_N=$( [ -n "$SYS" ] && asset_name "$SYS" "$DEV" "$PROF" )
  echo "| ${PROF} | ${DEV} | \`${SYS_N:-无}\` | ${PKG} |" >> "$NOTES"
  found=$((found + 1))
done

if [ "$found" -eq 0 ]; then
  echo "未在 $FW_DIR 中找到任何 *-snapshot artifact"
  exit 1
fi

( cd assets && sha256sum * > sha256sums )

cat >> "$NOTES" <<'MD'

### 两个组合怎么选
- **lite**：路由本职 + 常用网络工具 + 中文界面 + QModem 蜂窝支持
- **ultimate**：lite 全部再加——网页终端 ttyd、filebrowser 网页文件管理、collectd 实时监控图表、travelmate 中继、tailscale 异地组网、macvlan 多拨与 tun/tproxy 内核模块

### 刷机步骤（务必按顺序）
1. 原厂固件 → 先刷 Cudy 官方**中间固件**（见 Cudy 下载页说明），**不要**直接刷 OpenWrt
2. 进入 OpenWrt 后，用「系统 → 备份/升级」刷入 `openwrt-…-<组合>-sysupgrade.bin`
3. 救砖：`openwrt-…-<组合>-initramfs-kernel.bin` 可引导进内存系统抢救

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

# 标题全 ASCII（用户要求不出现中文）：snapshot <run号> (<日期>)
TAG_ISO=$(printf '%s' "$TAG_DATE" | sed 's/^\(....\)\(..\)\(..\)$/\1-\2-\3/')
gh release create "$TAG" assets/* \
  --title "OpenWrt ${VER} (${TAG_ISO})" \
  --notes-file "$NOTES" --latest
echo "已发布: https://github.com/${GH_REPO}/releases/tag/${TAG}"
