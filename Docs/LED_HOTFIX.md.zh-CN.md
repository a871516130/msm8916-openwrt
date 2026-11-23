# 25.12.6-r8 设备的 LED 热修复

r8 镜像不包含基于角色的 LED 功能：它仍依据 `board_name` 决定颜色，
因此某台绿色和蓝色灯接反的设备会驱动错误的灯，并且不重新构建就无法更改。

本热修复通过**签名 feed 中的两个软件包**交付整个功能。无需 sysupgrade、
无需重新刷写、无需新镜像。

| 软件包 | 版本 | 新增内容 |
|---|---|---|
| `msm89xx-scripts` | `1.0-r18` | `/etc/config/leds`、共享解析器、`led-probe`，以及重写为读取角色表的监视器 |
| `luci-app-led-setup` | `1.0-r5` | **系统 → LED 设置**：灯下拉框、按场景的模式下拉框、**Blink** 按钮，并隐藏原厂 LED 配置页面 |

两者仅发布到 r8 修订 feed（`releases/25.12.6-r8/`），
因此它们永远不会到达其他构建：

```
https://akbar-npj.github.io/msm8916-openwrt/releases/25.12.6-r8/
├── hotfix.json
└── packages/aarch64_generic/
    └── base/     # msm89xx-scripts, luci-app-led-setup
```

机制本身（页面和仪表盘横幅显示什么、为何条目在安装后会滞留）见
[`HOTFIXES_ON_DEVICE.md`](HOTFIXES_ON_DEVICE.md)。LED 功能做什么见
[`LED_SETUP.md`](LED_SETUP.md)。

## 安装

### 从 LuCI（常规路径）

**系统 → 固件升级**在下一次检查后列出这两个条目。点击 **Install**。
两个软件包在一个事务中应用；LED 监视器随后重启，
因此预期灯会闪烁大约一秒钟。

### 从命令行

```sh
firmware-upgrade hotfix check     # 该构建提供什么
firmware-upgrade hotfix apply     # 安装所有提供的内容，重启服务
```

`apply` 是幂等的：它只安装比已安装版本更新的条目，
所以在部分安装后再次运行它是安全的。

### 如果页面什么都不显示

设备会缓存 feed 索引。强制重新读取：

```sh
rm -f /var/cache/apk/APKINDEX.*
firmware-upgrade hotfix check
```

如果仍什么都不显示，可能 Pages 部署尚未完成——`.apk` 和索引一起提交到
`gh-pages`，但 GitHub Pages 发布它们会有几分钟延迟。请重试；不要重新发布。

## 验证

```sh
apk list -I msm89xx-scripts luci-app-led-setup
# msm89xx-scripts-1.0-r18 ...
# luci-app-led-setup-1.0-r5 ...

led-probe --caps          # cap<TAB>battery<TAB>0|1
led-probe --show | head   # 生效的角色表
```

`led-probe --show` 在无人配置过的设备上为每个角色打印 `auto`——
即“板级默认值”，也就是该设备在热修复前的确切行为。在你分配一盏灯之前，一切不变。

LuCI 菜单项会立即出现，但浏览器会缓存菜单树：请注销再重新登录（或硬刷新）一次。

## 修复接反的设备

这就是热修复存在的原因。受影响的设备上 Wi-Fi 灯为蓝色、LTE 灯为绿色，
但板名说的却相反。

1. 打开 **系统 → LED 设置**。
2. 在 `wifi` 行点击 **Blink** 并观察哪盏灯闪烁。
3. 将 `wifi` 设为那盏灯的标签（`green:wlan` 或 `blue:wan`），并将 `wan` 设为另一盏。
4. **保存并应用**。

从 shell 执行同样操作：

```sh
led-probe --set wifi=green:wlan wan=blue:wan
```

`led-probe --reset` 将所有角色恢复到板级默认值。

## 不改变的内容

- **无固件、无内核、无重启。** 镜像、`version` 和 `/etc/openwrt_release`
  均未改动；设备仍报告 `25.12.6-r8`。
- **`/etc/config/leds` 是 conffile。** 编辑和角色分配在后续 `msm89xx-scripts`
  的 `apk upgrade` 中得以保留。
- **电池角色保持隐藏**在报告无电池的板子上（`led-probe --caps` 可回答此问题），
  因此两块仅市电供电的板子完全不显示电池区块。
- **原厂 LED 配置页面被隐藏**当 `luci-app-led-setup` 安装时。它把
  `config led` 区块写入 `/etc/config/system`，而 `/etc/init.d/led` 将其应用到
  监视器驱动的相同 `trigger`/`brightness` 文件——两处都配置一盏灯会让页面看起来
  损坏。移除该软件包会恢复原厂页面。

## 回滚

先前构建仍留在 feed 中；这就是回滚路径。`apk` 不会就地降级——当 r18 已安装时，
`apk add msm89xx-scripts=1.0-r14` 会以 `breaks: world[msm89xx-scripts=1.0-r14]` 失败——所以先移除：

```sh
apk del luci-app-led-setup msm89xx-scripts
apk add --repository https://akbar-npj.github.io/msm8916-openwrt/releases/25.12.6-r8/packages/aarch64_generic/base/packages.adb \
  msm89xx-scripts=1.0-r14
/etc/init.d/wifi-led-monitor restart
/etc/init.d/modem-led-monitor restart
```

r14 是上一个 r8 热修复，携带旧的硬编码颜色逻辑。先记录任何角色映射：
它位于 `/etc/config/leds`，移除软件包可能将该文件一并带走。

## 为何这是热修复而不是发布

该改动完全在用户空间：shell 脚本、一个 LuCI 视图和一个 uci 配置文件。
其中不需要新内核、新设备树或重建镜像，并且这两个软件包已经是本次改动后
从 `main` 构建的每个镜像的一部分。发布镜像意味着每台设备约 40 MB 下载
和重新刷写，只为交付 `apk` 可以就地替换的文件。
