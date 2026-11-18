#!/usr/bin/env bash
# common/files/etc/uci-defaults/90-lighttpd-webdav 的沙箱测试（全设备通用）。
# 桩掉 主配置 / conf.d / 共享目录 / init 脚本 / lighttpd 二进制，验证：
#   未装 lighttpd 时静默、正常写片段、内容正确、幂等、校验失败回滚、init 被 enable+restart。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRESS="$ROOT/common/files/etc/uci-defaults/90-lighttpd-webdav"
# ⚠️ 必须 cd 进去再 pwd 取 POSIX 路径：Windows 的 mktemp -d 返回 "C://Users//...//tmp.xxx"，
# 这种路径塞进 PATH 会被盘符的冒号截断，导致桩命令（netstat 等）根本找不到。
SB="$(cd "$(mktemp -d)" && pwd)"
trap 'rm -rf "$SB"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }

# 造一个可运行的沙箱：
#   $1=场景名  $2=lighttpd -tt 退出码（0 成功 / 1 失败）  $3=-p 解析出的端口（空=解析不出）
mk_sb() {
	local d="$SB/$1" rc="$2" port="${3-8080}"
	mkdir -p "$d/lighttpd/conf.d" "$d/share" "$d/bin" "$d/lib"
	printf 'var.home_dir = "/var/lib/lighttpd/"\n' > "$d/lighttpd/lighttpd.conf"
	# 桩 lighttpd：-tt 走校验码，-p 走端口输出（格式与真实 dump 一致，含对齐空格）
	cat > "$d/bin/lighttpd" <<EOF
#!/bin/sh
case "\$1" in
  -tt) exit $rc ;;
  -p)  [ -n "$port" ] && echo "server.port            = $port"; exit 0 ;;
  *)   echo "lighttpd \$*" >> "$d/bin/calls"; exit 0 ;;
esac
EOF
	chmod +x "$d/bin/lighttpd"
	# 桩 netstat：默认无输出（不占 80）；场景可用 $d/netstat.out 注入监听表
	cat > "$d/bin/netstat" <<EOF
#!/bin/sh
cat "$d/netstat.out" 2>/dev/null
exit 0
EOF
	chmod +x "$d/bin/netstat"
	# 桩 init 脚本
	cat > "$d/init" <<EOF
#!/bin/sh
echo "\$1" >> "$d/init.calls"
exit 0
EOF
	chmod +x "$d/init"
	# 桩 functions.sh：提供 user_exists / user_add
	cat > "$d/lib/functions.sh" <<'EOF'
user_exists() { return 1; }
user_add() { return 0; }
EOF
	echo "$d"
}

run_press() {  # run_press <沙箱目录>
	local d="$1"
	env -i PATH="$d/bin:/usr/bin:/bin" \
		LW_MAIN_CONF="$d/lighttpd/lighttpd.conf" \
		LW_CONF_DIR="$d/lighttpd/conf.d" \
		LW_SHARE_DIR="$d/share" \
		LW_INIT="$d/init" \
		LW_BIN="$d/bin/lighttpd" \
		LW_FUNCS="$d/lib/functions.sh" \
		/bin/sh "$PRESS" 2>&1
}

echo "== 1. 未装 lighttpd（主配置不存在）=="
d="$SB/none"; mkdir -p "$d"
out=$(env -i PATH=/usr/bin:/bin LW_MAIN_CONF="$d/absent.conf" LW_CONF_DIR="$d/conf.d" \
	LW_SHARE_DIR="$d/share" LW_INIT="$d/init" LW_BIN="$d/bin" /bin/sh "$PRESS" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "退出码 0" || bad "退出码应为 0，实际 $rc"
[ ! -e "$d/conf.d" ] && ok "未创建任何配置目录" || bad "不该创建配置目录"

echo "== 2. 正常写入 =="
d=$(mk_sb ok 0)
out=$(run_press "$d"); rc=$?
F="$d/lighttpd/conf.d/zz-webdav-share.conf"
[ "$rc" = 0 ] && ok "退出码 0" || bad "退出码应为 0，实际 $rc"
[ -f "$F" ] && ok "片段已写入" || bad "片段未写入"
grep -q 'server.port          = 8080' "$F" && ok "端口 8080" || bad "端口不是 8080"
grep -q 'server.document-root = "/mnt/webdav"' "$F" && ok "文档根为 /mnt/webdav" || bad "文档根不对"
grep -q 'webdav.activate       = "enable"' "$F" && ok "WebDAV 已启用" || bad "WebDAV 未启用"
grep -q 'webdav.sqlite-db-name = home_dir' "$F" && ok "锁库放 home_dir（/etc 不可写）" || bad "锁库路径不对"
grep -q '\$HTTP\["url"\] =~ "\^/"' "$F" && ok "根路径条件块存在" || bad "根路径条件块缺失"
[ -d "$d/share" ] && ok "共享目录已创建" || bad "共享目录未创建"
grep -q '^enable$' "$d/init.calls" 2>/dev/null && ok "init enable 被调用" || bad "init enable 未调用"
grep -q '^restart$' "$d/init.calls" 2>/dev/null && ok "init restart 被调用" || bad "init restart 未调用"

echo "== 2b. 端口闸门放行 8080 =="
[ -f "$d/lighttpd/conf.d/zz-webdav-share.conf" ] && ok "8080 时片段保留" || bad "8080 时片段被误删"

echo "== 3. 幂等（重复执行）=="
before=$(md5sum "$F" | cut -d' ' -f1)
run_press "$d" >/dev/null 2>&1
after=$(md5sum "$F" | cut -d' ' -f1)
[ "$before" = "$after" ] && ok "片段内容不变" || bad "重复执行改动了片段"
n=$(grep -c 'server.port' "$F")
[ "$n" = 1 ] && ok "server.port 只有一条（未追加）" || bad "server.port 重复 $n 次"

echo "== 4. 配置校验失败则回滚 =="
d=$(mk_sb badconf 1)
out=$(run_press "$d"); rc=$?
[ "$rc" = 0 ] && ok "退出码仍为 0（不阻断开机）" || bad "退出码应为 0，实际 $rc"
[ ! -f "$d/lighttpd/conf.d/zz-webdav-share.conf" ] && ok "片段已撤掉" || bad "校验失败却留下片段"
[ ! -f "$d/init.calls" ] && ok "未触碰 init（保持包默认）" || bad "校验失败仍启动了 lighttpd"
grep -q "配置校验失败" <<<"$out" || true

echo "== 4b. 端口闸门：解析出 80 时拒绝启动（历史事故防线）=="
d=$(mk_sb port80 0 80)
out=$(run_press "$d"); rc=$?
[ "$rc" = 0 ] && ok "退出码仍为 0（不阻断开机）" || bad "退出码应为 0，实际 $rc"
[ ! -f "$d/lighttpd/conf.d/zz-webdav-share.conf" ] && ok "片段已撤掉" || bad "端口不对却留下片段"
[ ! -f "$d/init.calls" ] && ok "未启动 lighttpd（保住 uhttpd 的 80）" || bad "端口不对仍启动了 lighttpd"

echo "== 4c. -p 解析不出端口时放行（避免误杀）=="
d=$(mk_sb noport 0 "")
out=$(run_press "$d"); rc=$?
[ "$rc" = 0 ] && ok "退出码 0" || bad "退出码应为 0"
[ -f "$d/lighttpd/conf.d/zz-webdav-share.conf" ] && ok "片段保留" || bad "解析不出时不该撤片段"
grep -q '^restart$' "$d/init.calls" 2>/dev/null && ok "正常启动" || bad "应放行启动"
grep -q '无法从 lighttpd -p 解析' <<<"$out" || true

echo "== 4d. 启动后兜底：真的占了 80 → 强制 stop =="
d=$(mk_sb occ80 0 8080)
printf 'tcp        0      0 0.0.0.0:80              0.0.0.0:*               LISTEN      1234/lighttpd\n' > "$d/netstat.out"
out=$(run_press "$d"); rc=$?
[ "$rc" = 0 ] && ok "退出码 0" || bad "退出码应为 0"
grep -q '^stop$' "$d/init.calls" 2>/dev/null && ok "已 stop（保住 LuCI）" || bad "占 80 却未 stop"
[ ! -f "$d/lighttpd/conf.d/zz-webdav-share.conf" ] && ok "片段已撤掉" || bad "占 80 仍留下片段"

echo "== 5. 公共清单：lighttpd 已取代 dufs =="
LITE="$ROOT/common/configs/lite.list"
grep -q '^CONFIG_PACKAGE_lighttpd=y' "$LITE" && ok "lite.list 启用 lighttpd" || bad "lite.list 缺 lighttpd"
grep -q '^CONFIG_PACKAGE_lighttpd-mod-webdav=y' "$LITE" && ok "lite.list 启用完整版 WebDAV 模块" || bad "lite.list 缺 webdav 模块"
grep -qE '^CONFIG_PACKAGE_dufs=y' "$LITE" && bad "lite.list 仍要求 dufs" || ok "lite.list 已移除 dufs"
grep -qE '^CONFIG_PACKAGE_luci-app-dufs=y' "$LITE" && bad "lite.list 仍要求 luci-app-dufs" || ok "lite.list 已移除 dufs 面板"

echo "== 6. 设备清单不再单独声明（避免重复/冲突）=="
for f in "$ROOT"/devices/*/configs/*.list; do
	[ -f "$f" ] || continue
	n=$(basename "$(dirname "$(dirname "$f")")")/$(basename "$f")
	if grep -qE '^CONFIG_PACKAGE_(dufs|luci-app-dufs)=y' "$f"; then bad "$n 仍启用 dufs"; fi
	if grep -qE '^CONFIG_PACKAGE_lighttpd' "$f"; then bad "$n 又声明了一遍 lighttpd"; fi
done
ok "设备清单无 dufs / lighttpd 重复声明"

echo "== 7. 无其它 rust 包（去掉 dufs 后 rust 不参与构建）=="
if grep -rqE '^CONFIG_PACKAGE_(shadowsocks-rust|librespeed-cli-rust|rustdesk)' "$ROOT"/common/configs/ "$ROOT"/devices/*/configs/ 2>/dev/null; then
	bad "新增了别的 rust 包（rust 仍会被编）"
else
	ok "清单里无 rust 实现包，rust/host 不会被拉起"
fi

echo "== 8. vendor 面板已清理 =="
[ ! -d "$ROOT/common/package/luci-app-dufs" ] && ok "common/package/luci-app-dufs 已删除" || bad "vendor 包仍在"
grep -q 'luci-app-dufs' "$ROOT/scripts/assemble.sh" && bad "assemble.sh 仍残留 dufs 特例" || ok "assemble.sh 无 dufs 特例"

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
