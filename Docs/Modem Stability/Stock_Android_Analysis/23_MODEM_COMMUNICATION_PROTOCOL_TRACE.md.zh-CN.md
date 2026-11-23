# Qualcomm MSM8916 调制解调器通信协议与系统调用跟踪报告

**目标板卡：** 通用 HMU05（Qualcomm MSM8916）  
**内核：** Linux 3.10.28（原厂 Android 4.4.4）  
**使用工具：** `strace`、`lsof`、`netstat`、`/proc/PID/fd/`  
**捕获位置：** `Docs/Modem Stability/Stock_Android_Analysis/`  

---

## 1. 执行摘要

通过对物理硬件进行实时内核插桩和动态系统调用跟踪，我们捕获了主机应用处理器与 Qualcomm Hexagon QDSP6 基带之间精确的字节级协议事务。

---

## 2. 进程描述符与 IPC 拓扑

| 进程 | PID | 目标套接字 / 节点 | 用途 |
| :--- | :--- | :--- | :--- |
| **`time_daemon`** | 242 | 套接字 `[8413]`、`[8414]`、`[8416]`、`[8430]`、`[8431]`<br>`/dev/diag`（FD 13） | 通过 IPC Router 连接到 QMI 服务 22（ATS 时间）；通过 `poll()` 监听基站 NITZ 指示。 |
| **`qmuxd`** | 232 | `/dev/smdcntl0` 至 `/dev/smdcntl7`（FD 15–22）<br>`/sys/power/wake_lock`（FD 8） | 通过共享内存 SMD 通道将原始 QMI 事务多路复用至 Hexagon DSP。 |
| **`netmgrd`** | 293 | 套接字 `[6861]`、`[6862]`、`[6863]`、`[9018]`<br>`/dev/diag`（FD 3） | 与 QMI WDS（服务 1）协调并配置 `rmnet0` 数据包成帧。 |
| **`rmt_storage`**| 246 | `/dev/uio0`（FD 5 - 共享内存）<br>`/dev/block/mmcblk0p13`（modemst1）<br>`/dev/block/mmcblk0p14`（modemst2）<br>`/dev/block/mmcblk0p20`（fsg） | 通过共享内存 DMA 为基带提供 EFS2 非易失文件系统请求服务。 |

---

## 3. 字节级 QMI 数据包捕获分析

从 `qmuxd` 读取 SMD 通道 `/dev/smdcntl0` 捕获：

```text
[pid 415] read(15, "\x01\x15\x00\x80\x03\x01\x04\xde\x02\x51\x00\x09\x00\x14\x06\x00\xc1\xf7\xa8\xff\xcc\x00", 5086) = 22
```

### 数据包字段分解：
* `\x01`：QMUX 数据包起始定界符。
* `\x15\x00`：长度 = 共 21 字节。
* `\x80`：控制标志（来自 Hexagon 基带的指示/响应）。
* `\x03`：**服务 ID `0x03` = QMI NAS（网络接入服务）**。
* `\x01`：客户端句柄 ID 1。
* `\x04`：SDU 头部控制标志。
* `\xde\x02`：事务 ID。
* `\x51\x00`：**消息 ID `0x0051` = `QMI_NAS_GET_SIG_INFO_RESP`**。
* `\x09\x00`：负载 TLV 长度（9 字节）。
* `\x14\x06\x00\xc1\xf7\xa8\xff\xcc\x00`：包含 RSSI、RSRP、RSRQ 信号强度的 TLV 负载。

---

## 4. 唤醒锁同步生命周期

每个 QMI 事务都遵循精确的原子唤醒锁序列：
1. `write(8, "qmuxd_port_wl_0", 15)` $\rightarrow$ 在读取前**获取内核唤醒锁**。
2. `read(15, buffer)` $\rightarrow$ 从 `/dev/smdcntl0` 读取 QMI 数据包。
3. `sendto(socket, buffer)` $\rightarrow$ 将负载转发至 RIL / 用户空间守护进程。
4. `write(10, "qmuxd_port_wl_0", 15)` $\rightarrow$ **释放内核唤醒锁**。

---

## 5. `time_daemon` 系统调用架构

* **无轮询**：`time_daemon` 在内核 `poll()` 循环中等待文件描述符 14、15、16（`socket:[8416]`、`socket:[8430]`）。
* **零忙等开销**：它消耗 **0% CPU**，且不发出周期性 `genoff_set` 数据包。
* **指示驱动**：当基站广播系统信息块（SIB16）帧时，调制解调器通过 `tod_update_ind_cb()` 向 `time_daemon` 推送指示。
