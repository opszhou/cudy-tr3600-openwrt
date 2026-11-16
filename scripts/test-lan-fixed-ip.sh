#!/usr/bin/env bash
# lan-fixed-ip 的沙箱测试：用桩 uci / ip / logger / init.d 真实执行 CLI 与热插拔钩子，
# 断言「末位固定、网段跟随、多规则、冲突替换、静默退出」都成立。
# 用法: bash scripts/test-lan-fixed-ip.sh   （无参数；临时目录自清理）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/common/files/usr/sbin/lan-fixed-ip"
HOOK="$ROOT/common/files/etc/hotplug.d/iface/99-lan-fixed-ip"
CONF_SRC="$ROOT/common/files/etc/config/lan-fixed-ip.conf"
ASSEMBLE="$ROOT/scripts/assemble.sh"

for f in "$CLI" "$HOOK" "$CONF_SRC"; do
	[ -f "$f" ] || { echo "FAIL: 找不到 $f" >&2; exit 1; }
done

mkdir -p "$ROOT/.workbuddy/tmp"
SB=$(mktemp -d "$ROOT/.workbuddy/tmp/lan-fixed-ip-test.XXXXXX")
trap 'rm -rf "$SB"' EXIT

pass=0; fail=0
ok()   { echo "  ✓ $1"; pass=$((pass + 1)); }
bad()  { echo "  ✗ $1" >&2; fail=$((fail + 1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: 期望 [$3]，实际 [$2]"; fi; }

mkdir -p "$SB/bin" "$SB/etc"
STATE="$SB/dhcp.state"
COMMITS="$SB/commit.log"
RELOADS="$SB/reload.log"
CONF="$SB/lan-fixed-ip.conf"
LEASES="$SB/dhcp.leases"
: > "$COMMITS"; : > "$RELOADS"

# ---- 桩 uci：只实现被测代码用到的子集 -------------------------------------
# 状态存 5 列：段名 mac name ip leasetime
cat > "$SB/bin/uci" <<'STUB'
#!/bin/sh
ST="$FAKE_DHCP_STATE"
if [ "$1" = "-q" ]; then shift; fi
cmd=$1; shift || true

field_of() { awk -v s="$1" -v n="$2" '$1==s { print $n }' "$ST"; }

case "$cmd" in
get)
	key=$1
	case "$key" in
	network.lan.ipaddr)
		[ -n "${FAKE_NET_IP:-}" ] || exit 1
		printf '%s\n' "$FAKE_NET_IP" ;;
	network.lan.device)
		[ -n "${FAKE_NET_DEV:-}" ] || exit 1
		printf '%s\n' "$FAKE_NET_DEV" ;;
	dhcp.*)
		rest=${key#dhcp.}; sec=${rest%%.*}; opt=${rest#*.}
		[ -f "$ST" ] || exit 1
		case "$opt" in
		mac) v=$(field_of "$sec" 2) ;;
		name) v=$(field_of "$sec" 3) ;;
		ip) v=$(field_of "$sec" 4) ;;
		leasetime) v=$(field_of "$sec" 5) ;;
		*) v="" ;;
		esac
		[ -n "$v" ] || exit 1
		printf '%s\n' "$v" ;;
	*) exit 1 ;;
	esac
	;;
show)
	[ -f "$ST" ] || exit 0
	awk 'NF { printf "dhcp.%s=host\n", $1 }' "$ST"
	;;
add)
	[ "$1" = "dhcp" ] && [ "$2" = "host" ] || exit 1
	[ -f "$ST" ] || : > "$ST"
	# 段名必须单调递增、绝不复用：真实 uci 删段后新增也不会撞名，
	# 用「当前行数 + 1」会在删过段之后与存活段撞名，测出来的全是假失败。
	cnt="$ST.cnt"
	[ -f "$cnt" ] || : > "$cnt"
	n=$(cat "$cnt" 2>/dev/null)
	[ -n "$n" ] || n=0
	n=$((n + 1))
	echo "$n" > "$cnt"
	sec=$(printf 'cfg%06d' "$n")
	printf '%s - - - -\n' "$sec" >> "$ST"
	printf '%s\n' "$sec"
	;;
set)
	kv=$1
	rest=${kv#dhcp.}; sec=${rest%%.*}; rest=${rest#*.}
	opt=${rest%%=*}; val=${rest#*=}
	[ -f "$ST" ] || exit 1
	awk -v s="$sec" -v o="$opt" -v v="$val" '
	BEGIN { FS = " "; OFS = " " }
	$1 == s {
		if (o == "mac") $2 = v
		else if (o == "name") $3 = v
		else if (o == "ip") $4 = v
		else if (o == "leasetime") $5 = v
	}
	{ print }
	' "$ST" > "$ST.tmp" && mv "$ST.tmp" "$ST"
	;;
delete)
	key=$1
	rest=${key#dhcp.}; sec=${rest%%.*}
	[ -f "$ST" ] || exit 1
	awk -v s="$sec" '$1 != s' "$ST" > "$ST.tmp" && mv "$ST.tmp" "$ST"
	;;
commit)
	echo "$*" >> "$FAKE_DHCP_COMMITS"
	;;
*)
	exit 1
	;;
esac
STUB

cat > "$SB/bin/ip" <<'STUB'
#!/bin/sh
[ -n "${FAKE_DEV_ADDR:-}" ] || exit 1
printf '3: %s    inet %s/24 brd 192.168.5.255 scope global %s\\       valid_lft forever\n' \
	"${FAKE_DEV_NAME:-br-lan}" "$FAKE_DEV_ADDR" "${FAKE_DEV_NAME:-br-lan}"
STUB

cat > "$SB/bin/logger" <<'STUB'
#!/bin/sh
exit 0
STUB

cat > "$SB/etc/dnsmasq" <<'STUB'
#!/bin/sh
case "$1" in
running) exit 0 ;;
reload) echo reload >> "$FAKE_DNSMASQ_RELOADS"; exit 0 ;;
esac
exit 0
STUB

chmod +x "$SB/bin/uci" "$SB/bin/ip" "$SB/bin/logger" "$SB/etc/dnsmasq"

export PATH="$SB/bin:$PATH"
export FAKE_DHCP_STATE="$STATE" FAKE_DHCP_COMMITS="$COMMITS" FAKE_DNSMASQ_RELOADS="$RELOADS"
export LAN_FIXED_CONF="$CONF" LAN_FIXED_DNSMASQ_INIT="$SB/etc/dnsmasq" LAN_FIXED_LEASES="$LEASES"
export LAN_FIXED_CLI="$CLI"

MAC_A='aa:bb:cc:dd:ee:01'
MAC_B='aa:bb:cc:dd:ee:02'
MAC_C='aa:bb:cc:dd:ee:99'

run()      { "$CLI" "$@"; }
hook_run() { ACTION="${1:-ifup}" INTERFACE="${2:-lan}" "$HOOK"; }

reset_state() {
	: > "$STATE"; : > "$COMMITS"; : > "$RELOADS"; : > "$LEASES"
	rm -f "$CONF" "$STATE.cnt"
	FAKE_NET_IP="192.168.5.1"; FAKE_NET_DEV=""; FAKE_DEV_ADDR=""
	export FAKE_NET_IP FAKE_NET_DEV FAKE_DEV_ADDR
}

rules() { if [ -f "$CONF" ]; then grep -vc '^[[:space:]]*#' "$CONF" || true; else echo 0; fi; }
rows()  { if [ -f "$STATE" ]; then awk 'NF{n++} END{printf "%d", n+0}' "$STATE"; else echo 0; fi; }
ip_of() { awk -v m="$1" '$2==m { print $4 }' "$STATE"; }

echo "== 静态检查 =="
sh -n "$CLI"  && ok "CLI shell 语法"  || bad "CLI shell 语法"
sh -n "$HOOK" && ok "钩子 shell 语法" || bad "钩子 shell 语法"
grep -q 'etc/hotplug.d' "$ASSEMBLE" \
	&& ok "assemble.sh 的可执行位兜底包含 hotplug.d" \
	|| bad "assemble.sh 的可执行位兜底没覆盖 hotplug.d（进镜像 644，钩子不执行）"
grep -q 'usr/sbin' "$ASSEMBLE" \
	&& ok "assemble.sh 的可执行位兜底包含 usr/sbin" \
	|| bad "assemble.sh 的可执行位兜底没覆盖 usr/sbin（CLI 进镜像不可执行）"
if grep -qE '^[[:space:]]*[0-9]+[[:space:]]+([0-9a-f]{2}:){5}[0-9a-f]{2}' "$CONF_SRC"; then
	bad "仓库规则文件里不该有实际 MAC（硬件身份不进仓库）"
else
	ok "仓库规则文件不含任何实际规则"
fi

echo "== add 一条规则 =="
reset_state
out=$(run add "$MAC_A" 10 armbian)
check "创建 1 条 host 段" "$(rows)" "1"
check "地址落在 .10" "$(ip_of "$MAC_A")" "192.168.5.10"
check "主机名" "$(awk 'NF{print $3}' "$STATE")" "armbian"
check "租期无限" "$(awk 'NF{print $5}' "$STATE")" "infinite"
case "$out" in *192.168.5.10*) ok "命令回显含目标地址" ;; *) bad "命令回显不含目标地址：$out" ;; esac

echo "== 再加一条（多规则）=="
run add "$MAC_B" 20 nas >/dev/null
check "两条 host 段" "$(rows)" "2"
check "第二条落在 .20" "$(ip_of "$MAC_B")" "192.168.5.20"
check "规则文件两条" "$(rules)" "2"

echo "== 换网段后全部跟随 =="
FAKE_NET_IP="10.7.0.1"; export FAKE_NET_IP
run sync
check "A 跟随到 10.7.0.10" "$(ip_of "$MAC_A")" "10.7.0.10"
check "B 跟随到 10.7.0.20" "$(ip_of "$MAC_B")" "10.7.0.20"
check "段数不变" "$(rows)" "2"

echo "== 幂等：网段没变不重复 commit =="
before=$(wc -l < "$COMMITS" | tr -d ' ')
run sync
check "没有多余提交" "$(wc -l < "$COMMITS" | tr -d ' ')" "$before"

echo "== 冲突替换 =="
run add "$MAC_C" 10 newbox >/dev/null
check "同末位只留一条规则" "$(rules)" "2"
check "末位 10 换成了新 MAC" "$(awk '$1==10 {print $2}' "$CONF")" "$MAC_C"
check "旧 MAC 的段已不存在" "$(ip_of "$MAC_A")" ""

echo "== del =="
run del 20 >/dev/null
check "按末位删掉规则" "$(rules)" "1"
check "对应 host 段也删了" "$(rows)" "1"
run del "$MAC_C" >/dev/null
check "按 MAC 删规则" "$(rules)" "0"
check "host 段清空" "$(rows)" "0"

echo "== --from-lease =="
reset_state
printf '1795000000 %s 192.168.5.177 armbian 01:%s\n' "$MAC_A" "$MAC_A" > "$LEASES"
run add --from-lease armbian 10 >/dev/null
check "从主机名查出 MAC 并建规则" "$(ip_of "$MAC_A")" "192.168.5.10"
run del 10 >/dev/null
run add --from-lease 192.168.5.177 30 >/dev/null
check "从当前 IP 查出 MAC" "$(ip_of "$MAC_A")" "192.168.5.30"

echo "== 非法输入被拒绝 =="
if run add "zz:bb:cc:dd:ee:ff" 10 >/dev/null 2>&1; then bad "非法 MAC 应被拒绝"; else ok "非法 MAC 被拒绝"; fi
if run add "$MAC_A" 0   >/dev/null 2>&1; then bad "末位 0 应被拒绝"; else ok "末位 0 被拒绝"; fi
if run add "$MAC_A" 255 >/dev/null 2>&1; then bad "末位 255 应被拒绝"; else ok "末位 255 被拒绝"; fi
if run add "$MAC_A" abc >/dev/null 2>&1; then bad "末位非数字应被拒绝"; else ok "末位非数字被拒绝"; fi

echo "== 前缀未知时安静退出 =="
reset_state
FAKE_NET_IP=""; FAKE_NET_DEV=""; FAKE_DEV_ADDR=""
export FAKE_NET_IP FAKE_NET_DEV FAKE_DEV_ADDR
printf '10 %s box\n' "$MAC_A" > "$CONF"
run sync
check "不建任何段" "$(rows)" "0"

echo "== 回退到接口实际地址 =="
FAKE_NET_DEV="br-lan"; FAKE_DEV_ADDR="172.16.8.1"
export FAKE_NET_DEV FAKE_DEV_ADDR
run sync
check "从 br-lan 实际地址推导" "$(ip_of "$MAC_A")" "172.16.8.10"

echo "== 热插拔钩子的触发面 =="
reset_state
printf '10 %s box\n' "$MAC_A" > "$CONF"
hook_run ifdown lan
check "ifdown 不动作" "$(rows)" "0"
hook_run ifup wan
check "非 lan 接口不动作" "$(rows)" "0"
hook_run ifup lan
check "lan ifup 生效" "$(ip_of "$MAC_A")" "192.168.5.10"

echo "== list =="
if run list | grep -q "192.168.5.10"; then ok "list 显示当前地址"; else bad "list 没显示当前地址"; fi

echo
if [ "$fail" -eq 0 ]; then
	echo "全部通过：$pass 项"
	exit 0
else
	echo "失败 $fail 项 / 通过 $pass 项" >&2
	exit 1
fi
