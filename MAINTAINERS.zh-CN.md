> 📄 本文件是 [MAINTAINERS.md](MAINTAINERS.md) 的英文原文中文译本，内容以英文版为准。

# 维护者

本项目采用**按板型指定维护者**的模式：每台设备有一名或多名硬件负责人，负责让其
device-tree 补丁与配置保持最新、在真实硬件上测试 release candidate、并审查涉及其板型的 PR。
负责人（lead）拥有共享的构建流水线与设备表。一个板型配置两名负责人是刻意为之 ——
多一个能刷机的人，少一个单点故障。

## 分支保护与审查流程

`main` 和 `staging-main` 都套用同一套经典分支保护规则。二者只有一项设置不同：

| | `main` | `staging-main` |
| :--- | :--- | :--- |
| 必需的状态检查 | `Shell test suites` | `Shell test suites` |
| 分支必须为最新 | **是** | 否 |
| 直接 `git push` | 拒绝 | 拒绝 |
| 强推 / 删除 | 阻止 | 阻止 |
| `enforce_admins` | **true** | **true** |
| 必需的审查 | 无 | 无 |

- **任何人都不能向这两个分支推送，负责人也不例外。** `enforce_admins: true`
  意味着 admin 标志不能绕过该规则：每个改动都必须通过 Pull Request 到达，且
  `Shell test suites` 必须先通过。这就是为什么发布 runbook 用 PR 而不是 `git push`
  来 promote（见 `Docs/RELEASING_FIRMWARE.md` §6）。
- **没有必需的审查。** `CODEOWNERS` 仍会自动请求正确的审查者，但 GitHub 不会因为缺少
  批准而阻止合并。这是刻意的：`CODEOWNERS` 以 `* @akbar-npj` 结尾，因此要求 code-owner
  审查会让负责人自己的 PR 无法合并（GitHub 禁止批准自己的 PR），而要求*任何*批准
  则需要每次改动都有第二个人。
- **板型维护者获得 Write 权限**，以便他们可以推送自己的 topic / 测试分支
  （例如 `uz801/test`）并开启 PR。由于没有必需的审查，只要检查是绿的，他们就可以
  合并自己板型的 PR —— 审查是一种请求，而不是关卡。负责人会被自动请求查看，
  而真正会阻塞的只有红色的检查。
- **`main` 还要求分支必须为最新**，因此落后的 PR 必须先更新（这会重新运行检查）
  才能合并。`staging-main` 则不然，因为多个板型 PR 会落在那里，让它们相互调和
  正是其意义所在。

## 名册

每个受支持的板型一行。**Hardware** 是维护者手上那台机器的状态 ——
`bench`（在桌上、可测试）、`field`（日常使用中）、`dead`（拥有但无法启动）
或 `none`（完全没有机器）。这一列决定了某个 release candidate 是否真的在该板型上
测试过，所以请如实维护，当机器到达、损坏或修好时更新它。

| 板型（代号） | 丝印 / 营销名 | Compatible | 维护者 | Hardware | 负责内容 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `hmuf02v5` | HMUF02-V5（原 HMU05） | `hmuf02v5,250605v0s`（旧称 `hmu05,250605v0s`） | @akbar-npj | bench | patches 805, 849; `diffconfigs/hmuf02v5` |
| `mifib-v12` | HM-MIFIB-V12 | `mifib-v12,generic` | @akbar-npj | bench | patch 853; `diffconfigs/mifib-v12` |
| `ufi001b` | UFI001B (V2.0) | `ufi001b,250605v0s` | @akbar-npj | **dead** — 已拥有，待维修 | patch 806; `diffconfigs/ufi001b` |
| `mf800b` | MF800B | `mf800b,generic` | @akbar-npj | **none — 需要测试者** | patch 807; `diffconfigs/mf800b` |
| `uf02` | UF02 (250605 V0S) | `uf02,250605v0s` | @akbar-npj | **none — 需要测试者** | patches 804, 851; `diffconfigs/uf02` |
| `uz801` | UZ801 (v3) | `yiming,uz801-v3` | @isprogrammer, @giraygokirmak | bench（@isprogrammer）+ field，日常车载（@giraygokirmak） | patches 803, 851; `diffconfigs/uz801` |
| `ufi003` | UFI003 MB V02 | `ufi003,mb-v02` | @isprogrammer | bench | patch 852; `diffconfigs/ufi003` |
| `jz02` | JZ02 Battery MiFi | `jz02,generic` | @GargoilXD | bench（@GargoilXD） | patch 868; `diffconfigs/jz02`; `sim-select`, `sim-test`, `20-usb0-bridge` |
| `uf896` | UF896 (v1.1) | `uf896,v1.1` | @akbar-npj | **none — 需要测试者** | patch 867; `diffconfigs/uf896` |

**没有可用机器**（`dead` 或 `none`）的板型仍在维护 —— 代码保持最新、镜像能构建 ——
但发布版中没有任何东西在它们上面刷过，那里的 bug 会由用户而不是我们发现。截至 r8，
这样的板型是 `mf800b`、`uf02` 和 `uf896`；`ufi001b` 是 `dead`，在维修完成之前也加入它们的
行列。这些行正是 issue
[#13](https://github.com/akbar-npj/msm8916-openwrt/issues/13) 所要征集的内容，
而其中任何一个板型拥有第二位负责人，都会把“由用户报告”的 bug 变成经过测试的 bug。

### 共享文件（由负责人拥有）

它们不属于任何单一板型，因为它们影响所有板型：

- `msm89xx/image/msm8916.mk` —— 设备表（一个文件，无法被 `CODEOWNERS` 按行拆分；
  按约定由各板型维护者审查自己那一块）
- patches 801/802（DTS 骨架、reserved-memory 标签），818/824/834/838/843/846
  （PMIC、RPM 统计、CPU interconnect/OPP/CPR），861（`msm8916-ufi.dtsi` 中的
  Wi-Fi/PMIC 散热控制，由 UFI 系列板型共享）
- `build.sh`、`diffconfigs/*` 的共享选项、`msm89xx/base-files/`、
  `msm89xx/modules.mk`、CI workflows 以及 `RELEASE_NOTES.md`

### 保持其最新

这张表和 `CODEOWNERS` 是同一份记录的两种形式：`CODEOWNERS` 是 GitHub 执行的内容，
本文件是给人读的内容。要在同一个 commit 中修改它们 —— 一个名字只出现在其中一个地方，
板型就会悄悄失去它的审查者。当一个板型增加或失去负责人时，也要更新 issue #13 中的镜像表。

## 职责

- **保持板型最新** —— 当 kernel 或共享 SoC 代码变化时，rebase 该板型的 DTS/补丁；
  尽早标记破坏。
- **测试 release candidate** —— 把 RC 刷到你的硬件上，在发布版打 tag 之前报告
  启动 / modem / Wi-Fi 状态。
- **审查 PR** —— GitHub 会自动就你那一列的文件请求你的审查。
- **没有压力** —— 即使是“愿意测试 RC”也很有价值。大家的理解是投入时间因人而异。

## 命名约定（适用于所有地方）

一个板型 = 一个身份，在以下所有地方**一致**地使用：

- device-tree 文件：`msm8916-generic-<codename>.dts`
- `compatible` 字符串：`<codename>,<rev>`（例如 `hmuf02v5,250605v0s`）
- OpenWrt 设备名 / `DEVICE_MODEL`（例如 `HMUF02-V5`）
- `diffconfigs/<codename>`
- 发布文件名与构建命令

**尽早改名，只改一次。** 一个板型用两个名字发布得越久，之后造成的改动就越多。

### 历史：HMU05 → HMUF02-V5

先前名为 `hmu05`（丝印 `HMU05 4G Modem Stick`）的板型，实物标签是
**HMUF02-V5**。它在本仓库中被改名以匹配实物丝印。旧的 `hmu05,250605v0s` compatible
被保留在 `SUPPORTED_DEVICES` 中，以便现有的 sysupgrade 镜像仍然匹配 —— 从旧镜像
sysupgrade 到新镜像受支持；反向则不受支持。

> 注意：本仓库还发布一个**独立的** `uf02` 设备（compatible `uf02,250605v0s`）。
> `uf02` 与 `hmuf02v5` **不是**同一块板型；不要混淆二者。它们是 DTS 不同的、
> 不同的 V1.0-HiMI 棒子。

## 识别已安装的发布版本（Note #2）

OpenWrt 本身永远报告上游的基础版本，因此它无法告诉你某根棒子上运行的是哪个项目构建。
本仓库通过 `CONFIG_VERSION_*` 把一个**项目发布版本**烙进每个镜像。

在运行中的系统上：

```sh
ubus call system board | jsonfilter -e @.release.version
# -> e.g. 25.12.5-r5
cat /etc/os-release | grep VERSION_
```

唯一权威来源是仓库的 **`version`** 文件。要提升它：

```sh
./sync-version.sh 25.12.6-r1   # rewrites version + propagates to all diffconfigs
```

`CONFIG_VERSION_DIST` 是 `msm8916-openwrt`；`CONFIG_VERSION_NUMBER` 是完整的
`X.Y.Z-rN` 字符串；`CONFIG_VERSION_CODE` 是其中的 `rN` 部分。仓库 / bug 的 URL
指向这个 GitHub 项目，因此 `opkg` 和 LuCI 的“report bug”流程都会落在这里。
