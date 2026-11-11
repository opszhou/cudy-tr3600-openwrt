#!/usr/bin/env bash
# 让 QModem 每次拨号固定下发 AT+QCFG="nat",2（网桥模式）。
#
# 背景：上游 at_dial() 在 manufacturer=quectel 分支每次拨号都发
#   [ "$donot_nat" = "1" ] && nat_cfg="AT+QCFG=\"nat\",0" || nat_cfg="AT+QCFG=\"nat\",1"
# 手工设的 nat=2 会在下一次重拨时被写回 1，双路随即失效。
# 实测（2026-11-07）：RM500U-CNV 在 nat=2 + AT+CFUN=1,1 下，
# USB(usb0) 与 RJ45(eth0) 同时拿 192.168.42.x、双 ping 通、可切换。
#
# 影响面：只改 feeds 内 qmodem 的 modem_dial.sh 一行；
# 只在 quectel 分支生效，其它厂商模组不受影响；
# donot_nat=1 / en_bridge=1 仍走 nat=0。
#
# 用法: apply-qmodem-nat2.sh <openwrt-root>
# 特性: 幂等；源码格式不符时显式失败，不静默跳过。
set -euo pipefail

OPENWRT="$(cd "${1:?缺少 openwrt 根目录}" && pwd)"

# 字面量，对应固定 commit 99553e5a 的写法（双引号 + 转义，勿改成单引号写法）
OLD_LINE='[ "$donot_nat" = "1" ] && nat_cfg="AT+QCFG=\"nat\",0" || nat_cfg="AT+QCFG=\"nat\",1"'
NEW_LINE='[ "$donot_nat" = "1" ] && nat_cfg="AT+QCFG=\"nat\",0" || nat_cfg="AT+QCFG=\"nat\",2"'

mapfile -t CANDIDATES < <(find "$OPENWRT/feeds" -type f -path '*/usr/share/qmodem/modem_dial.sh' -print 2>/dev/null | sort)
if [ "${#CANDIDATES[@]}" -ne 1 ]; then
    echo "错误: 期望恰好 1 个 qmodem modem_dial.sh，实际 ${#CANDIDATES[@]} 个" >&2
    printf '  %s\n' "${CANDIDATES[@]}" >&2
    exit 1
fi
QM_DIAL="${CANDIDATES[0]}"

if grep -qF "$NEW_LINE" "$QM_DIAL"; then
    echo "✅ qmodem nat=2 补丁已在位（幂等跳过）"
    exit 0
fi
if ! grep -qF "$OLD_LINE" "$QM_DIAL"; then
    echo "错误: nat_cfg 行与固定 commit 99553e5a 不符，需人工核对: ${QM_DIAL#$OPENWRT/}" >&2
    exit 1
fi

TMP="${QM_DIAL}.nat2.tmp"
# 纯字面替换（index + substr），避开 sed/awk 正则对 [ ] " \ + | 的转义陷阱。
# ⛔ 必须用 ENVIRON 传值：awk -v 会把 \" 解释成 "，导致字面量匹配不上而静默失败。
if ! OLD_NAT="$OLD_LINE" NEW_NAT="$NEW_LINE" awk '
BEGIN { old = ENVIRON["OLD_NAT"]; new = ENVIRON["NEW_NAT"] }
{
    p = index($0, old)
    if (p > 0) {
        $0 = substr($0, 1, p - 1) new substr($0, p + length(old))
        n++
    }
    print
}
END { exit (n == 1 ? 0 : 42) }
' "$QM_DIAL" > "$TMP"; then
    rm -f "$TMP" 2>/dev/null || true
    echo "错误: nat=2 替换未命中唯一一行，补丁未应用" >&2
    exit 1
fi
mv "$TMP" "$QM_DIAL"

grep -qF "$NEW_LINE" "$QM_DIAL" || { echo "错误: 回读校验失败" >&2; exit 1; }
echo "✅ 已应用 qmodem nat=2 补丁: ${QM_DIAL#$OPENWRT/}"
