#!/usr/bin/env bash
# 沙箱测试：用量按天/周聚合脚本 sysdashboard-usage
#
# 覆盖：首次建立基线、增量累加、模组统计清零不自减、跨天记「昨天」、跨周清零、
#       状态落盘与重启后继续累加。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/common/package/luci-app-sysdashboard/root/usr/libexec/sysdashboard-usage"
PY="${PYTHON:-$(command -v python3 || command -v python)}"

[ -f "$HELPER" ] || { echo "FAIL: 找不到 $HELPER" >&2; exit 1; }

SB=$(mktemp -d "$ROOT/.workbuddy/tmp/usage-test.XXXXXX")
trap 'rm -rf "$SB"' EXIT

STATE="$SB/usage.conf"
export SYSDASH_USAGE_STATE="$STATE"
export SYSDASH_USAGE_SAVE=0   # 每次调用都落盘，便于验证状态

pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$((pass+1)); }
bad() { echo "  ✗ $1" >&2; fail=$((fail+1)); }

# 断言 JSON 字段：check_json <名称> <json> <python 表达式>
check_json() {
	local name="$1" json="$2" expr="$3"
	local out
	out=$(printf '%s' "$json" | "$PY" -c "
import json,sys
d=json.load(sys.stdin)
print(int($expr))
" 2>/dev/null) || out="ERR"
	if [ "$out" = "1" ] || [ "$out" = "True" ]; then ok "$name"; else bad "$name（实际: $out）"; fi
}

echo "== 首次运行：只建立基线，不把历史总量算进今天 =="
J=$(bash "$HELPER" 1000000 500000)
check_json "今日清零" "$J" '(d["today"]["rx"]==0 and d["today"]["tx"]==0)'
check_json "本周清零" "$J" '(d["week"]["rx"]==0 and d["week"]["tx"]==0)'
check_json "记录起始时间" "$J" 'd["since"]>0'

echo "== 第二次：增量累加到今日/本周 =="
J=$(bash "$HELPER" 1001000 500300)
check_json "今日增量 rx" "$J" 'd["today"]["rx"]==1000'
check_json "今日增量 tx" "$J" 'd["today"]["tx"]==300'
check_json "本周等于今日（本周刚开始）" "$J" '(d["week"]["rx"]==1000 and d["week"]["tx"]==300)'

echo "== 模组统计被清零：不自减，只重置基线 =="
J=$(bash "$HELPER" 500 200)
check_json "今日保持不变" "$J" 'd["today"]["rx"]==1000'
J=$(bash "$HELPER" 700 260)
check_json "清零后继续按新增累加" "$J" 'd["today"]["rx"]==1200'

echo "== 跨天：前一天记为「昨天」 =="
# 伪造状态：day 改成很久以前但 last_save 是刚才（模拟隔夜）
sed -i.bak "s/^day=.*/day=2000-01-01/" "$STATE"
J=$(bash "$HELPER" 900 300)
check_json "今日从零开始" "$J" 'd["today"]["rx"]==200'
check_json "昨天保留前一天的量" "$J" 'd["yesterday"]["rx"]==1200'

echo "== 跨周：本周清零 =="
sed -i.bak "s/^week_id=.*/week_id=1999-W01/" "$STATE"
J=$(bash "$HELPER" 1000 400)
check_json "本周从零开始" "$J" 'd["week"]["rx"]==100'

echo "== 状态落盘：重启后继续累加 =="
grep -q '^day=' "$STATE" && ok "状态文件含 day 字段" || bad "状态文件缺 day 字段"
grep -q '^week_rx=' "$STATE" && ok "状态文件含 week_rx" || bad "状态文件缺 week_rx"
J=$(bash "$HELPER" 1100 500)
check_json "重启后增量继续累加（300 + 100）" "$J" 'd["today"]["rx"]==400'

echo "== 参数非法时优雅降级 =="
J=$(bash "$HELPER" "" "")
check_json "空参数当作 0，不报错" "$J" 'd["today"]["rx"]>=0'

echo
echo "---- 通过 $pass / 失败 $fail ----"
[ "$fail" -eq 0 ] || exit 1
