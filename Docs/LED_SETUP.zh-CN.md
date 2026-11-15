> 📄 本文件是 [LED_SETUP.md](LED_SETUP.md) 的英文原文中文译本，内容以英文版为准。

# LED 设置——角色、颜色与模式

LED 监视器不再从 `board_name` 判断哪种颜色对应什么。 它们从
`/etc/config/leds` 读取角色表，因此一块板子可以有绿色 Wi-Fi 灯、下一块是
蓝色，两者仍按设计工作。

> 在早于该功能的镜像——**25.12.6-r8**——上，它是以软件包热修的形式到来，
> 而不是新镜像。参见 [`LED_HOTFIX.md`](LED_HOTFIX.md)。

## 为什么会有这个功能

两台设备可能上报相同的 `board_name`（`hmuf02v5`），但绿灯和蓝灯的接线
恰好相反。 旧脚本把“HMUF02-V5 = 蓝色 Wi-Fi”写死，于是在接线相反的那台设备上，
Wi‑Fi 监视器驱动的是 LTE 灯，反之亦然。 这两台设备在软件上没有任何区别，
所以映射必须在每台设备上用眼睛确认一次。

## 角色

| 角色 | 驱动 |
|---|---|
| `wifi` | Wi‑Fi 状态灯（AP 就绪 / 客户端 / AP+STA / 关闭） |
| `wifi_fault` | Wi‑Fi 灯对的红色半边（带电池的板子） |
| `wan` | LTE/WAN 信号灯（空闲 / 活动 / 搜索中 / 无 SIM） |
| `wan_fault` | 红色调制解调器/故障灯 |
| `data` | 蓝色数据活动灯（四灯板子；HMUF02-V5 上为空） |
| `bat_green` | 电池灯对的绿色半边 |
| `bat_red` | 电池灯对的红色半边 |

每个角色在 `/etc/config/leds` 中都有 `option lamp`。 `auto` 表示“使用板子
默认值”；其他任何值都是 `/sys/class/leds` 下的标签——包括非 RGB 颜色，
如 `yellow:led1` 或 `white:status`。

## 模式

每个角色为每种场景携带一个模式：

```
off                lamp off
on                 lamp solid
blink:ON:OFF       kernel timer blink, milliseconds
```

默认值复现了本文件存在之前监视器的行为，因此未改动过的板子保持不变。 示例：

| 场景 | 默认值 |
|---|---|
| `wifi.ap_sta`（中继生效） | `blink:100:100` |
| `wifi.client`（有客户端加入 AP） | `blink:250:250` |
| `wan.active`（已注册 + 有流量） | `blink:250:250` |
| `wan_fault.search` | `blink:500:500` |
| `bat_green.charging` | `blink:1000:1000` |
| `bat_red.fault` | `blink:150:150` |

重新调校一块板子只是改配置，不必重建——无需热修。

## CLI：`led-probe`

在你想识别灯位的设备上通过 SSH 运行它。

```sh
led-probe                       # interactive wizard
led-probe --list                # indicator lamp labels
led-probe --show                # current role/pattern mapping
led-probe --blink blue:wan 3    # light one lamp for 3 s
led-probe --set wifi=green:wlan wan=blue:wan
led-probe --set wifi.client=blink:500:500
led-probe --reset               # every role lamp back to 'auto'
```

向导工作期间会停掉 LED 监视器（这样它们 2 秒的轮询不会覆盖识别闪烁），
把每盏灯点亮三秒，然后询问它是做什么的：

```
[w]ifi [l]te/wan [d]ata [f]ault [x]wifi-fault [b]attery-green [r]ed-pair [s]kip
```

它会写入 `/etc/config/leds`、提交并重启监视器。

`--show` 打印的是**实际生效**的内容，而不只是写下来的配置，因此未改动过的
板子仍会报告完整表格：

```
role    wifi       green:wlan  green:wlan     # configured / lamp in use
role    wan_fault  auto        red:power      # 'auto' resolved for this board
pattern wifi       ap_sta      blink:100:100 default
pattern wan        active      blink:250:250 set
```

`role` 行的第四列是监视器实际驱动的灯（板子没有该灯时为空）；`pattern` 行的
最后一列在 `/etc/config/leds` 覆盖它时是 `set`，在使用内建值时是
`default`。 内建表位于 `leds.sh`，且是唯一副本——监视器通过
`led_role_spec` 读取它。

## 确认接线相反的设备

这两台设备在软件上无法区分，所以用眼睛识别一次：

```sh
led-probe --blink blue:wan 3     # which colour lights up?
led-probe --blink green:wlan 3
```

然后记录每台的行为。 对于**绿色**灯是 Wi‑Fi、**蓝色**灯是 LTE 的那台：

```sh
led-probe --set wifi=green:wlan wan=blue:wan
```

把该设备接入一个中继上行来验证：绿灯必须快闪（100/100），蓝灯必须跟随
LTE 信号。 `led-probe --reset` 把每个角色都放回板子默认值。

`--set` 会校验传入的内容：

- 模式必须是 `off`、`on` 或以毫秒计的 `blink:ON:OFF`；其他任何值都会被
  拒绝，且什么都不写入；
- 不存在的灯标签仍会被保存，但会打印警告——该角色随后回退到板子默认值，
  所以拼错不会让灯一直黑着；
- 空的模式值（`led-probe --set wifi.client=`）会删除覆盖并恢复内建模式。

## LuCI 页面

**System → LED Setup** 列出每个角色，配有灯下拉框和 **Blink** 按钮，以及每个
场景一个模式下拉框。 电池灯对只在板子于 `/sys/class/power_supply` 中报告
有电池时才提供，因此两块仅市电供电的板子完全不显示电池部分
（`led-probe --caps` 打印相同答案）。 打开时显示的是当前生效的配置：
`auto` 条目会点名它解析到的板子默认灯，每个模式下拉框都以 `default (…)`
开头，显示将会使用的内建时序。 选 `off`、`on` 或某个闪烁预设来固定时序，
或选 `custom…` 自己输入 `blink:ON_MS:OFF_MS`；不是预设的时序会作为单独的
`(custom)` 条目保留，保存时不会被重置。 什么都不动就不会有任何变化；
**Save & apply** 只写入你编辑过的字段并重启监视器。 再次选择 `default (…)`
会放弃该覆盖。 **Reset lamps to auto** 清除灯位覆盖。

## 检查结果

```sh
led-probe --show
logread | grep -E 'wifi-led-monitor|modem-led-monitor'
cat /sys/class/leds/<label>/delay_on /sys/class/leds/<label>/delay_off
```

在中继上，`wifi.ap_sta` 应该让你分配给 `wifi` 的灯快闪
（亮 100 ms / 灭 100 ms），而不是 LTE 灯。

## 文件

- `/etc/config/leds` —— 角色表与模式（配置文件；编辑可挺过升级）。
- `/usr/share/msm89xx/leds.sh` —— 监视器共用的解析器。
- `/usr/sbin/led-probe` —— 上面的 CLI。
- `luci-app-led-setup` —— **System → LED Setup** 页面。

每个消费者都走该解析器，包括各服务的 `stop` 路径：停止
`wifi-led-monitor` 会关掉分配给 `wifi` 的灯，而不是某个写死的颜色。
