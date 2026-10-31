#!/usr/bin/env bash
# 公共定制脚本：在 openwrt 根目录下执行（feeds 安装之后、defconfig 之前，每次构建都会运行）。

# 修改默认 LAN IP（已由 uci-defaults 预设实现为 192.168.10.1，见 common/files/etc/uci-defaults/99-router-presets；
# 如需构建期修改而非首启修改，可取消下行注释）
# sed -i 's/192.168.1.1/192.168.10.1/g' package/base-files/files/bin/config_generate

# 修改默认固件名称显示
# sed -i 's/OpenWrt/MyWrt/g' package/base-files/files/bin/config_generate

# 修改默认主题为 Argon（仅当本组合预装了该主题时才替换，避免影响精简组合）
if grep -q '^CONFIG_PACKAGE_luci-theme-argon=y' .config 2>/dev/null \
   && [ -f feeds/luci/collections/luci/Makefile ]; then
    sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile
fi

# ---- 修复 QModem feed 自带的 ndisc6（qmodem 主包 kconfig 默认 INCLUDE，源死了会挂掉整个构建）----
# 现状：feed 里的 1.0.2 源 URL http://www.remlab.net/files/ndisc6 已 410 Gone，全网无 1.0.2 镜像，
#       官方 packages feed 也已删除 ndisc6。升级到 Debian 池 1.0.8（实测可下载）：
#       - 100-favor_bsd.patch：1.0.8 的 trace-tcp/udp.c 已重构（无 _BSD_SOURCE 锚点行），必须移除
#       - 110-strverscmp.patch：1.0.8 已无 rdnssd/ 目录，锚点不存在，必须移除
#       上游（FUjr/QModem）修复后此段自动变为空操作（grep 不中即跳过），届时可删除本段。
NDISC6_MAKEFILES="
feeds/qmodem/application/ndisc6/Makefile
package/feeds/qmodem/ndisc6/Makefile
"
for f in $NDISC6_MAKEFILES; do
    if [ -f "$f" ] && grep -q "remlab.net" "$f"; then
        echo "修复 ndisc6 源: $f"
        sed -i 's/^PKG_VERSION:=.*/PKG_VERSION:=1.0.8/' "$f"
        sed -i 's|^PKG_SOURCE_URL:=.*|PKG_SOURCE_URL:=https://deb.debian.org/debian/pool/main/n/ndisc6|' "$f"
        sed -i 's/^PKG_MD5SUM:=.*/PKG_HASH:=1f2fb2dc1172770aa5a09d39738a44d8b753cc5e2e25e306ca78682f9fea0b4f/' "$f"
        # Debian orig 压缩包命名（ndisc6_1.0.8.orig.tar.bz2）与 OpenWrt 默认不同，无条件覆盖
        sed -i 's|^PKG_SOURCE:=.*|PKG_SOURCE:=ndisc6_1.0.8.orig.tar.bz2|' "$f"
        PDIR="$(dirname "$f")/patches"
        [ -d "$PDIR" ] && rm -f "$PDIR"/*.patch && echo "已移除不兼容的 ndisc6 本地 patch"
    fi
done
