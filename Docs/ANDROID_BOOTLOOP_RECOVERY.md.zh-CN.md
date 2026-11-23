# 从启动循环中恢复 MSM8916 Android 加密狗

**适用对象：** 无显示器的 MSM8916（骁龙 410）USB 加密狗 / MiFi，运行原厂 Android（4.4/5.x）—— 包括 **MIFID / MF800B 级**设备。没有显示屏，通常也没有串口控制台；USB 是唯一通道。

**本指南覆盖内容**

1. 抓住一个循环启动的设备足够长时间来命令它。
2. 进入 fastboot。
3. 当 fastboot 无法写入时进入 **EDL（9008）**。
4. 从转储恢复分区，并验证它。
5. 为什么**锁定的引导加载程序不会阻止 OpenWrt 刷写**。
6. 如果 OpenWrt 本身循环启动，如何**回到 EDL**。

---

## 0. 了解 USB ID

| USB ID | 模式 | 含义 |
| :--- | :--- | :--- |
| `05c6:9008` | **EDL / PBL** | 紧急下载（Emergency Download）。Firehose 写入原始分区。**Android 解锁状态在此不适用。** |
| `05c6:9006` | DLOAD | SBL1 大容量存储 / 转储模式。 |
| `05c6:9091` | Android diag | 内核已启动：adb + diag。在循环启动中通常是*唯一*的窗口。 |
| `05c6:9024` | Android | 正常 Android 复合设备（adb / MTP）。 |
| `18d1:d00d` | **Fastboot** | ABOOT fastboot（某些设备报告 `05c6:9025`）。 |

在它循环时观察设备：

~~~sh
watch -n0.5 'lsusb | grep -E "05c6|18d1"'
~~~

- 循环 `9091` → 消失 → `9091`：一个到达内核的循环启动。转到 §1。
- 从不出现，或只有短暂的 `9008`：直接走硬件 EDL（§3.3）。

---

## 1. 在循环启动中抓住 ADB

即使是循环启动的 Android，通常也会把 adbd 带起来几秒钟。抓住它：

~~~sh
adb devices -l
# 10d200c3   device   usb:1-1 product:MIFID model:MIFID device:MIFID
~~~

如果 `adb shell` 失败并显示 `exec '/system/bin/sh' failed: Permission denied`，那是启动中途的正常现象 —— shell 还没准备好。**你不需要 shell** 来重启；adb 守护进程自己处理 `reboot`：

~~~sh
adb -s <serial> reboot bootloader     # -> fastboot
adb -s <serial> reboot edl            # -> EDL (9008), if the kernel supports it
~~~

> 如果设备是 `unauthorized`，主机密钥未被接受。在 `userdebug` / `test-keys` 构建上通常已经授权。如果未授权，你需要物理访问以接受提示，或者走硬件 EDL。

---

## 2. Fastboot

~~~sh
fastboot devices
fastboot -s <serial> oem device-info
~~~

锁定原厂设备上的典型输出：

~~~text
(bootloader)  Device tampered: false
(bootloader)  Device unlocked: false
~~~

- **已解锁** → fastboot 是你的恢复路径：`fastboot flash boot …`、`fastboot flash system …`，然后 `fastboot reboot`。
- **已锁定** → `fastboot flash` 失败（`FAILED (remote: 'flash write failure')` 或 `not allowed in locked state`）。改用 EDL。

最小 ABOOT 只应答少数变量。`getvar all` 可能为空；逐个查询（`getvar product`、`getvar serialno`、`getvar partition-size:system`）。`fastboot fetch` 通常不支持，所以你无法从 fastboot 转储分区。

---

## 3. EDL（9008）

### 3.1 从 Android（首选）

~~~sh
adb -s <serial> reboot edl
~~~

这适用于原厂内核具有 IMEM/TCSR EDL 路径时（MIFID 设备有）。主机随后看到 `05c6:9008`。

### 3.2 从 fastboot

~~~sh
fastboot -s <serial> oem edl
~~~

在最小 ABOOT 上通常 `FAILED (remote: 'unknown command')`。如果失败，设备留在 fastboot；没有损失。

### 3.3 硬件（有保证的方式）

如果以上都不行 —— 或设备从不枚举 —— 你必须电气强制 EDL。在 MSM8916 上通常是以下之一：

- 插入/通电时把 **EDL 测试点**短接到地；
- 按住 **EDL / 恢复按键**（如果有）；
- 维修手册使用的 **D+ / 测试点**技巧。

**在刷写任何内容之前先识别测试点。** 这是唯一不依赖软件启动的进入方式。

---

## 4. 用 `edl.py` 恢复分区

你需要一个用于 MSM8916 的 **firehose loader**（例如 `prog_emmc_firehose_8916_*.mbn`）。错误的 loader 会让 Sahara 握手失败；它**不会**刷写任何东西。

~~~sh
# 1. 握手并读取分区表（只读）
edl.py printgpt --loader=prog_emmc_firehose_8916_xxx.mbn

# 2. 确认分区与镜像大小匹配
#    system: Offset 0x1618c000, Length 0x32000000   == 838,860,800 bytes

# 3. 写入原始分区镜像
edl.py w system system.bin --loader=prog_emmc_firehose_8916_xxx.mbn

# 4. 验证：回读头部和尾部，比较 md5
edl.py rs 724064 2048 /tmp/rb_head.bin --loader=prog_emmc_firehose_8916_xxx.mbn
edl.py rs $((724064+0x190000-2048)) 2048 /tmp/rb_tail.bin --loader=prog_emmc_firehose_8916_xxx.mbn
dd if=system.bin bs=512 count=2048 status=none | md5sum
md5sum /tmp/rb_head.bin

# 5. 复位退出 EDL 并启动
edl.py reset --loader=prog_emmc_firehose_8916_xxx.mbn --resetmode=reset
~~~

> loader 报告的*稀疏*负载大小，而非展开后的镜像大小；`100.0%` 和最后的“Wrote … to sector N”是真正的成功信号。始终用回读验证：线缆松动会产生 `flash write failure` / 短写入，在日志中看起来仍然合理。

---

## 5. 实际示例 —— MIFID，2026-10-21

一台原厂 MIFID 设备循环启动了。它以 `05c6:9091` 枚举，adb 存活。

~~~text
adb devices -l            -> 10d200c3  device  product:MIFID model:MIFID
adb reboot bootloader     -> 18d1:d00d (fastboot)
fastboot oem device-info  -> Device unlocked: false
fastboot flash system …   -> FAILED (remote: 'flash write failure')
adb reboot edl            -> 05c6:9008
edl.py printgpt           -> system: Offset 0x1618c000, Length 0x32000000
edl.py w system …         -> 100.0%, "Wrote … to sector 724064"
edl.py rs head/tail       -> md5 match with the image
edl.py reset              -> boots, adb stable, bootloop gone
~~~

system 镜像是正好 `0x32000000` 字节的原始 ext4 转储。

---

## 6. 引导加载程序已锁定 —— 我们如何刷写 OpenWrt？

**使用 EDL。锁不适用。**

锁由 **ABOOT**（Android 引导加载程序）在收到 `fastboot flash` 命令时强制执行。EDL 是更低的层次：MSM8916 的 **PBL / Sahara / firehose** 路径在 ABOOT 之下运行，并写入原始 eMMC 扇区。那里不检查 `is_unlocked=false` 标志。

这正是本项目已经刷写 OpenWrt 的方式：`msm89xx/image/flash.sh --mode migrate` **完全通过 EDL 完成** —— 重新分区（GPT）、引导加载程序（`aboot`、`hyp`、`rpm`、`sbl1`、`tz`）、`boot` 和 `rootfs`。因此锁定的原厂引导加载程序不是初始安装的障碍。

注意事项：

- **firehose loader 必须匹配 SoC / 安全启动状态。** 握手失败的 loader 根本不会启动；它不能半写。
- 首次 `migrate` 前保留**完整转储**。该脚本备份七个无线/校准分区（`fsc fsg modem modemst1 modemst2 persist sec`）；也要保留 `aboot`、`sbl1`、`tz`、`hyp`、`rpm`、`boot`、`system`。
- 一旦 OpenWrt 布局就位，使用 `flash.sh --mode update`（仅 `boot` + `rootfs`）—— 它不碰引导加载程序和无线分区。

---

## 7. OpenWrt 循环启动 —— 我们如何回到 EDL？

有四条路径，按可靠性递减：

### 7.1 硬件 EDL —— 唯一有保证的

通电时短接 EDL 测试点（或按住 EDL 按钮）。即使内核、DTB 或用户空间完全损坏也有效。**刷写 OpenWrt 之前先识别它们。**

### 7.2 Fastboot —— 仅当引导加载程序已解锁且可达

如果 `aboot` 已解锁，你根本不需要 EDL：用 `fastboot flash` 重新刷写已知良好的 `boot`（和 `rootfs`）。为此保持引导加载程序解锁，并且**除非你有完整转储和硬件 EDL 回退，否则绝不要刷写 `aboot` / `sbl1`。**

在锁定的 ABOOT 上，fastboot 不会写入；最小 ABOOT 通常也不实现 `oem edl`。所以在锁定的设备上 fastboot 不是恢复路径。

### 7.3 从启动中的 OpenWrt 执行 `reboot-edl`

本项目发布 `reboot-edl`（补丁 813 + `packages/reboot-edl`）。如果 OpenWrt 到达用户空间，它会写入 IMEM/TCSR cookie 并热复位进入 EDL。这是最容易的路径 —— 但它要求 OpenWrt 能启动。

### 7.4 早期启动 USB gadget（“模拟 Android”）

Android 在循环启动中存活足够长时间以暴露 adb/diag，这正是让我们运行 `adb reboot edl` 的原因。OpenWrt 也可以：**failsafe** preinit 钩子在正常 init 之前，于 `192.168.10.1` 带起一个 USB gadget（CDC-NCM + ACM）和一个最小 shell。你可以向那个窗口添加 `reboot edl` 动作。

**但这只有在内核和 DTB 能启动时才有效。** 最常见的 OpenWrt 循环启动是坏的 `boot` 镜像 / DTB，此时 preinit 从不运行。所以这是**便利措施**，不是保证 —— 不要把它当作你唯一的回退路径。

> 本项目使用的 OpenWrt GPT **没有 `recovery` 分区**（`aboot`、`boot`、`rootfs`、`rootfs_data`），所以此布局中不存在“失败时启动 recovery 分区”的回退。

---

## 8. 恢复契约 —— 刷写前这样做

- [ ] **转储一切**你即将覆盖的内容（`aboot sbl1 tz hyp rpm boot system` + 七个无线分区）并保存在设备之外。
- [ ] 在原厂 Android 上**证明 EDL 进入有效**：`adb reboot edl` → `05c6:9008` → `edl.py printgpt` → `edl.py reset`。
- [ ] **识别硬件 EDL 测试点**（或确认按键组合）。
- [ ] 把匹配的 **firehose loader** 放在转储旁边。
- [ ] 首次成功启动 OpenWrt 后，测试 `reboot-edl` 并记录结果。
- [ ] 后续变更优先使用 `flash.sh --mode update`；`migrate` 是一次性且破坏性的。

如果以上全部为真，循环启动可在几分钟内恢复。如果唯一进入方式是“祈祷 OpenWrt 能启动”，那你还没有恢复路径。

---

## 附录 —— MIFID / MF800B 级发现（2026-10-21）

取自一台原厂 MIFID 设备（`ro.product.device=MIFID`，Android 4.4.4，`eng.edwin.20240806`）：

- 该板卡是 **MF800B 级**：补丁 `807` 的 LED/电池/按键 GPIO 完全匹配（`wifistatus` 73、`4g_2` 84、`4g_1` 85、`4g_type` 72、`batl2` 0、`bat1` 1、`key_freset` 102）。
- **`807` 中缺少 SIM 块。** 从 `/sys/kernel/debug/gpio`（TLMM 基址 902 → 引脚 = 编号 − 902）：

  | 功能 | Android 节点 | TLMM 引脚 | 状态 |
  | :--- | :--- | ---: | :--- |
  | 物理 SIM 使能 | `esim1_en` | **119** | **输出 HIGH** |
  | SIM 2 使能 | `esim2_en` | **112** | 输出 LOW |
  | SIM 3 使能 | `esim3_en` | 12 | 输出 LOW |
  | SIM 热插拔 | `sim_hotplug` | **114** | 输出 LOW |

  （此处 `esim2_en` 是 112；HMU05 用 14。`esim1_en` / `sim_hotplug` 与 HMU05 的 119/114 匹配。）

- 调制解调器：`gsm.version.baseband = HM02_MODEM_V1.2`；64 MB 的 `modem` 分区是 FAT16，包含构建 `MPSS.DPM.2.0.2.c1-00178-M8936FAAAANUZM-1_20161104_023832`（**V2.0**）。它包含**零**个 `HiMI_OK` 字符串 ⇒ **不需要** `himi-ok` 守卫，且该板卡属于正常（非 `a2-pin`）路径，与 UFI001B/MF800B 一样。
