> 📄 本文件是 [LED_HOTFIX.md](LED_HOTFIX.md) 的英文原文中文译本，内容以英文版为准。

# 针对 25.12.6-r8 设备的 LED 热修

r8 镜像不包含基于角色的 LED 功能：它仍然从 `board_name` 决定颜色，因此绿灯
和蓝灯接线相反的那台设备会驱动错误的灯，而且不重建就无法更改。

这个热修通过**签名 feed 中的两个软件包**交付整个功能。 无需 sysupgrade、
无需重刷、无需新镜像。

| 软件包 | 版本 | 新增内容 |
|---|---|---|
| `msm89xx-scripts` | `1.0-r18` | `/etc/config/leds`、共享解析器、`led-probe`，以及改为读取角色表的监视器 |
| `luci-app-led-setup` | `1.0-r5` | **System → LED Setup**：灯下拉框、按场景的模式下拉框、**Blink** 按钮，并隐藏原厂 LED Configuration 页面 |

两者只发布到 r8 修订版 feed
（`releases/25.12.6-r8/`），因此它们绝不可能进入别的构建：

```
https://akbar-npj.github.io/msm8916-openwrt/releases/25.12.6-r8/
├── hotfix.json
└── packages/aarch64_generic/
    └── base/     # msm89xx-scripts, luci-app-led-setup
```

机制本身（页面和仪表板横幅显示什么、为什么安装后条目仍会残留）见
[`HOTFIXES_ON_DEVICE.md`](HOTFIXES_ON_DEVICE.md)。
LED 功能做什么见 [`LED_SETUP.md`](LED_SETUP.md)。

## 安装

### 从 LuCI（常规路径）

**System → Firmware Upgrade** 在下一次检查后会列出这两个条目。
按 **Install**。 两个软件包在一个事务中应用；随后 LED 监视器会重启，
所以灯闪大约一秒是正常的。

### 从命令行

```sh
firmware-upgrade hotfix check     # what is offered for this build
firmware-upgrade hotfix apply     # install everything offered, restart services
```

`apply` 是幂等的：它只安装比已安装版本更新的条目，因此在部分安装之后
再次运行是安全的。

### 如果页面什么都不显示

设备会缓存 feed 索引。 强制重新读取：

```sh
rm -f /var/cache/apk/APKINDEX.*
firmware-upgrade hotfix check
```

如果仍然什么都不显示，Pages 部署可能还没完成——`.apk` 和索引是一起提交到
`gh-pages` 的，但 GitHub Pages 发布会有几分钟延迟。 请重试；不要重新发布。

## 验证

```sh
apk list -I msm89xx-scripts luci-app-led-setup
# msm89xx-scripts-1.0-r18 ...
# luci-app-led-setup-1.0-r5 ...

led-probe --caps          # cap<TAB>battery<TAB>0|1
led-probe --show | head   # the role table in effect
```

在没人配置过的设备上，`led-probe --show` 对每个角色都打印 `auto`——
那表示“板子默认值”，也就是该设备在热修之前的行为。 在你分配灯位之前
什么都不会变。

LuCI 菜单项会立即出现，但浏览器会缓存菜单树：请注销再登录（或强制刷新）一次。

## 修正接线相反的设备

这正是该热修存在的原因。 在受影响的设备上 Wi‑Fi 灯是蓝色、LTE 灯是绿色，
但板子名称说的是相反的。

1. 打开 **System → LED Setup**。
2. 在 `wifi` 行按 **Blink**，看哪盏灯在闪。
3. 把 `wifi` 设为该灯的标签（`green:wlan` 或 `blue:wan`），把 `wan` 设为
   另一个。
4. **Save & apply**。

从 shell 做同样的事：

```sh
led-probe --set wifi=green:wlan wan=blue:wan
```

`led-probe --reset` 把每个角色都放回板子默认值。

## 哪些不会变

- **不动固件、不动 kernel、不重启。** 镜像、`version` 和
  `/etc/openwrt_release` 都保持原样；设备仍上报 `25.12.6-r8`。
- **`/etc/config/leds` 是配置文件。** 编辑和角色分配可挺过之后对
  `msm89xx-scripts` 的 `apk upgrade`。
- **电池角色保持隐藏**，在报告没有电池的板子上
  （`led-probe --caps` 会给出答案），因此两块仅市电供电的板子完全不显示
  电池部分。
- **原厂 LED Configuration 页面在 `luci-app-led-setup` 安装期间被隐藏。**
  它往 `/etc/config/system` 写入 `config led` 段，而 `/etc/init.d/led`
  会把它们应用到监视器驱动的同一批 `trigger`/`brightness` 文件上——在两处
  配置同一盏灯会让该页面看起来坏掉。 移除软件包会把原厂页面带回来。

## 回滚

先前的构建仍留在 feed 里；那就是回滚路径。 `apk` 不会就地降级——当 r18
已安装时，`apk add msm89xx-scripts=1.0-r14` 会以
`breaks: world[msm89xx-scripts=1.0-r14]` 失败——所以先移除：

```sh
apk del luci-app-led-setup msm89xx-scripts
apk add --repository https://akbar-npj.github.io/msm8916-openwrt/releases/25.12.6-r8/packages/aarch64_generic/base/packages.adb \
  msm89xx-scripts=1.0-r14
/etc/init.d/wifi-led-monitor restart
/etc/init.d/modem-led-monitor restart
```

r14 是上一个 r8 热修，带有旧的写死颜色逻辑。 先把角色映射记下来：
它存在 `/etc/config/leds` 里，而移除软件包可能把这个文件一起带走。

## 为什么这是热修而不是发布

这次改动完全在用户态：shell 脚本、一个 LuCI 视图和一个 uci 配置文件。
其中不需要新 kernel、新设备树或重建镜像，而且这两个软件包在此改动之后
从 `main` 构建的每个镜像里都已经是其中一部分。 发布一个镜像意味着每台设备
约 40 MB 的下载和一次重刷，只为交付 `apk` 就能就地替换的文件。
