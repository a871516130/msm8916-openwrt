> 📄 本文件是 [README.md](README.md) 的英文原文中文译本，内容以英文版为准。

# MSM8916 OpenWrt 内核与源码补丁参考指南

本文档是本项目维护的每一个补丁的完整目录，并用通俗语言解释每个补丁做什么以及为什么需要它。

本项目在**五个**类别中维护改动。前三个是源码补丁；后两个是由 `openwrt-overlay/`、`packages/` 和 `msm89xx/` 构建出的交付产物。

| 集合 | 位置 | 数量 | 应用于 |
| :-- | :------- | :---- | :--------- |
| **内核补丁** | [`msm89xx/patches/`](../../msm89xx/patches/) | 53 | Linux kernel 源码，通过 OpenWrt 的 `target/linux/msm89xx/patches/` |
| **OpenWrt 源码补丁** | [`openwrt-patches/`](../../openwrt-patches/) | 4 | OpenWrt 构建树本身（package 配方与构建脚本） |
| **OpenWrt package 补丁** | [`openwrt-overlay/`](../../openwrt-overlay/) | 11 | 各个 OpenWrt package 与宿主工具（mac80211/wcn36xx、hostapd、libqmi、fstools、elfutils） |
| **自定义 packages** | [`packages/`](../../packages/) | 21 | 复制到 `package/msm8916/` 的用户态应用与 LuCI 模块 |
| **BSP / 板级支持** | [`msm89xx/`](../../msm89xx/) | -- | 随 rootfs 交付的 base-files、image、内核配置、modules、recovery |

> **板级支持范围。** 这些板级设备树面向七款 MSM8916 设备：
> **HMUF02-V5**（原名 HMU05）、**UF02**、**UFI001B**、**UFI003_MB_V02**、
> **MF800B**、**HM-MIFIB-V12** 以及上游的 **YiMing UZ801V3**。

---

## 1. 补丁总览

### 1.1 设备树 — 板级启用（801–807、852、853、867–869）

| 补丁 | 目标 | 说明 |
| :---- | :------ | :---------- |
| [`801-arm64-dts-qcom-add-devices-makefile.patch`](../../msm89xx/patches/801-arm64-dts-qcom-add-devices-makefile.patch) | `arch/arm64/boot/dts/qcom/Makefile` | 在内核构建中注册所有项目 DTB（`hmuf02v5`、`uf02`、`ufi001b`、`ufi003_mb_v02`、`mf800b`、`mifib-v12`、`uf896`、`jz02`、`mf32lt`）。 |
| [`802-arm64-dts-qcom-msm8916-label-reserved-memory.patch`](../../msm89xx/patches/802-arm64-dts-qcom-msm8916-label-reserved-memory.patch) | `msm8916.dtsi` | 添加 `reserved_memory:` 标签，使板级 DTS 文件可以追加 `ramoops` 区域。 |
| [`803-arm64-dts-qcom-uz801-leds-and-button.patch`](../../msm89xx/patches/803-arm64-dts-qcom-uz801-leds-and-button.patch) | `msm8916-yiming-uz801v3.dts` | 为 UZ801V3 的 LED 赋予标准 `LED_FUNCTION_WLAN` / `LED_FUNCTION_WAN` 角色；保留复位按键的低电平有效/上拉映射（GPIO23 空闲时为高电平）。 |
| [`804-arm64-dts-qcom-add-msm8916-generic-uf02.patch`](../../msm89xx/patches/804-arm64-dts-qcom-add-msm8916-generic-uf02.patch) | `msm8916-generic-uf02.dts` | UF02 棒状设备的完整板级 DTS（按键、LED）。 |
| [`805-arm64-dts-qcom-add-msm8916-generic-hmuf02v5.patch`](../../msm89xx/patches/805-arm64-dts-qcom-add-msm8916-generic-hmuf02v5.patch) | `msm8916-generic-hmuf02v5.dts` | HMUF02-V5 棒状设备的完整板级 DTS（SIM/eSIM GPIO hog、ramoops、LED、复位按键）。 |
| [`806-arm64-dts-qcom-add-msm8916-generic-ufi001b.patch`](../../msm89xx/patches/806-arm64-dts-qcom-add-msm8916-generic-ufi001b.patch) | `msm8916-generic-ufi001b.dts` | UFI001B 棒状设备的完整板级 DTS（SIM GPIO hog、ramoops、LED、复位按键）。 |
| [`807-arm64-dts-qcom-add-msm8916-generic-mf800b.patch`](../../msm89xx/patches/807-arm64-dts-qcom-add-msm8916-generic-mf800b.patch) | `msm8916-generic-mf800b.dts` | MF800B 棒状设备的完整板级 DTS（电池电量计、双色 LED、ramoops）。 |
| [`852-arm64-dts-qcom-add-msm8916-generic-ufi003.patch`](../../msm89xx/patches/852-arm64-dts-qcom-add-msm8916-generic-ufi003.patch) | `msm8916-generic-ufi003_mb_v02.dts` | UFI003_MB_V02 棒状设备的完整板级 DTS（SIM/eSIM GPIO hog、三色 LED、复位按键、ramoops）。 |
| [`853-arm64-dts-qcom-add-msm8916-generic-mifib-v12.patch`](../../msm89xx/patches/853-arm64-dts-qcom-add-msm8916-generic-mifib-v12.patch) | `msm8916-generic-mifib-v12.dts` | HM-MIFIB-V12 加密狗的完整板级 DTS：4.2 V 电池 + PM8916 LBC 充电器 + 带电池组热敏电阻的 VM-BMS、4 格电池 LED、双色 WLAN/WAN LED、热缓解以及 A2 引脚。 |
| [`867-arm64-dts-qcom-add-msm8916-generic-uf896.patch`](../../msm89xx/patches/867-arm64-dts-qcom-add-msm8916-generic-uf896.patch) | `msm8916-generic-uf896.dts` | UF896（v1.1）4G 路由器的完整板级 DTS：ramoops、复位按键 GPIO 35、三色状态 LED 外加六个额外指示 LED（充电器 / 网络 / Wi-Fi / 数据链路）。SIM 卡槽 1 是默认选择，无需用户态帮助；选择**不是** AP GPIO。同时在 `&bam_dmux` 上设置 `qcom,a2-pin`：r4 出厂时没有设置它，假设该板不会触发 A2 静默卡死，但现场日志显示 `a2_power.c:1216` 在约 930 秒运行时中止 remoteproc，随后每 70–130 秒崩溃循环一次。 |
| [`868-arm64-dts-qcom-add-msm8916-generic-jz02.patch`](../../msm89xx/patches/868-arm64-dts-qcom-add-msm8916-generic-jz02.patch) | `msm8916-generic-jz02.dts` | JZ02 电池 MiFi 的完整板级 DTS：三条 SIM 切换线加一条热插拔检测脉冲作为 gpio-leds（由 `etc/init.d/sim-select` 驱动）、三色网络 / Wi-Fi / 电池指示灯、4.35 V 电池，以及被禁用的复位按键（针孔在软件中不可见 — 硬件测试用）。 |
| [`869-arm64-dts-qcom-add-msm8916-generic-mf32lt.patch`](../../msm89xx/patches/869-arm64-dts-qcom-add-msm8916-generic-mf32lt.patch) | `msm8916-generic-mf32lt.dts` | MF32LT 棒状设备的完整板级 DTS：3 路 SIM/eSIM 复用器作为 gpio-leds（GPIO 49/50/51，由 `etc/init.d/sim-select` 和 `/usr/sbin/sim-select` 驱动）并带 `sim_en` gpio-hog、4 格电池电量计 + 带电池组 NTC 的 PM8916 充电器/BMS、Adreno GPU（`&gpu` 配 `qcom-msm8916-gpu-firmware`）、GPIO 电源键（`KEY_POWER`）、USB-id、SD 卡槽和 ramoops。 |

### 1.2 BAM-DMUX 网络驱动（808–812、814、820、821、825、828、831–833、848、850）

`qcom_bam_dmux` 驱动把 modem 的 BAM DMA 通道桥接到 Linux 网络接口（`wwan0`、`rmnet*`）。这是最大的一个集群——它承载了 AP↔modem 数据通路跨越 modem 重启与 A2 电源塌陷（power collapse）的全部修复。

| 补丁 | 说明 |
| :---- | :---------- |
| [`808-bam-dmux-stats.patch`](../../msm89xx/patches/808-bam-dmux-stats.patch) | 精确的 TX/RX 包与字节统计；在断电时释放 TX skb 并清除通道位图。 |
| [`809-bam-dmux-tx-pm-ordering.patch`](../../msm89xx/patches/809-bam-dmux-tx-pm-ordering.patch) | 在预留 TX 槽位**之前**获取 runtime-PM 引用，消除与 A2 电源塌陷扫描竞争的 NULL 解引用竞态。 |
| [`810-bam-dmux-tx-sweep-race.patch`](../../msm89xx/patches/810-bam-dmux-tx-sweep-race.patch) | 保护 `start_xmit()`，防止槽位在其执行期间被 `bam_dmux_free_skbs()` 扫描（释放）。 |
| [`811-bam-dmux-deferred-tx-telemetry.patch`](../../msm89xx/patches/811-bam-dmux-deferred-tx-telemetry.patch) | 延迟 TX 路径的诊断信息（被延迟的包是否曾经到达过 BAM？）。 |
| [`812-bam-dmux-preserve-deferred-tx.patch`](../../msm89xx/patches/812-bam-dmux-preserve-deferred-tx.patch) | 阻止静默（quiesce）丢弃那些只做了 DMA 映射、从未真正提交的延迟包。 |
| [`814-bam-dmux-ssr-powerup-retry.patch`](../../msm89xx/patches/814-bam-dmux-ssr-powerup-retry.patch) | 重试 SSR 之后的上电轮询，而不是永久放弃（缓慢的 modem 固件重载过去会让 `wwan0` 一直宕着直到重启）。 |
| [`820-bam-dmux-ssr-teardown-nonblocking-cancel.patch`](../../msm89xx/patches/820-bam-dmux-ssr-teardown-nonblocking-cancel.patch) | 使 RX 看门狗在拆解（teardown）期间以非阻塞方式取消，避免在 `state_lock` 上出现 ABBA 死锁。 |
| [`821-bam-dmux-ssr-teardown-flush-before-powerdown.patch`](../../msm89xx/patches/821-bam-dmux-ssr-teardown-flush-before-powerdown.patch) | 在 `rproc_stop()` 关闭 modem（及其 BAM）电源**之前**，让 SSR 拆解执行完毕。 |
| [`825-bam-dmux-pc-state-reconcile.patch`](../../msm89xx/patches/825-bam-dmux-pc-state-reconcile.patch) | 在分支判断之前把缓存的 `pc_state` 与总线实际状态对账——一个丢失的边沿过去会让它陈旧并导致 pc-ack 超时。 |
| [`828-bam-dmux-ack-stale-deassert.patch`](../../msm89xx/patches/828-bam-dmux-ack-stale-deassert.patch) | 确认一个被遗漏的 deassert 边沿，使 modem 的 `a2_task` 不会超时（`a2_task.c:3179`）。 |
| [`831-bam-dmux-defer-dma-release-to-powered-modem.patch`](../../msm89xx/patches/831-bam-dmux-defer-dma-release-to-powered-modem.patch) | 把释放 DMA 通道（它们会写 BAM 寄存器）推迟到 modem/BAM 重新上电之后——避免 AP 挂死。 |
| [`832-bam-dmux-tx-stats-uaf.patch`](../../msm89xx/patches/832-bam-dmux-tx-stats-uaf.patch) | 在 DMA 提交之前快照 `skb->len`；在完成回调之后再读它是一次 use-after-free。 |
| [`833-bam-dmux-down-ack-serialisation.patch`](../../msm89xx/patches/833-bam-dmux-down-ack-serialisation.patch) | Android 对齐：恢复（resume）会等待 modem 对 down 投票进行 ack 之后才投 up 票。**按板级限定为 HMUF02-V5。** |
| [`848-bam-dmux-a2-pin.patch`](../../msm89xx/patches/848-bam-dmux-a2-pin.patch) | 驱动对 `qcom,a2-pin` DT 属性的支持——保持 modem A2 电源域常驻存活（`pm_runtime_forbid()`）。 |
| [`850-bam-dmux-reattach-on-already-open.patch`](../../msm89xx/patches/850-bam-dmux-reattach-on-already-open.patch) | 当 modem 在没有配套 `CMD_CLOSE` 的情况下重新下发 `CMD_OPEN` 时，重新挂接 netdev（AP 未观察为 SSR 的内部重启）。 |

### 1.3 Remoteproc / modem 子系统（815、826、827）

| 补丁 | 说明 |
| :---- | :---------- |
| [`815-qcom-sysmon-ignore-wcnss-modem-ssr.patch`](../../msm89xx/patches/815-qcom-sysmon-ignore-wcnss-modem-ssr.patch) | 阻止把 modem SSR 通知转发给 WCNSS——其固件在收到 modem 关机通知时会出错。 |
| [`826-remoteproc-q6v5-mss-msm-subsys-restart.patch`](../../msm89xx/patches/826-remoteproc-q6v5-mss-msm-subsys-restart.patch) | Android 对齐的 `/sys/kernel/debug/msm_subsys/modem` 重启杠杆；同时修复 `rproc->power` 引用计数，使 `rproc_shutdown` 真正地循环重启 modem。 |
| [`827-remoteproc-q6v5-mss-gfmux-clk-src-switch-ovr.patch`](../../msm89xx/patches/827-remoteproc-q6v5-mss-gfmux-clk-src-switch-ovr.patch) | 在 GFMUX 源切换期间强制打开时钟，与下游/Android 的上电路径一致。 |

### 1.4 RPMSG（819、822、823）

| 补丁 | 说明 |
| :---- | :---------- |
| [`819-rpmsg-char-guard-null-eptdev.patch`](../../msm89xx/patches/819-rpmsg-char-guard-null-eptdev.patch) | 保护 `rpmsg_char` 免受 NULL 端点设备的影响。 |
| [`822-rpmsg-smd-drain-pollers-before-free.patch`](../../msm89xx/patches/822-rpmsg-smd-drain-pollers-before-free.patch) | 在释放 SMD 通道之前排空未完成的 poller，消除一个可能复位 AP 的 poll use-after-free。 |
| [`823-rpmsg-wwan-ctrl-no-smd-poll-registration.patch`](../../msm89xx/patches/823-rpmsg-wwan-ctrl-no-smd-poll-registration.patch) | 在不把调用者注册进 SMD 等待队列的情况下报告端点 TX 状态，去掉一个可达的 822 bug 实例（内核内的排空见 822）。 |

### 1.5 电源、复位与 EDL（813）

| 补丁 | 说明 |
| :---- | :---------- |
| [`813-msm8916-reboot-to-edl-support.patch`](../../msm89xx/patches/813-msm8916-reboot-to-edl-support.patch) | 内核支持热重启进入 Emergency Download（EDL / 9008）模式，与 `lk2nd` 的复位序列一致。 |

### 1.6 电源轨、CPR 与 CPU（818、824、834、838、841–846、849、851）

| 补丁 | 说明 |
| :---- | :---------- |
| [`818-arm64-dts-qcom-msm8916-pm8916-l13-voltage-range.patch`](../../msm89xx/patches/818-arm64-dts-qcom-msm8916-pm8916-l13-voltage-range.patch) | 把 PM8916 L13 拓宽到 3.05–3.3 V，使 USB HS PHY 能够设置其 3.3 V 供电。 |
| [`824-arm64-dts-qcom-msm8916-rpm-master-stats.patch`](../../msm89xx/patches/824-arm64-dts-qcom-msm8916-rpm-master-stats.patch) | 添加 `qcom,rpm-master-stats` 节点（APSS/MPSS/PRONTO 切片），用于 RPM 电源塌陷统计。 |
| [`834-arm64-dts-qcom-msm8916-cpu-interconnect.patch`](../../msm89xx/patches/834-arm64-dts-qcom-msm8916-cpu-interconnect.patch) | 声明 CPU→DDR 互连路径（`cpu-mem`），并带按 OPP 的带宽投票。 |
| [`838-arm64-dts-qcom-msm8916-cpu-opp-max-800mhz.patch`](../../msm89xx/patches/838-arm64-dts-qcom-msm8916-cpu-opp-max-800mhz.patch) | 移除 998.4 MHz 的 CPU OPP，把簇上限限制在 800 MHz（与 Android 对齐，电源轨电压更低）。 |
| [`841-soc-qcom-spm-v3.0-set-vdd.patch`](../../msm89xx/patches/841-soc-qcom-spm-v3.0-set-vdd.patch) | 为驱动 VDD_APC 的 APCS/L2 SAW 添加 SPM v3.0 的 VCTL/PMIC_DATA 电压寄存器接口。 |
| [`842-pmdomain-cpr-add-msm8916.patch`](../../msm89xx/patches/842-pmdomain-cpr-add-msm8916.patch) | 为主线 CPR（Core Power Reduction，核心降压）驱动添加 MSM8916 支持——即 AP 侧的 CPU 电源轨电压调节。 |
| [`843-arm64-dts-qcom-msm8916-cpr.patch`](../../msm89xx/patches/843-arm64-dts-qcom-msm8916-cpr.patch) | 为 MSM8916 添加 CPR DT 节点、QFPROM 熔丝角（fuse corners）以及 `cpr_opp_table`。 |
| [`844-dt-bindings-qcom-cpr-msm8916.patch`](../../msm89xx/patches/844-dt-bindings-qcom-cpr-msm8916.patch) | 为 MSM8916 CPR 变体扩展 `qcom,cpr.yaml` 绑定。 |
| [`845-cpufreq-qcom-nvmem-add-msm8916.patch`](../../msm89xx/patches/845-cpufreq-qcom-nvmem-add-msm8916.patch) | 把 MSM8916 注册到 `qcom-cpufreq-nvmem` 并接上 `cpr` 电源域。 |
| [`846-arm64-dts-qcom-msm8916-cpr-attach-cpus.patch`](../../msm89xx/patches/846-arm64-dts-qcom-msm8916-cpr-attach-cpus.patch) | 把各 CPU 挂接到 CPR genpd 并设置它们的 OPP 熔丝等级。 |
| [`849-arm64-dts-qcom-hmuf02v5-a2-pin.patch`](../../msm89xx/patches/849-arm64-dts-qcom-hmuf02v5-a2-pin.patch) | A2 引脚（848）的 HMUF02-V5 DTS 一侧：在 `&bam_dmux` 上设置 `qcom,a2-pin`，让驱动保持 modem A2 上电。 |
| [`851-arm64-dts-qcom-uf02-uz801-a2-pin.patch`](../../msm89xx/patches/851-arm64-dts-qcom-uf02-uz801-a2-pin.patch) | A2 引脚（848）的 UF02 + UZ801 DTS 一侧：在另外两块 HiMI 基带板的 `&bam_dmux` 上设置 `qcom,a2-pin`。 |

### 1.7 热管理（861、999）

| 补丁 | 说明 |
| :---- | :---------- |
| [`861-arm64-dts-qcom-msm8916-ufi-thermal-mitigation.patch`](../../msm89xx/patches/861-arm64-dts-qcom-msm8916-ufi-thermal-mitigation.patch) | Wi-Fi（65 °C）与 PMIC（90 °C）的热区与冷却映射，添加到**共享的** `msm8916-ufi.dtsi`，使该 target 中的每块板都获得它们。 |
| [`999-tsens-propagate-eprobe-defer.patch`](../../msm89xx/patches/999-tsens-propagate-eprobe-defer.patch) | 从 TSENS NV 校准传播 `-EPROBE_DEFER`，使热传感器在 QFPROM 晚到时能够延迟探测。 |

### 1.8 电源与电池（854–859）

PM8916 电压模式 BMS（`pm8916_bms_vm`）和线性充电器（`pm8916_lbc`）是带电池板卡（MF800B、
HM-MIFIB-V12）的电量计与充电器。上游版本既不报告可用的荷电状态（state of charge），也不报告
电池组温度，而且充电器在不切断系统电源轨的情况下无法停止充电——这六个补丁把三者全都补齐。

| 补丁 | 说明 |
| :---- | :---------- |
| [`854-power-supply-pm8916-bms-vm-report-capacity.patch`](../../msm89xx/patches/854-power-supply-pm8916-bms-vm-report-capacity.patch) | 从电压推导 `CAPACITY`——优先使用关机/挂起期间硬件捕获的开路电压（OCV，180 秒内有效），否则回退到实时电压，使估计值偏低而非偏高。 |
| [`855-power-supply-pm8916-bms-vm-report-battery-temperature.patch`](../../msm89xx/patches/855-power-supply-pm8916-bms-vm-report-battery-temperature.patch) | 读取可选的 `batt-therm` IIO 通道并报告 `TEMP`；没有该通道的板卡继续使用室温 OCV 表。 |
| [`856-iio-adc-qcom-spmi-vadc-expose-bat-therm-as-temperature.patch`](../../msm89xx/patches/856-iio-adc-qcom-spmi-vadc-expose-bat-therm-as-temperature.patch) | 把 VADC 的 `LR_MUX1_BAT_THERM` 作为温度通道暴露（内部 100 kΩ 上拉），而不是未缩放的原始电压。 |
| [`857-power-supply-pm8916-lbc-add-charge-enabled.patch`](../../msm89xx/patches/857-power-supply-pm8916-lbc-add-charge-enabled.patch) | 添加可写的 `CHARGE_ENABLED` 属性：写 0 会清除 `CHG_EN` 而 `PSTG_EN` 保持打开，使棒状设备由 VBUS 供电、电池被保持而不被充电。 |
| [`858-power-supply-pm8916-bms-vm-sample-temperature-on-demand.patch`](../../msm89xx/patches/858-power-supply-pm8916-bms-vm-sample-temperature-on-demand.patch) | 修复温度读取：`iio_read_channel_processed()` 成功时返回 `IIO_VAL_INT`（1），因此旧的非零判断丢弃了每一个好样本并停留在 25 °C。 |
| [`859-power-supply-pm8916-bms-vm-report-honest-charge-status.patch`](../../msm89xx/patches/859-power-supply-pm8916-bms-vm-report-honest-charge-status.patch) | 当充电器的 `CHARGE_ENABLED` 关闭时报告 `NOT_CHARGING`，而不是对任何在线的 VBUS 都声称 `Charging`。 |

### 1.9 其他 SoC（816）

| 补丁 | 说明 |
| :---- | :---------- |
| [`816-qcom-smsm-validate-mbox-before-request.patch`](../../msm89xx/patches/816-qcom-smsm-validate-mbox-before-request.patch) | 跳过为本地主机请求邮箱，并先校验 `mboxes` phandle，消除启动时的错误刷屏。 |

### 1.10 OpenWrt 源码补丁（openwrt-patches/）

| 补丁 | 目标 | 说明 |
| :---- | :------ | :---------- |
| [`0001-package-pack-fix-IDIR-conffiles.patch`](../../openwrt-patches/0001-package-pack-fix-IDIR-conffiles.patch) | `include/package-pack.mk` | 修复一个潜伏的 `$(...)` 计数 bug，它会在任何 package（例如 `base-files`）被重新打包时让 `make package/install` 输出 `IDIR_<pkg>: command not found`。把 `$$(IDIR_$(1))` 更正为 `$(IDIR_$(1))`，同时保留预期的 shell 命令替换以及 apk 的 `$`-ABI 分隔符。 |
| [`809-mac80211-enable-wcn36xx.patch`](../../openwrt-patches/809-mac80211-enable-wcn36xx.patch) | `package/kernel/mac80211/ath.mk` | 在 `msm89xx` target 上启用 `wcn36xx`（以及 `ath10k-sdio`）内核模块。 |
| [`810-rstrip-skip-carrier-mcfg.patch`](../../openwrt-patches/810-rstrip-skip-carrier-mcfg.patch) | `scripts/rstrip.sh` | 把附带的运营商 MCFG blob 排除在 `rstrip` 之外——它们是 modem 固件（`\x7fELF`），不是 AP 可执行文件，剥离会损坏它们。 |
| [`811-wifi-sta-guard-phy-restart.patch`](../../openwrt-patches/811-wifi-sta-guard-phy-restart.patch) | `package/network/config/wifi-scripts/` — **同时**包括 `files/lib/netifd/wireless/mac80211.sh`（shell）和 `files-ucode/lib/netifd/wireless/mac80211.sh`（ucode） | **使 Station Mode 运行期间重启 radio 成为安全操作。** `setup()` 用 `wifi-sta-guard down` … `wifi-sta-guard up` 把驱动启动包裹起来，`teardown()` 则调用 `wifi-sta-guard down`。Station Mode 不是 `wifi-iface`，因此 netifd 过去会在活跃的 `wpa_supplicant` 底下重启 phy，导致 WCNSS 固件崩溃（`boot_exception_c_handlers.c:108: Data Abort Exception at 0x8b6b301c`）。**两个驱动都被打了补丁**，因为当 `CONFIG_WIFI_SCRIPTS_UCODE=y`（默认值，也是本 target 的构建方式）时 wifi-scripts 会用 `files-ucode/` 覆盖 `files/`——只给 shell 驱动打补丁会悄无声息地不起任何作用。参见 [Docs/WiFi/](../WiFi/)。 |

---

### 1.11 OpenWrt package 补丁（`openwrt-overlay/`）

这些是针对各个 OpenWrt **package**（以及宿主工具）的补丁。它们位于
[`openwrt-overlay/`](../../openwrt-overlay/)，由 `build.sh`
（`cp -a openwrt-overlay/. openwrt/`）在 package 构建**之前**合并进树中，从而遮蔽或扩展开源的
package 源码。由于合并不做删除，被改名/移除的补丁必须手工从已准备的树中删除（见
`Docs/PATCHES_AND_PACKAGING.md` 第 2 节）。

#### 1.11.1 wcn36xx Wi-Fi 驱动修复（`package/kernel/mac80211/patches/ath/`）

| 补丁 | 说明 |
| :---- | :---------- |
| [`450-wcn36xx-only-send-mc-list-when-sta-associated.patch`](../../openwrt-overlay/package/kernel/mac80211/patches/ath/450-wcn36xx-only-send-mc-list-when-sta-associated.patch) | 仅在 STA 关联之后才把组播（MC）地址表推送给固件——避免在关联之前设置该列表时引发固件警告/崩溃。 |
| [`451-wcn36xx-mfp-wpa3.patch`](../../openwrt-overlay/package/kernel/mac80211/patches/ath/451-wcn36xx-mfp-wpa3.patch) | 为 wcn36xx 添加管理帧保护（MFP）/ WPA3 支持。 |
| [`452-wcn36xx-iface-combinations.patch`](../../openwrt-overlay/package/kernel/mac80211/patches/ath/452-wcn36xx-iface-combinations.patch) | 声明 AP+STA 并发接口组合，使芯片能够在 AP 之外同时运行 station 模式。 |
| [`453-wcn36xx-thermal-mitigation.patch`](../../openwrt-overlay/package/kernel/mac80211/patches/ath/453-wcn36xx-thermal-mitigation.patch) | 把固件的热缓解状态作为 Linux 冷却设备暴露。**已 rebase 到 backports 6.18.55（针对 25.12.6）**（hunk 2 增加了 `WCN36XX_HAL_SET_THERMAL_MITIGATION_RSP` 分支）。 |
| ~~454~~ … ~~457~~ | **在 25.12.6 中被移除——现已进入上游。** Backports 从 6.18.26 升到 6.18.55 并吸收了全部四个：HAL 响应长度检查（`HAL response too large`，smd.c:3403）、print-reg-info 截断保护（smd.c 约 2870 行）、trigger-BA 长度检查（smd.c:2661）以及 TX-ack 定时器关闭（`timer_shutdown_sync(&wcn->tx_ack_timer)`，dxe.c:1058）。它们已从 overlay 中删除；保留它们会让整个补丁系列应用失败。 |
| [`458-wcn36xx-bmps-concurrency-guard.patch`](../../openwrt-overlay/package/kernel/mac80211/patches/ath/458-wcn36xx-bmps-concurrency-guard.patch) | 保护 BMPS（省电）状态机免受并发启用/禁用的影响。 |
| [`459-wcn36xx-rx-survey-null-band.patch`](../../openwrt-overlay/package/kernel/mac80211/patches/ath/459-wcn36xx-rx-survey-null-band.patch) | **修复一个 kernel PANIC**（当 2.4 GHz-only WCN 在 vif 拆除时 `wiphy->bands[band]` 为 NULL 且 chandef 陈旧，RX survey 路径发生 NULL 解引用）。**已实机验证**，刷入 `c1216b14`，此后零 panic。 |
| [`460-wcn36xx-scan-timeout.patch`](../../openwrt-overlay/package/kernel/mac80211/patches/ath/460-wcn36xx-scan-timeout.patch) | **修复一个永久性 station 中断**：`wcn->scan_req` 只会被固件扫描指示清除，因此一次未应答的扫描会让之后每次扫描都返回 `-EBUSY`（wpa_supplicant: `CTRL-EVENT-SCAN-FAILED ret=-16` 永远持续），直到模块被重载。它在启动失败时清除该请求，添加一个 15 秒超时自行完成扫描，并在指示到来 / `wcn36xx_stop()` 中取消。参见 `Docs/WiFi/WCN36XX_MEMORY_CORRUPTION_INVESTIGATION.md` §7。 |

#### 1.11.2 其他 package / 宿主工具补丁

| 补丁 | 目标 | 说明 |
| :---- | :----- | :---------- |
| [`900-wpa-cli-dispatch-ssid-temp-disabled.patch`](../../openwrt-overlay/package/network/services/hostapd/patches/900-wpa-cli-dispatch-ssid-temp-disabled.patch) | `hostapd` | 当客户端因错误 PSK 而 WPA 失败时，hostapd 派发一个 `SSID-TEMP-DISABLED` 事件，使 `wifi-sta-wpa-event` 能标记出错误凭据（驱动 LuCI 红色警报）。 |
| [`0001-block-skip-nonexistent-fstab-in-config-try-load.patch`](../../openwrt-overlay/package/system/fstools/patches/0001-block-skip-nonexistent-fstab-in-config-try-load.patch) | `fstools` | 在 config-try-load 时跳过不存在的 fstab 条目（路由器闪存存储的健壮性）。 |
| [`100-aarch64-use-sys-uio.patch`](../../openwrt-overlay/tools/elfutils/patches/100-aarch64-use-sys-uio.patch) | `tools/elfutils` | 构建修复：在 aarch64 上包含 `<sys/uio.h>`。 |
| [`001-fix-pdc-load-config-segfault.patch`](../../openwrt-overlay/feeds/packages/libs/libqmi/patches/001-fix-pdc-load-config-segfault.patch) | `libqmi` | 修复加载 PDC（carrier）配置时的段错误。 |
| [`002-qmicli-pdc-chunk-256.patch`](../../openwrt-overlay/feeds/packages/libs/libqmi/patches/002-qmicli-pdc-chunk-256.patch) | `libqmi` | 把 PDC 配置上传拆分为 256 字节块（与 modem PDC 加载器互操作）。 |

### 1.12 自定义 packages（`packages/`）

26 个用户态应用与 LuCI 模块。`build.sh` 把每个 `packages/<name>/` 复制到
`openwrt/package/msm8916/<name>/`（并把任何 `packages/<name>/patches/` 复制到对应的
上游 package）。除非另有说明，所有这些都是**仅下游**的。

| Package | 用途 |
| :------ | :------ |
| `ats-probe` | 通过 QMI 读取 modem 的 ATS_RTC 运行时长（真正的 modem 运行时长）——为 SSR/看门狗检测提供数据。 |
| `bt-spp` | 蓝牙串口规范（SPP）服务器/客户端，用于经蓝牙的串口访问。 |
| `bt-ssp-guard` | 保护 WCNSS 蓝牙 Secure Simple Pairing 特性位。 |
| `cups` | 面向 USB 打印机的通用 UNIX 打印系统服务器守护进程（`cupsd`）。 |
| `diag-bind` | 把 SMD DIAG 端点绑定到 `rpmsg_chrdev`（创建 `/dev/rpmsg0`、`/dev/rpmsg1`）。 |
| `diag-efs` | 经由 SMD DIAG 通道读/写 modem EFS（实时解密）。 |
| `diag-logtool` | Qualcomm DIAG 客户端：F3 日志掩码、捕获以及经 SMD DIAG 的监听。 |
| `luci-app-battery` | LuCI：电池状态、充电限制与电池 LED。 |
| `luci-app-cpu-perf` | LuCI：CPU 性能信息与管理。 |
| `luci-app-firmware-upgrade` | LuCI：设备内固件升级页面（检查 `firmware.json`、下载、校验、刷写；保留设置或 `-n`）。 |
| `luci-app-modem-watchdog` | Modem Watchdog 的 LuCI 支持。 |
| `luci-app-sms-manager` | 通过 ModemManager 的 LuCI 短信管理。 |
| `luci-app-tailscale` | Tailscale 的 LuCI。 |
| `luci-app-update-notify` | LuCI：当 `apk` 有 package 更新时在仪表盘提示（6 小时轮询，尊重 pins）。 |
| `luci-app-usb-gadget` | USB Gadget Manager 的 LuCI。 |
| `luci-theme-feelgood` | Feelgood LuCI 主题（登录页 CSS 以未压缩形式交付）。 |
| `luci-app-wifi-sta` | 并发 Station Mode（AP+STA）的 LuCI。 |
| `msm-firmware-dumper` | Qualcomm 固件分区转储工具（modem/WCNSS）。 |
| `msm89xx-firmware-upgrade` | 升级页面背后的 CLI：`check`/`download`/`apply [--no-keep]`/`upgrade`。 |
| `msm89xx-scripts` | 用户态板级支持：modem/Wi-Fi LED 监视器、开机闪烁、station 模式辅助程序。 |
| `qcom-carrier-autocfg` | SIM 运营商自动配置引擎——从插入的 SIM 中选择/激活 MCFG/PDC 运营商配置（Jio/MCFG 可用）。 |
| `qcom-time-daemon` | QMI 时间同步守护进程——从蜂窝网络设置系统时间。 |
| `qrtr` | Qualcomm IPC Router 用户态库（DIAG/RMTFS/tqft 的传输层）。 |
| `reboot-edl` | 安全地把 SoC 重启进 EDL / DLOAD / Fastboot 模式（封装内核的 EDL 支持）。 |
| `rmtfs` | Qualcomm Remote Filesystem 服务守护进程（经 QRTR 为 modem 提供 EFS 服务）。 |
| `uci-usb-gadget` | 基于 UCI 的 USB gadget 管理器（配置 ethernet/serial USB 功能）。 |

### 1.13 BSP / 板级支持（`msm89xx/`）

板级支持层**不是**单个补丁，而是一个 `msm89xx/` 目录，`build.sh`
把它复制到 `target/linux/msm89xx`（并把 `base-files/` 合并进 rootfs）。它包含：

| 组件 | 角色 |
| :-------- | :--- |
| `patches/` | 第 1.1-1.9 节记录的内核补丁（复制到 `target/linux/msm89xx/patches/`）。 |
| `base-files/` | 随 rootfs 交付的文件：`etc/apk/repositories.d/customfeeds.list`（上游 25.12.x feeds）、`etc/apk/keys/*`（我们的签名密钥 + `openwrt-25.12.pem`）、init 脚本（`himi-ok-guard`、`modem-bearer-watchdog`）、failsafe USB gadget 以及提交钩子。 |
| `image/` | 镜像生成（受支持的板型、recovery 镜像组装）。 |
| `config-6.12` | 生产构建的内核配置。`config-6.12-recovery` 属于**遗留/未使用**：recovery 镜像不再构建内核，而是复用生产内核（见 `build-recovery.sh`）。 |
| `modules.mk` | 该 target 的内核包（`kmod-*`）定义。 |
| `msm8916/` | 共享的 SoC 级 DTS/构建片段。 |
| `recovery/` | 无界面的 recovery initramfs（USB gadget + dnsmasq + dropbear）。 |
| `Makefile` | target makefile（设备/profile 定义）。 |

> 设备树本身（801-807、852、853）是 `msm89xx/patches/` 中的内核补丁，
> 不属于这个 BSP 目录。

---

## 2. 详细技术剖析

### 2.1 设备树 — 板级启用

#### 801：设备树 Makefile 注册
- **目标**：`arch/arm64/boot/dts/qcom/Makefile`
- **用途**：上游内核 Makefile 没有列出我们的通用 4G 加密狗
  target。这会把它们加入 `dtb-$(CONFIG_ARCH_QCOM)`：
  ```makefile
  dtb-$(CONFIG_ARCH_QCOM) += msm8916-generic-hmuf02v5.dtb
  dtb-$(CONFIG_ARCH_QCOM) += msm8916-generic-uf02.dtb
  dtb-$(CONFIG_ARCH_QCOM) += msm8916-generic-ufi001b.dtb
  dtb-$(CONFIG_ARCH_QCOM) += msm8916-generic-ufi003_mb_v02.dtb
  dtb-$(CONFIG_ARCH_QCOM) += msm8916-generic-mf800b.dtb
  dtb-$(CONFIG_ARCH_QCOM) += msm8916-generic-mifib-v12.dtb
  ```

#### 802：MSM8916 保留内存节点标签
- **目标**：`msm8916.dtsi`
- **用途**：上游把 `reserved-memory` 定义为匿名节点。板级 DTS 文件
  需要追加 `ramoops` 缓冲区，因此这里添加 phandle 标签：
  ```dts
  -	reserved-memory {
  +	reserved_memory: reserved-memory {
  ```

#### 803：UZ801V3 LED 功能
- **目标**：`msm8916-yiming-uz801v3.dts`
- **用途**：赋予 `LED_FUNCTION_WLAN`（蓝色，GPIO 6）和
  `LED_FUNCTION_WAN`（绿色，GPIO 8），使 OpenWrt 的 LED 监视器和 `uci`
  触发器在各板型变体上一致地识别这些指示灯。

#### 804：通用 UF02 板设备树
- **目标**：`msm8916-generic-uf02.dts`
- **Compatible**：`"uf02,250605v0s", "qcom,msm8916"`
- **用途**：GPIO 23 上的复位按键（高电平有效，下拉）以及三色
  状态 LED——红色（GPIO 72）、绿色（GPIO 71，WAN）、蓝色（GPIO 73，WLAN）。

#### 805：通用 HMUF02-V5 板设备树
- **目标**：`msm8916-generic-hmuf02v5.dts`
- **Compatible**：`"hmuf02v5,250605v0s", "qcom,msm8916"`
- **用途**：
  1. **Ramoops**：位于 `0x8db00000` 的 1 MB（256 KB record / 256 KB console / 256 KB pmsg）。
  2. **复位键**：GPIO 37（`key_freset`，高电平有效，下拉）。
  3. **LED**：绿色 GPIO 71（WLAN）、红色 GPIO 72（POWER）、蓝色 GPIO 73（WAN）。
  4. 用于 SIM 路由/供电的 **GPIO hogs**：`sim1_en`（GPIO 119，高）、`sim2_en`
     （GPIO 14，低）、`sim3_en`（GPIO 12，低）、`sim_hotplug`（GPIO 114）、
     `bat1`（GPIO 36）、`ftest`（GPIO 106）。

#### 806：通用 UFI001B 板设备树
- **目标**：`msm8916-generic-ufi001b.dts`
- **用途**：
  1. **Ramoops**：位于 `0x8db00000` 的 1 MB。
  2. **复位键**：GPIO 37（`key_freset`，高电平有效，下拉）。
  3. **LED**：红色 GPIO 22（POWER）、绿色 GPIO 21（WAN）、蓝色 GPIO 20（WLAN）。
  4. **GPIO hogs**：`sim_en`（GPIO 1）、`sim_sel`（GPIO 2）、`4G_L3`（GPIO 68）。

#### 807：通用 MF800B 板设备树
- **目标**：`msm8916-generic-mf800b.dts`
- **用途**：MF800B 棒状设备的板级 DTS：一块 2100 mAh / 4.35 V 锂聚合物电池的
  电量计（出厂 `qcom,v-cutoff-uv` 为 3.35 V，无 `ocv-capacity-table`）、位于
  `0x8bd00000–0x8dbfffff` System RAM 范围顶部的同一 ramoops 区域、GPIO 102 上的
  复位按键（高电平有效，下拉），以及三个高电平有效的
  双色 LED（Wi-Fi 绿色 GPIO 73 / 红色 GPIO 84，
  Cellular 绿色 GPIO 85 / 红色 GPIO 72）。

#### 852：通用 UFI003_MB_V02 板设备树
- **目标**：`msm8916-generic-ufi003_mb_v02.dts`
- **Compatible**：`"ufi003,mb-v02", "qcom,msm8916"`
- **用途**：基于 `msm8916-ufi.dtsi` 构建的 UFI003_MB_V02 棒状设备板级 DTS：
  1. **Ramoops**：位于 `0x8db00000` 的 1 MB（256 KB record / console / pmsg）。
  2. **复位键**：GPIO 37，高电平有效带下拉——与 UF02、UFI001B 和
     HMUF02-V5 的接线相同。
  3. **LED**：WAN 绿色 GPIO 21、WLAN 蓝色 GPIO 20、POWER 红色 GPIO 22
     （默认点亮）。共享的 `led-r`/`led-g`/`led-b` 节点会先被删除，
     使通用 LED 脚本回退到各自的颜色默认值。
  4. 用于 SIM 路由的 **GPIO hogs**：`esim_sel`（GPIO 0，低）、`sim_en`
     （GPIO 1，低）、`sim_sel`（GPIO 2，高）、`esim2_sel`（GPIO 3，低）、
     `lte_aux`（GPIO 68，低）。

#### 853：通用 HM-MIFIB-V12 板设备树
- **目标**：`msm8916-generic-mifib-v12.dts`
- **Compatible**：`"mifib-v12,generic", "qcom,msm8916"`
- **用途**：HM-MIFIB-V12 加密狗的板级 DTS——项目的第二块
  电池板（继 MF800B 之后），也是唯一一块具备完整电池
  指示灯组的：
  1. **电池**：面向 4.2 V / 2150 mAh 电池组的 `simple-battery`（出厂
     `qrd_4v2_2000mah`）：3.35–4.2 V、1 A 恒流充电、100 mA 截止电流，
     外加出厂的 OCV→荷电状态表。**不要照搬 MF800B 的 4.35 V
     数值**——这是 4.2 V 电芯。
  2. **充电器**：带 `monitored-battery` 的 `pm8916_lbc`，快充限制在
     4.2 V / 1 A；`pm8916_usbin` 被禁用，因为 VBUS 检测归 LBC 所有。
  3. **电量计**：带 `monitored-battery`、`power-supplies` 的 `pm8916_bms`，
     以及接在 `batt-therm` 上的电池组热敏电阻（VADC `LR_MUX1_BAT_THERM`）。
  4. **VADC**：热敏电阻的 `channel@30`，比率式，16 ms 稳定时间。
     `qcom,hw-settle-time` 单位是微秒，且绑定只接受
     100 µs 的整数倍（≤1000）或 2000 µs（>1000）：这里最初写的无效 `<10>`
     使整个 VADC 探测以 `-EINVAL` 失败，进而让
     BMS 没有热敏电阻。请使用 `<16000>`。
  5. **LED**：双色 WLAN（绿色 GPIO 73 / 红色 GPIO 84）和 WAN
     （绿色 GPIO 85 / 红色 GPIO 72）、4 格电量计（`green:bat` GPIO 0、
     `red:bat` GPIO 1、`batl3` GPIO 91、`batl4` GPIO 100）以及 `ftest`（GPIO 32，
     `default-state = "keep"`）。全部为 `retain-state-suspended`。
  6. **复位键**：GPIO 102，**低电平有效带上拉**——与
     MF800B/HMUF02-V5 的接线相反，因此不要照搬它们的高电平有效/下拉标志。
  7. **GPIO hogs**：`sim1_en`（GPIO 119，高）、`sim2_en`（GPIO 112，低）、
     `sim3_en`（GPIO 12，低）。
  8. **热管理**：复用 HMUF02-V5 的缓解映射（Wi-Fi 65 °C、PMIC 90 °C）——
     同一 SoC，同样的冷却设备。
  9. **A2 引脚**：`&bam_dmux { qcom,a2-pin; }`。该板搭载与 HMUF02-V5/UF02/UZ801
     相同的 HiMI V1.0 基带，因此获得同样的 modem 保持。

#### 867：通用 UF896（v1.1）板设备树
- **目标**：`msm8916-generic-uf896.dts`
- **Compatible**：`"uf896,v1.1", "qcom,msm8916"`
- **用途**：基于 `msm8916-ufi.dtsi` 构建的 UF896 v1.1 4G LTE 路由器
  板级 DTS：
  1. **Ramoops**：位于 `0x8db00000` 的 1 MB（256 KB record / console / pmsg）——
     最初的 PR #1 提交遗漏了它；此处恢复以与其他每块板一致。
  2. **复位键**：GPIO 35，**低电平有效**带上拉（UF02 /
     HMUF02-V5 / UFI001B 家族的接线）。
  3. **状态 LED**：`led_r` GPIO 8、`led_g` GPIO 9、`led_b` GPIO 10，全部
     高电平有效并作为 `LED_FUNCTION_STATUS` 暴露。
  4. **额外指示 LED**（`leds-extra`）：充电器蓝色 GPIO 77 / 红色
     GPIO 78、网络蓝色 GPIO 81 / 红色 GPIO 82、Wi-Fi 绿色 GPIO 83 以及
     数据链路蓝色 GPIO 84。
  5. **无 SIM GPIO hog；A2 引脚已启用**：卡槽 1 是 modem 的默认选择，因此
     不交付用户态 SIM 辅助程序。该板**确实**会触发 A2 静默
     卡死——现场日志显示 `a2_power.c:1216` 出现在约 930 s，之后每
     70–130 s 崩溃循环一次——因此补丁 `867` 在 `&bam_dmux` 上设置
     `qcom,a2-pin`，与其他 HiMI 家族板卡一致。
- **板级启动怪癖**：modem 以 DMS 操作模式 `factory-test` 启动
  （RF 被禁用，无法注册）。`etc/init.d/uf896-modem-online`
  （START=60，先于 70 的 ModemManager）等待 `/dev/wwan0qmi0` 并运行
  `qmicli --dms-set-operating-mode=online`。

### 2.2 BAM-DMUX 网络驱动

驱动位于 `drivers/net/wwan/qcom_bam_dmux.c`（本集群的全部补丁）。
这些修复相互关联，反映了一次关于 AP↔modem 数据通路为何在 A2 电源塌陷和
modem 重启之后中断的长期调查。

#### 808：统计与干净关机
上游 `bam_dmux` 漏掉了包/字节计账（LuCI / `ip -s link`
报告为 0）。这为 tx/rx 包和字节添加了 `DEV_STATS_INC/ADD`，并在
断电时释放待发的 TX skb 并清除通道位图，使 DMA 缓冲区不泄漏、
通道状态不被破坏。

#### 809：TX 电源管理顺序
runtime-PM 引用必须在预留 TX 槽位**之前**获取。
`pm_runtime_get_sync()` 可能会运行 `bam_dmux_runtime_resume()`，后者
会把 `SMSM_A2_POWER_CONTROL` 投为高；modem 随后拉高 A2，
`bam_dmux_pc_irq()` → `bam_dmux_pm_restart()` 释放每一个 `tx_skbs[]` 槽位。如果
先预留了槽位，skb 就会在这个函数执行期间被释放，
`bam_dmux_skb_dma_map()` 将解引用 NULL 的 `skb_dma->skb`。

#### 810：TX 扫描竞态防护
A2 电源塌陷扫描可以在 `start_xmit()` 位于
`bam_dmux_tx_queue()` 与映射调用之间时把 TX 槽位置 NULL，因为 `start_xmit` 不持有
`state_lock`。由于扫描同时也释放了该 skb，该补丁会干净地
失败而不是解引用 NULL，并统计每一次被阻止的崩溃。

#### 811：延迟 TX 遥测
延迟 TX 路径的诊断信息——统计有多少延迟包被
排队、真正提交，以及带着活跃 skb 被丢弃。这用数据
回答了在 resume 进行过程中被延迟的包是否曾经到达
BAM。

#### 812：保留延迟 TX
一个延迟槽位只做了 DMA 映射，从未提交，因此静默流程从来
没有属于自己的描述符可以终止——该映射对于
重建后的通道仍然有效。释放它们（旧行为）丢弃的正是
`start_xmit()` 刚刚延迟、而等待的恰恰是执行这次释放的
那次唤醒的包。修复前实测：27 个延迟，27 个带着活跃 skb 被抹掉，0
个被提交。

#### 814：SSR 上电重试
第一次上电尝试轮询 modem 的 A2 线 3200 ms——足以应对
热重启，但不足以应对完整的固件重载（实测约 5.9 s）。超时后
该 work 返回且再也不运行，使 `wwan0` 一直宕着直到重启。这添加了
有界的重试（`BAM_DMUX_SSR_POWERUP_MAX_RETRIES 20`，额外约 77 s）。

#### 820：SSR 拆解非阻塞取消
`bam_dmux_power_off()` 总是在持有 `state_lock` 的情况下到达；同步
取消 `rx_watchdog_work`（它需要 `state_lock`）会造成 ABBA 死锁。看门狗
取消被改为非阻塞（它会在锁下重新检查）；
`rx_rearm_work` 保持同步，因为它不获取 `state_lock`。

#### 821：SSR 拆解在断电之前冲刷
`rproc_stop()` 触发 `BEFORE_SHUTDOWN` 通知器，然后在数十毫秒之后
关闭 modem 电源。拆解 work 会终止并**释放**
BAM-DMUX DMA 通道，而 BAM 位于 modem 的电源域中。若保持
异步，释放会与断电竞争；该补丁让拆解执行到
完成之后 `rproc_stop()` 才继续。

#### 825：把 `pc_state` 与总线对账
`pc_state` 只跟踪 `pc_irq` 边沿，因此一个丢失的边沿会让它在
modem 塌陷时保持陈旧的高电平，而分支逻辑从不读取总线。这
是发生率最高的一类 pc-ack 超时（恢复中占 40 %，而总线为高时仅
2.3 %）。该补丁信任总线：它清除缓存的边沿，
并由 resync 路径在 `state_lock` 下重新读取该线。

#### 828：确认一个陈旧的 deassert
如果 deassert 确实发生了（总线为低）但 `pc_irq()` 错过了该
边沿，AP 的 ack 翻转就会少一次。modem 永远看不到它的 deassert
被 ack，它的 `a2_task` 会等待，并在约 15 秒后拉高（`a2_task.c:3179`）。
实测：8 例 `a2_task.c:3179` 致命错误中，全部 8 例都在陈旧边沿之后
15.0–25.7 秒发生。该补丁在 `state_lock` 下重新检查并 ack。

#### 831：把 DMA 释放推迟到 modem 上电之后
`dma_release_channel()` → `bam_free_chan()` 会写 BAM 寄存器，而 BAM
位于 modem 的电源域（`qcom,powered-remotely`）。SSR 拆解
总是在 modem 塌陷的情况下运行，因此在那里释放会与 BAM
断电竞争，而对未上电 BAM 的一次寄存器访问会卡死 AP。释放
被推迟到 `bam_dmux_power_on()`。

#### 832：TX 统计 use-after-free
一旦 DMA 被提交，完成回调可以在计账运行之前
释放 skb；此时读取 `skb->len` 就是一次 use-after-free（实测：
一个被释放的 skb 被计账约 4 GB）。该补丁在 skb 仍被
拥有时快照该长度。

#### 833：Down-Ack 串行化（按板级限定为 HMUF02-V5）
Android 对齐（`bam_dmux.c ul_wakeup()`）：在 HMUF02-V5 上，恢复会等待
modem 对 down 投票进行 ack 之后才投 up 票。一个由
`bam_dmux_runtime_suspend()` 置位、由 `bam_dmux_runtime_resume()` 清除的标志把关
这次等待。通过
`of_machine_is_compatible("hmuf02v5,250605v0s")` **限定为 HMUF02-V5**，
因为 UFI001B 共享同一基带产品线但并不表现出该致命问题。

#### 848：按板级限定的 A2 引脚
添加 `qcom,a2-pin` DT 属性。当置位时，驱动会在 `&bam_dmux` 上调用
`pm_runtime_forbid()`（永远保持 `power/control=on`），使
modem 的 A2 电源域保持存活。它从 `bam_dmux_netdev_open()` 应用，
此时设备已是 runtime-ACTIVE，因此 forbid 的 resume 是空操作。

#### 849：HMUF02-V5 DTS A2 引脚
848 的设备树一侧：为 HMUF02-V5 板在 `&bam_dmux` 上
设置 `qcom,a2-pin`。它的 modem（`HIMI_U01_MODEM_V1.0`）在 AP
释放 A2 电源投票之后再拉高时，会把内部 A2 静默握手
卡死在 `a2_power.c:1189`；保持该域常开就是变通办法。UF02 和 UZ801 在
补丁 851 中设置同一属性，HM-MIFIB-V12 在补丁 853 中设置；UFI001B 和
MF800B 不设置，保持正常的 runtime suspend。

#### 851：UF02 + UZ801 DTS A2 引脚
把 849 的 A2 引脚扩展到同一 HiMI 基带产品线上的另外两块板——
UF02（`HIMI_U01_MODEM_V1.0`，与 HMUF02-V5 相同）和 UZ801（同一 HiMI 家族）。
两者都会暴露在完全相同的 `a2_power.c:1189` 静默卡死之下，因此两者都在
`&bam_dmux` 上设置 `qcom,a2-pin`（HM-MIFIB-V12 在它自己的板级文件中设置，见补丁
853）。UFI001B（modem `MPSS.DPM.2.0.2`，V2.0）和 MF800B 则留在正常的
runtime-suspend 路径上。

#### 850：已打开时重新挂接
如果 modem 在没有配套 `CMD_CLOSE` 的情况下重新下发 `CMD_OPEN`
（例如在 AP 未观察为 SSR 的一次内部重启之后），
通道可能已被标记为打开。netdev 仍然可以被摘除；直接退出会留下
被摘除的 netdev 并悄悄杀死数据通路。`netif_device_attach()` 和
netdev 注册 work 是幂等的，因此该补丁会重新运行它们。

### 2.3 Remoteproc / modem 子系统

#### 815：Sysmon 忽略 WCNSS modem SSR
WCNSS 固件没有实现 modem SSR 事件处理，收到 modem 关机通知时会出错。
该补丁跳过这些通知：
```c
if (!strcmp(sysmon->name, "wcnss") && !strcmp(sysmon_event->subsys_name, "modem"))
    return NOTIFY_DONE;
```

#### 826：Android 对齐的干净重启接口
Android 的 `subsystem_restart` 框架暴露 `/sys/kernel/debug/msm_subsys/<name>`；
写入 `restart` 会关闭子系统并从 workqueue 把它重新上电。
主线没有等价物——唯一的杠杆是同步的 `remoteproc0/state` 文件，
其停止路径会把调用者阻塞在 q6v5 强制停止握手之内
（并且可能被 PMIC 看门狗捕获）。这为 modem 提供了
非阻塞的节点。
- **引用计数修复**：当 `rproc->power > 1` 时该杠杆会悄悄变成空操作（一次多余的
  重复 `start` 会把它抬高，而 `rproc_boot` 即使短路也会增加它）。
  该补丁在 `rproc_shutdown` 之前执行 `atomic_set(&rproc->power, 1)`，
  使引用计数被抬高的重启真正地循环重启 modem。

#### 827：GFMUX 时钟源切换覆盖
与下游/Android 的 q6v56 上电路径一致，后者在源切换期间
强制打开时钟。实机 Android 的 `GFMUX_CTL` 读到 `BIT(1)|BIT(8)`；
该补丁记录 bootloader 的值以便解读。

### 2.4 RPMSG

#### 819：防护 NULL 端点设备
当端点设备为 NULL 时从 `rpmsg_char` 提前返回。

#### 822：释放之前排空 SMD poller
阻塞在 rpmsg 端点上 `poll()`/`ppoll()` 的任务持有一个
链接在 `channel->fblockread_event` 中的 `poll_table_entry`；
它只有在被唤醒的任务再次被调度后才由
`poll_freewait()` 摘链。`device_for_each_child()`
会唤醒它但不等待，而释放通道的边沿释放回调
在几行之后同步运行——于是在 poller 仍指向该通道时
通道就被释放，`poll_freewait()` 遍历的是已回收的内存。
该补丁添加了一个排空屏障。

#### 823：rpmsg_wwan_ctrl 不注册 SMD poll
在不把调用者注册进 SMD 等待队列的情况下报告端点的
TX 状态，从而无需内核崩溃即可去掉一个可达的 822
use-after-free 实例（内核内的排空见 822）。

### 2.5 电源、复位与 EDL

#### 813：Emergency Download（EDL / 9008）模式
从 `reboot edl`/`reboot dload` 启用热重启进入 EDL，
复刻 `lk2nd` 的复位序列：
1. **IMEM cookies**：在 `0x08600FE0` 写入
   `0x444C4F57`/`0x12345678`/`0x56781234`。
2. **TCSR boot detect**：`qcom_scm_set_edload_mode()` 置位
   `TCSR_BOOT_MISC_DETECT`（`0x193D100`）的 bit 0。
   注意：**绝不能**使用 `QCOM_DLOAD_FULLDUMP` 路径——Linux 把它编码到
   bits[5:4]（0x10），而 MSM8916 PBL 检查的是 bit[0]（0x01）。
3. **PM8916 PON**：热复位配置，清除 PMIC 看门狗。
4. **PMIC arbiter halt**：SCM 服务 `0x9`，命令 `0x1`（重试命令 `0x2`）。
5. **PS_HOLD assert**：以系统关闭优先级 130 写入 0。

### 2.6 电源轨、CPR 与 CPU

#### 818：PM8916 L13 电压范围
`phy-qcom-usb-hs.c` 调用 `regulator_set_voltage_triplet(v3p3, 3050000, 3300000, 3300000)`。
`v3p3-supply` 是 PM8916 `l13`，被配置为固定 3.075 V
（`min == max`），因此 regulator core 以
`l13: voltage operation not allowed` 拒绝该请求。该补丁把约束拓宽到
3.05–3.3 V（在物理 PLDO 范围之内）。

#### 824：RPM Master Stats
添加带 APSS/MPSS/PRONTO 切片的 `qcom,rpm-master-stats` 节点。基准
事实来自出厂 HMUF02-V5 DTS：`qcom,rpm-master-stats@60150`，
`qcom,master-offset = <0x1000>`，`qcom,masters = "APSS","MPSS","PRONTO"` →
`0x60150`/`0x61150`/`0x62150`（步长 `0x1000`，记录 `0x50` =
`sizeof(struct rpm_master_stats)`）。

#### 834：CPU 互连
声明 `interconnects = <&bimc MASTER_AMPSS_M0 &bimc SLAVE_EBI_CH0>`，
`interconnect-names = "cpu-mem"`，以及按 OPP 的 `opp-peak-kBps` 投票
（3.2 GB/s 和 8.528 GB/s）。注意：在 MSM8916 上 CPU→DDR 总线
只有 RPM 能控制；从 AP 这边这是一次投票而非控制
（见 DDR 调查文档）。

#### 838：把 CPU 限制在 800 MHz
移除 998.4 MHz 的 OPP，使簇最高到 800 MHz，
与 Android 的 OPP 最大值一致，并让 CPU 电源轨保持在更低电压。

#### 841：SPM v3.0 Set VDD
添加 APCS/L2 SAW 的电压寄存器接口。SAW v3.0 的 VCTL /
PMIC_DATA_3 选择器就是原始的 PMIC VSET 值：对 PM8916 S2
（VDD_APC）所用的 ULT_HF 范围，`vlevel = (uV - 375000) / 12500`
（1.15 V → 62 / `0x3e`）。位于 `0xb012000` 的 APCS/L2 SAW
是驱动共享 VDD_APC 轨的主机；其 SPM 序列归 PSCI 固件所有，
因此只触及电压寄存器（VCTL/PMIC_DATA_3，经 RST 触发并通过
PMIC_STS 轮询）。

#### 842：MSM8916 的 CPR
MSM8916 使用单一 APC 电源轨（PM8916 S2，由 SAW/SPM 控制），
带三个 CPR 熔丝角。每芯片电压位于 QFPROM 第 27 行；
没有按角的 quotient-offset 熔丝，因此偏移量由相邻
熔丝角 quotient 之差推导。环形振荡器选择熔丝为 3 位
（8 个 step-quotient 表项，全部为 26）。正是它把 CPU 电源轨从
1.15 V 降到 Android 的约 1.05 V。

#### 843：CPR DT 节点
添加 CPR 节点、QFPROM 第 27 行的熔丝单元（SVS/NORMAL/TURBO 角：每个
都是 6 位初始电压——最高位是符号位，10 mV 步进——以及 12 位目标
quotient，外加共享的 3 位环形振荡器选择）以及 `cpr_opp_table`。

#### 844：CPR 绑定
为 MSM8916 变体（`qcom,msm8916-cpr`）、
`qcom,cpr-loop-disable` 启动杠杆以及 MSM8916 熔丝单元布局（无
按角 quotient 偏移、无 revision 单元）扩展 `qcom,cpr.yaml`。

#### 845：MSM8916 的 cpufreq-nvmem
以 `genpd_names = { "cpr" }` 把 MSM8916 注册到 `qcom-cpufreq-nvmem`。

#### 846：把 CPU 挂接到 CPR
把各 CPU 挂接到 CPR genpd 并设置它们的 `qcom,opp-fuse-level`
（SVS/NORMAL）。

### 2.7 热管理

#### 847：HMUF02-V5 热缓解
WCN36XX 固件支持 `WCN36XX_HAL_SET_THERMAL_MITIGATION_REQ`（等级
0–4；1–4 逐步禁用 TX AMPDU 聚合并降低发射功率），
以 `wcn36xx` 冷却设备的形式暴露。没有专用的 WCNSS 温度
传感器，因此——像 Android 的 thermal-engine 一样——触发由
CPU 簇传感器（tsens5 / cpu0-1）在 65 °C 驱动；
PMIC 触发点在 90 °C。补丁 861 把它们放进
`msm8916-ufi.dtsi`，每块板级文件都包含它，因此所有
板卡共享同一份。

#### 999：TSENS 传播 `-EPROBE_DEFER`
`tsens_calibrate_nvmem()` 读取 QFPROM NVMEM 单元；如果提供者尚未
探测，它返回 `-EPROBE_DEFER`，驱动过去把这当作致命错误，
从而禁用 SoC 热监控。该补丁传播它，使探测延迟：
```c
ret = tsens_calibrate_nvmem(priv, 3);
if (ret == -EPROBE_DEFER)
    return ret;
```

### 2.8 电源与电池

电池路径由三个驱动组成：`pm8916_lbc`（线性充电器）、
`pm8916_bms_vm`（电压模式电量计）和 `qcom-spmi-vadc`（采样
电池组热敏电阻的 PMIC ADC）。前两者是树中用户可见电池数字的
唯一来源，而且在没有下面这些补丁的情况下，
它们在本平台上都不可用。

#### 854：BMS-VM 报告容量
VM-BMS 只有电压：没有库仑计，也没有电流检测，
因此荷电状态必须从电压推导。该补丁优先采用系统关机或
挂起期间硬件捕获的开路电压——唯一未被系统负载
扭曲的样本——并认为它在 `PM8916_BMS_VM_OCV_TIMEOUT_S`
（180 s）内有效。超过之后它回退到实时电压，
而实时电压在负载下读数偏低，因此得出的百分比是
保守（偏低）的估计而非乐观的估计。

#### 855：BMS-VM 报告电池温度
电池组热敏电阻接在 PMIC VADC 上而不是 BMS 模块上，
因此必须通过可选的 `batt-therm` IIO 通道单独采样。
当节点没有提供该通道时，驱动只是不报告温度并
继续使用室温 OCV 表——没有热敏电阻的板卡不会被
这个补丁弄坏。

#### 856：VADC 把电池热敏电阻暴露为温度
`LR_MUX1_BAT_THERM` 此前以 `VADC_CHAN_NO_SCALE` 注册，
即作为原始电压。它接在内部 100 kΩ 上拉上，
这恰好是下游"比率式 + therm 缩放函数"这一对所描述的，
因此该通道被改为 `VADC_CHAN_TEMP(..., SCALE_THERM_100K_PULLUP)`，
用户态直接读取毫摄氏度。

#### 857：LBC 添加 `CHARGE_ENABLED`
充电器过去无法在不切断系统供电的情况下停止充电。
这添加了可写的 `POWER_SUPPLY_PROP_CHARGE_ENABLED` 属性
（外加其 sysfs 属性）：写 0 会清除 `CHG_EN` 而 `PSTG_EN`
保持使能，于是棒状设备继续由 VBUS 供电，电池只是被
*保持*。这是充电限制器（`battery-charge-limit`，默认 85 %）
的内核一侧。

#### 858：按需采样温度
`iio_read_channel_processed()` 成功时返回 IIO 值类型——
`IIO_VAL_INT == 1`，不是 0。因此原来的
`if (iio_read_channel_processed(...))` 丢弃了**每一个**
好样本，让温度停留在 `25000` 占位值上，
于是电量计看上去总是处于 25 °C。该辅助函数现在返回 int，
只把 `ret < 0` 视为失败（未配置通道时为 `-ENODATA`），
并从属性 getter 按需调用。

#### 859：报告诚实的充电状态
只要存在充电器（VBUS 在线），BMS 就报告 `STATUS=Charging`，
而不检查充电是否真的被启用。在充电限制器
保持电池的情况下这是错误的，LuCI 会在 85 % 永远显示"Charging"。
驱动现在查询供电充电器的 `CHARGE_ENABLED`，当其关闭时报告
`POWER_SUPPLY_STATUS_NOT_CHARGING`。

### 2.9 其他 SoC

#### 816：SMSM 请求之前校验邮箱
在 Linux 6.12 中，只要 `fwnode_property_get_reference_args()` 失败，
`mbox_request_channel()` 就会打印 `can't parse "mboxes" property`。
MSM8916 定义了
`mboxes = <0>, <&apcs 13>, <0>, <&apcs 19>;`，其中 host 0 是 APPS
（`local-host`），host 2 是空的 AUDIO 占位符。该驱动无条件地
遍历所有主机，刷屏启动错误。该补丁：
1. 跳过为 `smsm->local_host` 请求邮箱（APPS 从不向自己发 IPC）。
2. 用 `of_parse_phandle_with_args()` 先校验 phandle。
3. 如果邮箱控制器仍在探测，干净地传播 `-EPROBE_DEFER`。

### 2.10 OpenWrt 源码补丁

#### 0001：package-pack IDIR / conffiles 修复
上游 `include/package-pack.mk` 在一个需要两个美元符号的 Make
上下文中使用了 `$$(IDIR_$(1))`（三个美元符号）：Make 会把 `$(...)`
展开一次并把结果传给 shell，而 `$$(...)` 会以字面 `$(...)` 传给
shell，shell 随后尝试把 `IDIR_base-files` 作为命令执行
-> `command not found`，构建在 `package/install` 处失败。
该修复把每一处 `$$(IDIR_$(1))` / `$$$$(IDIR_$(1))` 改为
`$(IDIR_$(1))`，不触碰预期的 shell 命令替换
（`$$$$(cat ...)`、`$$$$(MKHASH ...)`）、shell 变量（`$$$$FILE`、
`$$$$CONTROL`）或 apk 的 `$`-ABI 分隔符（`$(1)$$(ABIV_$(1))` 必须
保持三个 `$`）。该 bug 在 v25.12.5 和 v25.12.6 上游 tag 中都是
潜伏的，只有在某个 package 的 ipk 被重新打包时（例如干净的
`rebuild`）才会触发，因此被复用缓存 ipk 的增量构建掩盖了。

#### 809：mac80211 wcn36xx 支持
在 OpenWrt 的 mac80211 package 中启用 `kmod-wcn36xx`
（WCN3660/3680 Wi-Fi）和 `kmod-ath10k-sdio`：给 `kmod-ath` 添加
`@TARGET_msm89xx` 依赖，定义带 autoload/probe 的
`KernelPackage/wcn36xx`，并启用 `WCN36XX_DEBUGFS`。

#### 810：rstrip 跳过运营商 MCFG
每个运营商 MCFG（`mcfg_sw.mbn`）都以 `\x7fELF` 魔数开头，因此
`file(1)` 会把它报告为 ELF 可执行文件，而 `rstrip.sh` 把它喂给
`sstrip -z`，后者重写头部并截断 blob（29816 → 29813 字节，
SHA-1 变化）。这些是 modem 固件映像，不是 AP 可执行文件。
该补丁以 `/lib/firmware` 已有的同样方式排除
`*/qcom-carrier-autocfg/mcfg/*`。

---

### 2.11 OpenWrt package 补丁（`openwrt-overlay/`）

由 `build.sh` 在 package 构建之前合并进树（一次遮蔽上游 package
源码的 `cp -a`）。截至 25.12.6，wcn36xx 系列是**六个**补丁
（450-453、458、459）：四个加固补丁（454-457）已被 backports
6.18.55 吸收并删除。剩下的是：451/452 添加 WPA3/MFP 与 AP+STA
并发；453 把固件热缓解作为冷却设备暴露（已 rebase 到 6.18.55）；
458 是 BMPS 省电并发防护；以及——最重要的——**459**，RX survey
路径中的 NULL 解引用 PANIC，已**实机验证**（刷入 `c1216b14`，
此后零 panic）。`hostapd` 900 在 PSK 错误失败时派发
`SSID-TEMP-DISABLED`（驱动 `wifi-sta-wpa-event` 的 LuCI 红色警报）。
`libqmi` 001/002 修复 PDC 配置加载段错误并把上传拆成 256 字节
块——两者都是 `qcom-carrier-autocfg` 所需的。`fstools` 0001 和
`elfutils` 100 是构建/运行时健壮性修复。

> **升级 backports 树。** overlay 的合并不做删除，因此当一个补丁进入
> 上游时，你必须同时从 **`openwrt-overlay/` 和已准备的
> `openwrt/` 树**中删除它，否则整个系列会以 `1 out of 2 hunks FAILED`
> 失败，整个 `package/kernel/mac80211` 构建随之完蛋。务必针对
> 原始的 `openwrt/dl/backports-<ver>.tar.zst` 重新生成 rebase 后的补丁，
> 并已应用在前的补丁，然后按 450 → 451 → 452 → 453 → 458 → 459
> 重放以确认零 reject。

### 2.12 自定义 packages（`packages/`）

这 21 个应用已列在表 1.12 中。承载项目关键逻辑的有：

- `qcom-carrier-autocfg` —— 从 SIM 选择/激活 MCFG/PDC 运营商配置
  （Jio/MCFG 可用）；依赖 libqmi 001/002。
- `luci-app-modem-watchdog` 加 `modem-bearer-watchdog` base-file 脚本 ——
  SSR/僵尸恢复（重新注册 bearer，在其死亡时轻推 ModemManager）。
- `qcom-time-daemon` —— 从蜂窝时间设置系统时钟。
- `rmtfs` / `qrtr` —— 上述组件所依赖的 QRTR/EFS 传输。
- `reboot-edl` —— 封装内核 EDL 支持以供恢复。
- `uci-usb-gadget` / `luci-app-usb-gadget` —— USB gadget（ethernet/serial）
  管理，包括 failsafe gadget。
- `diag-bind` / `diag-efs` / `diag-logtool` —— 用于 modem 调试的
  SMD DIAG 工具链。

### 2.13 BSP / 板级支持（`msm89xx/`）

BSP 是一个目录，不是一个补丁。`build.sh` 把它复制到
`target/linux/msm89xx` 并把 `base-files/` 合并进 rootfs。要点：

- `base-files/etc/apk/repositories.d/customfeeds.list` 在*运行时*添加
  **上游 25.12.x 二进制 feeds**（于是用户可以 `apk add` 任何上游
  package——包括 telephony 和 video——而无需重新构建），
  而 `CONFIG_VERSION_REPO` 把 `apk` 指向我们自己的 kmod/用户态
  仓库以获取 vermagic 锁定的内核模块。
- `base-files/etc/apk/keys/` 交付我们的签名密钥以及 `openwrt-25.12.pem`
  （上游 25.12.x apk 密钥），使这些 feeds 受信任。
- `config-6.12` 固定内核配置；`modules.mk` 定义 `kmod-*`
  packages；`recovery/` 是无界面的 recovery initramfs（USB gadget +
  dnsmasq + dropbear + WiFi 模块），作为 ramdisk 打包到生产内核上。
  `config-6.12-recovery` 仅为参考保留——已没有任何东西构建它。

---

## 3. 维护与补丁摄取工作流

在开发或更新补丁时：

1. **源码位置**：
   - 内核补丁 → [`msm89xx/patches/`](../../msm89xx/patches/)
   - OpenWrt 构建树补丁 → [`openwrt-patches/`](../../openwrt-patches/)
   - OpenWrt package 补丁 → [`openwrt-overlay/`](../../openwrt-overlay/)（由 `build.sh` 在 package 构建之前合并进树）
   - 自定义 packages → [`packages/`](../../packages/)（由 `build.sh` 复制到 `package/msm8916/`）
   - BSP / 板级支持 → [`msm89xx/`](../../msm89xx/)（base-files、image、config、modules、recovery）
2. **编号方案**：三位数字，按字典序应用。数字是
   稳定标识符而非连续序列——空缺（817、829、830、835–837、
   839、840）是已移除/退役的补丁，不可随意重用。
   - `801–807`、`852–853`、`867–869`：设备树板级启用
   - `808–851`：内核驱动（BAM-DMUX、remoteproc、rpmsg、power、CPR、thermal）
   - `854–859`：电源与电池（PM8916 LBC 充电器、VM-BMS、VADC）
   - `999`：必须排在最后的收尾 bug 修复
3. **格式**：unified diff（`diff -u` / `git diff`），带 `a/...` 和
   `b/...` 路径。
4. **集成**：在构建期间，[`build.sh`](../../build.sh) 和
   [`scripts/openwrt-prepare.sh`](../../scripts/openwrt-prepare.sh) 把
   [`msm89xx/patches/`](../../msm89xx/patches/) 同步到 OpenWrt 的
   `target/linux/msm89xx/patches/`，并在内核/package 构建之前把
   [`openwrt-patches/`](../../openwrt-patches/) 应用到 OpenWrt 源码树。
5. **按板级限定**：少数补丁只对特定的 modem
   版本正确。目前只有 **833** 被限定（通过
   `of_machine_is_compatible` 限定到 HMUF02-V5）。板级特定行为
   其余通过 DT 属性表达（例如 849/851/853 中的 `qcom,a2-pin`），
   而不是 `#ifdef`。
