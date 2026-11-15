> 📄 本文件是 [BATTERY.md](BATTERY.md) 的英文原文中文译本，内容以英文版为准。

# 电池、充电上限与电池 LED

有两款板子配备锂离子电池组：**mifib-v12**（4.2 V / 2150 mAh）和 **mf800b**
（4.35 V / 2100 mAh）。 与电池相关的一切都打包在一个软件包里，
[`packages/luci-app-battery`](../packages/luci-app-battery/)，只有这两块板子会
安装它——另外五块板子没有电池，因此既没有 LuCI 页面，也没有相关服务。

---

## 软件包里有什么

| 文件 | 作用 |
| :--- | :--- |
| `etc/config/battery` | 充电上限设置（`enabled`、`limit`、`resume`） |
| `usr/sbin/battery-charge-limit` | 充电上限监视器（procd 服务） |
| `usr/sbin/battery-led-monitor` | 驱动绿色/红色电池 LED 灯对 |
| `usr/sbin/battery-session` | 记录设备已用电池运行了多长时间 |
| `usr/sbin/battery-ctl` | CLI：显示状态、切换充电、编辑上限 |
| `luci/controller/battery.lua` + `view/battery/status.htm` | **System → Battery** 页面 |

两个 init 脚本在安装软件包时会自动启用
（`default_postinst` 会启用 `/etc/init.d/` 下的所有内容），因此它没有自己的
uci-defaults。

---

## LuCI 页面

**System → Battery** 显示电量、电压、温度、充电状态与健康状况、充电上限状态，
以及当前电池会话（设备已拔掉电源多久、为此消耗了多少电量）。 除了充电上限开关
之外，该页面是只读的；其余操作请使用 `battery-ctl` 或 uci。

---

## 充电上限

默认策略：**充到 85 % 停止充电，80 % 时恢复。** 锂离子电芯在满电保持状态下
老化最快，而这些棒状设备通常一次插电就是数周。

工作原理——PM8916 线性充电器在上游没有“停止充电但保持系统供电”这一位，
因此补丁 **857** 增加了一个：

* 向 `charge_enabled` 写入 `0` 会清除 `CHG_EN`，同时 `PSTG_EN` 保持置位，
  这样棒状设备继续由 VBUS 供电，电池组只是被**保持**在当前电量；
* 监视器还会把 `constant_charge_current` 下限压在其 90 mA 最低值上，作为
  双重保险措施；
* 当电量降至 `resume` 时，重新启用充电。

配置（`/etc/config/battery`）：

```
config charge
	option enabled '1'     # master switch for the limit
	option limit   '85'    # stop charging at this %
	option resume  '80'    # resume at this % (hysteresis)
```

CLI：

```sh
battery-ctl                  # live status + current policy
battery-ctl limit 90         # change the stop level
battery-ctl resume 85        # change the resume level
battery-ctl enable|disable   # turn the monitor on/off
battery-ctl charge on|off    # one-shot nudge (the monitor re-applies its policy)
```

---

## 充电状态如实上报

上游只要 VBUS 在线就上报 `Charging`，因此被保持在 85 % 的棒状设备会永远显示
“Charging”。 补丁 **859** 让电量计查询充电器的 `CHARGE_ENABLED` 并上报：

| 状态 | 含义 |
| :---- | :------ |
| `Charging` | VBUS 在线**且**充电已启用 |
| `Not charging` | VBUS 在线，电池组被保持在上限 |
| `Discharging` | 由电池组供电运行 |

---

## 移除电池

这里**故意没有**防护服务。 PM8916 LBC 只能补充电池组，不能替代它，因此拔掉
电芯会让 AP 短暂地靠 VBUS 运行，随后电源轨塌陷——在负载系统上这是一次硬掉电
（brownout），来不及做任何同步。

1.0-r2 曾随附一个 200 ms 轮询器，在 1.0-r3 中被移除。 它永远赢不了那场竞态
（实测：塌陷甚至比 1 秒采样器还快），而它唯一被证实的效果是把一台本不需要
关机的 USB 供电设备给关掉了。 现在设备会在电源轨撑得住的范围内一直运行。

驱动仍然会上报 `POWER_SUPPLY_PROP_PRESENT` 并记录
`battery removed`，因此事后仍可在 `dmesg` 中看到该事件。

---

## LED

`battery-led-monitor` 每隔几秒轮询一次，驱动电池灯对——
mifib-v12 上是 `green:bat` / `red:bat`，mf800b 上是 `green:charging` /
`red:charging`（名称按板子解析；mf800b 的 `red:charging` 绑定到内核触发器
`pm8916-bms-vm-charging`，监视器会接管该灯，使两块板子行为一致）：

| 模式 | 含义 |
| :------ | :------ |
| 绿色慢闪（1 s） | 正在充电 |
| 绿色常亮 | 充电完成 |
| 红色快闪（150 ms） | 电量计存在但电量无法读取（驱动/热敏电阻故障） |
| 全灭 | 正常放电中，或没有电池设备 |

这对灯**只上报充电状态和故障**。 电量是故意不编码的：百分比无法从闪烁中读出，
按阈值换色也不好记。 电量、续航估计、电压、温度和充电上限都在 LuCI 的
Battery 页面上。

“没有电池”和“电池损坏”是故意区分的状态：前者静默，后者快闪。

`/etc/diag.sh` 中的开机动画是在 `green:bat` 上的普通“正在启动”闪烁——
它同样不再用颜色编码电量。

---

## sysfs 与内核侧

```sh
/sys/class/power_supply/pm8916-bms-vm/     # fuel gauge
    capacity  voltage_now  temp  status  health
/sys/class/power_supply/pm8916-lbc-chgr/   # charger
    online  charge_enabled  constant_charge_current
```

这些属性的存在归功于 PM8916 电源系列——参见
[`Docs/Patches/README.md`](Patches/README.md) §1.8（补丁 854–859）。 实践中
最重要的两个：

* **854** 从电压推导 `capacity`（VM-BMS 没有库仑计数器），优先使用挂起期间
  捕获的开路电压，回退到实时电压，因此该数值倾向于偏低而非偏高；
* **858** 修正了温度读取——`iio_read_channel_processed()` 成功时返回
  `IIO_VAL_INT`（1），而原来非零判断丢弃了每一个正常采样，导致电量计
  卡在 25 °C。

---

## 故障排查

```sh
battery-ctl
logread | grep -E "battery-charge-limit|battery-led-monitor"
cat /sys/class/power_supply/pm8916-bms-vm/capacity
cat /sys/class/power_supply/pm8916-lbc-chgr/charge_enabled
```

| 症状 | 原因 |
| :------ | :---- |
| LuCI 中没有 Battery 页面 | 软件包未安装——只有 mifib-v12 和 mf800b 随附它 |
| 电量数值跳变 | 预期行为：它由电压推导，而非库仑计数器 |
| 温度始终为 25 °C | 缺少补丁 858，或该板子没有 `batt-therm` 通道 |
| 85 % 时状态仍显示 `Charging` | 缺少补丁 859 |
| 红色快闪 | 电量计存在但无法读取——检查 `dmesg` 中的 BMS/VADC 探测错误 |
