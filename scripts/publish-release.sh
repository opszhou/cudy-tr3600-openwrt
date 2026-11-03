#!/usr/bin/env bash
# 把 fw/ 下已下载的固件 artifact 汇总成单个 Release（多组合同页，只发裸文件）。
# 由 build.yml（构建后自动发布）与 release.yml（手动补发指定 run）共用，避免两处逻辑漂移。
#
# 必需环境变量：
#   GH_TOKEN / GH_REPO / RUN（run number）
# 可选：
#   FW_DIR    artifact 根目录（默认 fw，其下每个 artifact 一个子目录）
#   TAG_DATE  标签中的日期（默认 UTC 今天）
#
# 同页语义：标签 = <上游>-<上游版本号>。同一上游同一 revision 的构建**永远落在同一页**——
# 标签已存在时不新建，而是把本批资产并入（sha256sums 按文件名合并），说明文字按页面
# 实际资产重新生成。这样 lite / ultimate 无论是否在同一次 run 里构建，都汇到同一页。
set -euo pipefail

: "${GH_TOKEN:?需要 GH_TOKEN}"
: "${GH_REPO:?需要 GH_REPO (owner/repo)}"
FW_DIR=${FW_DIR:-fw}
TAG_DATE=${TAG_DATE:-$(date -u +%Y%m%d)}
UPSTREAM_LABEL=${UPSTREAM_LABEL:-openwrt}

cd "$(dirname "$0")/.."

[ -d "$FW_DIR" ] || { echo "找不到 artifact 目录 $FW_DIR"; exit 1; }

# 资产命名：组合名紧跟设备名（…-cudy_tr3600-v1-ultimate-squashfs-sysupgrade.bin）；
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

# 版本标识取上游自己的 version.buildinfo（形如 r42943-89f1ef18c8），
# 它比 CI 的 run 号更有意义：一眼看出这份固件基于哪个上游 revision。
# 文件在 artifact 内多层深，必须 find（只扫一层会落空，run#28 标签 unknown 的教训）。
VER=""
while IFS= read -r f; do
  VER=$(head -n1 "$f" | tr -d '[:space:]')
  [ -n "$VER" ] && break
done < <(find "$FW_DIR" -name version.buildinfo | sort)
VER=${VER:-unknown}

TAG="${UPSTREAM_LABEL}-${VER}"
APPEND=0
if gh release view "$TAG" >/dev/null 2>&1; then
  APPEND=1
  echo "Release $TAG 已存在 → 追加资产模式（同页合并）"
fi

rm -rf assets && mkdir -p assets
ROWS=$(mktemp)
PROFS=""
found=0

echo "== fw 布局（扫描前） =="
find "$FW_DIR" -mindepth 1 -maxdepth 2 -type d | head -10 || true

for d in "$FW_DIR"/*/; do
  [ -d "$d" ] || continue
  A=$(basename "$d")
  # artifact 目录名由本仓库 workflow 生成（<上游>-<设备>-<组合>-snapshot）；
  # 目录内文件前缀取决于上游，所以一律用无前缀 glob
  case "$A" in *-snapshot) ;; *) continue ;; esac
  X=${A%-snapshot}; X=${X#${UPSTREAM_LABEL}-}
  PROF=${X##*-}; DEV=${X%-*}
  case " $PROFS " in *" $PROF "*) ;; *) PROFS="$PROFS $PROF" ;; esac
  while IFS= read -r f; do
    cp -f "$f" "assets/$(asset_name "$(basename "$f")" "$DEV" "$PROF")"
  done < <(find "$d" -type f ! -path "*/packages/*" \
             \( -name '*.bin' -o -name '*.itb' -o -name '*.img' \
                -o -name '*.manifest' -o -name '*.buildinfo' \) | sort)
  SYS=$(find "$d" -name '*-sysupgrade.bin' -printf '%f\n' 2>/dev/null | head -n1)
  MF=$(find "$d" -name '*.manifest' | head -n1)
  PKG=$( { [ -n "$MF" ] && grep -c . "$MF"; } || echo "?" )
  SYS_N=$( [ -n "$SYS" ] && asset_name "$SYS" "$DEV" "$PROF" )
  echo "| ${PROF} | ${DEV} | \`${SYS_N:-无}\` | ${PKG} |" >> "$ROWS"
  found=$((found + 1))
done

if [ "$found" -eq 0 ]; then
  echo "未在 $FW_DIR 中找到任何 *-snapshot artifact"
  exit 1
fi

( cd assets && sha256sum * > sha256sums )

echo "== 待发布资产 =="
ls -lh assets

# ---------- 上传（新建或追加） ----------
if [ "$APPEND" = 1 ]; then
  # 追加模式：合并新旧 sha256sums（按文件名去重；资产名含组合名，不会互相覆盖）
  OLD=$(mktemp -d)
  if gh release download "$TAG" -p 'sha256sums' -D "$OLD" --clobber >/dev/null 2>&1 \
     && [ -s "$OLD/sha256sums" ]; then
    { cat "$OLD/sha256sums"; cat assets/sha256sums; } \
      | sort -k2 | awk '!seen[$2]++' > assets/sha256sums.merged
    mv assets/sha256sums.merged assets/sha256sums
    echo "sha256sums 已与页面既有资产合并"
  fi
  gh release upload "$TAG" assets/* --clobber
  echo "已追加到: https://github.com/${GH_REPO}/releases/tag/${TAG}"
else
  gh release create "$TAG" assets/* \
    --title "${UPSTREAM_LABEL} ${VER} (${TAG_DATE:0:4}-${TAG_DATE:4:2}-${TAG_DATE:6:2})" \
    --notes-file /dev/null --latest >/dev/null
  echo "已创建: https://github.com/${GH_REPO}/releases/tag/${TAG}"
fi

# ---------- 说明文字：按页面实际资产生成（追加后以 Release 资产为准） ----------
if [ "$APPEND" = 1 ]; then
  mapfile -t ALL < <(gh api "repos/$GH_REPO/releases/tags/$TAG" --jq '.assets[].name')
  PROFS=$(printf '%s\n' "${ALL[@]}" \
    | sed -nE 's/.*-([^-]+)\.manifest$/\1/p' | sort -u | tr '\n' ' ')
  ROWS=$(mktemp)
  TMPD=$(mktemp -d)
  for prof in $PROFS; do
    SYS=$(printf '%s\n' "${ALL[@]}" | grep -- "-${prof}-" | grep -- "sysupgrade\.bin" | head -n1 || true)
    MAN=$(printf '%s\n' "${ALL[@]}" | grep -- "-${prof}.manifest" | head -n1 || true)
    DEV="?"
    for dd in devices/*/; do
      dv=$(basename "$dd")
      case "${SYS:-}" in *"-${dv}-"*|*"-${dv}.") DEV=$dv ;; esac
    done
    PKG="?"
    if [ -n "$MAN" ]; then
      gh release download "$TAG" -p "$MAN" -D "$TMPD" --clobber >/dev/null 2>&1 || true
      [ -s "$TMPD/$MAN" ] && PKG=$(grep -c . "$TMPD/$MAN") || true
    fi
    echo "| ${prof} | ${DEV} | \`${SYS:-无}\` | ${PKG} |" >> "$ROWS"
  done
fi
PROFS_SHOW=$(echo $PROFS | sed 's/ /、/g; s/^、//')

NOTES=$(mktemp)
{
  echo "本页包含组合：**${PROFS_SHOW:-未知}**（${UPSTREAM_LABEL} \`${VER}\`，${TAG_DATE:0:4}-${TAG_DATE:4:2}-${TAG_DATE:6:2}）。"
  echo "资产名里的组合名紧跟设备名（如 ${UPSTREAM_LABEL}-…-cudy_tr3600-v1-<组合>-squashfs-sysupgrade.bin）。"
  echo
  echo "| 组合 | 设备 | 主固件 | 包数量 |"
  echo "| --- | --- | --- | --- |"
  cat "$ROWS"
} > "$NOTES"

cat >> "$NOTES" <<'MD'

### 两个组合怎么选
- **lite**：路由本职 + 常用网络工具 + 中文界面 + QModem 蜂窝支持
- **ultimate**：lite 全部再加——网页终端 ttyd、collectd 实时监控图表、travelmate 中继、tailscale 异地组网、macvlan 多拨与 tun/tproxy 内核模块、Transmission（BT 下载，web-control 中文面板）

### 刷机步骤（务必按顺序）
1. 原厂固件 → 先刷 Cudy 官方**中间固件**（见 Cudy 下载页说明），**不要**直接刷第三方固件
2. 进入系统后，用「系统 → 备份/升级」刷入 `<上游>-…-<组合>-sysupgrade.bin`
3. 救砖：`<上游>-…-<组合>-initramfs-kernel.bin` 可引导进内存系统抢救

### 校验
```
sha256sum -c sha256sums
```

### 包含内容
- `*-sysupgrade.bin`：主固件（系统内升级/刷机）
- `*-initramfs-kernel.bin`：救砖 / 内存调试
- `*.manifest`：包清单（纯文本，精确到每个包的版本）
- `*.buildinfo`：构建配置与 feed 版本（可复现）
- 不提供压缩包，也不提供 `packages/*.apk`

### ⚠️ 声明
本项目为**个人自用构建**，未经系统性真机验证，仅适配 Cudy TR3600 v1。刷机有变砖风险，后果自担。
MD

gh release edit "$TAG" --notes-file "$NOTES" --latest
echo "说明已更新: https://github.com/${GH_REPO}/releases/tag/${TAG}"
rm -f "$ROWS"
echo "== 完成 =="
