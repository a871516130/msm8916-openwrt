# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=qcom-msm8916-gpu-firmware
PKG_VERSION:=1.0
PKG_RELEASE:=1

PKG_LICENSE:=Proprietary
PKG_MAINTAINER:=OpenStick

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
	SECTION:=firmware
	CATEGORY:=Firmware
	TITLE:=Qualcomm Adreno 306 GPU firmware for MSM8916
	DEPENDS:=
	PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
	Adreno 306 (a300_pm4 / a300_pfp) GPU microcode for the Qualcomm MSM8916
	on-die GPU.  The headless msm8916 boards enable the GPU with
	CONFIG_DRM_MSM and msm.separate_gpu_kms=1; without this firmware the
	adreno driver fails to initialise (/dev/dri/renderD128 is never created).
endef

# Files-only package: nothing to compile.  Stub Build/Compile or the build
# system runs `make -C $(PKG_BUILD_DIR)` on an empty dir and fails.
define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/lib/firmware/qcom
	$(CP) ./files/lib/firmware/qcom/a300_pm4.fw $(1)/lib/firmware/qcom/
	$(CP) ./files/lib/firmware/qcom/a300_pfp.fw $(1)/lib/firmware/qcom/
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
