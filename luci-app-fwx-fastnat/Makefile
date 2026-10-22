include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI app for FWX Fastnat
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+luci-compat +luci-lib-jsonc +luci-app-fwx-resources +kmod-shortcut-fe +fwxd

PKG_NAME:=luci-app-fwx-fastnat
PKG_VERSION:=1.0
PKG_RELEASE:=2

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
