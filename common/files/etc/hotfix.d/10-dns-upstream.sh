#!/bin/sh
# 兜底上游 DNS（幂等，可反复执行）
#
# 问题：上行若是 QModem 的模组接口（proto='none'，quectel-CM 自己配地址/路由），
#   netifd 拿不到运营商 DNS；WAN 口没插线时也没有。此时
#   /tmp/resolv.conf.d/resolv.conf.auto 为空，dnsmasq 没有任何上游服务器，
#   对**所有**查询回 REFUSED（不是 SERVFAIL）。
#   表现：路由器 ping 得通，客户端「已连接但无互联网」（iOS 的联网探测就是一次域名解析）。
#
# 处置：固定两份公共 DNS 兜底。运营商真下发 DNS 时它们只是并列候选，不影响解析结果。
#   换 DNS 改这里（或临时用 HOTFIX_DNS="x y" 覆盖）。

for dns in ${HOTFIX_DNS:-223.5.5.5 119.29.29.29}; do
	uci -q del_list dhcp.@dnsmasq[0].server="$dns"
	uci -q add_list dhcp.@dnsmasq[0].server="$dns"
done
uci -q commit dhcp

# 让改动立即生效（reload 走 SIGHUP，比 restart 温和；失败再 restart）
DNSMASQ_INIT="${DNSMASQ_INIT:-/etc/init.d/dnsmasq}"
if [ -x "$DNSMASQ_INIT" ]; then
	"$DNSMASQ_INIT" reload >/dev/null 2>&1 || "$DNSMASQ_INIT" restart >/dev/null 2>&1 || true
fi
