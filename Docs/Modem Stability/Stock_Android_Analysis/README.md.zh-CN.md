# 原厂 Android 取证分析与逆向工程索引

**目标设备：** Qualcomm MSM8916 Snapdragon 410（通用 HMU05 / UFI）  
**基带固件：** `HIMI_U01_MODEM_V1.0`（`MPSS.DPM.1.0.C7`）  
**固件系统：** 原厂 Android 4.4.4（内核 3.10.28）  
**记录的连续运行时间：** **>33 分钟（2,010+ 秒）**，0% 丢包且 0 调制解调器错误。  

> ⚠️ **更正通知（2026-10-07）。** 这些报告始于 2026 年 9 月，其建立在一个
> 现已**撤回**的前提之上：即约 900 秒的调制解调器致命错误是一个 900 秒的 SCLK/DRX 维护定时器（
> 并且 `rmt_storage` 执行"900 秒 NV 同步刷写"）。真正的原因在于调制解调器射频任务的
> `memcmp` 将 NV 项 2500 与字面量 `"HiMI_OK"` 比较，由 **AP 侧**的 `himi-ok-guard` 修复。
> 在引用此处任何内容之前，请阅读父级索引 [`../README.md`](../README.md) 与账本
> [`../197_UZ801_PORT_LEDGER_AND_MANDATORY_SOP.md`](../197_UZ801_PORT_LEDGER_AND_MANDATORY_SOP.md)
> §112.165–§112.171。

---

## 1. 目录内容与报告

| 文档 / 资产 | 描述 |
| :--- | :--- |
| [`STOCK_ANDROID_GROUND_TRUTH_REPORT.md`](STOCK_ANDROID_GROUND_TRUTH_REPORT.md) | 详细说明硬件 GPIO、分区布局和 DMA 架构的全面主报告。 |
| [`17_WHY_STOCK_ANDROID_DOES_NOT_CRASH.md`](17_WHY_STOCK_ANDROID_DOES_NOT_CRASH.md) | 防止 15 分钟崩溃的 4 个稳定机制的深入对比分解。 |
| [`23_MODEM_COMMUNICATION_PROTOCOL_TRACE.md`](23_MODEM_COMMUNICATION_PROTOCOL_TRACE.md) | 动态 `strace`、`lsof` 和 `/proc/PID/fd/` 系统调用跟踪及 QMI 数据包分解。 |
| [`GHIDRA_ANALYSIS_TARGETS.md`](GHIDRA_ANALYSIS_TARGETS.md) | Ghidra/IDA 逆向工程目标列表（`time_daemon`、`libril-qc-qmi-1.so`、`libqmiservices.so`）。 |
| `binaries/` | 提取的供应商可执行文件（`time_daemon`、`qmuxd`、`netmgrd`、`rild`、`rmt_storage`、`thermal-engine`）。*（本地分析产物 — 未提交到仓库。）* |
| `vendor_libs/` | 完整的 Qualcomm QMI、RIL 和时间共享库（`.so`）。*（本地分析产物 — 未提交到仓库。）* |

> `binaries/`、`vendor_libs/` 和 `hw_libs/` 目录是提取的原厂 Android 产物，
> **仅**保留在分析机器上；它们不属于本仓库。以下报告对其进行描述。

---

## 2. 关键诊断发现

1. **硬件 GPIO 映射**：
   * **GPIO 119（`esim1_en`）**：`HIGH`（255）$\rightarrow$ 为主 SIM 供电。
   * **GPIO 114（`sim_hotplug`）**：`LOW`（0）$\rightarrow$ SIM 存在检测。
   * **GPIO 71（`4g_1`）**：`HIGH`（1）$\rightarrow$ 4G 射频路径与状态 LED。
2. **时间同步**：
   * `time_daemon` 在启动时设置一次 RTC 偏移，然后在 `poll()` 中等待异步 NITZ 基站指示。
3. **BAM-DMUX DMA 传输**：
   * 以 Raw-IP 模式运行，无 1000ms 自动挂起抖动；在协议层转换为 `DORMANT`（`active=2`），同时保持 DMA 描述符活动。
4. **EFS 存储**：
   * `rmt_storage` 对 `/dev/block/bootdevice/by-name/` 具有读写访问权限，用于 900 秒 NV 同步刷写。
