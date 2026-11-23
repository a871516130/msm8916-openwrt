# LED 设置——角色、颜色与模式

LED 监视器不再依据 `board_name` 决定哪种颜色是哪个。它们从 `/etc/config/leds`
读取角色表，因此一块板子可以有绿色 Wi-Fi 灯，而下一块是蓝色，且两者都按设计工作。

> 在此功能之前的镜像——**25.12.6-r8**——它以软件包热修复的形式到达，而不是新镜像。
> 见 [`LED_HOTFIX.md`](LED_HOTFIX.md)。

## 为何存在此功能

两台设备可以报告相同的 `board_name`（`hmuf02v5`），但绿色和蓝色灯接法相反。
旧脚本硬编码“HMUF02-V5 = 蓝色 Wi-Fi”，因此在接反的设备上 Wi-Fi 监视器驱动 LTE 灯，
反之亦然。设备间没有软件可见的差异，因此必须在每台设备上目视确认一次映射。

## 角色

| 角色 | 驱动 |
|---|---|
| `wifi` | Wi-Fi 状态灯（AP 就绪 / 客户端 / AP+STA / 断开） |
| `wifi_fault` | Wi-Fi 对的红色半边（带电池的板子） |
| `wan` | LTE/WAN 信号灯（空闲 / 活动 / 搜索 / 无 SIM） |
| `wan_fault` | 红色调制解调器/故障灯 |
| `data` | 蓝色数据活动灯（四灯板子；HMUF02-V5 上为空） |
| `bat_green` | 电池对的绿色半边 |
| `bat_red` | 电池对的红色半边 |

每个角色在 `/etc/config/leds` 中有 `option lamp`。`auto` 表示“使用板级默认值”；
其他任何值都是 `/sys/class/leds` 下的标签——包括非 RGB 颜色如 `yellow:led1` 或 `white:status`。

## 模式

每个角色按场景携带一个模式：

```
off                灯灭
on                 灯常亮
blink:ON:OFF       内核定时器闪烁，毫秒
```

默认值复现了此文件存在之前监视器的行为，因此未改动的板子保持不变。示例：

| 场景 | 默认值 |
|---|---|
| `wifi.ap_sta`（中继激活） | `blink:100:100` |
| `wifi.client`（有客户端加入 AP） | `blink:250:250` |
| `wan.active`（已注册 + 有流量） | `blink:250:250` |
| `wan_fault.search` | `blink:500:500` |
| `bat_green.charging` | `blink:1000:1000` |
| `bat_red.fault` | `blink:150:150` |

调校板子只需改配置，无需重建——不需要热修复。

## CLI：`led-probe`

在你想识别灯的设备上通过 SSH 运行。

```sh
led-probe                       # 交互式向导
led-probe --list                # 指示灯标签
led-probe --show                # 当前角色/模式映射
led-probe --blink blue:wan 3    # 点亮一盏灯 3 秒
led-probe --set wifi=green:wlan wan=blue:wan
led-probe --set wifi.client=blink:500:500
led-probe --reset               # 每个角色灯回到 'auto'
```

向导在工作时停止 LED 监视器（以免它们 2 秒的轮询覆盖识别闪烁），每盏灯闪烁
三秒钟，并询问它的作用：

```
[w]ifi [l]te/wan [d]ata [f]ault [x]wifi-fault [b]attery-green [r]ed-pair [s]kip
```

它写入 `/etc/config/leds`、提交，并重启监视器。

`--show` 打印**生效中**的内容，而不仅仅是记录的内容，因此未改动的板子仍报告完整表格：

```
role    wifi       green:wlan  green:wlan     # 已配置 / 使用的灯
role    wan_fault  auto        red:power      # 该板子的 'auto' 已解析
pattern wifi       ap_sta      blink:100:100 default
pattern wan        active      blink:250:250 set
```

`role` 行的第四列是监视器实际驱动的灯（当板子没有该灯时为空）；
`pattern` 行的最后一列在 `/etc/config/leds` 覆盖时为 `set`，使用内置值时为 `default`。
内置表位于 `leds.sh`，是唯一副本——监视器通过 `led_role_spec` 读取它。

## 确认接反的设备

设备无法在软件上区分，因此请目视识别一次：

```sh
led-probe --blink blue:wan 3     # 哪种颜色亮起？
led-probe --blink green:wlan 3
```

然后记录每台的功能。对于**绿色**灯是 Wi-Fi、**蓝色**灯是 LTE 的设备：

```sh
led-probe --set wifi=green:wlan wan=blue:wan
```

通过将设备加入中继上行来检查：绿色灯必须快速闪烁（100/100），
蓝色灯必须跟随 LTE 信号。`led-probe --reset` 将每个角色恢复到板级默认值。

`--set` 会校验输入：

- 模式必须是毫秒计的 `off`、`on` 或 `blink:ON:OFF`；否则被拒绝且不写入任何内容；
- 不存在的灯标签仍会保存，但会打印警告——该角色随后回退到板级默认值，
  因此拼写错误不会让灯熄灭；
- 空模式值（`led-probe --set wifi.client=`）删除覆盖并恢复内置模式。

## LuCI 页面

**系统 → LED 设置**列出每个角色，带灯下拉框和 **Blink** 按钮，外加每个场景的模式下拉框。
电池对仅在板子于 `/sys/class/power_supply` 中报告电池时才提供，因此两块仅市电供电的板子
完全不显示电池区块（`led-probe --caps` 打印相同答案）。它打开时显示生效中的配置：
`auto` 条目命名它解析到的板级默认值，每个模式下拉框以 `default (…)` 开头，
显示将使用的内置定时。选择 `off`、`on` 或某个闪烁预设以固定定时，
或 `custom…` 自己输入 `blink:ON_MS:OFF_MS`；非预设的定时保留为它自己的 `(custom)` 条目，
而不会在保存时重置。什么都不动则什么都不变；**保存并应用**只写入你编辑的字段并重启监视器。
再次选择 `default (…)` 会丢弃覆盖。**Reset lamps to auto** 清除灯覆盖。

## 检查结果

```sh
led-probe --show
logread | grep -E 'wifi-led-monitor|modem-led-monitor'
cat /sys/class/leds/<label>/delay_on /sys/class/leds/<label>/delay_off
```

在中继上，`wifi.ap_sta` 应让分配给 `wifi` 的灯快速闪烁（100 ms 亮 / 100 ms 灭），
而不是 LTE 灯。

## 文件

- `/etc/config/leds` —— 角色表和模式（conffile；编辑在升级后保留）。
- `/usr/share/msm89xx/leds.sh` —— 监视器使用的共享解析器。
- `/usr/sbin/led-probe` —— 上述 CLI。
- `luci-app-led-setup` —— **系统 → LED 设置**页面。

每个消费者都通过解析器，包括服务的 `stop` 路径：停止 `wifi-led-monitor`
会关闭分配给 `wifi` 的灯，而不是硬编码颜色。
