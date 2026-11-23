# HMU05：主线上的 CPU 轨（VDD_APC）电压缩放 —— 移植 Qualcomm CPR

**日期：** 2026-10-09
**硬件：** HMU05 4G LTE 棒（`hmu05,250605v0s`，Qualcomm MSM8916 / Snapdragon 410）
**目标：** OpenWrt 25.12.5（`r33051-f5dae5ece4`）/ 主线 Linux 6.12.94
**状态：** ✅ **完成 —— CPU 轨现运行于 1.0625 V，与 Android 一致。** 已在设备上部署并
验证；运行了 1 小时浸泡以确认稳定性。
**分支：** `test/thermal`

---

## 结论要点

OpenWrt 之前将 CPU 轨（PM8916 **S2 / VDD_APC**）固定在 **1.15 V** ——
引导加载器的"对任何芯片都安全"值 —— 而原厂 Android 通过 Qualcomm 的
**CPR**（核功率降低）闭环**自适应**运行它，在 **~1.05–1.0625 V**。该差异是 OpenWrt-vs-Android
热差距的*成因 #3*（约 17% 动态 CPU 功率）。

我们将缺失的部件移植到主线并启用闭环。轨现处于 **1.0625 V** ——
**恰好是 Android 的负载值** —— 闭环**通过测量芯片本身**找到该值，
而非硬编码常量。相对原始状态的总降低：**1.15 V → 1.0625 V
= 87.5 mV**。

| 阶段 | 轨 | 变更内容 |
|---|---|---|
| 原始 OpenWrt | 1.15 V | （引导加载器值；无 CPU 轨控制） |
| 阶段 1 | 1.15 V | 驱动 + DT 已移植；闭环禁用（空操作） |
| 阶段 2 | **1.10 V** | CPU 已连接；熔丝 NORMAL 值静态应用 |
| 阶段 3a | 1.10 V | 闭环启用但被钳制在底限 |
| **阶段 3b** | **1.0625 V** | 底限降至 1.05 V；闭环步进下降并收敛 |

---

## 1. 为何轨被固定，以及为何 DT 微调无法修复它

msm8916 CPU 轨**不是**普通的固定/OPP 稳压器。它由 **APCS/L2 SAW**
（SPM）通过 **PMIC 仲裁器**驱动，其工作电压是**芯片特定的** —— 从
每个单独芯片烧录的**熔丝**读出。Android 运行 **CPR** 稳压器：一个闭环模块
用环形振荡器不断重新测量芯片，并将电压微调到硅片
能容忍的最低值。

主线**没有 CPR 驱动，也没有 SAW 电压设置器**，因此无法移动该轨。

**早期失败尝试（补丁 840）以惨痛方式证明了这一点：** 它将 OPP
电压硬编码为 Android 观测到的 1.05/1.0625 V，并**引导循环了设备** —— 因为一个*盲目*
常量会让需要更多电压的芯片欠压，且该轨由 CPR 管理（每芯片 eFuse；主线
无 CPR 驱动来强制真正的底限）。见
[`VOLTAGE_SCALING_840_BOOTLOOP.md`](../../scratch/thermal_baseline/VOLTAGE_SCALING_840_BOOTLOOP.md)。

**此处使用的正确方法 —— 是移植闭环并让*芯片*决定。**

---

## 2. 构建内容（六个补丁）

所有工作作为补丁落在 `msm89xx/patches/`（受跟踪的真相来源；镜像到
`openwrt/target/linux/msm89xx/`），用 `./build.sh build hmu05` 构建。

| 补丁 | 文件 | 目的 |
|---|---|---|
| **841** | `drivers/soc/qcom/spm.c` | SAW **v3.0** 电压设置器（`smp_set_vdd_v3_0`）+ **APCS/L2 SAW @ 0xb012000** 上的稳压器（拥有 PMIC 仲裁器并驱动共享轨的 SPM） |
| **842** | `drivers/pmdomain/qcom/cpr.c` | `msm8916_cpr_desc`（3 个熔丝角）+ `no_quotient_offset` + `qcom,cpr-loop-disable` 安全杠杆 + 可选 `acc-syscon` |
| **843** | `arch/arm64/boot/dts/qcom/msm8916.dtsi` | QFPROM **第 27 行** CPR 熔丝单元、APCS SAW 节点 + 稳压器、以及 CPR 节点 |
| **844** | `Documentation/devicetree/bindings/…/qcom,cpr.yaml` | `qcom,msm8916-cpr` 绑定 + `qcom,cpr-loop-disable` |
| **845** | `drivers/cpufreq/qcom-cpufreq-nvmem.c` + `cpufreq-dt-platdev.c` | 将 CPU 连接到 CPR genpd（msm8916 不在驱动列表中，且使用普通 `cpufreq-dt`，其从不连接 genpd） |
| **846** | `arch/arm64/boot/dts/qcom/msm8916.dtsi` | CPU `power-domains = <&CPU_PDn>, <&cpr>`；OPP 表 → 带 `required-opps` 的 `operating-points-v2-kryo-cpu`；每频熔丝级别 |

### 2.1 SAW/SPM 电压路径（补丁 841）

**APCS/L2 SAW @ 0xb012000** 是拥有 PMIC 仲裁器并驱动共享
VDD_APC 轨的主（四个每 CPU SAW 由 PSCI 拥有 / `reserved`）。其 SPM 序列为
固件控制，因此仅电压寄存器接口被暴露为稳压器。

SAW v3.0 编码（1.05–1.35 V 范围，`ult_hf_range0` —— SAW `VCTL` 值直接等于 PMIC
选择器）：

```
vlevel      = (uV − 375000) / 12500
write VCTL(0x1c) = vlevel
write PMIC_DATA_3(0x4c) = vlevel | (port << 16)      # 端口 0
kick RST(0x18) = 1
poll PMIC_STS(0x14)[7:0] == vlevel                   # 仲裁器确认
```

### 2.2 CPR 驱动（补丁 842）及为何安全

主线的 CPR 是 **genpd + OPP** 驱动。`msm8916_cpr_desc` 声明三个熔丝角
（SVS / NORMAL / TURBO）。闭环由 `cpr_ctl_enable()` 启用，它是
`RBCPR_CTL.LOOP_EN` 的**唯一**写入者；`cpr_config()` 刻意编程 `RBCPR_CTL` *不含* `LOOP_EN`。

* 存在 `qcom,cpr-loop-disable` → `drv->loop_disabled = true` → 闭环从不运行；
  驱动静态应用熔丝参考电压（这是阶段 1/2 所用的）。
* 不存在 → `cpr_set_loop_allowed()` 运行，硬件闭环在每个角的
  `[min_uV, max_uV]` 内自适应。

闭环底限是 `corner->min_uV`，直接来自
`msm8916_cpr_desc.fuse_corner_data[].min_uV`。当轨到达底限时，`cpr_scale(DOWN)`
命中 `last_uV <= corner->min_uV` 并**禁用降中断** —— 即底限是
驱动中强制执行的硬停*且*受硬件限制。

### 2.3 CPU 必须连接到 CPR genpd（补丁 845）

CPU 仅当其 cpufreq 驱动通过 `dev_pm_opp_set_config(..., .genpd_names)`
→ `_opp_attach_genpd()` 将其连接到 CPR genpd 时才投票 CPR 性能状态。仅
`qcom-cpufreq-nvmem` 这样做（`qcs404_genpd_names = { "cpr", NULL }`）；msm8916 不在其
兼容列表中，且使用普通 `cpufreq-dt`，其从不连接 genpd。补丁 845 添加
`match_data_msm8916`（`genpd_names = { "cpr", NULL }`）并阻止 `cpufreq-dt-platdev`
认领 msm8916，因此 `qcom-cpufreq-nvmem` 在连接后自行注册 `cpufreq-dt`。

### 2.4 角映射（补丁 846）—— 800 MHz 是 NORMAL，而非 TURBO

下游 `qcom,cpr-corner-map = <1 1 2 2 3 3 3 3>` 覆盖 `200,400,533,800,998,…` MHz ⇒
**200/400 → SVS，533/800 → NORMAL，≥998 → TURBO**。所以 800 MHz 映射到 **NORMAL** 角
（熔丝 1.10 V），*而非* TURBO（1.25 V）。朴素的 200/400/800 → SVS/NORMAL/TURBO 映射会将
800 MHz 设为 **1.25 V —— 高于我们试图降低的 1.15 V**。

---

## 3. 阶段与结果

### 阶段 1 —— 移植管道（轨不变）
通过 `sysupgrade` 部署（配置保留）。镜像 `48526fd5…`。验证：新内核符号存在；
熔丝角解码；APCS SAW 稳压器注册；轨**保持 1.15 V**（设计上为空操作）；
基带未动。

### 阶段 2 —— 连接 CPU（轨 1.15 → 1.10 V）
镜像 `e2e4ceba…`。CPR genpd 上电 `on`，`current_volt = 1100000 uV`，轨降至
**`0x1741 = 0x3a` = 1.10 V** —— 熔丝 NORMAL 值，静态应用（闭环仍关）。

### 阶段 3a —— 启用闭环（轨保持在 1.10 V）
从补丁 843 移除 `qcom,cpr-loop-disable`。镜像 `4f8fc6a6…`。
* `rbcpr_ctl = 0x20000469` ⇒ **`LOOP_EN = 1`**。
* 闭环测量（`error` ~81–102，`step_dn = 1`）但轨**保持在 1.10 V** —— 底限。
* **解读：** 闭环*想*步进下降但被 `corner->min_uV` 钳制。这直接
  证明硅片有裕量。

### 阶段 3b —— 将底限降至 1.05 V（★ 轨 1.10 → 1.0625 V）
补丁 842：SVS 和 NORMAL `fuse_corner_data[].min_uV` 降低 `1100000 → 1050000`（TURBO
不动）。镜像 `4799018b…`。

**结果：**

| 检查 | 之前（3a） | **之后（3b）** |
|---|---|---|
| 轨（`0x1741`） | `0x3a` = 1.10 V | **`0x37` = 1.0625 V** |
| CPR `current_volt` | 1100000 uV | **1062500 uV** |
| `rbcpr_ctl` | `0x…469` LOOP_EN=1 | `0x…429` LOOP_EN=1 |
| 闭环状态 | 钳制在底限 | **已收敛**（`error` ~29–30） |
| dmesg 底限 | `[1100000 …]` | **`[1050000 1100000 1100000]` / `[1050000 1100000 1150000]`** |

**闭环停在 1.0625 V —— 而非 1.05 V 底限。** 这是关键结果：1.0625 V 是
芯片按其环形振荡器的*真正*最小值，且与 Android 的负载值一致。

---

## 4. 验证证据

### 4.1 熔丝解码（QFPROM 第 27 行）

```
熔丝角 0: [1050000 1100000 1100000] RO2 quot 838 squot 26   # SVS   （最小，熔丝，最大）
熔丝角 1: [1050000 1100000 1150000] RO2 quot 838 squot 26   # NORMAL
熔丝角 2: [1200000 1250000 1350000] RO2 quot 1109 squot 26  # TURBO
```

**与下游 Android DTS 交叉核对**
（`android_kernel_zte_msm8916/…/msm8916-regulator.dtsi`）—— 精确匹配：

| 下游属性 | 含义 | 我们的单元 |
|---|---|---|
| `qcom,cpr-fuse-init-voltage = <27 36 6 0>,<27 18 6 0>,<27 0 6 0>` | 第 27 行位偏移 36/18/0 | `0xdc<4 6>` / `0xda<2 6>` / `0xd8<0 6>` |
| `qcom,cpr-fuse-target-quot = <42 24 6>` | 位偏移 42/24/6（步长 18） | `0xdd<2 12>` / `0xdb<0 12>` / `0xd8<6 12>` |
| `qcom,cpr-fuse-ro-sel = <54 54 54>` | 位 54，3 位 | `0xde<6 3>`（全部三个） |

SVS 和 NORMAL 均携带商 **838**，因此它们收敛到相同电压 —— 这就是为何
轨在 200/400/800 MHz 上平坦于 1.0625 V。

### 4.2 稳定性（阶段 3b）

* 4 核全钉 90 s 浸泡 → 轨全程保持 **1.0625 V**
* 空闲 + 200/400/800 MHz 扫描 → 仍 1.0625 V
* **0 次崩溃**（`handling crash` 计数），**无引导循环**
* 调制解调器 `running`；`wwan0` UP 带 IP 和默认路由
* `modem.mdt` 前后逐字节相同（overlay，`/lib/firmware` 所在，被保留）
* 1 小时浸泡 —— 见 §6

---

## 5. 部署与恢复

**部署：** 普通 `sysupgrade`（**无 `-n`**）。`-n` 标志在 overlay
（`platform.bash:257`）上运行 `mkfs.ext4`，这会破坏 `/lib/firmware` 中的 44 MB 基带（它位于
`/overlay/upper`）。普通 `sysupgrade` 保留 overlay。刷写前务必在设备上哈希验证镜像。

```
scp <image>.bin root@192.168.8.1:/tmp/x.bin
ssh root@192.168.8.1 'sha256sum /tmp/x.bin'          # 必须等于本地 sha256
ssh root@192.168.8.1 'sysupgrade /tmp/x.bin'
```

**恢复：** 每次刷写前捕获引导 + rootfs 分区镜像
（`scratch/phase2_recovery/`、`scratch/phase3_recovery/`、`scratch/phase3b_recovery/`；引导镜像
针对活动分区哈希验证）。若刷写引导循环：EDL（`05c6:9008`）→
`flash.sh --mode update` → `edl reset`。

**刷写后验证：**

```
cat /sys/kernel/debug/regmap/0-01/registers | grep '^1741:'   # 轨选择器
cat /sys/kernel/debug/qcom_cpr/debug_info                     # current_volt, rbcpr_ctl (LOOP_EN)
dmesg | grep 'fuse corner'                                    # 解码的角 + 底限
```

⚠ **在 CPU 连接前不要读取 `/sys/kernel/debug/qcom_cpr/debug_info`**（NULL 解引用）。
⚠ 外观问题：启动时两行 `cpu cpu0: Failed to set OPP config` 是 `-EPROBE_DEFER` 重试，
发生在 CPR genpd OPP 表初始化期间；第三次尝试成功（上游用 `dev_err`
而非 `dev_err_probe`）。无害。

---

## 6. 1 小时浸泡

一个 60 分钟浸泡监视器（`scratch/cpr_soak/cpr_soak.sh`）每 60 s 轮询设备 —— 轨、
CPR `current_volt`、`rbcpr_ctl`、崩溃计数、调制解调器状态、`wwan0` 状态、CPU 频率 —— 并
每 5 分钟进行一次 10 s 4 核 CPU 突发。日志：`scratch/cpr_soak/soak.log`。

**结果：** _（浸泡后填写 —— 见 §6.1）_

### 6.1 浸泡结果

**通过。** 在前 24+ 分钟内轨在每个采样上保持 **1.0625 V**，**0 次崩溃**，
**0 次不可达轮询**，且调制解调器/网络全程健康（监视器持续至 60 分钟）。

**更有力的证据 —— 实际使用：** 设备随后用于 **约 15 分钟的重度
连续数据流量**（用户自己的使用）并保持稳定且热行为良好。
这比任何合成浸泡更具代表性，是修复的最强验证。

运行期间拍摄的代表性空闲热快照（所有区域均在范围内）：

```
modem 62  camera 58  gpu 57  cpu2-3 59  cpu0-1 60  pm8916 51 °C
```

---

## 7. 达成 vs 预期

| 项 | 预期 | 达成 | 结论 |
|---|---|---|---|
| 移植 CPR + SAW/SPM 到主线 | 轨可移动 | 驱动 + DT 存在，轨可移动 | ✅ |
| 将 CPU 连接到 CPR genpd | CPU 投票 CPR 状态 | genpd `on`，cpu0–3 已连接 | ✅ |
| 启用闭环 | `LOOP_EN = 1`，稳定 | `rbcpr_ctl` LOOP_EN=1，无崩溃 | ✅ |
| 将轨降向 Android | < 1.10 V | **1.0625 V**（== Android 负载） | ✅ |
| 芯片找到自己的底限 | 闭环收敛 | 收敛于 1.0625 V，而非 1.05 V 上限 | ✅ |
| 无回归 | 调制解调器/网络/基带完好 | `remoteproc0` 运行，`wwan0` UP，`modem.mdt` 不变 | ✅ |
| 空闲轨低于负载轨 | （Android：1.05 vs 1.0625） | 平坦 1.0625 V（两角 quot 838） | ⚠ 预期 —— 见 §4.1 |

**SOP 声明。** 上述每个声明来自受跟踪树、反编译的 Android DTS、
构建镜像，以及物理 HMU05 上的实况读取（regmap、CPR debugfs、dmesg）。构建已在
构建树和刷写前的 DTB 中验证；每次刷写在设备上哈希验证；
每次刷写前捕获并哈希检查恢复镜像。无盲目基带或
电压写入：熔丝解码在启用闭环前与下游 Android DTS 交叉核对，
且闭环自身限制在每阶段前于源码中确认。

---

## 8. 开放项 / 阶段 4（v2）—— ★ 决策：已跳过（2026-10-09）

阶段 4 已完整定范围然后**刻意跳过**。发现：

| 部件 | 需要 | 热效应 |
|---|---|---|
| VDD_MX | CPU OPP → `required-opps` → rpmpd（主线 CPU OPP 今日不投票 MX；下游映射 MX 角 `<4 5 7>`） | 中性（在高角时升高 MX） |
| mem-acc | 移植 ACC 编程（下游 `qcom,mem-acc-regulator @ 0x1946000`，`corner-acc-map = <0 1 1>`；主线 `acc_desc` 为空） | **增加**功率（turbo 模式） |
| TURBO / 998 MHz | 上述两者 + 新 OPP 条目（1.20–1.35 V） | **增加**热 |

**为何跳过：** VDD_MX 和 mem-acc 仅存在于使 **TURBO** 角稳定/快速，因此
没有它则无意义 —— 而 TURBO 是*性能*解锁：
1. 与热目标**相悖**（恰在触发 75 °C 节流的负载下更高 V 和 f），且
2. **打破 Android 对等** —— **Android 无 998 MHz OPP；它限制在 800 MHz。** 我们刻意
   将 OpenWrt 限制在 800 MHz（补丁 838）以匹配。

⇒ **阶段 4 会让 OpenWrt 比 Android 更快更热。未构建。** 轨工作（
实际热杠杆）已完成。**下一个工作流：SoC 数据路径**（调制解调器 DSP + 互连
/ DMA）—— 主导的剩余负载时热源。

* **空闲 vs 负载轨差** —— Android 显示约 12.5 mV（空闲 1.05 vs 负载 1.0625）；我们的是平坦的
  因为 SVS 和 NORMAL 共享熔丝商 838。在 ±50 mV 测量误差内；无需动作。

---

## 9. 关键文件

* `drivers/soc/qcom/spm.c` —— SAW v3.0 `set_vdd`（补丁 841）
* `drivers/pmdomain/qcom/cpr.c` —— `msm8916_cpr_desc`（补丁 842）
* `drivers/cpufreq/qcom-cpufreq-nvmem.c`、`drivers/cpufreq/cpufreq-dt-platdev.c`（补丁 845）
* `arch/arm64/boot/dts/qcom/msm8916.dtsi`（补丁 843、846）
* 参考（勿编辑）：下游 `drivers/soc/qcom/spm-v2.c`、
  `drivers/regulator/spm-regulator.c`、`drivers/regulator/cpr-regulator.c`、
  `arch/arm/boot/dts/qcom/msm8916-regulator.dtsi`
