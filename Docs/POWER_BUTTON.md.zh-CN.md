# 电源按钮

本项目中只有**两块**板子有电源按钮：

| 板子 | 电源键 | 复位按钮 |
| :---- | :-------- | :----------- |
| `mifib-v12` | `pm8941_pwrkey`（PMIC PON） | GPIO 102，同时也是恢复键 |
| `mf800b` | `pm8941_pwrkey`（PMIC PON） | GPIO 102，同时也是恢复键 |
| `hmuf02v5`、`uf02`、`ufi001b`、`ufi003`、`uz801` | 无 | GPIO 37 / GPIO 23——普通复位，无电源键 |

在无按钮的板子上 `pwrkey-monitor` 不会启动，处理器也从不被调用；其他一切不变。

---

## 每次按压的结果

| 按压 | 结果 |
| :---- | :----- |
| 短按（≤ 2 秒） | 无——防误触 |
| 800 ms 内**两次**短按 | 干净的 `sync; reboot` |
| 按住 ≥ 4 秒，电池供电 | LED 闪烁 6 次，然后 `poweroff` |
| 按住 ≥ 4 秒，VBUS 供电 | 干净的 `sync; reboot`（见下文） |
| 按住 ≥ 约 10–15 秒 | PMIC 自行硬复位——软件无法阻止 |

### 为何插入电源时长按会重启

当 U 盘被 tether 时，软件关机不会保持关机：只要 VBUS 存在，
PMIC 就会重新施加系统电源，而按住足够久的按键会触发 PMIC 硬复位。
与其与 PMIC 赛跑（并让用户面对一个看似已死但实际在重启的 U 盘），
处理器检查每个 `/sys/class/power_supply/*/online`，当任一个读取 `1` 时执行干净重启。
电池供电时则真正关机。

---

## 工作原理

```
pm8941_pwrkey  (evdev, /dev/input/eventN)
        │
        │  /sbin/pwrkey-monitor   (procd, START=94)
        ▼
/etc/rc.button/power            ACTION=released SEEN=<seconds> BUTTON=power
        │
        ├─ SEEN ≤ 2  → 双击窗口 (800 ms) → reboot
        ├─ SEEN ≥ 4  → VBUS? reboot : 闪烁 + poweroff
        └─ 其他情况 → 无
```

`pwrkey-monitor` 存在是因为 procd 只对 `kmod-gpio-button-hotplug` 报告的
**GPIO** 按键分发 `/etc/rc.button/*`。PMIC 电源键是纯 evdev 设备，
从不产生那些 uevent，因此该监视器对其解码并提供相同的
`ACTION`/`SEEN`/`BUTTON` 环境。

实现要点（均为踩坑所得）：

* 按键是 `EV_KEY` 记录内的 **`0x74`**（`KEY_POWER` = 116）；不要信任
  此内核上的 `capabilities/key` 位图。
* 此处的 `input_event` 是 16 字节，但读取器采用 32 字节块并扫描
  滑动窗口，因此 24 字节的结构体也能工作。
* 它在放弃前最多等待 60 秒让 `pm8941_pwrkey` 输入节点出现。
  启动时裸 `exit 1` 会使 procd 紧密循环中重生它，因为驱动可能在服务启动后才探测。

---

## 调校

阈值是
[`etc/rc.button/power`](../msm89xx/base-files/etc/rc.button/power) 顶部的常量：

| 变量 | 默认值 | 含义 |
| :------- | :------ | :------ |
| `SHORT_MAX` | 2 | 仍算作“短按”的最长按压（秒） |
| `LONG_HOLD` | 4 | 触发关机 / 重启的最短按压（秒） |
| `DBL_WINDOW` | 800 | 双击窗口（毫秒） |

保持 `LONG_HOLD` 低于约 10 秒：超过后 PMIC 会自行复位板子，
脚本将永远看不到释放事件。

用于告别闪烁的 LED 是 `red:wan`、`green:wan`、`red:bat`、`green:bat`、
`green:wlan` 中第一个存在的——因此同一脚本无需板子检查即可在
两块按钮板子上工作。

---

## 故障排查

```sh
logread | grep -E "pwrkey-monitor|power-button"
cat /sys/class/input/input*/name          # 预期 pm8941_pwrkey
/etc/init.d/pwrkey-monitor running && echo ok
```

| 症状 | 原因 |
| :------ | :---- |
| 任何按压都无反应 | `pwrkey-monitor` 未运行，或无 `pm8941_pwrkey` 节点（板子无电源键） |
| 长按关机而不是重启 | 电池供电，而非 VBUS |
| 长按约 10 秒时板子重启 | PMIC 硬复位，不是脚本 |
| 双击不重启 | 两次按压相隔超过 800 ms |
