> 📄 本文件是 [STOCK_ANDROID_SSH_AND_DEBUG_TOOLKIT_GUIDE.md](STOCK_ANDROID_SSH_AND_DEBUG_TOOLKIT_GUIDE.md) 的英文原文中文译本，内容以英文版为准。

# 高通 MSM8916 原厂 Android SSH 与调试工具包

本工具包为运行原厂 32 位 Android（4.4.4 KitKat / userdebug）的高通 Snapdragon 410（MSM8916）4G LTE USB 加密狗和便携式 Wi-Fi 路由器（例如 **HM-MIFIB-V12**、**HMU05**、**Melbon**、**UFI001B / UFI003**、**FXD 4G LTE** 等）提供一套自动化部署系统和全面的实用工具集。

它提供：
- 端口 22 上的**永久 OpenSSH 服务器（`sshd`）**，拥有完整 root 权限。
- **双重认证**：免密登录（通过 SSH 密钥和/或空密码）以及密码保护登录（通过标准 `passwd`）。
- **完整调试工具套件（426 个 CLI 工具）**，位于 `/system/xbin`，包括 `bash`、`htop`、`strace`、`gdb`、`gdbserver`、`curl`、`git`、`tcpdump`、`iperf`、`socat`、`vim`、`nano`、`wg`（WireGuard）、`zramctl` 以及所有 BusyBox 小程序。
- **EDL 模式灵活性**：
  - 默认使用原生 `reboot edl` 命令。
  - 包含一个**可选载荷**（`reboot-edl` 和 `edl_tcsr.ko`），可安装在原厂 `reboot edl` 缺失或不可用的设备上。
- **便捷的系统命令**：独立的 `rw` 和 `ro` 命令，用于快速解锁和锁定 `/system` 分区。
- **完整的终端仿真**：为 `xterm`、`xterm-256color`、`linux` 和 `vt100` 部署了 terminfo 数据库。

---

## 目录结构

```
device_debug_toolkit/
├── install.sh                  # Automated installer script (supports --with-edl / --without-edl)
├── README.md                   # This guide and documentation
├── payload/                    # Base payload deployed to /system
    ├── xbin/                   # 87 standalone static ARM binaries & helper scripts
    │   ├── bash, sshd, ssh, scp, sftp, sftp-server, ssh-keygen, ssh-add...
    │   ├── curl, git, htop, iftop, nano, vim, strace, gdb, gdbserver...
    │   ├── lsof, socat, tcpdump, iperf, iperf3, rsync, ncdu, netcat, nethogs...
    │   ├── iw, wg, inotifywait, inotifywatch, zramctl, ntfs-3g, mount.exfat-fuse...
    │   ├── useradd, usermod, userdel, groupadd, chsh, passwd...
    │   ├── rw                  # Standalone helper: unlocks /system as RW
    │   └── ro                  # Standalone helper: locks /system as RO
    ├── etc/
    │   ├── ssh/                # OpenSSH server & client configuration + host keys
    │   │   ├── sshd_config     # Configured for Android (PrivilegeSeparation disabled)
    │   │   ├── ssh_config
    │   │   ├── moduli
    │   │   └── ssh_host_*      # Pre-generated RSA, ECDSA, ED25519 host keys
    │   ├── passwd              # Root account (shell: /system/xbin/bash, home: /data/local)
    │   ├── shadow              # Default empty root password (ready for custom 'passwd')
    │   ├── group               # Root and sshd user group definitions
    │   ├── gshadow
    │   ├── profile             # Sources /system/etc/bashrc on login
    │   ├── bashrc              # Colorized prompt, aliases (rw, ro, ll, ports, mem), PATH
    │   └── nanorc, virc, inputrc, mkshrc, login.defs
    └── usr/
        └── share/
            └── terminfo/       # Curses terminal definitions (xterm, xterm-256color, etc.)
└── payload_optional/
    └── edl/                    # Optional EDL payload for devices lacking native 'reboot edl'
        ├── bin/
        │   └── reboot-edl      # Userspace script that arms TCSR latch and reboots
        └── lib/
            └── modules/
                └── edl_tcsr.ko # Kernel module issuing SCM SMC write to Qualcomm TCSR
```

---

## 1. 快速开始：自动安装

通过 USB 将设备连接到主机计算机，然后运行：

### 标准安装（默认：原生 `reboot edl`）
```bash
cd /home/shaanair/Projects/msm8916-openwrt-clean/device_debug_toolkit
./install.sh
```
*如果以交互方式运行，脚本会询问你是否要安装可选的 `reboot-edl` 工具。*

### 安装选项
```bash
# Explicitly skip the optional EDL payload (recommended for standard devices):
./install.sh --without-edl

# Install WITH the optional 'reboot-edl' script & 'edl_tcsr.ko' module:
./install.sh --with-edl

# Target a specific device serial (if multiple ADB devices are attached):
./install.sh --without-edl -s 10d200c3
```

---

## 2. 连接设备

### SSH 终端连接
```bash
# Connect to the device (passwordless with key or empty password prompt):
ssh root@192.168.100.1
```

> **关于主机密钥警告的说明**：如果你之前在同一 IP 上连接过其他设备，请用以下命令从 known_hosts 中清除过期密钥：
> `ssh-keygen -R 192.168.100.1`

### SFTP 文件传输连接
```bash
sftp root@192.168.100.1
```
你可以直接通过 SFTP 或使用 FileZilla、VS Code SFTP 扩展等图形客户端浏览、上传和下载文件。

---

## 3. 管理认证方式（密码 vs. 免密）

### 选项 A：免密访问（默认）
工具包预配置了两种免密登录机制：
1. **公钥认证**：如果你的主机计算机上有 `~/.ssh/id_rsa.pub` 或 `~/.ssh/id_ed25519.pub`，`install.sh` 会自动将其复制到 `/data/local/.ssh/authorized_keys`。从这台计算机连接时，SSH 会立即连接而不提示凭据。
2. **空密码认证**：在 `/system/etc/shadow` 中，root 的密码字段为空，且 `sshd_config` 允许空密码（`PermitEmptyPasswords yes`）。如果从没有密钥的计算机或手机连接，只需在提示时按回车即可。

### 选项 B：用自定义密码保护 root
如果你想强制使用密码保护登录：
1. 通过 SSH 连接到设备：
   ```bash
   ssh root@192.168.100.1
   ```
2. 运行 `passwd`：
   ```bash
   passwd
   ```
   > **关于自动分区处理的说明**：`/system/xbin/passwd` 包含一个自动包装器，它会检查 `/system` 是否以只读（`ro`）挂载，若是则临时解锁为 `rw` 以便写入 `/system/etc/shadow`，完成后重新锁回 `ro`。如果你愿意，也可以手动依次运行 `rw`、`passwd` 和 `ro`。

3. 输入你的新密码（至少 5 个字符，混合大写、小写字母和数字）。
4. 下次有设备在没有授权 SSH 密钥的情况下连接时，SSH 将提示并强制使用该密码。

### 选项 C：恢复回免密登录
如果你之前设置了密码并想移除它以再次实现免密登录：
```bash
passwd -d root
```
*（`-d` 选项会删除 `/etc/shadow` 中 root 的密码哈希，恢复空密码的免密登录。）*

---

## 4. 设备内的常用命令

| 命令 | 描述 |
|---|---|
| `passwd` | 修改 root 密码（自动处理 `/system` 重新挂载）。 |
| `passwd -d root` | 删除 root 密码，使 SSH 登录再次免密。 |
| `rw` | 手动解锁 `/system` 分区（将 `ext4` 挂载为读写）。 |
| `ro` | 手动锁定 `/system` 分区（将 `ext4` 挂载为只读）。 |
| `reboot edl` | 直接重启进入高通紧急下载（9008）模式（使用原生 Android `/system/bin/reboot`）。 |
| `reboot bootloader` | 重启进入高通 Fastboot 模式。 |
| `reboot recovery` | 重启进入 Recovery 分区。 |
| `reboot` | 执行干净的设备重启。 |
| `reboot-edl` | *（仅可选软件包）* 通过 `edl_tcsr.ko` 布设高通 TCSR 寄存器并进入 EDL 模式。 |
| `htop` | 交互式进程查看器和 CPU/RAM 监视器。 |
| `tcpdump -i any` | 直接在蜂窝/桥接接口上抓包。 |
| `iperf -s` | 启动 iperf 带宽测试服务器。 |
| `strace <cmd>` | 追踪系统调用和信号。 |
| `ports` | 别名，列出所有监听的网络套接字（`netstat`）。 |
| `mem` | 查看当前内核内存摘要。 |

> **关于 `reboot` 命令的说明**：`/system/xbin/reboot` 明确链接到原生 Android 二进制文件（`/system/bin/reboot`），而非 BusyBox 的 `reboot`。标准 BusyBox `reboot` 不认识 `edl` 或 `bootloader` 这类 Android 参数，而原生二进制文件会正确地向 Android init（`powerctl`）发信号以切换模式。

---

## 5. 技术细节与手动分步参考

如果你曾经需要手动执行此设置或理解底层 Android 机制：

### 步骤 1：将 ADB shell 提权为 root
在高通原厂 Android userdebug 构建上，可通过以下方式获得临时 root：
```bash
adb shell "setprop service.adb.root 1; busybox killall adbd"
# Wait 2-3 seconds for adbd to restart, then verify:
adb shell id
# Output should show: uid=0(root) gid=0(root)
```

### 步骤 2：重新挂载 `/system`
```bash
adb shell "mount -o remount,rw /system"
```

### 步骤 3：部署二进制文件与权限
`/system/xbin` 中的所有二进制文件都是使用 musl/glibc 编译的 32 位静态 ARM 可执行文件：
```bash
adb shell "chmod 755 /system/xbin/*"
adb shell "chmod 6755 /system/xbin/tcpdump"
adb shell "busybox chown -R 0:0 /system/xbin /system/etc/ssh"
adb shell "/system/bin/busybox --install -s /system/xbin"
# Ensure reboot points to Android native reboot (for 'reboot edl', 'reboot bootloader', etc.):
adb shell "ln -sf /system/bin/reboot /system/xbin/reboot"
```

### 步骤 4：OpenSSH 服务器 Android 适配
标准 OpenSSH 期望 `/var/empty` 和系统用户隔离。在 Android 上，`/system/etc/ssh/sshd_config` 中需要以下设置：
```sshconfig
Port 22
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
PermitEmptyPasswords yes
UseDNS no
UsePrivilegeSeparation no
PidFile /data/local/tmp/sshd.pid
Subsystem sftp /system/xbin/sftp-server
AuthorizedKeysFile /data/local/.ssh/authorized_keys .ssh/authorized_keys
```
并且特权分离运行时目录必须在 `/data` 中创建：
```bash
mkdir -p /data/var/empty
chmod 700 /data/var/empty
busybox chown 0:0 /data/var/empty
```

### 步骤 5：开机持久自启动
高通 Android 每次启动都会通过 Android init 触发 `/system/etc/init.qcom.post_boot.sh`。添加以下代码块可确保 SSH 可靠启动：
```sh
# Master Boot Trigger: Unconditional SSH Lifecycle
(
    sleep 15
    setenforce 0
    mkdir -p /data/var/empty /data/local/tmp
    chmod 700 /data/var/empty
    /system/xbin/sshd -p 22
) &
```

### 步骤 6：锁定系统
```bash
adb shell "sync; sleep 1; mount -o remount,ro /system"
```
