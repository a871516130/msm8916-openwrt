> 📄 本文件是 [HOTFIXES_ON_DEVICE.md](HOTFIXES_ON_DEVICE.md) 的英文原文中文译本，内容以英文版为准。

# 设备上的热修

本文解释你在路由器本身上看到的东西：LuCI 里的 **firmware-upgrade 页面**以及
仪表板上 **“A fix for your build is available”** 横幅。 它涵盖热修从哪里来、
为什么某个修复会（或不会）出现在那个页面上，以及——最有用的——为什么某个修复
在你安装之后*仍可能被列出*，以及该怎么办。

发布热修（维护者一侧）在
[`RELEASING_FIRMWARE.md` §3.1](RELEASING_FIRMWARE.md) 中另行介绍。 本文档是
设备/操作者视角。

## 什么是“热修”

热修是为你的确切固件镜像重新构建的单个软件包，通过签名软件包 feed 推送。
它**无需新镜像 / sysupgrade** 即可随附。 本项目的例子：

- `msm89xx-scripts` —— LED 监视器和 Wi‑Fi station 看门狗
- `luci-app-wifi-sta` —— station 模式网页
- `msm89xx-firmware-upgrade` —— 升级工具 + 仪表板横幅逻辑
- `base-files`、`kernel`、`libc` —— 固定版本；特殊处理（见下文）

每个软件包都带一个 `PKG_RELEASE`（“rN”）。 热修只是某个现有软件包更高的
`rN`，例如 `msm89xx-scripts 1.0-r11`。

## 设备去哪里找

运行镜像 `25.12.6-r8` 的设备读取它自己的修订版 feed：

```
https://<pages>/releases/25.12.6-r8/
├── hotfix.json                 # the list of available hotfixes for THIS build
└── packages/aarch64_generic/
    ├── base/packages.adb       # the apk index (what apk can install)
    └── luci/packages.adb
```

有两个文件很关键：

- **`hotfix.json`** —— *提供了什么*。 firmware-upgrade 页面和横幅调用
  `firmware-upgrade hotfix check`，它下载该文件并列出每一个版本**比已安装
  更新**的条目。
- **`packages.adb`** —— *实际能安装什么*。 当你按 **Install** 时，工具运行
  `apk add pkg=version --repository <packages.adb>`。 该版本必须存在于这个
  索引中，否则安装失败。

## 横幅/页面如何决定显示什么

firmware-upgrade 页面只在热修**比已安装版本更新**时才列出它。 所以：

- 已安装的热修（例如设备上已有的 `msm89xx-firmware-upgrade 1.0-r19`）会
  **被正确隐藏**——它们“已完成”。
- 尚未安装的新热修（例如 `msm89xx-scripts 1.0-r11`）会**出现**为可用。

仪表板横幅由 `update-notify` 供数，它调用同一个检查并把结果缓存到
`/tmp/hotfix-notify.json`。 `update-notify` **每 6 小时**运行一次
（INTERVAL = 21600 s），因此横幅可能比页面滞后最多 6 小时——但只要你重启
它就会立即刷新：

```sh
/etc/init.d/update-notify restart
```

页面本身是实时调用检查的，所以通常比横幅更新。

## 安装

在 firmware-upgrade 页面按 **Install**，或在命令行：

```sh
apk update
apk upgrade msm89xx-scripts          # for non-pinned packages
# pinned packages (base-files/kernel/libc) instead need an explicit version:
# apk add 'base-files=1719~981c978eff'
```

成功安装后，该条目会从列表中消失（它不再“比已安装更新”）。

## “我装了但它还在显示”——故障排查

这是最常见的困惑。 按可能性排序：

### 1. 因为 CDN 索引过期，安装悄悄失败了

当 feed 被修复或重新索引时，修正后的 `packages.adb` 被提交到 `gh-pages`，
但**GitHub Pages 必须先部署它**，你的路由器才能拉取到它。 在那之前，公开的
`packages.adb` 仍列着旧版本，因此 `apk add pkg=1.0-r11` 找不到 `r11`，
**在什么都没安装的情况下失败**——条目留在页面上。

如果 GitHub Pages 部署本身失败（例如卡在 `deployment_queued` 然后超时），
也会发生这种情况。 git 提交可能是正确的，而 CDN 仍在提供旧文件。

**检查它：**

```sh
apk list -I msm89xx-scripts          # what is ACTUALLY installed?
```

如果仍显示旧的 `rN`，说明安装没有生效。 **修复：** 等 Pages 部署完成，然后
`apk update` 再安装一次。 你可以在仓库的 *pages-build-deployment* workflow
运行记录里盯部署。

### 2. 横幅显示的是 6 小时前的缓存

仪表板横幅读取 `/tmp/hotfix-notify.json`，它只由 `update-notify` 每 6 小时
刷新一次。 即使安装成功之后，横幅也可能在缓存刷新前一直唠叨。

**修复：**

```sh
/etc/init.d/update-notify restart    # regenerates the cache now
```

firmware-upgrade **页面**是实时查询的，所以通常先更新；相信页面胜过横幅。

### 3. 它确实已经装好了（预期行为）

如果 `apk list -I <package>` 报告出热修版本，事情就完成了——页面按设计
隐藏它。 无需任何操作。

### 4. 卡在半安装状态

某个热修的安装后脚本重启了服务，或者某个软件包写入了 `apk` 无法写的文件
（例如 base-files 写只读的 `/rom`），都可能在实际安装的同时报错。 要按
已安装版本（`apk list -I`）判断，而不是退出码。

## 验证安装确实发生了

```sh
apk list -I msm89xx-scripts                                 # expect 1.0-r11
opkg ... # n/a
# for a file-level check, inspect the installed files:
ls -l /usr/sbin/wifi-sta-up                                # scripts package
```

## 关键要点

- **页面列出**的是 `hotfix.json` 提供的、且比已安装更新的内容。
- 只有当 CDN 上的 `packages.adb` 真正包含该版本时，**安装才会成功**。
  `hotfix.json` 和 `packages.adb` 是独立部署的，因此完全可能*看到*一个你
  还*装不了*的修复。
- `hotfix.json` 每个软件包只带**一个条目**——最新的构建，它是累积的。
  如果你看到同一软件包的两个条目（例如 `msm89xx-scripts` 同时有
  `1.0-r9` 和 `1.0-r14`），而安装以
  `breaks: world[<pkg>=<oldver>]` 失败，那么较旧的条目就是罪魁：索引只带
  最新版本，因此固定旧版本是无法满足的。 发布 workflow 现在会自动丢弃较旧
  的条目；修法是把它从 `hotfix.json` 中删掉（把它的 `restart` 服务合并进
  最新条目）。
- 安装后，条目从页面消失 = 成功；条目残留通常意味着安装失败（CDN 索引过期）
  或横幅显示的是过期的 6 小时缓存。
- `apk list -I <pkg>` 是事实来源。
