#!/usr/bin/env bash
# luci-app-sysdashboard 的沙箱冒烟测试：注入假的 /proc、/sys、DHCP 租约，
# 真实执行 rpcd 脚本，断言输出是合法 JSON 且字段/降级行为正确。
# 用法: bash scripts/test-sysdashboard.sh   （无参数；临时目录自清理）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/common/package/luci-app-sysdashboard"
RPCD="$PKG/root/usr/libexec/rpcd/sysdashboard"
# 独立页面已删除，只剩管理面板部件：入口 include + sd/*.js
JS="$PKG/htdocs/luci-static/resources/view/dashboard/include/50-cellular.js"
SD_DIR="$PKG/htdocs/luci-static/resources/view/dashboard/sd"
PY="${PYTHON:-$(command -v python3 || command -v python)}"

[ -f "$RPCD" ] || { echo "FAIL: 找不到 rpcd 脚本 $RPCD" >&2; exit 1; }
[ -f "$JS" ] || { echo "FAIL: 找不到入口部件 $JS" >&2; exit 1; }
[ -d "$SD_DIR" ] || { echo "FAIL: 找不到 sd 模块目录 $SD_DIR" >&2; exit 1; }

mkdir -p "$ROOT/.workbuddy/tmp"
SB=$(mktemp -d "$ROOT/.workbuddy/tmp/sysdashboard-test.XXXXXX")
trap 'rm -rf "$SB"' EXIT

pass=0; fail=0
ok()   { echo "  ✓ $1"; pass=$((pass+1)); }
bad()  { echo "  ✗ $1" >&2; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: 期望 $3，实际 $2"; fi; }

echo "== 静态检查 =="
sh -n "$RPCD" && ok "rpcd 脚本 shell 语法" || bad "rpcd 脚本 shell 语法"
if [ -x "$RPCD" ]; then ok "rpcd 脚本带可执行位"; else bad "rpcd 脚本缺可执行位（固件里 rpcd 不会加载它）"; fi
grep -qF 'include $(TOPDIR)/feeds/luci/luci.mk' "$PKG/Makefile" \
	&& ok "Makefile 指向 feed 里的 luci.mk" || bad "Makefile 的 luci.mk 路径不对"
if command -v node >/dev/null 2>&1; then
	node --check "$JS" >/dev/null 2>&1 && ok "入口部件 JS 语法" || bad "入口部件 JS 语法"
	for f in "$SD_DIR"/*.js; do
		node --check "$f" >/dev/null 2>&1 && ok "sd 模块语法: $(basename "$f")" || bad "sd 模块语法: $(basename "$f")"
	done
else
	echo "  · 跳过 JS 语法检查（本机无 node）"
fi
"$PY" - "$PKG" <<'PYEOF'
import json, sys, os
pkg = sys.argv[1]
for rel in ("root/usr/share/rpcd/acl.d/luci-app-sysdashboard.json",):
    with open(os.path.join(pkg, rel), encoding="utf-8") as f:
        json.load(f)
    print("  ✓ JSON 合法: " + rel)
PYEOF

echo
echo "== rpcd 协议 =="
LIST_OUT=$(SYSDASH_PROC_DIR="$SB/proc" SYSDASH_SYS_DIR="$SB/sys" "$RPCD" list)
check "list 返回方法签名" "$LIST_OUT" '{"get":{}}'

# ---- 构造全量假数据 ----
mkdir -p "$SB/proc/net" "$SB/proc/sys/net/netfilter" \
         "$SB/sys/class/thermal/thermal_zone0" \
         "$SB/sys/class/thermal/cooling_device0" \
         "$SB/sys/class/hwmon/hwmon0"
printf '123456.78 98765.43\n' > "$SB/proc/uptime"
printf '0.12 0.34 0.56 1/120 9999\n' > "$SB/proc/loadavg"
printf 'cpu  1000 20 300 5000 100 0 0 0 0\ncpu0 500 10 150 2500 50 0 0 0 0\n' > "$SB/proc/stat"
cat > "$SB/proc/meminfo" <<'EOF'
MemTotal:         512000 kB
MemFree:          120000 kB
MemAvailable:     300000 kB
Buffers:           20000 kB
Cached:           150000 kB
SwapTotal:             0 kB
EOF
cat > "$SB/proc/net/dev" <<'EOF'
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 999 9 0 0 0 0 0 0 888 8 0 0 0 0 0 0
 br-lan: 1000000 100 0 0 0 0 0 0 500000 50 0 0 0 0 0 0
  eth1: 2000000 200 0 0 0 0 0 0 700000 70 0 0 0 0 0 0
EOF
printf '998\n' > "$SB/proc/sys/net/netfilter/nf_conntrack_count"
printf '52300\n' > "$SB/sys/class/thermal/thermal_zone0/temp"
printf 'cpu_thermal\n' > "$SB/sys/class/thermal/thermal_zone0/type"
printf 'pwm-fan\n' > "$SB/sys/class/thermal/cooling_device0/type"
printf '2\n' > "$SB/sys/class/thermal/cooling_device0/cur_state"
printf '4\n' > "$SB/sys/class/thermal/cooling_device0/max_state"
printf 'pwmfan\n' > "$SB/sys/class/hwmon/hwmon0/name"
printf '3200\n' > "$SB/sys/class/hwmon/hwmon0/fan1_input"
printf '128\n' > "$SB/sys/class/hwmon/hwmon0/pwm1"
cat > "$SB/leases" <<'EOF'
1762350000 aa:bb:cc:dd:ee:01 192.168.10.101 nas 01:aa:bb:cc:dd:ee:01
1762350001 aa:bb:cc:dd:ee:02 192.168.10.102 "phone\evil" 01:aa:bb:cc:dd:ee:02
EOF

# 假 ip：默认路由两条（验证取最小 metric）+ wwan0 地址
mkdir -p "$SB/bin"
cat > "$SB/bin/ip" <<'EOS'
#!/bin/sh
case "$*" in
  "-4 route") printf 'default via 10.186.203.87 dev wwan0 metric 11 \ndefault via 192.168.5.254 dev br-lan metric 20 \n' ;;
  "-6"*) : ;;
  *"addr show dev wwan0"*) printf '7: wwan0    inet 10.186.203.86/8 brd 10.255.255.255 scope global wwan0\\       valid_lft forever preferred_lft forever\n' ;;
  *) : ;;
esac
EOS
# 假 ubus：模拟 qmodem cell_info 的真实输出结构（key 一行、value 一行）
cat > "$SB/bin/ubus" <<'EOS'
#!/bin/sh
cat <<'JSON'
{
	"modem_info": [
		{
			"key": "Network Type",
			"value": "FDD LTE"
		},
		{
			"key": "MCC",
			"value": "460"
		},
		{
			"key": "MNC",
			"value": "01"
		},
		{
			"key": "Duplex Mode",
			"value": "FDD"
		},
		{
			"key": "network_mode",
			"value": "LTE Mode"
		},
		{
			"key": "RSRP",
			"value": "-89"
		},
		{
			"key": "RSRQ",
			"value": "-10"
		},
		{
			"key": "SINR",
			"value": "20"
		},
		{
			"key": "RSSI",
			"value": "-60"
		},
		{
			"key": "Cell ID",
			"value": "DB9CA31"
		},
		{
			"key": "Physical Cell ID",
			"value": "210"
		},
		{
			"key": "EARFCN",
			"value": "1650"
		},
		{
			"key": "DL Bandwidth",
			"value": "20"
		}
	]
}
JSON
EOS
chmod +x "$SB/bin/ip" "$SB/bin/ubus"
# ARP：第一条与租约同一 MAC（验证去重），第二条只有 ARP（静态 IP 设备）
cat > "$SB/arp" <<'EOS'
IP address       HW type     Flags       HW address            Mask     Device
192.168.10.101   0x1         0x2         aa:bb:cc:dd:ee:01     *        br-lan
192.168.10.150   0x1         0x2         11:22:33:44:55:66     *        br-lan
EOS

OUT="$SB/full.json"
SYSDASH_PROC_DIR="$SB/proc" SYSDASH_SYS_DIR="$SB/sys" SYSDASH_LEASES_FILE="$SB/leases" \
	SYSDASH_ARP_FILE="$SB/arp" SYSDASH_IP_CMD="$SB/bin/ip" SYSDASH_UBUS_CMD="$SB/bin/ubus" \
	"$RPCD" call get > "$OUT"

if "$PY" - "$OUT" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
def eq(name, got, want):
    print(("  ✓ " if got == want else "  ✗ ") + name + " = " + repr(got) + ("" if got == want else " (期望 " + repr(want) + ")"))
    if got != want: sys.exit(1)
eq("uptime", d["uptime"], 123456)
eq("load", d["load"], [0.12, 0.34, 0.56])
eq("cpu.total", d["cpu"]["total"], 6420)
eq("cpu.idle", d["cpu"]["idle"], 5100)
eq("memory.total", d["memory"]["total"], 512000)
eq("memory.available", d["memory"]["available"], 300000)
eq("接口数(排除 lo)", len(d["traffic"]), 2)
eq("br-lan rx", d["traffic"][0]["rx"], 1000000)
eq("br-lan tx", d["traffic"][0]["tx"], 500000)
eq("租约数", len(d["leases"]), 2)
eq("恶意 hostname 被转义且 JSON 合法", d["leases"][1]["host"], "phoneevil")
eq("温度(millic)", d["thermal"][0]["millic"], 52300)
eq("风扇转速", d["fan"]["rpm"], 3200)
eq("风扇 PWM", d["fan"]["pwm"], 128)
eq("温控档位", d["fan"]["state"], 2)
eq("温控最大档", d["fan"]["state_max"], 4)
eq("连接数", d["conntrack"], 998)
eq("在线设备数(租约2+ARP新增1)", len(d["clients"]), 3)
eq("租约设备来源", d["clients"][0]["source"], "dhcp")
eq("ARP 设备来源", d["clients"][2]["source"], "arp")
eq("ARP 设备无主机名时用 IP", d["clients"][2]["host"], "192.168.10.150")
eq("ARP 与租约同 MAC 不重复", len([c for c in d["clients"] if c["mac"] == "aa:bb:cc:dd:ee:01"]), 1)
eq("上联已连接", d["uplink"]["connected"], True)
eq("上联取最小 metric 的接口", d["uplink"]["device"], "wwan0")
eq("上联网关", d["uplink"]["gateway"], "10.186.203.87")
eq("上联地址", d["uplink"]["ip"], "10.186.203.86/8")
eq("运营商识别", d["carrier"]["name"], "中国联通")
eq("运营商 key", d["carrier"]["key"], "unicom")
eq("运营商 MCC/MNC", [d["carrier"]["mcc"], d["carrier"]["mnc"]], ["460", "01"])
eq("caps.wan 可用", d["caps"]["wan"]["ok"], True)
eq("caps.clients 计数", d["caps"]["clients"]["count"], 3)
eq("caps 无 iw 时 wifi 不可用", d["caps"]["wifi"]["ok"], False)
eq("caps 无 qmodem 时 modem 不可用", d["caps"]["modem"]["ok"], False)
eq("cell 字段降级为空串", d["cell"]["band"], "")
eq("usage 无模组统计时为 0", [d["usage"]["rx"], d["usage"]["tx"]], [0, 0])
eq("usage 清零计划默认值", [d["usage"]["reset_enabled"], d["usage"]["reset_day"]], [False, 1])
eq("ipv6 无地址时为空串", d["ipv6"], "")
eq("信号 RSRP", d["signal"]["rsrp"], -89)
eq("信号 RSRQ", d["signal"]["rsrq"], -10)
eq("信号 SINR", d["signal"]["sinr"], 20)
eq("信号 RSSI", d["signal"]["rssi"], -60)
eq("信号制式", d["signal"]["mode"], "LTE Mode")
eq("信号双工", d["signal"]["duplex"], "FDD")
eq("小区 ID", d["signal"]["cell_id"], "DB9CA31")
eq("PCI", d["signal"]["pci"], "210")
eq("带宽", d["signal"]["bw"], "20")
assert d["ts"] > 0, "ts 应为正整数"
print("  ✓ ts 为正整数")
PYEOF
then
	pass=$((pass+1))
else
	fail=$((fail+1))
fi

echo
echo "== 全缺失降级（无风扇/无温度/无租约的设备）=="
mkdir -p "$SB/empty/proc" "$SB/empty/sys"
OUT2="$SB/empty.json"
SYSDASH_PROC_DIR="$SB/empty/proc" SYSDASH_SYS_DIR="$SB/empty/sys" SYSDASH_LEASES_FILE="$SB/empty/nope" \
	SYSDASH_ARP_FILE="$SB/empty/nope.arp" SYSDASH_IP_CMD="$SB/empty/no-ip" SYSDASH_UBUS_CMD="$SB/empty/no-ubus" \
	"$RPCD" call get > "$OUT2"
if "$PY" - "$OUT2" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["fan"]["rpm"] == -1 and d["fan"]["pwm"] == -1, "无风扇时必须为 -1（视图显示 N/A）"
assert d["thermal"] == [] and d["traffic"] == [] and d["leases"] == [], "缺失源必须为空数组"
assert d["conntrack"] == -1, "无 conntrack 文件时必须为 -1"
assert d["clients"] == [], "无租约且无 ARP 时 clients 必须为空数组"
assert d["uplink"]["connected"] is False, "无默认路由时 uplink.connected 必须为 false"
assert d["carrier"]["name"] == "", "无 ubus / 无模组时运营商名必须为空"
assert d["signal"]["rsrp"] == 0 and d["signal"]["mode"] == "", "无模组时信号字段必须降级"
assert isinstance(d["ts"], int), "ts 必须仍是整数"
print("  ✓ 空环境下仍输出合法 JSON，所有缺失项优雅降级")
PYEOF
then
	pass=$((pass+1))
else
	fail=$((fail+1))
fi

echo
echo "----------------------------------------"
echo "通过 $pass 项，失败 $fail 项"
[ "$fail" -eq 0 ] || exit 1
