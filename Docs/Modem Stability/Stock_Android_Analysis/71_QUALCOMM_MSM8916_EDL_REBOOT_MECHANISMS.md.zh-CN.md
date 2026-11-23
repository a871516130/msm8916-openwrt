# Qualcomm MSM8916 原厂引导加载程序（`aboot`）与硬件 EDL 进入指南
## 逆向工程 `aboot.mbn`（LittleKernel）与直接 IMEM 寄存器控制

**目标 SoC：** Qualcomm MSM8916 / Snapdragon 410  
**分析的引导加载程序：** `aboot.mbn`（从 `/dev/block/bootdevice/by-name/aboot` 提取的 1 MB ELF）  
**基地址：** `0x8f600000`（111,900 行反汇编）  
**硬件 IMEM 基址：** `0x08600000`  
**重启原因寄存器：** `0x0860065c`（32 位字）  
**日期：** 2026-09-02  

---

## 1. 为何标准 `adb reboot edl` 在原厂 Android 上失败

对原厂 Android 4.4.4 用户空间（`/system/bin/reboot` 和 Bionic `libc`）以及 `aboot.mbn` 的逆向工程揭示了确切的失败机制：

1. **Android 4.4.4 Libc 限制：**
   在 Android KitKat（4.4.4）中，`/system/bin/reboot` 只识别 `"recovery"` 和 `"bootloader"`。
   当传入 `"edl"` 或 `"dload"` 时，Android `libc` 忽略未知字符串并将 `0`（`ANDROID_RB_RESTART`）传给内核。内核写入 `0x77665500`（正常重启），导致加密狗只是重新启动回 Android。
2. **`aboot` 魔数 cookie 验证：**
   对 `aboot.mbn` 在 `0x8f61e8a4` – `0x8f61e8d4` 周围的反汇编显示，引导加载程序直接检查 **`0x0860065c`**（IMEM 重启原因）处的 32 位寄存器：
   * `0x77665500` -> **正常 Android 启动**
   * `0x77665501` -> **DLOAD / EDL 紧急下载模式（9008）**
   * `0x77665502` -> **Fastboot 引导加载程序模式**
   * `0x77665503` -> **恢复模式**

---

## 2. 直接硬件方法（保证有效）

由于我们在原厂 Android 系统上拥有 root 访问权限和 `/system/xbin/devmem`，我们可以直接将魔数 cookie 写入硬件 IMEM 寄存器。

---

### 方法 A：直接 IMEM 魔数写入（软件 EDL）
在 root `adb shell` 内执行：

```bash
# 1. Write the EDL magic cookie (0x77665501) directly to physical IMEM
devmem 0x0860065c 32 0x77665501

# 2. Trigger immediate hardware reset
echo b > /proc/sysrq-trigger
```
* **结果：** 系统立即复位。`aboot` / PBL 在 `0x0860065c` 读取到 `0x77665501` 并停驻于 **Qualcomm HS-USB QDLoader 9008（EDL 模式）**。

---

### 方法 B：Fastboot 模式的直接 IMEM 魔数写入
如果你想进入 Fastboot 而非 EDL：

```bash
# 1. Write Fastboot cookie (0x77665502) to physical IMEM
devmem 0x0860065c 32 0x77665502

# 2. Trigger immediate hardware reset
echo b > /proc/sysrq-trigger
```
* **结果：** 重新启动进入 Qualcomm Fastboot 模式（`fastboot devices`）。

---

### 方法 C：物理复位键 / 测试点接地（硬件 EDL）
1. 从计算机上拔下 4G USB 加密狗。
2. 按住 PCB 上的小型物理复位按钮（连接到 GPIO 37 / `key_freset`），或将 EDL 测试点短接（D+ 到 GND）。
3. 在按住按钮的同时，将加密狗插入 USB 端口。
4. 3 秒后释放按钮。
* **结果：** PBL 检测到硬件按键序列并直接枚举为 `05c6:9008`。

---

## 3. MSM8916 上 IMEM 魔数 cookie 摘要

| 目标启动模式 | IMEM 物理地址 | 魔数值（十六进制） | 命令 |
|:---|:---|:---|:---|
| **EDL（9008）** | `0x0860065c` | `0x77665501` | `devmem 0x0860065c 32 0x77665501 && echo b > /proc/sysrq-trigger` |
| **Fastboot** | `0x0860065c` | `0x77665502` | `devmem 0x0860065c 32 0x77665502 && echo b > /proc/sysrq-trigger` |
| **恢复** | `0x0860065c` | `0x77665503` | `devmem 0x0860065c 32 0x77665503 && echo b > /proc/sysrq-trigger` |
| **正常** | `0x0860065c` | `0x77665500` | 标准 `reboot` |

---
*报告记录于 Docs/Modem Stability/Stock_Android_Analysis/71_QUALCOMM_MSM8916_EDL_REBOOT_MECHANISMS.md*
