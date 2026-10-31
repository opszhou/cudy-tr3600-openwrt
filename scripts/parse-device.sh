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

echo "DEV_ID=$(field id)"
echo "DEV_TARGET=$(field target)"
echo "DEV_PROFILE=$(field profile)"
echo "DEV_BRANCH=$(field branch)"

# default_prs 列表：仅取未注释的 "- <数字>" 行
PRS="$(sed -nE 's/^[[:space:]]*-[[:space:]]*([0-9]+)[[:space:]]*(#.*)?$/\1/p' "$YML")"
echo "DEV_PRS=\"$PRS\""
