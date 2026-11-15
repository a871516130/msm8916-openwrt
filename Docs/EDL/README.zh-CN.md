> 📄 本文件是 [README.md](README.md) 的英文原文中文译本，内容以英文版为准。

# MSM8916 高通重启至 EDL、Fastboot 与系统模式

## 概述

本目录包含关于高通 Snapdragon 410（MSM8916）OpenWrt 设备的硬件重启模式（PBL 9008 EDL、SBL1 9006 DLOAD、Android Fastboot、Recovery）以及安全用户态拆解的全面文档。

## 主文档索引

- [**MSM8916 重启至 EDL 完整实现指南**](MSM8916_Reboot_to_EDL_Complete_Implementation_Guide.md)：权威指南，涵盖 IMEM cookie 的逆向工程、内核重启处理程序、两级用户态编排器、常规重启 `umount-overlay` 干净卸载修复以及实机硬件测试结果。

---

## 快速参考：硬件模式命令

```bash
# Reboot into Qualcomm 9008 Emergency Download Mode (PBL)
reboot-edl

# Reboot into Qualcomm 9006 Mass Storage / Dump Mode (SBL1)
reboot-dload

# Reboot into Fastboot Bootloader Mode (aboot / lk2nd)
reboot-bootloader

# Reboot into Android Recovery Mode
reboot-recovery

# Normal Safe Reboot (cleanly unmounts EXT4 overlay)
reboot
```
