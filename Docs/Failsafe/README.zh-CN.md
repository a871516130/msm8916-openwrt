> 📄 本文件是 [README.md](README.md) 的英文原文中文译本，内容以英文版为准。

# Failsafe 模式、恢复出厂设置与恢复

这些 MSM8916 USB 棒状设备**没有以太网口，也没有外部串口排针**。 与它们通信
的唯一途径是它们呈现给主机的 USB gadget（一个 CDC-NCM 网络接口加一个
CDC-ACM 串口控制台）以及 Wi‑Fi/LTE 无线电。 这让恢复变难：如果一个坏配置
让网络挂掉，正常启动就不可达。

本文涵盖固件内置的恢复路径：

1. **Failsafe 模式** —— 一个极简的 pre-init shell，可通过 `192.168.10.1`
   （USB 网卡）或 `/dev/ttyACM0`（USB 串口）进入，用于修复损坏的配置。
2. **恢复出厂设置** —— 在运行中的系统里，**长按 5 秒** Restart 按钮会清空
   overlay。
3. **EDL / Fastboot** —— 从主机进行的最后手段重刷。

---

## 1. Failsafe 模式

Failsafe 模式是 OpenWrt 标准的 pre-init 救援 shell。 它在任何配置被应用
**之前**，从只读 squashfs 启动 kernel 和一个极简用户态，让你能够修复问题
（重置网络配置、挂载 overlay、运行 `firstboot` 等）。 这与 OpenWrt 路由器
使用的是同一套机制——这个固件只是为无头棒状设备增加了触发方式和可达性。

### 如何进入

**选项 A —— Restart 按钮（推荐）。** 给棒状设备上电（或重启它），并在启动
的头 7 秒内**任意时刻按一次 Restart 按钮**。

- **单次短按就够了**——无需长按。 按键只需落在 7 秒窗口之内。
- 注意看 **LED**：进入 failsafe 后它会**快闪**（约 12 Hz）。 板子有
  **红色** LED 就用红色，否则用**绿色** LED（UZ801 v3），再否则用任意 LED。

> **UZ801 状态：** GPIO23 对按钮有响应，空闲时观测为高电平；其 DTS 现在
> 使用低电平有效/上拉。 完整的 failsafe 流程在 UZ801 上尚不能工作，
> 因此在那里不要依赖该按钮进行恢复。
**选项 B —— 串口控制台。** 如果你把 UART 接到了 kernel 控制台
（`ttyMSM0`，115200），在同一窗口内按 **`f`** 再回车。

> **启动延迟：** failsafe 窗口是 7 s，因此每次启动都要比原厂的 4 s 多等
> 约 3 s 才继续。 这是换来可用按钮触发方式的代价。

### 如何访问

Failsafe 会自行拉起一个极简 USB gadget（NCM + ACM），因此主机看到：

- 一个配置为 **`192.168.10.1/24`** 的 **USB 网络接口**（CDC-NCM），以及
- 一个 **USB 串口**——Linux 上是 `/dev/ttyACM0`，115200 波特。

**SSH**（无密码）：

```bash
ssh root@192.168.10.1
```

**串口控制台：**

```bash
screen /dev/ttyACM0 115200      # or: picocom -b 115200 /dev/ttyACM0
```

> failsafe 地址故意设为 `192.168.10.1`，与正常 LAN 地址 `192.168.8.1`
> 不同，这样半坏的网络配置不会与它冲突。 Failsafe 在 gadget 链路上运行
> 一个 DHCP 服务器（dnsmasq，地址池 `192.168.10.10`-`.50`），因此主机通常
> 会自动拿到地址。 如果没有，运行
> `ip addr add 192.168.10.2/24 dev <usb-nic>`。 租约**不带默认路由器、
> 也不带 DNS 服务器**：failsafe 没有 WAN，而把自己通告为网关会在棒状设备
> 插上的那一刻替换主机的默认路由。

> **failsafe 里没有 WiFi——有意为之。** Failsafe 是 *pre-init* 环境：
> 它在无线配置被应用**之前**从只读 squashfs 运行，而 wcn36xx 需要它的
> 固件（位于 overlay 上）加上一个 `hostapd` 守护进程才能发挥作用。
> 提供 WiFi 的是**恢复镜像**：一个 AP，这样不在网线旁边的盒子仍能从手机或
> 笔记本被操控。 让 failsafe 只保留 USB 也保住了它 7 s 的窗口以及
> “永远无法清空 overlay”这一性质。 参见
> [`Docs/RECOVERY/README.md`](../RECOVERY/README.md) §5。

### 进去之后做什么

根文件系统以只读挂载，overlay 还**没有**挂载。 典型的恢复步骤：

```bash
# Mount the writable overlay so your edits persist:
mount_root

# Inspect / repair the config, e.g.:
vi /etc/config/network
vi /etc/config/wireless

# Reset to defaults (wipes the overlay):
firstboot && reboot

# Or just reboot out of failsafe when done:
reboot
```

说明：

- 不运行 `mount_root`，编辑只存在于 RAM 中，重启即失。
- `firstboot` 移除 overlay 内容；只读 squashfs（固件本身）不受影响。
- 如果 `/tmp` 里暂存了 `sysupgrade` 镜像，failsafe 会检测到它并自动继续
  升级，而不是落到 shell。

### 如果 failsafe 没有起来

- **主机上没有新 USB 设备？** 换一根 USB 线/换一个口试试；NCM gadget
  需要 USB 数据线，不是只能充电的线。
- **按钮没反应？** 7 秒窗口在 preinit 期间开始，而不是在上电时。
  HMU05 的按钮触发 failsafe 流程已验证。 UZ801 的按钮响应和空闲电平已验证，
  但它的 failsafe 流程还不能工作。 UFI001B、UFI003、UF02 和 MF800B 的按钮
  被声明为高电平有效/下拉，但尚未在硬件上确认——如果你的没反应，请改用
  串口 `f` 键并反馈。
- **全都挂了？** 退回 EDL（第 3 节）。

---

## 2. 恢复出厂设置（在运行中的系统里）

系统起来之后，**长按 5 秒** Restart 按钮会执行恢复出厂设置并重启：

1. 按住 Restart 按钮 **5 秒**。
2. 松开。 设备运行 `factoryreset`，并带着干净的 overlay 重启。

**短按没有任何作用**——快速点按不会让设备重启（与原厂 OpenWrt 不同），
正因为该按钮是唯一的物理控制，而无头盒子上的误重启代价很高。

> 恢复出厂设置只清空 **overlay**（你的配置和安装的软件包）。 它绝不会
> 碰调制解调器固件、NV 分区或 bootloader。

---

## 3. EDL / Fastboot（最后手段）

如果系统无法启动且 failsafe 不可达，从主机重刷。

从运行中的 OpenWrt（如果你还能到达它）：

```bash
reboot-edl            # Qualcomm EDL  (host sees 05c6:9008)
reboot-bootloader     # Qualcomm Fastboot (host: fastboot devices)
```

然后使用 [`Docs/EDL/`](../EDL/) 中的刷机工具和项目的
[`flash.sh`](../../msm89xx/image/flash.sh)。 详情参见主
[README → Recovery](../../README.md#-recovery-and-reboot-modes)。

> ⚠ **一次糟糕的 migrate 刷写可能损坏调制解调器 NV**（`modemst1`/`modemst2`），
> 把 IMEI 变成 `000000000000000`。 如果你使用 EDL，请从已知良好的转储中
> 恢复七个关键分区（`fsc fsg modem modemst1 modemst2 persist sec`）。

---

## 参考——各板子细节

| 板子   | Restart 按钮 GPIO | 极性 / 偏置        | 状态 LED                    | Failsafe LED |
|---------|---------------------|------------------------|----------------------------------|--------------|
| HMU05   | `tlmm 37`           | active-high, pull-down | `red:power`                      | `red:power`  |
| UFI001B | `tlmm 37`           | active-high, pull-down | `red:power`                      | `red:power`  |
| UFI003  | `tlmm 37`           | active-high, pull-down | `red:power`                      | `red:power`  |
| UF02    | `tlmm 23`           | active-high, pull-down | `red`                            | `red`        |
| UZ801   | `tlmm 23`           | active-low, pull-up    | `green:wlan` (no red on some)    | `green:wlan` |
| MF800B  | `tlmm 102`          | active-high, pull-down | `red:wlan`, `red:wan`, `red:charging` | all red LEDs |

> ⚠ **按钮的极性和偏置必须与硬件匹配，否则按钮完全无效**（永远没有边沿到达
> 驱动，因此没有 uevent，也就没有 failsafe）。 已验证的 HMU05 行为是
> **`GPIO_ACTIVE_HIGH` + `bias-pull-down`**（空闲低电平，按下 = 高电平）：
> 它的针孔式 Restart 按钮按下时把 GPIO37 **拉高到 VCC**，原厂 HMU05
> Android DTS 也是这么写的（`key_freset`，flags `0x00`）。 早先
> 低电平有效/上拉的声明让 GPIO37 空闲为高电平，于是按下不产生边沿。
>
> **只有 HMU05 在实机上验证过（2026-10-10）。** UFI001B、UFI003、UF02 和
> MF800B 被声明为高电平有效/下拉但未经验证。 **UZ801 是例外——它是
> 低电平有效/上拉**：GPIO23 空闲为高电平，所以高电平有效的声明会让驱动
> 把按钮读成一直被按住，一次短按就触发了恢复出厂设置；已于 2026-10-16
> 回退（PR #11）。 如果某块板子的按钮接线相反，修法是回退该板子的补丁
> （`GPIO_ACTIVE_HIGH` ↔ `GPIO_ACTIVE_LOW`、`bias-pull-down` ↔
> `bias-pull-up`）并反馈。 如果按钮没反应，请对照板子的原厂 DTS 检查
> `bias` 和极性。

> Failsafe LED 在有红色时**红色**快闪，否则**绿色**快闪（没有红色 LED 的
> UZ801 v3 设备），再否则任意 LED——这样每块板子上指示都有效。

该按钮是 DT 的 `button_restart` 节点（`KEY_RESTART` → 按钮名 `reset`）。
它由 `kmod-gpio-button-hotplug` 驱动，后者发出按钮 uevent；preinit 的
hotplug 守护进程把启动窗口内的按键变成 `/tmp/failsafe_button`，而运行中的
系统为恢复出厂长按执行 `/etc/rc.button/reset`。

## 实现说明

- Failsafe 核心（`lib/preinit/30_failsafe_wait`、`40_run_failsafe_hook`、
  `99_10_failsafe_login`）是原厂 OpenWrt 且被编译进来。
- `CONFIG_TARGET_PREINIT_TIMEOUT=7` 设定窗口；`CONFIG_TARGET_PREINIT_IP`
  等设定 failsafe 地址（各板子的 `diffconfigs/`）。 这些符号是
  **有门控的**：`CONFIG_IMAGEOPT=y` 让 `CONFIG_PREINITOPT` 可见，
  `CONFIG_PREINITOPT=y` 让 `TARGET_PREINIT_*` 符号可见。 两者必须都设置，
  否则 `make defconfig` 会把它们重置为默认值（4 s /
  `192.168.1.1`）。 请在构建出的镜像的 `lib/preinit/00_preinit.conf` 中核对。
- `msm89xx/base-files/lib/preinit/35_failsafe_usb` 拉起 preinit USB
  gadget（configfs `g1`：`ncm.usb0` + `acm.GS0`）、分配地址、闪 LED
  （红 → 绿 → 任意回退），并生成 `ttyGS0` 登录 shell。 它只在 `failsafe`
  钩子上运行。
- `msm89xx/base-files/etc/rc.button/reset` 是启动后的恢复出厂处理程序
  （长按 5 s；短按被忽略）。
- 内核内的 `gpio_keys` 驱动（`CONFIG_KEYBOARD_GPIO`）被**禁用**，以便
  `kmod-gpio-button-hotplug` 能绑定 `gpio-keys` DT 节点；否则内建驱动会
  先抢走它，按钮就不产生 hotplug uevent。

### 事后分析：为什么长按 5 s 会清空 overlay，而 failsafe 不会

存在两条独立的按钮路径，从外面看它们一模一样：

| 启动路径 | 运行什么 | overlay 已挂载？ | 能清空吗？ |
|---|---|---|---|
| 在 7 s 窗口内按下 | `30_failsafe_wait` 设置 `FAILSAFE` -> `40_run_failsafe_hook` **阻塞** | **否** —— preinit 永远到不了 `80_mount_root` | **永远不会** |
| 按键错过窗口（正常启动） | 经 `button-hotplug` 的 `/etc/rc.button/reset` | **是**（约 1–2 s 时挂载） | **是，松键时** |

`40_run_failsafe_hook` 停在
`while [ ! -e /tmp/sysupgrade ]; do lock -w /tmp/.failsafe; done`，
这在 preinit 链中位于 `80_mount_root` *之前*。 所以在 failsafe 内部
`/overlay` 确实未挂载，`rc.button/reset` 看到空的 `OVERLAY` 变量并拒绝
动作。 到达 failsafe 的按键是安全的。

陷阱是另一行。 `rc.button/reset` 对 `released` 的判断与 `pressed`
**相互独立**：

```sh
released)
	if [ "$SEEN" -ge "$HOLD_SECONDS" ] 2>/dev/null && [ -n "$OVERLAY" ]; then
		factoryreset -y && reboot &
	fi
```

没有从 `pressed` 事件携带任何状态，因此一个在 `/overlay` 存在之*前*开始的
按键，只要在 `button-hotplug` 探测之后 >= 5 s 松开，仍会清空这台设备。
没有任何提示，控制台上不打印任何东西，重启在后台发生——在高负载的设备上
（例如 WCNSS 固件正在崩溃循环时）可能要花几秒，于是设备看起来像
“没有重启”。

**观测到的后果（2026-10-24）：** 启动期间错过 7 s 窗口的 5 秒长按对设备执行了
恢复出厂设置。 overlay 回到默认状态（45 MB，`.fs_state -> 2`），
`/etc/config/wireless` 消失，无线电以 `OpenWrt` 在信道 1 上起来，只有手工
重建 Wi‑Fi 配置后设备才可达。

**经验法则：** 在这些棒状设备上，Restart 按钮有*两种*破坏性含义，只差在
时机。 在头 7 秒内点按一次（< 1 s）进入 failsafe。 除非你有意恢复出厂设置，
否则绝不要在启动期间长按它。


> **串口控制台节点：** preinit 的 `/dev` 是 512k tmpfs，没有 devtmpfs
> 填充，因此即使主机正常枚举出 `/dev/ttyACM0`，kernel 也不会为 ACM 功能
> 创建节点。 所以 `35_failsafe_usb` 在生成登录 shell 之前自行创建它
> （从 `/sys/class/tty/ttyGS0/dev` 执行
> `mknod /dev/ttyGS0 c <major> <minor>`）。 2026-10-24 验证：节点被删除，
> `fs_ensure_tty` 重新创建它（242:0），主机从 `/dev/ttyACM0` 读到
> BusyBox 横幅。
