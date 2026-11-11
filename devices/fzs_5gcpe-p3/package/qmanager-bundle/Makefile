# SPDX-License-Identifier: GPL-2.0-only
#
# QManager（dr-dolomite/QManager）——Quectel 模组的独立 Web 控制台。
#
# 它不是 LuCI 应用、也不在任何 feed 里，上游只发"GitHub Release tar.gz + install.sh"。
# 因此这里做的是"载荷包"：把 release tarball 原样打进镜像，首启由 uci-defaults 离线执行
# 上游 install.sh。好处是：
#   - 版本 lock 在 PKG_VERSION，构建可复现（PKG_HASH 校验，供应链上也安全）
#   - 不替上游重写安装逻辑，上游怎么改都得跟着，不会悄悄偏离
#
# 只在 build.yml 勾选 with_qmanager 时启用（configs/qmanager.list）。
# ⚠️ 它是完整的模组管理器，会与 QModem 抢同一个 AT 口/拨号权 —— 二者只能选一个当主界面。

include $(TOPDIR)/rules.mk

PKG_NAME:=qmanager-bundle
PKG_VERSION:=0.1.35
PKG_RELEASE:=1

PKG_SOURCE:=qmanager.tar.gz
PKG_SOURCE_URL:=https://github.com/dr-dolomite/QManager/releases/download/v$(PKG_VERSION)
PKG_HASH:=4eb567af1dfa008b0e59e8621bdd4434bdbe03b97dfe37e703552b246814c3b9
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/qmanager-bundle
  SECTION:=net
  CATEGORY:=Network
  TITLE:=QManager web console payload (Quectel modem UI, offline install at first boot)
  URL:=https://github.com/dr-dolomite/QManager
  DEPENDS:=+jq +curl +coreutils-timeout +ethtool
endef

define Package/qmanager-bundle/description
 QManager 的离线载荷：release 包原样放入 /usr/share/qmanager，
 首启由 /etc/uci-defaults/91-qmanager-install.sh 执行上游 install.sh。
 仅支持 Quectel AT 模组，且不可与 QModem 拨号同时启用。
endef

define Build/Compile
endef

define Package/qmanager-bundle/install
	$(INSTALL_DIR) $(1)/usr/share/qmanager
	$(INSTALL_DATA) $(DL_DIR)/$(PKG_SOURCE) $(1)/usr/share/qmanager/qmanager.tar.gz
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/91-qmanager-install.sh $(1)/etc/uci-defaults/91-qmanager-install.sh
endef

$(eval $(call BuildPackage,qmanager-bundle))
