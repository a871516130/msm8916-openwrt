# 发布固件构建

切割发布的运行手册。它涵盖分支模型、携带版本的三个文件、CI 做什么，以及如何验证 —— 或替换 —— 一个出错的发布。

关于手动构建和刷写镜像，请参阅
[构建与刷写参考](https://github.com/akbar-npj/msm8916-openwrt/wiki/Build-and-Flashing-Reference)。

---

## TL;DR

```sh
# 1. 提升发布（见 §2）-- version 文件是唯一要编辑的版本
printf '25.12.6-r4\n' > version

# 2. 描述它（见 §4）
$EDITOR RELEASE_NOTES.md

# 3. 本地检查（见 §5）
./build.sh guard
./build.sh build mifib-v12

# 4. 通过 PR 提升 -- 直接推送到 main 被拒绝（见 §6）
git checkout -b test/release-r8 origin/main && git add -A
git commit -m "release: 25.12.6-r8" && git push -u origin test/release-r8
gh pr create --base main --head test/release-r8 --title 'release: 25.12.6-r8' --body-file /tmp/pr.md
gh pr merge --merge

# 5. 构建一个 TEST 发布（见 §7）-- 预发布；不向任何设备提供
gh workflow run build-and-release.yml --ref main
gh run list --workflow=build-and-release.yml --limit 1

# 6. 在测试台上刷写它，然后提升到生产（见 §7.2）
gh workflow run promote-release.yml --ref main -f tag=v25.12.6-r4
```

---

## 1. 分支模型

| 分支 | 作用 |
|---|---|
| `test/firmware-upgrade` | 工作落点。每个提交先到这里。 |
| `staging-main` | 集成。`test` 用 `--no-ff` 合并进来。 |
| `main` | 已发布。**仅通过快进**接收 `staging-main`。CI 从这里发布。 |

快进不是装饰 —— 它是不变量：`main` 始终是 `staging-main` 的祖先，所以提升绝不会静默丢弃提交，或创建后来分叉的合并提交。两条规则保持其为真：

* 绝不在 `main` 上直接提交。其唯一提交通过从 `staging-main` 的 FF 到达。
* 如果 `main` 从别处获得提交（在 GitHub 合并的 PR、热修复），在提升前 `git merge main` **进入 `staging-main`**。把该提交 cherry-pick 到 staging 不会恢复快进：cherry-pick 是带不同父级的新哈希，所以 `main` 仍不是祖先。

```sh
git rev-list --left-right --count main...staging-main   # want: 0   0
git merge-base --is-ancestor main staging-main && echo ff_ok
```

## 2. 版本

`version`（仓库根目录）是**单一事实来源**。它保存完整发布字符串，基础加修订后缀：

```
25.12.6-r3
└──┬──┘ └┬┘
   │     └── release revision — bump this for every release, even a rebuild
   └──────── OpenWrt base version — only changes when the upstream tree changes
```

谁读它：

| 消费者 | 它取什么 |
|---|---|
| `build-and-release.yml` → `TAG` | `v$(cat version)` → git 标签和发布名 |
| `build-and-release.yml` → `BASE` | `${VERSION%-r*}` → 设备轮询的 feed 路径 `releases/<base>/` |
| `gen-firmware-manifest.py` | `version` → `firmware.json`，LuCI 升级页面比较的内容 |
| `build.sh prepare_config` | 把 `CONFIG_VERSION_NUMBER` 盖进 `.config` → `/etc/openwrt_release` → `DISTRIB_RELEASE` |

最后一行是会咬人的那个。`CONFIG_VERSION_NUMBER` 曾是所有 `diffconfigs/` 文件中手工维护的副本，r3 发布时它仍读取 `25.12.6-r2` —— 所以每个 r3 镜像*报告* r2。`firmware-upgrade` 比较设备的 `DISTRIB_RELEASE` 与 manifest，所以这样的设备永远相信自己落后一个发布，并在每次检查时重新提供同一更新。`build.sh` 现在每次构建都从 `version` 盖该值；diffconfigs 仍为可读性携带一份副本，但会被覆盖。

```sh
# any build 后，这必须等于 version 文件：
grep DISTRIB_RELEASE openwrt/build_dir/target-aarch64_generic_musl/root-msm89xx/etc/openwrt_release
```

**不要为此使用 `./build.sh version`。** 该命令管理上游 OpenWrt *基础*检出（`devenv/.env`，树固定到的上游提交）。`-rN` 后缀只属于 `version` 文件。

## 3. 包发布

文件变更的包会在其 `Makefile` 中提升 `PKG_RELEASE`，所以 `apk` 看到新版本，feed 实际替换它：

```sh
grep -rn 'PKG_RELEASE' packages/*/Makefile
```

镜像内容不依赖此（镜像从树组装），但**发布的包 feed**依赖 —— 未变的 `PKG_RELEASE` 意味着 `apk upgrade` 不会拾取新文件。每当包的 `root/` 树变更时提升它。

### 3.1 无发布的包热修复

只存在于包中的修复（`base-files` 脚本、LuCI 应用、feed 包）通过 feed 发布，而非新镜像。`version` 和 `RELEASE_NOTES.md` 保持不动：设备继续报告例如 `25.12.6-r4`。

**1. 发布它。** `.github/workflows/publish-package.yml` 用已发布的工具链重建这一个包，并把它拼接进已发布的 feed，然后重新签名索引。

```sh
# packages/ 下的包
gh workflow run publish-package.yml --ref main -f package=luci-app-foo -f bump=true

# TARGET 包（base-files）：其 PKG_RELEASE 是 $(COMMITCOUNT)，发布间不动，所以盖一个显式编号
gh workflow run publish-package.yml --ref main \
  -f package=base-files -f target_package=true -f pkg_release=1719
```

`target_package` 也会重新索引并重新签名 `bin/targets/.../packages`，TARGET 包落到那里。对它跳过 `bump`。

**2. 检查发布了什么** —— 不要相信运行摘要：

```sh
curl -s https://akbar-npj.github.io/msm8916-openwrt/releases/25.12.6/targets/msm89xx/msm8916/packages/index.json \
  | grep -o 'base-files[^"]*'
# base-files": "1719~981c978eff
```

并确认 `.apk` 确实携带你的文件 —— 索引对内容只字不提：

```sh
A=openwrt/staging_dir/host/bin/apk
$A adbdump <feed>/base-files-1719~981c978eff.apk | grep -A3 'name: sim-hotplug'
# size + hash 必须等于树中的文件（不确定就 md5sum）
```

**3. 在设备上安装。`apk upgrade` 对 base-files 是无操作。**

镜像构建在 `/etc/apk/world` 中版本固定三个包：

```
base-files=1718~981c978eff
kernel=6.12.112~8efa871abf779b5591d7c27483980dfd-r1
libc=1.2.5-r5
```

`apk` 尊重固定，所以 `apk upgrade base-files` 跳过它**且仍打印 `OK: 83.1 MiB in 307 packages`**。LuCI 的升级按钮做同样的事。命令中的版本就是让它成为升级的东西，并随之移动固定：

```sh
apk update
apk add 'base-files=1719~981c978eff'
/etc/init.d/sim-hotplug restart      # the upgrade replaces files, not the daemon
```

未固定的包（`luci-app-*`、`msm89xx-scripts`、kmods）走正常形式：`apk update && apk upgrade <package>`。

**4. 在设备上验证。**

```sh
apk list -I | grep base-files              # 1719~981c978eff
grep -c restart_modem /usr/sbin/sim-hotplug  # 新代码，不是镜像的
logread -e sim-hotplug | tail                # restart 后的行为
```

**回滚。** 前一构建保留在已发布的 feed 和其索引中，所以带旧版本的同一命令把固定移回：

```sh
apk add 'base-files=1718~981c978eff'
```

不要从 gh-pages 修剪旧的 `.apk` 文件 —— 它们是回滚路径。

## 4. `RELEASE_NOTES.md`

此文件*就是*发布正文（工作流中的 `body_path: RELEASE_NOTES.md`）。它保存**仅当前发布**的说明 —— 一个 `### v…` 条目，没有更旧的发布。（历史说明在 wiki 和 git 历史中。）

条目形态 —— 简洁、项目符号、仅一个发布：

```markdown
### v25.12.6-r4 (YYYY-MM-DD) — built from `main`

> 🆕 **First-release highlights** — one-line caveat if the upgrade path needs a manual step.

- 🎯 **Headline fix (fix)** — what changed and why it mattered, in user terms.
- 🔋 **Another fix** — symptom → cause → fix, kept to one or two lines.
- 🔐 **Security** — backported CVE-… if any.
- 🧰 **Also** — small fixes, as a final bullet or two.
```

为拥有设备的人写，而不是为读 diff 的人写：先讲他们会看到的症状，然后原因，然后修复。保持项目符号和可扫描性；如果有任何未关闭的事，添加 `**⚠️ Known issues**` 项目符号。

## 5. 预检

```sh
./build.sh guard                 # live openwrt/ tree matches msm89xx/ + packages/
./build.sh build mifib-v12       # ~9-11 min, one board
```

然后验证产物，而非源码：

```sh
I=openwrt/bin/targets/msm89xx/msm8916/*mifib-v12-squashfs-sysupgrade.bin
mkdir -p /tmp/chk && tar -xf $I -C /tmp/chk
unsquashfs -d /tmp/chk/root /tmp/chk/sysupgrade-generic-mifib-v12/root
grep DISTRIB_RELEASE /tmp/chk/root/etc/openwrt_release      # must match version
```

CI 负责完整多板卡矩阵 —— 本地构建**一个**板卡，并用 `apk add` 通过 feed 检查包，而非为它重新刷写。

## 6. 提升

`main` 和 `staging-main` 都以 `enforce_admins: true` 运行，所以直接 `git push` **对所有人被拒绝，包括负责人** —— 发布与任何其它变更一样落地，通过必须通过 `Shell test suites` 的 PR。因此旧的快进舞步消失了；`main` 通过合并 PR 更新。

```sh
git checkout -b test/release-r8 origin/main
printf '25.12.6-r8\n' > version        # §2
$EDITOR RELEASE_NOTES.md               # §4
./build.sh guard && ./build.sh build mifib-v12   # §5
git add -A && git commit -m "release: 25.12.6-r8"
git push -u origin test/release-r8

gh pr create --base main --head test/release-r8 --title 'release: 25.12.6-r8' --body-file /tmp/pr.md
gh pr merge --merge                    # after the check is green
```

`main` 还要求分支最新（`strict: true`）。如果 PR 变 `BEHIND`，更新它 —— `gh pr update-branch <n>` —— 这重新运行检查。

`staging-main` 不再在发布路径上。它是板卡工作的集成分支，不与 `main` 保持同步；不要试图从其中一个快进到另一个。参见 `MAINTAINERS.md` §“Branch protection and review flow”。

## 7. 构建与发布

```sh
gh workflow run build-and-release.yml --ref main
sleep 15 && gh run list --workflow=build-and-release.yml --limit 1
```

输入（全部可选）：

| 输入 | 默认 | 备注 |
|---|---|---|
| `release_tag` | 从 `version` 推导 | `v25.12.6-r3` |
| `boards` | 空 = 所有板卡 | 针对性修复发布的空格分隔列表 |

设置 `boards` 后，只重建那些板卡。两个合并保持其余发布一致：`firmware.json` 保留其它板卡的条目，`sha256sums` 被拼接，使它们的校验和行存活，而不是被只覆盖重建板卡的文件替换。

流水线是 `setup` → `build`（每个板卡一个 runner，并行）→ `publish`。每个板卡在自己的 runner 上构建，所以墙钟时间大约是一个板卡的构建，而非总和。

### 构建发布 TEST 发布

该任务不会直接发布到生产。它把 GitHub 发布写成**预发布**，只把 feed 部署到 `releases/<version>`，并让共享的 `releases/<base>` feed 和根 `firmware.json` 不动。运行设备轮询的任何东西都看不到它 —— `firmware.json` 仍命名前一发布，所以没有设备被提供升级。

这种隔离是刻意的。`releases/<base>` 是每个设备读取的，而内核/kmod 修剪只保留此构建产生的 vermagic，所以在那里发布测试构建会删除生产设备仍需要的 kmods。

刷写它，然后用 §7.2 提升它。

> **一次只调度一个发布。** 发布共享一个 `concurrency` 组，所以第二次调度等待而非并发运行 —— 这就是阻止两个运行同时写共享 `gh-pages` feed 和 `firmware.json` 的原因。不过 GitHub 每组只保留**一个待运行**：如果第三次调度在第一次仍运行时到达，第二个排队的运行被**静默取消**，从不显示为失败。再次调度前运行 `gh run list`；如果排队的运行消失了，只需再调度一次。

无需循环轮询地观察它：

```sh
gh run view <run-id> --json status,conclusion -q '.status + " " + (.conclusion // "-")'
gh api repos/akbar-npj/msm8916-openwrt/actions/runs/<run-id>/jobs \
  --jq '.jobs[].steps[] | "\(.number) \(.status) \(.name)"'
```

### 7.1 附加冻结的恢复镜像

该任务**不**构建 `recovery-<board>.img`：镜像嵌入 WCNSS 固件和校准的 wlan NV，它们是 git 忽略的（`msm89xx/recovery/blobs/`），所以 CI 没有构建它的原料。镜像反而被**冻结** —— 恢复只需要把加密狗带回来，而一个已在硬件上启动的镜像胜过新构建。

它们作为一次发布 `v25.12.6-r4` 的资源发布，工作流的*附加冻结恢复镜像*步骤把它们复制到**每个**新发布（该步骤顶部的 `RECOVERY_SOURCE_TAG`）。它们也列在 `sha256sums` 中，所以发布无需任何手动上传即完整。

哈希和验证日期在 `msm89xx/recovery/README.md` §“Shipped (frozen) images” —— 那张表，而非资源，才是记录。

**只有当你刻意重建一个镜像**（重建触发器列在那份 README）时才碰源发布：在那里替换资源，每个后续发布继承新的。

```sh
mkdir -p /tmp/rel
cp msm89xx/recovery/mifib-v12.img /tmp/rel/recovery-mifib-v12.img
cp msm89xx/recovery/hmuf02v5.img /tmp/rel/recovery-hmuf02v5.img
sha256sum /tmp/rel/*.img            # must match the frozen table
gh release upload v25.12.6-r4 /tmp/rel/recovery-*.img --clobber
```

在同一提交中更新 `msm89xx/recovery/README.md` 中的表（大小、sha256、验证日期）。如果 `RECOVERY_SOURCE_TAG` 曾被重新指向，先把镜像上传到新标签：工作流若无法下载它们会失败该发布。

### 7.2 提升到生产

```sh
gh workflow run promote-release.yml --ref main -f tag=v25.12.6-r4
```

它不重建任何东西：它需要的一切已由测试构建发布。

1. 除非标签存在、是**预发布**、不是草稿、并携带至少八个资源，否则拒绝 —— 不完整或已提升的发布不能溜过。
2. 把 `releases/<version>` 复制进 `releases/<base>` —— 目标包 feed、架构 feed、每发布 `firmware.json` 和公钥 —— 并修剪此构建未产生的每个 `kernel-*.apk` / `kmod-*.apk`。
3. 把该 manifest 作为根 `firmware.json` 发布，即设备最先请求的文件。这是发布对他们可见的时刻。
4. 把 GitHub 发布翻到 `--latest` 并去掉“（test build）”标题。

`-f dry_run=true` 做除推送和发布编辑外的一切，并打印暂存的 diff。

**只有在镜像已在硬件启动后才提升。** 这就是拆分的全部意义：坏构建在测试台上失败，而非在用户的加密狗上。r6 给 PM8916 RTC 添加了 `allow-set-time` 并让每个板卡停止启动；它之所以到达生产，只是因为发布曾直接发布到那里。

## 8. 验证发布

```sh
gh release view v25.12.6-r3 --json tagName,isDraft,assets
gh api repos/akbar-npj/msm8916-openwrt/contents/firmware.json?ref=gh-pages \
  --jq '.content' | base64 -d | head -40
```

在提升前对照**测试**发布检查 1–3。4–6 只在 §7.2 后为真，因为 feed 和 `firmware.json` 在那之前不动。

按顺序检查：

1. **标签不是草稿**并携带所有板卡（加 `kmods-*.tar.gz`）。
2. **manifest 与资源一致。** `firmware.json` 为每个板卡发布一个 `sha256`；它必须等于上传文件的哈希：
   ```sh
   gh release download v25.12.6-r3 --pattern '*mifib-v12-squashfs-sysupgrade.bin'
   sha256sum *mifib-v12*sysupgrade.bin
   ```
3. **镜像报告正确版本。** 下载它，解包 squashfs，读 `/etc/openwrt_release`。这是本会在 r3 版本 bug 发布前抓住它的检查。
4. **feed 服务它**：`https://akbar-npj.github.io/msm8916-openwrt/firmware.json`。
5. **恢复资源已附加**并匹配 `msm89xx/recovery/README.md` 中的冻结哈希（§7.1 手动上传它们）。
6. **升级路径可用** —— CI 无法测试的一件事。让设备留在前一发布，打开 LuCI 更新页面，让它下载并刷写。确认横幅，然后确认 `DISTRIB_RELEASE`；仍报告旧版本的设备会永远提供同一升级。

## 9. 重切坏发布

同一版本号，替换：

```sh
gh release delete v25.12.6-r3 --yes --cleanup-tag
git push origin :refs/tags/v25.12.6-r3     # only if the tag survived
gh workflow run build-and-release.yml --ref main
```

新运行从新构建的二进制重新生成 `firmware.json`（合并只保留此运行未构建的板卡），并以 `keep_files: true` 重新发布 feed，所以同一 `releases/25.12.6/` 路径被就地覆盖。已刷写坏构建设备会重新提供更新并自我纠正。

如果坏发布已广泛安装且版本字符串本身错误（如 r3），优先**下一修订** —— 删除设备在 manifest 中缓存的标签会让他们指向 404，直到新 manifest 落地。

## 10. 陷阱

| 症状 | 原因 | 修复 |
|---|---|---|
| 发布死于“Prepare OpenWrt Tree”，`git clone` 退出 128 | `actions/cache` 预创建了 `openwrt/` | 在 `clone_openwrt` 中处理（临时克隆 + 交换） |
| 每个设备报告前一发布 | `CONFIG_VERSION_NUMBER` 陈旧 | 自 `build.sh` 盖章后自动 —— 用 §2 验证 |
| 提供升级但 `do_upgrade` 拒绝 | 设备低于 `min_version`（`25.12.6-r1`） | 手动刷写一次；下限只对真正不可刷写的跳跃移动 |
| 发布后 feed 404 | 只发布了 `releases/<version>` | 工作流也发布 `releases/<base>` —— 检查两者 |
| `gh` 说标签存在 | 前一运行在失败前创建了它 | 删除时 `--cleanup-tag`，或提升修订 |
| 本地构建有旧代码 | `./build.sh kernel` 仅编译，不安装进 `root-msm89xx` | 使用 `./build.sh build <board>` |
| 构建日志有数百行 `ERROR:` | postinst 脚本回显 `ERROR: …` | 改为查找 `*** Error N` 和缺失的 `==> Finished in`；用 `grep -a`（日志含转义序列） |
| `apk upgrade base-files` 打印 `OK` 但版本不变 | 镜像在 `/etc/apk/world` 固定 `base-files` | `apk add 'base-files=<version>'`（§3.1） |
| `apk` 失败 `kernel-... breaks: world[kernel=...]` | 旧镜像留在 world 中的重复 `kernel=` 行 | 删除陈旧行，或 `firstboot -y` |

## 清单

- [ ] `version` 已提升（`-rN` 递增）
- [ ] `RELEASE_NOTES.md` 已用**仅本发布**的说明更新（无更旧条目，无悬空交叉引用）
- [ ] 对每个文件变更的包提升 `PKG_RELEASE`
- [ ] `./build.sh guard` 同步
- [ ] 本地构建一个板卡，镜像 `DISTRIB_RELEASE` 匹配 `version`
- [ ] 在测试台上刷写并冒烟测试
- [ ] `test` → `staging-main` 用 `--no-ff` 合并，`main` 快进
- [ ] 两个分支都推送
- [ ] CI 运行绿，发布不是草稿，所有板卡 + kmods 已附加
- [ ] `recovery-*.img` 存在于发布并匹配冻结表（§7.1）
- [ ] manifest `sha256` 匹配上传的资源
- [ ] 在真实设备上从先前发布测试升级
