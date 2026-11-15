> 📄 本文件是 [BUILD_SYSTEM_GUIDE.md](BUILD_SYSTEM_GUIDE.md) 的英文原文中文译本，内容以英文版为准。

# OpenWrt 构建系统指南

本指南详细介绍了 `msm8916-openwrt` 仓库中构建编排系统的架构、操作流程、
脚本生命周期和配置机制。

---

## 1. 概述与架构原则

该构建系统为基于 Qualcomm Snapdragon 410/412（MSM8916/MSM8916v2）的
4G LTE USB dongle、移动路由器和开发板（如 `hmu05`、`uf02`、`ufi001b`、
`ufi003`、`uz801`、`mf800b`）自动化生成 OpenWrt 固件。

### 三层脚本架构

系统把职责划分到三个专用脚本中：

```
                  ┌────────────────────────┐
                  │        User / CI       │
                  └───────────┬────────────┘
                              │
                              ▼
                      ┌───────────────┐
                      │   build.sh    │  (Top-Level Orchestrator)
                      └───┬───────┬───┘
                          │       │
          ┌───────────────┘       └────────────────┐
          ▼                                        ▼
┌────────────────────┐                   ┌────────────────────┐
│ openwrt-version.sh │                   │ openwrt-prepare.sh │
│ (Version Tracking) │                   │ (Tree Preparation) │
└────────────────────┘                   └────────────────────┘
```

1. **`build.sh`（顶层编排器）**
   - 管理完整生命周期：Docker 构建器设置、OpenWrt git 克隆/检出、配置
     部署、编译以及板卡镜像生成。
   - 在宿主机系统上运行，并通过 Docker Compose 与容器交互。
2. **`scripts/openwrt-version.sh`（版本管理器）**
   - 在 `devenv/.env` 中跟踪并更新期望的上游 OpenWrt 发布版或开发分支。
   - 通过 `git ls-remote` 发现可用的上游发布 tag。
   - 从不克隆仓库、从不准备树、从不与 Docker 交互。
3. **`scripts/openwrt-prepare.sh`（树准备与同步）**
   - 在 Docker 构建容器内执行。
   - 把项目专属的 target（`msm89xx`）、package（`packages/`）、
     kernel/package patch、overlay（`openwrt-overlay/`）和 feed 注入到
     原始的 OpenWrt 检出中。
   - 从不克隆 OpenWrt、从不切换分支、从不管理 Docker 容器。

---

## 2. 事实来源模型 vs. 生成的树

为了在上游 OpenWrt 与自定义 Qualcomm 硬件支持之间保持干净的分离：

| 组件 | 事实来源（Git 跟踪） | 在 OpenWrt 构建树中的目标位置 |
|---|---|---|
| **Linux Target / BSP** | `msm89xx/` | `openwrt/target/linux/msm89xx/` |
| **项目 Packages** | `packages/` | `openwrt/package/msm8916/` |
| **Package Patches** | `packages/<pkg>/patches/*.patch` | `openwrt/package/system/<pkg>/patches/` |
| **OpenWrt 树 Patches** | `openwrt-patches/*.patch` | `openwrt/`（通过 `patch -p1` 应用） |
| **文件系统 Overlay** | `openwrt-overlay/` | `openwrt/`（合并进 rootfs） |
| **板卡配置** | `diffconfigs/<board>` | `openwrt/.config`（通过 `make defconfig` 展开） |
| **OpenWrt 版本** | `devenv/.env`（`OPENWRT_VERSION`） | 检出于 `openwrt/` |

> [!IMPORTANT]
> `openwrt/target/linux/msm89xx/` 或 `openwrt/package/msm8916/` 下的文件
> 都是临时副本。任何直接在 `openwrt/` 内部做的手工修改，都会在
> `build.sh` 同步 BSP 时被覆盖。务必在根目录的 `msm89xx/` 和
> `packages/` 目录中做 target 修改。

### 什么发布到哪里

package 选择有三个层次：

| 层次 | 文件 | 范围 |
| :--- | :--- | :--- |
| `DEFAULT_PACKAGES` | `msm89xx/Makefile` | 每块板卡 —— 所有共享 package |
| `DEVICE_PACKAGES` | `msm89xx/image/msm8916.mk` | 每个设备 |
| `diffconfigs/<board>` | `diffconfigs/` | 每块板卡：`=m` 驱动 feed、option 符号（busybox/kernel/package）、failsafe 块、设备行、仅板卡专属的 package |

`build.sh` 把 `diffconfigs/<board>` 复制到 `openwrt/.config` 并运行
`make defconfig`，于是 `DEFAULT_PACKAGES` 会自动落到每块板卡上 ——
新板卡不需要自己的 package 列表。`./build.sh guard` 会验证保证这一点
诚实成立的两条不变式。

---

## 3. 容器化的构建环境

所有工具链生成、package 编译和 kernel 构建都在一个可复现的 Docker
容器内发生：

- **Compose 配置**：`devenv/docker-compose.yml`
- **容器名称**：`devenv-builder`（服务：`builder`）
- **仓库挂载**：根工作区被挂载在容器内的 `/repo`。
- **用户权限**：通过把 `HOST_UID=$(id -u)` 和 `HOST_GID=$(id -g)`
  传入容器来保留宿主机属主。在容器内创建的构建产物仍然归你的宿主机
  用户所有。

---

## 4. 操作生命周期与执行流程

### 高层构建工作流

当你运行 `./build.sh build <board>` 时：

```text
1. check_requirements
   └── Docker installed & running? Git available? Compose file present?

2. ensure_builder
   ├── Check if builder image exists (builds if missing)
   └── Starts 'builder' container via docker compose up -d

3. ensure_prepared
   ├── Reads configured version via scripts/openwrt-version.sh --current
   ├── Clones upstream OpenWrt if 'openwrt/.git' is missing
   ├── Checks out the requested version/tag (e.g. v25.12.5 or main)
   │
   ├── If .builder-state version AND TREE_SHA match:
   │   └── sync_bsp: Fast sync of msm89xx/, packages/, and patches into openwrt/
   │       (TREE_SHA is a content hash of openwrt-patches/ + openwrt-overlay/; if
   │        either changed, the fast path is refused -- see step 7)
   │
   └── If .builder-state does not match or is missing:
       └── prepare_tree: Runs scripts/openwrt-prepare.sh in container
           ├── Copies msm89xx target into target/linux/
           ├── Strips out OpenWrt mac80211 patch from kernel patch dir
           ├── Copies project packages into package/msm8916
           ├── Applies package patches to package/system/<pkg>
           ├── Merges openwrt-overlay/
           ├── Applies mac80211 OpenWrt patch (package/kernel/mac80211/ath.mk)
           ├── Updates and installs OpenWrt package feeds
           ├── Applies ModemManager / LuCI compatibility fixes
           └── Records OPENWRT_VERSION, timestamp and TREE_SHA in .builder-state

4. prepare_config <board>
   ├── Copies diffconfigs/<board> to openwrt/.config
   └── Runs 'make defconfig V=sc' inside container to expand full configuration

5. Compilation
   └── Runs 'make -j$(($(nproc)+1)) V=sc' inside container
```

---

## 5. 命令参考

### `build.sh`

```bash
./build.sh <command> [arguments]
```

| 命令 | 参数 | 说明 |
|---|---|---|
| `help` | （无） | 显示用法说明和可用命令。 |
| `list` | （无） | 列出在 `diffconfigs/` 中找到的所有受支持板卡。 |
| `version` | `[args]` | 调用 `scripts/openwrt-version.sh` 以查看或切换 OpenWrt 版本。 |
| `image` | （无） | 重新构建 Docker 构建器容器镜像。 |
| `prepare` | `[--force]` | 克隆并准备 OpenWrt 源码树。用 `--force` 可无视 `.builder-state`。 |
| `shell` | （无） | 直接进入构建器容器内的交互式 bash shell。 |
| `build` | `<board... \| all>` | 校验板卡并编译固件。可以指定多块板卡或 `all`。 |
| `rebuild` | `<board... \| all>` | 先执行 `make clean`，再为指定板卡编译固件。 |
| `menuconfig` | `<board>` | 把 `<board>` 的配置载入 `.config` 并启动交互式 ncurses 菜单。 |
| `saveconfig` | `<board>` | 通过 `./scripts/diffconfig.sh` 提取最小配置差异，并提示是否更新 `diffconfigs/<board>`。 |
| `clean` | （无） | 在 OpenWrt 树内运行 `make clean`（清理 target 对象）。 |
| `dirclean` | （无） | 运行 `make dirclean`（清理 target、工具链和 staging 目录）。 |
| `distclean` | （无） | 运行 `make distclean`（清除所有构建产物、下载和 feed）。 |
| `guard` | `[--deep]` | 宿主机侧检查：在线的 OpenWrt 树是否与被跟踪的源码（`msm89xx/`、`packages/`）一致，**外加 diffconfig 不变式**：`=m` 模块块在每块板卡上完全相同，且没有 diffconfig 选择 `DEFAULT_PACKAGES` 中的 package。`--deep` 还会询问 `make` 下一次 kernel 构建是否会重新准备（抹掉 `build_dir`）还是增量构建。除非加 `--deep`，否则**不需要** Docker。 |
| `kernel` | `[board]` | 只重新构建 kernel 及其 in-tree 模块。不指定板卡时复用现有的 `.config`。 |
| `package` | `<name\|path> [board]` | 只重新构建一个 package，例如 `qrtr` 或 `package/msm8916/qrtr`。 |
| `kmod` | `<name> [board]` | 只重新构建一个内核模块（树外 kmod 直接构建；树内模块回退到 kernel target）。 |

> [!TIP]
> 可以在任何构建命令前加上 `DRY_RUN=1`，使其打印 OpenWrt 的 `make`
> 调用而不是执行它（适用于每个构建命令）。

---

### `scripts/openwrt-version.sh`

```bash
# Print the currently configured version
./scripts/openwrt-version.sh --current

# View the current version and list the latest 20 upstream release tags
./scripts/openwrt-version.sh

# Change the target version (updates devenv/.env)
./scripts/openwrt-version.sh v25.12.5
./scripts/openwrt-version.sh main
```

---

### `scripts/openwrt-prepare.sh`

主要由 `build.sh` 在 Docker 内调用，但也可以在容器内手工调用：

```bash
./scripts/openwrt-prepare.sh [options] [openwrt-directory]
```

- `--version <version>`：把版本记录进 `openwrt/.builder-state`。
- `--refresh-feeds`：强制完整清空 `tmp/` 并重新运行
  `./scripts/feeds update -a && ./scripts/feeds install -a`。

---

## 6. 板卡配置工作流

### 创建或定制板卡配置

1. **启动 `menuconfig`**：
   ```bash
   ./build.sh menuconfig <board>
   ```
   *示例：* `./build.sh menuconfig hmu05`

2. **做出修改**：
   在交互式 ncurses 界面中选择所需的内核模块、package 或驱动，然后选择
   `< Save >` -> `< Exit >`。

3. **把修改保存到 Diffconfig**：
   ```bash
   ./build.sh saveconfig <board>
   ```
   - `build.sh` 在容器中运行 `diffconfig.sh`，只提取非默认的选项。
   - 与现有的 `diffconfigs/<board>` 做比较。
   - 覆盖前提示确认：`Overwrite diffconfigs/<board>? [y/N]`

4. **验证构建**：
   ```bash
   ./build.sh build <board>
   ```

### 添加一块硬件板卡

添加一块物理板卡不仅仅是添加一个 DTS 文件；OpenWrt 还必须注册并选择
该板卡专属的 DTB：

1. 在 `msm89xx/patches/` 下添加一个板卡 DTS patch。
2. 在 Qualcomm 的 `arch/arm64/boot/dts/qcom/Makefile` patch 中注册其 DTB。
3. 向 `msm89xx/image/msm8916.mk` 添加一个 `Device/<profile>` 条目，
   带有显式的 `DEVICE_DTS`、唯一的 `SUPPORTED_DEVICES`、合适的
   package，以及任何板卡专属的 GPT 扇区数。
4. 添加 `diffconfigs/<board>`，选择新的 profile。
5. 验证板卡的 RAM 映射、GPIO 状态以及 eMMC/GPT 几何结构。
6. 用 `./build.sh build <board>` 构建，并在刷机前检查生成的启动镜像和
   内嵌的 DTB。

tag 发布和选择性重建工作流通过 `diffconfigs/` 发现板卡。旧的、手工调度
的 `build.yml` 仍然有一个固定的设备列表，并引用旧的
`diffconfig_<board>` 命名，因此若无单独维护，它不是一条可靠的
UFI003 构建路径。

---

## 7. 快速增量同步（`sync_bsp`）

在开发 kernel 驱动、device tree 或 package 时：
- 你**不需要**重新运行完整的 `prepare`（那会重新下载并重新安装 feed）。
- `build.sh` 检查 `.builder-state`。如果版本匹配，它会在构建前自动运行
  `sync_bsp()`：
  1. 从 `msm89xx/` 刷新 `openwrt/target/linux/msm89xx/`。
  2. 从 `packages/` 刷新 `openwrt/package/msm8916/`。
  3. 更新 `openwrt/package/system/<pkg>/patches/` 下的 patch。
  4. 重新应用运行时修复（例如 ModemManager init 脚本修复）。

**快速路径*不*做的事：** 它从不碰 `openwrt-patches/` 或
`openwrt-overlay/`，因为那些是由 `openwrt-prepare.sh` 应用的。因此，
任一树中新增或编辑的 patch 过去会被之后的每次构建悄悄忽略。
`.builder-state` 现在记录 `TREE_SHA`（两棵树的内容哈希）；如果不匹配，
`ensure_prepared` 就会拒绝快速路径并运行完整准备。因此，编辑
`openwrt-patches/*.patch` 或 `openwrt-overlay/` 下的任何东西，代价是
一次重新准备（feed 重新安装），而不是一次完整的 kernel 重建 ——
`build_dir` 不受影响。

注意 `TREE_SHA` 对*被删除*的 overlay 文件没有帮助：合并是 `cp -a`，
所以从 `openwrt-overlay/` 移除的 patch 会留在 `openwrt/` 中，必须在
那里手工删除。

---

## 8. 故障排查与常见陷阱

### `defconfig` 期间提示新的 Kernel Kconfig 选项
如果 Linux kernel 版本变化或引入了新选项：
- OpenWrt 可能在 `make defconfig` 期间交互式地提示。
- 解决这些提示，保存内核配置，并更新 `msm89xx/config-6.12`。

### Docker 权限问题
如果构建因文件权限而失败，确保 `HOST_UID` 和 `HOST_GID` 与你的本地
用户匹配：
```bash
HOST_UID=$(id -u) HOST_GID=$(id -g) ./build.sh image
```

### 重置 OpenWrt 源码状态
如果源码树进入不一致的状态：
```bash
./build.sh prepare --force
```
或者要彻底从头开始：
```bash
./build.sh distclean
```
