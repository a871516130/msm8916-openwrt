> 📄 本文件是 [readme.md](readme.md) 的英文原文中文译本，内容以英文版为准。

# USB Gadget 管理器 —— UCI 配置指南

面向 OpenWrt、基于 configfs 接口的通用 USB Gadget 管理器。

## 快速开始

```bash
# View current configuration
uci show usbgadget

# Enable/start the service
/etc/init.d/usb-gadget enable
/etc/init.d/usb-gadget start

# Check status
/etc/init.d/usb-gadget status
```

## 配置文件

位置：`/etc/config/usbgadget`

## 常用操作

### 启用/禁用 USB Gadget 模式

```bash
# Disable gadget (enable host mode - for USB storage, etc.)
uci set usbgadget.usb.enabled='0'
uci commit usbgadget
/etc/init.d/usb-gadget restart

# Enable gadget mode
uci set usbgadget.usb.enabled='1'
uci commit usbgadget
/etc/init.d/usb-gadget restart
```

### 网络功能

#### RNDIS（Windows 以太网）

```bash
# Enable RNDIS
uci set usbgadget.rndis.enabled='1'
uci commit usbgadget
/etc/init.d/usb-gadget restart
```

**兼容性：** Windows（所有版本，即插即用）

#### ECM（macOS/Linux 以太网）

```bash
# Enable ECM
uci set usbgadget.ecm.enabled='1'
uci set usbgadget.rndis.enabled='0'  # Disable RNDIS
uci commit usbgadget
/etc/init.d/usb-gadget restart
```

**兼容性：** macOS ≤10.14、Linux（全部）

#### NCM（现代高性能以太网）

```bash
# Enable NCM (best performance)
uci set usbgadget.ncm.enabled='1'
uci set usbgadget.rndis.enabled='0'  # Disable RNDIS
uci set usbgadget.ecm.enabled='0'     # Disable ECM
uci commit usbgadget
/etc/init.d/usb-gadget restart
```

**兼容性：** Windows 11+、macOS ≥10.15、Linux（全部）

**注意：** 网络接口会自动加入 LAN 桥。

### 串口控制台（ACM）

#### 启用带登录 shell 的串口控制台

```bash
# Enable ACM with shell access
uci set usbgadget.acm.enabled='1'
uci set usbgadget.acm.shell='1'
uci commit usbgadget
/etc/init.d/usb-gadget restart

# Access from host:
# Linux/macOS: screen /dev/ttyACM0 115200
# Windows: Use PuTTY or similar on COMx port
```

#### 启用原始 TTY（无 shell）

```bash
# Enable ACM without shell (raw serial port)
uci set usbgadget.acm.enabled='1'
uci set usbgadget.acm.shell='0'
uci commit usbgadget
/etc/init.d/usb-gadget restart
```

### 大容量存储（UMS）

```bash
# Enable USB mass storage
uci set usbgadget.ums.enabled='1'
uci set usbgadget.ums.image_path='/var/lib/usb-gadget/storage.img'
uci set usbgadget.ums.image_size='1G'
uci set usbgadget.ums.readonly='0'  # 0=read-write, 1=read-only
uci commit usbgadget
/etc/init.d/usb-gadget restart
```

**注意：** 镜像文件会在首次使用时自动创建。

### 设备信息

```bash
# Change USB vendor/product name
uci set usbgadget.usb.manufacturer='MyCompany'
uci set usbgadget.usb.product='My USB Device'
uci commit usbgadget
/etc/init.d/usb-gadget restart

# Change USB IDs (advanced)
uci set usbgadget.usb.vendor_id='0x1234'
uci set usbgadget.usb.product_id='0x5678'
uci commit usbgadget
/etc/init.d/usb-gadget restart
```

### 自定义 Gadget 名称

```bash
# Change internal gadget name (optional)
uci set usbgadget.usb.gadget_name='my-device'
uci commit usbgadget
/etc/init.d/usb-gadget restart
```

## 常见场景

### 场景 1：快速网络访问（Windows PC）

```bash
uci set usbgadget.usb.enabled='1'
uci set usbgadget.rndis.enabled='1'
uci commit usbgadget
/etc/init.d/usb-gadget restart
```

连接 USB 线。Windows 会检测到 "Remote NDIS Compatible Device" 并从 OpenWrt
获取 DHCP。

### 场景 2：最大性能（现代操作系统）

```bash
uci set usbgadget.usb.enabled='1'
uci set usbgadget.ncm.enabled='1'
uci set usbgadget.rndis.enabled='0'
uci commit usbgadget
/etc/init.d/usb-gadget restart
```

### 场景 3：串口控制台 + 网络

```bash
uci set usbgadget.usb.enabled='1'
uci set usbgadget.rndis.enabled='1'
uci set usbgadget.acm.enabled='1'
uci set usbgadget.acm.shell='1'
uci commit usbgadget
/etc/init.d/usb-gadget restart
```

在同一条 USB 连接上同时提供网络访问和串口控制台。

### 场景 4：USB 存储 + 网络

```bash
uci set usbgadget.usb.enabled='1'
uci set usbgadget.rndis.enabled='1'
uci set usbgadget.ums.enabled='1'
uci set usbgadget.ums.image_size='2G'
uci commit usbgadget
/etc/init.d/usb-gadget restart
```

### 场景 5：切换到 USB 主机模式

```bash
# Disable gadget to use USB port for storage, etc.
uci set usbgadget.usb.enabled='0'
uci commit usbgadget
/etc/init.d/usb-gadget restart
```

现在你可以把 USB 存储设备接到 OpenWrt 设备上了。

## 服务管理

```bash
# Start
/etc/init.d/usb-gadget start

# Stop
/etc/init.d/usb-gadget stop

# Restart (applies new configuration)
/etc/init.d/usb-gadget restart

# Status
/etc/init.d/usb-gadget status

# Enable on boot
/etc/init.d/usb-gadget enable

# Disable on boot
/etc/init.d/usb-gadget disable
```

## 查看配置

```bash
# View all settings
uci show usbgadget

# View specific section
uci show usbgadget.usb
uci show usbgadget.rndis
uci show usbgadget.acm

# Export to file
uci export usbgadget > /tmp/usbgadget-backup.conf

# Import from file
uci import usbgadget < /tmp/usbgadget-backup.conf
```

## 故障排查

### 检查 gadget 是否激活

```bash
/etc/init.d/usb-gadget status
```

### 查看日志

```bash
logread | grep usb-gadget
```

### 检查 USB 控制器

```bash
ls /sys/class/udc/
# Should show: ci_hdrc.0 (MSM8916), 20980000.usb (RPi), etc.
```

### 验证网络接口

```bash
ip link show
# Look for: usb0, usb1, etc.

# Check if added to bridge
uci show network.@device[0].ports
```

### 恢复默认值

```bash
rm /etc/config/usbgadget
/etc/init.d/usb-gadget restart
```

这会用默认值重新创建配置。

### 常见问题

**"No UDC device found"**
- 未启用 USB gadget 内核支持
- 安装：
  - `opkg install kmod-usb-gadget kmod-usb-configfs`
  - `apk add kmod-usb-gadget kmod-usb-configfs`

**"ttyGS0 not found"**
- ACM 功能大约需要 10 秒初始化
- 检查：`ls -l /dev/ttyGS0`

**网络不工作**
- 确认功能已启用：`uci show usbgadget.rndis.enabled`
- 检查接口是否存在：`ip link show usb0`
- 验证桥接：`brctl show br-lan`

## 硬件兼容性

**以下设备自动检测 USB 控制器：**
- Raspberry Pi（所有带 USB OTG 的型号）
- Qualcomm MSM8916/MSM89xx 设备
- Orange Pi、Banana Pi
- 任何具备 USB gadget 内核支持的设备

**无需任何针对硬件的配置！**

## 进阶：手动选择 UDC

如果自动检测失败：

```bash
# Check available UDC
ls /sys/class/udc/

# Set manually
uci set usbgadget.usb.udc_device='ci_hdrc.0'  # Example
uci commit usbgadget
/etc/init.d/usb-gadget restart
```

## 配置参考

### 设备节（`config device 'usb'`）

| 选项 | 默认值 | 说明 |
|--------|---------|-------------|
| `enabled` | `1` | 启用/禁用 gadget（0=主机模式，1=设备模式） |
| `gadget_name` | `g1` | 内部 gadget 名称（任意字符串） |
| `vendor_id` | `0x1d6b` | USB Vendor ID（Linux Foundation） |
| `product_id` | `0x0104` | USB Product ID（多功能复合设备） |
| `device_version` | `0x0100` | 设备版本（BCD 格式） |
| `manufacturer` | `OpenWrt` | 向主机显示的制造商字符串 |
| `product` | `USB Gadget` | 向主机显示的产品字符串 |
| `udc_device` | _(空)_ | UDC 设备名（为空时自动检测） |

### 功能节

每个功能都有：
- `enabled`：`0` 或 `1`
- `description`：人类可读描述（系统不使用）

#### RNDIS 功能（`config function 'rndis'`）
无额外选项。

#### ECM 功能（`config function 'ecm'`）
无额外选项。

#### NCM 功能（`config function 'ncm'`）
无额外选项。

#### ACM 功能（`config function 'acm'`）
- `shell`：`0` 或 `1` —— 在串口控制台上启用登录 shell

#### UMS 功能（`config function 'ums'`）
- `image_path`：镜像文件路径
- `image_size`：创建时的大小（例如 `512M`、`1G`、`2G`）
- `readonly`：`0`（读写）或 `1`（只读）

## 提示

- **多功能：** 可以同时启用多个功能（例如 RNDIS + ACM）
- **网络优先级：** 一次只应启用一个网络功能（RNDIS、ECM 或 NCM）
- **序列号：** 从 `/etc/machine-id` 自动生成以保证唯一
- **MAC 地址：** 确定性自动生成（同一设备 = 相同 MAC）
- **存储持久性：** UMS 镜像在重启后保留（位于 `/var`，即 `/tmp`）

## 了解更多

- OpenWrt USB Gadget：https://openwrt.org/docs/guide-user/hardware/usb_gadget
- Linux USB Gadget API：https://www.kernel.org/doc/html/latest/usb/gadget_configfs.html
- UCI 文档：https://openwrt.org/docs/guide-user/base-system/uci
