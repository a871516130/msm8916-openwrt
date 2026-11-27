# MF32LT 移植进度记录

## 2026-11-27 会话：回退 modemmanager 到上游 + 重写 cellular 页

### 用户决策（最终）：回退上游 + 重写 cellular
- modemmanager 页 = **纯上游原版**（前端 JS 视图 `status.js`，mmcli-only，无 QMI 射频层）+ 中文 i18n。
- `luci-app-cellular` **从零重新设计**，承担 modemmanager 页**没有**的内容（QMI 射频层/频段/基站信令/SIM 卡槽+切卡/IMEI）。
- 硬件 WCN3620（2.4GHz 单频）；LAN IP=192.168.1.1；ModemManager 用上游原版不 patch MM 源码。

### 回退 luci-proto-modemmanager 到上游（已完成）
- 恢复上游 `menu.json`（`admin/status/modemmanager` 标题 "Cellular Network"，`action.type=view` 指向 `modemmanager/status`）。
- 删除项目新增的 `root/usr/lib/`（`modemstatus.lua` + `status.htm` Lua controller），`status.js` 恢复为唯一视图。
- 回退后 feed 版与上游 HEAD **完全一致**（`git status` 干净）；上游 `acl.json` 仅授权 mmcli（无 qmicli）。
- 镜像内验证：menu.json="Cellular Network" ✓、`status.js`(4421 B) 在 ✓、无 modemmanager Lua controller ✓。

### modemmanager 中文 i18n（新增）
- 上游 `status.js` 已用 `_()`（32 个唯一字符串），新增 `po/zh_Hans/modemmanager.po` 全量翻译。
- `luci.mk` 自动生成 `luci-i18n-modemmanager-zh-cn`；`.config` 已启用（`CONFIG_PACKAGE_luci-i18n-modemmanager-zh-cn=y`，依赖 `CONFIG_LUCI_LANG_zh_Hans=y`）。
- 构建产物 `modemmanager.zh-cn.lmo`(912 B) 含 UTF-8 中文 ✓。

### cellular 页重写（从零设计）
- **保留 modemmanager 没有的**：QMI 射频层（`--nas-get-serving-system` 服务注册状态/漫游）、Radio bands（`--nas-get-rf-band-info` 频段/信道 + MM `current/supported-bands`）、基站信令（GCI/EARFCN/LTE band/服务小区/RSRP/RSRQ/SNR/邻区）、SIM 卡（活动卡槽+卡槽状态+切卡）、IMEI 修改、运营商配置。
- **删除与上游重复的**：PLMN/TAC（上游 Cell Location 已有 MCC/MNC/TAC）、ICCID/IMSI（上游 SIMs 已有）；不再重复 Modem/Status/Network registration/Network rejection 区块。
- 仍用 `DEVICE="qcom-soc"`（真机 MM 枚举 /Modem/7 有 IMEI、/Modem/13 无 IMEI；`any` 读到幽灵 modem）。
- `cellular.lua`/`status.htm` 均过 `luac5.1` 语法校验；`packages/` 已同步。

### 两个真实 bug（已修，本次重建入镜像）
- **cellular 邻区信令**：`collect_signal()` 退出小区块判断 `^%s+[A-Z]...`（1+ 空白）误判 2-tab 子字段 → 已改 `^%s[A-Z]...`（恰好 1 空白），RSRP/RSRQ/RSSI 恢复。
- **ufi-voice SIP 注册**：`sip_entry` 用 awk `/^[[:space:]]*Contact:/` 且取 `$2` 导致 Registered 恒 "down"、host 恒空 → 已改匹配 `/\/sip:/`、取 `$1`/`$4`；**本次已确认重建入镜像**。

### 重建产物（本次）
- 重编 `luci-proto-modemmanager-26.288.56989~75a306d.apk` + `luci-i18n-modemmanager-zh-cn-0.apk` + `luci-app-cellular-1.0-r1.apk` + `luci-i18n-cellular-zh-cn-0.apk`。
- 增量 `make` 重打：`squashfs-system.img` 69,667,791 B（16:01）、`boot.img`、`sysupgrade.bin`、`firmware.zip`。
- 镜像内验证：modemmanager 回退版 ✓、`modemmanager.zh-cn.lmo` ✓、cellular 重写版（controller 含 serving_reg/roaming/rf-band-info、status.htm 含 QMI/基站信令/SIM 卡槽）✓、ufi-voice sip_entry 修复 ✓、cellular 菜单标题 "Cellular Network (Advanced)"→"蜂窝网络(高级)" ✓。
- **新刷机包**：`/tmp/opencode/mf32lt-flash-final.tar.gz`（166,246,038 B，sha256 `160c39b48f449c5e18b281508b5a38470fc8c64ac60a5d0359b2548461dcc326`）。

### 菜单命名（用户决策）
- 两个页面原同名同序 "Cellular Network"（Status 菜单）。已改 cellular 标题为 **"Cellular Network (Advanced)"**（中文"蜂窝网络(高级)"），与 modemmanager 页（上游 "Cellular Network"）区分。

## 2026-11-26 会话：Asterisk / 全量编译 / 刷机包

### Asterisk 未运行根因（已定位）
- 设备当前固件（旧，kernel Oct 17）**根本未安装 ufi-voice / asterisk**（`apk` 无 asterisk、无 ufi-voice，`/etc/init.d` 无 asterisk，`ufi-voice-status` 用 `pidof asterisk` 判"运行中/已停止"→ 恒为"已停止"）。
- 新构建的 system.img 也**未含 asterisk**：`.config` 里 `CONFIG_PACKAGE_ufi-voice=y` 但 `# CONFIG_PACKAGE_ufi-voice-asterisk is not set`、`# CONFIG_PACKAGE_asterisk is not set`。
- **根因**：`ufi-voice` 只是控制端；Asterisk 来自独立包 `ufi-voice-asterisk`（DEPENDS `+asterisk +asterisk-pjsip +asterisk-res-rtp-asterisk +...`），从未被启用。

### 已修复（config 变更 + 构建成功）
- 启用 `CONFIG_PACKAGE_ufi-voice-asterisk=y` → 自动拉起 `asterisk`、`asterisk-pjsip`、`asterisk-res-rtp-asterisk`、`asterisk-bridge-simple`、`asterisk-codec-ulaw/alaw`、`asterisk-app-audiosocket`、`asterisk-res-audiosocket`、`asterisk-func-shell`、`asterisk-res-timing-timerfd`、`libpj*`（pjproject feed）。
- 用户确认复用 sqlite：`libsqlite3` 已启用且是 asterisk 硬依赖（`--with-sqlite3` 系统库，非捆绑）。追加启用 `asterisk-cdr-sqlite3`、`asterisk-cel-sqlite3-custom`、`asterisk-res-config-sqlite3`（均复用现有 libsqlite3，零新增依赖）。
- **构建成功（BUILD_EXIT=0）**：asterisk 重配+重编完成，`HAVE_PJPROJECT=1`，`res_pjsip.so`(413K)/`chan_pjsip.so`(126K)/`cdr_sqlite3_custom.so`/`cel_sqlite3_custom.so`/`res_config_sqlite3.so` 均在镜像内；73 个模块；`/etc/init.d/asterisk`+`S99asterisk`、`91-ufi-voice-asterisk` 就位。
- **新 system.img** = 68,947,959 B（65.7 MiB，旧 63.2 → +2.5 MiB 压缩），rootfs 分区 128 MiB，余量充足；LAN IP 仍 192.168.1.1，无 192.168.8.1 残留。
- **新刷机包**：`/tmp/opencode/mf32lt-flash-final.tar.gz`（164,806,164 B，sha256 `26d4716bb8edafdd9ea4d5de2482c2255aa3b71643cc2ce11ef3853ef8ac10af`）。

### 集成链（刷机后）
- `ufi-voice-asterisk` 装 `91-ufi-voice-asterisk`（uci-defaults）→ 首次启动跑 `ufi-voice-asterisk-apply`：生成 `pjsip.conf`/`extensions.conf`/`manager.conf`，建 `asterisk` 用户，`uci set asterisk.general.enabled=1`。
- `S99asterisk`（START 99，先于 S99ufi-voiced）→ asterisk 运行 → `ufi-voice-status` 的 `pidof asterisk` = running → 页面显示"运行中"。

### 其余已确认（前次会话）
- iris `compatible = "qcom,wcn3620"`（硬件 WCN3620，2.4GHz 单频；`use_48mhz_xo=false`），非 wcn3680。
- LAN IP `192.168.1.1`（99-msm89xx-firstboot），全部硬编码 192.168.8.1 已清（含 `packages/` 副本）。
- 已集成：`imei-tool`、`luci-app-cellular`(+zh-cn)、`qmi-modem-410-init`、`qmi_auto_activate`；启动链 115 链接 0 dangling。
- Qt5 侧移除 `qt5base-gui`/`eglfs` 的 `libmesa` 依赖（Qt5 未启用），保留无头 `libmesa-freedreno`。
- 刷机包：`/tmp/opencode/mf32lt-flash-final.tar.gz`（旧，sha256 `3143b380...`）—— **需在本次构建后重打**。

## 2026-11-21 会话摘要（历史）

### WiFi / WCNSS 根因
- dtb iris `compatible` 曾为 `qcom,wcn368`（缺 0）→ WCNSS `start timed out`；已改 `qcom,wcn3620`（匹配硬件）。

### modem 待机根因
- WCNSS 失败 → modem/WiFi 共址未就绪 → modem 固件 `low-power`（DMS online → DeviceNotReady）。
- 新 `boot.img`(wcn3620) 应解决；modem 硬件无损坏。

### 本机网络（防阻塞）
- 设备 DHCP 关闭（`dhcp.lan.ignore=1`）；本机 NM unmanaged 仅 `mac:02:00:01:e8:28:dd`。
- 设备 USB 网卡 MAC 每次插拔会变，不能依赖固定 MAC；gadget VID:PID `0x1d6b:0x0104`。

## 关键文件
- `openwrt/target/linux/msm89xx/patches/869-arm64-dts-qcom-add-msm8916-generic-mf32lt.patch`（iris wcn3620）
- `openwrt/package/msm8916/qcom-firmware/`（mf32 固件，md5 与 ImmortalWrt 一致）
- `openwrt/package/msm8916/ufi-voice/`（ufi-voice + ufi-voice-asterisk，`ufi-voice-asterisk-apply` 生成 asterisk 配置）
- `openwrt/package/msm8916/imei-tool/`、`luci-app-cellular/`、`qmi-modem-410-init/`（已移植）
