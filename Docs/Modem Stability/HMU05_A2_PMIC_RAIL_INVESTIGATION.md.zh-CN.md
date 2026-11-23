# HMU05 —— #367 “PMIC 引线”：是否存在一处电源轨/PMIC 差异使 Android 对 `a2_power.c:1189` 免疫？

**任务：** 搁置 **#367** —— *为何 Android 结构性免疫于 `a2_power.c:1189` 致命错误？*
热管理相关工作（`../Thermal/HMU05_ANDROID_THERMAL_CONTROL_PORT.md`）指向“系统级
电源（PMIC 电源轨 / DDR 互连）”并把它与 #367 关联，因此本文档专门追查 **PMIC/电源轨**角度。

**结论：PMIC/电源轨轴不是 A2 致命错误的成因。** 调制解调器的电源轨（CX/MX）在两个栈中的
投票*确实*不同 —— 但仅发生在**启动窗口**内；两者都在交接时释放投票，而致命错误发生在
启动*之后*数千个 A2 周期。排除这一点（连同之前三个握手阴性结果）确认致命错误是
**调制解调器塌缩↔重新启动握手内部**的问题 —— 唯一剩余的动作是基带客户端字跟踪
（`A2_QUIESCE_ASYMMETRY.md` §6）。

---

## 1. “PMIC 引线”是什么

Android 的调制解调器节点（`qcom,mss@4080000`）携带显式的**电源轨**投票，而 OpenWrt 节点
显然没有：

| Android（`stock_dts_0.dts` `qcom,mss@4080000`） | 解析为 | 值 |
|---|---|---|
| `vdd_cx-supply = <0x67>` | `8916_s1_corner`（RPM **SMPA id 1**，`use-voltage-corner`） | `RPM_REGULATOR_CORNER_SUPER_TURBO` |
| `vdd_mx-supply = <0x113>` | `8916_l3`（RPM **LDOA id 3**） | `vdd_mx-uV = 0x100590` = **1.05 V** |
| `vdd_pll-supply = <0xda>` | `8916_l7` | 1.8 V |

由 PIL 驱动应用：
* **CX** —— `pil-q6v5.c:86`：
  ```c
  regulator_set_voltage(drv->vreg_cx,
      RPM_REGULATOR_CORNER_SUPER_TURBO, RPM_REGULATOR_CORNER_SUPER_TURBO);
  ```
* **MX** —— `pil-msa.c:258`：`regulator_set_voltage(drv->vreg_mx, uv /*=1.05V*/, INT_MAX);`

下游角点枚举（`include/linux/regulator/rpm-smd-regulator.h`）：
`NONE=1, RETENTION=2, SVS_KRAIT=3, SVS_SOC=4, NORMAL=5, TURBO=6, SUPER_TURBO=7`
⇒ Android 为 CX 请求**绝对最大角点（7）**。

OpenWrt 的等效物位于 DTS，而非驱动：
* `msm8916.dtsi:1989`（`mpss` remoteproc 节点）：
  ```dts
  power-domains = <&rpmpd MSM8916_VDDCX>,
                  <&rpmpd MSM8916_VDDMX>;
  ```
* `qcom_q6v5_mss.c:399`（`q6v5_pds_enable`）：
  ```c
  dev_pm_genpd_set_performance_state(pds[i], INT_MAX);
  ```
* `rpmpd.c:43`：`#define MAX_CORNER_RPMPD_STATE 6` —— 因此 `INT_MAX` 被钳制到**角点 6**。

rpmpd 域与 Android 的**相同 RPM 资源**：`cx_s1a_corner`（`RPMPD_SMPA`，res_id 1，
`KEY_CORNER`）≡ `8916_s1_corner`；`mx_l3a_corner`（`RPMPD_LDOA`，res_id 3）≡ `8916_l3`。
因此这是同口径对比：

| | CX（SMPA id 1） | MX（LDOA id 3） |
|---|---|---|
| **Android** | `RPM_REGULATOR_CORNER_SUPER_TURBO`（下游枚举值 7） | 1.05 V（固定） |
| **OpenWrt** | rpmpd `opp-level = <6>` = `super_turbo` | rpmpd `opp-level = <6>` = `super_turbo` |

**★ 这是相同的角点 —— 两种编号方案相差一。** 主线的 rpmpd OPP 表
（`arch/arm64/boot/dts/qcom/msm8916.dtsi`，由提交 `2709436` *"arm64: dts: qcom: msm8916: Add
RPM power domains"*，Stephan Gerhold，2020-10 添加）将其层级命名为
`1=retention, 2=svs_krait, 3=svs_soc, 4=nominal, 5=turbo, 6=super_turbo` —— **没有 `NONE` 层级**。
下游枚举计数 `NONE=1 … TURBO=6, SUPER_TURBO=7`。因此主线 `opp-level=6` = **super_turbo** =
下游 `SUPER_TURBO`。⇒ OpenWrt 的 `INT_MAX` 钳制到 `MAX_CORNER_RPMPD_STATE=6` 达到
**Android 请求的相同最大角点** —— **没有角点上限**，CX 电源轨在两个栈上处于相同层级。
（该提交还确认了设计历史：主线*刻意*用角点投票替换 Android 风格的原始电压调节器投票 ——
两者本意是等效的。）

> **剩余注意事项（未验证的离线信息）：** Android 的 `8916_s1_corner` 节点是
> `status="disabled"`（`s1_corner_ao`、`s1_floor_corner`、`s2` 亦如此），然而它是调制解调器的
> `vdd_cx` 供电 —— 因此该请求是真实 RPM 投票还是虚拟空操作，无法仅从 DTS 证明。它不改变
> 结论（无论如何都仅限启动窗口）。

**★ 系列上下文（确认机制是刻意的）。** rpmpd 节点来自
*[PATCH 00/10] Convert MSM8916 to use rpmpd/power domains*（Stephan Gerhold，2020-09-16，
lore `20200916104135.25085`）。此处相关的部分：
* `06 remoteproc: qcom_q6v5_mss: Allow replacing regulators with power domains`
* `09 arm64: dts: qcom: msm8916: Use power domains for MSS/WCNSS remoteprocs`
* `10 arm64: dts: qcom: msm8916-pm8916: Stop using s1/l3 as regulators`
⇒ 主线**刻意**将调制解调器的 CX/MX 投票从原始电压调节器（Android 的模型）迁移到 rpmpd
角点，处于**相同最大层级**（`super_turbo`）。`mpss` 节点上的 `power-domains` 是 Android 的
`vdd_cx`/`vdd_mx` 供电的预期替代 —— 而非缺失的投票。

**★ 权威引述（系列补丁 02）：** *"像 MSM8916、MSM8939、MSM8974、MSM8996 等较老的 SoC
使用 'voltage corners' 而非 'voltage levels'。看起来它们都使用完全相同的角点值集，
**一个 0-6 的值，其中 6 是最大角点（super turbo）**。"* —— 即 `MAX_CORNER_RPMPD_STATE = 6`
**就是** super-turbo，因此 OpenWrt 的 `INT_MAX` 钳制达到 Android 请求的相同最大角点。
（补丁 09 还指出*旧*调节器路径有潜在 bug —— `super_turbo` 标志未被使用，因此它只启用电源轨
而从未实际投票最大角点 —— 这是改用电源域的部分原因。）

## 2. 为何它**不**重要 —— 投票仅限启动窗口

两个栈都将这些视为**代理投票** —— 仅在 AP 启动调制解调器时持有，随后释放，因为
**调制解调器固件在运行后投票自己的电源轨**（它是独立的 RPM 客户端）。

* OpenWrt —— 在 MBA 加载路径 `q6v5_mba_load` → `q6v5_pds_enable` 中启用
  （`qcom_q6v5_mss.c:1100`），并在**交接时释放**：
  ```c
  static void qcom_msa_handover(struct qcom_q6v5 *q6v5) {   /* qcom_q6v5_mss.c:1709 */
      ...
      q6v5_pds_disable(qproc, qproc->proxy_pds, qproc->proxy_pd_count);   /* :1719 */
  }
  ```
* Android —— `pil_mss_make_proxy_votes`（启动）/ `pil_mss_remove_proxy_votes`
  （`pil-msa.c:280`，启动后）。

**实时确认**（HMU05 @ 192.168.8.1，调制解调器 `running`）：
```
cx                              off-0                           0
    genpd:0:4080000.remoteproc      suspended                   0           SW
mx                              off-0                           0
    genpd:1:4080000.remoteproc      suspended                   0           SW
```
调制解调器的 CX/MX 代理子节点**挂起**且**性能状态为 0** —— 即 AP 的投票已被释放（如设计），
调制解调器正运行在自己的电源轨投票上（对 AP 的 rpmpd 不可见）。

⇒ 唯一的差异是**数百毫秒启动窗口内的角点值**（CX 角点 6 vs 7；MX 角点 vs 1.05 V）。
`a2_power.c:1189` 致命错误发生在启动*之后*数千个 A2 周期，此时 AP 根本不再投票这些电源轨。
启动窗口角点差不能导致它。

## 3. 这对 #367 意味着什么

至此，**每个 AP 侧输入到调制解调器**都已纳入考虑：

| AP→调制解调器接口 | 已测试 / 状态 |
|---|---|
| SMSM A2 投票 + pc/pc-ack 握手 | 补丁 833 + 834（down-ack 串行化）—— **阴性** |
| A2 触发模型（按需端口） | 补丁 834-new —— **阴性** |
| CX/MX 电源轨代理投票 | **本文档 —— 仅启动，非成因** |
| 启动时钟 / 调节器 / pll | 代理投票，交接时释放（与 Android 相同） |

⇒ #367 如所述成立：致命错误是**调制解调器塌缩↔重新启动静止（quiesce）内部**的问题
（`FUN_c0505308` 塌缩而不等待五个客户端字 `0xec320b{ba4,ba8,bac,bd8,be0}`；
`FUN_c0504fc8` 随后在共享预算内自旋等待它们）。**唯一**证明方式是跨一次塌缩对五个客户端字
做逐边沿跟踪 —— 一个**基带内部环形缓冲区** —— 这是 `A2_QUIESCE_ASYMMETRY.md` §6 中的待办项。

## 4. 实证证伪 —— 已完成，阴性（2026-10-08）

便宜的测试已运行：通过从 `qcom_msa_handover` 移除 `q6v5_pds_disable()` 调用（补丁 `839`，
现退役至 `scratch/a2rail/rejected/`）**使 AP 的 CX/MX 投票在交接后持续**。从同一棵树构建了
**匹配的模块对**（仅 ±839 —— `q6v5_probe`/`q6v5_remove` 经验证指令级一致）；补丁后的模块
（`68c40822…`）持续持有投票：

```
cx   on   2147483647   <- INT_MAX -> rpmpd 钳制到角点 6 = super_turbo，整个运行时持有
    genpd:0:4080000.remoteproc  active  2147483647  SW
mx   on   2147483647
    genpd:1:4080000.remoteproc  active  2147483647  SW
```

两个臂都以 `control=auto`、有流量、且**相同的 `a2_power.c:1189` 复现状态**运行。
（对照模块的回读为 `perf=0`，即投票*确实*如设计被释放。）

| 臂 | A2 周期 | `a2_power.c:1189` 致命错误 | 比率 |
| :-- | --: | --: | --: |
| 对照（未补丁，投票已释放，`perf=0`） | 100 | 7 | **7.0 %** |
| **测试（投票持于最大，`perf=INT_MAX`）** | 111 | 10 | **9.0 %** |

差异 **+2.0 个百分点**（标准误 3.8 个百分点）⇒ **无显著变化**。将电源轨投票持于 Android 所用
的相同最大角点**并不**减少致命错误 —— 反而略*高*。H3（投票确实被持有）在测试臂上通过。
完整证据、测试框架和强制器陷阱：`scratch/a2rail/AB_RESULT.md`。⇒ PMIC/电源轨轴在
**分析层面和实证层面均已关闭**。

## 5. 次要观察（热量，而非 #367）

Android 的 RPM 调节器集比主线更细粒度：它定义了 **AO/SO** 变体
（`8916_l7_ao`/`l7_so`、`l3_corner_ao`/`so`、`s1_corner_ao`、`s2_corner_ao`），并将多个节点
标记为 `status="disabled"`（`s1_corner`、`s1_corner_ao`、`s1_floor_corner`、`s2`）。主线的
`msm8916-pm8916.dtsi` 将其收拢为一小撮常开电源轨（`l2/l5/l7`、`s3/s4`）。这是更可信的*热量*
线索（空闲/系统功耗），但它与 #367 是**独立**的问题，需要电源轨级功耗测量，而非代码阅读。

---

**SOP 声明。** 对受版本控制树的静态代码/DTS 阅读
（`GitIgnore/android_kernel_zte_msm8916/`、`openwrt/build_dir/.../linux-6.12.94/`、
`Docs/Modem Stability/Stock_Android_Analysis/dtb/stock_dts_0.dts`）+ 一次只读实时
`pm_genpd_summary` 转储。未写入基带，未改变设备状态。角点枚举和 RPM 资源身份
（SMPA id 1，LDOA id 3）通过 `res_type`/`res_id` 和 `qcom,resource-name`/`resource-id`
DT 属性在两个栈之间匹配。
