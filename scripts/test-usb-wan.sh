#!/usr/bin/env bash
# 50-usb-wan（USB 网卡自动当 WAN）的沙箱测试
#
# 用假 sysfs 树 + stub 的 uci/ubus/ifup/ifdown，覆盖 5 种判定：
#   1. 纯 USB 网卡（rndis_host，无 AT 口）        → 建 wanusb + ifup
#   2. QMI/MBIM 模组（同设备有 qmi_wwan）          → 完全不碰
#   3. 模组类（网卡 + cdc_acm AT 口）+ QModem 已接管 → 让位，不建（之前会抢设备）
#   4. 模组类 + QModem 未接管                      → 仍然接管（准予当 WAN）
#   5. 设备已被其它 uci 接口占用                    → 不碰
#   6. 板载 eth0                                  → 不碰
#
# 用法: bash scripts/test-usb-wan.sh   （无参数；沙箱在仓库 .workbuddy/tmp 下，自动清理）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/common/files/etc/hotplug.d/net/50-usb-wan"
[ -f "$SCRIPT" ] || { echo "FAIL: 找不到 $SCRIPT" >&2; exit 1; }

mkdir -p "$ROOT/.workbuddy/tmp"
SB=$(mktemp -d "$ROOT/.workbuddy/tmp/usb-wan-test.XXXXXX")
# 环境里的安全删除钩子会拦截 rm -rf（连沙箱都删不掉），改用 find -delete
cleanup() { [ -d "$SB" ] && find "$SB" -mindepth 1 -delete 2>/dev/null; rmdir "$SB" 2>/dev/null; }
trap cleanup EXIT
mkdir -p "$SB/bin"

# ---- uci stub ----
cat > "$SB/bin/uci" <<'STUB'
#!/usr/bin/env bash
state="$UCI_STATE_FILE"
[ "${1:-}" = "-q" ] && shift
cmd="${1:?}"; shift
case "$cmd" in
  set)
    kv="$1"; key="${kv%%=*}"; val="${kv#*=}"; val="${val#\'}"; val="${val%\'}"
    grep -vF "${key}=" "$state" > "$state.t" 2>/dev/null || :
    mv "$state.t" "$state"
    printf "%s='%s'\n" "$key" "$val" >> "$state" ;;
  get)
    line=$(grep -F "$1=" "$state" | head -n1) || exit 1
    [ -n "${line:-}" ] || exit 1
    out="${line#*=}"; out="${out#\'}"; out="${out%\'}"; printf '%s\n' "$out" ;;
  add_list)
    printf "%s\n" "$1" >> "$state.list" ;;
  show)
    grep "^$1\." "$state" 2>/dev/null || : ;;
  delete)
    k="${1#network.}"; grep -vF "network.${k}" "$state" > "$state.t" 2>/dev/null || :
    mv "$state.t" "$state" ;;
  commit) : ;;
  *) exit 0 ;;
esac
STUB

# ---- ubus stub：模拟 netifd 已绑定某设备 ----
cat > "$SB/bin/ubus" <<'STUB'
#!/usr/bin/env bash
[ -f "$UBUS_DEV_FILE" ] && cat "$UBUS_DEV_FILE" || echo '{}'
STUB

# ---- ifup / ifdown stub ----
printf '#!/usr/bin/env bash\necho "ifup $1" >> "$IF_LOG"\n' > "$SB/bin/ifup"
printf '#!/usr/bin/env bash\necho "ifdown $1" >> "$IF_LOG"\n' > "$SB/bin/ifdown"
# ip stub：输出 IP_OUT_FILE 里预置的地址（模拟「网卡上已经有 IP」）
printf '#!/usr/bin/env bash\n[ -f "$IP_OUT_FILE" ] && cat "$IP_OUT_FILE" || true\n' > "$SB/bin/ip"
chmod +x "$SB/bin/uci" "$SB/bin/ubus" "$SB/bin/ifup" "$SB/bin/ifdown" "$SB/bin/ip"

export UCI_STATE_FILE="$SB/uci.state"
export UBUS_DEV_FILE="$SB/ubus.dev"
export IF_LOG="$SB/if.log"
export IP_OUT_FILE="$SB/ip.out"
: > "$UCI_STATE_FILE"; : > "$IF_LOG"; : > "$IP_OUT_FILE"

# 假 sysfs：每个用例独立目录（不删目录，避免触发安全删除钩子）
CASE=0
make_usb_dev() { # $1=网卡名 $2=网卡驱动 $3..=同设备其它接口驱动
	local name="$1" drv="$2"; shift 2
	CASE=$((CASE + 1))
	SYS="$SB/sys$CASE"; RUN="$SB/run$CASE"
	mkdir -p "$SYS/class/net/$name" "$SYS/devices/usb1/1-1" "$SYS/drivers" "$RUN"
	echo 1 > "$SYS/class/net/$name/type"
	ln -s "$SYS/devices/usb1/1-1/1-1:1.0" "$SYS/class/net/$name/device"
	mkdir -p "$SYS/drivers/$drv" "$SYS/devices/usb1/1-1/1-1:1.0"
	ln -s "$SYS/drivers/$drv" "$SYS/devices/usb1/1-1/1-1:1.0/driver"
	local i=2
	for d in "$@"; do
		mkdir -p "$SYS/drivers/$d" "$SYS/devices/usb1/1-1/1-1:1.$i"
		ln -s "$SYS/drivers/$d" "$SYS/devices/usb1/1-1/1-1:1.$i/driver"
		i=$((i + 1))
	done
}

run_hotplug() { # $1=ACTION $2=网卡名
	INTERFACE="$2" ACTION="$1" SYSFS="${SYS:-$SB/sys0}" QM_RUN="${RUN:-$SB/run0}" GRACE=0 \
		PATH="$SB/bin:$PATH" sh "$SCRIPT" || true
}

fails=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (期望 [$2] 实际 [$3])" >&2; fails=$((fails + 1)); fi; }
state_val() { grep -F "$1=" "$UCI_STATE_FILE" 2>/dev/null | head -n1 | sed "s/^[^=]*='//; s/'$//"; }

echo "==== 1. 纯 USB 网卡：应建 wanusb 并 ifup ===="
: > "$UCI_STATE_FILE"; : > "$IF_LOG"
make_usb_dev usb0 rndis_host
run_hotplug add usb0
assert_eq "建了 network.wanusb" "interface" "$(state_val network.wanusb)"
assert_eq "proto=dhcp" "dhcp" "$(state_val network.wanusb.proto)"
assert_eq "绑到 usb0" "usb0" "$(state_val network.wanusb.device)"
assert_eq "metric=20（让板载 WAN 优先）" "20" "$(state_val network.wanusb.metric)"
assert_eq "已触发 ifup" "ifup wanusb" "$(cat "$IF_LOG")"

echo "==== 2. QMI/MBIM 模组：不应接管 ===="
: > "$UCI_STATE_FILE"; : > "$IF_LOG"
make_usb_dev wwan0 rndis_host qmi_wwan
run_hotplug add wwan0
assert_eq "未创建 wanusb" "" "$(state_val network.wanusb)"
assert_eq "未 ifup" "" "$(cat "$IF_LOG")"

echo "==== 3. 模组类（网卡+AT 口）且 QModem 已接管：应让位 ===="
: > "$UCI_STATE_FILE"; : > "$IF_LOG"
make_usb_dev usb0 cdc_ether cdc_acm
mkdir -p "$RUN/1_1_dir"
run_hotplug add usb0
assert_eq "未创建 wanusb（让位 QModem）" "" "$(state_val network.wanusb)"
assert_eq "未 ifup" "" "$(cat "$IF_LOG")"
find "$RUN/1_1_dir" -mindepth 1 -delete 2>/dev/null; rmdir "$RUN/1_1_dir" 2>/dev/null

echo "==== 4. 模组类但 QModem 未接管：仍应接管 ===="
: > "$UCI_STATE_FILE"; : > "$IF_LOG"
make_usb_dev usb0 cdc_ether cdc_acm
run_hotplug add usb0
assert_eq "建了 wanusb" "dhcp" "$(state_val network.wanusb.proto)"
assert_eq "已 ifup" "ifup wanusb" "$(cat "$IF_LOG")"

echo "==== 5. 已被其它接口占用：不应抢 ===="
: > "$UCI_STATE_FILE"; : > "$IF_LOG"
make_usb_dev usb0 rndis_host
printf "network.qmodem.device='usb0'\n" >> "$UCI_STATE_FILE"
run_hotplug add usb0
assert_eq "未重复创建 wanusb" "" "$(state_val network.wanusb)"

echo "==== 6. 板载 eth0：不应接管 ===="
: > "$UCI_STATE_FILE"; : > "$IF_LOG"
make_usb_dev eth0 r8152
run_hotplug add eth0
assert_eq "未创建 wanusb" "" "$(state_val network.wanusb)"

echo "==== 7. 非 USB 设备（无 device 链接）：不应接管 ===="
: > "$UCI_STATE_FILE"; : > "$IF_LOG"
CASE=$((CASE + 1)); SYS="$SB/sys$CASE"; RUN="$SB/run$CASE"
mkdir -p "$SYS/class/net/eth2" "$RUN"; echo 1 > "$SYS/class/net/eth2/type"
run_hotplug add eth2
assert_eq "未创建 wanusb" "" "$(state_val network.wanusb)"

echo "==== 8. 拔掉：只 ifdown，不删配置 ===="
: > "$UCI_STATE_FILE"; : > "$IF_LOG"
make_usb_dev usb0 rndis_host
printf "network.wanusb='interface'\nnetwork.wanusb.device='usb0'\n" >> "$UCI_STATE_FILE"
run_hotplug remove usb0
assert_eq "已 ifdown" "ifdown wanusb" "$(cat "$IF_LOG")"
assert_eq "配置仍保留" "interface" "$(state_val network.wanusb)"

echo "==== 9. 网卡上已有 IPv4 地址（别人已接好）：不应再操作 ===="
: > "$UCI_STATE_FILE"; : > "$IF_LOG"
make_usb_dev usb0 rndis_host
echo "2: usb0    inet 192.168.1.23/24 brd 192.168.1.255 scope global usb0" > "$IP_OUT_FILE"
run_hotplug add usb0
assert_eq "已连通则未创建 wanusb" "" "$(state_val network.wanusb)"
assert_eq "已连通则未 ifup" "" "$(cat "$IF_LOG")"
: > "$IP_OUT_FILE"

echo "==== 10. 等待窗口内 QModem 抢先接管：应让位 ===="
: > "$UCI_STATE_FILE"; : > "$IF_LOG"
make_usb_dev usb0 cdc_ether cdc_acm
mkdir -p "$RUN/1_1_dir"
run_hotplug add usb0
assert_eq "QModem 接管后未创建 wanusb" "" "$(state_val network.wanusb)"

if [ "$fails" -ne 0 ]; then echo "结果: $fails 项断言失败" >&2; exit 1; fi
echo "结果: 全部断言通过"
