> 📄 本文件是 [ANDROID_BOOTLOOP_RECOVERY.md](ANDROID_BOOTLOOP_RECOVERY.md) 的英文原文中文译本，内容以英文版为准。

# 从 Bootloop 中恢复 MSM8916 Android 加密狗

**适用范围：** 无屏幕的 MSM8916（Snapdragon 410）USB 加密狗 / MiFi，运行原厂
Android（4.4/5.x）——包括 **MIFID / MF800B 系列**设备。这些设备没有
显示屏，通常也没有串口控制台；USB 是唯一的通道。

**本指南涵盖的内容**

1. 在 bootloop 设备上抓住足够长的时间窗口向其发送命令。
2. 进入 fastboot。
3. 当 fastboot 无法写入时进入 **EDL（9008）**。
4. 从 dump 恢复某个分区，并进行验证。
5. 为什么**已锁定的 bootloader 并不能阻止 OpenWrt 刷写**。
6. 当 **OpenWrt 自身出现 bootloop 时如何回到 EDL**。

---

## 0. 了解 USB ID

| USB ID | 模式 | 含义 |
| :--- | :--- | :--- |
| `05c6:9008` | **EDL / PBL** | 紧急下载。Firehose 直接写入原始分区。**Android 解锁状态在此不适用。** |
| `05c6:9006` | DLOAD | SBL1 大容量存储 / dump 模式。 |
| `05c6:9091` | Android diag | 内核已启动：adb + diag。通常是 bootloop 中*唯一*的窗口。 |
| `05c6:9024` | Android | 正常 Android 复合设备（adb / MTP）。 |
| `18d1:d00d` | **Fastboot** | ABOOT fastboot（部分设备上报 `05c6:9025`）。 |

在设备循环时观察它：

~~~sh
watch -n0.5 'lsusb | grep -E "05c6|18d1"'
~~~

- 循环出现 `9091` → 消失 → `9091`：说明是能到达内核的 bootloop。转到 §1。
- 从不出现，或只短暂出现 `9008`：直接走硬件 EDL（§3.3）。

---

## 1. 在 bootloop 中捕获 ADB

即使是处于 bootloop 的 Android，通常也会把 adbd 启动几秒钟。抓住它：

~~~sh
adb devices -l
# 10d200c3   device   usb:1-1 product:MIFID model:MIFID device:MIFID
~~~

如果 `adb shell` 失败并报 `exec '/system/bin/sh' failed: Permission denied`，
这是启动中途的正常现象——shell 还没准备好。**你不需要 shell**
也能重启；adb 守护进程自己就能处理 `reboot`：

~~~sh
adb -s <serial> reboot bootloader     # -> fastboot
adb -s <serial> reboot edl            # -> EDL (9008)，前提是内核支持
~~~

> 如果设备状态是 `unauthorized`，说明主机密钥未被接受。在
> `userdebug` / `test-keys` 构建上通常已经授权。如果没有，
> 你需要物理接触设备以接受提示，或者改用硬件 EDL。

---

## 2. Fastboot

~~~sh
fastboot devices
fastboot -s <serial> oem device-info
~~~

在锁定的原厂设备上的典型输出：

~~~text
(bootloader)  Device tampered: false
(bootloader)  Device unlocked: false
~~~

- **已解锁** → fastboot 就是你的恢复路径：`fastboot flash boot …`、
  `fastboot flash system …`，然后 `fastboot reboot`。
- **已锁定** → `fastboot flash` 会失败（`FAILED (remote: 'flash write failure')`
  或 `not allowed in locked state`）。改用 EDL。

精简版 ABOOT 只响应少数几个变量。`getvar all` 可能为空；请逐个查询
（`getvar product`、`getvar serialno`、`getvar partition-size:system`）。
`fastboot fetch` 通常不受支持，因此你无法从 fastboot 导出分区。

---

## 3. EDL（9008）

### 3.1 从 Android 进入（首选）

~~~sh
adb -s <serial> reboot edl
~~~

当原厂内核带有 IMEM/TCSR EDL 路径时此方法有效（MIFID 设备就具备）。
随后主机能看到 `05c6:9008`。

### 3.2 从 fastboot 进入

~~~sh
fastboot -s <serial> oem edl
~~~

在精简版 ABOOT 上通常返回 `FAILED (remote: 'unknown command')`。如果失败，
设备仍停留在 fastboot，不会丢失任何东西。

### 3.3 硬件方式（保证有效的方法）

如果上述两种方式都不行——或者设备根本不枚举——你就必须
用电的方式强制进入 EDL。在 MSM8916 上通常是以下方法之一：

- 在插入 USB / 开机的同时将 **EDL 测试点**对地短接；
- 按住 **EDL / recovery 按键**（如果设备有）；
- 维修手册中使用的 **D+ / 测试点**技巧。

**在刷写任何内容之前先找到测试点。** 这是唯一不依赖软件启动的
进入方式。

---

## 4. 用 `edl.py` 恢复分区

你需要一个适用于 MSM8916 的 **firehose loader**（例如
`prog_emmc_firehose_8916_*.mbn`）。错误的 loader 会导致 Sahara 握手失败；
它**不会**刷入任何内容。

~~~sh
# 1. 握手并读取分区表（只读）
edl.py printgpt --loader=prog_emmc_firehose_8916_xxx.mbn

# 2. 确认分区大小与镜像大小匹配
#    system: Offset 0x1618c000, Length 0x32000000   == 838,860,800 bytes

# 3. 写入原始分区镜像
edl.py w system system.bin --loader=prog_emmc_firehose_8916_xxx.mbn

# 4. 验证：读回头部和尾部，比较 md5
edl.py rs 724064 2048 /tmp/rb_head.bin --loader=prog_emmc_firehose_8916_xxx.mbn
edl.py rs $((724064+0x190000-2048)) 2048 /tmp/rb_tail.bin --loader=prog_emmc_firehose_8916_xxx.mbn
dd if=system.bin bs=512 count=2048 status=none | md5sum
md5sum /tmp/rb_head.bin

# 5. 退出 EDL 并启动
edl.py reset --loader=prog_emmc_firehose_8916_xxx.mbn --resetmode=reset
~~~

> loader 报告的是 *sparse* 负载大小，而不是展开后的镜像大小；
> `100.0%` 以及最后的 "Wrote … to sector N" 才是真正的成功标志。
> 始终用读回进行验证：松动的线缆会产生
> `flash write failure` 或短写，而这些在日志中看起来仍然似乎合理。

---

## 5. 实例演练 —— MIFID，2026-10-21

一台原厂 MIFID 设备出现 bootloop。它以 `05c6:9091` 枚举，且 adb 存活。

~~~text
adb devices -l            -> 10d200c3  device  product:MIFID model:MIFID
adb reboot bootloader     -> 18d1:d00d (fastboot)
fastboot oem device-info  -> Device unlocked: false
fastboot flash system …   -> FAILED (remote: 'flash write failure')
adb reboot edl            -> 05c6:9008
edl.py printgpt           -> system: Offset 0x1618c000, Length 0x32000000
edl.py w system …         -> 100.0%, "Wrote … to sector 724064"
edl.py rs head/tail       -> md5 与镜像一致
edl.py reset              -> 启动，adb 稳定，bootloop 消失
~~~

该 system 镜像是一个恰好 `0x32000000` 字节的 raw ext4 dump。

---

## 6. bootloader 已锁定 —— 我们如何刷入 OpenWrt？

**使用 EDL。锁定状态在这里不适用。**

锁定是由 **ABOOT**（Android bootloader）在收到 `fastboot flash` 命令时强制执行的。
EDL 是更低的一层：MSM8916 的 **PBL / Sahara / firehose**
路径运行在 ABOOT 之下，直接写入原始 eMMC 扇区。
`is_unlocked=false` 标志在那里不会被查询。

这正是本项目已经用来刷写 OpenWrt 的方式：
`msm89xx/image/flash.sh --mode migrate` **完全通过 EDL 完成一切**——
重新分区（GPT）、bootloader（`aboot`、`hyp`、`rpm`、`sbl1`、`tz`）、
`boot` 和 `rootfs`。因此，锁定的原厂 bootloader 并不是初次安装的障碍。

注意事项：

- **firehose loader 必须与 SoC / 安全启动状态匹配**。握手失败的 loader
  根本不会启动；它不可能写到一半。
- 在第一次 `migrate` 之前保留一份**完整 dump**。脚本会备份七个
  射频/校准分区（`fsc fsg modem modemst1 modemst2 persist sec`）；
  另外请保留 `aboot`、`sbl1`、`tz`、`hyp`、`rpm`、`boot`、`system`。
- 一旦 OpenWrt 布局就位，就使用 `flash.sh --mode update`
  （仅 `boot` + `rootfs`）——它不会动 bootloader 和射频
  分区。

---

## 7. OpenWrt 出现 bootloop —— 我们如何回到 EDL？

有四条路径，按可靠性从高到低排列：

### 7.1 硬件 EDL —— 唯一保证有效的方式

开机时短接 EDL 测试点（或按住 EDL 按键）。即使内核、DTB 或用户态
完全损坏，这也能奏效。**在刷写 OpenWrt 之前先找到这些
测试点。**

### 7.2 Fastboot —— 仅当 bootloader 已解锁且可达时

如果 `aboot` 已解锁，你根本不需要 EDL：用 `fastboot flash`
重新刷入一个已知良好的 `boot`（以及 `rootfs`）。为此请保持
bootloader 解锁，并且**除非你有完整 dump 和硬件 EDL 兜底，
否则绝不要刷 `aboot` / `sbl1`。**

在锁定的 ABOOT 上，fastboot 不会写入；而且精简版 ABOOT 往往没有
实现 `oem edl`。所以在锁定设备上 fastboot 不是恢复路径。

### 7.3 从可启动的 OpenWrt 执行 `reboot-edl`

本项目提供了 `reboot-edl`（补丁 813 + `packages/reboot-edl`）。如果
OpenWrt 能到达用户态，它会写入 IMEM/TCSR cookie 并暖复位进入
EDL。这是最简单的路径——但需要 OpenWrt 能启动。

### 7.4 早期启动 USB gadget（"模拟 Android"）

Android 能在 bootloop 中存活足够长的时间以暴露 adb/diag，这正是我们能够
执行 `adb reboot edl` 的原因。OpenWrt 也能做到同样的事：**failsafe** preinit 钩子
会在正常 init 之前启动一个 USB gadget（CDC-NCM + ACM），地址为 `192.168.10.1`，
并提供一个极简 shell。你可以为这个窗口添加一个 `reboot edl` 动作。

**但这只有在内核和 DTB 能启动时才有效。** 最常见的 OpenWrt
bootloop 是损坏的 `boot` 镜像 / DTB，在这种情况下 preinit 根本不会运行。所以这只是
一种**便利**，而不是保证——不要把它当作唯一回去的方式。

> 本项目使用的 OpenWrt GPT **没有 `recovery` 分区**
> （`aboot`、`boot`、`rootfs`、`rootfs_data`），因此该布局下
> 不具备"失败时启动 recovery 分区"的兜底能力。

---

## 8. 恢复契约 —— 刷写之前请做到这些

- [ ] **导出所有你即将覆盖的内容**（`aboot sbl1 tz hyp rpm
      boot system` + 七个射频分区），并保存在设备之外。
- [ ] **在原厂 Android 上验证 EDL 进入方式有效**：`adb reboot edl` →
      `05c6:9008` → `edl.py printgpt` → `edl.py reset`。
- [ ] **找到硬件 EDL 测试点**（或确认按键组合）。
- [ ] 将匹配的 **firehose loader** 与 dump 放在一起保存。
- [ ] 在第一次成功启动 OpenWrt 之后，测试 `reboot-edl` 并记下
      结果。
- [ ] 以后的修改优先使用 `flash.sh --mode update`；`migrate` 是
      一次性且具破坏性的操作。

如果以上全部成立，bootloop 可以在几分钟内恢复。如果唯一的进入方式是
"祈祷 OpenWrt 能启动"，那你还没有恢复路径。

---

## 附录 —— MIFID / MF800B 系列设备的发现（2026-10-21）

捕获自一台原厂 MIFID 设备（`ro.product.device=MIFID`，Android 4.4.4，
`eng.edwin.20240806`）：

- 该板卡属于 **MF800B 系列**：补丁 `807` 中的 LED/电池/按键 GPIO
  完全吻合（`wifistatus` 73、`4g_2` 84、`4g_1` 85、`4g_type` 72、`batl2` 0、
  `bat1` 1、`key_freset` 102）。
- **`807` 中缺少 SIM 部分**。来自
  `/sys/kernel/debug/gpio`（TLMM 基址 902 → 引脚 = 编号 − 902）：

  | 功能 | Android 节点 | TLMM 引脚 | 状态 |
  | :--- | :--- | ---: | :--- |
  | 物理 SIM 使能 | `esim1_en` | **119** | **输出高电平** |
  | SIM 2 使能 | `esim2_en` | **112** | 输出低电平 |
  | SIM 3 使能 | `esim3_en` | 12 | 输出低电平 |
  | SIM 热插拔 | `sim_hotplug` | **114** | 输出低电平 |

  （此处 `esim2_en` 为 112；HMU05 使用 14。`esim1_en` / `sim_hotplug`
  与 HMU05 的 119/114 一致。）

- Modem：`gsm.version.baseband = HM02_MODEM_V1.2`；64 MB 的 `modem`
  分区为 FAT16，包含构建版本
  `MPSS.DPM.2.0.2.c1-00178-M8936FAAAANUZM-1_20161104_023832`（**V2.0**）。
  其中**没有任何** `HiMI_OK` 字符串 ⇒ `himi-ok` 守卫**不需要**，
  且该板卡应走普通（非 `a2-pin`）路径，与
  UFI001B/MF800B 相同。
