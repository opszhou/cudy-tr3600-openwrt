#!/usr/bin/env bash
# 公共定制脚本：在 openwrt 根目录下执行（feeds 安装之前，每次构建都会运行）。
# 以下示例按需取消注释，也可在此追加任意 shell 定制。

# 修改默认 LAN IP
# sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate

# 修改默认固件名称显示
# sed -i 's/OpenWrt/MyWrt/g' package/base-files/files/bin/config_generate

# 修改默认主题为 Argon（仅当本组合预装了该主题时才替换，避免影响精简组合）
if grep -q '^CONFIG_PACKAGE_luci-theme-argon=y' .config; then
    sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile
fi
