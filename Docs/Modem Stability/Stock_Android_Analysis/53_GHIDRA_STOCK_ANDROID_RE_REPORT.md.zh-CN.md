# Qualcomm MSM8916 原厂 Android 二进制逆向工程报告
## 全面的 Ghidra 无头反编译与协议重建

**目标硬件：** Qualcomm Snapdragon 410 / MSM8916（通用 HMU05 / UFI-001C）  
**基带版本：** `HIMI_U01_MODEM_V1.0`（`MPSS.DPM.1.0.C7`）  
**Android 构建：** Android 4.4.4 KTU84P（内核 3.10.28）  
**Ghidra 版本：** 12.1.2_PUBLIC（无头 ARM 32 位小端反编译器）  
**产物目录：** `Docs/Modem Stability/Stock_Android_Analysis/`  
**日期：** 2026-09-02  

---

## 1. 执行摘要

使用 Ghidra 12.1.2 无头反编译直接对提取的原厂 Android 二进制（`time_daemon`、`libtime_genoff.so`、`rmt_storage`、`qmuxd`、`netmgrd`、`libqmiservices.so`、`thermal-engine`）进行分析，我们完整逆向工程了防止原厂 Android 在 15 分钟后（$t = 900\text{s}$）崩溃的专有协议层。

本报告提供字节级 C 反编译、数据包结构、套接字路径和状态机图，用于在 OpenWrt / Linux 主线复现这些行为。

```
╔══════════════════════════════════════════════════════════════════════════════════════════╗
║                         REVERSE-ENGINEERED SUBSYSTEM TOPOLOGY                           ║
╠════════════════════╦══════════════════════════════════╦══════════════════════════════════╣
║ BINARY / LIBRARY   ║ IPC INTERFACE                    ║ REVERSE-ENGINEERED ROLE          ║
╠════════════════════╬══════════════════════════════════╬══════════════════════════════════╣
║ time_daemon        ║ QMI Service 22 + /dev/rtc0       ║ Anchors Modem ATS TOD to RTC0 at ║
║                    ║ + \0time_genoff (AF_UNIX)        ║ boot via QMI 0x0020; handles NITZ║
╠════════════════════╬══════════════════════════════════╬══════════════════════════════════╣
║ libtime_genoff.so  ║ \0time_genoff (32-byte struct)   ║ Client IPC library for apps to   ║
║                    ║ (AF_UNIX abstract socket)        ║ get/set ATS time from daemon     ║
╠════════════════════╬══════════════════════════════════╬══════════════════════════════════╣
║ rmt_storage        ║ QMI CSI + /dev/uio0 (DMA)        ║ Serves Hexagon DSP EFS2 sync     ║
║                    ║ + /dev/block/bootdevice/by-name  ║ requests to modemst1/st2/fsg/fsc ║
╠════════════════════╬══════════════════════════════════╬══════════════════════════════════╣
║ qmuxd              ║ /dev/smdcntl0-7 + /dev/socket/   ║ Multiplexes QMI across SMD with  ║
║                    ║ qmux_radio/qmux_connect_socket   ║ per-packet kernel wake-locks     ║
╠════════════════════╬══════════════════════════════════╬══════════════════════════════════╣
║ netmgrd            ║ Netlink + librmnetctl + QMI WDS  ║ Manages rmnet0 BAM DMA endpoints ║
║                    ║ + /dev/diag                      ║ & IP data call lifecycle         ║
╠════════════════════╬══════════════════════════════════╬══════════════════════════════════╣
║ libqmiservices.so  ║ Qualcomm IDL Type Tables         ║ Full service descriptors for     ║
║                    ║ (CSI / CCI runtime)              ║ WDS, DMS, NAS, UIM, TIME, DSD    ║
╚════════════════════╩══════════════════════════════════╩══════════════════════════════════╝
```

---

## 2. `time_daemon` 与 QMI 服务 22 深入剖析

### 2.1 完整初始化与同步工作流

从反编译的 `FUN_000113d0` 和 `FUN_00010ef4`：

```
+-------------------------------------------------------------------------------+
|                       time_daemon Boot Synchronization Flow                   |
|                                                                               |
|  [Step 1] open("/dev/rtc0", O_RDONLY)                                         |
|  [Step 2] ioctl(fd, RTC_RD_TIME, &tm)                                         |
|  [Step 3] rtc_ms = (mktime(&tm) + tm.tm_gmtoff) * 1000                        |
|  [Step 4] qmi_client_notifier_init(time_service_get_service_object_v01())     |
|  [Step 5] qmi_client_get_service_list() -> wait up to 6s for modem QMI ready  |
|  [Step 6] qmi_client_init(..., &client_handle)                                |
|  [Step 7] Build QMI_TIME_GENOFF_SET_REQ (0x0020):                             |
|           - base = 2 (ATS TOD / User Base)                                    |
|           - ts_val = rtc_ms (64-bit uint)                                     |
|           - unit = 1 (ms)                                                     |
|  [Step 8] qmi_client_send_msg_sync(handle, 0x0020, &req, 0x10, &resp, 8, 5000)|
|  [Step 9] Mark is_initialized = 1; Enter event loop (0% CPU)                  |
+-------------------------------------------------------------------------------+
```

### 2.2 RTC 读取函数（`FUN_00010ef4`）

```c
// Decompiled from /system/bin/time_daemon @ 0x00010ef4
int get_rtc_time_in_ms(uint64_t *rtc_ms_out)
{
    int fd = open("/dev/rtc0", O_RDONLY);
    if (fd < 0) {
        __android_log_print(ANDROID_LOG_ERROR, "TimeDaemon", "Failed to open /dev/rtc0");
        return -EINVAL;
    }

    struct tm rtc_tm;
    int ret = ioctl(fd, RTC_RD_TIME, &rtc_tm);
    if (ret < 0) {
        __android_log_print(ANDROID_LOG_ERROR, "TimeDaemon", "RTC_RD_TIME ioctl failed");
        close(fd);
        return -EINVAL;
    }

    time_t t = mktime(&rtc_tm);
    int64_t total_sec = (int64_t)t + rtc_tm.tm_gmtoff;
    if (total_sec >= 0) {
        *rtc_ms_out = (uint64_t)total_sec * 1000ULL;
        close(fd);
        return 0; // Success
    }

    close(fd);
    return -EINVAL;
}
```

### 2.3 调制解调器异步指示回调（`FUN_00011670`）

```c
// Decompiled from /system/bin/time_daemon @ 0x00011670
void time_qmi_ind_callback(qmi_client_type user_handle, unsigned int msg_id,
                           void *ind_buf, unsigned int ind_buf_len, void *ind_cb_data)
{
    // Filter for valid time update indications:
    // 0x29 = QMI_TIME_ATS_TOD_IND (Tower Time of Day Indication)
    // 0x2d = QMI_TIME_ATS_USER_IND (User / NITZ Indication)
    // 0x2e = QMI_TIME_ATS_SECURE_IND
    if (msg_id != 0x29 && (msg_id - 0x2d > 1)) {
        return;
    }

    uint32_t decoded_msg[4]; // local_28[0] contains base_id
    int ret = qmi_client_message_decode(user_handle, QMI_IDL_INDICATION, msg_id,
                                        ind_buf, ind_buf_len, decoded_msg, sizeof(decoded_msg));
    if (ret == QMI_NO_ERR && decoded_msg[0] < 15) {
        pthread_mutex_lock(&time_daemon_mutex);
        pending_base_id = decoded_msg[0];
        has_pending_update = 1;
        pthread_cond_signal(&time_daemon_cond); // Wake worker thread (FUN_000120d0)
        pthread_mutex_unlock(&time_daemon_mutex);
    }
}
```

### 2.4 工作线程查询循环（`FUN_000120d0`）

```c
// Decompiled from /system/bin/time_daemon @ 0x000120d0
void *time_daemon_worker_thread(void *arg)
{
    while (1) {
        pthread_mutex_lock(&worker_mutex);
        while (!has_pending_update) {
            pthread_cond_wait(&worker_cond, &worker_mutex);
        }

        uint32_t base_to_query = pending_base_id;
        has_pending_update = 0;
        pthread_mutex_unlock(&worker_mutex);

        // Query updated time from baseband via QMI_TIME_GENOFF_GET_REQ (0x0021)
        uint32_t req = base_to_query;
        uint8_t resp_buf[0x18]; // 24 bytes response struct
        memset(resp_buf, 0, sizeof(resp_buf));

        int ret = qmi_client_send_msg_sync(time_client_handle, 0x0021,
                                           &req, sizeof(req),
                                           resp_buf, sizeof(resp_buf), 1000);
        if (ret == QMI_NO_ERR) {
            uint64_t modem_ts = *(uint64_t *)(resp_buf + 12);
            // Re-sync local clock state table
            update_local_base_table(base_to_query, modem_ts);
        }
    }
}
```

---

## 3. `libtime_genoff.so` IPC 客户端协议

### 3.1 抽象 Unix 套接字架构

* **套接字域：** `AF_UNIX`（1）
* **套接字类型：** `SOCK_STREAM`（1）
* **套接字地址：** `\0time_genoff`（抽象命名空间：`sa_family=AF_UNIX`，`sa_data[0]='\0'`，`sa_data[1..11]="time_genoff"`）
* **超时：** `SO_RCVTIMEO` = 10s，`SO_SNDTIMEO` = 10s

### 3.2 32 字节 IPC 消息结构（`time_genoff_msg`）

```c
struct time_genoff_msg {
    uint32_t base;        // Offset 0x00: Time base ID (0 = RTC, 1 = TOD, 2 = USER, ...)
    uint32_t unit;        // Offset 0x04: 1 = ms (uint64), 2 = secs, 3 = struct tm
    uint32_t operation;   // Offset 0x08: 0 = SET, 1 = GET, 2 = SET_AND_GET, 3 = DISABLE, 4 = ENABLE
    uint64_t ts_val;      // Offset 0x0C: 64-bit timestamp value in milliseconds
    int32_t  result;      // Offset 0x14: -1 = pending/error, 0 = success
    uint32_t reserved[2]; // Offset 0x18: Padding / context
}; // sizeof = 32 bytes (0x20)
```

### 3.3 操作与基础 ID 表

| 基础 ID | 常量名称 | 描述 |
|:---|:---|:---|
| **0** | `TIME_BASE_RTC` | 硬件实时时钟 |
| **1** | `TIME_BASE_TOD` | 时刻（蜂窝网络时间） |
| **2** | `TIME_BASE_USER` | 用户调整时钟（用于 SCLK 同步） |
| **3** | `TIME_BASE_SECURE` | DRM / 安全子系统时间 |
| **4** | `TIME_BASE_GPS` | GPS 时间戳偏移 |
| **5** | `TIME_BASE_1X` | CDMA 1x 系统时间 |
| **6** | `TIME_BASE_HDR` | EV-DO HDR 系统时间 |
| **7** | `TIME_BASE_WCDMA` | WCDMA 系统时间 |
| **8** | `TIME_BASE_LTE` | LTE SIB16 系统时间 |

---

## 4. `rmt_storage` 逆向工程与 EFS2 同步

### 4.1 QMI CSI 架构

`rmt_storage` **不是**作为标准文件服务器运行。它注册为 QMI 服务 ID `0x14`（`QMI_RMTFS_SERVICE`）的 **QMI CSI（通用服务接口）服务器**。

### 4.2 UIO 内存映射 DMA 发现

从反编译的 `rmt_storage`：
1. 扫描 `/sys/class/uio/` 以查找名为 `rmtfs` 的设备。
2. 从 `/sys/class/uio/uio%d/maps/map0/addr` 读取物理 DMA 地址。
3. 打开 `/dev/uio0` 并调用 `mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)`。
4. 通过 QMI 响应消息将虚拟映射指针与 Hexagon DSP 共享。

### 4.3 分区打开与 I/O 循环

```c
// Partitions registered by rmt_storage:
// 1. /dev/block/bootdevice/by-name/modemst1  (EFS2 Primary)
// 2. /dev/block/bootdevice/by-name/modemst2  (EFS2 Backup)
// 3. /dev/block/bootdevice/by-name/fsg       (Golden EFS)
// 4. /dev/block/bootdevice/by-name/fsc       (EFS Cookie)

void rmt_storage_handle_rw_request(struct rmt_req *req)
{
    // Acquire kernel wakelock to prevent CPU power collapse during NV writeback
    write(wake_lock_fd, "rmt_storage_0", 13);

    int fd = open_partition(req->partition_id);
    if (req->is_write) {
        lseek64(fd, req->sector_offset * 512, SEEK_SET);
        write(fd, req->dma_shared_buf, req->num_sectors * 512);
        fsync(fd);
    } else {
        lseek64(fd, req->sector_offset * 512, SEEK_SET);
        read(fd, req->dma_shared_buf, req->num_sectors * 512);
    }

    close(fd);
    qmi_csi_send_resp(req->req_handle, QMI_RMTFS_RW_RESP, &resp, sizeof(resp));

    // Release wakelock
    write(wake_unlock_fd, "rmt_storage_0", 13);
}
```

> **面向 OPENWRT 的关键洞察：**  
> 当 OpenWrt 的 `rmtfs` 以 `-r`（只读）启动时，在 $t = 900\text{s}$ 时每个写请求都会在 `write()` 处失败。调制解调器基带检测到 EFS2 刷写失败并以 `Excep :0:` 崩溃。`rmtfs` **必须**以完整读写权限运行！

---

## 5. `qmuxd` 与 QMI 路由架构

### 5.1 SMD 通道映射

`qmuxd` 打开 8 个专用 Qualcomm 共享内存控制通道：
* `/dev/smdcntl0` $\rightarrow$ 调制解调器控制 0（RIL / 电话）
* `/dev/smdcntl1` $\rightarrow$ 调制解调器控制 1（数据 / WDS）
* `/dev/smdcntl2` $\rightarrow$ 调制解调器控制 2（QoS）
* `/dev/smdcntl3` $\rightarrow$ 调制解调器控制 3（IMS）
* `/dev/smdcntl4` $\rightarrow$ 调制解调器控制 4（网络共享 / QCMAP）
* `/dev/smdcntl5` $\rightarrow$ 调制解调器控制 5（音频）
* `/dev/smdcntl6` $\rightarrow$ 调制解调器控制 6（定位 / GPS）
* `/dev/smdcntl7` $\rightarrow$ 调制解调器控制 7（诊断 / 测试）

### 5.2 原子唤醒锁协议

每个传入/传出 QMUX 帧触发：
1. 向 `/sys/power/wake_lock` 写入 `write(fd, "qmuxd_port_wl_0", 15)`。
2. 在 `/dev/smdcntl%d` 上完成读 / 写。
3. 向 `/sys/power/wake_unlock` 写入 `write(fd, "qmuxd_port_wl_0", 15)`。

这保证了控制数据包在途时 Hexagon A2 DMA 总线时钟不会被门控。

---

## 6. `netmgrd` 与 BAM-DMUX 接口管理

### 6.1 `librmnetctl` Netlink 控制

`netmgrd` 通过 Netlink 命令配置内核 `rmnet` 驱动：
* `rmnet_set_logical_ep_config(mux_id, "rmnet0")` $\rightarrow$ 将 QMI WDS 呼叫 ID 映射到虚拟网络设备。
* `rmnet_set_link_ingress_data_format(flags)` $\rightarrow$ 配置 Raw-IP 成帧（无以太网 MAC 头部）。
* `rmnet_set_link_egress_data_format(flags)` $\rightarrow$ 在单 APN 模式下禁用 MAP 头部多路复用。

### 6.2 BAM-DMUX 通道状态

`netmgr_kif_cb` 的反编译确认 `netmgrd` 将 BAM-DMUX 通道 `ch00`–`ch07` 视为**持久静态 DMA 管道**。它不在睡眠时执行活动打开/关闭周期。

---

## 7. OpenWrt 实现蓝图

要在不使用专有二进制 blob 的情况下完全匹配原厂 Android 行为：

```
+-------------------------------------------------------------------------------+
|                       OpenWrt Exact Replication Blueprint                     |
|                                                                               |
|  1. CLOCK DRIFT:                                                              |
|     Apply patch FUN_c03987e0 in modem.b16 -> disables 900s DRX timer          |
|     (OR run a 50-line C daemon sending QMI 0x0020 at boot)                    |
|                                                                               |
|  2. BAM DMA AUTOSUSPEND:                                                      |
|     Apply 808-bam-dmux-stats.patch -> pm_runtime_resume_and_get() on open     |
|                                                                               |
|  3. EFS2 STORAGE:                                                             |
|     Start rmtfs with '-P -s' targeting /dev/disk/by-partlabel/modemst1/2      |
|                                                                               |
|  4. GPIO PIN LATCH:                                                           |
|     DTS gpio-hog: GPIO 119 = HIGH, GPIO 114 = LOW, GPIO 71 = HIGH             |
+-------------------------------------------------------------------------------+
```

---

*报告直接由对原厂 MSM8916 Android 4.4.4 二进制的 Ghidra 无头逆向工程生成。*  
*参考输出日志：`41_ghidra_time_daemon_RE.txt`、`42_ghidra_rmt_storage_RE.txt`、`43_ghidra_qmuxd_RE.txt`、`44_ghidra_libqmiservices_RE.txt`、`45_ghidra_libtime_genoff_RE.txt`、`51_ghidra_netmgrd_RE.txt`、`52_ghidra_thermal_engine_RE.txt`。*
