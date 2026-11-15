#!/usr/bin/env bash
# 让 QModem 在拨号开始时先把模组射频打开（CFUN≠1 时发 AT+CFUN=1）。
#
# 背景（2026-11-15 真机实测，FZS 5GCPE P3 + RM500U-CNV / MBIM 模式）：
#   模组一旦处于 CFUN=0（UI 的「最小功能模式」AT 预设 AT+CFUN=0、或调试残留），
#   dial() 会卡在 prepare 等待循环里等注网，而负责恢复射频的 check_cfun
#   写在后面的 at_dial_monitor 里——永远走不到那一步。表现就是
#   「点拨号没反应、不报错、dial_log 也不写」。
#   A/B 实测：CFUN=0 → 拨号 → 45 秒后 CFUN 仍为 0、wwan0 DOWN、无路由；
#   手动 AT+CFUN=1 后同一条路径立刻拨通（10.68.129.197，ping 通）。
#
# 影响面：在 dial() 的 prepare 等待循环体内插入一次 check_cfun()。
#   CFUN 正常时它只是一次 AT+CFUN? 查询，不改任何状态；异常时补发 AT+CFUN=1。
#   必须放在循环体内而不是循环之前：实测放在循环前无效——卡住的拨号进程会一直
#   持有 dial.lock，新拨号在 flock -n 处直接 return 1（且 ubus 仍回「执行成功」），
#   根本走不到循环前那句；放进循环体内才能让已经卡住的进程自己恢复。
#
# 用法: apply-qmodem-cfun-fix.sh <openwrt-root>
# 特性: 幂等；锚点不唯一/找不到时显式失败；打完后跑 sh -n 语法自检。
set -euo pipefail

OPENWRT="$(cd "${1:?缺少 openwrt 根目录}" && pwd)"

MARKER='# QModem-hotfix: CFUN=0 时拨号会空转'
INSERT_LINE='check_cfun >/dev/null 2>&1'

# 只扫 qmodem 这个 feed：全 feeds 扫描会撞上别的 feed 里的同名杂项
# （run#56 实测 feeds/base/feeds/qmodem/... 也被匹配到，脚本误判为 2 个）。
# 不用 find -exec：部分环境（Windows Git Bash）会因环境变量过大而 exec 失败。
QM_FEED="$OPENWRT/feeds/qmodem"
if [ ! -e "$QM_FEED" ]; then
	echo "错误: 未找到 qmodem feed 目录: $QM_FEED" >&2
	exit 1
fi
CANDIDATES=()
while IFS= read -r f; do
	CANDIDATES+=("$f")
done < <(find -L "$QM_FEED" -type f -path '*/usr/share/qmodem/modem_dial.sh' 2>/dev/null | sort)
if [ "${#CANDIDATES[@]}" -ne 1 ]; then
	echo "错误: 期望恰好 1 个 qmodem modem_dial.sh，实际 ${#CANDIDATES[@]} 个" >&2
	printf '  %s\n' "${CANDIDATES[@]}" >&2
	exit 1
fi
QM_DIAL="${CANDIDATES[0]}"

if grep -qF "$MARKER" "$QM_DIAL"; then
	echo "✅ qmodem CFUN 补丁已在位（幂等跳过）"
	exit 0
fi

# 锚点必须唯一：dial() 里进入 prepare 等待循环的那一行
ANCHOR_RE='^[[:space:]]*while \[ "\$dial_prepare" != 1 \] ; do[[:space:]]*$'
ANCHOR_COUNT="$(grep -cE "$ANCHOR_RE" "$QM_DIAL" || true)"
if [ "$ANCHOR_COUNT" -ne 1 ]; then
	echo "错误: dial() 的 prepare 等待循环锚点数量异常（$ANCHOR_COUNT 个），需人工核对 QModem 版本: ${QM_DIAL#$OPENWRT/}" >&2
	exit 1
fi

TMP="$QM_DIAL.cfun.tmp"
awk -v marker="$MARKER" -v ins="$INSERT_LINE" '
	!done && $0 ~ /^[[:space:]]*while \[ "\$dial_prepare" != 1 \] ; do[[:space:]]*$/ {
		match($0, /^[[:space:]]*/)
		ind = substr($0, 1, RLENGTH) "    "
		print
		print ind marker
		print ind ins
		done = 1
		next
	}
	{ print }
' "$QM_DIAL" > "$TMP"
# ⚠️ 用 cat 写回而不是 mv：mv 会把临时文件的 0644 换成目标文件的权限，
# 丢掉可执行位 → procd 启动实例时 execve 失败（exit_code=127），拨号永远起不来。
# 这个坑在设备上真实踩过一次（2026-11-15）。
cat "$TMP" > "$QM_DIAL"
rm -f "$TMP"
# 兜底：这个脚本必须可执行，否则 procd 的实例起不来
chmod 755 "$QM_DIAL"

if [ "$(grep -cF "$INSERT_LINE" "$QM_DIAL")" -ne 1 ]; then
	echo "错误: 补丁写入后回读失败（$QM_DIAL）" >&2
	exit 1
fi
if [ ! -x "$QM_DIAL" ]; then
	echo "错误: 补丁后 modem_dial.sh 不可执行（procd 会 exit 127）: $QM_DIAL" >&2
	exit 1
fi
if ! sh -n "$QM_DIAL"; then
	echo "错误: 补丁后 modem_dial.sh 语法校验失败（$QM_DIAL）" >&2
	exit 1
fi
echo "✅ qmodem CFUN 补丁已应用：dial() 等待循环内持续确保射频开启"
