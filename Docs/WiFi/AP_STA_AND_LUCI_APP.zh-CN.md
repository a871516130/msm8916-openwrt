> 📄 本文件是 [AP_STA_AND_LUCI_APP.md](AP_STA_AND_LUCI_APP.md) 的英文原文中文译本，内容以英文版为准。

# 并发 AP+STA 与 Station Mode LuCI 应用

*状态：已随附并在 HMUF02-V5 上验证（2026-10-24 / 2026-10-25）。*

WCN36xx 无线电可以同时充当访问点**以及**另一个访问点的客户端。 本文档是该
功能的用户指南——确立*为什么*必须如此工作的逆向工程日志见
[`WCN36XX_AP_STA_RE.md`](WCN36XX_AP_STA_RE.md)。

---

## 1. 你能得到什么

- 无线电在关联到上游网络**的同时**继续为自己的 AP 发送信标（客户端保持
  连接）。
- 一切都从 LuCI 的 **Network → Station Mode** 配置——两个视图，
  *Overview* 和 *Configuration*——或从 `/etc/config/wifista`。
- **`/etc/config/wireless` 不会被碰。** 这是有意为之，不是疏忽（见 §2）。

典型用途：在盒子仍提供自己 AP 的同时给它一条 Wi‑Fi 上行，或把手机热点当作
LTE 承载旁边的备用路径。

---

## 2. 为什么 station 不是一个 `wifi-iface`

第二个带 `option mode 'sta'` 的 `config wifi-iface` 看起来是显然的做法，
而且确实可行——直到 phy 重启。 netifd 的 Wi‑Fi 脚本在**每一次**无线配置
变更时都会重启 phy，包括启动时，而**在该 phy 上配置了受管接口时重启 phy
会杀死 WCNSS 固件**：

```
boot_exception_c_handlers.c:108: Data Abort Exception at 0x8b6b301c
```

这不是关联问题——用一个仅扫描的 station（根本没有匹配的 SSID）也能复现，
甚至 station 接口从未被拉起也能复现，只要 phy 重启时它存在。 因为 netifd
在每次无线保存时都重启 phy，“在 LuCI 里加个 STA 接口”永远不可能安全。

所以 station 是在 AP 起来并运行**之后**用 `iw` 创建的：

```
iw phy phy0 interface add phy0-sta0 type managed addr 00:11:22:33:44:77
ip link set phy0-sta0 up
wpa_supplicant -D nl80211 -i phy0-sta0 -c ...
```

它也被隔离在 netifd 之外：netifd 没有为它自己没创建的 vif 准备设备对象，
因此 `option device 'phy0-sta0'` 会以 `NO_DEVICE` 失败。 于是改为直接运行
`udhcpc`。

> **崩溃现状（2026-10-26）。** `0x8b6b301c` abort 在 25.12.6 backports
> （6.18.55）上**不能**复现：受管 station 在 `wifi reload` 下 6/6 存活，
> 零崩溃。 上述设计因第二个独立原因而保留——受管 station 大约每三次启动
> 只有一次能关联，而失败时会丢失无线电的扫描状态。见
> [WCN36XX_AP_STA_RE.md](WCN36XX_AP_STA_RE.md#attempt-3-2026-10-26--reliability-measured-not-adopted)。

---

## 3. 快速开始（LuCI）

1. **Network → Station Mode → Configuration**
2. 勾选 **Enable station mode**
3. **Saved networks** —— *首次保存时可选*：加一行，输入 SSID（或按
   **Scan** 并在某行上用 *Use*——它会填入第一个空行），以及密码。
   没有行时 station 只是保持空闲，因此表单可以先保存、以后再填。
4. **Station MAC address** —— 必须与 AP 的 MAC 不同（默认的
   `00:11:22:33:44:77` 就可以）
5. **Save & Apply**

可以保存任意数量的网络：每个启用的行给 `wpa_supplicant` 一个 `network=` 块，
它会加入范围内那个，密码被拒绝时就转到下一个。 被拒绝的密码会在
**Overview** 页面（*Wrong password: …*）和日志中标出并点名该网络——修好那一行
再 Save & Apply；与此同时设备会继续尝试其他网络。

服务立即重启；station 通常几秒内就关联上。 **Overview** 显示实时状态，
每 5 s 刷新一次。

### 从 shell 做同样的事

```sh
uci set wifista.main.enabled=1
uci set wifista.net1=ap
uci set wifista.net1.ssid='MyHomeWiFi'
uci set wifista.net1.key='secret'
uci commit wifista
/etc/init.d/wifi-sta-late restart

# state, machine-readable (profiles= and wrong_key= included)
/usr/sbin/wifi-sta-up status
```

---

## 4. 配置参考（`/etc/config/wifista`）

| 选项 | 默认值 | 含义 |
|---|---|---|
| `enabled` | `0` | 主开关。 默认关闭——服务立即退出。 |
| `ssid` / `key` | *（空）* | **传统单网络** —— 只在没有 `ap` 段时使用（LuCI 页面首次保存时会把这对值迁入一行）。 `ssid` 为空 = 完全没有网络；station 保持空闲（记录一次，然后每 5 分钟重试）。 |
| `macaddr` | *（空 —— 推导）* | station vif 的地址。 留空则服务从 AP 的地址推导一个（末字节 + 1，跨重启稳定）。 它**必须与 AP 的不同**：否则由 `iw` 创建的 vif 会克隆 AP 的地址，`ip link set up` 会以令人误解的 `RTNETLINK answers: No error information` 失败。 |
| `dhcp` | `1` | 运行 `udhcpc`。 租约**只**安装地址——没有默认路由，因此 LTE/移动路径保持为默认。 |
| `hostname` | *（空）* | 作为 DHCP option 12（`udhcpc -x hostname:…`）向上游网络通告的名称，这样上游路由器可以按名解析本设备。 为空 = 系统主机名（`system.@system[0].hostname`，否则用 kernel 的）。 |
| `radio` | `radio0` | 哪个无线电的信道跟随上游。 |
| `recover_after` | `60` | station 允许 down 多少秒后看门狗会回收它。 `0` 禁用该检查。 |
| `wait_ap_timeout` | `60` | 服务等待 hostapd 上报 `ENABLED` 多久后放弃（下次启动会重试）。 |

### 已保存的网络（`wifista.ap` 段）

任意数量的 `ap` 段；每一段是生成的 `wpa_supplicant` 配置里的一个
`network=` 块：

| 选项 | 默认值 | 含义 |
|---|---|---|
| `ssid` | — | 网络名。 没有 SSID 的行会被忽略。 |
| `key` | *（空）* | WPA/WPA2/WPA3 口令。 为空 = 开放网络。 |
| `disabled` | `0` | 保留该行但绝不尝试它。 |

```sh
# two networks, one temporarily off
uci set wifista.net1=ap; uci set wifista.net1.ssid='androidap'; uci set wifista.net1.key='testtest'
uci set wifista.net2=ap; uci set wifista.net2.ssid='home';     uci set wifista.net2.key='secret'
uci set wifista.net3=ap; uci set wifista.net3.ssid='old';     uci set wifista.net3.key='x'; uci set wifista.net3.disabled=1
```

`wpa_supplicant` 会选择范围内（信号 + 安全性）的任一已保存网络，因此不需要
优先级字段；信道同步（§5）跟随**扫描中可见的第一个已保存网络**。 密码被拒绝时，
该网络被 `wpa_supplicant` 自己拉黑并尝试其他网络——拒绝会呈现给用户
（见 §6 的 *Wrong password*）。

---

## 5. 服务实际做什么

`/etc/init.d/wifi-sta-late`（`START=95`）监管**四个 procd 实例**，
全部带 `respawn 3600 5 0`，因此挂掉的辅助进程总会被重启：

| 实例 | 命令 | 职责 |
|---|---|---|
| `sta` | `wifi-sta-up sta` | 等待 AP、创建 vif，然后**在前台**运行 `wpa_supplicant` |
| `dhcp` | `wifi-sta-up dhcp` | 等待 `Connected`，然后在前台运行 `udhcpc` |
| `watchdog` | `wifi-sta-up watchdog` | 每 15 s 轮询，回收一直 down 的 station |
| `wpaevent` | `wpa_cli -a /usr/sbin/wifi-sta-wpa-event -i phy0-sta0` | 挂到 supplicant 的 ctrl socket；标记被拒绝的密码 |

`wpa_supplicant` 故意在前台运行：带 `-B` 它会守护化到 PPID 1，procd 就再也
无法重启它。

`wpaevent` 以 action 模式启动 `wpa_cli`：它留在前台（在 ctrl socket 上的
eloop——没有 stdin），并对每个 supplicant 事件运行 `wifi-sta-wpa-event`。
原厂 `wpa_cli` 会丢弃 `CTRL-EVENT-SSID-TEMP-DISABLED`（其分发中没有通用
回退），因此 hostapd overlay 带有补丁
`900-wpa-cli-dispatch-ssid-temp-disabled.patch` 来转发它。 当
`wpa_supplicant` 以 `reason=WRONG_KEY` 放弃某个网络时，脚本把 SSID 记入
`/var/run/wifi-sta-wrongkey`（连接时按 SSID 清除，每次 station 启动时整体
清除）并写日志；`wifi-sta-up status` 把它打印为 `wrong_key=`。

### 信道处理——一个无线电，一个信道

station **没有自己的信道**：它必须与所关联的 AP 同信道，而必须移动的是 AP。
因此在拉起时服务会：

0. 拒绝在 `channel='auto'` 上运行（见下文）——它先把无线电固定到一个
   具体信道，
1. 创建 vif 并 `ip link set up` 它（DOWN 的 netdev 无法扫描），
2. 扫描已保存的网络并读取**范围内第一个**的信道，
3. 如果与 AP 的信道不同：**先删除 vif**，设置
   `wireless.<radio>.channel`，运行 `wifi reload`，等待 AP 重新 `ENABLED`，
   再创建 vif，
4. 然后启动 `wpa_supplicant`。

否则信道不匹配会悄无声息且令人困惑：`SME: Authentication request to
the driver failed` 出现在不断加大的退避循环里，拿不到租约——但不崩溃。

**为什么拒绝 `auto`。** 用 `channel='auto'`，hostapd 每次 AP 启动都跑一次
ACS 扫描，而 wcn36xx 可能丢一次扫描，随后对之后每一次都以 `-EBUSY` 应答，
直到下次启动。 当 ACS 是受害者时，AP 起来时**既没有信道也没有 SSID**，
于是整个无线电都死了——一次失败的 station 尝试把访问点一起带走。
`wifi-sta-up` 中的 `ensure_fixed_channel` 因此在一切之前运行：当 AP 已经在
某信道发信标时就采用那个信道（无中断、无 reload），否则固定为 **6** 并重启
无线电，好让 AP 真正起来。 日志行是
`radio 'radio0' had channel 'auto'; pinning it to N`。 一旦固定，上面第 3 步
仍可像往常一样把 AP 移到上游的信道。

AP 自己的客户端在信道变更时会看到一次短暂掉线（不发送 CSA）。

### 看门狗

每 15 s：如果 station 已经 down 了 `recover_after` 秒，就扫描并比较信道。

- **不匹配** → 记日志、删除 vif、杀掉 `wpa_supplicant`/`udhcpc`；procd
  重启 `sta`/`dhcp`，它们会重跑信道同步。
- **无匹配**（上游不在、密钥错误）→ 交给 `wpa_supplicant`；记一次日志，
  之后每五个周期记一次。 **密码错误**不*在这里*处理——它由 `wpaevent`
  实例上报。
- **vif 消失** → 无条件回收。

删除 vif **不会**让 `wpa_supplicant` 退出（pid 不变，procd 永远不会重启
它），所以看门狗显式杀掉它。

---

## 6. LuCI 应用（`luci-app-wifi-sta`）

**Network → Station Mode**（order 30，在 *Wireless* 之后）。 通过
`DEFAULT_PACKAGES`（`msm89xx/Makefile`）随每块板子发行，因此每个镜像都带它。

### Overview

- 状态每 5 s 从 `wifi-sta-up status` 轮询
- AP：接口、hostapd 状态、信道、客户端数量
- STA：接口、已连接/未连接、SSID、BSSID、信道、信号、tx bitrate、地址、
  已保存网络数量
- 警告：**“Wrong password: …”**（红色——点名被拒绝的网络，并把修复链接到
  Configuration 标签页）、信道不匹配，以及
  **“a station interface is still configured in the wireless config”** ——
  那个是 §2 的崩溃风险
- 按钮：**Restart service**、**Stop**、**Start**、**Show log**

状态契约是**每行一个 `key=value`，别无其他**。 每个值在打印前都把 CR/LF
折成空格（SSID 合法地可以包含换行，原样的换行会注入第二个 key）。
**缺失**的 key 表示“未知 / 不适用”，页面渲染为破折号——station 未连接时
`sta_signal` 和 `sta_bitrate` 缺失，完全没有 station 接口时整个 `sta_*`
块缺失。

解析说明，因为 `iw` 输出跨版本不稳定：SSID 用 `sed 's/^\s*SSID: //'` 取，
而不是 `awk -F': '`（SSID 本身可能包含 `": "`），信号/bitrate 字段按标签
而不是按位置定位（iw 可能打印 `signal: -55 [-60, -58] dBm`，旧构建把
`tx bitrate:` 与 `signal:` 放在同一行）。

### Configuration

`wifista.main` 段（§4 的表格）加上 **Saved networks** 表格
（增删 SSID + 密码 + disabled 的行）。 **Scan** 按钮运行
`iwinfo <ap_iface> scan`；某行上的 *Use* 会填入已保存网络表格中**第一个
空的** SSID 字段（或提示你添加/清空一行）。 **Save & Apply** 提交
`wifista` 并重启服务——SSID、密钥或 profile 列表的更改无需重启即生效。
没有 `ap` 行的传统 `wifista.main.ssid`/`key` 对在加载时会迁入一行
（Save 时提交）。

该应用**只**写 `/etc/config/wifista`。

扫描是纯只读操作——在 AP 接口上做 netlink 硬件扫描，绝不在 station vif 上，
也绝不碰无线配置（不重启 phy、不 `wifi reload`）。 它只在状态输出确实报告了
AP 接口时才运行；否则按钮会解释 Wi‑Fi 未起来，而不是对着一个猜测的名字
exec。 2026-10-25 实机验证：`iwinfo phy0-ap0 scan` —— 直接调用以及通过
rpcd `file exec`（确切的 LuCI 路径）——在服务禁用时、在存在孤儿受管 vif 时、
以及在 AP 接口 down 时都是无害的（只是返回一个 netlink 错误）；没有固件
错误、没有重启、正常运行时间不受影响。 2026-10-25 点击扫描附近看到的设备
重启是调制解调器笔记中记录的无关冷断电。

### 权限

`/usr/share/rpcd/acl.d/luci-app-wifi-sta.json` 授予：

- 读：uci `wifista` + `wireless`；exec `/usr/sbin/wifi-sta-up`、
  `/etc/init.d/wifi-sta-late`、`/usr/sbin/iw`、`/usr/bin/iwinfo`、
  `/sbin/logread`
- 写：uci `wifista`；exec `/usr/sbin/wifi-sta-up` 和 init 脚本

**已用受限登录验证。** root 在 `/etc/config/rpcd` 里有 `read '*' / write '*'`，
所以 root 会话完全绕过 ACL、什么也证明不了——检查必须以*只有*
`luci-app-wifi-sta` 组的登录来跑。 曾创建、使用并删除了这样一个临时登录：

| 调用（以受限登录） | 结果 |
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
| `uci apply` | 允许 —— 提交，且服务重启 |
| `uci get wireless`（radio 列表） | 允许，只读 |
| `uci set wireless` | **拒绝** |
| `uci get network` | **拒绝** |

以该登录经 uhttpd 端到端测试：
`/cgi-bin/luci/admin/network/wifi-sta/{overview,config}` → **200**，而
`/admin/network/wireless` 和 `/admin/status/overview` → **403**。 菜单的
`depends.acl` 门控同样有效，因为这些路由都解析成功。

> **关于 ACL 形状的说明。** 代码树中其他每个应用都在文件路径旁边列出
> `"ubus": { "file": [ "exec" ] }`，但 rpcd 通过 `file` 和 `uci` 对象各自的
> scope 来强制执行：用本应用的 ACL（它没有 `ubus.file` 条目），
> `session access` 报告 `ubus file.exec` = *false*，而实际的 `file exec`
> 调用却成功。 所以该条目不是必需的——它只是 `session access` 给出的答案。
> 页面中没有任何东西 consult 那个答案。

---

## 7. 验证记录

| 日期 | 检查 | 结果 |
|---|---|---|
| 2026-10-24 | 两个 vif 同时活动（AP 服务手机的同时关联上游） | 两者都在承载流量，0 崩溃 |
| 2026-10-24 | 刷入镜像上的启动拉起 | vif 创建，2 s 内关联，拿到租约，`crashes=0` |
| 2026-10-24 | 10 分钟浸泡测试 | 10/10 干净，rtt 45–108 ms |
| 2026-10-24 | 信道同步（AP 强制 ch1，上游 ch6） | AP 移到 ch6，4 s 后连接 |
| 2026-10-24 | 看门狗（模拟上游移动） | 60 s 时检测到，约 40 s 恢复，0 崩溃 |
| 2026-10-24 | `stop` → `wifi reload` → `start` | 0 崩溃 |
| 2026-10-25 | 刷入镜像上的 LuCI 应用 | 两个视图 HTTP 200 |
| 2026-10-25 | ACL，以**受限**登录演练（root 绕过 ACL） | 页面发起的每次调用都被允许；`/bin/sh` exec、`/etc/shadow`、`uci set wireless` 被拒绝；受限用户在两个视图都得到 200、在 Wireless/Status 得到 403 |
| 2026-10-25 | Save & Apply 路径（`uci set` RPC → `uci apply`） | 配置已提交，`sta` 实例在 <1 s 内重启，重新关联，同一租约 |
| 2026-10-26 | **Guard，在 25.12.5 上、station 已关联时实测** —— `uci set wireless.radio0.channel=6; wifi reload`（强制 teardown+setup） | **`crashes=0`**。 Syslog：`18:59:28 wifi-sta-guard: station stopped for a phy restart` → `18:59:29 wifi-sta-guard: phy restarted; restarting the station`。 `wpa_supplicant` PID 1709 → 25687（服务确实被停了）。 AP 回到 ch11（station 信道同步），station 在 4 s 内重新关联，同一租约 `10.162.21.33` |
| 2026-10-26 | 对照：无线配置**未变**时的 `wifi reload` | guard **不**触发（netifd 在什么都没变时不碰 phy）—— 0 崩溃，supplicant PID 不变。 崩溃需要配置变更；裸 reload 是空操作 |

---

## 8. 故障排查

| 症状 | 原因 | 修复 |
|---|---|---|
| 菜单里没有 **Station Mode** 条目 | 软件包不在镜像里 | `apk info -e luci-app-wifi-sta`；它是 `DEFAULT_PACKAGES` 条目——检查 `msm89xx/Makefile` |
| Overview 显示 *not connected*，日志反复出现 `SME: Authentication request to the driver failed` | 上游在不同信道，扫描没找到它 | 确认上游在范围内（`iwinfo phy0-ap0 scan`）；服务会在下次重启时重新同步 |
| `ip link set up` 时报 `RTNETLINK answers: No error information` | vif 拿到了 AP 的 MAC | 让 `wifista.main.macaddr` 留空（推导）或设一个不同地址 |
| 页面以 `RPC call to uci/get failed with ubus code 4: Resource not found` 失败 | 现场的 `/etc/config/wifista` 缺失，因此 `uci.load('wifista')` 在表单渲染之前就被拒绝。 `base-files` 随附该文件，所以这意味着它被删了——而普通 `rm` 会留下 overlay **whiteout**，跨重启一直遮住镜像里的副本 | 删掉 whiteout（`rm /overlay/upper/etc/config/wifista`）并重启，或用 `cp /rom/etc/config/wifista /etc/config/wifista` 拷回来 |
| `ctrl_iface exists and seems to be in use` | 有残留的 `wpa_supplicant` | `/etc/init.d/wifi-sta-late restart`（服务会移除残留的 socket） |
| station 连上了，没有地址 | 上游没有 DHCP，或 `dhcp=0` | 上游启用 DHCP / 设 `dhcp=1` |
| 启动时 AP 的客户端掉线一秒 | AP 跟随了上游的信道 | 预期行为；只在信道不同时发生 |
| 保存 **Wireless** 设置时 AP 重启 / 调制解调器掉线 | STA vif 存在时 phy 重启——§2 中的 bug | **自 25.12.6 起已修复**：netifd 用 `wifi-sta-guard`（`openwrt-patches/811`）括住 phy 重启，所以不应再发生。 如果仍发生，检查 `/usr/sbin/wifi-sta-guard status` 和 `logread \| grep wifi-sta`（§9） |

---

## 9. 注意事项

- **station 运行时 `wifi reload` 和 **Save & Apply** 是安全的**（自 25.12.6
  起）。 `openwrt-patches/811` 钩住 netifd 的无线驱动：

  | netifd 调用 | guard 动作 |
  | :--- | :--- |
  | `setup()` | `wifi-sta-guard down` … phy 已配置 … `wifi-sta-guard up` |
  | `teardown()` | `wifi-sta-guard down`（配套的 setup 会重启它） |

  该钩子在 wifi-scripts 发行的**两个**驱动里都有——`files/`（shell）和
  `files-ucode/`（ucode）——因为当 `CONFIG_WIFI_SCRIPTS_UCODE=y` 时
  ucode 版本会覆盖 shell 版本安装，而那是默认值，也是本目标的构建方式。

  `down` 停止 `wifi-sta-late`（它会杀掉 `wpa_supplicant`/`udhcpc` 并删除
  `phy0-sta0`）并等待两者真的消失；`up` 只在 `down` 确实停了东西时才重启它，
  因此启动和空操作的 reload 不会提前启动 station，服务自身改信道的 reload
  也不会杀死自己。 当 Station Mode 禁用时两个动词都是空操作。

  ```sh
  wifi-sta-guard status
  # enabled=1 station_up=1 stopped=0
  ```

  **仍然**是坑的：任何*绕过* netifd 去重置无线电的东西——裸的
  `iw dev wlan0 del`、`rmmod wcn36xx`、驱动重新绑定。 对那些情况，先停服务：

  ```sh
  /etc/init.d/wifi-sta-late stop
  # ...do the thing...
  /etc/init.d/wifi-sta-late start
  ```
- **单信道。** AP 和 station 共用一个无线电，所以 AP 必须坐在上游的信道上。
  没有第二个信道可以放 AP。
- **让 `wireless.radio0.channel` 固定 —— 绝不 `auto`。** `auto` 让 hostapd
  每次 AP 启动都跑 ACS 扫描。 wcn36xx 可能丢一次扫描，随后在本次启动剩余
  时间里对每次扫描都以 `-EBUSY` 应答；用 `auto` 时那也会杀死 AP（它永远选
  不出信道，起来时没有 SSID），于是整个无线电死到下次重启为止。 固定信道
  保持 AP 可用，并让服务的 `recover_after` 看门狗能重试 station。
  服务强制执行这一点：启动时它把 `auto` 固定为 AP 当前的信道，AP 没有信道时
  固定为 **6**，并记录 `pinning it to N`。
- **普通的 `wifi-iface mode=sta` 不是替代品。** 它在 2026-10-26 被移植并
  测量过（backports 6.18.55，因此没有固件崩溃）：它大约每三次启动只有一次
  能关联，而失败时恰好像上面那样丢失无线电的扫描状态。 该服务的存在正是
  因为那个，而不只是因为旧崩溃——见
  [WCN36XX_AP_STA_RE.md](WCN36XX_AP_STA_RE.md#attempt-3-2026-10-26--reliability-measured-not-adopted)。
- **租约不带来默认路由。** station 拿到地址、在其子网内可达，但移动承载
  仍是默认路径。
- station 对 netifd/LuCI *Wireless* 不可见——这是有意的。

---

## 10. 文件

| 路径 | 作用 |
|---|---|
| `msm89xx/base-files/etc/config/wifista` | UCI 配置（默认禁用） |
| `msm89xx/base-files/usr/sbin/wifi-sta-up` | 整个服务：`sta` / `dhcp` / `watchdog` / `status` |
| `msm89xx/base-files/usr/sbin/wifi-sta-dhcp.sh` | udhcpc 处理器 —— 只要地址，绝不要默认路由 |
| `msm89xx/base-files/etc/init.d/wifi-sta-late` | procd 监督器 + `config.change` reload 触发器 |
| `msm89xx/base-files/etc/uci-defaults/95-wifi-sta-late` | 首次启动时启用 init 脚本 |
| `packages/luci-app-wifi-sta/` | LuCI 应用（菜单、ACL、`overview.js`、`config.js`） |
| `openwrt-overlay/package/kernel/mac80211/patches/ath/452-*` | mac80211：通告 `{AP}<=1,{managed}<=1` |
| `openwrt-overlay/package/kernel/mac80211/patches/ath/458-*` | wcn36xx：并发时抑制 BMPS |
| `Docs/WiFi/WCN36XX_AP_STA_RE.md` | 上述一切背后的实验 |
