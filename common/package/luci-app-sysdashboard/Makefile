# SPDX-License-Identifier: Apache-2.0
#
# luci-app-sysdashboard -- read-only system dashboard (this project's own code)

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for the system dashboard (CPU / memory / traffic / fan)
LUCI_DEPENDS:=+luci-base

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=cudy-tr3600-openwrt

# Vendored into the source tree's package/ directory (not a feed), so the
# relative ../../luci.mk would resolve to a non-existent $(TOPDIR)/luci.mk.
include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
