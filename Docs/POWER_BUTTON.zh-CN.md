> 📄 本文件是 [POWER_BUTTON.md](POWER_BUTTON.md) 的英文原文中文译本，内容以英文版为准。

# 电源按钮

本项目中只有**两**块板子有电源按钮：

| 板子 | 电源键 | Reset 按钮 |
| :---- | :-------- | :----------- |
| `mifib-v12` | `pm8941_pwrkey`（PMIC PON） | GPIO 102，同时也是恢复键 |
| `mf800b` | `pm8941_pwrkey`（PMIC PON） | GPIO 102，同时也是恢复键 |
| `hmuf02v5`、`uf02`、`ufi001b`、`ufi003`、`uz801` | 无 | GPIO 37 / GPIO 23——普通 reset，没有电源键 |

在没有按钮的板子上，`pwrkey-monitor` 不会启动，处理程序也永远不会被调用；
其他方面没有任何变化。

---

## 每次按下会发生什么

| 按法 | 结果 |
| :---- | :----- |
| 短按（≤ 2 s） | 无操作——防误触 |
| **800 ms 内两次**短按 | 干净的 `sync; reboot` |
| 长按 ≥ 4 s，用电池供电 | LED 闪 6 下，然后 `poweroff` |
| 长按 ≥ 4 s，用 VBUS 供电 | 干净的 `sync; reboot`（见下文） |
| 长按 ≥ 约 10–15 s | PMIC 自行硬复位——软件无法阻止 |

### 为什么插着电时长按会重启

只要棒状设备还接着线，软件关机就不会保持关闭：只要 VBUS 在线，PMIC 就会
重新施加系统电源，而按住足够久的按键会触达 PMIC 硬复位。 处理程序没有去
与 PMIC 竞速（而是让用户面对一台看似死机、其实在重启的设备），而是检查每一个
`/sys/class/power_supply/*/online`，只要有任何一个读到 `1` 就执行干净重启。
用电池供电时才真正关机。

---

## 工作原理

```
pm8941_pwrkey  (evdev, /dev/input/eventN)
        │
        │  /sbin/pwrkey-monitor   (procd, START=94)
        ▼
/etc/rc.button/power            ACTION=released SEEN=<seconds> BUTTON=power
        │
        ├─ SEEN ≤ 2  → double-press window (800 ms) → reboot
        ├─ SEEN ≥ 4  → VBUS? reboot : blink + poweroff
        └─ otherwise → nothing
```

`pwrkey-monitor` 之所以存在，是因为 procd 只对 `kmod-gpio-button-hotplug`
上报的 **GPIO** 按键分发 `/etc/rc.button/*`。 PMIC 电源键是一个普通 evdev
设备，永远不会产生那些 uevent，因此该监视器负责解码它，并提供相同的
`ACTION`/`SEEN`/`BUTTON` 环境变量。

实现说明（都是吃一堑长一智得来的）：

* 按键值在 `EV_KEY` 记录内是 **`0x74`**（`KEY_POWER` = 116）；在这个内核上
  不要相信 `capabilities/key` 位图。
* 这里的 `input_event` 是 16 字节，但读取端按 32 字节块读取并扫描滑动窗口，
  所以 24 字节的结构体同样可行。
* 它最多等待 60 s 找 `pm8941_pwrkey` 输入节点，之后才放弃。 启动时直接
  `exit 1` 会让 procd 以紧密循环重启它，因为驱动可能在服务启动之后才探测。

---

## 调整

阈值是
[`etc/rc.button/power`](../msm89xx/base-files/etc/rc.button/power)
顶部的常量：

| 变量 | 默认值 | 含义 |
| :------- | :------ | :------ |
| `SHORT_MAX` | 2 | 仍算作“短按”的最长时长（秒） |
| `LONG_HOLD` | 4 | 触发关机 / 重启的最短长按时长（秒） |
| `DBL_WINDOW` | 800 | 双击窗口（毫秒） |

把 `LONG_HOLD` 保持在约 10 s 以下：超过那个长度，PMIC 会自行复位板子，
脚本永远看不到松键。

用于告别闪烁的 LED 是 `red:wan`、`green:wan`、`red:bat`、`green:bat`、
`green:wlan` 中第一个存在的——因此同一份脚本无需板子判断即可在两块有按钮的
板子上工作。

---

## 故障排查

```sh
logread | grep -E "pwrkey-monitor|power-button"
cat /sys/class/input/input*/name          # expect pm8941_pwrkey
/etc/init.d/pwrkey-monitor running && echo ok
```

| 症状 | 原因 |
| :------ | :---- |
| 任何按法都无反应 | `pwrkey-monitor` 未运行，或没有 `pm8941_pwrkey` 节点（板子没有电源键） |
| 长按关机而不是重启 | 正在用电池供电，而不是 VBUS |
| 长按约 10 s 时板子重启 | PMIC 硬复位，不是脚本所为 |
| 双击没有重启 | 两次按键间隔超过 800 ms |
