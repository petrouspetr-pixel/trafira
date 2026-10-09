include $(TOPDIR)/rules.mk

PKG_NAME:=trafira-warp-scout
PKG_VERSION:=0.16.0
PKG_RELEASE:=1

PKG_SOURCE:=warpscout-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/vernette/warpscout/tar.gz/refs/tags/v$(PKG_VERSION)?
PKG_HASH:=c21c777239856401f6529e4e2503d9f6ebd9071f78988fe86e35aaefc65a1c20
PKG_BUILD_DIR:=$(BUILD_DIR)/warpscout-$(PKG_VERSION)

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=luci-app-trafira-warp contributors

TRAFIRA_HOST_GO?=$(shell command -v go)
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

include $(INCLUDE_DIR)/package.mk

define Package/trafira-warp-scout
  SECTION:=net
  CATEGORY:=Network
  TITLE:=WARP endpoint discovery helper for luci-app-trafira-warp
  URL:=https://github.com/vernette/warpscout
  DEPENDS:=@(aarch64) +ca-bundle
endef

define Package/trafira-warp-scout/description
  A private WARPSCOUT build used to register WARP and select a verified
  AmneziaWG endpoint outside excluded exit locations.
endef

define Build/Compile
	cd $(PKG_BUILD_DIR) && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 GOTOOLCHAIN=local $(TRAFIRA_HOST_GO) build -trimpath -ldflags "-s -w" -o $(PKG_BUILD_DIR)/trafira-warp-scout .
endef

define Package/trafira-warp-scout/install
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/trafira-warp-scout $(1)/usr/libexec/trafira-warp-scout
	$(INSTALL_DIR) $(1)/usr/share/licenses/trafira-warp-scout
	$(INSTALL_DATA) $(CURDIR)/LICENSE $(1)/usr/share/licenses/trafira-warp-scout/LICENSE
endef

define Package/trafira-warp-scout/conffiles
endef

$(eval $(call BuildPackage,trafira-warp-scout))
