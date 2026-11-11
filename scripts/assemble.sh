#!/usr/bin/env bash
# 组装 openwrt 源码树：补丁 → PR → feeds → 设备包 → files → .config → 定制脚本。
# 用法: assemble.sh <repo-root> <device-id> <profile> <openwrt目录> [owner] [repo] [extra_prs] [branch]
#   branch: 上游分支（CI 传 upstream_branch；留空则取 device.yml 的 branch）
set -euo pipefail

ROOT="${1:?缺少 repo root}"
DEV="${2:?缺少设备ID}"
PROFILE="${3:-lite}"
OPENWRT="${4:?缺少 openwrt 目录}"
OWNER="${5:-openwrt}"
REPO="${6:-openwrt}"
EXTRA_PRS="${7:-}"
BRANCH_ARG="${8:-}"

# 规范化为绝对路径：脚本内会 cd 进 openwrt 树，相对路径会解析错位
ROOT="$(cd "$ROOT" && pwd)"

# shellcheck disable=SC2046
eval "$(bash "$ROOT/scripts/parse-device.sh" "$ROOT" "$DEV")"
# 显式传入的上游分支优先于 device.yml（否则切了 immortalwrt/master 却仍在找 patches/openwrt-main，run#29 教训）
BRANCH="${BRANCH_ARG:-${DEV_BRANCH:-main}}"

echo "==== 组装: 设备=$DEV target=$DEV_TARGET profile=$DEV_PROFILE 上游分支=$BRANCH ===="

# 1) 应用设备补丁（含已入库的官方 PR 补丁；目录按上游区分 patches/<upstream>-<branch>/）
bash "$ROOT/scripts/apply-device-patches.sh" "$ROOT" "$DEV" "$OPENWRT" "$BRANCH" "$REPO"

# 2) 临时追加合并官方 PR（不入库，仅本次构建生效）
for pr in $EXTRA_PRS; do
    bash "$ROOT/scripts/apply-pr.sh" "$OPENWRT" "$pr" "/tmp/pr$pr.diff" "$OWNER" "$REPO"
done

# 3) 追加 feeds（去重；只追加，不覆盖上游自带 feeds）
#    三层来源：upstreams/<上游>/feeds.append（必需）→ devices/<设备>/feeds.append（可选）
#    如 immortalwrt 自带 argon/ddns-go，它的 feeds.append 就不拉 kenzok8，避免重复定义
#    支持 ;@latest 标记：构建时解析该仓库「最新稳定 release tag」——
#    过滤 rc/beta/alpha 等预发布 tag 取版本最高者；无稳定 tag 取最高 tag；完全无 tag 回退默认分支
#    ^<sha> 固定 commit 行原样透传（OpenWrt scripts/feeds 原生支持，可复现、可回滚）；
#    ⛔ 同一行不得同时写 ;branch 与 ^commit（feeds 优先 branch，commit 会被忽略）
FEEDS_FILE="$ROOT/upstreams/$REPO/feeds.append"
if [ ! -f "$FEEDS_FILE" ]; then
    echo "错误: 找不到上游 feed 配置: ${FEEDS_FILE#$ROOT/}（每个上游目录必须有 feeds.append）" >&2
    exit 1
fi
echo "feed 追加来源: ${FEEDS_FILE#$ROOT/}"
resolve_latest_tag() {
    local tags stable
    tags=$(git ls-remote --tags "$1" 2>/dev/null | awk '{print $2}' | sed 's|refs/tags/||' | grep -v '\^{}' || true)
    [ -z "$tags" ] && return 0
    stable=$(echo "$tags" | grep -viE '(rc|beta|alpha|dev|test|snapshot)' | sort -rV | head -1)
    [ -n "$stable" ] && { echo "$stable"; return 0; }
    echo "$tags" | sort -rV | head -1
}

touch "$OPENWRT/feeds.conf.default"
while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    # ⛔ ;branch 与 ^commit 不能混用：scripts/feeds 先判 branch 再判 commit，
    # 有 ; 时走 init_branch，^<sha> 会被静默忽略，等于没有固定版本。
    if [[ "$line" == *";"* && "$line" == *"^"* ]]; then
        echo "错误: feed 行不能同时使用 ;branch 与 ^commit: $line" >&2
        exit 1
    fi
    if [[ "$line" == *";@latest" ]]; then
        _name=$(echo "$line" | awk '{print $2}')
        _url=$(echo "$line" | awk '{print $3}' | sed 's|;@latest$||')
        _tag="$(resolve_latest_tag "$_url")"
        if [ -n "$_tag" ]; then
            echo "feed $_name: 追踪最新 release tag -> $_tag"
            line="src-git $_name $_url;$_tag"
        else
            echo "feed $_name: 仓库无 tag，回退默认分支"
            line="src-git $_name $_url"
        fi
    fi
    grep -qxF "$line" "$OPENWRT/feeds.conf.default" || echo "$line" >> "$OPENWRT/feeds.conf.default"
done < "$FEEDS_FILE"

# 4) 源码树内包：公共 vendor 包（如 netpath）+ 设备专属包（如 tr3600-dualslot-upgrade）
#    不走 feed：绕开 scan.mk 对非标准 feed 布局的兼容问题
if [ -d "$ROOT/common/package" ]; then
    cp -a "$ROOT/common/package/." "$OPENWRT/package/"
    # luci-app-dufs 例外：它是从 immortalwrt/luci vendored 来的（openwrt 官方 luci 没有这个应用），
    # 而 immortalwrt 自己的 luci feed 恰好自带同一个包——两份同名包会让 Kconfig 出现重复符号，
    # 因此该上游删掉本地副本，直接用 feed 里那份（同一个仓库、同一份代码）。
    if [ "$REPO" = "immortalwrt" ] && [ -d "$OPENWRT/package/luci-app-dufs" ]; then
        rm -rf "$OPENWRT/package/luci-app-dufs"
        echo "immortalwrt: 跳过本地 luci-app-dufs（改用其 luci feed 自带版本）"
    fi
fi
if [ -d "$ROOT/devices/$DEV/package" ]; then
    cp -a "$ROOT/devices/$DEV/package/." "$OPENWRT/package/"
fi

# 5) files 覆盖：common 先、device 后（同名后者胜）
mkdir -p "$OPENWRT/files"
if [ -d "$ROOT/common/files" ]; then
    cp -a "$ROOT/common/files/." "$OPENWRT/files/"
fi
if [ -d "$ROOT/devices/$DEV/files" ]; then
    cp -a "$ROOT/devices/$DEV/files/." "$OPENWRT/files/"
fi

# 6) 组装 .config：交给 assemble-config.sh（单一真源）
#    注意：feeds update 会静默触发一次 make defconfig，那时 feed 包还不可见 → 必须由
#    build-device.sh 在 feeds 安装完成后再调一次同一个脚本（见那里的注释）。
UPSTREAM_REPO="$REPO" bash "$ROOT/scripts/assemble-config.sh" "$ROOT" "$DEV" "$PROFILE" "$OPENWRT"

# 定制脚本（customize.sh）在 build-device.sh 的 feeds 安装之后执行——
# 部分定制（如默认主题 sed）需要操作 feeds 里的文件，早于 feeds 会报文件不存在
echo "==== 组装完成 ===="
