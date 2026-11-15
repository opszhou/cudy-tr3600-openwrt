#!/usr/bin/env bash
# 出 Artifact 前的最后一道闸：必装包真的进了镜像 + sysupgrade.bin 不超过 ubi 分区上限。
#
# 为什么要有它：编译成功 ≠ 刷得进去。defconfig 通过了，包也可能在 package/install
# 阶段被裁掉；镜像超过 ubi 分区则刷机必半死。这两件事到刷机现场才发现就太晚。
#
# 期望值按设备配置（devices/<id>/audit.conf），⛔ 不写死在 workflow 里：
# 不同设备的 WiFi 驱动与分区大小本来就不同（run#54：P3 的 kmod-mt7915e /
# mt7981-wo-firmware 被套到 TR3600（MT7987B）上，构建成功却被判失败）。
#
# audit.conf 字段：
#   REQUIRED_PKGS="qmodem luci-app-qmodem-next"   # 必装包，逐个在 manifest 里核对
#   MAX_MIB=232                                   # sysupgrade.bin 上限（MiB），= ubi 分区大小
#
# 用法: audit-image.sh <device-id> <bin/targets 目录>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV="${1:?缺少设备ID}"
TARGETS="${2:?缺少 bin/targets 目录}"
CONF="$ROOT/devices/$DEV/audit.conf"

if [ ! -f "$CONF" ]; then
	echo "错误: 缺少 $CONF —— 必装包与镜像上限按设备配置，见 docs/ADD-DEVICE.md" >&2
	exit 1
fi
# shellcheck disable=SC1090
. "$CONF"
: "${REQUIRED_PKGS:?audit.conf 缺 REQUIRED_PKGS}"
: "${MAX_MIB:?audit.conf 缺 MAX_MIB}"

MF="$(find "$TARGETS" -name '*.manifest' | head -n1)"
if [ -z "$MF" ]; then
	echo "错误: 未找到 manifest（$TARGETS）" >&2
	exit 1
fi
echo "== 必装包核对（$MF）=="
miss=0
for p in $REQUIRED_PKGS; do
	if grep -qE "^$p([[:space:]]|$)" "$MF"; then
		echo "  OK      $p"
	else
		echo "  MISSING $p"
		miss=1
	fi
done
if [ "$miss" -ne 0 ]; then
	echo "错误: 有必装包缺失" >&2
	exit 1
fi

BIN="$(find "$TARGETS" -name "*${DEV}*sysupgrade*.bin" | head -n1)"
if [ -z "$BIN" ]; then
	echo "错误: 未找到 $DEV 的 sysupgrade 镜像" >&2
	ls -lh "$TARGETS" 2>/dev/null || true
	exit 1
fi
SZ="$(stat -c %s "$BIN")"
LIMIT=$((MAX_MIB * 1024 * 1024))
echo "== 镜像体积 =="
echo "  $BIN = $SZ bytes ($((SZ / 1024 / 1024)) MiB)，上限 ${MAX_MIB} MiB"
if [ "$SZ" -ge "$LIMIT" ]; then
	echo "错误: 超过 ${MAX_MIB} MiB ubi 分区上限" >&2
	exit 1
fi
echo "RESULT: OK"
