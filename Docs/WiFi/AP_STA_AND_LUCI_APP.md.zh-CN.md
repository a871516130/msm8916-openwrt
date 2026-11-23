# 并发 AP+STA 与 Station Mode LuCI 应用

*状态：已在 HMUF02-V5 上交付并验证（2026-10-24 / 2026-10-25）。*

WCN36xx 无线收发器可以同时充当接入点**和**另一接入点的客户端。本文档是该功能的用户指南——确立*为什么*必须这样工作的逆向工程记录见 [`WCN36XX_AP_STA_RE.md`](WCN36XX_AP_STA_RE.md)。

---

## 1. 你能得到什么

- 收发器在关联到上游网络**的同时**，持续发送自身 AP 的信标（客户端保持连接）。
- 所有配置都通过 LuCI 中的 **Network → Station Mode** 完成——两个视图，*Overview* 与 *Configuration*——或通过 `/etc/config/wifista`。
- **`/etc/config/wireless` 不会被改动。** 这是有意的，不是疏忽（见 §2）。

典型用途：让设备在上游网络中提供自身 AP 的同时获得 Wi-Fi 上行链路，或作为 LTE 承载旁边的备份路径接入手机热点。

---

## 2. 为什么 station 不是一个 `wifi-iface`

带 `option mode 'sta'` 的第二个 `config wifi-iface` 看起来是显而易见的方式，而且它确实能用——直到 phy 重启为止。netifd 的 Wi-Fi 脚本在**每次**无线配置变更时都会重启 phy，包括开机时，而**在配置了 managed 接口的 phy 上重启 phy 会杀死 WCNSS 固件**：

```
boot_exception_c_handlers.c:108: Data Abort Exception at 0x8b6b301c
```

这不是关联问题——用仅扫描的 station（完全没有匹配的 SSID）也能复现，甚至 station 接口从未被启动也能复现，只要它在 phy 重启时存在。由于 netifd 在每次无线保存时都重启 phy，"只需在 LuCI 里加一个 STA 接口"永远不可能安全。

因此 station 是在 AP 启动**之后**用 `iw` 创建的：

```
iw phy phy0 interface add phy0-sta0 type managed addr 00:11:22:33:44:77
ip link set phy0-sta0 up
wpa_supplicant -D nl80211 -i phy0-sta0 -c ...
```

它也刻意被排除在 netifd 之外：netifd 对它未创建的 vif 没有设备对象，所以 `option device 'phy0-sta0'` 会失败并报 `NO_DEVICE`。`udhcpc` 改为直接运行。

> **崩溃状态（2026-10-26）。** 在 25.12.6 backports（6.18.55）上，`0x8b6b301c` 中止**不再**复现：managed station 在 `wifi reload` 下 6/6 存活且零崩溃。上述设计之所以保留，是出于第二个独立的原因——managed station 大约每三次开机才关联成功一次，而这些失败会丢失无线电的扫描状态。参见 [WCN36XX_AP_STA_RE.md](WCN36XX_AP_STA_RE.md#attempt-3-2026-10-26--reliability-measured-not-adopted)。

---

## 3. 快速开始（LuCI）

1. **Network → Station Mode → Configuration**
2. 勾选 **Enable station mode**
3. **Saved networks** ——*首次保存时可选*：添加一行，输入 SSID（或按 **Scan** 并在某一行上用 *Use*——它会填充第一个空行），以及密码。没有行时 station 保持空闲，所以表单可以先保存、稍后再填。
4. **Station MAC address** ——必须与 AP 的 MAC 不同（默认 `00:11:22:33:44:77` 即可）
5. **Save & Apply**

可以保存任意数量的网络：`wpa_supplicant` 为每个启用行生成一个 `network=` 块，并连接范围内任意一个，密码被拒时跳到下一个。被拒的密码会在 **Overview** 页面标记（*Wrong password: …*）并在日志中注明网络名——修复该行并 Save & Apply；设备同时继续尝试其他网络。

服务会立即重启；station 通常在几秒内关联成功。**Overview** 显示实时状态，每 5 秒刷新一次。

### 从 shell 做同样的事

```sh
uci set wifista.main.enabled=1
uci set wifista.net1=ap
uci set wifista.net1.ssid='MyHomeWiFi'
uci set wifista.net1.key='secret'
uci commit wifista
/etc/init.d/wifi-sta-late restart

# 状态，机器可读（包含 profiles= 和 wrong_key=）
/usr/sbin/wifi-sta-up status
```

---

## 4. 配置参考（`/etc/config/wifista`）

| 选项 | 默认值 | 含义 |
|---|---|---|
| `enabled` | `0` | 主开关。默认关闭——服务立即退出。 |
| `ssid` / `key` | *（空）* | **旧式单一网络**——仅在没有 `ap` 段时使用（LuCI 页面在首次保存时会把这一对迁移成一行）。`ssid` 为空 = 完全没有网络；station 保持空闲（记录一次，然后每 5 分钟重试）。 |
| `macaddr` | *（空——自动推导）* | station vif 的地址。留空则服务从 AP 的地址推导一个（最后一字节 + 1，重启间保持稳定）。它**必须与 AP 的不同**：否则用 `iw` 创建的 vif 会克隆 AP 的地址，`ip link set up` 会以误导性的 `RTNETLINK answers: No error information` 失败。 |
| `dhcp` | `1` | 运行 `udhcpc`。租约**只**安装地址——不设默认路由，因此 LTE/移动路径保持默认。 |
| `hostname` | *（空）* | 作为 DHCP 选项 12 通告给上游网络的名称（`udhcpc -x hostname:…`），使上游路由器能按名称解析此设备。空 = 系统主机名（`system.@system[0].hostname`，否则内核的）。 |
| `radio` | `radio0` | 哪个无线电的信道跟随上游。 |
| `recover_after` | `60` | station 可保持关闭的秒数，之后看门狗回收它。`0` 禁用该检查。 |
| `wait_ap_timeout` | `60` | 服务等待 hostapd 报告 `ENABLED` 的时间，超时则放弃（下次启动时重试）。 |

### 已保存网络（`wifista.ap` 段）

任意数量的 `ap` 段；每个是生成的 `wpa_supplicant` 配置中的一个 `network=` 块：

| 选项 | 默认值 | 含义 |
|---|---|---|
| `ssid` | — | 网络名。没有 SSID 的行会被忽略。 |
| `key` | *（空）* | WPA/WPA2/WPA3 密码。空 = 开放网络。 |
| `disabled` | `0` | 保留该行但从不尝试。 |

```sh
# 两个网络，一个临时关闭
uci set wifista.net1=ap; uci set wifista.net1.ssid='androidap'; uci set wifista.net1.key='testtest'
uci set wifista.net2=ap; uci set wifista.net2.ssid='home';     uci set wifista.net2.key='secret'
uci set wifista.net3=ap; uci set wifista.net3.ssid='old';     uci set wifista.net3.key='x'; uci set wifista.net3.disabled=1
```

`wpa_supplicant` 会选择范围内任意已保存网络（信号 + 安全），所以不需要优先级字段；信道同步（§5）跟随**扫描中可见的第一个已保存网络**。当密码被拒时，该网络会被 `wpa_supplicant` 自己列入黑名单并尝试其他网络——拒绝会反馈给用户（见 §6 中的 *Wrong password*）。

---

## 5. 服务实际做什么

`/etc/init.d/wifi-sta-late`（`START=95`）监管**四个 procd 实例**，全部带 `respawn 3600 5 0`，因此死掉的辅助进程总会被重启：

| 实例 | 命令 | 任务 |
|---|---|---|
| `sta` | `wifi-sta-up sta` | 等待 AP，创建 vif，然后**前台**运行 `wpa_supplicant` |
| `dhcp` | `wifi-sta-up dhcp` | 等待 `Connected`，然后前台运行 `udhcpc` |
| `watchdog` | `wifi-sta-up watchdog` | 每 15 秒轮询，回收保持关闭的 station |
| `wpaevent` | `wpa_cli -a /usr/sbin/wifi-sta-wpa-event -i phy0-sta0` | 挂到 supplicant 的 ctrl socket；标记被拒的密码 |

`wpa_supplicant` 刻意在前台运行：用 `-B` 它会守护化到 PPID 1，procd 就无法再重启它。

`wpaevent` 以 action 模式启动 `wpa_cli`：它保持前台（在 ctrl socket 上的 eloop——无 stdin），并对每个 supplicant 事件运行 `wifi-sta-wpa-event`。原版 `wpa_cli` 会丢弃 `CTRL-EVENT-SSID-TEMP-DISABLED`（其分发没有通用回退），因此 hostapd overlay 携带补丁 `900-wpa-cli-dispatch-ssid-temp-disabled.patch` 以转发它。当 `wpa_supplicant` 以 `reason=WRONG_KEY` 放弃某个网络时，脚本把 SSID 记入 `/var/run/wifi-sta-wrongkey`（连接时按 SSID 清除，每次 station 启动时整体清除）并记录日志；`wifi-sta-up status` 将其打印为 `wrong_key=`。

### 信道处理——一个无线电，一个信道

station **没有自己的信道**：它必须位于所关联 AP 所在的信道上，而移动的一方是 AP。因此服务在启动时：

0. 拒绝在 `channel='auto'` 上运行（见下文）——它先把无线电钉到具体信道，
1. 创建 vif 并 `ip link set up`（DOWN 的 netdev 无法扫描），
2. 扫描已保存网络并读取**范围内第一个**网络的信道，
3. 若与 AP 的信道不同：**先删除 vif**，设置 `wireless.<radio>.channel`，运行 `wifi reload`，等待 AP 再次 `ENABLED`，重新创建 vif，
4. 然后启动 `wpa_supplicant`。

否则不匹配是无声且令人困惑的：`SME: Authentication request to the driver failed` 在越来越大的退避循环中反复出现，并且没有租约——但不会崩溃。

**为什么拒绝 `auto`。** 用 `channel='auto'` 时，hostapd 在每次 AP 启动时执行 ACS 扫描，而 wcn36xx 可能丢失一次扫描，然后用 `-EBUSY` 回应之后的所有扫描直到下次开机。当 ACS 成为受害者时，AP 以**无信道且无 SSID** 的状态启动，整个无线电都死了——一次失败的 station 尝试会把接入点一起拖垮。因此 `wifi-sta-up` 中的 `ensure_fixed_channel` 在其他一切之前运行：当 AP 已在某个信道上发信标时，它就采用该信道（无中断、无重载），否则钉到 **6** 并重启无线电，使 AP 能够真正启动。日志行是 `radio 'radio0' had channel 'auto'; pinning it to N`。一旦钉住，上面的第 3 步仍可按常规把 AP 移到上游的信道上。

AP 自身的客户端在信道改变时会短暂掉线（不发送 CSA）。

### 看门狗

每 15 秒：如果 station 已关闭 `recover_after` 秒，则扫描并比较信道。

- **不匹配** → 记录日志，删除 vif，杀掉 `wpa_supplicant`/`udhcpc`；procd 重启 `sta`/`dhcp`，它们重新执行信道同步。
- **无不匹配**（上游不存在、密码错误）→ 交给 `wpa_supplicant`；记录一次，然后每五个周期记录一次。**密码错误***不*在此处理——它由 `wpaevent` 实例报告。
- **vif 消失** → 无条件回收。

删除 vif **不会**使 `wpa_supplicant` 退出（pid 不变，procd 从不重启），所以看门狗显式杀掉它。

---

## 6. LuCI 应用（`luci-app-wifi-sta`）

**Network → Station Mode**（顺序 30，在 *Wireless* 之后）。通过 `DEFAULT_PACKAGES`（`msm89xx/Makefile`）随每块板子一起提供，所以每个镜像都携带它。

### Overview

- 每 5 秒从 `wifi-sta-up status` 轮询状态
- AP：接口、hostapd 状态、信道、客户端数量
- STA：接口、已连接/未连接、SSID、BSSID、信道、信号、tx 比特率、地址、已保存网络数量
- 警告：**"Wrong password: …"**（红色——指明被拒的网络，链接到 Configuration 标签页的修复）、信道不匹配，以及**"station 接口仍配置在 wireless 配置中"**——那就是 §2 的崩溃风险
- 按钮：**Restart service**、**Stop**、**Start**、**Show log**

状态契约是**每行一个 `key=value`，别无其他**。每个值在打印前都折叠 CR/LF 为空格（SSID 合法地可能包含换行，原始换行会注入第二个键）。**缺失**的键表示"未知 / 不适用"，页面渲染为短横线——station 未连接时 `sta_signal` 与 `sta_bitrate` 不存在，完全没有 station 接口时整个 `sta_*` 块都不存在。

解析注意，因为 `iw` 输出在各版本间不稳定：SSID 用 `sed 's/^\s*SSID: //'` 而非 `awk -F': '`（SSID 本身可能包含 `": "`），signal/bitrate 字段按标签而非位置定位（iw 可能打印 `signal: -55 [-60, -58] dBm`，旧版构建把 `tx bitrate:` 放在与 `signal:` 同一行）。

### Configuration

`wifista.main` 段（§4 中的表格）加上 **Saved networks** 表（添加/删除 SSID + 密码 + disabled 行）。**Scan** 按钮运行 `iwinfo <ap_iface> scan`；某行上的 *Use* 会把 SSID 填进已保存网络表的**第一个空** SSID 字段（或提示你添加/清空一行）。**Save & Apply** 提交 `wifista` 并重启服务——更改的 SSID、密码或配置集无需重启即可生效。没有 `ap` 行的旧式 `wifista.main.ssid`/`key` 对会在加载时迁移成一行（保存时提交）。

该应用**只**写 `/etc/config/wifista`。

扫描是纯只读操作——在 AP 接口上的 netlink 硬件扫描，绝不在 station vif 上，也绝不触碰 wireless 配置（不重启 phy、不 `wifi reload`）。它仅在状态输出实际报告了 AP 接口时运行；否则按钮解释 Wi-Fi 未启动，而不是针对猜想的名称执行。2026-10-25 在设备上验证：`iwinfo phy0-ap0 scan`——直接调用以及通过 rpcd `file exec`（即 LuCI 的确切路径）——在服务禁用、存在孤儿 managed vif、以及 AP 接口关闭时都是惰性的（只返回 netlink 错误）；无固件错误、无重启、正常运行时间不受影响。2026-10-25 一次点击扫描时看到的设备重启，是调制解调器笔记中记载的无关冷电源丢失。

### 权限

`/usr/share/rpcd/acl.d/luci-app-wifi-sta.json` 授予：

- 读：uci `wifista` + `wireless`；exec `/usr/sbin/wifi-sta-up`、`/etc/init.d/wifi-sta-late`、`/usr/sbin/iw`、`/usr/bin/iwinfo`、`/sbin/logread`
- 写：uci `wifista`；exec `/usr/sbin/wifi-sta-up` 和 init 脚本

**用受限登录验证。** root 在 `/etc/config/rpcd` 里有 `read '*' / write '*'`，所以 root 会话完全绕过 ACL，证明不了任何事——检查必须作为仅持有 `luci-app-wifi-sta` 组的登录运行。临时创建、执行并移除了这样一个登录：

| 调用（作为受限登录） | 结果 |
|---|---|
| `exec /usr/sbin/wifi-sta-up status` | 允许 |
| `exec /etc/init.d/wifi-sta-late running` | 允许 |
| `exec /usr/bin/iwinfo phy0-ap0 scan` | 允许 |
| `exec /sbin/logread -e wifi-sta` | 允许 |
| `exec /bin/sh -c id` | **拒绝** |
| `read /etc/shadow` | **拒绝** |
| `read /etc/config/wireless` | **拒绝** |
| `uci get wifista` | 允许 |
| `uci set wifista` | 允许 |
| `uci apply` | 允许——提交，且服务重启 |
| `uci get wireless`（radio 列表） | 允许，只读 |
| `uci set wireless` | **拒绝** |
| `uci get network` | **拒绝** |

以该登录通过 uhttpd 端到端：`/cgi-bin/luci/admin/network/wifi-sta/{overview,config}` → **200**，而 `/admin/network/wireless` 和 `/admin/status/overview` → **403**。菜单 `depends.acl` 门控也正常，因为路由能解析。

> **关于 ACL 形状的说明。** 树中其他每个应用都在文件路径旁边列出 `"ubus": { "file": [ "exec" ] }`，但 rpcd 通过各自的作用域强制执行 `file` 与 `uci` 对象：用此应用的 ACL（没有 `ubus.file` 条目），`session access` 报告 `ubus file.exec` = *false*，而实际的 `file exec` 调用却成功。所以该条目不是必需的——它只是 `session access` 给出的答案。页面中没有任何东西会查询该答案。

---

## 7. 验证记录

| 日期 | 检查 | 结果 |
|---|---|---|
| 2026-10-24 | 两个 vif 同时激活（AP 服务手机的同时关联上游） | 两者都承载流量，0 崩溃 |
| 2026-10-24 | 烧录镜像上的开机启动 | vif 创建，2 秒内关联，租约，`crashes=0` |
| 2026-10-24 | 10 分钟浸泡 | 10/10 干净，rtt 45–108 ms |
| 2026-10-24 | 信道同步（AP 强制到 ch1，上游 ch6） | AP 移到 ch6，4 秒后连接 |
| 2026-10-24 | 看门狗（模拟上游移动） | 60 秒检测到，约 40 秒恢复，0 崩溃 |
| 2026-10-24 | `stop` → `wifi reload` → `start` | 0 崩溃 |
| 2026-10-25 | 烧录镜像上的 LuCI 应用 | 两个视图 HTTP 200 |
| 2026-10-25 | ACL，以**受限**登录执行（root 绕过 ACL） | 页面发出的每个调用都允许；`/bin/sh` exec、`/etc/shadow`、`uci set wireless` 被拒绝；受限用户两个视图 200，Wireless/Status 403 |
| 2026-10-25 | Save & Apply 路径（`uci set` RPC → `uci apply`） | 配置提交，`sta` 实例 <1 秒内重启，重新关联，同一租约 |
| 2026-10-26 | **保护，在 25.12.5 上 station 已关联时实测** —— `uci set wireless.radio0.channel=6; wifi reload`（强制 teardown+setup） | **`crashes=0`**。Syslog：`18:59:28 wifi-sta-guard: station stopped for a phy restart` → `18:59:29 wifi-sta-guard: phy restarted; restarting the station`。`wpa_supplicant` PID 1709 → 25687（服务确实被停止了）。AP 回到 ch11（station 信道同步），station 4 秒内重新关联，同一租约 `10.162.21.33` |
| 2026-10-26 | 对照：`wifi reload` 时 wireless 配置**未变** | 保护**不**触发（netifd 在无变化时不触碰 phy）——0 崩溃，supplicant PID 不变。崩溃需要配置变更；裸重载是空操作 |

---

## 8. 故障排除

| 症状 | 原因 | 修复 |
|---|---|---|
| 菜单中没有 **Station Mode** 条目 | 包不在镜像中 | `apk info -e luci-app-wifi-sta`；它是 `DEFAULT_PACKAGES` 条目——检查 `msm89xx/Makefile` |
| Overview 显示 *not connected*，日志重复 `SME: Authentication request to the driver failed` | 上游在不同信道上且扫描未找到 | 检查上游在范围内（`iwinfo phy0-ap0 scan`）；服务在下次重启时重新同步 |
| `ip link set up` 报 `RTNETLINK answers: No error information` | vif 拿到了 AP 的 MAC | 将 `wifista.main.macaddr` 留空（自动推导）或设置不同的地址 |
| 页面报 `RPC call to uci/get failed with ubus code 4: Resource not found` | 存活的 `/etc/config/wifista` 缺失，所以表单渲染前 `uci.load('wifista')` 被拒。`base-files` 提供该文件，因此这意味着它被删了——而简单的 `rm` 会留下一个 overlay **whiteout**，在重启间隐藏镜像副本 | `rm` 掉 whiteout（`rm /overlay/upper/etc/config/wifista`）并重启，或用 `cp /rom/etc/config/wifista /etc/config/wifista` 复制回来 |
| `ctrl_iface exists and seems to be in use` | 陈旧的 `wpa_supplicant` | `/etc/init.d/wifi-sta-late restart`（服务移除陈旧 socket） |
| Station 连接但无地址 | 上游无 DHCP，或 `dhcp=0` | 启用上游 DHCP / 设置 `dhcp=1` |
| 启动时 AP 的客户端掉线一秒 | AP 跟随了上游的信道 | 属预期；仅当信道不同时 |
| 保存 **Wireless** 设置时 AP 重启 / 调制解调器掉线 | STA vif 存在时 phy 重启——§2 的 bug | **自 25.12.6 起已修复**：netifd 用 `wifi-sta-guard`（`openwrt-patches/811`）括住 phy 重启，所以这不应再发生。若仍发生，检查 `/usr/sbin/wifi-sta-guard status` 和 `logread \| grep wifi-sta`（§9） |

---

## 9. 注意事项

- **`wifi reload` 与 **Save & Apply** 在 station 启动时是安全的**（自 25.12.6 起）。`openwrt-patches/811` 钩住 netifd 的 wireless 驱动：

  | netifd 调用 | 保护动作 |
  | :--- | :--- |
  | `setup()` | `wifi-sta-guard down` … phy 配置 … `wifi-sta-guard up` |
  | `teardown()` | `wifi-sta-guard down`（匹配的 setup 会重启它） |

  该钩子在 wifi-scripts 提供的**两个**驱动中都有——`files/`（shell）与 `files-ucode/`（ucode）——因为当 `CONFIG_WIFI_SCRIPTS_UCODE=y`（默认值，也是本 target 构建的值）时 ucode 版会覆盖 shell 版。

  `down` 停止 `wifi-sta-late`（它会杀掉 `wpa_supplicant`/`udhcpc` 并删除 `phy0-sta0`）并等待两者真正消失；`up` 仅在 `down` 确实停止了某物时才重启它，所以开机与空操作重载不会提前启动 station，服务自身的信道变更重载也不会杀死自己。当 Station Mode 禁用时两个动词都是空操作。

  ```sh
  wifi-sta-guard status
  # enabled=1 station_up=1 stopped=0
  ```

  **仍然**是个坑的是：任何*不经过* netifd 就重置无线电的东西——裸 `iw dev wlan0 del`、`rmmod wcn36xx`、驱动重新绑定。对这些，先停止服务：

  ```sh
  /etc/init.d/wifi-sta-late stop
  # ...做那件事...
  /etc/init.d/wifi-sta-late start
  ```
- **单信道。** AP 与 station 共享一个无线电，所以 AP 必须位于上游的信道上。没有第二个信道可放 AP。
- **保持 `wireless.radio0.channel` 固定——绝不用 `auto`。** `auto` 会让 hostapd 在每次 AP 启动时执行 ACS 扫描。wcn36xx 可能丢失一次扫描，然后用 `-EBUSY` 回应之后的所有扫描直到本次开机结束；用 `auto` 这也会杀死 AP（它从不选择信道，以无 SSID 状态启动），所以整个无线电死到下次重启。固定信道保持 AP 可用，并让服务的 `recover_after` 看门狗重试 station。服务强制执行此点：启动时它把 `auto` 钉到 AP 当前的信道，或当 AP 无信道时钉到 **6**，并记录 `pinning it to N`。
- **普通的 `wifi-iface mode=sta` 不是替代品。** 它在 2026-10-26 被移植并测量（backports 6.18.55，无固件崩溃）：约每三次开机关联一次，失败时与上述完全一样丢失无线电的扫描状态。服务之所以存在是因为这个，而不只是因为旧的崩溃——见 [WCN36XX_AP_STA_RE.md](WCN36XX_AP_STA_RE.md#attempt-3-2026-10-26--reliability-measured-not-adopted)。
- **租约不设默认路由。** Station 获得地址并可在其子网内被访问，但移动承载保持为默认路径。
- Station 对 netifd/LuCI *Wireless* 不可见——这是有意的。

---

## 10. 文件

| 路径 | 角色 |
|---|---|
| `msm89xx/base-files/etc/config/wifista` | UCI 配置（默认禁用） |
| `msm89xx/base-files/usr/sbin/wifi-sta-up` | 整个服务：`sta` / `dhcp` / `watchdog` / `status` |
| `msm89xx/base-files/usr/sbin/wifi-sta-dhcp.sh` | udhcpc 处理程序——仅地址，绝不做默认路由 |
| `msm89xx/base-files/etc/init.d/wifi-sta-late` | procd 监管器 + `config.change` 重载触发 |
| `msm89xx/base-files/etc/uci-defaults/95-wifi-sta-late` | 首次开机启用 init 脚本 |
| `packages/luci-app-wifi-sta/` | LuCI 应用（菜单、ACL、`overview.js`、`config.js`） |
| `openwrt-overlay/package/kernel/mac80211/patches/ath/452-*` | mac80211：通告 `{AP}<=1,{managed}<=1` |
| `openwrt-overlay/package/kernel/mac80211/patches/ath/458-*` | wcn36xx：在并发中抑制 BMPS |
| `Docs/WiFi/WCN36XX_AP_STA_RE.md` | 上述所有内容的实验依据 |
