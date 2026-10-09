include $(TOPDIR)/rules.mk
PKG_NAME:=luci-app-trafira-warp
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_BUILD_DEPENDS:=luci-base/host
include $(INCLUDE_DIR)/package.mk

define Package/luci-app-trafira-warp
  SECTION:=luci
  CATEGORY:=LuCI
  TITLE:=Optional WARP management for Trafira
  DEPENDS:=+luci-base +trafira +trafira-warp-awg +trafira-warp-scout +ucode +ucode-mod-fs +ucode-mod-uci +curl +ca-bundle +jsonfilter +ip-full
endef

define Build/Compile
	$(STAGING_DIR_HOSTPKG)/bin/po2lmo ./po/ru/trafira-warp.po $(PKG_BUILD_DIR)/trafira-warp.ru.lmo
endef

define Package/luci-app-trafira-warp/conffiles
/etc/config/trafira-warp
/etc/trafira-warp/
endef

define Package/luci-app-trafira-warp/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/usr/share/licenses/luci-app-trafira-warp
	$(CP) ./root/* $(1)/
	$(INSTALL_DIR) $(1)/www $(1)/usr/lib/lua/luci/i18n
	$(CP) ./htdocs/* $(1)/www/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/trafira-warp.ru.lmo $(1)/usr/lib/lua/luci/i18n/
	$(INSTALL_DATA) ./LICENSE $(1)/usr/share/licenses/luci-app-trafira-warp/LICENSE
	$(INSTALL_DATA) ../NOTICE.md $(1)/usr/share/licenses/luci-app-trafira-warp/NOTICE
endef

$(eval $(call BuildPackage,luci-app-trafira-warp))
