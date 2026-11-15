> 📄 本文件是 [PATCHES_AND_PACKAGING.md](PATCHES_AND_PACKAGING.md) 的英文原文中文译本，内容以英文版为准。

# Patch 与打包 —— 完整地图

*该固件的每一处改动是如何组织的、每种改动住在哪里，以及你自己如何添加一个
改动。基于 2026-10-25 时的树撰写。*

wiki 上有一份通俗版本（*The Patches Explained*）；本文档是你据以实现的
参考。

---

## 1. 全景：四类改动，四个归宿

| 你想修改… | 编辑… | 由谁应用 |
|---|---|---|
| Linux kernel（驱动、SoC 代码） | `msm89xx/patches/NNN-*.patch` | kernel 构建（quilt） |
| mac80211 backports 树（Wi-Fi 驱动：wcn36xx……） | `openwrt-overlay/package/kernel/mac80211/patches/ath/NNN-*.patch` | mac80211 package 构建（quilt） |
| 一个上游 OpenWrt package（hostapd……） | `openwrt-overlay/package/<feed-path>/patches/NNN-*.patch` | 该 package 的构建（quilt） |
| OpenWrt 树本身（罕见） | `openwrt-patches/*.patch` | `build.sh`（`patch -p1`，有 dry-run 守卫） |
| 发布一个新程序/应用 | `packages/<name>/` | 由 `build.sh` 复制到 `package/msm8916/` |
| 镜像（文件、默认值、package 选择） | `msm89xx/base-files/`、`msm89xx/Makefile`、`msm89xx/image/`、`diffconfigs/` | 镜像构建 |

绝不要在 `openwrt/` 内部编辑任何东西 —— 那个目录是构建产物（被 git
忽略）。`build.sh` 每次运行都会把被跟踪的源码重新同步进去，所以只在
`openwrt/` 内部做的改动会被悄悄丢失。

---

## 2. `build.sh` 如何把它串起来

`./build.sh build <board>` 在一个 Docker 构建器内运行。在 `make` 之前，
同步步骤会把被跟踪的源码复制进树中：

1. `rm -rf openwrt/target/linux/msm89xx` 然后 `cp -a msm89xx` —— 整个
   target（patch、base-files、image makefile、config）。
2. `rm -rf openwrt/package/msm8916` 然后 `cp -a packages` —— 我们的
   package。
3. 对每个 `packages/*/patches/`，复制到 `openwrt/package/system/<name>/patches/`
   下对应的上游 package 中。
4. `cp -a openwrt-overlay/. openwrt/` —— **合并**（不删除），于是
   overlay 文件会追加或遮蔽树中的文件。mac80211 和 hostapd 的 patch
   目录就是这样进去的。
5. `openwrt-patches/*.patch` 用 `patch -p1` 应用，每个都先做 dry-run，
   这样一个过期的 patch 不会破坏构建。

⚠ **合并从不删除。** 如果你*重命名或移除*了 `openwrt-overlay/` 中的
一个 patch，旧文件会留在 `openwrt/` 中，而 quilt 会应用两份副本 ——
第二次应用会以 `Hunk #1 FAILED` 失败，构建死在 mac80211 的准备步骤。
重命名/移除之后，手工从已准备的树中删除过期副本：

```sh
rm openwrt/package/kernel/mac80211/patches/ath/<old-name>.patch
```

（相反的情况是安全的：overlay 中的*新*文件会简单地出现在树中，而*被
编辑*的文件会被同步覆盖。）

`./build.sh guard [--deep]` 会验证在线的树是否仍与被跟踪的源码一致 ——
当一次构建的表现像是在使用旧的 patch 集时，就运行它。

---

## 3. Kernel patch（`msm89xx/patches/`）

本项目共有 53 个 patch，编号为 `8xx`（`9xx` 范围预留给通用修复）。
它们是针对 kernel 源码的普通 quilt 格式 patch；kernel 构建会按名称顺序
应用该目录中的所有内容。

约定：

- 每个 patch 只关心一件事，命名为 `NNN-area-subsystem-what.patch`
  （例如 `826-remoteproc-q6v5-mss-msm-subsys-restart.patch`）
- 头部带有真实的 `Subject:` 和解释**为什么**的正文，并附上证据
  （崩溃签名、实测行为）—— 这些就是审计轨迹
- 板卡专属的 patch 必须在运行时门控（`of_machine_is_compatible`）或
  按 device-tree 是否存在来门控，绝不能通过编辑另一块板卡的 DTS 来实现

**陷阱（两个都坑过本项目）：**

- `./build.sh kernel <board>` 是**仅编译**：它*不会*把模块安装进镜像
  root。之后刷机运行的是旧模块 —— 当改动必须到达设备时，务必做完整的
  `build.sh build <board>`。
- `msm89xx/patches/` 是驱动改动的事实来源。`openwrt/` 下的副本是重新
  生成的；在下结论之前先 `diff -r`。

### 添加一个 kernel patch

1. 在 `openwrt/build_dir/target-*/linux-*/linux-6.12.94/` 中找到该文件
   （已准备、已打 patch 的树 —— 那正是你的 patch 将要叠加的状态）。
2. 做出编辑，然后用 `git diff` 生成 patch（为什么手写 hunk 是坏主意见
   第 6 节），把路径修正为 `a/` `b/`，命名为 `NNN-...`，放进
   `msm89xx/patches/`。
3. 验证：`cd <prepared tree> && patch -p1 --dry-run --fuzz=0 < your.patch`
   **以及** `git apply --check your.patch`。
4. `./build.sh build <board>`，然后确认改动已在镜像中（unsquashfs 解开
   sysupgrade bin 并检查该文件 —— 见第 8 节）。
---

## 4. mac80211 / backports patch

Wi-Fi 栈（包括 wcn36xx 驱动）**不是**从树内的 kernel 副本构建的 ——
它来自 mac80211 backports package。因此 patch 位于：

```
openwrt-overlay/package/kernel/mac80211/patches/ath/NNN-*.patch
```

它在同步时合并进 `openwrt/package/kernel/mac80211/patches/ath/`。
编号遵循 backports 自己的序列（`453`、`454`、`455`…… —— 我们的
wcn36xx 温度/HAL/survey 修复）。用于打 patch 的已准备树是
`openwrt/build_dir/target-*/mac80211-regular/backports-*/`。

约定与验证方式与第 3 节相同。

---

## 5. 针对上游 OpenWrt package 的 patch

`openwrt/package/` 下的任何 package 都可以用同样的方式打 patch ——
在 overlay 中创建 patch 目录，它就会合并进树：

```
openwrt-overlay/package/network/services/hostapd/patches/900-*.patch
```

经验法则：

- 给 patch 编号时让它在 feed 自身的 patch **之后**应用（它们从 `010`
  开始；`900` 是个安全的槽位）
- apk 风格的 pre-commit hook 以非零退出会中止事务 —— hook 必须始终
  `exit 0`
- feed 可能在你脚下升级：在 feed 更新之后检查你的 patch 是否仍能应用
  （第 3 节的 dry-run 就是这项检查）

实例：`900-wpa-cli-dispatch-ssid-temp-disabled.patch` 给
`wpa_cli_action_process()` 添加了一个 `else if` 分支，使 `wpa_cli -a`
动作脚本能够收到 `CTRL-EVENT-SSID-TEMP-DISABLED`（原厂 wpa_cli 没有
通用回退，会悄悄丢弃它）。Station 模式用该事件来报告被拒绝的密码。

---

## 6. 写出真正能应用的 patch

**生成，而不是手写。** GNU `patch` 和 quilt 对 hunk 头毫不留情；
`git diff` 则不会。可靠配方：

```sh
# work on a scratch copy of the file
mkdir -p /tmp/p/wpa_supplicant && cd /tmp/p && git init -q .
cp <prepared-tree>/wpa_supplicant/wpa_cli.c wpa_supplicant/
git add -A && git -c user.email=a@b -c user.name=t commit -qm base
# ...edit the file...
git diff > my.patch     # exact context, exact counts, trailing blank line
```

一个手写的 hunk 如果差了一行上下文或一个行数，即使字节看起来完全相同，
也会以 "fuzz" 方式应用（或在 quilt 的 `--fuzz=0` 下失败）。用
**两者**验证：

```sh
patch -p1 --dry-run --fuzz=0 < my.patch
git apply --check my.patch
```
---

## 7. 我们自己的 package（`packages/`）

一个 package 是一个带有 `Makefile` 和待安装文件的目录：

```
packages/luci-app-wifi-sta/
├── Makefile            # package definition
├── htdocs/             # LuCI JS/CSS  -> /www/
└── root/               # -> / (etc, usr, ...)
```

两种 Makefile 风格：

- **LuCI 应用**：`include $(TOPDIR)/feeds/luci/luci.mk`，配合
  `LUCI_TITLE`、`LUCI_DEPENDS`、`PKG_VERSION`（见
  `packages/luci-app-wifi-sta/Makefile`）。
- **普通 package**：`include $(TOPDIR)/rules.mk`，配合 `PKG_NAME`、
  `PKG_VERSION`，以及一个 `Build/Compile`（或构建上游源码时用
  `PKG_SOURCE*`，例如 `packages/rmtfs`）。

把 package 安装进镜像的方式是：把它们加进 `msm89xx/Makefile` 中的
`DEFAULT_PACKAGES`（每块板卡），或加进 `msm89xx/image/msm8916.mk` 中
某块板卡的 `DEVICE_PACKAGES`。diffconfig 守卫会拒绝 `diffconfigs/` 中
与 `DEFAULT_PACKAGES` 条目重复的 `=m` 行 —— 默认选中的内核模块不得
再出现在每板卡配置中。

### 添加一个 package

1. `packages/<name>/Makefile` + `root/`（或 `htdocs/`）。
2. 加进 `DEFAULT_PACKAGES`（`msm89xx/Makefile`）或 `DEVICE_PACKAGES`。
3. `./build.sh build <board>`；确认文件已落进镜像（`unsquashfs` +
   `ls`，第 8 节）。
4. LuCI 应用还需要一个 ACL 文件
   （`/usr/share/rpcd/acl.d/<name>.json`）—— 用**受限**登录验证它，
   绝不要用 root：root 的 `read '*'/write '*'` 会完全绕过 ACL。

---

## 8. 验证一个构建出的镜像（刷机前先做这个）

```sh
IMG=openwrt/bin/targets/msm89xx/msm8916/*-<board>-squashfs-sysupgrade.bin
OFF=$(grep -abo hsqs "$IMG" | head -1 | cut -d: -f1)
tail -c +$((OFF+1)) "$IMG" > /tmp/root.sqfs
unsquashfs -d /tmp/rootfs -f /tmp/root.sqfs
```

然后检查 `/tmp/rootfs` 中的实际文件（而不是 repo 中的副本）：被打过
patch 的驱动、package 文件、init 脚本、modules.d 条目。一个在 repo 里
"看起来没问题"的构建，如果同步或安装步骤漏掉了它，刷机时仍可能写入旧的
字节。

---

## 9. Package feed（`apk`）

每个镜像都带有 `/etc/apk/repositories.d/distfeeds.list`，由构建根据两个
配置旋钮生成：

- **`CONFIG_VERSION_REPO`**（`diffconfigs/*`）—— 发布的基础 URL。⚠ 它
  **绝不能**以 `/packages` 结尾：OpenWrt 的生成器会自己追加
  `/packages/%A/<feed>/packages.adb`，所以一个结尾的 `/packages` 会让
  路径翻倍（`packages/packages/...`），于是每个 repo 都 404。正确取值：
  `https://<user>.github.io/<repo>/releases/<version>`。
- **`CONFIG_FEED_<name>`** —— 每个 feed 一行。只启用构建确实会填充的
  feed：git 无法发布空目录，所以一个空的 feed（这里是 `telephony`、
  `video`）会永远 404，`apk update` 每次运行都会警告。

结果是 5 个 repo，全部位于项目的 GitHub Pages 站点上：**targets** repo
（`targets/msm89xx/msm8916/packages/` —— kernel、kmod 和板卡专属的
package）外加标准的 **base / luci / packages / routing** feed。
`customfeeds.list` 是用户自己的扩展槽位，发布时为空。

**kmod 受 vermagic 锁定**：一个 `kmod-*` package 依赖于一个精确的
`kernel = <kver>~<hash>-r<N>`，所以为不同 kernel 构建的 feed 无法安装
它的 kmod（apk 会在 kernel 约束上失败）。`apk-key-refresh` 会对此发出
警告（它比较 `apk list -I` 与 `apk list -a`）—— 只警告，从不阻断。

⚠ overlay 从不删除：如果一台设备从较旧的镜像带来过期的
`/overlay/upper/etc/apk/repositories.d/*.list`，它会遮蔽修好的文件 ——
删除它并重启。

### 用 `--allow-untrusted` 安装本地构建 —— 升级陷阱

当你在把本地构建的 `.apk` 发布到 feed 之前就对它做冒烟测试时，你会用
`apk add --allow-untrusted ./pkg.apk` 安装它。这能工作，但它会把该
package 记录为**没有仓库来源**。后果是：

- `apk upgrade` 和 `apk add <pkg>`（正常路径，也是 LuCI 的
  *Software → Upgrade* 按钮所调用的）**不会**替换它。apk 认为已安装的
  副本已经满足请求，于是悄悄什么都不做 —— 尽管 `apk version -l '<'`
  仍把它列为可升级（这是一个误导性的提示，因为该比较只看版本、忽略
  出处）。
- LuCI 的升级按钮调用 `apk` 时*不带* `--available`，于是它同样地空
  操作：用户看到"已是最新" / 什么也没发生。

**修复 —— 强制切换到 repo 中的版本：**

```sh
apk update
apk upgrade --available <pkg>...
```

`--available` 会告诉 apk 升级到已配置仓库中存在的版本，即使已安装的
副本来自本地 / `--allow-untrusted` 来源。运行过一次之后，该 package
现在带上了正确的 feed 出处，**今后**由 CI 发布的版本提升就能通过
`apk upgrade` 和 LuCI 正常升级。

**测试的经验法则：** `--allow-untrusted` 只用于快速的本地冒烟测试。
在把一个 package 视为"已升级"之前 —— 或在把设备交给 LuCI 驱动的升级
之前 —— 用 `apk upgrade --available` 把它重新同步到 feed（或直接从
feed `apk add` 它）。如果你打算之后通过 LuCI 升级设备，绝不要让设备
停留在仅有 `--allow-untrusted` 的状态。

---

## 10. Commit 流程

1. 在 `test/<topic>` 上工作（绝不要在 `main`）。
2. 每个 commit 只关心一件事；commit message 说明证据（测量了什么、在哪
   块板卡上）—— 这些 message 就是审计轨迹。
3. `git merge --no-ff` 进 `staging-main` 并推送 `staging-main`。
4. `main` 受分支保护：要在那里落地一个改动，用基于 `origin/main` 的
   最小 PR（cherry-pick）并 `gh pr merge --admin` —— GitHub 拒绝自我
   批准，所以普通合并会被阻止。
5. 在同一个 commit 系列中更新 `Docs/` 下对应的文档；wiki 得到通俗版
   摘要。
