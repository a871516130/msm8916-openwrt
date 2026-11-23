> **更正 2026-10-24（迟到）：** 下方的"总线投票热惰性 / 与 OS 无关"
> 结论被 `Docs/Thermal/rpmfindings.md` **部分推翻**：共享 RPM
> 固件在 OpenWrt 下将 BIMC/DDR（MEM_CLK）时钟保持在 MAX，而在
> Android 下约为 1/4 速率（在相同 CPU 频率下测得 4-7x DDR 带宽差异），因为
> 每个 OS 发送的投票不同（OpenWrt 的 cpu0 opp-peak-kBps 投票映射到 1066 MHz PLL 最大值；
> Android 的 msm_bus 从不将 MEM_CLK 投票上调）。先读 rpmfindings.md 了解 RPM/DDR 的故事。
>
> 更正 - 2026-10-24（在下文总线投票或 DDR 缩放部分操作前先读）

本文件中的总线投票声明已被 Docs/Thermal/HMU05_LIVE_BUS_VOTING_AB.md（更正后审计，2026-10-24）取代。

变更内容：
- OpenWrt **确实**投票总线带宽。实况 interconnect_summary 显示 mas_apss / slv_ebi_ch0 cpu0 峰值 = 8,528,000 kBps 随 CPU 频率跟踪。互连驱动（CONFIG_INTERCONNECT_QCOM_MSM8916=y，补丁 834）活跃并以正确的主线 RPM ID 发送 RPM 投票（slv_ebi_ch0 slv_rpm_id=0，bimc_snoc 99/130，snoc_bimc 101/132，pcnoc_snoc 29/45）。
- RPM 固件是**共享硅片**（非 OS 相关）。Android（msm_bus）和 OpenWrt（interconnect）向同一 RPM 发送相同的 RPM 带宽投票，RPM 对任一 OS 以相同方式缩放 DDR/BIMC 时钟。因此总线投票**不能**解释 OpenWrt-vs-Android 温度差距。若要说，Android 投票更多带宽，会让总线更热。
- 之前"bimc_ddr_clk_src = 800 MHz 意味着总线不缩放"的读取是 Linux 视图伪影：该时钟由 RPM 管理且**无频率表**，因此 Linux 无法观察 RPM 驱动的频率变化。

动作：**不要**移植 Android msm_bus ID（错误命名空间，不必要）。总线投票杠杆对于 OS 差距问题已**关闭**。改为运行**受控的等吞吐量** A/B（见更正后审计文档）。

---
# HMU05：确定性热发现与经验性地面真相

**日期：** 2026 年 10 月 8 日  
**硬件平台：** HMU05 4G LTE USB 棒（`hmu05,250605v0s`，Qualcomm MSM8916 / Snapdragon 410）  
**蜂窝运营商：** Jio 4G（印度，MCC/MNC `405/861`，Band 3/5/40）  
**测试协议：** 对运行以下系统的物理设备进行实况并排 SSH 检查：
1. **原厂 ZTE Android 4.4 / 内核 3.10.28** 于 `192.168.100.1`
2. **OpenWrt 24.10 / 内核 6.12.94** 于 `192.168.8.1`（100% 只读）

> **注（2026-10-10）—— A2 引脚现在在驱动中，而非用户空间。** 下面提到的
> 用户空间 `/usr/sbin/modem-a2-hold` 辅助工具已**移除**。A2
> 引脚现由 `qcom_bam_dmux` 驱动在设备树设置 `qcom,a2-pin` 的板上保持
> （HMU05；补丁 848/849）；用
> `echo 0|1 > /sys/module/qcom_bam_dmux/parameters/a2_pin` 切换它。下文对
> `modem-a2-hold` 的引用描述的是更早的用户空间机制。

---

> ## ⚠ 更正（2026-10-09）—— 使用本文档前请阅读
>
> 下面两个头条声明被
> [HMU05_OPENWRT_ANDROID_THERMAL_ROOT_CAUSE.md](./HMU05_OPENWRT_ANDROID_THERMAL_ROOT_CAUSE.md)
> 中调和的证据**驳斥**：
>
> 1. **"Android 收起 A2；OpenWrt 将其钉住"（§1 表，§2.1，§3.2，§4 成因 1）——
>    已驳斥。** 实况 Android 数据（`android_idle.csv`）保持 `a2_out=30`、`a2_in=28`、
>    `a2_pwr=30` **恒定 —— 窗口内 0 次转换** ⇒ **Android 保持 A2 开**，
>    *与* OpenWrt 的 `modem-a2-hold` 引脚相同状态。该引脚因此是**对等，而非
>    偏差**，无法解释 OpenWrt−Android 差距。所声称的"+10–12 °C A2 偏移"
>    **不受支持**；测得的钉住−未钉住**空闲**差约 **+2.8 °C**。
> 2. **"将热跳闸降至 60/65 °C"（§4 及相关报告）—— 作为修复已驳斥。**
>    受控测试（跳闸 75→60 °C）给出 **0 °C 收益**，**rx 吞吐量 −37 %**，以及
>    永久空闲节流回归。
>
> **也被取代：** 下文描述的 CPU 轨电压差距（OpenWrt ~1.15 V vs Android
> 1.05 V）此后已**修复** —— Qualcomm **CPR** 已移植到主线（补丁 841–846）；
> 轨现运行于 **1.0625 V**，与 Android 一致。见
> [HMU05_CPU_RAIL_CPR_PORT.md](./HMU05_CPU_RAIL_CPR_PORT.md)。
>
> 下方的传感器表和负载/冷却曲线仍是有用的**原始观察**；*因果*归因
> （尤其是 A2 引脚和 60/75 °C 跳闸）则不然。
>
> **2026-10-24 —— GPU 限制在此处热惰性；真正的剩余成因是总线投票。**
> 两个 HMU05 构建都是**无显示、无 GPU 工作负载的调制解调器棒**。Adreno 306 在未使用时被时钟门控/关闭，因此 Android 的 200 MHz GPU 限制（其 `ss`/GPU 动作）**毫无改变** —— 空闲 GPU 在 310 MHz 或 200 MHz 都拉约 ~0 W。因此 GPU 限制与 OpenWrt↔Android 差距无关，且 OpenWrt（补丁 847）从未移植 GPU 冷却设备（仅 Wi‑Fi @65 °C + PMIC @90 °C）。在 CPR/CPU 轨修复（成因 #2，已完成）之后，负载相关 +12 °C 的**唯一剩余量化差异**是 **AP 互连 / DDR 带宽投票**：Android 的 AP 是 RPM 总线客户端（`MSM_BUS_SCALING`，约 107 个调用点，17 个 `/d/msm-bus-dbg` 客户端），在 LTE 负载下将 fabric/AXI/DDR 角缩小，而 OpenWrt 投票**无**总线带宽并让 fabric 处于其默认更高功率状态（Android 差分轴 A17）。决定性测试是配对 A/B：在匹配的空闲 vs LTE 负载下比较 `bimc`/`snoc`/`pcnoc` 时钟速率和 CX/MX 角电压。

---

## 1. 执行摘要：三种运行状态

实况硬件测量决定性地解决了 HMU05 上 OpenWrt 与原厂 Android 的真实热行为。热差并非平坦、恒定的温度偏移，而完全取决于设备处于**三种运行状态中的哪一种**：

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                             THE THREE THERMAL REGIMES                            │
├──────────────────────┬─────────────────────────────┬─────────────────────────────┤
│ 1. Disconnected Idle │ 2. Connected Idle (No Data) │ 3. Active LTE Data Load     │
│  • BAM-DMUX: Suspended│  • BAM-DMUX: Pinned Active  │  • 10 MB HTTP LTE Download  │
│  • Modem: Sleep      │  • Modem: Pinned Awake      │  • Continuous Packet DMA    │
│  • OWrt: 48°C / 46°C │  • OWrt: 59°C / 57°C        │  • OWrt: 63°C / 61°C        │
│  • Andr: 49°C / 47°C │  • Andr: 49°C / 47°C        │  • Andr: 51°C / 49°C        │
│  • Delta: 0°C PARITY │  • Delta: +10°C OWrt Shift  │  • Delta: +12°C OWrt Shift  │
└──────────────────────┴─────────────────────────────┴─────────────────────────────┘
```

---

## 2. 经验数据矩阵

所有读数直接来自 Qualcomm TSENS 片上热传感器和 PM8916 PMIC 硬件寄存器：

### 2.1 完整实况传感器比较表

| 传感器节点 | 监测的硅域 | 状态 1：断开空闲 | 状态 2：连接空闲（LTE 上） | 状态 3：活动 LTE 负载（10 MB 下载） |
|---|---|---|:---:|:---:|
| **TSENS 0** | 调制解调器 Hexagon DSP / 基带 | **Android:** 49.0°C<br>**OpenWrt:** 48.0°C<br>*（差值: -1.0°C）* | **Android:** 49.0°C<br>**OpenWrt:** 59.0°C<br>*（差值: +10.0°C）* | **Android:** 51.0°C<br>**OpenWrt:** 63.0°C<br>*（差值: +12.0°C）* |
| **TSENS 1** | 相机接口 / 晶粒顶部 | **Android:** 45.0°C<br>**OpenWrt:** 45.0°C<br>*（差值: 0.0°C）* | **Android:** 45.0°C<br>**OpenWrt:** 56.0°C<br>*（差值: +11.0°C）* | **Android:** 47.0°C<br>**OpenWrt:** 60.0°C<br>*（差值: +13.0°C）* |
| **TSENS 2** | Adreno 306 GPU | **Android:** 44.0°C<br>**OpenWrt:** 43.0°C<br>*（差值: -1.0°C）* | **Android:** 44.0°C<br>**OpenWrt:** 55.0°C<br>*（差值: +11.0°C）* | **Android:** 46.0°C<br>**OpenWrt:** 60.0°C<br>*（差值: +14.0°C）* |
| **TSENS 3** | Cortex-A53 核 2 与 3 | **Android:** 45.0°C<br>**OpenWrt:** 44.0°C<br>*（差值: -1.0°C）* | **Android:** 45.0°C<br>**OpenWrt:** 55.0°C<br>*（差值: +10.0°C）* | **Android:** 47.0°C<br>**OpenWrt:** 59.0°C<br>*（差值: +12.0°C）* |
| **TSENS 4** | Cortex-A53 核 0 与 1 | **Android:** 47.0°C<br>**OpenWrt:** 46.0°C<br>*（差值: -1.0°C）* | **Android:** 47.0°C<br>**OpenWrt:** 57.0°C<br>*（差值: +10.0°C）* | **Android:** 49.0°C<br>**OpenWrt:** 61.0°C<br>*（差值: +12.0°C）* |
| **PMIC** | PM8916 晶粒热敏电阻 | **Android:** 39.2°C<br>**OpenWrt:** 37.4°C<br>*（差值: -1.8°C）* | **Android:** 39.2°C<br>**OpenWrt:** 54.8°C<br>*（差值: +15.6°C）* | **Android:** 39.5°C<br>**OpenWrt:** 59.9°C<br>*（差值: +20.4°C）* |
| **PA 热敏** | RF 功率放大器（VADC） | **Android:** 36.0°C<br>**OpenWrt:** *（未暴露）* | **Android:** 36.0°C<br>**OpenWrt:** *（未暴露）* | **Android:** 37.0°C<br>**OpenWrt:** *（未暴露）* |

---

## 3. 冷却动态：相同 10 MB LTE 负载下 Android vs OpenWrt

在 Jio 4G LTE（`speedtest.tele2.net`）上完全相同的 10 MB 下载下，我们在两个操作系统上刻画了负载后耗散曲线和内部硅状态：

### 3.1 经验并排冷却曲线

| 经过时间 | Android 调制解调器（TSENS 0） | Android CPU（TSENS 5） | Android PMIC | OpenWrt 调制解调器（TSENS 0） | OpenWrt CPU（TSENS 4） | OpenWrt PMIC | 热差（调制解调器 / CPU） |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **测试前基线** | 49.0°C | 48.0°C | 39.9°C | 59.0°C | 57.0°C | 54.8°C | **+10.0°C / +9.0°C（OpenWrt）** |
| **T = 0s（峰值负载）** | **52.0°C** | **50.0°C** | **43.5°C** | **63.0°C** | **61.0°C** | **59.9°C** | **+11.0°C / +11.0°C（OpenWrt）** |
| **T = 30s 负载后** | **49.0°C** *（-3°C）* | **47.0°C** *（-3°C）* | **40.0°C** *（-3.5°C）* | **62.0°C** *（-1°C）* | **59.0°C** *（-2°C）* | **56.3°C** *（-3.6°C）* | **+13.0°C / +12.0°C（OpenWrt）** |
| **T = 60s 负载后** | **48.0°C** *（-4°C）* | **46.0°C** *（-4°C）* | **39.2°C** *（-4.3°C）* | **61.5°C** *（-1.5°C）* | **59.5°C** *（-1.5°C）* | **56.4°C** *（-3.5°C）* | **+13.5°C / +13.5°C（OpenWrt）** |
| **T = 90s 负载后** | **48.0°C** *（基线）* | **46.0°C** *（基线）* | **38.7°C** *（基线）* | **61.0°C** *（底限）* | **60.0°C** *（底限）* | **56.5°C** *（底限）* | **+13.0°C / +14.0°C（OpenWrt）** |

### 3.2 分歧的机制原因

1. **在 Android 上：**
   * **即时 A2 收起：** 数据包一停止流动，`bam_dmux` 执行 SMSM 握手（`a2 ack out cnt` 从 66 推进到 68；`a2 pwr cntl in` 推进到 68）。
   * **Hexagon DSP 睡眠：** `/sys/kernel/debug/rpm_master_stats` 确认调制解调器处理器子系统（MPSS）在几毫秒内转换到 `active_cores: 0x0`，在 90s 冷却窗口内记录 **+98 次睡眠关机**。
   * **时钟门控：** Hexagon AXI 总线时钟（`gcc_mss_q6_bimc_axi_clk`）立即降至 `rate = 0 Hz`。
   * **结果：** 总 PCB 功率立即崩溃，在 60 秒内恢复凉爽的 **48.0°C 基线**。

2. **在 OpenWrt 上：**
   * **钉住的 DMA 与基带：** A2 引脚（[补丁 848](../../msm89xx/patches/848-bam-dmux-a2-pin.patch)）在 BAM-DMUX remoteproc 设备上强制 `control = on`（这取代了更早的用户空间 `modem-a2-hold` 辅助工具）。
   * **Hexagon DSP 钉住唤醒：** 调制解调器基带被阻止放下 `SMSM_A2_POWER_CONTROL`。Hexagon DSP 和 BAM DMA 引擎以全功率连续运行。
   * **结果：** 10 MB 下载期间产生的热无法完全消散，因为调制解调器主动生成基线功率。设备在 **约 59°C–61°C** 停止冷却，相对 Android 产生永久的 **+13°C 差距**。

---

## 4. 架构根因分析

### 成因 1：调制解调器 A2 域钉住（A2 引脚；以前为 `modem-a2-hold`）——（+10°C 基线偏移）  ⚠ *作为热差距成因已驳斥 —— 见上方更正框*
* **在 Android 上：** Qualcomm 的下游 `bam_dmux.c` 使用运行时电源管理（`ul_powerdown()` / `ul_wakeup()`）。当网络流量暂停时，AP 清除其在 `SMSM_A2_POWER_CONTROL` 上的投票。调制解调器基带（Hexagon DSP、BAM DMA 引擎、共享内存总线）将 A2 时钟/电源域收起为低功耗睡眠。
* **在 OpenWrt 上：** 将 A2 电源下上循环会触发原厂调制解调器固件中的 `a2_power.c:1189` 断言崩溃。OpenWrt 因此保持 A2 引脚 —— 现由 `qcom_bam_dmux` 驱动在 DT 设置 `qcom,a2-pin` 的板上强制（HMU05；补丁 848/849），等效于：
  ```sh
  echo on > /sys/devices/platform/soc@0/4080000.remoteproc/4080000.remoteproc:bam-dmux/power/control
  ```
  （以前是已移除的用户空间 `/usr/sbin/modem-a2-hold` 辅助工具）
* **影响：** 调制解调器基带及其共享 DMA 引擎 24/7 全功率运行，只要蜂窝连接打开，就在整个 PCB 上产生连续 **约 10°C 热偏移**。

### 成因 2：缺失的 CPU 核电压缩放（CPR / VDD_APC）——（负载下 +3°C 至 +5°C）
* **在 Android 上：** 
  * Qualcomm 的核功率降低（CPR）硬件模块主动调节 PM8916 SMPS2（`8916_s2`）供应的 `VDD_APC`。
  * 在此确切 HMU05 硬件单元上来自 `/sys/kernel/debug/cpr-regulator/apc_corner/debug_info` 的实况寄存器：
    ```
    corner = 4 (800 MHz), current_volt = 1050000 uV (1.05 V)
    fuse_corner = 2, rbcpr_gcnt_target = 0x13346
    pvs voltage: [1050000 1100000 1250000] uV
    ceiling voltage: [1050000 1150000 1350000] uV
    floor voltage:   [1050000 1050000 1162500] uV
    ```
  * 对于高达 800 MHz 的所有工作频率（角 1–4：200、400、533、800 MHz），CPU 核电压由 Qualcomm 硅片 eFuse（QFPROM 第 0 和 27 行）分档，严格运行于 **1.05 V**。
* **在 OpenWrt 上：** 
  * 在主线 `arch/arm64/boot/dts/qcom/msm8916.dtsi` 中，CPU 节点上无 `cpu-supply` 属性，`opp-table-cpu` 中无 `opp-microvolt` 值。
  * CPU 频率调控器动态切换频率，但 PM8916 SMPS2 降压转换器仍锁定在默认引导加载器输出电压（**约 1.20 V–1.25 V**）。
* **影响：** 动态开关功率耗散随电压平方缩放（$P \propto V^2$）：
  $$\frac{(1.20\text{ V})^2}{(1.05\text{ V})^2} \approx 1.306 \implies \mathbf{+30.6\%\text{ OpenWrt 动态功率耗散更高}}$$
  在 800 MHz 处理网络数据包时，OpenWrt 每包产生显著更多热。

### 成因 3：不同的热缓解跳闸点  ⚠ *作为修复已驳斥 —— 见上方更正框*
* **在 Android 上：** 内核 DTS 在 **60°C**（`qcom,limit-temp = <60>`）设置被动节流。用户空间 `thermal-engine` 在 55°C 监测 GPU、60°C 监测 WLAN。
* **在 OpenWrt 上：** 主线 DTS 在 **75°C**（`cpu0_1_alert0`）设置被动节流。
* **影响：** 在 55°C 和 75°C 之间，OpenWrt 施加**零热限制**，允许热在持续网络传输期间自由积累，直到达到 75°C。

---

## 5. 被证明为假的内容（被揭穿的迷思）

1. **迷思 1："OpenWrt 总是高 15°C，即使空闲时。"**
   * **被揭穿：** 在断开空闲时，OpenWrt 是 **48.0°C vs Android 的 49.0°C**（精确对等）。
2. **迷思 2："OpenWrt 无 CPU 空闲，只做 WFI。"**
   * **被揭穿：** 实况遥测显示 OpenWrt 通过 PSCI OSI 模式将 **97.9% 的空闲时间**花在 `cpu-sleep-0`（独立功率收起）中。
3. **迷思 3："Android 使用激进的 thermal-engine 节流来保持凉爽。"**
   * **被揭穿：** 在 Android 中，`msm_thermal` 在启动时被禁用（`enabled = 0`），且 `thermal-engine` 记录 0 次缓解事件。Android 因 1.05 V 核电压和 A2 功率收起而自然保持凉爽。
4. **迷思 4："主线 Linux 上 TSENS 校准损坏。"**
   * **被揭穿：** 两个 OS 读取相同的 QFPROM 熔丝并计算匹配的斜率和偏移。

---

## 6. 技术修复计划

为永久将 OpenWrt 的工作温度降至 Android 水平：

### 步骤 1：解决 `a2_power.c:1189` 静止 bug（目标：-10°C）  ⚠ *非热修复 —— A2 钉住与 Android 对等；这是调制解调器稳定性任务*
* **目标：** 启用 BAM-DMUX 运行时挂起（`control=auto`），使调制解调器基带在数据包突发间睡眠。
* **实现：** 修复 `kmod-bam-dmux` 中的 down-ack 串行化握手（跟踪于 `Docs/Modem Stability/Modem RE/hmu05/A2_QUIESCE_ASYMMETRY.md`），这将允许放下 A2 引脚（`echo 0 > /sys/module/qcom_bam_dmux/parameters/a2_pin`；旧用户空间 `modem-a2-hold` 已移除）。

### 步骤 2：在设备树中接上 1.05 V SMPS2 稳压器（目标：负载下 -3°C 至 -5°C）
* **目标：** 将 CPU 核电压从引导加载器默认值（约 1.20 V）降至 1.05 V。
* **实现：** 在 `msm89xx/patches/805-arm64-dts-qcom-add-msm8916-generic-hmu05.patch` 中，绑定 `cpu-supply = <&pm8916_s2>` 并在 200/400/800 MHz OPP 表中添加 `opp-microvolt = <1050000>`。

### 步骤 3：将被动热跳闸点降至 65°C  ⚠ *已驳斥 —— 75→60 °C 给出 0 °C 收益和 −37 % 吞吐量*
* **目标：** 防止长时间持续 LTE 下载将晶粒温度推入 70°C+ 范围。
* **实现：** 在 `msm8916-generic-hmu05.dts` 中覆盖 `cpu0_1_alert0` 以设置 `temperature = <65000>`。

### 步骤 4：AP 互连 / DDR 带宽投票（目标：关闭剩余的 +12°C 负载差距）
* **目标：** 使 OpenWrt AP 在 LTE 负载下缩小 fabric/AXI/DDR 角，如同 Android 的 RPM 总线客户端（`MSM_BUS_SCALING` / `MSM_DEVFREQ_DEVBW`）。
* **为何：** 在 CPR/CPU 轨修复（成因 #2，已完成）之后，这是**唯一剩余的量化差异**。Android 投票总线带宽（约 107 个调用点，17 个实况 `/d/msm-bus-dbg` 客户端）；OpenWrt 投票**无**，使互连处于默认更高功率状态 —— 一个晶粒级、负载比例的热源（Android 差分轴 A17，`project_android_ap_is_an_rpm_client.md`）。
* **实现（提议，尚未完成）：** 启用 `INTERCONNECT_QCOM` + `DEVFREQ_DEVBW` 路径，为 CPU/GPU/显示主设备投票带宽，或在负载下静态降低 `bimc`/`snoc`/`pcnoc` 角。**先验证**，用配对 A/B（在匹配的空闲 vs LTE 负载下比较 `bimc`/`snoc`/`pcnoc` 时钟速率和 CX/MX 角电压）再提交 —— 不要猜测角。

> **注（2026-10-24）：** Android 施加的 GPU 热限制在这些无显示设备上**热惰性**（无 GPU 工作负载 → Adreno 306 时钟门控/关），因此移植 GPU 冷却设备将零效果，且在补丁 847 中正确地未做。
