#!/usr/bin/env bash
# 沙箱验证 filogic 的 02_network：给定 board 名，断言 LAN/WAN 端口映射。
#
# 为什么要有这个：02_network 是 board.d 里唯一"写错了也能编过"的东西——
# 编译期完全看不出来，只有刷进机器才发现网口全反/wan 不存在。这里用 stub 把
# ucidef_* 换掉，直接跑真文件里的 case 分支。
#
# 用法: test-02network.sh <path/to/02_network> <board> [期望LAN] [期望WAN]
#   例: test-02network.sh .../02_network fzs,5gcpe-p3 "lan1 lan2" wan
set -euo pipefail

FILE="${1:?用法: test-02network.sh <02_network> <board> [lan] [wan]}"
BOARD="${2:?缺少 board 名（device tree 的 compatible[0]）}"
EXPECT_LAN="${3:-}"
EXPECT_WAN="${4:-}"

[ -f "$FILE" ] || { echo "错误: 找不到 $FILE" >&2; exit 1; }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/lib/functions"

# ---- stub: /lib/functions.sh（board_name / 配置框架）----
cat >"$SB/lib/functions.sh" <<'EOF'
board_name() { echo "${BOARD_NAME:-unknown}"; }
config_load() { :; }
config_get() { :; }
config_set() { :; }
EOF
# 02_network 里用到的网络/MAC 辅助函数统一 stub 掉
cat >"$SB/lib/functions/system.sh" <<'EOF'
mtd_get_mac_ascii() { echo ""; }
mtd_get_mac_binary() { echo ""; }
macaddr_add() { echo "${1:-}"; }
get_mac_binary() { echo ""; }
EOF
# ---- stub: ucidef_* 全部改成"打印断言用的一行" ----
cat >"$SB/lib/functions/uci-defaults.sh" <<'EOF'
ucidef_set_interfaces_lan_wan() {
	printf 'LAN_WAN|%s|%s\n' "${1:-}" "${2:-}"
}
ucidef_set_interfaces_lan_wan_bridge() { ucidef_set_interfaces_lan_wan "$@"; }
ucidef_set_interface_lan() { printf 'LAN_ONLY|%s|\n' "${1:-}"; }
ucidef_set_interface_wan() { printf 'WAN_ONLY||%s\n' "${1:-}"; }
ucidef_set_interface_macaddr() { :; }
ucidef_set_label_macaddr() { :; }
ucidef_set_interface() { :; }
ucidef_add_switch() { :; }
ucidef_add_switch_attr() { :; }
ucidef_add_switch_attr_if_exists() { :; }
ucidef_add_switch_port() { :; }
board_config_update() { :; }
board_config_flush() { :; }
EOF

# 把文件里的绝对 source 路径改到沙箱（原文件是 . /lib/...）
sed -e "s|^\. /lib/|\. $SB/lib/|" "$FILE" >"$SB/02_network"

OUT="$(BOARD_NAME="$BOARD" sh "$SB/02_network" 2>&1 || true)"
echo "board: $BOARD"
echo "输出:"
echo "$OUT" | sed 's/^/  /'

fail=0
if [ -n "$EXPECT_LAN" ]; then
	if ! echo "$OUT" | grep -qxF "LAN_WAN|$EXPECT_LAN|$EXPECT_WAN"; then
		echo "FAIL: 期望 LAN_WAN|$EXPECT_LAN|$EXPECT_WAN 未出现" >&2
		fail=1
	fi
fi
if [ "$fail" -ne 0 ]; then
	echo "RESULT: FAIL" >&2
	exit 1
fi
echo "RESULT: OK"
