#!/usr/bin/env bash
# 组装 openwrt 源码树：补丁 → PR → feeds → 设备包 → files → .config → 定制脚本。
# 用法: assemble.sh <repo-root> <device-id> <profile> <openwrt目录> [owner] [repo] [extra_prs]
#   profile: lite | ultimate
#   extra_prs: 临时追加合并的官方 PR 号（空格分隔，仅本次构建，不入库）
set -euo pipefail

ROOT="${1:?缺少 repo root}"
DEV="${2:?缺少设备ID}"
PROFILE="${3:-lite}"
OPENWRT="${4:?缺少 openwrt 目录}"
OWNER="${5:-openwrt}"
REPO="${6:-openwrt}"
EXTRA_PRS="${7:-}"

# 规范化为绝对路径：脚本内会 cd 进 openwrt 树，相对路径会解析错位
ROOT="$(cd "$ROOT" && pwd)"

# shellcheck disable=SC2046
eval "$(bash "$ROOT/scripts/parse-device.sh" "$ROOT" "$DEV")"
BRANCH="${DEV_BRANCH:-main}"

echo "==== 组装: 设备=$DEV target=$DEV_TARGET profile=$DEV_PROFILE 上游分支=$BRANCH ===="

# 1) 应用设备补丁（含已入库的官方 PR 补丁）
bash "$ROOT/scripts/apply-device-patches.sh" "$ROOT" "$DEV" "$OPENWRT" "$BRANCH"

# 2) 临时追加合并官方 PR（不入库，仅本次构建生效）
for pr in $EXTRA_PRS; do
    bash "$ROOT/scripts/apply-pr.sh" "$OPENWRT" "$pr" "/tmp/pr$pr.diff" "$OWNER" "$REPO"
done

# 3) 追加公共 feeds（去重；只追加，不覆盖上游自带 feeds）
#    支持 ;@latest 标记：构建时解析该仓库「最新稳定 release tag」——
#    过滤 rc/beta/alpha 等预发布 tag 取版本最高者；无稳定 tag 取最高 tag；完全无 tag 回退默认分支
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
done < "$ROOT/common/feeds.append"

# 4) 设备专属源码包（如 tr3600-dualslot-upgrade）
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

# 6) 组装 .config：设备种子 + 包组合（make defconfig 会解析补全）
cp "$ROOT/devices/$DEV/default.seed" "$OPENWRT/.config"
case "$PROFILE" in
    lite)
        # 精简实用型：随身WiFi(QModem) + 需求清单精简版
        cat "$ROOT/common/packages/modem.list" >> "$OPENWRT/.config"
        cat "$ROOT/common/packages/lite.list" >> "$OPENWRT/.config"
        ;;
    ultimate)
        # 全能型：lite 全部 + tailscale/travelmate/ttyd/filebrowser/netspeedtest/statistics/netpath/macvlan
        cat "$ROOT/common/packages/modem.list" >> "$OPENWRT/.config"
        cat "$ROOT/common/packages/lite.list" >> "$OPENWRT/.config"
        cat "$ROOT/common/packages/proxy.list" >> "$OPENWRT/.config"
        cat "$ROOT/common/packages/extra.list" >> "$OPENWRT/.config"
        ;;
    *)
        echo "错误: 未知 profile: $PROFILE（可选 lite/ultimate）" >&2
        exit 1
        ;;
esac

# 定制脚本（customize.sh）在 build-device.sh 的 feeds 安装之后执行——
# 部分定制（如默认主题 sed）需要操作 feeds 里的文件，早于 feeds 会报文件不存在
echo "==== 组装完成 ===="
