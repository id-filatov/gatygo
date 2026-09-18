include $(TOPDIR)/rules.mk

PKG_NAME:=gatygo
PKG_VERSION:=20260918.1525
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=id-filatov
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/gatygo
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=Xray-JSON subscription VPN client with transparent proxy
  URL:=https://github.com/id-filatov/gatygo
  DEPENDS:=+xray-core +jq +curl +ca-bundle +kmod-nft-tproxy +ip-full
  CONFLICTS:=luci-app-passwall luci-app-passwall2
  PKGARCH:=all
endef

define Package/gatygo/description
 Fetches an Xray-JSON subscription, lets you pick a
 profile, runs xray-core with the profile's balancer and routing, and
 transparently proxies the whole LAN via nftables tproxy.
endef

define Package/gatygo/conffiles
/etc/config/gatygo
endef

define Build/Compile
endef

define Package/gatygo/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/usr/lib/gatygo $(1)/etc/init.d $(1)/etc/config $(1)/lib/upgrade/keep.d
	$(INSTALL_BIN) ./files/gatygo $(1)/usr/bin/gatygo
	$(INSTALL_DATA) ./files/lib/* $(1)/usr/lib/gatygo/
	echo "$(PKG_VERSION)" > $(1)/usr/lib/gatygo/version
	$(INSTALL_BIN) ./files/gatygo.init $(1)/etc/init.d/gatygo
	$(INSTALL_CONF) ./files/gatygo.config $(1)/etc/config/gatygo
	$(INSTALL_DATA) ./files/gatygo.keep $(1)/lib/upgrade/keep.d/gatygo
endef

define Package/gatygo/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || { mkdir -p /etc/gatygo && chmod 700 /etc/gatygo; }
exit 0
endef

define Package/gatygo/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /etc/init.d/gatygo stop
exit 0
endef

$(eval $(call BuildPackage,gatygo))
