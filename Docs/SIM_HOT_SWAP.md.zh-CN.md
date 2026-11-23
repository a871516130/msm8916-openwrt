# 物理 SIM 热插拔

**状态：** 仅在 **HMUF02-V5** 上实现并实测验证。
**其他板子：** **HM-MIFIB-V12 定义了同一线路**（补丁 853，TLMM
GPIO114）但未验证；其余板子未定义它，因此服务在那里保持惰性。见
[在其他板子上测试](#testing-on-another-board)。
**服务：** `sim-hotplug`（`/etc/init.d/sim-hotplug`、`/usr/sbin/sim-hotplug`）。

> **板子范围。** 热插拔**仅在 HMUF02-V5 上验证**，其设备树将 `sim_hotplug`
> 线路（TLMM GPIO114）暴露为用户空间可控制的 `gpio-leds` 节点。
> **HM-MIFIB-V12 的 DTS 定义了同一节点**（补丁 853）但尚未在硬件上验证。
> 其他板子的 DTS 未定义它，因此服务在那里自我禁用。
> **设备拥有者应在假定其板子不支持热插拔之前**用下述流程进行验证。

## 为何存在此功能

这些加密狗**没有 AP 侧的 SIM 卡检测线路**。基带固件出厂时也带有
`feature_support_hotswap` **禁用**：

- 它**能察觉拔出**——UIM 开始应答 `error: possibly-removed`。
- 它**从不觉察插入**——卡可插在槽中，调制解调器不会看到它，
  直到 AP 脉冲 `sim_hotplug`。

因此物理更换需要 AP：(a) 察觉卡已拔出，(b) 脉冲该线路让基带重新读取插槽，
(c) 让 ModemManager 重新加载 SIM，以便*不同*运营商的 IMSI/APN
对 `qcom-carrier-autocfg` 可见。

## 它做什么

| 状态 | 行为 |
| :--- | :--- |
| 卡在位 + 调制解调器已注册 | 每 **60 秒**一次 UIM 检查 |
| 卡在位 + 调制解调器搜索中 | 每 **5 秒**一次 UIM 检查（仅节奏——单独的 `searching` 永不代表“更换”） |
| 认为卡已缺失 | 脉冲 `sim_hotplug` → 等待 4 秒 → 重新检查，每 **6 秒** |

在 `absent → present` 时服务：

1. 等待调制解调器注册（最长 60 秒）；
2. 强制 ModemManager 重新读取 SIM（`mmcli -d` + `mmcli -e`），
   这就是让*不同*卡的 IMSI/APN 可见的做法；
3. 恢复数据承载（`ifup modem`，在承载锁下）。

脉冲仅在认为卡**缺失**时发送。脉冲一张已可见的卡会使调制解调器弹跳，
并可能使其停留在 `searching`。

## 实测延迟

硬件上端到端：约 **~15 秒**，对应约 4 秒的更换。

```
16:33:20 SIM removed (UIM absent)
16:33:37 SIM detected after re-announce
16:33:42 modem registered
16:33:46 re-reading the SIM through ModemManager / bearer up
          → 10.152.146.4/29, ping 0% loss
```

## 设计约束（刻意为之）

- **无调制解调器状态检测。** `searching` 不是更换信号——行驶中的列车
  或小区重选会产生相同状态。检测仅基于 UIM，因此这些事件不触发任何操作。
- **无朴素的 `qmicli` 轮询循环。** 每个 QMI 客户端必须关闭，
  否则服务会命中 `ClientIdsExhausted`（这在早期尝试中曾导致服务中断）。
  服务使用 `--device-open-proxy`，一次一个短生命周期客户端，始终在 `timeout` 下，
  并用 `flock` 串行化。
- **无 SSR / `mmcli -r`。** 重新读取是禁用/启用（`-d`/`-e`），约 10 秒，
  且从不复位调制解调器。
- **启动宽限。** 循环在首次查询前等待 10 秒，以便 ModemManager 完成枚举。

## 配置

`/etc/config/sim-hotplug`：

| 选项 | 默认值 | 含义 |
| :--- | :--- | :--- |
| `enabled` | `1` | 运行服务 |
| `idle_interval` | `60` | 已注册时的 UIM 轮询周期 |
| `active_interval` | `5` | 失联时的 UIM 轮询周期 |
| `absent_interval` | `6` | 卡缺失时的重新通告周期 |
| `pulse_ms` | `300` | `sim_hotplug` 脉冲宽度 |

## 手动操作

```sh
sim-hotplug --help
/etc/init.d/sim-hotplug status
/etc/init.d/sim-hotplug rescan      # 立即强制一次重新通告
logread -e sim-hotplug
```

## 已知限制

**短于调制解调器自身移除去抖**的更换是不可见的：调制解调器保留其缓存的卡，
保持 `connected`，UIM 继续应答 `present`，因此 AP 无从检测。当同一张卡插回时
这无害。如果*不同*的卡那么快插入，运行 `/etc/init.d/sim-hotplug rescan`——
或在数据失败时让承载看门狗的 SSR 重新初始化 UIM。

## 板子状态

| 板子 | 当前 DTS 中的 `sim_hotplug` 节点 | 热插拔 |
| :--- | :--- | :--- |
| `hmuf02v5` (HMUF02-V5) | **是**——补丁 805，`&tlmm 114` | **已实现 + 已验证** |
| `mifib-v12` (HM-MIFIB-V12) | **是**——补丁 853，`&tlmm 114` | **已实现，未验证** |
| `uz801` | 不在当前补丁中 | **未测试——请验证** |
| `ufi001b` | 不在当前补丁中 | **未测试——请验证** |
| `ufi003` | 不在当前补丁中 | **未测试——请验证** |
| `uf02` | 不在当前补丁中 | **未测试——请验证** |
| `mf800b` | 不在当前补丁中 | **未测试——请验证** |

补丁 **805**（hmuf02v5）和 **853**（mifib-v12）定义
`/sim-presence/sim_hotplug`（`gpios = <&tlmm 114 GPIO_ACTIVE_HIGH>`）。
服务随共享 `base-files` 发布，并在每块板子上 `enabled 1`。

> **节点门控（随附）。** `sim-hotplug` 依据节点自我门控：当
> `/sys/class/leds/sim_hotplug/brightness` 不存在或不可写时，init
> 脚本干净跳过（`logger: no sim_hotplug line on this board - disabled`），
> `rescan` 变为空操作，且不空转。*确实*暴露该节点的板子自我激活，
> 行为与 HMUF02-V5 上验证的完全一致。

## 在其他板子上测试

请在真实硬件上执行。**不要脉冲你尚未识别的 GPIO**——对无关线路的脉冲
可能干扰其他硬件。

1. **查找现有节点。**

   ```sh
   ls -l /sys/class/leds/ | grep -i sim
   cat /sys/firmware/devicetree/base/sim-presence/sim_hotplug/gpios 2>/dev/null
   grep -ril 'sim' /sys/firmware/devicetree/base/ 2>/dev/null | head
   ```

   如果 `/sys/class/leds/sim_hotplug/brightness` 存在，该线路已暴露——
   跳到步骤 3。

2. **从板子找到该线路。** 检查原理图 / 厂商 DTS 寻找连接到基带 SIM
   重新检测的 GPIO。与 HMUF02-V5 接线（GPIO114，高电平有效）对比。
   如果线路存在但未暴露，添加一个类似补丁 805 的 `gpio-leds` 节点，
   或临时用 `gpioset`（来自 `libgpiod-tools`）驱动它。

3. **确认调制解调器有反应。** 卡在位时：

   ```sh
   qmicli --device-open-proxy -d /dev/wwan0qmi0 --uim-get-card-status
   echo 255 > /sys/class/leds/sim_hotplug/brightness; sleep 0.3
   echo 0   > /sys/class/leds/sim_hotplug/brightness
   sleep 3
   qmicli --device-open-proxy -d /dev/wwan0qmi0 --uim-get-card-status
   ```

   然后是真实场景：移除卡（UIM 应报告 `possibly-removed`），重新插入，
   脉冲，检查 UIM 是否再次报告 `present`。

4. **端到端运行服务。**

   ```sh
   uci set sim-hotplug.general.enabled='1'; uci commit sim-hotplug
   /etc/init.d/sim-hotplug restart
   logread -f -e sim-hotplug     # 然后物理更换卡
   ```

5. **回报**板子名、GPIO 号、极性、脉冲宽度，以及物理更换是否恢复。
   这就是把“未测试”变成“已支持”的做法。

## 实现

| 文件 | 角色 |
| :--- | :--- |
| `msm89xx/base-files/usr/sbin/sim-hotplug` | 轮询/脉冲/恢复逻辑 |
| `msm89xx/base-files/etc/init.d/sim-hotplug` | procd 服务，`rescan` 命令 |
| `msm89xx/base-files/etc/config/sim-hotplug` | 默认值 |
| `msm89xx/base-files/etc/rc.d/S98sim-hotplug` | 开机启用（sysupgrade 后保留） |
| `msm89xx/patches/805-...hmuf02v5.patch` | GPIO114 `gpio-leds` 节点 |

## 验证记录

- HMUF02-V5 上实卡更换：5–7 秒内检测到拔出，≤10 秒检测到插入，
  约 15 秒完成重新读取 + 承载恢复，新 IP，ping 0% 丢包。
- 在 scp 构建上验证两次，并在刷写的 `sysupgrade -n` 镜像上再次验证。
