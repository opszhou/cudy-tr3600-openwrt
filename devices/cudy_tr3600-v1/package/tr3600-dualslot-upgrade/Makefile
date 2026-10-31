# SPDX-License-Identifier: GPL-2.0-only
include $(TOPDIR)/rules.mk

PKG_NAME:=tr3600-dualslot-upgrade
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/tr3600-dualslot-upgrade
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=Cudy TR3600 v1 dual-slot sysupgrade integration
  DEPENDS:=+fwtool +uboot-envtools +ubi-utils
  HIDDEN:=1
  PKGARCH:=all
endef

define Package/tr3600-dualslot-upgrade/description
  Adds fail-closed inactive-slot UBI handling for Cudy TR3600 v1 sysupgrade.
endef

define Build/Compile
endef

define Package/tr3600-dualslot-upgrade/install
	$(INSTALL_DIR) $(1)/lib/upgrade
	$(INSTALL_BIN) ./files/zz-tr3600-dualslot.sh \
		$(1)/lib/upgrade/zz-tr3600-dualslot.sh
endef

$(eval $(call BuildPackage,tr3600-dualslot-upgrade))
