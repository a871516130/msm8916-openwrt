# WCN36XX / mifib-v12 —— 内核内存损坏与自发性重启

**状态：开放——调查中（浸泡进行中）。** 首次观察到 2026-10-29，位于 `mifib-v12`（`HM-MIFIB-V12`，25.12.6-r2，内核 6.12.112，backports 6.18.55）。

本文档记录关于**重复的内核内存损坏**迄今已知的一切，该损坏曾让单元重启一次（panic），并自那以后每次启动都产生 oops/警告。它刻意以证据优先：什么是已证明的、什么是怀疑的、以及什么能区分两者。

---

## 1. 用户看到了什么

单元在 **2026-10-29 06:35:58** 约 8 小时 12 分钟正常运行时间后自行重启。重启后 station 模式从未启动：`wpa_supplicant` 每秒一次记录 `CTRL-EVENT-SCAN-FAILED ret=-16` 直到永远，`wifi-sta-up` 每 90 秒回收 STA vif。（第二个问题是独立的、现已修补的驱动 bug——见 §7。）

---

## 2. 启动 A —— panic（正常运行时间 29 630 s）

```
[29630.459423] Internal error: Oops: 0000000096000004 [#16] PREEMPT SMP
[29630.524090] CPU: 3 UID: 0 PID: 1 Comm: procd
[29630.564611] pc : kmem_cache_alloc_noprof+0x78/0x340
[29630.790886] Kernel panic - not syncing: Attempted to kill init! exitcode=0x0000000b
[29631.084583] Rebooting in 3 seconds..
```

本次启动的第 16 个 oops 落在 **PID 1（procd）内的 `execve()`** 中。按设计杀掉 init 是致命的，所以内核 panic 并在 3 秒后重启。重启是*后果*；故障是 oops。

### 2.1 故障是一个被损坏的 `struct kmem_cache *`

9 秒内 15 个 oops（29 621 → 29 630 s），每一个完全相同：

```
fault : 0x006f5548f8fe59bc        (== x19 + 0x80)
x19   : 7d6f5548f8fe593c          (identical in 13 of 13 allocator oopses)
pc    : kmem_cache_alloc_noprof+0x78/0x340
```

注意坏指针的形状：**低半部分看起来像内核堆地址**（`…f8fe59xx`；真实堆是 `ffff184f…`），而**高半部分是垃圾**（`7d6f5548`）。那是*对指针上半部分的一次乱写 4 字节*，不是单比特翻转。

每个回溯都终止在相同位置：

```
execve → alloc_bprm → insert_vm_struct → vma_link → mas_preallocate
       → mas_node_count_gfp → mas_alloc_nodes → kmem_cache_alloc_noprof
clone  → copy_mm → __mt_dup → mas_dup_build → mas_alloc_nodes
       → kmem_cache_alloc_noprof
```

**两条路径都是 maple-tree 节点分配**——即相同的全局缓存指针（`maple_node_cache`），不是 13 个独立损坏。内核 BSS/data 中的一个 8 字节字段受损，之后每次 maple-node 分配都崩溃。

### 2.2 之前发生了什么（约 1.2 小时前）

```
[22958.876938] wcn36xx: ERROR hal_delete_bss response failed err=5
[22958.886615] wcn36xx: ERROR hal_remove_bsskey response failed err=16
[22958.959213] wcn36xx: WARNING BSS or STA with addr be:29:f6:6a:de:6e not found
[22959.214977] WARNING: CPU: 0 ... net/mac80211/rx.c:5354 ieee80211_rx_list
```

接下来 13 分钟有 **42** 个这样的 mac80211 警告，全部来自 `ieee80211_handle_queued_frames` → `ieee80211_rx_napi` → `ieee80211_rx_list`，且 `phy0-sta0` 正在重新认证（`Reason: 9=STA_REQ_ASSOC_WITHOUT_AUTH`）。驱动正在把 RX 帧交给一个已停止的设备。

---

## 3. 同一启动，7.8 小时前 —— vmap 损坏先来（856 → 1 540 s）

> **更正（2026-10-29）。** 本节原标题为"启动 B —— 再次损坏，不同子系统"，日期 06:35:58 → 07:19。pstore 证据显示这些事件属于**启动 A**，那个在 29 630 s panic 的启动。oops 计数器是按启动的并从 1 开始，所以它解决了归属：
>
> * `dmesg-ramoops-0` = `Oops#1 Part1` —— 1 540 s 的 oops；
> * `dmesg-ramoops-1` = `Oops#16 Part1`，其正文包含 29 621–29 622 s 处的 `[#2] … [#16]`。
>
> 一个启动不可能不先发出 #1 就发出 #2…#16，所以 1 540 s 的 oops 与致命爆发是**同一个启动**。控制台记录独立解决：`console-ramoops` 转储在 **panic 时**写入，所以 `console-ramoops-0` 属于在 29 630 s panic 的那个启动——它包含 856 s / 929 s 的警告*以及* 1 540 s 的 oops #1。它在那里结束只是因为控制台区在那次非常大的 oops 转储时填满且不环绕。
>
> 挂钟时间（启动 A 约于 2026-10-28 22:22:08 开始）：856 s ≈ 22:36，929 s ≈ 22:37，1 540 s ≈ 22:47，29 630 s = 06:35:58。

```
[ 856.443255] WARNING: CPU: 0 PID: 6223 at mm/vmalloc.c:1950 alloc_vmap_area
[ 929.368919] vmalloc bug: 0x200000200000000-0x4 overlaps with 0x1-0xffff800080000000
[ 929.372790] WARNING: CPU: 2 PID: 18778 at mm/vmalloc.c:1195 reclaim_list_global
```

`mm/vmalloc.c:1195` 是 `WARN(1, "vmalloc bug: … overlaps with …")`；`:1950` 是 `va_size/va_start/va_end` 健全性检查。`va_start = 1` 且 `va_end = 0xffff800080000000` 的 `vmap_area` 不是合理对象。

然后本次启动的第一个 oops：

```
Unable to handle kernel paging request at virtual address 0000ffff97495000
Internal error: Oops: 0000000096000006 [#1]
CPU: 2 PID: 1585 Comm: wifi-sta-up
pc : insert_vmap_area_augment.constprop.0+0xb8/0x24c
```

被插入为 `vmap_area` 起点的地址是**用户空间虚拟地址**（`0x0000ffff97495000`，在 48 位用户范围内）。持有用户 VA 的内核 `vmap_area` 是**释放后使用然后页复用**的经典签名，而非随机比特翻转。

**所以形状是一个启动、两个阶段**——约 1 540 s 时 `vmap_area` 损坏，约 7.8 小时后 `maple_node_cache` 全局损坏。那是*一个*乱写者在一个启动中命中两个分配器结构，不是两个启动上的两个无关事件。

启动 B（06:35:58 → 07:19）**没有**留下自己的 pstore 记录，所以它没有 panic——它要么以有意重启结束（加载修补模块），要么以不写 pstore 记录的路径结束（挂起 + 看门狗）。无论哪种，用户在 06:35:58 后看到的扫描楔死是 §7 的 `scan_req` bug，不是内存损坏。

---

## 4. 启动 C —— 当前（07:19:13 开始）

* 约 1 141 s 到约 1 155 s 之间有 19 × `ieee80211_rx_list` WARNING（与 §2.2 相同位置）。
* 截至写作时 0 oops。
* station 在模块重新加载前被 `scan_req` bug（§7）楔死。

---

## 5. 什么是已证明 / 什么不是

**已证明**

1. 重启是由 PID 1 中 oops 导致的内核 panic——不是看门狗、不是用户空间崩溃、不是热、不是 OOM（380 MB 中用 72 MB，swap 未触碰）。
2. 损坏是*结构化的*，不是随机噪声：一个有效低半部分和垃圾高半部分的指针（§2.1），以及一个持有用户 VA 的 `vmap_area`（§3）。
3. 在一个启动内损坏进展：1 540 s 时 `vmap_area` 已坏，29 621 s 时 `maple_node_cache` 全局已坏（§3）。同一写者，两个分配器结构，相隔约 7.8 小时——不是一次性。
4. wifi 驱动在每个受影响启动中都行为异常（停止后交付 RX，固件拒绝 `delete_bss`/`remove_bsskey`）。

**未证明**

* 损坏代理是 wifi 驱动、WCNSS 固件（经 DMA），还是 DRAM 本身。

---

## 6. 假设与区分它们的实验

| # | 假设 | 支持 | 反对 |
| - | ---------- | --- | ------- |
| H1 | **wcn36xx（或它驱动的固件）越界写 / DMA 到陈旧地址。** 它是两个受影响启动中唯一可见地行为异常的东西，且在树外（`wcn36xx(O)`）。 | 解释损坏每次启动落在不同内核结构中；解释 vmap_area 中的用户 VA（从用户缓冲区 DMA 或 memcpy 到错误位置）。 | maple-node 缓存与 `vmap_area` 池并不显然在 wcn36xx 的任意路径上。 |
| H2 | **本单元 DRAM 有缺陷。** | 相同症状形状；便宜的加密狗；损坏广泛且与负载无关。 | 损坏是*结构化*的（有效低半部分、用户 VA）。纯比特腐烂通常是单比特。 |
| H3 | 通用内核/分配器 bug（6.12 vmap 池是新代码）。 | 两次启动命中 vmap 路径。 | 启动 A 命中 maple-node 缓存，它与 vmap 不共享代码。 |

### 区分器：三级阶梯，而非二选一

明显的"无线电关 vs 无线电开"拆分**不**成立，§6 最初在这方面错了。`wifi down` 让模块保持加载、WCNSS remoteproc **运行**——固件已启动，只是空闲。所以干净的无线电关浸泡不能开脱 wifi 栈；它只说明*空闲*路径是干净的。手臂必须是：

| 手臂 | wifi 状态 | 这里崩溃意味着什么 | 干净运行意味着什么 |
| --- | --- | --- | --- |
| **A0** | `rmmod wcn36xx` —— 驱动消失，remoteproc 停止，固件关闭 | 写者**不是** wifi 栈 → H2/H3 | wifi 栈未排除 |
| **A1** | 驱动加载，固件运行，无 vif（空闲） | 固件/驱动**空闲**路径就够 | 需要数据路径 → 前往 B |
| **B** | 无线电启动，STA 关联，流量 | H1 确认：wifi 栈越界写 | H1 在该流量级别被削弱 |

先跑 A1 再 B：它是廉价基线，说明是否根本需要流量。A0 只有在 **A1 与 B 都保持干净**时才值得跑——那是"不是 wifi 栈"成为现实可能性的节点。

每只手臂的注意事项：事件罕见（唯一一次坏启动中是 26 分钟与 8 小时 12 分钟），所以单个干净窗口是弱证据，只有手臂之间的*差异*携带信息。

---

## 7. 独立的、已修复的 bug：`scan_req` 楔死

`wcn36xx_hw_scan()` 把请求存入 `wcn->scan_req`，仅在固件发送扫描完成指示时清除它。如果固件从不应答：

```
$ iw dev phy1-sta0 scan
command failed: Resource busy (-16)
```

…且*每次*之后扫描都被拒绝，所以 station 永远无法重新关联，直到模块重新加载。在本单元上观察到两次。

由 `openwrt-overlay/package/kernel/mac80211/patches/ath/460-wcn36xx-scan-timeout.patch` 修复：

* 若 `wcn36xx_smd_start_hw_scan()` 失败则清除 `scan_req`；
* 扫描开始时武装一个 15 秒 `delayed_work`，到期时清除 `scan_req` 并调用 `ieee80211_scan_completed(aborted=true)`；
* 在固件指示与 `wcn36xx_stop()` 中取消它。

这把永久故障变成 15 秒的小故障。它**不**解决固件首先静默的问题，也不解决 §2/§3 的损坏。

---

## 8. 工具 / 如何重新收集

```sh
# 崩溃启动的控制台（经 ramoops 在重启间存活）
cat /sys/fs/pstore/console-ramoops-0
# oops 记录，每个标记 "Oops#N Part1" / "Panic#N Part1"
head -1 /sys/fs/pstore/dmesg-ramoops-*
# 运行中启动的警告普查
dmesg | grep -cE 'WARNING: CPU|Internal error'
```

pstore 记录会被**下一次崩溃覆盖**，所以浸泡收集器每次启动把它们复制到 `/root/soak/`（见 §9）。

---

## 9. 浸泡

收集器位于 `/root/soak/collect.sh`（追加到 `/root/soak/events.log`，把 pstore 按启动快照到 `/root/soak/pstore-<boot_id>-*`，写 `heartbeat`，对 `warn.prev` 差异警告行）。从 `/etc/rc.local` 挂钩。

### 9.1 手臂 A —— 无线电关（运行中）

启动 `c9ff0c2e-a0b4-403d-aeda-70abb9ff4bd6`，2026-10-29 07:19:14 启动。

| t（正常运行时间） | 事件 |
|---|---|
| 0 – 5682 s（94 分钟） | 无线电**开**，修补的 `wcn36xx.ko`（`eaa69f3a…`），STA 于 08:53:16 关联，DHCP 10.18.242.33 —— **无损坏** |
| 5682 s（08:53:56） | `wifi down` —— phy3 拆除，`wcn36xx` refcnt 0（模块卸载） |
| 5682 s → 现在 | 无线电**关**，驱动未加载 |

12:34 时的状态（正常运行时间 18 909 s / 5 小时 15 分，**无线电关闭 3 小时 40 分**）：

- **无新 oops、无新 vmalloc bug、无新 panic。** `dmesg` 计数：`Internal error` = 0，`vmalloc bug` = 0，`WARNING: CPU` = 19（全部是先前启动日志继承的既有 `ieee80211_rx_list` rx.c:5354 警告；启动后无新增）。
- `events.log` 只含 08:53:55 的基线快照（先前启动的 pstore：`Oops#1 Part1`、`Oops#16 Part1`）。
- 拆除发出三个固件响应失败，无致命：`hal_delete_bss err=5`、`hal_remove_bsskey err=16`、`hal_delete_sta_self err=7` —— 因为 phy 在途中被移除，SMD 响应从未到达。

**第一个数据点（弱但真实）：** 本次启动在**无线电开启且驱动修补的情况下干净运行了 94 分钟**。两个记录的损坏事件在 856 s 与 29 630 s，所以 5682 s 本身还不足以区分——事件罕见，非确定性。

**手臂 B 已武装，2026-10-29 09:45：** `/root/arm_b.sh 11307` 在设备上休眠，并在 **12:53:45 UTC** 触发 `wifi up`，即手臂 A 恰好运行满 4 小时。然后用 `USR1` 轻推 `uplink-manager`，转储 `iw dev` / `ip -br addr` 到 `/root/soak/arm_b.log`，并追加标记到 `events.log`。

在 4 小时而非 8 小时切断手臂 A 的理由：唯一一次坏启动中事件在 26 分钟与 8 小时 12 分触发，所以 4 小时无线电开窗口有不错的机会捕捉它，而 4 小时无线电开崩溃对 4 小时无线电关干净已经是差异。若手臂 B 在 16:54 也干净，两个手臂都会被延长而非结论。

⚠ 定时任务活在设备上；**12:53 前重启会取消它**。任何重启后检查 `ps | grep arm_b` 或 `/root/soak/arm_b.log`。

### 9.2 H2 侧检 —— 内存校验，并发运行

H2（坏 DRAM）否则只能通过换板测试，所以它并行用 `stress-ng --vm 1 --vm-bytes 96M --vm-keep --verify` 检查 3 小时（`/root/soak/memtest.log`）。`stress-ng` 0.19.04 用 OpenWrt 工具链从 feed 交叉构建，从 `/tmp/mt` 带 `LD_LIBRARY_PATH` 运行（五个库：libaio、libbsd、libjpeg、libkmod、libsctp）——没有东西安装进包数据库，所以 `/overlay` 未触碰，手臂完全可逆。

如何解读：

* **verify-mismatch / failed > 0** → 对 H2 决定性，停止并换板；
* **干净 3 小时** → 仅*暗示性*地反对 H2。测试只证明它持有的 96 MB 用户页；限于内核自身页的故障不会显现。

**结果（2026-10-29 12:14）：干净。**

```
vm   94601749  10800.05  10696.86  4.45   8759.38  8840.20
skipped: 0   passed: 1   failed: 0   metrics untrustworthy: 0
successful run completed in 3 hours
```

94.6 M 次模式写/校验周期，覆盖相同 96 MB 持续 3 小时，零不匹配。这**不**排除 H2——它覆盖四分之一的 RAM 且仅用户页——但严重的 DRAM 故障现在不太可能，且这 3 小时内没有任何东西干扰内核。

混淆因素，预先说明：这只手臂给手臂 A 的窗口增加了一个忙碌核心。若现在出现损坏则含混（负载 vs DRAM）；干净结果不受影响。

### 9.3 手臂 B —— 无线电开：38 分钟后 PANIC

手臂 B 按计划在 **12:55:16（正常运行时间 20 162 s）** 触发——`wifi up`，radio0 开，STA 关联到 `hidden1`，DHCP 10.18.242.33，AP `OpenWrt` 发信标。

**38 分 15 秒后盒子 panic：**

```
[22457.483253] Kernel panic - not syncing: corrupted stack end detected inside scheduler
[22457.483510] CPU: 1 UID: 0 PID: 23288 Comm: basename Tainted: G        W  O
[22457.503008] Call trace:
[22457.522805]  panic+0x12c/0x308
[22457.526163]  schedule+0x0/0xbc
[22457.529052]  do_task_dead+0x44/0x48
[22457.532108]  do_exit+0x5a0/0x8e8
[22457.535484]  do_group_exit+0x30/0x8c
[22457.542514]  invoke_syscall+0x50/0xf0
[22457.818092] Rebooting in 3 seconds..
```

`__schedule()` 中的 `task_stack_end_corrupted()`：PID 23288 内核栈顶部的 `STACK_END_MAGIC` 字被覆盖，所以这次受害者是**任务栈**——继 `vmap_area`（1 540 s）与 `maple_node_cache` 全局（29 621 s）之后的第三个不同受害者。同类故障，不同结构。

整个启动的时间线：

| 正常运行时间 | 状态 | 结果 |
| --- | --- | --- |
| 0 → 5 682 s | 无线电开（启动默认） | 1 108–1 155 s 处 19 × `ieee80211_rx_list` WARN，无崩溃 |
| 5 682 → 20 162 s | **无线电关**（手臂 A，4 小时 1 分） | 干净 |
| 20 162 → 22 457 s | **无线电开**（手臂 B，38 分钟） | **panic** |

**这说了什么、没说什么。** 这是首次崩溃在*同一*启动中被长的干净窗口括住，且发生在无线电回来 38 分钟后——这真实支持 H1。但同一启动的最初 95 分钟也运行无线电开且保持干净，所以仅"无线电开"不够：崩溃发生在**4 小时空闲后的无线电重新初始化**之后，这与自启动就一直开启的无线电不同。可能的解读，尚无排除：

* 损坏是累积的且需要无线电活动来累积（95 分钟只是不够，第二个窗口有 4 小时的先手）；
* `wifi up` 重初始化路径留下陈旧状态（§2.2 的 `ieee80211_rx_list` 停止后交付正是那种形状）；
* 巧合——事件罕见，38 分钟是一个样本。

时钟说明：在手臂 B 带来上行链路且 NTP 于重启时校正之前，设备的挂钟快了约 9 分钟。以上所有时间都是**正常运行时间**，是精确的。

### 9.4 第二次无线电开启动 —— 再次崩溃（38 分钟 → 66 分钟）

§9.3 之后的重启以无线电**开**（自动启动）上来，即"自启动无线电开"条件，又崩溃了：

```
[ 3009.575185] Unable to handle kernel paging request at virtual address 001b84daa1e2358b
[ 3009.623857] Internal error: Oops: 0000000096000004 [#8]
        ... 44 oopses ...
[ 3957.613770]  copy_mm+0x1a4/0x778
[ 3957.616809]  copy_process+0x814/0x1230
[ 3957.620396]  kernel_clone+0x48/0x378
[ 3957.736137] Kernel panic - not syncing: Attempted to kill init! exitcode=0x0000000b
```

与其余同类——一个乱指针（`0x001b84daa1e2358b`，不是有效内核地址），这次经 `copy_mm` 在 `fork()` 中杀死 PID 1。

**计分板现在读作：**

| 条件 | 时长 | 结果 |
| --- | --- | --- |
| 无线电关 | 4 小时 1 分（一次启动） | 干净 |
| 无线电开 | 38 分钟（4 小时空闲后） | panic |
| 无线电开 | 50 分钟 → 66 分钟处 panic（自启动） | panic |
| 无线电开 | 95 分钟（§9.3 启动的第一个窗口） | 干净——异常值 |

两个连续的无线电开启动约一小时内死亡；唯一长的无线电关窗口没有。H1 现在以明显优势是首要假设。95 分钟干净窗口仍无法解释，这也是它还不是结论的原因。

---

### 9.5 第三次无线电开启动 —— 3 小时 47 分干净，H1 削弱

下一次启动（2a01696f）**自启动无线电开运行 13 655 s（3 小时 47 分）**，最后一次检查浸泡时仍干净：经无线电 200 MB rx / 48 MB tx，客户端 -36 dBm，零 oops，35 个 `ieee80211_rx_list` WARN 全部说明（见下文）。这是本单元记录的最长干净无线电开窗口，直接与 H1 相对。

更新的计分板：

| 条件 | 时长 | 结果 |
| --- | --- | --- |
| 无线电关 | 4 小时 1 分（一次启动） | 干净 |
| 无线电开 | 38 分钟（4 小时空闲后） | panic |
| 无线电开 | 50 分钟 -> 66 分钟处 panic（自启动） | panic |
| 无线电开 | 95 分钟（9.3 启动的第一个窗口） | 干净 |
| **无线电开** | **3 小时 47 分，200 MB rx** | **干净** |

所以"无线电开"在此证据上既不必要也不充分：两次 panic 发生在无线电开启动，但两个最长干净窗口也如此。95 分钟窗口不再是需要解释的异常值——它是干净一侧的小端。仍把 panic 与干净启动区分开的东西未识别，"无线电活动"作为朴素相关不在此样本中成立。

#### 35 个警告，根因（并已修复）

全部 35 个是 `mac80211` `rx.c:5354 ieee80211_rx_list`，即 `WARN_ON(!sband)`——不是 `WARN_ON_ONCE`，所以它重复。它们以 276 ms 间隔的约 20 帧突发到达（本次启动中 8 673-8 688 s 与 11 355-11 369 s）。

原因：`wcn36xx` 纯粹依据硬件信道号（`bd->rf_band != 1 && hwch <= sizeof(ab_rx_ch_map)`）把从扫描结果学到的帧标记为 5 GHz，不检查设备是否注册了 5 GHz 频段。本单元的 WCN3620 只注册 **Band 1**（`iw phy phy0 info`），所以状态频段是 5 GHz 而 `hw->wiphy->bands[NL80211_BAND_5GHZ]` 为 NULL，`ieee80211_rx_list` 经其 WARN 路径丢弃该帧。修复是 `461-wcn36xx-scan-learn-band-guard.patch`；它在此启动中不是崩溃前兆（35 个警告，存活 3 小时 47 分），所以它是日志噪声与丢帧修复，不是损坏修复。

---

## 10. 后续步骤

1. 完成无线电关浸泡（§6）并在此记录结果。
2. 若 H1：捕获完整的 `slub_debug=FZPU` 或 KASAN 启动——被损坏的*源*对象通常在 KASAN 报告中自报姓名。代价是性能，但本单元已因长浸泡而不可用。
3. 若 H2：换板并重新运行相同浸泡；或运行 `memtester` 数小时（未随镜像提供——需要包）。
4. 考虑原厂 Android 内核（prima/qcacld-2.0）是否在本单元上显示相同损坏——它是相同硅片和相同固件，而厂商驱动是我们唯一的长运行参考实现。
