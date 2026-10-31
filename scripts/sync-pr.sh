#!/usr/bin/env bash
# 把「官方 PR 补丁」落盘入库：应用 PR → 生成补丁文件到 devices/<dev>/patches/。
# 失败的 PR 其 diff 保留为 failed-pr<号>.diff（已被 .gitignore 排除，仅作 artifact）。
# 用法: sync-pr.sh <repo-root> <device-id> <openwrt目录> [PR号...]
#   不传 PR 号时，使用 device.yml 的 default_prs。
# 退出码: 0=全部成功；1=存在失败（成功者已正常落盘）
set -uo pipefail

ROOT="${1:?缺少 repo root}"
DEV="${2:?缺少设备ID}"
OPENWRT="${3:?缺少 openwrt 目录}"
shift 3
PRS="$*"

# shellcheck disable=SC2046
eval "$(bash "$ROOT/scripts/parse-device.sh" "$ROOT" "$DEV")"
BRANCH="${DEV_BRANCH:-main}"

if [ -z "$PRS" ]; then
    PRS="$DEV_PRS"
    [ -n "$PRS" ] || { echo "未指定 PR 号，且 device.yml 未配置 default_prs"; exit 1; }
fi

# 先应用已有补丁，保证新 PR 基于当前补丁栈（与构建时顺序一致）
bash "$ROOT/scripts/apply-device-patches.sh" "$ROOT" "$DEV" "$OPENWRT" "$BRANCH"

PDIR="$ROOT/devices/$DEV/patches/openwrt-$BRANCH"
mkdir -p "$PDIR"

OWNER="${UPSTREAM_OWNER:-openwrt}"
REPO="${UPSTREAM_REPO:-openwrt}"

OK=(); FAIL=()
for pr in $PRS; do
    # 补丁名带 PR 号前缀保证应用顺序（PR 号 5 位补零；100000+ 时需人工调整命名）
    OUT="$PDIR/pr$(printf '%05d' "$pr").patch"
    if bash "$ROOT/scripts/apply-pr.sh" "$OPENWRT" "$pr" "$OUT" "$OWNER" "$REPO"; then
        OK+=("$pr")
    else
        FAIL+=("$pr")
        [ -f "$OUT" ] && mv -f "$OUT" "$PDIR/failed-pr$pr.diff"
    fi
done

echo "----------------------------------------"
echo "合并成功: ${OK[*]:-无}  -> $PDIR"
echo "合并失败: ${FAIL[*]:-无}"
[ "${#FAIL[@]}" -eq 0 ]
