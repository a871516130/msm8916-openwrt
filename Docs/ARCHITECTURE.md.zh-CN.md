# 项目架构与目录映射

> **定向指南**，针对 `msm8916-openwrt-clean` 仓库。
> 配套文档（**不要**在此重复）：
> - [BUILD_SYSTEM_GUIDE.md](BUILD_SYSTEM_GUIDE.md) —— 完整的 `build.sh` 命令参考。
> - [PATCHES_AND_PACKAGING.md](PATCHES_AND_PACKAGING.md) —— 哪个变更属于哪个目录，以及如何添加一个。
> - [OPENWRT_UPSTREAMING_STRATEGY.md](OPENWRT_UPSTREAMING_STRATEGY.md) —— 将变更向上游合入官方 OpenWrt 的路线图。
> - [msm8916-openwrt-build-flow.md](msm8916-openwrt-build-flow.md) —— BSP 作为事实来源的设计说明。
> - [Docker/README.md](Docker/README.md) —— 构建容器的详细说明。

---

## 1. 三个层次（心智模型）

此仓库中的一切都为了把*受跟踪的源码*变成*刷写的镜像*。在你的脑海中保持这三个层次分离：

| 层次 | 位置 | 可编辑？ | 生命周期 |
| :---- | :---- | :-------- | :------- |
| **1. 受跟踪源码** | `msm89xx/`、`openwrt-patches/`、`openwrt-overlay/`、`packages/`、`diffconfigs/`、`devenv/`、`scripts/`、`build.sh`、`sync-version.sh`、`build-recovery.sh` | **是 —— 这是你提交的仓库** | 版本受控 |
| **2. 准备好的 OpenWrt 树** | `openwrt/` | **否 —— 生成的产物** | 在*每次* `build.sh` 运行时从第 1 层重新同步；git 忽略 |
| **3. 构建的镜像 / 包** | `openwrt/bin/`、`openwrt/build_dir/`、`openwrt/staging_dir/` | 否 | 一次构建的一次性输出 |

**黄金法则：** 永远不要编辑 `openwrt/` 内的任何东西。`build.sh` 每次运行时会把受跟踪源码重新同步进去，所以只在 `openwrt/` 内做的编辑会被静默覆盖。请改第 1 层的源码。

---

## 2. 顶层目录映射

| 路径 | 作用 |
| :--- | :--- |
| `build.sh` | 顶层构建编排器（**在宿主机上运行**，驱动 Docker）。 |
| `scripts/` | 两个编排辅助脚本：`openwrt-version.sh`、`openwrt-prepare.sh`。 |
| `sync-version.sh` | 发布版本单一事实来源辅助脚本（宿主机侧）。 |
| `build-recovery.sh` | 构建每个板卡的恢复/救援启动镜像（宿主机侧）。 |
| `devenv/` | Docker **builder** 定义：`Dockerfile`、`docker-compose.yml`、`dependencies.sh`、`.env`。 |
| `msm89xx/` | **BSP 事实来源** —— OpenWrt 的 `target/linux/msm89xx` 目标、内核补丁、内核配置、base-files、镜像 + 恢复配方、`Makefile`（`DEFAULT_PACKAGES`）、`modules.mk`。 |
| `openwrt-patches/` | 4 个**应用到 OpenWrt 树本身**的补丁（`include/package-pack.mk`、mac80211 `ath.mk`、`rstrip.sh`、netifd 的 wifi 驱动 —— `wifi-scripts` shell **和** ucode `mac80211.sh`）。 |
| `openwrt-overlay/` | 按包 / 按 feed 的**源码补丁**，通过 `cp -a` 在构建前合并进 `openwrt/`（wcn36xx、hostapd、libqmi、modemmanager 等）。 |
| `packages/` | 21 个自定义用户空间应用 + LuCI 模块；复制到 `package/msm8916/`。 |
| `diffconfigs/` | 7 个按板卡的内核/包配置（`hmuf02v5`、`uf02`、`ufi001b`、`ufi003`、`uz801`、`mf800b`、`mifib-v12`）。 |
| `openwrt/` | **准备好的 OpenWrt 树**（克隆 + 补丁 + 覆盖层）。构建产物 —— 不要编辑，不要提交。 |
| `version` | 发布版本字符串（例如 `25.12.6-r3`）；`sync-version.sh` 的事实来源。 |
| `tests/` | 测试框架（例如 `tests/himi-ok-guard/run.sh`）。 |
| `TBR/` | “待审查”包，已暂存但尚未提升进 `packages/`。 |
| `Docs/` | 本文档树。 |
| `fsg_extracted/`、`hmu05_fsg_extracted/`、`ghidra_proj/`、`ghidra_scripts/`、`edl-ground-truth-analysis.md` | 调制解调器固件逆向工程 / 提取的 NV 产物。**不属于构建。** |
| `README.md`、`RELEASE_NOTES.md`、`FLASHING_AND_RELEASE_GUIDE.md`、`MAINTAINERS.md`、`CODEOWNERS`、`LICENSE` | 项目元 / 发布文档。 |

> **卫生提示：** 工作树当前还包含 `doc/` 和 `docs/` 目录，其内容与 `Docs/` 逐字节相同。`Docs/` 是其它所有地方引用的规范树 —— 把 `doc/` 和 `docs/` 当作多余副本，不要在那里添加新文档。

---

## 3. 四个“事实来源”机制

`build.sh` 将四个不同的变更流合并进准备好的 `openwrt/` 树。知道哪一个胜出、何时胜出，可以防止某层中的文件在镜像组装时静默冲突的那类损坏。

| 你想更改… | 编辑… | 由谁应用 | 机制 |
| :------------------ | :---- | :--------- | :-------- |
| Linux 内核（驱动、SoC） | `msm89xx/patches/NNN-*.patch` | 内核构建（quilt） | 逐字复制到 `openwrt/target/linux/msm89xx/patches` |
| OpenWrt 树本身（罕见） | `openwrt-patches/*.patch` | `build.sh` | `patch -p1`（dry-run 守卫） |
| 上游 OpenWrt 包（hostapd、mac80211/wcn36xx、libqmi 等） | `openwrt-overlay/package/&lt;feed&gt;/&lt;pkg&gt;/patches/NNN-*.patch` | `build.sh` | `cp -a openwrt-overlay/. openwrt/` |
| 发布新程序 / LuCI 应用 | `packages/&lt;name&gt;/` | `build.sh` | 复制到 `openwrt/package/msm8916/` |
| 镜像内容 / 默认值 / 包选择 | `msm89xx/base-files/`、`msm89xx/Makefile`、`msm89xx/image/`、`diffconfigs/` | 镜像构建 | 复制 / 编译进去 |

**`build.sh` 强制执行的三个不变量：**

1. **`cp -a` 从不删除。** `openwrt-overlay/` 用 `cp -a` 合并，它*覆盖*但从不移除。你从 `openwrt-overlay/` 重命名或删除的补丁，旧文件会留在 `openwrt/` 中，直到你手动删除。（参见 `PATCHES_AND_PACKAGING.md` §2。）因为覆盖层合并无法移除文件，删除 `openwrt/` 中的陈旧副本是每次覆盖层移除的必需部分。
2. **BSP 漂移是致命的。** 同步后，`build.sh` 运行 `assert_bsp_synced()`，对 `msm89xx/` 和 `packages/` 与实时的 `openwrt/` 树做 `diff -rq`。任何分歧都会中止构建 —— 缺少补丁的实时树会静默产生错误的内核。运行 `./build.sh guard [--deep]` 检查。
3. **补丁树变更强制重新准备。** `ensure_prepared()` 通常在 `.builder-state` 已记录当前 OpenWrt 版本时走快路径：它只重新同步 BSP，跳过 `openwrt-prepare.sh` —— 后者才是应用 `openwrt-patches/` 并合并 `openwrt-overlay/` 的地方。这意味着在任一树中新增或编辑的补丁曾被后续构建静默忽略。`.builder-state` 现在也记录 `TREE_SHA`，即 `openwrt-patches/` + `openwrt-overlay/` 的内容哈希；如果不再匹配，快路径被拒绝，完整准备重新运行。（早于 `TREE_SHA` 的状态文件无法证明同步，所以它也会触发一次重新准备 —— 仅一次。）

**diffconfig 守卫**额外强制执行：(a) `=m` 内核模块块在所有板卡间*相同*，且 (b) 没有 diffconfig 选择已在 `DEFAULT_PACKAGES`（在 `msm89xx/Makefile` 中）的包。分歧在构建开始前就被拒绝。

---

## 4. 构建与发布脚本（辅助脚本）

这些都在**宿主机**上运行，除非另有说明。它们通过 shell 进入 Docker 容器进行实际编译。

| 脚本 | 运行于 | 作用 |
| :----- | :------ | :--- |
| `build.sh` | 宿主机 | **编排器。** 管理 Docker builder，在固定版本克隆/检出 OpenWrt 树，同步 BSP，运行守卫，并在容器内调用 `make`。子命令：`help`、`list`、`version`、`image`（构建 Docker 镜像）、`prepare [--force]`、`guard [--deep]`、`shell`（交互式容器）、`build &lt;board\|all&gt;`、`rebuild &lt;board\|all&gt;`（干净构建）、`kernel [board]`、`package &lt;name\|path&gt; [board]`、`kmod &lt;name&gt; [board]`、`menuconfig &lt;board&gt;`、`saveconfig &lt;board&gt;`。 |
| `scripts/openwrt-version.sh` | 宿主机 | **版本管理器。** 读/写 `devenv/.env`（`OPENWRT_VERSION`）。决定 `openwrt/` 检出于哪个 OpenWrt 标签/分支。从不克隆，从不碰 Docker。由 `build.sh version` 委派。 |
| `scripts/openwrt-prepare.sh` | **容器内** | **树准备器。** 安装 `msm89xx` 目标 + 项目 `packages`，应用 `openwrt-overlay/`（`cp -a`），应用 `openwrt-patches/`（`patch -p1`），更新/安装 feeds，应用兼容性修复，记录准备状态。从不克隆，从不读 `.env`，从不调用 Docker。 |
| `sync-version.sh` | 宿主机 | **发布版本 SSoT。** 提升 `version` 文件并重写每个 `diffconfigs/*` 中的 `CONFIG_VERSION_*` 块，使刷写的系统报告正确的版本。 |
| `build-recovery.sh` | 宿主机（无容器） | 构建每个板卡的恢复/救援镜像 → `msm89xx/recovery/&lt;board&gt;.img` = 板卡的**生产内核**（从其 `-squashfs-boot.img` 中取出）+ 以 `msm89xx/recovery/irfs` 作为 ramdisk 的 gzip cpio。不编译任何内核。 |
| `devenv/Dockerfile` | 构建时 | 定义 `devenv-builder` 镜像：`ubuntu:22.04` + 所有 OpenWrt 构建依赖（`dependencies.sh`）+ 一个非 root 的 `builder` 用户，其 UID/GID 与宿主机匹配。 |
| `devenv/docker-compose.yml` | 宿主机 | 定义 `builder` 服务；将仓库 bind-mount 到 `/repo`；工作目录 `/repo/openwrt`；主机网络。 |
| `devenv/dependencies.sh` | 构建时（镜像内） | `apt-get` 安装烘焙进镜像的每个工具链/构建依赖。 |
| `devenv/.env` | 宿主机 | `OPENWRT_VERSION=v25.12.5` —— `openwrt-version.sh` 消费的版本固定值。 |

> **运行时（设备）脚本是另一个类别。** *发布进*镜像的脚本 —— 例如 `msm89xx/base-files/etc/diag.sh`、`lib/himi-ok.sh`、`usr/sbin/wifi-sta-dhcp.sh`、`msm89xx/image/flash.sh`、`msm89xx/recovery/fetch-device-blobs.sh` 以及 `packages/*/files/*.sh` —— 在镜像构建时复制到 rootfs，并在**设备**上运行，而不是构建期间。它们不是构建辅助工具。

---

## 5. Docker 分离 —— 宿主机与容器的边界

这是项目中最不明显的一部分，所以它有自己的章节。

~~~
 宿主机                        DOCKER 容器（devenv-builder）
 +---------------------------+    +------------------------------------------+
 |  repo  (msm8916-openwrt…) |    | 镜像: ubuntu:22.04 + 工具链依赖           |
 |   |- build.sh  -----------|--->| 服务: builder（容器 openwrt-builder）     |
 |   |- msm89xx/  packages/  |    | 挂载:  ..  -->  /repo   （整个仓库）      |
 |   |- openwrt/  (树)       |<---| 工作目录: /repo/openwrt                  |
 |   '- devenv/              |    | 用户: HOST_UID:HOST_GID（非 root）       |
 +---------------------------+    | 网络: host                               |
         只需要:                 | 运行:  make -jN  （所有编译）             |
         docker + git            +------------------------------------------+
~~~

**它是如何工作的：**

- 宿主机只需要 **Docker + git**。不需要编译器，不需要 OpenWrt 工具链。
- `devenv/docker-compose.yml` 从 `devenv/Dockerfile`（Ubuntu 22.04 + `dependencies.sh` 中的依赖）构建 `devenv-builder` 镜像。
- **整个仓库**被 bind-mount 进容器的 `/repo`（`volumes: - ..:/repo`，其中 `..` 是仓库根目录，因为 compose *context* 是仓库根目录）。因此 OpenWrt 树在容器内显示为 `/repo/openwrt`，即容器的工作目录。
- `build.sh` 在宿主机上运行。对于每个构建步骤，它通过 `docker compose exec builder …`（`docker_exec` 辅助函数）shell 进入容器。**所有 `make`/`patch`/`cp` 工作都在容器内完成。**
- 容器以**一个 UID/GID 等于宿主机用户的非 root 用户**运行（`HOST_UID`/`HOST_GID`，默认从 `id -u`/`id -g` 取得）。这就是为什么构建期间在 `/repo/openwrt` 下写入的文件回到宿主机时所有权正确 —— 无需 `sudo` 清理。
- 网络是 **host** 模式，以便容器能获取 OpenWrt feeds/源码。

**为什么存在这种分离：**

1. **可复现性。** 每个开发者和 CI 使用*相同的* Ubuntu 22.04 + 固定依赖集，所以“在我机器上能行”的构建失败消失。
2. **隔离。** OpenWrt 构建具有侵入性（写入数 GB、需要特定工具）；它留在临时容器内，绝不污染宿主机。
3. **OpenWrt 树是挂载点，不是副本。** 因为 `openwrt/` 是 bind-mount 的仓库子目录，构建输出立即在宿主机可见，并且自然被 git 排除（它是构建产物）。

**心智捷径：** *你在宿主机编辑，`build.sh` 在容器内构建，容器通过 `/repo` 挂载点把输出写回宿主机的 `openwrt/`。*

---

## 6. 一次端到端构建

~~~
./build.sh build hmuf02v5
        | (宿主机)
        |- ensure_builder()        docker compose up -d builder
        |- openwrt-version.sh      从 devenv/.env 读取 OPENWRT_VERSION
        |- ensure_openwrt()        在该版本克隆 / 检出 openwrt/
        |- prepare_tree()  -------> (容器) openwrt-prepare.sh
        |                             - 安装 msm89xx 目标 + packages
        |                             - cp -a openwrt-overlay/  -> openwrt/
        |                             - patch -p1 openwrt-patches/*.patch
        |                             - ./scripts/feeds update/install
        |- sync_bsp()  -----------> (容器) cp -a msm89xx  -> openwrt/target/linux/
        |                             cp -a packages -> openwrt/package/msm8916
        |                             assert_bsp_synced()   (diff -rq 守卫)
        |- prepare_config()        复制 diffconfigs/hmuf02v5 -> openwrt/.config
        |- run_openwrt_make() ----> (容器) make -jN  ->  openwrt/bin/targets/…
        '- 镜像 + 包落入 openwrt/bin/  （通过 /repo 在宿主机可见）
~~~

选择性子命令（`kernel`、`package`、`kmod`）复用相同的 `ensure_prepared` → `sync_bsp` → `make &lt;target&gt;` 路径，但在相关的 `make` 目标处停止，而不是完整镜像。

---

## 7. 想找什么看哪里

| 我想要… | 阅读 |
| :---------- | :--- |
| 运行构建 / 了解 `build.sh` 标志 | [BUILD_SYSTEM_GUIDE.md](BUILD_SYSTEM_GUIDE.md) |
| 知道变更属于哪个目录 | [PATCHES_AND_PACKAGING.md](PATCHES_AND_PACKAGING.md) |
| 理解 BSP 作为事实来源 | [msm8916-openwrt-build-flow.md](msm8916-openwrt-build-flow.md) |
| 理解 Docker builder | [Docker/README.md](Docker/README.md) |
| 查看每个补丁的目录 | [Patches/README.md](Patches/README.md) |
| 提升发布版本 | `sync-version.sh`（§4）+ `version` 文件 |
| 构建恢复镜像 | `build-recovery.sh`（§4） |

---
*撰写于 2026-10-25。反映截至提交 `79d102e`（guard-the-patch-tree）的 `build.sh` 和固定树 `v25.12.5`。*
