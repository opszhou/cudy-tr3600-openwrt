#!/bin/sh
# 20-qmodem-apn-auto.sh —— 首启/每次开机给 QModem 的模组段自动补 APN（只补空的，不覆盖你手动设的）
#
# 为什么需要：QModem 的模组段是运行期扫描生成的，默认 APN 为空 → enable_dial=1 也不会真的拨号，
# 表现为 usb0 carrier=0、有地址或没地址都不一定。CM 类设备开箱应当自己认运营商。
#
# 做法：读 IMSI（AT+CIMI）→ MCC+MNC → 映射到国内三大运营商 APN → uci 写入 → 重启 qmodem_network。
# 不猜运营商之外的 APN；物联网卡/定向卡等特殊卡请手动：fzs-p3-set-apn <apn>
#
# 幂等：APN 非空就完全不动；AT 读不到就直接退出（不影响开机）。
# 日志：/etc/qmodem-apn-auto.log

LOG=/etc/qmodem-apn-auto.log
QMODEM=uci

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# ---- IMSI → APN ----
apn_from_imsi() {
	imsi="$1"
	[ -n "$imsi" ] || return 1
	mccmnc=$(echo "$imsi" | cut -c1-5)
	case "$mccmnc" in
		46000|46002|46004|46007|46008) echo cmnet ;;   # 中国移动
		46001|46006|46009)             echo 3gnet ;;   # 中国联通
		46003|46005|46011)             echo ctnet ;;   # 中国电信
		46015)                         echo ctwap  ;;   # 中国广电（部分卡）
		*) return 1 ;;
	esac
}

# 调试用：--print-apn <imsi>
if [ "${1:-}" = "--print-apn" ]; then
	apn_from_imsi "$2" || { echo "(未知运营商)"; exit 1; }
	exit 0
fi

# ---- 找模组段 ----
seg=$($QMODEM -q show qmodem 2>/dev/null | sed -n 's/^qmodem\.\([^.=]*\)=modem-device$/\1/p' | head -n1)
[ -n "$seg" ] || { log "没有 modem-device 段，跳过（模组还没被 QModem 扫描到）"; exit 0; }

cur_apn=$($QMODEM -q get "qmodem.$seg.apn" 2>/dev/null)
if [ -n "$cur_apn" ]; then
	log "qmodem.$seg.apn='$cur_apn' 已有值，不覆盖"
	exit 0
fi

# ---- 找 AT 口：优先用段里记录的，否则按 ttyUSB2/3/1/0 逐个探 ----
at_port=$($QMODEM -q get "qmodem.$seg.at_port" 2>/dev/null)
if [ -z "$at_port" ]; then
	for t in /dev/ttyUSB2 /dev/ttyUSB3 /dev/ttyUSB1 /dev/ttyUSB0; do
		[ -c "$t" ] || continue
		stty -F "$t" 115200 raw -echo clocal 2>/dev/null || continue
		: > /tmp/.apn_auto_at
		timeout 3 cat "$t" > /tmp/.apn_auto_at 2>/dev/null &
		rp=$!
		sleep 0.3
		printf 'AT\r' > "$t" 2>/dev/null
		sleep 1
		kill "$rp" 2>/dev/null; wait "$rp" 2>/dev/null
		if tr -d '\r' < /tmp/.apn_auto_at | grep -q '^OK'; then at_port="$t"; break; fi
	done
fi
[ -n "$at_port" ] || { log "没找到 AT 口，跳过"; exit 0; }

# ---- 读 IMSI ----
read_at() {
	: > /tmp/.apn_auto_at2
	timeout 3 cat "$at_port" > /tmp/.apn_auto_at2 2>/dev/null &
	rp=$!
	sleep 0.3
	printf '%s\r' "$1" > "$at_port" 2>/dev/null
	sleep 1
	kill "$rp" 2>/dev/null; wait "$rp" 2>/dev/null
	tr -d '\r' < /tmp/.apn_auto_at2
}
imsi=$(read_at 'AT+CIMI' | grep -E '^[0-9]{15}' | head -n1)
[ -n "$imsi" ] || { log "AT+CIMI 没读到 IMSI（SIM 未就绪？），跳过"; exit 0; }

apn=$(apn_from_imsi "$imsi") || { log "IMSI $imsi 不属于已知国内运营商（MCCMNC=$(echo $imsi | cut -c1-5)），跳过"; exit 0; }

# ---- 写入 ----
$QMODEM set "qmodem.$seg.apn=$apn"
$QMODEM set "qmodem.$seg.pdp_type=ipv4v6"
$QMODEM set "qmodem.$seg.enable_dial=1"
if $QMODEM commit qmodem; then
	log "已按 IMSI 自动设 APN: qmodem.$seg.apn='$apn' (IMSI 前缀 $(echo $imsi | cut -c1-5), AT 口 $at_port)"
	/etc/init.d/qmodem_network restart >/dev/null 2>&1 || true
else
	log "写入 uci 失败"
fi
exit 0
