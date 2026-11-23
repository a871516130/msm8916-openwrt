# HMU05 约 900 秒调制解调器致命错误 —— 用户指南：选择你的修复方案

**状态：** ✅ 当前有效 —— 面向用户的指南。
**日期：** 2026-10-07
**适用于：** HMU05（`hmu05,250605v0s`）—— MSM8916 / Snapdragon 410
**账本：** `197_UZ801_PORT_LEDGER_AND_MANDATORY_SOP.md` §112.162、§112.165–§112.171
**另见：** `HMU05_900S_FATAL_FIX_OPTIONS_AND_DECISION.md`（理由记录）

> **两条受支持的路径。** **默认**路径 —— 已在已发布镜像中 —— 是纯软件
> **`himi-ok-guard`**（路径 A）。**基带二进制补丁**作为**可选**提供给偏好它的用户
> （路径 B）。本指南展示如何**自己执行路径 B**；
> **二进制补丁代码刻意不在此分支中发布**（见 §3 的框）。

---

## 0. 快速摘要 —— 二选一

| 你想要… | 执行这个 |
|---|---|
| 无需基带改动的修复 | **什么都不做。** 路径 A 已在镜像中启用。在 §2.2 验证。 |
| 基带补丁路线 | 跟随 **§3**（可选、手动、修改你的调制解调器固件）。 |
| 完全不要修复 | 禁用守卫 —— §2.3。 |

---

## 1. 约 900 秒致命错误是什么（一段话）

调制解调器的 RF 任务读取 **NV 项 2500**（`NV_FACTORY_DATA_4_I`）并对其与字面量
**`"HiMI_OK"`** 执行 `memcmp()`。当它**不**匹配时，任务走其 *"get imei will stop"* 分支并等待
（出厂 **600000 ms = 600 s**），随后约 900 秒截止时间所建立其上的 ML1 致命错误触发
（`lte_ml1_common_timer.c:390`）。项 2500 在**每次调制解调器启动时被清零**，因此任何从不
重写它的 AP 都会让调制解调器在热重启后约 900 秒致命错误。约 900 秒 = **约 300 秒锚点 +
600 秒等待**（调制解调器时钟）。

恰好有两种方法可以停止它：

- **A —— 使比较通过**（从 AP 侧重写 `HiMI_OK`）。根因修复。**默认。**
- **B —— 将等待远远推迟到未来**（补丁 600000 ms 常量）。一种延迟。

---

## 2. 路径 A —— 纯软件 `himi-ok-guard`（默认，已发布）

### 2.1 工作原理

一个小服务（`/usr/sbin/himi-ok-guard`，由 `/etc/init.d/himi-ok` 启动）经
`/usr/sbin/diag_nv` 通过 `/dev/rpmsg0` 轮询调制解调器，读取 NV 项 2500，并且 —— 若该
128 字节项**全零**（且尚非 `"HiMI_OK"`）—— 写回 `"HiMI_OK"`。它持续重新检查，
因此覆盖冷启动*和*每次 SSR/崩溃重启，且若调制解调器再次清空该项则自我修复。
当 `memcmp` 通过时，**截止时间永远不会触发**。

> **安全性（2026-10-09）：** 项 2500 是一个通用出厂数据项。守卫仅在该项读回**全零**时写入，
> 因此它永远不会覆盖在其他位置存储其他内容的调制解调器上的真实出厂数据。非零、
> 非 `HiMI_OK` 内容保持不变（记录一次警告）。DIAG 访问在 `/var/lock/himi-ok-diag.lock` 上
> 串行化，因为 `/dev/rpmsg0` 是独占打开。

它由 `board_name` 门控到**出现**该致命错误的板卡 —— `*hmu05*`、`*uz801*` 和 `*uf02*`
（三者携带相同 HiMI 基带且需要相同修复）—— 因此在其他每块板卡上都是惰性的。
门控位于 `/lib/himi-ok.sh`；它刻意*不是*“每块 HiMI 基带板卡”，因为 UFI001B（V2.0）
携带相同的基带系列但不出现该崩溃。

### 2.2 验证它在运行

```sh
# 服务状态
/etc/init.d/himi-ok status
logread | grep himi-ok-guard | tail

# 项 2500 当前是否为 "HiMI_OK"？
/usr/sbin/diag_nv read 2500

# 调制解调器（重新）启动后，守卫应仅在项被清空时记录一次写入：
logread | grep "item 2500 was cleared"
```

### 2.3 启用 / 禁用

```sh
# 禁用（例如测试原始故障，或如果你运行路径 B）
uci set modem-watchdog.recovery.himi_ok_enabled='0'
uci commit modem-watchdog
/etc/init.d/himi-ok restart

# 重新启用
uci set modem-watchdog.recovery.himi_ok_enabled='1'
uci commit modem-watchdog
/etc/init.d/himi-ok restart
```

调优：`modem-watchdog.recovery.himi_ok_interval`（检查间隔秒数；默认 **20**，最小 5）。

**板卡门控。** 守卫运行在出现该致命错误的板卡上（`*hmu05*`、`*uz801*`、`*uf02*`）。
另一块共享 HiMI 基带但不出现该崩溃的板卡（例如 `ufi001b`）不在列表中 —— 如果你想双保险，
显式启用它；全零安全检查使这样做是安全的：

```sh
uci set modem-watchdog.recovery.himi_ok_boards='*hmu05* *uz801* *uf02*'
uci commit modem-watchdog
/etc/init.d/himi-ok enable && /etc/init.d/himi-ok restart
```

### 2.4 回退

按 §2.3 禁用它。未更改其他任何东西 —— 路径 A **不**触及基带。

---

## 3. 路径 B —— 基带二进制补丁（可选，你来做）

> ⚠️ **本节是指令，不是已发布代码。** 项目**不**将补丁器添加到本分支：镜像中无
> `hmu05-patch-modem` 源码、无 Makefile 构建、无启动钩子。如果你想要这条路，你自己应用它，
> 并自行承担后果。退役实现可从 git 历史恢复
> （`git show 57024f2^:packages/msm-firmware-dumper/src/hmu05-patch-modem.c`），
> 如果你想构建自己的自动化。

### 3.1 它改变什么，以及它是什么（不是什么）

它重写 `modem.b16` 中的**一个 8 字节常量** —— RF 任务的事件等待超时 —— 从 `600000 ms`
（10 分钟）改为 `0x7fffffff ms` ≈ **24.855 天**，并重新签名固件使 MPSS 认证仍然通过。

- 它是**延迟**，不是修复：截止时间仍会触发，只是约 24.9 天后。除非 NV 项被（重新）写入，
  调制解调器仍会最终遭遇同样的故障。
- 它修改你的**基带**。一个错误可能在恢复出厂固件前让调制解调器不可用（见 §3.7）。

### 3.2 先决条件与备份

- 设备上的 root shell，从 Linux 主机 `scp`/`ssh`。
- 主机需要 `dd`、`sha256sum`、`xxd`。
- **先备份。** 固件位于设备的 `/lib/firmware`：

```sh
mkdir -p ~/hmu05-patch && cd ~/hmu05-patch
scp root@<device-ip>:/lib/firmware/modem.b16 .
scp root@<device-ip>:/lib/firmware/modem.b01 .
scp root@<device-ip>:/lib/firmware/modem.mdt .
cp modem.b16 modem.b16.bak; cp modem.b01 modem.b01.bak; cp modem.mdt modem.mdt.bak
```

你始终可以用 §3.7 重新生成出厂文件，但无论如何保留此备份。

### 3.3 在 `modem.b16` 中修补常量

位置是 **`modem.b16` 文件偏移 `0x00AD8160`**（VA `0xc0d5f160`，基址 `0xc0287000`）。

```sh
# 1) 确认出厂字节（必须打印：9f64 0000 00c0 0078）
xxd -s 0xAD8160 -l 8 modem.b16

# 2) 写入补丁后字节  r0 = ##0x7fffffff  (0x7fffffff ms ≈ 24.855 天)
printf '\xff\x7f\xff\x07\xe0\xc7\x00\x78' | dd of=modem.b16 bs=1 seek=$((0xAD8160)) conv=notrunc

# 3) 确认
xxd -s 0xAD8160 -l 8 modem.b16   # 预期：ff7f ff07 e0c7 0078
```

### 3.4 重新签名（`modem.b01` / `modem.mdt`）

固件使用逐段 SHA-256 表。`modem.mdt = modem.b00 ‖ modem.b01`，且 `len(modem.b00) = 916 (0x394)`；
段 *n* 的哈希位于 `modem.b01 + 0x28 + 32·n`，即 `modem.mdt + 0x3bc + 32·n`。因为我们只改变了
段 **16**（`modem.b16`）：

```sh
h=$(sha256sum modem.b16 | cut -d' ' -f1)      # 补丁后的 modem.b16 的 SHA-256

# modem.b01 中段 16 的哈希槽位 (0x28 + 32*16 = 0x228)
printf '%s' "$h" | xxd -r -p | dd of=modem.b01 bs=1 seek=$((0x228)) conv=notrunc

# modem.mdt 中相同的字节 (0x394 + 0x228 = 0x5bc)
printf '%s' "$h" | xxd -r -p | dd of=modem.mdt bs=1 seek=$((0x5bc)) conv=notrunc
```

> 如果你改变**不同**的段（例如一个 `modem.b05` 补丁），也重新哈希**该**段：
> 它在 `modem.b01` 中的槽位是 `0x28 + 32·n`。一个未重新哈希的段会让调制解调器以
> `MPSS authentication failed: -19` 失败。

### 3.5 部署并重启

```sh
scp modem.b16 modem.b01 modem.mdt root@<device-ip>:/lib/firmware/
ssh root@<device-ip> 'sync; reboot'
```

`/lib/firmware/DUMPED` 已存在，因此 `msm-firmware-dumper` 将**不**重新转储并覆盖你的文件。

### 3.6 验证

```sh
# 设备上，回来后
dmesg | grep -i "fatal error"          # 预期无输出
dmesg | grep "modem subsystem failure reason"   # 预期无输出
mmcli -m 0 | head                      # 调制解调器存在
uptime                                 # 在数据承载建立下观察超过 1000 s
```

决定性的检查只是时间：补丁后，约 900 秒处不应出现 `lte_ml1` 致命错误。

### 3.7 恢复到出厂固件

最干净的恢复是重新运行转储器，它会从设备自身的 `modem` 分区将出厂 blob 拷贝回来：

```sh
ssh root@<device-ip> 'rm -f /lib/firmware/DUMPED && reboot'
```

（`msm-firmware-dumper` 看到标记消失，从 `modem` 分区重新转储 `modem.*`，然后再重启一次。）
你也可以重新刷写出厂固件。

### 3.8 使补丁在 `sysupgrade` 后存活

**它本身不能存活。** `/lib/firmware` 位于 **overlay** 上，而非 sysupgrade 镜像中；
`sysupgrade -n` 会清空 overlay，`msm-firmware-dumper` 在下次启动时从**出厂** `modem` 分区
重新创建 `/lib/firmware` —— 丢弃你的补丁。

两种处理方式：

1. **每次 `sysupgrade` 后手动重新应用**：重复 §3.2–§3.5。简单，无需额外代码。
2. **自动化重新应用**，添加你自己的补丁器 + 钩子（项目的退役机制）：
   补丁器从 `msm-firmware-dumper.sh`（转储后、`sync` 前）和 `99-msm89xx-firstboot` 运行，
   因此它在每次供给时重新应用。因为 `sysupgrade -n` 清空 overlay，自动化钩子必须**位于
   镜像中** —— 即你必须构建包含补丁器自己的固件。完整机制、精确钩子片段和适配记录在
   [`HMU05_900S_FATAL_FIX_OPTIONS_AND_DECISION.md`](HMU05_900S_FATAL_FIX_OPTIONS_AND_DECISION.md) §3。

---

## 4. 你应该选择哪个？

| | **A —— `himi-ok-guard`**（默认） | **B —— 基带二进制补丁** |
|---|---|---|
| 性质 | 根因修复 —— 截止时间永不触发 | 延迟 —— 截止时间约 24.9 天后 |
| 触及基带 | 否 | 是（并重新签名它） |
| 风险 | 对调制解调器固件无风险 | 若错误签名则有 MPSS 认证 / 变砖风险 |
| 在 `sysupgrade` 后存活 | 是，天然（在镜像中） | 否 —— 手动重新应用（§3.8） |
| 工作量 | 零（已启用） | 手动，每设备、每次重新刷写 |
| 回退 | 一个 `uci` 键 | 重新转储出厂（§3.7） |

**建议：使用路径 A。** 仅当你确实需要调制解调器在运行时固件不被 AP 触及，或你在做实验时，
才选择路径 B —— 并把它当作限时延迟，而非治愈。

---

## 5. 警告

- **路径 B 前备份 `/lib/firmware`。** 一次糟糕的重新签名会让调制解调器无法认证
  （`MPSS authentication failed: -19`）。
- **不要编辑任意的 `modem.bNN` 文件。** 某些段携带 RSA 签名 + 证书链；改变一个你未重新哈希
  的段即使 `modem.b01` 看起来正确也会破坏认证。
- **路径 B 未发布，且不被构建支持。** 你自己应用它；本分支中的任何更新都不会替你携带它。

---

## 6. 参考 —— 精确偏移与字节

| 项 | 值 |
|---|---|
| 补丁位置（VA） | `0xc0d5f160`（在 `modem.b16` 中） |
| `modem.b16` VA 基址 | `0xc0287000` |
| `modem.b16` 文件偏移 | `0x00AD8160`（= `0xc0d5f160 − 0xc0287000`） |
| 出厂字节 | `9f 64 00 00 00 c0 00 78`（`r0 = ##0x927c0` = 600000 ms） |
| 补丁后字节 | `ff 7f ff 07 e0 c7 00 78`（`r0 = ##0x7fffffff` = 2147483647 ms ≈ 24.855 天） |
| 哈希表基址 | `modem.b01` + `0x28`，步长 `32` |
| 段 16 槽位 | `modem.b01` @ `0x0228` == `modem.mdt` @ `0x05bc` |
| `modem.mdt` 布局 | `modem.b00 ‖ modem.b01`，`len(modem.b00) = 916 (0x394)` |

---

## 7. SOP 合规声明

- **固件修改（已发布）：** 无。路径 A 仅 AP 侧用户空间；本分支不包含基带补丁器、
  无 `modem.b16` 构建步骤、无补丁器钩子。
- **本指南：** 仅记录用户应用的过程。它不向树中添加可执行代码。机制已对照出厂 HMU05
  真实基准（在线连接的 coredump + `modem_full_decompiled.c`）和 git 历史中的退役实现确立。
- **重新签名：** 偏移和方案已对照当前工具验证（`modem.mdt = modem.b00 ‖ modem.b01`，
  `len(modem.b00) = 916`；`modem.b01 @ 0x0228` == `modem.mdt @ 0x05bc` == 段 16 的 SHA-256）。
- **错误/限制已陈述，未隐瞒：** 路径 B 是延迟，不是治愈；它本身不能在 `sysupgrade` 后存活。

---

## 8. 达成 vs 预期

| 目标 | 预期 | 达成 |
|---|---|---|
| 默认修复存在，无基带改动 | 守卫在镜像中，HMU05 门控 | ✅ `himi-ok-guard` + `init.d/himi-ok` + `97-himi-ok`（在构建的 rootfs 中验证） |
| 用户可选择软件路径 | 无需重新刷写即可启用/禁用 | ✅ `uci set modem-watchdog.recovery.himi_ok_enabled` |
| 用户可选择二进制路径 | 可复现、精确的配方 | ✅ §3：位置、字节、重新签名、部署、验证、回退 |
| 二进制代码保持在分支之外 | 未添加补丁器源码/Makefile/钩子 | ✅ 仅指令；代码可从 `57024f2^` 恢复 |
| 诚实说明限制 | 陈述延迟 + sysupgrade 注意事项 | ✅ §3.1、§3.8、§5 |
