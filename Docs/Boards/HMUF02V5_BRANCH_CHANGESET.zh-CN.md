# HMUF02-V5 分支变更集（相对 `main`）

状态：**已完成并在硬件上验证**（2026-10-19）
分支：`test/hmuf02v5-rename-and-version`
提交：`8cd34fa` `2416e73` `0d49cc0` `75386bf` `52a0002` `a4da026`
基线：`main` @ `cda9d48`（领先六个提交）

本文档是此分支上所有与 `main` 不同内容的参考依据。它存在的目的是让其他文档（README、wiki、板卡指南）能从一个准确的来源更新，而不是通过挖掘提交历史。

---

## 1. 板卡重命名：HMU05 → HMUF02-V5

代号现在与丝印（**HMUF02-V5**）一致。

| 项目 | 变更 |
|---|---|
| DTS | `msm8916-generic-hmuf02v5.dts`，兼容字符串 `hmuf02v5,250605v0s` |
| 设备 | `DEVICE_generic-hmuf02v5`，`DEVICE_MODEL "HMUF02-V5"` |
| diffconfig | `diffconfigs/hmu05` → `diffconfigs/hmuf02v5`（并且现在选择 `DEVICE_generic-hmuf02v5` —— 旧文件仍选择 hmu05 设备，会构建出错误的镜像） |
| 补丁 | `805`、`847`、`849` 已重命名；`801`/`833` 的兼容字符串已更新 |
| 运行时 glob | `himi-ok`、`modem-led-monitor`、`qcom-carrier-autocfg`、`qcom-time-daemon` 同时匹配 **`hmuf02v5`** 和 `hmu05` |

**为兼容性刻意保留：**
- `SUPPORTED_DEVICES` 仍包含 `hmu05,250605v0s`，因此接受从旧镜像执行 sysupgrade。
- 运行时 `*hmu05*` glob 仍保留，因此刷了旧镜像的设备在保留配置升级后仍能工作。
- 历史文档和描述性驱动注释仍写 HMU05。

**未改动：** `uf02,250605v0s` 是一个*不同*的板卡，仓库中已存在。它不是本板卡的别名。

---

## 2. 发布标识

在此分支之前，每个镜像都报告标准的 OpenWrt 版本，因为 `CONFIG_VERSION_*` 符号被 `make defconfig` 丢弃（它们需要 `CONFIG_VERSIONOPT=y`）。

- 新的唯一事实来源：`version` 文件（`25.12.5-r6`）。
- `sync-version.sh` 将其传播到每个 `diffconfigs/*`：
  `VERSION_DIST/NUMBER/CODE/REPO/HOME_URL/BUG_URL`，并设置 `CONFIG_VERSIONOPT=y`。
- `CONFIG_VERSION_CODE` 为空，因此版本号**只渲染一次**（`25.12.5-r6`，而不是 `25.12.5-r6 r6`）。

实时检查：

```sh
ubus call system board | jsonfilter -e @.release.version   # 25.12.5-r6
grep VERSION_ID /etc/os-release                            # 25.12.5-r6
```

固件文件名现在带项目前缀，例如
`msm8916-openwrt-msm89xx-msm8916-generic-hmuf02v5-squashfs-sysupgrade.bin`。
所有 CI glob 已从 `openwrt-msm89xx-*` 更新为 `*-msm89xx-*`。

---

## 3. 维护者策略

新文件：`CODEOWNERS`、`MAINTAINERS.md`。

- UZ801（`803`、`851`、`diffconfigs/uz801`）和 UFI003（`852`、`diffconfigs/ufi003`）路由到各自的板卡维护者。
- `msm8916.mk` 及其他所有内容路由到负责人。
- `MAINTAINERS.md` 记录职责、命名约定、重命名历史，以及如何识别/升级已安装的发布版本。

---

## 4. 自动物理 SIM 热插拔（主要功能）

提交 `75386bf`（机制）、`52a0002`（延迟调优）。

### 4.1 为何之前是坏的

- **AP 侧没有卡检测线。** GPIO114 `sim_hotplug` 是**输出**（AP 驱动其为低 = "卡存在"，并翻转它使基带重新读取卡）。GPIO119 `esim1_en` 是 SIM 电源轨使能。
- **ModemManager 无法检测交换。** 其 `qcom-soc` 插件在调制解调器使能时读取一次 SIM 然后缓存。拔出后，`mmcli` 仍报告旧的 IMSI/ICCID，`/SIM/9` 永不消失；只有 `modem.generic.state` 降级为 `searching`。
- **固件禁用了 `feature_support_hotswap`。** 它能注意到**移除**（卡停止应答 → UIM 在 **stderr** 上返回 `error: possibly-removed (6)`），但**永远不会注意到插入**。实测：卡物理插入后，UIM 持续应答 `possibly-removed` 数分钟；**一次 `sim_hotplug` 脉冲**使其在 <5 秒内报告 `present`，调制解调器约 10 秒后注册。

这种不对称就是整个设计：AP 必须在**认为卡不存在时**进行脉冲。"等待 UIM present 再脉冲"是不可能的。

### 4.2 服务

`/usr/sbin/sim-hotplug` + `/etc/init.d/sim-hotplug`（`START=98`），随 `/etc/rc.d/S98sim-hotplug` 一起发布，因此在 sysupgrade 后仍保留。配置：`/etc/config/sim-hotplug`。

| 状态 | 行为 |
|---|---|
| 卡存在 + 调制解调器已注册 | 每个 `idle_interval`（60 秒）一次 UIM 检查 |
| 卡存在 + 调制解调器 searching | 每个 `active_interval`（5 秒）一次 UIM 检查 |
| 认为卡不存在 | 脉冲 → 等待 4 秒 → 检查，每个 `absent_interval`（6 秒）一次 |

在 `absent → present` 时：

1. 等待注册（最多 60 秒），
2. `mmcli -d` + `-e` 使 ModemManager 重新读取 SIM（这就是让**不同**卡的 IMSI/APN 对 `qcom-carrier-autocfg` 可见的原因），
3. `ifup modem`（在共享承载锁下）。

### 4.3 延迟（硬件实测）

```
16:08:10  SIM removed (UIM absent)
16:08:17  SIM detected after re-announce      <- 7 s
16:08:22  modem registered
16:08:25  modem re-registered after SIM re-read
16:08:25  bringing the modem bearer up
          -> new IP, ping 0% loss
```

约 4 秒的交换端到端约 15 秒（调优前约 35 秒）。移除检测 5–7 秒；插入检测 ≤10 秒（6 秒周期 + 4 秒稳定等待）。

### 4.4 刻意的约束

- **仅 `searching` 永不意味着"交换"。** 它只用于选择轮询节奏。因此列车/汽车/重选不会触发任何操作。
- **绝不对已存在的卡脉冲** —— 这会使基带无法稳定（观察到：每 5 秒脉冲时调制解调器卡在 `searching`）。
- **QMI 卫生：** 始终 `qmicli --device-open-proxy`（通过 qmi-proxy 与 MM 共享端口），一次一个进程（busybox `flock`，无 `-w` 选项），始终在 `timeout` 下。并发/长时间运行的客户端会耗尽调制解调器的 client-ID 池，并使 MM 以 `ClientIdsExhausted` 失败。
- **此服务不使用 `mmcli -r`，也不做 SSR。**

### 4.5 设备树

补丁 `805`：GPIO114 现在是 `gpio-leds` 节点（`/sim-presence/sim_hotplug`），而不是 `gpio-hog`，像原版 Android 一样暴露 `/sys/class/leds/sim_hotplug/brightness`。

> **板卡范围。** 此节点目前**仅**在 HMUF02-V5 的 DTS 中定义。其他板卡（`uz801`、`ufi001b`、`ufi003`、`uf02`、`mf800b`）可以定义 `sim_hotplug` 节点，但需要测试；它们的硬件**可能**有此线路 —— **未测试**。此服务随共享的 `base-files` 发布，在没有节点的地方无法脉冲。设备所有者可通过 [`Docs/SIM_HOT_SWAP.md`](../SIM_HOT_SWAP.md#testing-on-another-board) 中的测试流程验证。

### 4.6 已知限制

比调制解调器自身的移除去抖更短的交换可能**不可见**：调制解调器保留其缓存的卡并保持 `connected`，因此 UIM 持续应答 `present`，AP 无法检测到。同一张卡放回时无害。如果*不同*的卡以这种方式插入，陈旧上下文会持续到数据失败（承载看门狗随后做 SSR，重新初始化 UIM）或直到 `/etc/init.d/sim-hotplug rescan`。

### 4.7 手动使用

```sh
sim-hotplug --help
/etc/init.d/sim-hotplug status
/etc/init.d/sim-hotplug rescan      # force one re-announce now
logread -e sim-hotplug
```

---

## 5. 为每个自定义程序提供 `--help`

提交 `a4da026`。在此之前，12 个命令不打印任何内容，6 个仅在错误调用时打印一行简短的用法。

| 程序 | 之前 | 现在 |
|---|---|---|
| `apk-key-refresh` | 无 | 完整帮助 |
| `himi-ok-guard` | 无 | 完整帮助 + uci 键 |
| `modem-bearer-watchdog` | 无 | 完整帮助 + 所有 uci 键 + 日志标签 |
| `modem-led-monitor` | 无 | 完整帮助 |
| `wifi-led-monitor` | 无 | 完整帮助 |
| `qcom-carrier-autocfg` | 无 | 完整帮助 + 文件/日志 |
| `msm-firmware-dumper` | 无 | 完整帮助 + 环境变量 |
| `diag-bind` | 无 | 完整帮助 + 输出格式 |
| `diag-bind-watch` | 无 | 完整帮助 + 状态文件 |
| `diag_nv` | 预编译二进制，仅用法 | 包装器 + 完整帮助 |
| `bt-spp` | 无 | 完整帮助 |
| `reboot-mode-raw` | 无 | 完整帮助 |
| `sim-hotplug` | 仅用法 | 完整帮助 |
| `usb-gadget` | 仅用法 | 完整帮助 |
| `bt-ssp-guard` | 仅用法 | 完整帮助 |
| `diag_efs` | 仅用法 | 完整帮助 |
| `diag_logtool` | 仅用法 | 完整帮助 |
| `qcom-time-daemon` | 错误选项时用法 | `-h` + 完整帮助 |
| `ats-probe` | `-h` | 不变（+ 列出 `-h`） |
| `reboot-mode` | `-h` | 不变 |

每个帮助块列出命令/选项、它遵守的 `uci` 键或环境变量，以及要监视的 `logread -e <tag>`。注意 `modem-bearer-watchdog` 以 **`modem-stall-watchdog`** 记录日志。

**`diag_nv` 布局变更：** 静态二进制移至 `/usr/libexec/diag_nv.bin`；`/usr/sbin/diag_nv` 现在是一个薄包装器，响应 `-h/--help` 并 `exec` 它。`himi-ok-guard` 调用相同路径，不受影响。

主机侧脚本：`flash.sh` 已有帮助；`generate_firmware.sh` 和 `generate_squashfs_gpt.sh` 是 CI 内部脚本，未更改。

---

## 6. CI / 打包

- 缓存键和作业标签：`diffconfigs/hmu05` → `diffconfigs/hmuf02v5`。
- 产物 glob：`openwrt-msm89xx-*` → `*-msm89xx-*`（DIST 前缀现在在文件名开头）。
- `msm8916.mk`、`generate_squashfs_gpt.sh`、`tests/himi-ok-guard/run.sh` 已为重命名更新。

---

## 7. 验证记录（2026-10-19）

在 HMUF02-V5 上用 `sysupgrade -n` 刷写：

| 检查项 | 结果 |
|---|---|
| 固件 | `25.12.5-r5` / `r33051-f5dae5ece4` |
| `/usr/sbin/sim-hotplug` md5 | `e9974c754968991e581f08597a3de19c`（与仓库一致） |
| 服务 | 运行中，`SIM present at startup`，无杂散脉冲 |
| 调制解调器 | `connected`，IPv4 + IPv6 |
| 数据 | ping 3/3，0% 丢包，DNS OK |
| SIM 交换（同卡） | 约 15 秒内检测并恢复，新 IP，数据恢复 |
| `--help` | 已为所有 shell 工具验证；二进制携带新字符串 |
| 构建 | `./build.sh build hmuf02v5` → 退出码 0 |

`sysupgrade -n` 会擦除 overlay。`/lib/firmware` 中的调制解调器固件位于 overlay 上，**不**在镜像中；设备的首次启动自动化会重新填充它，但手动刷写必须考虑这一点。

---

## 8. 升级说明

- 保留配置的 `sysupgrade` 会保留 overlay，包括任何陈旧的 `/overlay/upper/lib/modules/*.ko`；应从 `/rom` 刷新而不是删除（whiteout 会隐藏新镜像文件）。
- 从早于此分支的镜像执行 `sysupgrade` 仍可工作（`hmu05,250605v0s` 仍在 `SUPPORTED_DEVICES` 中）。
- `/etc/config/sim-hotplug` 是一个新的 conffile；全新刷写会得到默认值（idle 60 / active 5 / absent 6 / pulse 300）。

---

## 9. 未决事项

1. **不同 SIM 的 APN 切换** 已实现（MM `-d`/`-e` 重读 + `qcom-carrier-autocfg`）但尚未用第二张卡实测。
2. **亚去抖交换** 本质上不可见（见 §4.6）。曾考虑可选周期性重新公告但被否决（它会使连接闪断）。
3. 其余板卡（`mf800b`、`uf02`、`ufi001b`、`ufi003`、`uz801`）尚未用此分支重新构建/刷写。

---

## 附录 —— 文件索引

```
version                                             new
sync-version.sh                                     version propagation
CODEOWNERS, MAINTAINERS.md                          new
diffconfigs/hmu05 -> diffconfigs/hmuf02v5           rename + device fix
diffconfigs/{mf800b,uf02,ufi001b,ufi003,uz801}      version block
msm89xx/Makefile                                    rename
msm89xx/image/msm8916.mk                            rename
msm89xx/patches/805,847,849                         renamed (DTS)
msm89xx/patches/801,833                             compatible strings
msm89xx/base-files/usr/sbin/sim-hotplug             new
msm89xx/base-files/etc/init.d/sim-hotplug           new
msm89xx/base-files/etc/rc.d/S98sim-hotplug          new (symlink)
msm89xx/base-files/etc/config/sim-hotplug           new
msm89xx/base-files/usr/sbin/diag_nv                 wrapper (was ELF)
msm89xx/base-files/usr/libexec/diag_nv.bin          moved ELF
msm89xx/base-files/usr/sbin/{apk-key-refresh,himi-ok-guard,
  modem-bearer-watchdog,modem-led-monitor,wifi-led-monitor}   --help
msm89xx/base-files/lib/himi-ok.sh                   board list
msm89xx/base-files/etc/config/modem-watchdog        comments
msm89xx/base-files/etc/uci-defaults/97-himi-ok      comments
msm89xx/base-files/etc/uci-defaults/99-msm89xx-firstboot  hostname
packages/{diag-bind,bt-ssp-guard,msm-firmware-dumper,
  qcom-carrier-autocfg,uci-usb-gadget}              --help
packages/{diag-efs,diag-logtool,bt-spp,
  qcom-time-daemon,reboot-edl,ats-probe}/src        --help
scripts/openwrt-prepare.sh                          LuCI branch metadata
.github/workflows/*                                 rename + globs
tests/himi-ok-guard/run.sh                          label
readme.md, README.md                                rename
```
