# HMU05 蓝牙 — 启动、配对根因与打包

状态：**蓝牙可用，包括 BR/EDR 配对。** 已于 2026-10-09 在 HMU05 上验证
（`hmu05,250605v0s`），OpenWrt 25.12.5 / 内核 6.12.94，bluez 5.83。

本文件取代记忆中早先记录的结论“配对总是失败；WCNSS DHKey 加密已损坏”。**那个结论是错的。** 配对成功。

## 1. 协议栈

- 蓝牙核心已编入内核（`CONFIG_BT=y`）。
- 传输层 **`btqcomsmd`**（OF 属性 `qcom,wcnss-bt`）+ 辅助模块 **`btqca`**。
- `openwrt/target/linux/msm89xx/config-6.12`：`CONFIG_BT_QCA=m`、`CONFIG_BT_QCOMSMD=m`。
- 平台设备 `a204000.remoteproc:smd-edge:wcnss:bluetooth`，在 `remoteproc1` 启动
  `wcnss.mdt`（约 9.5 秒）时创建。rpmsg 通道 `…APPS_RIVA_BT_CMD/CTRL/DATA`。
- `hci0` — 总线 SMD，BD 地址 `02:00:C2:B9:10:3D`（= Wi-Fi MAC `…:3c` + 1，由 lk2nd 通过
  `local-bd-address` 属性注入），厂商 Qualcomm（29），HCI 4.0，class `0x000100`。

## 2. 配对失败的根因 — SSP LMP 特性位

控制器通过 **LMP 特性位 51** = NVM 标签 6 的 **字节 6，位 3（`0x08`）** 通告安全简单配对（Secure Simple Pairing）。该位在控制器处门控 SSP：

| NVM 标签 6 字节 6 | SSP 位 | `Read Simple Pairing Mode`（`0x03|0x0055`） |
|---|---|---|
| `0x5B` | 置位 | `01 55 0C 00 01` — 状态 `0x00`，**模式 `0x01`** |
| `0x53` | 清除 | `01 55 0C 11 FF` — **状态 `0x11`（不支持的特性）** |

当该位被清除时，控制器报告不支持 SSP，于是设备回退到**传统 PIN 配对，而这也失败**（`PIN Code Request` → `Auth Complete 状态 0x06`，“PIN 或密钥缺失”）。当该位置位时，SSP 正常运行，配对成功。

**`Write Simple Pairing Mode`（`0x03|0x0056`）在此控制器上可用。**
- `mode = 0x01` → 状态 `0x00`（成功）。
- `mode = 0x00` → 状态 **`0x0C`（命令被禁止）** — 控制器*拒绝禁用 SSP*；回读仍为 `01`。

> 更正：早先的注释声称 `Write_Simple_Pairing_Mode`（0x0C56）返回“未知命令”。
> 这对本控制器而言是**错误**的。

**干净重启后的固件默认值**（已验证）：特性 `FF FE 8F FE D8 3F 5B 87`（SSP 位已
置位），SSP 模式 `01`。`bluetoothd` 在其自身初始化时也会写入 `Write SSP=1`。⇒ 出厂启动
已处于良好状态；**该修复跨重启自愈，无需 init 脚本。**

### ★ `0x05` 触发点 — 2026-10-23 查明（主机控制器状态；断电重启可修复）
最初的失败 — SSP 已激活但 `Simple Pairing Complete (0x36) 状态 0x05` — 在**两块**板卡上
复发，现已解释清楚。它是**主机侧**问题，而非设备侧。

复现（Fedora 5.87 主机；在 `mifib-v12` **和** `hmuf05` 上，以及针对一台 POCO
M6 Pro 5G 复现）：经过长时间的扫描与失败的配对尝试后，每次配对都以 `0x05` 失败，
即使双方都显示并确认**相同**的 passkey，且设备返回
`btd_adapter_confirm_reply() … success 1`。Just Works（双方均为 NoInputNoOutput）也以
同样方式失败。双侧删除旧配对、`hciconfig reset`，甚至设备完全重启都**无法**清除它。

修复 — 文档记载的成功配方（§3）在配对前对**主机**控制器断电重启：

```
bluetoothctl
  power off; sleep 3; power on; sleep 3
  scan bredr          # `scan on` 会反复漏掉这个仅 BR/EDR 的设备
  scan off
  pair <bdaddr>
```

→ `Bonded: yes / Paired: yes`，且**双方**随后持有相同的链路密钥（设备侧与主机侧的
`info` 文件一致）。mgmt 断电重启会重新初始化主机控制器；仅 HCI reset 或重启扫描并不够。

⇒ 实用规则：**若配对以 `0x05` 失败，先给主机适配器断电重启** — 不要先去查设备。
这也解释了早期 RFCOMM 上的 `EBADE`（无效交换）：同样是过期的主机状态，断电重启后消失。

### 尚未证实的部分
BD 地址假设（SSP 的 f1/f2/f3 绑定 BD_ADDR；bluez 曾报告过期的
`00:90:4A:13:A0:72`）已对照 fedora 侧抓包核查，**不成立** — 失败的交换全程使用
`02:00:C2:B9:10:3D`。NVM BD_ADDR 标签（厂商 `0x3f|0x000b` 标签 1）在两块板卡上均为**空**，
且 NVM 写入被接受但不持久化，因此地址来自 lk2nd 的 `local-bd-address`；这不是失败触发点。

## 3. 已验证的配对

在设备完全重启后，进行干净的全新配对（双方删除旧配对）：

```
[host] agent registered (NoInputNoOutput)
[host] pairing with 02:00:C2:B9:10:3D
[host] PAIR OK
```

设备侧：`Paired: yes / Bonded: yes`、`LegacyPairing: no`。完整 SDP 会话完成
（L2CAP / AVRCP / HFP / A2DP / OBEX 记录）。这已用 OpenWrt 默认的
`NoInputNoOutput` agent（Just Works）以及 `DisplayYesNo`（确认 passkey）复现。

### 3.1 配对跨重启保持（2026-10-09 验证）

重启设备并重新检查。配对**及其链路密钥**均保留：

| 检查项 | 重启前 | 重启后 |
|---|---|---|
| `bluetoothctl info C0:95:6D:45:9A:F3` | `Paired: yes / Bonded: yes` | `Paired: yes / Bonded: yes` |
| `…/C0:95:6D:45:9A:F3/info` md5（含 `[LinkKey]`） | `f8975a1bdc3a5c4015d2961ed0b5c9b5` | **完全相同** |
| `…/02:00:C2:B9:10:3D/settings` md5 | `c166d0c91918551fb7efa4d32ae17c26` | **完全相同** |
| `hci0` | UP RUNNING，0 错误 | UP RUNNING，0 错误 |
| `btqca` / `btqcomsmd` 已加载 | 是 | 是（自动加载） |

根文件系统是 `overlayfs`，`/overlay` 位于 `/dev/mmcblk0p15`（ext4），因此 `/var/lib/bluetooth` 位于
持久存储上。（`sysupgrade -n` **会**清掉它 — 参见部署陷阱。）

**存储的链路密钥仍能通过认证**（这才是真正的测试，而不只是磁盘上的文件）：

- 设备侧：`hcitool cc C0:95:6D:45:9A:F3` → **`rc=0`**，且 `hcitool con` 显示
  `< ACL C0:95:6D:45:9A:F3 handle 2 state 1 lm PERIPHERAL` — 一条*使用存储密钥*建立的基带 ACL 链路。密钥缺失/无效会给出 `Authentication Failed`，而不是干净连接。
- 主机侧：`bluetoothctl connect 02:00:C2:B9:10:3D` → `ServicesResolved: yes`（SDP **在已认证链路上**完成）然后是 `BREDR.ProfileUnavailable`。

> **关于 `br-connection-profile-unavailable` 的说明：** 两个通用 Linux 主机之间执行普通的
> `bluetoothctl connect` 会返回此错误。这是一个**配置文件**错误（双方都未暴露可连接的服务 — 没有 A2DP/HID/PAN 监听器），**不是**认证错误。不要把它解读为“配对坏了”。要证明密钥有效，请使用 `hcitool cc`（链路层），或连接真实配置文件（例如 RFCOMM 服务器，或带 A2DP/HFP 的手机）。

### 3.2 SPP 端到端验证（2026-10-23）
在配对建立后，主机直接对通道 1 执行普通 RFCOMM 连接即可到达 `bt-spp` shell 桥：

```
RFCOMM CONNECTED to 02:00:10:D2:00:C2 channel 1
~ # echo SPP_OK; uname -n
SPP_OK
mifib-v12
```

SDP 在 RFCOMM 通道 1 上通告 `Serial Port`（0x1101）（`sdptool browse`）。已在
`mifib-v12`（已配对）和 `hmuf02v5`（未配对 — shell 桥不要求认证）上验证。
这完成了端到端 SPP 检查：配对 → 双侧建立 bond → RFCOMM ch 1 → shell。

## 4. 打包 — `kmod-btqca` + `kmod-btqcomsmd`

这些模块现在是正式的软件包，而不是手工复制的 overlay 文件。

- `msm89xx/modules.mk` 新增：
  - `KernelPackage/btqca` — `CONFIG_BT_QCA`，附带 `btqca.ko`，不自动加载（无平台驱动）。
  - `KernelPackage/btqcomsmd` — `CONFIG_BT_QCOMSMD`，附带 `btqcomsmd.ko`，
    `AUTOLOAD = btqca btqcomsmd`，`DEPENDS = +kmod-bluetooth +kmod-btqca +kmod-qcom-rproc-wcnss`。
- `msm89xx/Makefile`：两者均加入 `DEFAULT_PACKAGES`。
- `BLUETOOTH_MENU` 可安全使用：`package/kernel/linux/Makefile:77` 在
  `:78` 包含 `$(SUBTARGET_MODULES)` 之前包含 `modules/*.mk`。

构建（已验证）：产出 `kmod-btqca-6.12.94-r1.apk` 与 `kmod-btqcomsmd-6.12.94-r1.apk`，两者
均列入 `generic-hmu05` 清单，sysupgrade 镜像已重建。

> **陷阱（文档 171）：** 目标 `modules.mk` 中新增的 `KernelPackage` 会被过期的
> `tmp/.config-package.in` 缓存**静默丢弃** — `.ko` 会构建、构建成功，但没有 apk 出现。
> 构建前请清理：
> ```
> rm -f openwrt/tmp/info/.packageinfo-* openwrt/tmp/info/.targetinfo-* openwrt/tmp/info/.files-* \
>       openwrt/tmp/.packageinfo openwrt/tmp/.config-package.in openwrt/tmp/.config-target.in \
>       openwrt/tmp/.packagedeps
> ```
> 然后**确认 apk 确实存在**，而不要轻信构建的退出状态。

部署到设备用 `apk add --allow-untrusted`；重启后由软件包提供的
`/etc/modules.d/btqcomsmd` 会加载 `btqca` + `btqcomsmd`，`hci0` 拉起，且 fedora 侧配对
保持。冗余的手工 `/etc/modules.d/65-btqcomsmd` 已移除。

## 5. 可复用的陷阱

- 设备的 `bt-agent` 是**交互式**的 — 用 `yes | bt-agent -c <cap>` 运行。
- `bluetoothctl` 会自动注册自己的 agent 并设为默认，覆盖任何其他 agent。
  使用既注册又调用 `Device1.Pair` 的 D-Bus agent。
- `bluetoothctl scan on`（LE+BR/EDR）会反复**漏掉**这个仅 BR/EDR 的设备 — 请用
  `bluetoothctl scan bredr`（或 `hcitool scan`）。
- **任何 HCI reset 都会清除 inquiry-scan（ISCAN）** — 重新运行 `hciconfig hci0 piscan` /
  `bluetoothctl discoverable on`。这不是射频问题。
- 设备**无法通过 USB/br-lan 链路从主机抓取 HTTP**（`EPERM`）；请用 `scp`。

## 6. 证据

`Docs/Bluetooth/evidence/`：
- `pairing_failure_dhkey_status05.log` — 原始失败的设备侧 HCI 跟踪
  （`User Confirmation Request` → `Simple Pairing Complete (0x36) 状态 0x05`）。
- `phone_test_poco_m6_pro_5g.log` — 针对 POCO M6 Pro 5G 的同样失败。
- `pairing_failure_legacy_pin.log` — 传统 PIN 回退（`PIN Code Request` → `Auth Complete 0x06`），在 SSP 特性位被清除时看到。
- `pairing_success_ssp3.log` — 一次成功的 fedora 发起配对（`DisplayYesNo`）。
- `pairing_success_noio.log` — 使用 OpenWrt 默认 `NoInputNoOutput` agent 的成功配对。
