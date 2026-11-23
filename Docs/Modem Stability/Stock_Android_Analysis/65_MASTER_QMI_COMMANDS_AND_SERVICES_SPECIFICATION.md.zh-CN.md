# Qualcomm MSM8916 QMI 服务与命令主逆向工程规范
## 完整协议 IDL、消息目录、客户端 API（`libqmiservices`、`libqmi_cci`、`qmuxd`、`qmiproxy`）

**目标平台：** Qualcomm MSM8916（Snapdragon 410）原厂 Android 4.4.4  
**提取的二进制：**
- `libqmiservices.so`（87 KB，ARMv7 32 位小端）
- `libqmi.so`（190 KB，ARMv7 32 位小端）
- `libqmi_cci.so`（30 KB，ARMv7 32 位小端）
- `libqmi_client_qmux.so`（42 KB，ARMv7 32 位小端）
- `qmiproxy`（166 KB，ARMv7 32 位小端）
- `qmuxd`（84 KB，ARMv7 32 位小端）

**产物目录：** `Docs/Modem Stability/Stock_Android_Analysis/`  
**日期：** 2026-09-02  

---

## 1. 执行摘要与 QMI 服务架构

Qualcomm MSM8916 使用 Qualcomm MSM 接口（QMI）协议进行所有基带配置、网络连接建立、电源管理和 SIM 卡管理。

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                         QUALCOMM QMI PROTOCOL LAYER STACK                        │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Application Layer: rild / netmgrd / ModemManager / libqmi                        │
├──────────────────────────────────────────────────────────────────────────────────┤
│ QMI Service Layer: WDS (0x01), DMS (0x02), NAS (0x03), QoS (0x04), WMS (0x05),   │
│                    UIM (0x0B), TIME (0x16), DSD (0x2A), DPM (0x2F)               │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Client API Layer: QCCI (libqmi_cci.so) / Legacy QMI (libqmiservices.so)          │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Framing Layer: QMUX Framing (6-Byte Header) or QRTR AF_QIPCRTR                   │
├──────────────────────────────────────────────────────────────────────────────────┤
│ Physical Transport: SMD (/dev/smdcntl0..7) or BAM-DMUX DMA (wwan0)               │
└──────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 完整 QMI 服务目录与提取的命令

### 2.1 WDS（0x01）— 无线数据服务
*管理蜂窝分组数据会话、APN 配置文件、LTE 附着参数和数据统计。*

| 消息 ID | 命令 / API 函数 | 描述 |
|:---|:---|:---|
| `0x0020` | `qmi_wds_start_nw_if` | 使用指定的 APN、IP 类型和配置文件 ID 发起 LTE/3G 分组数据呼叫。 |
| `0x0021` | `qmi_wds_stop_nw_if` | 断开活动的蜂窝分组数据承载。 |
| `0x0022` | `qmi_wds_get_pkt_srvc_status` | 查询当前分组连接状态（已断开、连接中、已连接、已挂起）。 |
| `0x0024` | `qmi_wds_get_current_channel_rate` | 以 bps 返回瞬时上行/下行物理信道数据速率。 |
| `0x0025` | `qmi_wds_get_pkt_statistics` | 读取总 TX/RX 字节、数据包和错误丢弃计数器。 |
| `0x0026` | `qmi_wds_reset_pkt_statistics` | 重置会话数据包计数器。 |
| `0x0027` | `qmi_wds_create_profile` | 在调制解调器 NVRAM 中创建新的 PDP/APN 配置文件。 |
| `0x0028` | `qmi_wds_modify_profile` | 修改 APN、认证（PAP/CHAP）、PDP 类型（IPv4/IPv6）。 |
| `0x0029` | `qmi_wds_delete_profile` | 删除已存储的 APN 配置文件。 |
| `0x002A` | `qmi_wds_get_profile_list` | 枚举存储在调制解调器和 USIM 上的所有 APN 配置文件。 |
| `0x002B` | `qmi_wds_get_default_settings` | 读取默认运营商 APN 参数。 |
| `0x0030` | `qmi_wds_get_current_bearer_tech` | 查询活动无线电承载技术（LTE、HSPA+、WCDMA、EVDO）。 |
| `0x0085` | `qmi_wds_set_lte_attach_pdn_list` | 设置运营商默认 LTE 初始附着 APN 列表。 |
| `0x0086` | `qmi_wds_get_lte_attach_pdn_list` | 查询活动 LTE 初始附着 APN 列表。 |
| `0x0088` | `qmi_wds_set_lte_data_retry` | 配置 LTE 附着重试间隔。 |
| `0x009E` | `qmi_wds_bind_mux_data_port` | 将 WDS 客户端绑定到特定的 BAM-DMUX DMA / RmNet 通道。 |

---

### 2.2 DMS（0x02）— 设备管理服务
*设备硬件控制、运行模式、IMEI/MEID 序列号和基带重启。*

| 消息 ID | 命令 / API 函数 | 描述 |
|:---|:---|:---|
| `0x0020` | `qmi_dms_reset` | 重置 DMS 服务状态变量。 |
| `0x0022` | `qmi_dms_get_device_caps` | 查询最大无线电能力、支持的频段和版本。 |
| `0x0023` | `qmi_dms_get_device_serial_numbers` | 从基带读取 IMEI、MEID 和 ESN 号码。 |
| `0x002D` | `qmi_dms_get_operating_mode` | 读取电源模式：`0`=在线、`1`=低功耗模式（LPM）、`2`=工厂测试、`3`=离线。 |
| `0x002E` | `qmi_dms_set_operating_mode` | 切换调制解调器电源模式（例如将调制解调器置于在线或飞行/LPM）。 |
| `0x002F` | `qmi_dms_get_time` | 查询调制解调器内部实时时间戳。 |
| `0x0036` | `qmi_dms_get_device_rev_id` | 读取基带固件版本字符串（例如 `HIMI_U01_MODEM_V1.0`）。 |

---

### 2.3 NAS（0x03）— 网络接入服务
*蜂窝网络搜索、注册状态、信号质量和无线电技术偏好。*

| 消息 ID | 命令 / API 函数 | 描述 |
|:---|:---|:---|
| `0x0020` | `qmi_nas_set_event_report_state` | 订阅信号强度（RSSI、RSRP、RSRQ、SINR）变化指示。 |
| `0x0022` | `qmi_nas_get_serving_system` | 查询当前注册状态、漫游状态、MCC/MNC 和小区 ID。 |
| `0x0024` | `qmi_nas_initiate_ps_attach_detach`| 触发 LTE 分组交换（PS）域附着或分离。 |
| `0x0033` | `qmi_nas_set_sys_sel_pref` | 设置无线电接入技术（RAT）偏好（例如仅 4G LTE、自动）。 |
| `0x0034` | `qmi_nas_get_sys_sel_pref` | 读取活动 RAT 偏好、采集顺序和频段偏好。 |
| `0x004F` | `qmi_nas_get_sig_info` | 读取详细的 5 频段 LTE 信号指标（RSRP、RSRQ、RSSI、SINR）。 |
| `0x0051` | `qmi_nas_get_sys_info` | 全面的服务/邻区小区信息报告。 |

---

### 2.4 UIM（0x0B）— 用户身份模块服务
*SIM 卡存在、PIN 验证、ICCID/IMSI 读取和 APDU 通道传输。*

| 消息 ID | 命令 / API 函数 | 描述 |
|:---|:---|:---|
| `0x0020` | `qmi_uim_read_transparent` | 从 SIM 读取透明二进制基本文件（EF）（例如 EF_ICCID、EF_IMSI）。 |
| `0x0021` | `qmi_uim_read_record` | 从 SIM 文件系统读取线性固定 / 循环记录。 |
| `0x0022` | `qmi_uim_write_transparent` | 向 SIM EF 写入二进制数据。 |
| `0x0023` | `qmi_uim_write_record` | 更新 SIM EF 中的记录。 |
| `0x0025` | `qmi_uim_set_pin_protection` | 启用/禁用 SIM PIN1/PIN2 锁。 |
| `0x0026` | `qmi_uim_verify_pin` | 提交 PIN1/PIN2 代码以解锁 SIM。 |
| `0x0027` | `qmi_uim_unblock_pin` | 提交 PUK1/PUK2 代码以解锁被锁定的 SIM。 |
| `0x0028` | `qmi_uim_change_pin` | 修改现有 PIN 代码。 |
| `0x002B` | `qmi_uim_get_card_status` | 查询物理 SIM 存在、卡状态（就绪、需要 PIN、错误）和插槽。 |
| `0x0030` | `qmi_uim_power_down` / `power_up` | 切断或恢复物理 SIM 插槽的供电（GPIO 119）。 |
| `0x003B` | `qmi_uim_send_apdu` | 向 SIM 卡传输原始 ISO-7816-4 APDU 命令并读取响应。 |

---

### 2.5 TIME（0x16 / 22）— 时间同步服务
*将 Linux 应用处理器 RTC 时钟与 Hexagon 基带同步。*

| 消息 ID | 消息类型 | 描述 |
|:---|:---|:---|
| `0x0020` | `QMI_TIME_GENOFF_SET_REQ` | 将 GPS/Unix 纪元时间差写入基带（`ATS_USER` / `ATS_TOD`）。 |
| `0x0021` | `QMI_TIME_GENOFF_GET_REQ` | 读取当前基带时间偏移。 |
| `0x0025` | `QMI_TIME_REG_IND_REQ` | 注册主机以接收异步基站 NITZ / SIB16 广播指示。 |
| `0x0029` | `QMI_TIME_TOD_IND` | 基带向主机 AP 广播基站网络时间。 |

---

## 3. Qualcomm 通用客户端接口（`libqmi_cci.so`）

`libqmi_cci.so` 提供所有 Qualcomm 供应商守护进程使用的统一异步/同步 QMI 事务 API：

### 3.1 导出的 API 函数
```c
/* 1. Client Initialization & Binding */
qmi_client_error_type qmi_client_init_instance(
    qmi_idl_service_object_type service_obj,
    qmi_service_instance_instance_id instance_id,
    qmi_client_ind_cb ind_cb,
    void *ind_cb_data,
    qmi_client_os_params *os_params,
    qmi_client_type *user_handle);

/* 2. Synchronous Command Dispatch */
qmi_client_error_type qmi_client_send_msg_sync(
    qmi_client_type user_handle,
    unsigned int msg_id,
    void *req_c_struct,
    int req_c_struct_len,
    void *resp_c_struct,
    int resp_c_struct_len,
    int timeout_msecs);

/* 3. Asynchronous Command Dispatch */
qmi_client_error_type qmi_client_send_msg_async(
    qmi_client_type user_handle,
    unsigned int msg_id,
    void *req_c_struct,
    int req_c_struct_len,
    void *resp_c_struct,
    int resp_c_struct_len,
    qmi_client_recv_msg_async_cb resp_cb,
    void *resp_cb_data,
    qmi_txn_handle *txn_handle);

/* 4. Release Handle */
qmi_client_error_type qmi_client_release(qmi_client_type user_handle);
```

### 3.2 双传输操作
`libqmi_cci.so` 动态检测并选择传输后端：
* **`qcci_ipc_router_ops`**：使用内核共享内存上的 AF_QIPCRTR 套接字（低开销）。
* **`qmuxd_ops`**：使用连接到 `/dev/socket/qmux_radio/` 和 `/dev/smdcntl0..7` 的 UNIX 域套接字。

---

## 4. OpenWrt 实现与命令映射

在 OpenWrt 上，标准开源工具（`libqmi`、`qmicli`、`ModemManager`）使用完全相同的 QMI 协议语义：

```bash
# Query Device Capabilities (DMS 0x0022)
qmicli -d /dev/cdc-wdm0 --dms-get-capabilities

# Query Operating Mode (DMS 0x002D)
qmicli -d /dev/cdc-wdm0 --dms-get-operating-mode

# Set Operating Mode to Online (DMS 0x002E)
qmicli -d /dev/cdc-wdm0 --dms-set-operating-mode=online

# Query Serving System & Network Registration (NAS 0x0022)
qmicli -d /dev/cdc-wdm0 --nas-get-serving-system

# Query Signal Quality (NAS 0x004F)
qmicli -d /dev/cdc-wdm0 --nas-get-signal-info

# Query SIM Card Status (UIM 0x002B)
qmicli -d /dev/cdc-wdm0 --uim-get-card-status

# Start Data Session (WDS 0x0020)
qmicli -d /dev/cdc-wdm0 --wds-start-network="apn=jionet,ip-type=4" --client-no-release-cid
```

---
*报告记录于 Docs/Modem Stability/Stock_Android_Analysis/65_MASTER_QMI_COMMANDS_AND_SERVICES_SPECIFICATION.md*
