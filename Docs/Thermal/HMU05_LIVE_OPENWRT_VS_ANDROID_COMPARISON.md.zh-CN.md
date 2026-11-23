# HMU05：实况 OpenWrt vs Android 地面真相比较

**日期：** 2026 年 10 月  
**硬件：** HMU05 4G 调制解调器棒（`hmu05,250605v0s`，Qualcomm MSM8916）  
**检查的设备：**
* **原厂 Android 4.4 / Linux 3.10.28：** 于 `192.168.100.1` 实况 SSH（Jio 4G LTE 已连接）
* **OpenWrt 24.10 / Linux 6.12.94：** 于 `192.168.8.1` 实况 SSH（通过 `wwan0` 连接 Jio 4G LTE，100% 只读检查）

> **注（2026-10-10）—— A2 引脚现在在驱动中，而非用户空间。** 下面引用的
> 用户空间 `/usr/sbin/modem-a2-hold` 辅助工具已**移除**。A2
> 引脚现由 `qcom_bam_dmux` 驱动在设备树设置 `qcom,a2-pin` 的板上保持
> （HMU05；补丁 848/849）；用
> `echo 0|1 > /sys/module/qcom_bam_dmux/parameters/a2_pin` 切换它。下文对
> `modem-a2-hold` 的引用描述的是更早的用户空间机制。

---

> ## ⚠ 更正（2026-10-09）—— 使用本文档前请阅读
>
> 本文档的**中心声明被驳斥。** 它断言（§1 表，§2.1，§3）差距由
> OpenWrt 钉住调制解调器 A2 而 *Android 让它收起*造成。实况 Android 数据
> （`android_idle.csv`）保持 `a2_out=30`、`a2_in=28`、`a2_pwr=30` **恒定 —— 0 次转换**
> ⇒ **Android 保持 A2 开**，*与* OpenWrt 的 `modem-a2-hold` 引脚相同状态。该引脚是
> **对等，而非偏差**，无法解释 OpenWrt−Android 差距。所声称的
> **"+10–12 °C A2 偏移"不受支持**；测得的钉住−未钉住**空闲**差约
> **+2.8 °C**。见
> [HMU05_OPENWRT_ANDROID_THERMAL_ROOT_CAUSE.md](./HMU05_OPENWRT_ANDROID_THERMAL_ROOT_CAUSE.md)
> 的调和。
>
> **本文档中也已取代：**
> - **§2.2 / §3 "未缩放的 CPU 电压" —— 已修复。** 轨差距（1.15 V vs Android 1.05 V）已
>   关闭：Qualcomm **CPR** 已移植（补丁 841–846）且轨现运行于 **1.0625 V**。
>   下方提议的"接 `cpu-supply` + `opp-microvolt`"修复是**错误**的 —— 它引导循环
>   （补丁 840）；该轨由 CPR 管理。见
>   [HMU05_CPU_RAIL_CPR_PORT.md](./HMU05_CPU_RAIL_CPR_PORT.md)。
> - **§3 "将跳闸降至 65 °C" —— 作为修复已驳斥**（0 °C 收益，−37 % rx，空闲节流
>   回归）。
>
> 测得的传感器数字仍是有用的**原始观察**；因果故事则不然。

---

## 1. 执行摘要与地面真相矩阵

通过跨三种运行状态的受控实况硬件测试，OpenWrt 与原厂 Android 之间的热行为现已完全理解并证明：

```
[Regime 1: Disconnected Idle] ──► [Regime 2: Connected Idle] ──► [Regime 3: Active LTE Load]
   • BAM-DMUX: suspended             • BAM-DMUX: active (pinned)     • Continuous LTE transfer
   • Delta: 0°C (Exact Parity!)      • Delta: +10°C to +12°C         • Delta: +12°C to +14°C
```

### 三种运行状态比较

| 运行状态 | TSENS 通道 | Android（`192.168.100.1`） | OpenWrt（`192.168.8.1`） | 实况差（OWrt - Android） |
|---|---|:---:|:---:|:---:|
| **1. 断开空闲**<br>*（调制解调器挂起）* | 调制解调器（TSENS 0）<br>CPU0–1（TSENS 4）<br>PMIC 晶粒 | 49.0°C<br>47.0°C<br>39.2°C | **48.0°C**<br>**46.0°C**<br>**37.4°C** | **-1.0°C**<br>**-1.0°C**<br>**-1.8°C** *（精确对等）* |
| **2. 连接空闲**<br>*（LTE 附着，0 流量）* | 调制解调器（TSENS 0）<br>CPU0–1（TSENS 4）<br>PMIC 晶粒 | 49.0°C<br>47.0°C<br>39.2°C | **59.0°C**<br>**57.0°C**<br>**54.8°C** | **+10.0°C**<br>**+10.0°C**<br>**+15.6°C** |
| **3. 活动 LTE 负载**<br>*（10 MB 下载）* | 调制解调器（TSENS 0）<br>CPU0–1（TSENS 4）<br>PMIC 晶粒 | 51.0°C<br>49.0°C<br>39.5°C | **63.0°C**<br>**61.0°C**<br>**59.9°C** | **+12.0°C**<br>**+12.0°C**<br>**+20.4°C** |

---

## 2. 重跑测试（调制解调器连接）的关键见解

### 2.1 BAM-DMUX 与 A2 电源状态的关键作用
1. **当 BAM-DMUX 挂起（状态 1）：**  
   在蜂窝连接建立之前，BAM-DMUX 运行时状态为 `suspended`，电源控制为 `auto`。在此状态下，OpenWrt 运行于 **48.0°C 调制解调器 / 46.0°C CPU / 37.4°C PMIC**，显示**与 Android 完全热对等**。
2. **当调制解调器连接（状态 2 与 3）：**  
   一旦 `wwan0` 连接到 Jio 4G，BAM-DMUX 电源状态转为 `control = on` 且 `runtime_status = active`。  
   因为调制解调器 A2 域在 OpenWrt 上被 24/7 钉住唤醒以防止 `a2_power.c:1189` 崩溃，调制解调器 Hexagon DSP、BAM DMA 引擎和共享内存总线在突发间从不进入低功耗睡眠。这立即将空闲底限从约 48°C 提升到 **约 59°C**（+11°C 跳升）。
3. **在 Android 上：**  
   Android 的下游 `bam_dmux.c` 驱动允许 A2 域在空闲暂停期间动态收起，即使注册在 LTE 网络上也将基线温度保持在 **约 49°C**。

---

### 2.2 负载下 CPU 电压与动态功率耗散
* **Android：** 实况电压轨 `8916_s2`（VDD_APC）运行于 **1,050,000 µV（1.05 V）**。
* **OpenWrt：** 主线设备树不将 `cpu-supply` 绑定到 `PM8916 SMPS2`，使 CPU 核处于固定引导加载器默认（约 1.15 V–1.25 V）。
* 在活动下载负载下（800 MHz 处理 TCP/IP 数据包）：
  $$\frac{(1.20\text{ V})^2}{(1.05\text{ V})^2} \approx 1.30 \implies \mathbf{OpenWrt\ 动态功率耗散高\ +30\%}$$
  结合钉住的调制解调器，这在短暂的 10 MB 传输后立即将晶粒温度推至 **63°C**（90 秒后非常缓慢地冷却到约 61°C）。

---

### 2.3 热缓解与跳闸点
* **Android：** 在 `dmesg` 中，内核热缓解在启动时被禁用（`msm_thermal:set_enabled enabled = 0`），且 `thermal-engine` 记录 0 次缓解事件。Android 在 10 MB 负载下**不**节流以保持凉爽；它纯粹通过硬件功率收起和 1.05 V 核轨保持在 51°C。
* **OpenWrt：** 主线 `msm8916.dtsi` 在 **75°C**（`cpu0_1_alert0`）设置被动节流。在 55°C 和 75°C 之间，OpenWrt 不施加热限制，允许负载热自由积累。

---

## 3. 最终结论与解决路径

| 识别的问题 | 影响 | 推荐修复 |
|---|---|---|
| **调制解调器 A2 域钉住唤醒** | 连接时 **+10°C 至 +12°C** 偏移 | 修复 `kmod-bam-dmux` 中的 `bam-dmux` down-ack 串行化 bug 以允许运行时挂起而不触发 `a2_power.c:1189` 崩溃，消除 `control=on` 的需求。 |
| **未缩放的 CPU 电压（1.20V vs 1.05V）** | CPU 负载下 **+3°C 至 +5°C** | 在 DTS 中接 `cpu-supply = <&pm8916_s2>` 并向 200/400/800 MHz OPP 表添加 `opp-microvolt = <1050000>`。 |
| **高热跳闸点（75°C）** | 允许热无缓解地积累至 75°C | 在 DTS 中将被动跳闸阈值降至 **65°C** 以限制峰值持续负载温度。 |
| **Wi-Fi TX 功率（默认 20 dBm）** | 小外壳内 +1°C 至 +2°C 环境热 | 将默认 AP TX 功率降至 14 dBm（25 mW）。 |
