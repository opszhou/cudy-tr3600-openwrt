#!/usr/bin/env bash
# 沙箱测试：audit-image.sh 的必装包核对 / 体积上限 / 镜像缺失 / 配置缺失。
# 用真实设备配置（devices/<id>/audit.conf）跑，构造临时 bin/targets 即可，不需要真实构建产物。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$ROOT/scripts/audit-image.sh"

TMP="$(mktemp -d /tmp/audit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
DEV="cudy_tr3600-v1"
T="$TMP/bin/targets/mediatek/filogic"
mkdir -p "$T"

pass=0
fail=0
check() {
	if [ "$2" = "$3" ]; then
		echo "✅ $1"
		pass=$((pass + 1))
	else
		echo "❌ $1: 期望 [$3] 实际 [$2]"
		fail=$((fail + 1))
	fi
}
run() { bash "$AUDIT" "$DEV" "$TMP/bin/targets" > /dev/null 2>&1; }

# 样本：TR3600 的 manifest + 小镜像
mkok() {
	printf '%s\n' \
		'qmodem - 3.4.0_rc3-r1' \
		'luci-app-qmodem-next - 3.4.0_rc3-r1' \
		'kmod-usb3 - 6.12.0-r1' \
		'luci-i18n-base-zh-cn - git-1' \
		'ksmbd-server - 3.5.6-r1' \
		'luci-app-ksmbd - git-1' \
		> "$T/openwrt-mediatek-filogic-cudy_tr3600-v1.manifest"
	truncate -s 80M "$T/openwrt-mediatek-filogic-cudy_tr3600-v1-squashfs-sysupgrade.bin"
}

# 用例 1：全部满足 → 通过
mkok
if run; then check "必装包齐全且体积正常应通过" "通过" "通过"; else check "必装包齐全且体积正常应通过" "失败" "通过"; fi

# 用例 2：缺必装包 → 失败
mkok
grep -v '^kmod-usb3' "$T/openwrt-mediatek-filogic-cudy_tr3600-v1.manifest" > "$T/m.tmp"
mv "$T/m.tmp" "$T/openwrt-mediatek-filogic-cudy_tr3600-v1.manifest"
if run; then check "缺必装包应失败" "未失败" "失败"; else check "缺必装包应失败" "失败" "失败"; fi

# 用例 3：镜像体积达上限 → 失败（232 MiB 上限，造 232M 稀疏文件）
mkok
truncate -s 232M "$T/openwrt-mediatek-filogic-cudy_tr3600-v1-squashfs-sysupgrade.bin"
if run; then check "体积达上限应失败" "未失败" "失败"; else check "体积达上限应失败" "失败" "失败"; fi

# 用例 4：找不到 sysupgrade 镜像 → 失败
mkok
rm -f "$T/openwrt-mediatek-filogic-cudy_tr3600-v1-squashfs-sysupgrade.bin"
if run; then check "缺镜像应失败" "未失败" "失败"; else check "缺镜像应失败" "失败" "失败"; fi

# 用例 5：设备没有 audit.conf → 失败（不允许静默跳过审计）
mkok
if bash "$AUDIT" no_such_device "$TMP/bin/targets" > /dev/null 2>&1; then
	check "缺 audit.conf 应失败" "未失败" "失败"
else
	check "缺 audit.conf 应失败" "失败" "失败"
fi

# 用例 6：P3 的配置能识别自己的驱动包（回归 run#54 的误判：A 设备期望套到 B 设备）
rm -rf "$TMP/bin/targets"/*; mkdir -p "$T"
printf '%s\n' 'qmodem - x' 'luci-app-qmodem-next - x' 'kmod-mt7915e - x' 'mt7981-wo-firmware - x' \
	'kmod-usb3 - x' 'luci-i18n-base-zh-cn - x' \
	'ksmbd-server - x' 'luci-app-ksmbd - x' > "$T/openwrt-mediatek-filogic-fzs_5gcpe-p3.manifest"
truncate -s 80M "$T/openwrt-mediatek-filogic-fzs_5gcpe-p3-squashfs-sysupgrade.bin"
if bash "$AUDIT" fzs_5gcpe-p3 "$TMP/bin/targets" > /dev/null 2>&1; then
	check "P3 用 P3 配置应通过" "通过" "通过"
else
	check "P3 用 P3 配置应通过" "失败" "通过"
fi

echo "---- 通过 $pass / 失败 $fail ----"
[ "$fail" -eq 0 ]
