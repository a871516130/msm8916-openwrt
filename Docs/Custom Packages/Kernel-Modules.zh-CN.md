# 仓库内内核模块

这些 `kmod-*` 软件包定义在
[`msm89xx/modules.mk`](../../msm89xx/modules.mk) 中 — 它们是 MSM8916 移植所需的树外 /
尚未合入上游的 Qualcomm 驱动。它们被门控到 `@TARGET_msm89xx`，并像其他软件包一样发布到已签名 APK 源。

| 软件包 | 模块 | 自动加载 | 用途 |
| :--- | :--- | :--- | :--- |
| `kmod-qcom-rproc` | `mdt_loader`, `qcom_common`, `qcom_pil_info` | ✅ | Qualcomm **remoteproc** 支持 — 为 SoC 上的远程处理器加载固件。 |
| `kmod-qcom-rproc-wcnss` | `qcom_wcnss_pil`, `wcnss_ctrl` | ✅ | **WCNSS**（Wi-Fi/BT Pronto 核心）remoteproc 固件加载与控制。 |
| `kmod-qcom-rproc-modem` | `qcom_q6v5`, `qcom_q6v5_mss` | ✅ | **Modem**（MPSS/Q6）remoteproc 固件加载与控制。 |
| `kmod-rpm-master-stats` | `rpm_master_stats` | ❌ 手动 | 从 RPM 消息 RAM 读取的每子系统 **RPM 睡眠/唤醒计数器**，暴露于 `/sys/kernel/debug/qcom_rpm_master_stats/{APSS,MPSS,PRONTO}`。不附带 `MODULE_DEVICE_TABLE`（调试模块），因此用 `modprobe rpm_master_stats` 加载。需要 `msm8916.dtsi` 的 master-stats 节点（补丁 824）。 |
| `kmod-rpmsg-wwan-ctrl` | `rpmsg_wwan_ctrl` | ✅ | **RPMSG WWAN 控制** — 暴露使用 RPMSG 的调制解调器控制端口（AT、QMI）。 |
| `kmod-bam-dmux` | `qcom_bam_dmux` | ✅ | Qualcomm **BAM-DMUX** WWAN 网络驱动 — `wwan0` 数据接口。这是承载 A2 引脚及许多 AP 侧稳定性修复的驱动（参见 [Docs/Modem Stability/](../Modem%20Stability/)）。 |
| `kmod-btqca` | `btqca` | ❌ 依赖 | Qualcomm **蓝牙辅助**例程（ROM 补丁 / NVM 下载、BD 地址）。提供 `qca_set_bdaddr_rome()`；自身无平台驱动，作为 `kmod-btqcomsmd` 的依赖被加载。 |
| `kmod-btqcomsmd` | `btqcomsmd` | ✅ | **基于 Qualcomm SMD 的 HCI** — 将蓝牙桥接到 WCNSS 共享内存通道。绑定到 WCNSS remoteproc 启动时创建的 `qcom,wcnss-bt` 平台设备，因此 `wcnss.mdt` 必须存在。 |
| `kmod-sched-bbr` | `tcp_bbr` | ✅ | Google 的 **BBR TCP 拥塞控制** — 基于模型（测量带宽/RTT）而非基于丢包，因此在 LTE 链路上避免填满运营商缓冲区。列于 `DEFAULT_PACKAGES`（`msm89xx/Makefile`），因此每块板卡都预装并自动加载。内核符号保持 `=m`：该模块是镜像中附带的外部 `.ko`，**未**编入 vmlinux。**BBR 是镜像的默认拥塞控制**，而不仅是可选项：[`/etc/sysctl.d/10-bbr.conf`](../../msm89xx/base-files/etc/sysctl.d/10-bbr.conf) 在启动时设置 `net.ipv4.tcp_congestion_control=bbr`（自动加载运行于 `START=10`，sysctl 运行于 `START=11`）。理由、注意事项与 A/B 配方：[**Docs/BBR_TCP_CONGESTION_CONTROL.md**](../BBR_TCP_CONGESTION_CONTROL.md)。该模块由目标内核配置构建（`CONFIG_TCP_CONG_BBR=m`）；本软件包只是附带它。 |

> **自动加载**使用 OpenWrt 的 `AutoProbe`，它会写入一个 `modules.d` 别名，使列出的
> 模块在启动时加载。标记为 ❌ 的模块特意保持为手动/依赖加载。

## 相关

- [**README.md**](README.md) — 用户态软件包。
- [**Docs/Patches/README.md**](../Patches/README.md) — 为这些模块所依赖的 DT 节点和驱动改动添加的内核补丁。
- [**Docs/Bluetooth/**](../Bluetooth/) — 蓝牙启动（使用 `btqca` / `btqcomsmd`）。
