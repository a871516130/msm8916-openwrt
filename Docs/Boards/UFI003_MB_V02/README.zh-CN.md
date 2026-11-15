> 📄 本文件是 [README.md](README.md) 的英文原文中文译本，内容以英文版为准。

# UFI003 MB V02 —— 板卡配置与原厂设备树参考

本页记录 UFI003 MB V02 MSM8916 modem 棒的 OpenWrt 配置与硬件验证情况，
并记录相应的原厂 Qualcomm 设备树条目及其来源。

## OpenWrt 配置

- 构建别名：`ufi003`
- OpenWrt 设备配置：`generic-ufi003-mb-v02`
- DTS：`msm8916-generic-ufi003_mb_v02`
- `SUPPORTED_DEVICES`：`ufi003,mb-v02`
- eMMC：7,634,944 扇区 × 512 字节
- GPT 总扇区数：7,634,944

该配置使用独立的板卡 DTS，并遵循 UFI001B 的功能与配置基线。已在实体
UFI003 MB V02 上验证。

## 原厂设备树标识与匹配

原厂 rootfs 报告的是通用 MSM8916 MTP 型号/compatible，而不是 UFI003 产品
名称。条目 02 自我标识为 **Qualcomm Technologies, Inc. MSM 8916 MTP**，
`qcom,board-id = <0x08 0x00>`。提取出的原厂 DTS 报告相同的通用 rootfs
标识。其运行时 GPIO 标签和值与 UFI003 原厂 GPIO dump 相符；因此 OpenWrt
板卡 DTS 使用 UFI003 专属的 model 和 compatible 字符串。

条目 02 与 2026-11-05 从运行中的 UFI003 棒上读取的 SMEM 板卡标识匹配：
soc_id 206、revision 1.0、hardware_platform 8、subtype 0、
platform_version 65536、PM8916。在提取出的 33 个 QCDT 条目中，它是唯一匹配
MSM8916/soc 206 且 board-id <0x08 0x00> 的条目；原厂 LK 就是用这个匹配来
选择 DTB 的。目前仍没有捕获到原厂 `/proc/device-tree` 的 dump。

## 原厂 QCDT 文件与条目

该目录保留条目 02 的原始 DTB 和反编译 DTS。表中的索引使用提取出的文件名
`dtb00` 到 `dtb32`。

| 文件 | 说明 |
|---|---|
| `dtb02.dtb` | 从原厂 boot 镜像提取的 33 条目 QCDT 表中的原始条目 02 |
| `dtb02.dts` | 该原始 DTB 的反编译源码 |

| 索引 | 型号 | Board ID |
|---:|---|---|
| 00 | MSM 8916 CDP | `0x01/0x00` |
| 01 | MSM 8916 SMB1360 CDP | `0x01/0x01` |
| 02 | MSM 8916 MTP | `0x08/0x00` |
| 03 | MSM 8916 SMB1360 MTP | `0x08/0x01` |
| 04 | MSM 8916 512MB MTP | `0x08/0x100` |
| 05 | MSM 8916 512MB SMB1360 MTP | `0x08/0x101` |
| 06 | MSM8916 RUMI | `0x0f/0x00` |
| 07 | MSM8916 Simulator | `0x10/0x00` |
| 08 | MSM 8916 QRD SKUH | 多个 QRD ID |
| 09 | MSM 8916 QRD SKUI | 多个 QRD ID |
| 10 | MSM 8916 512MB QRD SKUH | 多个 QRD ID |
| 11 | MSM 8916 512MB QRD SKUI | 多个 QRD ID |
| 12 | MSM 8916 QRD SKUHF | 多个 QRD ID |
| 13 | MSM 8916 QRD SKUIC | `0x11010b/0x105` |
| 14 | MSM 8916 QRD SKUID | 多个 QRD ID |
| 15 | MSM 8916 512MB QRD SKUID | 多个 QRD ID |
| 16 | MSM 8936 CDP | `0x01/0x00` |
| 17 | MSM 8936 SMB1360 CDP | `0x01/0x01` |
| 18 | MSM 8936 SMB1360 MTP | `0x08/0x00` |
| 19 | MSM 8936 MTP | `0x08/0x01` |
| 20 | MSM 8936 WCD9306 MTP | `0x08/0x02` |
| 21 | MSM8939 QRD SKUK | `0x1000b/0x05` |
| 22 | MSM 8939 CDP | `0x01/0x00` |
| 23 | MSM 8939 SMB1360 CDP | `0x01/0x01` |
| 24 | MSM 8939 SMB1360 MTP | `0x08/0x00` |
| 25 | MSM 8939 MTP | `0x08/0x01` |
| 26 | MSM 8939 WCD9306 MTP | `0x08/0x02` |
| 27 | MSM8939 RUMI | `0x0f/0x00` |
| 28 | MSM8939 Simulator | `0x10/0x00` |
| 29 | MSM8939 QRD SKUK | 多个 QRD ID |
| 30 | APQ 8016 CDP | `0x01/0x00` |
| 31 | APQ 8016 MTP | `0x08/0x00` |
| 32 | APQ 8016 SMB1360 MTP | `0x08/0x01` |

## GPIO 状态

| TLMM 偏移 | 原厂标签 | 初始状态 | OpenWrt 角色 |
|---:|---|---|---|
| 0 | `ESIM_SEL` | 输出低 | SIM 选择 GPIO |
| 1 | `SIM_EN` | 输出低 | SIM 使能 GPIO |
| 2 | `SIM_SEL` | 输出高（选中物理 SIM） | SIM 选择 GPIO |
| 3 | `ESIM2_SEL` | 输出低 | eSIM 选择 GPIO |
| 20 | `WIFI_S` | 输出低 | `blue:wlan` |
| 21 | `4G_L2` | 输出低 | `green:wan` |
| 22 | `4G_S` | 输出高 | `red:power` |
| 37 | `key_freset` | 输入，高电平有效，下拉 | Restart / failsafe 按键 |
| 68 | `4G_L3` | 输出低 | 辅助 LTE GPIO |

原厂 DTS 将 GPIO37 声明为高电平有效按键并施加下拉；运行时 GPIO dump 显示
它空闲为低电平。按键极性与响应、LED 行为和 SIM 操作均已在实体板上验证。

## 内存保留

捕获到的 OpenWrt 内存映射把 `0x8db00000–0x8dbfffff` 划为 System RAM 内的
1 MiB ramoops 保留区，紧邻从 `0x8dc00000` 开始的保留区域。内核日志确认了
ramoops 与 pstore 的注册。

## 配置功能选择

该配置遵循 UFI001B 基线：

- failsafe，使用 UFI003 的高电平有效 GPIO37；
- Bluetooth；
- WPA3-SAE 与多 SSID；
- CPU CPR 与 800 MHz 上限。

UFI003 DTS 通过在 `&bam_dmux` 上设置 `qcom,a2-pin` 来启用驱动管理的
`a2_pin` modem 保持。`qcom-time-daemon` 仍在该配置之外。Wi-Fi/PMIC 散热
映射来自共享的 `msm8916-ufi.dtsi`（补丁 861），已包含在内。这些可选的
板卡专属功能与已验证的按键、LED 和 SIM 行为是分开的。

UFI 公共 DTS 启用了 `pm8916_usbin` USB extcon；PM8916 充电器节点默认被
禁用。该配置不包含任何电池/BMS 覆盖。只有在确认了实体 UFI003 电池之后才
应添加。

## 构建与硬件验证

```sh
./build.sh list
./build.sh build ufi003
```

UFI003 MB V02 已使用该配置在硬件上验证。板卡可以启动，高电平有效/下拉的
按键响应正确，LED 使用文档所述角色，SIM 按预期工作。

## OpenWrt DTS 对比

OpenWrt 板卡 DTS 由
[`msm89xx/patches/852-arm64-dts-qcom-add-msm8916-generic-ufi003.patch`](../../../msm89xx/patches/852-arm64-dts-qcom-add-msm8916-generic-ufi003.patch)
添加；其上游路径为
`arch/arm64/boot/dts/qcom/msm8916-generic-ufi003_mb_v02.dts`。

## 来源

原始 DTB 和反编译 DTS 来自在旧构建主机上对原厂 boot 镜像的 QCDT 提取。
原始 DTB 是权威版本；反编译结果可能因 dtc 版本而异。
