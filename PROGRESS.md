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

## 2026-11-28 会话：语音留言 / *98 IVR 提示音静音修复

### 根因：缺 `asterisk-codec-gsm`（提示音转码链断了一环）
- 设备提示音**只有 `.gsm`**（358 个），`.ulaw`/`.wav` 为 0；feed 的 sounds 安装规则从 `sounds/en/` 只复制 gsm。
- 软电话（Zoiper/Linphone/baresip）协商 `ulaw`，通道 native format = ulaw。
- 播放 `.gsm` 到 ulaw 通道需 translator 链 `gsm→slin→ulaw`：
  - `codec_gsm` 提供 `gsmtolin`（gsm→slin）——**原先未装**
  - `codec_ulaw` 提供 `lintoulaw`（slin→ulaw）——已装
- asterisk 23.1.0 源码树**无** `res/res_transcode.c`、`res_format_sel*.c`、`res_nativefile.c`（20+ 已删老转码层），转码唯一途径是 codec 模块注册的 translator。
- 缺 `codec-gsm` 时 `ast_translator_build_path` 找不到路径 →
  `Unable to find a codec translation path: (gsm) -> (ulaw)` →
  `Unable to open vm-intro (format (ulaw)): Function not implemented` → 全程静音后挂断。

### 关键排查坑
- `codec_gsm` 用 **`ast_register_translator`**（非 `ast_translator_register`）；grep 写错函数名会误判"无人注册 translator"。
- `main/translate.c` **已静态编进主程序**（导出 `__ast_register_translator`/`ast_translator_build_path` 等 7 个符号）。
- 设备 `/usr/sbin/asterisk` 是 stripped，`nm -D` 全空属正常，不能据此判断符号不存在。
- 设备上 `nm -D codec_gsm.so` 报 `ast_format_slin: symbol not found` 是 ldd 脱离主程序的假象，`module load` 实测成功。
- **translator 的 src/dst 是 `slin` 而非 `ulaw`**，所以必须两跳，只装 codec_ulaw 不够。

### 实测验证（决定性）
用 AMI `Originate` 到 `Local/s@voicetest`（`Local` 无需对端注册），另一端 `testanswer/s` 接听；测试上下文里 `Set(CODEC=ulaw)` 强制 ulaw 通道，依次播 `vm-intro`、`demo-congrats`、`IVRDemo(ufi-phones)`：
- `Response: Success`、`DialStatus: ANSWER`
- **转码错误 0、文件打开错误 0、文件找不到 0**
- 全部历史 `codec translation path` 错误时间戳（03:35–05:41）均**早于** codec_gsm 加载（06:07）

### AMI 用法坑
- `Originate` 必须用 **`Exten`**（不是 `Extension`），否则 `Extension does not exist`。
- 加 `Async: true` + `ActionID` 才能拿到响应。
- `Channel: Local/s@ctx` 可自建通道，不受端点未注册影响。

### 修复与持久化
- `.config` 启用 `CONFIG_PACKAGE_asterisk-codec-gsm=y`，编译产出 `asterisk-codec-gsm-23.1.0-r1.apk`（在 `telephony/` 目录，非 `base/`）。
- **`ufi-voice/Makefile` 的 `ufi-voice-asterisk` DEPENDS 补上** `asterisk-codec-gsm`、`asterisk-app-voicemail`、`asterisk-app-ivrdemo` —— 否则只靠 `.config` 漂移，重打镜像可能不带（commit `9076271`）。
- 设备上 `apk add --allow-untrusted` 可临时验证，但重刷会丢；必须进镜像。
- `modules.conf` 仅 `autoload=yes` + 少量 `noload`，`codec_gsm` 为 `AST_MODFLAG_DEFAULT` 会自动加载。

### 固件构建系统的坑：`make target/install` 不刷新 root.orig
- 镜像 rootfs **不是**来自 `staging_dir/.../root-msm89xx`，而是 `build_dir/.../root.orig-msm89xx`（`TARGET_DIR_ORIG`）。
- `include/image.mk` 的 `target-dir-%` 规则：`rm -rf` → `$(CP) $(TARGET_DIR_ORIG)` → `apk add $(mkfs_packages_add)`，即**每次从 root.orig 全新复制**再装 `PACKAGES_<profile>`（= DEVICE_PACKAGES）。
- 症状：改了 `.config` 加包后只跑 `make target/install`，system.img **大小/内容完全不变**（本次 72,216,921 B 与之前逐字节一致），因为 root.orig 是旧的。
- **正确顺序：先 `make package/install`（刷新 root.orig），再 `make target/install`**。
- 验证镜像内容：`unsquashfs -d /tmp/x <system.img>` 后 `ls usr/lib/asterisk/modules/`（squashfs 压缩流里 grep 明文无效）。

### voicemail 相关既有结论（前次会话确认）
- `voicemail()` 参数：`argv0`=mailbox、`argv1`=options → 正确写法 `voicemail(101@main)`。
- 只注册了 `VoiceMail`（留言）与 `VoiceMailMain`（查收），**无 `vmmain` 别名**。
- `voicemail reload` 才刷新 mailbox（`core reload` 无效，`load_config()` 仅模块加载时调一次）。
- ~~`IVRDemo` 必须带参数（上下文名），播 `demo-congrats`/`demo-instruct`。~~
  **已推翻**：asterisk 23 的 `IVRDemo` 是骨架应用，**忽略** filename 参数，硬编码播
  `demo-congrats`/`demo-instruct`（本构建无此二文件）→ 菜单必静默。见下方 2026-11-28 第二章。
- 录音 `format` 只能 `gsm`（只编了 `format_gsm.so`）。

## 2026-11-28（二）：*98 IVR 静默的第二个根因 —— IVRDemo 是骨架应用

> 上文第一根因（缺 `asterisk-codec-gsm`）修好后，用户仍报"拨通没声音"。
> 排查后发现是**完全独立的第二个 bug**，与 codec 无关。

### 根因：`IVRDemo` 在 asterisk 23 已被删成骨架

读 `apps/app_ivrdemo.c` 全文，`skel_exec()` 只做一件事：

```c
ast_ivr_menu_run(chan, &ivr_demo, tmp);   /* tmp = 传入的 filename */
```

而菜单 `ivr_demo` 的项是**硬编码**的：

```c
{ "s", AST_ACTION_BACKGROUND, "demo-congrats" },   /* 问候语 */
{ "g", AST_ACTION_BACKGROUND, "demo-instruct" },
{ "1", AST_ACTION_PLAYBACK, "digits/1" },
{ "2", AST_ACTION_MENU, &ivr_submenu },
...
```

结论：
- 传给 `IVRDemo(ufi-phones)` 的 `ufi-phones` **根本不作问候语用**；
- 问候语固定是 `demo-congrats` / `demo-instruct`；
- 设备上 `ls /usr/share/asterisk/sounds/demo-*.gsm | wc -l` = **0**；
- 所以拨 `*98` **必然全程静默**，无论 codec 是否修好。

设备日志铁证（修 codec 之前）：
```
NOTICE app.c: Unable to find file 'demo-congrats'!
NOTICE app.c: Unable to find file 'demo-instruct'!
```

### 修复：改用 `Playback` + `WaitExten`

在 `packages/ufi-voice/files/ufi-voice-asterisk-apply` 里重写 `[ivr-menu]`：

```
exten => *98,1,Answer()
 same => n(top),Playback(ufi-phones)
  same => n,WaitExten(30)
  same => n,GotoIf($["${EXTEN}" = "*"]?top)
  same => n,GotoIf($["${EXTEN}" = "*98"]?end)
  same => n,GotoIf($["${EXTEN}" = "s"]?end)
  same => n,Goto(ufi-phones,${EXTEN},1)
 same => n(end),Hangup()
```

按号码路由进 `ufi-phones`：`100`/`101` 转分机（离线则落信箱），其它号码走移动外呼，`*` 重复菜单。

**`WaitExten` 的坑**：呼叫者不输入时它**不改 `EXTEN`**，仍是入口扩展号（`*98` 或 `s`）。
若不显式把这两个值路由到挂断，呼叫会 `Goto(ufi-phones,*98,1)` **无限循环回菜单**。

### 第二个缺失文件：`ufi-phones` 从未被创建

即使 `IVRDemo` 的参数生效也无处可播——这个录音文件**从来没被创建过**。
新增 `install_ivr_greeting()`：从 stock 提示音复制出 `ufi-phones.gsm`，
优先级 `basic-pbx-ivr-main` → `vm-starmain` → `vm-intro`（本机只有 `.gsm`）。
已存在的文件不覆盖，允许用户替换成自己的录音。

### 决定性验证方法（本构建缺 Record/MixMonitor）

本 asterisk 只装了 9 个 app（无 `Record`、无 `MixMonitor`，实测
`No application 'MixMonitor'/'Record'`）。无法录音取证。

改用 **`AudioSocket`**（`app_audiosocket.so` 已装，且正是移动外呼的生产通路）：
起本地 TCP 监听器 `127.0.0.1:9093`，让 `AudioSocket(uuid,127.0.0.1:9093)` 把通道音频
送过来数字节。**抓到 200,279 字节 ≈ 31 秒有声内容** → 问候语确实在发声、
`gsm→slin→ulaw` 转码链有效。

### 排查中暴露的其它事实
- 提示音**不在语言子目录**：`/usr/share/asterisk/sounds/en/` 是**空的**，
  实际全在 `/usr/share/asterisk/sounds/*.gsm`（358 个）。按 `en/` 查会误判"文件不存在"。
- `messages.log` 默认只记 `notice,warning,error`。**成功的播放/转码不产生任何日志**，
  因此"没有日志 ≠ 没有播放"。
- 开 verbose：改 `logger.conf` 的 `[logfiles]` 行加 `verbose,debug,dtmf`，
  但 **`logger reload` 不生效**，必须重启 asterisk。
- asterisk 23 **无** `logger enable <file> <level>`、无 `pjsip set bsd`、无 `core show logging`；
  只能 `logger add channel`、`core set verbose N`、`pjsip set logger`。
- `logger.conf` **不能**出现 `(!)`（那是 asterisk.conf 的类别引用），
  否则报 `No '=' (equal sign) in line 2`。
- `Set(TIMEOUT(soft)=30)` 非法：`func_timeout.c: Unknown timeout type specified.`
  （合法类型：all/ring/proceed/warm/progress/alerting/confirm）。

### 构建/部署注意
- 本机构建目录 `build_dir/.../asterisk-23.1.0/` 里**没有** `main/ivr.c`（asterisk 23 已删），
  想查 `ast_ivr_menu_run` 源码需另找上游。
- `packages/ufi-voice/`（顶层跟踪）与 `openwrt/package/msm8916/ufi-voice/` 是**两份副本**，
  改动必须两边同步，否则只进 git 不进镜像。

## 关键文件
- `openwrt/target/linux/msm89xx/patches/869-arm64-dts-qcom-add-msm8916-generic-mf32lt.patch`（iris wcn3620）
- `openwrt/package/msm8916/qcom-firmware/`（mf32 固件，md5 与 ImmortalWrt 一致）
- `openwrt/package/msm8916/ufi-voice/`（ufi-voice + ufi-voice-asterisk，`ufi-voice-asterisk-apply` 生成 asterisk 配置）
- `openwrt/package/msm8916/imei-tool/`、`luci-app-cellular/`、`qmi-modem-410-init/`（已移植）
