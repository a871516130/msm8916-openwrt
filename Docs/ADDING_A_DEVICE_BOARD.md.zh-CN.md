# 向 msm8916-openwrt 添加新的设备板卡

本指南逐步说明为这个固件树添加一个新的基于 MSM8916 的板卡（4G 加密狗 / MiFi / 上网棒）所需的一切。

它基于一个真实的、完整的示例编写：**PR #2 — MF800B 板卡**（2026-09-22 合并）。下方引用的每个文件都是该 PR 实际改动过的文件。请对照本指南同时阅读 MF800B 相关文件；它们是规范模板。

> 心智模型：构建目标 `msm89xx/msm8916` 已经存在，并为*每个* MSM8916 板卡构建。“添加板卡”意味着添加**一个设备配置文件（Device profile）+ 一个设备树（Device Tree）+ 一个 diffconfig**，外加少量通常可选的、针对 LED / 按键的 base-files 调整。你很少需要动内核、网络配置或构建系统本身。

---

## 0. 前置条件 — 了解你的硬件

在写任何代码之前，先收集关于目标板卡的这些事实：

| 项目 | 原因 | 在哪里查找 |
|------|-----|------------------|
| SoC 是 **MSM8916**（骁龙 210/410） | 整个树以该 SoC 为目标 | 板卡标签 / 原厂固件 |
| 它复用 **`msm8916-ufi.dtsi`** 布局 | 所有现有板卡共享此基座 | 确认它能以 ufi 布局启动 Android/Linux |
| **LED GPIO**（TLMM 引脚，高/低电平有效） | DTS 必须映射它们 | 原厂 DTS，或探测板卡 |
| **复位按键** GPIO + 极性 | failsafe 与复位处理 | 原厂 DTS `gpio-keys` 节点 |
| **eMMC 容量**（以 512 字节扇区计） | 设置 `GPT_TOT_SECTORS` | 在原有系统上 `cat /sys/block/mmcblk0/size`，或读取 GPT |
| 是否存在**电池 / 充电器** | 驱动 `battery` / `pm8916_charger` 节点 | 原厂 DTS |
| **EDL 进入方法**（测试点 / 按键组合） | 刷写与恢复所需 | 查找 `FB` 测试点、音量/组合键 |

如果该板卡*不是* ufi 布局板卡，下面的 DTS 工作会更难（不同的 `.dtsi` 基座，可能不同的外设）。本指南其余部分假定常见的 ufi 上网棒/MiFi 外形。

---

## 1. 设备树源文件（新的内核补丁）

创建一个新补丁：

```
msm89xx/patches/8XX-arm64-dts-qcom-add-msm8916-generic-<board>.patch
```

选择 **8xx 范围内下一个空闲编号**（MF800B 使用了 `807`；`801` 是 qcom Makefile，不要复用它）。该文件是一个 `git diff --no-index` 风格的补丁，在 `arch/arm64/boot/dts/qcom/msm8916-generic-<board>.dts` 下新增一个 `.dts`。

模板（摘自 `807-arm64-dts-qcom-add-msm8916-generic-mf800b.patch`）：

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

* **第一个 `compatible` 字符串**（`"<board>,generic"`）会成为 OpenWrt 运行时看到的 `board_name`（`/tmp/sysinfo/board_name`）。保持其稳定 —— base-files 脚本会对其做 glob 匹配。
* 保留 `ramoops` 区域。它是内核 panic 可恢复的关键。
* 除非你有特定理由不这样做，否则保留 `pm8916_usbin` 禁用 / `pm8916_charger` 启用的拆分。

---

## 2. 在 qcom Makefile 补丁中注册 DTB

内核只编译 qcom `Makefile` 中列出的 DTB。将你的板卡加入维护该列表的现有补丁：

`msm89xx/patches/801-arm64-dts-qcom-add-devices-makefile.patch`

```diff
 dtb-$(CONFIG_ARCH_QCOM)	+= msm8916-samsung-j5.dtb
+dtb-$(CONFIG_ARCH_QCOM)	+= msm8916-generic-<board>.dtb
 dtb-$(CONFIG_ARCH_QCOM)	+= msm8916-samsung-j5x.dtb
```

没有这一行，DTB 永远不会被编译，镜像构建会失败，或者发布的镜像不包含你的设备树。

---

## 3. 设备配置文件 —— `msm89xx/image/msm8916.mk`

添加一个 `define Device/...` 块。它继承共享的 `Device/msm8916` 默认值（cmdline、squashfs、GPT 产物、flash.sh），仅覆盖板卡特有的内容。以 `generic-mf800b` 块为模板：

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

注意事项：

* **`DEVICE_DTS`** 必须等于你在 §1 中创建的 `.dts` 基名。
* **`SUPPORTED_DEVICES`** 必须包含目标 sysupgrade 兼容性检查接受的板卡标识符。在此树中，它通常与板卡专属的第一个 DTS `compatible` 字符串一致（例如 `compatible = "mf800b,generic", ...` 搭配 `SUPPORTED_DEVICES := mf800b,generic`）。保持拼写一致。
* **`DEVICE_PACKAGES`** —— 以上述公共集合为起点。仅在板卡确实需要时添加板卡独有的包（示例：`qcom-time-daemon` 仅 `generic-hmuf02v5` 有，因为它锚定 HMUF02-V5 调制解调器的 ATS 状态，且在其它所有板卡上其 init 是空操作）。如果你的板卡有电池，添加 **`luci-app-battery`** —— 该包携带 LuCI 页面、限充器和电池 LED 监视器。不要把这些脚本放进目标 base-files：那样每个板卡都会得到它们，包括那些没有电池的板卡。
* **`GPT_TOT_SECTORS`** —— 仅当 eMMC 容量不同时才覆盖。默认值（`7569408`）是 4 GB 上网棒的容量。`flash.sh` 现在会在刷写时*读取* GPT 中的真实容量，但镜像本身的 GPT 是根据此值构建的，所以请为你的硬件正确设置它。
* **`GPT_RECOVERY`** —— 设为 `1` 会在 `rootfs_data` 之后追加 `misc`（1 MiB）和 `recovery`（16 MiB）分区，这正是 lk2nd 引导故障切换和 LuCI 的 *重启到恢复模式（Reboot to Recovery）* 入口所需的。`boot`/`rootfs` 的偏移不会移动，所以该标志可以稍后添加，但那样上网棒必须重新分区（执行完整的 `flash.sh`，而不是 `sysupgrade`）。
* **⚠ `DEVICE_VARS`** —— 任何新的按设备变量**必须**在 `msm8916.mk` 顶部声明：
  ```makefile
  DEVICE_VARS += GPT_TOT_SECTORS GPT_RECOVERY
  ```
  没有它，该变量就是普通全局变量，所以每个 `define Device/...` 块会继承*前一个*块留下的值。这正是 `generic-hmuf02v5` 一度悄悄带上 MF800B 布局的原因：文件中最后一个设备胜出。如果某个新板卡神秘地得到了另一个板卡的分区大小，请先检查 `DEVICE_VARS`。

---

## 4. 板卡专属 base-files（通常很小或没有）

OpenWrt 的运行时脚本位于 `msm89xx/base-files/`。大多数已经对**所有板卡通用**，无需修改：

* `etc/board.d/02_network` —— 将 `usb0` 设为 LAN、Wi-Fi 国家代码和 AP SSID。**无需修改**，除非你的板卡网络配置不同。
* `etc/uci-defaults/99-msm89xx-firstboot` —— ModemManager WAN、移除不存在的目标 feed 等。**无需修改。**

仅当你的板卡硬件不同时才编辑这些：

### 4a. Wi-Fi LED —— `etc/hotplug.d/ieee80211/99-wifi-led`

该脚本在 `phy0` 出现时点亮 WLAN LED。它通过类名回退选择 LED（`green:wlan` → `green:wan`），并跳过没有合适 LED 的板卡。PR #2 为 MF800B 添加了显式跳过（它没有自动 LED 指示）：

```sh
case "$(cat /tmp/sysinfo/board_name 2>/dev/null)" in
	*<board>*) exit 0 ;;   # your board has no WLAN LED, or you handle it elsewhere
esac
```

如果你的板卡*确实*有 `green:wlan` / `green:wan` LED，则**此处无需修改** —— 它会自动被选中。如果你使用不同的 LED 类名，要么重命名 DTS 节点以匹配，要么添加板卡分支。

### 4b. 电源按键 —— `etc/rc.button/power`

该处理程序在长按时关闭设备，并先闪烁“再见”LED。它通过一个 LED 名称*列表*回退：

```sh
LED="/sys/class/leds/red:power"
[ -d "$LED" ] || LED="/sys/class/leds/green:power"
[ -d "$LED" ] || LED="/sys/class/leds/green:charging"
[ -d "$LED" ] || LED="/sys/class/leds/red:charging"
[ -d "$LED" ] || LED="/sys/class/leds/green:wan"
[ -d "$LED" ] || LED="/sys/class/leds/blue:wan"
```

如果这些 LED 在你的板卡上都不存在，处理程序仍然会关机 —— 只是跳过闪烁。**并非严格需要修改**，但如果你的板卡将电源/充电 LED 命名为其它名称，请把它加入此回退链，以便用户获得视觉确认。

两个值得了解的注意事项：

* **当 VBUS 存在时长按会重启而不是关机。** 在带电池的板卡上，关机看起来像上网棒已死而它仍插着电，所以处理程序会先检查每个 `/sys/class/power_supply/*/online`，当其中一个读出 `1` 时执行干净的 `sync; reboot`。
* **处理程序只有在 PMIC 电源键到达用户空间时才运行。** `sbin/pwrkey-monitor`（由 `init.d/pwrkey-monitor` 启动）查找 `pm8941_pwrkey` 输入设备，解码键码 `0x74`（`KEY_POWER`），并将按住时长写入 `/etc/rc.button/power`。它最多等待 60 秒等待输入节点，所以它**不能**在慢启动时提前退出 —— procd 会循环重新拉起它。没有电源键的板卡永远不会触发它。

### 4c. 已按 `board_name` 键控的服务

两个服务对 `board_name` 做 glob 匹配，可能需要把你的板卡加入允许列表：

* `lib/himi-ok.sh` —— **HiMI 基带**的“modem-OK”守卫。只有带 HiMI 基带的板卡（HMU05、UF02、UZ801 等）需要它。如果你的板卡是 HiMI 基带设备，把它加入允许列表；否则不用管。
* `usr/sbin/modem-led-monitor` —— 蜂窝/充电 LED 监视器。它已经按板卡分支；只有当你希望 WWAN LED 行为与默认不同时才添加分支。

---

## 5. 板卡 diffconfig —— `diffconfigs/<board>`

该文件是板卡保存的 OpenWrt 配置。**`build.sh` 从此目录枚举板卡**（`build.sh list` 列出这里的每个文件），CI / 发布流程为每个 diffconfig 构建一个镜像 + kmod feed。

复制一个现有的作为起点：

```sh
cp diffconfigs/uf02 diffconfigs/<board>
```

（`uf02` 是最小模板；`mf800b` 还带有三行你必须删除的 `amneziawg`。）

然后编辑它：

* 设置设备选择（这是最重要的一行）：
  ```sh
  CONFIG_TARGET_msm89xx=y
  CONFIG_TARGET_msm89xx_msm8916=y
  CONFIG_TARGET_msm89xx_msm8916_DEVICE_generic-<board>=y
  ```
* **Failsafe**：7 秒 preinit 窗口和 `192.168.10.1` preinit IP 已经是默认值。保留 `CONFIG_IMAGEOPT=y` / `CONFIG_PREINITOPT=y` / `CONFIG_TARGET_PREINIT_*` 块（从 uf02 复制）以便它们保持显式，且不会被 `make defconfig` 重置。
* 添加任何**板卡专属的包选择**（例如你的板卡是 HMU05 级时添加 `qcom-time-daemon`）。
* 大的 `=m` 块是**可选的 kmod feed** —— 构建进包 feed 但*不*烘入镜像的模块，以便用户可按需 `apk add`。原样复制；只有当你确定某个模块不需要时才裁剪。这些刻意保持 `=m` —— 外部模块，从不内建 —— 所以它们留在 diffconfig 中，不能移入 `DEFAULT_PACKAGES`。
* **共享包无需其它内容**：所有板卡完全相同的内容（整个 LuCI Web 栈、ModemManager/QMI、工具）已经通过 `msm89xx/Makefile` 中的 `DEFAULT_PACKAGES` 发布。`./build.sh guard` 在 `=m` 块在板卡间漂移或 diffconfig 重新选择默认包时失败。

编辑后，在提交前验证它能构建（§7）。

---

## 6. 记录 —— `README.md` 受支持设备表

在受支持设备表中添加一行，让用户能找到该板卡：

```markdown
| **`<board>`** | `generic-<board>` | <Board description> | MSM8916 | 512 MB | 4 GB eMMC | USB NCM, ACM, Wi-Fi AP, LTE, Reboot-to-EDL, Reboot-to-Fastboot, <any unique features> |
```

（匹配现有列布局 —— 参见 PR #2 添加的 `mf800b` 行。）

---

## 7. 构建、刷写、验证

### 构建

```sh
./build.sh list                 # confirm <board> is now listed
./build.sh prepare              # first time only: clone + prepare the OpenWrt tree
./build.sh guard                # verify the live tree matches msm89xx/ + packages/ and the diffconfig invariants hold
./build.sh build <board>        # build the firmware image + kmod feed
```

`build.sh` 会从 `diffconfigs/<board>` 重写 OpenWrt 的 `.config`（通过 `make defconfig`），所以 §3 的设备配置与 §5 的 diffconfig 必须在设备名称上一致。

### 刷写

首次（原厂 Android → OpenWrt）：

```sh
# from the build output dir (bin/targets/.../msm8916/)
./flash.sh --mode migrate --yes       # or run with no args for the menu
```

后续更新：

```sh
./flash.sh --mode update --keep-config --yes
```

`flash.sh` 在写入任何内容*之前*备份无线/校准分区（`fsc fsg modemst1 modemst2 modem persist sec`），所以失败的刷写绝不会把调制解调器 NV 变砖。

### 在设备上验证

* `cat /tmp/sysinfo/board_name` → 应打印 `<board>,generic`。
* `ls /sys/class/leds/` → 你命名的 LED 存在。
* 按键行为取决于 DTS 键码。在 UFI 家族板卡上，Restart 输入是 `KEY_RESTART`：启动后，短按被忽略，按住至少五秒执行出厂重置加重启。它不会关闭设备；再见闪烁的关机处理程序仅适用于单独的 `KEY_POWER` 输入。
* 调制解调器：`mmcli -L` 显示调制解调器；`mmcli -m 0` 显示信号/注册状态。
* Wi-Fi：`OpenWrt` AP 正在广播。
* **Failsafe**：启动最初七秒内轻按一次 Restart；不要按住七秒。你应该能访问 `192.168.10.1`（通过 USB gadget 的 root shell）。启动后的长按会调用复位按键处理程序。

---

## 8. 常见陷阱

1. **忘了把 DTB 加入补丁 801。** DTS 存在但从不编译 → 镜像中没有设备树。始终在同一 PR 中编辑 qcom `Makefile` 补丁。
2. **`GPT_TOT_SECTORS` 错误。** 如果你的 eMMC 不是 4 GB，从 `cat /sys/block/mmcblk0/size` 设置。镜像 GPT 由该值构建。（`flash.sh` 在刷写时读取*真实*容量，所以不匹配主要影响生成的 GPT 镜像，而非实际设备 —— 但要设对。）
3. **LED 类名与脚本不匹配。** `99-wifi-led` 和 `rc.button/power` 查找特定名称（`green:wlan`、`green:wan`、`*:power`、`*:charging`）。要么命名你的 DTS LED 以匹配，要么添加板卡分支。
4. **`SUPPORTED_DEVICES` 必须与 DTS 板卡身份一致。** 不匹配可能使 `sysupgrade` 拒绝应用镜像。保持板卡标识符与第一个、板卡专属的 `compatible` 字符串一致。
5. **合并后 `board_name` 改变。** Base-files 脚本会对其做 glob 匹配。选择一个稳定的第一个 `compatible` 字符串，之后不要重命名它。
6. **复制了 diffconfig 但忘了改 `DEVICE_*` 行。** 你会构建错误板卡的镜像。`CONFIG_TARGET_msm89xx_msm8916_DEVICE_*` 行必须命名*你的*设备。
7. **HiMI 基带板卡需要 himi-ok 允许列表。** 如果你的板卡携带 HiMI 基带，把它加入 `lib/himi-ok.sh`，否则 modem-OK 门不会运行。
8. **新的 `DEVICE_*` 变量没有 `DEVICE_VARS` 条目。** 该值会泄漏到（或来自）下一个设备块，因为它就成了普通全局变量。始终把名称加到 `msm8916.mk` 顶部的 `DEVICE_VARS`。
9. **把电池脚本放进目标 base-files。** 它们会发布到每个板卡，包括五个没有电池的板卡，并在 LuCI 菜单里放一个死页面。把它们保留在 `packages/luci-app-battery` 中，并且只在带电池的板卡上把该包加入 `DEVICE_PACKAGES`。
10. **没有 recovery 分区却使用 `reboot-recovery`。** LuCI 条目检查 `/sys/class/block/*/uevent` 是否有 `PARTNAME=recovery`，分区不存在时会隐藏自身，但 CLI 工具仍然存在 —— 在告诉用户使用它之前，确保 GPT 实际上以 `GPT_RECOVERY=1` 写入。

---

## 9. 清单（复制/粘贴）

> `tests/board-profile/run.sh` 在每次推送时强制执行本清单的机制部分：diffconfig ↔ 设备配置 ↔ DTS ↔ DTB 注册 ↔ `SUPPORTED_DEVICES`、文件权限、`rc.d` 符号链接、补丁编号，以及“除非有板卡门，否则不得修改共享 `base-files` 文件”。门要么是运行时检查（`board_name`、`board_match`、`/proc/device-tree/compatible` grep），要么是文件头部的 `# BOARDS: <list>` 标记。本地运行 `bash tests/board-profile/run.sh --self-check`。
>
> `tests/board-profile/signoff.sh <board>` 打印板卡 PR 必须贴回的硬件证据，`board-build` 标签让 CI 构建该板卡（`.github/workflows/board-build.yml`）。

- [ ] **DTS 补丁** `msm89xx/patches/8XX-...-generic-<board>.patch`
  - [ ] `#include "msm8916-ufi.dtsi"`
  - [ ] `model` + `compatible = "<board>,generic", "qcom,msm8916"`
  - [ ] `ramoops` 保留内存区域
  - [ ] LED 节点（删除默认 `led-r/g/b`，添加命名 LED）+ `gpio_leds_default` 引脚
  - [ ] `button_restart` GPIO + `button_default` 偏置
  - [ ] 充电器 / bms / usb extcon 块（或记录省略的原因）
  - [ ] 电池节点（如果存在电芯）
- [ ] 在 `msm89xx/patches/801-...-makefile.patch` 中**注册 DTB**
- [ ] 在 `msm89xx/image/msm8916.mk` 中的**设备配置**（`TARGET_DEVICES += generic-<board>`）
  - [ ] `DEVICE_DTS` 与 `.dts` 基名匹配
  - [ ] `SUPPORTED_DEVICES` 与 DTS `compatible` 匹配
  - [ ] eMMC ≠ 4 GB 时设置 `GPT_TOT_SECTORS`
  - [ ] 板卡应获得 `misc` + `recovery` 时设 `GPT_RECOVERY := 1`
  - [ ] 任何新的 `DEVICE_*` 变量加入 `DEVICE_VARS`
  - [ ] `DEVICE_PACKAGES` = 公共集合 + 任何板卡独有包
  - [ ] 仅当板卡有电池时才添加 `luci-app-battery`
- [ ] **base-files 调整**（仅当硬件不同）
  - [ ] `99-wifi-led` 板卡跳过/分支
  - [ ] `rc.button/power` LED 回退
  - [ ] `himi-ok.sh` / `modem-led-monitor` 允许列表（仅 HiMI 板卡）
- [ ] **diffconfig** `diffconfigs/<board>`（从 `uf02` 复制，设备行已修正）
- [ ] **README.md** 受支持设备表行
- [ ] `./build.sh build <board>` 成功；在硬件上刷写 + 验证

---

*参考实现：[PR #2 — MF800B](https://github.com/akbar-npj/msm8916-openwrt/pull/2)。*
