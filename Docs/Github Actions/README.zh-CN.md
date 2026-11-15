> 📄 本文件是 [README.md](README.md) 的英文原文中文译本，内容以英文版为准。

# GitHub Actions CI/CD —— 架构与运维指南

本项目如何通过 GitHub Actions 构建固件、发布软件包并交付热修复。

一切都在 GitHub 托管的 Ubuntu runner 上运行。没有自托管基础设施，除两处
之外没有任何状态：

- **GitHub Releases** —— 不可变的固件镜像，供人们下载刷写。
- **`gh-pages` 分支** —— 一个作为网站发布的 git 分支，地址为
  `https://akbar-npj.github.io/msm8916-openwrt`，设备用 `apk` 读取。

本文档中的其余内容都是围绕这两处的记账工作。

---

## 1. 三条流水线

共有六个 workflow 文件，但实际能*做*的事情只有少数几种：

| 流水线 | Workflow | 构建内容 | 发布到 | 大约耗时 |
|---|---|---|---|---|
| **固件** | `build-and-release.yml` | 每块板的镜像 + 整个 feed | 一个**测试** GitHub Release + `releases/<version>` | 30-45 分钟 |
| **晋升** | `promote-release.yml` | 什么都不构建——只是移动测试构建已发布的内容 | `releases/<base>`、根 `firmware.json`、`latest` | 约 1 分钟 |
| **软件包** | `publish-package.yml` | 一个软件包 | 共享的 `gh-pages` feed | 7-35 分钟 |
| **热修复** | `publish-package.yml`（`scope=revision`） | 一个软件包 | 该镜像自己的 feed 目录 + `hotfix.json` | 7-35 分钟 |
| **内核模块** | `publish-kmod.yml` | kernel + 所选 `kmod-*` | 目标 feed | 20-40 分钟 |

四条构建流水线形态相同：**构建产物 -> 签名软件包索引 -> 推送到设备查找的
位置。** 区别只在于*构建什么*以及落入*哪个目录*。固件构建会落入**测试**
目录，而 `promote-release.yml` 负责把它送到设备面前——见第 2 节。

### 产物落在哪里

```text
GitHub Releases
  v25.12.6-r4/
    <board>-squashfs-boot.img, -system.img, -sysupgrade.bin, -firmware.zip
    recovery-*.img, kmods-msm8916-<version>.tar.gz, sha256sums

gh-pages branch  (served as https://akbar-npj.github.io/msm8916-openwrt)
  firmware.json                                  <- update manifest, all boards
  public-key.pem                                 <- stable feed signing key
  releases/25.12.6/                              <- SHARED by every 25.12.6 device
    packages/aarch64_generic/{base,luci,packages,routing}/
    targets/msm89xx/msm8916/packages/            <- kernel + kmod-*
  releases/25.12.6-r4/                           <- ONLY devices running r4
    ...same layout...
    hotfix.json                                  <- fixes offered to r4 devices
```

### 两种 feed 作用域

这是最值得内化的部分：

```text
releases/25.12.6/       every device on the 25.12.6 base reads this
                        written by: full releases, and package builds (scope=base)

releases/25.12.6-r4/    only devices running exactly r4 read this
                        written by: hotfix builds (scope=revision)
```

针对镜像 X 编译的修复绝不能到达镜像 Y，这就是热修复拥有自己目录的原因。
*软件包*通常是体系结构无关的，因此可以安全地放入共享目录，触达该基线版本
上的每一台设备。

### 我需要哪条流水线？

- 改了 kernel、驱动、板卡配置或镜像内容 -> **固件构建**。
- 修了 shell 脚本或某个 LuCI 页面 -> **软件包构建**。
- 修了只应触达已运行此确切镜像的设备的东西 -> **热修复构建**。
- 新增或修改了内核模块 -> **内核模块构建**。

---

## 2. 固件构建 —— `build-and-release.yml`

由推送标签（`v*`）或从 Actions 页面手动触发。

```yaml
jobs:
  setup:    # resolve tag / version / feed base + the board matrix
  build:    # one runner per board, in parallel
  publish:  # assemble artifacts, publish the feed, cut the release
```

### 输入

| 输入 | 默认值 | 说明 |
|---|---|---|
| `release_tag` | 由 `version` 推导 | `v25.12.6-r4` |
| `boards` | 空 = 全部八块板 | 空格分隔，用于定向修复发布 |

### 并发

```yaml
concurrency:
  group: release-build
  cancel-in-progress: false
```

发布是串行化的：每次运行都会重写共享的 `gh-pages` feed 和 `firmware.json`，
因此两个重叠的运行会互相踩踏。`cancel-in-progress` 为 **false**，这样排队
中的发布会等待，而不是被后来的调度杀掉。

> **一次只调度一个发布。** GitHub 每个并发组只保留**一个待运行**，因此第三次
> 调度会静默取消排队的那一个，而且绝不会显示为失败。再次调度前请先检查
> `gh run list`。

### Job `setup`

1. 读取 `version`（`25.12.6-r4`），通过去掉 `-rN` 后缀推导 `base`。设备读取
   `releases/<base>`，因此该路径也必须发布。
2. 解析标签：输入值，否则是推送的标签，否则 `v<version>`。
3. 把 `boards` 变成 JSON 矩阵。为空表示 `diffconfigs/*` 中的每一项；未知
   板名会立即失败并列出有效项。

### Job `build` —— 每块板一个 runner

`fail-fast: false`，因此一块板坏掉不会取消其余七块。

| 步骤 | 作用 |
|---|---|
| Checkout | `fetch-depth: 0` 以获取标签元数据 |
| 释放磁盘 | 删除 .NET/MySQL/PHP/Android SDK，找回约 35 GB |
| 恢复缓存 | 仅 `actions/cache/restore` —— 见第 8 节 |
| 准备 + 密钥 | `./build.sh prepare`，然后把 `APK_SIGNING_KEY` 写入 `openwrt/private-key.pem` |
| 构建 `<board>` | `./build.sh build <board>` |
| CUPS | 仅第一块板——软件包 feed 是目标级的，不是按板的 |
| 保存缓存 | 仅第一块板 |
| 上传 | `board-<name>` 制品，外加第一块板的 `feeds` |

签名密钥写在 `prepare` **之后**：全新的 prepare 会克隆 OpenWrt 树，如果
事先放好 `private-key.pem` 会被删掉。

### Job `publish`

唯一会写入任何公开内容的 job。

| 步骤 | 作用 |
|---|---|
| 下载制品 | 重新组装每块板 + 软件包 feed |
| 冻结的恢复镜像 | 从 `v25.12.6-r4` 原样重新附加（它们内嵌了被 git 忽略的固件） |
| Kmod 打包 + 校验和 | `kmods-msm8916-<version>.tar.gz` 和 `sha256sums` |
| 合并校验和 | 拼接进已发布的文件——见下文 |
| `firmware.json` | 合并进已发布的清单 |
| Feed -> gh-pages | 只写 `releases/<version>` —— 测试构建绝不触碰 `releases/<base>` |
| GitHub Release | 附上每个镜像和校验文件，作为 **prerelease** |

**为什么合并很重要。** 一次定向发布（`boards=uf02 uz801`）只构建两块板。
清单和校验文件为全部八块板共享，因此两者都是下载、编辑、重新上传，而不是
重新生成——否则另外六块板会从发布元数据中悄悄消失。

**为什么测试构建不碰共享 feed。** `releases/<base>` 是每台设备读取的路径，
而 feed 目录是追加式的（`keep_files: true`），因此往那里发布的构建会再加
一代 kernel——而裁剪到新的 vermagic 会删掉生产环境设备仍然需要的 kmod。
测试构建只写 `releases/<version>`，根 `firmware.json` 仍指向上一个发布，
因此不会有任何设备被提供升级。

### 晋升 —— `promote-release.yml`

发布的后半程：`workflow_dispatch`，带 `tag` 和 `dry_run`。

1. 验证标签存在、是 **prerelease**、不是 draft，并且至少带八个附件。
2. 把 `releases/<version>` 复制到 `releases/<base>`，并裁掉新构建没有产出的
   每个 `kernel-*.apk` / `kmod-*.apk` —— `apk list -a` 按索引顺序而非版本
   顺序打印，因此残留的一代会让设备以为自己的 kernel 缺失。
3. 把该清单作为根 `firmware.json` 发布，这是设备最先询问的文件。发布就是
   在这一刻变得可见的。
4. 把 GitHub release 翻转为 `--latest` 并去掉 "(test build)" 标题。

它不重新构建任何东西；只移动测试构建已经发布的内容。**只有在镜像已在硬件
上启动之后**才执行 promote——这正是拆分成两步的意义所在。

### 发布产物

| 文件 | 用途 |
|---|---|
| `*-squashfs-boot.img` | 启动镜像（kernel + DTB）—— fastboot / EDL |
| `*-squashfs-system.img` | 只读 SquashFS rootfs —— fastboot / EDL |
| `*-squashfs-sysupgrade.bin` | sysupgrade 归档 —— LuCI 或 CLI |
| `*-firmware.zip` | 完整固件 + 分区脚本 —— 救砖 |
| `kmods-msm8916-<version>.tar.gz` | 目标 feed 的离线副本 |
| `recovery-<board>.img` | 冻结的救援镜像，用于有恢复分区的板 |
| `sha256sums` | 以上所有内容的校验和 |

---

## 3. 软件包构建 —— `publish-package.yml`

一个软件包，不构建镜像，不重启。这就是修复在不重新刷写的情况下触达设备的
方式。

```sh
gh workflow run publish-package.yml --ref main -f package=msm89xx-scripts
# on the device:  apk update && apk upgrade msm89xx-scripts
```

### 输入

| 输入 | 默认值 | 说明 |
|---|---|---|
| `package` | — | `packages/` 下的目录名 |
| `base` | 来自 `version` | feed 基线，即 `25.12.6` |
| `bump` | `true` | 递增 `PKG_RELEASE`；没有它设备会看到相同版本而什么都不做 |
| `board` | `hmuf02v5` | 只对 `kmod-*` 有意义，它们受 vermagic 锁定 |
| `target_package` | `false` | 用于构建进 target 的软件包（例如 `base-files`） |
| `pkg_release` | — | target 软件包的显式 release |
| `skip_kernel` | `false` | 对没有内核模块的软件包跳过内核树 |
| `scope` | `revision` | `revision` = 仅该镜像，`base` = 基线上的每台设备 |
| `delete` | — | 要从 feed 中删除的 `.apk` 文件 |
| `hotfix_title` | — | 非空即把它变成热修复——见第 4 节 |
| `hotfix_restart` | — | 安装后要重启的 init 脚本 |

### 它做什么

| 步骤 | 作用 |
|---|---|
| Resolve | 校验软件包和 feed 基线 |
| Bump | `PKG_RELEASE` += 1（除非 `bump=false`） |
| Prepare | Docker 镜像 + OpenWrt 树 |
| **获取已发布的 feed** | 从 `gh-pages` 恢复 `releases/<base>` 到 `openwrt/bin/` |
| Build | 只构建该软件包 |
| 重新索引 + 重新签名 | 重新生成 `packages.adb` 并用 `APK_SIGNING_KEY` 签名 |
| Verify | 如果软件包数量减少则拒绝发布 |
| Publish | 复制进 `gh-pages` 并推送 |

### 为什么要先恢复 feed

`make package/index` 索引的是**构建树中现有的内容**。在全新树上那恰好只有
一个软件包，因此它产出的索引只会描述一个软件包，其他每个软件包都会从每台
设备的 `apk search` / `apk add` 中消失。因此该 job 先下载当前已发布的
feed，把重新构建的软件包加进去，再对整体重新索引。"验证没有东西掉队"
这一步就是确保这件事确实发生了的护栏。

### 为什么要重新签名

`apk` 会用 `/etc/apk/keys/` 中的公钥校验每个 `packages.adb`。除非
`openwrt/private-key.pem` 已存在，否则 OpenWrt 每次构建都会生成**随机
密钥**，因此跳过密钥的 job 产出的 feed 会被每台设备以 `UNTRUSTED signature`
拒绝。两个 CI workflow 都会把 `APK_SIGNING_KEY` secret 写到该路径，且未
设置时直接失败。

---

## 4. 热修复构建 —— 同一个 workflow，`scope=revision`

热修复不是单独的 workflow。它是设置了两个输入的 `publish-package.yml`：

```sh
gh workflow run publish-package.yml --ref main \
  -f package=msm89xx-firmware-upgrade -f bump=false \
  -f skip_kernel=true -f scope=revision \
  -f hotfix_title="what this fixes"
```

| | 软件包构建 | 热修复构建 |
|---|---|---|
| 落入 | `releases/25.12.6/`（共享） | `releases/25.12.6-r4/`（仅该镜像） |
| 还会写入 | — | `hotfix.json` |
| 提供方式 | `apk upgrade` | `firmware-upgrade hotfix check` |

### 清单

```json
{
  "build": "25.12.6-r4",
  "hotfixes": [
    { "id": "2026-11-02-msm89xx-firmware-upgrade",
      "package": "msm89xx-firmware-upgrade",
      "version": "1.0-r13",
      "title": "...",
      "restart": [],
      "published": "2026-11-02" }
  ]
}
```

URL 就是适用版本标签，因此发布在这里的修复绝不会到达别的镜像。再次发布
相同的 `id` 会替换该条目而不是重复添加。

### 设备端

`firmware-upgrade hotfix check` 抓取 `releases/<installed version>/hotfix.json`，
将每个条目与已安装内容比较，并报告更新的那些。`hotfix apply` 从同一个
revision 目录安装它们。

有两个值得知道的坑：

- **时钟不对会让它静默失效。** `wget` 会拒绝 TLS 证书，抓取失败，命令返回
  1。现在它会记录 URL 和 `wget` 错误，并在错误看起来像 TLS 时时点名时钟，
  但如果某次检查因不明原因失败，请先检查 `date -u`。
- **该渠道无法修复自己的安装器。** 如果 bug 在 `firmware-upgrade` 本身，
  那份损坏的副本正是执行 `hotfix apply` 的那个。设备需要一次手动安装或一个
  新镜像。

### 热修复做不到的事

- 它不能改变 kernel。为某个 kernel 构建的 `kmod-*` 只能在该 kernel 上加载。
- 它不能按板限定作用域。清单按构建版本键控，而不是按设备。

---

## 5. 内核模块 —— `publish-kmod.yml`

内核模块是最棘手的情况：模块只能加载到它编译所针对的那个确切 kernel。
这个身份就是 **vermagic**，它是内核软件包版本的一部分：

```text
kernel-6.12.112~8efa871abf779b5591d7c27483980dfd-r1
              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ vermagic
```

每个 `kmod-*` 都声明 `kernel (=<version>~<vermagic>-r<N>)` 为依赖，因此来自
不同构建的模块不是"大概没问题"—— `apk` 会直接拒绝它。

vermagic 是内核配置中 `=y`/`=m` 行的 md5，因此内核配置中任何东西一变它
就变。

### Workflow

```sh
gh workflow run publish-kmod.yml --ref main \
  -f kmods="kmod-ifb kmod-sched" -f checkout_ref=v25.12.6-r4 -f dry_run=true
```

| 步骤 | 作用 |
|---|---|
| Validate | 解析 feed 基线和所请求的模块列表 |
| Prepare | Docker 镜像 + 位于 `checkout_ref` 的 OpenWrt 树 |
| 可选地 bump | `LINUX_RELEASE`，让设备看到更新的版本 |
| 获取已发布的 targets feed | 使之后的索引完整 |
| **构建 kernel** | 填充 `Module.symvers` 和已配置的树 |
| 构建模块 | 只构建所请求的 `kmod-*` |
| Verify | 每个所请求的模块确实被产出 |
| 重新索引 + 重新签名 | 重新生成并签名 `packages.adb` |
| Publish | 推送到 `gh-pages` |

`checkout_ref` 必须是产出该已发布 kernel 的那次发布。从不同的树构建会得到
不同的 vermagic，以及没人能安装的模块。`dry_run=true` 会构建并验证，但在
推送前停下——第一次请使用它。

### 精选的仅构建集合

因为 `msm89xx` 不是上游 OpenWrt target，没有上游 kmod feed 可以回退：本
项目不编译的东西就根本无法安装。

默认情况下 OpenWrt 只构建镜像中选中的 kmod 及其依赖，这使得 feed 不完整
—— 即使 README 建议过，`apk add kmod-usb-net-rtl8152` 也会失败。因此每个
`diffconfigs/<board>` 都会追加一个精选块：

```text
CONFIG_PACKAGE_kmod-usb-net-rtl8152=m
```

`=m` 就是关键所在：模块被**编译并发布进 feed**，但**不安装进镜像**。用户
按需用 `apk add <name>` 安装。

> `CONFIG_ALL_KMODS=y` 会构建一切，但每个 kmod 软件包会 `select` 它的内核
> 依赖，因此它还会把约 227 个额外的**内置**子系统（cgroups/MEMCG、
> media/DVB/V4L2、DRM + fbcon、MPTCP、NFSD、...）强塞进一个为该设备精心
> 调优的 kernel。精选集合只引入适度的 USB/网络/存储子系统。

要扩展 feed，请把 `CONFIG_PACKAGE_kmod-<name>=m` 加入
`diffconfigs/<board>`。要确认某模块已发布，请在 `packages/` 下寻找
`kmod-<name>-*.apk`。

---

## 6. 辅助 workflow

| Workflow | 触发 | 用途 |
|---|---|---|
| `build.yml` | 手动 | 构建一块板（或全部）并把镜像作为制品上传。不发布任何东西——用于回答"它还能编译吗？" |
| `tests.yml` | push、pull request、手动 | 运行 `tests/*/run.sh`（当前是 `himi-ok-guard`）。不触碰其他任何东西 |

`tests.yml` 以分支名而非 ref 作为键，因此向一个已有打开 pull request 的
分支推送只会运行一次测试套件而不是两次。

---

## 7. `gh-pages` 上的 feed

### 设备实际使用的 URL

```text
https://akbar-npj.github.io/msm8916-openwrt/releases/25.12.6/targets/msm89xx/msm8916/packages/packages.adb
https://akbar-npj.github.io/msm8916-openwrt/releases/25.12.6/packages/aarch64_generic/base/packages.adb
https://akbar-npj.github.io/msm8916-openwrt/releases/25.12.6/packages/aarch64_generic/packages/packages.adb
https://akbar-npj.github.io/msm8916-openwrt/releases/25.12.6/packages/aarch64_generic/luci/packages.adb
https://akbar-npj.github.io/msm8916-openwrt/releases/25.12.6/packages/aarch64_generic/routing/packages.adb
```

首次启动时由 `msm89xx/base-files/etc/uci-defaults/99-msm89xx-firstboot` 写入。
上游 OpenWrt feed 会并排添加进来，用于本项目不构建的软件包集合（尤其是
`telephony`）。

本树中没有 `CONFIG_VERSION_REPO` —— 这些 URL 是由那个 firstboot 脚本
逐字写死的。

### 签名密钥

OpenWrt 对每个 `packages.adb` 签名。设备会拒绝它没有对应密钥的 feed，并报
`UNTRUSTED signature`。

- **Secret：** `APK_SIGNING_KEY` 保存 EC P-256 私钥（PEM）。
- **CI：** 写入 `openwrt/private-key.pem`；secret 未设置时 job 失败。
- **镜像：** 对应的公钥内嵌在 `/etc/apk/keys/akbar-npj-v25.12.6.pem`，并由
  `99-msm89xx-firstboot` 重新创建。
- **已发布：** 复制到每个发布目录以及稳定路径
  `https://akbar-npj.github.io/msm8916-openwrt/public-key.pem`。

`apk-key-refresh` 在启动时抓取该稳定 URL，当它与磁盘上的密钥不同时安装它，
因此携带过期密钥的设备无需重新刷写即可恢复。当 feed 不再提供该设备自身
的 kernel 时它还会告警——那才是真正破坏 kmod 安装的情形。

> **轮换密钥：** 生成新的 EC P-256 密钥对，更新 secret，替换
> `msm89xx/base-files/etc/apk/keys/` 中被跟踪的公钥**以及**
> `99-msm89xx-firstboot` 中的 heredoc，然后切一个发布。

### 裁剪

每次发布之后，job 会重新克隆 `gh-pages` 并删除当前构建没有产出的每个
`kernel-*.apk` / `kmod-*.apk`。其他软件包不动，因为被热修复过的
`base-files` 必须在后续发布中存活。推送会以 rebase 方式重试：软件包
workflow 在各自的并发组下写同一个分支。

### base-files 版本下限

每个镜像都会往 `/etc/apk/world` 写入一行：

```text
base-files=1719
```

那是一把锁，也是新镜像取代热修复的方式：`apk upgrade` 不会移动被锁定的
软件包，因此刷写之后胜出的是镜像自己的数字。

**apk 比较的是数字，不是内容。** 有两个推论：

1. 用不同字节重新发布同一个数字是**静默的无效操作**。已经拥有 `1720` 的
   设备会看到"已安装"、打印 OK，而修复永远到不了。任何地方都不报错。
2. 一个携带*更低*数字的镜像永远无法取代该热修复渠道。

上游从 `COMMITCOUNT`——触及 `package/base-files` 的提交数——推导这个数字，
而它在我们的发布之间不会变动。我们构建的每个镜像都发布 `1719`，而热修复
渠道那时已经在提供 `1720`。

**下限。** `openwrt-patches/812-base-files-release-floor.patch` 把那一行替换为

```make
BASE_FILES_RELEASE_FLOOR:=1721
PKG_RELEASE:=$(shell echo $$(( ... )))
```

于是软件包版本是 `max(COMMITCOUNT, floor)`。一旦上游的计数超过下限，它会
再次接管，因此这不会让我们永久地与上游分叉。

**水位标记。** `publish-package.yml` 每次发布都会写
`releases/<base>/published-versions.json`：

```json
{ "updated": "2026-11-03", "packages": { "base-files": "1720~981c978eff" } }
```

它每次运行都从零重建——先是 `gh-pages` 上已有的每个 `hotfix.json`，然后是
现有文件，然后是本次构建——版本最高者胜出。因此它在第一次运行时自我播种，
且绝不会向后移动。

**护栏。** `build-and-release.yml` 的 `setup` job 读取该文件，如果树中的
下限并不严格高于已发布的 `base-files`，就**让发布失败**。十秒钟，在任何
runner 启动之前，而不是交付一个没人能热修复的镜像。

> 触发时，把 `openwrt-patches/812-base-files-release-floor.patch` 中的
> `BASE_FILES_RELEASE_FLOOR` 提到比已发布版本高一个，然后随发布一起提交。
> 这就是全部流程——这个数字就是要在发布时有意手工提升的。

### DRY_RUN

两个 workflow 都接受 `dry_run`：

- **`publish-package.yml`** —— 一切真实运行（构建、拼接、索引、清单、
  水位标记），该步骤打印暂存的 diff，然后在 commit 和 push 之前停下。
  没有任何东西离开 runner，因此对线上 feed 是安全的。
- **`build-and-release.yml`** —— 下限检查仍然运行并报告，但以
  `::warning::` 而非让发布失败的形式。

```sh
gh workflow run publish-package.yml --ref main \
  -f package=base-files -f target_package=true -f pkg_release=1722 \
  -f scope=revision -f hotfix_title="..." -f dry_run=true
```

---

## 8. 缓存

有三个目录被缓存，合计约 4.5 GB：

1. `openwrt/dl` —— 上游 tarball。
2. `openwrt/staging_dir/toolchain-aarch64_generic_gcc-14.3.0_musl` —— 交叉
   工具链。
3. `openwrt/staging_dir/host` —— 主机构建工具。

```yaml
- name: Restore OpenWrt Cache
  uses: actions/cache/restore@v4
  with:
    path: |
      openwrt/dl
      openwrt/staging_dir/toolchain-aarch64_generic_gcc-14.3.0_musl
      openwrt/staging_dir/host
    key: openwrt-cache-${{ needs.setup.outputs.version }}-${{ hashFiles('openwrt/feeds.conf.default', 'diffconfigs/hmuf02v5') }}
    restore-keys: |
      openwrt-cache-${{ needs.setup.outputs.version }}-${{ hashFiles('openwrt/feeds.conf.default', 'diffconfigs/hmuf02v5') }}-
      openwrt-cache-${{ needs.setup.outputs.version }}-
      openwrt-cache-
```

三条规则让这件事负担得起：

1. **密钥中不带 `${{ github.run_id }}`。** 限定于某次运行的密钥永远无法被
   恢复，于是每次运行都保存一份新的约 2.3 GB 副本。四份就填满 10 GB 预算，
   条目被驱逐，后续运行静默回退到过期前缀。
2. **矩阵中只恢复，只保存一次。** 八个并行 job 各推 2.3 GB 会在一次运行中
   打爆预算。矩阵使用 `actions/cache/restore`；只有 `first` 板的 job 运行
   `actions/cache/save`。
3. **哈希输入必须存在。** 早期某个密钥哈希了 `diffconfigs/hmu05`，一块
   已不存在的板—— `hashFiles` 对缺失路径会静默返回空哈希，于是该密钥
   恒定不变。

冷缓存下一次完整发布约 75 分钟。热缓存时，工具链和 `dl/` 在几分钟内恢复，
各板并行构建，因此墙钟时间大约等于一块板的构建时间。

---

## 9. 运维

### 切一个发布

```sh
# from main, with version already bumped in ./version
gh workflow run build-and-release.yml --ref main
sleep 15 && gh run list --workflow=build-and-release.yml --limit 1

# flash the test build on a bench unit, then:
gh workflow run promote-release.yml --ref main -f tag=v25.12.6-r7
```

### 替换预发布标签

```sh
git tag -f v25.12.6-rc1
git push origin v25.12.6-rc1 --force
```

标签推送会触发一次完整运行；同名的发布附件会被替换。

### 验证一个发布

```sh
curl -fsS https://akbar-npj.github.io/msm8916-openwrt/firmware.json | jq '.release, (.boards | keys)'
curl -fsS https://akbar-npj.github.io/msm8916-openwrt/releases/25.12.6-r4/hotfix.json | jq .
```

### 故障排查

| 症状 | 原因 |
|---|---|
| `apk update` 报 `UNTRUSTED signature` | feed 用设备没有的密钥签名——检查 `APK_SIGNING_KEY` |
| `hotfix check` 返回 1 且无输出 | 抓取失败；通常是时钟不对（`date -u`） |
| `hotfix apply` 报 `unable to select packages` | 该软件包所在的 feed 没有作为 `--repository` 传入 |
| `apk search` 几乎什么都不显示 | 索引是从一个没有先恢复的树重新生成的 |
| kmod 拒绝安装 | feed 的 kernel vermagic 与设备的 kernel 不同 |
| 排队的发布消失了 | 第三次调度替换了它——见第 2 节 |
| 新发布永远到不了设备 | 设计如此——用 `promote-release.yml` 晋升它（第 2 节） |
| `is already a production release` | 它已经被晋升过；重新切需要新版本 |
| `base-files floor is N but … is already published` | 热修复渠道已越过镜像那一行——提升 `BASE_FILES_RELEASE_FLOOR`（第 7 节） |
| `Cannot read …/published-versions.json` | 水位标记尚不存在——先发布任意一个软件包，或检查 gh-pages |

---

## 10. 文件

| 路径 | 内容 |
|---|---|
| `.github/workflows/build-and-release.yml` | 固件流水线（发布一个测试发布） |
| `.github/workflows/promote-release.yml` | 把测试过的发布晋升为正式版 |
| `.github/workflows/publish-package.yml` | 软件包 + 热修复流水线 |
| `.github/workflows/publish-kmod.yml` | 内核模块流水线 |
| `.github/workflows/build.yml` | 手动的一次性构建 |
| `.github/workflows/tests.yml` | shell 测试套件 |
| `diffconfigs/<board>` | 按板的 OpenWrt 配置，含精选 kmod 列表 |
| `msm89xx/base-files/etc/uci-defaults/99-msm89xx-firstboot` | 写入 feed URL 和密钥 |
| `msm89xx/base-files/usr/sbin/apk-key-refresh` | 密钥自愈 + kernel 检查 |
| `packages/msm89xx-firmware-upgrade/` | `firmware-upgrade`，含 `hotfix check/apply` |
| `openwrt-patches/812-base-files-release-floor.patch` | `base-files` 版本下限 |
| `gh-pages: releases/<base>/published-versions.json` | 每个软件包有史以来发布的最高版本 |
| `scripts/gen-firmware-manifest.py` | 构建 `firmware.json` |
| `build.sh` | CI 使用的本地构建驱动 |
