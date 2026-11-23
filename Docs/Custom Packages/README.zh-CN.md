# 自定义软件包

除上游 OpenWrt 树之外，本项目在 [`packages/`](../../packages/) 下附带 **26 个软件包** — 这些工具、守护进程和 LuCI 应用让 MSM8916 USB 加密狗可作为带 Qualcomm 基带的无头路由器使用。

它们分为两组：

- **仓库内编写（17）** — 为本项目编写，针对 MSM8916 调制解调器/DIAG/蓝牙/电池硬件。
- **内置第三方（9）** — 在树内携带的上游或第三方软件包（常带本地补丁），使固件构建自包含。

> 内核模块**不**在 `packages/` 中；它们位于
> [`msm89xx/modules.mk`](../../msm89xx/modules.mk)。参见
> [**Kernel-Modules.md**](Kernel-Modules.md)。

---

## 仓库内编写

| 软件包 | 功能 |
| :--- | :--- |
| [`ats-probe`](../../packages/ats-probe/) | 通过 QMI TIME（服务 22）读取调制解调器自身的 **ATS_RTC 运行计数**，并为每次读取打上 AP 的 `CLOCK_BOOTTIME` 时间戳，使调制解调器侧的时间戳可与 AP 侧关联。仅发送只读的 `GENOFF_GET 0x0021` — 不能写入调制解调器。用于判断约 902 秒的致命故障是计数器回绕、常开时钟，还是调制解调器本地条件。 |
| [`bt-spp`](../../packages/bt-spp/) | 蓝牙**串口配置文件（SPP）服务器和客户端**。`bt-spp serve` 将传入的 SPP 连接桥接到登录 shell（pty）或 TCP 主机:端口；`bt-spp connect` 将远程 SPP 设备桥接到本地 shell/TCP 监听器。目标在 `/etc/config/bt-spp` 中选择。 |
| [`bt-ssp-guard`](../../packages/bt-ssp-guard/) | 确保 WCNSS 蓝牙控制器**通告安全简单配对（SSP）**。SSP LMP 特性位（NVM 标签 6、字节 6、位 3）仅存在于 RAM 中，因此每次启动重新检查并在缺失时重写 — 否则 BR/EDR 配对会回退到传统 PIN 配对并失败。 |
| [`diag-bind`](../../packages/diag-bind/) | 通过将 `remoteproc0:smd-edge.DIAG` / `DIAG_CNTL` 绑定到 `rpmsg_chrdev` 驱动（`/dev/rpmsg0` 数据，`/dev/rpmsg1` 控制），将调制解调器的 SMD DIAG 通道暴露为字符设备。附带一次性辅助脚本**以及**一个 procd 服务，在调制解调器子系统每次重启（SSR）时重新绑定。 |
| [`diag-efs`](../../packages/diag-efs/) | 通过 `/dev/rpmsg0` 上的 DIAG EFS2 子系统（0x13）读写调制解调器 **EFS**。调制解调器实时解密其自身 EFS，在无需每芯片存储密钥的情况下暴露实时的解密 NV 树。`list/read/stat/get/dump`（只读）加上一个受保护的 `put`，未经 `--force` 拒绝校准路径（`rfnv/`、`mcs/`）。 |
| [`diag-logtool`](../../packages/diag-logtool/) | 用于 SMD DIAG 通道（`/dev/rpmsg0`、`/dev/rpmsg1`）的 Qualcomm **DIAG 客户端**。往返/原始探测、解码/捕获 DIAG 流，并通过 `DIAG_LOG_CONFIG_F`（0x73）控制日志掩码。 |
| [`msm-firmware-dumper`](../../packages/msm-firmware-dumper/) | 首次启动时将 Qualcomm 固件分区转储到 `/lib/firmware`。 |
| [`qcom-carrier-autocfg`](../../packages/qcom-carrier-autocfg/) | 面向 MSM8916 Snapdragon 调制解调器的自动 **SIM 检测、运营商配置匹配、APN 配置**以及动态连接管理器。 |
| [`qcom-time-daemon`](../../packages/qcom-time-daemon/) | **QMI 时间同步**守护进程：将主机时间与调制解调器的 ATS/TOD 同步，并提供周期性保活以保持调制解调器 DRX 睡眠状态机稳定。 |
| [`reboot-edl`](../../packages/reboot-edl/) | 安全地静止后台服务、将文件系统重挂载为只读，并将设备重启到 **EDL（9008）、DLOAD（9006）、引导加载器或恢复模式**。 |
| [`luci-app-battery`](../../packages/luci-app-battery/) | 两块电池板（mifib-v12、mf800b）的电池状态、**充电上限**和电池 LED：一个 LuCI 页面，显示容量/电压/温度/健康状态和电池会话、85 %/80 % 充电上限监视器（PM8916 LBC 上的 `charge_enabled`）、绿/红 LED 监视器，以及 `battery-ctl`。仅在存在电池组的地方安装。 |
| [`msm89xx-scripts`](../../packages/msm89xx-scripts/) | **板级支持的用户态部分**打包：调制解调器和 Wi-Fi LED 监视器及其 procd 服务、启动闪烁（`led-boot`），以及 `luci-app-wifi-sta` 驱动的 Wi-Fi 站（中继）辅助脚本。这些以前位于目标的 `base-files` 中，意味着一个 LED 或站修复需要完整刷写固件；作为软件包可以通过签名源推送（参见 [无需重新刷写即可发布软件包](#shipping-a-package-without-a-reflash)）。启动关键部分特意保留在 `base-files`：`/etc/diag.sh`、`/lib/preinit` 钩子和 `/lib/batteryless.sh`。 |
| [`msm89xx-firmware-upgrade`](../../packages/msm89xx-firmware-upgrade/) | **设备内固件升级引擎**。`firmware-upgrade check` 读取 `firmware.json` — 发布流水线在镜像旁发布的清单 — 并以 JSON 打印此板的可用性；`download` 获取镜像并验证其 SHA-256；`apply [--no-keep]` 将其交给 `sysupgrade`（保留配置，或用 `-n` 清除）；`upgrade` 执行以上全部三步。`apply` 用 `setsid` 分离，因为 rpcd 的 30 秒超时短于 35 MB 的 LTE 下载。 |
| [`luci-app-firmware-upgrade`](../../packages/luci-app-firmware-upgrade/) | 上述内容的 LuCI 页面 — *系统 → 固件升级*。显示运行版本、此板已发布版本、镜像大小和发布说明，然后下载、验证并刷写，带一个 **保留设置** 复选框（默认开启；取消勾选进行干净安装）。列入 `DEFAULT_PACKAGES`，因此从 r3 起每块板卡都有它。 |
| [`luci-app-wifi-sta`](../../packages/luci-app-wifi-sta/) | **站模式**（并发 AP+STA）的 LuCI 支持：在不改动无线配置的情况下配置 wcn36xx 无线电的晚启动站接口。 |
| [`luci-app-modem-watchdog`](../../packages/luci-app-modem-watchdog/) | **调制解调器承载看门狗**的 LuCI Web UI — 状态横幅、启用/禁用、自动 `auto_mobile` 切换配置（默认开启）加上手动 `mobile_optimized` 强制模式、停滞超时/检查间隔、保活和恢复升级设置。 |
| [`luci-app-update-notify`](../../packages/luci-app-update-notify/) | **可用软件包更新**的仪表板通知。一个小守护进程每 6 小时运行 `apk update` 并写入 `/tmp/update-notify.json`；LuCI 仪表板 include 渲染“有 N 个软件包更新可用”并链接到包管理器，设备为最新时什么都不显示。统计 `apk upgrade --simulate` 的 `Upgrading` 行，因此版本固定的 `base-files`/`kernel`/`libc` — 以及 `/etc/apk/world` 中固定的任何其他内容 — 永远不会被通告。（`apk list --upgradable --world` 看起来正确但实际不对：`--world` 只是把 world 软件包加入选择，因此固定软件包仍会计数。） |

## 内置第三方

| 软件包 | 功能 |
| :--- | :--- |
| [`cups`](../../packages/cups/) | **CUPS** 打印服务器（`cupsd`），带 IPP、AirPrint、原始套接字和端口 631 上的 Web 管理。 |
| [`qrtr`](../../packages/qrtr/) | Qualcomm **IPC Router** 用户态 — `libqrtr` 加上 `qrtr-utils`（工具和 nameservice 守护进程）。 |
| [`rmtfs`](../../packages/rmtfs/) | Qualcomm **远程文件系统服务**守护进程 — 从 AP 端服务调制解调器的远程文件系统请求。 |
| [`luci-app-cpu-perf`](../../packages/luci-app-cpu-perf/) | CPU 性能信息与管理的 LuCI 页面。 |
| [`luci-app-sms-manager`](../../packages/luci-app-sms-manager/) | 通过 ModemManager 进行 **SMS / USSD / AT 命令**的 LuCI JS 接口。 |
| [`luci-app-tailscale`](../../packages/luci-app-tailscale/) | **Tailscale** 的 LuCI 接口。 |
| [`luci-app-usb-gadget`](../../packages/luci-app-usb-gadget/) | 管理 **USB gadget** 功能（RNDIS、ECM、NCM、ACM、大容量存储）的 Web 接口。 |
| [`luci-theme-feelgood`](../../packages/luci-theme-feelgood/) | **Feelgood** LuCI 主题，在树内携带并本地打补丁（登录页面级联以未压缩形式发布 — `csstidy` 会错误排序规则并遮挡登录表单）。 |
| [`uci-usb-gadget`](../../packages/uci-usb-gadget/) | 基于内核 configfs 接口的 **UCI USB gadget 管理器**。将设备配置为 USB 外设并将 USB 以太网接口集成到 LAN 桥；自动检测 UDC 控制器。 |

---

## Base-files 服务

一些设备端程序随 `msm89xx/base-files/` 发布，而不是作为软件包（它们是目标默认配置的一部分）：

| 程序 | 功能 |
| :--- | :--- |
| `sim-hotplug` | 检测物理 SIM 更换并重新向基带通告该卡（`/etc/init.d/sim-hotplug`，`rescan` 命令）。 |
| `himi-ok-guard` | 每次调制解调器启动后重写调制解调器 NV `HiMI_OK` 标记。 |
| `modem-bearer-watchdog` | 监视调制解调器/承载，执行预防性 SSR 和僵尸恢复（日志名为 `modem-stall-watchdog`）。 |
| `apk-key-refresh` | 启动时重新同步固定的 APK 源签名密钥。 |
| `apk-overlay-heal` | 修复保留配置的刷写后的 overlay：清除隐藏镜像附带文件的 whiteout，丢弃镜像现在以不同版本附带的包文件的 overlay 副本，并将过期的 `/etc/apk/world` 与包数据库与镜像的合并。从 preinit 运行；参见 [无需重新刷写即可发布软件包](#shipping-a-package-without-a-reflash)。 |
| `battery-led-monitor` | 驱动电池组（仅充电状态和故障）。随 `luci-app-battery` 附带。 |

LED 监视器、启动闪烁和 Wi-Fi 站辅助脚本以前也列在这里；现在它们作为 [`msm89xx-scripts`](../../packages/msm89xx-scripts/) 软件包发布，以便可通过源更新。留在 `base-files` 中的正是必须在**软件包可安装之前**存在的内容：`/etc/diag.sh`、`/lib/preinit/*` 和 `/lib/batteryless.sh`。

**每个自定义程序 — 软件包或 base-files — 都响应 `-h`/`--help`**，输出其选项、遵守的 `uci` 键，以及要查看的 `logread` 标签：

```sh
sim-hotplug --help
modem-bearer-watchdog --help
diag-bind --help
diag_nv --help
```

---

## 各内容去向

| 层 | 文件 | 范围 |
| :--- | :--- | :--- |
| `DEFAULT_PACKAGES` | [`msm89xx/Makefile`](../../msm89xx/Makefile) | 每块板卡 — 所有共享软件包 |
| `DEVICE_PACKAGES` | [`msm8916.mk`](../../msm89xx/image/msm8916.mk) | 每设备 |
| `diffconfigs/<board>` | [`diffconfigs/`](../../diffconfigs/) | 每板：`=m` 驱动源、选项符号、故障安全调优、设备行、仅板卡软件包 |

所有板卡间完全相同的内容以前被手工复制到每个 `diffconfigs/<board>`；现在位于 `DEFAULT_PACKAGES` 中，因此新板卡自动获得。`=m` 条目有意保留在 diffconfigs 中 — 它们是外部模块，`DEFAULT_PACKAGES` 会强制它们内建。`./build.sh guard` 检查这两个不变量。

软件包由 [`build.sh`](../../build.sh) 构建，并也发布到签名 APK 源（参见主 [README → 官方软件包与内核驱动仓库](../../README.md#-official-package--kernel-driver-repository)），因此可在设备上用 `apk add` 安装。

## 无需重新刷写即可发布软件包

对于 `wifi-led-monitor` 中的一行改动，完整固件构建是错误工具：镜像约 34 MB，每块板卡都花费一次刷写周期。[`publish-package.yml`](../../.github/workflows/publish-package.yml) 使用与已发布固件相同的工具链和内核重建**一个**软件包，将新的 `.apk` 拼接进**已发布**的源并重新签名索引。源 URL 不变，因此设备用以下方式获取：

```sh
apk update
apk upgrade msm89xx-scripts   # 若软件包尚未安装则用 'apk add'
```

这仅适用于属于**软件包**的文件。内核、驱动、preinit 钩子或 `base-files` 都烘焙进镜像，只能随固件发布更改 — 设备随后通过 *系统 → 固件升级* 自行安装（参见 [版本与热修复](https://github.com/akbar-npj/msm8916-openwrt/wiki/How-Releases-and-Hotfixes-Work)）。

### 调度

```sh
# 提升 PKG_RELEASE，构建，发布（常见情况）
gh workflow run publish-package.yml --ref main -f package=msm89xx-scripts

# 重建同一版本（例如发布失败后）
gh workflow run publish-package.yml --ref main \
  -f package=msm89xx-scripts -f bump=false

# 不同的源基（默认为 ./version，去掉 -rN 后缀）
gh workflow run publish-package.yml --ref main \
  -f package=luci-app-wifi-sta -f base=25.12.6
```

| 输入 | 默认 | 含义 |
| :--- | :--- | :--- |
| `package` | — | `packages/` 下的目录名 |
| `base` | `./version` 去掉 `-rN` | 发布到哪个 `releases/<base>/` 源 |
| `board` | `hmuf02v5` | 构建配置；仅对 `kmod-*`（vermagic）有意义 |
| `bump` | `true` | 先递增 `PKG_RELEASE` |

### 该任务做什么

1. 准备 OpenWrt 树并注入持久的 `APK_SIGNING_KEY`。
2. **从 `gh-pages` 分支下载已发布的源**到 `openwrt/bin/` — 参见下面的陷阱。
3. 递增 `PKG_RELEASE`（除非 `bump=false`）并构建这一个软件包。
4. 重新运行 `make package/index`，它用持久密钥重新签名每个源索引。
5. 若软件包总数下降则拒绝发布。
6. 将源复制回 `gh-pages` 并提交。

### 为何先下载源

`make package/index` 索引 `openwrt/bin/packages` 中恰好存在的任何 `.apk` 文件。单软件包构建恰好填满一个目录，因此重新索引全新树会发布一个只列出**一个**软件包的索引，而其他每个软件包都会从 `apk search` / `apk add` 中悄悄消失。因此该任务先恢复已发布的树，并断言数量永不变小。

### 会咬人的事项

- **`PKG_RELEASE` 必须改变。** apk 比较版本；重建 `1.0-r1` 并重新上传对设备不可见。`bump=true` 处理了这点，但该递增只存在于 CI 运行内 — 之后提交 `packages/<name>/Makefile`，否则下次构建又从旧数字开始（任务摘要会提醒你）。
- **kmod 受 vermagic 锁定。** `kmod-*` 热修复只能安装在运行其构建所针对的确切内核的设备上。其他一切都是架构无关且安全的。
- **软件包必须已在源中。** 这会发布到现有 `releases/<base>/`；从未成为发布一部分的软件包没有可扩展的源条目 — 先出一个发布。
- **在软件包之间移动文件会留下 whiteout。** 当某路径停止由 `base-files` 拥有并开始由新软件包拥有时，保留的 overlay 仍可携带它的 whiteout（一个 `0,0` 字符设备）。新软件包安装，`apk info` 列出它，`/rom` 中存在符号链接 — 但合并视图仍显示无内容，因此服务静默地从不启动。
- **包数据库是上一镜像的。** `/lib/apk/db/installed` 在 apk 首次写入时被复制到 overlay，因此镜像更改后设备保留旧的“谁拥有什么”视图 — `apk info -W` 指向错误的软件包，`apk add` 可能因文件冲突失败。
- **`/etc/apk/world` 也一样。** 它列出 apk 视为显式安装的软件包。来自上一镜像的 world 不列出新镜像添加的软件包，因此 apk 将该软件包视为不需要，并在**下一次事务中从数据库删除它** — 文件保留在磁盘上，记录却没有。这是在刷写*之后*启动时咬人的一个：软件包可用，然后悄悄消失。
- **包文件的 overlay 副本遮蔽镜像。** overlay 总是胜出。软件包拥有的文件在首次写入时被复制上来，该副本随后比每次刷写都长寿 — 因此镜像更改后合并视图提供*旧*文件，而 `apk info` 报告新版本。任何地方都无错误记录：守护进程只是运行上一发布。LuCI 主题是最响亮的案例，因为样式表和链接它的模板都过期，页面看起来未改动，而 `apk` 声称更新已落地。

上述四项均由 [`apk-overlay-heal`](../../msm89xx/base-files/usr/sbin/apk-overlay-heal) **自动**修复，从 `/lib/preinit/85_apk_overlay_heal` 运行 — 在 overlay 挂载后、任何 init 脚本之前 — 并且**仅在镜像更改后的首次启动**。它

1. 删除运行镜像附带的每条路径的 whiteout（`/etc/uci-defaults` 下的 whiteout 保留不动 — 那是 OpenWrt 记录一次性脚本已运行的方式），
2. 丢弃与镜像不同的包文件的 overlay 副本，使合并视图提供镜像实际附带的文件。这是上游的 `sysupgrade -o` 规则（*“保留 / 中所有更改的文件，但软件包的除外，包括更改的 conf”*）在启动时而不是升级时应用：conffiles — `*.conffiles_static`、`/etc/sysupgrade.conf`、`/lib/upgrade/keep.d` — 永不还原，镜像不附带的任何内容也不还原，这正是从源安装的软件包保留其文件的方式。与镜像匹配的文件保持原样，因此从未手工编辑的设备上该遍不做任何事。而*升级*自源的软件包比镜像新 — 还原它将是静默降级 — 因此其文件也保留，步骤 4 保留匹配的数据库记录而不是镜像的。这需要版本比较（`apk version -t`，回退到 `sort -V`），因为两种情况下 overlay 都有文件，只有记录的版本能区分它们，
3. 以同样方式合并 `/etc/apk/world`（镜像条目加上 overlay 上添加的任何内容），以及
4. 将 overlay 的数据库与镜像的合并：对于镜像附带的每个软件包，镜像胜出 — 除非 overlay 记录*更高*版本，此时保留该记录以匹配步骤 2 保留的文件 — 且从源安装的软件包被保留。若结果无法解析则拒绝合并并保留 overlay 副本。

镜像更改由 `/etc/apk/.image_id`（镜像数据库的 md5）跟踪；普通启动时该钩子立即返回。

门控很重要：whiteout *也*是合法的 `apk del` 删除镜像附带文件的方式，因此每次启动都修复会复活用户卸载的软件包。刷写后立即没有这种歧义 — 新镜像的软件包集是权威的。

> **`apk add` 后无需重启。** 软件包更新正常通过 apk 并立即生效，与上游 OpenWrt 完全相同。修复之所以存在，只是因为*本项目*在固件刷写后保留 overlay；它是刷写已经花费的启动的一部分，而不是额外的一次。

用 `logread -e apk-overlay-heal`、`apk info -W <file>` 和 `ps w | grep led` 检查（busybox `pgrep` 将名称截断到 15 个字符，因此 `pgrep modem-led-monitor` 静默地不匹配任何内容）。

### 添加新软件包

对树而言新的软件包在扫描注意到它之前对构建不可见，且失败并不说明：

    make[1]: *** No rule to make target 'package/msm8916/<name>/compile'.  Stop.
    WARNING: your configuration is out of sync. Please run make menuconfig...

`include/scan.mk` 通过对每个 `Makefile` 执行 `grep 'call (Build/DefaultTargets|BuildPackage|KernelPackage)'` 构建软件包列表 — 是文本搜索，不是解析。`luci.mk` 软件包唯一的构建调用位于 `luci.mk` *内部*，因此其 `Makefile` 必须携带使其匹配的尾随注释行：

    include $(TOPDIR)/feeds/luci/luci.mk

    # call BuildPackage - OpenWrt buildroot signature

没有它，该目录在静默中被跳过。纯文件软件包（无 `src/`）还需要空的 `Build/Compile` — 否则默认规则运行 `make -C $(PKG_BUILD_DIR)` 并失败于“未指定目标且未找到 makefile” — 且其想要的任何 `rc.d` 符号链接必须显式创建，因为构建时没有东西运行 `default_postinst`。

添加后，刷新扫描和配置（`./build.sh package <name>` 执行同步；容器命令是）：

    rm -f tmp/info/.files-packageinfo* tmp/info/.overrides-packageinfo* \
          tmp/.packageinfo tmp/.packagedeps
    make prepare-tmpinfo && make defconfig

`CONFIG_DEFAULT_<name>=y` 来自 `DEFAULT_PACKAGES`；`CONFIG_PACKAGE_<name>=y` 仅在元数据重新生成后才出现，因此运行 `defconfig` 第二次 — 第一遍是写入 `DEFAULT_` 符号的那个。

## 相关文档

- [**Kernel-Modules.md**](Kernel-Modules.md) — 仓库内 `kmod-*` 驱动。
- [**Docs/Patches/README.md**](../Patches/README.md) — 每个内核补丁，包括这些软件包依赖的驱动改动。
- [**Docs/Modem Stability/**](../Modem%20Stability/) — 上下文中调制解调器/DIAG 工具。
