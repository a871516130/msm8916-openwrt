# 设备端热修复（Hotfix）

本文说明你在路由器上会看到的内容：LuCI 中的**固件升级
页面**以及仪表盘上的**“你的构建有可用修复”**横幅。内容涵盖热修复的来源、
为何某个修复会出现在（或从）该页面消失，以及——最实用的部分——为何修复
*在你安装后仍会列出来*，以及该如何处理。

发布热修复（维护者侧）在
[`RELEASING_FIRMWARE.md` §3.1](RELEASING_FIRMWARE.md) 中单独说明。本文档面向
设备/运维人员视角。

## 什么是“热修复”

热修复是针对你的确切固件镜像重新构建的单个软件包，并通过签名软件包 feed 推送。
它**不随新镜像 / sysupgrade 一起发布**。本项目的例子：

- `msm89xx-scripts` —— LED 监视器和 Wi-Fi 站点看门狗
- `luci-app-wifi-sta` —— 站点模式网页
- `msm89xx-firmware-upgrade` —— 升级工具 + 仪表盘横幅逻辑
- `base-files`、`kernel`、`libc` —— 固定版本；特殊处理（见下文）

每个软件包带有一个 `PKG_RELEASE`（“rN”）。热修复只是已有软件包更高的 `rN`，
例如 `msm89xx-scripts 1.0-r11`。

## 设备从哪里查找

运行 `25.12.6-r8` 镜像的设备读取自身的修订 feed：

```
https://<pages>/releases/25.12.6-r8/
├── hotfix.json                 # 该构建可用的热修复列表
└── packages/aarch64_generic/
    ├── base/packages.adb       # apk 索引（apk 可安装的内容）
    └── luci/packages.adb
```

两个文件至关重要：

- **`hotfix.json`** —— *提供什么*。固件升级页面和横幅调用
  `firmware-upgrade hotfix check`，它会下载此文件并列出所有
  **比已安装版本更新**的条目。
- **`packages.adb`** —— *实际可安装什么*。当你点击
  **Install** 时，工具会运行 `apk add pkg=version --repository <packages.adb>`。
  该版本必须存在于这个索引中，否则安装失败。

## 横幅/页面如何决定显示内容

固件升级页面仅当热修复**比已安装版本更新**时才列出它。因此：

- 已安装的热修复（例如设备上已有 `msm89xx-firmware-upgrade 1.0-r19`）
  会被**正确隐藏**——它们“已完成”。
- 尚未安装的新热修复（例如 `msm89xx-scripts 1.0-r11`）**会显示**为可用。

仪表盘横幅由 `update-notify` 提供数据，它会调用同样的检查并缓存结果到
`/tmp/hotfix-notify.json`。`update-notify` **每 6 小时**运行一次
（INTERVAL = 21600 秒），因此横幅可能比页面滞后最多 6 小时——但重启后它会立即刷新：

```sh
/etc/init.d/update-notify restart
```

页面本身实时调用检查，因此通常比横幅更新鲜。

## 安装

在固件升级页面点击 **Install**，或在命令行执行：

```sh
apk update
apk upgrade msm89xx-scripts          # 针对非固定版本软件包
# 固定版本软件包（base-files/kernel/libc）需要显式指定版本：
# apk add 'base-files=1719~981c978eff'
```

安装成功后该条目从列表中消失（它不再“比已安装版本更新”）。

## “我安装了但它仍显示”——故障排查

这是最常见的困惑点。按可能性从高到低：

### 1. 安装因 CDN 索引过期而静默失败

当 feed 被修复或重新索引后，修正后的 `packages.adb` 会被提交到
`gh-pages`，但**GitHub Pages 必须先部署**你的路由器才能获取到它。
在此之前公开的 `packages.adb` 仍列出旧版本，所以
`apk add pkg=1.0-r11` 找不到 `r11` 并**不安装任何东西直接失败**——该条目仍留在页面上。

如果 GitHub Pages 部署本身失败（例如卡在 `deployment_queued` 并超时），
也会发生这种情况。git 提交可能是正确的，而 CDN 仍提供旧文件。

**检查方法：**

```sh
apk list -I msm89xx-scripts          # 实际安装的是什么？
```

如果仍显示旧 `rN`，说明安装未生效。**解决办法：** 等待 Pages 部署完成，
然后 `apk update` 再安装一次。你可以在仓库的 *pages-build-deployment* 工作流运行中观察部署。

### 2. 横幅显示的是 6 小时前的缓存

仪表盘横幅读取 `/tmp/hotfix-notify.json`，仅由 `update-notify` 每 6 小时刷新一次。
即使安装成功，横幅也可能持续提醒直到缓存刷新。

**解决办法：**

```sh
/etc/init.d/update-notify restart    # 立即重新生成缓存
```

固件升级**页面**实时查询，所以通常先更新；请信任页面而非横幅。

### 3. 其实已经安装了（预期行为）

如果 `apk list -I <package>` 报告的是热修复版本，任务已完成——页面按设计隐藏它。
无需操作。

### 4. 卡在半安装状态

某个热修复的安装后脚本重启了服务，或某个软件包写入了一个 `apk`
无法写入的文件（例如 base-files 写入只读的 `/rom`），可能在实际安装时报告错误。
请依据已安装版本（`apk list -I`）判断，而不是退出码。

## 验证安装确实发生

```sh
apk list -I msm89xx-scripts                                 # 预期 1.0-r11
opkg ... # n/a
# 文件级检查，可检查已安装的文件：
ls -l /usr/sbin/wifi-sta-up                                # scripts 软件包
```

## 要点总结

- **页面列出** `hotfix.json` 中提供且比已安装版本更新的内容。
- **安装成功**仅当 CDN 上的 `packages.adb` 实际包含该版本。
  `hotfix.json` 和 `packages.adb` 独立部署，因此有可能*看到*一个你还不能*安装*的修复。
- `hotfix.json` **每个软件包一条条目**——最新构建，是累积性的。
  如果你看到同一软件包两条条目（例如 `msm89xx-scripts` 同时为 `1.0-r9` 和 `1.0-r14`）
  且安装失败并提示 `breaks: world[<pkg>=<oldver>]`，则旧条目是元凶：索引只携带
  最新版本，所以固定旧版本无法满足。发布工作流现在会自动丢弃旧条目；解决办法是
  将其从 `hotfix.json` 中移除（把它的 `restart` 服务合并到最新条目中）。
- 安装后条目从页面消失 = 成功；条目滞留通常意味着安装失败（CDN 索引过期）
  或横幅显示过期的 6 小时缓存。
- `apk list -I <pkg>` 是判断真相的依据。
