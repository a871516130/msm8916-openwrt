> 📄 本文件是 [RELEASE_NOTES.md](RELEASE_NOTES.md) 的英文原文中文译本，内容以英文版为准。

> 📖 **完整构建与刷机指南 →** <https://github.com/akbar-npj/msm8916-openwrt/wiki/Build-and-Flashing-Reference>

## v25.12.6-r8 — 特性亮点

- 🆕 **新板型：`jz02`** —— 一块带电池的 MiFi，拥有三条 SIM 切换线、一块 2100 mAh / 4.35 V 电池
  和 USB-gadget LAN。外部卡槽（3）是在硬件上实测过的；卡槽 1 和 2 在该机上是内置或未贴片的。
  它的原厂 Android DTB 对 LED 的命名有误导性，因此镜像使用在板上实测的映射，而不是那些标签。
  **该板型没有 failsafe 模式**：reset 按键孔在软件上不可见 —— 没有 GPIO 电平变化、没有 PMIC GPIO
  变化、没有 `pm8941_pwrkey` 事件、也不会重启 —— 所以它是一个纯硬件复位。无法启动的配置只能通过
  EDL 恢复。其他一切正常，包括电量上报和 SIM 选择器（`uci set sim.slot=3`）。

- 📶 **掉线的 Wi-Fi station 再也没回来。** 一台现场设备断网约 39 分钟，而它的上游在正确信道上
  出现在扫描结果中：66 分钟内有 14 次 4-way 握手失败和 22 次 `SSID-TEMP-DISABLED`，期间 watchdog
  一直得出“没有信道不匹配；交给 wpa_supplicant 处理”的结论，直到两次 `-EBUSY` 扫描恰好触发了驱动
  重载。生成的 supplicant 配置里完全没有 `key_mgmt`，于是 wpa_supplicant 套用了自己的默认值，
  另外两个缺陷又让死掉的接口无法重新启用。三个问题都已修复，AKM 现在从扫描结果中选择：
  支持 WPA3 的 AP 会得到带 PMF 的 SAE，仅支持 WPA2 的 AP 仍然能连接。

- 🔄 **一次 manifest 获取失败让更新检查静默了六个小时。** 开机后的最初几分钟恰恰是 station 已经
  关联、但 manifest 还读不出来的时刻，而那次运行被计为成功，于是 daemon 等满了 6 小时间隔。
  现在失败的检查会在 15 分钟后重试。

- 🩹 **从 Firmware Upgrade 页面安装热修看起来像一个死按钮。** 没有忙碌状态、没有进度，结果 toast
  被插入页面顶部 —— 按下底部按钮时它在屏幕之外 —— 随后是 "No fixes pending for this build."。
  成功安装与什么都没发生无法区分。现在页面会显示正在安装的软件包的进度条，以及一个保持可见的结果。

- 🐛 **热修可能毫无理由地先失败一次。** 发布时把索引和 `.apk` 写在同一个 commit 中，因此在一分钟内
  读取 feed 的设备会看到一个并非冲突的版本不匹配 —— 那是 `apk` 在说它能看到的唯一候选就是已经安装的
  版本。安装现在会对这种特定失败重试一次。

- 🧰 **Software 页面会提供一个永远装不上的 `base-files` 更新。** `base-files` 在 `/etc/apk/world`
  中被固定了版本，因此 `apk upgrade` 会遵守该固定、打印 `OK: … in 307 packages` 且什么都不改 ——
  而 LuCI 却报告成功。这个提议来自 promote 把发行版的 `base-files` 复制进每个 revision 都会读取的
  共享 feed。Promote 不再发布它；base-files 热修仍然通过按 revision 划分的 feed 提供。

- 🧪 **板型支持现在有了测试工具。** `tests/board-profile/run.sh` 在每个 PR 上检查每个板型 ——
  diffconfig ↔ 设备 profile ↔ DTS ↔ DTB 注册 ↔ `SUPPORTED_DEVICES`、文件模式、`rc.d` 符号链接、
  patch 编号，以及对共享 `base-files` 文件的改动是否被限制在其所属板型上。`board-build` 标签会在 CI 中
  构建贡献者的板型，而 `signoff.sh` 会打印板型 PR 必须贴回的硬件证据。
  另外修复了：`device=all` 只构建八个板型中的七个 —— `uf896` 不在硬编码矩阵中，而该矩阵现在从
  `diffconfigs/` 派生。

## v25.12.6-r7 — 特性亮点

- 🩹 **r6 已撤回 —— 它无法启动。** r6 试图让 PM8916 RTC 可写，以便 `hwclock -w` 不再失败。
  该调用由 `sysfixtime` 在 `START=00`（也就是第一个 init 脚本）时运行，而 RTC 复位后停在 1970 年，
  所以每次开机都会触发。没有该属性时，它在到达 PMIC 之前就返回
  `RTC_SET_TIME: No such device` —— 无害。有了该属性，它就成了这些板型上第一段通过 SPMI 写 RTC
  寄存器的代码，开机就卡死在那里：系统永远到不了 userspace，lk2nd 的 3 次计数耗尽，设备落入
  recovery 分区。`firstboot` 也救不了，因为失败发生在它之前。该补丁已被移除，DTB 与 r5 字节级一致。
  **如果你在 r6 上，请刷 r7。**

- 📊 **固件升级现在会显示它在做什么。** 升级期间页面完全没有任何指示：控制台只有在 apply 日志有
  内容后才出现，而下载 —— 最长的阶段，经 Wi-Fi 传输约 8 MB —— 什么也不显示，于是一次正常的升级
  看起来像一个死按钮。现在有一条由镜像在磁盘上的真实字节数驱动的进度条（0–80 %），随后是
  verify（85 %）和 flash（92 %）；`sysupgrade` 不会报告更细的粒度，所以进度条也不会假装如此，
  失败时会变红。控制台在你按下 Upgrade 的那一刻出现，随日志滚动，并能在页面刷新后保留。

- 🧪 **每个版本都先以测试构建的形式发布。** tag 构建只发布 prerelease 和 `releases/<version>/`；
  它不再触碰共享的 `releases/<base>/` feed 或根 `firmware.json`，因此一个后来被证明有问题的镜像
  不会被送到已经在运行的设备上。Promote 是一次显式的 `promote-release.yml` 运行，它复制 feed、
  清理被取代的 kernel 与 kmod 软件包、重新发布根 manifest，并把该 release 翻转为 Latest。

- 🐛 **CI 不再悄悄丢掉 LuCI 子模块。** `packages/luci-app-cpu-perf` 是一个 git 子模块，而
  `actions/checkout` 默认不拉取子模块，于是 CI 生成了一个不含它的镜像，OpenWrt 又悄悄把它从
  `DEFAULT_PACKAGES` 中丢掉。现在两处 checkout 都传入 `submodules: recursive`。
