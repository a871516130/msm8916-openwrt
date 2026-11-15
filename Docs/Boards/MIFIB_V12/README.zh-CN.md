> 📄 本文件是 [README.md](README.md) 的英文原文中文译本，内容以英文版为准。

# MIFIB-V12 —— 原厂 Android 设备树

MIFIB-V12（MIFID）dongle 的**原厂 Android DTB** 参考副本，于 2026-10-22
从一台正在运行且工作正常的 Android 系统中提取。保留它是为了让 OpenWrt
移植可以与厂商实际发布的产物做 diff。

## 文件

| 文件 | 内容 |
|---|---|
| `android-msm8916-mtp.dts` | 设备启动所用板卡 DTB 的反编译源码 |
| `android-msm8916-mtp.dtb` | 同一 DTB 的原始字节（权威版本） |

sha256：
```
f52928530a367590bb0b42ae2277191aafd4c73e58115e4072315386bc5301e6  android-msm8916-mtp.dtb
1a688703c95f2837a72e2ad91054fe1e4693767e16c1f9b3e2a44c1eb406cb34  android-msm8916-mtp.dts
```

## 来源（可复现）

在该 3.10 kernel 上，板卡 DTB **不会**通过 `/proc/device-tree` 或
`/sys/firmware/fdt` 暴露，因此它是从 boot 镜像中取出来的：

```sh
# boot header: page_size=2048 kernel=5937576 ramdisk=568157 dt_size=3748864
# DTB offset = 2048 + round_up(kernel) + round_up(ramdisk) = 6510592
ssh root@192.168.101.1 'dd if=/dev/block/bootdevice/by-name/boot \
    bs=512 skip=12716 count=7322' > dtblob.bin

# the blob starts with a QCDT table; scan for FDT magic instead of parsing it
python3 scratch/fdtscan.py dtblob.bin fdt/     # finds 23 DTBs
dtc -I dtb -O dts -o out.dts fdt/<one>.bin
```

**这 23 个中哪一个是板卡 DTB？** `fdt-002-off00051000.bin`
（`model = "Qualcomm Technologies, Inc. MSM 8916 MTP"`，
`qcom,board-id = <0x08 0x00>`）。
通过排除法确认：设备报告 `MemTotal 402464 kB`，所以它是普通 MTP，而
**不是** `MSM 8916 512MB MTP`（`board-id <0x08 0x100>`）。该 blob 中的其他
候选都是参考板（CDP/QRD/RUMI/Simulator/MSM8936/8939/APQ8016）。厂商没有
新增 `model` 字符串——他们直接修改了 MTP DTS。

## 三个按键

| 按键 | DT 标签 | TLMM GPIO | 极性 | `linux,code` | 在 OpenWrt 中暴露？ |
|---|---|---|---|---|---|
| 电源 | (PMIC pwrkey) | — | — | `KEY_POWER` (116) | 不适用 |
| Reset | `key_freset` | **102** (`0x66`) | 低电平有效 | `0xd8` = **216** = `KEY_CHAT` | 是 —— `button_restart` |
| WPS | `key_wps` | **27** (`0x1b`) | 低电平有效 | `0x40` = **64** = `KEY_F6` | **否** |

```dts
gpio_keys {
	compatible = "gpio-keys";
	input-name = "gpio-keys";
	pinctrl-0 = <0xda 0xdb>;	/* tlmm_gpio_key — pin 0x66 only */

	key_freset {
		label = "key_freset";
		gpios = <0x2f 0x66 0x01>;	/* tlmm, 102, GPIO_ACTIVE_LOW */
		linux,code = <0xd8>;		/* KEY_CHAT */
		gpio-key,wakeup;
		debounce-interval = <0x3c>;	/* 60 ms */
	};

	key_wps {
		label = "key_wps";
		gpios = <0x2f 0x1b 0x01>;	/* tlmm, 27, GPIO_ACTIVE_LOW */
		linux,code = <0x40>;		/* KEY_F6 */
		gpio-key,wakeup;
		debounce-interval = <0x3c>;	/* 60 ms */
	};
};
```

两个引脚空闲时均为**高电平**（`/sys/kernel/debug/gpio`：`in hi`），即低电平
有效、外部上拉，且两者都具备 `gpio-key,wakeup` 能力。

**Pinctrl：**两个独立的组，每组一个引脚，均为 `pin-func = 0`（GPIO）、
`bias-pull-up`、2 mA，并带有 active 与 suspend 两种变体：

```dts
tlmm_gpio_key     { qcom,pins = <0xcf 0x66>; ... }   /* pin 102, phandles 0xda / 0xdc */
tlmm_wps_gpio_key { qcom,pins = <0xcf 0x1b>; ... }   /* pin  27, phandles 0xdb / 0xdd */
```

运行时确认（`/sys/kernel/debug/pinctrl/1000000.pinctrl/pinmux-pins`）：

```
pin 27  (gp-27):  gpio_keys.62 gp:929  function tlmm_wps_gpio_key-func group tlmm_wps_gpio_key
pin 102 (gp-102): gpio_keys.62 gp:1004 function tlmm_gpio_key-func     group tlmm_gpio_key
```

## 与 OpenWrt 移植的差异

`msm89xx/patches/853-arm64-dts-qcom-add-msm8916-generic-mifib-v12.patch`
只添加了 `&button_restart`（`gpios = <&tlmm 102 GPIO_ACTIVE_LOW>`）和
`&button_default`（`bias-pull-up`）。**没有 `gpio-keys` 节点，也没有
`key_wps`** —— WPS 按键对 OpenWrt 不可见。

## 实测：WPS 按键并不驱动 GPIO 27（2026-10-22）

在运行中的 Android 上测试，物理按下按键并保持 5 秒：

* 在整个保持期间以约 10 Hz 采样 `/sys/kernel/debug/gpio` —— **`gpio-929
  (key_wps)` 始终保持 `in hi`**（没有记录到任何 `in lo` 跳变）。
* `getevent -lt /dev/input/event1` —— **0 行**；没有 `KEY_F6` 事件。

因此 `key_wps` 节点是从 MTP 继承来的样板内容，这块 PCB 并未将其布线（或者
按键被布到 WiFi 模块 / 某条不是 TLMM 27 的网络上）。该引脚本身是健康的：
已复用到 `tlmm_wps_gpio_key-func`、施加上拉、被 `gpio_keys.62` 认领、空闲
为高电平。

**对恢复设计的影响：** WPS 按键在该板上**不能**用作恢复键。GPIO 102
（`key_freset`）是唯一真正布线的按键，因此 mifib-v12 上的恢复按键只能是
reset 按键。

## 实测：reset 按键是普通 GPIO，可安全用作启动期按键（2026-10-22）

按住 reset 按键不放，然后按下电源键（电池供电、USB 已拔掉）：
**Android 正常启动，按键没有任何效果。**

如果 `key_freset` 接入了硬件复位路径，上电时按住它会让 SoC 一直保持在复位
状态，设备将永远起不来。而设备起来了，说明该按键就是普通 GPIO 输入，
**lk2nd 可以在启动时采样它** —— 这正是恢复键设计所需的唯一前提条件。

## Android 中的 reset 按键长按

在 Android 运行时长按 reset 按键约 5 秒会**重启设备并恢复出厂设置**——
管理 IP 从 `192.168.101.1` 变回出厂默认的 `192.168.100.1`。这是用户态行为：
该按键是 `KEY_CHAT` (216)，不是标准 keycode，因此几乎可以肯定有一个厂商
守护进程在监听它的长按。

## 未解问题

* WPS 按键实际接在哪条网络上？（不是 GPIO 27。按键是贴装的，所以它必然
  连到某处——可能直接连到 WiFi 模块，那样的话它对 AP 完全不可见。）
* 在 GPIO 102 上同样的 5 秒长按能否在 OpenWrt 中复现，还是说它纯粹是
  Android 的用户态策略。
