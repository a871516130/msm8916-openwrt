# 补丁与打包 —— 完整映射

*此固件的每个变更如何组织，每种类型住在哪里，以及如何自己添加一个。按 2026-10-25 时的树编写。*

wiki 上有此内容的通俗版（*The Patches Explained*）；本文档是你据以实现的参考。

---

## 1. 大局：四类变更，四个家

| 你想更改… | 编辑… | 由谁应用 |
|---|---|---|
| Linux 内核（驱动、SoC 代码） | `msm89xx/patches/NNN-*.patch` | 内核构建（quilt） |
| mac80211 backports 树（Wi-Fi 驱动：wcn36xx 等） | `openwrt-overlay/package/kernel/mac80211/patches/ath/NNN-*.patch` | mac80211 包构建（quilt） |
| 上游 OpenWrt 包（hostapd 等） | `openwrt-overlay/package/<feed-path>/patches/NNN-*.patch` | 该包的构建（quilt） |
| OpenWrt 树本身（罕见） | `openwrt-patches/*.patch` | `build.sh`（`patch -p1`，dry-run 守卫） |
| 发布新程序/应用 | `packages/<name>/` | 由 `build.sh` 复制到 `package/msm8916/` |
| 镜像（文件、默认值、包选择） | `msm89xx/base-files/`、`msm89xx/Makefile`、`msm89xx/image/`、`diffconfigs/` | 镜像构建 |

`openwrt/` 内不编辑任何东西 —— 该目录是构建产物（git 忽略）。`build.sh` 每次运行时重新同步受跟踪源码进去，所以只在 `openwrt/` 内做的变更会被静默丢失。

---

## 2. `build.sh` 如何把它们串起来

`./build.sh build <board>` 在 Docker builder 内运行。`make` 之前，同步步骤把受跟踪源码复制进树：

1. `rm -rf openwrt/target/linux/msm89xx` 然后 `cp -a msm89xx` —— 整个目标（补丁、base-files、镜像 makefile、配置）。
2. `rm -rf openwrt/package/msm8916` 然后 `cp -a packages` —— 我们的包。
3. 对每个 `packages/*/patches/`，复制进 `openwrt/package/system/<name>/patches/` 下匹配的上游包。
4. `cp -a openwrt-overlay/. openwrt/` —— **合并**（不删除），所以覆盖层文件添加或遮蔽树。这就是 mac80211 和 hostapd 补丁目录进入的方式。
5. `openwrt-patches/*.patch` 用 `patch -p1` 应用，每个都先 dry-run，所以陈旧补丁不能破坏构建。

⚠ **合并从不删除。** 如果你在 `openwrt-overlay/` 中*重命名或移除*补丁，旧文件会留在 `openwrt/` 中，quilt 会应用两份 —— 第二次应用以 `Hunk #1 FAILED` 失败，构建死在 mac80211 prepare 步骤。重命名/移除后，从准备好的树中手动删除陈旧副本：

```sh
rm openwrt/package/kernel/mac80211/patches/ath/<old-name>.patch
```

（反向情况是安全的：覆盖层中的*新*文件只是出现在树中，*已编辑*的文件被同步覆盖。）

`./build.sh guard [--deep]` 验证实时树是否仍匹配受跟踪源码 —— 当构建行为像用了旧补丁集时运行它。

---

## 3. 内核补丁（`msm89xx/patches/`）

53 个补丁，此项目编号为 `8xx`（`9xx` 范围保留给通用修复）。它们是针对内核源码的普通 quilt 格式补丁；内核构建按名称顺序应用此目录中的所有内容。

约定：

- 每个补丁一个关注点，`NNN-area-subsystem-what.patch`
  （例如 `826-remoteproc-q6v5-mss-msm-subsys-restart.patch`）
- 头部携带真实的 `Subject:`，正文解释**为什么**，附证据（崩溃签名、实测行为）—— 这些是审计追踪
- 板卡特定补丁必须运行时门控（`of_machine_is_compatible`）或按设备树存在性，绝不通过编辑另一板卡的 DTS

**陷阱（两者都曾烧过本项目）：**

- `./build.sh kernel <board>` 是**仅编译**：它*不*把模块安装进镜像 rootfs。之后刷写会运行旧模块 —— 当变更必须到达设备时，始终做完整的 `build.sh build <board>`。
- `msm89xx/patches/` 是驱动变更的事实来源。`openwrt/` 下的副本被重新生成；除非先 `diff -r` 检查。

### 添加内核补丁

1. 在 `openwrt/build_dir/target-*/linux-*/linux-6.12.94/` 中找到文件（准备好的、打过补丁的树 —— 那是你的补丁将应用到的状态）。
2. 做编辑，然后用 `git diff` 生成补丁（为什么手写 hunk 是坏主意见第 6 节），修复路径为 `a/` `b/`，命名为 `NNN-...`，放入 `msm89xx/patches/`。
3. 验证：`cd <prepared tree> && patch -p1 --dry-run --fuzz=0 < your.patch` **以及** `git apply --check your.patch`。
4. `./build.sh build <board>`，然后确认变更在镜像中（unsquashfs sysupgrade bin 并检查文件 —— 见第 8 节）。
---

## 4. mac80211 / backports 补丁

Wi-Fi 栈（包括 wcn36xx 驱动）**不是**从树内内核副本构建的 —— 它来自 mac80211 backports 包。补丁因此位于：

```
openwrt-overlay/package/kernel/mac80211/patches/ath/NNN-*.patch
```

它在同步时合并进 `openwrt/package/kernel/mac80211/patches/ath/`。编号遵循 backports 自己的系列（`453`、`454`、`455`、... —— 我们的 wcn36xx thermal/HAL/survey 修复）。要打补丁的准备树是 `openwrt/build_dir/target-*/mac80211-regular/backports-*/`。

与第 3 节相同的约定和验证。

---

## 5. 对上游 OpenWrt 包的补丁

`openwrt/package/` 下的任何包都可以同样打补丁 —— 在覆盖层中创建补丁目录，它就会合并进树：

```
openwrt-overlay/package/network/services/hostapd/patches/900-*.patch
```

经验法则：

- 编号补丁使其应用在**feed 自己的补丁之后**（它们从 `010` 开始；`900` 是安全槽位）
- apk 风格 pre-commit 钩子非零退出会中止事务 —— 钩子必须始终 `exit 0`
- feed 可能在下面升级：检查你的补丁在 feed 更新后仍能应用（第 3 节的 dry-run 就是检查）

实际示例：`900-wpa-cli-dispatch-ssid-temp-disabled.patch` 给 `wpa_cli_action_process()` 添加一个 `else if` 分支，使 `wpa_cli -a` 动作脚本收到 `CTRL-EVENT-SSID-TEMP-DISABLED`（原厂 wpa_cli 没有通用回退，静默丢弃它）。站点模式用该事件报告被拒绝的密码。

---

## 6. 编写真正能应用的补丁

**生成，不要手写。** GNU `patch` 和 quilt 对 hunk 头毫不留情；`git diff` 不是。可靠配方：

```sh
# 在文件的临时副本上工作
mkdir -p /tmp/p/wpa_supplicant && cd /tmp/p && git init -q .
cp <prepared-tree>/wpa_supplicant/wpa_cli.c wpa_supplicant/
git add -A && git -c user.email=a@b -c user.name=t commit -qm base
# ...编辑文件...
git diff > my.patch     # exact context, exact counts, trailing blank line
```

一个上下文行或行数差一的手写 hunk 会以“fuzz”应用（或在 quilt 的 `--fuzz=0` 下失败），即使字节看起来相同。用**两者**验证：

```sh
patch -p1 --dry-run --fuzz=0 < my.patch
git apply --check my.patch
```
---

## 7. 我们自己的包（`packages/`）

一个包是一个带 `Makefile` 和要安装文件的目录：

```
packages/luci-app-wifi-sta/
├── Makefile            # package definition
├── htdocs/             # LuCI JS/CSS  -> /www/
└── root/               # -> / (etc, usr, ...)
```

两种 Makefile 风格：

- **LuCI 应用**：`include $(TOPDIR)/feeds/luci/luci.mk`，带 `LUCI_TITLE`、`LUCI_DEPENDS`、`PKG_VERSION`（参见 `packages/luci-app-wifi-sta/Makefile`）。
- **普通包**：`include $(TOPDIR)/rules.mk`，带 `PKG_NAME`、`PKG_VERSION`，以及 `Build/Compile`（或构建上游源码时的 `PKG_SOURCE*`，例如 `packages/rmtfs`）。

包通过把它们加入 `msm89xx/Makefile` 中的 `DEFAULT_PACKAGES`（每个板卡）或 `msm89xx/image/msm8916.mk` 中板卡的 `DEVICE_PACKAGES` 安装进镜像。diffconfig 守卫拒绝 `diffconfigs/` 中复制 `DEFAULT_PACKAGES` 条目的 `=m` 行 —— 默认选择的模块也不得出现在按板卡配置中。

### 添加一个包

1. `packages/<name>/Makefile` + `root/`（或 `htdocs/`）。
2. 添加到 `DEFAULT_PACKAGES`（`msm89xx/Makefile`）或 `DEVICE_PACKAGES`。
3. `./build.sh build <board>`；确认文件落入镜像（`unsquashfs` + `ls`，第 8 节）。
4. LuCI 应用还需要一个 ACL 文件（`/usr/share/rpcd/acl.d/<name>.json`）—— 用**受限**登录验证它，绝不用 root：root 的 `read '*'/write '*'` 完全绕过 ACL。

---

## 8. 验证构建的镜像（刷写前这样做）

```sh
IMG=openwrt/bin/targets/msm89xx/msm8916/*-<board>-squashfs-sysupgrade.bin
OFF=$(grep -abo hsqs "$IMG" | head -1 | cut -d: -f1)
tail -c +$((OFF+1)) "$IMG" > /tmp/root.sqfs
unsquashfs -d /tmp/rootfs -f /tmp/root.sqfs
```

然后检查 `/tmp/rootfs` 中的实际文件（不是仓库副本）：打过补丁的驱动、包文件、init 脚本、modules.d 条目。一个在仓库中“看起来正确”的构建，如果同步或安装步骤漏掉了它，仍可能刷写旧字节。

---

## 9. 包 feed（`apk`）

每个镜像发布 `/etc/apk/repositories.d/distfeeds.list`，由构建从两个配置旋钮生成：

- **`CONFIG_VERSION_REPO`**（`diffconfigs/*`）—— 发布基 URL。⚠ 它**不能**以 `/packages` 结尾：OpenWrt 的生成器自己追加 `/packages/%A/<feed>/packages.adb`，所以尾部 `/packages` 会使路径翻倍（`packages/packages/...`），每个仓库都 404。正确值：`https://<user>.github.io/<repo>/releases/<version>`。
- **`CONFIG_FEED_<name>`** —— 每个 feed 一行。只启用构建实际填充的 feed：git 不能发布空目录，所以空 feed（此处为 `telephony`、`video`）永远 404，`apk update` 每次运行都警告。

结果是 5 个仓库，都在项目 GitHub Pages 站点上：**targets** 仓库（`targets/msm89xx/msm8916/packages/` —— 内核、kmods 和板卡特定包）加上标准 **base / luci / packages / routing** feed。`customfeeds.list` 是用户自己的扩展槽位，发布为空。

**kmods 是 vermagic 锁定的**：`kmod-*` 包依赖一个确切的 `kernel = <kver>~<hash>-r<N>`，所以为不同内核构建的 feed 无法安装其 kmods（apk 在内核约束上失败）。`apk-key-refresh` 对此发出警告（它比较 `apk list -I` 与 `apk list -a`）—— 仅警告，绝不阻塞。

⚠ 覆盖层从不删除：如果设备携带来自旧镜像的陈旧 `/overlay/upper/etc/apk/repositories.d/*.list`，它会遮蔽固定文件 —— 移除它并重启。

### 用 `--allow-untrusted` 安装本地构建 —— 升级陷阱

当你未先发布到 feed 就冒烟测试本地构建的 `.apk` 时，用 `apk add --allow-untrusted ./pkg.apk` 安装。这有效，但记录包时**没有仓库来源**。后果：

- `apk upgrade` 和 `apk add <pkg>`（正常路径，也是 LuCI 的 *软件 → 升级* 按钮调用的）**不会**替换它。apk 把已安装副本视为已满足请求并静默无操作 —— 即使 `apk version -l '<'` 仍把它列为可升级（一个误导性提示，因为该比较仅基于版本，忽略来源）。
- LuCI 的升级按钮调用 `apk` 时*不带* `--available`，所以它以同样方式无操作：用户看到“已是最新”/什么都没发生。

**修复 —— 强制切换到仓库版本：**

```sh
apk update
apk upgrade --available <pkg>...
```

`--available` 告诉 apk 升级到配置仓库中存在的版本，即使已安装副本来自本地 / `--allow-untrusted` 源。这运行一次后，包现在带有正确的 feed 来源，**未来** CI 发布的提升则通过 `apk upgrade` 和 LuCI 正常升级。

**测试经验法则：** `--allow-untrusted` 仅用于快速本地冒烟测试。在认为包“已升级”之前 —— 或把设备交给 LuCI 驱动的升级之前 —— 用 `apk upgrade --available` 把它重新同步到 feed（或简单地从 feed `apk add`）。如果你打算之后通过 LuCI 升级它，绝不要让设备停留在仅 `--allow-untrusted` 状态。

---

## 10. 提交流程

1. 在 `test/<topic>` 上工作（绝不在 `main` 上）。
2. 每个提交一个关注点；消息陈述证据（测到了什么、在哪个板卡上）—— 这些消息是审计追踪。
3. `git merge --no-ff` 进 `staging-main` 并推送 `staging-main`。
4. `main` 受分支保护：用从 `origin/main` 拉出的最小 PR（cherry-pick）在那里落地变更，然后 `gh pr merge --admin` —— GitHub 拒绝自我批准，所以普通合并被阻止。
5. 在同一提交系列中更新 `Docs/` 下匹配的文档；wiki 得到通俗版摘要。
