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

# 目录名规则 patches/<上游仓库名>-<分支>/，以下两种情况只用分支名：
#   1) release 分支名字里已带上游（openwrt-25.12），再前缀会变成 openwrt-openwrt-25.12（首验踩到）
#   2) 上游换了但分支同名：P3 从 openwrt/openwrt 换到 immortalwrt/immortalwrt 的同一个
#      openwrt-25.12 分支。release 分支名本身唯一确定基线，补丁能否应用与"哪个仓库提供的
#      同名分支"无关，目录不该跟着上游名变，否则一切换上游整份补丁栈就找不到。
# 滚动分支（main / master）不含版本信息，必须带上游名区分：openwrt-main / immortalwrt-master。
case "$BRANCH" in
    openwrt-*|immortalwrt-*) PDIR="$ROOT/devices/$DEV/patches/$BRANCH" ;;
    "${UPSTREAM}-"*)         PDIR="$ROOT/devices/$DEV/patches/$BRANCH" ;;
    *)                       PDIR="$ROOT/devices/$DEV/patches/${UPSTREAM}-$BRANCH" ;;
esac

# 补丁目录缺失 = 上游/分支组合写错（如 upstream=immortalwrt 但 branch 仍取 device.yml 的 main），
# 静默 0 补丁会让后续 defconfig 把整个 target 丢掉（run#29 教训），必须硬失败
if [ ! -d "$PDIR" ]; then
    echo "错误: 补丁目录不存在: ${PDIR#$ROOT/}" >&2
    echo "       上游=$UPSTREAM 分支=$BRANCH（补丁目录规则: patches/<上游仓库名>-<分支>/）" >&2
    echo "       现有可用目录:" >&2
    ls -d "$ROOT/devices/$DEV/patches/"*/ 2>/dev/null | sed "s|$ROOT/|         |" >&2
    exit 1
fi
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
