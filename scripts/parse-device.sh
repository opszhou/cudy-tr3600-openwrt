#!/usr/bin/env bash
# 解析 devices/<id>/device.yml，输出可 eval 的 shell 变量：
#   DEV_ID / DEV_TARGET / DEV_PROFILE / DEV_BRANCH / DEV_PRS
# 用法: eval "$(scripts/parse-device.sh <repo-root> <device-id>)"
set -euo pipefail

ROOT="${1:?用法: parse-device.sh <repo-root> <device-id>}"
DEV="${2:?缺少设备ID}"
YML="$ROOT/devices/$DEV/device.yml"

[ -f "$YML" ] || { echo "错误: 设备配置不存在: $YML" >&2; exit 1; }

field() {
    # 取 "key: value" 的 value，去掉行内注释和引号
    sed -nE "s/^$1:[[:space:]]*//p" "$YML" | head -n1 | cut -d'#' -f1 \
        | tr -d "\"'" | xargs
}

DEV_ID=$(field id); DEV_TARGET=$(field target)
DEV_PROFILE=$(field profile); DEV_BRANCH=$(field branch)

# 必填字段校验：缺失时给出明确指引（run#29 教训——静默错位比崩溃贵）
MISSING=""
[ -n "$DEV_ID" ]      || MISSING="$MISSING id"
[ -n "$DEV_TARGET" ]  || MISSING="$MISSING target"
[ -n "$DEV_PROFILE" ] || MISSING="$MISSING profile"
[ -n "$DEV_BRANCH" ]  || MISSING="$MISSING branch"
if [ -n "$MISSING" ]; then
    echo "错误: $YML 缺少必填字段:$MISSING" >&2
    echo "       device.yml 至少需要: id / target / profile / branch" >&2
    exit 1
fi

echo "DEV_ID=$DEV_ID"
echo "DEV_TARGET=$DEV_TARGET"
echo "DEV_PROFILE=$DEV_PROFILE"
echo "DEV_BRANCH=$DEV_BRANCH"

# default_prs 列表：仅取未注释的 "- <数字>" 行
PRS="$(sed -nE 's/^[[:space:]]*-[[:space:]]*([0-9]+)[[:space:]]*(#.*)?$/\1/p' "$YML")"
echo "DEV_PRS=\"$PRS\""
