> 📄 本文件是 [ADDING_A_DEVICE_BOARD.md](ADDING_A_DEVICE_BOARD.md) 的英文原文中文译本，内容以英文版为准。

# 为 msm8916-openwrt 添加新设备板卡

本指南逐步讲解了为该固件树添加一块新的 MSM8916 板卡（4G dongle / MiFi / stick）支持所需的全部工作。

本指南基于一个真实、完整的例子撰写：**PR #2 —— MF800B 板卡**
（于 2026-09-22 合并）。下文引用的每个文件都是该 PR 实际改动过的文件。
请将 MF800B 的文件与本指南对照阅读；它们是权威模板。

> 心智模型：构建 target `msm89xx/msm8916` 已经存在，并且已经能为*每一块*
> MSM8916 板卡构建。"添加一块板卡"意味着添加**一个 Device profile +
> 一个 Device Tree + 一个 diffconfig**，外加少量通常可选的、针对 LED /
> 按键的 base-files 微调。你几乎不需要改动 kernel、网络配置或构建系统本身。

---

## 0. 前置条件 —— 了解你的硬件

在编写任何代码之前，先收集关于目标板卡的这些事实：

| 事项 | 原因 | 哪里能找到 |
|------|------|------------|
| SoC 是 **MSM8916**（Snapdragon 210/410） | 整个树都面向这个 SoC | 板卡标签 / 原厂固件 |
| 它复用 **`msm8916-ufi.dtsi`** 布局 | 当前所有板卡都基于这个底座 | 确认它能用 ufi 布局启动 Android/Linux |
| **LED GPIO**（TLMM 引脚，高电平/低电平有效） | DTS 必须映射它们 | 原厂 DTS，或探测板卡 |
| **复位按键** GPIO 及极性 | failsafe 与复位处理程序 | 原厂 DTS 的 `gpio-keys` 节点 |
| **eMMC 容量**（以 512 字节扇区计） | 决定 `GPT_TOT_SECTORS` | 在原厂系统上执行 `cat /sys/block/mmcblk0/size`，或读取 GPT |
| **电池 / 充电器**是否存在？ | 决定 `battery` / `pm8916_charger` 节点 | 原厂 DTS |
| **EDL 进入方式**（测试点 / 按键组合） | 刷机与恢复所必需 | 查找 `FB` 测试点、音量键/组合键 |

如果该板卡*不是* ufi 布局板卡，下面的 DTS 工作会更困难
（不同的 `.dtsi` 底座，可能还有不同的外设）。本指南的其余部分假设是
常见的 ufi stick/MiFi 形态。

---

## 1. Device Tree 源码（一个新的 kernel patch）

创建一个新 patch：

```
msm89xx/patches/8XX-arm64-dts-qcom-add-msm8916-generic-<board>.patch
```

选择 **8xx 范围内下一个空闲编号**（MF800B 用的是 `807`；`801` 是
qcom 的 Makefile，所以不要复用它）。该文件是一个 `git diff --no-index`
风格的 patch，在 `arch/arm64/boot/dts/qcom/msm8916-generic-<board>.dts`
下添加一个新的 `.dts`。

模板（摘自 `807-arm64-dts-qcom-add-msm8916-generic-mf800b.patch` 的精简版）：

```dts
// SPDX-License-Identifier: GPL-2.0-only

/dts-v1/;

#include "msm8916-ufi.dtsi"
#include <dt-bindings/leds/common.h>

/ {
        model = "<Board> 4G ...";
        compatible = "<board>,generic", "qcom,msm8916";

        /*
         * Optional: a battery node. Only if the board has a Li-ion cell
         * and you want charge / capacity reporting. Copy the mf800b values
         * and adjust voltage / capacity to the pack label.
         */
        battery: battery {
                compatible = "simple-battery";
                device-chemistry = "lithium-ion-polymer";
                voltage-min-design-microvolt = <3350000>;
                voltage-max-design-microvolt = <4350000>;
                charge-full-design-microamp-hours = <2100000>;
                constant-charge-current-max-microamp = <1000000>;
                constant-charge-voltage-max-microvolt = <4350000>;
        };
};

/* Persistent kernel log (ramoops) — same region as every other board. */
&reserved_memory {
        ramoops@8db00000 {
                compatible = "ramoops";
                reg = <0x0 0x8db00000 0x0 0x00100000>;
                record-size = <0x00040000>;
                console-size = <0x00040000>;
                pmsg-size   = <0x00040000>;
                ecc-size = <16>;
        };
};

/*
 * LEDs. The ufi .dtsi ships a generic tri-colour "led-r/g/b". Delete those
 * and define your real, named LEDs. Match function/color to what the LED
 * scripts expect (see §4).
 */
&{/leds} {
        /delete-node/ led-r;
        /delete-node/ led-g;
        /delete-node/ led-b;

        led-wlan-green { function = LED_FUNCTION_WLAN; color = <LED_COLOR_ID_GREEN>; gpios = <&tlmm 73 GPIO_ACTIVE_HIGH>; };
        led-wlan-red   { function = LED_FUNCTION_WLAN; color = <LED_COLOR_ID_RED>;   gpios = <&tlmm 84 GPIO_ACTIVE_HIGH>; };
        led-wwan-green { function = LED_FUNCTION_WAN;  color = <LED_COLOR_ID_GREEN>; gpios = <&tlmm 85 GPIO_ACTIVE_HIGH>; };
        led-wwan-red   { function = LED_FUNCTION_WAN;  color = <LED_COLOR_ID_RED>;   gpios = <&tlmm 72 GPIO_ACTIVE_HIGH>; };
        /* ... etc ... */
};

/* The gpio_leds pinctrl must list every LED GPIO you use. */
&gpio_leds_default {
        pins = "gpio0", "gpio1", "gpio72", "gpio73", "gpio84", "gpio85";
};

/*
 * Reset button. Copy the active-high / pull-down convention used by the other
 * boards (verified on HMU05/UFI001B). gpio102 is the common ufi "key_freset".
 */
&button_restart {
        gpios = <&tlmm 102 GPIO_ACTIVE_HIGH>;
};
&button_default {
        pins = "gpio102";
        bias-pull-down;
};

/*
 * Battery charger and voltage-mode BMS are board-specific. In the pinned
 * Linux 6.12 tree, the base PM8916 DTS leaves pm8916_charger disabled and
 * msm8916-ufi.dtsi enables pm8916_usbin as the USB extcon. A battery-equipped
 * board may need the MF800B-style charger/BMS setup instead; do not enable
 * both paths because they share PMIC USB detection resources. A bus-powered
 * stick without a battery should keep the usbin extcon and omit battery/BMS
 * nodes.
 */
&pm8916_usbin   { status = "disabled"; };
&pm8916_charger {
        monitored-battery = <&battery>;
        qcom,fast-charge-safe-voltage = <4350000>;
        qcom,fast-charge-safe-current = <1000000>;
        status = "okay";
};
&pm8916_bms {
        monitored-battery = <&battery>;
        power-supplies = <&pm8916_charger>;
        status = "okay";
};

/* Peripheral-only USB, fed by the charger extcon. */
&usb         { dr_mode = "peripheral"; extcon = <&pm8916_charger>; };
&usb_hs_phy  { extcon = <&pm8916_charger>; };
```

**DTS 的经验法则**

* **第一个 `compatible` 字符串**（`"<board>,generic"`）会成为 OpenWrt
  运行时看到的 `board_name`（`/tmp/sysinfo/board_name`）。保持它稳定 ——
  base-files 脚本会对它做 glob 匹配。
* 保留 `ramoops` 区域。正是它让 kernel panic 可以恢复。
* 保留 `pm8916_usbin` 禁用 / `pm8916_charger` 启用这种拆分，除非你有
  具体的理由不这么做。

---

## 2. 在 qcom Makefile patch 中注册 DTB

kernel 只会构建列在 qcom `Makefile` 中的 DTB。把你的板卡加入维护该列表的
现有 patch：

`msm89xx/patches/801-arm64-dts-qcom-add-devices-makefile.patch`

```diff
 dtb-$(CONFIG_ARCH_QCOM)	+= msm8916-samsung-j5.dtb
+dtb-$(CONFIG_ARCH_QCOM)	+= msm8916-generic-<board>.dtb
 dtb-$(CONFIG_ARCH_QCOM)	+= msm8916-samsung-j5x.dtb
```

没有这一行，DTB 就永远不会被编译，镜像构建会失败，或者构建出的镜像
不包含你的 device tree。

---

## 3. Device profile —— `msm89xx/image/msm8916.mk`

添加一个 `define Device/...` 块。它继承共享的 `Device/msm8916`
默认值（cmdline、squashfs、GPT 产物、flash.sh），只覆盖板卡相关的部分。
以 `generic-mf800b` 块为样板：

```makefile
define Device/generic-<board>
	$(Device/msm8916)
	DEVICE_VENDOR := Generic
	DEVICE_MODEL  := <Board>
	DEVICE_DTS    := msm8916-generic-<board>
	SUPPORTED_DEVICES := <board>,generic
	FILESYSTEMS   := squashfs
	# Only if your eMMC size differs from the 4 GB sticks:
	# GPT_TOT_SECTORS := <cat /sys/block/mmcblk0/size>
	# Only if you want the 17-partition layout (misc + recovery):
	# GPT_RECOVERY := 1
	DEVICE_PACKAGES := wpad-basic-wolfssl rmtfs uci-usb-gadget \
		block-mount f2fs-tools tar \
		msm-firmware-dumper reboot-edl qcom-carrier-autocfg \
		diag-efs diag-logtool
endef
TARGET_DEVICES += generic-<board>
```

说明：

* **`DEVICE_DTS`** 必须等于你在 §1 中创建的 `.dts` 文件基本名。
* **`SUPPORTED_DEVICES`** 必须包含该 target 的 sysupgrade 兼容性检查所
  接受的板卡标识。在本树中，它通常与板卡专属的第一个 DTS compatible
  字符串一致（例如，`compatible = "mf800b,generic", ...` 对应
  `SUPPORTED_DEVICES := mf800b,generic`）。保持拼写一致。
* **`DEVICE_PACKAGES`** —— 从上面的通用集合开始。只有当板卡确实需要时
  才添加板卡独有的 package（例子：`qcom-time-daemon` 只用于
  `generic-hmuf02v5`，因为它锚定 HMUF02-V5 modem 的 ATS 状态，而且它的
  init 在其他所有板卡上都是空操作）。如果你的板卡有电池，就添加
  **`luci-app-battery`** —— 这个 package 带有 LuCI 页面、充电限制器和
  电池 LED 监视器。不要把这些脚本放进 target 的 base-files：那样每块
  板卡都会得到它们，包括没有电池的板卡。
* **`GPT_TOT_SECTORS`** —— 只有当 eMMC 容量不同时才覆盖。默认值
  （`7569408`）是 4 GB stick 的容量。`flash.sh` 现在会在刷机时从 GPT
  中*读取*真实容量，但镜像自身的 GPT 是由这个值构建的，所以请为你的
  硬件正确设置它。
* **`GPT_RECOVERY`** —— 设为 `1` 可在 `rootfs_data` 之后追加 `misc`
  （1 MiB）和 `recovery`（16 MiB）分区，这正是 lk2nd 启动故障转移和
  LuCI *Reboot to Recovery* 入口所需要的。`boot`/`rootfs` 的偏移不会
  移动，所以该标志可以稍后添加，但那时必须对 stick 重新分区（要完整跑
  一次 `flash.sh`，而不是 `sysupgrade`）。
* **⚠ `DEVICE_VARS`** —— 任何新的每设备变量**必须**在 `msm8916.mk`
  顶部声明：
  ```makefile
  DEVICE_VARS += GPT_TOT_SECTORS GPT_RECOVERY
  ```
  没有它，该变量就是一个普通全局变量，于是每个 `define Device/...` 块
  都会继承*前一个*块留下的值。`generic-hmuf02v5` 一度悄悄地发布了
  MF800B 的分区布局，正是这个原因：文件中最后一个设备获胜。如果一块新
  板卡莫名其妙地获得了另一块板卡的分区大小，先检查 `DEVICE_VARS`。

---

## 4. 板卡专属的 base-files（通常很少或没有）

OpenWrt 的运行时脚本位于 `msm89xx/base-files/`。大多数已经是
**对所有板卡通用的**，无需修改：

* `etc/board.d/02_network` —— 把 `usb0` 设为 LAN、Wi-Fi 国家码和 AP
  SSID。**无需修改**，除非你的板卡网络不同。
* `etc/uci-defaults/99-msm89xx-firstboot` —— ModemManager WAN、移除
  不存在的 target feed 等。**无需修改。**

只有当你的板卡硬件不同时才编辑这些：

### 4a. Wi-Fi LED —— `etc/hotplug.d/ieee80211/99-wifi-led`

该脚本在 `phy0` 出现时点亮一个 WLAN LED。它通过 class-name 回退来选择
LED（`green:wlan` → `green:wan`），并跳过没有合适 LED 的板卡。PR #2 为
MF800B 添加了一个显式跳过（它没有自动 LED 指示）：

```sh
case "$(cat /tmp/sysinfo/board_name 2>/dev/null)" in
	*<board>*) exit 0 ;;   # your board has no WLAN LED, or you handle it elsewhere
esac
```

如果你的板卡*确实*有 `green:wlan` / `green:wan` LED，这里**无需修改**
—— 它会被自动拾取。如果你使用不同的 LED class 名称，要么把 DTS 节点改名
以匹配，要么添加一个板卡分支。

### 4b. 电源键 —— `etc/rc.button/power`

该处理程序在长按时关闭设备电源，并先闪烁一个"告别"LED。它会按*列表*
依次回退尝试 LED 名称：

```sh
LED="/sys/class/leds/red:power"
[ -d "$LED" ] || LED="/sys/class/leds/green:power"
[ -d "$LED" ] || LED="/sys/class/leds/green:charging"
[ -d "$LED" ] || LED="/sys/class/leds/red:charging"
[ -d "$LED" ] || LED="/sys/class/leds/green:wan"
[ -d "$LED" ] || LED="/sys/class/leds/blue:wan"
```

如果你的板卡上这些 LED 一个都不存在，处理程序仍然会关机 —— 只是跳过
闪烁。**严格来说无需修改**，但如果你的板卡的电源/充电 LED 叫别的名字，
把它加进这个回退链，让用户能看到视觉确认。

有两个行为值得了解：

* **当 VBUS 存在时长按会重启而不是关机。** 在带电池的板卡上，关机会
  让一个仍然插着电的 stick 看起来像死机了，所以处理程序会先检查每个
  `/sys/class/power_supply/*/online`，当其中一个读到 `1` 时执行干净的
  `sync; reboot`。
* **只有当 PMIC 电源键事件到达 userspace 时，处理程序才会运行。**
  `sbin/pwrkey-monitor`（由 `init.d/pwrkey-monitor` 启动）找到
  `pm8941_pwrkey` 输入设备，解码 keycode `0x74`（`KEY_POWER`）并把按住
  时长写给 `/etc/rc.button/power`。它最多等待输入节点 60 秒，所以在
  启动较慢时**绝不能**提前退出 —— 否则 procd 会循环地反复拉起它。
  没有电源键的板卡根本不会触发它。

### 4c. 已经按 `board_name` 分支的服务

有两个服务会对 `board_name` 做 glob 匹配，可能需要把你的板卡加入
允许列表：

* `lib/himi-ok.sh` —— **HiMI 基带**的 "modem-OK" 守卫。只有带 HiMI
  基带的板卡（HMU05、UF02、UZ801……）需要它。如果你的板卡是 HiMI 基带
  设备，把它加进允许列表；否则就不要加。
* `usr/sbin/modem-led-monitor` —— 蜂窝/充电 LED 监视器。它已经按板卡
  分支；只有当你希望 WWAN LED 行为与默认不同时才添加分支。

---

## 5. 板卡 diffconfig —— `diffconfigs/<board>`

该文件是板卡保存下来的 OpenWrt 配置。**`build.sh` 从这个目录枚举板卡**
（`build.sh list` 会列出这里的每个文件），CI / 发布流程会为每个
diffconfig 构建一个镜像 + 一个 kmod feed。

复制一个现有文件作为起点：

```sh
cp diffconfigs/uf02 diffconfigs/<board>
```

（`uf02` 是最小模板；`mf800b` 还带有三行 `amneziawg`，你必须删除它们。）

然后编辑它：

* 设置设备选择（这是最重要的一行）：
  ```sh
  CONFIG_TARGET_msm89xx=y
  CONFIG_TARGET_msm89xx_msm8916=y
  CONFIG_TARGET_msm89xx_msm8916_DEVICE_generic-<board>=y
  ```
* **Failsafe**：7 秒的 preinit 窗口和 `192.168.10.1` 的 preinit IP
  已经是默认值。保留 `CONFIG_IMAGEOPT=y` / `CONFIG_PREINITOPT=y`
  / `CONFIG_TARGET_PREINIT_*` 这一块（从 uf02 复制而来），使它们保持
  显式，且不会被 `make defconfig` 重置。
* 添加任何**板卡专属的 package 选择**（例如，如果你的板卡是 HMU05 级别
  的，就加 `qcom-time-daemon`）。
* 那一大块 `=m` 是**可选的 kmod feed** —— 被构建进 package feed 但
  *没有*烧进镜像的模块，这样用户可以按需 `apk add`。逐字复制它；只有
  确定某个模块不需要时才裁剪。这些保持 `=m` 是有意为之 —— 外部模块，
  从不内置 —— 所以它们留在 diffconfig 里，不能移到 `DEFAULT_PACKAGES`。
* **共享 package 不需要其他任何操作**：所有板卡都相同的东西（整个
  LuCI web 栈、ModemManager/QMI、各种工具）已经通过
  `msm89xx/Makefile` 中的 `DEFAULT_PACKAGES` 发布。如果 `=m` 块在
  板卡之间发生漂移，或者某个 diffconfig 重新选择了默认项，
  `./build.sh guard` 会失败。

编辑完成后，在提交之前先验证它能构建（§7）。

---

## 6. 记录文档 —— `README.md` 的受支持设备表格

在受支持设备表格中添加一行，让用户能找到这块板卡：

```markdown
| **`<board>`** | `generic-<board>` | <Board description> | MSM8916 | 512 MB | 4 GB eMMC | USB NCM, ACM, Wi-Fi AP, LTE, Reboot-to-EDL, Reboot-to-Fastboot, <any unique features> |
```

（保持与现有列布局一致 —— 参见 PR #2 添加的 `mf800b` 行。）

---

## 7. 构建、刷机、验证

### 构建

```sh
./build.sh list                 # confirm <board> is now listed
./build.sh prepare              # first time only: clone + prepare the OpenWrt tree
./build.sh guard                # verify the live tree matches msm89xx/ + packages/ and the diffconfig invariants hold
./build.sh build <board>        # build the firmware image + kmod feed
```

`build.sh` 会从 `diffconfigs/<board>`（通过 `make defconfig`）重写
OpenWrt 的 `.config`，所以 §3 中的 Device profile 和 §5 中的 diffconfig
必须在设备名称上保持一致。

### 刷机

首次（原厂 Android → OpenWrt）：

```sh
# from the build output dir (bin/targets/.../msm8916/)
./flash.sh --mode migrate --yes       # or run with no args for the menu
```

后续更新：

```sh
./flash.sh --mode update --keep-config --yes
```

`flash.sh` 会在写入任何内容*之前*备份射频/校准分区（`fsc fsg modemst1
modemst2 modem persist sec`），所以刷机失败永远不会让 modem NV 变砖。

### 在设备上验证

* `cat /tmp/sysinfo/board_name` → 应打印 `<board>,generic`。
* `ls /sys/class/leds/` → 你命名的 LED 存在。
* 按键行为取决于 DTS 的键码。在 UFI 系列板卡上，Restart 输入是
  `KEY_RESTART`：开机后短按会被忽略，按住至少五秒会执行恢复出厂设置
  并重启。它不会关闭设备电源；带告别闪烁的关机处理程序只适用于另一个
  `KEY_POWER` 输入。
* Modem：`mmcli -L` 显示 modem；`mmcli -m 0` 显示信号/注册状态。
* Wi-Fi：`OpenWrt` AP 正在广播。
* **Failsafe**：在开机后的头七秒内轻点一次 Restart；不要按住七秒。
  你应该能够访问 `192.168.10.1`（通过 USB gadget 的 root shell）。
  开机后再长按会转而调用复位按键处理程序。

---

## 8. 常见陷阱

1. **忘记把 DTB 加进 patch 801。** DTS 存在但从未被编译 → 镜像里没有
   device tree。务必在同一个 PR 里同时修改 qcom 的 `Makefile` patch。
2. **`GPT_TOT_SECTORS` 错误。** 如果你的 eMMC 不是 4 GB，请用
   `cat /sys/block/mmcblk0/size` 的结果设置它。镜像 GPT 是由这个值构建
   的。（`flash.sh` 会读取刷机时的*真实*容量，所以不匹配主要影响生成的
   GPT 镜像，而不是在线设备 —— 但还是要设对。）
3. **LED class 名称与脚本不匹配。** `99-wifi-led` 和
   `rc.button/power` 查找特定名称（`green:wlan`、`green:wan`、
   `*:power`、`*:charging`）。要么把 DTS LED 命名成匹配的名字，要么
   添加一个板卡分支。
4. **`SUPPORTED_DEVICES` 必须与 DTS 的板卡标识匹配。** 不匹配会让
   `sysupgrade` 拒绝应用镜像。保持板卡标识与第一个、板卡专属的
   `compatible` 字符串一致。
5. **合并后 `board_name` 发生变化。** base-files 脚本会对它做 glob
   匹配。选择一个稳定的第一个 `compatible` 字符串，之后不要改名。
6. **复制了 diffconfig 但忘了改 `DEVICE_*` 行。** 你会构建出错误板卡的
   镜像。`CONFIG_TARGET_msm89xx_msm8916_DEVICE_*` 这一行必须写*你的*
   Device。
7. **HiMI 基带板卡需要 himi-ok 允许列表。** 如果你的板卡搭载 HiMI
   基带，把它加进 `lib/himi-ok.sh`，否则 modem-OK 门控不会运行。
8. **新增 `DEVICE_*` 变量却没有 `DEVICE_VARS` 条目。** 该值会泄漏到
   （或来自）下一个设备块，因为它此时是一个普通全局变量。务必在
   `msm8916.mk` 顶部把名字加进 `DEVICE_VARS`。
9. **把电池脚本放进 target 的 base-files。** 它们会发布到每块板卡，
   包括那五块没有电池的板卡，并在 LuCI 菜单里留下一个死页面。把它们
   留在 `packages/luci-app-battery` 中，只在带电池的板卡的
   `DEVICE_PACKAGES` 中添加该 package。
10. **没有 recovery 分区却使用 `reboot-recovery`。** LuCI 入口会检查
    `/sys/class/block/*/uevent` 中的 `PARTNAME=recovery`，分区不存在时
    会隐藏自己，但 CLI 工具仍然存在 —— 在告诉用户使用它之前，先确认
    GPT 确实是以 `GPT_RECOVERY=1` 写入的。

---

## 9. 检查清单（可复制粘贴）

> `tests/board-profile/run.sh` 在每次推送时强制执行本清单中机械的那一
> 半：diffconfig ↔ device profile ↔ DTS ↔ DTB 注册 ↔
> `SUPPORTED_DEVICES`、文件权限、`rc.d` 符号链接、patch 编号，以及"没有
> 板卡门控就不改共享 `base-files` 文件"。门控可以是运行时检查
> （`board_name`、`board_match`、对 `/proc/device-tree/compatible` 的
> grep），也可以是文件头部的 `# BOARDS: <list>` 标记。在本地用
> `bash tests/board-profile/run.sh --self-check` 运行它。
>
> `tests/board-profile/signoff.sh <board>` 会打印板卡 pull request 必须
> 粘贴回去的硬件证据，而 `board-build` 标签会让 CI 构建该板卡
> （`.github/workflows/board-build.yml`）。

- [ ] **DTS patch** `msm89xx/patches/8XX-...-generic-<board>.patch`
  - [ ] `#include "msm8916-ufi.dtsi"`
  - [ ] `model` + `compatible = "<board>,generic", "qcom,msm8916"`
  - [ ] `ramoops` 保留内存区域
  - [ ] LED 节点（删除默认的 `led-r/g/b`，添加命名 LED）+ `gpio_leds_default` 引脚
  - [ ] `button_restart` GPIO + `button_default` 偏置
  - [ ] charger / bms / usb extcon 块（或省略它们的书面理由）
  - [ ] battery 节点（如果存在电池）
- [ ] **DTB 注册**，位于 `msm89xx/patches/801-...-makefile.patch`
- [ ] **Device profile**，位于 `msm89xx/image/msm8916.mk`（`TARGET_DEVICES += generic-<board>`）
  - [ ] `DEVICE_DTS` 与 `.dts` 基本名一致
  - [ ] `SUPPORTED_DEVICES` 与 DTS 的 `compatible` 一致
  - [ ] eMMC ≠ 4 GB 时设置 `GPT_TOT_SECTORS`
  - [ ] 板卡需要 `misc` + `recovery` 时设置 `GPT_RECOVERY := 1`
  - [ ] 任何新的 `DEVICE_*` 变量都已加入 `DEVICE_VARS`
  - [ ] `DEVICE_PACKAGES` = 通用集合 + 任何板卡独有的 package
  - [ ] **只有**板卡有电池时才添加 `luci-app-battery`
- [ ] **base-files 微调**（仅当硬件不同时）
  - [ ] `99-wifi-led` 的板卡跳过/分支
  - [ ] `rc.button/power` 的 LED 回退
  - [ ] `himi-ok.sh` / `modem-led-monitor` 的允许列表（仅 HiMI 板卡）
- [ ] **diffconfig** `diffconfigs/<board>`（从 `uf02` 复制，设备行已修正）
- [ ] **README.md** 受支持设备表格的行
- [ ] `./build.sh build <board>` 成功；在硬件上刷机并验证

---

*参考实现：[PR #2 — MF800B](https://github.com/akbar-npj/msm8916-openwrt/pull/2)。*
