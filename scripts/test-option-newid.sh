#!/usr/bin/env bash
# 20-option-newid（FM170EAU 2cb7:0110 补 option 注册）的沙箱测试
#
# 用假 sysfs 树 + 假 option1/new_id 覆盖：
#   1. MBIM 组合、ff 串口未绑            → 写 new_id
#   2. ff 串口已绑 option                → 不动（幂等）
#   3. 表内 PID 0111                     → 不动
#   4. 数据接口尚未绑驱动                → 不动
#   5. dynids 已登记                     → 不重复写
#   6. option1 驱动未加载                → 安全退出
#   7. 开机兜底 hotfix 脚本              → 同样生效
#   8. 两台设备（0110 + 0111）           → 只给 0110 补
#
# 用法: bash scripts/test-option-newid.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/common/files/etc/hotplug.d/usb/20-option-newid"
BOOT="$ROOT/common/files/etc/hotfix.d/20-option-newid.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: 找不到 $SCRIPT" >&2; exit 1; }
[ -f "$BOOT" ] || { echo "FAIL: 找不到 $BOOT" >&2; exit 1; }

mkdir -p "$ROOT/.workbuddy/tmp"
SB=$(mktemp -d "$ROOT/.workbuddy/tmp/option-newid-test.XXXXXX")
cleanup() { [ -d "$SB" ] && find "$SB" -mindepth 1 -delete 2>/dev/null; rmdir "$SB" 2>/dev/null; }
trap cleanup EXIT

pass=0
fail=0
N=0

# 建一台设备：$1=PID $2=接口驱动列表（逗号分隔，_ 表示未绑）$3=目标 sysfs 根 $4=设备名
mkdev() {
	local pid="$1" drvs="$2" sys="$3" name="$4"
	local dev="$sys/bus/usb/devices/$name"
	mkdir -p "$dev" "$sys/bus/usb-serial/drivers/option1" "$sys/bus/usb/drivers"
	echo 2cb7 > "$dev/idVendor"
	echo "$pid" > "$dev/idProduct"
	local i=0 d
	IFS=',' read -ra arr <<< "$drvs"
	for d in "${arr[@]}"; do
		local ifdir="$dev/$name:1.$i"
		mkdir -p "$ifdir"
		if [ "$d" != "_" ]; then
			mkdir -p "$sys/bus/usb/drivers/$d"
			ln -s "$sys/bus/usb/drivers/$d" "$ifdir/driver"
		fi
		i=$((i + 1))
	done
}

# $1=名称 $2=期望(write/skip) $3=PID $4=驱动列表 $5=已有 dynids $6=入口(hotplug/hotfix) $7=是否删掉 new_id
run_case() {
	local name="$1" expect="$2" pid="$3" drvs="$4" existing="$5" entry="$6" noid="${7:-0}"
	N=$((N + 1))
	local c="$SB/c$N"
	mkdev "$pid" "$drvs" "$c/sys" "2-1"
	local newid="$c/sys/bus/usb-serial/drivers/option1/new_id"
	if [ "$noid" = 1 ]; then
		rm -f "$newid"
	else
		: > "$newid"
		[ -n "$existing" ] && printf '%s\n' "$existing" > "$newid"
	fi

	local cmd="$SCRIPT"
	[ "$entry" = "hotfix" ] && cmd="$BOOT"
	OPTION_NEWID_SH="$SCRIPT" \
	SYSFS="$c/sys" \
	DRV_DIR="$c/sys/bus/usb-serial/drivers/option1" \
	LOGGER=true GRACE=0 sh "$cmd" >/dev/null 2>&1 || true

	local got=""
	[ -f "$newid" ] && got=$(cat "$newid")
	if { [ "$expect" = write ] && [ "$got" = "2cb7 0110" ]; } || \
	   { [ "$expect" = skip ] && [ "$got" = "$existing" ]; }; then
		pass=$((pass + 1)); echo "  ✓ $name"
	else
		fail=$((fail + 1)); echo "  ✗ $name (期望=$expect 得到='$got')"
	fi
}

echo "== 语法 =="
sh -n "$SCRIPT" && echo "  ✓ hotplug 脚本 sh -n 通过"
sh -n "$BOOT" && echo "  ✓ hotfix 脚本 sh -n 通过"
echo

echo "== 判定用例 =="
run_case "MBIM 组合 ff 串口未绑 → 补注册"   write 0110 "cdc_mbim,cdc_mbim,_,_"        ""             hotplug 0
run_case "ff 串口已绑 option → 幂等不动"      skip  0110 "cdc_mbim,cdc_mbim,option,option" ""           hotplug 0
run_case "表内 PID 0111 → 不动"              skip  0111 "cdc_mbim,cdc_mbim,_,_"        ""             hotplug 0
run_case "数据接口未绑驱动 → 不动"            skip  0110 "_,_,_,_"                       ""             hotplug 0
run_case "dynids 已登记 → 不重复写"           skip  0110 "cdc_mbim,cdc_mbim,_,_"        "2cb7 0110"   hotplug 0
run_case "option1 未加载 → 安全退出"          skip  0110 "cdc_mbim,cdc_mbim,_,_"        ""             hotplug 1
run_case "开机兜底 hotfix 入口"               write 0110 "cdc_mbim,cdc_mbim,_,_"        ""             hotfix   0

# 第 8 例：同机两台设备，只有 0110 需要补
N=$((N + 1))
c="$SB/c$N"
mkdev 0111 "cdc_mbim,cdc_mbim,_,_" "$c/sys" "2-2"
mkdev 0110 "cdc_mbim,cdc_mbim,_,_" "$c/sys" "2-1"
newid="$c/sys/bus/usb-serial/drivers/option1/new_id"
: > "$newid"
SYSFS="$c/sys" DRV_DIR="$c/sys/bus/usb-serial/drivers/option1" LOGGER=true GRACE=0 \
	sh "$SCRIPT" >/dev/null 2>&1 || true
got=$(cat "$newid")
if [ "$got" = "2cb7 0110" ]; then
	pass=$((pass + 1)); echo "  ✓ 两台设备（0110 + 0111）→ 只补一次"
else
	fail=$((fail + 1)); echo "  ✗ 两台设备场景，得到='$got'"
fi

echo
echo "== 结果：$pass 通过 / $fail 失败（共 $N 例）=="
[ "$fail" -eq 0 ] || exit 1
