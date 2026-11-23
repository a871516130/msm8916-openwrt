# Qualcomm MSM8916 原厂 Android 地面实况分析报告

**目标板卡：** 通用 HMU05 / UFI（Snapdragon 410 / MSM8916）  
**基带固件：** `HIMI_U01_MODEM_V1.0`（`MPSS.DPM.1.0.C7`）  
**Android 版本：** Android 4.4.4 KTU84P（内核 3.10.28）  
**捕获日期：** 2026-09-02  

---

## 1. 执行摘要

通过对物理 HMU05 硬件上已 root 的原厂 Android 固件进行插桩，我们捕获了以下精确的地面实况配置：
1. **GPIO 引脚配置与 SIM 控制**
2. **分区布局与存储节点**
3. **BAM-DMUX 与 SPS DMA 配置**
4. **守护进程架构（`rild`、`qmuxd`、`netmgrd`、`time_daemon`、`rmt_storage`）**
5. **数据呼叫生命周期（活动 vs. 休眠）**

---

## 2. 硬件 GPIO 与引脚复用映射

来自 `/sys/kernel/debug/gpio`（`msm_tlmm_v4_gpio` 的基址 902）：

| 信号名称 | 内核 GPIO ID | TLMM 物理 GPIO | 方向 | 原厂状态 | 用途 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`esim1_en`** | `gpio-1021` | **GPIO 119** | `out` | **`HIGH`（255）** | **主 SIM / eSIM 1 电源与选择** |
| **`sim_hotplug`**| `gpio-1016` | **GPIO 114** | `out` | **`LOW`（0）** | **SIM 热插拔检测线** |
| **`4g_1`** | `gpio-973` | **GPIO 71** | `out` | **`HIGH`（1）** | **4G LTE 射频电源 / LTE 状态 LED** |
| **`4g_type`** | `gpio-974` | **GPIO 72** | `out` | `LOW`（0） | 4G 网络模式指示器 |
| **`wifistatus`** | `gpio-975` | **GPIO 73** | `out` | **`HIGH`（1）** | Wi-Fi 电源 / WLAN 状态 LED |
| **`key_freset`** | `gpio-939` | **GPIO 37** | `in` | `LOW`（0） | 恢复出厂设置按钮 |
| **`esim2_en`** | `gpio-916` | **GPIO 14** | `out` | `LOW`（0） | 副 eSIM 2 选择 |
| **`esim3_en`** | `gpio-914` | **GPIO 12** | `out` | `LOW`（0） | 第三 eSIM 3 选择 |
| **`USB_ID_GPIO`** | `gpio-1012`| **GPIO 110** | `in` | `HIGH`（1） | USB ID / OTG 检测 |

> **关键发现：** 在 OpenWrt DTS 上，GPIO 119（`esim1_en`）必须置为 HIGH、GPIO 114（`sim_hotplug`）置为 LOW，以确保物理 SIM 插槽保持通电并被基带检测到。

---

## 3. 原厂分区表布局

来自 `/proc/partitions` 和 `/dev/block/bootdevice/by-name/`：

* `mmcblk0p1`：**`modem`**（64 MB vfat，挂载于 `/firmware`）
* `mmcblk0p13`：**`modemst1`**（1.5 MB 原始，EFS2 NV 主）
* `mmcblk0p14`：**`modemst2`**（1.5 MB 原始，EFS2 NV 备份）
* `mmcblk0p16`：**`fsc`**（1 KB 原始，EFS Cookie）
* `mmcblk0p20`：**`fsg`**（1.5 MB 原始，出厂黄金 EFS）
* `mmcblk0p24`：**`persist`**（32 MB ext4，挂载于 `/persist`）
* `mmcblk0p22`：**`boot`**（16 MB 原始，内核启动镜像）
* `mmcblk0p23`：**`system`**（800 MB ext4，Android 根/系统）
* `mmcblk0p28`：**`userdata`**（2.3 GB ext4，数据分区）

---

## 4. BAM-DMUX DMA 架构

来自 `/d/bam_dmux/tbl` 和 `/d/bam_dmux/stats`：

```text
ch00 local open=Y remote open=Y
ch01 local open=Y remote open=Y
ch02 local open=Y remote open=Y
ch03 local open=Y remote open=Y
ch04 local open=Y remote open=Y
ch05 local open=Y remote open=Y
ch06 local open=Y remote open=Y
ch07 local open=Y remote open=Y
```

* **无空闲自动挂起抖动**：`runtime_status` 为 `unsupported`。原厂 Android **不**每 1000 ms 掉电 BAM-DMUX。
* **持久 DMA 通道**：全部 8 个数据通道（`ch00`–`ch07`）保持打开并与 Hexagon A2 DMA 引擎同步。
* **休眠 vs. 挂起**：当流量暂停时，调制解调器通过 `UNSOL_DATA_CALL_LIST_CHANGED` 以 `active=2`（`DORMANT`）通知主机，但 DMA 环形缓冲区保持完整。

---

## 5. 守护进程与同步流程

1. **`time_daemon`（`/system/bin/time_daemon`）**：
   * 从 `/dev/rtc0` 读取 RTC。
   * 在启动时通过 `genoff_boot_tod_init` 初始化调制解调器基偏移。
   * 注册 `tod_update_ind_cb` 以接收来自调制解调器的异步 NITZ 基站时间指示。
   * **不**在忙等循环中轮询或刷 `genoff_set`。
2. **`rmt_storage`（`/system/bin/rmt_storage`）**：
   * 以 `-P -s` 以完整读写模式运行，目标为 `/dev/block/bootdevice/by-name/` 节点。
   * 处理 900 秒周期性 EFS2 同步刷写而不被拒绝。
3. **`qmuxd` 与 `netmgrd`**：
   * 跨 SMD 通道 `DATA40_CNTL` 和 IPCRTR 调解 QMI 消息。
