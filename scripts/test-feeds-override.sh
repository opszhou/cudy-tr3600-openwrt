#!/usr/bin/env bash
# 校验「设备级 feeds.append 覆盖上游同名 feed」这套机制。
#
# 背景（run#82）：P3 锁了 ImmortalWrt v25.12.2，该 tag 自带的 feeds.conf.default
# 把 luci 钉在 d6167ea，那一版 luci-mod-dashboard 没有 lib/ 目录，自研面板直接用不了。
# 解决办法是设备级 feeds.append 显式覆盖 luci 到新 commit——这里守住三件事：
#   1. 设备级文件格式合法（不能同时带 ;branch 与 ^commit，否则 scripts/feeds 会忽略 commit）
#   2. assemble.sh 真的读取设备级文件并做同名覆盖
#   3. 覆盖后 luci 只剩一行、且是新 commit
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV_FEEDS="$ROOT/devices/fzs_5gcpe-p3/feeds.append"
ASM="$ROOT/scripts/assemble.sh"
SB="$(cd "$(mktemp -d)" && pwd)"
trap 'rm -rf "$SB"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }

echo "== 1. 设备级 feeds.append 格式 =="
[ -f "$DEV_FEEDS" ] && ok "文件存在" || bad "文件不存在"
lines=$(grep -v '^#' "$DEV_FEEDS" | grep -c '^src-git' || true)
[ "$lines" = 1 ] && ok "只声明 1 个 feed（luci）" || bad "feed 行数异常：$lines"
grep -qE '^src-git luci https://github\.com/immortalwrt/luci\.git\^[0-9a-f]{40}$' "$DEV_FEEDS" \
	&& ok "luci 用 ^<40位commit> 钉住（可复现）" || bad "luci 行不是 ^commit 形式"
if grep -E '^src-git' "$DEV_FEEDS" | grep -qE ';.*\^|\^.*;'; then
	bad "同时出现 ;branch 与 ^commit（scripts/feeds 会忽略 commit）"
else
	ok "未混用 ;branch 与 ^commit"
fi

echo "== 2. assemble.sh 读取设备级文件 =="
grep -q 'DEV_FEEDS="$ROOT/devices/\$DEV/feeds.append"' "$ASM" && ok "拼接了设备级路径" || bad "未拼接设备级路径"
grep -q 'cat "$DEV_FEEDS" >> "$FEEDS_FILE"' "$ASM" && ok "设备级内容被合并" || bad "未合并设备级内容"
grep -q '覆盖上游自带定义' "$ASM" && ok "有同名覆盖逻辑" || bad "缺同名覆盖逻辑"

echo "== 3. 覆盖逻辑实测（桩 feeds.conf.default）=="
UP="$SB/feeds.conf.default"
cat > "$UP" <<'EOF'
src-git packages https://github.com/immortalwrt/packages.git^84bd86384928955b568988ca0e09e2c78c75173d
src-git luci https://github.com/immortalwrt/luci.git^d6167ea0645cbd1327708d85f94824f42d0eb872
src-git routing https://github.com/openwrt/routing.git^e49d76035aafb85ddc993b59271d8c7ba56b5362
EOF
LINE=$(grep -v '^#' "$DEV_FEEDS" | grep '^src-git' | head -1)
_fname=$(printf '%s\n' "$LINE" | awk '{print $2}')
grep -qE "^src-git ${_fname} " "$UP" && sed -i "/^src-git ${_fname} /d" "$UP"
grep -qxF "$LINE" "$UP" || echo "$LINE" >> "$UP"
grep -q 'luci.git^476b5257' "$UP" && ok "luci 已提到新 commit" || bad "luci 未更新"
grep -q 'd6167ea' "$UP" && bad "旧 luci 行仍残留" || ok "旧行已删除"
[ "$(grep -c '^src-git luci ' "$UP")" = 1 ] && ok "luci 恰好一行" || bad "luci 行数不对"
# 其它 feed 不能被误删
grep -q '^src-git packages ' "$UP" && ok "packages 行未被误删" || bad "packages 行被删了"
grep -q '^src-git routing ' "$UP" && ok "routing 行未被误删" || bad "routing 行被删了"

echo "== 4. 其它设备不受影响 =="
for d in "$ROOT"/devices/*/; do
	n=$(basename "$d")
	[ "$n" = "fzs_5gcpe-p3" ] && continue
	[ -f "$d/feeds.append" ] && bad "$n 也有 feeds.append（会被本机制影响，需确认）"
done
ok "仅 P3 有设备级 feeds.append"

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
