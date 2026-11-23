# Qualcomm MSM8916 原厂 Android SSH 与调试工具包

此工具包为运行原厂 32 位 Android（4.4.4 KitKat / userdebug）的
Qualcomm Snapdragon 410 (MSM8916) 4G LTE USB 加密狗和便携式 Wi-Fi 路由器
（例如 **HM-MIFIB-V12**、**HMU05**、**Melbon**、**UFI001B / UFI003**、
**FXD 4G LTE** 等）提供自动化部署系统和全面的实用工具套件。

它提供：
- **常驻 OpenSSH 服务器（`sshd`）** 在端口 22 上，具有完整 root 访问权限。
- **双认证**：免密码登录（通过 SSH 密钥和/或空密码）和密码保护登录（通过标准 `passwd`）。
- **完整的调试工具套件（426 个 CLI 工具）** 位于 `/system/xbin`，包括 `bash`、`htop`、
  `strace`、`gdb`、`gdbserver`、`curl`、`git`、`tcpdump`、`iperf`、`socat`、`vim`、
  `nano`、`wg`（WireGuard）、`zramctl` 以及所有 BusyBox applet。
- **EDL 模式灵活性**：
  - 默认使用原生 `reboot edl` 命令。
  - 包含一个**可选载荷**（`reboot-edl` 和 `edl_tcsr.ko`），可安装到原厂 `reboot edl`
    缺失或不可用的设备上。
- **便捷系统命令**：独立的 `rw` 和 `ro` 命令，用于快速解锁和锁定 `/system` 分区。
- **完整终端模拟**：部署 `xterm`、`xterm-256color`、`linux` 和 `vt100` 的 terminfo 数据库。

---

## 目录结构

```
device_debug_toolkit/
├── install.sh                  # 自动化安装脚本（支持 --with-edl / --without-edl）
├── README.md                   # 本指南和文档
├── payload/                    # 部署到 /system 的基础载荷
    ├── xbin/                   # 87 个独立静态 ARM 二进制和辅助脚本
    │   ├── bash, sshd, ssh, scp, sftp, sftp-server, ssh-keygen, ssh-add...
    │   ├── curl, git, htop, iftop, nano, vim, strace, gdb, gdbserver...
    │   ├── lsof, socat, tcpdump, iperf, iperf3, rsync, ncdu, netcat, nethogs...
    │   ├── iw, wg, inotifywait, inotifywatch, zramctl, ntfs-3g, mount.exfat-fuse...
    │   ├── useradd, usermod, userdel, groupadd, chsh, passwd...
    │   ├── rw                  # 独立辅助：解锁 /system 为 RW
    │   └── ro                  # 独立辅助：锁定 /system 为 RO
    ├── etc/
    │   ├── ssh/                # OpenSSH 服务器和客户端配置 + 主机密钥
    │   │   ├── sshd_config     # 为 Android 配置（禁用 PrivilegeSeparation）
    │   │   ├── ssh_config
    │   │   ├── moduli
    │   │   └── ssh_host_*      # 预生成的 RSA、ECDSA、ED25519 主机密钥
    │   ├── passwd              # root 账户（shell: /system/xbin/bash, home: /data/local）
    │   ├── shadow              # 默认空 root 密码（为自定义 'passwd' 准备）
    │   ├── group               # root 和 sshd 用户组定义
    │   ├── gshadow
    │   ├── profile             # 登录时加载 /system/etc/bashrc
    │   ├── bashrc              # 彩色提示符、别名（rw, ro, ll, ports, mem）、PATH
    │   └── nanorc, virc, inputrc, mkshrc, login.defs
    └── usr/
        └── share/
            └── terminfo/       # Curses 终端定义（xterm、xterm-256color 等）
└── payload_optional/
    └── edl/                    # 可选 EDL 载荷，用于缺少原生 'reboot edl' 的设备
        ├── bin/
        │   └── reboot-edl      # 用户空间脚本：武装 TCSR 锁存并重启
        └── lib/
            └── modules/
                └── edl_tcsr.ko # 内核模块：向 Qualcomm TCSR 发出 SCM SMC 写
```

---

## 1. 快速开始：自动化安装

通过 USB 将设备连接到主机，然后运行：

### 标准安装（默认：原生 `reboot edl`）
```bash
cd /home/shaanair/Projects/msm8916-openwrt-clean/device_debug_toolkit
./install.sh
```
*如果交互运行，脚本会询问你是否要安装可选的 `reboot-edl` 工具。*

### 安装选项
```bash
# 显式跳过可选的 EDL 载荷（推荐用于标准设备）：
./install.sh --without-edl

# 带可选的 'reboot-edl' 脚本和 'edl_tcsr.ko' 模块安装：
./install.sh --with-edl

# 指定特定设备序列号（如果连接了多个 ADB 设备）：
./install.sh --without-edl -s 10d200c3
```

---

## 2. 连接到设备

### SSH 终端连接
```bash
# 连接到设备（使用密钥免密码，或空密码提示）：
ssh root@192.168.100.1
```

> **关于主机密钥警告的说明**：如果你先前在同一 IP 上连接过不同设备，
> 用以下命令清除 known_hosts 中的陈旧密钥：
> `ssh-keygen -R 192.168.100.1`

### SFTP 文件传输连接
```bash
sftp root@192.168.100.1
```
你可以通过 SFTP 或图形客户端（如 FileZilla 或 VS Code SFTP 扩展）直接浏览、上传和下载文件。

---

## 3. 管理认证（密码 vs 免密码）

### 选项 A：免密码访问（默认）
工具包预先配置了两种免密码登录机制：
1. **公钥认证**：如果你的主机有 `~/.ssh/id_rsa.pub` 或 `~/.ssh/id_ed25519.pub`，
   `install.sh` 会自动将其复制到 `/data/local/.ssh/authorized_keys`。
   从此计算机连接时，SSH 会立即连接而无需提示凭据。
2. **空密码认证**：在 `/system/etc/shadow` 中，root 有空密码字段，
   且 `sshd_config` 允许空密码（`PermitEmptyPasswords yes`）。
   如果从没有密钥的计算机或手机连接，只需在提示时按回车。

### 选项 B：用自定义密码保护 root
如果你想强制密码保护登录：
1. 通过 SSH 连接到设备：
   ```bash
   ssh root@192.168.100.1
   ```
2. 运行 `passwd`：
   ```bash
   passwd
   ```
   > **关于自动分区处理的说明**：`/system/xbin/passwd` 包含一个自动包装器，
   > 它会检查 `/system` 是否以只读（`ro`）挂载，临时解锁为 `rw` 以写入
   > `/system/etc/shadow`，完成后重新锁定为 `ro`。如果你愿意，也可以手动运行
   > `rw`、`passwd`、`ro`。

3. 输入你的新密码（最少 5 个字符，混合大写、小写和数字）。
4. 下次设备在无授权 SSH 密钥时连接，SSH 会提示并强制执行此密码。

### 选项 C：恢复为免密码登录
如果你之前设置了密码并想移除它，使登录再次免密码：
```bash
passwd -d root
```
*（`-d` 选项会删除 `/etc/shadow` 中 root 的密码哈希，恢复空密码免密码登录。）*

---

## 4. 设备内的有用命令

| 命令 | 描述 |
|---|---|
| `passwd` | 更改 root 密码（自动处理 `/system` 重新挂载）。 |
| `passwd -d root` | 删除 root 密码，使 SSH 登录再次免密码。 |
| `rw` | 手动解锁 `/system` 分区（以读写方式挂载 `ext4`）。 |
| `ro` | 手动锁定 `/system` 分区（以只读方式挂载 `ext4`）。 |
| `reboot edl` | 直接重启进入 Qualcomm 紧急下载（9008）模式（使用原生 Android `/system/bin/reboot`）。 |
| `reboot bootloader` | 重启进入 Qualcomm Fastboot 模式。 |
| `reboot recovery` | 重启进入 Recovery 分区。 |
| `reboot` | 执行干净设备重启。 |
| `reboot-edl` | *（仅可选包）* 通过 `edl_tcsr.ko` 武装 Qualcomm TCSR 寄存器并进入 EDL 模式。 |
| `htop` | 交互式进程查看器和 CPU/RAM 监视器。 |
| `tcpdump -i any` | 直接在蜂窝/桥接接口上抓包。 |
| `iperf -s` | 启动 iperf 带宽测试服务器。 |
| `strace <cmd>` | 跟踪系统调用和信号。 |
| `ports` | 列出所有监听网络套接字的别名（`netstat`）。 |
| `mem` | 查看当前内核内存摘要。 |

> **关于 `reboot` 命令的说明**：`/system/xbin/reboot` 显式链接到原生 Android
> 二进制（`/system/bin/reboot`），而不是 BusyBox `reboot`。标准 BusyBox `reboot`
> 不识别 Android 参数如 `edl` 或 `bootloader`，而原生二进制会正确地向
> Android init（`powerctl`）发出信号以切换模式。

---

## 5. 技术细节与手动逐步参考

如果你需要手动执行此设置或理解底层 Android 机制：

### 第 1 步：将 ADB Shell 提升为 root
在 Qualcomm 原厂 Android userdebug 构建上，可通过以下方式获取临时 root：
```bash
adb shell "setprop service.adb.root 1; busybox killall adbd"
# 等待 2-3 秒让 adbd 重启，然后验证：
adb shell id
# 输出应显示：uid=0(root) gid=0(root)
```

### 第 2 步：重新挂载 `/system`
```bash
adb shell "mount -o remount,rw /system"
```

### 第 3 步：部署二进制和权限
`/system/xbin` 中的所有二进制都是 32 位静态 ARM 可执行文件，用 musl/glibc 编译：
```bash
adb shell "chmod 755 /system/xbin/*"
adb shell "chmod 6755 /system/xbin/tcpdump"
adb shell "busybox chown -R 0:0 /system/xbin /system/etc/ssh"
adb shell "/system/bin/busybox --install -s /system/xbin"
# 确保 reboot 指向 Android 原生 reboot（用于 'reboot edl'、'reboot bootloader' 等）：
adb shell "ln -sf /system/bin/reboot /system/xbin/reboot"
```

### 第 4 步：OpenSSH 服务器 Android 适配
标准 OpenSSH 期望 `/var/empty` 和系统用户分离。在 Android 上，
`/system/etc/ssh/sshd_config` 中需要以下设置：
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
并且必须在 `/data` 中创建权限分离运行时目录：
```bash
mkdir -p /data/var/empty
chmod 700 /data/var/empty
busybox chown 0:0 /data/var/empty
```

### 第 5 步：开机持久自启动
Qualcomm Android 通过 Android init 在每次启动时触发 `/system/etc/init.qcom.post_boot.sh`。
添加此代码块可确保 SSH 可靠启动：
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

### 第 6 步：锁定系统
```bash
adb shell "sync; sleep 1; mount -o remount,ro /system"
```
