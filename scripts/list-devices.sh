#!/usr/bin/env bash
# 列出 devices/ 下所有设备。
# 用法: list-devices.sh [--json]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVS=()

for d in "$ROOT"/devices/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/device.yml" ] || continue
    DEVS+=("$(basename "$d")")
done

if [ "${1:-}" = "--json" ]; then
    if [ "${#DEVS[@]}" -eq 0 ]; then
        echo "[]"
    else
        JSON=""
        for v in "${DEVS[@]}"; do
            JSON="$JSON\"$v\","
        done
        echo "[${JSON%,}]"
    fi
else
    printf '%s\n' "${DEVS[@]}"
fi
