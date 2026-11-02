# SPDX-License-Identifier: Apache-2.0
#
# Copyright (C) 2024 ImmortalWrt.org

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for dufs
LUCI_DEPENDS:=+dufs

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Tianling Shen <cnsztl@immortalwrt.org>

# 本目录是 vendored 到 package/ 的（不是 feeds/luci/applications 下），
# 所以 ../../luci.mk 会解析到不存在的 $(TOPDIR)/luci.mk，必须指到 luci feed 里的那份
include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
