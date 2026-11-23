# 需求驱动的 A2 电源（Android `ul_wakeup` 对齐）— 已测试，阴性

**日期：** 2026-10-07 · **板卡：** HMU05（`hmu05,250605v0s`）· **分支：** `staging-main`
**台账：** `197_UZ801_PORT_LEDGER_AND_MANDATORY_SOP.md`（在 `test/pure-software-modem` 上）

> **注（2026-10-10）：** 下文提到的 `control=on` 引脚是用户态
> `modem-a2-hold` 辅助程序，此后**已移除** — 该引脚现位于 `qcom_bam_dmux`
> 驱动中（DT `qcom,a2-pin`，补丁 848/849；通过
> `/sys/module/qcom_bam_dmux/parameters/a2_pin` 切换）。以下实验结果不变。

## 本文档为何存在

`a2_power.c:1189` 致命（"A2 断言失败" — 调制解调器的上电**静止**超时）
仅被 `control=on` 引脚保持（`modem-a2-hold`）抑制，后者冻结 A2 使其永不折叠。
那是一种变通方案：调制解调器被保持上电，从不进入空闲。此处测试的假设是
OpenWrt 的**触发模型** — 而非线路协议 — 是原因，因此移植 Android 的需求驱动
模型可让 A2 自然折叠而不致命，从而可停用该引脚。

## 假设（来自 `reference_a2_handshake_semantics.md`）

两个栈以相同方式投票 A2（AP 写 `SMSM_APPS_STATE & SMSM_A2_POWER_CONTROL`；
调制解调器通过 `SMSM_MODEM_STATE` 应答）。真正差异在于**谁决定何时**：

| | Android `bam_dmux.c` | OpenWrt `qcom_bam_dmux.c` |
| :-- | :-- | :-- |
| 上电 | 来自 TX/RX 数据路径的 `ul_wakeup()` | 运行时-PM 自动挂起定时器上的 `bam_dmux_runtime_resume()` |
| 掉电 | `verify_tx_queue_is_empty()` 之后的 `ul_powerdown()` | 定时器上的 `bam_dmux_runtime_suspend()`，队列未检查 |
| RX 保持 A2 上电 | 是（RX 上 `ul_packet_written=1`） | 否（RX 仅 `pm_runtime_mark_last_busy()`，不持有 PM 引用） |

⇒ 主张是：定时器调度的恢复可能在调制解调器 A2 客户端的静止字仍为
`& 7 != 0` 时落地，且调制解调器自旋至其 45 000 次自旋的断言预算。

## 实现（补丁 `834-bam-dmux-demand-driven-a2-power.patch`）

- 驱动拥有的空闲定时器 `power_timeout_work`（1000 ms，`BAM_DMUX_POWER_IDLE_MS`）—
  Android 的 `ul_timeout_work`。
- TX **和 RX** 标记活动（`pkt_written`，Android 的 `ul_packet_written`）。
- `bam_dmux_power_wakeup()` ≡ `ul_wakeup()`；`bam_dmux_power_collapse()` ≡ `ul_powerdown()`。
- `runtime_suspend` 返回 `-EBUSY`，`runtime_resume` 返回 0 — PM 核心永远无法
  折叠 A2；驱动拥有它。
- 一个 `demand_driven` 布尔模块参数（默认 1），使两个模型可在同一镜像上 A/B 测试。

从擦除的 `build_dir` 重放序列 001–834 逐字节复现了编辑后的源码
（`33d8a658…`），随后在下述 `runtime_auto` 修复后为 `700aec30…`。

## 结果 — 致命

浸泡 `scratch/a2dd_soak.sh armB 1 3600` — `control=auto`，`modem-a2-hold` 和承载
看门狗停止，约 1 个 A2 周期 / 6 s（匹配基线周期速率）：

| 分支 | 首次致命 | 之前 A2 周期 | 每周期速率 |
| :-- | :-- | --: | --: |
| **demand_driven=1，`control=auto`** | `a2_power.c:1189` @ 调制解调器运行时间 **52 s** | **约 9**（`pc_vote` 10 / `pc_unvote` 9） | **约 11 %** |
| runtime-PM 基线（先前） | 约 95 s | 约 10–12 | 约 8.2 % |

首次致命后，调制解调器每约 55–70 s **崩溃循环**（7 次致命 / 553 s）。需求驱动
触发器**不**移动致命。这是**第三个**独立的 AP 侧机制失败（补丁 833 down-ack
序列化；补丁 834-old down-ack 折叠等待；补丁 834-new 需求驱动）⇒ 静止失败
**在调制解调器内部**，仅需要 A2 *实际*折叠。**线索关闭。**

原始证据：`scratch/a2dd_armB_evidence/armB.log`。

## ★ 可复用发现 — 驱动拥有的折叠不得击败 `control=on`

驱动的空闲定时器**绕过 PM 核心**。因此第一个 834 构建在 *`control=on` 时*
折叠 A2：`pc_unvote_tx_count` 在 47 s 内达到 3（833 模块保持它为 0），
静默移除已证实的缓解措施。

修复：`bam_dmux_power_collapse()` 在 `!dmux->dev->power.runtime_auto` 时提前返回
（`pm_runtime_forbid()` 清除它；`control=auto` 保持它为 true）。已验证：`control=on`
+ `demand_driven=1` → 25 s 流量中 `pc_unvote` 保持 0。**任何未来的
驱动内折叠路径必须携带此门控**，否则引脚不是有效覆盖。

## 处置

- 补丁 834 从两个补丁树中**已还原**；序列止于 833。保留为
  `scratch/patch834/834-bam-dmux-demand-driven-a2-power.patch.negative`。
- 设备模块回滚至 833 对照（`d9274204…`）；`modem-a2-hold` +
  承载看门狗重新启用 → `control=on`，A2 冻结，0 致命。
- **`control=on` 引脚保持被保留**作为交付的稳定性措施。

## 达成 vs 预期

| 意图 | 预期 | 达成 | 状态 |
| :-- | :-- | :-- | :-- |
| 需求驱动 A2 修复 `a2_power.c:1189` | 3600 s 内 0 致命 | mu 52 s 致命（约 9 周期）+ 崩溃循环 | **未达成** |
| 每周期致命率低于 8.2 % | < 8.2 % | 约 11 %（不变） | **未达成** |
| `control=on` 仍为有效回滚 | 引脚不受影响 | 首个构建击败引脚；经 `runtime_auto` 门控修复，后验证 | **达成（修复后）** |
| 设备保持稳定 | 0 致命，A2 冻结 | 833 + `control=on`，0 致命，`pc_unvote` 0 | **达成** |

## SOP

先基准事实：Android 触发模型从已追踪驱动读取
（`GitIgnore/android_kernel_zte_msm8916/drivers/soc/qcom/bam_dmux.c`），而非推断；
OpenWrt 侧来自 `qcom_bam_dmux.c`。每分支一个变量：分支间唯一差异是
`demand_driven`。补丁在浸泡前通过从擦除的 `build_dir` 重放整个序列并
逐字节比较来验证。浸泡使用与基线**相同的周期速率**，使每周期速率可比较。
**记录阴性结果，而非掩埋**：需求驱动线索关闭；唯一的 AP 侧缓解是
`control=on` 引脚保持，真正修复将是基带更改（使
`FUN_c0505308` 等待五个 `0xec320b80` 客户端字，或在上电时重置断言预算 —
见 `A2_QUIESCE_ASYMMETRY.md`）。
