> 📄 本文件是 [ARCHITECTURE.md](ARCHITECTURE.md) 的英文原文中文译本，内容以英文版为准。

# 项目架构与目录地图

> `msm8916-openwrt-clean` 仓库的**定位指南**。
> 配套文档（这里**不要**重复其内容）：
> - [BUILD_SYSTEM_GUIDE.md](BUILD_SYSTEM_GUIDE.md) —— 完整的 `build.sh` 命令参考。
> - [PATCHES_AND_PACKAGING.md](PATCHES_AND_PACKAGING.md) —— 哪个改动放进哪个文件夹，以及如何添加一个改动。
> - [OPENWRT_UPSTREAMING_STRATEGY.md](OPENWRT_UPSTREAMING_STRATEGY.md) —— 把改动上游化到官方 OpenWrt 的路线图。
> - [msm8916-openwrt-build-flow.md](msm8916-openwrt-build-flow.md) —— "BSP 即事实来源"的设计说明。
> - [Docker/README.md](Docker/README.md) —— 构建器容器的细节。

---

## 1. 三个层次（心智模型）

本仓库中的一切都是为了把*被跟踪的源码*变成*已刷写的镜像*。
在脑子里保持这三个层次分开：

| 层次 | 位置 | 可编辑？ | 生命周期 |
| :---- | :---- | :-------- | :------- |
| **1. 被跟踪的源码** | `msm89xx/`、`openwrt-patches/`、`openwrt-overlay/`、`packages/`、`diffconfigs/`、`devenv/`、`scripts/`、`build.sh`、`sync-version.sh`、`build-recovery.sh` | **可以 —— 这才是你提交的 repo** | 受版本控制 |
| **2. 已准备的 OpenWrt 树** | `openwrt/` | **不可以 —— 生成产物** | 每次 `build.sh` 运行都从第 1 层重新同步；被 git 忽略 |
| **3. 构建出的镜像 / package** | `openwrt/bin/`、`openwrt/build_dir/`、`openwrt/staging_dir/` | 不可以 | 构建的一次性输出 |

**黄金法则：绝不修改 `openwrt/` 里的任何东西。** `build.sh` 每次运行都会
把被跟踪的源码重新同步进去，所以只在 `openwrt/` 内部做的修改会被悄悄
覆盖。请改为在第 1 层修改源码。

---

## 2. 顶层目录地图

| 路径 | 角色 |
| :--- | :--- |
| `build.sh` | 顶层构建编排器（**在宿主机上**运行，驱动 Docker）。 |
| `scripts/` | 两个编排辅助脚本：`openwrt-version.sh`、`openwrt-prepare.sh`。 |
| `sync-version.sh` | 发布版本唯一事实来源辅助脚本（宿主机侧）。 |
| `build-recovery.sh` | 构建每块板卡的 recovery/救援启动镜像（宿主机侧）。 |
| `devenv/` | Docker **构建器**定义：`Dockerfile`、`docker-compose.yml`、`dependencies.sh`、`.env`。 |
| `msm89xx/` | **BSP 事实来源** —— OpenWrt 的 `target/linux/msm89xx` target、kernel patches、kernel 配置、base-files、镜像 + recovery 配方、`Makefile`（`DEFAULT_PACKAGES`）、`modules.mk`。 |
| `openwrt-patches/` | 4 个**直接打在 OpenWrt 树本身上**的 patch（`include/package-pack.mk`、mac80211 的 `ath.mk`、`rstrip.sh`、netifd 的 wifi 驱动 —— `wifi-scripts` shell **以及** ucode 的 `mac80211.sh`）。 |
| `openwrt-overlay/` | 构建前通过 `cp -a` 合并进 `openwrt/` 的每 package / 每 feed **源码 patch**（wcn36xx、hostapd、libqmi、modemmanager……）。 |
| `packages/` | 21 个自定义 userspace 应用 + LuCI 模块；被复制到 `package/msm8916/`。 |
| `diffconfigs/` | 7 份按板卡的 kernel/package 配置（`hmuf02v5`、`uf02`、`ufi001b`、`ufi003`、`uz801`、`mf800b`、`mifib-v12`）。 |
| `openwrt/` | **已准备的 OpenWrt 树**（克隆 + patch + overlay）。构建产物 —— 不要编辑，不要提交。 |
| `version` | 发布版本字符串（如 `25.12.6-r3`）；`sync-version.sh` 的事实来源。 |
| `tests/` | 测试框架（如 `tests/himi-ok-guard/run.sh`）。 |
| `TBR/` | "待评审（To-be-reviewed）"的 package，已暂存但尚未提升进 `packages/`。 |
| `Docs/` | 本文档树。 |
| `fsg_extracted/`、`hmu05_fsg_extracted/`、`ghidra_proj/`、`ghidra_scripts/`、`edl-ground-truth-analysis.md` | modem 固件逆向工程 / 提取出的 NV 产物。**不属于构建的一部分。** |
| `README.md`、`RELEASE_NOTES.md`、`FLASHING_AND_RELEASE_GUIDE.md`、`MAINTAINERS.md`、`CODEOWNERS`、`LICENSE` | 项目元信息 / 发布文档。 |

> **卫生提示：** 工作树目前还包含 `doc/` 和 `docs/` 目录，其内容与
> `Docs/` 逐字节相同。`Docs/` 是其他所有地方引用的权威文档树 —— 把
> `doc/` 和 `docs/` 当作散落的重复副本，不要往那里添加新文档。

---

## 3. 四种"事实来源"机制

`build.sh` 把四个不同的改动流合并进已准备好的 `openwrt/` 树。
知道哪一个是最终胜者、以及在何时胜出，可以避免这样一类破坏：某一层的
文件在镜像组装时被悄悄冲突掉。

| 你想修改… | 编辑… | 由谁应用 | 机制 |
| :------------------ | :---- | :--------- | :-------- |
| Linux kernel（驱动、SoC） | `msm89xx/patches/NNN-*.patch` | kernel 构建（quilt） | 逐字复制到 `openwrt/target/linux/msm89xx/patches` |
| OpenWrt 树本身（罕见） | `openwrt-patches/*.patch` | `build.sh` | `patch -p1`（有 dry-run 守卫） |
| 上游 OpenWrt package（hostapd、mac80211/wcn36xx、libqmi……） | `openwrt-overlay/package/&lt;feed&gt;/&lt;pkg&gt;/patches/NNN-*.patch` | `build.sh` | `cp -a openwrt-overlay/. openwrt/` |
| 发布一个新程序 / LuCI 应用 | `packages/&lt;name&gt;/` | `build.sh` | 复制到 `openwrt/package/msm8916/` |
| 镜像内容 / 默认值 / package 选择 | `msm89xx/base-files/`、`msm89xx/Makefile`、`msm89xx/image/`、`diffconfigs/` | 镜像构建 | 复制 / 编译进去 |

**`build.sh` 强制执行的三条不变式：**

1. **`cp -a` 从不删除。** `openwrt-overlay/` 用 `cp -a` 合并，它只会
   *覆盖*复制，绝不删除。你从 `openwrt-overlay/` 重命名或删除的 patch
   会在 `openwrt/` 中留下旧文件，直到你手工删除它。（参见
   `PATCHES_AND_PACKAGING.md` §2。）由于 overlay 合并不能删除文件，
   从 `openwrt/` 删除过期副本是每次移除 overlay 的必要环节。
2. **BSP 漂移是致命的。** 同步之后，`build.sh` 会运行
   `assert_bsp_synced()`，即把 `msm89xx/` 和 `packages/` 与在线的
   `openwrt/` 树做 `diff -rq`。任何差异都会中止构建 —— 否则一棵缺少
   patch 的在线树会产出一个悄悄错误的 kernel。用
   `./build.sh guard [--deep]` 检查。
3. **patch 树变更会强制重新准备。** 当 `.builder-state` 已记录当前
   OpenWrt 版本时，`ensure_prepared()` 通常走快速路径：它只重新同步
   BSP 并跳过 `openwrt-prepare.sh` —— 而后者正是应用
   `openwrt-patches/` 并合并 `openwrt-overlay/` 的步骤。这意味着任一
   树中新添加或编辑的 patch 会被之后的每次构建悄悄忽略。
   `.builder-state` 现在还记录 `TREE_SHA`，即 `openwrt-patches/` +
   `openwrt-overlay/` 的内容哈希；如果它不再匹配，快速路径就会被拒绝，
   完整准备会重新运行。（早于 `TREE_SHA` 的状态文件无法证明同步，
   所以它也会触发一次重新准备。）

**diffconfig 守卫**另外强制：(a) `=m` 内核模块块在所有板卡之间
*完全相同*，(b) 没有 diffconfig 选择已在 `DEFAULT_PACKAGES`
（位于 `msm89xx/Makefile`）中的 package。差异会在构建开始前被拒绝。

---

## 4. 构建与发布脚本（辅助脚本）

除另有说明外，这些都在**宿主机**上运行。它们 shell 进 Docker 容器执行
实际编译。

| 脚本 | 运行于 | 角色 |
| :----- | :------ | :--- |
| `build.sh` | 宿主机 | **编排器。** 管理 Docker 构建器，在固定版本上克隆/检出 OpenWrt 树，同步 BSP，运行守卫，并在容器内调用 `make`。子命令：`help`、`list`、`version`、`image`（构建 Docker 镜像）、`prepare [--force]`、`guard [--deep]`、`shell`（交互式容器）、`build &lt;board|all&gt;`、`rebuild &lt;board|all&gt;`（清理后构建）、`kernel [board]`、`package &lt;name|path&gt; [board]`、`kmod &lt;name&gt; [board]`、`menuconfig &lt;board&gt;`、`saveconfig &lt;board&gt;`。 |
| `scripts/openwrt-version.sh` | 宿主机 | **版本管理器。** 读/写 `devenv/.env`（`OPENWRT_VERSION`）。决定 `openwrt/` 检出到哪个 OpenWrt tag/branch。从不克隆，从不碰 Docker。由 `build.sh version` 委托运行。 |
| `scripts/openwrt-prepare.sh` | **容器内** | **树准备器。** 安装 `msm89xx` target + 项目 `packages`，应用 `openwrt-overlay/`（`cp -a`），应用 `openwrt-patches/`（`patch -p1`），更新/安装 feed，应用兼容性修复，记录准备状态。从不克隆，从不读 `.env`，从不调用 Docker。 |
| `sync-version.sh` | 宿主机 | **发布版本 SSoT。** 提升 `version` 文件并重写每份 `diffconfigs/*` 中的 `CONFIG_VERSION_*` 块，使刷写后的系统报告正确的版本。 |
| `build-recovery.sh` | 宿主机（不用容器） | 构建每块板卡的 recovery/救援镜像 → `msm89xx/recovery/&lt;board&gt;.img` = 该板卡的**生产 kernel**（从其 `-squashfs-boot.img` 中取出）+ 一个 gzip 压缩的、以 `msm89xx/recovery/irfs` 为内容的 cpio 作为 ramdisk。不编译任何 kernel。 |
| `devenv/Dockerfile` | 构建时 | 定义 `devenv-builder` 镜像：`ubuntu:22.04` + 所有 OpenWrt 构建依赖（`dependencies.sh`）+ 一个 UID/GID 与宿主机匹配的非 root `builder` 用户。 |
| `devenv/docker-compose.yml` | 宿主机 | 定义 `builder` 服务；把 repo 以 bind mount 挂在 `/repo`；工作目录 `/repo/openwrt`；host 网络。 |
| `devenv/dependencies.sh` | 构建时（在镜像内） | 用 `apt-get` 安装烘焙进镜像的每个工具链/构建依赖。 |
| `devenv/.env` | 宿主机 | `OPENWRT_VERSION=v25.12.5` —— `openwrt-version.sh` 消费的版本 pin。 |

> **运行时（设备）脚本是另一类东西。** 随镜像*发布进去*的脚本 —— 例如
> `msm89xx/base-files/etc/diag.sh`、`lib/himi-ok.sh`、
> `usr/sbin/wifi-sta-dhcp.sh`、`msm89xx/image/flash.sh`、
> `msm89xx/recovery/fetch-device-blobs.sh` 以及 `packages/*/files/*.sh`
> —— 在镜像制作时被复制进 rootfs，并在**设备上**运行，而不是在构建
> 期间运行。它们不是构建辅助脚本。

---

## 5. Docker 分离 —— 宿主机与容器的边界

这是项目中最不显眼的部分，所以单独成节。

~~~
 HOST MACHINE                      DOCKER CONTAINER (devenv-builder)
 +---------------------------+    +------------------------------------------+
 |  repo  (msm8916-openwrt…) |    |  image: ubuntu:22.04 + toolchain deps     |
 |   |- build.sh  -----------|--->|  service: builder (container openwrt-builder)
 |   |- msm89xx/  packages/  |    |  mount:  ..  -->  /repo   (the whole repo) |
 |   |- openwrt/  (tree)     |<---|  workdir: /repo/openwrt                   |
 |   '- devenv/              |    |  user: HOST_UID:HOST_GID (non-root)        |
 +---------------------------+    |  network: host                            |
         needs only:               |  runs:  make -jN  (all compilation)       |
         docker + git              +------------------------------------------+
~~~

**工作原理：**

- 宿主机只需要 **Docker + git**。不需要编译器，不需要 OpenWrt 工具链。
- `devenv/docker-compose.yml` 从 `devenv/Dockerfile` 构建
  `devenv-builder` 镜像（Ubuntu 22.04 + `dependencies.sh` 中的依赖）。
- **整个 repo** 被 bind mount 进容器的 `/repo`
  （`volumes: - ..:/repo`，其中 `..` 是 repo 根目录，因为 compose 的
  *context* 就是 repo 根）。因此 OpenWrt 树在容器内显示为
  `/repo/openwrt`，这正是容器的工作目录。
- `build.sh` 在宿主机上运行。对每个构建步骤，它通过
  `docker compose exec builder …`（`docker_exec` 辅助函数）shell 进
  容器。**所有 `make`/`patch`/`cp` 工作都在容器内发生。**
- 容器以**一个 UID/GID 等于宿主机用户的非 root 用户**运行
  （`HOST_UID`/`HOST_GID`，默认取自 `id -u`/`id -g`）。这就是为什么
  构建期间写在 `/repo/openwrt` 下的文件回到宿主机上时属主是正确的 ——
  无需 `sudo` 清理。
- 网络采用 **host** 模式，以便容器能够获取 OpenWrt feed/源码。

**为什么要有这种分离：**

1. **可复现性。** 每位开发者和 CI 都使用*相同的* Ubuntu 22.04 +
   固定的依赖集合，于是"在我机器上能构建"式失败不复存在。
2. **隔离。** OpenWrt 构建是侵入性的（写入数 GB、需要特定工具）；
   它留在一个临时容器内，绝不污染宿主机。
3. **OpenWrt 树是一个挂载，而不是副本。** 因为 `openwrt/` 是被
   bind mount 的 repo 子目录，构建输出会立即在宿主机上可见，并且天然
   被 git 排除（它是构建产物）。

**心智捷径：** *你在宿主机上编辑，`build.sh` 在容器里构建，容器通过
`/repo` 挂载把结果写回宿主机的 `openwrt/`。*

---

## 6. 一次构建，端到端

~~~
./build.sh build hmuf02v5
        | (host)
        |- ensure_builder()        docker compose up -d builder
        |- openwrt-version.sh      read OPENWRT_VERSION from devenv/.env
        |- ensure_openwrt()        clone / checkout openwrt/ at that version
        |- prepare_tree()  -------> (container) openwrt-prepare.sh
        |                             - install msm89xx target + packages
        |                             - cp -a openwrt-overlay/  -> openwrt/
        |                             - patch -p1 openwrt-patches/*.patch
        |                             - ./scripts/feeds update/install
        |- sync_bsp()  -----------> (container) cp -a msm89xx  -> openwrt/target/linux/
        |                             cp -a packages -> openwrt/package/msm8916
        |                             assert_bsp_synced()   (diff -rq guard)
        |- prepare_config()        copy diffconfigs/hmuf02v5 -> openwrt/.config
        |- run_openwrt_make() ----> (container) make -jN  ->  openwrt/bin/targets/…
        '- image + packages land in openwrt/bin/   (visible on host via /repo)
~~~

选择性子命令（`kernel`、`package`、`kmod`）复用同样的
`ensure_prepared` → `sync_bsp` → `make &lt;target&gt;` 路径，只是停在相关的
`make` 目标上，而不是完整镜像。

---

## 7. 到哪里找什么

| 我想… | 阅读 |
| :---------- | :--- |
| 运行一次构建 / 了解 `build.sh` 的标志 | [BUILD_SYSTEM_GUIDE.md](BUILD_SYSTEM_GUIDE.md) |
| 知道某个改动属于哪个文件夹 | [PATCHES_AND_PACKAGING.md](PATCHES_AND_PACKAGING.md) |
| 理解"BSP 即事实来源" | [msm8916-openwrt-build-flow.md](msm8916-openwrt-build-flow.md) |
| 理解 Docker 构建器 | [Docker/README.md](Docker/README.md) |
| 查看所有已编目的 patch | [Patches/README.md](Patches/README.md) |
| 提升发布版本 | `sync-version.sh`（§4）+ `version` 文件 |
| 构建 recovery 镜像 | `build-recovery.sh`（§4） |

---
*写于 2026-10-25。反映的是 commit `79d102e`（guard-the-patch-tree）时的 `build.sh` 以及 `v25.12.5` 固定树。*
