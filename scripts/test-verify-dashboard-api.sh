#!/usr/bin/env bash
# 沙箱测试：管理面板上游契约校验脚本 verify-dashboard-api.sh
#
# 构造一个最小的「假官方 dashboard 目录」，验证：
#   1) 契约齐全时通过
#   2) index.js 少了 !=null 过滤时报错（我们靠它隐藏卡片）
#   3) 少一个官方 include（丢 widget id）时报错并指出缺失项
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT/scripts/verify-dashboard-api.sh"
[ -f "$VERIFY" ] || { echo "FAIL: 找不到 $VERIFY" >&2; exit 1; }

SB=$(mktemp -d "$ROOT/.workbuddy/tmp/vd-test.XXXXXX")
trap 'rm -rf "$SB"' EXIT

pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$((pass+1)); }
bad() { echo "  ✗ $1" >&2; fail=$((fail+1)); }

build_fake() {
	local d="$1"
	rm -rf "$d"
	mkdir -p "$d/lib" "$d/include"

	cat > "$d/lib/charts.js" <<'EOF'
return baseclass.extend({kpi(o){},card(o){},empty(t){}});
EOF

	cat > "$d/lib/widgets.js" <<'EOF'
return baseclass.extend({slots:['cards'],available(){},defaults(){}});
EOF

	cat > "$d/index.js" <<'EOF'
const found={cards:{},charts:{},tabs:{}};
const sections={};sections[slot]=layout[slot].map(id=>found[slot][id]).filter(item=>item!=null);
EOF

	cat > "$d/include/10_router.js" <<'EOF'
widgets:[{id:'internet',slot:'cards'},{id:'uptime',slot:'cards'},{id:'internet',slot:'tabs'},{id:'system',slot:'tabs'}]
EOF
	cat > "$d/include/12_resources.js" <<'EOF'
widgets:[{id:'cpu',slot:'cards'},{id:'memory',slot:'cards'},{id:'load',slot:'cards'},{id:'system',slot:'charts'},{id:'resources',slot:'tabs'}]
EOF
	cat > "$d/include/15_traffic.js" <<'EOF'
widgets:[{id:'wan',slot:'charts'}]
EOF
	cat > "$d/include/20_lan.js" <<'EOF'
widgets:[{id:'dhcp',slot:'cards'},{id:'dhcp',slot:'tabs'}]
EOF
	cat > "$d/include/30_wifi.js" <<'EOF'
widgets:[{id:'wifi',slot:'cards'},{id:'distribution',slot:'charts'},{id:'signal',slot:'charts'},{id:'traffic',slot:'charts'},{id:'wifi',slot:'tabs'}]
EOF
}

echo "== 契约齐全 =="
D="$SB/good"; build_fake "$D"
if out=$(bash "$VERIFY" --dir "$D" 2>&1); then
	ok "正常目录通过"
	echo "$out" | grep -q "RESULT: OK" && ok "输出 RESULT: OK" || bad "缺少 RESULT: OK"
else
	bad "正常目录被误判失败"
	echo "$out" | sed 's/^/      /' >&2
fi

echo "== 少了 null 过滤 =="
D="$SB/no-null"; build_fake "$D"
sed -i 's/filter(item=>item!=null)/filter(item=>item)/' "$D/index.js"
if bash "$VERIFY" --dir "$D" >/dev/null 2>&1; then
	bad "缺少 !=null 时未报错"
else
	ok "缺少 !=null 时构建失败"
fi

echo "== 少一个官方 include =="
D="$SB/no-wan"; build_fake "$D"
rm -f "$D/include/15_traffic.js"
out=$(bash "$VERIFY" --dir "$D" 2>&1 || true)
echo "$out" | grep -q "charts:wan" && ok "明确指出缺失 charts:wan" || bad "未指出缺失项"

echo "== 目录不存在 =="
if bash "$VERIFY" --dir "$SB/nope" >/dev/null 2>&1; then
	bad "不存在的目录未报错"
else
	ok "不存在的目录直接失败"
fi

echo
echo "---- 通过 $pass / 失败 $fail ----"
[ "$fail" -eq 0 ] || exit 1
