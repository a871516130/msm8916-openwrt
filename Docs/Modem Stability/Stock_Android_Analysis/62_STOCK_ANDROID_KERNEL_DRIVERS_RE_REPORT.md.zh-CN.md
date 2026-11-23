# Qualcomm MSM8916 原厂 Android 内核驱动逆向工程报告
## 对 `msm_smd`、`rpm_smd`、`msm_pil`、`bam_dmux`/`rmnet_bam` 与主线的深度分析

**目标平台：** Qualcomm MSM8916（Snapdragon 410）原厂 Android 4.4.4  
**内核基线：** Linux 3.10.28 SMP PREEMPT（ARMv7l，`gcc 4.7`）  
**提取符号：** 从实机 `/proc/kallsyms` 提取 102,850 个符号（设备 `c2b9103c`）  
**内核配置：** 从 `/proc/config.gz` 提取（3,558 个选项）  
**产物目录：** `Docs/Modem Stability/Stock_Android_Analysis/`  
**日期：** 2026-09-02  

---

## 1. 执行摘要与内核架构矩阵

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│                   QUALCOMM MSM8916 STOCK ANDROID KERNEL DRIVER ARCHITECTURE                      │
├──────────────────────────┬─────────────────────────────────────┬─────────────────────────────────┤
│ DRIVER SUBSYSTEM         │ STOCK ANDROID (Linux 3.10)          │ OPENWRT MAINLINE (Linux 6.12)   │
├──────────────────────────┼─────────────────────────────────────┼─────────────────────────────────┤
│ 1. Shared Memory IPC     │ drivers/soc/qcom/smd.c              │ drivers/rpmsg/qcom_smd.c        │
│    (msm_smd.c)           │ Legacy MSM SMD FIFO + SMSM voting   │ RPMSG SMD Bus Driver            │
├──────────────────────────┼─────────────────────────────────────┼─────────────────────────────────┤
│ 2. Resource Power Mgr    │ drivers/soc/qcom/rpm-smd.c          │ drivers/soc/qcom/smd-rpm.c      │
│    (rpm_smd.c)           │ SMD Service "rpm_requests"          │ MFD SMD-RPM Regulator & Clock   │
├──────────────────────────┼─────────────────────────────────────┼─────────────────────────────────┤
│ 3. Peripheral Image Ldr  │ drivers/soc/qcom/pil-q6v5-mss.c     │ drivers/remoteproc/qcom_q6v5_mss│
│    (msm_pil.c)           │ TrustZone SCM PIL + Proxy Voting    │ Remoteproc Q6V5 MSS Driver      │
├──────────────────────────┼─────────────────────────────────────┼─────────────────────────────────┤
│ 4. Network Data Engine   │ drivers/net/msm_rmnet_bam.c         │ drivers/net/wwan/qcom_bam_dmux.c│
│    (bam_dmux / rmnet)    │ BAM-DMUX DMA + RmNet Multi-Channel  │ BAM-DMUX WWAN Netdev Driver     │
│    [Note on qmi_wwan]    │ (qmi_wwan used only for USB dongles)│ (qmi_wwan for USB, bam_dmux SoC)│
└──────────────────────────┴─────────────────────────────────────┴─────────────────────────────────┘
```

---

## 2. 驱动 1：`msm_smd.c`（共享内存驱动）

### 2.1 内核配置与内存布局
* **配置：** `CONFIG_MSM_SMD=y`、`CONFIG_MSM_SMD_PKT=y`
* **共享内存区域（`smem`）：**
  * Hexagon 调制解调器 SMD FIFO 基址：通过 DT `qcom,smd-channels` 映射到物理 RAM。
  * 通道：带独立读/写指针的数据包和流 FIFO 环。

### 2.2 提取的符号分析
来自 `/proc/kallsyms`（共 481 个符号）：
* `smd_memcpy_to_fifo`（`0xc02ac6ac`）：将传出数据包复制到 SMD 环形缓冲区。
* `smd_memcpy_from_fifo`（`0xc02ac738`）：从 SMD 环形缓冲区读取传入数据包。
* `smd_stream_read_avail`（`0xc02aca70`）/ `smd_packet_write_avail`（`0xc02acaf8`）：通道容量检查器。
* `smd_enable_read_intr`（`0xc02acbe8`）/ `smd_disable_read_intr`（`0xc02acc0c`）：中断缓解。

### 2.3 SMD 状态转换机
```text
SMD_SS_CLOSED -> SMD_SS_OPENING -> SMD_SS_OPENED -> SMD_SS_FLUSHING -> SMD_SS_CLOSING -> SMD_SS_RESET
```
* 在 Android 中，应用处理器在共享内存中更新本地状态，并向 Hexagon DSP 发出共享内存状态机（SMSM）处理器间中断。
* 在主线 Linux（OpenWrt）中，这被干净地封装在 `drivers/rpmsg/qcom_smd.c` 中。

---

## 3. 驱动 2：`rpm_smd.c`（资源电源管理器 SMD）

### 3.1 内核配置与通信角色
* **配置：** `CONFIG_MSM_RPM_SMD=y`
* **角色：** 通过向 Cortex-M3 资源电源管理器（RPM）派发键值对（KVP）请求，管理时钟树、PM8916 PMIC 稳压器、总线频率和睡眠投票。

### 3.2 提取的符号分析（173 个符号）
* `msm_rpm_dev_probe`（`0xc02a5f04`）：探测 SMD 通道 `"rpm_requests"`。
* `msm_rpm_send_smd_buffer`（`0xc02a6c44`）：通过 SMD 传输原始 KVP 缓冲区。
* `msm_rpm_wait_for_ack`（`0xc02a72e0`）/ `msm_rpm_wait_for_ack_noirq`（`0xc02a728c`）：同步 ACK 等待器。
* `msm_rpm_enter_sleep`（`0xc02a7008`）/ `msm_rpm_exit_sleep`（`0xc02a6fe0`）：转换 RPM 睡眠状态集。

### 3.3 消息协议
* 消息以 32 位字成帧：
  * `服务类型`：`0x00716572`（`"req\0"`）
  * `消息 ID`：单调递增的序列 ID。
  * `设置类型`：`0` = 活动集（立即），`1` = 睡眠集（在掉电时应用）。
  * `资源类型`：4 字符代码（例如 `LDOA`、`SMPS`、`CLK1`）。

---

## 4. 驱动 3：`msm_pil.c` 与 `pil-q6v5-mss.c`（外设镜像加载器）

### 4.1 内核配置与安全模型
* **配置：** `CONFIG_MSM_PIL=y`、`CONFIG_MSM_PIL_SSR_GENERIC=y`、`CONFIG_MSM_PIL_MSS_QDSP6V5=y`
* **安全流程：**
  * 使用 Qualcomm 安全通道管理器（`scm_call`）通过 `pil_mem_setup_trusted`（`0xc02bed08`）和 `pil_init_image_trusted`（`0xc02bf33c`）进入 TrustZone（QSEE）。
  * 启动调制解调器启动验证器（`mba.mbn`），它分配 Hexagon 内存并验证 `modem.mdt` / `modem.b16`。

### 4.2 提取的符号分析（137 个符号）
* `pil_boot`（`0xc02be264`）：将基带镜像加载到保留内存的主编排器。
* `pil_auth_and_reset`（`0xc02bf28c`）：在 MBA 验证哈希表后触发硬件复位线。
* `pil_q6v5_init`（`0xc02c0138`）/ `pil_q6v5_reset`（`0xc02bff34`）/ `pil_q6v5_shutdown`（`0xc02bfec0`）：管理 QDSP6 核心时钟、稳压器和 AXI 总线停止。
* `pil_make_proxy_vote`（`0xc02bf92c`）/ `pil_remove_proxy_vote`（`0xc02bf0c0`）：在初始化期间保持电源轨开启。

---

## 5. 驱动 4：`msm_bam_dmux.c` / `msm_rmnet_bam.c` 与 `qmi_wwan.c` 对比

### 5.1 关于 `qmi_wwan` 与 `bam_dmux` 的澄清
* **`qmi_wwan.c`**：上游 Linux USB 主机驱动，用于 USB 连接的蜂窝调制解调器（使用 CDC WDM USB 端点）。
* **`msm_bam_dmux.c` / `msm_rmnet_bam.c`**：MSM8916 的片上 SoC 驱动。由于 Hexagon 调制解调器直接集成在硅片上，它通过**BAM DMA 引擎**在内部总线上连接，**而非通过 USB**。
* 因此原厂 Android 编译 `CONFIG_MSM_RMNET_BAM=y` 并使 `CONFIG_MSM_RMNET_USB` 保持禁用！

### 5.2 提取的符号分析（304 个符号）
* `bam_dmux_probe`（`0xc02a3010`）：绑定 BAM DMA 通道 `ch00`–`ch07`。
* `bam_dmux_smsm_cb`（`0xc02a1768`）：处理来自调制解调器的 SMSM 电源控制通知。
* `msm_bam_dmux_ul_power_vote`（`0xc02a399c`）/ `msm_bam_dmux_ul_power_unvote`（`0xc02a3a04`）：在传输期间为 BAM DMA 时钟投票。
* `bam_rmnet_probe`（`0xc03960ac`）、`rmnet_xmit`（`0xc03963d8`）：暴露虚拟 `rmnet0`..`rmnet7` 网络接口。

### 5.3 关键电源管理对比：原厂与主线
| 特性 | 原厂 Android 3.10（`msm_bam_dmux`） | 未打补丁主线 6.12（`qcom_bam_dmux`） | 带稳定性修复的 OpenWrt |
|:---|:---|:---|:---|
| **自动挂起延迟** | 禁用 / 不支持（`-1`） | `1000ms`（激进睡眠） | `autosuspend_delay_ms = -1`（sysfs） |
| **电源投票处理** | 接口 UP 时持续持有 | 静默 1s 后丢弃 | `open` 中 `pm_runtime_resume_and_get()` |
| **SMSM 握手** | 同步电源状态保留 | 唤醒时掉电超时 | 掉电已消除 |

---

## 6. 结论

1. **`msm_smd.c` 与 `rpm_smd.c`**：主线 Linux 6.12 在 `drivers/rpmsg/qcom_smd.c` 和 `drivers/soc/qcom/smd-rpm.c` 中干净地实现了这些。
2. **`msm_pil.c`**：主线 Linux 通过 `drivers/remoteproc/qcom_q6v5_mss.c` 实现此功能。
3. **`bam_dmux`**：主线 Linux `drivers/net/wwan/qcom_bam_dmux.c` 存在 1000ms 自动挂起 bug，我们的**二级修复**通过强制 `control=on` 和 `autosuspend_delay_ms=-1` 解决了此问题，完全复刻了原厂 Android 的稳定性！

---
*报告记录于 Docs/Modem Stability/Stock_Android_Analysis/62_STOCK_ANDROID_KERNEL_DRIVERS_RE_REPORT.md*
