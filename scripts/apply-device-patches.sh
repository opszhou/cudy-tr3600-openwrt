#!/usr/bin/env bash
# 按文件名排序应用设备补丁目录下的所有 *.patch。
# 排序约定（依赖字母序）：
#   0xxx-*.patch      本地基础补丁（不依赖任何 PR）
#   pr<PR号>.patch    官方 PR 补丁（由「合并官方 PR」工作流生成）
#   9xxx-*.patch      PR 之后的本地修正
# 用法: apply-device-patches.sh <repo-root> <device-id> <openwrt目录> [branch]
set -euo pipefail

ROOT="${1:?缺少 repo root}"
DEV="${2:?缺少设备ID}"
OPENWRT="${3:?缺少 openwrt 目录}"
BRANCH="${4:-}"

if [ -z "$BRANCH" ]; then
    # shellcheck disable=SC2046
    eval "$(bash "$ROOT/scripts/parse-device.sh" "$ROOT" "$DEV")"
    BRANCH="${DEV_BRANCH:-main}"
fi

PDIR="$ROOT/devices/$DEV/patches/openwrt-$BRANCH"
COUNT=0

if [ -d "$PDIR" ]; then
    while IFS= read -r p; do
        echo "应用补丁: $(basename "$p")"
        if ! git -C "$OPENWRT" apply --3way "$p"; then
            echo "错误: 补丁应用失败: $p" >&2
            echo "可能原因: 上游分支已变动/已合并该 PR。" >&2
            echo "处理: 删除对应补丁文件，或重跑「合并官方 PR」工作流重新生成。" >&2
            exit 1
        fi
        COUNT=$((COUNT + 1))
    done < <(find "$PDIR" -maxdepth 1 -name '*.patch' -type f | sort)
fi

echo "共应用 $COUNT 个补丁（来源: $PDIR）"
