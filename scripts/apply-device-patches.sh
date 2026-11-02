#!/usr/bin/env bash
# 按文件名排序应用设备补丁目录下的所有 *.patch。
# 统一命名规范（首位数字 = 档位，纯字典序即应用顺序，⚠️ 改命名必须同时核对本文档与 docs/ARCHITECTURE.md）：
#   0xxx-<描述>.patch        本地基础补丁（不依赖任何 PR）
#   1pr<PR号5位补零>.patch   官方 PR 补丁（由「合并官方 PR」工作流生成，如 1pr25860.patch）
#   9xxx-<描述>.patch        PR 之后的本地修正
# 用法: apply-device-patches.sh <repo-root> <device-id> <openwrt目录> [branch] [upstream]
#   upstream: 上游仓库名（openwrt | immortalwrt），决定补丁目录 patches/<upstream>-<branch>/
set -euo pipefail

ROOT="${1:?缺少 repo root}"
DEV="${2:?缺少设备ID}"
OPENWRT="${3:?缺少 openwrt 目录}"
BRANCH="${4:-}"
UPSTREAM="${5:-openwrt}"

if [ -z "$BRANCH" ]; then
    # shellcheck disable=SC2046
    eval "$(bash "$ROOT/scripts/parse-device.sh" "$ROOT" "$DEV")"
    BRANCH="${DEV_BRANCH:-main}"
fi

PDIR="$ROOT/devices/$DEV/patches/${UPSTREAM}-$BRANCH"
COUNT=0

if [ -d "$PDIR" ]; then
    # 命名守卫：不符合统一命名规范的补丁直接拒绝应用，
    # 防止乱序文件名（如 pr*.patch 字母序排在 9xxx 之后）造成隐性应用顺序错误（run#13 已踩坑）。
    while IFS= read -r p; do
        b=$(basename "$p")
        case "$b" in
            0[0-9][0-9][0-9]*.patch | 1pr[0-9][0-9][0-9][0-9][0-9]*.patch | 9[0-9][0-9][0-9]*.patch) ;;
            *)
                echo "错误: 补丁命名不符合统一规范（0xxx-* / 1pr<PR号5位>* / 9xxx-*）: $b" >&2
                exit 1
                ;;
        esac
        echo "应用补丁: $b"
        # 转绝对路径：git -C 会在源码树内解析相对路径，导致找不到补丁
        p="$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
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
