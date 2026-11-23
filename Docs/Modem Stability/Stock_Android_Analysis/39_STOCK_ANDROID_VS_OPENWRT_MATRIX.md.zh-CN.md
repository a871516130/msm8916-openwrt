# Qualcomm MSM8916：原厂 Android 与 OpenWrt 稳定性差异矩阵

**目标设备：** Qualcomm Snapdragon 410 / MSM8916（通用 HMU05 / UFI）  
**基线固件：** 原厂 Android 4.4.4（内核 3.10.28）— **>5.5 小时连续运行时间**  
**对比目标：** OpenWrt 25.12.5（内核 6.12.94 `msm89xx`）  
**产物路径：** `Docs/Modem Stability/Stock_Android_Analysis/39_STOCK_ANDROID_VS_OPENWRT_MATRIX.md`  

---

## 1. 执行摘要

通过对运行中的原厂 Android 系统在 0–15–30–45–300+ 分钟区间内进行连续插桩，我们绘制了原厂 Android（无限期运行而不崩溃）与原生 OpenWrt（在 $t = 900\text{s}$ 崩溃）之间的**每一个子系统差异**。

---

## 2. 全面子系统对比矩阵

```
========================================================================================================================
SUBSYSTEM               STOCK ANDROID GROUND-TRUTH               OPENWRT VANILLA                DIFFERENCE & IMPACT
========================================================================================================================
1. SCLK Clock /         time_daemon starts at boot;              No time daemon running;        CRITICAL: At T=900s,
   DRX Sleep FSM        anchors baseband to RTC (/dev/rtc0);     baseband SCLK timer            SCLK drift causes fatal
                        registers tod_update_ind_cb (0x0025).    drifts uncorrected.            assertion in lte_ml1.
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
2. BAM-DMUX DMA         Runtime autosuspend unsupported;         Upstream Linux enables         CRITICAL: 1000ms idle
   Power Management     all 8 channels (ch00-ch07) remain        1000ms autosuspend             triggers SMSM drop;
                        persistently open & ready in SPS/BAM.    (BAM_DMUX_AUTOSUSPEND_DELAY).  fails resume -> drops RX.
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
3. Remote Storage       rmt_storage runs full read-write         OpenWrt rmtfs default          CRITICAL: 900s EFS2
   (EFS2 NV Sync)       over /dev/uio0 shared memory DMA to      sometimes ran with -r          NV sync rejected ->
                        modemst1, modemst2, fsg, fsc.            (read-only).                   panics with :Excep :0:.
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
4. Primary SIM Power    GPIO 119 (esim1_en) driven HIGH (255)   DTS may leave floating         HIGH: SIM power unpowered
   & Select Line        continuously at boot.                    or misconfigured.              or drops out on dormancy.
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
5. SIM Hotplug Detect   GPIO 114 (sim_hotplug) driven            DTS may leave unmapped         MEDIUM: Baseband drops
   Detection Line       LOW (0) continuously.                    or pull-up active.             SIM card session.
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
6. 4G RF Path Power     GPIO 71 (4g_1) driven HIGH (1)           DTS may treat only as          MEDIUM: Baseband RF
   & Front-End Latch    continuously.                            passive LED.                   path unlatched.
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
7. PM8916 Regulators    L5 (1.8V), L6 (1.8V), L7 (1.8V MSS PLL), Set in DTS rpm-regulator;     LOW: Matches standard
                        L13 (3.075V USB/Audio), L17 (2.85V SPI), managed by RPM firmware.       Qualcomm power tree.
                        S4 (1.8V PMIC Buck).
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
8. Hardware Watchdog    MSM hardware WDT (b017000.qcom,wdt)      OpenWrt kernel uses same       NONE: In-kernel timer
                        fed in-kernel by scheduler core.         qcom_wdt driver.               feeding works properly.
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
9. Data Dormancy &      QCRIL manages wake-locks (qcril,         ModemManager uses QMI WDS;     MEDIUM: OpenWrt must
   Wake-Lock Lifecycle  radio-interface) on every QMI event;     network stack has no           maintain DMA active
                        transitions to DORMANT (active=2).       wake-lock semantics.           while netdev is UP.
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
10. Sysmon SSR          Sysmon isolates WCNSS Wi-Fi from         Vanilla Linux broadcasts       CRITICAL: Modem reset
    Handling            Modem SSR restarts.                      SSR to WCNSS -> panics Wi-Fi.  causes local Wi-Fi crash.
========================================================================================================================
```

---

## 3. OpenWrt 相对于原厂 Android 不稳定的 4 个根因

根据我们的取证分析，导致 OpenWrt 故障的 4 个具体机制是：

### 根因 1：$T = 900\text{s}$ 时的 SCLK 时钟漂移
* **Android 解决方案**：`time_daemon` 在启动时提供初始基带 ATS 时间锚点。
* **OpenWrt 解决办法**：二进制补丁 `FUN_c03987e0`（`lte_ml1_sleepmgr_cfg`）使其返回 `-1`（完全绕过 900s DRX 定时器）或实现轻量级 QMI 服务 22 守护进程。

### 根因 2：BAM-DMUX 1 秒自动挂起抖动
* **Android 解决方案**：BAM DMA 描述符保持永久激活；链路休眠在协议层处理。
* **OpenWrt 解决办法**：内核内 PM 锁（[`808-bam-dmux-stats.patch`](../../../msm89xx/patches/808-bam-dmux-stats.patch)），在 `wwan0` 处于 UP 状态时持有 `pm_runtime_resume_and_get()`。

### 根因 3：RMTFS NV 同步被拒
* **Android 解决方案**：对 eMMC 分区直接读写访问。
* **OpenWrt 解决办法**：`packages/rmtfs` 以 `-P -s` 运行，使用 `/dev/disk/by-partlabel/` 符号链接。

### 根因 4：硬件 GPIO 引脚置位
* **Android 解决方案**：显式驱动 GPIO 119 为 HIGH、GPIO 114 为 LOW、GPIO 71 为 HIGH。
* **OpenWrt 解决办法**：配置 `msm8916-generic-hmu05.dts` 和 `99-msm89xx-firstboot` 以锁存这些确切的引脚状态。
