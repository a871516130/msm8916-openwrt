> 📄 本文件是 [README.md](README.md) 的英文原文中文译本，内容以英文版为准。

# 恢复：救援镜像与 recovery 分区

这些棒状设备上有**两**套独立的救援机制，而且很容易混淆：

| | 救援镜像 | Recovery 分区 |
| :-- | :-- | :-- |
| 是什么 | 生产 kernel + 救援 initramfs，从 eMMC 启动 | 存放该镜像的一个 16 MiB 分区 |
| 存放在哪 | 发布物中的 `recovery-<board>.img`（已冻结——参见 [`msm89xx/recovery`](../../msm89xx/recovery/README.md#shipped-frozen-images)） | 分区 **p17**（`recovery`） |
| 如何启动它 | 用 EDL/fastboot 把它写入 `boot` | 开机键、`reboot recovery`、`fastboot reboot recovery`，或 3 次启动失败 |
| 需要什么 | 只需要镜像 | `GPT_RECOVERY=1` **以及** 打过补丁的 `aboot` |

两者都由 [`msm89xx/recovery/`](../../msm89xx/recovery/) 构建——镜像里有什么
见那个 README（USB NCM + ACM gadget、`192.168.10.1` 上的 SSH、浏览器上传器、
WiFi AP `OpenWrt-Recovery`，以及可选的 WiFi **station**）。 本页讲的是
**分区**以及如何进入它。

---

## 1. 分区布局

启用 `GPT_RECOVERY=1` 时，镜像会写入 17 个分区而不是 15 个：

| # | 名称 | 大小 | 备注 |
| - | :--- | :--- | :---- |
| 13 | `boot` | 64 MiB | kernel + DTB（lk2nd/appended） |
| 14 | `rootfs` | 128 MiB | squashfs —— cmdline 固定 `root=/dev/mmcblk0p14` |
| 15 | `rootfs_data` | 剩余 − 17 MiB | 可写 overlay |
| 16 | `misc` | 1 MiB | FFBM cookie + recovery BCB + 我们的 failover 计数器 |
| 17 | `recovery` | 16 MiB | 救援镜像 |

`misc` 和 `recovery` 是故意追加在 `rootfs_data` **之后**的：直到 `p14`
的每个分区号都保持其偏移，因此已经在运行 OpenWrt 的棒状设备不需要移动它的
boot/rootfs。

今天按此布局构建的板子：**hmuf02v5**、**mf800b**、**mifib-v12**。
另外四块保持 15 分区布局（没有 `misc`、没有 `recovery`）——LuCI 条目在那里
会隐藏自己，failover 也保持静默。

---

## 2. 进入 recovery

### a) 上电时按住 reset 按钮

`lk2nd` 在 `aboot` 运行之前采样板子的 reset 按钮，如果按住了，就把它上报为
**VOLUMEUP**，这正是原厂 bootloader 认作“启动 recovery”的东西。

| 板子 | Recovery 键 |
| :---- | :----------- |
| `mf800b`、`mifib-v12` | reset 按钮，GPIO 102，低电平有效 |
| `hmuf02v5` | **无** —— 它的 reset 按钮是 GPIO 37，那也是 EDL 拉线：上电时按住它会让 SoC 在 `lk2nd` 运行之前掉进 EDL |

所以：拔电、按住按钮、插电、再按住约 2 s。 在两块有按钮的板子上你会进入
recovery；在 hmuf02v5 上则会进入 EDL（那也有用，只是不同）。

### b) 从运行中的系统

```sh
reboot-recovery          # /sbin/reboot-recovery (reboot-edl package)
reboot recovery          # same thing, via the generic wrapper
```

在 LuCI 中：**System → Reboot to Recovery**。 该条目只在
`/sys/class/block/*/uevent` 上报 `PARTNAME=recovery` 时出现，也就是分区
确实存在时。

### c) 三次启动失败后自动进入

`aboot` 在 **`misc` 的最后 512 字节**里维护一个计数器：

```
magic 0x4C4B4643 ("LKFC") | count | padding to 512 bytes
```

每次正常启动都会把它加一；`S99recovery-bootcount`（来自 `reboot-edl`）
在用户态起来后把它清零。 当 `count >= 3` 时，bootloader 清除 cookie 并改为
启动 recovery 分区。 健康的系统每次启动都重置计数器，永远不会触发它——
这是对启动分区已损坏**且**没有 recovery 键的板子的唯一救援路径。

### d) 从 bootloader（`fastboot`）

已经停在 fastboot 里的棒状设备无需任何按键即可操控。
`msm89xx/image/lk2nd-patches/002-fastboot-reboot-reasons.patch`
教给 `aboot` 标准的重启原因：

```sh
fastboot reboot recovery     # boot the recovery partition (RECOVERY_MODE)
fastboot oem edl             # Emergency Download, 05c6:9008
fastboot reboot bootloader   # back to fastboot (stock behaviour)
```

`fastboot reboot edl` 配合 android-tools **不**工作：*客户端*在与设备通信
之前就把 `edl` 当作未知重启目标拒绝了，这正是 EDL 路径也以
`fastboot oem edl` 暴露的原因。 在该补丁之前构建的 `aboot` 对两者都回答
`FAILED (remote: 'unknown command')`。

---

## 3. 在已运行 OpenWrt 的安装上启用 recovery

添加分区**不是** `sysupgrade` 操作——GPT 必须被重写。 你需要：

1. 在设备 profile 中带 `GPT_RECOVERY=1` 运行一次 `flash.sh`（上面三块
   板子出厂就是这么发的）。
2. 用 `BOOT_FAILOVER_COUNT=3` 构建的 `aboot.mbn`——`generate_firmware.sh`
   在构建固件 zip 时会自动注入它。
3. 刷入 `recovery` 的 `recovery-<board>.img`，以及运行中的 rootfs 里的
   `reboot-edl` **r4 或更新**（正是它提供
   `/etc/rc.d/S99recovery-bootcount`）。

用下面的命令检查实机：

```sh
for d in /sys/class/block/*; do grep -l PARTNAME=recovery $d/uevent 2>/dev/null; done
ls -l /etc/rc.d/S99recovery-bootcount
strings /dev/mmcblk0p12 2>/dev/null | grep -c "boot failover"   # aboot patched?
```

从运行中的系统把镜像刷进 `recovery`：

```sh
cat msm89xx/recovery/<board>.img | ssh root@192.168.10.1 'cat > /tmp/r.img'
ssh root@192.168.10.1 'dd if=/tmp/r.img of=/dev/mmcblk0p17 bs=1M conv=fsync; sync'
ssh root@192.168.10.1 'echo 3 > /proc/sys/vm/drop_caches; \
    dd if=/dev/mmcblk0p17 bs=11991040 count=1 2>/dev/null | sha256sum'
```

`conv=fsync` 是关键所在：没有它，重启时写入还在页缓存里，回读会确认从未
落到 flash 上的数据，设备会带着*上一个*镜像回来。 完整流程——前置条件、
构建、刷写、验证，以及 USB 起不来时检查什么——见
[`msm89xx/recovery/README.md`](../../msm89xx/recovery/README.md) 中的
*Step by step: build, flash and run it*。

---

## 4. 陷阱

* **`lk2nd` 必须在采样按键前延时。** TLMM 配置之后的第一次读取返回 0，
  低电平有效测试会把它报成“已按下”——没有那 10 ms 的 `udelay()`，
  每次启动都会落进 recovery。
* **failover 计数器必须在交接时清除。** 如果不清除，之后每次启动都会被
  强制进入 recovery，即使系统已修复——因为唯一能清除它的东西是坏系统
  永远到不了的用户态钩子。
* **没有打过补丁的 `aboot` 的 recovery 分区只是死空间。** 按键和计数器
  都活在 `aboot` 里；单靠 `lk2nd` 无法启动 `p17`。
* **`sysupgrade -n` 会保留 `misc`/`recovery`**（升级不会碰它们）但会清空
  overlay——启动计数器又从零开始，这无害。

---

## 5. 不用网线到达救援镜像

该镜像总会拉起 AP `OpenWrt-Recovery`（WPA2/WPA3，口令 `recovery`）并在其上
提供 `192.168.10.1`，因此手机或笔记本无需 USB 连接即可操控 Web 界面。
加入它的客户端会从同一个为 USB 服务的 dnsmasq 拿到 `192.168.10.x` 租约——
但**没有默认路由、也没有 DNS 服务器**，所以加入 AP 绝不会夺走客户端的
互联网。

那是唯一的无线路径：没有 station 模式，因此盒子不会加入你的局域网，也不会
出现在你常规的地址空间里。 用 AP，或者插上 USB。 *为什么没有 WiFi station
模式*见 [`msm89xx/recovery/README.md`](../../msm89xx/recovery/README.md)，
其中有理由，如果哪天想恢复它，git 历史（`a43efba`）里有代码。

---

## 6. 另见

* [`msm89xx/recovery/README.md`](../../msm89xx/recovery/README.md) —— 镜像
  本身：分步的构建/刷写/运行流程、`/init` 启动了什么、如何重建冻结的二进制、
  Web 界面。
* [`RECOVERY_FIELD_NOTES.md`](RECOVERY_FIELD_NOTES.md) —— 为什么这样构建：
  硬件上遇到的每一次故障（悄悄杀死 DHCP 的缺失 devtmpfs、缺失的 eMMC 节点、
  模块化无线协议栈、夺走主机互联网的 DHCP 租约、没落盘的 `dd`）连同原因与
  修复。
* [`Docs/EDL/`](../EDL/) —— 进入 EDL，以及这些棒状设备的 firehose 怪癖。
* [`Docs/POWER_BUTTON.md`](../POWER_BUTTON.md) —— 在两块有按钮的板子上
  触发 recovery 键的按钮。
