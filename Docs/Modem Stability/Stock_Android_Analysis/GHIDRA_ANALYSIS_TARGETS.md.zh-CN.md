# 原厂 Android 二进制逆向工程地图与 Ghidra 分析目标

**源系统：** Qualcomm MSM8916 上的原厂 Android 4.4.4（内核 3.10.28）  
**产物路径：** `Docs/Modem Stability/Stock_Android_Analysis/`  

---

## 1. 提取的主要二进制与库

所有文件都存储在 `Docs/Modem Stability/Stock_Android_Analysis/binaries/` 和 `vendor_libs/`（本地分析产物，未提交到仓库）。

### 1. `time_daemon` 与 `libtime_genoff.so`
* **用途**：QMI 服务 22（ATS / 时间服务）主机同步。
* **Ghidra 中的关键函数**：
  * `genoff_boot_tod_init()`：PMIC RTC（`/dev/rtc0`）与调制解调器 ATS 之间的初始启动时基同步。
  * `tod_update_ind_cb()`：处理来自调制解调器的异步网络 NITZ / SIB16 广播指示。
  * `genoff_modem_qmi_init()`：通过 `AF_QIPCRTR`（端口 11，服务 22）初始化 QMI 客户端。
  * `time_genoff_operation()`：底层 QMI 消息格式化（`QMI_TIME_GENOFF_SET_REQ` `0x0020`、`QMI_TIME_REG_IND_REQ` `0x0025`）。

---

### 2. `libqmiservices.so` 与 `libqmi_cci.so`
* **用途**：Qualcomm QMI IDL 类型表和通用客户端接口（CCI）。
* **Ghidra 中的关键符号表**：
  * `time_service_get_service_object_v01()`：QMI 服务 22 消息结构和 TLV 布局。
  * `wds_get_service_object_v01()`：无线数据服务（WDS）休眠和承载状态。
  * `dms_get_service_object_v01()`：设备管理服务（DMS）掉电和无线电状态。

---

### 3. `libril-qc-qmi-1.so` 与 `netmgrd`
* **用途**：RIL 数据呼叫处理和网络管理。
* **Ghidra 中的关键函数**：
  * `qmi_ril_data_call_list_changed()`：以 `active=2`（`DORMANT`）分发 `UNSOL_DATA_CALL_LIST_CHANGED`。
  * `netmgr_kif_cb()`：跨通道 `ch00`–`ch07` 的 BAM-DMUX 链路状态监控。

---

### 4. `rmt_storage`（`/system/bin/rmt_storage`）
* **用途**：面向 Hexagon DSP 的远程 EFS2 存储服务器。
* **关键行为**：
  * 使用 POSIX 共享内存（`-P -s`）直接 DMA 访问 `/dev/block/bootdevice/by-name/`（`modemst1`、`modemst2`、`fsg`、`fsc`）。
  * 处理 900 秒周期性无线电校准同步。
