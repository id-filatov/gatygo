include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-gatygo
PKG_VERSION:=20260918.1753
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=id-filatov
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-gatygo
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=gatygo status and settings page
  URL:=https://github.com/id-filatov/gatygo
  DEPENDS:=+gatygo +luci-base
  PKGARCH:=all
endef

define Package/luci-app-gatygo/description
 LuCI pages for gatygo: connection state and country switch, subscription
 settings and log. Talks to the daemon through the rpcd plugin it ships.
endef

define Build/Compile
endef

define Package/luci-app-gatygo/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/gatygo $(1)/usr/share/luci/menu.d $(1)/usr/share/rpcd/acl.d $(1)/usr/libexec/rpcd
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/gatygo/*.js $(1)/www/luci-static/resources/view/gatygo/
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-gatygo.json $(1)/usr/share/luci/menu.d/luci-app-gatygo.json
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-gatygo.json $(1)/usr/share/rpcd/acl.d/luci-app-gatygo.json
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/gatygo $(1)/usr/libexec/rpcd/gatygo
endef

define Package/luci-app-gatygo/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || { /etc/init.d/rpcd reload; rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null; }
exit 0
endef

define Package/luci-app-gatygo/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || { /etc/init.d/rpcd reload; rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null; }
exit 0
endef

$(eval $(call BuildPackage,luci-app-gatygo))
