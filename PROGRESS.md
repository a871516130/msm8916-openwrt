# MF32LT 移植进度记录

## 2026-11-28 会话：SIP 账号 100 注册打通 + Registered 列 3 个 bug

### 结论：WSS 不支持，当前只有 UDP 5060
- 设备 `pjsip.conf` 仅 `[transport-udp]` → `protocol=udp`, `0.0.0.0:5060`。
- `res_pjsip_tls.so` **不存在**；asterisk 23.1.0 源码树里 **没有 `res/res_pjsip_tls.c`**（48 个 `res_pjsip_*.c` 无 tls）；`res_pjsip.c` 不处理 `protocol=tls`。
- pjproject 带 `--with-ssl`，但 asterisk 侧未启用 TLS 传输。
- **网页软电话（SIP.js/WebRTC，强制 WSS）当前用不了**；原生客户端（Zoiper/Linphone/baresip）用 UDP 即可。

### SIP Digest 算法（asterisk 23 pjsip 实测）
- `HA2 = MD5("REGISTER:" + 请求行 URI)`，URI = `sip:192.168.1.1:5060`（**请求行**，不是 Aor）。
- `response = MD5(HA1:nonce:HA2)`，**不带 qop**；带 `qop=auth` 会被 401 拒绝。
- 用此算法实测：`SIP/2.0 200 OK`，asterisk 记录 `Contact: 100/sip:100@192.168.1.174:55238 ... Avail`。
- 客户端密码：100 = `e27cf99746069e9505`，101 = `fb34c798365fd1134d`（见 `/etc/asterisk/ufi-voice-phones.txt`）。

### Registered 列恒显 "—" 的三个 bug（全部已修）
1. **`sip_entry` awk 取错字段**：asterisk 23 的 contact 数据行形如
   `Contact:  100/sip:100@192.168.1.174:55238;rinstance=d339  ab779a67c1  Avail  136.966`，
   即 `$1="Contact:"`、`$2=联系名`、`$3=Hash`、`$4=Status`。旧代码用 `$1` 当联系名 → `^100/` 永不匹配 → 恒报 `down`。改为 `$2`。
2. **前端取错 Promise.all 索引**（主因）：`load()` 是
   `[uci.load('ufivoice'), uci.load('network'), fs.exec(...)]`，状态在 **`data[2]`**；
   旧代码读 `data[1].stdout`（`uci.load('network')` 的返回值，无 `.stdout`）→ `st` 恒为 `null` → 两列恒 "—"。
3. **匿名 GridSection 兜底**：`section_id` 可能不是 uci 名，加按索引兜底取 `number`。

### 诊断手段（可复用）
- rpcd `file.exec` 的正确 ubus 参数名是 `command`/`params`/`env`（不是 `cmd`/`args`）：
  `ubus call file exec '{"command":"/usr/sbin/ufi-voice-status","params":[],"env":[]}'`
  → 返回 `{code, stdout}` 对象，`stdout` 为 JSON 字符串。
- `ufi-voice-status` 加了 `/tmp/ufi-status.log` 调用日志（含 `ppid`），`ppid=1400`=rpcd 即 LuCI 调用的证据。
- modem 探针超时 8s→3s（`mmcli`/`qmicli`/`--voice-list-calls`），避免顶出 rpcd 超时。
- 前端 `Registered` 列区分两种情况：`st` 为空 → "状态不可用"（脚本没跑通），否则 "—"。

### 已重建（本次）
- `ufi-voice-1.0-r26.apk`（awk `$2` + 日志 + 超时 3s）
- `luci-app-ufi-voice-1.0-r3.apk`（`data[2]` + section_id 兜底）
- `luci-i18n-ufi-voice-zh-cn-0.apk`（+「状态不可用」，共 62 条中文）
- 增量 `make` 重打镜像（`IMG_EXIT=0`）：
  `system.img` 72,216,921 B / `sysupgrade.bin` 79,298,838 B / `boot.img` 7,067,926 B / `gpt_both0.bin` 34,304 B / `firmware.zip` 632,480 B
- **刷机包**：`/tmp/opencode/mf32lt-flash-final.tar.gz`（171,344,755 B，
  sha256 `b488bcb7f09f5395668ad38a88bf0f497e7523369d09534e74506cc4d3362392`）
  staging `/tmp/opencode/flash-staging-v2/`，`flash.sh` 的 4 个 glob 全部命中，`BOARD_TOKEN=mf32lt`。
- 已提交 `22672cb` 并 push 到 fork `a871516130/msm8916-openwrt` main。
  （注：push 要用 `fork` 远端（SSH）；`origin` 走 HTTPS 代理需凭据，会失败。）

### 剩余待办
- 设备 kernel 仍 `6.12.112`（旧固件），新 system.img 未刷。
- 实际通话验收：验证音频链 `ufi_voiced` → `hfp_ag` → `voicebridge` → 软电话
  （`voicebridge` 平时 `stopped`，通话时才起）。

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

### ufi-voice SIP LAN IP 动态化（用户决策：只做前端）
- 背景：ufi-voice SIP 功能本身不依赖 LAN IP（asterisk 传输绑 `0.0.0.0:5060`、AMI 绑 `127.0.0.1`）；192.168.1.1 只出现在 LuCI 页面提示/示例（ntfy_click placeholder + 文案）。
- 已改 `config.js`：`load()` 加 `uci.load('network')`，`render()` 动态读 `network.lan.ipaddr`（回退 `192.168.1.1`），ntfy_click 的 placeholder 与示例文案动态插入实际 IP（`sip:100@<实际IP>`）。
- 同步更新 `ufi-voice.po`：ntfy_click 文案拆分为两段 msgid/msgstr（因动态插入 IP）。
- 镜像内验证：config.js 含 `uci.load('network')` + `lanip=uci.get(...)` ✓；lmo 含拆分后中文 ✓。
- **新刷机包**：`/tmp/opencode/mf32lt-flash-final.tar.gz`（166,246,086 B，sha256 `5bb4d87e1cb9c18c039b9499064a754b971f93271bb33c478bfcccc70e337020`）。

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
