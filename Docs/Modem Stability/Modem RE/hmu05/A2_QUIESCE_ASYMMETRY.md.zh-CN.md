# A2 电源 — 调制解调器侧的静止不对称

**它解释的崩溃：** `a2_power.c:1189` — *"A2 断言失败"*（ERR 描述符
`0xc3c1f3a0`，id 64，msg_ptr `0xc3cd68d8`）。

**状态：** 已验证结构（来自反编译的原厂基带）+ 针对崩溃的主导假设。以下结构
直接从反汇编中读出；因果步骤（折叠使某个客户端未静止，下一次上电随即失控）是
主导解释，**尚未证实** — 见 §6。

**真相来源：** `Docs/Modem Stability/Modem RE/hmu05/modem_full_decompiled.c`
（原厂 HMU05 调制解调器，105 MB，生成于 2025-09-20）。以下所有行号均指向
该文件。描述符 → 用 `scratch/a2_descr.py` 针对实际 coredump
（`scratch/coredump_live/modem_coredump_up919.52.elf`）解析为 `file:line`。

**相关发现：**
- `project_a2_power_fatal_needs_control_on.md` — 致命错误需要 `control=auto`
  （A2 频繁切换）；`control=on` 可抑制它。A/B：`auto` 下 16 次致命 / 195 周期，
  `on` 下 **0** 次。
- `project_a2_driver_fix_investigation.md` — AP 侧握手**不是**原因（补丁 834
  将恢复超时清零但致命错误不变；两个分支中致命错误都*先于*其 down-ack 超时）。

---

## 1. A2 概述（一段话）

**A2** 是 AP（路由器 CPU）与调制解调器（MPSS）之间共享的电源/时钟域。
调制解调器拥有它，并在空闲时折叠它（掉电），在有工作时将其重新上电（上电）。
两个转换都是"自旋直到硬件状态字达到要求值"的序列。始终未达到其值的自旋
最终会触发共享看门狗并**断言** — `a2_power.c:1189`。

---

## 2. 共享的自旋并断言辅助函数 — `FUN_c05042c8`

`FUN_c05042c8`（`:862146`）被**每个** A2 等待循环调用。它是 `a2_power.c:1189`
断言所在的唯一位置：

```c
void FUN_c05042c8(void)
{
  DAT_c28602f8 = DAT_c28602f8 + 1;              /* per-loop spin counter        */
  if (DAT_c28602f8 % 0x32 == 0) {               /* every 50 spins               */
      FUN_c0887450(1);
      DAT_c28602fc = DAT_c28602fc + 1;          /* SHARED budget counter        */
  } else {
      if (900 < DAT_c28602fc) {                 /* budget exhausted (> 900)     */
          FUN_c0506938();
          FUN_c0879150(&DAT_c3c1f3a0);          /* ASSERT a2_power.c:1189       */
      }
  }
}
```

* `DAT_c28602f8` — **每循环**自旋计数器；调用方在每个 `while` 循环前将其重置为
  `0`（`DAT_c28602f8 = 0;`）。
* `DAT_c28602fc` — **累计**预算；每 50 次自旋递增一次。当它超过 **900** 时触发断言，
  即 **> 45 000 次总自旋**（约几百毫秒）。
* 由于 `DAT_c28602f8` 每个循环重置但 `DAT_c28602fc` **不**重置，因此预算在
  **周围序列中的每个等待循环间共享**。

`DAT_c285eb80` 记录 `DAT_c28602fc` 的高水位标记（`:862905`，`:863202`）—
 一个诊断量，指示调制解调器曾经多么接近断言。

---

## 3. 两个方向等待 DISJOINT（不相交）状态集

### 上电 / 活动刷新路径

`FUN_c0504ccc`（`:862482`）是 A2 上电/刷新序列（它断言
`DAT_c285ebc8 == 1`，即"A2 已上电"）。它调用 **`FUN_c0504fc8`** 两次
（`:862512` 和 `:862574`）。

`FUN_c0504fc8`（`:862621`）等待**五个 per-client 状态字** — 即静止检查：

```c
/* fast pre-check: if any client word is set, do a pre-pass */
if (((_DAT_ec320ba4 & 7) != 0) || ((_DAT_ec320ba8 & 7) != 0) ||
    ((_DAT_ec320bac & 7) != 0) || ((_DAT_ec320bd8 & 7) != 0) ||
    ((_DAT_ec320be0 & 7) != 0))
    FUN_c0508c30();

DAT_c28602f8 = 0;  while ((_DAT_ec320ba4 & 7) != 0) FUN_c05042c8();   /* :862637 */
DAT_c28602f8 = 0;  while ((_DAT_ec320ba8 & 7) != 0) FUN_c05042c8();   /* :862641 */
DAT_c28602f8 = 0;  while ((_DAT_ec320bac & 7) != 0) FUN_c05042c8();   /* :862645 */
DAT_c28602f8 = 0;  while ((_DAT_ec320bd8 & 7) != 0) FUN_c05042c8();   /* :862649 */
DAT_c28602f8 = 0;  while ((_DAT_ec320be0 & 7) != 0) FUN_c05042c8();   /* :862653 */
```

每个客户端字必须达到 **`& 7 == 0`**（"已静止 / 已释放"）。这五个字
**仅**在此处和两个诊断快照函数（`:866113`–`:866197`，仅将它们复制到调试结构体）
中被引用 — 从不在任何掉电路径中。

### 掉电 / 折叠路径

`FUN_c0505308`（`:862791`）是折叠序列。它受 `DAT_c285ebc8 == 1` 门控
（必须已上电才能掉电 — 见 `FUN_c0505d90` `:863018` → `:863034`），并在末尾
设置 `DAT_c285ebc8 = 0`（`:862898`）。其等待为：

```c
DAT_c28602fc = 0;                                             /* :862803 — resets the budget! */
...  9 sub-block deinit checks (asserts a2_power.c:2337..2371) ...
DAT_c28602f8 = 0;
while ((sbyte)_DAT_ec320b94 != 0) FUN_c05042c8();             /* :862866 */
...  clears bits in _DAT_ec320808/80c/810/814/a98 ...
DAT_c28602f8 = 0;
while ((_DAT_ec320404 & 0x1e) != 0) FUN_c05042c8();           /* :862878 */
...  FUN_c0ce31dc(99,0); ...
DAT_c285ebc8 = 0;
```

它等待 **`0xec320b94`（低字节 == 0）** 和 **`0xec320404 & 0x1e == 0`** —
一个与五个客户端字**不相交**的集合。**它从不检查五个客户端字。**

| | 上电 / 刷新（`FUN_c0504ccc` → `FUN_c0504fc8`） | 掉电 / 折叠（`FUN_c0505308`） |
|---|---|---|
| per-client 静止（`ba4/ba8/bac/bd8/be0 & 7 == 0`） | **是**（5 个循环，×2 次调用） | **否** |
| 其他状态等待 | `b98&3, b9c&3, ba0&3, bbc==0, b94&0x3000, b94>>14&7, 0x404&0x10` | `b94（低字节）==0, 0x404&0x1e==0` |
| 重置共享预算 `DAT_c28602fc` | **否** | **是**（`:862803`） |

---

## 4. 不对称性，精确表述

1. **不同的前提条件。** 上电强制 per-client 释放（五个字 `& 7 == 0`）；
   折叠不强制相同条件 — 它在*不同的*一字对上进行折叠。
2. **单向预算。** 45 000 次自旋的断言预算（`DAT_c28602fc`）**仅**由折叠
   （`FUN_c0505308` `:862803`）重置。上电路径从不重置它，因此
   上电序列中的每个等待 — `FUN_c0500d4c` 中的 message-0x1d ack 自旋、
   `FUN_c0504ccc` 中的多次寄存器等待，以及五客户端静止 — **共享**
   一个预算。

---

## 5. 这如何产生 `a2_power.c:1189`

主导假设（与观察到的 A2 频繁切换触发的崩溃一致）：

1. 在 `control=auto` 下，A2 大约每 8 s 循环掉电/上电（测量值：
   `pc_vote/unvote` ≈ 62/61，在 488 s 内）。
2. 折叠（`FUN_c0505308`）**不**等待五个客户端字，因此它可能在某个客户端字
   仍为 `& 7 != 0` 时完成 — AP 的客户端仍持有 A2。
3. 下一次上电（`FUN_c0504fc8`）在该客户端字上自旋。该自旋与所有其他上电等待
   共享单个 45 000 次自旋预算，因此它比单独在该字上自旋 45 000 次更早触发断言。
4. `FUN_c05042c8` 触发 `a2_power.c:1189` → 调制解调器崩溃；AP 随后约 2 s 看到
   `bam-dmux` down-ack / pc-ack 超时（后果，而非原因）。

在观察到的致命 coredump 中，卡住的是 `_DAT_ec320bac & 7 == 1`。

AP 侧 A/B **排除了**替代的"交叉投票 / AP 握手竞态"解释：补丁 834 完全移除了
恢复超时，但致命率不变，且致命总是先于其超时。无论出了什么问题，都**在
调制解调器内部的折叠↔上电握手中**，并且它需要折叠实际发生 —
这就是为什么固定 `control=on`（不折叠）能消除它。

---

## 6. 已证实 vs 待定

**已证实（从反汇编读出）：**
- `a2_power.c:1189` 断言位于 `FUN_c05042c8`，预算 `DAT_c28602fc > 900`
  （≈ 45 000 次自旋）。
- 五客户端静止（`ba4/ba8/bac/bd8/be0 & 7 == 0`）**仅**存在于
  上电路径（`FUN_c0504fc8`，从 `FUN_c0504ccc` 调用）。
- 折叠路径（`FUN_c0505308`）等待一个**不相交**集合（`b94`，`0x404`），
  从不等待五个客户端字。
- 预算 `DAT_c28602fc` **仅**由 `FUN_c0505308`（`:862803`）重置。

**待定：**
- 五个字中哪个是 AP 的客户端，以及每个由什么置位/清零（`0xec320bac`
  是观察到的致命时的卡住者）。
- 折叠*实际上*是否在失败周期使某个客户端字保持置位（需要跨折叠的
  `0xec320bXX` 逐边沿追踪 — 尚未捕获；驱动的 `dev_dbg` 不可用，
  `CONFIG_DYNAMIC_DEBUG` 未设置）。
- 预期设计是折叠应使客户端静止（使上电检查冗余），还是客户端可以合法地
  跨折叠保持，而上电应容忍它。

---

## 7. 候选的调制解调器侧修复（未尝试）

使折叠**对称**：在 `FUN_c0505308` 中，完成前等待与 `FUN_c0504fc8` 所要求的
相同五个客户端字达到 `& 7 == 0` — 这样客户端就不会在跨折叠时保持未静止。
（替代方案：在上电开始时重置共享预算 `DAT_c28602fc`，使缓慢折叠不会使其耗尽。）

**为何未做：** 这是**基带（`modem.bNN`）补丁**。项目 SOP 将基带更改视为高风险
（MPSS RSA 认证、段签名陷阱 — 见 `reference_mdt_segment_auth_trap.md`），
且已交付的 AP 侧引脚保持已提供无崩溃设备（0 致命 / 1857 s）。此处记录为
*真正的*根因修复候选，而非已尝试。

---

## 验证 / 可复现性

```bash
F="Docs/Modem Stability/Modem RE/hmu05/modem_full_decompiled.c"

# the assert helper + budget
sed -n '862146,862168p' "$F"

# the five-client quiesce (only in the bring-up path)
grep -n "ec320ba4\|ec320ba8\|ec320bac\|ec320bd8\|ec320be0" "$F"

# the budget counter: incremented 862157, tested 862161, reset ONLY 862803
grep -n "DAT_c28602fc" "$F"

# the collapse path (waits b94 / 0x404, no client words)
sed -n '862791,862900p' "$F"

# resolve the assert descriptor to its message
python3 scratch/a2_descr.py scratch/coredump_live/modem_coredump_up919.52.elf 0xc3c1f3a0
#   -> a2_power.c:1189  id=64  file='a2_power.c'  msg='A2 Assertion Failed'
```

**SOP 声明。** 仅离线 RE；未写入任何基带。所有地址/行号均来自反编译的
原厂 HMU05 调制解调器和实际 coredump 的描述符数据库；单向预算重置和不相交字
集合已通过对五个客户端字和 `DAT_c28602fc` 的穷举 `grep` 确认（无其他写入者）。
因果步骤（§5）标记为假设，与两个独立的实际结果一致（AP 侧修复的 A/B
阴性，以及 `control=on` 引脚保持消除致命错误）。
