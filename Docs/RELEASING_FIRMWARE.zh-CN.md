> 📄 本文件是 [RELEASING_FIRMWARE.md](RELEASING_FIRMWARE.md) 的英文原文中文译本，内容以英文版为准。

# 发布一个固件构建

发布版本的操作手册（runbook）。它涵盖分支模型、承载版本号的三个文件、
CI 的行为，以及如何验证 —— 或替换 —— 一个发错了的版本。

关于手工构建和刷写镜像，请参见
[Build & Flashing Reference](https://github.com/akbar-npj/msm8916-openwrt/wiki/Build-and-Flashing-Reference)。

---

## TL;DR

```sh
# 1. bump the release (see §2) -- the version file is the only version to edit
printf '25.12.6-r4\n' > version

# 2. describe it (see §4)
$EDITOR RELEASE_NOTES.md

# 3. check it locally (see §5)
./build.sh guard
./build.sh build mifib-v12

# 4. promote through a PR -- direct push to main is rejected (see §6)
git checkout -b test/release-r8 origin/main && git add -A
git commit -m "release: 25.12.6-r8" && git push -u origin test/release-r8
gh pr create --base main --head test/release-r8 --title 'release: 25.12.6-r8' --body-file /tmp/pr.md
gh pr merge --merge

# 5. build a TEST release (see §7) -- a prerelease; no device is offered it
gh workflow run build-and-release.yml --ref main
gh run list --workflow=build-and-release.yml --limit 1

# 6. flash it on a bench unit, then promote it to production (see §7.2)
gh workflow run promote-release.yml --ref main -f tag=v25.12.6-r4
```

---

## 1. 分支模型

| 分支 | 角色 |
|---|---|
| `test/firmware-upgrade` | 工作落地之处。每个 commit 都先到这里。 |
| `staging-main` | 集成。`test` 以 `--no-ff` 合并进来。 |
| `main` | 已发布。以**仅限 fast-forward** 的方式接收 `staging-main`。CI 从这里发布。 |

这个 fast-forward 不是摆设 —— 它是"`main` 始终是 `staging-main` 的祖先"
这一不变式，因此提升（promotion）永远不会悄悄丢掉一个 commit，也永远不会
创建一个后来分叉的 merge commit。两条规则保证它成立：

* 绝不要直接在 `main` 上提交。它仅有的 commit 都是通过从
  `staging-main` FF 过来的。
* 如果 `main` 从别处获得了一个 commit（在 GitHub 上合并的 PR、一个
  hotfix），在提升之前先 `git merge main` **到 `staging-main`**。把该
  commit cherry-pick 到 staging 并*不能*恢复 fast-forward：cherry-pick
  是一个父提交不同的新 hash，所以 `main` 仍然不是祖先。

```sh
git rev-list --left-right --count main...staging-main   # want: 0   0
git merge-base --is-ancestor main staging-main && echo ff_ok
```

## 2. 版本号

`version`（repo 根目录）是**唯一事实来源（single source of truth）**。
它保存完整的发布字符串，即基础版本加上修订后缀：

```
25.12.6-r3
└──┬──┘ └┬┘
   │     └── release revision — bump this for every release, even a rebuild
   └──────── OpenWrt base version — only changes when the upstream tree changes
```

谁会读取它：

| 消费者 | 它取用什么 |
|---|---|
| `build-and-release.yml` → `TAG` | `v$(cat version)` → git tag 和 release 名称 |
| `build-and-release.yml` → `BASE` | `${VERSION%-r*}` → 设备轮询的 feed 路径 `releases/<base>/` |
| `gen-firmware-manifest.py` | `version` → `firmware.json`，LuCI 升级页面对比所用的文件 |
| `build.sh prepare_config` | 把 `CONFIG_VERSION_NUMBER` 打进 `.config` → `/etc/openwrt_release` → `DISTRIB_RELEASE` |

最后一行是最会咬人的。`CONFIG_VERSION_NUMBER` 过去是手工维护在所有
`diffconfigs/` 文件里的一份副本，r3 发布时它仍然写着 `25.12.6-r2` ——
于是每个 r3 镜像*报告*的都是 r2。`firmware-upgrade` 会把设备的
`DISTRIB_RELEASE` 与 manifest 对比，于是这样的设备会永远相信自己落后
一个版本，并在每次检查时重复提供同一个更新。`build.sh` 现在每次构建都会
从 `version` 打上这个值；diffconfigs 里仍保留一份副本以供阅读，但它会被
覆盖。

```sh
# after any build, this must equal the version file:
grep DISTRIB_RELEASE openwrt/build_dir/target-aarch64_generic_musl/root-msm89xx/etc/openwrt_release
```

**不要用 `./build.sh version` 来做这件事。** 该命令管理的是上游 OpenWrt
*base* 检出（`devenv/.env`，即该树固定在哪个上游 commit）。`-rN` 后缀
永远只属于 `version` 文件。

## 3. Package 发布

文件发生变更的 package 需要在其 `Makefile` 中提升 `PKG_RELEASE`，这样
`apk` 才会看到新版本，feed 才会真正替换它：

```sh
grep -rn 'PKG_RELEASE' packages/*/Makefile
```

镜像内容并不依赖这一点（镜像是从树组装出来的），但**已发布的 package
feed** 依赖 —— 未变更的 `PKG_RELEASE` 意味着 `apk upgrade` 不会拾取
新文件。每当 package 的 `root/` 树发生变化时都要提升它。

### 3.1 不发版的 package 热修复

只存在于某个 package 中的修复（`base-files` 脚本、一个 LuCI 应用、一个
feed package）通过 feed 发布，而不是通过新镜像。`version` 和
`RELEASE_NOTES.md` 保持不动：设备继续报告例如 `25.12.6-r4`。

**1. 发布它。** `.github/workflows/publish-package.yml` 会针对已发布的
toolchain 重新构建这一个 package，把它拼接进已经发布的 feed，然后重新
签署索引。

```sh
# a package under packages/
gh workflow run publish-package.yml --ref main -f package=luci-app-foo -f bump=true

# a TARGET package (base-files): its PKG_RELEASE is $(COMMITCOUNT), which does
# not move between releases, so stamp an explicit number instead
gh workflow run publish-package.yml --ref main \
  -f package=base-files -f target_package=true -f pkg_release=1719
```

`target_package` 还会对 `bin/targets/.../packages`（target package 的
落脚点）重新建立索引并重新签名。对它会跳过 `bump`。

**2. 检查发布了什么** —— 不要相信 run 摘要：

```sh
curl -s https://akbar-npj.github.io/msm8916-openwrt/releases/25.12.6/targets/msm89xx/msm8916/packages/index.json \
  | grep -o 'base-files[^"]*'
# base-files": "1719~981c978eff
```

并确认 `.apk` 确实携带你的文件 —— 索引对内容只字未提：

```sh
A=openwrt/staging_dir/host/bin/apk
$A adbdump <feed>/base-files-1719~981c978eff.apk | grep -A3 'name: sim-hotplug'
# size + hash must equal the file in the tree (md5sum it if unsure)
```

**3. 在设备上安装它。对 base-files 而言 `apk upgrade` 是空操作。**

镜像构建会在 `/etc/apk/world` 中对三个 package 做版本固定（version-pin）：

```
base-files=1718~981c978eff
kernel=6.12.112~8efa871abf779b5591d7c27483980dfd-r1
libc=1.2.5-r5
```

`apk` 会遵守这个 pin，所以 `apk upgrade base-files` 会跳过它**并且仍然
打印 `OK: 83.1 MiB in 307 packages`**。LuCI 的升级按钮也一样。命令中
的版本号才是让它成为升级的东西，并且它会连同 pin 一起移动：

```sh
apk update
apk add 'base-files=1719~981c978eff'
/etc/init.d/sim-hotplug restart      # the upgrade replaces files, not the daemon
```

未被 pin 的 package（`luci-app-*`、`msm89xx-scripts`、kmod）采用常规
形式：`apk update && apk upgrade <package>`。

**4. 在设备上验证。**

```sh
apk list -I | grep base-files              # 1719~981c978eff
grep -c restart_modem /usr/sbin/sim-hotplug  # the new code, not the image's
logread -e sim-hotplug | tail                # behaviour after the restart
```

**回滚。** 上一个构建仍然保留在已发布的 feed 及其索引中，所以用旧版本
号执行同一条命令就能把 pin 移回去：

```sh
apk add 'base-files=1718~981c978eff'
```

不要从 gh-pages 修剪旧的 `.apk` 文件 —— 它们就是回滚通道。

## 4. `RELEASE_NOTES.md`

该文件*就是* release 正文（workflow 中的 `body_path: RELEASE_NOTES.md`）。
它只保存**当前版本**的说明 —— 一条 `### v…` 条目，不含更早的版本。
（历史说明存放在 wiki 和 git 历史中。）

条目形态 —— 简洁、带项目符号、只写一个版本：

```markdown
### v25.12.6-r4 (YYYY-MM-DD) — built from `main`

> 🆕 **First-release highlights** — one-line caveat if the upgrade path needs a manual step.

- 🎯 **Headline fix (fix)** — what changed and why it mattered, in user terms.
- 🔋 **Another fix** — symptom → cause → fix, kept to one or two lines.
- 🔐 **Security** — backported CVE-… if any.
- 🧰 **Also** — small fixes, as a final bullet or two.
```

为拥有该设备的人写作，而不是为读 diff 的人写作：先写他们会看到的
症状，然后是原因，然后是修复。保持项目符号化、便于扫读；如果还有
未解决的问题，加一条 `**⚠️ Known issues**`。

## 5. 飞行前检查（Pre-flight）

```sh
./build.sh guard                 # live openwrt/ tree matches msm89xx/ + packages/
./build.sh build mifib-v12       # ~9-11 min, one board
```

然后验证产物，而不是源码：

```sh
I=openwrt/bin/targets/msm89xx/msm8916/*mifib-v12-squashfs-sysupgrade.bin
mkdir -p /tmp/chk && tar -xf $I -C /tmp/chk
unsquashfs -d /tmp/chk/root /tmp/chk/sysupgrade-generic-mifib-v12/root
grep DISTRIB_RELEASE /tmp/chk/root/etc/openwrt_release      # must match version
```

CI 负责完整的多板卡矩阵 —— 本地只构建**一块**板卡，要检查某个 package
就通过 feed 用 `apk add`，而不是为它重新刷机。

## 6. 提升（Promote）

`main` 和 `staging-main` 都以 `enforce_admins: true` 运行，所以直接
`git push` **对所有人、包括负责人都会被拒绝** —— 发布与其他任何更改
一样，通过一个必须通过 `Shell test suites` 的 PR 落地。因此过去那套
fast-forward 流程已经不复存在；`main` 通过合并 PR 来更新。

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

`main` 还要求分支保持最新（`strict: true`）。如果 PR 变成 `BEHIND`，
更新它 —— `gh pr update-branch <n>` —— 这会重新运行检查。

`staging-main` 已不在发布路径上。它是板卡工作的集成分支，不与 `main`
保持步调一致；不要试图用其中一个 fast-forward 另一个。参见
`MAINTAINERS.md` 的 "Branch protection and review flow" 一节。

## 7. 构建与发布

```sh
gh workflow run build-and-release.yml --ref main
sleep 15 && gh run list --workflow=build-and-release.yml --limit 1
```

输入（全部可选）：

| 输入 | 默认值 | 说明 |
|---|---|---|
| `release_tag` | 由 `version` 推导 | `v25.12.6-r3` |
| `boards` | 空 = 所有板卡 | 用于定向修复发布的、以空格分隔的列表 |

设置 `boards` 后，只有那些板卡会重新构建。两处合并让发布的其余部分保持
一致：`firmware.json` 保留其他板卡的条目，`sha256sums` 被拼接，使它们
的校验和行得以保留，而不是被一个只覆盖重新构建板卡的文件替换掉。

流水线是 `setup` → `build`（每块板卡一个 runner，并行）→ `publish`。
每块板卡在自己的 runner 上构建，所以墙钟时间大致等于一块板卡的构建时间，
而不是所有板卡之和。

### 一次构建发布的是一个 TEST 版本

该 job 不会直接发布到生产环境。它把 GitHub release 写成
**prerelease**，只把 feed 部署到 `releases/<version>`，而对共享的
`releases/<base>` feed 和根 `firmware.json` 置之不理。运行中的设备轮询
的任何东西都看不到它 —— `firmware.json` 仍然写着上一个 release，所以
没有设备会被提供升级。

这种隔离是刻意的。`releases/<base>` 是每台设备读取的对象，而
kernel/kmod 的修剪只保留本次构建产生的 vermagic，在那里发布一个测试
构建会删除生产环境设备仍然需要的 kmod。

刷写它，然后用 §7.2 提升它。

> **一次只调度一个 release。** Release 共享一个 `concurrency` 组，所以
> 第二次调度会等待而不是并发运行 —— 正是这阻止了两个 run 同时写共享的
> `gh-pages` feed 和 `firmware.json`。不过 GitHub 每个组只保留**一个
> 待处理 run**：如果第三次调度在第一次仍在运行时到达，第二个排队的 run
> 会被**悄悄取消**，并且永远不会作为失败出现。再次调度前先运行
> `gh run list`；如果一个排队的 run 消失了，再调度一次即可。

用不循环轮询的方式观察它：

```sh
gh run view <run-id> --json status,conclusion -q '.status + " " + (.conclusion // "-")'
gh api repos/akbar-npj/msm8916-openwrt/actions/runs/<run-id>/jobs \
  --jq '.jobs[].steps[] | "\(.number) \(.status) \(.name)"'
```

### 7.1 附上冻结的 recovery 镜像

该 job **不会**构建 `recovery-<board>.img`：该镜像内嵌了 WCNSS 固件和
已校准的 wlan NV，而它们被 git 忽略（`msm89xx/recovery/blobs/`），所以
CI 没有构建它所需的材料。这些镜像改为**冻结**的 —— recovery 只需把
stick 救回来，而在硬件上启动过的一个镜像胜过一个全新构建的。

它们作为一个 release（`v25.12.6-r4`）的资产发布，workflow 的
*Attach the frozen recovery images* 步骤会把它们复制到**每一个**新
release 上（该步骤顶部的 `RECOVERY_SOURCE_TAG`）。它们也会列在
`sha256sums` 中，所以一个 release 无需任何手工上传就是完整的。

哈希和已验证日期存放在 `msm89xx/recovery/README.md` 的
"Shipped (frozen) images" 一节 —— 那张表（而不是资产）才是记录。

**只有当你刻意重新构建某个镜像时**（重新构建的触发条件列在那个 README
中）才去动源 release：替换那里的资产，之后每个 release 都会继承新的。

```sh
mkdir -p /tmp/rel
cp msm89xx/recovery/mifib-v12.img /tmp/rel/recovery-mifib-v12.img
cp msm89xx/recovery/hmuf02v5.img /tmp/rel/recovery-hmuf02v5.img
sha256sum /tmp/rel/*.img            # must match the frozen table
gh release upload v25.12.6-r4 /tmp/rel/recovery-*.img --clobber
```

在同一个 commit 中更新 `msm89xx/recovery/README.md` 里的表（大小、
sha256、验证日期）。如果 `RECOVERY_SOURCE_TAG` 曾被改指向别处，先把这些
镜像上传到新 tag：如果 workflow 下载不到它们，会使 release 失败。

### 7.2 提升到生产环境

```sh
gh workflow run promote-release.yml --ref main -f tag=v25.12.6-r4
```

它什么都不重新构建：它需要的一切都已由测试构建发布。

1. 除非 tag 存在、是 **prerelease**、不是 draft 且至少带有八个资产，
   否则拒绝 —— 一个不完整的或已经提升过的 release 不可能蒙混过关。
2. 把 `releases/<version>` 复制进 `releases/<base>` —— target package
   feed、arch feed、该版本的 `firmware.json` 和公钥 —— 并修剪掉本次
   构建没有产生的每个 `kernel-*.apk` / `kmod-*.apk`。
3. 把该 manifest 作为根 `firmware.json` 发布，这是设备最先询问的文件。
   这一刻起 release 对它们可见。
4. 把 GitHub release 翻转为 `--latest` 并去掉 "(test build)" 标题。

`-f dry_run=true` 会执行除推送和 release 编辑之外的所有步骤，并打印
暂存的 diff。

**只有在镜像已在硬件上启动之后才提升。** 这正是这种拆分的全部意义：
一个糟糕的构建会在工作台设备上失败，而不是在用户的 stick 上。r6 曾给
PM8916 RTC 加了 `allow-set-time`，导致所有板卡都无法启动；它之所以到达
生产环境，仅仅是因为过去有一个 release 会直接发布到那里。

## 8. 验证 release

```sh
gh release view v25.12.6-r3 --json tagName,isDraft,assets
gh api repos/akbar-npj/msm8916-openwrt/contents/firmware.json?ref=gh-pages \
  --jq '.content' | base64 -d | head -40
```

第 1–3 项对着**测试** release 检查，在提升之前。第 4–6 项只有在 §7.2
之后才成立，因为 feed 和 `firmware.json` 在那之前不会移动。

按顺序检查：

1. **tag 不是 draft**，并且带有所有板卡（外加 `kmods-*.tar.gz`）。
2. **manifest 与资产一致。** `firmware.json` 为每块板卡发布一个
   `sha256`；它必须等于所上传文件的哈希：
   ```sh
   gh release download v25.12.6-r3 --pattern '*mifib-v12-squashfs-sysupgrade.bin'
   sha256sum *mifib-v12*sysupgrade.bin
   ```
3. **镜像报告正确的版本。** 下载它，解开 squashfs，读取
   `/etc/openwrt_release`。正是这项检查本可以在 r3 发布前抓住那个版本
   号 bug。
4. **feed 在提供它**：`https://akbar-npj.github.io/msm8916-openwrt/firmware.json`。
5. **recovery 资产已附上**，并与 `msm89xx/recovery/README.md` 中的
   冻结哈希一致（§7.1 由手工上传它们）。
6. **升级路径可用** —— 这是 CI 唯一无法测试的东西。留一台设备在上一个
   release 上，打开 LuCI 更新页面，让它下载并刷写。先确认横幅，再确认
   之后的 `DISTRIB_RELEASE`；一台仍报告旧版本的设备会永远重复提供同一
   个升级。

## 9. 重新发布一个坏版本

版本号不变，替换它：

```sh
gh release delete v25.12.6-r3 --yes --cleanup-tag
git push origin :refs/tags/v25.12.6-r3     # only if the tag survived
gh workflow run build-and-release.yml --ref main
```

新的 run 会从刚构建的二进制重新生成 `firmware.json`（合并只保留本次 run
未构建的板卡），并以 `keep_files: true` 重新发布 feed，于是同一条
`releases/25.12.6/` 路径会被就地覆盖。已经刷了坏构建的设备会再次收到
该更新并自我纠正。

如果坏版本已经被广泛安装，而且版本字符串本身是错的（如 r3），则改用
**下一个**修订版本 —— 删除一个设备已在 manifest 中缓存的 tag，会让它们
指向 404，直到新 manifest 到达。

## 10. 陷阱（Gotchas）

| 症状 | 原因 | 修复 |
|---|---|---|
| Release 在 "Prepare OpenWrt Tree" 处失败，`git clone` 退出码 128 | `actions/cache` 预先创建了 `openwrt/` | 在 `clone_openwrt` 中处理（临时克隆 + 交换） |
| 每台设备都报告上一个 release | `CONFIG_VERSION_NUMBER` 过期 | 自 `build.sh` 打点以来已自动化 —— 用 §2 验证 |
| 提供了升级但 `do_upgrade` 拒绝 | 设备低于 `min_version`（`25.12.6-r1`） | 手工刷一次；这个下限只有在确实无法刷写的跨越时才移动 |
| 发布后 feed 404 | 只发布了 `releases/<version>` | workflow 也会发布 `releases/<base>` —— 两个都检查 |
| `gh` 说 tag 已存在 | 之前的 run 在失败前创建了它 | 删除时加 `--cleanup-tag`，或提升修订号 |
| 本地构建是旧代码 | `./build.sh kernel` 只编译，不安装进 `root-msm89xx` | 用 `./build.sh build <board>` |
| 构建日志有数百行 `ERROR:` | postinst 脚本回显 `ERROR: …` | 改找 `*** Error N` 和缺失的 `==> Finished in`；用 `grep -a`（日志含转义序列） |
| `apk upgrade base-files` 打印 `OK` 但版本没变 | 镜像在 `/etc/apk/world` 中 pin 了 `base-files` | `apk add 'base-files=<version>'`（§3.1） |
| `apk` 报 `kernel-... breaks: world[kernel=...]` 失败 | 较旧的镜像在 world 里留下了重复的 `kernel=` 行 | 删除过期行，或 `firstboot -y` |

## 检查清单

- [ ] `version` 已提升（`-rN` 递增）
- [ ] `RELEASE_NOTES.md` 已更新，**只有本版本的**说明（没有更早的条目，没有悬空的交叉引用）
- [ ] 每个文件有变更的 package 的 `PKG_RELEASE` 已提升
- [ ] `./build.sh guard` 通过
- [ ] 本地构建了一块板卡，镜像的 `DISTRIB_RELEASE` 与 `version` 一致
- [ ] 已在工作台刷机并做冒烟测试
- [ ] `test` → `staging-main` 以 `--no-ff` 合并，`main` 已 fast-forward
- [ ] 两个分支都已推送
- [ ] CI run 绿色，release 不是 draft，所有板卡 + kmod 已附上
- [ ] `recovery-*.img` 存在于 release 上并与冻结表一致（§7.1）
- [ ] manifest 的 `sha256` 与上传的资产一致
- [ ] 已在真实设备上从上一个 release 测试过升级
