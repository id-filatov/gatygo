include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-gatygo
PKG_VERSION:=20260930.1259
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=id-filatov
PKGARCH:=all

# the languages the pages are translated into: po/<lang>/gatygo.po
GATYGO_LANGS:=$(notdir $(patsubst %/,%,$(dir $(wildcard ./po/*/gatygo.po))))

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
	$(foreach l,$(GATYGO_LANGS),python3 ./po/po2lmo.py ./po/$(l)/gatygo.po $(PKG_BUILD_DIR)/gatygo.$(l).lmo;)
endef

define Package/luci-app-gatygo/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/gatygo $(1)/usr/share/luci/menu.d $(1)/usr/share/rpcd/acl.d $(1)/usr/libexec/rpcd
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/gatygo/*.js $(1)/www/luci-static/resources/view/gatygo/
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-gatygo.json $(1)/usr/share/luci/menu.d/luci-app-gatygo.json
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-gatygo.json $(1)/usr/share/rpcd/acl.d/luci-app-gatygo.json
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/gatygo $(1)/usr/libexec/rpcd/gatygo
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/gatygo.*.lmo $(1)/usr/lib/lua/luci/i18n/
endef

define Package/luci-app-gatygo/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/rpcd reload; rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null
	# offer the languages the pages speak (System > Language, and "auto" by the browser)
	for l in $(GATYGO_LANGS); do
		uci -q get luci.languages.$$l >/dev/null && continue
		case $$l in ru) n='Русский (Russian)' ;; *) n=$$l ;; esac
		uci -q get luci.languages >/dev/null || uci set luci.languages=internal
		# "auto" takes the first browser language registered here and LuCI never registers
		# English itself: without it a browser listing English first, then this one, would switch
		uci -q get luci.languages.en >/dev/null || uci set luci.languages.en='English'
		uci set luci.languages.$$l="$$n" && uci commit luci
	done
}
exit 0
endef

define Package/luci-app-gatygo/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/rpcd reload; rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null
	# a language stays offered while another package still translates LuCI into it
	for l in $(GATYGO_LANGS); do
		ls /usr/lib/lua/luci/i18n/*.$$l.lmo >/dev/null 2>&1 && continue
		uci -q delete luci.languages.$$l && uci commit luci
	done
	# the English entry postinst added goes once no other language needs it
	[ "$$(uci -q show luci.languages | grep -c '^luci\.languages\.')" = 1 ] && [ "$$(uci -q get luci.languages.en)" = English ] && { uci -q delete luci.languages.en; uci commit luci; }
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-gatygo))
