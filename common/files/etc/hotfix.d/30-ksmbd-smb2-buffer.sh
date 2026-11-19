#!/bin/sh
# ksmbd：把 smb2 max read/write/trans 从 1M 降到 64K
#
# 现象（2026-11-19 真机实测，FZS 5GCPE P3）：
#   内核态 ksmbd **读文件**必卡死 —— 哪怕只读 3 字节，也会把系统冻住，
#   31 秒后 mtk 看门狗复位，表现成「设备莫名重启」。写文件反而正常。
#   崩溃没有 panic 转储（pstore 空）、没有 boot_reason，很容易误判成电源或固件问题。
#
# 原因：ksmbd 的 init（/etc/init.d/ksmbd 的 config_get_ram）按 MemTotal 分档给 SMB2 缓冲，
#   128MB~256MB 这一档给的是 1M。这台机 233MB 内存、overlay 是 ubifs，
#   1M 缓冲的读路径会炸。
#
# 验证：改成 64K 后 2MB 随机文件「写入 + 读回逐字节一致」，连续运行无重启。
#
# 做法：改 /var/etc/ksmbd/ksmbd.conf（/etc/ksmbd/ksmbd.conf 是指向它的软链），再让 mountd 重载。
# 幂等：已经是 64K 就什么都不做；没装 ksmbd 的设备等不到配置文件，直接退出。
#
# ⚠️ ksmbd 与 hotfix 同为 START=98，conf 可能还没生成，所以先等最多 10 秒。

CONF=/var/etc/ksmbd/ksmbd.conf

i=0
while [ ! -f "$CONF" ] && [ "$i" -lt 10 ]; do
	sleep 1
	i=$((i + 1))
done
[ -f "$CONF" ] || exit 0

grep -q 'smb2 max read = 1M' "$CONF" || exit 0

sed -i \
	-e 's/smb2 max read = 1M/smb2 max read = 64K/' \
	-e 's/smb2 max write = 1M/smb2 max write = 64K/' \
	-e 's/smb2 max trans = 1M/smb2 max trans = 64K/' \
	"$CONF"

/usr/sbin/ksmbd.control -r >/dev/null 2>&1
logger -t hotfix "ksmbd: SMB2 缓冲降到 64K（1M 会导致读文件卡死重启）"
exit 0
