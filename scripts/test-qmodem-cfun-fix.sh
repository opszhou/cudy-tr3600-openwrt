#!/usr/bin/env bash
# 沙箱测试：apply-qmodem-cfun-fix.sh 的插入 / 幂等 / 锚点缺失 / 锚点重复 / 缺文件。
# 不依赖真实 OpenWrt 源码树，构造临时 feeds 目录即可运行。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="$ROOT/scripts/apply-qmodem-cfun-fix.sh"
MARKER='# QModem-hotfix: CFUN=0 时拨号会空转'
INS='check_cfun >/dev/null 2>&1'

TMP="$(mktemp -d /tmp/qmcfun.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
F="$TMP/feeds/qmodem/application/qmodem/files/usr/share/qmodem/modem_dial.sh"
mkdir -p "$(dirname "$F")"

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

sample() {
	printf '%s\n' \
		'#!/bin/sh' \
		'check_cfun(){' \
		'    at_command="AT+CFUN?"' \
		'}' \
		'dial(){' \
		'    update_config' \
		'    while [ "$dial_prepare" != 1 ] ; do' \
		'        sleep 5' \
		'        check_dial_prepare' \
		'        dial_prepare=$?' \
		'    done' \
		'    set_if || return 1' \
		'}' > "$F"
}

# 用例 1：正常插入
sample
bash "$APPLY" "$TMP" > /dev/null
check "插入 check_cfun 调用" "$(grep -cF "$INS" "$F")" "1"
check "插入注释标记" "$(grep -cF "$MARKER" "$F")" "1"
check "锚点行保留" "$(grep -cE '^[[:space:]]*while \[ "\$dial_prepare" != 1 \] ; do' "$F")" "1"
check "插入行行号" "$(grep -nF "$INS" "$F" | cut -d: -f1)" "9"
check "锚点在其上一行" "$(grep -nE '^[[:space:]]*while \[ "\$dial_prepare" != 1 \] ; do' "$F" | cut -d: -f1)" "7"
check "插在循环体内（缩进 8 空格）" "$(grep -c '^        check_cfun >/dev/null 2>&1$' "$F")" "1"
check "后续逻辑未被破坏" "$(grep -c 'set_if || return 1' "$F")" "1"

# 用例 2：幂等
bash "$APPLY" "$TMP" > /dev/null
check "二次运行不重复插入" "$(grep -cF "$INS" "$F")" "1"

# 用例 3：锚点不存在必须失败，且文件不变
sample
sed -i 's/while \[ "\$dial_prepare" != 1 \] ; do/while true ; do/' "$F"
before="$(cat "$F")"
if bash "$APPLY" "$TMP" > /dev/null 2>&1; then
	check "锚点缺失应失败" "未失败" "失败"
else
	check "锚点缺失应失败" "失败" "失败"
fi
check "失败时文件未被改动" "$(cat "$F")" "$before"

# 用例 4：锚点重复必须失败
sample
printf '%s\n' '    while [ "$dial_prepare" != 1 ] ; do' '        sleep 1' '    done' >> "$F"
if bash "$APPLY" "$TMP" > /dev/null 2>&1; then
	check "锚点重复应失败" "未失败" "失败"
else
	check "锚点重复应失败" "失败" "失败"
fi

# 用例 5：缺文件必须失败
rm -f "$F"
if bash "$APPLY" "$TMP" > /dev/null 2>&1; then
	check "缺少文件应失败" "未失败" "失败"
else
	check "缺少文件应失败" "失败" "失败"
fi

echo "---- 通过 $pass / 失败 $fail ----"
[ "$fail" -eq 0 ]
