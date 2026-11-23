# HMU05：OpenWrt vs Android 热差异 —— 源码审计、实况 Android 策略与发现

**日期：** 2026-10-08
**范围：** 比较存储的 HMU05 OpenWrt 和原厂 Android 测量、用户指定的 Android 内核、以及 OpenWrt 6.12.94 构建树的热/DT 实现，并记录 2026-10-08 收集的实况 Android 策略/轨迹证据。这始于源码和工件审计；现在还包括只读实况设备观察（一个 160 s LTE 负载轨迹和点检）。

**源修订：** Android 内核分支 cm-11.0 于 c5dd03a3；OpenWrt 构建树内核版本 6.12.94。

> **注（2026-10-10）—— A2 引脚现在在驱动中，而非用户空间。** 下面引用的
> 用户空间 `/usr/sbin/modem-a2-hold` 辅助工具已**移除**。A2
> 引脚现由 `qcom_bam_dmux` 驱动在设备树设置 `qcom,a2-pin` 的板上保持
> （HMU05；补丁 848/849）；用
> `echo 0|1 > /sys/module/qcom_bam_dmux/parameters/a2_pin` 切换它。下文对
> `modem-a2-hold` 的引用描述的是更早的用户空间机制。

## 结论要点

源比较**不**支持 OpenWrt TSENS 转换中 15 °C 错误。Android 和 OpenWrt 使用相同 MSM8916 TSENS 硬件传感器 ID、相同 QFPROM 校准字段、相同 30/120 °C 锚点、以及实质上相同的斜率/截距转换。单位归一化和整数舍入太小，无法解释 15 °C 差值。

存储测量显示**负载相关**差异：比较 `android_load.csv` 与 `owrt_load_control.csv`（每个约 4 分钟 LTE 负载），OpenWrt 在五个匹配 TSENS 传感器上平均约 **12 °C 更热**，峰值差 **14–15 °C**。保存的空闲运行反而根据使用哪个 OpenWrt 捕获而相差约 **3–7 °C**；所有保存空闲捕获在采样窗口内冷却。因此更早报告声称的稳定、均匀 +15 °C 空闲偏移不被其原始 CSV 支持。

要测试的主要解释是调制解调器负载下**真实的功率/热管理差异**，尤其是 Android 的 Qualcomm thermal-engine 路径。该路径现已**部分解决**：设备**无 `thermal-engine.conf`** —— 守护进程运行**编译进默认值**，其唯一调制解调器缓解（`fusion`，通过 QMI）在 **105 °C** 触发，即在观察到的约 62 °C 下未激活；其实用温度下的活动动作是 GPU（55 °C）、WLAN（60 °C）和 CPU `ss` 控制（78–85 °C）。因此调制解调器功率缓解线索**减弱**；剩余负载差距候选是 CPU/GPU/WLAN 策略差异和无线电/TX 条件。LTE 信号/TX 条件和精确负载速率也未并排记录。

**推荐处置：** 不要添加笼统 −15 °C 偏移，不要更改 TSENS 校准，不要作为温度修复降低 OpenWrt 热跳闸。恢复的 Android 策略和 LTE 轨迹**排除调制解调器/PA 热缓解差异**作为负载差距成因（无 `thermal-engine.conf`；`fusion` 在 105 °C 以下未激活；无运行时配置推送；无调制解调器动作观察），因此**不要**构建调制解调器节流等效物。实施任何更改前运行受控、稳态配对 A/B 以隔离剩余候选 —— GPU/CPU 策略、无线电/TX 条件和轨/功率输入。

## 存储数据实际说什么

下方比较使用 android_load.csv（120 行，启动 578–829 s）和 owrt_load_control.csv（120 行，启动 2045–2300 s）中五个 TSENS 通道的均值和最大值。采样名义每两秒一次，因此每个窗口约 4.2 分钟。捕获窗口时长相似，但未同步且未证明具有相同 LTE 吞吐量、无线电条件、环境温度或起始温度。

| 硬件传感器 / 采样器名 | Android 均值 / 最大 | OpenWrt 均值 / 最大 | 均值差 | 峰值差 |
|---|---:|---:|---:|---:|
| 0 / 调制解调器 | 59.25 / 62 °C | 71.03 / 76 °C | +11.78 °C | +14 °C |
| 1 / 相机 | 55.70 / 58 °C | 67.98 / 73 °C | +12.28 °C | +15 °C |
| 2 / GPU | 55.08 / 58 °C | 67.11 / 72 °C | +12.03 °C | +14 °C |
| 4 / CPU2–3 | 55.03 / 58 °C | 66.88 / 72 °C | +11.85 °C | +14 °C |
| 5 / CPU0–1 | 56.88 / 60 °C | 69.40 / 75 °C | +12.52 °C | +15 °C |

五个晶粒传感器上的近均匀上升指向热生成或运行条件的广泛差异，而非一个错误标记的热传感器。然而这些是片上 TSENS 读数 —— 非外壳或表面温度测量。捕获工件中无独立热电偶/IR 参考。

空闲证据实质不同：

| 捕获 | 传感器 0 均值 | 传感器 5 均值 | PMIC 通道均值 | 说明 |
|---|---:|---:|---:|---|
| android_idle.csv，30 行 | 55.7 °C | 54.1 °C | 45.5 °C | 启动 516–578 s；捕获期间温度下降 |
| owrt_idle_unpinned.csv，60 行 | 58.9 °C | 57.1 °C | 48.5 °C | 启动 4600–4725 s；捕获期间温度下降 |
| owrt_idle_pinned.csv，30 行 | 61.7 °C | 59.8 °C | 51.9 °C | 启动 4008–4070 s；非配对运行 |

Android 对未钉住 OpenWrt 均值在 TSENS 上约 +2.7 至 +3.6 °C；Android 对另一 OpenWrt 空闲文件约 +5.2 至 +7.0 °C。这些是短冷却瞬态，无环境/起始状态日志，非平衡空闲基线。它们不能证明空闲时 +15 °C。

**测量可比性注意事项：** OpenWrt 的 run_load_test.sh 记录其有界 Cloudflare 下载循环。android_thermal_sample2.sh 仅是采样器；收集的文件不含等效 Android 负载运行器、吞吐量、LTE 频带、RSRP/RSRQ、调制解调器发射功率或输入功率。Android 负载 CSV 有累计 skb 计数器，但非匹配吞吐量记录。OpenWrt 对照也允许 998.4 MHz 采样，而 Android 样本报告 800 MHz；800 MHz OpenWrt 上限后来被测试，但无来自同一测试会话的配对 Android 运行。这些差异阻止将全部热差距归因于一个软件策略。

PMIC 数字不应作为苹果对苹果温度比较。Android 报告 pm8916_tz 且捕获区域转储中 mode=disabled。检查的 OpenWrt MSM8916 DTS 无 pm8916-thermal 区域，尽管 OpenWrt 采样器搜索一个。CSV 的 pm8916 列的源/映射因此需要在用作佐证前于精确运行时镜像上验证。

## TSENS 源比较

| 区域 | Android 源 | OpenWrt 构建源 | 评估 |
|---|---|---|---|
| 传感器映射 | msm8916.dtsi 声明五个 TSENS 通道，斜率 3200，ID 0、1、2、4、5 | tsens-v0_1.c 有 MSM8916 硬件 ID 表 {0,1,2,4,5}；板 DTS 为模式/基提供 NVMEM 单元和相同五个传感器校准点对 | 相同物理通道和熔丝数据布局 |
| 校准 | msm8974-tsens.c 读取 MSM8916 QFPROM 校准字并提取每传感器点 1/2；锚点常数为 30 和 120 °C，比例因子为 1000 | tsens-v0_1.c 调用 tsens_calibrate_nvmem(priv, 3)；tsens.c 解码相同 MSM8916 位字段并计算相同两点斜率/截距 | 未识别源级 15 °C 偏移 |
| 温度转换 | 用每传感器斜率/截距转换 ADC 码并舍入到整数 °C | 使用相同整数 °C 转换然后向热核心返回毫度 | 单位/舍入至多可解释亚度/整数度差异，非 15 °C |
| 设备树身份 | Android TSENS compatible qcom,msm8916-tsens；传感器 ID 显式 | OpenWrt compatible qcom,msm8916-tsens 加 qcom,tsens-v0_1；NVMEM 单元按硬件传感器 ID 命名 | 两个 DT 都描述 MSM8916 TSENS 而非不同传感器 |

这是源和构建 DT 描述的比较。它**尚未**证明两个运行时内核都选择了预期 HMU05 DTB、成功读取相同实际熔丝值、或报告相同实况有效系数。所选 DTB、TSENS 原始 ADC 值和有效斜率/截距（或等效驱动调试输出）的运行时捕获是最终校准健全性检查。尽管如此，校准缺陷现在比真实的板功率或热策略差异更低概率。

有用的审阅行锚点：Android MSM8916 TSENS DT 是 msm8916.dtsi:258–266；Android 校准是 msm8974-tsens.c:1196–1316，码到温度转换在 :590–608。OpenWrt MSM8916 熔丝位布局是 tsens-v0_1.c:26–45，校准入口点是 :86–116；共享斜率/截距和转换是 tsens.c:259–348。OpenWrt 硬件传感器 ID 表是 tsens-v0_1.c:353–370，熔丝单元/TSENS NVMEM 映射是 msm8916.dtsi:480–578，热区域在 :2640–2750。

检查的 OpenWrt 树是构建的 Linux 6.12.94 树于 GitIgnore/compare/openwrt/build_dir/target-aarch64_generic_musl/linux-msm89xx_msm8916/linux-6.12.94。其 MSM8916 DTS 包含 PSCI CPU 空闲和簇空闲状态（msm8916.dtsi:202–228），且其构建配置启用 CPU_IDLE 和 ARM_PSCI_CPUIDLE（.config:547、558–559）。因此"OpenWrt 无深 CPU 空闲支持"不是有效的源级解释。实际驻留和轨状态仍需测量。Android 使用其下游 msm_idle/功率收起实现；任一方的源支持都不证明测试中输入了状态。

## 热策略差异与最强线索

Android DT 的 msm-thermal 节点每 250 ms 轮询，并在 60 °C 配置硬件传感器 5 上的 CPU 频率限制，加 80 °C 核限制。OpenWrt 主线 DT 将 CPU 传感器 5 和传感器 4 映射到 75 °C 被动 CPU 冷却跳闸；调制解调器传感器 0 区域是 85 °C 热跳闸且无调制解调器冷却动作。这是真实策略差异，但保存 Android 负载样本显示 CPU 当前/最大频率 800 MHz 且不记录明显降频事件。更早 OpenWrt 杠杆测试将 CPU 跳闸降至 60 °C 并强制大量 CPU 节流；调制解调器峰值保持 76 °C 而 RX 吞吐量下降约 37%。这使 CPU 跳闸调谐单独成为多传感器差距的不令人信服解决方案。

Android 有一个额外厂商路径，在检查的 OpenWrt 源工件中未找到等效物：

- init.target.rc 启动 /system/bin/thermal-engine，且捕获的 Android 属性显示其运行中。
- 捕获的 lsof 转储显示 thermal-engine 持有 /sys/devices/soc.0/qpnp-vadc-de70d000/pa_therm0 打开（实况设备节点是 `qpnp-vadc-de6e5000` —— 相同 PA 通道，构建特定地址；确认在实况设备上作为 fd 29 打开）。Android DTS 将该 PA 热敏电阻定义为 PM8916 VADC 通道。
- 原厂 thermal-engine 二进制的本地逆向说明包含 /system/etc/thermal-engine.conf 路径、TSENS/PMIC/pa_therm0 传感器名、QMI 热服务引用、以及调制解调器缓解成功/失败日志字符串。

**★ 恢复的配置（2026-10-08，实况设备）。** 设备上**无 `thermal-engine.conf` 文件**
（原厂 `system.bin` 中也没有）—— `/system/etc/thermal-engine.conf` 缺失，且
守护进程在启动其**编译进默认值**前记录 `open: No such file or directory`。有效
配置用二进制自身的 `-o` 转储（见
[scratch/thermal_baseline/android/](../../scratch/thermal_baseline/android/README.md)）：

```
[SS-POPMEM]  ss  sensor pop_mem  set 78/clr 73 °C          -> cpu
[SS-CPU2-3]  ss  sensor cpu2-3   set 85/clr 55 °C          -> cpu
[SS-CPU0-1]  ss  sensor cpu0-1   set 85/clr 55 °C          -> cpu
[CX_MITIGATION_MONITOR_TSENS4] monitor sensor cpu0-1
             thresholds 55/60/105 °C  clr 50/55/101 °C
             actions fusion+gpu / fusion+gpu+wlan / gpu+wlan+fusion
             action_info 0+200000000 / 0+200000000+0 / 200000000+0+1
[CPU2-3_MONITOR] monitor cpu2-3  116/108 °C -> shutdown
[CPU0-1_MONITOR] monitor cpu0-1  116/108 °C -> shutdown
```

这实质改变线索：`fusion` 动作**是**通过 QMI 的调制解调器热缓解
（`ACTION: FUSION - Fusion modem mitigation succeeded for level %d`），但在此配置中其级别
是 **55/60 °C 处 0，仅 105 °C 处 1** ⇒ **调制解调器/PA 缓解在观察到的
板温下实际上未激活**（Android 峰值 ≈ 62 °C）。配置设置**GPU 频率限制
（55 °C →200 MHz）**和**60 °C WLAN 动作**；其 CPU/pop_mem `ss` 控制目标
78–85 °C。值得注意的是 `pa_therm0` 被守护进程打开，但**不是活动配置中的受监测传感器**，
且调制解调器传感器 `tsens_tz_sensor0` 完全未被监测。

因此"Android 从 PA 热敏电阻节流调制解调器/PA"假设**不受恢复配置支持**。一个 **160 s 实况 LTE 负载轨迹**（2026-10-08）确认它：CPU0–1 峰值仅 58 °C，因此**唯一触发的动作是 GPU 限制（55 °C 310→200 MHz）** —— WLAN、CPU `ss` 和调制解调器 `fusion` 从未触发。轨迹也显示**无运行时配置推送**（无 `Config set` 活动，无热客户端套接字上的客户端），因此运行的是编译进默认值。无线电/TX 条件和功率输入/轨功率差异仍是未测量的替代项。

**额外实况点检（2026-10-08 09:10 UTC，对 `192.168.100.1` 的只读 SSH）。** `thermal-engine`（PID 208）和 `mpdecision`（PID 1201）均运行，而 `/sys/devices/system/cpu/online` 报告 `0-3` 且每个 CPU 的 `online` 节点报告 `1`。CPU0 的累计 cpuidle 计数器对 `standalone_pc`（状态 1：3,873 次进入）和 `pc`（状态 2：105,760 次进入）非零，以及 WFI（状态 0：48,008 次进入）。这是单快照加累计计数器：它显示该时刻四核在线并证明这些空闲状态已被进入，但不确立其在存储 OpenWrt 比较工作负载下的当前驻留或行为。

同一快照中，Android TSENS 硬件传感器 0/1/2/4/5 读 50/46/44/47/48 °C；`pm8916_tz` 为 39.486 °C，电池 33 °C。PA VADC sysfs 节点 `/sys/devices/soc.0/qpnp-vadc-de6e5000/pa_therm0` 返回 `Result:36 Raw:7b49`。活动热策略仍不将此 PA 通道列为受监测输入。当前日志缓冲无 `ThermalEngine` 行，因此此点检不添加新事件证据；单独 160 s LTE 轨迹仍是有用动作轨迹。一起，运行时检查直接反驳提案的绝对声明，即 `mpdecision` 保持 CPU 1–3 离线，但不排除它在其他时期热插拔它们的可能性。

证据锚点：Android 在 init.target.rc:148 启动 thermal-engine，且捕获属性显示其运行于 05_subsystems_and_properties.txt:77。lsof 捕获在 18_lsof_and_sockets_dump.txt:496 列出 pa_therm0；Ghidra 说明包括 :7450 的配置路径、:7648–7649 的 PA/PMIC 传感器名、:7947–7949 的调制解调器缓解成功/失败字符串。Android PA VADC 通道是 msm8916.dtsi:1803；PM8916 热报警 DT 节点是 msm-pm8916.dtsi:175–185。

| 发现 / 假设 | 置信度 | 为何 |
|---|---|---|
| 保存 OpenWrt 负载运行比保存 Android 负载运行更热 | 对这些捕获高 | 所有五个 TSENS 通道显示约 +12 °C 均值和 +14–15 °C 峰值；条件未完全匹配 |
| OpenWrt 有系统 +15 °C 空闲偏移 | 已拒绝 | 原始空闲均值 +3–7 °C，且所有空闲轨迹在采样期间冷却 |
| TSENS 转换/校准代码产生 +15 °C 差值 | 低可能性 | 相同传感器 ID、熔丝位布局、校准锚点和转换数学；实况系数/原始码仍需确认 |
| Android 热策略解释大部分负载差值 | **GPU 动作观察；因果效应未知** | 恢复默认和 LTE 轨迹显示 GPU 在 CPU0–1 TSENS 55 °C 从 310 限制到 200 MHz。WLAN 的 60 °C 动作和 CPU `ss` 控制在 78–85 °C 未达到；`fusion` 是 55/60 °C 级别 0，仅 105 °C 级别 1。无调制解调器缓解或运行时配置推送发生；这些观察不量化 GPU 动作的温度效应 |
| CPU 跳闸点差异单独解释差值 | 作为唯一成因不太可能 | OpenWrt 的 60 °C 跳闸测试未降低调制解调器峰值且付出吞吐量代价；所有传感器通道一起移动 |
| 缺失 CPU 深度空闲支持是空闲解释 | 不被源支持 | OpenWrt 有 PSCI CPU/簇空闲状态和 CPU 空闲驱动启用；实际驻留仍未测量 |

## 提议的解决方案与验证

### 解决方案设计 —— 证据优先；提议，未实施

**不要**从当前证据实施 OpenWrt 调制解调器/PA 热管理器。恢复的 Android 默认不监测 `pa_therm0`；其 `fusion` 缓解级别在 55/60 °C 阈值为 0，仅 105 °C 级别 1，而 LTE 轨迹在板传感器上峰值约 62 °C。轨迹也显示无运行时配置推送或调制解调器动作。因此将此策略复制为 QMI 调制解调器节流解决方案将不受支持。不要更改 TSENS 校准、添加推测性 CPU 热插拔、降低热跳闸、更改电压表、或清除 A2 引脚（`echo 0 > /sys/module/qcom_bam_dmux/parameters/a2_pin`；以前为 `modem-a2-hold`）作为此证据上的温度修复。

当前推荐是实施前**受控、配对 A/B**。存储 LTE 捕获显示真实、广泛的片上温度差异，但其无线电/负载/环境条件未充分匹配以归因其成因。Android 轨迹确立一个值得隔离的较窄候选：CPU0–1 TSENS 达 55 °C 时 GPU 频率从 310 降至 200 MHz；WLAN 的 60 °C 动作在该轨迹未触发，且无调制解调器缓解触发。这是策略行为证据，而非 GPU 动作解释多传感器温度差距的证据。

推荐顺序：

- 在同一设备、电源、SIM/网络和受控流量模式上重复配对 Android/OpenWrt 测试。尽可能匹配起始/环境温度、频带和信号；记录相同字节数和吞吐量，并允许稳态间隔。
- 在两系统记录匹配 TSENS 通道、USB 输入电压/电流、LTE 频带和信号度量、流量方向/速率、CPU 在线/频率和空闲状态计数器、GPU 时钟、以及相关 thermal-engine 日志。此基线期间保持现有 OpenWrt 热策略和调制解调器 A2 变通不变。
- 若差距持续，用可逆单变量测试隔离 GPU、CPU/空闲、无线电 TX 和轨功率贡献。仅然后设计范围狭窄的策略更改，先验证其温度源、阈值、动作语义、迟滞和回滚行为。
- 保留固件和调制解调器热保护。不要仅从打开文件描述符推断 PA 缓解，或从二进制嵌入的字符串推断运行时策略。

基线期间保持 OpenWrt 现有 75 °C CPU 被动跳闸、当前 OPP 设置和 A2 引脚（`/sys/module/qcom_bam_dmux/parameters/a2_pin`；以前为 `modem-a2-hold`）不变。保存的 60 °C CPU 跳闸实验未实质降低峰值 TSENS 且施加大量吞吐量惩罚。A2 变通是调制解调器稳定性措施；仅在独立 BAM-DMUX 静止故障修复和验证后移除它。

### 实施前验证

1. **运行真正配对的 A/B。** 使用相同 HMU05 板、电源、SIM/APN、调制解调器固件和运营商配置；保持环境温度和气流固定；从匹配板温启动每个运行；实际时使用相同 LTE 频带/信号并传输相同字节数于受控速率。等待平衡并记录至少 10 分钟。记录两个 TSENS 集合、SoC 和 PA 屏蔽上的独立热电偶/IR 点、USB 输入电压/电流或总功率、LTE 吞吐量、RSRP/RSRQ/频带、CPU 频率和 cpuidle 驻留。

2. **捕获 Android 的运行时策略证据。** 活动配置已从运行二进制的 `-o` 转储器恢复；`/system/etc/thermal-engine.conf` 缺失。通过完整匹配测试捕获日志和状态，包括 GPU/WLAN 动作和任何调制解调器缓解级别。关键测试是哪些策略动作实际发生以及是否有任何与降低输入功率或温度相关。

3. **验证 OpenWrt 运行时校准和传感器来源。** 确认确切启动的 HMU05 DTB 和 TSENS 探测/校准成功。可能的话捕获两 OS 上的原始 TSENS 码加有效斜率/截距。识别采样器 pm8916-thermal 区域的运行时提供者；在此之前，从跨 OS 结论排除该系列。

4. **每个更改以证据门控。** 若 Android 在相关负载期间无调制解调器缓解请求 —— 如同捕获的 160 s 轨迹 —— 不将调制解调器缓解实现为解释。用配对测量选择下一步测试哪个单子系统。

5. **对照相同对照评估任何打补丁的 OpenWrt 构建。** 要求负载温度差距在运行间噪声之外可重复降低，同时检查吞吐量和调制解调器稳定性/SSR 事件。保持 CPU 跳闸和 OPP 不变，使结果隔离被测单变量。

## 更正后的发现

今日最佳证据支持答案是：**OpenWrt 在存储的 LTE 负载捕获中确实运行更热，但所谓的 +15 °C 空闲偏移是对瞬态数据的误读。TSENS 转换/校准 bug 不太可能。Android 调制解调器/PA 缓解假设不被恢复的编译进配置或 160 s LTE 轨迹支持：`fusion` 在观察温度下未激活，且无运行时配置推送发生。轨迹确实显示 55 °C 时 GPU 限制，而 WLAN 未达其 60 °C 触发。当前点检也发现全部四个 Android CPU 在线，`mpdecision` 运行，且 `standalone_pc`/`pc` 空闲计数器非零。CPU/GPU 策略和无线电/TX 或功率输入差异仍是候选，非已证明成因；下一步是受控配对 A/B，而非推测性策略移植。**

这取代 HMU05_ANDROID_THERMAL_CONTROL_PORT.md §3 中的基线声明及其均匀 +15 °C 空闲上升证明 DDR/fabric 功率是成因的推断。它同样取代稳定的 +15 °C 空闲前提和 [HMU05_THERMAL_RESEARCH_AND_PROPOSAL.md](HMU05_THERMAL_RESEARCH_AND_PROPOSAL.md) 中的排序幅度表（见上方调和）。两个更早报告对 CPU 跳闸实验仍有用，但对空闲基线/根因结论则不然。

## 与更早提案（HMU05_THERMAL_RESEARCH_AND_PROPOSAL.md）的调和

更早报告 [HMU05_THERMAL_RESEARCH_AND_PROPOSAL.md](HMU05_THERMAL_RESEARCH_AND_PROPOSAL.md)
得出结论 OpenWrt 空闲时比 Android 稳定高 **+15 °C** 并排序六个复合根
因。重读其自身原始 CSV（此处重算，每个捕获窗口的均值 °C）不
支持该结论。本节逐因裁定该报告，以便两份文档可以
一起阅读。

### 已验证测量矩阵（均值 °C；TSENS 通道 → 采样器标签）

| 捕获 | 窗口（s） | 调制解调器/0 | 相机/1 | gpu/2 | cpu23/4 | cpu01/5 |
|---|---:|---:|---:|---:|---:|---:|
| android_idle.csv | 516–578 | 55.70 | 52.30 | 50.70 | 52.60 | 54.10 |
| android_load.csv | 578–829 | 59.25 | 55.70 | 55.08 | 55.02 | 56.88 |
| owrt_idle_unpinned.csv | 4600–4725 | 58.90 | 55.78 | 54.28 | 55.28 | 57.07 |
| owrt_idle_pinned.csv | 4008–4070 | 61.73 | 58.70 | 57.67 | 57.83 | 59.80 |
| owrt_idle_c1.csv | **159–221** | 69.47 | 66.13 | 66.00 | 64.70 | 67.17 |
| owrt_load_control.csv | 2045–2300 | 71.03 | 67.97 | 67.11 | 66.88 | 69.40 |
| owrt_load_c1.csv | **221–484** | 75.66 | 72.33 | 71.88 | 70.89 | 73.62 |
| owrt_load_pinned.csv | 4080–4336 | 72.33 | 69.29 | 68.42 | 68.12 | 70.73 |

OpenWrt − Android 差值（同列）：**负载对照 +11.8/+12.3/+12.0/+11.9/+12.5**；
负载钉住 +13.1/+13.6/+13.3/+13.1/+13.9；**空闲未钉住 +3.2/+3.5/+3.6/+2.7/+3.0**；
空闲钉住 +6.0/+6.4/+7.0/+5.2/+5.7。

两个捕获族**不是有效基线**，必须从任何"+15 °C"声明排除：

- `_c1` 捕获位于启动 **159–221 s（空闲）**和 **221–484 s（负载）**—— 即
  新启动后的最初几分钟内，板卡仍在变暖。`owrt_idle_c1` 在其窗口内从
  67→71 °C 上升（启动预热），其"对 Android 空闲 +12–15 °C"是预热，
  而非空闲偏移。
- 其他每个空闲捕获在其窗口内**冷却**（android_idle 59→52 °C；owrt_idle_unpinned
  61→56 °C；owrt_idle_pinned 64→61 °C）。下降轨迹是瞬态，而非平衡空闲
  基线，因此它也不能确立稳定偏移。

报告的执行摘要图（"OpenWrt 空闲于 65–70 °C"）匹配启动预热
瞬态，而非存储的近乎稳定空闲捕获（钉住 61.7 °C，未钉住 58.9 °C）。

### 逐因裁定

| 报告排名 | 声明 | 裁定 | 证据 |
|---|---|---|---|
| 1 | Android 空闲时将 A2 收起为深睡；OpenWrt 钉住它 → **+5–7 °C** | **前提驳斥；幅度夸大；非差距成因** | android_idle.csv 保持 `a2_out=30`、`a2_in=28`、`a2_pwr=30` **恒定**（整个窗口 0 次转换）⇒ Android 空闲时保持 A2 **开** —— 与 OpenWrt 的 `modem-a2-hold` 引脚相同状态。测得钉住−未钉住空闲差约 **+2.8 °C**（调制解调器通道），非 +5–7。因为 Android 处于钉住状态，该引脚是*对等*，而非偏差，不能解释 OpenWrt−Android。 |
| 2 | `mpdecision` 保持 CPU1–3 离线 → **+3–4 °C** | **对记录时期矛盾；未确立所有时间** | android_idle.csv 和 android_load.csv 报告 `f0..f3 = 800000`；实况 2026-10-08 快照同样发现 `mpdecision` 运行且 CPU 0–3 在线。这不排除其他时期热插拔。无证据支持所声称的热影响。也不可 DT 移植：主线无 CPU 热插拔冷却设备（见 CONTROL_PORT 杠杆 2b）。 |
| 3 | 无 CPR/动态电压缩放 → **+3–5 °C** | **开放，未量化** | 源声明正确：主线 CPU OPP 表无 `opp-microvolt`/`cpu-supply`，CPR 未实现；Android 使用 `qcom,cpr-regulator`。但**工件中无轨电压遥测**，因此 °C 值是估计。`required-opps`→rpmpd 是可证明空操作（`drivers/opp/core.c:1117`）；真实修复需要内核驱动更改（CONTROL_PORT 杠杆 3）。 |
| 4 | Android 跳闸 60 °C vs OpenWrt 75 °C → **"设置 +15 °C 上限"** | **作为成因驳斥** | 跳闸是*响应*，非源。CONTROL_PORT 杠杆 1 将 OpenWrt 跳闸降至 60 °C：**0 °C 收益**（峰值调制解调器两者 76 °C），**rx 吞吐量 −37 %**，以及永久空闲节流回归。"60 °C = Android 空闲上限"框架本身是已拒绝 +15 °C 空闲基线的下游；OpenWrt 的 75 °C 可说是已基线校正的类比。 |
| 5 | 无 SPM `spc` / PSCI 回退到 WFI → **+2–3 °C** | **不被源支持；Android 状态进入观察，OpenWrt 驻留未测量** | OpenWrt 6.12.94 有 PSCI CPU/簇空闲状态（msm8916.dtsi:202–228）且 `CONFIG_CPU_IDLE`/`ARM_PSCI_CPUIDLE` 启用。实况 Android CPU0 计数器显示进入 `standalone_pc` 和 `pc`；这不确立其比较驻留或轨节省。 |
| 6 | 无 PA/Wi-Fi thermal-engine 节流 → **+1–2 °C** | **PA/调制解调器声明不受支持；GPU 限制在无显示设备上热惰性；WLAN 策略是唯一子候选** | 恢复默认不监测 `pa_therm0`；`fusion` 在观察温度下未激活，且 LTE 轨迹无调制解调器动作。它确实显示 55 °C GPU 限制 —— 但两个 HMU05 构建**无显示且无 GPU 工作负载**，因此 Adreno 306 时钟门控/关，200 MHz 限制是空操作（空闲 GPU 在任何频率拉约 ~0 W）。WLAN 的 60 °C 动作在轨迹中未达到；OpenWrt（补丁 847）在 65 °C 镜像它。这些的任何 °C 贡献未测量。真正的剩余负载差距差异是 **AP 总线带宽投票**（Android 差分轴 A17），而非 GPU/PA/WLAN 策略。 |

**净：** 六个更早声明的无一根因或测得温度
贡献。成因 6 的 PA/调制解调器部分被恢复策略/轨迹反驳；其 GPU
和 WLAN 策略部分是受控测试候选，非已确认解释。成因 3
（CPR/电压）仍是未测量的源差距。报告的"+5–7"、"+3–4"等数字是
估计，非结果。

**从更早报告保留什么：** 其源观察可告知实验，但
CPU 热插拔、热跳闸、欠压和调制解调器节流更改不是验证的温度
解决方案。修复 A2 静止故障仍是单独调制解调器稳定性任务
（`Docs/Modem Stability/Modem RE/hmu05/A2_QUIESCE_ASYMMETRY.md`），非已证明的热修复。
不要沿用稳定的 +15 °C 空闲前提或排序幅度表。

## 源与工件索引

- Android TSENS 源：GitIgnore/android_kernel_zte_msm8916/drivers/thermal/msm8974-tsens.c（MSM8916 熔丝解码，30/120 °C 转换）和 arch/arm/boot/dts/qcom/msm8916.dtsi（TSENS ID/斜率，msm-thermal，PA VADC 通道）。
- OpenWrt TSENS 源：GitIgnore/compare/openwrt/build_dir/target-aarch64_generic_musl/linux-msm89xx_msm8916/linux-6.12.94/drivers/thermal/qcom/tsens-v0_1.c 和 tsens.c；匹配 DT/校准单元和区域在该树的 arch/arm64/boot/dts/qcom/msm8916.dtsi。
- 捕获数据和采样器：[thermal_baseline 目录](../../scratch/thermal_baseline/)，尤其是 android_idle.csv、android_load.csv、owrt_idle_unpinned.csv、owrt_idle_pinned.csv、owrt_load_control.csv、thermal_sample.sh、android_thermal_sample2.sh 和 run_load_test.sh。
- Android 策略/轨迹工件（2026-10-08）：[thermal_baseline/android/](../../scratch/thermal_baseline/android/README.md) —— `thermal-engine-active.conf`（通过 `thermal-engine -o` 恢复）、`thermal-engine.bin`（md5 d8084a1c342c82ca796a91f27033b59e）、`thermal_trace.log` + `thermal_samples.log` + `trace_thermal.sh`（160 s LTE 轨迹）、以及 `init.target.rc.thermal-engine.txt`。
- Android 运行时证据：[thermal-engine 逆向说明](../Modem%20Stability/Stock_Android_Analysis/52_ghidra_thermal_engine_RE.txt)、[init 服务配置](../Modem%20Stability/Stock_Android_Analysis/init.target.rc)、[运行时热区域](../Modem%20Stability/Stock_Android_Analysis/05_subsystems_and_properties.txt)、以及[文件描述符捕获](../Modem%20Stability/Stock_Android_Analysis/18_lsof_and_sockets_dump.txt)。
- 更早 CPU 杠杆数据/审阅：[Android 热控制移植报告](./HMU05_ANDROID_THERMAL_CONTROL_PORT.md)。
- 上游交叉检查：[Linux Qualcomm TSENS 转换/校准](https://github.com/torvalds/linux/blob/master/drivers/thermal/qcom/tsens.c)、[TSENS v0.1/MSM8916 数据](https://github.com/torvalds/linux/blob/master/drivers/thermal/qcom/tsens-v0_1.c)、以及[上游 MSM8916 设备树](https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/qcom/msm8916.dtsi)。
