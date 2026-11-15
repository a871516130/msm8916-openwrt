> 📄 本文件是 [HMUF02V5.md](HMUF02V5.md) 的英文原文中文译本，内容以英文版为准。

# HMUF02-V5

本页记录 **HMUF02-V5** MSM8916 modem 棒的 OpenWrt 配置与硬件验证情况。它是
本项目的**参考 / 主力板**——受测设备，所有恢复与稳定性功能都在这台设备上
得到验证。其他板卡上属于可选的功能，在这里全部启用。

## 构建标识与存储

- 构建别名：`hmuf02v5`
- OpenWrt 设备配置：`generic-hmuf02v5`
- DTS：`msm8916-generic-hmuf02v5`
- `SUPPORTED_DEVICES`：`hmuf02v5,250605v0s`
- eMMC：7,634,944 扇区 × 512 字节
- GPT 总扇区数：7,634,944
- 恢复分区：**有**（17 分区布局，`misc` + `recovery`）——参见
  [Recovery](../RECOVERY/README.md)
- Ramoops：有（`ramoops@8db00000`，1 MiB）

## LED

| GPIO | 功能 | 说明 |
| ---: | :------- | :--- |
| 71 | `wlan`（蓝色） | Wi-Fi AP 活动 |
| 72 | `power`（红色） | 默认**点亮**——modem/子系统健康状态 |
| 73 | `wan`（绿色） | 4G / 互联网活动 |

## Reset / failsafe 按键

- GPIO **37**，**高电平有效，下拉**（空闲为低，按下为高）。
- 开机后前 7 秒内短按 → **failsafe**（2026-10-10 实机验证）；长按 5 秒 →
  **恢复出厂设置**。
- 这是唯一一块 failsafe 按键流程确认可用的板卡。关键在于极性是高电平有效/
  下拉——相反的声明会让按键完全无效。参见
  [Failsafe](../Failsafe/README.md)。

## SIM

HMUF02-V5 是**唯一**暴露 `sim-presence` / `sim_hotplug` 节点的板卡（TLMM
**GPIO 114**，高电平有效）。物理 SIM 热插拔在这里**已实现并经实机验证**
（端到端约 15 秒）。参见
[SIM Hot-Swap](../SIM_HOT_SWAP.md)。

## 配置功能选择（完整集合）

这块板启用了项目交付的全部功能：

- failsafe —— **已验证**
- SIM 热插拔 —— **已验证**（`sim_hotplug` 服务在每块板上都启用 1，但只有
  该线存在的地方才有意义）
- **A2 电源轨保持**（补丁 848 + 849）—— modem `HIMI_U01_MODEM_V1.0`，
  同样是暴露给 `a2_power.c:1189` 静默卡死问题的 HiMI 基带
- **`qcom-time-daemon`** —— **仅限** HMUF02-V5；锚定 modem 的 ATS 状态
  （在其他所有板上其 init 都是空操作）
- **Wi-Fi + PMIC 热量缓解**（补丁 861）—— 映射表位于共享的
  `msm8916-ufi.dtsi`，因此每块板都有
- 恢复分区
- Bluetooth、WPA3-SAE、多 SSID
- CPU CPR 与 800 MHz 上限
- Himi-OK modem 正常门控

## 备注

整个约 900 秒 modem 致命故障的调查就是在这块板上解决的；修复在 AP 侧
（Himi-OK 门控 + A2 保持），而不是基带补丁。modem 固件本身与原厂 Android
逐字节相同。参见 wiki 中的
[Modem Stability](../Modem%20Stability/README.md)。
