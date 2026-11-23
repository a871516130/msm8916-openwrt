# Qualcomm MSM8916 `qmiproxy` 与 `qmuxd` 逆向工程报告
## IPC 架构、QMI 传输路由与电源锁同步

**分析的二进制：**
1. `/system/bin/qmiproxy`（166,452 字节，ARMv7 32 位小端）
2. `/system/bin/qmuxd`（84,592 字节，ARMv7 32 位小端）

**目标平台：** Qualcomm MSM8916（Snapdragon 410）原厂 Android 4.4.4  
**提取来源：** 实机 `c2b9103c`（`192.168.100.1`）  
**产物目录：** `Docs/Modem Stability/Stock_Android_Analysis/`  
**日期：** 2026-09-02  

---

## 1. 执行摘要与栈架构

在 Qualcomm MSM8916 的原厂 Android 中，用户空间客户端（如 `rild`、`netmgrd`、网络共享）与 Hexagon QDSP6 调制解调器基带之间的通信被组织为多层 IPC 传输管道：

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                   QUALCOMM STOCK ANDROID QMI IPC PIPELINE                         │
├──────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   [ Client Applications / Daemons: rild, netmgrd, wdsdaemon, Settings App ]      │
│                                   │                                              │
│                                   │ (UNIX Domain Socket: AF_UNIX)                │
│                                   v                                              │
│   ┌──────────────────────────────────────────────────────────────────────────┐   │
│   │                      /system/bin/qmiproxy                                │   │
│   │  • Sockets: /dev/socket/qmux_radio/proxy_qmux_connect_socket             │   │
│   │             /dev/socket/qmux_radio/proxy_tether_connect_socket           │   │
│   │  • Multi-client QMI transaction arbitration & dispatch                   │   │
│   │  • SGLTE / SVLTE Dual-stack voice/data state machine                     │   │
│   │  • System selection preference & mode arbitration (NAS / DMS / WMS)      │   │
│   └──────────────────────────────────────────────────────────────────────────┘   │
│                                   │                                              │
│                                   │ (UNIX Domain Socket)                         │
│                                   v                                              │
│   ┌──────────────────────────────────────────────────────────────────────────┐   │
│   │                      /system/bin/qmuxd                                   │   │
│   │  • Socket: /dev/socket/qmux_radio/qmux_connect_socket                    │   │
│   │  • QMUX protocol packet framing & client ID allocation                   │   │
│   │  • Wake-Lock Management: /sys/power/wake_lock (qmuxd_port_wl_0..7)       │   │
│   │  • Physical SMD Channel Multiplexing: /dev/smdcntl0 .. /dev/smdcntl7     │   │
│   └──────────────────────────────────────────────────────────────────────────┘   │
│                                   │                                              │
│                                   │ (SMD Character Device I/O)                   │
│                                   v                                              │
│   ┌──────────────────────────────────────────────────────────────────────────┐   │
│   │             Kernel SMD Drivers (drivers/soc/qcom/smd.c)                  │   │
│   └──────────────────────────────────────────────────────────────────────────┘   │
│                                   │                                              │
│                                   │ (Shared Memory IPC / SMSM interrupts)        │
│                                   v                                              │
│   ┌──────────────────────────────────────────────────────────────────────────┐   │
│   │                  Hexagon QDSP6 v5 Baseband Core                          │   │
│   └──────────────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 逆向工程 `qmiproxy`（166 KB）

### 2.1 组件源码布局（从二进制符号恢复）
该二进制由专有 Qualcomm QMI 代码库编译：
* `vendor/qcom/proprietary/qmi/proxy/qmi_proxy.c`（主路由与套接字监听器）
* `vendor/qcom/proprietary/qmi/proxy/qmi_proxy_sm.c`（通用代理状态机）
* `vendor/qcom/proprietary/qmi/proxy/qmi_proxy_sglte_sm.c`（GSM 与 LTE 同时仲裁）
* `vendor/qcom/proprietary/qmi/proxy/qmi_proxy_queue.c`（线程安全事务 FIFO 队列）

### 2.2 套接字与 IPC 接口
`qmiproxy` 绑定并监听两个专用的抽象/文件系统 UNIX 域套接字：
1. `/dev/socket/qmux_radio/proxy_qmux_connect_socket`（由 `rild`、`netmgrd`、电话服务使用）
2. `/dev/socket/qmux_radio/proxy_tether_connect_socket`（由 USB/Wi-Fi 网络共享守护进程使用）

### 2.3 服务仲裁子系统
`qmiproxy` 拦截、缓存并仲裁所有标准 QMI 服务的请求：

| QMI 服务 | `qmiproxy` 中的仲裁函数 | 关键职责 |
|:---|:---|:---|
| **NAS（0x03）** | `qmi_proxy_nas_srvc_arb_hdlr` | 仲裁系统选择偏好（`NAS_SET_SYS_SEL_PREF`）、网络扫描（`NAS_PER_NET_SCAN`）、信号信息（`NAS_GET_SIG_INFO`）和 RAT 模式掩码。 |
| **DMS（0x02）** | `qmi_proxy_dms_srvc_arb_hdlr` | 同步运行模式更改（`DMS_SET_OPRT_MODE` -> 在线、低功耗模式、工厂测试）。 |
| **WMS（0x05）** | `qmi_proxy_wms_srvc_arb_hdlr` | 管理 SMS 指示注册和消息路由。 |
| **VOICE（0x09）**| `qmi_proxy_voice_srvc_arb_hdlr`| 跟踪语音通话活动状态，防止 CS/PS 切换中断数据通话。 |
| **PBM（0x07）** | `qmi_proxy_pbm_srvc_arb_hdlr` | 电话簿管理器仲裁。 |
| **SAR（0x11）** | `qmi_proxy_sar_srvc_arb_hdlr` | 比吸收率射频功率回退控制。 |
| **IMS VT** | `qmi_proxy_ims_vt_srvc_arb_hdlr` | IMS 视频电话 QoS 请求。 |
| **IMS Presence**| `qmi_proxy_ims_presence_srvc_arb_hdlr` | IMS Presence 能力。 |

### 2.4 事务生命周期
1. `qmi_proxy_init_qmux_listener()`：在套接字上生成监听线程。
2. `qmi_proxy_rx_hdlr()`：从客户端 FD 读取 QMUX 成帧请求。
3. `qmi_proxy_decode_qmi_srvc_message()`：解析 QMI 服务 ID、消息 ID 和 TLV。
4. `qmi_proxy_add_txn_entry()` / `qmi_proxy_queue_push()`：分配跟踪事务 ID。
5. `qmi_proxy_dispatch_txn()`：将请求转发给 `qmuxd`。
6. `qmi_proxy_send_response_to_clients()`：将调制解调器响应分发回请求客户端 FD。

---

## 3. 逆向工程 `qmuxd`（84 KB）

### 3.1 内核设备绑定
`qmuxd` 是通往内核 SMD 字符设备的直接桥梁：
* `/dev/smdcntl0` – 默认无线电 / 控制端口
* `/dev/smdcntl1` – 主数据 / Netmgr 端口
* `/dev/smdcntl2` – 辅助数据端口
* `/dev/smdcntl3` – 辅助 / IMS 端口
* `/dev/smdcntl4` – GPS / 定位端口
* `/dev/smdcntl5` – 蓝牙 / 音频端口
* `/dev/smdcntl6` – 测试 / 诊断端口
* `/dev/smdcntl7` – 子系统管理端口

### 3.2 电源管理与唤醒锁处理
在 `qmuxd` 中，每个物理端口都有一个关联的内核唤醒锁：
* `qmuxd_port_wl_0` 至 `qmuxd_port_wl_7`

#### 唤醒锁执行例程：
```c
void qmuxd_acquire_wake_lock(int port_id) {
    char lock_name[64];
    snprintf(lock_name, sizeof(lock_name), "qmuxd_port_wl_%d", port_id);
    int fd = open("/sys/power/wake_lock", O_WRONLY);
    if (fd >= 0) {
        write(fd, lock_name, strlen(lock_name));
        close(fd);
    }
}

void qmuxd_release_wake_lock(int port_id) {
    char lock_name[64];
    snprintf(lock_name, sizeof(lock_name), "qmuxd_port_wl_%d", port_id);
    int fd = open("/sys/power/wake_unlock", O_WRONLY);
    if (fd >= 0) {
        write(fd, lock_name, strlen(lock_name));
        close(fd);
    }
}
```
* **为何这至关重要：** 当 QMI 请求发送到 Hexagon DSP 时，`qmuxd` 立即获取 `qmuxd_port_wl_X`。这防止 Linux 应用处理器在调制解调器处理命令时进入挂起状态。一旦 Hexagon DSP 通过 SMD 发送响应，`qmuxd` 读取响应并释放唤醒锁。

### 3.3 QMUX 数据包成帧格式
`qmuxd` 使用标准的 6 字节 QMUX 头对所有数据进行成帧：
```text
Offset  Size  Field          Description
──────  ────  ─────────────  ──────────────────────────────────────────
0x00    1     I/F Flag       0x01 (Always 0x01 for QMUX packet)
0x01    2     Length         Total packet length including QMUX header
0x03    1     Control Flag   0x00 = Request/Response, 0x80 = Indication
0x04    1     Service Type   QMI Service ID (e.g. 0x01=WDS, 0x03=NAS)
0x05    1     Client ID      Assigned QMI Client ID (0x01..0xFF)
0x06    ...   SDU Body       QMI Control/Service Message Payload
```

---

## 4. 面向 OpenWrt 的关键要点

1. **OpenWrt 上的唤醒锁等效机制：**
   * 在 OpenWrt / 主线 Linux 中，ModemManager 和 `qmi_wwan` / `qcom_bam_dmux` 使用内核 Runtime PM 框架，而非用户空间的 `/sys/power/wake_lock`。
   * 这就是为什么我们的**二级修复**（`bam_dmux_netdev_open()` 中的 `pm_runtime_resume_and_get()` + sysfs `control=on` / `autosuspend_delay_ms=-1`）完美复刻了 `qmuxd` 在内核驱动层的唤醒锁保证！

2. **OpenWrt 上无需用户空间 `qmiproxy`/`qmuxd`：**
   * OpenWrt 的 `libqmi` 和 `ModemManager` 直接与内核设备通信（`/dev/wwan0qmi0` / `/dev/cdc-wdm0` / QRTR 套接字），绕开用户空间套接字代理层，同时保持完整的 QMI 消息兼容性。

---
*报告记录于 Docs/Modem Stability/Stock_Android_Analysis/59_QMIPROXY_AND_QMUXD_REVERSE_ENGINEERING_REPORT.md*
