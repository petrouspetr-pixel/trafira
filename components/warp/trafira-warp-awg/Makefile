include $(TOPDIR)/rules.mk

PKG_NAME:=trafira-warp-awg
PKG_VERSION:=3.1.20260828
PKG_RELEASE:=3

PKG_SOURCE:=amneziawg-go-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/amnezia-vpn/amneziawg-go/tar.gz/refs/tags/v$(PKG_VERSION)?
PKG_HASH:=24c656cfb80ff6855702710eaf2e3729fa710bf6bfdbbbdfba01984ccd17de95
PKG_BUILD_DIR:=$(BUILD_DIR)/amneziawg-go-$(PKG_VERSION)

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=luci-app-trafira-warp contributors

TRAFIRA_HOST_GO?=$(shell command -v go)
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

include $(INCLUDE_DIR)/package.mk

define Package/trafira-warp-awg
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Userspace AmneziaWG backend for luci-app-trafira-warp
  URL:=https://github.com/amnezia-vpn/amneziawg-go
  DEPENDS:=@(aarch64) +kmod-tun +libgcc
endef

define Package/trafira-warp-awg/description
  A private userspace AmneziaWG daemon and minimal UAPI controller used by
  luci-app-trafira-warp. It does not require a kernel-specific AmneziaWG module.
endef

define Build/Prepare
	$(call Build/Prepare/Default)
	$(SED) 's/^const Version = .*/const Version = "$(PKG_VERSION)"/' $(PKG_BUILD_DIR)/version.go
endef

define Build/Compile
	cd $(PKG_BUILD_DIR) && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 GOTOOLCHAIN=local $(TRAFIRA_HOST_GO) build -trimpath -ldflags "-s -w" -o $(PKG_BUILD_DIR)/trafira-warp-amneziawg-go .
	$(TARGET_CC) $(TARGET_CPPFLAGS) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-std=c11 -Wall -Wextra -Werror -o $(PKG_BUILD_DIR)/trafira-warp-awgctl \
		$(CURDIR)/files/warp-awgctl.c
	$(TARGET_CC) $(TARGET_CPPFLAGS) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -std=c11 -Wall -Wextra -Werror -o $(PKG_BUILD_DIR)/trafira-warp-exec $(CURDIR)/files/warp-exec.c
	python3 $(CURDIR)/../dependency_notices.py "$(TRAFIRA_HOST_GO)" "$(PKG_BUILD_DIR)" "$(PKG_BUILD_DIR)/dependency-licenses"
endef

define Package/trafira-warp-awg/install
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/trafira-warp-exec $(1)/usr/libexec/trafira-warp-exec
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/trafira-warp-amneziawg-go $(1)/usr/libexec/trafira-warp-amneziawg-go
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/trafira-warp-awgctl $(1)/usr/libexec/trafira-warp-awgctl
	$(INSTALL_DIR) $(1)/usr/share/licenses/trafira-warp-awg
	$(INSTALL_DATA) $(CURDIR)/LICENSE $(1)/usr/share/licenses/trafira-warp-awg/LICENSE
	$(CP) $(PKG_BUILD_DIR)/dependency-licenses $(1)/usr/share/licenses/trafira-warp-awg/
endef

define Package/trafira-warp-awg/conffiles
endef

$(eval $(call BuildPackage,trafira-warp-awg))
