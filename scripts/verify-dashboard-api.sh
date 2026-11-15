#!/bin/sh
# verify-dashboard-api.sh -- 校验上游 luci-mod-dashboard 的接口契约
#
# 我们的面板是「扩展点」方式：不改官方文件，只往它扫描的目录加 include / sd 模块，
# 并用同 id 覆盖部件。因此强依赖官方这几个内部行为：
#   1) lib/charts.js 提供 kpi() / card() / empty()
#   2) index.js 的 collectSections 用 layout 映射后 .filter(item != null) 过滤空部件
#      （我们靠「node: null」实现隐藏）
#   3) lib/widgets.js 有 available() / defaults() / slots
#   4) 官方 include 的 widget id 仍包含我们要覆盖的那些
#
# 任何一条不成立 → 直接失败，不让「面板白屏 / 空卡片」的固件发出去。
#
# 用法:
#   verify-dashboard-api.sh <openwrt-root>       # CI：feeds 安装后调用
#   verify-dashboard-api.sh --dir <dashboard视图目录>   # 本地/真机：直接指定
#
# 目录可指向：
#   <openwrt>/feeds/luci/modules/luci-mod-dashboard/htdocs/luci-static/resources/view/dashboard
#   <openwrt>/package/feeds/luci/luci-mod-dashboard/htdocs/luci-static/resources/view/dashboard
#   设备上的 /www/luci-static/resources/view/dashboard
set -u

die() { echo "错误: $*" >&2; exit 1; }

VD=""
if [ "${1:-}" = "--dir" ]; then
	VD="${2:?缺少目录}"
	[ -d "$VD" ] || die "目录不存在: $VD"
else
	ROOT="${1:?用法: verify-dashboard-api.sh <openwrt-root> | --dir <dir>}"
	for cand in \
		"$ROOT/feeds/luci/modules/luci-mod-dashboard/htdocs/luci-static/resources/view/dashboard" \
		"$ROOT/package/feeds/luci/luci-mod-dashboard/htdocs/luci-static/resources/view/dashboard" \
		"$ROOT/www/luci-static/resources/view/dashboard"
	do
		[ -d "$cand" ] && { VD="$cand"; break; }
	done
	[ -n "$VD" ] || die "找不到 luci-mod-dashboard 的视图目录（feeds 是否已安装？）"
fi

echo "== 管理面板接口契约校验 =="
echo "  目标: $VD"

fail=0
ok()   { echo "  OK   $1"; }
bad()  { echo "  FAIL $1" >&2; fail=$((fail + 1)); }

[ -f "$VD/lib/charts.js" ] || die "缺少 lib/charts.js（上游结构已变）"
[ -f "$VD/index.js" ] || die "缺少 index.js"
[ -f "$VD/lib/widgets.js" ] || die "缺少 lib/widgets.js"

# 1) charts API
for sym in 'kpi(' 'card(' 'empty('; do
	if grep -qF "$sym" "$VD/lib/charts.js"; then ok "charts.js 提供 $sym"; else bad "charts.js 缺少 $sym"; fi
done

# 2) collectSections 的 null 过滤（我们隐藏卡片的机制）
if grep -qF 'found[slot]' "$VD/index.js" && grep -qF '!=null' "$VD/index.js"; then
	ok "index.js 仍用 found[slot] + !=null 过滤"
else
	bad "index.js 的部件收集/过滤逻辑已变（node=null 隐藏机制会失效）"
fi

# 3) widgets 语义
for sym in 'available' 'defaults' 'slots'; do
	if grep -qF "$sym" "$VD/lib/widgets.js"; then ok "widgets.js 含 $sym"; else bad "widgets.js 缺少 $sym"; fi
done

# 4) 官方 include 的 widget id
REQ_CARDS="internet uptime cpu memory dhcp wifi"
REQ_CHARTS="wan system distribution signal traffic"
REQ_TABS="internet system resources dhcp wifi"

# 只取官方 include（排除我们自己的 99-sd-*），并兼容单/双引号与紧凑写法
IDS=$(cat "$VD"/include/*.js 2>/dev/null \
	| grep -v 'sd-' \
	| grep -oE "id:['\"][a-z-]+['\"],slot:['\"][a-z]+['\"]" \
	| sed "s/.*id:['\"]\([a-z-]*\)['\"],slot:['\"]\([a-z]*\)['\"].*/\2:\1/" \
	| sort -u)

missing=""
for id in $REQ_CARDS; do
	echo "$IDS" | grep -qx "cards:$id" || missing="$missing cards:$id"
done
for id in $REQ_CHARTS; do
	echo "$IDS" | grep -qx "charts:$id" || missing="$missing charts:$id"
done
for id in $REQ_TABS; do
	echo "$IDS" | grep -qx "tabs:$id" || missing="$missing tabs:$id"
done

if [ -z "$missing" ]; then
	ok "官方部件 id 齐全（cards/charts/tabs 共 16 个）"
else
	bad "官方部件 id 缺失:$missing"
	echo "       实际获取到:" >&2
	echo "$IDS" | sed 's/^/         /' >&2
fi

# 5) 打印上游版本，便于回溯漂移
if [ -d "${ROOT:-}/feeds/luci/.git" ]; then
	ver=$(git -C "$ROOT/feeds/luci" describe --always --tags 2>/dev/null || true)
	[ -n "$ver" ] && echo "  上游 luci feed: $ver"
fi

if [ "$fail" -ne 0 ]; then
	echo "RESULT: FAIL（$fail 项不满足，先适配再编译）" >&2
	exit 1
fi

echo "RESULT: OK"
