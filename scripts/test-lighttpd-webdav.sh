#!/usr/bin/env bash
# common/files/etc/uci-defaults/90-lighttpd-webdav 的沙箱测试（全设备通用）。
#
# 重点覆盖 run#78 刷机现场踩到的两个真故障：
#   · 加了 set -u + source functions.sh → 脚本在写配置前退出，lighttpd 用默认 80 抢了 LuCI
#   · 在 conf.d 里覆盖 server.document-root → lighttpd 报 Duplicate config variable 拒绝启动
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRESS="$ROOT/common/files/etc/uci-defaults/90-lighttpd-webdav"
# ⚠️ 必须 cd 进去再 pwd 取 POSIX 路径：Windows 的 mktemp -d 返回 "C:\Users\...\tmp.xxx"，
# 这种路径塞进 PATH 会被盘符的冒号截断，桩命令就找不到了。
SB="$(cd "$(mktemp -d)" && pwd)"
trap 'rm -rf "$SB"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }

# mk_sb <场景名> <lighttpd -p 输出的端口；空=解析不出>
mk_sb() {
	local d="$SB/$1" port="${2-8080}"
	mkdir -p "$d/lighttpd/conf.d" "$d/share" "$d/bin" "$d/lib"
	# 主配置模板：与包自带 lighttpd.conf 同构（document-root 引用 var）
	cat > "$d/lighttpd/lighttpd.conf" <<'CONF'
var.log_root    = "/var/log/lighttpd/"
var.server_root = "/www/"
var.state_dir   = "/var/run/"
var.home_dir    = "/var/lib/lighttpd/"

server.document-root        = server_root
server.upload-dirs          = ( "/tmp" )
include "/etc/lighttpd/conf.d/*.conf"
CONF
	cat > "$d/bin/lighttpd" <<EOF
#!/bin/sh
case "\$1" in
  -p) [ -n "$port" ] && echo "    server.port                    = $port"; exit 0 ;;
  *)  exit 0 ;;
esac
EOF
	chmod +x "$d/bin/lighttpd"
	cat > "$d/init" <<EOF
#!/bin/sh
echo "\$1" >> "$d/init.calls"
exit 0
EOF
	chmod +x "$d/init"
	# functions.sh 里带一处未定义变量引用：脚本若加了 set -u 就会在这里退出
	cat > "$d/lib/functions.sh" <<'EOF'
user_exists() { return 1; }
user_add() { return 0; }
EOF
	echo "$d"
}

run_press() {
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
[ ! -e "$d/conf.d" ] && ok "未产生任何副作用" || bad "不该创建目录"

echo "== 2. 正常写入（不得触碰全局变量）=="
d=$(mk_sb ok 8080)
out=$(run_press "$d"); rc=$?
CONF="$d/lighttpd/lighttpd.conf"; F="$d/lighttpd/conf.d/zz-webdav-share.conf"
[ "$rc" = 0 ] && ok "退出码 0" || bad "退出码应为 0，实际 $rc"
grep -q '^var\.server_root = "/mnt/webdav/"' "$CONF" && ok "var.server_root 已改（不覆盖 document-root）" || bad "var.server_root 未改"
grep -qE '^server\.port + = 8080' "$CONF" && ok "server.port 已插入" || bad "server.port 未插入"
grep -qE '^server\.document-root += server_root' "$CONF" && ok "document-root 仍是变量引用（不会被判重复）" || bad "document-root 被改坏了"
grep -qE 'server\.document-root *=' "$F" && bad "片段里不该出现 document-root" || ok "片段未碰全局变量"
grep -q 'webdav.activate       = "enable"' "$F" && ok "片段启用 WebDAV" || bad "片段未启用"
grep -q 'webdav.sqlite-db-name = home_dir' "$F" && ok "锁库在 home_dir（/etc 不可写）" || bad "锁库路径不对"
[ -d "$d/share" ] && ok "共享目录已创建" || bad "共享目录未创建"
grep -q '^enable$' "$d/init.calls" 2>/dev/null && ok "init enable" || bad "init enable 未调用"
grep -q '^restart$' "$d/init.calls" 2>/dev/null && ok "init restart" || bad "init restart 未调用"

echo "== 3. 幂等（重复执行）=="
before=$(md5sum "$CONF" "$F" | awk '{print $1}' | tr '\n' ' ')
run_press "$d" >/dev/null 2>&1
after=$(md5sum "$CONF" "$F" | awk '{print $1}' | tr '\n' ' ')
[ "$before" = "$after" ] && ok "两份文件均未变" || bad "重复执行改动了文件"
[ "$(grep -c '^server\.port' "$CONF")" = 1 ] && ok "server.port 只有一条" || bad "server.port 重复"

echo "== 4. 端口闸门：解析出 80 → 回滚 + 停用（run#78 事故防线）=="
d=$(mk_sb port80 80)
out=$(run_press "$d"); rc=$?
CONF="$d/lighttpd/lighttpd.conf"
[ "$rc" = 0 ] && ok "退出码 0（不阻断开机）" || bad "退出码应为 0"
grep -q '^var\.server_root = "/www/"' "$CONF" && ok "主配置已回滚" || bad "主配置未回滚"
[ ! -f "$d/lighttpd/conf.d/zz-webdav-share.conf" ] && ok "片段已撤掉" || bad "片段仍在"
grep -q '^stop$' "$d/init.calls" 2>/dev/null && ok "已 stop" || bad "未 stop"
grep -q '^disable$' "$d/init.calls" 2>/dev/null && ok "已 disable（开机不再拉起）" || bad "未 disable"
grep -q '^restart$' "$d/init.calls" 2>/dev/null && bad "闸门失败却 restart 了" || ok "未启动 lighttpd"

echo "== 5. 解析不出端口 → 不启动（不赌它会不会退回 80）=="
d=$(mk_sb noport "")
out=$(run_press "$d"); rc=$?
[ "$rc" = 0 ] && ok "退出码 0" || bad "退出码应为 0"
[ ! -f "$d/lighttpd/conf.d/zz-webdav-share.conf" ] && ok "片段已撤掉" || bad "片段仍在"
grep -q '^stop$' "$d/init.calls" 2>/dev/null && ok "已 stop" || bad "未 stop"
grep -q '^restart$' "$d/init.calls" 2>/dev/null && bad "解析失败仍启动" || ok "未启动 lighttpd"

echo "== 6. 脚本本身不得再用 set -u =="
grep -qE '^[[:space:]]*set -u' "$PRESS" && bad "仍存在 set -u（会让 source functions.sh 提前退出）" || ok "无 set -u"

echo "== 7. 公共清单：lighttpd 已取代 dufs =="
LITE="$ROOT/common/configs/lite.list"
grep -q '^CONFIG_PACKAGE_lighttpd=y' "$LITE" && ok "lite.list 启用 lighttpd" || bad "缺 lighttpd"
grep -q '^CONFIG_PACKAGE_lighttpd-mod-webdav=y' "$LITE" && ok "lite.list 启用完整版模块" || bad "缺 webdav 模块"
grep -qE '^CONFIG_PACKAGE_dufs=y' "$LITE" && bad "lite.list 仍要求 dufs" || ok "lite.list 无 dufs"
dup=0
for f in "$ROOT"/devices/*/configs/*.list; do
	[ -f "$f" ] || continue
	grep -qE '^CONFIG_PACKAGE_(dufs|lighttpd)' "$f" && dup=1
done
[ "$dup" = 0 ] && ok "设备清单无重复声明" || bad "设备清单重复声明"
[ ! -d "$ROOT/common/package/luci-app-dufs" ] && ok "vendor dufs 面板已删" || bad "vendor 包仍在"

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
