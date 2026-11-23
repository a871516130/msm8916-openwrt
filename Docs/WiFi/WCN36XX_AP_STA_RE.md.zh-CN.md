# WCN36xx AP+STA —— 逆向工程调查与参考映射（2026-10-24）

状态：调查完成；实现已交付（用户指南见 [`AP_STA_AND_LUCI_APP.md`](AP_STA_AND_LUCI_APP.md)——服务、`luci-app-wifi-sta`、配置与故障排除）。是 WPA3 工作（补丁 451-453）与今年早些时候记录的 iface-combination 崩溃的配套文档。

## 目标与先前状态

目标：在 WCN3620 上并发 AP+STA（wcn36xx 驱动，backports 6.18.26）。
先前状态：补丁 452 通告仅 AP 的组合（`{AP} <= 2`），因为崩溃是 `remoteproc1 a204000` 致命（WCNSS 固件），即使信道匹配；mac80211 拒绝 STA+AP，除非驱动通告它。已记录的陷阱：`ADHOC & max>1` 组合使 probe 失败 -22（无 wiphy）。

## 调查发现

### 1. 上游（torvalds 树，drivers/net/wireless/ath/wcn36xx）

- 上游不存在并发或多 vif 工作——从未实现。仅更新驱动没有免费的好处。
- 本次调查回移了四个 6.18.26 之后的稳定性修复（暂存为 mac80211 补丁 454-457，commit f27adef）：
    - 88a240d86d: HAL 响应边界检查（堆溢出，固件可控）
    - df2187acfc: PRINT_REG_INFO 指示 OOB 读取
    - b5e6f21923: TRIGGER_BA 响应短读
    - d9be5e7553: TX-ack 计时器拆除 UAF
  上下文说明：454 需要改编——补丁 453 的 SET_THERMAL_MITIGATION_RSP case 位于同一个 switch 中。

### 2. 固件特性位图（现场转储，firmware_feat_caps debugfs）

WCNSS blob 通告：**MCC**、**P2P**、**P2P_GO_NOA_DECOUPLE_INIT_SCAN**、**SAP32STA**，加上信标/扫描/省电卸载、TDLS、WOW、CH144 等。P2P GO *就是* AP-with-STA 并发；MCC 是多信道并发。该 blob 自述具备并发能力——在证明相反之前，把崩溃当作**驱动**排序问题。

### 3. 固件镜像布局（wcnss.mdt，2026-10-24 解析）

ARM ELF（e_machine 40——不是 Hexagon），加载基址 0x8b600000，12 个段：
主固件 = ph6 / wcnss.b06（3.4 MB 文件，5.2 MB 内存——1.8 MB 清零 RAM，与 modem b19 相同的运行时补丁模式）；b10 = 640 KB 数据；b11 = 39 KB。
与 MPSS 相同的 PIL 签名（b01 中的哈希段 + RSA）——如果需要代码补丁，MPSS 的 auth-trap 规则适用。NV bin（WCNSS_qcom_wlan_nv.bin，29.8 KB）**未签名**——可自由补丁的配置杠杆。

## 参考实现（qcacld-2.0 / prima）

来源：Fairphone 2 内核（msm8916 + WCN3620——相同硅片），`ubports/android_kernel_fairphone_fp2` 分支 `ubp-5.1`，`drivers/staging/prima`。
副本归档在 `Docs/WiFi/reference/`（limSendMessages.c、wlan_hdd_hostapd.c、wlan_hdd_cfg80211.c、wlan_hdd_main.c）。

下游驱动做了而 wcn36xx 没做的事：

1. **带不同 MAC 的 Persona 模型。** `VOS_MAX_CONCURRENCY_PERSONA` 个 MAC 从 NV 读取（`vos_nv_readMultiMacAddress`）并按 persona 推导（serialno 步进）——每个接口获得自己的硬件地址。wcn36xx 为所有东西用一个 MAC。
2. **并发模式记账。** `wlan_hdd_set_concurrency_mode()` / `vos_concurrent_open_sessions_running()`；SCC 与 MCC 由信道相等决定（`apChannel==staChannel ? SCC : MCC`）。
3. **并发期间禁用 BMPS/IMPS。** "Disable BMPS incase of Concurrency"（wlan_hdd_main.c:6505）——两个 persona 活跃时省电被关闭。wcn36xx 有 pmc.c（IMPS）且**不**为第二个接口禁用它。
4. **会话模型。** 每个 persona 是带自身 id 的独立会话；SAP 启动（`wlan_hdd_cfg80211_start_ap` -> `wlan_hdd_cfg80211_start_bss` -> eSAP_START_BSS_EVENT）在 STA 会话保持关联时运行。
5. 每个 BSS 的 HAL 消息集：ADD_BSS + ADD_STA(self) + START_BSS + 信标模板。wcn36xx 反而发送合并的 CONFIG_BSS_REQ 和每个接口一个 ADD_STA_SELF。

## STA+AP 崩溃的分级假设

1. AP 发信标时 IMPS/BMPS 省电介入（qcacld 显式禁用它；wcn36xx 不禁）。最便宜的实验：补丁 pmc.c，在 AP vif 启动时拒绝 IMPS，重试 STA+AP。
2. 跨 vif 的 MAC 重复（两者共用一个 NV MAC）——像 qcacld 一样推导每 vif MAC（NV 多 MAC 或 base+step）。
3. CONFIG_BSS 单消息模型不处理第二个 BSS——按 qcacld 拆分为 ADD_BSS + ADD_STA + START_BSS 顺序。
4. 信道/策略差距（最不可能——崩溃发生在信道匹配时）。

## 后续步骤

1. 完成 400 MHz 热浸泡（进行中；独立线程）。
2. 崩溃捕获仪器：在崩溃时武装一个 WCNSS 转储读取器（a204000），复现一次 STA+AP，识别出错的 PC/断言文本。
3. 在构建标志后实现假设 1（pmc 保护）；在 454-457 鲁棒性修复就位时重试 STA+AP。
4. 针对 `Docs/WiFi/reference/` 对假设 2-3 做序列差异。
5. 仅当 1-4 失败时才改动固件 blob（见上方布局）。

## 尝试 1（2026-10-24）——已实现、已烧录、已测量

分支 `test/wcn36xx-ap-sta`（自 `staging-main` 70da8a6），commit 777f6d8。

### 代码

* **452（重写）**——两个组合而非一个：
  `{AP}<=2`（保留已验证的多 SSID 行为）与
  `{AP}<=1, {managed}<=1`（单信道）。ADHOC/MESH 排除在限制之外；
  包含它们会使 wiphy 注册失败。现场 `iw phy phy0 info`：
  `* #{ AP } <= 2` 与 `* #{ AP } <= 1, #{ managed } <= 1`。
* **458（新增）**——`wcn36xx_pmc_enter_bmps_state()` 在 `wcn->vif_list` 中多于一个 vif 时拒绝 BMPS，镜像 qcacld。注意这只是保险措施：mac80211 已在任何 AP vif 运行时强制 `IEEE80211_CONF_PS` 关闭（`ieee80211_recalc_ps()` 在 AP 上设 `count = 0`），所以该保护主要买到一个调试面包屑。

### 在 hmuf02v5 上测量（内核 6.12.94，mac80211 6.18.26）

| 步骤 | 结果 |
| --- | --- |
| `iw phy phy0 interface add sta0 type managed` | OK |
| `ip link set sta0 up` | **失败** —— mac80211 克隆 AP vif 的地址，RTNETLINK 返回虚假的 "No error information" |
| 同前，在 `ip link set sta0 address 00:11:22:33:44:55` 之后 | OK，接口 UP |
| 在 AP 发信标时扫描 | OK，3 个 BSS，无固件错误，`remoteproc0/1` = running |
| auth / assoc | OK —— `RX AssocResp ... status=0`，`sta0: associated` |
| 约 100 ms 之后 | **AP 发送 Disassoc，reason 5（DISASSOC_AP_BUSY）** |
| GTK 安装 | 失败 `nl80211: kernel reports: key not allowed`（= `nl80211_key_allowed()`：STATION 需要 `wdev->connected`）——是 disassoc 的后果，不是密钥 bug |

对照，全部复现相同失败：

* AP vif **关闭**，纯 STA（完全没有并发）。
* `key_mgmt=WPA-PSK` 与 `key_mgmt=SAE`（AP 通告 `PSK SAE`，支持 MFP，group/pairwise CCMP）。
* 干净重启后（无陈旧固件 BSS 状态）。

### 结论

并发管道工作正常：组合被接受，第二个 vif 启动，无线电持续发信标，扫描与关联都成功，固件**不**崩溃。链路无法完成是因为一个**STA 路径 / AP 互操作问题，该问题在纯 STA 模式也存在**——所以它不是 AP+STA 造成的，必须在评判并发之前解决。

`hidden1`（3e:77:2f:9e:02:15，ch6）为其他客户端服务正常（主机 `wld0` 关联到它），所以要么此 AP 有我们未满足的策略，要么 wcn36xx 的 STA 路径对它有问题。需要第二个已知良好的 AP 来区分两者。

### 后续步骤（修订）

1. 针对第二个 AP（手机热点 / Android 单元的热点）复现 STA。若能在那里连接，则是 AP 策略问题；若在那里也失败，则是 wcn36xx STA 路径（用 a204000 转储读取器捕获）。
2. 之后才重新测试 AP+STA，这次用 `iw phy phy0 interface add ... addr`，使重复 MAC 窗口永不发生。
3. 在镜像中保留 454-457 用于崩溃捕获。

## 尝试 1 结果 —— STA+AP 可用（2026-10-24）

针对正常 AP（`androidap`，Android 热点，ch6），两个接口在单一 wcn36xx 无线电上同时运行：

| | 证据 |
| --- | --- |
| AP 服务客户端 | `iw dev phy0-ap0 station dump` -> `Station 1a:73:65:b1:ee:83`，-54 dBm，rx 200 565 B |
| STA 已关联 | `iw dev sta0 link` -> `Connected to 8e:aa:47:8a:a1:6c (androidap)`，-52 dBm，rx 905 886 B |
| 同一信道 | 两者都是 `channel 6 (2437 MHz), width 20 MHz` |
| 数据路径 | DHCP 10.162.21.33，gw ping 10.3 ms 均值，8.8.8.8 44.9 ms |
| 90 秒浸泡 | 6/6 检查：STA 已连接 + 网关 ping OK + AP 启动；无 wcn36xx/固件错误；`remoteproc1` running |

一部手机在设备保持关联 `androidap` 的同时关联 `Hmu05-White`——并发场景，端到端。

### 实际重要的是什么

1. **452**（组合 `{AP}<=1,{managed}<=1`）——没有它，mac80211 直接拒绝第二个接口。
2. **第二个 vif 上的不同 MAC。** mac80211 为新接口克隆 AP vif 的地址，`ip link set sta0 up` 随即以虚假的 "No error information" 失败。`iw phy phy0 interface add sta0 type managed addr ...` 完全避免该窗口。

这也**推翻了 "STA+AP 崩溃 WCNSS 固件" 的发现**：那个观察几乎可以肯定是对重复 MAC 配置，而非并发。使用不同 MAC 时固件从未动摇——454-457 在镜像中，但日志中没有任何东西表明它们被使用过。

### 注意事项 / 特性仍需要什么

* **仅单信道**（`num_different_channels = 1`）。AP 必须位于 STA 的信道上；若不，mac80211 拒绝移动发信标的 AP，关联失败。OpenWrt 必须保持 `wireless.radio0.channel` 与上游 AP 同步（或 STA 必须跟随 AP 的信道）。
* STA vif 是手工创建的。`wifi reload` 拆除 phy 并把 `sta0` 一起带走，所以它不持久。真正的特性意味着 `/etc/config/wireless` 里有第二个 `wifi-iface`（`mode=sta`），让 netifd 拥有两者。
* STA 成为默认路由（`default via 10.162.21.74 dev sta0`）并取代了调制解调器的路径。需要策略路由（metric / mwan3）使调制解调器保持主路径。
* STA tx 比特率针对 -52 dBm AP 报告 1-2 Mbit/s——特性改为配置驱动后值得检查速率控制 / 省电。
* `hidden1`（3e:77:2f:9e:02:15）在*纯* STA 模式下仍以 reason 5 断开关联。那是 AP 特有的，与并发无关，但意味着并非每个 AP 都适合测试。

## netifd 管理的 AP+STA 崩溃 WCNSS 固件（2026-10-24）

> **2026-10-26 部分取代——见 *尝试 2* 与 *尝试 3*。** 在 v25.12.6 镜像（backports 6.18.55）上，配置管理的 `wifi-iface mode=sta` 在 `wifi reload` 下存活且零固件崩溃（6/6 重载），mac80211 自行推导不同的每 vif MAC——下面的 `Data Abort 0x8b6b301c` 已在上游修复。它仍不可交付：*尝试 3* 测得约每三次开机关联一次，其余丢失无线电的扫描状态。基于服务的设计是为此保留的，不是因为崩溃。

配置：AP（`default_radio0`，默认 MAC）+ STA（`wifinet1`，`mode=sta`，`macaddr='random'`，SSID `hidden1`），`radio0.channel='6'`。

启动日志：

```
[  29.965] qcom-wcnss-pil a204000.remoteproc: fatal error received:
           boot_exception_c_handlers.c:108:Data Abort Exception at 0x8b6b301c
[  29.977] remoteproc remoteproc1: handling crash #1
[  79.665] ... same signature ... handling crash #2
[  89.566] wcn36xx: ERROR Timeout! No SMD response to req 24 in 10000ms
[  89.566] wcn36xx: ERROR Sending hal_set_bsskey failed
[  99.806] wcn36xx: ERROR Timeout! No SMD response to req 127 (delete_sta_self)
[ 109.832] wcn36xx: ERROR Timeout! No SMD response to req 2 (hal_stop)
```

结果：`remoteproc1` = `crashed`，无可用 wiphy，负载均值 10.6，LuCI 无响应。恢复需要在 STA 接口禁用时重启。

伴随两个 cfg80211 WARN（hostapd 接口创建期间的 `cfg80211_register_netdevice` 与 scan.c:1193 处来自 `ieee80211_sched_scan_stopped` 的 `cfg80211_scan_done`）——跨两个 vif 的扫描记账在固件死亡前就已经出错。

### 为什么手工测试通过了

成功的运行先创建 AP（netifd），再手工添加 `sta0` 并让 wpa_supplicant 关联。这里 netifd 创建**两个**接口并并发启动 hostapd 与 wpa_supplicant，而 wpa_supplicant 在 hostapd 配置 AP BSS 时立即扫描 `hidden1`。单一的 wcn36xx 扫描引擎加上进行中的 BSS 启动是新成分。

### 候选变通方案（未测试）

1. STA 接口上的 `option bssid='<upstream BSSID>'` —— wpa_supplicant 随后跳过扫描直接认证，消除并发扫描窗口。
2. 仅在 AP 建立后启动 STA（init/hotplug 脚本在 `phy0-ap0` 出现几秒后对 STA 网络执行 `ifup`）。
3. 固件级：解码 `wcnss.mdt` 中的 PC `0x8b6b301c`（加载基址 `0x8b600000`，偏移 `0xB301C`）——我们拥有的并发路径第一个硬故障地址。

在这些被证明之前，**交付仅 AP**；AP+STA 保持手工/实验配置。

## E1/E2（2026-10-24）——崩溃是 PHY 重启，不是 STA vif

### E1：用已知良好上游与固定 MAC 重测

配置：AP `Hmu05-White`（ch6，默认 MAC）+ STA `wifinet1` -> `androidap`（psk2，`macaddr='00:11:22:33:44:77'`，**无** `random`）。这消除了第一次尝试的两个混淆因素（有问题的 `hidden1` 上游与 `macaddr=random`）。

结果：**崩溃，逐字节相同的签名** ——

```
[ 29.260] wcn36xx: firmware WLAN version '...' / API 1.5.1.2
[ 29.301] phy0-ap0 created, br-lan blocking/disabled, allmulti+promisc
[ 29.374] phy0-ap0 left allmulti/promisc        <- vif DELETED
[ 29.513] phy0-ap0 created again                <- vif RE-ADDED
[ 29.977] Data Abort Exception at 0x8b6b301c    <- 0.46 s later
```

⇒ `hidden1` 与 `macaddr=random` **被洗清**。重试风暴假设已死。

### 仅 AP 对照

仅 AP 启动是干净的（**0 崩溃**），且仍记录来自 `radio0` 的同样两个 `command failed: Not supported (-95)` 以及 `hostapd: Restart interface for phy phy0`。所以重启路径每次启动都运行，且在 phy 配置中**无** managed 接口时无害。

### E2：配置了 STA 时运行时 `wifi reload`

`uci set wireless.wifinet1.disabled=0; wifi reload` →

```
[ 78.291] phy0-ap0 left allmulti/promisc        <- AP vif deleted
[ 78.869] phy0-ap0 created again
[ 79.168] Data Abort Exception at 0x8b6b301c    <- 0.30 s later
```

**本次运行从未创建 STA vif**（`dmesg` 完全没有 `sta0`/managed vif）。与干净仅 AP 重载的唯一区别是 wpa_supplicant 带着 phy 配置中的 managed BSS 在运行；它在同一瞬间重启（`supp-global-ctrl-iface-init ... bind(PF_UNIX): Address in use`），其扫描落在 AP BSS 正被重新创建时。

**结论：** 每当该 phy 上配置了 wpa_supplicant 管理的接口，固件就在 *phy 重启*（hostapd `Restart interface`）时死亡。手工 AP+STA 测试从未重启 phy——它只对已发信标的 AP 做 `iw phy phy0 interface add`——这正是它成功的原因。

⇒ 任何把 STA 路由经 `/etc/config/wireless` 的设计都会碰到这个，因为 netifd 的 wifi 脚本在 wireless 配置每次变更时重启整个 phy（包括每次启动）。**AP+STA 不得使用 `wifi-iface`。**

### 次要：固件崩溃 30 秒后内核 oops

当 netifd 在死固件上重试 `ip link set phy0-ap0 up` 时：

```
[ 109.276] Unable to handle kernel paging request at ffff800080cf5004
           ESR 0x96000007, FSC 0x07 (level 3 translation fault), WnR = 0
[ 109.441] pc : __memcpy+0x110/0x260
[ 109.447] lr : wcn36xx_smd_load_nv+0x94/0x170 [wcn36xx]
[ 109.537] drv_start+0x30/0x50 [mac80211]
           ieee80211_do_open+0x258 -> __dev_open -> dev_change_flags
```

`wcn36xx_smd_load_nv()` 执行 `memcpy(wcn->hal_buf + sizeof(msg_body), &nv_d->table + fm_offset, 3072)`，其中 `nv_d = wcn->nv->data`；这里 `x1`（源）是 `ffff800080cf5004`——根本不是固件加载器分配。缓存的 `wcn->nv` 仅在 `wcn36xx_remove()` 释放且**不**置为 NULL，`wcn36xx_start()` 信任它。最一致的解读：SSR 后驱动在一个固件 blob 已被释放的 `wcn` 上被重新进入。**尚未证明**——需要 `wcn->nv` 指针打印或 KASAN 构建。无论结论如何：崩溃的 WCNSS 让内核在每次 netifd 重试时 oops，而非干净失败。


## E4（2026-10-24）——延迟 STA 服务：已交付、启动已验证

E1/E2/P1 结果把 bug 归结为一句话：**当该 phy 上配置了 managed 接口时 phy 重启会杀死 WCNSS 固件**。netifd 的 wifi 脚本在每次 wireless 配置变更时重启 phy（包括每次启动），所以表示为两个 `wifi-iface` 段的 AP+STA 配置永远不可能安全。已验证安全的路径是手工的：让 AP 先启动，再用 `iw` 添加 STA vif 并让 wpa_supplicant 关联。

`/etc/init.d/wifi-sta-late` 正好自动化这一点，作为两个 procd 实例：

| 实例 | 命令 | 做什么 |
|---|---|---|
| `sta` | `wifi-sta-up sta` | 轮询 `hostapd.<ap>.get_status` 直到 `ENABLED`，然后 `iw phy <phy> interface add <phy>-sta0 type managed addr <mac>`，写 wpa 配置，并 `exec` 前台 `wpa_supplicant` |
| `dhcp` | `wifi-sta-up dhcp` | 等待 `iw dev <sta> link` 报告 `Connected`，然后 `exec` 带 `wifi-sta-dhcp.sh` 的 `udhcpc -f` |

两者都是 `procd_set_param respawn 3600 5 0`，所以任一死掉都会被修复。刻意**不**用 `wpa_supplicant -B`：它会守护化到 PPID 1，procd 无法再监管它（观察到的：只有 udhcpc 被监管）。

文件：

- `/etc/config/wifista` —— `enabled`（默认 **0**）、`macaddr`、`ssid`、`key`、`dhcp`（默认 1）、`wait_ap_timeout`（默认 60）。
- `/usr/sbin/wifi-sta-up` —— 两种模式。
- `/usr/sbin/wifi-sta-dhcp.sh` —— 最小 udhcpc 处理程序：仅地址 + 已连接路由，**绝不做默认路由**（LTE 链路必须保持默认）。
- `/etc/uci-defaults/95-wifi-sta-late` —— 启用该服务。

### 为什么 STA netdev 不走 netifd

netifd 接口上的 `option device 'phy0-sta0'` 失败并报 `errors: [{subsystem: interface, code: NO_DEVICE}]`——netifd 对它未创建的 vif 没有设备对象，`ubus list` 显示没有 `network.device.phy0-sta0`。因此 udhcpc 直接运行。代价是租约对 LuCI/ubus 不可见（它是普通 `ip addr`），这对并发 AP+STA 特性是可接受的。

### 验证（HMU05，镜像 `c24dd181`）

启动，无手工步骤：

```
wifi-sta: phy0-sta0 created on phy0 (phy0-ap0 ENABLED after 0s); ssid 'androidap'
wifi-sta: phy0-sta0 associated after 2s
wifi-sta: dhcp: 10.162.21.33/24 on phy0-sta0
dmesg | grep -c "handling crash"  ->  0
phy0-sta0  UP  10.162.21.33/24      phy0-ap0  ssid Hmu05-White  ch6
ping -I 10.162.21.33 8.8.8.8 -> 0% loss, 56-96 ms
default route still via wwan0 (LTE)
```

### 注意事项

1. ~~**STA 启动时 `wifi reload` / LuCI wireless 保存会带着 `phy0-sta0` 重启 phy → 相同固件崩溃。**~~ **25.12.6 已关闭。** `openwrt-patches/811` 用 `wifi-sta-guard down` … `up` 括住 `drv_mac80211_setup()`，并从 `drv_mac80211_teardown()` 调用 `down`，所以 netifd 无法再在活动 station 下重启 phy。只有非 netifd 的无线电重置（裸 `iw dev del`、`rmmod`、驱动重新绑定）仍需要手工的 `/etc/init.d/wifi-sta-late stop; …; start` 序列。
2. **快速 stop/start 周期可能记录一个 `SME: Authentication request to the driver failed`** 并把 BSSID 放入 wpa_supplicant 的 10 秒忽略列表；它自行恢复（在 `restart` 期间观察到，非启动时）。
3. STA 按设计**不获得默认路由**。要将其用作上行链路，自行添加路由/策略规则。
4. `enabled` 出厂为 **0**；这是选择加入的。


5. **`wifi reload` 会短暂弹起 `br-lan`**（USB gadget 是桥端口），所以 gadget 链路上的 SSH 会话会在命令中途掉线。自 25.12.6 起 station 不再需要手工停止——netifd 钩子会做——它带着租约自行恢复。


## 信道是共享的：AP 跟随 STA（2026-10-24）

station 没有自己的信道——它去上游所在的地方。单一无线电一次只有一个信道，所以不匹配对 STA 是致命的：

```
AP forced to channel 1, upstream on channel 6:
phy0-sta0: Trying to authenticate with 2a:2a:8a:9d:f5:2c (SSID='androidap' freq=2437 MHz)
phy0-sta0: SME: Authentication request to the driver failed
phy0-sta0: CTRL-EVENT-SSID-TEMP-DISABLED ... auth_failures=2 duration=28
```

**已测量：** 无固件崩溃、无租约，只是越来越大的退避循环——驱动拒绝而非把 AP 拖离信道。

所以 `wifi-sta-up sta` 现在自己同步信道，**在** STA 连接之前：

1. AP 已 ENABLED（任意信道）。
2. 创建 STA vif 并 `ip link set up` 它——DOWN 的 netdev 无法扫描（`iw scan` 返回 ENETDOWN），这是第一次实现漏掉的。
3. `iw dev <sta> scan` 并读取目标 SSID 的信道。解析陷阱：`iw` 在 HT operation 下把信道打印为 `\t\t * primary channel: N`，而非裸的 `primary channel:` 行——第一个正则静默地什么都没匹配。
4. 若与 AP 的信道不同：**删除 STA vif**，`uci set wireless.<radio>.channel`，`wifi reload`，等待 AP 在新信道上回来 ENABLED，再重新创建 STA vif。
5. 连接。

第 4 步的重载之所以安全，只是因为 STA vif 先被删除——与本文档其他地方相同的不变量。

现场结果（AP 刻意设到 ch1，上游在 ch6）：

```
wifi-sta: upstream 'androidap' is on channel 6, AP is on 1; moving the AP
wifi-sta: AP moved to channel 6; re-creating phy0-sta0
wifi-sta: phy0-sta0 created on phy0 (phy0-ap0 ENABLED after 0s); ssid 'androidap'
wifi-sta: dhcp: phy0-sta0 associated after 4s; 10.162.21.33/24
```

`/etc/config/wifista` 中的 `option radio 'radio0'` 选择移动哪个无线电的信道。注意事项：这仅在启动时运行——若上游后来移动信道（CSA/重启），STA 掉线并保持关闭直到服务重启；移动 AP 信道会短暂断开其自身客户端（信道变更的正常情况，不发送 CSA）。


### 看门狗（2026-10-24）——无需重启的恢复

上面的信道同步仅在启动时运行，所以后来的上游信道变更（重启、CSA）会让 STA 保持关闭直到有人重启服务。第三个 procd 实例 `wifi-sta-up watchdog` 堵上这个：

- 每 15 秒轮询；已连接的 STA 重置计数器
- 关闭 `recover_after` 秒（默认 60）后，它扫描并比较上游信道与 AP 的
- **不匹配** -> 记录日志，删除 STA vif，杀掉 wpa_supplicant + udhcpc，让 procd 重启 `sta`/`dhcp` 实例，它们重新运行同步
- **无不匹配**（上游不存在、PSK 错误）-> 交给 wpa_supplicant；记录一次然后每五个周期一次，避免环形缓冲区被淹没
- **vif 完全缺失** -> 回收；没有这个，实例会永远存活，持有死 netdev

**现场验证**通过模拟失败（删除 vif，在无 STA vif 存在时把 AP 移到信道 1，使重载安全）：

```
18:15:03 wifi-sta: watchdog: down 60s and upstream 'androidap' moved to channel 6 (AP on 1); recycling the STA
18:15:10 wifi-sta: upstream 'androidap' is on channel 6, AP is on 1; moving the AP
18:15:11 wifi-sta: AP moved to channel 6; re-creating phy0-sta0
18:15:13 wifi-sta: dhcp: phy0-sta0 associated after 59s; starting udhcpc
18:15:43 wifi-sta: dhcp: 10.162.21.33/24 on phy0-sta0
```

从检测到可用链路约 40 秒，0 固件崩溃。

**非显而易见的发现：** 删除 vif **不会**使 wpa_supplicant 退出（pid 不变，procd 从不重启），所以"只删 vif 让 procd 处理"不成立——看门狗必须显式杀掉进程。这个 busybox 里 `pkill -f` 不可靠，所以用 `pgrep -f` + `kill`。



### LuCI 应用 —— `luci-app-wifi-sta`（2026-10-25）

Network → **Station Mode**（顺序 30，紧接 Wireless）。两个视图：

- **Overview** —— 每 5 秒从 `wifi-sta-up status` 轮询的实时状态（AP 接口/状态/信道/客户端，STA 接口/状态/SSID/BSSID/信道/信号/比特率/地址），一个信道不匹配警告，一个"station 仍配置在 wireless 配置中"的崩溃风险警告，以及 Restart / Stop / Start / Show log。
- **Configuration** —— 整个 `/etc/config/wifista` 段（`enabled`、`ssid`、`key`、`macaddr`、`dhcp`、`radio`、`recover_after`、`wait_ap_timeout`）加一个运行 `iwinfo <ap_iface> scan` 的 **Scan** 按钮，可直接把 SSID 填入字段。

wireless 配置不受触动：页面只写 `wifista`。

ACL（`/usr/share/rpcd/acl.d/luci-app-wifi-sta.json`）：读 = uci `wifista` + `wireless`，exec `/usr/sbin/wifi-sta-up`、`/etc/init.d/wifi-sta-late`、`/usr/sbin/iw`、`/usr/bin/iwinfo`、`/sbin/logread`；写 = uci `wifista` + exec init 脚本。通过真实会话验证（带 `ubus_rpc_session` 的 `ubus call file exec`）——全部五个 exec 返回 0。

**接线 Save & Apply 时发现两个 procd 陷阱：**

1. `procd_add_reload_trigger` **只能从顶层 `service_triggers()` 函数工作**。从 `start_service()` 内部调用会被静默丢弃——`ubus call service list` 随后显示 `"triggers": [ ]` 且什么都不触发。（firewall/dnsmasq/log 都用独立函数。）
2. procd 默认的 `reload` 是裸的 `start()`，它让已运行的实例保持不动，所以更改的 SSID/key 永不生效。脚本因此定义 `reload_service() { restart; }`。

通过 LuCI 使用的相同 RPC 路径端到端验证（带会话的 `uci set` → `uci apply`）：配置提交，`sta` 实例在 <1 秒内重启（pid 改变、重新关联、同一租约）。

**构建陷阱：** `packages/` 里的包会被 `include/scan.mk` 拾取，它 grep Makefile 中字面字符串 `call BuildPackage`。只有 `include $(TOPDIR)/feeds/luci/luci.mk` 的 luci Makefile 根本不产生 **Kconfig 符号**——`defconfig` 静默忽略它，包不在镜像中。本树的惯例是尾部注释：

```make
include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
```

**Overlay 陷阱：** 直接从 `/overlay/upper/...` 删除文件不会让合并视图回退到镜像副本——`/etc/init.d/wifi-sta-late` 持续服务被删除的 inode 直到下次重启。就地编辑 overlay 文件后重启（或通过合并路径 `rm`，它会 whiteout）。

## 尝试 2（2026-10-26）——配置管理的 STA 在 25.12.6 上可用

分支 `test/wcn36xx-config-sta`（自 `staging-main` `a130b5d`）。在运行 v25.12.6-r1 镜像（内核 6.12.112，backports 6.18.55）的现场 HMUF02-V5 上测试。

**头条：E2 崩溃不复现。** `/etc/config/wireless` 里真正的 `wifi-iface` 带 `mode='sta'`，同一无线电上的第二个 vif，以及 `wifi reload`——在 6.18.26 上产生 `Data Abort Exception at 0x8b6b301c` 的确切序列——在 6.18.55 上是干净的：

| 测试 | 结果 |
| --- | --- |
| 带配置管理的 STA + AP 的 `wifi reload` | **0 崩溃**，`remoteproc1: running`，两个 vif 都在 |
| AP vif 的完整删除/重加周期（旧触发） | 运行，只记录良性的 `hal_delete_bss err=5` / `hal_remove_bsskey err=16` / `hal_delete_sta_self err=7` |
| STA 关联 | `phy0-sta0: associated`，同一租约 |
| **连续 6 次 `wifi reload`** | **6/6 干净**，`crashes=0`，每次之后 STA 重新关联 |

### backports 6.18.55 的两个结构性事实

1. **`sme.c` 已不存在。** SME 层被并入 `main.c`（1711 行）；`wcn36xx_smd_config_bss` 现在从 `main.c:561/834/890/937` 调用。任何曾以 `sme.c` 为目标的未来补丁必须以 `main.c` 为目标。这也是 450-453/458/459 仍能应用的原因——它们都没碰 `sme.c`。
2. **wiphy 仍通告一个地址**（`n_addresses` / `addresses[]` 从未设置），**但 mac80211 现在仍推导一个不同的**：未配置 `macaddr` 时 STA vif 以 `06:00:c2:b9:10:3c` 启动，而 AP 是 `02:00:c2:b9:10:3c`——相同 OUI，本地位已置位。6.18.26 的"克隆 AP 地址，然后 `ip link set up` 以虚假的 *No error information* 失败"问题消失了。**假设 2（每 vif MAC）已在上游解决。**

### 这推翻了什么

* 分级假设 1-3（IMPS/BMPS 保护、每 vif MAC、CONFIG_BSS 拆分）**不需要**使配置管理的 STA 安全——驱动变更在 6.18.26 与 6.18.55 之间落入上游。
* 基于服务的 Station Mode 的前提（"`wifi-iface` STA 会崩溃固件，所以不得经过 netifd"）在 25.12.6 上不再成立——但*尝试 3* 随后表明 `wifi-iface` 路径因另一原因（扫描状态丢失）不可靠，所以服务无论如何保留了。`openwrt-patches/811`（phy 重启保护）仍正确且仍为基于服务的设计所需。

### 仍开放的（不是驱动问题）

**无** `macaddr` 时 STA 关联成功（`RX AssocResp status=0`）然后约 10 秒后以 `Reason: 3=DEAUTH_LEAVING` 取消认证——*本地*拆除，循环重复。带 `macaddr='00:11:22:33:44:77'` 时它跨全部六次重载保持连接。所以剩余差距是 netifd/network 管道（测试用的虚拟 `proto=none` 接口、载波处理，以及 netifd 如何重启 STA），不是 wcn36xx 驱动。

### 结果

两个开放问题都在 2026-10-26 得到回答，移植被放弃——见下方*尝试 3*。`DEAUTH_LEAVING` 循环是虚拟 `proto=none` 接口的产物：带 `proto='dhcp'` 时 station 保持关联并拿到租约。产品决策是保留服务，因为配置管理的 station 约三分之一的启动才关联。

## 尝试 3（2026-10-26）——可靠性测量：未采纳

尝试 2 证明了*崩溃*消失，所以明显的下一步是把 Station Mode 移到普通 `wifi-iface` 并退休 `wifi-sta-late` / `wifi-sta-up` / `openwrt-patches/811`。该移植被构建并测量，然后**被放弃**：配置管理的 STA 约三分之一的启动才关联，一次失败尝试让无线电不可用直到下次启动。基于服务的设计被保留。

### 失败

```
wpa_supplicant: phy0-sta0: CTRL-EVENT-SCAN-FAILED ret=-16 retry=1     (once a second, forever)
iw dev phy0-sta0 scan   -> command failed: Resource busy (-16)
iw dev phy0-ap0   scan  -> command failed: Resource busy (-16)
```

当 `wcn->scan_req` 置位时 `wcn36xx_hw_scan()` 返回 `-EBUSY`。当扫描丢失其完成事件时该字段从不清除，所以**每次**之后对该 phy 的扫描在本次开机剩余时间内都失败——包括 hostapd 的 ACS：

```
hostapd: Failed to request acs scan ret=-16 (Resource busy) - try to scan after 5 seconds
```

带 `radio0.channel='auto'` 时这第二个后果本身就致命：AP 无法选择信道，所以它无 SSID 启动，什么都不工作。固定信道不能阻止楔死，但它让 AP 在发生时保持可用。

### 测量（HMUF02-V5，v25.12.6-r1，backports 6.18.55）

| 设计 | STA 何时出现 | 信道 | 启动次数 | 已连接 |
| --- | --- | --- | --- | --- |
| 配置管理的 `wifi-iface` | 与 AP 相同的 `setup()`（启动） | `auto` | 3 | 1 |
| 配置管理的 `wifi-iface` | 与 AP 相同的 `setup()`（启动） | 固定 | 3 | 1 |
| 配置管理的 `wifi-iface` | AP 启动后 `wifi reload` | `auto` | 2 | 2 |
| 配置管理的 `wifi-iface` | 启动一分钟后 `ifup` | `auto` | 2 | 1 |
| 配置管理 + 等待 AP-ENABLED 的驱动补丁 | 启动 | 两者 | 2 | 1 |
| **服务（`wifi-sta-late`）** | AP 启动后 | 固定 | 3 | 2 |

两种设计都不可靠，差异不显著。排序技巧（延迟 `wifi reload`、`ifup`、等待 `AP-ENABLED`）有时有用有时失败——竞争在固件单一扫描引擎内部，不在 netifd 的排序。服务保留其 `recover_after` 看门狗，它在失败尝试后重试；那是唯一实际的差异。

### 这对本树意味着什么

* Station Mode 保持在服务上（`wifista` + `wifi-sta-late` + `wifi-sta-up` + `wifi-sta-guard` + `openwrt-patches/811` + `luci-app-wifi-sta`）。
* `radio0.channel` 必须在任何使用 Station Mode 的板卡上保持**固定**。`auto` 会把楔死的扫描变成死 AP。`wifi-sta-up` 现在强制执行：`ensure_fixed_channel` 把 `auto` 钉到 AP 当前的信道，或当 AP 无信道时钉到 6，并重启无线电。
* 尝试 2 的发现仍成立且值得保留：6.18.26 的 `Data Abort 0x8b6b301c` 在 6.18.55 上不复现，`sme.c` 消失，mac80211 自行推导不同的每 vif MAC。只有*产品*决策走向了另一边。
