> 📄 本文件是 [UFI001B.md](UFI001B.md) 的英文原文中文译本，内容以英文版为准。

# UFI001B

本页记录 **UFI001B** MSM8916 modem 棒的 OpenWrt 配置与硬件验证情况。它是
其他配置所依据的*参考*板，但其 modem 是不同修订版（V2.0），**不需要**——
也没有启用——A2 电源轨保持。

## 构建标识与存储

- 构建别名：`ufi001b`
- OpenWrt 设备配置：`generic-ufi001b`
- DTS：`msm8916-generic-ufi001b`
- `SUPPORTED_DEVICES`：`ufi001b,250605v0s`
- eMMC：7,569,408 扇区 × 512 字节（4 GB 级别）
- GPT 总扇区数：7,569,408
- 恢复分区：**无**（15 分区布局）
- Ramoops：有（`ramoops@8db00000`，1 MiB）

## LED

| GPIO | 功能 | 说明 |
| ---: | :------- | :--- |
| 22 | `power`（红色） | 默认**点亮**——modem/子系统健康状态 |
| 21 | `wan`（绿色） | 4G / 互联网活动 |
| 20 | `wlan`（蓝色） | Wi-Fi AP 活动 |

## Reset / failsafe 按键

- GPIO **37**，**高电平有效，下拉**（与 HMUF02-V5 相同的接法）。
- 开机后前 7 秒内短按 → failsafe；长按 5 秒 → 恢复出厂设置。
- 真机验证？**尚未**——声明为高电平有效/下拉，但未确认。串口 `f` 键是
  备用手段。

## SIM

板级补丁定义了 SIM 路由 hog：

| GPIO | 线路 | 状态 |
| ---: | :--- | :--- |
| 1 | `sim_en` | 低 |
| 2 | `sim_sel` | 高（选中物理 SIM） |
| 68 | （辅助 LTE GPIO） | 低 |

物理 SIM 热插拔（`sim_hotplug`）**未测试**——未暴露 `sim-presence` 节点。
参见 [SIM Hot-Swap](../SIM_HOT_SWAP.md)。

## 配置功能选择

遵循公共基线：

- failsafe（按键，未验证）
- Bluetooth
- WPA3-SAE 与多 SSID
- CPU CPR 与 800 MHz 上限

有意**不启用 A2 电源轨保持**：它的 modem 是 `MPSS.DPM.2.0.2`（V2.0），不会
出现 `a2_power.c:1189` 静默卡死问题，因此保留正常的 runtime-suspend 路径。
同时也不包含 HMUF02-V5 的热量映射、`qcom-time-daemon` 和恢复分区。

## 备注

UFI001B 的 RF/收发器布局与原厂 MSM8916 MTP 相同；与 HMU05/HMUF02 系列不同，
它**不是** RF 移植候选。参见 wiki 中的
[Modem Stability](../Modem%20Stability/README.md)。
