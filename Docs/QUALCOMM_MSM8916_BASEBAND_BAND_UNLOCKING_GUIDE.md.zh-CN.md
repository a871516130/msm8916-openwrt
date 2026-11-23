# Qualcomm MSM8916 基带频段解锁指南

## 1. 概述与架构

本文档提供了在运行 OpenWrt / Linux 的 **Qualcomm Snapdragon 410 (MSM8916)** 设备
（如 Generic HMU05、UZ801、UF896、UFI001C 加密狗）上解锁额外 LTE 和
WCDMA/GSM 蜂窝频段的分步技术指南。

### 硬件与固件背景
- **SoC**：Qualcomm Snapdragon 410（MSM8916，四核 Cortex-A53）
- **调制解调器核心**：Qualcomm Hexagon QDSP6 v5（MSS 子系统）
- **射频收发器**：Qualcomm WTR2605 / WTR1605 多模 RFIC
- **基带固件**：`HIMI_U01_MODEM_V1.0`（或类似的 AMSS/Modem OS）
- **存储子系统**：eMMC 分区 `modemst1`（`/dev/mmcblk0p4`）、`modemst2`（`/dev/mmcblk0p5`）
  和 `fsg`（`/dev/mmcblk0p2`），通过 `rmtfs` 用户空间服务提供给 DSP。

### 出厂默认频段 vs 解锁频段
| 技术 | 出厂启用的频段 | 解锁后可工作的频段 |
| :--- | :--- | :--- |
| **LTE (FDD)** | B1 (2100)、B3 (1800)、B5 (850)、B8 (900) | B1、B3、B5、**B7 (2600)**、B8、**B20 (800)**、**B28 (700)** |
| **LTE (TDD)** | *无* | **B38 (2600)**、**B40 (2300)**、**B41 (2500 - BSNL/Jio)** |
| **WCDMA/UMTS** | B1 (2100)、B5 (850)、B8 (900) | B1、B5、B8 |

---

## 2. 安全第一：分区与 NVRAM 备份

在发出任何底层 Qualcomm DIAG NV 写入命令之前，请备份调制解调器 EFS 分区，
以防止校准数据或 IMEI 永久丢失。

在设备上运行（或通过 SSH）：
```bash
# 1. 转储活动调制解调器 NVRAM 分区
dd if=/dev/disk/by-partlabel/modemst1 of=/tmp/modemst1_factory.img bs=64k
dd if=/dev/disk/by-partlabel/modemst2 of=/tmp/modemst2_factory.img bs=64k
dd if=/dev/disk/by-partlabel/fsg of=/tmp/fsg_factory.img bs=64k

# 2. 将备份传输到主机
scp root@192.168.8.1:/tmp/*_factory.img ~/modem_backups/
```

---

## 3. 暴露 Qualcomm DIAG 接口

在 Qualcomm MSM8916 OpenWrt 中，Hexagon DSP 通过共享内存 rpmsg 通道与应用处理器（AP）通信。
DIAG 服务暴露在调制解调器端点 `/dev/rpmsg_ctrl*` 上。

### 步骤 3.1：创建 RPMSG DIAG 端点
Linux 内核 `rpmsg_char` 驱动提供 `RPMSG_CREATE_EPT_IOCTL` 来创建动态端点。

识别调制解调器 rpmsg 控制节点（通常为 `/dev/rpmsg_ctrl2` 或 `/dev/rpmsg_ctrl3`）：
```bash
ls -l /dev/rpmsg_ctrl*
```

### 步骤 3.2：编译并运行 DIAG 桥
一个轻量级用户空间守护进程（`diag_bridge`）建立 RPMSG `DIAG` 端点，
并在 `/dev/rpmsg0` 与 USB gadget 串口接口 `/dev/ttyGS0` 之间桥接双向流量：

```c
// diag_bridge.c snippet
int ctrl_fd = open("/dev/rpmsg_ctrl2", O_RDWR);
struct rpmsg_endpoint_info ept_info = { .name = "DIAG", .src = RPMSG_ADDR_ANY, .dst = RPMSG_ADDR_ANY };
ioctl(ctrl_fd, RPMSG_CREATE_EPT_IOCTL, &ept_info);

int rpmsg_fd = open("/dev/rpmsg0", O_RDWR | O_NONBLOCK);
int gs0_fd = open("/dev/ttyGS0", O_RDWR | O_NOCTTY | O_NONBLOCK);

// Bi-directional forwarding loop using select() between gs0_fd and rpmsg_fd
```

在设备上启动桥：
```bash
/usr/sbin/diag_bridge &
```

当通过 USB 连接到主机时，主机会检测到 CDC ACM 串口：
```bash
# 在主机 Linux 机器上
ls -l /dev/ttyACM0
```

---

## 4. Qualcomm DIAG 协议与 NV 项规范

Qualcomm 调制解调器通过 DIAG 使用带 CRC-16 CCITT 的 HDLC 帧包进行通信。

### 4.1 HDLC 帧与 CRC-16
- **帧定界符**：`0x7E`
- **转义字符**：`0x7D`（转义字节 = `byte ^ 0x20`）
- **CRC-16 多项式**：`0x8408`（CCITT 反向）
- **初始 CRC**：`0xFFFF`，最终 XOR：`0xFFFF`

### 4.2 包长度要求（关键）
许多自定义脚本因省略请求中的尾部 2 字节状态字段而以 `TimeoutError`
或 `DIAG_BAD_LEN_F`（0x15）失败：
- **`CMD_NV_READ` (0x26)**：必须恰好为 **133 字节**
  - `uint8 cmd` = `0x26`（1 字节）
  - `uint16 nv_item`（2 字节，小端）
  - `uint8 data[128]`（128 字节，请求中为零）
  - `uint16 status` = `0x0000`（2 字节）
  - *总载荷 = 133 字节 + 2 字节 CRC + 1 字节定界符 = 136 字节。*
- **`CMD_NV_WRITE` (0x27)**：必须恰好为 **133 字节**
  - `uint8 cmd` = `0x27`（1 字节）
  - `uint16 nv_item`（2 字节，小端）
  - `uint8 data[128]`（128 字节，目标值以零填充）
  - `uint16 status` = `0x0000`（2 字节）
  - *总载荷 = 133 字节 + 2 字节 CRC + 1 字节定界符 = 136 字节。*

响应中 `status == 0` 表示 `NV_DONE_S`（成功）。

---

## 5. 频段位掩码计算

### 5.1 LTE 频段掩码（NV 6828 - `NV_LTE_BC_CONFIG_I`）
LTE 频段位索引为 `1 << (Band - 1)`，存储在 64 位小端整数中。

| 字节偏移 | 覆盖位 | 包含频段 | 十六进制值 | 启用的频段 |
| :--- | :--- | :--- | :--- | :--- |
| **字节 0** | 位 0–7 | B1–B8 | `0xD5` | B1 (`0x01`) + B3 (`0x04`) + B5 (`0x10`) + B7 (`0x40`) + B8 (`0x80`) |
| **字节 1** | 位 8–15 | B9–B16 | `0x00` | 无 |
| **字节 2** | 位 16–23 | B17–B24 | `0x08` | B20 (`1 << 3` = `0x08`) |
| **字节 3** | 位 24–31 | B25–B32 | `0x08` | B28 (`1 << 3` = `0x08`) |
| **字节 4** | 位 32–39 | B33–B40 | `0xA0` | B38 (`1 << 5` = `0x20`) + B40 (`1 << 7` = `0x80`) |
| **字节 5** | 位 40–47 | B41–B48 | `0x01` | B41 (`1 << 0` = `0x01`) |

**完整的 6 字节十六进制字符串**：
```text
d5 00 08 08 a0 01
```

### 5.2 WCDMA 与 GSM 频段掩码（NV 1877 - `NV_RF_BC_CONFIG_I`）
- 位 7：GSM DCS 1800
- 位 8：GSM EGSM 900
- 位 9：GSM PGSM 900
- 位 19：GSM 850
- 位 21：GSM PCS 1900
- 位 22：WCDMA 频段 I (2100)
- 位 26：WCDMA 频段 V (850)
- 位 49：WCDMA 频段 VIII (900)

**完整的 8 字节十六进制字符串**：
```text
80 03 68 04 00 00 02 00
```

---

## 6. 执行：写入 NV 项

保存并针对主机的 `/dev/ttyACM0` 端口运行以下 Python 自动化脚本：

```python
#!/usr/bin/env python3
import serial, struct, time

def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc = (crc >> 8) ^ CRC_TABLE[(crc ^ b) & 0xFF]
    return crc ^ 0xFFFF

# Precompute CRC table
CRC_TABLE = []
for i in range(256):
    crc = i
    for _ in range(8):
        crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    CRC_TABLE.append(crc)

def hdlc_encode(payload: bytes) -> bytes:
    crc = crc16(payload)
    raw = payload + struct.pack('<H', crc)
    out = bytearray()
    for b in raw:
        if b in (0x7E, 0x7D):
            out.append(0x7D)
            out.append(b ^ 0x20)
        else:
            out.append(b)
    out.append(0x7E)
    return bytes(out)

def write_nv(ser, nv_id: int, hex_data: str):
    data = bytes.fromhex(hex_data).ljust(128, b'\x00')
    # Exact 133-byte packet: cmd (1) + nv_id (2) + data (128) + status (2)
    payload = struct.pack('<BH', 0x27, nv_id) + data + struct.pack('<H', 0)
    frame = hdlc_encode(payload)
    ser.reset_input_buffer()
    ser.write(frame)
    ser.flush()
    time.sleep(0.5)
    resp = ser.read(ser.in_waiting or 200)
    target = bytes([0x27]) + struct.pack('<H', nv_id)
    pos = resp.find(target)
    if pos >= 0:
        status = int.from_bytes(resp[pos+131:pos+133], 'little')
        print(f"NV {nv_id} write result: status={status} (0=OK)")
    else:
        print(f"NV {nv_id} write: acknowledgment received ({len(resp)} bytes)")

ser = serial.Serial('/dev/ttyACM0', baudrate=115200, timeout=3)
ser._update_dtr_state = lambda: None
ser._update_rts_state = lambda: None

# 1. Unlock LTE Bands (B1, B3, B5, B7, B8, B20, B28, B38, B40, B41)
write_nv(ser, 6828, "d5000808a001")

# 2. Unlock GSM & WCDMA Bands
write_nv(ser, 1877, "8003680400000200")

ser.close()
```

### 步骤 6.1：将更改提交到闪存
通过 AP 将写缓冲区刷写到 eMMC：
```bash
ssh root@192.168.8.1 "sync"
```

重启 ModemManager 以触发干净的能力查询：
```bash
ssh root@192.168.8.1 "/etc/init.d/modemmanager restart"
```

---

## 7. 关键修复：防止脚本回退

默认情况下，OpenWrt 中现有的运营商自动配置脚本可能会在非 Jio 网络激活时，
或在 LTE 搜索检测到附近的 Jio/Loop 导频时，尝试将频段锁定到出厂默认值。

### 7.1 根本原因
在 `/usr/sbin/modem-led-monitor` 中：
```bash
# BUGGY ORIGINAL CODE:
case "$op_name" in
    *[Jj]io*|*[Rr]eliance*|*"IN Loop"*) is_jio=1 ;;
esac
if [ "$is_jio" = "1" ]; then
    mmcli -m "$m_idx" --set-current-bands="eutran-1|eutran-3|eutran-5|eutran-8"
fi
```
1. 在自动网络搜索期间，非 Jio SIM（例如 BSNL `40471`）会偷听到来自 Jio
   （`405861` / "IN Loop"）的邻区小区导频。
2. 脚本错误地将运营商识别为 Jio。
3. 它执行了 `mmcli --set-current-bands="eutran-1|eutran-3|eutran-5|eutran-8"`。
4. ModemManager 将该调用转换为 QMI DMS 命令，**将 NV 6828 破坏性地改回出厂 `0x95`**。

### 7.2 永久修复
在 `msm89xx/base-files/usr/sbin/modem-led-monitor` 和
`openwrt/target/linux/msm89xx/base-files/usr/sbin/modem-led-monitor` 两处：

1. 将 `is_jio` 检查严格限制为运营商 MCC/MNC（`4058xx`），在存在非 Jio
   运营商代码时显式忽略邻区基站名称：
   ```bash
   case "$op_code" in
       4058[4-7][0-9]) is_jio=1 ;;
       404*|405*) is_jio=0 ;;
       *)
           case "$op_name" in
               *[Jj]io*|*[Rr]eliance*) is_jio=1 ;;
           esac
           ;;
   esac
   ```

2. 如果需要 Jio 频段限制来避免旧调制解调器固件上的 IRAT 2G/3G 崩溃，
   **动态查询支持的频段**，而不是硬编码出厂频段：
   ```bash
   if [ "$is_jio" = "1" ]; then
       local sup_bands="$(mmcli -m "$m_idx" --output-keyvalue 2>/dev/null | awk -F': ' '/modem.generic.supported-bands.value/ {print $2}')"
       local lte_bands=""
       for b in $(echo "$sup_bands" | tr -s ', ' '\n'); do
           case "$b" in
               eutran-*) lte_bands="${lte_bands:+${lte_bands}|}$b" ;;
           esac
       done
       if [ -n "$lte_bands" ]; then
           mmcli -m "$m_idx" --set-current-bands="$lte_bands" >/dev/null 2>&1 || true
       fi
   fi
   ```

---

## 8. 验证与运行测试

### 步骤 8.1：验证支持的频段和当前频段
查询调制解调器状态：
```bash
mmcli -m 0
```

预期输出：
```text
  ----------------------------------
  Bands    |              supported: utran-1, utran-5, utran-8, eutran-1, eutran-3, eutran-5, 
           |                         eutran-7, eutran-8, eutran-38, eutran-40, eutran-41
           |                current: utran-1, utran-5, utran-8, eutran-1, eutran-3, eutran-5, 
           |                         eutran-7, eutran-8, eutran-38, eutran-40, eutran-41
```

### 步骤 8.2：通过 QMI 验证活跃的射频调谐
验证调制解调器无线电确实调谐到扩展后的频率：
```bash
qmicli -d /dev/wwan0qmi0 --nas-get-rf-band-info
```

预期输出：
```text
[/dev/wwan0qmi0] Successfully got RF band info
Band Information:
	Radio Interface:   'lte'
	Active Band Class: 'eutran-1'
	Active Channel:    '465'
```

检查系统选择偏好：
```bash
qmicli -d /dev/wwan0qmi0 --nas-get-system-selection-preference
```

预期输出：
```text
[/dev/wwan0qmi0] Successfully got system selection preference
	LTE band preference: '1, 3, 5, 7, 8, 38, 40, 41'
```

### 步骤 8.3：将解锁的频段应用到 Netifd / 网络
配置 `/etc/config/network` 以使用多模并偏好 4G：
```bash
uci set network.modem.allowedmode='3g|4g'
uci set network.modem.preferredmode='4g'
uci commit network
/etc/init.d/network reload
```
