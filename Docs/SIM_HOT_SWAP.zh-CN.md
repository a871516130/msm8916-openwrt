> 📄 本文件是 [SIM_HOT_SWAP.md](SIM_HOT_SWAP.md) 的英文原文中文译本，内容以英文版为准。

# 实体 SIM 卡热插拔

**状态：** 已实现，并在 **HMUF02-V5 上完成实机验证**。
**其他板子：** **HM-MIFIB-V12 定义了同一根线**（补丁 853，TLMM
GPIO114）但未经验证；其余板子没有定义它，因此该服务在那里保持静默。参见
[在另一块板子上测试](#在另一块板子上测试)。
**服务：** `sim-hotplug`（`/etc/init.d/sim-hotplug`、`/usr/sbin/sim-hotplug`）。

> **板子范围。** 热插拔**仅在 HMUF02-V5 上得到验证**，其设备树把
> `sim_hotplug` 线（TLMM GPIO114）暴露为用户态可控的 `gpio-leds` 节点。
> **HM-MIFIB-V12 的 DTS 定义了同一节点**（补丁 853），但尚未在硬件上验证。
> 其他板子的 DTS 没有定义它，因此该服务在那里会自行禁用。
> **设备所有者应按下面的流程验证**，再假定自己的板子不支持热插拔。

## 为什么会有这个功能

这些棒状设备**没有 AP 侧的 SIM 卡在位检测线**。 基带固件出厂时
`feature_support_hotswap` 也是**禁用**的：

- 它**能察觉拔出**——UIM 开始应答 `error: possibly-removed`。
- 它**永远察觉不到插入**——卡可以一直插在槽里，而调制解调器不会看到它，
  除非 AP 脉冲 `sim_hotplug`。

所以实体换卡需要 AP：(a) 察觉卡已不在，(b) 脉冲该线让基带重新读取卡槽，
(c) 让 ModemManager 重新加载 SIM，使*另一个*运营商的 IMSI/APN 对
`qcom-carrier-autocfg` 可见。

## 它做什么

| 状态 | 行为 |
| :--- | :--- |
| 卡在位 + 调制解调器已注册 | 每 **60 s** 检查一次 UIM |
| 卡在位 + 调制解调器搜索中 | 每 **5 s** 检查一次 UIM（仅调节奏——`searching` 本身绝不意味着“换卡”） |
| 认为卡不在位 | 脉冲 `sim_hotplug` → 等 4 s → 重新检查，每 **6 s** 一次 |

在 `absent → present` 时，服务会：

1. 等待调制解调器注册（最多 60 s）；
2. 强制 ModemManager 重新读取 SIM（`mmcli -d` + `mmcli -e`），
   这正是让**另一张**卡的 IMSI/APN 可见的做法；
3. 把数据承载重新拉起（`ifup modem`，在承载锁之下）。

脉冲只在卡被认为**不在位**时才发送。 对一张已经可见的卡发脉冲会让
调制解调器反复弹跳，并可能使其停留在 `searching`。

## 实测延迟

硬件上端到端：一次约 4 s 的换卡，**约 15 s** 完成。

```
16:33:20 SIM removed (UIM absent)
16:33:37 SIM detected after re-announce
16:33:42 modem registered
16:33:46 re-reading the SIM through ModemManager / bearer up
          → 10.152.146.4/29, ping 0% loss
```

## 设计约束（有意为之）

- **不做调制解调器状态检测。** `searching` 不是换卡信号——行驶中的列车或
  小区重选会产生相同状态。检测只基于 UIM，因此那些事件不会触发任何动作。
- **不做朴素的 `qmicli` 轮询循环。** 每个 QMI 客户端都必须关闭，否则服务会
  撞上 `ClientIdsExhausted`（早期一次尝试就因此造成了服务中断）。该服务使用
  `--device-open-proxy`，一次只用一个短生命周期客户端，始终包在 `timeout`
  内，并用 `flock` 串行化。
- **不做 SSR / `mmcli -r`。** 重新读取是一次禁用/启用
  （`-d`/`-e`），大约 10 s，绝不会复位调制解调器。
- **启动宽限。** 循环在首次查询前等待 10 s，让 ModemManager 完成枚举。

## 配置

`/etc/config/sim-hotplug`：

| 选项 | 默认值 | 含义 |
| :--- | :--- | :--- |
| `enabled` | `1` | 运行该服务 |
| `idle_interval` | `60` | 注册状态下的 UIM 轮询周期 |
| `active_interval` | `5` | 脱离服务时的 UIM 轮询周期 |
| `absent_interval` | `6` | 卡不在位时的重新通告周期 |
| `pulse_ms` | `300` | `sim_hotplug` 脉冲宽度 |

## 手动操作

```sh
sim-hotplug --help
/etc/init.d/sim-hotplug status
/etc/init.d/sim-hotplug rescan      # force one re-announce now
logread -e sim-hotplug
```

## 已知限制

一次**短于调制解调器自身拔出消抖时间**的换卡是不可见的：调制解调器保留其
缓存的卡，保持 `connected`，UIM 继续应答 `present`，因此 AP 无从检测。
当插回同一张卡时这无害。 如果这么快插入的是*另一张*卡，请运行
`/etc/init.d/sim-hotplug rescan`——或者等承载看门狗的 SSR 在数据失败时
重新初始化 UIM。

## 板子状态

| 板子 | 当前 DTS 中的 `sim_hotplug` 节点 | 热插拔 |
| :--- | :--- | :--- |
| `hmuf02v5`（HMUF02-V5） | **有** —— 补丁 805，`&tlmm 114` | **已实现 + 已验证** |
| `mifib-v12`（HM-MIFIB-V12） | **有** —— 补丁 853，`&tlmm 114` | **已实现，未验证** |
| `uz801` | 不在当前补丁中 | **未测试 —— 请验证** |
| `ufi001b` | 不在当前补丁中 | **未测试 —— 请验证** |
| `ufi003` | 不在当前补丁中 | **未测试 —— 请验证** |
| `uf02` | 不在当前补丁中 | **未测试 —— 请验证** |
| `mf800b` | 不在当前补丁中 | **未测试 —— 请验证** |

补丁 **805**（hmuf02v5）和 **853**（mifib-v12）定义了
`/sim-presence/sim_hotplug`（`gpios = <&tlmm 114 GPIO_ACTIVE_HIGH>`）。
该服务随共享的 `base-files` 发行，在每块板子上都是 `enabled 1`。

> **节点门控（已随附）。** `sim-hotplug` 会依据节点自行门控：当
> `/sys/class/leds/sim_hotplug/brightness` 不存在或不可写时，init 脚本会
> 干净地跳过（`logger: no sim_hotplug line on this board - disabled`），
> `rescan` 变成空操作，也不会有任何空转。 *确实*暴露该节点的板子会自行
> 激活，行为与 HMUF02-V5 上验证过的完全一致。

## 在另一块板子上测试

请在真实硬件上做这件事。 **不要脉冲你尚未确认身份的 GPIO**
——对无关线路发脉冲可能干扰其他硬件。

1. **寻找现有节点。**

   ```sh
   ls -l /sys/class/leds/ | grep -i sim
   cat /sys/firmware/devicetree/base/sim-presence/sim_hotplug/gpios 2>/dev/null
   grep -ril 'sim' /sys/firmware/devicetree/base/ 2>/dev/null | head
   ```

   如果 `/sys/class/leds/sim_hotplug/brightness` 存在，该线已经暴露——
   直接跳到第 3 步。

2. **从板子上找到这根线。** 检查原理图 / 厂商 DTS，找一根接到基带
   SIM 重新检测的 GPIO。 与 HMUF02-V5 的接线（GPIO114，高电平有效）对比。
   如果该线存在但未暴露，请像补丁 805 那样添加一个 `gpio-leds` 节点，
   或用 `gpioset`（来自 `libgpiod-tools`）临时驱动它。

3. **确认调制解调器有反应。** 插着卡时：

   ```sh
   qmicli --device-open-proxy -d /dev/wwan0qmi0 --uim-get-card-status
   echo 255 > /sys/class/leds/sim_hotplug/brightness; sleep 0.3
   echo 0   > /sys/class/leds/sim_hotplug/brightness
   sleep 3
   qmicli --device-open-proxy -d /dev/wwan0qmi0 --uim-get-card-status
   ```

   然后是真实场景：拔出卡（UIM 应报告
   `possibly-removed`），重新插入，脉冲，再检查 UIM 是否重新报告
   `present`。

4. **端到端运行该服务。**

   ```sh
   uci set sim-hotplug.general.enabled='1'; uci commit sim-hotplug
   /etc/init.d/sim-hotplug restart
   logread -f -e sim-hotplug     # then physically swap the card
   ```

5. **反馈结果**，包括板子名称、GPIO 编号、极性、脉冲宽度，以及实体换卡是否
   恢复。 正是这些信息把“未测试”变成“受支持”。

## 实现

| 文件 | 作用 |
| :--- | :--- |
| `msm89xx/base-files/usr/sbin/sim-hotplug` | 轮询/脉冲/恢复逻辑 |
| `msm89xx/base-files/etc/init.d/sim-hotplug` | procd 服务、`rescan` 命令 |
| `msm89xx/base-files/etc/config/sim-hotplug` | 默认值 |
| `msm89xx/base-files/etc/rc.d/S98sim-hotplug` | 开机启用（可挺过 sysupgrade） |
| `msm89xx/patches/805-...hmuf02v5.patch` | GPIO114 `gpio-leds` 节点 |

## 验证记录

- HMUF02-V5 上的实机换卡：5–7 s 内检测到拔出，≤10 s 检测到插入，
  约 15 s 完成重新读取 + 承载拉起，获得新 IP，ping 丢包 0 %。
- 在 scp 传输的构建上验证过两次，又在刷入的 `sysupgrade -n`
  镜像上验证过一次。
