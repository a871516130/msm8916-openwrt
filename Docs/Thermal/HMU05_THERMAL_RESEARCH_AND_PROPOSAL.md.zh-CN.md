# HMU05 热调查：重新评估更早的 +15°C 声明

**设备：** HMU05 4G 调制解调器棒（`hmu05,250605v0s`，Qualcomm MSM8916 / Snapdragon 410）  
**比较：** 原厂 ZTE Android 4.4 / Linux 3.10.28 vs OpenWrt（主线 Linux 6.12）  
**报告日期：** 2026 年 10 月  

> **注（2026-10-10）—— A2 引脚现在在驱动中，而非用户空间。** 下面提到的
> 用户空间 `/usr/sbin/modem-a2-hold` 辅助工具已**移除**。A2
> 引脚现由 `qcom_bam_dmux` 驱动在设备树设置 `qcom,a2-pin` 的板上保持
> （HMU05；补丁 848/849）；用
> `echo 0|1 > /sys/module/qcom_bam_dmux/parameters/a2_pin` 切换它。下文对
> `modem-a2-hold` 的引用描述的是更早的用户空间机制。

> **更正（2026-10-08）—— 使用本报告前请阅读。** 本报告背后的原始 CSV **不**支持稳定的 **+15 °C 空闲偏移**。重算它们：OpenWrt − Android 空闲均值是 **+3–7 °C**，且每个空闲捕获是冷却（或启动预热）瞬态，而非平衡基线。真实的、佐证的差距是**负载相关**（LTE 下五个 TSENS 传感器约 +12 °C）。源审计也发现 TSENS 校准偏移不太可能，并驳斥下方根因 #1 的前提 —— Android 的空闲捕获保持 `a2_pwr` **恒定**（A2 开），即 Android 与 OpenWrt 的引脚处于相同 A2 状态。六个排序成因携带**估计**而非测得的 °C 值。实况 thermal-engine 配置削弱调制解调器/PA 节流声明：其 `fusion` 缓解是 55/60 °C 级别 0，仅 105 °C 级别 1；观察到的 LTE 轨迹反而显示 55 °C GPU 限制。当前 Android 快照发现 `mpdecision` 运行且四 CPU 在线，以及非零 CPU0 `standalone_pc` 和 `pc` 空闲计数器。CPR/电压仍是未测量的源差距。见
> [HMU05_OPENWRT_ANDROID_THERMAL_ROOT_CAUSE.md](HMU05_OPENWRT_ANDROID_THERMAL_ROOT_CAUSE.md)
> 的完整证据和当前推荐，该文档取代本报告的空闲基线、根因和行动计划结论。下方更早的 CPU/A2 想法作为假设保留，非验证解决方案。

> **实况 Android 验证（2026-10-08 09:10 UTC；对 `192.168.100.1` 的只读 SSH）。**
> `thermal-engine`（PID 208）和 `mpdecision`（PID 1201）运行中。CPU 0–3 全部报告在线；CPU0 的累计空闲计数器显示进入 `standalone_pc`（3,873）和 `pc`（105,760），以及 WFI（48,008）。TSENS 硬件传感器 0/1/2/4/5 读 50/46/44/47/48 °C；PMIC 和电池区域读 39.486 °C 和 33 °C。PA VADC 节点返回 `Result:36 Raw:7b49`。
> 这是一个快照，非比较负载测试：它反驳 Android 总是保持 CPU 1–3 离线的绝对声明，但不确立全时热插拔行为或热因果。不要按书面形式应用下方热插拔、降跳闸、欠压或调制解调器节流建议；其声称的温度收益从未被测量。

---

## 历史执行摘要（已取代；为审计保留）

在 HMU05 调制解调器棒上，遥测显示在原厂 Android 下，空闲和路由工作温度处于 **49°C 至 54°C** 之间（通过 Qualcomm TSENS 硬件传感器 0–5 测量）。在运行主线 Linux 6.12 的 OpenWrt 下，设备空闲于 **65°C 至 70°C** —— 持续 **高 15°C**。

TSENS 数学转换公式、校准熔丝和硬件寄存器在两个内核间**相同**。+15°C 差异是**真实的物理热耗散**，源于 Qualcomm 下游厂商 BSP 与 OpenWrt 上游内核之间的六个复合架构和配置差异：

| 排名 | 根因 | Android 行为 | OpenWrt 行为 | 热影响 |
|:---:|---|---|---|:---:|
| **1** | **调制解调器 A2 电源域** | 空闲时收起为深睡（`ul_powerdown`） | 24/7 钉住活动（驱动 A2 引脚；以前为 `/usr/sbin/modem-a2-hold`） | **+5°C 至 +7°C** |
| **2** | **CPU 核热插拔** | `/system/bin/mpdecision` 保持 CPU1–3 **离线** | 4 核 100% 时间在线 | **+3°C 至 +4°C** |
| **3** | **CPU 电压与 CPR** | 通过 CPR 动态闭环欠压（约 0.90V） | 固定高引导加载器电压（约 1.15V–1.25V） | **+3°C 至 +5°C** |
| **4** | **热跳闸点** | 主动热缓解始于 **60°C** | 被动跳闸点始于 **75°C** | **设置 +15°C 上限** |
| **5** | **CPU 空闲 / SPM vs PSCI** | 硬件 SAW2 SPM 独立功率收起（`spc`） | 通用 PSCI；回退到浅 WFI | **+2°C 至 +3°C** |
| **6** | **调制解调器 PA 与 Wi-Fi 功率** | 用户空间 `thermal-engine` 节流 PA；BMPS 睡眠 | 无 PA 热节流；连续 AP 信标 | **+1°C 至 +2°C** |

---

## 更早根因假设（未确立）

### 1. 调制解调器 A2 电源域钉住唤醒（A2 引脚；以前为 `modem-a2-hold`）
* **原厂 Android：** 在 Qualcomm 的下游 `bam_dmux.c` 中，运行时电源管理（`ul_powerdown()` / `ul_wakeup()`）完全活动。当蜂窝接口上无数据包传输时，AP 释放其在 `SMSM_A2_POWER_CONTROL` 上的投票。调制解调器基带（Hexagon DSP、BAM DMA 引擎、共享内存总线）完全关闭 **A2 时钟/电源域**。
* **OpenWrt：** OpenWrt 与 HMU05 调制解调器固件有未解决的握手 bug，其中 A2 电源下上循环使调制解调器断言 `a2_power.c:1189`（A2 上电静止超时）。为防止调制解调器每约 60 秒崩溃，OpenWrt 保持 A2 引脚 —— 现由 `qcom_bam_dmux` 驱动在 DT 设置 `qcom,a2-pin` 的板上强制（HMU05；补丁 848/849），等效于：
  ```sh
  # 驱动执行此旧功能（用户空间 modem-a2-hold 已移除）
  echo on > /sys/devices/platform/soc@0/4080000.remoteproc/4080000.remoteproc:bam-dmux/power/control
  ```
* **后果：** 通过保持 `power/control = on`，BAM-DMUX 从不运行时挂起。调制解调器整个 A2 电源域、DSP 接口和 DMA 时钟保持 **每周 7 天、每天 24 小时带电**，即使无流量通过也耗散连续静态和动态热。

---

### 2. CPU 热插拔：`mpdecision` vs 4 个常开核
* **原厂 Android：** 原厂 Android 运行 `/system/bin/mpdecision`。遥测和进程转储（`Docs/Modem Stability/Stock_Android_Analysis/18_lsof_and_sockets_dump.txt`）揭示 `mpdecision` 持有以下文件描述符：
  ```
  /sys/devices/system/cpu/cpu1/online
  /sys/devices/system/cpu/cpu2/online
  /sys/devices/system/cpu/cpu3/online
  ```
  每当负载轻（在专用路由器上几乎总是如此），`mpdecision` 写 `0` 卸载核 1、2 和 3。**仅 CPU0 保持在线。** 核 1–3 完全门控并与电源断开。
* **OpenWrt：** OpenWrt 无 CPU 热插拔服务。所有 4 个 Cortex-A53 核连续保持在线。每核执行空闲循环、定时器中断、调度器刻度、网络软中断。
* **后果：** 四个 Cortex-A53 核消耗约单个活动核静态漏电和空闲时钟功率的 3.5×。

---

### 3. 缺失的核功率降低（CPR）与动态电压缩放
* **原厂 Android：** Qualcomm 实现**核功率降低（CPR）**（`qcom,cpr` 于 `msm8916-regulator.dtsi`）。CPR 读取硅工艺熔丝（速度仓和角目标）并实时测量环形振荡器速度。它动态降低 PMIC 降压稳压器（`PM8916 SMPS2` / `VDD_APC`）至绝对最低安全电压（欠压至约 0.90V – 0.95V）。
* **OpenWrt：** 在主线 Linux 6.12 中，MSM8916 的 CPR 完全未实现。此外，在 `arch/arm64/boot/dts/qcom/msm8916.dtsi` 中：
  ```dts
  cpu_opp_table: opp-table-cpu {
      compatible = "operating-points-v2";
      opp-shared;
      opp-200000000 { opp-hz = /bits/ 64 <200000000>; };
      opp-400000000 { opp-hz = /bits/ 64 <400000000>; };
      opp-800000000 { opp-hz = /bits/ 64 <800000000>; };
  };
  ```
  **无 `cpu-supply` 属性**链接到 PMIC 降压稳压器，且**无 `opp-microvolt` 值**。
* **后果：** 虽然 CPU 频率步进降至 200 MHz，**电压从不下降**。CPU 运行于固定引导加载器默认电压（通常 1.15V 至 1.25V）。因为功率随电压平方缩放（$P \propto V^2$）：
  $$\frac{(1.20\text{ V})^2}{(0.95\text{ V})^2} \approx 1.60 \implies \mathbf{+60\%\text{ 更多动态功率}}$$
  此外，28nm 半导体漏电电流随更高供电电压和温度指数增加。

---

### 4. 热缓解阈值差异
* **原厂 Android：** 在 `arch/arm/boot/dts/qcom/msm8916.dtsi` 中：
  ```dts
  qcom,msm-thermal {
      qcom,limit-temp = <60>;             /* 在 60°C 节流频率 */
      qcom,temp-hysteresis = <10>;
      qcom,core-limit-temp = <80>;        /* 在 80°C 热插拔核离线 */
  };
  ```
  此外，Android 的用户空间 `/system/bin/thermal-engine` 每 250ms 监测 TSENS 并在 55°C–60°C 起强制执行严格热节流。
* **OpenWrt：** 在主线 `arch/arm64/boot/dts/qcom/msm8916.dtsi` 中：
  ```dts
  cpu0-1-thermal {
      trips {
          cpu0_1_alert0: trip-point0 {
              temperature = <75000>;      /* 仅在 75°C 被动节流！ */
              hysteresis = <2000>;
              type = "passive";
          };
      };
  };
  ```
* **后果：** 在 OpenWrt 中，内核在 75°C 以下做**零热节流**。热调控器允许热无阻力积累直至达到 75°C。在 Android 中，调控器主动将设备钳制在约 55°C–60°C。

---

### 5. CPU 空闲状态：硬件 SPM vs 不完整 PSCI
* **原厂 Android：** 在 `msm8916-pm.dtsi` 中，Qualcomm 的 `spm-v2` 用专用微码编程子系统功率管理器（SAW2）硬件块（`0xb089000`、`0xb099000` 等），用于：
  * `wfi`：等待中断
  * `spc`：独立功率收起（门控到单个核的电源轨）
  * `pc`：簇功率收起（收起 L2 缓存并通知 RPM 进入睡眠）
* **OpenWrt：** 主线 Linux 6.12 在 ARM64 上禁用 `ARM_QCOM_SPM_CPUIDLE` 并依赖 `arm,psci-1.0` SMC 调用。然而，在 HMU05 上，固件是原厂 2016 年 32 位 Qualcomm TrustZone（`tz.mbn`）。原厂 TZ 不实现完整 PSCI 簇睡眠或 RPM 协调。当调用 `CPU_SUSPEND` 时，它回退到无轨收起的基及时钟门控 `wfi`。

---

### 6. 调制解调器 RF 功率放大器（PA）与 Wi-Fi 功率曲线
* **原厂 Android：** `/system/bin/thermal-engine` 监测调制解调器 PA 温度并发出 QMI 命令，若棒变暖则节流 PA 发射功率并步降 LTE 上行速率。
* **OpenWrt：** 无调制解调器 PA 热守护进程。调制解调器无论晶粒温度如何都以最大发射功率运行。此外，OpenWrt 的上游 `wcn36xx` 驱动在无激进 802.11 省电下以完整 AP 模式运行 hostapd。

---

## 更早提议的解决方案与行动计划（已取代；不要按书面形式应用）

### 阶段 1：即时用户空间与配置修复（目标：-8°C 至 -10°C）

这些更改无需内核重编译，可立即在实况系统上测试：

#### 1. 实现动态 CPU 热插拔（Mini-mpdecision）
因为路由 4G 流量在棒上很少需要超过 1–2 核，空闲时保持核 1–3 离线：
创建 init 脚本 `/etc/init.d/cpu-hotplug`：
```sh
#!/bin/sh /etc/rc.common
START=95
USE_PROCD=1

hotplug_loop() {
    while :; do
        # 读取 1 分钟负载均值
        load=$(awk '{print int($1 * 100)}' /proc/loadavg)
        if [ "$load" -lt 50 ]; then
            # 低负载：仅保持 CPU0 在线
            [ "$(cat /sys/devices/system/cpu/cpu1/online 2>/dev/null)" = "1" ] && echo 0 > /sys/devices/system/cpu/cpu1/online
            [ "$(cat /sys/devices/system/cpu/cpu2/online 2>/dev/null)" = "1" ] && echo 0 > /sys/devices/system/cpu/cpu2/online
            [ "$(cat /sys/devices/system/cpu/cpu3/online 2>/dev/null)" = "1" ] && echo 0 > /sys/devices/system/cpu/cpu3/online
        else
            # 高负载：将所有核带线
            echo 1 > /sys/devices/system/cpu/cpu1/online 2>/dev/null
            echo 1 > /sys/devices/system/cpu/cpu2/online 2>/dev/null
            echo 1 > /sys/devices/system/cpu/cpu3/online 2>/dev/null
        fi
        sleep 5
    done
}

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh -c "$(declare -f hotplug_loop); hotplug_loop"
    procd_set_param respawn
    procd_close_instance
}
```

#### 2. 限制最大 CPU 频率并使用 `conservative` 或 `powersave` 调控器
默认情况下，`luci-app-cpu-perf` 将 `schedutil` 设置到 1.2 GHz。将频率限制到 800 MHz 消除高电压 turbo 状态：
```sh
uci set cpu-perf.@cpu_freq_policy[0].scaling_max_freq="800000"
uci set cpu-perf.@cpu_freq_policy[0].scaling_governor="conservative"
uci commit cpu-perf
/etc/init.d/cpu-perf restart
```

#### 3. Wi-Fi 发射功率优化
将 Wi-Fi TX 功率从默认 20 dBm（100 mW）降至 14 dBm（25 mW）。在无散热器的封闭棒中，Wi-Fi PA 热直接辐射到 MSM8916 晶粒：
```sh
iw dev wlan0 set txpower fixed 1400
```

---

### 阶段 2：内核与设备树增强（目标：-5°C 至 -7°C）

#### 1. 降低 DTS 热跳闸点以匹配原厂 Android
在 `msm89xx/patches/` 中添加补丁，更新 `arch/arm64/boot/dts/qcom/msm8916-generic-hmu05.dts`（或覆盖 `msm8916.dtsi`）：
```dts
&cpu0_1_alert0 {
    temperature = <55000>;  /* 从 75°C 降至 55°C，匹配 Android */
    hysteresis = <5000>;
};

&cpu2_3_alert0 {
    temperature = <55000>;
    hysteresis = <5000>;
};
```

#### 2. 解决 `a2_power.c:1189` 根因以放下 A2 引脚
* 如 `Docs/Modem Stability/Modem RE/hmu05/A2_QUIESCE_ASYMMETRY.md` 所述，A2 引脚（以前为用户空间 `modem-a2-hold`，现为 `qcom_bam_dmux` 驱动引脚）只是防止静止超时断言的创可贴。
* 修复内核驱动中的 `bam-dmux` down-ack 串行化/握手，使运行时 PM 可重新启用（`control=auto`）。
* 允许调制解调器 A2 域在空闲间隔收起将产生单一最大温度降（约 5°C 至 7°C）。

#### 3. 将 PM8916 SMPS2 稳压器连接到 CPU 节点以实现电压缩放
在 `msm8916.dtsi` 中通过将 CPU 节点链接到 `PM8916 SMPS2` 并在 OPP 表中指定 `opp-microvolt` 启用动态电压缩放，使降低频率也降低核电压。
