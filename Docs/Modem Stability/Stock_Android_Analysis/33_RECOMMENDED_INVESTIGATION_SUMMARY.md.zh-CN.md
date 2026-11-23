# Qualcomm MSM8916 原厂 Android 地面实况调查摘要

**目标设备：** Qualcomm MSM8916 Snapdragon 410（通用 HMU05 / UFI）  
**基带固件：** `HIMI_U01_MODEM_V1.0`（型号：4094，版本：2015 年 9 月 9 日）  
**固件系统：** 原厂 Android 4.4.4（内核 3.10.28）  
**捕获位置：** `Docs/Modem Stability/Stock_Android_Analysis/`  

---

## 1. 看门狗子系统与馈送进程

* **硬件看门狗节点：** `/sys/devices/soc.0/b017000.qcom,wdt`（驱动：`msm_watchdog`）
* **/dev 中的看门狗设备节点：** 用户空间**没有 `/dev/watchdog`** 暴露。
* **内核初始化：**
  ```text
  [    0.060760] msm_watchdog b017000.qcom,wdt: MSM Watchdog Initialized
  ```
* **看门狗馈送：** MSM 硬件看门狗**完全在内核中**通过定时器工作队列管理（其中 `VosWDThread` 用于 WCNSS Wi-Fi 监控，`/sbin/healthd` 监控 Android 框架 binder 事务）。
* **看门狗状态：** `disable = 0`（激活）。内核硬件看门狗定时器具有默认的 10s bark / 11s bite 窗口，由调度器核心持续馈送。

---

## 2. 调制解调器内存映射（`mpss_mem` / CMA 区域）

来自实时内核 `dmesg`：

| 区域名称 | 基地址 | 大小 | 结束地址 | 用途 |
| :--- | :--- | :--- | :--- | :--- |
| **`modem_adsp_mem`（`mpss_mem`）** | **`0x86800000`** | **85 MiB（`0x5500000`）** | **`0x8BD00000`** | **Hexagon QDSP6 调制解调器固件（MPSS）** |
| `external_image_mem` | `0x86000000` | 8 MiB（`0x800000`） | `0x86800000` | MBA（调制解调器启动验证器）与 TrustZone |
| `peripheral_mem` | `0x8BD00000` | 6 MiB（`0x600000`） | `0x8C300000` | WCNSS（Pronto 无线子系统） |
| `venus_qseecom_mem` | `0x8F800000` | 8 MiB（`0x800000`） | `0x90000000` | 硬件视频核心与 QSEE / TrustZone |

* **Remoteproc 加载范围**：
  ```text
  [    6.002955] pil-q6v5-mss 4080000.qcom,mss: modem: loading from 0x86800000 to 0x8ba00000
  [    6.048943] pil: MBA boot done
  [    6.677921] pil-q6v5-mss 4080000.qcom,mss: modem: Brought out of reset
  ```

---

## 3. 调制解调器激活时的运行 GPIO 状态

来自 `/sys/kernel/debug/gpio`（基址 902 `msm_tlmm_v4_gpio`）：

| 信号名称 | 内核 GPIO ID | TLMM 物理 GPIO | 方向 | 运行状态 | 用途 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`esim1_en`** | `gpio-1021` | **GPIO 119** | `out` | **`HIGH`（255）** | **主 SIM 卡电源 / 使能** |
| **`sim_hotplug`** | `gpio-1016` | **GPIO 114** | `out` | **`LOW`（0）** | **SIM 卡存在检测已置位** |
| **`4g_1`** | `gpio-973` | **GPIO 71** | `out` | **`HIGH`（1）** | **4G 射频电源 / LTE 状态 LED** |
| **`wifistatus`** | `gpio-975` | **GPIO 73** | `out` | **`HIGH`（1）** | **Wi-Fi 电源 / 状态 LED** |
| **`key_freset`** | `gpio-939` | **GPIO 37** | `in` | `LOW`（0） | 恢复出厂设置按钮 |
| **`esim2_en`** | `gpio-916` | **GPIO 14** | `out` | `LOW`（0） | 副 SIM 选择（禁用） |
| **`esim3_en`** | `gpio-914` | **GPIO 12** | `out` | `LOW`（0） | 第三 SIM 选择（禁用） |
| **`disp_rst_n`** | `gpio-1019` | **GPIO 117** | `in` | `HIGH`（1） | 显示复位 / 电源 |
| **`disp_dc`** | `gpio-1018` | **GPIO 116** | `in` | `HIGH`（1） | 显示数据/命令线 |
| **`USB_ID_GPIO`**| `gpio-1012` | **GPIO 110** | `in` | `HIGH`（1） | USB OTG ID 检测 |

---

## 4. AT 命令与接口模式分析

* **AT 端口：** `/dev/smd11`（调制解调器 AT 通道）
* **调制解调器标识：**
  ```text
  ATI
  Manufacturer: QUALCOMM INCORPORATED
  Model: 4094
  Revision: HIMI_U01_MODEM_V1.0  1  [Sep 09 2015 10:00:00]
  IMEI: 864293052253917
  +GCAP: +CGSM
  ```
* **网络状态：**
  ```text
  AT+CPIN? -> +CPIN: READY
  AT+COPS? -> +COPS: 0,0,"JIO 4G Jio",7 (LTE E-UTRAN Connected)
  AT+CSQ   -> +CSQ: 28,99 (~-57 dBm excellent signal)
  ```
* **USB/数据模式查询（`AT+QCFG="usbnet"`）**：
  * 返回**`ERROR`**，因为 `AT+QCFG` 是专有的**移远（Quectel）**命令语法。
  * 这是一个**原生 Qualcomm 参考设计基带（`型号：4094`，Qualcomm Incorporated）**，内部不使用 USB-CDC 模拟。
  * **传输：** 它使用**原生 SoC BAM-DMUX DMA**（`/dev/bam_dmux8` / 通过 QMI WDS 的 `rmnet0`）进行 IP 数据传输，而非 USB CDC-ECM/NCM/QMI 加密狗接口。
