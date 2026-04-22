include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-warren
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-warren
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Warren LuCI interface
  DEPENDS:=+luci-base +luci-compat
endef

define Package/luci-app-warren/description
  LuCI UI for Warren OpenWrt router/VPS assistant.
endef

define Build/Compile
endef

define Package/luci-app-warren/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/warren.lua $(1)/usr/lib/lua/luci/controller/warren.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/warren
	$(INSTALL_DATA) ./luasrc/view/warren/index.htm $(1)/usr/lib/lua/luci/view/warren/index.htm
	$(INSTALL_DIR) $(1)/usr/libexec/warren
	$(INSTALL_BIN) ./root/usr/libexec/warren/warren-luci-run $(1)/usr/libexec/warren/warren-luci-run
endef

$(eval $(call BuildPackage,luci-app-warren))
