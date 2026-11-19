#!/usr/bin/env bash
# SMB 共享（ksmbd）预设的沙箱测试。
#
# 覆盖两件事：
#   1. 清单：ksmbd 三件套必须在（写错包名不会报错，Kconfig 会静默丢弃，只有断言能拦）
#   2. /etc/config/ksmbd：共享段字段齐全、格式合法、没有残留上游模板值（testshare / /tmp）
#
# 用法: bash scripts/test-smb-share.sh   （无参数）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LITE="$ROOT/common/configs/lite.list"
KSMBD="$ROOT/common/files/etc/config/ksmbd"

for f in "$LITE" "$KSMBD"; do
	[ -f "$f" ] || { echo "FAIL: 找不到 $f" >&2; exit 1; }
done

pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); }
bad() { echo "  ✗ $1" >&2; fail=$((fail + 1)); }
present(){ if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3（在 $1 里找不到 $2）"; fi; }
absent(){ if grep -qF -- "$2" "$1"; then bad "$3（$1 里仍有 $2）"; else ok "$3"; fi; }

# ---- 1. 清单 ---------------------------------------------------------------
echo "[1] 包清单"
present "$LITE" 'CONFIG_PACKAGE_kmod-fs-ksmbd=y'  '内核态 SMB 模块在清单里'
present "$LITE" 'CONFIG_PACKAGE_ksmbd-server=y'    'ksmbd 服务端在清单里'
present "$LITE" 'CONFIG_PACKAGE_luci-app-ksmbd=y'  'SMB 面板（服务 → 网络共享）在清单里'

# ---- 2. ksmbd 共享预设 -----------------------------------------------------
echo "[2] /etc/config/ksmbd"
present "$KSMBD" 'config share'            '有分享段'
present "$KSMBD" "option name 'share'"     '分享名是 share'
present "$KSMBD" "option path '/mnt'"      '分享路径是 /mnt（U 盘挂载点父目录）'
present "$KSMBD" "option guest_ok 'yes'"   '默认免密（家庭内网常规做法）'
present "$KSMBD" "option read_only 'no'"   '默认可读写'
absent  "$KSMBD" "'testshare'"             '没有残留上游模板的 testshare'
absent  "$KSMBD" "option path '/tmp'"      '没有残留上游模板的 /tmp（内存盘，重启即丢）'
if grep -qE "^[[:space:]]+option[[:space:]]+[a-z_]+[[:space:]]+'[^']*'$" "$KSMBD"; then
	ok "option 行格式合法（option key 'value'）"
else
	bad "option 行格式可疑（应为 option key 'value'）"
fi
# uci 段必须能被 config_load 认出来：段名与键名都不带引号
if grep -qE '^config[[:space:]]+[a-z]+$' "$KSMBD"; then
	ok "config 段行格式合法"
else
	bad "config 段行格式可疑（应为 config <name>）"
fi

echo
if [ "$fail" -eq 0 ]; then
	echo "全部通过：$pass 项"
else
	echo "失败 $fail 项（通过 $pass 项）" >&2
	exit 1
fi
