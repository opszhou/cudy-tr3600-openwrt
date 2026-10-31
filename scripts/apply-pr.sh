#!/usr/bin/env bash
# 下载官方 OpenWrt PR 的 diff 并应用到 openwrt 源码树。
# 用法: apply-pr.sh <openwrt目录> <PR号> <diff保存路径> [owner] [repo]
set -euo pipefail

WORK="${1:?缺少 openwrt 目录}"
PR="${2:?缺少 PR 号}"
OUT="${3:?缺少 diff 保存路径}"
OWNER="${4:-openwrt}"
REPO="${5:-openwrt}"

URL="https://patch-diff.githubusercontent.com/raw/${OWNER}/${REPO}/pull/${PR}.diff"
# 转绝对路径：git -C 会在源码树内解析相对路径，导致找不到 diff
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
curl -fsSL "$URL" -o "$OUT" || { echo "pr$PR: diff 下载失败 ($URL)" >&2; exit 1; }

if [ ! -s "$OUT" ] || ! grep -q '^diff --git' "$OUT"; then
    echo "pr$PR: 未取到有效 diff（PR 不存在 / 已关闭无变更 / 返回了 HTML 页面）" >&2
    exit 1
fi

if git -C "$WORK" apply --check "$OUT" 2>/dev/null; then
    git -C "$WORK" apply "$OUT"
    echo "pr$PR: 干净应用"
elif git -C "$WORK" apply --3way "$OUT"; then
    echo "pr$PR: 三方合并应用（上下文有漂移，建议检查结果）"
else
    echo "pr$PR: 应用失败（可能冲突，或上游已合并该 PR）" >&2
    echo "       diff 已保留在 $OUT 供人工处理" >&2
    exit 1
fi
