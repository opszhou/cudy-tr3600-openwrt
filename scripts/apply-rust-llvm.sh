#!/usr/bin/env bash
# 让 rust/host 从源码编译 LLVM，而不是下载 CI 预编译包。
#
# 背景（run#74，P3 切 immortalwrt 后首次构建）：
#   immortalwrt/packages 的 lang/rust/Makefile 用
#       --set=llvm.download-ci-llvm=true
#   bootstrap 于是去 ci-artifacts.rust-lang.org 拉 rust-dev-<ver>-x86_64-unknown-linux-gnu.tar.xz，
#   该地址返回 404（版本对应的 CI 构建已过期或被清理）。重试三次后：
#       ERROR: failed to download llvm from ci
#       Bootstrap failed while executing ... dist build-manifest rustc ...
#       ERROR: package/feeds/packages/rust [host] failed to build.
#   而 openwrt/packages 同一文件写的是 false（从源码编 LLVM），所以 openwrt 两条线不受影响。
#
# 影响面：只改 feeds 内 lang/rust/Makefile 的一行开关。产物一致（都是同一个 LLVM 版本），
# 代价是 host rust 编译时间变长（从源码编 LLVM）。openwrt 侧一直是这么编的（run#69 实测可过）。
#
# 何时会触发：清单里只要出现任何 Rust 实现的包就会编 host rust。
#   · 2026-11 之前是 dufs（Rust 单二进制，PKG_BUILD_DEPENDS:=rust/host）
#   · 2026-11 起 dufs 已换成 lighttpd + mod_webdav，当前清单里没有 Rust 包 → 本脚本空转
# 保留它的理由：这是防御。immortalwrt 的 download-ci-llvm=true 一旦被任何 rust 包拉起
# 就必然 404 失败，而失败点埋在编译两小时之后，代价远高于这几行判断。
#
# 用法: apply-rust-llvm.sh <openwrt-root>
# 特性: 幂等；已关闭时静默跳过；两处都不匹配时显式失败（上游改了写法必须人看）。
set -euo pipefail

OPENWRT="$(cd "${1:?缺少 openwrt 根目录}" && pwd)"

OLD_FLAG='--set=llvm.download-ci-llvm=true'
NEW_FLAG='--set=llvm.download-ci-llvm=false'

mapfile -t CANDIDATES < <(find "$OPENWRT/feeds" -type f -path '*/lang/rust/Makefile' -print 2>/dev/null | sort)

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
	echo "✅ 未找到 lang/rust（当前配置不编译 rust），跳过"
	exit 0
fi
if [ "${#CANDIDATES[@]}" -ne 1 ]; then
	echo "错误: 期望恰好 1 个 lang/rust/Makefile，实际 ${#CANDIDATES[@]} 个" >&2
	printf '  %s\n' "${CANDIDATES[@]}" >&2
	exit 1
fi
RUST_MK="${CANDIDATES[0]}"

# ⛔ grep 的模式以 "--" 开头，必须用 "--" 结束选项解析，否则 grep 把模式当成长选项、
#    以退出码 2 静默失败（脚本会误判成「写法已变」）。
if grep -qF -- "$NEW_FLAG" "$RUST_MK"; then
	echo "✅ rust LLVM 已设为源码编译（幂等跳过）"
	exit 0
fi
if ! grep -qF -- "$OLD_FLAG" "$RUST_MK"; then
	echo "错误: rust Makefile 里既无 '$OLD_FLAG' 也无 '$NEW_FLAG'，上游写法已变，需人工核对: ${RUST_MK#$OPENWRT/}" >&2
	exit 1
fi

TMP="${RUST_MK}.llvm.tmp"
# 纯字面替换（index + substr）。⛔ 必须用 ENVIRON 传值：awk -v 会吃掉反斜杠，导致匹配不上。
if ! OLD_LLVM="$OLD_FLAG" NEW_LLVM="$NEW_FLAG" awk '
BEGIN { old = ENVIRON["OLD_LLVM"]; new = ENVIRON["NEW_LLVM"] }
{
	p = index($0, old)
	if (p > 0) {
		$0 = substr($0, 1, p - 1) new substr($0, p + length(old))
		n++
	}
	print
}
END { exit (n == 1 ? 0 : 42) }
' "$RUST_MK" > "$TMP"; then
	rm -f "$TMP" 2>/dev/null || true
	echo "错误: download-ci-llvm 替换未命中唯一一行，未应用" >&2
	exit 1
fi
cat "$TMP" > "$RUST_MK"
rm -f "$TMP"

grep -qF -- "$NEW_FLAG" "$RUST_MK" || { echo "错误: 回读校验失败" >&2; exit 1; }
echo "✅ 已改为源码编译 LLVM（避免 CI artifact 404）: ${RUST_MK#$OPENWRT/}"
