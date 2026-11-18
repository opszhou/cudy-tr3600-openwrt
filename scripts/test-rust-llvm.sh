#!/usr/bin/env bash
# apply-rust-llvm.sh 的沙箱测试。桩出最小目录树，断言五种场景。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/apply-rust-llvm.sh"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }

mk_rust() {  # mk_rust <root> <flag-value>
	mkdir -p "$1/feeds/packages/lang/rust"
	cat > "$1/feeds/packages/lang/rust/Makefile" <<EOF
RUST_CONFIGURE_ARGS = \\
	--bootstrap-cache-path=\$(DL_DIR)/rustc \\
	--set=llvm.download-ci-llvm=$2 \\
	--set=build.extended=false
EOF
}

echo "== 1. 无 rust 包（不编译 rust 的组合）=="
mkdir -p "$SB/t1/feeds"
out=$(bash "$SCRIPT" "$SB/t1" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "退出码 0" || bad "退出码应为 0，实际 $rc"
grep -q "未找到" <<<"$out" && ok "提示未找到 lang/rust" || bad "应提示未找到"

echo "== 2. openwrt 写法（已是 false）=="
mk_rust "$SB/t2" false
before=$(md5sum "$SB/t2/feeds/packages/lang/rust/Makefile" | cut -d' ' -f1)
out=$(bash "$SCRIPT" "$SB/t2" 2>&1); rc=$?
after=$(md5sum "$SB/t2/feeds/packages/lang/rust/Makefile" | cut -d' ' -f1)
[ "$rc" = 0 ] && ok "退出码 0" || bad "退出码应为 0，实际 $rc"
[ "$before" = "$after" ] && ok "文件未被改动（幂等）" || bad "文件不应被改动"
grep -q "幂等跳过" <<<"$out" && ok "提示幂等跳过" || bad "应提示幂等跳过"

echo "== 3. immortalwrt 写法（true → false）=="
mk_rust "$SB/t3" true
out=$(bash "$SCRIPT" "$SB/t3" 2>&1); rc=$?
mk="$SB/t3/feeds/packages/lang/rust/Makefile"
[ "$rc" = 0 ] && ok "退出码 0" || bad "退出码应为 0，实际 $rc"
grep -q -- '--set=llvm.download-ci-llvm=false' "$mk" && ok "已改为 false" || bad "未改成 false"
grep -q -- 'download-ci-llvm=true' "$mk" && bad "仍残留 true" || ok "true 已消失"
grep -q -- '--bootstrap-cache-path' "$mk" && ok "同行其他参数保持完整" || bad "其他参数被破坏"
grep -q -- '--set=build.extended=false' "$mk" && ok "后续行未被破坏" || bad "后续行被破坏"

echo "== 4. 上游写法已变（既无 true 也无 false）=="
mkdir -p "$SB/t4/feeds/packages/lang/rust"
printf 'RUST_CONFIGURE_ARGS = \\\n\t--set=build.something=1\n' > "$SB/t4/feeds/packages/lang/rust/Makefile"
out=$(bash "$SCRIPT" "$SB/t4" 2>&1); rc=$?
[ "$rc" != 0 ] && ok "退出码非 0（构建应失败而非静默跳过）" || bad "应失败退出"
grep -q "上游写法已变" <<<"$out" && ok "提示写法已变" || bad "应提示写法已变"

echo "== 5. 多个 lang/rust（布局异常）=="
# 必须都落在同一个 feeds 根下，否则 find 从 $SB/t5/feeds 扫不到，测的是「无 rust」而不是「多个」
for f in packages luci; do
	mkdir -p "$SB/t5/feeds/$f/lang/rust"
	printf 'RUST_CONFIGURE_ARGS = \\\n\t--set=llvm.download-ci-llvm=true\n' > "$SB/t5/feeds/$f/lang/rust/Makefile"
done
out=$(bash "$SCRIPT" "$SB/t5" 2>&1); rc=$?
[ "$rc" != 0 ] && ok "退出码非 0" || bad "应失败退出"
grep -q "期望恰好 1 个" <<<"$out" && ok "提示数量异常" || bad "应提示数量异常"

echo "== 6. 缺参数 =="
out=$(bash "$SCRIPT" 2>&1); rc=$?
[ "$rc" != 0 ] && ok "无参数时失败" || bad "无参数应失败"

echo "== 7. customize.sh 已接线 =="
grep -q 'apply-rust-llvm.sh' "$ROOT/common/customize.sh" && ok "customize.sh 已调用" || bad "customize.sh 未调用"

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
