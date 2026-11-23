# Qualcomm MCFG 运营商 MBN 架构与 QMI PDC 子系统

**文档 ID：** \`72_QUALCOMM_MCFG_CARRIER_MBN_AND_PDC_ARCHITECTURE.md\`  
**分类：** Qualcomm Hexagon 调制解调器基带架构与运营商配置  
**目标：** MSM8916 / MSM8939 / MDM9625 基带处理器子系统  

---

## 1. 什么是 \`mcfg_sw.mbn\`？

\`mcfg_sw.mbn\`（**调制解调器配置软件 / 运营商 MBN**）是 Qualcomm 的有符号二进制打包格式，用于打包针对运营商定制的非易失（NV）项、EFS 配置文件、无线电资源控制（RRC）频段优先级矩阵以及运营商睡眠/DRX 定时器。

Qualcomm 基带固件（\`modem.b00\`–\`modem.b26\`）被编译为**单一通用蜂窝二进制**（全球支持 2G GSM、3G WCDMA 和 4G LTE）。由于每个蜂窝运营商（Reliance Jio、Airtel、中国移动、Verizon、AT&T、NTT DoCoMo）都强制不同的网络参数，Qualcomm 调制解调器不会将运营商参数硬编码进固件镜像。

相反，Qualcomm 提供位于调制解调器分区下的运营商配置包：
\`\`\`
modem_pr/mcfg/configs/mcfg_sw/generic/<region>/<carrier>/<type>/mcfg_sw.mbn
\`\`\`

### 反编译的二进制结构（\`Reliance/commerci/mcfg_sw.mbn\`）
对 \`/apac/reliance/commerci/mcfg_sw.mbn\` 的分析揭示：

\`\`\`text
ELF 32-bit LSB executable (Qualcomm MBN container)
Magic: 'MCFG' (0x4746434D)
Carrier Name: 'Reliance' (Jio 4G India)
Embedded NV & EFS Items:
  ├── /nv/item_files/modem/lte/rrc/csp/band_priority_list (Jio Band 40 / Band 3 / Band 5 priority)
  ├── /nv/item_files/modem/mmode/voice_domain_pref         (IMS / VoLTE preference)
  ├── /nv/item_files/modem/nas/exclude_ptmsi_type_field
  ├── /nv/item_files/modem/utils/a2/sps_dynamic_usb_endpoint
  ├── /data/ds_dsd_attach_profile.txt                     (Attach_Profile_ID: 1;)
  ├── /data/iwlan_s2b_config.txt                          (epdg_fqdn: vowifi.jio.com; natt_keepalive: 20s)
  ├── /efsprofiles/imshandoverconfig                      (LTE RSRQ/SNR handover thresholds)
  └── /nv/item_files/therm_monitor/config_test.ini        (PA thermal mitigation)
\`\`\`

---

## 2. 为何原厂 Android 使用 \`mcfg_sw.mbn\`？

在原厂 Android 中，\`rild\`（无线电接口层守护进程）和 \`libril-qc-qmi-1.so\` 包含一个名为 **QCRIL QMI PDC** 的专用子系统：

\`\`\`c
/* Disassembled symbols in Stock Android libril-qc-qmi-1.so */
qcril_qmi_pdc_init()
qcril_qmi_pdc_retrieve_current_mbn_info()
qcril_qmi_pdc_get_available_configs()
qcril_qmi_pdc_load_configuration()
qcril_qmi_pdc_select_configuration()
qcril_qmi_pdc_activate_configuration()
\`\`\`

### 原厂 Android SIM 运营商检测流程
1. **启动初始化：** \`rild\` 连接到 QMI 服务 ID \`0x24\`（**\`QMI_PDC\`** - 持久设备配置）。
2. **SIM IMSI 检查：** 当检测到 SIM（例如 IMSI 以 \`405861\` 开头表示 Jio）时，\`rild\` 向调制解调器查询其已加载的运营商配置文件。
3. **MBN 匹配与激活：** \`rild\` 定位 \`/apac/reliance/commerci/mcfg_sw.mbn\` 并发送 \`QMI_PDC_LOAD_CONFIG\`，随后发送 \`QMI_PDC_ACTIVATE_CONFIG\`。
4. **基带热重载：** Hexagon 基带应用 Jio 的频段优先级、DRX 寻呼定时器和保活间隔，无需复位处理器。

---

## 3. 通用 OpenWrt 上会发生什么？

在标准 OpenWrt 上：
* OpenWrt 不包含 Qualcomm 专有的 \`qcril\` 守护进程。
* \`ModemManager\` 和标准 \`netifd\` 都不会在启动时自动调用 \`QMI_PDC\`。
* Qualcomm Hexagon 调制解调器启动进入其内置的备用配置文件：
  \`\`\`text
  Configuration 1:
      Description: ROW_Generic_3GPP
      Type:        software
      Size:        8984
      Status:      Active
      Version:     0x2010801
  \`\`\`
* **\`ROW_Generic_3GPP\` 的影响：**
  * 蜂窝数据和 LTE 附着正常连接。
  * 然而，运营商特定的 DRX（非连续接收）寻呼保活间隔未针对运营商的核心 EPC 进行定制。
  * 特别是在像 Reliance Jio（纯 4G/5G EPC，无 2G/3G 传统备用）这样的严格运营商网络上，如果设备空闲或在大约 15–20 分钟后未能确认周期性寻呼周期，运营商会终止下行承载。

---

## 4. 如何在 Linux / OpenWrt 中管理运营商 MBN

使用 \`qmicli\`，可以从用户空间直接操作持久设备配置（PDC）服务：

### 1. 列出已加载的运营商配置文件
\`\`\`sh
qmicli -d /dev/wwan0qmi0 --pdc-list-configs=software
\`\`\`

### 2. 将运营商配置文件加载到调制解调器 EFS
\`\`\`sh
qmicli -d /dev/wwan0qmi0 --pdc-load-config=/path/to/reliance/commerci/mcfg_sw.mbn
\`\`\`

### 3. 激活运营商配置
\`\`\`sh
# Format: --pdc-activate-config=software,<CONFIG_ID>
qmicli -d /dev/wwan0qmi0 --pdc-activate-config=software,1F:F9:BC:...
\`\`\`

---

## 5. 17 分钟链路停滞的调查与解决办法

在我们对硬件 \`c2b9103c\`（\`192.168.8.1\`）进行 28+ 分钟的实时浸泡测试期间：

1. **硬件与内核稳定性：**
   * 运行时间超过 **28 分钟**，无单个内核崩溃、MBA 复位或 remoteproc 崩溃。
   * Wi-Fi Pronto（\`remoteproc1\`）和 Hexagon MSS（\`remoteproc0\`）保持 100% 活动。
   * **77.6 MiB 数据**被干净传输。

2. **约 17 分钟时的运营商掉线：**
   * Jio 的运营商核心重新协商无线电连接。
   * 在 \`ROW_Generic_3GPP\` 模式下，下行 RX 字节暂停，而 TX 字节继续递增。
   * 传统 \`ifdown modem\` / \`ifup modem\` 无法绑定，因为 netifd 与动态 DBus 路径（\`Modem/1\` -> \`Modem/4\`）失去同步。

3. **\`modem-watchdog\` 中的决定性修复：**
   * \`packages/modem-watchdog/files/modem-watchdog.sh\` 被增强为渐进式恢复管道：
     * **阶段 1：** 动态直接连接（\`mmcli -m any --simple-connect="apn=jionet,ip-type=ipv4v6"\`）。
     * **阶段 1.5：** 通过 QMI DMS 直接切换无线电电源（\`dms-set-operating-mode=low-power\` -> \`online\`）以强制小区 SFN/时钟重新同步。
   * 测试确认：**Ping 立即恢复至 0% 丢包（平均 42.3 ms）**，在不到 5 秒内完成，无需系统重启。
