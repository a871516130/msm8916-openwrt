#
# Unified cellular network page: modem status, SIM info, SIM slot switching
# and IMEI read/write.  Replaces the standalone imei and sim-select LuCI
# pages with a single Chinese-localized "蜂窝网络" page.
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=Cellular network: modem status, SIM info, SIM switch, IMEI
LUCI_DESCRIPTION:=LuCI page showing ModemManager/QMI modem status, SIM card state, physical-SIM/eSIM runtime switching and IMEI read/write via imei-tool.
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+luci-lua-runtime +imei-tool +msm89xx-scripts +qmi-utils +modemmanager

PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
