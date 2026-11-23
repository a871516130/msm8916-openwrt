# 161 — 构建工具：补丁同步守卫，以及选择性内核 / 软件包 / kmod 构建

**日期：** 2026-09-21。**仅涉及工具** —— 唯一被改动的文件是 `build.sh`。固件、驱动、
DTS、补丁或配置均无改动；已部署的模块不受影响。

**状态：** **已实现并验证。** 十项检查全部通过（§6），其中包括一次真实的漂移注入
流程，证明守卫既能检测问题也能修复问题。

**存在原因：** 文档 160 发现内核构建读取的是**活动状态**的
`openwrt/target/linux/msm89xx/` 目录树，而非受版本控制的 `msm89xx/`，且该活动目录树已
停留在 14 个补丁的状态 —— 因此重新 prepare 会静默回退四个修复，其中包括补丁 812 的
根因数据停滞修复。本文档前半部分自动封堵了这一漏洞。后半部分补充了日常驱动开发所
缺失的能力：一种只重新构建**单个**目标、而非整套固件的方式。

---

## 1. 守卫

### 1.1 不变式

`sync_bsp()` 将两棵受版本控制的目录树镜像到已 prepare 的 OpenWrt 目录树中：

| 受版本控制 | 活动状态 |
| :-- | :-- |
| `msm89xx/` | `openwrt/target/linux/msm89xx/` |
| `packages/` | `openwrt/package/msm8916/` |

`bsp_drift()`（`build.sh`）用 `diff -rq` 比较两者，返回 **0 = 已同步，1 = 有漂移**，
并在漂移时打印差异路径（上限 20 个）。它在**宿主机**上运行，这是正确的，因为该仓库
以 bind-mount 挂载在 `/repo`，所以宿主机上的 `openwrt/` *就是* 容器的目录树。

### 1.2 修复前报告，修复后断言

`sync_bsp()` 执行 `rm -rf live && cp -a tracked live` —— 这是既有且预期的行为，也是
受版本控制目录树具有权威性的原因。缺失的是可见性和校验：

* **拷贝之前：** 若 `bsp_drift` 报告有差异，则打印并解释该漂移
  （*“这通常意味着一次构建是在 `./build.sh` 之外运行的”*）。差异绝不会被静默修复。
* **拷贝之后：** `assert_bsp_synced()` 重新检查，若活动目录树仍有差异则**终止**。过去
  拷贝部分失败或失败意味着会用错误的补丁集构建内核，且完全没有任何报错。

### 1.3 两条安装路径均被覆盖

`sync_bsp()` 只是**快速**路径。全新 prepare 走 `scripts/openwrt-prepare.sh`，它自己安装
相同的目录树（`install_target`/`install_packages`，`openwrt-prepare.sh:178-197`）。
因此 `assert_bsp_synced()` 也在 `ensure_prepared()` 的慢路径和 `force_prepare()` 的末尾被
调用。每条安装路径现在都遵循同一不变式。

### 1.4 `./build.sh guard [--deep]`

一个独立的预检命令，运行 `bsp_drift()` 并在漂移时以**非零**退出，因此可用于脚本中，
或任何手动容器操作之前。`check_requirements`（强制要求 Docker 守护进程在运行）在
**无 `--deep` 的 `guard` 下被跳过** —— 该检查恰恰在构建环境未运行时最有价值。

## 2. 深度检查 —— “下一次构建会不会重新 prepare？”

重新 prepare 会清空 `build_dir` 并耗费一次完整的内核重建，因此值得在开始之前预判。

**这刻意不是 OpenWrt `find_md5` 的重新实现。** 该哈希覆盖**绝对路径**，而绝对路径在
宿主机（`/home/.../openwrt`）与容器（`/repo/openwrt`）之间不同，因此宿主机侧拷贝会算出
不同的值。守卫改为**向 make 询问它自己的值**：

```
cd /repo/openwrt/target/linux/msm89xx
make TOPDIR=/repo/openwrt TARGET_BUILD=1 -r -s --no-print-directory \
     --eval='print-stamp: ; @printf "%s\n" "$(STAMP_PREPARED)"' print-stamp
```

三个细节使这一方案成立，每一点都是通过实测而非臆测发现的：

* **`make -p` 不够用。** `STAMP_PREPARED` 是递归展开变量（`include/kernel-build.mk:13`），
  而 `make -p` 会**未展开**地打印递归变量 —— 已用一个最小 makefile 验证
  （`FOO = $(shell echo hi)` 被原样打印）。一个 `--eval` 出的目标会在配方展开时正确地
  展开它。
* **必须传入 `TOPDIR`。** 它由顶层 make 设置并导出给子 make；它在 `rules.mk` 中**不**被
  设置。直接调用目标 Makefile 而不传它会导致
  `/target.mk: No such file or directory`。
* **`TARGET_BUILD` 必须恰好为 `1`** —— `include/target.mk:389` 以
  `ifeq ($(TARGET_BUILD),1)` 门控 `kernel-build.mk`。

若返回的 stamp 存在，则 `build_dir` 与当前补丁集一致（增量构建）。若不存在，则一次
重新 prepare 即将到来。若查询无返回，则判定报告为 **UNKNOWN** 而非猜测。

## 3. 选择性构建

OpenWrt 已支持更窄的目标 —— 顶层 `%::` 捕获所有规则（`include/toplevel.mk:225-238`）
通过 `$(SUBMAKE)` 分发任何目标，且 `target/linux/Makefile:11` 声明了
`prereq clean download prepare compile install …`。它们只需要一个 `.config`。

| 命令 | make 目标 |
| :-- | :-- |
| `./build.sh kernel [board]` | `make target/linux/compile V=s` |
| `./build.sh package <名称\|路径> [board]` | `make <解析后路径>/compile V=s` |
| `./build.sh kmod <name> [board]` | 一个软件包，或内核目标（§3.3） |

### 3.1 `ensure_config` —— 板卡可选

有板卡时，`.config` 从该板卡的 diffconfig 重写，与 `build` 完全相同。**没有**板卡时，
复用现有 `.config`，跳过拷贝和 `make defconfig` —— 这正是使单目标迭代变快的原因。
两者都不提供则报用法错误。

### 3.2 `package` 解析

按原样接受显式的 `package/...` 或 `feeds/...` 路径；否则依次解析：
`package/<name>`、`package/msm8916/<name>`、`package/feeds/*/<name>`、`feeds/**/<name>`，
然后对嵌套在分组下的基础树软件包尝试 `package/**/<name>`。已验证：

| 名称 | 解析为 |
| :-- | :-- |
| `dnsmasq` | `package/network/services/dnsmasq` |
| `mac80211` | `package/kernel/mac80211` |
| `curl` | `package/feeds/packages/curl` |
| `qrtr`、`rmtfs`、`reboot-edl` | `package/msm8916/<name>` |

无法解析的名称会列出近似匹配（`package sms` → `package/msm8916/luci-app-sms-manager`）并以
非零退出。

### 3.3 `kmod` —— 两种真正不同的情形

* **树外** kmod 软件包（`package/kernel/<name>` 或一个 feed）→ 直接构建。
* **树内**（由内核配置生成 —— `qcom_bam_dmux` → `kmod-bam-dmux`，**没有**软件包目录）
  → **没有比 `target/linux/compile` 更窄的目标**，它会重建内核和每个树内模块。命令会明确
  说明这一点，而不是假装有更窄的目标，然后委派给内核目标。

由于文件名很少与模块名匹配，它还会打印带 md5 的匹配模块：
`kmod bam-dmux` → `*bam_dmux*.ko` → `qcom_bam_dmux.ko`（`eca269f1…`，设备正在运行的哈希）。

### 3.4 产物报告

每次选择性构建都会打印自启动以来产生的 `*.ko` / `*.ipk`（`find -newermt "@<start>"`）
并附带 **md5**，按哈希去重 —— 单次构建会在 `build_dir`、`.pkgdir`、`ipkg-*` 和 `root-*`
留下相同副本，五行输出对应三个不同哈希只会是噪音。md5 的存在是为了能立即将结果与设备
比对。

## 4. `DRY_RUN=1`

`run_openwrt_make` 打印命令而不执行它。这正是使新命令无需数分钟构建即可验证的原因。
它**完全没有副作用**：`prepare_config` 的 `cp diffconfigs/<board> .config` 也被守护。
该守护是在一次 dry run *确实* 破坏了 `.config` 之后添加的 —— 留下裸的 diffconfig，
且因为后续的 `make defconfig` 被跳过，`TARGET_DIR_NAME` 求值为 `_`，stamp 路径变成
`target-_/…`。该问题由深度检查打印出损坏路径而发现，并在两侧修复（守护本身，以及为
`hmu05` 恢复 `.config`）。**一个会改变状态的测试手段比没有测试手段更糟。**

## 5. 验证（十项全部通过）

1. `bash -n build.sh` —— 语法检查。
2. `./build.sh guard` —— 已同步，退出码 0。
3. `./build.sh guard --deep` —— 打印真实的 `STAMP_PREPARED` 和判定。
4–6. `DRY_RUN=1 ./build.sh kernel | package qrtr | kmod bam-dmux` —— 目标正确，未执行构建。
7. **漂移注入：** 在活动目录树中放一个杂散文件 → `guard` 报告它并以 **1** 退出。
8. 一次构建在修复漂移前报告它。
9. `guard` 回到**已同步**，退出码 0。
10. 杂散文件已消失（同步修复了它）。

另外验证：`DRY_RUN=1` 使 `.config` 保持字节一致（md5 不变），且对未知软件包和缺失参数
退出码为非零。

深度检查的判定**与真实基准交叉核对**：当天早些时候活动目录树已从 14 个补丁同步到 18 个，
因此 stamp 必然已变化。磁盘上 stamp
`.prepared_355cb72e7a69043f8b20402138589420`；计算值 `.prepared_28a7f3ba27781b9fb696ad9199a34d30`
→ **“重新 prepare 待处理”**，这是正确的答案。

## 6. 本改动**不**覆盖的内容

* 守卫保护的是经由 `build.sh` 的构建。**直接在容器内**运行 `make`
  （例如通过 `./build.sh shell`）仍会读取活动目录树当时的状态。这正是
  `./build.sh guard` 的用途。**已记录，未解决。**
* 未添加 `deploy` 命令 —— 产物以带 md5 的形式报告，供手动拷贝。
* `sync_bsp` 破坏性的 `rm -rf live` 语义不变。任何对活动目录树的手工编辑在下次构建时
  仍会丢失；守卫的职责是让这种丢失可见，而不是阻止它。
* 本改动不触及调制解调器、902 版致命错误，或 AP 侧挂起问题。

## 7. 用法

```
./build.sh guard [--deep]
./build.sh kernel  [board]
./build.sh package <name|path> [board]
./build.sh kmod    <name> [board]
DRY_RUN=1 ./build.sh <any build command>
```

## 8. 一句话总结

**构建现在拒绝从受版本控制源码未描述的补丁集生成内核 —— 它会报告漂移、修复它，并在
两条安装路径上验证结果 —— 而且它还能只重建内核、单个软件包或单个内核模块，打印每个
产物的 md5 以便与设备比对。**

## 9. 来源与 SOP 合规

* 于 2026-09-21 在构建主机 `192.168.8.243` 上实现并验证。
* **SOP 合规（双固件对比工作流）：** **无基带工作，无固件、驱动、DTS、补丁或 NV 改动。**
  这是构建工具，因此 SOP 步骤 1–5 不适用。被触及的唯一配置（`openwrt/.config`，已被
  gitignore）**已恢复为生成已部署镜像的 `hmu05` 板卡配置** —— 已验证：8383 行，
  28 个 `CONFIG_TARGET*` 条目，镜像位于 `bin/targets/…/openwrt-msm89xx-msm8916-generic-hmu05-*`。
  按任务允许的形式执行了真实基准纪律：上述每项声明都是实际运行过的命令，且深度检查的
  判定已与已知良好的 stamp 交叉核对。发现并记录了一个自我造成的副作用，而非隐瞒它（§4）。
* 设备**始终未被触碰**；浸泡运行 8 全程继续（3 次致命错误，3 次 SSR，全部恢复，
  `retries 0`，`rebuilds 0`）。
* 相关文档：文档 160（本守卫自动化的陈旧活动目录树发现）；文档 147 §7（同类漂移，
  补丁 809）；文档 155/156/157（补丁 810/811/812/814，陈旧活动目录树会丢弃它们）。
