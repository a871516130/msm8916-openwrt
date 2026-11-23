# 电池、充电限制与电池 LED

两个板卡携带锂离子电芯：**mifib-v12**（4.2 V / 2150 mAh）和 **mf800b**（4.35 V / 2100 mAh）。所有电池相关内容都在一个包中发布，[`packages/luci-app-battery`](../packages/luci-app-battery/)，只有这两个板卡安装它 —— 其它五个没有电芯，所以它们没有 LuCI 页面，也没有服务。

---

## 包中有什么

| 文件 | 作用 |
| :--- | :--- |
| `etc/config/battery` | 充电限制设置（`enabled`、`limit`、`resume`） |
| `usr/sbin/battery-charge-limit` | 充电限制监视器（procd 服务） |
| `usr/sbin/battery-led-monitor` | 驱动绿/红电池 LED 对 |
| `usr/sbin/battery-session` | 记录设备用电池运行了多长时间 |
| `usr/sbin/battery-ctl` | CLI：显示状态、切换充电、编辑限制 |
| `luci/controller/battery.lua` + `view/battery/status.htm` | **系统 → 电池** 页面 |

安装包时两个 init 脚本都会自动启用（`default_postinst` 启用 `/etc/init.d/` 下的所有内容），所以它没有自己的 uci-defaults。

---

## LuCI 页面

**系统 → 电池** 显示容量、电压、温度、充电状态和健康状态、充电限制状态，以及当前电池会话（设备已拔电多久、消耗了多少容量）。除充电限制开关外，页面是只读的；其余用 `battery-ctl` 或 uci 操作。

---

## 充电限制

默认策略：**在 85 % 停止充电，在 80 % 恢复。** 锂离子电芯在满电保持时老化最快，而这些上网棒通常一连插电数周。

它是如何工作的 —— PM8916 线性充电器上游没有“停止充电但保持系统供电”位，所以补丁 **857** 添加了一个：

* 向 `charge_enabled` 写 `0` 会清除 `CHG_EN` 而 `PSTG_EN` 保持置位，所以上网棒继续由 VBUS 供电，电芯仅被**保持**；
* 监视器还把 `constant_charge_current` 保底在它的 90 mA 最小值作为双保险；
* 当容量降到 `resume` 时，重新启用充电。

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

## 充电状态讲真话

上游在 VBUS 在线时报告 `Charging`，所以保持在 85 % 的上网棒会永远显示“Charging”。补丁 **859** 让电量计查询充电器的 `CHARGE_ENABLED` 并报告：

| 状态 | 含义 |
| :---- | :------ |
| `Charging` | VBUS 存在**且**充电已启用 |
| `Not charging` | VBUS 存在，电芯保持在限制 |
| `Discharging` | 由电芯供电运行 |

---

## 电池移除

刻意**没有**守卫服务。PM8916 LBC 只能补充电芯，不能替代它，所以拔出电芯会让 AP 靠 VBUS 运行片刻，然后电源轨塌陷 —— 在负载系统上那是硬欠压，没有机会同步。

1.0-r2 发布过一个 200 ms 轮询器，在 1.0-r3 被移除。它永远赢不了那场比赛（实测：塌陷比 1 s 采样器还快），它唯一被证明的效果是关掉一台不需要关机的 USB 供电设备。设备现在会一直运行到电源轨撑不住为止。

驱动仍报告 `POWER_SUPPLY_PROP_PRESENT` 并记录 `battery removed`，所以该事件事后在 `dmesg` 中仍然可见。

---

## LED

`battery-led-monitor` 每几秒轮询一次，驱动电池 LED 对 —— mifib-v12 上是 `green:bat` / `red:bat`，mf800b 上是 `green:charging` / `red:charging`（名称按板卡解析；mf800b 的 `red:charging` 绑定到内核触发器 `pm8916-bms-vm-charging`，监视器接管指示灯，使两个板卡行为一致）：

| 模式 | 含义 |
| :------ | :------ |
| 绿色慢闪（1 s） | 充电中 |
| 绿色常亮 | 充电完成 |
| 红色快闪（150 ms） | 电量计存在但容量不可读（驱动/热敏电阻故障） |
| 全灭 | 正常放电，或无电池设备 |

LED 对只报告**充电状态和故障**。容量刻意不编码：百分比无法从闪烁读出，阈值颜色也不易记住。容量、运行时间估计、电压、温度和充电限制在 LuCI 的电池页面。

“无电池”和“电池损坏”刻意是不同状态：前者静默，后者快闪。

`/etc/diag.sh` 中的启动闪烁是在 `green:bat` 上的普通“启动中”闪烁 —— 它也不再按容量着色。

---

## sysfs 与内核侧

```sh
/sys/class/power_supply/pm8916-bms-vm/     # fuel gauge
    capacity  voltage_now  temp  status  health
/sys/class/power_supply/pm8916-lbc-chgr/   # charger
    online  charge_enabled  constant_charge_current
```

这些属性存在是因为 PM8916 电源供应系列 —— 参见 [`Docs/Patches/README.md`](Patches/README.md) §1.8（补丁 854–859）。实践中最重要的两个：

* **854** 从电压推导 `capacity`（VM-BMS 没有库仑计数器），优先使用挂起时捕获的开路电压，回退到实时电压，所以数字偏低而非偏高；
* **858** 修复温度读取 —— `iio_read_channel_processed()` 成功时返回 `IIO_VAL_INT`（1），原测试的非零判断丢弃了每个良好样本，使电量计卡在 25 °C。

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
| LuCI 中没有电池页面 | 包未安装 —— 只有 mifib-v12 和 mf800b 发布它 |
| 容量跳来跳去 | 预期行为：它从电压推导，而非库仑计数器 |
| 温度总是 25 °C | 补丁 858 缺失，或板卡没有 `batt-therm` 通道 |
| 状态在 85 % 时显示 `Charging` | 补丁 859 缺失 |
| 红色快闪 | 电量计存在但不可读 —— 检查 `dmesg` 中的 BMS/VADC 探测错误 |
