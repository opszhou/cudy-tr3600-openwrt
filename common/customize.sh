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

# ---- ndisc6：已在 common/configs/modem.list 用 choice 关闭（不再参与构建）----
# 背景：qmodem feed 的 ndisc6 1.0.2 源 remlab.net 已 410；升到 Debian 池 1.0.8 后
#       又因 src/trace-tcp.c 用 C11 alignas、而该包带 -std=c99 编译失败（run#17）。
# 恢复：修 trace-tcp.c 的 alignas（改 __attribute__((aligned))），choice 改回 INCLUDE_ndisc6。
