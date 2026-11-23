# MF32LT 移植进度记录

## 2026-11-21 会话摘要

### WiFi / WCNSS 根因（start timed out）
- 设备 `dmesg`: `qcom-wcnss-pil a204000.remoteproc: start timed out`
- **根因**: dtb 的 iris `compatible = "qcom,wcn368"`（缺一个 0），不匹配内核 `qcom,wcn3680` → WCNSS 启动超时
- **修复**: `869` patch 已把 `wcnss_iris compatible` 改为 `qcom,wcn3680`（build 的 boot.img 已含，strings 确认），**待刷 boot.img**

### 蜂窝 / SIM
- `sim-select` 已切到 `esim1`（GPIO50=1，设备只有 eSIM，无物理卡），GPIO 映射 24/49/50/51 与 ImmortalWrt 一致
- **eSIM 识别正常**: QMI UIM `Slot[1]` = present，USIM application `ready`，PIN1 disabled（eUICC 有 profile 且激活）
- ModemManager 报 `couldn't find SIM`（是 modem 未就绪的连带现象，非 eSIM 问题）

### modem 待机根因（关键）
- 对比 ImmortalWrt 实际设备（同固件 md5、同驱动、同 kernel 配置）:
  - ImmortalWrt: WCNSS `remoteproc1 is now up`（dtb 用正确 `wcn3680`）→ modem `online`（DMS online 成功）
  - 我们: WCNSS `start timed out`（dtb 用错 `qcom,wcn368`）→ modem `low-power`（DMS online → `DeviceNotReady`(52)）
- **根因**: WCNSS（WiFi）失败 → modem 与 WiFi 共址（`coex_interface`）未就绪 → modem 固件 `low-power`（拒绝 online）
- **修复**: 刷 `boot.img`（wcn3680）→ WCNSS 启动 → **WiFi + modem online 同时修复**
- 结论: **modem 硬件没有损坏**，是未刷 boot.img（旧 dtb wcn368）所致

### 本机网络（防阻塞）
- 设备 DHCP 已关闭（`uci set dhcp.lan.ignore=1` + dnsmasq restart，不再监听 UDP 67）
- 本机策略已清理: udev 规则、systemd-networkd 已删；NM unmanaged 仅保留 `mac:02:00:01:e8:28:dd`
- 设备 USB 网卡 MAC 每次插拔会变（fe:7a → 82:20 → ce:c2），**不能依赖固定 MAC**；gadget VID:PID `0x1d6b:0x0104`

### 移植完成（编译 OK）
- `imei-tool-1.0-r1.apk`（写 NV 550 /dev/rpmsg0 DIAG）
- `luci-app-cellular-1.0-r1.apk` + `luci-i18n-cellular-zh-cn-0.apk`（蜂窝网络页面：切卡 + 修改 IMEI）

## 明天刷机计划
1. 移植 `qmi-modem-410-init`（DMS online + repower_sim + MM enable 激活序列）到 `package/msm8916/`
2. 集成新包（imei-tool / luci-app-cellular / qmi-modem-410-init）到 system.img（`make target/install`）
3. 刷机：`boot.img`（wcn3680）+ `system.img`（LAN IP 192.168.1.1 + 新包）
4. 验证：WiFi（5GHz / 802.11ac）+ 蜂窝（eSIM → modem online → 注册网络）
5. 提交待用户批准（qcom-firmware、869 patch 等，origin `ghfast` + fork）

## 关键文件
- `openwrt/target/linux/msm89xx/patches/869-arm64-dts-qcom-add-msm8916-generic-mf32lt.patch`（wcn3680 + SIM GPIO）
- `openwrt/package/msm8916/qcom-firmware/`（mf32 固件，md5 与 ImmortalWrt 一致）
- `openwrt/package/msm8916/imei-tool/`、`luci-app-cellular/`（已移植）
- `/tmp/opencode/mf32lt-flash-final.tar.gz`（刷机包，sha256 `abd0010609e8b3fb41a18f9cb6a6deba349324fd8dfa33ebe8784c1c19279cb`）
