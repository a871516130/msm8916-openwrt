> 📄 本文件是 [README.md](README.md) 的英文原文中文译本，内容以英文版为准。

# MSM8916 OpenWrt Sysupgrade 与 LuCI 固件升级指南

## 概述

本目录包含关于高通 Snapdragon 410（MSM8916）4G USB 棒状设备（包括 HMU05、
UFI001B、UZ801v3、UF02 和 MF800B）OpenWrt 固件升级的完整文档。

## 文档索引

- [**MSM8916 Sysupgrade 与 LuCI 架构指南**](MSM8916_Sysupgrade_and_LuCI_Architecture_Guide.md)：完整的架构深入讲解、LuCI 间歇性失败的根因分析、`platform.sh` 中的技术修复、CLI 与 LuCI 选项参考，以及分步操作流程。
- [**干净安装后的首次启动：固件转储（以及那 45 秒）**](FIRST_BOOT_FIRMWARE_DUMP.md)：为什么 `sysupgrade -n` 会让设备在首次启动从 overlay 中解出固件之前*没有*固件——失败的 `-2` 加载、实测的 39 s 与 17 s 时间线，以及为什么这不是回归。

---

## 快速参考：刷写方法

### 1. 命令行 Sysupgrade（CLI）

```bash
# Transfer image to device
scp openwrt-msm89xx-msm8916-<board>-squashfs-sysupgrade.bin root@192.168.8.1:/tmp/sysupgrade.bin

# Upgrade while preserving configuration
ssh root@192.168.8.1 "sysupgrade -v /tmp/sysupgrade.bin"

# Clean upgrade (wipe configuration and reset overlay)
ssh root@192.168.8.1 "sysupgrade -n -v /tmp/sysupgrade.bin"

# Force upgrade (override board metadata check)
ssh root@192.168.8.1 "sysupgrade -F -v /tmp/sysupgrade.bin"
```

### 2. LuCI Web 界面升级

1. 打开浏览器并访问 `http://192.168.8.1/cgi-bin/luci/admin/system/flashops`。
2. 在 **Flash new firmware image** 下点击 **Browse** 并选择 `openwrt-msm89xx-msm8916-<board>-squashfs-sysupgrade.bin`。
3. 点击 **Upload...**。
4. LuCI 校验镜像校验和与板子兼容性元数据。
5. 选择是否勾选 **Keep settings and retain the current configuration**：
   - **勾选**（等价于 `sysupgrade`）：保留 `/etc/config/*` 和已还原的 overlay。
   - **不勾选**（等价于 `sysupgrade -n`）：把 `rootfs_data` 分区格式化为干净的 EXT4 文件系统。
6. 点击 **Continue** / **Flash**。 设备进入 Stage 2 ramfs，把 kernel 和 rootfs 写入 eMMC，并自动重启。

---

### 3. 内置升级页面（r3 及以后）

从 **r3** 起，设备可以自行发现、校验并安装新发布——
不需要 `scp`，也不需要手动下载：

* **LuCI** —— *System → Firmware Upgrade*（`/cgi-bin/luci/admin/system/firmware-upgrade`）。
  它显示运行中的版本、该板子已发布的版本、镜像大小和发布说明，然后下载、
  校验 SHA-256 并刷写。 **Keep settings** 复选框默认勾选；要 `sysupgrade -n`
  就取消勾选。
* **CLI** —

  ```bash
  firmware-upgrade check          # JSON: available, version, url, sha256, size
  firmware-upgrade status
  firmware-upgrade download       # fetch + sha256 verify into /tmp
  firmware-upgrade apply [--no-keep]
  firmware-upgrade upgrade [--no-keep]   # check + download + apply
  ```

该客户端读取 `firmware.json`——发布流水线在镜像旁边发布的清单——并与本设备的
`DISTRIB_RELEASE` 对比。 它遵守 `min_version` 下限，因此版本太旧无法跳升的
设备会被告知手工刷写一次，而不是拿到一个无法应用的镜像。

> **r1/r2 上的设备没有该客户端。** 它们必须手工刷到 r3；从 r3 起，每个发布
> 都可就地更新。参见
> [How Releases and Hotfixes Work](https://github.com/akbar-npj/msm8916-openwrt/wiki/How-Releases-and-Hotfixes-Work)。

引擎以 `msm89xx-firmware-upgrade` 发行，页面以
`luci-app-firmware-upgrade` 发行（在 `DEFAULT_PACKAGES` 中，因此每块板子
都有）。

---

## 设备不可达时的恢复

这些棒状设备没有以太网口也没有串口排针，因此如果升级把网络协议栈弄坏了，
使用 **failsafe 模式**：

1. 给棒状设备上电（或重启）。
2. **在头 7 秒内按一次 Restart 按钮。** 点按一次就够。 failsafe 激活时
   **LED 快闪**（红色，否则绿色）。
3. 在 **`192.168.10.1`**（USB 网卡）或 **`/dev/ttyACM0`**
   （USB 串口，115200）访问设备：

   ```bash
   ssh root@192.168.10.1
   screen /dev/ttyACM0 115200
   ```

4. 进去后运行 `mount_root` 挂载 overlay，修复 `/etc/config/*`，或
   `firstboot && reboot` 恢复默认值。 如果 `/tmp` 里暂存了 sysupgrade
   镜像，failsafe 会自动执行升级而不是落到 shell。

完整指南：[`Docs/Failsafe/`](../Failsafe/README.md)。 作为最后手段，通过
EDL/Fastboot 重刷（[`Docs/EDL/`](../EDL/)）。
