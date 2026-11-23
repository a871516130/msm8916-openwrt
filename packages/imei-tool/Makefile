# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=imei-tool
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=local

include $(INCLUDE_DIR)/package.mk

define Package/imei-tool
	SECTION:=utils
	CATEGORY:=Utilities
	TITLE:=Read/write the modem IMEI (NV item 550) via DIAG
	DEPENDS:=+diag-bind +qmi-utils
endef

define Package/imei-tool/description
	Read or write the modem IMEI on UFI MF32 / MSM8916 devices.

	The IMEI is stored in modem NV item 550 (0x226).  Writes go through
	the DIAG NV write (opcode 0x27); a short delay lets the modem's EFS2
	garbage collector commit the value so it survives a reboot.

	Requires the DIAG bridge (/dev/rpmsg0), provided by the diag-bind
	service.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(CURDIR)/src/imei-tool.c $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) -Os -o $(PKG_BUILD_DIR)/imei-tool \
		$(PKG_BUILD_DIR)/imei-tool.c
endef

define Package/imei-tool/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/imei-tool $(1)/usr/sbin/imei-tool
endef

$(eval $(call BuildPackage,imei-tool))
