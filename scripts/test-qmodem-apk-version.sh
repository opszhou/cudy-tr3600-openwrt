#!/usr/bin/env bash
# 沙箱测试：apply-qmodem-apk-version.sh 的改写 / 幂等 / 已合法跳过 / 格式不符失败 / 缺文件失败。
# 不依赖真实 OpenWrt 源码树，构造临时 feeds 目录即可运行。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="$ROOT/scripts/apply-qmodem-apk-version.sh"

TMP="$(mktemp -d /tmp/qmver.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
F="$TMP/feeds/qmodem/version.mk"
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

# 样本：与真实 version.mk 结构一致（含 commitcount 定义等其它内容）
sample() {
	cat > "$F" <<'EOF'
# Unified version management for modem_feeds
QMODEM_AUTORELEASE:=$(shell echo 1)
QMODEM_VERSION:=3.4.0-rc.3
QMODEM_RELEASE:=$(QMODEM_AUTORELEASE)
EOF
}

# 用例 1：连字符预发布写法被改写为下划线形式
sample
bash "$APPLY" "$TMP" > /dev/null
check "改写为 3.4.0_rc3" "$(grep -c '^QMODEM_VERSION:=3.4.0_rc3$' "$F")" "1"
check "无连字符残留" "$(grep -c '^QMODEM_VERSION:=3.4.0-rc.3$' "$F")" "0"
check "其它行未被破坏" "$(grep -c '^QMODEM_RELEASE:=' "$F")" "1"
check "注释行未被破坏" "$(grep -c '^# Unified version management' "$F")" "1"

# 用例 2：幂等，再跑一次内容不变
bash "$APPLY" "$TMP" > /dev/null
check "二次运行仍只有 1 行规范化版本" "$(grep -c '^QMODEM_VERSION:=3.4.0_rc3$' "$F")" "1"

# 用例 3：本来就是合法写法（纯数字版本）直接跳过且不改内容
printf 'QMODEM_VERSION:=3.4.0\n' > "$F"
before="$(cat "$F")"
bash "$APPLY" "$TMP" > /dev/null
check "纯数字版本跳过不改动" "$(cat "$F")" "$before"

# 用例 4：无法识别的版本行必须失败，且文件不被改动
printf 'QMODEM_VERSION:=SOMETHING_ELSE\n' > "$F"
before="$(cat "$F")"
if bash "$APPLY" "$TMP" > /dev/null 2>&1; then
	check "格式不符应失败" "未失败" "失败"
else
	check "格式不符应失败" "失败" "失败"
fi
check "失败时文件未被改动" "$(cat "$F")" "$before"

# 用例 5：找不到 version.mk 必须失败
rm -f "$F"
if bash "$APPLY" "$TMP" > /dev/null 2>&1; then
	check "缺少文件应失败" "未失败" "失败"
else
	check "缺少文件应失败" "失败" "失败"
fi

echo "---- 通过 $pass / 失败 $fail ----"
[ "$fail" -eq 0 ]
