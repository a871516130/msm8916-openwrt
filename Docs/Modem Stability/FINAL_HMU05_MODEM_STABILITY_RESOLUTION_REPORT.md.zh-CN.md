> ⚠️ **已被取代（2026-10-07）—— 请先阅读本更正。** 本报告早于 2026-10-06 的根因发现，
> 其核心前提已被**撤回**：并不存在需要中和的 900 秒 SCLK/DRX 定时器，修复也**不是**基带补丁。
> ~900 秒致命错误的真正原因是调制解调器 RF 任务对 NV 项 2500（`NV_FACTORY_DATA_4_I`）
> 与字面量 `"HiMI_OK"` 的 `memcmp` 比较；它在**AP 侧**由 `himi-ok-guard` 修复
> （每次调制解调器启动后重写 `HiMI_OK`，则截止时间永远不会触发）。
> **`hmu05-patch-modem` 已从树中移除**（`57024f2`）—— 其源码、Makefile 构建/安装，
> 以及 `msm-firmware-dumper.sh` 和 `99-msm89xx-firstboot` 中的调用都已删除，因此
> **下面关于 `modem.b16` / `modem.mdt` / `modem.b01` 的每条指令都不再适用**。
> “支柱 1”已过时；A2 `control=on` 引脚保持（现在由 `qcom_bam_dmux` 驱动强制执行 ——
> DT `qcom,a2-pin`，补丁 848/849；先前是被移除的 `modem-a2-hold` 辅助工具）覆盖了独立的
> `a2_power.c:1189` 致命错误。当前状态：
> `Docs/Modem Stability/Modem RE/hmu05/`；账本 `197_…SOP.md` §112.165–§112.171。

# Qualcomm MSM8916 HMU05 调制解调器：确定性稳定性与连接性解决报告

**日期：** 2026 年 9 月 3 日  
**作者：** OpenWrt MSM8916 移植与稳定性团队  
**目标硬件：** Generic HMU05（MSM8916 / Snapdragon 410，板卡 `generic-hmu05`）  
**内核：** Linux 6.12.94 / OpenWrt 25.12.5（`msm89xx/msm8916`）  
**基带固件：** `MPSS.DPM.1.0.C7`（调制解调器固件 v1.0）  
**产物路径：** `Docs/Modem Stability/FINAL_HMU05_MODEM_STABILITY_RESOLUTION_REPORT.md`

---

## 1. 执行摘要

Qualcomm MSM8916 USB 上网卡和口袋路由器 —— 具体来说是运行基带固件 `MPSS.DPM.1.0.C7` 的
**Generic HMU05** —— 在移植到主线 Linux 和 OpenWrt 时历来存在蜂窝掉线、崩溃和启动摩擦：
1. **15 至 18 分钟致命崩溃（$t \approx 900\text{s} - 1118\text{s}$）：**
   Hexagon QDSP6 调制解调器协处理器因致命断言崩溃（`lte_ml1_sleepmgr_stm.c:4054` 或
   Hexagon CPU 中止 `:Excep  :0:`），重置 `remoteproc0` 并使蜂窝接口下线。
2. **空闲 BAM-DMUX 电源塌缩与接收冻结：**
   上游 `qcom_bam_dmux` 驱动在 1000ms 无活动后自动挂起，丢失 SMSM 电源塌缩同步，
   使内核运行时 PM 进入 `RPM_ERROR`（`-EINVAL`）。
3. **缺少运营商 APN 配置：**
   设备需要为运营商 SIM 卡（如 Reliance Jio、Airtel、Vi）手动设置 APN 才能发起 LTE 数据承载。
4. **首次启动竞态条件：**
   调制解调器固件 blob 在首次启动时从内部 eMMC 分区提取；此前网络服务会在早期启动时
   找不到调制解调器，需要手动重启。

通过使用 Ghidra Headless 逆向工程、对出厂 Android 二进制的静态反汇编、QMI 协议追踪，
以及迭代的真实硬件测试，工程团队设计、实现并验证了一个**确定性的 4 支柱解决方案**。

结果是**100% 稳定、持续的蜂窝连接**，**零丢包**，已在真实硬件上验证超过 45 分钟连续运行
和 >130 MB 高速数据传输。

---

## 2. 技术根因分析

### 2.1 900 秒 SCLK 漂移与 DRX 睡眠断言
在 Qualcomm Hexagon 固件 `MPSS.DPM.1.0.C7`（`modem.b16`）中，LTE Layer 1 睡眠管理器通过
有限状态机（`LTE_ML1_SLEEPMGR_STM`）管理非连续接收（DRX）电源塌缩。
* 每 900 秒（15 分钟），一个后台维护定时器触发，以针对 19.2 MHz TCXO 振荡器重新校准
  睡眠时钟（SCLK）漂移。
* 在出厂 Android 上，专有 Qualcomm RIL 和 `time_daemon` 会定期同步 ATS（精度时间源）时钟。
* 在没有这些保活信号的干净 OpenWrt 中，累积的时钟漂移导致一个异步 SCLK 错误事件在
  调制解调器处于睡眠状态时触发，进而触发错误处理器 `FUN_c03987c0`，它断言
  `lte_ml1_sleepmgr_stm.c:4054`。

### 2.2 BAM-DMUX 驱动运行时 PM 状态错位
* 空闲 1000ms 时，上游 Linux `qcom_bam_dmux` 驱动调用运行时自动挂起。
* 流量到达时，`bam_dmux_runtime_resume()` 试图等待一个调制解调器固件不会发出的电源塌缩
  确认（`pc_ack_completion`）。
* 这以 `-ETIMEDOUT` 超时，使 `dev->power.runtime_status` 处于 `RPM_ERROR`（`-EINVAL`），
  将 `wwan0` 网络接口永久锁定为 `DOWN` 状态。

---

## 3. 4 支柱解决架构

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                    QUALCOMM MSM8916 HMU05 STABILITY STACK                   │
├──────────────────────────────────────┬──────────────────────────────────────┤
│ 1. Hardware-Locked No-Sleep Patch    │ 2. Clean BAM-DMUX Runtime PM Sync    │
│    (hmu05-patch-modem)               │    (808-bam-dmux-stats.patch)        │
│    • Patches FUN_c03987e0 to ret -1  │    • pm_runtime_set_active on power  │
│    • Disables 900s sleep timer       │    • Zero ndo_open/resume lockups    │
│    • Re-aligns SHA-256 in MDT/B01    │    • 4-byte padding bug fix & stats  │
├──────────────────────────────────────┼──────────────────────────────────────┤
│ 3. Qualcomm QMI Time Daemon          │ 4. Dynamic Carrier Auto-Cfg Engine   │
│    (qcom-time-daemon)                │    (qcom-carrier-autocfg)            │
│    • Syncs ATS_USER (Service 22)     │    • Auto-detects IMSI / PLMN        │
│    • Periodic ATS_TOD QRTR keepalive │    • Dynamic APN configuration       │
│    • Hardware-locked to HMU05 only   │    • Provisions carrier MCFG MBN     │
└──────────────────────────────────────┴──────────────────────────────────────┘
```

### 支柱 1：硬件锁定的固件 No-Sleep 补丁器
* **源码：** `packages/msm-firmware-dumper/src/hmu05-patch-modem.c`
* **机制：**
  - 在文件偏移 `0x001117e0` 处修补 `modem.b16`（`FUN_c03987e0` / `lte_ml1_sleepmgr_cfg`），
    操作码为 `00 c4 00 78 00 c0 9f 52`（`r0 = #-1; { jumpr r31 }`）。
  - 重新计算被修改段的 SHA-256 哈希，并更新 `modem.mdt`（偏移 `0x05bc`）和 `modem.b01`
    （偏移 `0x0228`）中的哈希表，以通过 Qualcomm MBA 安全引导加载器完整性校验。
  - **硬件保护：** 检查 `/proc/device-tree/compatible` 和 `/tmp/sysinfo/board_name`。
    如果板卡不是 HMU05（例如 `uz801`、`uf02`、`ufi001b`），则**立即以退出码 0 退出，
    不修改任何文件**。

### 支柱 2：BAM-DMUX 运行时 PM 状态机对齐
* **补丁：** `msm89xx/patches/808-bam-dmux-stats.patch`
* **机制：**
  - 在 `bam_dmux_pc_irq()` 中：
    - 调制解调器上电时（`new_state == 1`）：在 `bam_dmux_pc_ack()` 之后立即调用
      `pm_runtime_set_active(dmux->dev)`。
    - 调制解调器下电时（`new_state == 0`）：调用 `pm_runtime_set_suspended(dmux->dev)`。
  - 修复 4 字节 SKB 填充计算：`(sizeof(u32) - (skb->len % sizeof(u32))) % sizeof(u32)`。
  - 实现标准 Linux netdev RX/TX 字节与数据包计数器。
  - 使 `bam_dmux_netdev_open()` 完全干净，避免无效的 `pm_runtime_resume_and_get()` 错误。

### 支柱 3：原生 QMI 时间同步守护进程
* **软件包：** `packages/qcom-time-daemon/`
* **机制：**
  - 打开一个轻量级 QRTR 套接字，连接到调制解调器 QMI 时间服务（服务 ID `0x16` = 22）。
  - 注册指示，并在服务发现时以及每当系统时钟跳变 >5 秒（例如 NTP 同步）时同步
    `ATS_USER`（基数 2）时钟偏移。
  - 每 60 秒发送一次周期性的 `ATS_TOD`（基数 1）GET 请求，作为轻量级信道保活。
  - **干净启动：** 在分发消息前等待 `QRTR_TYPE_NEW_SERVER` 发现，消除连接重置警告。
  - **硬件范围限定：** 在 `msm8916.mk` 中严格包含于 `Device/generic-hmu05`，
    并在 `/etc/init.d/qcom-time-daemon` 中有运行时板卡检查。

### 支柱 4：混合全局与自定义 APN 自动配置引擎
* **软件包：** `packages/qcom-carrier-autocfg/`
* **机制：**
  - **第 1 层（用户自定义覆盖）：** 检查 `/etc/qcom-carrier-autocfg/custom-apns.tsv`。
    通过 `conffiles` 在 sysupgrade 期间保留，允许用户定义或覆盖任何运营商配置文件，
    而无需重新编译固件。
  - **第 2 层（全局 TSV 数据库）：** 通过快速的 `awk` 匹配 SIM 的 MCC-MNC，
    查询 `/usr/share/qcom-carrier-autocfg/apns.tsv`。
    - **尼泊尔覆盖：** Nepal Telecom（NTC/Namaste `42901` -> `ntnet`）、Ncell Axiata
      （`42902` -> `web`）、Smart Telecom（`42904` -> `smart`）。
    - **全球覆盖：** 印度（Jio、Airtel、Vi、BSNL）、美国（AT&T、Verizon、T-Mobile）、
      中国（CMCC、CU、CT）、英国/欧洲（EE、Vodafone、O2、Three、Telekom）、阿联酋、东南亚。
  - **第 3 层（模糊运营商匹配）：** 作为回退，对 SIM 属性中的运营商名称进行模式匹配。
  - **第 4 层（通用默认）：** 回退到通用 `internet`（`ipv4v6`）。
  - 自动将匹配的 APN 推送到 UCI（`/etc/config/network`），并命令 ModemManager
    （`mmcli --simple-connect`）发起数据承载。

---

## 4. 多目标安全与隔离

一个主要设计约束是确保其他 MSM8916 硬件目标（`yiming-uz801v3`、`generic-uf02`、
`generic-ufi001b`）保持 100% 不受影响：
1. **调制解调器固件 2.0 设备：** 其他上网卡运行更新的基带固件，其中 SCLK 睡眠漂移已在
   内部处理。`qcom-time-daemon` 严格地从它们的 `DEVICE_PACKAGES` 中省略。
2. **固件补丁范围限定：** `hmu05-patch-modem` 二进制对 `hmu05` 强制执行显式的 compatible
   检查；在其他设备上，它作为空操作干净退出。
3. **调制解调器看门狗消除：** 旧的 `modem-watchdog` 脚本（它激进地重置 remoteproc 并干扰
   启动）已完全从仓库中移除。

---

## 5. 真实硬件基准与验证

该解决方案已刷写到物理 HMU05 上网卡上，通过 USB CDC-NCM 评估：

| 指标 | 测量值 | 目标 | 状态 |
| :--- | :--- | :--- | :--- |
| **连续运行时间** | **45 分钟以上** | > 30 分钟 | **通过** |
| **数据传输量** | **> 130 MB**（103 MB 接收 / 27 MB 发送） | > 50 MB | **通过** |
| **丢包** | **0.0%**（0 错误，0 丢弃） | 0.0% | **通过** |
| **Ping 延迟（`1.1.1.1`）** | **35 ms – 44 ms** | < 80 ms | **通过** |
| **DNS 解析（`google.com`）** | 即时 IPv4 与 IPv6 | < 100 ms | **通过** |
| **内核 `dmesg` 错误** | **0 致命错误，0 崩溃，0 异常** | 0 | **通过** |
| **首次启动上网** | **自动，无需手动重启** | 自动 | **通过** |

### 5.1 实验证明：为什么硬件锁定的 No-Sleep 补丁是严格必需的

为严格验证 No-Sleep 二进制补丁是否与 `qcom-time-daemon` 一起严格必要，在真实硬件上进行了
一次受控实证测试：
1. **测试设置：**
   - 构建的固件不含 `hmu05-patch-modem`。
   - 提取的 `modem.b16` 经验证为 100% 未改动的出厂 Qualcomm 基带
     （`ab795bf097be054880da5e8992e372701afa1b6be1cd2226002d3108c9338c60`）。
   - `qcom-time-daemon` 和 `qcom-carrier-autocfg` 正在积极运行。
2. **结果（$t = 931.6\text{s}$ 时崩溃）：**
   正好在 15.5 分钟时，调制解调器 DSP 崩溃并触发完整的板卡看门狗重置。内核持久 RAM
   oops 日志（`/sys/fs/pstore/console-ramoops-0`）捕获到：
   ```text
   [  931.633672] qcom-q6v5-mss 4080000.remoteproc: fatal error received: lte_ml1_sleepmgr_stm.c:4054:
   [  931.633880] remoteproc remoteproc0: crash detected in 4080000.remoteproc: type fatal error
   [  931.641808] remoteproc remoteproc0: handling crash #1 in 4080000.remoteproc
   [  931.649933] remoteproc remoteproc0: recovering 4080000.remoteproc
   ```
3. **结论：**
   `qcom-time-daemon` 处理 ATS/SCLK 主机同步，但**只有硬件锁定的 No-Sleep 补丁
   （`hmu05-patch-modem`）能防止内部 Hexagon DRX 状态机塌缩进致命的
   `lte_ml1_sleepmgr_stm.c:4054` 断言**。两个组件是相互补充的，并且对于 HMU05 的
   长期连续稳定性都是严格必需的。

---

## 6. Git 分支与合并策略

* **主题分支：** [`fix/hmu05-modem-crash-fix`](https://github.com/akbar-npj/msm8916-openwrt/tree/fix/hmu05-modem-crash-fix)
* **提交：** [`5917b06`](https://github.com/akbar-npj/msm8916-openwrt/commit/5917b06)
* **目标分支：** `main`
* **已清理的陈旧分支：** `remove/modem-hex-patch`、`test-modem-stability`、`test/time-daemon-unpatched-modem`。
