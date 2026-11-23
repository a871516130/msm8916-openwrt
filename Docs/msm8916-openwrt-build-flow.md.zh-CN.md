# MSM8916 OpenWrt 项目——构建流程与架构

## 1. 目的

本文档记录 `msm8916-openwrt-clean` 项目如何组织、项目脚本如何与 OpenWrt 交互，
以及 Linux 内核/BSP 补丁在何处进入构建。

项目使用三个主要脚本：

- `build.sh` —— 顶层构建管理器
- `scripts/openwrt-version.sh` —— OpenWrt 版本管理器
- `scripts/openwrt-prepare.sh` —— 准备/同步 OpenWrt 源码树

关键的架构要点是：仓库的 `msm89xx/` 目录是 OpenWrt `target/linux/msm89xx`
目标的 **BSP 真相来源**。

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
    └── ... OpenWrt 源码树 ...
```

### 真相来源 vs 生成树

维护的 BSP 是：

```text
msm89xx/
```

生成的 OpenWrt 目标是：

```text
openwrt/target/linux/msm89xx/
```

`openwrt-prepare.sh` 将前者复制到后者。因此持久性变更应放在项目仓库中，
而不仅仅是生成的 OpenWrt 树中。

---

## 3. `openwrt-version.sh`

### 目的

`openwrt-version.sh` 管理项目所选的 OpenWrt 版本。

它**不**：

- 克隆 OpenWrt
- 准备 OpenWrt
- 调用 Docker
- 构建 OpenWrt

它读取并修改：

```text
devenv/.env
```

具体为：

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

显示当前版本和可用发布版。

```bash
./scripts/openwrt-version.sh main
```

选择开发版 `main`。

```bash
./scripts/openwrt-version.sh v25.12.5
```

选择一个稳定发布版。

脚本使用以下方式发现稳定标签：

```bash
git ls-remote --tags https://git.openwrt.org/openwrt/openwrt.git
```

### 重要规则

`openwrt-version.sh` 选择期望的版本。实际的检出/版本处理由 `build.sh` 编排。

---

## 4. `build.sh`

`build.sh` 是顶层项目构建管理器。

其作用是编排：

1. 环境校验
2. Docker 构建器设置
3. OpenWrt 检出/版本处理
4. OpenWrt 准备
5. 配置准备
6. OpenWrt 编译
7. 镜像生成

因此常规板子构建应从以下开始：

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
用户
  │
  │ ./build.sh build ufi001b
  ▼
build.sh
  │
  ├── 校验环境
  ├── 确保 Docker 构建器
  ├── 选择/准备 OpenWrt 版本
  │
  ├── openwrt-prepare.sh
  │      │
  │      ├── 安装 msm89xx BSP
  │      ├── 安装项目软件包
  │      ├── 安装软件包补丁
  │      ├── 应用仓库 overlay
  │      ├── 应用 OpenWrt 源码补丁
  │      ├── 更新/安装 feeds
  │      └── 兼容性修复
  │
  ├── 准备 OpenWrt 配置
  │
  └── OpenWrt 构建
        │
        ▼
   OpenWrt 构建系统
        │
        ├── target/linux/msm89xx
        ├── Linux 内核
        ├── DTS/DTB
        ├── 根文件系统
        └── 镜像生成
                │
                ▼
          最终固件
```

---

## 6. `openwrt-prepare.sh`

此脚本是项目 BSP 仓库与 OpenWrt 源码树之间的桥梁。

其记录的责任包括：

- 安装 `msm89xx` 目标
- 安装项目软件包
- 应用仓库 overlay
- 应用项目补丁
- 更新/安装软件包 feeds
- 应用兼容性修复
- 记录准备状态

它**不**：

- 克隆 OpenWrt
- 检出分支/标签
- 调用 Docker
- 读取 `devenv/.env`

---

## 7. BSP 安装

重要的操作实际上是：

```bash
TARGET_DIR="$REPO_DIR/msm89xx"

rm -rf "$OPENWRT_DIR/target/linux/msm89xx"

cp -a     "$TARGET_DIR"     "$OPENWRT_DIR/target/linux/"
```

因此：

```text
项目 BSP
msm89xx/
    │
    │ 复制
    ▼
OpenWrt 目标
openwrt/target/linux/msm89xx/
```

### 后果

每次准备都可能替换生成的目标。

因此这不是项目变更的**持久**位置：

```text
openwrt/target/linux/msm89xx/
```

持久性变更必须放在：

```text
msm89xx/
```

---

## 8. 为何 810/811 补丁先前会消失

在内核调试期间，补丁最初创建在：

```text
openwrt/target/linux/msm89xx/patches/
```

它们在手动修改的内核树中可用，但在以下操作后消失：

```bash
./build.sh build ufi001b
```

因为准备会移除生成的目标并再次复制 BSP。

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

准备后它们会自动出现在：

```text
openwrt/target/linux/msm89xx/patches/
```

这现已验证可用。

---

## 9. 当前 BSP 补丁组织

当前补丁集包括：

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

`809-mac80211-enable-wcn36xx.patch` 是一个 **OpenWrt 源码树补丁**
（修改 `package/kernel/mac80211/ath.mk`），而不是 Linux 内核补丁。它存放在：

```text
openwrt-patches/
└── 809-mac80211-enable-wcn36xx.patch
```

并由 `scripts/openwrt-prepare.sh` 和 `build.sh` 直接应用到 OpenWrt 源码。

因此：

```text
Linux 内核补丁
    └── target/linux/msm89xx/patches/

OpenWrt 源码树补丁
    └── openwrt-patches/
```

---

## 10. 项目软件包

项目在以下位置维护软件包：

```text
packages/
```

它们被安装到：

```text
openwrt/package/msm8916/
```

生成的软件包目录在准备期间被重建。

因此 `packages/` 是持久真相来源。

---

## 11. 软件包补丁

软件包特定的补丁位于：

```text
packages/<package>/patches/
```

它们被复制到：

```text
openwrt/package/system/<package>/patches/
```

因此持久性变更应放在 `packages/` 下，而不仅仅是生成的 OpenWrt 树中。

---

## 12. 仓库 Overlay

项目还有：

```text
openwrt-overlay/
```

当存在时，其内容被复制到：

```text
openwrt/
```

这用于需要直接叠加到 OpenWrt 源码树中的文件。

---

## 13. OpenWrt Feeds

常规准备检查这些 feeds：

```text
packages
luci
routing
telephony
video
smsmanager
```

如果它们已存在，准备会报告 feeds 已安装。

可以请求完全刷新：

```bash
./scripts/openwrt-prepare.sh --refresh-feeds
```

---

## 14. 准备状态

准备脚本写入：

```text
openwrt/.builder-state
```

包括如下信息：

```text
OPENWRT_VERSION=...
PREPARED_AT=...
```

这记录了该树为哪个 OpenWrt 版本准备的。

---

## 15. 当 OpenWrt 接管时

准备后，生成的树包含：

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

此时标准 OpenWrt 构建机制接管。

项目特定的 BSP 已转换为一个 OpenWrt 目标。

---

## 16. Linux 内核构建流程

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
OpenWrt 内核构建机制
    │
    ▼
build_dir/target-aarch64_generic_musl/
linux-msm89xx_msm8916/
    │
    ├── Linux 源码
    ├── 内核配置
    ├── 内核补丁
    ├── DTS 源码
    └── 构建产物
```

当前内核源码树是：

```text
linux-6.12.94/
```

位于以下的内核补丁：

```text
target/linux/msm89xx/patches/
```

作为 OpenWrt 内核构建的一部分被应用。

---

## 17. 验证内核产物

未压缩的内核是：

```text
build_dir/target-aarch64_generic_musl/linux-msm89xx_msm8916/linux-6.12.94/arch/arm64/boot/Image
```

例如：

```bash
strings build_dir/target-aarch64_generic_musl/linux-msm89xx_msm8916/linux-6.12.94/arch/arm64/boot/Image | grep 'MSM8916 TEST'
```

这用于验证修改后的内核源码确实已被编译。

---

## 18. Android 启动镜像生成

MSM89xx 镜像构建创建 Android 启动镜像。

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

生成的启动镜像可以用以下方式检查：

```bash
file <boot-image>
```

要提取它：

```bash
unpack_bootimg     --boot_img <boot-image>     --out /tmp/boot-test
```

提取出的内核是 gzip 压缩的。

解压它：

```bash
gzip -dc /tmp/boot-test/kernel     > /tmp/boot-test/kernel.uncompressed
```

然后验证：

```bash
strings /tmp/boot-test/kernel.uncompressed     | grep 'MSM8916 TEST'
```

这验证最终启动镜像包含修改后的内核。

---

## 19. DTB 与板子选择

MSM8916 目标构建板子特定的 DTB，例如：

```text
image-msm8916-generic-ufi001b.dtb
image-msm8916-generic-ufi003_mb_v02.dtb
image-msm8916-generic-hmu05.dtb
image-msm8916-generic-uf02.dtb
image-msm8916-yiming-uz801v3.dtb
```

因此板子特定的硬件变更属于相应的 DTS 或修改该 DTS 的补丁。

---

## 20. 通用 vs 板子特定调试

### 补丁 802

```text
802-arm64-dts-qcom-msm8916-label-reserved-memory.patch
```

将：

```dts
reserved-memory {
```

改为：

```dts
reserved_memory: reserved-memory {
```

这提供了一个板子 DTS 文件可引用的标签。

该基础设施旨在 MSM8916 全平台通用。

### 板子 Ramoops 集成（805 和 806）

在早期迭代中，ramoops 日志节点作为单独的增量补丁添加（811 为 UFI001B，812 为 HMU05）。
这些已直接整合到相应的板子 DTS 补丁中：

- `805-arm64-dts-qcom-add-msm8916-generic-hmu05.patch`
- `806-arm64-dts-qcom-add-msm8916-generic-ufi001b.patch`

两块板子都分配已验证的 1MB 系统 RAM 区域：

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

区域 `0x8db00000 - 0x8dbfffff` 是紧邻 `0x8dc00000` 调制解调器保留区下方的系统 RAM。

### 补丁 813

```text
813-msm8916-reboot-to-edl-support.patch
```

在 Qualcomm SCM、PM8916 PON 暖复位配置、IMEM 下载 cookie
（`0x322A4F99`、`0xC67E4350`、`0x77777777` 位于 `0x08600FE0`，
重启原因 `0x00000001` 位于 `0x0860065C`）以及 `msm-poweroff.c` 重启处理器
（在 `reboot edl` / `reboot dload` 时调用）之间实现硬件级紧急下载模式（EDL / 9008）触发。

---

## 21. Ramoops / PSTORE 调试

当前内核配置启用：

```text
CONFIG_PSTORE=y
CONFIG_PSTORE_COMPRESS=y
CONFIG_PSTORE_CONSOLE=y
CONFIG_PSTORE_PMSG=y
CONFIG_PSTORE_RAM=y
```

DTB `ramoops` 节点提供持久 RAM 区域。

概念上：

```text
MSM8916 RAM
    │
    ├── 常规系统 RAM
    ├── 内核
    ├── 保留区
    └── ramoops 区域
            │
            ▼
          pstore
            │
            ▼
    持久崩溃/日志数据
```

这旨在跨重启和崩溃保留有用的内核信息。

---

## 22. 重要调试教训

修改过的内核源码树并不能证明设备正在运行该内核。

验证应通过多个层次进行：

```text
1. 仓库源码
       │
       ▼
2. 已准备的 OpenWrt 目标
       │
       ▼
3. 内核源码树
       │
       ▼
4. 编译后的 Image
       │
       ▼
5. 生成的 boot.img
       │
       ▼
6. 提取出的启动内核
       │
       ▼
7. 运行中的设备
       │
       ▼
8. 运行时行为
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

这防止混淆：

```text
“构建树包含我的变更”
```

与：

```text
“设备正在运行我的变更”
```

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

对于内核/DTS 工作，编辑：

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

### 构建板子

```bash
./build.sh build ufi001b
```

---

## 24. 添加新 MSM8916 板子

典型顺序：

```text
添加板子 DTS
      │
      ▼
添加板子目标定义
      │
      ▼
如需则添加板子特定补丁
      │
      ▼
存入 msm89xx/
      │
      ▼
运行 openwrt-prepare.sh
      │
      ▼
用 build.sh 构建
      │
      ▼
检查内核 + DTB + 镜像
      │
      ▼
刷写并测试
```

对于 ramoops：

```text
先验证板子 RAM 映射
      │
      ▼
选择已验证的 RAM 区域
      │
      ▼
添加板子特定 ramoops 节点
```

不要假定另一块 MSM8916 板子具有相同的内存布局。

---

## 25. 变更归属何处

| 变更 | 仓库位置 |
|---|---|
| MSM89xx 目标 | `msm89xx/` |
| Linux 内核补丁 | `msm89xx/patches/` |
| 板子 DTS 补丁 | `msm89xx/patches/` |
| 内核配置 | `msm89xx/config-6.12` |
| 镜像生成 | `msm89xx/image/` |
| 项目软件包 | `packages/` |
| 软件包补丁 | `packages/<pkg>/patches/` |
| OpenWrt 源码 overlay | `openwrt-overlay/` |
| OpenWrt 选定版本 | `devenv/.env` |
| 生成的 OpenWrt 目标 | `openwrt/target/linux/msm89xx/` |
| 生成的内核源码 | `openwrt/build_dir/.../linux-6.12.94/` |

最后两项是生成/构建产物，通常不应视为真相来源。

---

## 26. 当前 UFI001B 调试状态

BSP 现在包含：

```text
802-arm64-dts-qcom-msm8916-label-reserved-memory.patch
806-arm64-dts-qcom-add-msm8916-generic-ufi001b.patch
```

准备已用以下方式测试：

```bash
./scripts/openwrt-prepare.sh --version v25.12.5 openwrt
```

生成的 OpenWrt 树包含两个补丁：

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

这确认 **BSP → 准备 → OpenWrt 目标** 流水线部分工作正常。

下一阶段是运行完整的：

```text
build.sh
  ↓
openwrt-prepare.sh
  ↓
OpenWrt 内核构建
  ↓
DTB
  ↓
boot.img
```

流水线，并验证生成的启动镜像和运行时 pstore/DT 状态。

---

## 27. 简化心智模型

整个项目可以记忆为：

```text
                  项目仓库
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
     OPENWRT 树
          │
          ▼
       build.sh
          │
          ▼
 OpenWrt 构建系统
          │
     ┌────┼────┐
     │    │    │
     ▼    ▼    ▼
  内核  DTB  Rootfs
     │    │    │
     └────┼────┘
          ▼
   镜像生成
          │
          ▼
    MSM8916 固件
          │
          ▼
        设备
```

### 最重要的边界

```text
项目 BSP
    ↓
openwrt-prepare.sh
    ↓
OPENWRT 源码树
    ↓
OpenWrt 构建系统
    ↓
固件
```

理解这个边界是维护项目并避免意外丢失 BSP 变更的关键。
