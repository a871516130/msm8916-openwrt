# MSM8916 OpenWrt 启动错误与守护进程警告的调查和修复

> **注（2026-10-10）：** 下方引用的 `msm89xx/base-files/etc/init.d/hmu05-modem-pm` init 服务已被**移除** —— 它实现的 A2 调制解调器电源引脚现在位于 `qcom_bam_dmux` 驱动中（DT `qcom,a2-pin`，补丁 848/849）。这些引用保留为纯路径（不再是活动链接）。

## 1. 概述与问题陈述

在 Qualcomm Snapdragon 410（MSM8916）OpenWrt 系统的设备启动和服务初始化期间，多个内核错误（`kern.err`）、用户空间存储错误（`user.err`）和守护进程警告（`daemon.err`）被记录到 `dmesg` 和 syslog：

```text
[Jun 29, 2026, 1:01:37 PM UTC] kern.err: [    0.844843] qcom-smsm smsm: mbox_request_channel: can't parse "mboxes" property
[Jun 29, 2026, 1:01:37 PM UTC] kern.err: [    0.844915] qcom-smsm smsm: mbox_request_channel: can't parse "mboxes" property
[Jun 29, 2026, 1:01:37 PM UTC] kern.err: [    0.851151] qcom-smsm smsm: mbox_request_channel: can't parse "mboxes" property
[Jun 29, 2026, 1:01:37 PM UTC] user.info: [    7.539555] block: attempting to load /tmp/overlay/upper/etc/config/fstab
[Jun 29, 2026, 1:01:37 PM UTC] user.err: [    7.541141] block: unable to load configuration (fstab: Entry not found)
[Jun 29, 2026, 1:01:37 PM UTC] user.info: [    7.545679] block: attempting to load /tmp/overlay/etc/config/fstab
[Jun 29, 2026, 1:01:37 PM UTC] user.err: [    7.552294] block: unable to load configuration (fstab: Entry not found)
[Jun 29, 2026, 1:01:37 PM UTC] user.info: [    7.558201] block: attempting to load /etc/config/fstab
[Jun 29, 2026, 1:01:37 PM UTC] user.err: [    7.568457] block: unable to load configuration (fstab: Entry not found)
[Jun 29, 2026, 1:01:37 PM UTC] user.err: [    7.570097] block: no usable configuration
[Jun 29, 2026, 1:01:37 PM UTC] user.info: [    7.577078] block: attempting to load /etc/config/fstab
[Jun 29, 2026, 1:01:37 PM UTC] user.err: [    7.580972] block: unable to load configuration (fstab: Entry not found)
[Jun 29, 2026, 1:01:37 PM UTC] user.err: [    7.586077] block: no usable configuration
[Jun 29, 2026, 1:01:37 PM UTC] user.info: [    7.873002] block: attempting to load /etc/config/fstab
[Jun 29, 2026, 1:01:37 PM UTC] user.err: [    7.876792] block: unable to load configuration (fstab: Entry not found)
[Jun 29, 2026, 1:01:37 PM UTC] user.err: [    7.881843] block: no usable configuration
[Jun 29, 2026, 1:01:38 PM UTC] daemon.err: modprobe: failed to find a module named qrtr-tun
[Jun 29, 2026, 1:01:41 PM UTC] daemon.err: modprobe: failed to find a module named qrtr-tun
[Jun 29, 2026, 1:01:42 PM UTC] kern.err: [   15.681075] wcn36xx: ERROR HAL_8023_MULTICAST_LIST rsp failed err=16
[Jun 29, 2026, 1:01:42 PM UTC] daemon.err: collectd[2658]: plugin_load: plugin "cpu" successfully loaded.
[Jun 29, 2026, 1:01:42 PM UTC] daemon.info: ModemManager[2462]: hotplug: ModemManager not yet available
[Jun 29, 2026, 1:01:42 PM UTC] daemon.err: collectd[2658]: plugin_load: plugin "interface" successfully loaded.
[Jun 29, 2026, 1:01:42 PM UTC] daemon.err: collectd[2658]: plugin_load: plugin "iwinfo" successfully loaded.
[Jun 29, 2026, 1:01:42 PM UTC] daemon.err: collectd[2658]: plugin_load: plugin "load" successfully loaded.
[Jun 29, 2026, 1:01:42 PM UTC] daemon.err: collectd[2658]: plugin_load: plugin "memory" successfully loaded.
[Jun 29, 2026, 1:01:42 PM UTC] daemon.notice: [2523]: <msg> ModemManager (version 1.24.0) starting in system bus...
[Jun 29, 2026, 1:01:42 PM UTC] daemon.err: collectd[2658]: plugin_load: plugin "rrdtool" successfully loaded.
[Jun 29, 2026, 1:01:42 PM UTC] daemon.err: collectd[2658]: rrdtool plugin: RRASingle = true: creating only AVERAGE RRAs
[Jun 29, 2026, 1:01:42 PM UTC] daemon.err: collectd[2658]: Initialization complete, entering read-loop.
```

本指南详述每项的技术调查、根本原因诊断和确切修复。

---

## 2. 问题 1：`qcom-smsm smsm: mbox_request_channel: can't parse "mboxes" property`

### 2.1 症状
```text
[Jun 29, 2026, 1:01:37 PM UTC] kern.err: [    0.844843] qcom-smsm smsm: mbox_request_channel: can't parse "mboxes" property
[Jun 29, 2026, 1:01:37 PM UTC] kern.err: [    0.844915] qcom-smsm smsm: mbox_request_channel: can't parse "mboxes" property
[Jun 29, 2026, 1:01:37 PM UTC] kern.err: [    0.851151] qcom-smsm smsm: mbox_request_channel: can't parse "mboxes" property
```

### 2.2 根本原因分析
1. 在 `drivers/soc/qcom/smsm.c` 中，`qcom_smsm_probe()` 函数为 Qualcomm 处理器间通信建立共享内存状态机（Shared Memory State Machine）。
2. 驱动查询 `smsm_get_size_info()` 以确定参与的主机数量（`smsm->num_hosts`），在 MSM8916 上为 4（主机 0：APPS，主机 1：MODEM，主机 2：AUDIO，主机 3：WCNSS）。
3. 探测循环遍历从 `0` 到 `smsm->num_hosts - 1` 的每个主机 ID，并调用 `smsm_parse_mbox(smsm, id)`：
   ```c
   for (id = 0; id < smsm->num_hosts; id++) {
       ret = smsm_parse_mbox(smsm, id);
       if (!ret)
           continue;
       ret = smsm_parse_ipc(smsm, id);
       if (ret < 0)
           goto out_put;
   }
   ```
4. `smsm_parse_mbox()` 无条件调用 `mbox_request_channel(&smsm->mbox_client, host_id)`。
5. 在 Linux 6.12 中，`drivers/mailbox/mailbox.c` 里的 `mbox_request_channel()` 调用 `fwnode_property_get_reference_args(fwnode, "mboxes", "#mbox-cells", 0, index, &fwspec)`。每当这失败时，`mbox_request_channel()` 发出高优先级内核错误：
   ```c
   dev_err(dev, "%s: can't parse \"%s\" property\n", __func__, "mboxes");
   ```
6. 在 `arch/arm64/boot/dts/qcom/msm8916.dtsi` 中，`smsm` 节点指定：
   ```dts
   mboxes = <0>, <&apcs 13>, <0>, <&apcs 19>;
   ```
   - **主机 0** 是本地主机（`APPS`）。它从不需向自己发送 IPC 中断或邮箱通道。因为条目 0 是 `<0>`（一个空 phandle），解析器返回 `-ENOENT` 并记录错误。
   - **主机 2** 是 `AUDIO`，在 MSM8916 上未使用，也表示成 `<0>`。解析器返回 `-ENOENT` 并记录错误。
   - 任何超出范围的远程主机索引同样触发 `-ENOENT` 和错误。
   - 此外，如果邮箱控制器（`apcs`）尚未探测，`mbox_request_channel()` 返回 `-EPROBE_DEFER`，但 SMSM 驱动以前忽略此错误并回退到不存在的 syscon 条目，而不是推迟探测。

### 2.3 解决方案与实现
创建了内核补丁 [`msm89xx/patches/816-qcom-smsm-validate-mbox-before-request.patch`](../msm89xx/patches/816-qcom-smsm-validate-mbox-before-request.patch)：
- 跳过为 `smsm->local_host`（`host_id == smsm->local_host`）请求传出邮箱通道。
- 使用 `of_parse_phandle_with_args()` 在调用 `mbox_request_channel()`*之前*验证设备树中 `host_id` 存在一个真实、非空的 phandle。如果条目是 `<0>` 或缺失，则静默跳过邮箱请求。
- 如果邮箱提供者尚未就绪，干净地传播 `-EPROBE_DEFER`。

---

## 3. 问题 2：`block: unable to load configuration (fstab: Entry not found)` 与 `block: no usable configuration`

### 3.1 症状
```text
[Jun 29, 2026, 1:01:37 PM UTC] user.info: [    7.539555] block: attempting to load /tmp/overlay/upper/etc/config/fstab
[Jun 29, 2026, 1:01:37 PM UTC] user.err: [    7.541141] block: unable to load configuration (fstab: Entry not found)
[Jun 29, 2026, 1:01:37 PM UTC] user.info: [    7.545679] block: attempting to load /tmp/overlay/etc/config/fstab
[Jun 29, 2026, 1:01:37 PM UTC] user.err: [    7.552294] block: unable to load configuration (fstab: Entry not found)
[Jun 29, 2026, 1:01:37 PM UTC] user.info: [    7.558201] block: attempting to load /etc/config/fstab
[Jun 29, 2026, 1:01:37 PM UTC] user.err: [    7.568457] block: unable to load configuration (fstab: Entry not found)
[Jun 29, 2026, 1:01:37 PM UTC] user.err: [    7.570097] block: no usable configuration
```

### 3.2 根本原因分析
1. 在早期 OpenWrt preinit（`/lib/preinit/80_mount_root`）期间，`mount_root` 执行 `mount_extroot("/tmp/overlay")` 以检查 rootfs 或 overlay 是否应切换到外部分区。
2. 在 OpenWrt 的 `fstools` 包（`block.c`）中，`config_load(cfg)` 尝试加载：
   - `/tmp/overlay/upper/etc/config/fstab`
   - `/tmp/overlay/etc/config/fstab`
   - `/etc/config/fstab`
3. 在原厂 OpenWrt 中，`/etc/config/fstab` 不随 `base-files` 发布。相反，它由 `/etc/uci-defaults/10-fstab` 在首次启动时通过 `block detect > /etc/config/fstab` 动态生成。
4. 然而，`/etc/uci-defaults/` 只在*更晚*的启动序列中当 `/sbin/init` 启动 `/etc/init.d/boot` 时才运行。在 preinit（7.539s）和 eMMC 分区的早期内核热插拔事件（7.577s、7.873s）期间，`/etc/config/fstab` 尚不存在。
5. 此外，`block.c` 中的 `config_try_load(ctx, path)` 在调用 `uci_load(ctx, file, &pkg)` 前没有测试 `access(path, R_OK)`。每当文件缺失时，`uci_load` 失败，`block` 用 `unable to load configuration (fstab: Entry not found)` 和 `no usable configuration` 刷屏 syslog。

### 3.3 解决方案与实现
1. **预填默认 fstab**：创建了 [`msm89xx/base-files/etc/config/fstab`](../msm89xx/base-files/etc/config/fstab)，带标准 OpenWrt 全局块挂载设置：
   ```uci
   config global
   	option anon_swap '0'
   	option anon_mount '0'
   	option auto_swap '1'
   	option auto_mount '1'
   	option delay_root '5'
   	option check_fs '0'
   ```
   这确保 `/etc/config/fstab` 从启动的最初一刻就存在于 rootfs 上，满足早期 preinit 和热插拔查找。
2. **防止 `fstools` 中的推测性错误刷屏**：添加了补丁 [`openwrt-overlay/package/system/fstools/patches/0001-block-skip-nonexistent-fstab-in-config-try-load.patch`](../openwrt-overlay/package/system/fstools/patches/0001-block-skip-nonexistent-fstab-in-config-try-load.patch)，让 `config_try_load()` 在调用 `uci_load()` 前检查 `if (access(path, R_OK)) return NULL;`。不存在的推测性路径（`/tmp/overlay/upper/...`）被静默跳过，不记录错误。

---

## 4. 问题 3：`modprobe: failed to find a module named qrtr-tun`

### 4.1 症状
```text
[Jun 29, 2026, 1:01:38 PM UTC] daemon.err: modprobe: failed to find a module named qrtr-tun
[Jun 29, 2026, 1:01:41 PM UTC] daemon.err: modprobe: failed to find a module named qrtr-tun
```

### 4.2 根本原因分析
1. Qualcomm 远程文件系统守护进程服务 [`packages/rmtfs/files/rmtfs.init`](../packages/rmtfs/files/rmtfs.init)（START=15）和 QRTR 名称服务器服务 [`packages/qrtr/files/qrtrns.init`](../packages/qrtr/files/qrtrns.init)（START=60）包含：
   ```sh
   load_modules() {
       modprobe qrtr 2>/dev/null || true
       modprobe qrtr-tun 2>/dev/null || true
   }
   ```
2. 在 MSM8916 平台上：
   - `CONFIG_QRTR=y` 和 `CONFIG_QRTR_SMD=y` 直接编译进内核镜像。
   - APPS 处理器与 Hexagon 调制解调器 DSP 之间的 QRTR 通信通过共享内存设备（**SMD**）通道（`IPCRTR`）运行。
   - `qrtr-tun` 是一个 TUN 字符设备驱动，仅用于测试或通过网络设备进行用户空间隧道；它在 MSM8916 上既未启用（`CONFIG_QRTR_TUN` 未设置）也不需要。
3. OpenWrt 的 `modprobe` 由 `kmodloader`（`ubox`）提供。当请求的模块名无法在 `/lib/modules/$(uname -r)/` 中找到时，`kmodloader` 调用：
   ```c
   ULOG_ERR("failed to find a module named %s\n", name);
   ```
   `ULOG_ERR` 直接以 `LOG_DAEMON | LOG_ERR` 写入 syslog。shell 的 stderr 重定向（`2>/dev/null || true`）只抑制控制台输出，syslog 错误仍保持活动。

### 4.3 解决方案与实现
修改了 [`packages/qrtr/files/qrtrns.init`](../packages/qrtr/files/qrtrns.init) 和 [`packages/rmtfs/files/rmtfs.init`](../packages/rmtfs/files/rmtfs.init)：
- 移除了对 `modprobe qrtr-tun` 的调用。
- 将无条件 `modprobe qrtr` 替换为对 `/sys/module/qrtr` 的检查：
  ```sh
  load_modules() {
      [ -d /sys/module/qrtr ] || modprobe qrtr 2>/dev/null || true
  }
  ```
因为 `CONFIG_QRTR=y` 是内建的，`/sys/module/qrtr` 已经存在，不再进行不必要的 modprobe 调用。

---

## 5. 问题 4：`wcn36xx: ERROR HAL_8023_MULTICAST_LIST rsp failed err=16`

### 5.1 症状
```text
[Jun 29, 2026, 1:01:42 PM UTC] kern.err: [   15.681075] wcn36xx: ERROR HAL_8023_MULTICAST_LIST rsp failed err=16
```

### 5.2 根本原因分析
1. 在 `drivers/net/wireless/ath/wcn36xx/main.c` 中，`wcn36xx_configure_filter()` 处理从 `mac80211` 传递的硬件组播过滤请求：
   ```c
   /* FW handles MC filtering only when connected as STA */
   if (*total & FIF_ALLMULTI)
       wcn36xx_smd_set_mc_list(wcn, vif, NULL);
   else if (NL80211_IFTYPE_STATION == vif->type && tmp->sta_assoc)
       wcn36xx_smd_set_mc_list(wcn, vif, fp);
   ```
2. 在 Qualcomm WCN36xx 硬件中，固件*只*支持作为**关联站点**运行时的主机定向组播列表过滤。
3. 当 OpenWrt 启动并配置网络时：
   - 无线接口 `wlan0` 被加入 LAN 桥（`br-lan`）。
   - Linux 桥配置自动在成员端口上设置 `IFF_ALLMULTI` / `FIF_ALLMULTI` 以接受组播流量（mDNS、IGMP、IPv6 路由器发现）。
4. 当 `wcn36xx_configure_filter()` 求值 `*total & FIF_ALLMULTI` 时，它分发 `wcn36xx_smd_set_mc_list(wcn, vif, NULL)`，而不检查接口是否处于站点模式、是否已关联、或 `bss_index` 是否有效（`!= 0xFF` / `WCN36XX_HAL_BSS_INVALID_IDX`）。
5. 因为接口要么在 AP 模式（hostapd 默认）要么是未关联的 STA，固件以错误码 16（`eHAL_STATUS_BSS_NOT_FOUND` / `eHAL_STATUS_INVALID_PARAMETER`）拒绝 HAL 命令。
6. `smd.c` 中的 `wcn36xx_smd_set_mc_list()` 收到状态检查失败并记录：
   ```c
   wcn36xx_err("HAL_8023_MULTICAST_LIST rsp failed err=%d\n", ret);
   ```

### 5.3 解决方案与实现
创建了内核补丁 [`openwrt-overlay/package/kernel/mac80211/patches/ath/450-wcn36xx-only-send-mc-list-when-sta-associated.patch`](../openwrt-overlay/package/kernel/mac80211/patches/ath/450-wcn36xx-only-send-mc-list-when-sta-associated.patch)：
- 显式将 `FIF_ALLMULTI` 组播列表更新守卫在检查之后：
  ```c
  /* FW handles MC filtering only when connected as STA */
  if (NL80211_IFTYPE_STATION == vif->type && tmp->sta_assoc &&
      tmp->bss_index != WCN36XX_HAL_BSS_INVALID_IDX) {
      if (*total & FIF_ALLMULTI)
          wcn36xx_smd_set_mc_list(wcn, vif, NULL);
      else
          wcn36xx_smd_set_mc_list(wcn, vif, fp);
  }
  ```
- 如果接口是 AP 或尚未关联，则不会向固件发送无效 SMD 命令，从而消除错误。当接口作为站点关联时，过滤器正常配置。

---

## 6. Collectd 与 ModemManager 日志分析

用户日志片段包含若干标记为 `daemon.err`、`daemon.info` 和 `daemon.notice` 的行：

```text
[Jun 29, 2026, 1:01:42 PM UTC] daemon.err: collectd[2658]: plugin_load: plugin "cpu" successfully loaded.
[Jun 29, 2026, 1:01:42 PM UTC] daemon.info: ModemManager[2462]: hotplug: ModemManager not yet available
[Jun 29, 2026, 1:01:42 PM UTC] daemon.err: collectd[2658]: plugin_load: plugin "interface" successfully loaded.
[Jun 29, 2026, 1:01:42 PM UTC] daemon.err: collectd[2658]: plugin_load: plugin "iwinfo" successfully loaded.
[Jun 29, 2026, 1:01:42 PM UTC] daemon.err: collectd[2658]: plugin_load: plugin "load" successfully loaded.
[Jun 29, 2026, 1:01:42 PM UTC] daemon.err: collectd[2658]: plugin_load: plugin "memory" successfully loaded.
[Jun 29, 2026, 1:01:42 PM UTC] daemon.notice: [2523]: <msg> ModemManager (version 1.24.0) starting in system bus...
[Jun 29, 2026, 1:01:42 PM UTC] daemon.err: collectd[2658]: plugin_load: plugin "rrdtool" successfully loaded.
[Jun 29, 2026, 1:01:42 PM UTC] daemon.err: collectd[2658]: rrdtool plugin: RRASingle = true: creating only AVERAGE RRAs
[Jun 29, 2026, 1:01:42 PM UTC] daemon.err: collectd[2658]: Initialization complete, entering read-loop.
```

### 6.1 Collectd 优先级分类
- **原因**：OpenWrt 的 init 脚本 `/etc/init.d/collectd` 在前台模式（`-f`）下以 `procd` 监督运行 collectd，并设置 `procd_set_param stderr 1`。
- 在 `procd` 中，被监督守护进程的标准错误流被重定向到 `logd`，syslog 级别为 `LOG_DAEMON | LOG_ERR`（`daemon.err`）。
- 当 collectd 未启用 `syslog` 输出插件启动时，它把标准启动横幅和插件加载通知打印到 stderr。
- **结论**：这些消息**完全是正常的操作通知**（`plugin successfully loaded`、`Initialization complete, entering read-loop`），不是真正的错误。

> **更新：** `collectd`（和 `watchcat`）自那以后已从固件构建中**完全移除**，所以本节仅作为 2026 年 6 月历史日志片段的分析保留 —— 该守护进程不再发布。

### 6.2 ModemManager 热插拔通知
- **原因**：在 1:01:42 PM，系统热插拔子系统检测到蜂窝调制解调器 USB / SMD 接口，而 ModemManager 正在系统总线上启动（`ModemManager (version 1.24.0) starting in system bus...`）。
- 热插拔脚本检查 ModemManager 是否响应 D-Bus 请求。因为它仍在初始化，热插拔脚本记录一条信息消息（`daemon.info: hotplug: ModemManager not yet available`）并退出。
- 一旦 ModemManager 完成总线注册，它会自动枚举所有调制解调器端口。
- **结论**：正常的启动时并发行为；以 `info` 优先级记录，不是错误。

---

---

## 7. 问题 5：`remoteproc remoteproc1/0: request_firmware failed: -2` / `Boot failed: -2`

### 7.1 症状
```text
[Jun 29, 2026, 12:59:22 PM UTC] kern.err: [    9.469784] remoteproc remoteproc1: request_firmware failed: -2
[Jun 29, 2026, 12:59:23 PM UTC] kern.err: [   11.875673] remoteproc remoteproc0: request_firmware failed: -2
[Jun 29, 2026, 12:59:23 PM UTC] kern.err: [   11.883776] remoteproc remoteproc0: Boot failed: -2
```

### 7.2 根本原因分析
1. MSM8916 的 Qualcomm 协处理器固件（调制解调器：`mba.mbn` / `modem.mdt`；WCNSS：`wcnss.mdt`）是专有 Qualcomm 二进制，不能直接在 upstream OpenWrt squashfs 镜像内分发。
2. 相反，OpenWrt 包 [`msm-firmware-dumper`](../packages/msm-firmware-dumper) 在首次启动时自动挂载设备的原厂 eMMC 调制解调器分区（`/dev/mmcblk0p6`），将固件文件提取到 `/lib/firmware/`，并创建 `/lib/firmware/DUMPED`。
3. 固件转储服务 [`/etc/init.d/msm-firmware-dumper`](../packages/msm-firmware-dumper/files/msm-firmware-dumper.init) 在运行级别 `START=95`（约启动第 31 秒）执行。
4. 然而，在**干净刷写后立即首次启动**的内核模块加载和服务启动期间：
   - `remoteproc1`（WCNSS）在第 9.4 秒以 `auto_boot = true` 探测。
   - `remoteproc0`（调制解调器）在第 11.8 秒当 `/etc/init.d/rmtfs`（START=15）启动并调用 `rproc_start()` 时启动。
   - 在首次启动的第 9.4 和 11.8 秒，固件文件尚不存在于 `/lib/firmware`。
   - 因此，`request_firmware()` 返回 `-2`（`-ENOENT`），记录该警告。
5. 在第 31 秒，`msm-firmware-dumper` 挂载分区，提取所有固件文件，并循环遍历 `/sys/class/remoteproc/remoteproc*/state` 发出 `start`。两个处理器都上电并成功初始化。
6. **后续启动行为**：在所有后续重启中，固件文件已存在于 `/overlay/upper/lib/firmware/`。正如在运行硬件上经验验证的，`remoteproc1` 在第 13.7 秒启动 `wcnss.mdt`，`remoteproc0` 在第 17.6 秒启动 `mba.mbn`，**零错误**。

---

## 8. 问题 6：`l13: voltage operation not allowed`

### 8.1 症状
```text
[Jun 29, 2026, 12:59:45 PM UTC] kern.err: [   34.255959] l13: voltage operation not allowed
```

### 8.2 根本原因分析
1. 在 `drivers/phy/qualcomm/phy-qcom-usb-hs.c` 中，Qualcomm USB 2.0 高速 PHY 驱动在 `qcom_usb_hs_phy_power_on()` 期间配置其模拟 3.3V 电源轨：
   ```c
   ret = regulator_set_voltage_triplet(uphy->v3p3, 3050000, 3300000, 3300000);
   if (ret)
       goto err_3p3;
   ```
2. 电源 `v3p3` 通过设备树（`msm8916-pm8916.dtsi`）链接到 PMIC 稳压器 `pm8916_l13`：
   ```dts
   &usb_hs_phy {
       v1p8-supply = <&pm8916_l7>;
       v3p3-supply = <&pm8916_l13>;
   };
   ```
3. 在标准 upstream `msm8916-pm8916.dtsi` 中，LDO 约束以相同的最小和最大电压声明：
   ```dts
   pm8916_l13: l13 {
       regulator-min-microvolt = <3075000>;
       regulator-max-microvolt = <3075000>;
   };
   ```
4. 在 Linux 内核稳压器核心（[`drivers/regulator/of_regulator.c`](../openwrt/build_dir/target-aarch64_generic_musl/linux-msm89xx_msm8916/linux-6.12.94/drivers/regulator/of_regulator.c%23L106)）中，`REGULATOR_CHANGE_VOLTAGE` 能力仅在最小和最大约束不同时启用：
   ```c
   /* Voltage change possible? */
   if (constraints->min_uV != constraints->max_uV)
       constraints->valid_ops_mask |= REGULATOR_CHANGE_VOLTAGE;
   ```
5. 当 `usb-gadget` 初始化并绑定 UDC（`ci_hdrc.0`）时，PHY 驱动执行 `regulator_set_voltage_triplet()`。因为 `min_uV == max_uV`，稳压器核心检查 [`drivers/regulator/core.c`](../openwrt/build_dir/target-aarch64_generic_musl/linux-msm89xx_msm8916/linux-6.12.94/drivers/regulator/core.c%23L430) 中的 `regulator_ops_is_valid(rdev, REGULATOR_CHANGE_VOLTAGE)` 并拒绝调用：
   ```c
   rdev_err(rdev, "voltage operation not allowed\n");
   return -EPERM;
   ```
6. 这导致 PHY `power_on` 例程失败并跳转到 `err_3p3`，使 PHY 未复位并运行在引导加载程序默认值上。

### 8.3 解决方案与实现
创建了内核补丁 [`msm89xx/patches/818-arm64-dts-qcom-msm8916-pm8916-l13-voltage-range.patch`](../msm89xx/patches/818-arm64-dts-qcom-msm8916-pm8916-l13-voltage-range.patch)：
- 扩展 `pm8916_l13` 的设备树约束以反映 USB HS PHY 驱动所需的三元组：
  ```dts
  pm8916_l13: l13 {
  -    regulator-min-microvolt = <3075000>;
  -    regulator-max-microvolt = <3075000>;
  +    regulator-min-microvolt = <3050000>;
  +    regulator-max-microvolt = <3300000>;
  };
  ```
- 这启用 `REGULATOR_CHANGE_VOLTAGE`，满足 `regulator_set_voltage_triplet()`，完全防止 `voltage operation not allowed` 错误，并允许 USB HS PHY 干净地上电和校准。

---

## 9. 问题 7：`remoteproc remoteproc0: crash detected in 4080000.remoteproc: type fatal error`（:Excep  :0: 在 913s）

### 9.1 症状
```text
[Sep 3, 2026, 9:34:16 AM UTC] kern.err: [  913.670698] qcom-q6v5-mss 4080000.remoteproc: fatal error received:     :Excep  :0:
[Sep 3, 2026, 9:34:16 AM UTC] kern.err: [  913.670892] remoteproc remoteproc0: crash detected in 4080000.remoteproc: type fatal error
[Sep 3, 2026, 9:34:16 AM UTC] kern.err: [  913.677598] remoteproc remoteproc0: handling crash #1 in 4080000.remoteproc
[Sep 3, 2026, 9:34:16 AM UTC] kern.err: [  913.685842] remoteproc remoteproc0: recovering 4080000.remoteproc
```

### 9.2 根本原因分析
1. **周期性 900 秒（15 分钟）EFS2 同步**：Qualcomm 调制解调器固件发起周期性非易失存储器（NV）写回，将更新的 LTE 定时和射频统计写回 eMMC 分区（`modemst1`、`modemst2`），通过 `rmtfs` 在 900 秒定时器上进行。
2. **运行时电源塌陷抖动**：默认情况下，Linux 内核 `qcom_bam_dmux.c` 在 1000ms 无活动后自动挂起，触发 SMSM 电源塌陷（`pc`），并使共享内存和 DMA 通道进入睡眠。`/sys/devices/platform/soc@0/4080000.remoteproc/` 下的所有 sysfs 节点默认是 `power/control: auto`。
3. **Hexagon 总线异常**：当调制解调器固件在 DMA 通道挂起时尝试 900 秒写回，IPC 握手超时，产生 Hexagon QDSP6 硬件异常 0（`:Excep  :0:`）。
4. **自愈恢复**：Remoteproc 捕获致命异常，重新加载 DSP 固件（`mba.mbn` 和 `modem.mdt`），并在 0.6 秒内恢复调制解调器。然而，不锁定运行时 PM，DMA 通道仍然脆弱。

### 9.3 解决方案与实现（HMU05 特定设备）
1. **新 init 服务**：创建了 `msm89xx/base-files/etc/init.d/hmu05-modem-pm`（`START=96`；此后已移除）。严格限定为 `board_name == *hmu05*`。启动时将所有 `4080000.remoteproc` 和 `bam-dmux` 节点永久保持活动：
   ```sh
   for f in $(find /sys/devices/platform/soc@0/4080000.remoteproc/ -name "control"); do
       echo on > "$f" 2>/dev/null || true
   done
   for f in $(find /sys/devices/platform/soc@0/4080000.remoteproc/ -name "autosuspend_delay_ms"); do
       echo -1 > "$f" 2>/dev/null || true
   done
   ```
2. **在 `modem-led-monitor` 中的监督执行**：在 [`msm89xx/base-files/usr/sbin/modem-led-monitor`](../msm89xx/base-files/usr/sbin/modem-led-monitor) 中，当在 HMU05 上运行时，在 5 秒健康循环期间动态检查并把 `4080000.remoteproc:bam-dmux/power/control` 锁定为 `on`。
3. **首次启动配置**：在 [`msm89xx/base-files/etc/uci-defaults/99-msm89xx-firstboot`](../msm89xx/base-files/etc/uci-defaults/99-msm89xx-firstboot) 中加入了 HMU05 限定的运行时 PM 锁。

### 9.4 验证与结果
- 部署到实机硬件并监视超过 913 秒故障阈值。
- 达到**超过 33 分钟（2020+ 秒）**的连续运行时间。
- `dmesg` 确认**零崩溃、零致命错误、零 remoteproc 重启**。

---

## 10. 变更总结

| 组件 | 目标文件 | 修复性质 |
| :--- | :--- | :--- |
| **Qualcomm SMSM** | [`msm89xx/patches/816-qcom-smsm-validate-mbox-before-request.patch`](../msm89xx/patches/816-qcom-smsm-validate-mbox-before-request.patch) | 内核补丁：在 `mbox_request_channel` 前跳过本地主机并验证 DT phandle。 |
| **FSTools / Preinit** | [`msm89xx/base-files/etc/config/fstab`](../msm89xx/base-files/etc/config/fstab) | 为 preinit 和早期热插拔发布默认 `/etc/config/fstab`。 |
| **FSTools / Block** | [`openwrt-overlay/package/system/fstools/patches/0001-block-skip-nonexistent-fstab-in-config-try-load.patch`](../openwrt-overlay/package/system/fstools/patches/0001-block-skip-nonexistent-fstab-in-config-try-load.patch) | 在 `config_try_load()` 中调用 `uci_load()` 前检查 `access(path, R_OK)`。 |
| **QRTR 守护进程** | [`packages/qrtr/files/qrtrns.init`](../packages/qrtr/files/qrtrns.init) | 移除不存在的 `qrtr-tun` modprobe 并检查 `/sys/module/qrtr`。 |
| **RMTFS 守护进程** | [`packages/rmtfs/files/rmtfs.init`](../packages/rmtfs/files/rmtfs.init) | 移除不存在的 `qrtr-tun` modprobe 并检查 `/sys/module/qrtr`。 |
| **Wi-Fi WCN36xx** | [`openwrt-overlay/package/kernel/mac80211/patches/ath/450-wcn36xx-only-send-mc-list-when-sta-associated.patch`](../openwrt-overlay/package/kernel/mac80211/patches/ath/450-wcn36xx-only-send-mc-list-when-sta-associated.patch) | 内核补丁：仅在关联的 STA 接口上发送 `WCN36XX_HAL_8023_MULTICAST_LIST_REQ`。 |
| **PMIC / USB HS PHY** | [`msm89xx/patches/818-arm64-dts-qcom-msm8916-pm8916-l13-voltage-range.patch`](../msm89xx/patches/818-arm64-dts-qcom-msm8916-pm8916-l13-voltage-range.patch) | 内核补丁：将 L13 电压范围加宽到 3.05V–3.3V 以便 `regulator_set_voltage_triplet` 成功。 |
| **HMU05 Modem PM** | `msm89xx/base-files/etc/init.d/hmu05-modem-pm`（此后已移除；现为驱动 A2 引脚） | Init 服务：为 HMU05 remoteproc 和 BAM-DMUX 锁定 `control=on` 和 `autosuspend=-1`。 |
| **HMU05 健康守卫** | [`msm89xx/base-files/usr/sbin/modem-led-monitor`](../msm89xx/base-files/usr/sbin/modem-led-monitor) | 持续检查：确保 BAM-DMUX 电源控制跨重新枚举保持 `on`。 |
| **HMU05 首次启动** | [`msm89xx/base-files/etc/uci-defaults/99-msm89xx-firstboot`](../msm89xx/base-files/etc/uci-defaults/99-msm89xx-firstboot) | 首次启动脚本：在初始刷写时配置 HMU05 运行时 PM 锁。 |
| **文档** | [`Docs/Patches/README.md`](Patches/README.md) | 将新补丁 816、817 和 818 编目。 |
| **文档** | [`Docs/BOOT_ERRORS_INVESTIGATION_AND_FIXES.md`](BOOT_ERRORS_INVESTIGATION_AND_FIXES.md) | 综合工程报告、根本原因分析和实机验证。 |

