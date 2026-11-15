# SPDX-License-Identifier: Apache-2.0
#
# luci-app-sysdashboard -- read-only dashboard widgets for luci-mod-dashboard
# (rpcd snapshot + include/catalog modules; there is no standalone LuCI page)

include $(TOPDIR)/rules.mk

LUCI_TITLE:=Dashboard widgets for luci-mod-dashboard (signal / uplink / clients / traffic)
LUCI_DEPENDS:=+luci-base +luci-mod-dashboard

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=cudy-tr3600-openwrt

# Vendored into the source tree's package/ directory (not a feed), so the
# relative ../../luci.mk would resolve to a non-existent $(TOPDIR)/luci.mk.
include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
