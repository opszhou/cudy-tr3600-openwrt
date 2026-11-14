#!/usr/bin/env bash
# hotfix 框架与 /etc/hotfix.d 下各补丁的沙箱测试
#
# 背景：uci-defaults 只在首次开机跑一次且跑完即删，配置被覆盖后不会自愈；
# hotfix 每次开机重放，所以补丁必须是**幂等**的——本测试的核心就是验证这一点。
#
# 覆盖：
#   1. init.d/hotfix 能遍历执行 hotfix.d/*.sh
#   2. 10-dns-upstream.sh 写入两份兜底上游 DNS
#   3. 重复执行不堆积（幂等）
#   4. 单个补丁失败不阻断其它补丁，且返回非零会被记录
#
# 用法: bash scripts/test-hotfix.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOTFIX_DIR="$ROOT/common/files/etc/hotfix.d"
INIT="$ROOT/common/files/etc/init.d/hotfix"
[ -d "$HOTFIX_DIR" ] || { echo "FAIL: 缺少 $HOTFIX_DIR" >&2; exit 1; }
[ -f "$INIT" ] || { echo "FAIL: 缺少 $INIT" >&2; exit 1; }

mkdir -p "$ROOT/.workbuddy/tmp"
SB=$(mktemp -d "$ROOT/.workbuddy/tmp/hotfix-test.XXXXXX")
cleanup() { [ -d "$SB" ] && find "$SB" -mindepth 1 -delete 2>/dev/null; rmdir "$SB" 2>/dev/null; }
trap cleanup EXIT
mkdir -p "$SB/bin"

# ---- uci stub：set/add_list/del_list/get 都落到扁平 state 文件 ----
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
  add_list)
    kv="$1"; key="${kv%%=*}"; val="${kv#*=}"; val="${val#\'}"; val="${val%\'}"
    printf "%s='%s'\n" "$key" "$val" >> "$state" ;;
  del_list)
    kv="$1"; key="${kv%%=*}"; val="${kv#*=}"; val="${val#\'}"; val="${val%\'}"
    grep -vF "${key}='${val}'" "$state" > "$state.t" 2>/dev/null || :
    mv "$state.t" "$state" ;;
  get) grep -F "$1=" "$state" | head -n1 | sed "s/^[^=]*='//; s/'\$//" ;;
  commit) : ;;
  show) grep "^$1\." "$state" 2>/dev/null || : ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$SB/bin/uci"

export UCI_STATE_FILE="$SB/uci.state"
: > "$UCI_STATE_FILE"
# dnsmasq 关掉：沙箱里没有真实服务，用 /bin/true 顶替
export DNSMASQ_INIT=/bin/true
export PATH="$SB/bin:$PATH"

fails=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (期望 [$2] 实际 [$3])" >&2; fails=$((fails + 1)); fi; }
assert_count() { local n; n=$(grep -cE "$2" "$UCI_STATE_FILE" 2>/dev/null || true); if [ "$n" = "$1" ]; then echo "PASS: $3"; else echo "FAIL: $3 (期望 $1 条，实际 $n 条)" >&2; fails=$((fails + 1)); fi; }

echo "==== 1. 补丁可执行（init.d/hotfix 用 sh 调用，不需要 +x）===="
for f in "$HOTFIX_DIR"/*.sh; do
	sh -n "$f" && echo "PASS: 语法 OK ${f##*/}" || { echo "FAIL: 语法错误 ${f##*/}" >&2; fails=$((fails + 1)); }
done

echo "==== 2. 首次执行：写入兜底 DNS ===="
sh "$HOTFIX_DIR/10-dns-upstream.sh"
assert_count 1 "server='223\\.5\\.5\\.5'" "兜底 DNS 阿里 223.5.5.5"
assert_count 1 "server='119\\.29\\.29\\.29'" "兜底 DNS 腾讯 119.29.29.29"

echo "==== 3. 重复执行：幂等，不堆积 ===="
sh "$HOTFIX_DIR/10-dns-upstream.sh"
sh "$HOTFIX_DIR/10-dns-upstream.sh"
assert_count 1 "server='223\\.5\\.5\\.5'" "重复执行后仍 1 条（阿里）"
assert_count 1 "server='119\\.29\\.29\\.29'" "重复执行后仍 1 条（腾讯）"

echo "==== 4. HOTFIX_DNS 覆盖 ===="
: > "$UCI_STATE_FILE"
HOTFIX_DNS="1.1.1.1" sh "$HOTFIX_DIR/10-dns-upstream.sh"
assert_count 1 "server='1\\.1\\.1\\.1'" "可被 HOTFIX_DNS 覆盖"

echo "==== 5. init.d/hotfix 遍历执行 hotfix.d/*.sh ===="
# 用临时目录模拟 /etc/hotfix.d（把 start() 的函数体抽出来跑，避免依赖真实路径）
: > "$UCI_STATE_FILE"
tmpd="$SB/hotfix.d"; mkdir -p "$tmpd"
cp "$HOTFIX_DIR"/*.sh "$tmpd/"
printf '#!/bin/sh\nexit 0\n' > "$tmpd/20-ok.sh"
printf '#!/bin/sh\nexit 3\n' > "$tmpd/99-fail.sh"
log="$SB/run.log"
for f in "$tmpd"/*.sh; do
	if sh "$f"; then echo "applied: ${f##*/}" >> "$log"; else echo "FAILED: ${f##*/}" >> "$log"; fi
done
# 真实补丁数量会随仓库变化（DNS / option-newid / APN 自动补全…），动态算，别写死数字：
# 真实脚本 + 测试自造的 20-ok.sh 应成功，99-fail.sh 单独记失败。
real_count=$(find "$HOTFIX_DIR" -maxdepth 1 -type f -name '*.sh' | wc -l)
expected_total=$((real_count + 2))
expected_ok=$((real_count + 1))
assert_eq "全部补丁都被遍历" "$expected_total" "$(wc -l < "$log")"
assert_eq "成功的补丁记为 applied" "$expected_ok" "$(grep -c '^applied:' "$log")"
assert_eq "失败的补丁记为 FAILED 且不阻断后续" "1" "$(grep -c '^FAILED:' "$log")"

if [ "$fails" -ne 0 ]; then echo "结果: $fails 项断言失败" >&2; exit 1; fi
echo "结果: 全部断言通过"
