# 原厂 Android 深度动态跟踪与调查报告

**目标板卡：** Qualcomm MSM8916（通用 HMU05 / UFI）  
**记录的连续运行时间：** **5 小时 28 分 59 秒（`19,739.07` 秒）**，**0% 丢包**且**0 调制解调器错误**。  
**执行工具：** `strace`、`inotifywait`、`lsof`、`dumpsys`、`tcpdump`、`cat /d/pinctrl/`  

---

## 1. 看门狗与保活跟踪

* **看门狗节点：** `/sys/devices/soc.0/b017000.qcom,wdt`
* **设备节点：** 此平台不存在 `/dev/watchdog` 字符设备。
* **内核机制：** 通过高优先级内核工作队列管理。
* **`healthd` 的 Strace：** `healthd` 监听 Android Binder（`/dev/binder`）和一个 `timerfd`。它不馈送外部硬件看门狗字符设备；硬件 pet/bark/bite 在 Linux 内核调度器层进行馈送。

---

## 2. `rild` 与 QCRIL 实时系统调用跟踪

跟踪 `rild`（PID 197，16 线程）显示：
```text
[pid  640] recvfrom(34, "\0\0\0\0\16\0\0\0... \1\0\0\0$\200\0\0\4\24\3\1\0\4\0\30\1\0\1", 43) = 43
[pid  381] write(20, "qcril", 5) = 5  (Acquires /sys/power/wake_lock "qcril")
[pid  555] recvfrom(28, "3\0\0\0\1\200\0\0\4\36\32\215\0\t\0\20\6\0d\0\0d\0\0", 48) = 48
[pid  381] write(20, "radio-interface", 15) = 15  (Acquires /sys/power/wake_lock "radio-interface")
```

### 关键发现：
* `rild` 在每个 QMI 事件上动态管理电源唤醒锁（`qcril`、`radio-interface`），防止 CPU 和 BAM DMA 路径在未处理的无线指示在途时进入深度睡眠。

---

## 3. 文件系统访问模式（`inotifywait`）

* 使用 `inotifywait` 监控 `/persist/` 和 `/data/misc/radio/`。
* 在稳态数据传输期间**零非请求文件访问**。
* 调制解调器基带**不会**周期性地在 `/persist/` 或 `/system/etc/` 中读写零散配置文件。所有非易失校准访问都直接经由 `/dev/uio0` 共享内存 DMA，通过 `rmt_storage` 通往**原始 eMMC 分区（`modemst1`、`modemst2`、`fsg`）**。

---

## 4. 面向 OpenWrt 移植的地面实况摘要

```
+---------------------------------------------------------------------------------------------------+
| COMPONENT         | GROUND-TRUTH PARAMETER                   | OPENWRT IMPLEMENTATION             |
+---------------------------------------------------------------------------------------------------+
| MPSS Mem Base     | 0x86800000, Size: 85 MiB (0x5500000)     | Set in DTS / reserved-memory       |
| Primary SIM GPIO  | GPIO 119 (esim1_en) = HIGH (255)         | Assert HIGH in DTS / firstboot     |
| SIM Detect GPIO   | GPIO 114 (sim_hotplug) = LOW (0)         | Assert LOW in DTS / firstboot      |
| 4G RF Power GPIO  | GPIO 71 (4g_1) = HIGH (1)                | Assert HIGH in DTS / firstboot     |
| DMA Transport     | Persistent BAM DMA (No 1s autosuspend)   | Patch 808 PM lock in kernel        |
| Time Sync         | QMI Service 22 (One-time boot sync + IND)| Baseband No-Sleep / Service 22     |
| NV Storage        | Read-Write rmt_storage to modemst1/st2   | rmtfs running -P -s without -r     |
+---------------------------------------------------------------------------------------------------+
```
