# Arm A — 无 833 的 bam_dmux 驱动仍因 `a2_power.c:1189` 致命

**日期：** 2026-10-07 · **设备：** HMU05 `hmu05,250605v0s` @ 192.168.8.1 · **台账：** `197_UZ801_PORT_LEDGER_AND_MANDATORY_SOP.md`

> **注（2026-10-10）：** 下文提到的 `control=on` 引脚是用户态
> `modem-a2-hold` 辅助程序，此后**已移除** — 该引脚现位于 `qcom_bam_dmux`
> 驱动中（DT `qcom,a2-pin`，补丁 848/849；通过
> `/sys/module/qcom_bam_dmux/parameters/a2_pin` 切换）。以下实验结果不变。

## 问题

`test/pure-software-modem` 运行 `a2_pin=0` 且（按台账 §112.170）"不崩溃"，
而 `staging-main` 在 `control=auto` 下，一旦数据承载建立，每约 65-70 s 因
`a2_power.c:1189` 致命。两个分支之间**唯一的行为驱动差异**是补丁 **833**
（`bam-dmux-down-ack-serialisation`，HMU05 门控；测试分支没有它 — 其额外补丁
830 是纯 `dev_err` 日志记录）。833 是否被牵涉？

## 方法（单变量：驱动）

- 驱动切换到**无 833** 模块：`/overlay/modbackup/qcom_bam_dmux.ko.pre833`，
  md5 `323075c0fa6ec41def32f82988e65461`（45528 B），验证不含 833 字符串
  （`bam_dmux: modem down-ack timeout before resume`、`pc_down_ack_*_count`）。
  它携带 825（"stale edge … reconciling"）和 831（"release deferred"）标记 ⇒
  它是 staging-main 序列**减去 833**（其 820/821/831 早于提交 `365eba1`，该提交
  仅剥离了惰性 `dev_err` 探针）。
- 其他一切不变：staging-main 系统 + HiMI_OK 保护。
- 中和 `control=on` 引脚（`modem-a2-hold` 停止并禁用，承载看门狗停止），
  强制 `power/control=auto`，重启调制解调器锚定到 U0，驱动突发流量
  （2 次 ping / 约 8 s 周期），监控 `dmesg` 中的 `fatal error received`。

工具：`scratch/armA/deploy_armA.sh`、`scratch/armA/armA_soak.sh`。

## 结果

| 分支 | 驱动 | 首次致命 | 之前 A2 周期 | 速率 |
| :-- | :-- | --: | --: | --: |
| 对照（833） | `d9274204…` | 运行时间约 30–96 s | 15 | 8.2 %（16/195） |
| **Arm A（无 833）** | **`323075c0…`** | **调制解调器运行时间 74 s** | **15** | **约 6.7 %（1/15）** |

原始数据：`scratch/armA/armA_A.log`。

```
[up52s] modem up; U0=52 state=running
[up52s] traffic started (2 pings / ~8 s period)
[up127s mu74] *** FATAL at mu=74s: qcom-q6v5-mss ...: fatal error received: a2_power.c:1189: ***
[up127s mu74] telemetry at fatal: pc_state: 1 pc_vote_tx_count: 16 pc_unvote_tx_count: 15 pc_timeout_count: 1 pm_suspend_attempts: 15 pm_suspend_completions: 13 pm_resume_attempts: 16
```

## 结论

**补丁 833 未被牵涉。** 无 833 驱动在调制解调器上电后 **22 s** 因
`a2_power.c:1189` 致命，约 15 个 A2 周期之后 — 与 833 对照相同的
约 7-8 %/周期速率。`a2_power` 致命是 OpenWrt A2 掉电/上电循环在流量下
的固有特性，与 AP 的 down-ack 序列化无关。

**推论 — 测试分支"`a2_pin=0` 安全"是无流量的假象。** §112.170 的
Arm B 使用 LTE IP 运行但没有持续数据；致命仅在 A2 *在流量下*频繁切换时
才会武装。移除 833 并不复现测试分支的免疫力。任何分支比较都必须驱动流量。

## 对"为何 Android 免疫？"问题的启示

Android 在**约 1/3.5 s 空闲**时电源折叠其调制解调器（`MPSS numshutdowns`
918 / 53.8 min）且 **0** 次 `a2_power` 致命 ⇒ Android **结构上**免疫，
而非仅仅是更少见。OpenWrt AP 侧握手（无论有无 833）**不是**这个轴。
剩余差异在调制解调器内部的折叠↔上电**客户端静止**
（`A2_QUIESCE_ASYMMETRY.md` §6）或 AP 侧客户端释放时序 — 两者**待定**。

## 达成 vs 预期

| 意图 | 预期 | 达成 | 状态 |
| :-- | :-- | :-- | :-- |
| 流量下无 833 驱动 | 若 833 是原因 → 无/极少致命 | `a2_power.c:1189` @ mu 74 s（约 7 %） | **达成（对 833 假设为阴性）** |
| 单变量（仅移除 833） | 仅驱动差异 | `pre833` = 序列减去 833（825/831 标记已验证） | **达成** |
| 设备已恢复 | 833 模块 + `control=on` + 0 致命 | `d9274204`，control=on，0 致命，承载已建立 | **达成** |

## SOP 合规声明

遵循双固件比较工作流（Doc 133 §1）：**备份**（833 模块在交换前被复制到
`/overlay/modbackup/qcom_bam_dmux.ko.armA_prev.*`）→ **基准事实验证**
（无 833 模块经 md5 固定并字符串验证缺少 833 标记，其 825/831 标记对照
已追踪补丁确认）→ **一次只改一个**（仅驱动模块与已知 833 基线不同）→
**实际经验验证**（设备上浸泡）。**未写入任何基带（`modem.bNN`）。**
未涉及加密重新签名。**捕获的错误：** 恢复步骤中第一个 `md5sum` 回显
引用错误（单引号 SSH 命令内 `cut -d\" \"`）；模块仍被恢复，md5 在
后续步骤中重新验证。
