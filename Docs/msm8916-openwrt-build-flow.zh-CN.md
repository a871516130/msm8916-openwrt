> 📄 本文件是 [msm8916-openwrt-build-flow.md](msm8916-openwrt-build-flow.md) 的英文原文中文译本，内容以英文版为准。

# MSM8916 OpenWrt 项目 — 构建流程与架构

## 1. 目的

本文档记录 `msm8916-openwrt-clean` 项目是如何组织的、项目脚本如何与 OpenWrt 交互，以及 Linux kernel/BSP 补丁从何处进入构建。

项目使用三个主要脚本：

- `build.sh` — 顶层构建管理器
- `scripts/openwrt-version.sh` — OpenWrt 版本管理器
- `scripts/openwrt-prepare.sh` — 准备/同步 OpenWrt 源码树

关键架构要点是：仓库中的 `msm89xx/` 目录是 OpenWrt `target/linux/msm89xx` target 的 **BSP 真相来源（source of truth）**。

---

## 2. 仓库布局

```text
msm8916-openwrt-clean/
├── build.sh
├── scripts/
│   ├── openwrt-version.sh
│   └── openwrt-prepare.sh
├── msm89xx/
│   ├── Makefile
│   ├── config-6.12
│   ├── image/
│   ├── modules.mk
│   ├── msm8916/
│   └── patches/
├── packages/
├── openwrt-overlay/
├── devenv/
│   ├── .env
│   └── docker-compose.yml
└── openwrt/
    └── ... OpenWrt source tree ...
```

### 真相来源 vs 生成树

被维护的 BSP 是：

```text
msm89xx/
```

生成的 OpenWrt target 是：

```text
openwrt/target/linux/msm89xx/
```

`openwrt-prepare.sh` 会把前者复制到后者。因此，持久性的修改应当放在项目仓库中，而不能只放在生成的 OpenWrt 树里。

---

## 3. `openwrt-version.sh`

### 目的

`openwrt-version.sh` 管理项目所选择的 OpenWrt 版本。

它**不**：

- 克隆 OpenWrt
- 准备 OpenWrt
- 调用 Docker
- 构建 OpenWrt

它读取并修改：

```text
devenv/.env
```

具体来说是：

```text
OPENWRT_VERSION=...
```

### 命令

```bash
./scripts/openwrt-version.sh --current
```

显示当前版本。

```bash
./scripts/openwrt-version.sh
```

显示当前版本和可用的发行版本。

```bash
./scripts/openwrt-version.sh main
```

选择开发分支 `main`。

```bash
./scripts/openwrt-version.sh v25.12.5
```

选择一个稳定发行版。

该脚本通过以下命令发现稳定 tag：

```bash
git ls-remote --tags https://git.openwrt.org/openwrt/openwrt.git
```

### 重要规则

`openwrt-version.sh` 只负责选择期望的版本。实际的检出/版本处理由 `build.sh` 编排。

---

## 4. `build.sh`

`build.sh` 是项目的顶层构建管理器。

它的职责是编排：

1. 环境校验
2. Docker 构建器设置
3. OpenWrt 检出/版本处理
4. OpenWrt 准备
5. 配置准备
6. OpenWrt 编译
7. 镜像生成

因此，正常的板级构建应当以如下方式启动：

```bash
./build.sh build <board>
```

例如：

```bash
./build.sh build ufi001b
```

---

## 5. 高层构建流程

```text
User
 │
 │ ./build.sh build ufi001b
 ▼
build.sh
 │
 ├── validate environment
 ├── ensure Docker builder
 ├── select/prepare OpenWrt version
 │
 ├── openwrt-prepare.sh
 │      │
 │      ├── install msm89xx BSP
 │      ├── install project packages
 │      ├── install package patches
 │      ├── apply repository overlay
 │      ├── apply OpenWrt source patches
 │      ├── update/install feeds
 │      └── compatibility fixes
 │
 ├── prepare OpenWrt configuration
 │
 └── OpenWrt build
        │
        ▼
   OpenWrt build system
        │
        ├── target/linux/msm89xx
        ├── Linux kernel
        ├── DTS/DTB
        ├── root filesystem
        └── image generation
                │
                ▼
          final firmware
```

---

## 6. `openwrt-prepare.sh`

该脚本是项目 BSP 仓库与 OpenWrt 源码树之间的桥梁。

其文档记载的职责是：

- 安装 `msm89xx` target
- 安装项目 packages
- 应用仓库 overlay
- 应用项目补丁
- 更新/安装 package feeds
- 应用兼容性修复
- 记录准备状态

它**不**：

- 克隆 OpenWrt
- 检出分支/tag
- 调用 Docker
- 读取 `devenv/.env`

---

## 7. BSP 安装

关键操作实际上就是：

```bash
TARGET_DIR="$REPO_DIR/msm89xx"

rm -rf "$OPENWRT_DIR/target/linux/msm89xx"

cp -a     "$TARGET_DIR"     "$OPENWRT_DIR/target/linux/"
```

因此：

```text
Project BSP
msm89xx/
    │
    │ copy
    ▼
OpenWrt target
openwrt/target/linux/msm89xx/
```

### 后果

每一次准备都可能替换掉生成的 target。

因此这里**不是**项目修改的持久位置：

```text
openwrt/target/linux/msm89xx/
```

持久性的修改必须做在：

```text
msm89xx/
```

---

## 8. 为什么 810/811 补丁此前会消失

在内核调试期间，补丁最初创建于：

```text
openwrt/target/linux/msm89xx/patches/
```

它们在手动修改过的内核树中有效，但在执行以下命令后消失：

```bash
./build.sh build ufi001b
```

因为准备过程会删除生成的 target 并重新复制 BSP。

正确的位置是：

```text
msm89xx/patches/
```

对于当前项目：

```text
msm89xx/patches/
├── 801-arm64-dts-qcom-add-devices-makefile.patch
├── 802-arm64-dts-qcom-msm8916-label-reserved-memory.patch
├── 803-arm64-dts-qcom-uz801-leds-and-button.patch
├── 804-arm64-dts-qcom-add-msm8916-generic-uf02.patch
├── 805-arm64-dts-qcom-add-msm8916-generic-hmu05.patch
├── 806-arm64-dts-qcom-add-msm8916-generic-ufi001b.patch
├── 808-bam-dmux-stats.patch
├── 813-msm8916-reboot-to-edl-support.patch
├── 815-qcom-sysmon-ignore-wcnss-modem-ssr.patch
└── 999-tsens-propagate-eprobe-defer.patch
```

准备之后，它们会自动出现在：

```text
openwrt/target/linux/msm89xx/patches/
```

目前已验证该方式可正常工作。

---

## 9. 当前 BSP 补丁组织

当前补丁集包含：

```text
801-arm64-dts-qcom-add-devices-makefile.patch
802-arm64-dts-qcom-msm8916-label-reserved-memory.patch
803-arm64-dts-qcom-uz801-leds-and-button.patch
804-arm64-dts-qcom-add-msm8916-generic-uf02.patch
805-arm64-dts-qcom-add-msm8916-generic-hmu05.patch
806-arm64-dts-qcom-add-msm8916-generic-ufi001b.patch
808-bam-dmux-stats.patch
813-msm8916-reboot-to-edl-support.patch
815-qcom-sysmon-ignore-wcnss-modem-ssr.patch
999-tsens-propagate-eprobe-defer.patch
```

### OpenWrt 树补丁：openwrt-patches/

`809-mac80211-enable-wcn36xx.patch` 是一个 **OpenWrt 源码树补丁**（修改 `package/kernel/mac80211/ath.mk`），而不是 Linux kernel 补丁。它存放于：

```text
openwrt-patches/
└── 809-mac80211-enable-wcn36xx.patch
```

并由 `scripts/openwrt-prepare.sh` 和 `build.sh` 直接应用到 OpenWrt 源码上。

因此：

```text
Linux kernel patches
    └── target/linux/msm89xx/patches/

OpenWrt source-tree patches
    └── openwrt-patches/
```

---

## 10. 项目 packages

项目维护的 packages 位于：

```text
packages/
```

它们被安装到：

```text
openwrt/package/msm8916/
```

生成的 package 目录在准备过程中会被重新创建。

因此 `packages/` 是持久的真相来源。

---

## 11. Package 补丁

特定于 package 的补丁位于：

```text
packages/<package>/patches/
```

它们被复制到：

```text
openwrt/package/system/<package>/patches/
```

因此持久性的修改应当放在 `packages/` 下，而不能只放在生成的 OpenWrt 树里。

---

## 12. 仓库 Overlay

项目还有一个：

```text
openwrt-overlay/
```

当它存在时，其内容会被复制到：

```text
openwrt/
```

这用于需要直接覆盖进 OpenWrt 源码树的文件。

---

## 13. OpenWrt Feeds

正常准备会检查这些 feeds：

```text
packages
luci
routing
telephony
video
smsmanager
```

如果它们已经存在，准备过程会报告 feeds 已安装。

可以通过以下命令请求完整刷新：

```bash
./scripts/openwrt-prepare.sh --refresh-feeds
```

---

## 14. 准备状态

准备脚本会写入：

```text
openwrt/.builder-state
```

其中包括如下信息：

```text
OPENWRT_VERSION=...
PREPARED_AT=...
```

这记录了该树是为哪个 OpenWrt 版本准备的。

---

## 15. OpenWrt 接管的时刻

准备之后，生成的树包含：

```text
openwrt/
├── target/
│   └── linux/
│       └── msm89xx/
│           ├── Makefile
│           ├── config-6.12
│           ├── image/
│           ├── modules.mk
│           ├── msm8916/
│           └── patches/
├── package/
├── feeds/
└── ...
```

此时，标准的 OpenWrt 构建机制接管工作。

项目专属的 BSP 已被转换为一个 OpenWrt target。

---

## 16. Linux Kernel 构建流程

概念上：

```text
msm89xx/
    │
    ▼
openwrt-prepare.sh
    │
    ▼
openwrt/target/linux/msm89xx/
    │
    ▼
OpenWrt kernel build machinery
    │
    ▼
build_dir/target-aarch64_generic_musl/
linux-msm89xx_msm8916/
    │
    ├── Linux source
    ├── kernel configuration
    ├── kernel patches
    ├── DTS sources
    └── build artifacts
```

当前的内核源码树是：

```text
linux-6.12.94/
```

位于以下路径之下的内核补丁：

```text
target/linux/msm89xx/patches/
```

会作为 OpenWrt 内核构建的一部分被应用。

---

## 17. 验证内核产物

未压缩的内核位于：

```text
build_dir/target-aarch64_generic_musl/linux-msm89xx_msm8916/linux-6.12.94/arch/arm64/boot/Image
```

例如：

```bash
strings build_dir/target-aarch64_generic_musl/linux-msm89xx_msm8916/linux-6.12.94/arch/arm64/boot/Image | grep 'MSM8916 TEST'
```

这被用来验证修改过的内核源码确实已被编译。

---

## 18. Android Boot 镜像生成

MSM89xx 镜像构建会创建一个 Android boot 镜像。

项目镜像流程使用：

```text
kernel-bin
    │
    ▼
gzip
    │
    ▼
append-dtb
    │
    ▼
aboot-img
```

生成的 boot 镜像可以用以下命令检查：

```bash
file <boot-image>
```

要解包它：

```bash
unpack_bootimg     --boot_img <boot-image>     --out /tmp/boot-test
```

解出的内核是 gzip 压缩的。

解压它：

```bash
gzip -dc /tmp/boot-test/kernel     > /tmp/boot-test/kernel.uncompressed
```

然后验证：

```bash
strings /tmp/boot-test/kernel.uncompressed     | grep 'MSM8916 TEST'
```

这可以验证最终的 boot 镜像中包含的是修改过的内核。

---

## 19. DTB 与板型选择

MSM8916 target 会构建板级特定的 DTB，例如：

```text
image-msm8916-generic-ufi001b.dtb
image-msm8916-generic-ufi003_mb_v02.dtb
image-msm8916-generic-hmu05.dtb
image-msm8916-generic-uf02.dtb
image-msm8916-yiming-uz801v3.dtb
```

因此，板级特定的硬件差异应当放在对应的 DTS 中，或放在修改该 DTS 的补丁中。

---

## 20. 通用调试 vs 板级调试

### 补丁 802

```text
802-arm64-dts-qcom-msm8916-label-reserved-memory.patch
```

把：

```dts
reserved-memory {
```

改为：

```dts
reserved_memory: reserved-memory {
```

这提供了一个可供板级 DTS 文件引用的 label。

这套基础设施是面向整个 MSM8916 平台的。

### 板级 Ramoops 集成（805 与 806）

在早期迭代中，ramoops 日志节点是以单独的增量补丁添加的（UFI001B 用 811，HMU05 用 812）。这些现在已经合并到各自的板级 DTS 补丁中：

- `805-arm64-dts-qcom-add-msm8916-generic-hmu05.patch`
- `806-arm64-dts-qcom-add-msm8916-generic-ufi001b.patch`

两块板都分配了经过验证的 1MB System RAM 区域：

```dts
&reserved_memory {
        ramoops@8db00000 {
                compatible = "ramoops";
                reg = <0x0 0x8db00000 0x0 0x00100000>;
                record-size = <0x00040000>;
                console-size = <0x00040000>;
                pmsg-size = <0x00040000>;
        };
};
```

区域 `0x8db00000 - 0x8dbfffff` 是紧邻位于 `0x8dc00000` 的 modem 保留区域下方的 System RAM。

### 补丁 813

```text
813-msm8916-reboot-to-edl-support.patch
```

实现了硬件级的 Emergency Download Mode（EDL / 9008）触发，涉及 Qualcomm SCM、PM8916 PON 热复位配置、IMEM 下载 cookie（`0x322A4F99`、`0xC67E4350`、`0x77777777` 位于 `0x08600FE0`，以及重启原因 `0x00000001` 位于 `0x0860065C`），还有在 `reboot edl` / `reboot dload` 时被调用的 `msm-poweroff.c` 重启处理程序。

---

## 21. Ramoops / PSTORE 调试

当前内核配置启用了：

```text
CONFIG_PSTORE=y
CONFIG_PSTORE_COMPRESS=y
CONFIG_PSTORE_CONSOLE=y
CONFIG_PSTORE_PMSG=y
CONFIG_PSTORE_RAM=y
```

DTB 中的 `ramoops` 节点提供了持久 RAM 区域。

概念上：

```text
MSM8916 RAM
    │
    ├── normal System RAM
    ├── kernel
    ├── reserved regions
    └── ramoops region
            │
            ▼
          pstore
            │
            ▼
    persistent crash/log data
```

这旨在跨重启和崩溃保留有用的内核信息。

---

## 22. 重要的调试教训

修改过的内核源码树并不能证明设备正在运行那个内核。

验证应当经过多个层次：

```text
1. Repository source
       │
       ▼
2. Prepared OpenWrt target
       │
       ▼
3. Kernel source tree
       │
       ▼
4. Compiled Image
       │
       ▼
5. Generated boot.img
       │
       ▼
6. Extracted boot kernel
       │
       ▼
7. Running device
       │
       ▼
8. Runtime behavior
```

有用的检查包括：

```bash
grep ...
strings Image ...
file boot.img
unpack_bootimg ...
strings kernel.uncompressed ...
dmesg ...
/proc/iomem
/sys/firmware/devicetree/base/
```

这可以避免把：

```text
"the build tree contains my change"
```

与：

```text
"the device is running my change"
```

混为一谈。

---

## 23. 常规开发工作流

### 选择 OpenWrt 版本

```bash
./scripts/openwrt-version.sh --current
```

或：

```bash
./scripts/openwrt-version.sh v25.12.5
```

### 修改项目 BSP

对于 kernel/DTS 工作，编辑：

```text
msm89xx/
```

对于内核补丁：

```text
msm89xx/patches/
```

对于内核配置：

```text
msm89xx/config-6.12
```

对于镜像生成：

```text
msm89xx/image/
```

### 准备 OpenWrt

```bash
./scripts/openwrt-prepare.sh --version v25.12.5 openwrt
```

### 构建某块板

```bash
./build.sh build ufi001b
```

---

## 24. 添加一块新的 MSM8916 板

典型顺序：

```text
Add board DTS
      │
      ▼
Add board target definition
      │
      ▼
Add board-specific patch if needed
      │
      ▼
Store it in msm89xx/
      │
      ▼
Run openwrt-prepare.sh
      │
      ▼
Build with build.sh
      │
      ▼
Inspect kernel + DTB + image
      │
      ▼
Flash and test
```

对于 ramoops：

```text
Verify board RAM map first
      │
      ▼
Choose verified RAM region
      │
      ▼
Add board-specific ramoops node
```

不要假设另一块 MSM8916 板具有相同的内存布局。

---

## 25. 修改应当放在哪里

| 修改 | 仓库位置 |
|---|---|
| MSM89xx target | `msm89xx/` |
| Linux kernel 补丁 | `msm89xx/patches/` |
| 板级 DTS 补丁 | `msm89xx/patches/` |
| 内核配置 | `msm89xx/config-6.12` |
| 镜像生成 | `msm89xx/image/` |
| 项目 package | `packages/` |
| Package 补丁 | `packages/<pkg>/patches/` |
| OpenWrt 源码 overlay | `openwrt-overlay/` |
| OpenWrt 选定版本 | `devenv/.env` |
| 生成的 OpenWrt target | `openwrt/target/linux/msm89xx/` |
| 生成的内核源码 | `openwrt/build_dir/.../linux-6.12.94/` |

最后两项是生成/构建产物，通常不应被当作真相来源。

---

## 26. 当前 UFI001B 调试状态

BSP 现在包含：

```text
802-arm64-dts-qcom-msm8916-label-reserved-memory.patch
806-arm64-dts-qcom-add-msm8916-generic-ufi001b.patch
```

准备过程已用以下命令测试：

```bash
./scripts/openwrt-prepare.sh --version v25.12.5 openwrt
```

生成的 OpenWrt 树包含了这两个补丁：

```text
openwrt/target/linux/msm89xx/patches/810-...
openwrt/target/linux/msm89xx/patches/811-...
```

生成的文件包含：

```text
reserved_memory: reserved-memory
```

以及：

```text
ramoops@8db00000
record-size
console-size
pmsg-size
```

这证实了流水线中 **BSP → 准备 → OpenWrt target** 这一部分是工作的。

下一阶段是运行完整的：

```text
build.sh
  ↓
openwrt-prepare.sh
  ↓
OpenWrt kernel build
  ↓
DTB
  ↓
boot.img
```

流水线，并验证生成的 boot 镜像以及运行时的 pstore/DT 状态。

---

## 27. 简化的心智模型

整个项目可以这样记忆：

```text
                  PROJECT REPOSITORY
                         │
          ┌──────────────┼──────────────┐
          │              │              │
          ▼              ▼              ▼
      msm89xx/       packages/    openwrt-overlay/
          │
          │
          ▼
 openwrt-prepare.sh
          │
          ▼
     OPENWRT TREE
          │
          ▼
       build.sh
          │
          ▼
 OpenWrt build system
          │
     ┌────┼────┐
     │    │    │
     ▼    ▼    ▼
  Kernel DTB Rootfs
     │    │    │
     └────┼────┘
          ▼
   Image generation
          │
          ▼
    MSM8916 firmware
          │
          ▼
        DEVICE
```

### 最重要的边界

```text
PROJECT BSP
    ↓
openwrt-prepare.sh
    ↓
OPENWRT SOURCE TREE
    ↓
OpenWrt build system
    ↓
FIRMWARE
```

理解这条边界是维护项目、避免 BSP 修改意外丢失的关键。
