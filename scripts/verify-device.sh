#!/usr/bin/env bash
# 设备移植前置校验：编译前 10 秒证明"补丁能应用 + 设备树结构正确 + 网口映射正确"。
#
# 为什么要有它：OpenWrt 编译到失败要几十分钟，而设备移植最常见的三类错误
#   （补丁上下文漂移、dts 语法/引用错、02_network 网口映射写错）
# 都能在"应用补丁后的树上"静态判定。先花 10 秒，省掉一整轮 CI。
#
# 关键设计：所有检查都在 git worktree 里做，绝不碰 openwrt 主工作区——
#   主工作区可能已被 assemble.sh 改花，拿它做 --check 会得到假的"补丁不适用"。
#
# 用法: verify-device.sh <repo-root> <openwrt目录> <设备ID> [branch] [upstream-repo]
#   设备侧可选配置: devices/<id>/verify.conf
#     BOARD=fzs,5gcpe-p3      # device tree 的 compatible[0]，用于 02_network 映射测试
#     LAN="lan1 lan2"         # 期望的 LAN 端口列表
#     WAN="wan"               # 期望的 WAN 端口列表
set -euo pipefail

ROOT="$(cd "${1:?缺少 repo root}" && pwd)"
OPENWRT="$(cd "${2:?缺少 openwrt 目录}" && pwd)"
DEV="${3:?缺少设备ID}"
REPO_NAME="${5:-openwrt}"

# shellcheck disable=SC2046
eval "$(bash "$ROOT/scripts/parse-device.sh" "$ROOT" "$DEV")"
BRANCH="${4:-${DEV_BRANCH}}"

# 与 apply-device-patches.sh 同一规则：release 分支（openwrt-25.12）不再重复加上游前缀
case "$BRANCH" in
	"$REPO_NAME-"*) PATCHDIR="$ROOT/devices/$DEV/patches/$BRANCH" ;;
	*)                  PATCHDIR="$ROOT/devices/$DEV/patches/$REPO_NAME-$BRANCH" ;;
esac

echo "==== 校验: 设备=$DEV 上游=$REPO_NAME 分支=$BRANCH ===="
fail=0
err() { echo "FAIL: $*" >&2; fail=1; }
ok()  { echo "  OK: $*"; }

shopt -s nullglob
PATCHES=("$PATCHDIR"/*.patch)
shopt -u nullglob

if [ ! -d "$PATCHDIR" ]; then
	echo "  WARN: 无补丁目录 $PATCHDIR —— 若上游已原生支持该 profile 则正常"
elif [ "${#PATCHES[@]}" -eq 0 ]; then
	echo "  WARN: $PATCHDIR 下没有 .patch（可留 .gitkeep 占位）"
else
	echo "  补丁: ${#PATCHES[@]} 个"
fi

# ---- 一次性建 worktree，检查与应用都在里面 ----
WT="$(mktemp -d)"
cleanup() { git -C "$OPENWRT" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"; }
trap cleanup EXIT
if ! git -C "$OPENWRT" worktree add --detach "$WT" HEAD >/dev/null 2>&1; then
	echo "FAIL: 无法创建 worktree（$OPENWRT）" >&2
	exit 1
fi

for p in "${PATCHES[@]:-}"; do
	[ -n "$p" ] || continue
	abs="$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
	if git -C "$WT" apply --check "$abs" 2>/dev/null; then
		git -C "$WT" apply "$abs" || { err "应用失败: $(basename "$p")"; continue; }
		ok "应用 $(basename "$p")（干净）"
	# 上游微调后上下文可能已漂移，但 3-way 仍能合并 —— assemble.sh 用的就是 --3way，
	# 这里必须与它一致，否则会出现"校验说不适用、真编译又能过"的假警报（cudy 的 PR 补丁常见）
	elif git -C "$WT" apply --3way "$abs" 2>/dev/null; then
		ok "应用 $(basename "$p")（3-way 合并）"
	else
		err "补丁无法应用: $(basename "$p")（上下文漂移且 3-way 失败，需 rebase）"
		git -C "$WT" apply --3way "$abs" >&2 || true
	fi
done

# ---- 设备树结构校验：从补丁里取新增的 .dts ----
DTS_FILE=""
for p in "${PATCHES[@]:-}"; do
	[ -n "$p" ] || continue
	f="$(grep -oE '^[+][+][+] b/target/linux/mediatek/dts/[^[:space:]]+[.]dts$' "$p" | head -n1 | sed 's|^+++ b/||')"
	if [ -n "$f" ]; then DTS_FILE="$f"; break; fi
done

if [ -n "$DTS_FILE" ] && [ -f "$WT/$DTS_FILE" ]; then
	LABELS="$WT/target/linux/mediatek/patches-6.12/117-complete-mt7981b-dtsi.patch"
	[ -f "$LABELS" ] || LABELS=""
	if ! command -v node >/dev/null 2>&1; then
		err "缺少 node，无法运行 scripts/validate-dts.mjs"
	elif node "$ROOT/scripts/validate-dts.mjs" "$WT/$DTS_FILE" ${LABELS:+--dtsi-labels "$LABELS"}; then
		ok "DTS 结构校验 ($DTS_FILE)"
	else
		err "DTS 结构校验失败 ($DTS_FILE)"
	fi
else
	echo "  WARN: 补丁未新增 .dts（复用上游现有 dts 时正常）"
fi

# ---- filogic.mk 自洽 ----
F_MK="$WT/target/linux/mediatek/image/filogic.mk"
if [ -f "$F_MK" ]; then
	grep -q "^define Device/$DEV_PROFILE$" "$F_MK" 		&& ok "filogic.mk 有 define Device/$DEV_PROFILE" 		|| err "filogic.mk 缺少 define Device/$DEV_PROFILE"
	grep -q "^TARGET_DEVICES += $DEV_PROFILE$" "$F_MK" 		&& ok "filogic.mk 已注册 TARGET_DEVICES += $DEV_PROFILE" 		|| err "filogic.mk 缺少 TARGET_DEVICES += $DEV_PROFILE（profile 不会出现在 image 列表里）"
	DEV_DTS_NAME="$(awk -v p="$DEV_PROFILE" '
		$0 == "define Device/" p { inside = 1; next }
		inside && /^endef/ { inside = 0 }
		inside && $1 == "DEVICE_DTS" { print $3 }
	' "$F_MK" | head -n1)"
	if [ -n "$DEV_DTS_NAME" ]; then
		[ -f "$WT/target/linux/mediatek/dts/$DEV_DTS_NAME.dts" ] 			&& ok "DEVICE_DTS=$DEV_DTS_NAME 对应 dts 存在" 			|| err "DEVICE_DTS=$DEV_DTS_NAME 在 dts/ 下不存在（镜像会缺 dtb）"
	fi
else
	echo "  WARN: $F_MK 不存在，跳过 filogic.mk 校验"
fi

# ---- 02_network 端口映射功能测试 ----
VERIFY_CONF="$ROOT/devices/$DEV/verify.conf"
NET_FILE="$WT/target/linux/mediatek/filogic/base-files/etc/board.d/02_network"
if [ -f "$VERIFY_CONF" ] && [ -f "$NET_FILE" ]; then
	. "$VERIFY_CONF"
	if bash "$ROOT/scripts/test-02network.sh" "$NET_FILE" "${BOARD:?verify.conf 缺 BOARD}" "${LAN:-}" "${WAN:-}"; then
		ok "02_network 映射 ($BOARD -> LAN:[${LAN:-}] WAN:[${WAN:-}])"
	else
		err "02_network 映射不符合 verify.conf 期望"
	fi
else
	echo "  WARN: 无 verify.conf 或无 02_network，跳过端口映射测试"
fi

if [ "$fail" -ne 0 ]; then
	echo
	echo "RESULT: FAIL —— 先修上面这些，再谈编译"
	exit 1
fi
echo
echo "RESULT: OK"
