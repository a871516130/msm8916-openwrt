# HMU05 约 900 秒调制解调器致命错误 —— 修复方案与决策

**状态：** ✅ 当前有效 —— 这是关于著名的约 900 秒调制解调器致命错误*如何*被修复、
以及*为何*选择本方案而非备选方案的权威记录。
**日期：** 2026-10-07
**板卡：** HMU05（`hmu05,250605v0s`）—— MSM8916 / Snapdragon 410
**分支：** `main`（staging：`staging-main`）
**账本：** `197_UZ801_PORT_LEDGER_AND_MANDATORY_SOP.md` §112.162、§112.165–§112.171
**用户指南：** `HMU05_900S_FATAL_FIX_USER_GUIDE.md`（两条路径的分步说明）

> **一句话总结。** 有两种方法可以停止约 900 秒致命错误：**(A)** 修补调制解调器固件，
> 将截止时间推迟约 24.9 天；或 **(B)** 每次调制解调器启动后从 AP 侧重写一个 NV 项，
> 使截止时间永远不会触发。**我们选择了 (B) —— 纯软件 `himi-ok-guard`** —— 因为它修复了
> 根因、不触及基带，且能在 `sysupgrade` 后存活。方案 (A) 被用作证明机制的决定性*实验*，
> 随后退役。

---

## 1. 根因（约 900 秒致命错误究竟是什么）

调制解调器的 RF 任务（`rf_task`，处理器 `0xc0d5efd0`）将 **NV 项 2500**
（`NV_FACTORY_DATA_4_I`）读入 `0xc310dcb0` 处的缓冲区，并对字面量 **`"HiMI_OK"`** 执行
`memcmp()`：

- **匹配** → 任务正常继续。
- **不匹配** → 任务走其 *"get imei will stop"* 分支并等待
  （出厂 **600000 ms = 600 s**），随后才发生 ML1 致命错误，约 900 秒截止时间正是建立在其上
  （`lte_ml1_common_timer.c:390`）。

两个事实使这成为*反复发生*的故障，而非一次性事件：

1. **项 2500 在每次调制解调器启动时被清零。** 其状态为 `0x0000`（PRESENT），但其 128 字节
   全为零。一个从不重写它的 AP 会让调制解调器在**任何热重启**后约 900 秒致命错误 ——
   无论是崩溃恢复的 SSR，还是刻意的干净重启。
2. **该项不在 EFS 中。** 它只能通过**原始 DIAG NV**（经 `/dev/rpmsg0` 的 `0x26` 读 /
   `0x27` 写，工具 `diag_nv`）访问。EFS `/nv` 树（1155 个条目，rfnv id ≥ 20086）不携带它；
   `"HiMI_OK"` 是 `modem.b18` 中的固件字面量。

约 900 秒数字分解为 **约 300 秒锚点 + 600 秒等待 ≈ 900 秒**（调制解调器时钟）。

这一机制已通过单常量 A/B 因果证明（§112.162）：将等待从 `600000` ms 改为 `60000` ms，
使 *"stoped"* 消息和致命错误*两者*都从约 900 秒移动到 **360.687 秒**。

---

## 2. 方案 A —— 调制解调器固件二进制补丁（将等待延长到约 24.9 天）

将 RF 任务的事件等待超时常量改为使截止时间落在约 24.9 天后，而非约 15 分钟。

| | |
|---|---|
| **位置** | `modem.b16` 中的 `0xc0d5f160`（VA 基址 `0xc0287000`；文件偏移 `0xc0d5f160 − 0xc0287000`） |
| **出厂字节** | `9f 64 00 00 00 c0 00 78` = `r0 = ##0x927c0` = **600000 ms** |
| **补丁后字节** | `ff 7f ff 07 e0 c7 00 78` = `r0 = ##0x7fffffff` = **2 147 483 647 ms ≈ 24.855 天** |
| **重新签名** | 将段 16 和 5 重新哈希进 `modem.b01`（哈希头 `0x28`，步长 32），重建 `modem.mdt = modem.b00 ‖ modem.b01` |
| **工具** | `scratch/build_imei_wait.py` |
| **已部署** | 2026-10-06；设备哈希已验证（`modem.mdt d78d1f2f…`）；AP 运行 31 分钟 / 调制解调器约 1860 秒干净 ⇒ 新截止时间约 24.9 天 |

**它是什么：** 一种**延迟**，而非修复。截止时间仍会触发；只是约 24.9 天后才触发。
它还承担了触及基带的全部代价：

- **MPSS 认证风险。** `modem.b01` 在哈希表之后携带 RSA 签名 + 证书链；错误的段哈希会让
  调制解调器以 `MPSS authentication failed: -19` 死掉。（相关陷阱：编辑某些 `modem.bNN`
  *文件*即使 `b01` 哈希验证通过，也会破坏认证。）
- **固件恢复后丢失 —— 但可重新应用。** `sysupgrade -n` 通过 `msm-firmware-dumper` 从 64 MB
  的 `modem` 分区恢复基带，静默回退补丁。可通过自动重新应用使其**在** `sysupgrade` **后
  存活** —— 见 **§3**。
- **本身不以软件方式按板卡门控。** 作为原始字节变更，它是已刷写镜像的一个属性；§3 的钩子
  添加了板卡门控。

---

## 3. 使调制解调器二进制补丁在 `sysupgrade` 后存活（方案 A，如果你选择它）

> 本节存在是为了让刻意想要走**二进制补丁**路线的用户有办法让它经受住固件重新刷写。
> **已发布**的选择仍是方案 B（§4）。退役的实现可从 git 恢复 ——
> `git show 57024f2^:packages/msm-firmware-dumper/src/hmu05-patch-modem.c`。

**问题。** `/lib/firmware` **不**在 sysupgrade 镜像中 —— 它位于可写的 **overlay** 上。
在 HMU05 上，调制解调器 blob 由 `msm-firmware-dumper` 在首次启动时*从设备自身的 `modem`
分区转储*。`sysupgrade -n`（不保留配置）会清空 overlay，因此 `/lib/firmware` 会在下次
启动时从出厂 `modem` 分区重新创建。你手工修补的任何字节因此都会**丢失** —— 除非补丁在
每次固件（重新）供给时被**自动重新应用**。

**项目此前使用的机制**（在 `57024f2` 中退役）。旧的 `hmu05-patch-modem` 补丁器不是试图让
补丁后的字节持久化，而是在**每次供给时重新运行**：

1. 一个小的 HMU05 门控 C 程序，安装于 **`/usr/sbin/hmu05-patch-modem`**，由
   `packages/msm-firmware-dumper/Makefile` 构建（`Build/Compile` →
   `$(TARGET_CC) … -o hmu05-patch-modem hmu05-patch-modem.c`；在 `Package/…/install` 中安装）。
2. **钩子 1 —— 转储器。** `packages/msm-firmware-dumper/files/msm-firmware-dumper.sh` 在它
   完成将 blob 拷贝到 `/lib/firmware` 之后、`sync` 之前立即调用它：
   ```sh
   if [ -x /usr/sbin/hmu05-patch-modem ]; then
     /usr/sbin/hmu05-patch-modem "$FW" && log "HMU05 modem patch check completed"
   fi
   ```
3. **钩子 2 —— 首次启动。** `msm89xx/base-files/etc/uci-defaults/99-msm89xx-firstboot`
   作为双保险调用它：
   ```sh
   if [ -x /usr/sbin/hmu05-patch-modem ]; then
       /usr/sbin/hmu05-patch-modem /lib/firmware
   fi
   ```

由于转储器是**由 `/lib/firmware/DUMPED` 标记守护的一次性操作**，`sysupgrade -n` 之后的
序列是：overlay 被清空 → 标记消失 → 转储器从 `modem` 分区重新转储出厂 blob →
**补丁器重新应用补丁 + 重新签名** → 设置标记 → 重启 → 调制解调器加载补丁后的镜像。
补丁“存活”是因为它在每次供给时被**重新派生**，而非因为字节持久化。

**补丁器做了什么 —— 要复制的结构：**

1. **按板卡门控** —— `is_hmu05_board()` 检查 `/tmp/sysinfo/board_name`、
   `/proc/device-tree/model`、`/proc/device-tree/compatible`；否则退出码 0。
2. **定位**固件目录下的 `modem.b16`、`modem.mdt`、`modem.b01`（`argv[1]`，默认为
   `/lib/firmware`）；任一缺失则退出码 0。
3. **幂等性** —— 若补丁位置已持有补丁后字节，退出码 0（因此重新运行是无代价的，
   且两个钩子都可触发）。
4. **就地修补 `modem.b16`。**
5. **重新签名** —— 重新计算补丁后的 `modem.b16` 的 SHA-256，并写入段哈希表（见下）。
6. 返回；调用者执行 `sync`。

**为方案 A 适配它。** 退役的补丁器在 `modem.b16` 文件偏移 `0x001117e0` 写入的是*已撤回*的
No-Sleep 字节。对于 imei-wait 延迟，你只改**步骤 4**，并保留**步骤 5**：

| | 退役（No-Sleep） | **方案 A（imei wait）** |
|---|---|---|
| `modem.b16` 文件偏移 | `0x001117e0` | `0xc0d5f160 − 0xc0287000 = 0x00AD8160` |
| 出厂字节 | — | `9f 64 00 00 00 c0 00 78`（`r0 = ##0x927c0` = 600000 ms） |
| 补丁后字节 | `00 c4 00 78 00 c0 9f 52` | `ff 7f ff 07 e0 c7 00 78`（`r0 = ##0x7fffffff` = 0x7fffffff ms） |

**重新签名（两者相同）。** 固件使用逐段 SHA-256 表。
`modem.mdt = modem.b00 ‖ modem.b01` 且 `len(modem.b00) = 916 (0x394)`。段 *n* 的哈希位于
`modem.b01 + 0x28 + 32·n`，即 `modem.mdt + 0x3bc + 32·n`。由于方案 A 只改变段 **16**
（`modem.b16`）：

- `modem.b01` @ `0x0228`（`0x28 + 32·16`）← SHA-256(补丁后的 `modem.b16`)
- `modem.mdt` @ `0x05bc`（`0x394 + 0x228`）← 相同的 32 字节

（退役补丁器正好写入这两个偏移；当前的方案 A 构建器 `scratch/build_imei_wait.py` 写入
`b01 @ 0x228` 并重建 `modem.mdt = b00 ‖ b01` —— 相同的表。它额外重新哈希段 **5**，
因为已部署的测试基础镜像也携带了 `modem.b05` 变更；在**干净的出厂基础上只有段 16 改变**。）

**注意事项。**

- **MPSS 认证。** `modem.b01` 在哈希表之后携带 RSA 签名 + 证书链。错误的哈希 —— 或编辑
  一个你未重新哈希的段 —— 会让调制解调器以 `MPSS authentication failed: -19` 死掉。
  始终重新哈希你改变的**每个**段。
- **让幂等性检查与补丁字节保持同步**，否则重新运行会双重应用。
- **退役代码可恢复**：`git show 57024f2^:packages/msm-firmware-dumper/src/hmu05-patch-modem.c`，
  以及 `57024f2` diff 中的 `Makefile` / `msm-firmware-dumper.sh` / `99-msm89xx-firstboot` 接线。
  重新添加它意味着恢复 `Makefile` 构建+安装和上述两个钩子。
- **不要在设备无关的分支上发布它。** 它被移除（`57024f2`）的原因是
  `staging-main`/`main` 是设备无关的，不得携带基带补丁器；如果你走这条路，请保持
  HMU05 门控（补丁器本身已自我门控）。

---

## 4. 方案 B —— 纯软件 `himi-ok-guard`（已选择）

在每次调制解调器启动后不久，从 AP 侧将 NV 项 2500 重写为 `"HiMI_OK"`。RF 任务的
`memcmp` 随即通过，**截止时间永远不会触发** —— 根因被移除，而非被推迟。

| | |
|---|---|
| **守卫** | `msm89xx/base-files/usr/sbin/himi-ok-guard` —— 经 `diag_nv` 轮询 `/dev/rpmsg0`，读项 2500，仅当其未设置时写入 `"HiMI_OK"`（`48694d495f4f4b`） |
| **NV 工具** | `msm89xx/base-files/usr/sbin/diag_nv` —— 经 `/dev/rpmsg0` 的原始 DIAG NV `0x26`/`0x27` |
| **服务** | `msm89xx/base-files/etc/init.d/himi-ok` —— procd，`board_name` 门控为 `*hmu05*`，`START=97` |
| **启用** | `msm89xx/base-files/etc/uci-defaults/97-himi-ok`（在 HMU05 首次启动时启用） |
| **UCI** | `modem-watchdog.recovery.himi_ok_enabled`（默认 **1**）、`modem-watchdog.recovery.himi_ok_interval`（默认 **20 s**） |

**为何轮询而非挂钩启动事件：** 持续重新检查覆盖冷启动*和*每次 SSR/崩溃重启，
不依赖重启检测信号，且若调制解调器再次清空该项则自我修复。稳态代价是每周期一次 NV 读。

**验证：**

- **§112.169** —— 在 60000 ms 测试镜像上，每 15 s 通过 RF 任务读取写入一次 `HiMI_OK`
  （调制解调器启动约 299 s），在调制解调器启动 902 s 时得到 **0 次重启 / 无致命错误**，
  LTE 完全建立；不写入的对照组**致命错误了**。
- **§112.170** —— 冷启动 A/B，两者都在 `a2_pin=0`：无守卫 → `lte_ml1_common_timer.c:390`
  于调制解调器约 363 s；守卫开启 → **0 次崩溃**。守卫是 `lte_ml1` 致命错误的根因修复。
  **⚠ 于 2026-10-09 更正：** §112.170 原本添加了 *“Android 运行 `a2_pin=0`，所以
  `a2_pin=0` + 守卫 = Android 对等”* —— 该对等说法是**错误的**。Android 保持 A2 **开启**
  （测得 120 s 空闲窗口内 0 次 A2 转换 ⇒ ≈ `a2_pin=1`），所以 **Android 对等 = `a2_pin=1`**
  —— 这正是 HMU05 现在发布所用的配置（补丁 849）。见 §6 和 §10。
- **§112.171** —— 守卫最初仅测试用；现在已在镜像中，并由 `sysupgrade` 恢复
  （一次普通的 copy-main 刷写曾使其回退，这正是促使它晋升到 `main` 的原因）。

---

## 5. 对比

| 维度 | **A** —— 固件二进制补丁 | **B** —— `himi-ok-guard`（已选择） |
|---|---|---|
| 性质 | **延迟**（截止时间 → 约 24.9 天） | **根因修复**（截止时间永不触发） |
| 修改基带？ | 是（`modem.b16` + 重新签名 `b01`/`mdt`） | **否** |
| MPSS 认证风险 | 是 | **否** |
| 在 `sysupgrade -n` 后存活？ | 本身不能 —— **仅当有 §3 的转储器/首次启动重新应用钩子** | **是**（在镜像中；无需重新应用） |
| 板卡范围 | 已刷写镜像（按设备） | **HMU05 门控 init**（其他板卡不受影响） |
| 可逆？ | 重新刷写出厂固件 | `uci set …himi_ok_enabled=0` |
| 验证依据 | §112.162 A/B + §112.171 哈希 | §112.169 + §112.170 A/B |
| 已发布到树中 | 否（仅实验） | **是** |

---

## 6. 决策与理由

**已选择：方案 B —— 纯软件 `himi-ok-guard`。**

1. **它修复的是原因，而非时钟。** 方案 A 留下有缺陷的 `memcmp`，仅将截止时间推迟
   24.9 天；B 使比较成功，因此截止时间永不触发。
2. **不修改基带 ⇒ 无 MPSS 认证暴露。** 项目的既定规则是从不盲补基带。B 无需重新签名，
   且不会触发 `MPSS authentication failed: -19` 陷阱。
3. **它天然在 `sysupgrade` 后存活。** B 位于镜像内的 `base-files` 中，由 `97-himi-ok`
   重新启用，无需重新应用。A 被任何 `sysupgrade -n` / 固件恢复回退，仅当你同时重新添加
   §3 的重新应用钩子才存活 —— 而这本身又把一个基带补丁器重新引入设备无关的分支。
4. **已门控且可逆。** init 是 `board_name` 门控到 `*hmu05*`，因此没有其他板卡受影响，
   且可用单个 UCI 键禁用。
5. **Android 对等。** Android 保持 A2 **开启**（测得：120 s 空闲窗口内 0 次 A2 转换 ⇒
   ≈ `a2_pin=1`），因此 HMU05 发布该引脚（经 DT 的 `qcom,a2-pin`，补丁 849 →
   `pm_runtime_forbid()` 保持 `power/control=on`）—— A2-ON 配置才是与 Android 匹配的配置。
   早先的 “Android = `a2_pin=0`” 解读是从驱动的 `ul_powerdown()` *意图*（队列空门控，
   很少触发）错误推断的，而非来自测量；且在数据承载下 `a2_pin=0` 本来就不安全
   （`a2_power.c:1189` 仍会触发）。

**方案 A 在前进中的角色：** 它仅被保留为证明机制（§112.162）的*决定性实验*和回退诊断。
它**不是**已发布修复的一部分，树中不再保留任何基带补丁器（`hmu05-patch-modem`）。

---

## 7. 操作说明

- 守卫与截止时间相关的工作发生在 RF 任务读取项 2500 之前的窗口内（测试镜像上调制解调器
  启动约 299 s）；默认 20 s 间隔留出充足余量。
- 若调制解调器承载被看门狗拆除，守卫继续运行（它是独立的 procd 服务），并在下次调制解调器
  启动后重写该项。
- `sysupgrade -n` 从 `modem` 分区恢复基带；守卫在镜像中，之后无需重新修补。

---

## 8. SOP 合规声明

- **固件修改：** 已发布修复中无。方案 B 中基带**未**被修改；守卫仅是 AP 侧用户空间。
- **双固件对比真实基准：** 机制已对照出厂 HMU05 真实基准（在线连接的 coredump +
  `modem_full_decompiled.c`）确立 —— `memcmp` 位置、`"HiMI_OK"` 字面量，以及 NV 项 2500 的
  存在/零填充都是读自固件，而非猜测。
- **方案 A 实验：** 测试固件镜像用受版本控制的工具（`scratch/build_imei_wait.py`）构建，
  设备上哈希验证，运行后回滚。A/B 记录在 §112.162。
- **重新签名 / 哈希工具：** `b01` 段哈希用与验证工具相同的方案重新计算；判定记录为设备侧
  md5 匹配（`modem.mdt d78d1f2f…`）。
- **捕获的错误：** 守卫最初仅测试用，一次普通刷写使其回退（§112.171）—— 通过将其晋升到
  镜像中来记录并纠正；以及一次对门控的冷对热解读被更正为 `a2_pin`（§112.170）。
- **退役补丁器：** §3 的重新应用机制从已移除的 `hmu05-patch-modem`（`57024f2`）的 git
  历史中记录；它**未**被重新添加到树中。

---

## 9. 达成 vs 预期

| 目标 | 预期 | 达成 |
|---|---|---|
| 停止约 900 秒致命错误 | 调制解调器启动 900 s 后无致命错误 | ✅ 守卫开启：调制解调器启动 902 s 内 0 次崩溃（§112.169）；冷 A/B 0 次崩溃（§112.170） |
| 不修改基带 | 已发布修复不触及固件 | ✅ 仅 AP 侧用户空间 |
| 在 `sysupgrade` 后存活 | 修复在干净重新刷写后持续 | ✅ 在 `base-files` + `97-himi-ok` 中 |
| 板卡隔离 | 仅出现该致命错误的板卡 | ✅ `board_name` 门控 init；`*hmu05* *uz801* *uf02*`（2026-10-09 扩大，§11；UF02 于 2026-10-10 用户确认后添加） |
| 因果性证明 | 用单个常量移动致命错误 | ✅ §112.162：`600000→60000 ms` 将致命错误移到 360.687 s |
| 可逆性 | 无需重新刷写即可禁用 | ✅ `uci set modem-watchdog.recovery.himi_ok_enabled=0` |

---

## 10. 证据指针

- **§112.162** —— 决定性 A/B：移动致命错误的单常量变更。
- **§112.165–§112.168** —— `memcmp` / NV 项 2500 根因。
- **§112.169** —— 守卫开启 vs 不写入对照组，在 60000 ms 镜像上。
- **§112.170** —— 冷启动 A/B；门控是 `a2_pin`（而非冷对热）。⚠ “`a2_pin=0` = Android 对等”
  子声明**于 2026-10-09 更正**：Android 保持 A2 开启 ⇒ 对等 = `a2_pin=1`。
- **§112.171** —— 守卫从仅测试晋升到镜像。
- **产物：** `msm89xx/base-files/usr/sbin/{himi-ok-guard,diag_nv}`、
  `msm89xx/base-files/etc/init.d/himi-ok`、
  `msm89xx/base-files/etc/uci-defaults/97-himi-ok`；
  方案 A 工具 `scratch/build_imei_wait.py`、`scratch/patch_imei_max/`。
- **退役的方案 A 接线（存活 `sysupgrade` 钩子，§3）：** 提交 `57024f2`（移除）及其父提交
  `57024f2^`（`hmu05-patch-modem.c` 源码、`Makefile`、`msm-firmware-dumper.sh` 钩子、
  `99-msm89xx-firstboot` 调用）。

---

## 11. 来自用户反馈的加固（2026-10-09）

GitHub issue **#5** 上的一份独立报告（用户 *miraclebg*，UZ801 v3，相同 HiMI 基带）
在第二块板卡上确认了该修复，并提出四项加固点；四项均已实现。

| # | 反馈 | 变更 | 文件 |
|---|---|---|---|
| 1 | 门控仅 HMU05；UZ801 v3 也需要 | 板卡**允许列表** `*hmu05* *uz801* *uf02*`（可通过 `uci …himi_ok_boards` 扩展）；刻意*不是*“所有 HiMI 板卡”（UFI001B 不出现该问题） | `lib/himi-ok.sh`、`etc/init.d/himi-ok`、`etc/uci-defaults/97-himi-ok` |
| 2 | 仅在项 2500 全零时写入 —— 一次读的 `status=0x0000` 仅表示读成功 | 解析 128 字节负载；**仅**当全零时写入，否则保留并警告一次 | `usr/sbin/himi-ok-guard` |
| 3 | `/dev/rpmsg0` 是独占打开；串行化 DIAG 使用 | 每次读/写周围在 `/var/lock/himi-ok-diag.lock` 上 `flock -x/-u` | `usr/sbin/himi-ok-guard` |
| 4 | `diag-bind-watch` 在持续失败时每 2 s 重写 `/root/diag-bind.status`（闪存磨损） | **仅在状态变化时**写入状态文件 | `packages/diag-bind/files/diag-bind-watch` |

**验证。** 门控矩阵、全零决策树（全零 → 写入；`HiMI_OK` → 跳过；出厂数据 → 跳过；
读超时 → 跳过），以及写时变化逻辑都在镜像构建前用 mock `diag_nv`/`uci`/`board_name`
测试框架演练过；`hmu05` 镜像构建干净。首个门控实现中的一个路径名展开错误
（`*hmu05*` 针对 CWD 展开）被该测试框架捕获，并用无 glob 的子 shell 修复。
