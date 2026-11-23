# 热与电源管理

这些 MSM8916 USB 棒在小型无通风外壳内运行高温，且
基带行为对 SoC 电源轨敏感。因此正确设置热
策略和 CPU 轨既是**舒适/稳定性**问题，也是（间接地）**调制解调器稳定性**
问题。

本文件夹收集 HMU05 热调查：OpenWrt-vs-Android
比较、根因分析、以及移植的修复。

**硬件：** HMU05 4G LTE 棒（`hmu05,250605v0s`，Qualcomm MSM8916 /
Snapdragon 410）。
**比较的栈：** 原厂 Android 4.4 / Linux 3.10.28 vs OpenWrt 25.12.5 /
主线 Linux 6.12.94。

---

## 我们已知的内容（当前结论）

- **差距是负载相关的，而非固定空闲偏移。** OpenWrt 确实更热
  **在 LTE 负载下**（五个 TSENS 传感器约 **+12 °C**），但
  更早的"+15 °C *空闲*"声明**不成立**：重算空闲捕获
  仅差 **+3–7 °C**，且每个空闲捕获是冷却/启动预热
  **瞬态**，而非平衡基线。
- **A2"引脚"是对等，非成因。** Android 空闲时保持 A2 域**开**
  （其 `a2_out/a2_in/a2_pwr` 计数器恒定），即与
  OpenWrt 的 A2 引脚*相同*状态。因此钉住 A2 **不是**额外热源。
- **Android 的 thermal-engine 在观察温度下不节流调制解调器/PA。**
  恢复的编译进配置的 `fusion` 缓解是 55/60 °C 级别
  0，仅 105 °C 级别 1；LTE 轨迹反而显示 **GPU**
  在 55 °C 限制。这削弱"Android 节流调制解调器/PA"假设。
- **找到的一个真实、可修复成因：CPU 轨。** 主线无动态
  电压缩放（无 `opp-microvolt`/`cpu-supply`，CPR 未实现），而
  Android 使用 `qcom,cpr-regulator`。移植主线 **CPR** 将轨带到
  **1.0625 V —— 匹配 Android**（原约 1.15 V）。

## 已交付内容

| 项 | 状态 | 位置 |
| :--- | :--- | :--- |
| **CPU 轨（主线 CPR）** —— 1.15 V → **1.0625 V**，Android 对等 | ✅ 完成 | 补丁 841–846；[`HMU05_CPU_RAIL_CPR_PORT.md`](HMU05_CPU_RAIL_CPR_PORT.md) |
| **CPU OPP 限制** —— 移除顶部 998.4 MHz OPP，CPU ≤ **800 MHz** | ✅ 完成 | 见根因报告 |
| **Wi-Fi + PMIC 热缓解** —— `wcn36xx` 冷却设备 + PMIC 冷却映射 | ✅ 完成 | 补丁 453 / 861；[README → 热与电源](../../README.md#-thermal--power-management) |

---

## 文档

### 从此开始（当前）

| 文档 | 覆盖内容 |
| :--- | :--- |
| [**HMU05_OPENWRT_ANDROID_THERMAL_ROOT_CAUSE.md**](HMU05_OPENWRT_ANDROID_THERMAL_ROOT_CAUSE.md) | **权威。** OpenWrt 6.12.94 构建树的源与工件审计 + 实况 Android 策略/轨迹（160 s LTE 轨迹 + 点检）。逐因驳斥 +15 °C 空闲前提并陈述更正后的发现。**取代下方更早报告的基线/根因声明。** |
| [**HMU05_CPU_RAIL_CPR_PORT.md**](HMU05_CPU_RAIL_CPR_PORT.md) | 移植 Qualcomm **CPR** 到主线，使 CPU 轨随硅片的熔丝速度仓缩放。结果：轨于 **1.0625 V == Android**（原固定约 1.15 V）。 |
| [**HMU05_SOC_DATA_PATH_RESCOPE.md**](HMU05_SOC_DATA_PATH_RESCOPE.md) | SoC 数据路径热工作重新定范围（2026-10-09）：剩余什么，什么已关闭。 |

### 历史（部分取代 —— 连同更正横幅阅读）

| 文档 | 覆盖内容 |
| :--- | :--- |
| [HMU05_ANDROID_THERMAL_CONTROL_PORT.md](HMU05_ANDROID_THERMAL_CONTROL_PORT.md) | 逐杠杆尝试在 OpenWrt 中模仿 Android 热控制（CPU 跳闸、热插拔、欠压）。其 §3 / DDR-fabric 推断被取代；**CPU 跳闸 A/B 观察仍有用**。 |
| [HMU05_THERMAL_RESEARCH_AND_PROPOSAL.md](HMU05_THERMAL_RESEARCH_AND_PROPOSAL.md) | 更早的"+15 °C"调查及其六个排序成因。空闲基线和根因结论被取代；保留其源观察。 |
| [HMU05_DEFINITIVE_THERMAL_FINDINGS.md](HMU05_DEFINITIVE_THERMAL_FINDINGS.md) | 并排 SSH 地面真相发现；"+13 °C 差距"声明现被限定为**负载相关**。 |
| [HMU05_LIVE_THERMAL_FINDINGS_AND_PROPOSAL.md](HMU05_LIVE_THERMAL_FINDINGS_AND_PROPOSAL.md) | 早期实况 Android 发现与 OpenWrt 缓解提案。 |
| [HMU05_LIVE_OPENWRT_VS_ANDROID_COMPARISON.md](HMU05_LIVE_OPENWRT_VS_ANDROID_COMPARISON.md) | 早期实况 OpenWrt-vs-Android 地面真相比较。 |

> 根因报告取代更早的空闲基线和根因
> 结论；历史报告为原始观察和 CPU 跳闸实验保留，
> **非**为其 +15 °C 空闲前提。

---

## 证据与相关材料

- **原始捕获 / 采样器：** [`scratch/thermal_baseline/`](../../scratch/thermal_baseline/)
  （`android_idle.csv`、`owrt_load_control.csv`、`thermal_sample.sh`，…）。
- **Android thermal-engine 恢复：** 守护进程运行**编译进**默认值
  （**无** `/system/etc/thermal-engine.conf`）；有效配置用
  `thermal-engine -o` 转储并逆向。
- **A2 静止故障（调制解调器侧）：** 单独的调制解调器稳定性任务 ——
  [`Docs/Modem Stability/Modem RE/hmu05/A2_QUIESCE_ASYMMETRY.md`](../Modem%20Stability/Modem%20RE/hmu05/A2_QUIESCE_ASYMMETRY.md)。
- **主 README：** [🌡️ 热与电源管理](../../README.md#-thermal--power-management)。
