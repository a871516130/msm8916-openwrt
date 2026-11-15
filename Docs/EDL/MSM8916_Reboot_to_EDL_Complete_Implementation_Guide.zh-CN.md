> 📄 本文件是 [MSM8916_Reboot_to_EDL_Complete_Implementation_Guide.md](MSM8916_Reboot_to_EDL_Complete_Implementation_Guide.md) 的英文原文中文译本，内容以英文版为准。

# 高通 MSM8916：完整重启模式、EDL、Fastboot 与系统更新实现指南

**作者：** OpenWrt MSM8916 移植与稳定性团队  
**目标平台：** 高通 MSM8916 / Snapdragon 410（HMU05、UFI001B、UFI003、UZ801、Generic MSM8916）  
**内核：** Linux 6.12.94 / OpenWrt 25.12.5  
**文档路径：** `Docs/EDL/MSM8916_Reboot_to_EDL_Complete_Implementation_Guide.md`  
**状态：** 100% 已实现、已通过硬件测试并合入 `main`

---

## 1. 执行摘要与架构总览

本文档是关于在运行干净 OpenWrt Linux 6.12 的高通 MSM8916 设备上启用全部硬件重启模式——**EDL（`05c6:9008`）**、**DLOAD（`05c6:9006`）**、**Fastboot（`18d1:d00d` / `05c6:9025`）**、**Recovery** 以及**安全的常规更新（Sysupgrade）**——的权威技术参考。

该实现解决了四项关键工程难题：
1. **硬件暖复位魔法（PBL EDL 与 SBL1 DLOAD）：** 写出精确的底层寄存器写入序列、IMEM 魔数 cookie（位于 `0x08600FE0` 的 `0x322A4F99`、`0xC67E4350`、`0x77777777`）、PM8916 PON PS_HOLD 暖复位配置，以及高通 BootROM（PBL）在暖复位过程中进入 9008 模式所需的 SPMI 仲裁器停机操作。
2. **Bootloader 与 Fastboot 模式处理：** 将 `reboot bootloader` / `reboot fastboot` 以及 `reboot recovery` 通过高通 PON 重启模式寄存器（`PON_SOFT_RB_SPARE`）进行路由，使 `aboot` / `lk2nd` 停留在 Fastboot 模式以便进行 USB 分区刷写。
3. **安全的用户态拆解与文件系统保护：** 编排一套干净的用户态关机流程（`reboot-mode` / `reboot-edl`），确保在网络接口关闭、后台服务停止之后、断电之前，`/overlay`（`/dev/mmcblk0p15` EXT4）以只读（`MS_RDONLY`）方式被干净地重新挂载。
4. **常规重启与 Sysupgrade 完整性：** 确保标准 `/sbin/reboot`、命令行 sysupgrade（`sysupgrade -v image.bin`）以及 LuCI 网页界面升级都能干净地卸载持久化 overlay，从而消除此后每次启动时的 EXT4 日志恢复和 `e2fsck` 修复警告。

```
===================================================================================================
                        COMPLETE QUALCOMM MSM8916 REBOOT MODES & UPDATE PIPELINE
===================================================================================================

+--------------------------------------------------------------------------------------------------+
| USERSPACE: Safe Teardown Orchestrator (/sbin/reboot-mode -> reboot-edl / fastboot / sysupgrade)  |
| 1. Quiesce network & modem interfaces (ifdown -a, stop BAM-DMUX/RMTFS)                          |
| 2. Stop system services (/etc/init.d/rcS K shutdown)                                             |
| 3. Terminate running daemons (SIGTERM -> 1s sleep -> SIGKILL)                                    |
| 4. Flush caches & drop page caches (echo 3 > /proc/sys/vm/drop_caches)                           |
| 5. Remount storage read-only (mount -o noatime,remount,ro /overlay; mount -o remount,ro /)      |
| 6. Unmount all file systems (umount -a -r)                                                       |
| 7. Trigger emergency kernel sync & remount-ro (SysRq-s, SysRq-u)                                 |
| 8. Execute low-level dispatcher: /sbin/reboot-mode-raw "<mode>"                                  |
+--------------------------------------------------------------------------------------------------+
                                                 │
                                                 │ syscall(SYS_reboot, ..., RESTART2, mode)
                                                 v
+--------------------------------------------------------------------------------------------------+
| LINUX KERNEL 6.12 RESET SUBSYSTEM                                                                 |
|                                                                                                  |
| [MODE: edl]                                                                                      |
|   1. Write 3 EDL Cookies to IMEM (0x08600FE0): 0x322A4F99, 0xC67E4350, 0x77777777                |
|   2. Set TCSR_BOOT_MISC_DETECT bit[0] = 0x01 via qcom_scm_io_writel(0x0193D100, 0x01)            |
|   3. PM8916 PON PS_HOLD Warm Reset (Reg 0x85A = 0x01, Reg 0x85B = BIT(7), Reg 0x857 = 0x0)       |
|   4. Halt SPMI PMIC Arbiter (SCM SVC=0x9, CMD=0x1) -> Drop PS_HOLD (0x004AB000 = 0x0)            |
|                                                                                                  |
| [MODE: dload]                                                                                    |
|   1. Set TCSR_BOOT_MISC_DETECT bit[4] = 0x10 (QCOM_DLOAD_FULLDUMP)                               |
|   2. PM8916 PON Warm Reset -> Drop PS_HOLD                                                       |
|                                                                                                  |
| [MODE: bootloader / fastboot / recovery]                                                         |
|   1. Write magic to PM8916 PON_SOFT_RB_SPARE (0x88F): 0x01 (bootloader), 0x02 (recovery)         |
|   2. Standard Warm Reset -> Drop PS_HOLD                                                         |
|                                                                                                  |
| [MODE: normal reboot / sysupgrade]                                                               |
|   1. Base-files umount-overlay (STOP=98) remounts /overlay RO and runs SysRq-u                   |
|   2. SBL1 -> aboot/lk2nd -> Boots OpenWrt Linux kernel normally                                  |
+--------------------------------------------------------------------------------------------------+
                                                 │
                                                 │ Hardware Reset with SRAM Retention
                                                 v
+--------------------------------------------------------------------------------------------------+
| QUALCOMM HARDWARE BOOT CHAIN EXECUTION                                                           |
|                                                                                                  |
| ├─▶ [PBL BootROM]: Checks IMEM 0x08600FE0 & TCSR 0x0193D100                                      |
| │     └─▶ If EDL Cookies Match: Halts in Qualcomm HS-USB QDLoader 9008 Mode (05c6:9008)          |
| │                                                                                                |
| ├─▶ [SBL1 Bootloader]: Checks TCSR DLOAD bit & PON Spare                                         |
| │     └─▶ If DLOAD Bit Set: Halts in Qualcomm HS-USB Diagnostics / Mass Storage (05c6:9006)      |
| │                                                                                                |
| ├─▶ [aboot / lk2nd Bootloader]: Checks PON_SOFT_RB_SPARE (0x88F)                                 |
| │     ├─▶ If Mode == 0x01: Halts in Android Fastboot Mode (18d1:d00d / 05c6:9025)                |
| │     ├─▶ If Mode == 0x02: Boots Android Recovery Kernel / Ramdisk                               |
| │     └─▶ Default (0x00): Boots OpenWrt SquashFS + Persistent EXT4 Overlay                       |
+--------------------------------------------------------------------------------------------------+
```

---

## 2. 支持的重启模式与更新操作

系统现在为每一种标准与恢复操作模式都提供了干净、安全的命令：

| 命令 | 目标硬件模式 | USB ID | 目标处理程序 | 主要使用场景 |
| :--- | :--- | :--- | :--- | :--- |
| **`reboot-edl`** / `reboot edl` | **高通 9008 EDL** | `05c6:9008` | PBL BootROM | 救砖、raw eMMC 刷写（`flash.sh`、`edl`、`qdl`）、GPT 重写 |
| **`reboot-dload`** / `reboot dload` | **高通 9006 DLOAD** | `05c6:9006` | SBL1 Bootloader | RAM dump、大容量存储模式下直接磁盘访问 |
| **`reboot-bootloader`** / `reboot bootloader` | **Fastboot 模式** | `18d1:d00d` / `05c6:9025` | `aboot` / `lk2nd` | Fastboot 刷写（`fastboot flash boot ...`）、kernel 更新 |
| **`reboot-recovery`** / `reboot recovery` | **Recovery 模式** | Android Recovery | `aboot` / `lk2nd` | 启动备用 recovery 分区或 recovery ramdisk |
| **`reboot`** / `/sbin/reboot` | **常规重启** | Composite Gadget（`1d6b:0104`） | SBL1 -> aboot -> OpenWrt | 标准系统重启，`/overlay` 干净重新挂载 |
| **`sysupgrade <image.bin>`** | **系统升级** | Composite Gadget（`1d6b:0104`） | `/lib/upgrade/stage2` | 完整固件升级，同时保留 `/dev/mmcblk0p15` 配置 |

---

## 3. 深入剖析：逆向工程与模式机制

### 3.1 模式 1：高通 PBL 紧急下载（EDL / 9008）
对原厂高通 Android 内核（`android-vmlinux`）和 Little Kernel（`lk2nd` 源码）的逆向工程表明，MSM8916 BootROM **不会**检查位于 `0x0860065c` 的通用 ASCII cookie `0x65646c00`（"edl\0"）。

相反，MSM8916 PBL 期望在 IMEM 偏移 `0xFE0`（物理地址 `0x08600FE0`）处存在**三个 32 位魔术 cookie**：

| 地址 | IMEM（`0x08600000`）内偏移 | 值（十六进制） | 宏名称 |
| :--- | :--- | :--- | :--- |
| `0x08600FE0` | `+0xFE0` | `0x322A4F99` | `MSM_IMEM_EDL_MAGIC1` |
| `0x08600FE4` | `+0xFE4` | `0xC67E4350` | `MSM_IMEM_EDL_MAGIC2` |
| `0x08600FE8` | `+0xFE8` | `0x77777777` | `MSM_IMEM_EDL_MAGIC3` |

#### 硬件执行要求：
1. **TCSR Boot Misc 寄存器（`0x0193D100`）：** PBL 检查 bit 0。必须将值 `0x01`（`SCM_EDLOAD_MODE`）直接写入 `0x0193D100`。
2. **PM8916 PMIC PON PS_HOLD 暖复位：** PM8916 PMIC 必须执行暖复位，以便在复位期间保持 SRAM 电源轨：
   - 寄存器 `0x85B`（`QPNP_PON_PS_HOLD_RST_CTL2`）= `0x0`（禁用）。
   - `udelay(300)`。
   - 寄存器 `0x85A`（`QPNP_PON_PS_HOLD_RST_CTL`）= `0x01`（`PON_POWER_OFF_WARM_RESET`）。
   - 寄存器 `0x85B`（`QPNP_PON_PS_HOLD_RST_CTL2`）= `BIT(7)`（`QPNP_PON_RESET_EN`）。
   - 寄存器 `0x857`（`QPNP_PON_WD_RST_S2_CTL2`）= `0x0`（清除看门狗）。
3. **PMIC 仲裁器停机（TrustZone SMC）：** 通过 `SCM_SVC_PWR`（`0x09`）、`SCM_IO_DISABLE_PMIC_ARBITER`（`0x01`）停机 SPMI 仲裁器。
4. **PS_HOLD 拉低：** 将 `msm_ps_hold`（`0x004AB000`）驱动为 0。

---

### 3.2 模式 2：Fastboot 模式（`bootloader` / `fastboot`）
MSM8916 上的 Fastboot 模式由 Little Kernel / Android Bootloader（`aboot` / `lk2nd`）处理：
1. 当调用 `reboot bootloader` 或 `reboot fastboot` 时，位于 `drivers/power/reset/qcom-pon.c` 中的 Linux `reboot-mode` 框架会拦截该命令字符串。
2. `pm8916_reboot_mode_write()` 将 bootloader 魔术标识写入 PM8916 上电（PON）软复位备用寄存器：
   - **`PON_SOFT_RB_SPARE`（SPMI 寄存器 `0x88F`）：** `0x01`（Fastboot 模式）。
3. 系统执行标准暖复位。
4. 启动过程中，SBL1 读取 `0x88F`、保留该原因并跳转到 `aboot`。
5. `aboot` 检查重启原因：看到 `0x01` 时，跳过 Linux 启动倒计时并停留在 **Fastboot USB 模式**（`ID 18d1:d00d` 或 `05c6:9025`）。
6. 用户现在可以使用标准主机工具刷写分区：
   ```bash
   fastboot flash boot openwrt-msm89xx-msm8916-generic-hmu05-boot.img
   fastboot reboot
   ```

---

### 3.3 模式 3：Recovery 模式（`recovery`）
与 Fastboot 模式类似：
1. `reboot recovery` 使 `drivers/power/reset/qcom-pon.c` 向 `PON_SOFT_RB_SPARE`（`0x88F`）写入 `0x02`。
2. SBL1 移交给 `aboot`，后者从 `recovery` eMMC 分区（而非 `boot`）加载并启动内核。

---

### 3.4 模式 4：常规更新与 Sysupgrade 流程

OpenWrt 为 MSM8916 设备支持两条稳健的升级路径：

#### 路径 A：原地标准 Sysupgrade（`sysupgrade` CLI 与 LuCI 网页 UI）
sysupgrade 工作流如下：
1. 用户通过 LuCI 网页 GUI 或 CLI 提供 sysupgrade tar/bin 镜像：
   ```bash
   sysupgrade -v /tmp/openwrt-msm89xx-msm8916-generic-hmu05-squashfs-sysupgrade.bin
   ```
2. **阶段 1（备份）：** OpenWrt 将网络、无线和系统配置文件归档到 `/tmp/sysupgrade.tgz`。
3. **阶段 2（Ramdisk 切换与存储刷写）：**
   - 系统执行 [`/lib/upgrade/stage2`](../../openwrt/package/base-files/files/lib/upgrade/stage2)。
   - 将根文件系统切换到 RAM（`tmpfs`），分离所有 loop/overlay 挂载，并将 `/overlay` 以**只读（`MS_RDONLY`）**方式挂载。
   - [`/lib/upgrade/platform.sh`](../../msm89xx/base-files/lib/upgrade/platform.sh) 识别目标 eMMC 分区（`boot` 位于 `p12`/`p13`，`rootfs` 位于 `p14`）。
   - 将新的 Android boot 镜像（kernel + initramfs）写入 `boot` 分区，将 SquashFS rootfs 写入 `rootfs` 分区。
   - 将配置恢复到持久化 EXT4 `/dev/mmcblk0p15`（`rootfs_data`）。
4. **阶段 3（干净重启）：** 触发 `/sbin/reboot`。base-files 的 `umount-overlay` 确保 `/overlay` 在重启前被干净刷写。

#### 路径 B：通过 EDL 或 Fastboot 的主机驱动刷写
当跨主要分区布局变化升级或救砖时：
1. 使设备进入 EDL 模式：`reboot-edl`。
2. 使用生成的 [`msm89xx/image/flash.sh`](../../msm89xx/image/flash.sh)（安装为 `openwrt-msm89xx-msm8916-<board>-flash.sh`）刷写 raw eMMC 分区，从构建输出目录运行。它二合一——选择 **`1` Migrate**（原厂 Android → OpenWrt）或 **`2` Update**（现有 OpenWrt；仅 `boot` + `rootfs`）：
   ```bash
   cd openwrt/bin/targets/msm89xx/msm8916
   ./openwrt-msm89xx-msm8916-<board>-flash.sh
   ```
3. 或者使设备进入 Fastboot 模式（`reboot-bootloader`）并逐个刷写分区：
   ```bash
   fastboot flash boot openwrt-msm89xx-msm8916-generic-hmu05-boot.img
   fastboot flash rootfs openwrt-msm89xx-msm8916-generic-hmu05-rootfs-squashfs.img
   ```

---

## 4. 内核补丁与子系统集成

所有内核级的重启与 EDL 支持都集中在 [`msm89xx/patches/813-msm8916-reboot-to-edl-support.patch`](../../msm89xx/patches/813-msm8916-reboot-to-edl-support.patch) 中。

### 4.1 设备树节点（`arch/arm64/boot/dts/qcom/msm8916.dtsi`）
```dts
qcom,msm-imem@8600000 {
	compatible = "qcom,msm-imem", "syscon", "simple-mfd";
	reg = <0x08600000 0x1000>;
	ranges = <0x0 0x08600000 0x1000>;
	#address-cells = <1>;
	#size-cells = <1>;

	emergency_download_mode@fe0 {
		compatible = "qcom,msm-imem-emergency_download_mode";
		reg = <0xfe0 12>;
	};
};
```

### 4.2 SCM 函数（`drivers/firmware/qcom/qcom_scm.c`）
```c
int qcom_scm_set_edload_mode(void)
{
	if (!__scm || !__scm->dload_mode_addr)
		return -ENODEV;

	/* Raw write: SCM_EDLOAD_MODE = 0x01 to TCSR_BOOT_MISC_DETECT */
	return qcom_scm_io_writel(__scm->dload_mode_addr, 0x01);
}
EXPORT_SYMBOL_GPL(qcom_scm_set_edload_mode);

void qcom_scm_halt_pmic_arbiter(void)
{
	struct qcom_scm_desc desc = {
		.svc   = 0x09,	/* SCM_SVC_PWR */
		.cmd   = 0x01,	/* SCM_IO_DISABLE_PMIC_ARBITER */
		.owner = ARM_SMCCC_OWNER_SIP,
	};
	int ret;

	if (!__scm)
		return;

	ret = qcom_scm_call_atomic(__scm->dev, &desc, NULL);
	if (ret) {
		desc.cmd = 0x02;	/* SCM_IO_DISABLE_PMIC_ARBITER1 */
		ret = qcom_scm_call_atomic(__scm->dev, &desc, NULL);
		if (ret)
			dev_err_ratelimited(__scm->dev,
				"halt_pmic_arbiter failed: %d\n", ret);
	}
}
EXPORT_SYMBOL_GPL(qcom_scm_halt_pmic_arbiter);
```

### 4.3 关机重启处理程序（`drivers/power/reset/msm-poweroff.c`）
```c
static void msm_write_emergency_dload_magic(void)
{
	if (!msm_imem_base)
		return;

	/* Write 3 EDL magic cookies to 0x08600FE0 */
	writel(MSM_IMEM_EDL_MAGIC1, msm_imem_base + IMEM_EDL_COOKIES_OFFSET + 0x00);
	writel(MSM_IMEM_EDL_MAGIC2, msm_imem_base + IMEM_EDL_COOKIES_OFFSET + 0x04);
	writel(MSM_IMEM_EDL_MAGIC3, msm_imem_base + IMEM_EDL_COOKIES_OFFSET + 0x08);
	mb();
}

static int do_msm_poweroff(struct sys_off_data *data)
{
	if (data->cmd && (!strcmp(data->cmd, "edl") || !strcmp(data->cmd, "dload"))) {
		pr_emerg("MSM8916: EDL warm reset sequence (lk2nd-equivalent)\n");
		msm_write_emergency_dload_magic();
		qcom_scm_set_edload_mode();
		if (msm_pon_configure_warm_reset_fn)
			msm_pon_configure_warm_reset_fn();
		qcom_scm_halt_pmic_arbiter();
	}

	writel(0, msm_ps_hold);
	mdelay(10000);

	return NOTIFY_DONE;
}
```

---

## 5. 用户态架构与安全关机编排

### 5.1 `packages/reboot-edl/` 中的两级架构

1. **底层系统调用辅助程序（[`packages/reboot-edl/src/reboot-mode-raw.c`](../../packages/reboot-edl/src/reboot-mode-raw.c)）：**
   编译为 `/sbin/reboot-mode-raw`。严格分发 `reboot(LINUX_REBOOT_CMD_RESTART2, cmd)`。
2. **安全编排器（[`packages/reboot-edl/files/reboot-mode.sh`](../../packages/reboot-edl/files/reboot-mode.sh)）：**
   安装到 `/sbin/reboot-mode`，并符号链接到 `/sbin/reboot-edl`、`/sbin/reboot-dload`、`/sbin/reboot-bootloader`、`/sbin/reboot-recovery`。

#### 拆解脚本流程：
```sh
#!/bin/sh
# /sbin/reboot-mode - Safe shutdown and reboot-to-mode utility

set -e

PROG="$(basename "$0")"
FORCE=0
MODE=""

# Determine default mode based on symlink
case "$PROG" in
	*edl*|*9008*)   MODE="edl" ;;
	*dload*|*9006*) MODE="dload" ;;
	*bootloader*)  MODE="bootloader" ;;
	*fastboot*)    MODE="fastboot" ;;
	*recovery*)    MODE="recovery" ;;
	*)             MODE="edl" ;;
esac

while [ $# -gt 0 ]; do
	case "$1" in
		-f|--force) FORCE=1 ;;
		*) MODE="$1" ;;
	esac
	shift
done

[ -z "$MODE" ] && MODE="edl"

if [ "$FORCE" -eq 1 ]; then
	sync
	exec /sbin/reboot-mode-raw "$MODE"
fi

# 1. Bring down network & modem interfaces
if command -v ifdown >/dev/null 2>&1; then
	ifdown -a 2>/dev/null || true
fi

# 2. Stop running system services
if [ -d /etc/rc.d ]; then
	/etc/init.d/rcS K shutdown >/dev/null 2>&1 || true
fi

# 3. Terminate remaining daemons
killall5 -15 2>/dev/null || true
sync; sleep 1
killall5 -9 2>/dev/null || true
sync; sleep 1

# 4. Flush page caches and sync buffers
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
sync

# 5. Remount storage and overlay read-only
if grep -q " /overlay " /proc/mounts 2>/dev/null; then
	mount -o noatime,remount,ro /overlay 2>/dev/null || true
fi
mount -o remount,ro / 2>/dev/null || true
umount -a -r 2>/dev/null || true

# 6. Kernel-level emergency sync & remount-ro
if [ -w /proc/sysrq-trigger ]; then
	echo s > /proc/sysrq-trigger 2>/dev/null || true
	echo u > /proc/sysrq-trigger 2>/dev/null || true
fi

# 7. Dispatch hardware reboot
exec /sbin/reboot-mode-raw "$MODE"
```

---

### 5.2 常规重启的干净卸载钩子（`msm89xx/base-files/`）

创建了 [`msm89xx/base-files/etc/init.d/umount-overlay`](../../msm89xx/base-files/etc/init.d/umount-overlay)（`STOP=98`）：
```sh
#!/bin/sh /etc/rc.common
# Cleanly flush caches and remount rootfs/overlay read-only during system halt/reboot

STOP=98

stop() {
	sync
	echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
	if grep -q " /overlay " /proc/mounts 2>/dev/null; then
		mount -o noatime,remount,ro /overlay 2>/dev/null || true
	fi
	mount -o remount,ro / 2>/dev/null || true
	if [ -w /proc/sysrq-trigger ]; then
		echo s > /proc/sysrq-trigger 2>/dev/null || true
		echo u > /proc/sysrq-trigger 2>/dev/null || true
	fi
}

shutdown() {
	stop
}
```
通过 [`msm89xx/base-files/etc/uci-defaults/99-msm89xx-firstboot`](../../msm89xx/base-files/etc/uci-defaults/99-msm89xx-firstboot) 在首次启动时自动启用。

---

## 6. 实机硬件验证与测试结果（192.168.8.1）

### 6.1 测试 1：标准重启对比

#### 修复前（旧实现）：
```
[    6.690689] rootfs_data: running e2fsck -p
[    6.900334] rootfs_data: recovering journal
[    7.076821] rootfs_data: clean, 114/217728 files, 44532/869879 blocks
[    7.168335] rootfs_data: filesystem clean
```
*⚠️ 每次重启 EXT4 都必须执行日志恢复。*

#### 修复后（实机结果）：
```
[    6.689074] rootfs_data: running e2fsck -p
[    6.901814] rootfs_data: clean, 120/217728 files, 44552/869879 blocks
[    6.967234] rootfs_data: filesystem clean
```
*✅ 日志恢复被彻底消除；文件系统 100% 干净。*

---

### 6.2 测试 2：安全的 `reboot-edl` 切换与复位

1. **在实机上触发 `/sbin/reboot-edl`**：
   * 网络接口被优雅地关闭。
   * 服务已停止（`rcS K shutdown`）。
   * 守护进程已终止（`killall5`）。
   * 页缓存已丢弃（`drop_caches: 3`）。
   * `/overlay` 以只读方式重新挂载：`EXT4-fs (mmcblk0p15): re-mounted ... ro.`
   * 执行了紧急同步与重新挂载（`sysrq: Emergency Remount R/O`）。
   * 触发了底层重启系统调用。

2. **在 Ramoops（`/sys/fs/pstore/console-ramoops-0`）中捕获的关机轨迹**：
   ```
   [   69.914400] reboot-edl (5305): drop_caches: 3
   [   70.260789] EXT4-fs (mmcblk0p15): re-mounted 7c50df6f-2fee-4370-b621-af0d89950311 ro.
   [   70.352377] sysrq: Emergency Sync
   [   70.352517] sysrq: Emergency Remount R/O
   [   70.355185] Emergency Sync complete
   [   70.359698] Emergency Remount complete
   [   70.411350] reboot: Restarting system with command 'edl'
   [   70.411536] MSM8916: EDL warm reset sequence (lk2nd-equivalent)
   ```

3. **主机 USB 枚举（`lsusb`）**：
   ```
   Bus 001 Device 008: ID 05c6:9008 Qualcomm, Inc. Gobi Wireless Modem (QDL mode)
   ```
   *✅ 设备干净地进入了高通 9008 EDL 模式。*

4. **通过 `edl reset` 返回 EDL 及下次启动验证**：
   * 从主机 PC 发送 `edl reset`。
   * 设备重新启动回 OpenWrt。
   * **启动内核日志（`dmesg`）：**
     ```
     [    6.643009] rootfs_data: existing ext filesystem detected
     [    6.643358] rootfs_data: od_magic=1 blkid_type=ext4
     [    6.647759] rootfs_data: running e2fsck -p
     [    6.891747] rootfs_data: clean, 120/217728 files, 44552/869879 blocks
     [    6.902277] rootfs_data: filesystem clean
     ```
   *✅ 文件系统在整个 EDL 模式切换过程中始终保持 100% 干净，没有任何日志恢复。*

---

## 7. 完整操作与恢复速查表

### 快速参考命令

#### 从 OpenWrt 重启进入特定硬件模式：
```bash
# Emergency Download Mode (PBL 9008)
reboot-edl

# Mass Storage / Memory Dump Mode (SBL1 9006)
reboot-dload

# Fastboot Mode (aboot / lk2nd 18d1:d00d)
reboot-bootloader

# Android Recovery Mode
reboot-recovery

# Normal Safe Reboot
reboot
```

#### 刷写与固件更新命令：
```bash
# 1. In-place OpenWrt firmware upgrade (preserving persistent config):
sysupgrade -v /tmp/openwrt-msm89xx-msm8916-generic-hmu05-squashfs-sysupgrade.bin

# 2. In-place OpenWrt clean upgrade (wipe persistent config):
sysupgrade -n -v /tmp/openwrt-msm89xx-msm8916-generic-hmu05-squashfs-sysupgrade.bin

# 3. Host-driven EDL full firmware flashing (while device is in EDL mode):
cd msm89xx/image
./flash.sh hmu05

# 4. Host-driven Fastboot or EDL flashing (while device is in Fastboot/EDL mode):
For Fastboot Mode

fastboot flash boot openwrt-msm89xx-msm8916-generic-hmu05-boot.img
fastboot flash rootfs openwrt-msm89xx-msm8916-generic-hmu05-rootfs-squashfs.img
fastboot reboot

------------------
	
For EDL Mode		     
```
edl w boot openwrt-msm89xx-msm8916-generic-hmu05-boot.img
edl w flash rootfs openwrt-msm89xx-msm8916-generic-hmu05-rootfs-squashfs.img
edl reset
---

## 8. 总结与仓库参考

| 文件 | 用途 |
| :--- | :--- |
| [`msm89xx/patches/813-msm8916-reboot-to-edl-support.patch`](../../msm89xx/patches/813-msm8916-reboot-to-edl-support.patch) | 内核补丁：IMEM cookie、SCM EDLOAD 模式、PM8916 PON 暖复位、PMIC 仲裁器停机以及 PS_HOLD 重启处理程序 |
| [`packages/reboot-edl/src/reboot-mode-raw.c`](../../packages/reboot-edl/src/reboot-mode-raw.c) | 极简 AArch64 C 可执行文件，用于底层 `LINUX_REBOOT_CMD_RESTART2` 分发 |
| [`packages/reboot-edl/files/reboot-mode.sh`](../../packages/reboot-edl/files/reboot-mode.sh) | 编排脚本：接口拆解、服务停止、守护进程终止、只读重新挂载与 SysRq 同步 |
| [`packages/reboot-edl/Makefile`](../../packages/reboot-edl/Makefile) | OpenWrt 软件包定义，安装二进制文件与符号链接 |
| [`msm89xx/base-files/etc/init.d/umount-overlay`](../../msm89xx/base-files/etc/init.d/umount-overlay) | base-files `STOP=98` 服务，确保在标准 `/sbin/reboot` 期间 `/overlay` 被干净地重新挂载为 `ro` |
| [`msm89xx/base-files/etc/uci-defaults/99-msm89xx-firstboot`](../../msm89xx/base-files/etc/uci-defaults/99-msm89xx-firstboot) | 首次启动脚本，启用 `umount-overlay` 服务 |

> 原先的 `MSM8916_Clean_Reboot_EDL_and_Filesystem_Safety_Analysis.md`（关于 procd 关机
> 与 EXT4 状态标志的深度追踪文档）已**合并进本指南**并从代码树中移除。
