# HMU05 实况 Android 热发现与 OpenWrt 缓解提案

**日期：** 2026 年 10 月  
**硬件：** HMU05 4G 调制解调器棒（`hmu05,250605v0s`，Qualcomm MSM8916）  
**目标实况设备：** Android 4.4 / Linux 3.10.28 上的 root SSH shell（`192.168.100.1`）  
**实况 OpenWrt 目标：** OpenWrt 25.12.5（`r33051-f5dae5ece4`）/ 主线 Linux 6.12.94 于 `192.168.8.1`  

> **注（2026-10-10）—— A2 引脚现在在驱动中，而非用户空间。** 下面提到的
> 用户空间 `/usr/sbin/modem-a2-hold` 辅助工具已**移除**。A2
> 引脚现由 `qcom_bam_dmux` 驱动在设备树设置 `qcom,a2-pin` 的板上保持
> （HMU05；补丁 848/849）；用
> `echo 0|1 > /sys/module/qcom_bam_dmux/parameters/a2_pin` 切换它。下文对
> `modem-a2-hold` 的引用描述的是更早的用户空间机制。

> **更正（2026-10-08）—— 使用本提案前请阅读。** 本文档早于
> [HMU05_OPENWRT_ANDROID_THERMAL_ROOT_CAUSE.md](./HMU05_OPENWRT_ANDROID_THERMAL_ROOT_CAUSE.md)
> 中调和的证据，并在多处与其冲突。**已验证正确：** Android 空闲约 44–49 °C；PM8916 轨 `8916_s2` 读 1,050,000 µV；CPU0 C2（`pc`）驻留约 81.5 %（重新确认 1894 s / 2318 s = 81.7 %）；`thermal-engine` 无 `/system/etc/thermal-engine.conf`；内核 `msm_thermal` 禁用。**不受支持 / 已驳斥：**
> - *"thermal-engine 记录 0 次缓解事件 / 完全未激活"*（§1.1，§2.4）是**日志缓冲采样伪影** —— 一个 160 s LTE 轨迹捕获了 `alarm raised 1 at 55.0 degC` → `Setting GPU[0] to 200000000`。§2.1 中的 10 s 负载从未越过 55 °C 阈值。
> - *`modem-a2-hold` 解释 5–7 °C 空闲惩罚*（§1.3，§3，阶段 3）**就空闲而言已驳斥**：Android 的捕获保持 A2 **开**（`a2_out/a2_in/a2_pwr` 恒定），与更早 OpenWrt 钉住样本相同状态；测得钉住−未钉住空闲成本约 **2.8 °C**。这不测试 A2 的负载贡献。OpenWrt 快照在检查期间改变：13:09 UTC 报告 `power/control=auto` / `suspended`；13:39 UTC 报告 `on` / `active`。后者快照中无 `modem-a2-hold` 进程，且状态变化的原因未确立。
> - *"PSCI 无功率收起时回退到 `wfi`"*（§3）被源码支持和当前运行时快照反驳：CPU0 在 `standalone-power-collapse` 记录约 590 s。该状态未证明与 Android 的 `pc` 等效，其热贡献未测量。
> - OpenWrt CPU 轨 *"约 1.15–1.25 V"*（§1.2，§3）**未测量**；约 25–30 % 动态功率和 3–5 °C 数字依赖它。Android 的 CPU 实际上通过 `apc_vreg_corner`（CPR）→ `pm8916_s2` 供电，其角 0 的 DTS 上限/底限为 1.1 V。
> - 阶段 1 DTS（§4）**按书面形式不适用**：主线 `msm8916.dtsi` **无 `pm8916_s2` 节点**（仅 msm8929/msm8939 定义它），因此 `cpu-supply = <&pm8916_s2>` 是悬空引用；`opp-peak-kBps` 需要 interconnect 路径；且将 `cpu-supply` 接入 CPR 路径需要驱动改动（见 CONTROL_PORT 杠杆 3）。
>
> **不要按书面形式应用 8–12 °C 行动计划。** 将其视为假设清单。OpenWrt CPU 轨电压、可比的 CPU 空闲状态效应、以及匹配的无线电/负载/输入功率仍是开放问题；在选择或实施热变更前测量它们。

---

## 1. 当前发现

可用证据确认存储捕获中存在负载相关的温度差异，
但**不**识别一个根因或确立稳定的空闲偏移：

- 保存的 LTE 负载比较在五个匹配 TSENS 通道上约为 **+12 °C 均值**和 **+14–15 °C 峰值**。这些运行未同步或匹配流量速率、无线电条件、环境温度、起始温度或输入功率。
- 保存的空闲比较约 **+3–7 °C**，但轨迹在采样期间冷却或变暖；它们不是平衡的空闲基线。
- Android 的实况 thermal-engine 策略编译进二进制。一个 160 s LTE 轨迹在 CPU0–1 TSENS 55 °C 观察 GPU 从 310 限制到 200 MHz。它未观察调制解调器缓解或运行时策略推送；WLAN 的 60 °C 阈值未达到。PA 热敏电阻被守护进程打开，但非恢复策略中的受监测输入。
- Android CPU0 报告的 `pc` cpuidle 驻留在一个捕获的启动时间窗口内约 81.5%，且 `8916_s2` 在实况快照中读 1.05 V。OpenWrt 现也有 CPU0 空闲状态快照，但状态列表/间隔不匹配；其 CPU 轨电压仍未测量。
- 一个单独实况快照发现 `mpdecision` 运行且四 CPU 全在线。这未确立其在其他时间的行为，但驳斥其总是停放 CPU 1–3 的声明。
- 一个只读 OpenWrt 快照于 `192.168.8.1` 发现 TSENS 0/1/2/4/5 于 48/45/43/44/46 °C，四 CPU 全在线 800 MHz，且 CPU0 频繁处于 `standalone-power-collapse`。BAM-DMUX 在第一次检查从 `auto`/`suspended` 变为较晚检查的 `on`/`active`；原因未知。较晚检查检测到已供电调制解调器，但它仍在搜索网络注册，分组服务分离，WWAN 链路关闭。两个快照都不是 LTE 负载样本。这些温度未与 Android 样本配对，不得视为 OpenWrt-vs-Android 差值。
- 两个更晚的干净仅 OpenWrt 下行运行（2026-10-08）使用附着的 LTE 承载和精确的 32 MiB 正文上限。每个都显示五个 SoC TSENS 通道从稳定的一分钟基线有可重复的瞬时 +4–5 °C 上升；调制解调器 TSENS 峰值 62 °C。第一次尝试被排除，因为用户确认的 `yes` CPU 压力工作进程并发运行。第一个 Android CSV 按用户指示丢弃；保留的运行 2 是唯一 Android 真相来源。它在五个 SoC 通道上比 OpenWrt 峰值低 4–5 °C，但开始低约 8–11 °C，并相对自身基线变暖 +9–10 °C。其负载速率高约 10%。这一个保留的短运行未解决存储的 +14–15 °C 跨 OS 差异。

**结论：** 目前尚无热策略、电压、CPU 热插拔或 A2 变更被证明为温度修复。下一步是以匹配起始温度和至少三对重复 Android/OpenWrt 比较，随后是可逆的单变量测试。当前测量不支持 8–12 °C 收益。

---

## 2. Android 实况遥测数据（`192.168.100.1`）

以下测量从运行中的 Android 系统实况捕获：

### 2.1 一个 Android 快照和短负载样本

| Sysfs 区域 / HW TSENS ID | 节点 | 通道描述 | 样本 A | 10 s 下载后 | 差值 |
|---|---|:---:|:---:|:---:|
| zone0 / ID 0 | `/sys/class/thermal/thermal_zone0` | 调制解调器/基带 | **49°C** | **51°C** | +2°C |
| zone1 / ID 1 | `/sys/class/thermal/thermal_zone1` | 相机/顶部晶粒 | **45°C** | **47°C** | +2°C |
| zone2 / ID 2 | `/sys/class/thermal/thermal_zone2` | Adreno 306 GPU | **44°C** | **46°C** | +2°C |
| zone3 / ID 4 | `/sys/class/thermal/thermal_zone3` | CPU 核 2–3 | **45°C** | **47°C** | +2°C |
| zone4 / ID 5 | `/sys/class/thermal/thermal_zone4` | CPU 核 0–1 | **47°C** | **49°C** | +2°C |
| **PMIC 晶粒** | `/sys/class/thermal/thermal_zone5` | PM8916（`pm8916_tz`） | **39.2°C** | **39.5°C** | +0.3°C |
| **PA 热敏电阻** | `qpnp-vadc-de6e5000/pa_therm0` | RF 功率放大器 | **36.0°C** | **37.0°C** | +1.0°C |
| **XO 热敏电阻** | `qpnp-vadc-de6e5000/xo_therm` | 19.2 MHz 晶振 | **40.0°C** | **40.0°C** | 0.0°C |

这些是短下载周围的点读数，而非匹配的 OpenWrt 比较或稳态热测试。保留捕获时间戳、启动时间、环境温度、下载命令/字节数、LTE 频带和信号数据用于任何未来复现。TSENS 硬件 ID 为 0、1、2、4 和 5；sysfs 区域索引非硬件 ID。

### 2.2 电气与电压轨

```text
8916_s1_corner: 5 uV (state=enabled)
8916_s2:        1050000 uV (1.05 V, state=enabled)   <-- Android 快照; CPU 轨映射
vph_pwr:        3445437 uV (3.445 V)                 <-- 系统电源轨
usb_in:         5125040 uV (5.125 V)                 <-- 5V USB 输入
```

`8916_s2` 值是 Android 在一个工作点的读回。它不确立 OpenWrt 的电压、每个 CPU OPP 的电压或温度贡献。在做出功率缩放推断前于匹配频率和负载下测量两系统。

### 2.3 报告的 CPU0 cpuidle 计数器（一次捕获；启动时间约 1,560 s）

```text
C0 (wfi):           282,724,828 us  ( 282.7 s / 18.1%)  - 浅时钟门控
C1 (standalone_pc):   3,990,260 us  (   3.9 s /  0.2%)  - 核轨掉落
C2 (pc):          1,271,011,076 us  (1271.0 s / 81.5%)  - 全簇功率收起
```

报告的计数器值总计约 1,558 s，与所述启动时间一致，且 `pc` 占此 CPU0 捕获的约 81.5%。这支持 Android 上频繁进入平台的 `pc` 空闲状态。它不是 OpenWrt 测量，也不是轨功率或漏电的直接测量；在归因热效应前于两系统收集可比的计数器差值。

### 2.4 热守护进程日志与缓解证据

* **内核驱动：** `dmesg` 报告：
  ```text
  [    7.256790] msm_thermal:set_enabled enabled = 0
  ```
  `msm_thermal` 缓解在此运行时被禁用。
* **用户空间 `thermal-engine`：** 无 `/system/etc/thermal-engine.conf` 存在；守护进程运行恢复的编译进默认值。一个短的 `logcat` grep 零匹配行不证明守护进程未激活：单独的 160 s LTE 轨迹在 55 °C 记录 GPU 动作。
* 该轨迹**未**记录调制解调器 `fusion` 缓解或运行时配置推送。恢复的默认在 55/60 °C 分配 `fusion` 级别 0，仅 105 °C 时级别 1；`pa_therm0` 非受监测输入。WLAN 60 °C 动作和 CPU `ss` 控制在 78–85 °C 在该轨迹中未达到。见[捕获的策略与轨迹说明](../../scratch/thermal_baseline/android/README.md)。

### 2.5 只读 OpenWrt 快照（`192.168.8.1`）

无设置更改，无负载测试或流量生成器启动。快照报告设备时间 `2026-06-29 13:09:12 UTC`，启动约 10 分钟，OpenWrt **25.12.5** 修订 `r33051-f5dae5ece4`，内核 **6.12.94**，板 `hmu05,250605v0s`。设备时钟不与 2026 年 10 月 Android/工作区捕获对齐，因此将其用作运行时状态观察，而非时间同步比较。

| OpenWrt 热区域 | HW TSENS ID | 当前读数 | 配置的跳闸 |
|---|---:|---:|---:|
| `modem-thermal` (zone0) | 0 | 48 °C | 85 °C |
| `camera-thermal` (zone1) | 1 | 45 °C | 75 °C |
| `gpu-thermal` (zone2) | 2 | 43 °C | 75 / 95 °C |
| `cpu2-3-thermal` (zone3) | 4 | 44 °C | 75 / 110 °C |
| `cpu0-1-thermal` (zone4) | 5 | 46 °C | 75 / 110 °C |
| `pm8916-thermal` (zone5) | — | 37.633 °C | 105 / 125 / 145 °C |

所有六区域报告模式 `enabled` 和策略 `step_wise`。CPU 频率策略显示所有 CPU `0-3` 在线 800 MHz（`schedutil`，200–800 MHz）；CPU 频率冷却设备处于 0/2 状态。这些读数低于此快照中列出的 CPU/GPU 跳闸点。

CPU0 暴露两个 cpuidle 状态：`WFI` 记录 12.88 s / 19,564 次进入，且 `standalone-power-collapse` 记录 589.99 s / 30,204 次进入。这是运行中 OpenWrt 内核**非简单停留在 WFI**的直接证据。时间计数器从启动累计，且 OpenWrt 状态名不证明与 Android 的 `pc` 状态等效或量化轨功率；在得出热结论前比较匹配的计数器差值和状态定义。

#### 13:39 UTC 跟进检查：调制解调器检测到，LTE 数据未附着

BAM-DMUX 设备初始报告 `power/control=auto` 和 `runtime_status=suspended`；其 RX 和功率收起遥测计数器为零。较晚只读检查于设备时间 `2026-06-29 13:39:39 UTC`（启动约 40 分钟）发现 `power/control=on`、`runtime_status=active`、`pc_state=1`、一个 PC 投票且无 PC 超时。较晚进程列表中无 `modem-a2-hold` 进程。这些快照不同；转换的原因未知，且任一读数单独不识别调制解调器的物理 A2 轨状态。

较晚检查中，`mmcli` 检测到调制解调器已供电，信号 86% 且允许 4G，但其状态为 `searching`，注册 `searching`，分组服务 `detached`，报告的网络拒绝为 `illegal-me`。`wwan0`–`wwan7` 全关，字节计数器为零。日志包括一个初始 EPS 承载 QMI `invalid-parameter-length` 错误和注册超时/拒绝消息。这不是工作的 LTE 数据会话，因此当时未启动负载。无调制解调器配置被检查或更改。较晚活动承载测试记录于 §2.6。现有
[`run_load_test.sh`](../../scratch/thermal_baseline/run_load_test.sh) 未使用，因为它在采样期间重复请求 50 MB 下载并将 CSV 写到目标路径；其请求循环对高速会话无实际字节上限。一个单独的
[实况比较说明](./HMU05_LIVE_OPENWRT_VS_ANDROID_COMPARISON.md)
报告 `wwan0` 空闲/未附着；较晚接口检查提供精确的每链路状态，但复现时接口快照仍应一起打时间戳。

稳压器类暴露 `s3`、`s4` 和 LDO，但无 `s2`/CPU 轨读回；OpenWrt CPU 电压仍未知。在所查询的 sysfs 路径未发现 KGSL 或 devfreq GPU 时钟端点，因此实况 GPU 时钟未测量。OpenWrt 的 `pm8916-thermal` 区域已启用，不同于捕获的 Android `pm8916_tz` 区域（已禁用）；不要将它们作为等效工作传感器比较。

仅作方向参考，OpenWrt 当前 TSENS 读数（HW ID 0/1/2/4/5 为 48/45/43/44/46 °C）接近或低于更早 Android 样本 A 值（49/45/44/45/47 °C）。它们**不是有效温度差**：快照在不同时间、不同设备时钟和未匹配负载、环境与功率条件下拍摄。当前 OpenWrt 快照实际上空闲且无可见调制解调器接口。

### 2.6 OpenWrt 活动 LTE 下行重测（2026-10-08 UTC）

上述更早无承载发现是历史性的。2026-10-08 上，调制解调器在 LTE 上注册 `home`，分组服务 `attached`，承载 2 在 `wwan0` 上连接，报告信号质量运行 1 为 91%、运行 2 为 88%。下文讨论的 CPU 压力进程在任一干净运行前完成；预检显示运行 1 上 97% CPU 空闲且两运行上无 `yes` 进程。BAM-DMUX 运行时状态保持 `active`。

每个干净运行使用相同只读测量程序：60 s 空闲基线每 5 s 采样；一个 Cloudflare 下行，响应上限 33,554,432 字节，以约 512 KiB/s 消耗；然后 120 s 冷却每 5 s 采样。两运行完整正文均耗时 71 s（约 3.78 Mbit/s 负载速率）。每块守卫会在调制解调器 TSENS 达到 80 °C 或任一 CPU TSENS 达到 73 °C 时停止传输；两个守卫均未触发。传输被流式并丢弃，无测试文件、配置或运行时设置写入设备。OpenWrt 频率策略在基线/负载窗口间在 400 和 800 MHz 间变化。运行 1 运行 11:12:57–11:16:59 UTC（下行 11:13:52–11:15:03）；运行 2 运行 11:22:00–11:26:02 UTC（下行 11:22:55–11:24:06）。

| OpenWrt 通道 | 运行 1 空闲范围 → 负载峰值 | 运行 2 空闲范围 → 负载峰值 | 高于该运行空闲最大值的峰值 |
|---|---:|---:|---:|
| `modem-thermal` (zone0 / TSENS 0) | 56–58 → 62 °C | 55–57 → 62 °C | +4 / +5 °C |
| `camera-thermal` (zone1 / TSENS 1) | 53–54 → 58 °C | 53 → 58 °C | +4 / +5 °C |
| `gpu-thermal` (zone2 / TSENS 2) | 52–53 → 57 °C | 51–52 → 57 °C | +4 / +5 °C |
| `cpu2-3-thermal` (zone3 / TSENS 4) | 52–54 → 58 °C | 52–53 → 58 °C | +4 / +5 °C |
| `cpu0-1-thermal` (zone4 / TSENS 5) | 54–56 → 60 °C | 54–55 → 60 °C | +4 / +5 °C |
| `pm8916-thermal` (zone5) | 45.779–46.712 → 51.767 °C | 45.288–46.074 → 51.423 °C | +5.1 / +5.3 °C |

两个重复在每个 SoC 通道上在 1 °C 内一致。冷却结束时，两运行调制解调器 TSENS 均为 57 °C。WWAN RX 计数器每运行增加约 35.4 MB，而测得正文恰好 32 MiB；接口计数器还包括传输/预读和后台流量。这些是短瞬态测试，非 10 分钟热平衡，且无环境温度、USB 输入功率、RSRP/RSRQ/SINR 或调制解调器发射功率测量被捕获。PM8916 通道仅对运行内趋势有用，且不等效于 Android 禁用的 `pm8916_tz` 传感器。原始样本保留于
[`openwrt_lte_retest_20261008.csv`](../../scratch/thermal_baseline/openwrt_lte_retest_20261008.csv)
和
[`openwrt_lte_retest_20261008_run2.csv`](../../scratch/thermal_baseline/openwrt_lte_retest_20261008_run2.csv)。

#### 排除的首次尝试：并发 CPU 压力

首次尝试不属于干净运行结果。其所谓空闲基线在下行开始前从约 61–63 °C 升至 74–75 °C；在短观察负载窗口期间，CPU 频率降至 200–400 MHz，温度达到 77 °C。较晚进程快照发现四个孤立 `yes` 工作进程消耗约 85–87% CPU（约 5.0 负载均值和 87% 用户 CPU）。用户确认这些是有意启动的进程并请求让它们运行至完成；它们未被停止。测试的 SSH 观察会话曾被中断，其下载子进程短暂比该连接存活更久。我在验证后仅向下载器管道 PID 发送 TERM；后续检查显示这些测试进程消失。用户的工作进程未被发信号。它们退出后，OpenWrt 在调制解调器区域冷却到 58 °C，CPU 区域 55–56 °C；上述干净重复随后开始。此事件无法将其 18–20 °C 上升归因于仅 LTE 负载，因为 CPU 压力和网络负载重叠。

### 2.7 Android 活动 LTE 下行重测 —— 保留的运行 2（2026-10-08 UTC）

**真相来源：** [`android_lte_retest_20261008_run2.csv`](../../scratch/thermal_baseline/android_lte_retest_20261008_run2.csv)。
更早的 Android CSV 按用户指示丢弃；下文发现中不使用其任何测量。

Android 在 JIO LTE 上注册 `home`，数据通过 `rmnet0` 连接。保留运行的电话快照报告 RSRP −95 dBm 和 RSRQ −14 dB。预检显示 97.7% CPU 空闲，无压力工作进程，采样频率字段中 CPU0 于 800 MHz。运行 2 运行 12:57:09–13:01:17 UTC，60 s 空闲基线和 120 s 冷却每 5 s 采样。它使用一个 Cloudflare 33,554,432 字节下行，限速 512 KiB/s。`curl` 使用现有 Android CA 证书通过内存进程替换验证 HTTPS；无 CA 包或其他文件写入设备。更早 curl 调用在传输数据前失败，因其编译进默认 CA 包路径缺失；该零字节尝试被排除。

保留传输返回 HTTP 200 且恰好 33,554,432 字节耗时 64.39 s（521,088 B/s，约 4.17 Mbit/s）。`rmnet0` RX 计数器通过最终负载样本上升约 35.4 MB；该计数器还包括协议开销和其他流量。保守守卫（调制解调器 TSENS 80 °C；CPU TSENS 4/5 73 °C）未触发。无设备配置、热策略或持久文件被更改。

| Android 通道 | 保留运行 2 空闲 → 峰值 | 高于空闲最大值的上升 | OpenWrt 运行 1 / 运行 2 峰值 | Android 峰值低于 OpenWrt 峰值 |
|---|---:|---:|---:|---:|
| TSENS 0 / 调制解调器 | 47 → 57 °C | +10 °C | 62 / 62 °C | 5 °C |
| TSENS 1 / 相机 | 44 → 53 °C | +9 °C | 58 / 58 °C | 5 °C |
| TSENS 2 / GPU | 42–43 → 53 °C | +10 °C | 57 / 57 °C | 4 °C |
| TSENS 4 / CPU2–3 | 44 → 53 °C | +9 °C | 58 / 58 °C | 5 °C |
| TSENS 5 / CPU0–1 | 45–46 → 55 °C | +9 °C | 60 / 60 °C | 5 °C |
| Android `pm8916_tz` | 37.674–38.017 → 48.600 °C | +10.6 °C | OpenWrt zone5: 51.423 / 51.767 °C | 不可直接比较 |

OpenWrt 基线在五个 SoC 通道上约暖 8–11 °C。Android 相对其基线变暖 +9–10 °C（对比 OpenWrt 的 +4–5 °C），而其绝对峰值低 4–5 °C。保留 Android 负载速率比 OpenWrt 的约 3.78 Mbit/s 高约 10%。这一个保留测试对这些短运行缩窄观察到的峰值差距，但不解释更早 +14–15 °C 结果或隔离 OS 效应。120 s 冷却在调制解调器 TSENS 50 °C 结束，约高于其基线 3 °C；该运行未达到热平衡。环境温度、USB 输入功率、LTE 频带、调制解调器 TX 功率和数值 OpenWrt RSRP/RSRQ 仍不可用。PMIC 通道仅作为运行内趋势保留。

---

## 3. 证据状态（根因尚未确定）

| 问题 | 当前可用证据 | 评估 |
|---|---|---|
| 是否存在温度差异？ | 存储 LTE 捕获在五个 TSENS 传感器上约 +12 °C 均值和 +14–15 °C 峰值不同，但未完全匹配。两个干净 OpenWrt 32 MiB 下行相对基线上升 +4–5 °C。保留 Android 运行 2 上升 +9–10 °C；其绝对 TSENS 峰值低于 OpenWrt 4–5 °C。 | 保留短运行缩窄观察到的峰值差距，但 Android 开始低 8–11 °C 且运行快约 10%。它不确立受控 OS 差值或解释更早结果。 |
| 是否 TSENS 转换是成因？ | Android 和 OpenWrt 源码使用相同 MSM8916 传感器 ID、校准字段和转换锚点。运行时系数/原始码未比较。 | 不太可能，但未完全关闭。不要添加温度偏移。 |
| Android 是否热节流调制解调器/PA？ | 恢复默认不监测 `pa_therm0`；160 s LTE 轨迹中无调制解调器动作；`fusion` 在观察温度下未激活。 | 不支持作为负载差距解释。不要从此证据移植调制解调器节流策略。 |
| Android 热策略是否不同？ | 轨迹在 CPU0–1 TSENS 55 °C 记录 GPU 310→200 MHz。WLAN 的 60 °C 动作和 CPU `ss` 限制未达到。 | GPU 策略是测试候选；其对整机温度的贡献未知。 |
| CPU 电压是否解释差异？ | Android `8916_s2` 在一个快照读 1.05 V。OpenWrt CPU 轨电压在匹配 OPP/负载下未测量。 | 开放问题。报告的 Android 值不验证固定 OpenWrt 电压或安全 OPP 值。 |
| CPU 空闲驻留是否解释它？ | Android CPU0 在一次捕获中报告约 81.5% 在 `pc`。OpenWrt CPU0 计数器约 10 分钟显示约 590 s 在 `standalone-power-collapse` 和 13 s 在 WFI；仅暴露两个状态。 | OpenWrt 停留在 WFI 的声明被快照反驳。状态定义/轨效应未证明等效；归因热前比较匹配的计数器差值。 |
| `modem-a2-hold` 是否是负载成因？ | Android 存储空闲捕获保持 A2 开，匹配更早 OpenWrt 钉住样本；钉住/未钉住空闲差约 2.8 °C。OpenWrt 先是 `auto`/`suspended`，后 `on`/`active`；后者检查时调制解调器搜索中且 WWAN 链路关闭。 | 不支持作为空闲差距成因；当前/历史状态不同且无 LTE 负载比较存在。不要作为温度实验更改 A2/运行时 PM 状态。 |
| 热跳闸是否负责？ | Android `msm_thermal` 运行时禁用。OpenWrt 的 60 °C 跳闸实验未降低峰值 TSENS 且将 RX 吞吐量降低约 37%。 | 无新证据时不要作为温度修复降低跳闸。 |
| 无线电和测试条件是否受控？ | 保留 Android 运行使用 `rmnet0` 上 JIO LTE，RSRP −95 dBm / RSRQ −14 dB，32 MiB 于 4.17 Mbit/s。OpenWrt 使用 32 MiB 于约 3.78 Mbit/s 且报告信号质量 91%/88%，与数值 RSRP/RSRQ 不可比。环境温度、输入功率、LTE 频带和调制解调器 TX 功率未捕获。 | 保留运行是有用对应，但非完全匹配对：起始 TSENS 低 8–11 °C，达成速率不同，且数值 OpenWrt 无线电值缺失。归因前匹配这些条件。 |

关于源/工件细节和实况 thermal-engine 轨迹，见
[调和的根因报告](./HMU05_OPENWRT_ANDROID_THERMAL_ROOT_CAUSE.md) 和
[Android 策略/轨迹说明](../../scratch/thermal_baseline/android/README.md)。

---

## 4. 证据优先行动计划

**状态：提议；无热设置已更改。** 本计划是诊断优先。它不承诺 8–12 °C 降低，因为无干预已证明该收益。

### 步骤 0 —— 保留干净基线

- 精确保留设备设置。最新快照报告 BAM-DMUX `power/control=on` / `runtime_status=active`（更早快照报告 `auto`/`suspended`）；不要标准化或切换它。不要启动/停止 A2 引脚（[补丁 848](../../msm89xx/patches/848-bam-dmux-a2-pin.patch)，以前为 `modem-a2-hold`），更改 Wi-Fi，或为此比较更改任何运行时电源设置。
- 不要添加固定 `opp-microvolt` 值、降低热跳闸、热插拔 CPU、添加调制解调器 QMI策略，或作为温度实验禁用 A2 变通。
- 每次运行记录两个 OS 镜像/内核修订、调制解调器固件、设备身份、环境温度、外壳/气流和电源详情。

### 步骤 1 —— 完成匹配的 Android/OpenWrt 比较（OpenWrt 两次；Android 运行 2 保留）

- OpenWrt 有两次干净注册 LTE 32 MiB 运行。Android 运行 2 是唯一保留 Android 数据集；其温度相对基线上升 +9–10 °C，开始低 8–11 °C，在 4.17 Mbit/s vs OpenWrt 约 3.78 Mbit/s 下峰值低于 OpenWrt 4–5 °C。运行 1 的 Android CSV 按用户指示丢弃。剩余比较未匹配起始温度或无线电条件；污染的 OpenWrt 尝试也仍排除。
- 任何进一步运行前，确认无无关 CPU 压力工作进程；污染尝试显示不受控 CPU 负载使明显空闲基线无效。
- 使用相同 HMU05、SIM、运营商/APN、USB 电源、外壳和物理设置。OS 间重启，但将每次运行预调到相同起始 TSENS 范围（目标 1 °C 内）。
- 将空闲、LTE 下行和 LTE 上行作为单独场景测试。在两 OS 上使用相同流量生成器、方向、字节数和目标速率；记录达成吞吐量而非假设运行等效。
- 负载开始后以 1–2 s 间隔捕获至少 10 分钟。持续直到滚动五分钟 TSENS 斜率低于 0.1 °C/min，或 30 分钟停止并将未稳定运行标记为瞬态。不要将启动预热或冷却瞬态作为稳态值比较。
- 至少重复三个 Android/OpenWrt 对，实际时交替顺序。保持环境条件和起始温度可比；记录任何偏差。

### 步骤 2 —— 在两系统收集相同信号

- 读取 TSENS 硬件 ID 0、1、2、4 和 5（并记录 sysfs 区域映射），外加 SoC 和 PA 屏蔽上的独立热电偶/IR 读数。不要将禁用的 Android PMIC 区域视为等效 SoC 温度。
- 测量 USB 输入电压/电流并计算运行期间输入功率/能量。记录 LTE 频带、RSRP/RSRQ/SINR（可用时）、调制解调器 TX 功率/热状态、流量方向、字节和吞吐量。
- 记录 CPU 在线状态、当前/最大频率、调控器，以及测量窗口内每个 cpuidle 状态的 `time`/`usage` 计数器**差值**。同间隔记录 GPU 频率/利用率和 thermal-engine 消息/动作。
- 不更改 `power/control` 记录 A2 状态/遥测。在 OpenWrt 上，用支持的运行时读回或安全仪表测量空闲和每个测试 OPP 的 CPU 轨；不要仅从无 DTS `cpu-supply` 推断 1.15–1.25 V。
- 保留原始样本、命令行、时间戳和环境说明与摘要一起。

### 步骤 3 —— 决定哪个单变量值得实验

- 若匹配比较显示 OpenWrt 上等效深度空闲状态驻留显著更低，调查 PSCI/空闲状态进入和固件协调。当前原始状态名/计数器不直接等效；不要添加 CPU 热插拔作为测量空闲的替代。
- 若相同 OPP 和工作负载下存在可重复 CPU 轨电压差异，先验证稳压器拓扑、硅角需求和主线驱动路径。任何 OPP/CPR 更改需要表征的安全电压限制、构建/启动验证和回滚镜像；绝不将 Android 单点 1.05 V 读回复制到每个 OpenWrt OPP。
- 若 GPU 利用率/功率不同，测试临时、可逆的 GPU 限制，类似观察到的 Android 200 MHz 动作，带迟滞和性能日志。仅当配对运行显示可重复热/功率收益且无不可接受吞吐量或图形影响时保留它。
- 仅当 Wi-Fi 在测试中活动且实际无线电功率被测量时，将 Wi-Fi TX 功率调谐视为相关。UCI 值或假设的 20 dBm 默认不证明耗散热。
- 将 BAM-DMUX/A2 静止修复视为单独调制解调器稳定性项目。其独立修复后，可在调制解调器压力下测试运行时 PM；不要预先清除 A2 引脚（`echo 0 > /sys/module/qcom_bam_dmux/parameters/a2_pin`；以前为已移除的 `modem-a2-hold`）或将未测量的温度变化计为预期结果。

除非受控测试显示安全或热控制需求，否则不要更改热跳闸。现有 60 °C OpenWrt 跳闸实验施加大量吞吐量惩罚而未降低测得峰值，因此跳闸降低不是当前温度补救措施。

### 步骤 4 —— 以可重复结果门控实现

一次更改一个子系统，保留已知良好回滚镜像/配置，并重复相同配对场景。仅当温度或输入功率改善在运行间变化之外可重复，且调制解调器稳定性、吞吐量、CPU/GPU性能和热保护保持可接受时接受更改。报告测得结果；不要预先分配 °C 收益。
