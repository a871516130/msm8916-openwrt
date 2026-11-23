# 将 Android 的热控制移植到 OpenWrt —— 逐杠杆结果（HMU05）

> **更正（2026-10-08）：** 原始空闲 CSV 并不支持本报告所声称的已稳定的 +15 °C OpenWrt 基线。空闲采集相差约 3–7 °C，且为冷却瞬态；约 14–15 °C 的差值出现在负载峰值上。源代码审计也使 TSENS 校准偏移的可能性降低，并指出 Android 的 PA/调制解调器热引擎路径是主要的负载相关假设，而非已证实的成因。参见 [更新后的根因研究](./HMU05_OPENWRT_ANDROID_THERMAL_ROOT_CAUSE.md)，该文档取代了 §3 和 §4 中的基线/DDR 互连推断。CPU 跳闸 A/B 观察结果仍分别有用。

**问题：** *"我们如何在 OpenWrt 中模仿 Android 的热控制？"*（之前的热测试
"收效甚微"）。

**答案（TL;DR）：** 你几乎可以 1:1 移植 Android 的 CPU 热杠杆 —— 但**它们并不能
给板卡降温**，其中一个甚至让情况更糟。板卡**每个传感器都均匀地比 Android 高约 ~15 °C，
且已处于空闲状态**（在任何 CPU 负载之前）。CPU
频率是这种热的*后果*（CPU 为响应它而节流），而非成因。Android 的热跳闸点是针对
Android 较冷的基线标定的；在 OpenWrt 较热的基线上，相同的绝对跳闸点会*永久*节流 CPU，
包括空闲时。

**结论：** CPU 热控制轴已**关闭**。多余的热是系统级的
（基线/空闲），与仍然开放的 DDR/互连/电源轨线索一致 —— *而非*缺失热调控器。

---

## 1. Android 在 MSM8916 上实际配置了什么

Android 的 `msm_thermal`（`drivers/thermal/msm_thermal.c`，4118 行，`CONFIG_THERMAL_MONITOR`）
每 250 ms 轮询一次并运行一系列 `do_*` 函数。在 MSM8916 上 DTS 中**仅配置了三个**；
其余虽被编译进来但为空操作：

| Android 杠杆 | 在 MSM8916 上配置？ | 作用 |
|---|---|---|
| `do_freq_control` | **是** —— `limit-temp=60`，步进 2，掩码 `0xf` | 在 60 °C 时限制 CPU 最大频率 |
| `do_core_control` | **是** —— `core-limit-temp=80`，掩码 `0xe` | 在 80 °C 时下线 CPU1-3 |
| `do_vdd_restriction` | **是** —— 冷保护（<5 °C） | 提升 VDD_DIG + CPU 最低频率下限（冷，而非热） |
| `do_psm` | 否 | 稳压器省电模式 |
| `do_ocr`、`do_vdd_mx`、`do_gfx_phase_cond`、`do_cx_phase_cond`、`do_therm_reset` | 否 | — |

OpenWrt 的主线等效物是 DT `thermal-zones` + `step_wise` 调控器 +
`cpufreq_cooling`。所以可移植的面很小。

---

## 2. 逐杠杆移植 + A/B 结果

所有 A/B 运行：持续 LTE 下载（有界 `wget` 循环），采样器
`scratch/thermal_baseline/thermal_sample.sh`（6 个区域 + 每核频率 + 冷却状态 +
bam-dmux 遥测），约 120 个采样 @ 2 s。CSV 位于 `scratch/thermal_baseline/`。

### 杠杆 1 —— `do_freq_control`：将 CPU 跳闸从 75 °C 降至 60 °C

**补丁：** `837-arm64-dts-qcom-msm8916-cpu-thermal-trip-60c.patch`
（`cpu0-1-thermal` / `cpu2-3-thermal` `trip-point0` 75000 → 60000，迟滞 2 °C 保留）。

| 运行 | 调制解调器峰值 | 调制解调器均值 | CPU 频率分布（负载） | 吞吐量 rx/tx |
|---|---|---|---|---|
| 对照（跳闸 75） | **76 °C** | 71.0 | 800M×98, 400M×15, 200M×2, 998M×5 | 1738 / 513 每秒 |
| 杠杆 1（跳闸 60） | **76 °C** | 69.6 | 200M×52, 400M×53, 800M×14 | **1098 / 429 每秒** |

**结果：无热收益（峰值相同），吞吐量代价大（rx −37 %，tx −16 %）。**
CPU 在 105/120 个采样中被钉在 200–400 MHz，板卡仍达到 76 °C。

**为何峰值相同 —— 决定性观察。** 在*两个*运行中，
**低频采样最热**：

```
对照:  f0=800MHz  调制解调器 70.4 °C (n=98) | f0=400MHz 调制解调器 74.9 °C (n=15) | f0=200MHz 调制解调器 76.0 °C (n=2)
杠杆1:  f0=800MHz  调制解调器 61.6 °C (n=14) | f0=400MHz 调制解调器 70.9 °C (n=53) | f0=200MHz 调制解调器 70.5 °C (n=52)
```

CPU 节流**是因为**板卡热。频率作为*效应*跟随热；强制
它下降并不会消除热。

**二阶效应 —— 空闲节流回归。** OpenWrt **空闲时约 60 °C**
（`cpu0-1-thermal` 55–61 °C，`modem-thermal` 61–64 °C 于真空闲）。因此 60 °C 跳闸配 2 °C
迟滞便*低于*空闲温度：一旦板卡变暖，CPU 便被
保持在 `cooling_device0 cur_state = 3` → **即使空闲也 200 MHz**，而对照
（跳闸 75）处于 800 MHz 且 `cur_state = 0`。Android **不**这样做，因为 Android
空闲时低约 15 °C（见 §3）。

### 杠杆 2 —— 将最大 CPU OPP 限制为 800 MHz（Android 上限）

**补丁：** `838-arm64-dts-qcom-msm8916-cpu-opp-max-800mhz.patch`（移除 `opp-998400000`）。

**结果：可证明无效（已测量）。** Android 的 OPP 表是 {200, 400, 533.333, 800} —— 无
998.4 —— 因此限制是*对等*。但在负载下对照已运行 800 MHz 达 **98/120**
个采样；998 MHz 的 5 个采样是整个运行中**最冷**的（均值 69.4 °C vs
800 时的 70.4 °C）。移除它们无法降低峰值。

实测 A/B（镜像 834+837+**838**，`owrt_load_lever2.csv`）：

| 运行 | 调制解调器峰值 | 调制解调器均值 | cool0 最大 | CPU 频率分布（负载） | rx/tx 每秒 |
|---|---|---|---|---|---|
| 对照（837，有 998） | 76 | 69.6 | 3 | 200M×52, 400M×53, 800M×14, 998M×1 | 1098 / 429 |
| +838（无 998） | **75** | 70.0 | 2 | 200M×59, 400M×59, 800M×2 | 1011 / 386 |

峰值 75 vs 76 °C = ≤1 °C，**在运行间噪声内**（对照和杠杆 1 均达峰 76）。
实况确认：`scaling_available_frequencies = 200000 400000 800000`（无 998400）。在
杠杆 1 生效时，CPU 在负载下无论如何达不到 800（118/120
个采样被节流到 ≤400），因此杠杆 2 被双重掩盖。**无害的对等变更，无热效应。**

### 杠杆 2b —— `do_core_control`（80 °C 下线 CPU1-3）—— 不在批准计划内

Android 的第二个已配置杠杆在 80 °C 下线核 1-3。OpenWrt 有 `CONFIG_CPU_THERMAL=y`
和 `CONFIG_HOTPLUG_CPU=y`，但**唯一的冷却设备是 `cpufreq-cpu0`** —— 主线没有
CPU-**热插拔**冷却设备（Android 的 `core_control` 是下游机制）。不可通过 DT 移植；
且鉴于 CPU 轴无效（见下文），它也无济于事。**注意峰值是
76 °C，低于 80 °C 触发 —— 在此负载下它无论如何都不会触发。**

### 杠杆 3 —— CPU OPP 电压缩放（`required-opps` → rpmpd VDDCX）

**结果：不可通过 DT 移植。** 已对照构建树验证：

- `arch/arm64/.../msm8916.dtsi` CPU OPP 表**无 `opp-microvolt`** 且**无
  `cpu-supply`** —— CPU 轨完全未被建模（主线省略 `pm8916_s2`；Android 的
  轨是下游 `spm-regulator` + `qcom,cpr-regulator`，两者均不在主线中）。
- CPU OPP 表中裸 `required-opps` 是**可证明的空操作**：
  `drivers/opp/core.c:1117` `_set_required_opps()` 在
  `opp_table->required_devs == NULL` 时立即返回，而 `required_devs` 仅由
  `devm_pm_opp_attach_genpd()` / `dev_pm_domain_attach_by_name()` 填充 —— **`cpufreq-dt.c` 包含
  零 genpd/pm-domain 引用**。因此 `_set_opp_level() → dev_pm_domain_set_performance_state()
  → rpmpd_set_performance()` 路径对 CPU 从未被触达。
- CPU 节点已携带 `power-domains = <&CPU_PDn>`（PSCI）配
  `power-domain-names = "psci"`；CPU 有一个电源域，仅 DT 无法添加 rpmpd。

实现此功能需要**内核驱动改动**（将 `cpufreq-dt` 接到 rpmpd）外加电压
映射 —— 中等风险（映射错误 ⇒ CPU 挂起，EDL 恢复）。超出热快速获胜的范围。

### 杠杆 4 —— `do_psm`（稳压器省电模式）

**结果：不可移植，且 Android 在 MSM8916 上不用它。** 主线
`drivers/regulator/qcom_smd-regulator.c` 暴露 `.set_load` 但**无 `.set_mode`** 操作，因此
没有稳压器模式接口。Android 的 `do_psm` 使用下游
`rpm_regulator_set_mode()` 且**未配置**在 MSM8916 DTS 中（无 `psm-*`
属性）—— 即使在 Android 上也是空操作。**跳过。**

### 杠杆 5 —— DDR / 互连缩放（最后杠杆）

**结果：已关闭。** 见专门审计：
- ICC 投票*确实*发往 RPM（`bimc_clk` = `{QCOM_SMD_RPM_MEM_CLK, 0}`，
  `qcom_icc_rpm_set_bus_rate()`），但 RPM 不对其采取动作 —— 热惰性（C-3，Δ≤0.3 °C）。
- `bimc_ddr_clk_src` 是 **AP 侧** RCG（GCC 0x32004，无频率表 ⇒ `clk_set_rate`
  返回 `-EINVAL`）；补丁 835/836 证明 AP 无法持久移动它。Android **无
  此类时钟** —— DDR/BIMC 仅由 RPM 管理。

从 AP 进行 DDR/互连缩放的路径**已关闭**。剩余的系统级线索是
PMIC/轨功率差异，而非缺失的 AP 时钟。

---

## 3. 根因发现 —— 基线，而非调控器

直接 Android↔OpenWrt A/B（`scratch/thermal_baseline/`，同一硅片）：

| tsens 传感器 | OpenWrt 峰值 | Android 峰值 | Δ |
|---|---|---|---|
| 0 调制解调器 | 77 | 62 | **+15** |
| 1 相机 | 74 | 58 | +16 |
| 2 gpu | 73 | 58 | +15 |
| 4 cpu23 | 73 | 58 | +15 |
| 5 cpu01 | 76 | 60 | +16 |
| pm8916 | 67 | 53 | +14 |

- 差距**在每个传感器上均匀**且**空闲时已存在**
  （OpenWrt 空闲：调制解调器 61–64 °C；Android 空闲：tsens 53–59 °C，pm8916 44–47 °C）。
- 任何负载之前就存在的均匀偏移是**系统级功率**，而非 CPU 热
  策略差异。（与 Android 通过 `msm_bus` —— 107
  个客户端 —— 投票 DDR/互连带宽一致，而 OpenWrt 的 ICC 路径无效。）

**对跳闸点的后果。** Android 的 60 °C CPU 跳闸 ≈ *Android 的空闲上限*。在
OpenWrt 上相同 60 °C 位于/低于空闲上限 → 永久节流。OpenWrt 的
**原始 75 °C 跳闸已经是 Android 60 °C 的基线校正等效物**
（60 + Δ15 ≈ 75）。将其降至 60 是错误方向。

---

## 4. 建议

1. **不要按原样交付杠杆 1**（`trip = 60`）：零热收益，−37 % 吞吐量，以及
   永久空闲节流回归。要么**还原 837**，要么，若希望更早节流，
   将跳闸设*高于*空闲基线（≥ 70 °C）—— 但两种方式预计 ≈0 °C 收益。
   **注意：** OpenWrt 的*原始* 75 °C 跳闸已经是 Android 60 °C 的基线校正等效物
   （60 + Δ15 ≈ 75），因此 `do_freq_control` 的"正确移植"是**完全
   不做改动**。
2. **杠杆 2（限制 800 MHz）** 是无害的对等；可交付或丢弃，无热效应。
3. **杠杆 3–5** 已如上述关闭 —— 无进一步 CPU 侧工作。
4. **真正的工作在基线。** 板卡从空闲起均匀 +15 °C；追踪
   系统级功率差异（PMIC 轨 / DDR-互连功率），而非热调控器。
   关联：停放 **#367**（为何 Android 对 `a2_power.c:1189` 免疫）以及 A2 引脚 /
   热 / 崩溃链。

**决策（2026-10-08）：** 杠杆 1 已**还原**（补丁 837 移至
`scratch/thermal_baseline/rejected/` 以保持可复现）；交付的镜像为 **834 + 838**
（Android 的 800 MHz OPP 对等，无害）。杠杆 1 的空闲节流回归在
对等镜像上实况观察到（在 59 °C 时 CPU 处于 `cooling_device0 cur_state = 1` / 400 MHz，
而未打补丁的对照处于 `cur_state = 0` / 800 MHz），因此有害杠杆
被移除。已在交付镜像上实况验证（boot_id `c2fd6ceb…`）：
`scaling_available_frequencies = 200000 400000 800000`，`cooling_device0 max_state = 2`，
`cpu0-1-thermal / cpu2-3-thermal trip0 = 75000`（原始），且在 55 °C 时 CPU 处于
`cur_state = 0` / 800 MHz —— 无空闲节流。

## 5. 工件

| 项 | 路径 |
|---|---|
| 杠杆 1 补丁 | `msm89xx/patches/837-arm64-dts-qcom-msm8916-cpu-thermal-trip-60c.patch` |
| 杠杆 2 补丁 | `msm89xx/patches/838-arm64-dts-qcom-msm8916-cpu-opp-max-800mhz.patch` |
| A/B 数据 | `scratch/thermal_baseline/owrt_load_{control,lever1,lever1b,lever2}.csv`、`android_{idle,load}.csv` |
| 采样器 / 驱动 | `scratch/thermal_baseline/{thermal_sample.sh,run_load_test.sh}` |
| 杠杆 3 代码证明 | `drivers/opp/core.c:1117`、`drivers/cpufreq/cpufreq-dt.c`（无 genpd 引用） |
| 杠杆 4 代码证明 | `drivers/regulator/qcom_smd-regulator.c`（`.set_load`，无 `.set_mode`） |
| 杠杆 5 | `msm89xx/patches/835,836`（已移除）—— DDR AP 时钟路径已关闭 |

## 6. SOP 说明

这是 AP 侧（DTS/内核）热演练，**非基带移植** —— 本会话未修改调制解调器固件，
因此双固件比较 SOP 的 Hexagon 补丁/哈希步骤不适用。所有声明均基于 (a) 构建树中的运行内核源码
（`drivers/opp/core.c:1117`、`drivers/cpufreq/cpufreq-dt.c`、
`drivers/regulator/qcom_smd-regulator.c`）或 (b) 实测 A/B CSV。A/B 运行使用固定
采样器和有界负载循环；峰值对比是预先登记的标准。
捕获的错误：第一个杠杆 1 补丁（调制解调器/pm8916 → CPU 冷却映射）导致空闲
回归，在评估前被还原；第一版 `scaling_max_freq` 运行时测试
无定论（板卡仍热），被运行内频率/温度
分析取代。
