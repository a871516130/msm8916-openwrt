> 📄 本文件是 [README.md](README.md) 的英文原文中文译本，内容以英文版为准。

# 高通 Snapdragon 410 (MSM8916) 4G LTE USB 网卡与调制解调器的 OpenWrt

[![OpenWrt Version](https://img.shields.io/badge/OpenWrt-25.12.6-blue.svg)](https://openwrt.org/)
[![Kernel](https://img.shields.io/badge/Linux_Kernel-6.12-green.svg)](https://kernel.org/)
[![Architecture](https://img.shields.io/badge/Arch-aarch64-orange.svg)](https://en.wikipedia.org/wiki/AArch64)
[![License](https://img.shields.io/badge/License-GPL--2.0-lightgrey.svg)](LICENSE)

一个可用于生产环境、完全开源的 OpenWrt 移植版本，面向基于高通 Snapdragon 410（MSM8916 / MSM8939）的 4G LTE USB 调制解调器、上网棒和便携路由器。

特性包括现代化的 **Linux 6.12 mainline kernel**、**ModemManager 1.24**、**Qualcomm WCN36xx Wi-Fi（支持 WPA3-SAE）**、**Bluetooth（BlueZ 5.83 + SPP）**、**USB ConfigFS CDC NCM/ACM**、**mainline CPR CPU 电压轨调节**、**真正持久的 eMMC EXT4 overlay 存储**，以及可用的**reboot-to-EDL 与 reboot-to-Fastboot 恢复路径**。

> 📚 **文档：** [Wiki](https://github.com/akbar-npj/msm8916-openwrt/wiki) · [构建与刷机参考](https://github.com/akbar-npj/msm8916-openwrt/wiki/Build-and-Flashing-Reference) · [架构](Docs/ARCHITECTURE.md) · [上游化策略](Docs/OPENWRT_UPSTREAMING_STRATEGY.md) · [BBR](Docs/BBR_TCP_CONGESTION_CONTROL.md) · [原厂 Android 调试工具包](Docs/STOCK_ANDROID_SSH_AND_DEBUG_TOOLKIT_GUIDE.md) · [CI/CD 流水线](Docs/Github%20Actions/README.md) · [LED 设置](Docs/LED_SETUP.md) · [r8 的 LED 热修](Docs/LED_HOTFIX.md) · [发布固件](Docs/RELEASING_FIRMWARE.md) · [发布与热修](https://github.com/akbar-npj/msm8916-openwrt/wiki/How-Releases-and-Hotfixes-Work) · [发行说明](RELEASE_NOTES.md)

---

## 🆕 版本亮点

在基础移植之上的近期新增内容：

* **⬆️ 设备内固件升级（r3+）** —— 设备会检查已发布的 `firmware.json`，下载**其所属板型**的镜像，校验 SHA-256 并刷写它 —— 通过 LuCI 中的 **System → Firmware Upgrade** 或控制台上的`firmware-upgrade` 完成。无需 `scp`、无需手动下载；默认保留设置（取消勾选 **Keep settings**即等效于 `sysupgrade -n`），并且 `min_version` 下限会拒绝设备无法应用的跨版本升级。**这是首个包含该功能的版本：r1/r2 没有客户端，因此请手动刷写一次 r3 —— 从 r3 起，每个版本都能自我更新。**
* **📦 无需重刷即可更新的自定义软件包** —— LED 监控、station 模式辅助程序、watchdog 和升级页面都位于 `packages/` 而非 `base-files`，因此修复会以**已签名的软件包热修**（`apk update && apk upgrade <name>`）形式送达设备，而不是 35 MB 的镜像刷写。CI 会针对已发布的 toolchain 和 kernel 重建该软件包、将其接入在线 feed 并重新签名索引；`luci-app-update-notify` 会在仪表盘上显示 "N package updates are available"。
* **📲 实体 SIM 热插拔** —— 拔出卡片再插入另一张：`sim-hotplug` 会检测到这次换卡，重新向 baseband 声明该卡，通过 ModemManager 重新读取，并在**约 15 秒**内恢复数据，**无需重启**（即使换了运营商）。
* **🆘 recovery 分区中的救援镜像** —— 在 `hmuf02v5`、`mf800b` 和 `mifib-v12` 上，`recovery` 分区存放着一套自包含的救援系统，它启动**生产 kernel**，并同时拉起 USB **和**一个 Wi-Fi AP（`OpenWrt-Recovery`，802.11n + WMM），提供用于重刷 rootfs、写入单个分区或重启到 EDL 的 Web 界面。其 DHCP 租约只分配地址、不含网关和 DNS，因此接入它绝不会劫持客户端的上网流量。参见 [`Docs/RECOVERY/`](Docs/RECOVERY/)。
* **🛟 Failsafe 模式** —— 在开机最初的 7 秒内轻按一次 **Restart 按钮**，即可让无屏幕的上网棒进入 USB 上的救援 shell（`192.168.10.1` 或 `/dev/ttyACM0`）；**按住 5 秒**则执行恢复出厂设置。failsafe 的 DHCP 租约不带网关也不带 DNS，因此把上网棒插上不会替换主机的默认路由。
* **🔵 Bluetooth** —— WCNSS BT core（SMD）配合 BlueZ 5.83、一个 SSP 配对修复保护，以及 Bluetooth **Serial Port Profile** 服务器/客户端（经 Bluetooth 的串口控制台或TCP 桥接）。
* **🔐 WPA3-SAE Wi-Fi** —— wcn36xx 驱动中的 PMF/SAE 支持，外加 **multi-SSID**（同一射频上的两个 AP）和 **并发 AP+STA**（射频在服务自身 AP 的同时作为客户端加入另一个网络）。
* **📶 表现可靠的 Station 模式** —— 可保存多个上游网络并自动故障切换、一条会标出 SSID 的红色 **Wrong password** 告警、一个能阻止 `channel='auto'` 卡死射频的信道锁定、一个让 station 在场时 *Save & Apply* 重启射频也安全的保护，以及专用的**Network → Station Mode** LuCI 应用。参见[该指南](Docs/WiFi/AP_STA_AND_LUCI_APP.md)。
* **🌡️ 散热与功耗** —— CPU 电压轨现在由 **mainline CPR** 管理（与 Android 的电压轨一致），最高 CPU OPP 被限制在 800 MHz，DDR 时钟运行在 **400 MHz**（与 Android 完全一致，patch 860 + `opp-peak-kBps` 3200000），Wi-Fi + PMIC 散热映射位于共享的`msm8916-ufi.dtsi`，因此每个板型都能获得。
* **🛡️ Modem 稳定性** —— A2 电源轨在驱动中被保持开启（`a2_pin=1`），modem 的 NV `HiMI_OK` 标记在每次开机后都会被重写，bearer watchdog 执行预防性 SSR 恢复，失败的 `--simple-connect` 不再把接口卡死（proto 会上报 `MM_CONNECT_FAILED`，使 netifd 带着 `autostart` 重试）。
* **🔑 带自愈能力的已签名软件包 feed** —— OTA `apk` feed 使用固定密钥签名，每台设备在开机时、任一接口 up 时、apk 提交之前以及 `apk()` shell 包装器中，都会从一个稳定 URL重新同步该密钥 —— 尽力而为，因此绝不会阻塞或导致软件包命令失败。
* **🔐 默认启用 HTTPS** —— 每个板型都附带 `px5g-mbedtls`，并在首次开机时生成设备自签名证书，因此 LuCI 除 HTTP 外也能通过 `https://192.168.8.1` 访问。**Reboot to EDL** 和 **Reboot to Recovery** 现已位于 System 菜单中。参见 [`Docs/HTTPS.md`](Docs/HTTPS.md)。
* **🎨 Feelgood 主题** —— 内置的 **Feelgood** 主题是默认 UI，带有固定的水平导航抽屉（不再有页面滚动卡死），登录页的图标也不再遮挡表单。
* **📡 运营商自动开通** —— 自动的 SIM/运营商 MBN 部署，并由 QMI time daemon在 LTE attach 之前锚定 modem 时钟。
* **🔋 电池、电源键与 LED** —— `mifib-v12`、`mf800b`、`jz02` 和 `mf32lt` 会上报真实电量、电池温度和充电状态，带有 85 % 充电上限和一个 `luci-app-battery` 页面；在`mifib-v12`/`mf800b`/`jz02` 上，`pwrkey-monitor` 还提供双击重启和长按关机，而 `mf32lt` 则通过其 GPIO 电源键（`rc.button/power`）获得这两种手势。
* **🚦 BBR TCP 拥塞控制成为默认** —— 镜像不再使用 CUBIC。BBR 基于模型（它测量 bearer 的带宽和 RTT）而非基于丢包，因此不会把 LTE 无线丢包误判为拥塞，也不会填满基站的缓冲区。结果是：**满速下载时延迟仍接近空闲水平**，而不是爬升到数百毫秒。参见 [BBR](Docs/BBR_TCP_CONGESTION_CONTROL.md)。

---

## 🚀 核心特性

* **⚡ 即插即用 USB 网络**：高速 **CDC NCM Ethernet** 自动绑定到 `br-lan`（`192.168.8.1/24`），内置 DHCP 服务器（避免与上游家用路由器的 `192.168.1.x`子网冲突）。
* **📟 内置 USB 串口控制台**：通过 CDC ACM 在 USB 上提供 `/dev/ttyACM0`（115200 波特率）即时 root shell，零配置即可访问终端、调试和恢复。
* **📶 首次开机 Wi-Fi 自动启动**：在全新首次开机时自动提取 Qualcomm WCNSS blob、就地启动 remoteproc、绑定物理射频通路，并广播一个开放的 `OpenWrt` 2.4 GHz AP（信道 1，2.412 GHz）。
* **🔐 WPA3-SAE 与 Multi-SSID**：wcn36xx 驱动宣告 WPA3-SAE（PMF/IGTK），且射频可同时承载**两个 AP 接口**。参见 [Wi-Fi](#-wi-fi)。
* **🔵 Bluetooth + Serial Port Profile**：经 SMD 的 WCNSS Bluetooth 配合 BlueZ 5.83、一个 SSP 配对修复保护，以及用于 Bluetooth 串口控制台或 TCP 桥接的 SPP 服务器/客户端。UZ801 v3 上无法使用 Bluetooth，因为该板型没有 Bluetooth 天线。参见 [蓝牙](#-蓝牙)。
* **🌡️ 散热与电源管理**：mainline **CPR** CPU 电压轨调节（与 Android 一致的电压）、800 MHz CPU OPP 上限，以及 HMUF02-V5 上的 Wi-Fi/PMIC 散热控制。参见 [散热与功耗管理](#-散热与功耗管理)。
* **🛡️ Modem 稳定性保护**：A2 电源轨被固定开启（`a2_pin=1`），modem 的 `HiMI_OK` NV 标记在每次 modem 启动后都会被重写，`modem-bearer-watchdog` 执行预防性 SSR 恢复。参见 [Modem 稳定性](#-modem-稳定性)。
* **🌐 4G LTE 蜂窝数据与运营商自动开通**：原生 **ModemManager** 集成，自动 SIM运营商检测（`qcom-carrier-autocfg`）、动态 APN 与 Qualcomm Carrier MBN 部署、安全的空 PLMN 归属运营商附着，以及持续的自愈守护进程监控（`modem-led-monitor`）。
* **🚦 BBR TCP 拥塞控制**：`tcp_bbr` 预装、自动加载，并在开机时通过`/etc/sysctl.d/10-bbr.conf` 选用。在 LTE bearer 上，这能在负载下保持 RTT 平稳（无 bufferbloat）、在无线丢包时不至于窗口崩溃，并让发送节奏适配 modem 基于授权的上行链路。参见 [BBR 拥塞控制](Docs/BBR_TCP_CONGESTION_CONTROL.md)。
* **💾 永久 eMMC 存储**：自动对 `/dev/mmcblk0p15`（`rootfs_data`）进行 EXT4格式化与挂载，带 preinit 文件系统检查和使用 `e2fsck -p` 的自动安全修复，在不无谓格式化现有文件系统的前提下提供持久 overlay 存储。
* **💡 直观的硬件状态 LED**：

  * 🟢 **绿色 LED**（`green:wlan`）：Wi-Fi AP 状态与无线客户端发送。常亮 = AP 就绪，250 ms 闪烁 = 有客户端加入，**100 ms 闪烁 = AP + station（中继）同时工作**。
  * 🔵 **蓝色 LED**（`blue:wan`）：4G LTE 注册、数据 bearer 与上网活动。
  * 🔴 **红色 LED**（`red:power`）：Modem 处理器与子系统健康指示。它还会在**每次开机的前 7 秒快闪** —— 也就是 failsafe 窗口，即“现在轻按一下即进入救援模式”。
  * ⚫ **无 SIM** = 两个 modem LED（红和蓝）都**熄灭**：modem 无法注册，因此无事可报。
  * 开机闪烁**仅限无电池板型** —— 带电池的板型在开机时闪烁自己的电池灯。无 SIM 和 AP+STA 适用于所有板型。
  * 🔋 **带电池的板型**（`mifib-v12`、`mf800b`、`jz02`）改为三对：`wan`、`wlan`和 `bat`/`charging`。第三对**只上报充电与故障** —— 绿色慢闪 = 充电中，绿色常亮 = 充满，红色快闪 = 电量计故障，熄灭 = 正常放电。电量显示在 LuCI 中，不在灯上。**`mf32lt`** 是例外：它保留共享的红/绿/蓝三色灯，外加一个 4 格蓝色电池条（`bat_1`–`bat_4`），没有监控程序驱动它 —— 没有开机闪烁，电量同样显示在 LuCI 中。
* **⬆️ 自我更新固件（r3+）**：设备读取已发布的 `firmware.json`、下载其板型的镜像、校验 SHA-256 并交给 `sysupgrade` —— 通过 **System → Firmware Upgrade** 或`firmware-upgrade check|download|apply|upgrade` 完成。除非你要求全新安装（`--no-keep`），否则配置会被保留。参见 [从设备端升级](#-从设备端升级r3-及之后)。
* **🔄 万无一失的 Sysupgrade**：优雅的升级前服务拆除（`platform_pre_upgrade`）消除了 LuCI Web 与 CLI 固件升级期间的 kernel 链表 panic，并有逐步诊断日志输出到 stdout 和 `/dev/kmsg`。
* **🆘 Failsafe 模式与恢复出厂设置**：在开机最初 7 秒内轻按一次 Restart 按钮，即可通过自包含 USB gadget（NCM + ACM）在 `192.168.10.1`（或 `/dev/ttyACM0`）启动 OpenWrt 的 pre-init 救援 shell，从而无需拆机即可在无屏幕的上网棒上恢复损坏的配置；**按住 5 秒**则清除 overlay。参见 [恢复与重启模式](#-恢复与重启模式)。
* **🔑 已签名的 OTA 软件包 feed**：预编译的 `kmod-*` 与应用软件包通过 GitHub Pages提供，使用固定密钥签名并具备设备端自愈能力。本项目自身的工具也发布在这里，因此修复只需 `apk upgrade` 而非重刷。参见[官方软件包与内核驱动仓库](#-官方软件包与内核驱动仓库)。
* **🚑 重启到 Qualcomm EDL**：`reboot-edl` 可干净地触发 Qualcomm Emergency Download（EDL / USB `05c6:9008`）模式，无需硬件测试点操作。
* **⚙️ 重启到 Bootloader/Fastboot**：`reboot-bootloader` 将设备切换到 Qualcomm Fastboot 模式，以便进行 bootloader 级别的恢复与刷写。
* **🔧 无需物理接触的恢复**：EDL 与 Fastboot 重启目标提供从运行中的 OpenWrt 系统直接触发的软件恢复路径。

---

## 📟 支持的设备

| 板型 Target  | Profile 名称      | 设备型号               | SoC     | RAM    | 存储   | LED 映射             |
| :------------ | :---------------- | :------------------------- | :------ | :----- | :-------- | :---------------------- |
| **`hmuf02v5`**   | `generic-hmuf02v5`   | HMUF02-V5（原 HMU05）（250605 V0S） | MSM8916 | 512 MB | 4 GB eMMC | 绿 / 蓝 / 红      |
| **`ufi001b`** | `generic-ufi001b` | 通用 UFI001B 4G 上网棒   | MSM8916 | 512 MB | 4 GB eMMC | 绿 / 蓝 / 红      |
| **`ufi003`**  | `generic-ufi003-mb-v02` | UFI003 MB V02 | MSM8916 | 512 MB | 4 GB eMMC | 绿 / 蓝 / 红      |
| **`uz801`**   | `yiming-uz801v3`  | YiMing UZ801 v3 上网棒     | MSM8916 | 512 MB | 4 GB eMMC | 绿 / 蓝 / 红      |
| **`uf02`**    | `generic-uf02`    | 通用 UF02 / UF2 上网棒   | MSM8916 | 512 MB | 4 GB eMMC | 绿 / 蓝 / 红      |
| **`mf800b`**  | `generic-mf800b`  | 通用 MF800B 4G MiFi     | MSM8916 | 512 MB | 4 GB eMMC | 双色 WLAN/WAN      |
| **`mifib-v12`** | `generic-mifib-v12` | HM-MIFIB-V12 4G LTE 上网棒 | MSM8916 | 512 MB | 4 GB eMMC | 双色 WLAN/WAN、4 格电池、SIM 热插拔 |
| **`uf896`**     | `generic-uf896`     | UF896 (v1.1) 4G LTE 路由器  | MSM8916 | 512 MB | 4 GB eMMC | 三色 + 充电/网络/wifi/数据 LED |
| **`jz02`**      | `generic-jz02`      | JZ02 电池 MiFi（3 条 SIM 切换线） | MSM8916 | 512 MB | 4 GB eMMC | 网络三色 + Wi-Fi 红 + 电池红/绿 |
| **`mf32lt`**    | `generic-mf32lt`    | MF32LT 4G Modem 网卡（3 路 SIM/eSIM mux） | MSM8916 | 512 MB | 4 GB eMMC | 4 格电池 + 蓝色 Wi-Fi + RGB 状态 |

### 各板型特性矩阵

| 板型     | Failsafe 模式 | Bluetooth | WPA3-SAE / Multi-SSID | CPU CPR + 800 MHz 上限 | Wi-Fi/PMIC 散热映射 | `a2_pin` modem 保持 | `qcom-time-daemon` |
| :-------- | :-----------: | :-------: | :-------------------: | :-------------------: | :---------------------: | :-----------------: | :----------------: |
| `hmuf02v5`   |      ✅       |    ✅     |          ✅           |          ✅           |           ✅            |         ✅          |         ✅         |
| `ufi001b` |      ✅       |    ✅     |          ✅           |          ✅           |           ✅            |         —           |         —          |
| `ufi003`  |      ✅       |    ✅     |          ✅           |          ✅           |           ✅            |         ✅          |         —          |
| `uz801`   |      ✅       |    ❌     |          ✅           |          ✅           |           ✅            |         ✅          |         —          |
| `uf02`    |      ✅       |    ✅     |          ✅           |          ✅           |           ✅            |         ✅          |         —          |
| `mf800b`  |      ✅       |    ✅     |          ✅           |          ✅           |           ✅            |         —           |         —          |
| `mifib-v12` |    ✅       |    ✅     |          ✅           |          ✅           |           ✅            |         ✅          |         —          |
| `uf896` |    ✅       |    ✅     |          ✅           |          ✅           |           ✅            |         ✅          |         —          |
| `jz02` |    —       |    ✅     |          ✅           |          ✅           |           ✅            |         ✅          |         —          |
| `mf32lt`  |      ✅       |    ✅     |          ✅           |          ✅           |           ✅            |         —           |         —          |

* UZ801 v3 没有 Bluetooth 天线；其镜像包含该软件，但该板型上无法使用 Bluetooth。
* **并发 AP+STA**（Station 模式）在**每个板型**上都可用 —— 服务、mac80211 补丁和`luci-app-wifi-sta` 都是 target 级别的；参见[该指南](Docs/WiFi/AP_STA_AND_LUCI_APP.md)。

### 各板型硬件特性

| 板型     | 电池 + 充电上限 | 电源键 | Recovery 分区 | SIM 热插拔 |
| :-------- | :--------------------: | :----------: | :----------------: | :----------: |
| `hmuf02v5`   |           —            |      —       |         ✅         |      ✅      |
| `ufi001b` |           —            |      —       |         —          |      —       |
| `ufi003`  |           —            |      —       |         —          |      —       |
| `uz801`   |           —            |      —       |         —          |      —       |
| `uf02`    |           —            |      —       |         —          |      —       |
| `mf800b`  |           ✅           |      ✅      |         ✅         |      —       |
| `mifib-v12` |         ✅           |      ✅      |         ✅         |      ✅      |
| `uf896` |         —           |      —      |         —         |      —      |
| `jz02` |         ✅           |      ✅      |         ✅         |      —      |
| `mf32lt` |         ✅           |      ✅      |         ✅         |      —      |

* **Recovery 分区** —— 17 分区布局（`misc` + `recovery`）。`—` 表示该板型保持15 分区布局；参见 [`Docs/RECOVERY/`](Docs/RECOVERY/)。
* **3 路 SIM 选择** —— JZ02 有三条 SIM 切换线（GPIO 1 / 22 / 23），但在实测的那台机器上只有外部卡槽（3）可访问；`sim-select` init 脚本从 `uci sim.slot`（默认 3）选择卡槽。它不是自动热插拔。
* **MF32LT SIM/eSIM 选择** —— 一个实体卡托（GPIO 49）加两颗嵌入式 SIM（GPIO 50/51）；`sim-select [sim|esim1|esim2]` 把选择保存到 `uci sim.sim.select`、通过 `sim-select` init 脚本重新应用，并重启 modem 以便 baseband 重新采样 mux（默认 `sim`）。它不是自动热插拔。
* **电源键** —— mifib-v12、mf800b 和 jz02 有 `pm8941_pwrkey`；`mf32lt` 改用 GPIO key（GPIO 34 → `KEY_POWER`，由 `etc/rc.button/power` 处理：双击重启，按住 4 s 关机）；参见 [`Docs/POWER_BUTTON.md`](Docs/POWER_BUTTON.md)。
* **SIM 热插拔** —— `sim-hotplug` 服务在**每个**板型上都附带并启用。表格标出`sim_hotplug` 这一行在哪里得到**确认**：HMUF02-V5（端到端验证，约 15 s）和mifib-v12（同一 modem 家族，已启用，尚未长期浸泡测试）。`—` 表示该行在该板型上未测试，而不是服务缺失 —— 参见 [`Docs/SIM_HOT_SWAP.md`](Docs/SIM_HOT_SWAP.md)。

> Wi-Fi/PMIC 散热映射位于**共享的 `msm8916-ufi.dtsi`**（patch 861），本 target 的每个板型都包含它，因此所有板型都能获得。`a2_pin` modem 电源轨保持在**HMUF02-V5、UZ801、UF02、HM-MIFIB-V12、JZ02 和 UFI003** 板型上启用 ——前四者带有同一个 HiMI baseband 家族（`HIMI_U01_MODEM_V1.0`），会暴露`a2_power.c:1189` 的 quiesce 卡死问题，JZ02（`M8936FAAAANUZM`）撞上了同一个 SSR循环（`modem pc-ack timeout during resume`），而 UFI003 的板级 DTS 在 `&bam_dmux`上设置了 `qcom,a2-pin`；`UFI001B`（modem `MPSS.DPM.2.0.2`，V2.0）、`MF800B` 和`MF32LT` 没有设置它，并且 **UF896 不需要它**（在真实硬件上经现场测试 —— 未观察到`a2_power.c:1189` 的 quiesce 卡死）。其余内容适用于每个板型。Failsafe 模式在**除 JZ02 之外的每个板型**上启用，JZ02 的 reset 按键孔在软件上不可见（硬件测试：没有 GPIO、PMIC-GPIO 或电源键事件），因此它没有按钮触发的救援模式；该功能**仅在 HMUF02-V5 上经过实际验证**。

### 🛠️ 添加新板型

想移植一个新的 MSM8916 设备？参见**[`Docs/ADDING_A_DEVICE_BOARD.md`](Docs/ADDING_A_DEVICE_BOARD.md)** —— 一份分步指南（DTS 补丁、qcom Makefile 注册、`msm8916.mk` Device profile、`diffconfigs/`、base-files 的 LED/按键调整、构建/刷机/验证，以及一份可复制粘贴的清单），以 [MF800B PR #2](https://github.com/akbar-npj/msm8916-openwrt/pull/2) 为蓝本。

---

## 🔄 恢复与重启模式

OpenWrt 既提供带内救援 shell（**failsafe 模式**），也提供通往 Qualcomm 恢复模式的
软件触发重启路径。

在采用 17 分区布局的三块板型（**hmuf02v5**、**mf800b**、**mifib-v12**）
上，还有一个真正的 **recovery 分区**：开
机时按住 reset 按钮、运行 `reboot-recovery`、在 LuCI
中使用 **System → Reboot to Recovery**，或让
bootloader 在三次启动失败后回落到它。分区布局、每块板型的按键和失败计数器
参见**[`Docs/RECOVERY/`](Docs/RECOVERY/)**。

### Failsafe 模式（修复损坏的配置）

这些上网棒没有以太网口也没有串口排针，因此 failsafe 模式会拉起自己的 USB gadget。
进入方法：

1. 给上网棒开机（或重启）。
2. **在最初的 7 秒内按一次 Restart 按钮。** 轻按一下即可
   —— 无需按住。**红色 LED 恰好在这 7 秒内快闪（100
   ms）**，因此无需控制台也能看到这个窗口。failsafe 激活后，LED 会切
   换到更快的 **40 ms 闪烁**（约 12 Hz；板型有红灯则用红色，
   否则绿色，再否则任意颜色）—— 于是“现在按”和“已经进去”看起来是不同的。
3. 通过 **`192.168.10.1`**（USB 网卡）或 **`/dev/ttyACM0`**
   （USB 串口，115200）访问设备：

   ```bash
   ssh root@192.168.10.1
   screen /dev/ttyACM0 115200
   ```

进去之后，运行 `mount_root` 挂载 overlay、修复 `/etc/config/*`，或者
`firstboot && reboot` 恢复默认值。完整指南：
[`Docs/Failsafe/`](Docs/Failsafe/README.md)。

> 在*运行中的*系统上**按住 Restart 按钮 5 秒**会执行
> **恢复出厂设置 + 重启**；短按会被忽略。

### 重启到 EDL

从 SSH shell 或 USB 串口控制台：

```bash
reboot-edl
```

设备会直接重启进入 **Qualcomm Emergency Download（EDL）模式**。

在主机上，确认检测到 Qualcomm EDL USB 设备：

```bash
lsusb | grep 05c6:9008
```

预期的 USB 标识：

```text
05c6:9008 Qualcomm HS-USB QDLoader 9008
```

这样就可以使用 `edl` 或 `qdl` 等 Qualcomm EDL 工具恢复或重刷设备。

### 重启到 Fastboot

在 OpenWrt 中：

```bash
reboot-bootloader
```

设备会重启进入 **Fastboot 模式**，允许从主机执行 bootloader 级别的操作。

在主机上验证设备：

```bash
fastboot devices
```

### Android/ADB EDL

在可用 ADB 的场合，也可以使用标准 Android 命令：

```bash
adb reboot edl
```

当设备已经在运行 OpenWrt 且没有 ADB 时，OpenWrt 专属的 `reboot-edl` 命令很有用。

---

## ⚡ 向设备刷写固件

### 1. 将设备置于 Qualcomm EDL 模式（`05c6:9008`）

使用以下任一方法把 USB modem 置于 **Qualcomm Emergency Download（EDL）模式**：
* 在把棒子插到 USB 口的同时短接硬件 **EDL 测试点**。
* 从 Android shell（有 ADB 的场合）：`adb reboot edl`
* 从 OpenWrt shell：`reboot-edl`
* 从 LuCI：**System → Reboot to EDL**（由 `reboot-edl` 软件包安装）。在带 recovery分区的板型（`hmuf02v5` / `mf800b` / `mifib-v12`）上，同一菜单还提供**System → Reboot to Recovery**。

确认主机检测到处于 Qualcomm EDL 模式的设备：

```bash
lsusb | grep 05c6:9008
# Expected: 05c6:9008 Qualcomm HS-USB QDLoader 9008
```

---

### 场景 A：从原厂 Android 迁移到 OpenWrt（首次刷机必用脚本）

> [!CAUTION]
> **从原厂 Android 迁移时，切勿直接刷写单个 boot 和 rootfs 分区。**原厂 Android 设备的分区表（GPT）布局完全不同，bootloader/固件分区不同，并且存在必须保留的关键射频/校准数据（`fsc`、`fsg`、
> `modemst1`、`modemst2`、`modem`、`persist`、`sec`）。在原厂 Android 之上直接刷写 OpenWrt 分区会导致bootloop、软变砖，或 IMEI、MAC 地址与 RF 校准数据的永久丢失。

要从原厂 Android 安全迁移到 OpenWrt，你**必须**使用编译期间在`openwrt/bin/targets/msm89xx/msm8916/` 生成的自动刷机脚本：

```bash
cd openwrt/bin/targets/msm89xx/msm8916/
chmod +x openwrt-msm89xx-msm8916-<board>-flash.sh
./openwrt-msm89xx-msm8916-<board>-flash.sh
```

脚本会显示一个带**四个**选项的交互菜单 —— **`1` Migrate**（原厂 Android → OpenWrt）、**`2` Update**（已有 OpenWrt → OpenWrt）、**`3` Repartition**（添加 recovery 分区）和 **`4` Backup**（整机 EDL dump，建议在做任何其他操作之前先做）——请先选 **`4`** 做备份，再选 **`1`** 进行首次迁移：

```
=== OpenWrt MSM8916 EDL Flash Script ===

  1) Migrate from stock Android to OpenWrt
     (DESTRUCTIVE: repartitions the eMMC, flashes the bootloader, wipes Android)
  2) Update an existing OpenWrt install
     (flashes boot + rootfs only; partition table left untouched)
  3) Repartition an existing OpenWrt install
     (rewrites the GPT, adds misc + recovery, wipes the overlay;
      boot + rootfs are kept)
  4) Back up the whole device (EDL dump - do this FIRST; named after the device)

Choice [1/2/3/4]:
```

*（无人值守时，`--mode migrate --yes` 选择相同的路径；`./...flash.sh --help`列出所有标志。）*

#### 脚本自动处理的内容：

* **整机 dump（建议首先执行）**：`./...flash.sh --mode backup` 通过 EDL 读取**整台设备** —— 既可以是一整个 raw 镜像（`edl rf` → `./<device>-dump.bin`），也可以按分区读取（`edl rl` → `./<device>-dump/`，用 `edl w <part> <file>`恢复单个分区）。dump **以设备命名**：名字来自 `--device-name`、被记住的`.flash-device-name`，或备份时的提示，因此一台机器的 dump 绝不会被误认为另一台的。在任何破坏性模式之前，脚本都会检查**这台设备**的 dump，除非指定 `--yes`，否则没有 dump 就拒绝继续。
* **安全备份**：把所有关键的、因设备而异的射频/校准分区（`fsc`、`fsg`、`modemst1`、`modemst2`、`modem`、`persist`、`sec`）备份到本地 `saved/` 目录。每次读取都会校验；任何备份失败（出错，或文件为空/过短）脚本都会**在写入任何内容之前中止**，设备保持原样。
* **GPT 重新分区**：通过 raw 扇区写入（`primary.bin`、`backup_entries.bin`、`backup_header.bin`）刷写 OpenWrt 分区表（`*-squashfs-gpt_both0.bin`），安全地为 eMMC 重新分区。
* **固件提取与刷写**：从该板型的 `*-firmware.zip` 中提取 `aboot.mbn`、`hyp.mbn`、`rpm.mbn`、`sbl1.mbn` 和 `tz.mbn`，并刷写到重新分区后的布局中。
* **OpenWrt 安装**：刷写 OpenWrt kernel/boot 镜像（`*-squashfs-boot.img`）、rootfs 系统镜像（`*-squashfs-system.img`），并擦除 `rootfs_data`（快速 2 MiB superblock 擦除，下次开机时重新格式化）。
* **分区恢复**：把先前备份的所有校准与射频分区恢复回设备。
* **自动重启**：直接把设备重启进 OpenWrt（`edl reset`）。

---

### 场景 B：更新或重新刷写已安装的 OpenWrt 设备

如果你的设备已经在运行 OpenWrt，并且已经重新分区为 OpenWrt 的 GPT 布局：

* **推荐（Sysupgrade）**：使用标准 sysupgrade 路径以保留配置（参见 [Sysupgrade](#-sysupgrade)）。
* **经 EDL 干净重刷**：使用**同一个 `*-flash.sh`**（菜单 `2`，或 `--mode update`），并选择 **`2`（Update an existing OpenWrt install）**。它只刷写 `boot` + `rootfs`，绝不触碰分区表、bootloader 或射频/校准分区：

```bash
cd openwrt/bin/targets/msm89xx/msm8916/
./openwrt-msm89xx-msm8916-<board>-flash.sh
```

  Update 模式会先确认设备具有 OpenWrt GPT（`edl printgpt` 列出 `boot` + `rootfs`），然后询问配置 overlay 是要 **KEEP** 还是 **ERASE**：

```
Config overlay (rootfs_data):
  y) KEEP  - preserve /etc, packages and the dumped modem/Wi-Fi firmware
  n) ERASE - wipe the overlay for a factory-clean first boot
             (fast: 2 MiB superblock wipe, reformatted on boot;
              modem firmware is re-dumped automatically)
Keep configuration? [Y/n]:
```

  * **KEEP**（默认）与常规 `sysupgrade` 一致。
  * **ERASE** 通过快速 2 MiB superblock 擦除实现出厂干净的首次开机。

  *（无人值守：`--mode update --keep-config --yes` 或`--mode update --erase-config --yes`。）*

* **手动 EDL 替代方案**（等价于带 KEEP 的 update 模式）：

```bash
# Flash kernel boot and rootfs partitions
edl w boot openwrt/bin/targets/msm89xx/msm8916/openwrt-msm89xx-msm8916-<board>-squashfs-boot.img
edl w rootfs openwrt/bin/targets/msm89xx/msm8916/openwrt-msm89xx-msm8916-<board>-squashfs-system.img

# Optional: wipe the persistent overlay superblock to start clean on next boot
# (reformatted automatically on boot). NOTE: `edl e` / `edl ep` do NOT work with
# this device's firehose loader (they silently no-op), so wipe with a raw write:
START=$(( $(edl printgpt | sed -n 's/^rootfs_data:.*Offset 0x\([0-9a-f]*\),.*/\1/p') / 512 ))
dd if=/dev/zero of=/tmp/zeros.bin bs=512 count=4096
edl ws "$START" /tmp/zeros.bin

# Reboot the device
edl reset
```

---

### 场景 C：为已安装的 OpenWrt 重新分区（添加 recovery 分区）

如果设备已经在运行 OpenWrt，但其镜像是**不含** recovery 分区构建的
（15 分区布局），而你想要那个救援分区（参见
[wiki 的 *Recovery* 页面](https://github.com/akbar-npj/msm8916-openwrt/wiki/Recovery)），
该模式会重写 GPT 以添加 `misc` + `recovery`，并刷写救援镜像，
**同时不触碰 `boot`/`rootfs`**。

> **仅适用于镜像附带 `recovery` 分区的板型** ——`hmuf02v5`、
> `mf800b`、`mifib-v12`、`jz02` 和 `mf32lt`
> 是以 `GPT_RECOVERY=1`构建的。在另外五块板型上，脚本会在
> 写入任何内容之前中止。`jz02` 和 `mf32lt`的构建包含这些分区，但还
> 没有发布的 `recovery-<board>.img`，而这也是脚本要求的。

它就是菜单 `3`（`--mode repartition`）：它重写
GPT、擦除 overlay（快速 2 MiB superblock 擦除），并
刷写 `recovery-<board>.img`。由于`boot`/`rootfs`
会被保留，如果你还想更换正在运行的固件，随后再执行一次常规更新：

```bash
./openwrt-msm89xx-msm8916-<board>-flash.sh --mode repartition --yes
./openwrt-msm89xx-msm8916-<board>-flash.sh --mode update --keep-config --yes
```

完整的 recovery 布局、每块板型的按键和
3 次失败的 failover 见 wiki。

---

## 🔧 Fastboot 恢复

如果设备已经在运行 OpenWrt 并支持软件 Fastboot 重启：

```bash
reboot-bootloader
```

然后验证设备：

```bash
fastboot devices
```

在设备的 bootloader 支持的场合，Fastboot 可用于 bootloader 级别的恢复操作。

---

## 🔄 Sysupgrade

OpenWrt 的 sysupgrade 路径会保留持久的 `rootfs_data` overlay。

在升级之前，platform 代码会执行所需的服务/子系统拆除，以避免先前观察到的重启 / kernel 问题。

刷写新的 sysupgrade 镜像之后，持久的 `/overlay` 文件系统仍然可用：

```bash
mount | grep overlay
```

预期结果：

```text
/dev/mmcblk0p15 on /overlay type ext4 (rw,noatime)
overlayfs:/overlay on / type overlay (...)
```

preinit 文件系统检查会在 `mount_root` 之前验证 EXT 文件系统：

```text
rootfs_data: ext filesystem detected
rootfs_data: running e2fsck -p
rootfs_data: filesystem errors repaired
mount_root: switching to ext4 overlay
```

现有的 EXT 文件系统**不会仅仅因为需要修复就被重新格式化**。只有在检测不到现有 EXT 文件系统时，才会创建新的 EXT4 文件系统。

### ⬆️ 从设备端升级（r3 及之后）

从 **r3** 起，设备自己就能发现、校验并安装新版本 —— 无需 `scp`、无需手动下载：

* **LuCI** —— *System → Firmware Upgrade*。显示运行中的版本、该板型已发布的版本、镜像大小和发行说明，然后下载、检查 SHA-256 并刷写。**Keep settings** 默认勾选；取消勾选即为全新安装（`sysupgrade -n`）。
* **CLI** —— `firmware-upgrade check`（JSON 可用性）、`download`、`apply [--no-keep]`，或 `upgrade [--no-keep]` 一次完成这三步。

客户端读取 `firmware.json` —— 发布流水线在镜像旁发布的 manifest —— 并将它与本设备的`DISTRIB_RELEASE` 比较。它遵守 `min_version` 下限，因此版本太旧、无法直接跳升的设备会被要求手动刷写一次，而不是递给它一个无法应用的镜像。

> **r1/r2 上的设备没有升级客户端**，必须手动刷写一次到 r3。从 r3 起，每个版本都能就地更新。引擎是 `msm89xx-firmware-upgrade`，页面是`luci-app-firmware-upgrade`（两者都在 `DEFAULT_PACKAGES` 中）。参见 [How Releases and Hotfixes Work](https://github.com/akbar-npj/msm8916-openwrt/wiki/How-Releases-and-Hotfixes-Work)。

---

## 📶 Wi-Fi

WCN36xx 2.4 GHz 射频在首次开机时自动启动，并在信道 1 广播一个**开放的** `OpenWrt` AP。它由 mainline `wcn36xx` 驱动加上本代码树携带的一小组 mac80211 backport 补丁驱动。

* 支持 **WPA3-SAE（Personal）**。从 LuCI（*Network → Wireless → Edit →Wireless Security*）或 UCI 配置；WPA3 客户端会协商 SAE + PMF，WPA2 客户端则继续照常工作。
* 支持 **Multi-SSID**：同一射频上最多**两个 AP 接口**（例如主 SSID 和访客 SSID）。
* 支持**并发 AP + STA**：射频在继续发送其 AP beacon **的同时**作为客户端加入另一个网络。从 **Network → Station Mode**（或 `/etc/config/wifista`）配置 ——参见 [Concurrent AP+STA and the Station Mode LuCI app](Docs/WiFi/AP_STA_AND_LUCI_APP.md)。station 是在 AP 起来**之后**由服务创建的；它刻意*不是* `wifi-iface`，因为 netifd 每次无线变更都会重启 phy，而带 station 接口配置的 phy 重启会崩溃 WCNSS 固件。

> [!NOTE]
> 在 *Network → Wireless* 下保存任何内容都会重启 phy —— 恰恰是会让固件崩溃的那件事。这已经处理了：netifd 的无线驱动被 `wifi-sta-guard`
> （`openwrt-patches/811`）包裹，它会在 phy 被触碰之前停止 station、之后再把它重启，因此**`wifi reload` 和 Save &
> Apply 在 station 模式运行时是安全的**。只有绕过 netifd的射频重置（裸的 `iw dev del`、`rmmod wcn36xx`、驱动 rebind）才仍然需要手
> 动序列：```sh /etc/init.d/wifi-sta-late stop; <the thing>; /etc/init.d/wifi-sta-late start ```

---

## 🔵 蓝牙

设备的 Bluetooth 控制器是经 SMD 传输到达的 WCNSS core（`kmod-btqcomsmd` + `kmod-btqca`），配合 **BlueZ 5.83** userspace（`bluetoothd`、`bluetoothctl`、`hcitool`、`btmgmt`、`rfcomm`、`sdptool`、`bt-agent`）。

> **UZ801 v3 硬件限制：** 该板型没有 Bluetooth 天线。Bluetooth 软件存在于其镜像中，但 UZ801 v3 上 Bluetooth 无法作为正常的空中特性使用。

从控制台拉起控制器并配对：

```bash
bluetoothctl
[bluetooth]# power on
[bluetooth]# scan on
[bluetooth]# pair <BD_ADDR>
```

### SSP 配对保护（`bt-ssp-guard`）

控制器的 Secure Simple Pairing 能力由存储在 Bluetooth NVM tag 6 中的单个LMP-feature 位控制。如果该位曾被清零，BR/EDR 配对就会回落到旧式 PIN 配对并失败。`bt-ssp-guard` 在开机时检查该位，并在需要时修复它：

```bash
bt-ssp-guard status    # report the feature bit / SSP mode
bt-ssp-guard repair    # check and repair; add --wait to poll for hci0 first
```

正常情况下它是一个无声的空操作 —— 它的存在是为 feature 位被清零买保险。

### 串口配置文件（`bt-spp`）

`bt-spp` 提供一个 Bluetooth **SPP** 端点，使已配对的手机或电脑能以串口方式访问该设备：

* **服务器**（开机启用）监听 RFCOMM channel 1，等待传入连接。
* **客户端**按需针对对端地址发起。

两者都使用可配置的 **bridge** —— 可以是 pty 上的登录 shell（经 Bluetooth 的串口控制台），也可以是本地 TCP socket：

```bash
uci show bt-spp           # current configuration
uci set bt-spp.server.bridge='tcp'
uci set bt-spp.server.tcp_port='5000'
uci commit bt-spp
/etc/init.d/bt-spp restart
```

> **注意：** `bluetoothd` 以 `--compat` 运行，因此本地 SDP Unix socket 才会存在（`sdptool`/`rfcomm` 需要它）。`br-connection-profile-unavailable` 错误表示*profile* 缺失，而不是认证失败。

---

## 🌡️ 散热与功耗管理

这些设备在狭小外壳里跑得很热，modem 的行为对电源轨也很敏感。本移植把 CPU 电源轨和散热策略与原厂 Android 对齐。

* **CPU 电源轨（mainline CPR）** —— CPU 电压由 mainline **CPR**（Core Power Reduction）而非固定电源轨管理，与 Android 针对该芯片熔丝速度档位的电压一致。与静态设置相比，这降低了空闲和中等负载下的 CPU 电压。
* **CPU OPP 上限** —— 998.4 MHz 的最高工作点被移除，因此 CPU 最高运行在**800 MHz**（与 Android 在这些部件上的上限一致）。
* **Wi-Fi + PMIC 散热控制（HMUF02-V5）** —— `wcn36xx` 驱动暴露一个对 Wi-Fi发射通路降频的 cooling device，PMIC 的 thermal zone 绑定到 CPU cooling device。触发点来自 CPU cluster 传感器，镜像 Android `thermal-engine` 的 "wlan" 动作。
* **电池与充电上限（mifib-v12、mf800b、jz02、mf32lt）** —— 启用 PM8916 电量计和充电器（容量、温度、如实的充电状态），充电被限制在 **85 %**（到 80 % 恢复）以保护电池。一个 LuCI 页面、一个电池 LED 监控和 `battery-ctl` 随`luci-app-battery` 提供。参见 **[`Docs/BATTERY.md`](Docs/BATTERY.md)**。
* **电源键（mifib-v12、mf800b）** —— 长按关机（插电时则是干净重启），双击重启。参见 **[`Docs/POWER_BUTTON.md`](Docs/POWER_BUTTON.md)**。

```bash
# Inspect the thermal zones and their cooling devices
for z in /sys/class/thermal/thermal_zone*; do
    echo "$z: $(cat $z/type) = $(cat $z/temp)"
done
```

完整的调查 —— OpenWrt 与 Android 的对比、根因分析以及 CPR 移植 —— 位于
**[`Docs/Thermal/`](Docs/Thermal/README.md)**。

---

## 🛡️ Modem 稳定性

这些棒子上的 Qualcomm baseband 可能在 modem 温重启之后撞上一个 **约 900 s 的期限**，并且在数据 bearer 下 A2（AP↔modem）电源握手失败时可能卡死。本移植附带若干自动运行的 **AP 侧**缓解措施 —— 无需用户操作：

| 组件 | 作用 |
| :--- | :--- |
| **`a2_pin`（HMUF02-V5、UZ801、UF02、UFI003）** | 在 `qcom_bam_dmux` 驱动中把 A2 电源轨保持**开启**，使 modem 不会在握手进行到一半时被 power collapse。在这些板型上经 device tree 启用。 |
| **`himi-ok-guard`** | 在**每次** modem 启动（冷启动和每次 SSR）之后重写 modem NV 项 `HiMI_OK`，使 RF 任务的身份检查通过、约 900 s 的期限永远不会被武装。在 HMUF02-V5、UZ801 v3 和 UF02 板型上启用；只在该项读出全零时写入（出厂数据绝不会被覆盖）。 |
| **`modem-bearer-watchdog`** | 监控 modem 与数据 bearer；执行预防性子系统重启，并在无需重启的情况下恢复僵尸 bearer/ModemManager。在**移动中**自动切换到切换安全的 **30/5 stall profile**（`auto_mobile`，默认开启 —— 经 ModemManager D-Bus 检测服务小区变化），静止 `mobile_grace_secs`（180 s）后回落到静止 profile，反之亦然。另提供手动的 `mobile_optimized` 强制模式。 |
| **`qcom-time-daemon`** | 在 LTE attach 之前锚定 modem 的时间基准（ATS），使 QMI 时间同步有效。 |

验证保护处于活动状态：

```bash
logread | grep -i himi-ok        # guard activity
ubus call network.interface.modem status   # data bearer state
```

> 对于更倾向于使用 AP 侧保护之外方案的用户，另有一个**可选的 baseband 二进制补丁**。二进制补丁代码刻意**不随本固件发布** —— 权衡与手动流程见**[`Docs/Modem Stability/HMU05_900S_FATAL_FIX_USER_GUIDE.md`](Docs/Modem%20Stability/HMU05_900S_FATAL_FIX_USER_GUIDE.md)**（"Choose Your Fix"）。

---

## 🔌 默认设备访问方式

| 服务                  | 访问方式                  | 默认凭据              |
| :----------------------- | :------------------------------ | :------------------------------- |
| **Web 界面（LuCI）** | `http://192.168.8.1` 和 `https://192.168.8.1` | 无密码（首次登录时设置）；HTTPS 使用自签名证书 —— 参见 [`Docs/HTTPS.md`](Docs/HTTPS.md) |
| **Modem Watchdog**       | 自动 + LuCI（Services → Modem Watchdog） | 预防性 SSR、僵尸恢复、自动切换 profile |
| **SMS 管理**       | LuCI：**Services $\to$ SMS**    | 通过 Web 界面查看 / 发送 SMS       |
| **SSH 终端**         | `ssh root@192.168.8.1`          | 无需密码             |
| **USB 串口控制台**   | `screen /dev/ttyACM0 115200`    | 直接 root shell                |
| **Wi-Fi 接入点**   | SSID：`OpenWrt`（2.4 GHz，Ch 1） | 开放（可配置 WPA3-SAE）     |
| **Bluetooth**            | `bluetoothctl` / `bt-spp`       | RFCOMM channel 1 上的 SPP 服务器   |
| **Failsafe 模式**        | 7 s 内轻按按钮 → `ssh root@192.168.10.1` | 救援 shell（LED 闪烁） |
| **恢复出厂设置**        | 按住 Restart 按钮 5 s         | 擦除 overlay，然后重启      |
| **EDL 恢复**         | `reboot-edl`                    | Qualcomm USB `05c6:9008`         |
| **Fastboot 恢复**    | `reboot-bootloader`             | `fastboot devices`               |

---

## 📡 SIM 检测、运营商自动开通与重启行为

当你插入装有 SIM 卡的 modem 棒 —— 或者实体换卡 —— 时，设备会**自动连接，无需重启**。`sim-hotplug` 察觉到实体换卡，并向 baseband 重新声明该卡；随后运营商检测、APN/网络配置、频段选择、radio-cache 刷新和 LTE bearer 拉起由`qcom-carrier-autocfg` 守护进程实时执行。

> [!NOTE]
> **早期构建会在约 10–15 秒后重启一次以重新加载运营商 MBN。该行为已被移除。**设备不再使用 `mcfg.mbn` / `MCFG_SW.MBN`，并且没有任何开通步骤会重启系统。

### 为什么不再需要重启？

1. **AP 不再应用运营商 MCFG。** 该引擎过去会通过 modem 的 PDC 服务（QMI）加载并激活每个运营商的 **Carrier MBN**（`mcfg_sw.mbn`），还有一个把文件复制到`/lib/firmware/MCFG_SW.MBN` 的旧式回退路径。两条路径都已移除。
2. **激活 MCFG 会强制 modem 自复位。** 固件自己的 `mcfg_utils.c:186` 描述符会记录`"MCFG:Modem Initiated Reset. This crash is expected!!!"`。对某些运营商而言，激活甚至从未提交（配置保持 Inactive，而已经 Active 的配置继续服务 —— HMUF02-V5/Jio：`ROW_Generic_3GPP`）。于是 AP 在**每次**开机时都会再次尝试，而每次尝试都是一次modem 重启 → SSR → A2 握手失步（`a2_power.c:1189`）→ 崩溃循环。
3. **modem 已经在 Active MCFG 配置下为该运营商服务**，因此动态加载什么也没带来。它因此被禁用：`provision_carrier_mbn()` 现在只是一个仅记日志的空操作（`return 1`）。

### `qcom-carrier-autocfg` 仍然做什么（全部实时、无需重启）

* **SIM 检测与匹配**：通过 ModemManager 读取 SIM 的 IMSI 和 MCC-MNC 运营商代码，然后在它自己的 APN 数据库中匹配运营商（见下文的自定义数据库路径）。
* **APN / 网络配置**：把运营商的 APN 和 IP 协议栈（IPv4/IPv6）写入`/etc/config/network`。
* **频段选择**：通过 QMI 应用适合该运营商的频段集合。
* **Radio-cache 刷新**：通过 ModemManager QMI DMS（`set-power-state-low` / `-on`）刷新 baseband 注册状态。裸 `AT+CFUN=0/1` **被刻意禁用** —— 在原厂未改动的固件上它会触发致命的 baseband 断言（`lte_ml1_common_dump.c:213`）。
* **Bearer 拉起**：与 Qualcomm QMI Time Daemon（`qcom-time-daemon`）校验时钟同步，然后命令 ModemManager 连接 4G LTE bearer。蓝色 WAN LED 点亮以指示活跃的蜂窝上网。

### SIM 热插拔行为

拔出卡片、插入另一张，设备会**实时恢复、无需重启**，即使新卡来自另一家运营商。

这些上网棒**没有 AP 侧的卡在位检测线**。GPIO 114（`sim_hotplug`）是一个 AP 驱动以让 baseband 重新读卡的*输出*，而 baseband 固件的 `feature_support_hotswap`是**禁用**的：它能察觉卡被**拔出**（UIM 报告 `possibly-removed`），却**永远察觉不到插入** —— 卡可以在卡槽里坐几分钟，modem 也看不见它，直到 AP 脉冲 `sim_hotplug`。

`sim-hotplug` 服务处理这件事：

| 状态 | 行为 |
| :--- | :--- |
| 卡在位 + modem 已注册 | 每 **60 s** 检查一次 UIM |
| 卡在位 + modem 搜索中 | 每 **5 s** 检查一次 UIM（仅节奏如此 —— 单纯的 `searching` 从不代表“换卡”，因此小区重选/列车切换不会触发任何动作） |
| 认为卡不在位 | 脉冲 `sim_hotplug` → 等待 4 s → 检查，每 **6 s** 一次 |

从 `absent → present` 时，它会等待注册、强制 ModemManager 重新读取 SIM（`mmcli -d` + `-e`，正是这一步让**另一张**卡的 IMSI/APN 对`qcom-carrier-autocfg` 可见），然后把 bearer 重新拉起来。

在硬件上端到端实测：一次约 4 s 的换卡全程约 **15 s**（拔出在 5–7 s 内检测到，插入在 ≤10 s 内检测到）。

```sh
sim-hotplug --help                  # options and log tag
/etc/init.d/sim-hotplug status
/etc/init.d/sim-hotplug rescan      # force one re-announce now
logread -e sim-hotplug
```

调优参数位于 `/etc/config/sim-hotplug`：`idle_interval`（60）、`active_interval`（5）、`absent_interval`（6）、`pulse_ms`（300）。

> [!NOTE]
> 比 modem 自身的拔出消抖**更短**的换卡是不可见的：modem 保留其缓存的卡、保持`connected`，UIM 继续回答 `present`，因此 AP 无从检测。同一张卡插回去时这无害。如果*另一张*卡这么快被插入，请运行 `/etc/init.d/sim-hotplug rescan` ——或者让 bearer watchdog 的 SSR 在数据失败时重新初始化 UIM。

该服务使用 `qmicli --device-open-proxy`（经 `qmi-proxy` 与 ModemManager 共享端口），一次一个短生命周期的客户端，并且始终在 `timeout` 之下运行；它从不自行发出`mmcli -r` 或 SSR。这避免了天真的 `qclicli` 轮询循环会造成的`ClientIdsExhausted` 失败。

> [!IMPORTANT]
> 热插拔**仅在 HMUF02-V5 上**实现并验证（GPIO114 `sim_hotplug`）；**HM-MIFIB-V12 的 DTS 定义了同一条线**但未经验证。其他板型没有定义它，服务因此会自行禁用。设备拥有者应当验证它：完整流程和板型矩阵见**[`Docs/SIM_HOT_SWAP.md`](Docs/SIM_HOT_SWAP.md)**。

### 自定义 SIM 运营商安装

如果你的运营商缺失或被误检测，把它加入用户覆盖数据库**`/etc/qcom-carrier-autocfg/custom-apns.tsv`** —— 它优先于内置的`/usr/share/qcom-carrier-autocfg/apns.tsv`，并且**在 OpenWrt sysupgrade 之间保留**。各条目以制表符分隔：

```text
MCC_MNC<TAB>Operator_Name<TAB>APN<TAB>IP_Type<TAB>Mode<TAB>MBN_Path
```

例如，要添加 Reliance Jio（MCC-MNC `405861`）：

```text
405861	Reliance Jio	jionet	ipv4v6	4g	generic/apac/reliance/commerci/mcfg_sw.mbn
```

> [!NOTE]
> 末尾的 `MBN_Path` 列**仅作参考保留** —— 运营商 MCFG 不再被应用（见上文），因此该值只会被记录、永远不会被加载。

### 实时监控自动开通

你可以通过 SSH 或 USB 串口控制台（`/dev/ttyACM0`）实时观察运营商检测、profile 匹配和 bearer 拉起：

```bash
logread -f -e carrier-autocfg
```

**首次 SIM 检测的示例日志输出：**

```text
[carrier-autocfg] Started MSM8916 SIM Carrier Auto-Provisioning Engine
[carrier-autocfg] Matched carrier in global APN database for MCC-MNC 405861
[carrier-autocfg] Carrier MCFG dynamic loading is disabled; the modem uses the MCFG config that is already Active (requested: generic/apac/reliance/commerci/mcfg_sw.mbn).
[carrier-autocfg] Boot-time carrier provisioning completed successfully. No reboot required.
[carrier-autocfg] [QMI-TIME] Modem ATS_USER time sync verified before LTE attach.
[carrier-autocfg] Requesting ModemManager bearer connection for APN 'jionet' (ipv4v6)...
```

**SIM 热插拔的示例日志输出：**

```text
[carrier-autocfg] Matched carrier in global APN database for MCC-MNC 40445
[carrier-autocfg] HOT-SWAP: Live APN and baseband caches flushed.
[carrier-autocfg] Hot-swap handled live without reboot. Connection restored.
```

---

## 📂 分区布局（eMMC /dev/mmcblk0）

| 分区    | 标签               | 大小     | 类型     | 用途                                                              |
| :----------- | :------------------ | :------- | :------- | :------------------------------------------------------------------- |
| `p1` / `p3`  | `modem`             | ~64 MB   | VFAT     | 原厂 Qualcomm modem 与 WCNSS 固件 blob                          |
| `p6` / `p24` | `persist`           | ~32 MB   | EXT4     | 出厂校准与 Wi-Fi NVRAM（`WCNSS_qcom_wlan_nv.bin`）       |
| `p13`        | `boot`              | ~32 MB   | Raw      | OpenWrt Linux 6.12 kernel + DTB（`boot.img`）                         |
| `p14`        | `system` / `rootfs` | ~1.5 GB  | SquashFS | OpenWrt 只读根文件系统（`system.img`）                     |
| `p15`        | `rootfs_data`       | ~1.5 GB+ | EXT4     | 可写的持久 overlay 存储（配置、软件包、日志） |

---

## 📦 官方软件包与内核驱动仓库

本仓库在 GitHub Pages 上托管一个实时 APK feed，包含所有预编译的 Qualcomm MSM8916内核模块（`kmod-*`）与应用程序：

* **主页**：https://akbar-npj.github.io/msm8916-openwrt/

该 feed **使用固定密钥签名**。每个镜像都附带匹配的公钥，以及一个开机服务（`apk-key-refresh`），它会从一个稳定 URL 重新同步该密钥，因此刷了旧镜像的设备绝不会陷入以 `UNTRUSTED signature` 拒绝 feed 的境地。

### 在设备上启用自定义 feed

```bash
cat << 'EOF' > /etc/apk/repositories.d/customfeeds.list
https://akbar-npj.github.io/msm8916-openwrt/releases/25.12.6/targets/msm89xx/msm8916/packages/packages.adb
https://akbar-npj.github.io/msm8916-openwrt/releases/25.12.6/packages/aarch64_generic/base/packages.adb
https://akbar-npj.github.io/msm8916-openwrt/releases/25.12.6/packages/aarch64_generic/packages/packages.adb
EOF

apk update
```

### 安装额外驱动与软件包

```bash
# Install USB Ethernet driver
apk add kmod-usb-net-rtl8152

# Install WireGuard VPN
apk add luci-app-wireguard

# Install the modem bearer watchdog web UI
apk add luci-app-modem-watchdog
```

### 更新本项目自有软件包（无需重刷）

本项目自己编写 —— modem 与 Wi-Fi LED 监控、station 模式辅助程序、watchdog 和升级页面 —— 的工具位于 [`packages/`](packages/)，而**不在** `base-files` 中。因此修复会以已签名的软件包更新的形式送达设备，而不是一个 35 MB 的镜像：

```bash
apk update
apk upgrade msm89xx-scripts            # the LED/station helpers
apk upgrade luci-app-firmware-upgrade  # the upgrade page
```

CI 会针对**同一个 toolchain 和 kernel** 重建这一个变更的软件包，把它接入本 feed，并用固定密钥重新签名索引 —— 因此设备上的仓库行和密钥都不会改变。`luci-app-update-notify` 会在仪表盘上放置一条*"N package updates are available"* 提示。

热修**无法**携带的是烙进镜像里的东西 —— kernel、驱动、preinit hook、`base-files`。那些需要一个固件发布版，而设备随后会自行安装它（参见[从设备端升级](#-从设备端升级r3-及之后)）。完整流程见[Releases & Hotfixes](https://github.com/akbar-npj/msm8916-openwrt/wiki/How-Releases-and-Hotfixes-Work)。

本仓库编写和内置的软件包（DIAG 工具、运营商自动配置、Bluetooth
SPP、LuCI 应用、……）记录在
**[`Docs/Custom Packages/`](Docs/Custom%20Packages/README.md)** 中。

每个自定义的设备端程序都会对 `--help`（或 `-h`）给出它的选项、它读取的 `uci` 键，
以及要观察的 `logread` 标签 —— 例如 `diag-bind --help`、
`modem-bearer-watchdog --help`、`diag_nv --help`。

---

## 📜 许可证

本项目以 **GNU General Public License v2.0（GPL-2.0）** 授权。

Qualcomm 固件 dumper 组件以 BSD-3-Clause License 授权。
