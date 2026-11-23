# OpenWrt 构建系统指南

本指南详述 `msm8916-openwrt` 仓库中构建编排系统的架构、操作流程、脚本生命周期和配置机制。

---

## 1. 概述与架构原则

构建系统为基于 Qualcomm Snapdragon 410/412（MSM8916/MSM8916v2）的 4G LTE USB 加密狗、移动路由器和开发板（如 `hmu05`、`uf02`、`ufi001b`、`ufi003`、`uz801`、`mf800b`）自动化生成 OpenWrt 固件。

### 三层脚本架构

系统将职责分配给三个专用脚本：

```
                  ┌────────────────────────┐
                  │        User / CI       │
                  └───────────┬────────────┘
                              │
                              ▼
                      ┌───────────────┐
                      │   build.sh    │  (顶层编排器)
                      └───┬───────┬───┘
                          │       │
          ┌───────────────┘       └────────────────┐
          ▼                                        ▼
┌────────────────────┐                   ┌────────────────────┐
│ openwrt-version.sh │                   │ openwrt-prepare.sh │
│ (版本跟踪)          │                   │ (树准备)            │
└────────────────────┘                   └────────────────────┘
```

1. **`build.sh`（顶层编排器）**
   - 管理完整生命周期：Docker builder 设置、OpenWrt git 克隆/检出、配置部署、编译、板卡镜像生成。
   - 在宿主机系统上运行，并通过 Docker Compose 与容器交互。
2. **`scripts/openwrt-version.sh`（版本管理器）**
   - 跟踪并更新 `devenv/.env` 中所需的上游 OpenWrt 版本或开发分支。
   - 通过 `git ls-remote` 发现可用的上游发布标签。
   - 从不直接克隆仓库、准备树或与 Docker 交互。
3. **`scripts/openwrt-prepare.sh`（树准备与同步）**
   - 在 Docker 构建容器内执行。
   - 将项目特定目标（`msm89xx`）、包（`packages/`）、内核/包补丁、覆盖层（`openwrt-overlay/`）和 feeds 注入原始 OpenWrt 检出。
   - 从不克隆 OpenWrt、切换分支或管理 Docker 容器。

---

## 2. 事实来源模型 vs. 生成树

为了保持上游 OpenWrt 与自定义 Qualcomm 硬件支持之间的干净分离：

| 组件 | 事实来源（git 跟踪） | OpenWrt 构建树中的目标位置 |
|---|---|---|
| **Linux 目标 / BSP** | `msm89xx/` | `openwrt/target/linux/msm89xx/` |
| **项目包** | `packages/` | `openwrt/package/msm8916/` |
| **包补丁** | `packages/<pkg>/patches/*.patch` | `openwrt/package/system/<pkg>/patches/` |
| **OpenWrt 树补丁** | `openwrt-patches/*.patch` | `openwrt/`（通过 `patch -p1` 应用） |
| **文件系统覆盖层** | `openwrt-overlay/` | `openwrt/`（合并进 rootfs） |
| **板卡配置** | `diffconfigs/<board>` | `openwrt/.config`（通过 `make defconfig` 展开） |
| **OpenWrt 版本** | `devenv/.env`（`OPENWRT_VERSION`） | 在 `openwrt/` 中检出 |

> [!IMPORTANT]
> `openwrt/target/linux/msm89xx/` 或 `openwrt/package/msm8916/` 下的文件是临时副本。任何直接在 `openwrt/` 内做的手动修改都会在 `build.sh` 同步 BSP 时被覆盖。始终在根目录的 `msm89xx/` 和 `packages/` 目录中做目标变更。

### 什么发布到哪里

包选择有三层：

| 层 | 文件 | 范围 |
| :--- | :--- | :--- |
| `DEFAULT_PACKAGES` | `msm89xx/Makefile` | 每个板卡 —— 所有共享包 |
| `DEVICE_PACKAGES` | `msm89xx/image/msm8916.mk` | 按设备 |
| `diffconfigs/<board>` | `diffconfigs/` | 按板卡：`=m` 驱动 feed、选项符号（busybox/内核/包）、failsafe 块、设备行、仅板卡包 |

`build.sh` 将 `diffconfigs/<board>` 复制到 `openwrt/.config` 并运行 `make defconfig`，所以 `DEFAULT_PACKAGES` 自动落到每个板卡上 —— 新板卡无需自己的包列表。`./build.sh guard` 验证保持这种诚实性的两个不变量。

---

## 3. 容器化构建环境

所有工具链生成、包编译和内核构建都发生在可复现的 Docker 容器内：

- **Compose 配置**：`devenv/docker-compose.yml`
- **容器名称**：`devenv-builder`（服务：`builder`）
- **仓库挂载**：工作区根目录挂载在容器内的 `/repo`。
- **用户权限**：通过将 `HOST_UID=$(id -u)` 和 `HOST_GID=$(id -g)` 传入容器，保留宿主机所有权。容器内创建的构建产物仍归你的宿主机用户所有。

---

## 4. 操作生命周期与执行流程

### 高层构建工作流

当你运行 `./build.sh build <board>` 时：

```text
1. check_requirements
   └── Docker 已安装且运行中？Git 可用？Compose 文件存在？

2. ensure_builder
   ├── 检查 builder 镜像是否存在（缺失则构建）
   └── 通过 docker compose up -d 启动 'builder' 容器

3. ensure_prepared
   ├── 通过 scripts/openwrt-version.sh --current 读取配置的版本
   ├── 如果 'openwrt/.git' 缺失则克隆上游 OpenWrt
   ├── 检出请求的版本/标签（例如 v25.12.5 或 main）
   │
   ├── 如果 .builder-state 版本和 TREE_SHA 匹配：
   │   └── sync_bsp：将 msm89xx/、packages/ 和补丁快速同步进 openwrt/
   │       （TREE_SHA 是 openwrt-patches/ + openwrt-overlay/ 的内容哈希；如果
   │        任一改变，快路径被拒绝 —— 见步骤 7）
   │
   └── 如果 .builder-state 不匹配或缺失：
       └── prepare_tree：在容器中运行 scripts/openwrt-prepare.sh
           ├── 将 msm89xx 目标复制进 target/linux/
           ├── 从内核补丁目录剥离 OpenWrt mac80211 补丁
           ├── 将项目包复制进 package/msm8916
           ├── 将包补丁应用到 package/system/<pkg>
           ├── 合并 openwrt-overlay/
           ├── 应用 mac80211 OpenWrt 补丁（package/kernel/mac80211/ath.mk）
           ├── 更新并安装 OpenWrt 包 feeds
           ├── 应用 ModemManager / LuCI 兼容性修复
           └── 在 .builder-state 中记录 OPENWRT_VERSION、时间戳和 TREE_SHA

4. prepare_config <board>
   ├── 将 diffconfigs/<board> 复制到 openwrt/.config
   └── 在容器内运行 'make defconfig V=sc' 以展开完整配置

5. 编译
   └── 在容器内运行 'make -j$(($(nproc)+1)) V=sc'
```

---

## 5. 命令参考

### `build.sh`

```bash
./build.sh <command> [arguments]
```

| 命令 | 参数 | 描述 |
|---|---|---|
| `help` | （无） | 显示用法说明和可用命令。 |
| `list` | （无） | 列出 `diffconfigs/` 中发现的所有受支持板卡。 |
| `version` | `[args]` | 调用 `scripts/openwrt-version.sh` 查看或切换 OpenWrt 版本。 |
| `image` | （无） | 重建 Docker builder 容器镜像。 |
| `prepare` | `[--force]` | 克隆并准备 OpenWrt 源码树。使用 `--force` 忽略 `.builder-state`。 |
| `shell` | （无） | 直接进入 builder 容器内的交互式 bash shell。 |
| `build` | `<board... \| all>` | 验证板卡并编译固件。可指定多个板卡或 `all`。 |
| `rebuild` | `<board... \| all>` | 在编译指定板卡固件前执行 `make clean`。 |
| `menuconfig` | `<board>` | 将 `<board>` 配置加载进 `.config` 并启动交互式 ncurses 菜单。 |
| `saveconfig` | `<board>` | 通过 `./scripts/diffconfig.sh` 提取最小配置差异，并提示更新 `diffconfigs/<board>`。 |
| `clean` | （无） | 在 OpenWrt 树内运行 `make clean`（清理目标对象）。 |
| `dirclean` | （无） | 运行 `make dirclean`（清理目标、工具链和暂存目录）。 |
| `distclean` | （无） | 运行 `make distclean`（清除所有构建产物、下载和 feeds）。 |
| `guard` | `[--deep]` | 宿主机侧检查实时 OpenWrt 树是否与受跟踪源码（`msm89xx/`、`packages/`）匹配，**加上 diffconfig 不变量**：`=m` 模块块在每个板卡上相同，且无 diffconfig 选择 `DEFAULT_PACKAGES` 包。`--deep` 额外询问 `make` 下次内核构建是重新准备（清空 `build_dir`）还是增量。除非 `--deep`，否则**不需要** Docker。 |
| `kernel` | `[board]` | 仅重建内核及其树内模块。没有板卡时复用现有 `.config`。 |
| `package` | `<name\|path> [board]` | 仅重建一个包，例如 `qrtr` 或 `package/msm8916/qrtr`。 |
| `kmod` | `<name> [board]` | 仅重建一个内核模块（树外 kmods 直接构建；树内模块回退到内核目标）。 |

> [!TIP]
> 可以在任何构建命令前加 `DRY_RUN=1`，打印 OpenWrt `make` 调用而不是执行它（适用于每个构建命令）。

---

### `scripts/openwrt-version.sh`

```bash
# 打印当前配置的版本
./scripts/openwrt-version.sh --current

# 查看当前版本并列出最新 20 个上游发布标签
./scripts/openwrt-version.sh

# 更改目标版本（更新 devenv/.env）
./scripts/openwrt-version.sh v25.12.5
./scripts/openwrt-version.sh main
```

---

### `scripts/openwrt-prepare.sh`

主要由 `build.sh` 在 Docker 内调用，但也可以在容器内手动调用：

```bash
./scripts/openwrt-prepare.sh [options] [openwrt-directory]
```

- `--version <version>`：在 `openwrt/.builder-state` 中记录版本。
- `--refresh-feeds`：强制完全清除 `tmp/` 并重新运行 `./scripts/feeds update -a && ./scripts/feeds install -a`。

---

## 6. 板卡配置工作流

### 创建或定制板卡配置

1. **启动 `menuconfig`**：
   ```bash
   ./build.sh menuconfig <board>
   ```
   *示例：* `./build.sh menuconfig hmu05`

2. **进行更改**：
   在交互式 ncurses UI 中选择所需内核模块、包或驱动，并选择 `< Save >` -> `< Exit >`。

3. **将更改保存到 Diffconfig**：
   ```bash
   ./build.sh saveconfig <board>
   ```
   - `build.sh` 在容器中运行 `diffconfig.sh` 以只提取非默认选项。
   - 与现有的 `diffconfigs/<board>` 比较。
   - 覆盖前提示确认：`Overwrite diffconfigs/<board>? [y/N]`

4. **验证构建**：
   ```bash
   ./build.sh build <board>
   ```

### 添加硬件板卡

添加物理板卡需要的不仅仅是添加 DTS 文件；OpenWrt 必须注册并选择板卡特定的 DTB：

1. 在 `msm89xx/patches/` 下添加板卡 DTS 补丁。
2. 在 Qualcomm `arch/arm64/boot/dts/qcom/Makefile` 补丁中注册其 DTB。
3. 向 `msm89xx/image/msm8916.mk` 添加 `Device/<profile>` 条目，带显式 `DEVICE_DTS`、唯一的 `SUPPORTED_DEVICES`、适当的包，以及任何板卡特定 GPT 扇区数。
4. 添加选择新配置文件的 `diffconfigs/<board>`。
5. 验证板卡 RAM 映射、GPIO 状态和 eMMC/GPT 几何。
6. 用 `./build.sh build <board>` 构建，并在刷写前检查生成的启动镜像和嵌入式 DTB。

标签发布和选择性重建工作流通过 `diffconfigs/` 发现板卡。遗留的手动分发 `build.yml` 仍有固定设备列表，并引用旧的 `diffconfig_<board>` 命名，所以除非单独维护，否则它不是一个可靠的 UFI003 构建路径。

---

## 7. 快速增量同步（`sync_bsp`）

在开发内核驱动、设备树或包时：
- 你**不需要**重新运行完整的 `prepare`（那会重新下载并重新安装 feeds）。
- `build.sh` 检查 `.builder-state`。如果版本匹配，它在构建前自动运行 `sync_bsp()`：
  1. 从 `msm89xx/` 刷新 `openwrt/target/linux/msm89xx/`。
  2. 从 `packages/` 刷新 `openwrt/package/msm8916/`。
  3. 更新 `openwrt/package/system/<pkg>/patches/` 下的补丁。
  4. 重新应用运行时修复（例如 ModemManager init 脚本修复）。

**快路径不做的事情：** 它从不碰 `openwrt-patches/` 或 `openwrt-overlay/`，因为那些由 `openwrt-prepare.sh` 应用。因此，在任一树中新增或编辑的补丁曾被后续构建静默忽略。`.builder-state` 现在记录 `TREE_SHA`（两树的内容哈希）；如果不匹配，`ensure_prepared` 拒绝快路径并运行完整准备。因此，编辑 `openwrt-patches/*.patch` 或 `openwrt-overlay/` 下的任何内容会花费一次重新准备（重新安装 feeds），而不是完整内核重建 —— `build_dir` 不受影响。

注意 `TREE_SHA` 对*删除的*覆盖层文件**没有**帮助：合并是 `cp -a`，所以从 `openwrt-overlay/` 移除的补丁会留在 `openwrt/`，必须在那里手动删除。

---

## 8. 故障排查与常见陷阱

### `defconfig` 期间提示的新内核 Kconfig 选项
如果 Linux 内核版本改变或引入新选项：
- OpenWrt 可能 在 `make defconfig` 期间交互式提示。
- 解决提示，保存内核配置，并更新 `msm89xx/config-6.12`。

### Docker 权限问题
如果构建因文件权限失败，确保 `HOST_UID` 和 `HOST_GID` 匹配你的本地用户：
```bash
HOST_UID=$(id -u) HOST_GID=$(id -g) ./build.sh image
```

### 重置 OpenWrt 源码状态
如果源码树进入不一致状态：
```bash
./build.sh prepare --force
```
或完全干净状态：
```bash
./build.sh distclean
```
