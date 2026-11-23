# Alpine Linux 在 msm89xx 加密狗上的双启动 — 设计方案（已搁置）

状态：**已搁置（2026-10-24）** — 待 OpenWrt 在目标板卡上足够稳定后再实施。本方案中的任何内容都不会阻塞或改动当前的 OpenWrt 镜像。相关事实已于 2026-10-24 现场验证；参见下方“已验证事实”。

## 目标

在 msm8916 加密狗（512 MB RAM、4 GB eMMC）上，将 Alpine Linux 作为 OpenWrt 之外的备选操作系统运行，可按次启动选择，且不冒引导加载器风险。

## 为何可行

- Alpine 已在 msm8916 上运行：postmarketOS 就是 Alpine + 该 SoC 上的主线内核。用户态移植已被验证；剩下的只是我们自己的设备适配层。
- 512 MB RAM 对 Alpine 而言绰绰有余；4 GB eMMC 有足够空间（仅出厂 userdata 就有 2.37 GB；移植本来就会重新分区）。
- 引导加载器是 **lk2nd**（开源，由本仓库用我们的补丁构建，位于 `msm89xx/image/lk2nd-patches/`），而不是锁定的厂商 aboot。它支持 BCB/恢复流程、重启原因、fastboot 以及启动故障切换计数器。
- 第二个可启动内核槽位已存在并已接好线（见下文）。

## 移植已自带的内容（2026-10-24 验证，hmuf02v5）

| 部件 | 状态 |
|---|---|
| `recovery` GPT 分区（p17，16 MiB）+ `misc`（p16，1 MiB） | 所有已出厂的板卡上均存在 |
| `/sbin/reboot-recovery` | 可用：优雅关闭 -> `reboot-mode-raw recovery` -> lk2nd 启动一次 recovery 槽位 |
| rescue 镜像构建器 | `msm89xx/recovery/build-recovery.sh` -> `<board>.img`（内核 + initramfs，USB ACM/NCM 控制台、SSH、Web UI、EDL 逃生通道） |
| 3 次故障切换 | lk2nd 统计从未进入用户态即启动的次数（cookie = misc 的最后 512 B）；达到 `BOOT_FAILOVER_COUNT`（3）后启动 recovery 槽位；`S99recovery-bootcount` 在每次健康启动时清除 cookie |
| EDL 恢复路径 | 反复验证；完整出厂转储已保留（`GitIgnore/MelbonWhiteStock_Dump/`） |

厂商 aboot 字符串检查（出厂转储，2026-10-24）：`boot-recovery`、
`Recovery command: %d %s`、`error in emmc_recovery_init`、`recoveryfs`、
`bootselect`、`fastboot` — 标准 Qualcomm lk misc/recovery 流程已编译进去；不过在运行中的板卡上，lk2nd 已取代它。

## 设计（实施时）

- `boot` 分区保留 OpenWrt。`recovery` 槽位承载 Alpine 启动镜像（Alpine initramfs + 主线内核 + USB-gadget 控制台）。
- 选择 = 一次性：`reboot-recovery` 启动一次 Alpine；Alpine 的 init 必须
  1. 清除重启原因 / BCB，使下一次重启返回 OpenWrt，
  2. 清除 misc 故障切换 cookie（否则一个启动失败的 Alpine 会以 3 次故障切换进入它自身），
  3. 尽早拉起 USB ACM/NCM gadget 控制台（无头设备）。
- 持久模式（阶段 2）：重新分区约 1 GB 用作 Alpine rootfs，将 Alpine initramfs 指向它，添加 `boot-alpine` / `boot-openwrt` 切换命令。此时 misc 故障切换充当安全网（Alpine 连续 3 次启动失败 -> 自动回到 OpenWrt）— 接线已经存在。
- 零刷写备选测试：lk2nd 有 fastboot — `fastboot boot alpine.img` 从 RAM 启动一次。需要在无头设备上进入 fastboot（USB）。

## 明确否决的方案

- 修改 lk/aboot 本身（变砖风险，需要对已签名引导加载器做逆向工程）。
- VM/kexec 优先方案（跨 kexec 时 Qualcomm 外设状态不稳定；仅作为实验再考虑）。
- 交互式启动菜单（加密狗上无按键/屏幕；只有标志位）。

## Alpine 侧待办清单（实施日使用）

1. 内核：复用已打补丁的 OpenWrt 6.12 源码或 pmOS msm8916 内核配置；必须包含 USB configfs gadget 以及用于控制台的 ncm/acm。
2. Initramfs：Alpine `mkinitfs` 配置，带 USB gadget + SSH（dropbear），以及上述 BCB/cookie 清除。
3. boot.img 打包：gzip Image + 板卡 DTB + mkbootimg（与 `msm89xx/recovery/README.md` 中的 rescue 镜像配方相同）。
4. Rootfs 布局：Alpine 基础（约 200 MB）+ 一个数据分区；决定用 ext4。
5. 切换 UX：从 OpenWrt 侧 `reboot-alpine`（复用 reboot-mode 基础设施），从 Alpine 侧 `reboot-openwrt`（按 lk2nd 期望的方式写入同一标志）。
6. 故障切换交互测试：recovery = Alpine 时的启动故障 cookie 行为。
7. 文档：扩展 `msm89xx/recovery/README.md` + 本文件。

## 安全边界

绝不写入：sbl1、tz、hyp、rpm、aboot（或它们的 .bak 孪生）、modem*、modemst*、
fsg、fsc、sec、persist。其余一切（boot、recovery、misc、rootfs）均可通过保留的出厂转储用 EDL 恢复。

## 参考

- `msm89xx/recovery/README.md` — rescue 镜像构建器 + 故障切换细节
- `msm89xx/image/lk2nd-patches/` — lk2nd 故障切换补丁
- `/sbin/reboot-mode.sh`、`/sbin/reboot-mode-raw`、`/etc/init.d/recovery-bootcount`
  （设备上，hmuf02v5）
- 会话 2026-10-24：aboot.bin/GPT 字符串分析、misc=p16 / recovery=p17
  验证、Android 单元 misc 转储（为空 — 无厂商 BCB 真值基线）。
