# 为什么原厂 Android 在 15 分钟后不崩溃：取证分析与对比

**目标硬件：** 通用 HMU05 4G LTE USB 加密狗（Qualcomm MSM8916）  
**基带固件：** `HIMI_U01_MODEM_V1.0`（`MPSS.DPM.1.0.C7`）  
**原厂系统：** Android 4.4.4（内核 3.10.28）  
**实测运行时间：** 通过 $t = 921.01\text{s}$（15 分 21 秒），**0% 丢包**且**0 调制解调器错误**。  

---

## 1. 执行摘要

在未打补丁的原厂 Android 上，调制解调器**从未在 15 分钟（$900\text{s}$）时刻崩溃**，蜂窝数据无限期流畅传输，无卡顿。

通过将原厂 Android 的实时执行轨迹与主线 Linux 6.12 / OpenWrt 对比，我们找出了保持原厂 Android 稳定的**4 个确切机制**：

```
+---------------------------------------------------------------------------------------------------+
| SUBSYSTEM / LAYER            | STOCK ANDROID BEHAVIOR                   | VANILLA LINUX / OPENWRT |
+---------------------------------------------------------------------------------------------------+
| 1. SCLK Clock Drift          | time_daemon synchronizes ATS clock via   | No time daemon running; |
|    (lte_ml1_sleepmgr_stm)    | QMI Service 22 at boot & registers IND   | SCLK drifts -> Panic    |
+---------------------------------------------------------------------------------------------------+
| 2. BAM DMA Driver            | Persistent SPS/BAM mode (Autosuspend     | 1000ms autosuspend loop |
|    (qcom_bam_dmux)           | unsupported); channels stay open         | drops SMSM ACKs (-22)   |
+---------------------------------------------------------------------------------------------------+
| 3. Remote Storage (EFS)      | rmt_storage runs full read-write access  | If run with -r, modem   |
|    (rmt_storage / rmtfs)     | for 900s periodic NV writebacks          | panics with :Excep :0:  |
+---------------------------------------------------------------------------------------------------+
| 4. Hardware GPIOs            | GPIO 119 (esim1_en) held HIGH (255)      | If unconfigured, SIM    |
|    (TLMM Pinmux)             | GPIO 114 (sim_hotplug) held LOW (0)      | drops after dormancy    |
+---------------------------------------------------------------------------------------------------+
```

---

## 2. 深入剖析：原厂 Android 中的 4 个稳定机制

### 机制 1：`time_daemon` 与 QMI 服务 22（时钟漂移防护）
* **在基带中 $t = 900\text{s}$ 时发生什么**：
  LTE 层 1 睡眠管理器（`lte_ml1_sleepmgr_stm.c`）醒来，计算 32.768 kHz 睡眠晶振与 19.2 MHz TCXO 之间的漂移：
  $$\text{Drift} = (\text{actual\_sclk\_ticks} - \text{expected\_sclk\_ticks}) \times \text{0x7800}$$
* **原厂 Android 如何处理**：
  1. `/system/bin/time_daemon` 在启动期间启动（`init.target.rc` 第 153 行）。
  2. 它通过 IPC Router 连接到 **QMI 服务 22（QMI TIME / ATS 服务）**。
  3. 它调用 `genoff_boot_tod_init`，将调制解调器的 ATS 时基锚定到硬件 RTC（`/dev/rtc0`）。
  4. 它注册 `tod_update_ind_cb`（`QMI_TIME_REG_IND_REQ` `0x0025`），使调制解调器的 SCLK 漂移保持在容差范围内。
  5. 由于漂移接近零，900s 维护定时器干净退出，不会在第 4054 行触发 `ERR_FATAL`。

---

### 机制 2：无 1 秒自动挂起抖动的持久 BAM DMA
* **在原厂 Android 中**：
  * 对 `/d/bam_dmux/tbl` 的 debugfs 检查显示，全部 8 个数据通道（**`ch00` 至 `ch07`**）都持久保持**`local open=Y remote open=Y`**。
  * Sysfs `power/runtime_status` 被标记为**`unsupported`**。
  * 当没有数据包传输时，Android 电话栈在 RIL 协议层转换为**`DORMANT`（`active=2`）**，但底层内核 DMA 描述符保持不变。
* **在原生主线 Linux 中**：
  * 上游 `qcom_bam_dmux.c` 硬编码 `#define BAM_DMUX_AUTOSUSPEND_DELAY 1000`（1 秒）。
  * 每空闲 1000 ms，Linux 就强制进行一次 SMSM 掉电握手。在 15 分钟内，这导致约 60 至 100 次快速掉电，最终引发 SMSM 握手超时（`Failed to resume: -22`），触发 `a2_task.c:3179`。

---

### 机制 3：用于 900 秒 NV 同步的读写 `rmt_storage`
* **在原厂 Android 中**：
  * `/system/bin/rmt_storage` 以完整读写权限运行于 `/dev/block/bootdevice/by-name/`（`modemst1`、`modemst2`、`fsg`、`fsc`）。
  * 当调制解调器执行其 900 秒周期性无线统计回写时，写入在 2 ms 内完成。

---

### 机制 4：硬件 GPIO 引脚配置
* **在原厂 Android 中**：
  * **GPIO 119（`esim1_en`）** 被驱动为 **HIGH（255）** $\rightarrow$ 为物理 SIM 卡供电。
  * **GPIO 114（`sim_hotplug`）** 被驱动为 **LOW（0）** $\rightarrow$ 指示 SIM 卡存在。
  * **GPIO 71（`4g_1`）** 被驱动为 **HIGH（1）** $\rightarrow$ 为 4G 射频路径供电。

---

## 3. 我们如何在 OpenWrt 中实现这一点

要在 OpenWrt 中达到完全相同的 100% 稳定性：

1. **固件无睡眠补丁（或 QMI 时间服务）**：
   * 通过将 `FUN_c03987e0`（`lte_ml1_sleepmgr_cfg`）修补为返回 `-1`，我们完全禁用 900s DRX 睡眠定时器，使调制解调器即使没有 Android 专有时间守护进程也不受时钟漂移影响。
2. **BAM-DMUX PM 锁（[`808-bam-dmux-stats.patch`](../../../msm89xx/patches/808-bam-dmux-stats.patch)）**：
   * 在 `wwan0` 处于 UP 状态时持有 `pm_runtime_resume_and_get()`，复刻原厂 Android 的持久 DMA 模式。
3. **读写 RMTFS（[`packages/rmtfs/files/rmtfs.init`](../../../packages/rmtfs/files/rmtfs.init)）**：
   * 以 `-P -s` 运行，目标为 `/dev/disk/by-partlabel/`。
4. **设备树 GPIO 对齐**：
   * 确保 `msm8916-generic-hmu05.dts` 将 GPIO 119 保持 HIGH，GPIO 114 保持 LOW。
