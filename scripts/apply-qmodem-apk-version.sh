#!/usr/bin/env bash
# 把 QModem feed 的预发布版本号改写成 apk 能接受的写法。
#
# 背景：v3.4.0-rc.3 tag 的 version.mk 写着 QMODEM_VERSION:=3.4.0-rc.3，
#   apk mkpkg 直接拒绝出包（run#53：package version is invalid）。
#   Alpine apk 的版本语法里连字符只允许作为末尾的 -r<N> 修订号，
#   预发布后缀必须写成 _rc<N>。上游 main 分支自己就是 3.4.0_rc3，
#   只有这个 tag 是连字符写法（打 tag 时自动生成，没经过 apk 打包验证）。
#   注意：编译本身是成功的，炸的是最后一步 apk mkpkg。
#
# 影响面：只改 feeds 内 qmodem/version.mk 一行；语义不变（仍是 3.4.0 的 rc3）。
#   全部 qmodem 包的 PKG_VERSION 都取自这一行，改一处即可让整组包出包；
#   源码、中文 i18n 包、依赖关系一律不动。
#
# 用法: apply-qmodem-apk-version.sh <openwrt-root>
# 特性: 幂等；版本行格式不符时显式失败，不静默跳过。
set -euo pipefail

OPENWRT="$(cd "${1:?缺少 openwrt 根目录}" && pwd)"

# 不用 find -exec：部分环境（Windows Git Bash）会因环境变量过大而 exec 失败
CANDIDATES=()
while IFS= read -r f; do
	grep -q '^QMODEM_VERSION:=' "$f" && CANDIDATES+=("$f")
done < <(find -L "$OPENWRT/feeds" -maxdepth 2 -type f -name version.mk 2>/dev/null | sort)
if [ "${#CANDIDATES[@]}" -ne 1 ]; then
	echo "错误: 期望恰好 1 个含 QMODEM_VERSION 的 version.mk，实际 ${#CANDIDATES[@]} 个" >&2
	printf '  %s\n' "${CANDIDATES[@]}" >&2
	exit 1
fi
VFILE="${CANDIDATES[0]}"

if [ "$(grep -c '^QMODEM_VERSION:=' "$VFILE")" -ne 1 ]; then
	echo "错误: $VFILE 里 QMODEM_VERSION 行不止一处，需人工核对" >&2
	exit 1
fi
LINE="$(grep -E '^QMODEM_VERSION:=' "$VFILE")"

# 已是 apk 合法写法（如 3.4.0_rc3 / 3.4.0）：幂等跳过
if printf '%s\n' "$LINE" | grep -qE '^QMODEM_VERSION:=[0-9]+\.[0-9]+\.[0-9]+(_[a-z]+[0-9]*)?$'; then
	echo "✅ qmodem 版本号已合法（幂等跳过）: $LINE"
	exit 0
fi

# 连字符预发布写法（如 3.4.0-rc.3）：改写成下划线形式 3.4.0_rc3
if printf '%s\n' "$LINE" | grep -qE '^QMODEM_VERSION:=[0-9]+\.[0-9]+\.[0-9]+-[a-z]+\.[0-9]+$'; then
	NEW="$(printf '%s\n' "$LINE" | sed -E 's/^QMODEM_VERSION:=([0-9]+\.[0-9]+\.[0-9]+)-([a-z]+)\.([0-9]+)$/QMODEM_VERSION:=\1_\2\3/')"
	awk -v new="$NEW" '/^QMODEM_VERSION:=/ { print new; next } { print }' "$VFILE" > "$VFILE.tmp"
	mv "$VFILE.tmp" "$VFILE"
	grep -qxF "$NEW" "$VFILE" || { echo "错误: 改写后回读失败: $VFILE" >&2; exit 1; }
	echo "✅ qmodem 版本号已规范化（apk 语法）: $LINE -> $NEW"
	exit 0
fi

echo "错误: QMODEM_VERSION 行无法识别，需人工核对 QModem 版本: $VFILE" >&2
echo "  实际: $LINE" >&2
exit 1
