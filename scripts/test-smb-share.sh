#!/usr/bin/env bash
# SMB 共享（samba4）预设的沙箱测试。
#
# 覆盖两件事：
#   1. 清单：samba4-server 与 luci-app-samba4 必须在（写错包名 Kconfig 会静默丢弃）
#   2. /etc/config/samba4：共享段字段齐全、有 CPU 降优先级设置、没有残留模板值
#
# 用法: bash scripts/test-smb-share.sh   （无参数）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LITE="$ROOT/common/configs/lite.list"
CONF="$ROOT/common/files/etc/config/samba4"

for f in "$LITE" "$CONF"; do
	[ -f "$f" ] || { echo "FAIL: 找不到 $f" >&2; exit 1; }
done

pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); }
bad() { echo "  ✗ $1" >&2; fail=$((fail + 1)); }
present(){ if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3（在 $1 里找不到 $2）"; fi; }
absent(){ if grep -qF -- "$2" "$1"; then bad "$3（$1 里仍有 $2）"; else ok "$3"; fi; }

# ---- 1. 清单 ---------------------------------------------------------------
echo "[1] 包清单"
present "$LITE" 'CONFIG_PACKAGE_samba4-server=y'   'samba4 服务端在清单里'
present "$LITE" 'CONFIG_PACKAGE_luci-app-samba4=y' 'SMB 面板（服务 → 网络共享）在清单里'
absent  "$LITE" 'CONFIG_PACKAGE_ksmbd-server=y'    'ksmbd 已从清单移除（内核态风险）'
absent  "$LITE" 'CONFIG_PACKAGE_kmod-fs-ksmbd=y'   'ksmbd 内核模块已移除'

# ---- 2. samba4 预设 --------------------------------------------------------
echo "[2] /etc/config/samba4"
present "$CONF" 'config samba'                 '有全局段'
present "$CONF" 'config sambashare'            '有共享段'
present "$CONF" "option name 'share'"          '共享名是 share'
present "$CONF" "option path '/mnt'"           '共享路径是 /mnt（U 盘挂载点父目录）'
present "$CONF" "option guest_ok 'yes'"        '允许无账号访问（老电视盒子需要）'
present "$CONF" "option read_only 'no'"        '默认可读写'
present "$CONF" 'config procd'                 '有 procd 段'
present "$CONF" "option samba_nice '3'"        'smbd 降优先级（不跟拨号抢 CPU）'
absent  "$CONF" '/mnt/tmp'                     '没有残留模板的 /mnt/tmp'

if grep -qE "^[[:space:]]+option[[:space:]]+[a-z_]+[[:space:]]+'[^']*'$" "$CONF"; then
	ok "option 行格式合法（option key 'value'）"
else
	bad "option 行格式可疑（应为 option key 'value'）"
fi

echo
if [ "$fail" -eq 0 ]; then
	echo "全部通过：$pass 项"
else
	echo "失败 $fail 项（通过 $pass 项）" >&2
	exit 1
fi
