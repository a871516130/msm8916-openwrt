# RPM 深度探究 —— MEM_CLK / DDR 时钟策略，OpenWrt vs Android（2026-10-24）

状态：重大新发现。这重写更早"总线投票热惰性 /
与 OS 无关"关闭（`HMU05_LIVE_BUS_VOTING_AB.md`）的一部分：RPM *固件*是共享硅片，
但*每个 OS 发送的投票*不同 —— 且 RPM 实际持有的 DDR/BIMC 时钟在
两个 OS 间相差 **4-7x**。这是第一个合理解释
OpenWrt 单元在等 CPU 忙%下约 12 C 空闲热差距的机制。

## 1. 我们如何到达这里

等吞吐量环回 A/B（见 `HMU05_EQUAL_TPUT_LOOPBACK_AB.md`）将空闲差距
（OWRT pm8916 55.4 C vs AND 43.6 C 于约 7% 忙，两者 800 MHz）留为未解释。深入两单元的 RPM
表面产生三个线索：interconnect debugfs INT_MAX 投票、
主线 `icc_node_add()` 启动投票机制、以及通过带宽基准直接测量 RPM 管理的 DDR
时钟（Linux 无法*读取* RPM MEM_CLK 速率，但任何流式
工作负载间接测量它）。

## 2. RPM 表面清单

OpenWrt 6.12（主线）：`/sys/kernel/debug/regulator/regulator_summary`（所有 pm8916 轨；
spm/vdd-apc 1062 mV == Android 的 1.05 V —— 轨对等重新确认），
`interconnect/interconnect_summary` + `interconnect_graph`、`clk/clk_summary`、`qcom_stats`
（空 —— 设备从不挂起）。主线上无 rpm_log/rpm_stats。

Android 3.10（下游）：`rpm_log`、`rpm_stats`（RPM 在 25230 s 内从未进入 xosd/vmin）、
`rpm_master_stats`、`rpm_send_msg`、`msm-bus-dbg/{commit-data,client-data,shell-client}`。
注意：`rpm_log`/`rpm_master_stats` 读取**阻塞**（不要 cat 它们）；`commit-data`/`client-data`
返回 "Input/output error" —— 此单元上的 msm_bus debugfs 半坏。

## 3. INT_MAX 之谜 —— 已解释（且基本良性）

`interconnect_summary` 显示 `mas_apss` / `slv_ebi_ch0` avg=peak=2147483647（INT_MAX）。
保管链：

1. `icc-rpm` **无 `get_bw` 回调**注册其提供者，因此 `icc_node_add()`
   （drivers/interconnect/core.c:957-963）将每个节点初始化为
   `init_avg = init_peak = INT_MAX` 并**一次性提交** —— 一个"为安全启动于最大"
   投票，实际到达 RPM（qcom_icc_bw_aggregate 带 tag 0 -> ACTIVE 和 SLEEP
   两个桶；qcom_icc_rpm_set -> smd-rpm）。
2. 启动期间，`aggregate_requests()` 将每次重新聚合以初始值下限
   （core.c:293-296）**直到 `icc_sync_state()` 运行**。
3. `msm8916.c` 是唯一**无 `.sync_state = icc_sync_state`** 的 qcom interconnect 平台
   （8909/8937/8939/8974/8976/8996/osm-l3/qcm2290 都有它）—— 因此下限从不清除且
   debugfs 显示永远显示 INT_MAX。
4. 然而，`qcom_icc_set` 实际每次提交**发送**的是每节点桶和
   （`qn->sum_avg`），`pre_bw_aggregate` 将其清零并从真实客户端请求重新填充。
   cpu0 的请求（补丁 834：800 MHz OPP 处 `opp-peak-kBps = 8528000`；无 avg）使
   *带宽*投票约 0 avg / 8528000 kBps 峰值。

所以 INT_MAX 是真实启动时最大投票加永久*显示*下限 —— **非**实时
最大带宽请求。有趣的投票在别处：

## 4. 发现：OpenWrt 将 MEM_CLK 投票到最大；Android 将其保持在约 1/4 速率

msm8916 的 BIMC 提供者有 `bus_clk_desc = &bimc_clk`（MEM_CLK r_id 0；SNOC = bus_1_clk）。
`qcom_icc_set` 计算总线速率为 `所有节点上 max(sum_avg, max_peak)/buswidth 的最大值`
并为 ACTIVE 和 SLEEP 集合提交到 RPM。以 cpu0 的峰值投票 8528000 kBps
和 buswidth 8：**8528000/8 = 1066000 kHz = 1066 MHz** —— BIMC PLL 最大值 —— 因此 OpenWrt 的
MEM_CLK 投票在每个 CPU OPP 处处于最大（OPP 表仅有峰值，且 200/400 MHz 处 3200000
仍映射到 400 MHz）。

测得的后果（Linux 无法伪造的基准）：

| 基准（相同硅片，4 核全在线，cpu0 钉住 800000 kHz，飞行中采样） | OpenWrt | Android |
|---|---|---|
| A：通过 /dev/zero 的 memset，4 GiB | **3.0 GB/s**（1.42 s） | **0.66-0.69 GB/s**（6.0-6.2 s） |
| A 于 200 MHz（OWRT powersave 控制） | 753 MB/s | — |
| C：页缓存读 64 MB x20 = 1.28 GiB | **3.4 GB/s**（0.38 s） | **0.5 GB/s**（2.55 s） |
| B：管道复制混合 2 GiB | 6.7 s | 13.7 s |

排除明显混杂的对照：

- **频率**：Android 基准期间每 0.4 s 采样 —— 每个单次采样中 cpu0 = 800000 kHz，核 0-3 全程在线。（Android `scaling_governor` 写入返回 rc=1 EINVAL 但**确实生效** —— 读回确认；不要信任 rc。）
- **热缓解**：`stop thermal-engine`，单元冷却 55->54 C，重基准 = 相同 688 MB/s。非 pop_mem/热节流。thermal-engine 事后恢复。
- **CPU 微架构 / 内核复制路径**：OpenWrt 于 200 MHz 给出 753 MB/s == Android 于 800 MHz（656-685 MB/s）。Android 行为完全像 OpenWrt 在四分之一 CPU 速率；纯 ISA/uaccess 差异不能产生该对齐。
- OpenWrt 基准在 `performance` 调控器下运行（事后恢复 schedutil）。

结论：**RPM 在 OpenWrt 下将 BIMC/DDR 时钟保持在最大，在 Android 下约为其四分之一，
即使完全内存负载下。** Android 的 msm_bus 从不将 MEM_CLK 投票上调
（其提交路径在此单元上可证明半坏），而 OpenWrt 的 cpu0 opp-peak 投票
将计算速率钉在 PLL 最大。

## 5. 热影响（为何重要）

LPDDR3/BIMC PHY+IO 功率随时钟缩放。OpenWrt 将 DDR 子系统 24/7 保持在最大时钟
（其投票从不下降：OPP 表仅有峰值，且即使 200 MHz OPP 映射
到 400 MHz），Android 约 1/4。几百 mW 差在被动
冷却棒上易为 3-8 C —— 这是第一个与观察空闲差距一致的机制
（OWRT 55.4 C vs AND 43.6 C pm8916，且 Android 实际运行更**忙** AP：loadavg
3.5-5.5 vs 0.29）。

它也将优化符号翻转：在此匹配"Android 对等"意味着教
OpenWrt 投票**更少**，而非更多。

## 6. 修复候选（每个 = 内核重建 + 刷写，均未测试）

1. **向 OPP 表添加真实 avg 投票**（补丁 834 扩展）：`opp-avg-kBps` 值远
   低于峰值（例如低 OPP 处下游风格 100-500 MB/s）—— 改变 qn->sum_avg，从而
   改变 MEM_CLK 速率。
2. **降低低/中 OPP 处的 `opp-peak-kBps`**（8528000 -> 例如 4264000 或每 OPP
   下游匹配值）—— 直接限制计算出的 MEM_CLK 速率。
3. **向 msm8916.c 添加 `.sync_state = icc_sync_state`**（匹配其他所有平台；清除
   INT_MAX 启动下限 + 显示伪影；良好卫生，可能小热效应，
   因为实时提交已取代它）。
4. 用相同基准验证每次刷写（若修复有效，预期 OWRT memset 从 3.0 GB/s 降至
   约 1-2 GB/s 于空闲 OPP）+ 空闲温度 A/B（12 C 差距应
   缩窄）。
5. 可选：尝试通过 `rpm_send_msg`/smem 读取 Android 的真实投票值 —— 但见
   下方事件；此单元上的 msm_bus debugfs 危险。

## 7. 事件：msm-bus shell-client 卡住 Android 单元

在尝试通过从用户空间注入最大投票证明机制时
（`echo 1 > mas; echo 512 > slv; echo 2e9 > ab/ib; echo 1 > update_request` 于
`/sys/kernel/debug/msm-bus-dbg/shell-client`），`update_request` 写入**阻塞**且
单元**停止应答 ping 和 ssh**（>3 分钟，无观察到的看门狗恢复）。debugfs
已半坏（`commit-data` = Input/output error）。若单元不自行恢复
则需物理断电；注入的投票在重启后不持久。**不要在此单元上再次使用 shell-client。**

同一会话也注意到：OpenWrt 上 `echo restart > /sys/kernel/debug/msm_subsys/modem`
返回 EINVAL（rc=1，无重启触发，`dmesg | grep -c 'msm_subsys: restarting'` 不变）
—— 实况验证的 SSR 杠杆这次**未**工作；值得单独查看。因此
"谁持有投票，AP 还是调制解调器？"归因测试（mpss-down 期间基准）仍开放，
尽管上述启动投票 + bus_clk_desc 链使 AP 侧成为近乎确定的持有者。

## 8. ID 与引用

- 下游总线 id（dt-bindings/msm/msm-bus-ids.h）：MSM_BUS_MASTER_AMPSS_M0 = 1，
  MSM_BUS_SLAVE_EBI_CH0 = 512。
- icc-rpm.c：qcom_icc_rpm_set()（bw 投票，ap_owned 节点跳过）、qcom_icc_set()
  （bus_clk_desc 速率提交，缓存于 qp->bus_clk_rate）、qcom_icc_bus_aggregate()/
  qcom_icc_calc_rate()（max(sum_avg, max_peak)/buswidth）。
- core.c：icc_node_add() 初始化 INT_MAX（无 get_bw）、aggregate_requests() !synced_state 下限、
  icc_sync_state() 清除（msm8916 上从不调用）。
- 补丁 834 = cpu interconnects + opp-peak-kBps；补丁 824 = rpm master-stats DT（实践上
  debugfs 空）；补丁 838 = OPP 限制 800 MHz。
- Android 频率表：200/400/533/800 MHz，最小 200000；OpenWrt OPP 限制在 800 MHz（838）。
- OpenWrt 静止时稳压器：s3 1300 mV（iris-vddrfa）、s4 1850 mV、l5/l6/l7 1800 mV、
  l8 2900 mV（mmc-vmmc）、l9 3300 mV（iris-vddpa）、l13 3300 mV（ulpi-v3p3）、spm 1062 mV
  （vdd-apc）—— 全部合理，相对 Android 无明明显错（每轨 Android 电压
  尚未转储；3.10 上无 regulator_summary，有每稳压器 debugfs 目录）。

## 9. 会话工具陷阱（给下一个实验者）

- `/dev/kmsg` 读取**阻塞**（tail 语义）—— 总是 `dmesg | grep`。
- Android `rpm_log` / `rpm_master_stats` 读取**阻塞**。
- Android `msm-bus-dbg/shell-client/update_request` 写入可**硬卡住**单元。绝不再用。
- Android `scaling_governor` 写入返回 rc=1 EINVAL 但成功（通过读回验证）。
- 主机侧 Bash 工具无法后台化长寿命服务器；保持服务器在设备上
  所有 fd 重定向到 /dev/null，否则 ssh 挂起至超时。
- Android 无 /tmp（用 /data/local/tmp）；OpenWrt busybox sleep 仅整数但 usleep
  存在；管道上 `dd bs=4M` 返回一个管道缓冲（约 64 KB）—— 用 `bs=65536 count=64`。

## 10. SSR 杠杆 EINVAL —— 根因（2026-10-24 解决）

`echo restart > /sys/kernel/debug/msm_subsys/modem` 在**已部署**镜像上返回 EINVAL，
而 `printf restart`（无尾随空白）有效，`printf ' restart'`（前导
空格）也有效。探测：尾随换行被拒，尾随空白变体未测试但暗示，前导空白接受 -> 已部署
存储仅修剪**前导**空白（skip_spaces + 原始 strcmp），非两端。

补丁 826 的两个已提交修订都不那样做（a23256e 2026-10-02 和 505b071 都有
完整 `strstrip`；v25.12.5-r6 标签与 HEAD 相同）。结论：刷写镜像的
qcom_q6v5_mss.c 从更**旧**、从未提交的 826 修订打补丁，它存在于
未跟踪的 openwrt 树（刷写时过时 quilt 状态；`openwrt/target` 非 git 跟踪
且 build.sh 同步补丁**文件**，但已应用的补丁可能不重新应用）。

当前已部署镜像的实用规则：以 `printf restart >
/sys/kernel/debug/msm_subsys/modem` 调用 SSR 杠杆（**无**尾随换行/空格）。此怪癖自愈于
下次刷写（当前树 = 完整 strstrip）。

也注意到：dmesg 重启行（t=26779 s）在此会话任何故意 SSR 前约 35 分钟触发
—— 几乎确定是调制解调器承载看门狗恢复路径（其调用显然
有效，即它不附加尾随换行）。未确认；看门狗脚本未在
预期路径定位（/root/modem-bearer-watchdog*）。

## 11. 实验：移除 AP opp-peak 投票**不**降低 MEM_CLK（2026-10-24）

构建并刷写一个镜像（分支 test/rpm-mem-clk，提交 d976793/e9e4bee/90b1bbd/21ed566），
编辑补丁 834/838/846 使 cpu0 的 `opp-peak-kBps` 在每个 OPP 处为 0（AP 从不
驱动 mas_apss/slv_ebi_ch0 上调）。刷写后验证：

- interconnect_summary：cpu0 客户端投票 0/0（原峰值 8,528,000）。mas_apss /
  slv_ebi_ch0 节点聚合仍读 2147483647（INT_MAX 启动初始化状态）。
- DDR 基准**不变**：memset 3.0 GB/s（x3，相同 1.41-1.45 s），页缓存 1.28 GiB 于
  0.37 s（约 3.4 GB/s），管道 2 GiB 于 6.7 s。同会话刷写前基线
  相同。

结论：实时 AP opp-peak 投票**非** MEM_CLK 持有者。持有者是
`icc_node_add()` 的 INT_MAX 启动初始化提交（提供者
无 get_bw 注册时 init_avg/init_peak = INT_MAX），msm8916.c 从不清除它，因为它是唯一
无 `.sync_state = icc_sync_state` 的 qcom ICC 平台。每个后续重新提交
重新聚合 INT_MAX 下限，因此 MEM_CLK 永远锁存于最大。

修复：补丁 860 向 msm8916_noc_driver 添加 `.sync_state = icc_sync_state`。所有
消费者探测后，核心清除初始化状态并重新提交真实聚合
（834 实验下：0/0 -> RPM 默认策略，即 Android 对等，因为 Android 的
3.10 内核从不投票 BIMC）。同会话基准 + 空闲温度 A/B 随后。

## 12. 补丁 860 刷写结果 —— MEM_CLK 破解（2026-10-24）

用补丁 860（msm8916_noc_driver 中 `.sync_state = icc_sync_state`）在
834/838/846 opp-peak=0 实验之上构建镜像。保留配置刷写（14:08 构建，635 s）。

刷写后验证：

- interconnect_summary：mas_apss / slv_ebi_ch0 节点聚合从 2147483647
  （INT_MAX）降至 0/0 —— sync_state **触发**且初始化状态被清除并重新提交。
- DDR 基准（同会话，同脚本，调控器钉住 performance @ 800 MHz）：

  | 测试 | pre-860（启动投票持有） | post-860 | Android（先前会话） |
  |-----------------|--------------------------|---------------|-------------------------|
  | dd /dev/zero | 3.0 GB/s | 1.4-1.6 GB/s | 0.66 GB/s |
  | 页缓存 20x | 0.37 s | 0.44 s | 约 0.8 s-等效 |
  | 管道 2 GiB | 6.7 s | 10.8 s | - |

  AP 的 INT_MAX 启动初始化提交**是** MEM_CLK 持有者。一行驱动代码将
  DDR/BIMC 时钟域减半。相对 Android 剩余 2.3x 开放（其他投票者？RPM 默认
  下限？3.10 上基准路径差异？）。

健全性：wwan0 附着（10.110.5.113），互联网 OK，cpufreq 最大 800 MHz（838 编辑完好）。

空闲热（30 分钟日志器，设备在启动 + 基准后空闲）：

- OWRT pm8916：56.5 -> 51.2-52.3 C 平台（30 分钟仍缓慢下降）。
- AND pm8916 同日：44.6-45.5 C。差距现约 7 C（记录基线差距约 11.8 C）。
- 注意：旧镜像上的单会话开始快照读 49.8 C，因此空闲
  改善**不**被今日数据单独干净证明（环境/时间混淆；
  启动残余热）。DDR 带宽变化是**决定性**的；空闲温度差需
  多小时浸泡。此镜像上等吞吐环回 A/B 的负载侧重复是
  更干净的热测试（那是 2-4.7x 带宽差异应显现的地方）。

下一步：此镜像上多小时空闲浸泡 + 等吞吐环回 A/B；然后决定
opp-peak=0 + sync_state 是否按原样交付（最接近 Android：AP 从不投票）或真实每 OPP
avg/peak 值替换零。

## 13. 860 镜像上的等吞吐环回 A/B —— 对等（2026-10-24）

同会话、匹配速率重跑等吞吐环回 A/B（方法文档
`HMU05_EQUAL_TPUT_LOOPBACK_AB.md`），两腿背靠背，一个测试台
（K=4 并行 4 MB 环回拉取，速率由客户端 usleep 设置，5 s 日志器）：

| 度量 | OpenWrt（860 镜像） | Android |
|---|---|---|
| 吞吐量 | 10.74 MB/s（161 次迭代，usleep 1.4 s） | 11.07 MB/s（166 次迭代，usleep 1.43 s） |
| pm8916 空闲基线 | 44.4 C（启动后约 2.5 h 稳定） | 43.6-44.1 C |
| 负载下 pm8916 上升 | 最大约 +0.5 C（44.4 -> 44.3-45.1，平坦） | 约 0 C（43.6-44.1 -> 43.2-44.4，平坦） |
| 负载下 CPU 忙 | 10.0% | 3.4% |
| 负载后恢复 | 2 分钟回到 43.6-44.2 C | - |

- 旧镜像上（先前会话，相同 10.8 MB/s）：OWRT +3.2 C 仍在上升于 36% 忙
  vs AND +1.9 C 于 24%。860 镜像上：**两者**平坦约 44-45 C。匹配
  速率下的负载热分歧**消失**（跨会话注意适用于旧数字；同会话
  平坦对平坦结果是可靠的）。
- 今日空闲对等：OWRT 43.6-44.3 C vs AND 43.2-44.4 C。记录的约 11.8 C 空闲差距
  （55.4 vs 43.6）在 860 镜像上**消失**。重要排序教训：30 分钟启动后
  日志器的'51-52 C 平台'**非**平衡 —— 板卡持续排放启动/基准热
  约 2 h（长热时间常数）。空闲差距声明需要稳定基线（>=2 h），
  而非 30 分钟日志器。
- OWRT 在合成路径中仍燃烧约 3x 每字节 CPU（10.0% vs 3.4% 忙）——
  方法文档中注意的 uhttpd/wget-vs-busybox 测试台不对称持续 —— 但在此速率下现热惰性。
- 意外（跨会话，未解释）：每迭代服务时间在两单元上相对先前会话崩溃
  （OWRT 约 2.1 s -> 约 0.07 s；AND 约 0.69 -> 约 0.03 s）。相同二进制、相同
  服务器。**不**跨会话比较绝对忙%/速率；可能状态/测试台
  混淆（页缓存状态、thermal-engine、后台负载）。OWRT 今日 usleep
  400 ms 下速率约 33 MB/s。

结论：用补丁 860（+ opp-peak=0），OpenWrt 在空闲**和**匹配 10.9 MB/s 环回负载下热匹配 Android。热差距目标在此证据上关闭。

## 14. 松散端：看门狗 SSR 归因 + 剩余 2.3x DDR（2026-10-24）

### 14a. modem-bearer-watchdog —— 已找到，且 26779 s 归因修订

脚本是 `/usr/sbin/modem-bearer-watchdog`（802 行），由
`/etc/init.d/modem-bearer-watchdog` procd 管理（START=96，respawn 3600 5 5），uci `modem-watchdog.*`，
启用，且可证明活跃（logread：启动时承载重驱动，移动性分析）。

其**唯一** SSR 杠杆是第 268 行：`echo restart > /sys/kernel/debug/msm_subsys/modem` ——
**带**尾随换行 —— 由 `modem-watchdog.recovery.ssr_enabled` 门控（默认 1）。

- 旧镜像上该存储返回 EINVAL（仅前导修剪解析器；尾随换行
  拒绝）。杠杆**死**。因此旧镜像上未解释的 26779 s 重启
  **非**看门狗 SSR。先前会话归因（"几乎确定是看门狗"）**修订**：
  最可能是调制解调器致命后内核侧 rproc 自动恢复（无
  msm_subsys 写入，仍增加 restart_count）。旧 dmesg 已消失（自此两次重启），因此
  无法从日志确认。
- 新镜像（完整 strstrip）上 `echo restart\n` **有效** —— 看门狗杠杆
  再次功能正常。完全如 §10 预测自愈。

### 14b. 剩余 2.3x DDR vs Android —— 真实，但基准混合

同日 Android 重基准：667-679 MB/s（== 先前会话的 0.66 GB/s，因此**非**会话
漂移）。OWRT post-860：1.4-1.6 GB/s。实况 OWRT DDR 负载期间，每个 AP ICC 投票者读
0/0（mas_apss、cpu0、mas_usb_hs、mas_tcu0/1、mas_gfx）—— 差距**非** AP 投票。

重读旧对照改变解释：旧镜像上 dd 基准
**随** CPU 频率比例缩放（753 MB/s @200 MHz vs 3.0 GB/s @800 MHz）——
一个 CPU-uaccess 受限状态 —— 而 post-860 @800 MHz 降至 1.5。因此基准是
**混合 CPU+内存**度量：3.0 -> 1.5 减半因果上是 ICC 变化（受控 A/B，
唯一变量），但"Android 将 DDR 保持在约 1/4 速率"是**推断**，来自其
Android 数字（667 MB/s）本身可能被 3.10 内核的 CPU 路径限制的基准。什么仍
**已证明**：OpenWrt 通过 INT_MAX 启动投票 24/7 将 MEM_CLK 钉在 PLL 最大，且补丁 860
以测得域 2x 降低 + 热对等（§13）修复它。

剩余 2.3x 的主要假设（开放，仅好奇）：显式 0 提交 vs
从不投票。OWRT 的 ICC 核心每次设置主动向 RPM 提交 0；Android 从不发送
任何 APSS->EBI 请求。RPM 固件策略可能对有活动（零）请求的主设备比无投票主设备
将 MEM_CLK 下限更高。无 RPM 内省不可测试
（rpm_log 读取阻塞）。实践上无关：1.5 GB/s >> 此设备数据路径需求，
且热对等已达成。

## 15. RPM 内省 —— 实际 MEM_CLK 测量（2026-10-24）

### 15a. 读取**不**阻塞（先前会话注意修订）

Android rpm_stats / rpm_log 用 `timeout -t N`（busybox 语法）和有界
读取（`head -c`）正常读。rpm_stats：RPM 自启动从未进入 xosd/vmin（计数 0，
7552 s）。rpm_log 内容是原始二进制记录（驱动十六进制转储它们）—— 无 ASCII
时钟决策；正确的内省工具是 GCC 寄存器，而非日志。

### 15b. Android AP 侧：bimc_clk 速率 = 0（从未投票）

/sys/kernel/debug/clk/：`bimc_clk`（RPM MEM_CLK 对象，r_id 0）读**速率 0** ——
Android 的 AP 从不对其调用 clk_set_rate。分支时钟报告 bimc_msmbus 400 MHz、
bimc_a_clk 约 200 MHz（AP 框架值，非 DDR 根）。此 BSP 上无 clk_measure。

### 15c. OpenWrt 通过 /dev/mem 的硬件真相（STRICT_DEVMEM 关，devmem 存在）

GCC 基址 0x1800000。BIMC PLL（mode 0x23000，L/M/N 0x23004/8/0c，status 0x2301c），
bimc_ddr_clk_src RCG2（cmd 0x32004，cfg 0x32008；src_sel 位 [10:8]，div 位 [4:0]）：

- BIMC PLL L=55 M=25 N=48 -> 19.2 MHz x (55 + 25/48) = **1066 MHz 已配置**（PLL 最大），
  但 status_reg = 0：PLL **未**运行。
- DDR RCG cfg = 0x103：src_sel = 1（GPLL0，L=41 M=2 N=3 = 800 MHz），div = 3+1 = 4
  -> **实际 MEM_CLK = 200 MHz** 于 860 镜像。匹配基准上限
  （200 MHz x 8 B = 1.6 GB/s vs memset 1.5 GB/s = 94%）。
- 完全 DDR 负载下 RCG 保持 0x103 且 PLL 保持关：**RPM 将 MEM_CLK 钉在
  其 200 MHz 下限；AP 无杠杆**（提交 0 状态）。

### 15d. 结论 —— MEM_CLK 对等；2.3x 是 CPU 路径

- Android：bimc_clk 从未设置 -> RPM 默认策略。OpenWrt post-860：提交 0 ->
  相同 RPM 默认下限（200 MHz，GPLL0/4，PLL 关）。§14b 的显式 0-vs-从未投票
  假设**被驳斥** —— 两个状态落在相同硬件配置。
- 剩余 2.3x memset 差距（1.5 vs 0.667 GB/s）是 CPU/uaccess 路径（6.12 vs
  3.10），**非** DDR 时钟：Android 的 667 MB/s 低于相同 1.6 GB/s 上限。
- 注意：Android 自身的寄存器读取不可能（/dev/mem 读取在 3.10 上 I/O 空间返回 EFAULT；
  无 devmem applet）—— 对等声明基于 bimc_clk 速率 0 + 基准上限一致性，而非直接寄存器比较。
- 风险注意：MEM_CLK 在负载下保持 200 MHz —— 重度吞吐场景（NAT、批量
  LTE）在 opp-peak=0 时无法升高它。被要求时 RPM **会**升高它（旧镜像
  驱动 1066 MHz）。若吞吐上限某时重要，每 OPP 投票重新启用缩放。

## 16. 通过静态 busybox 直接寄存器比较（2026-10-24）

工具：zoobab/busybox-static-for-android（ELF 32 位 ARM EABI5，静态，BusyBox
v1.16.0 2010）—— 与 msm8916 Android 单元兼容（armv7l 用户空间；陷阱：该
二进制必须**命名** `busybox`，它在 argv[0] 上多路复用）。安装于
/data/local/tmp/busybox；提供原厂 busybox 缺少的 devmem/od/hexdump/httpd。

直接 GCC 寄存器比较（相同地址，两单元）：

| 寄存器 | OpenWrt（860） | Android |
|---|---|---|
| BIMC PLL mode/L/M/N | 0x104000 / 55 / 25 / 48 | 相同 |
| BIMC PLL status | 0（关） | 0（关） |
| GPLL0 L/M/N | 41 / 2 / 3（800 MHz） | 相同 |
| DDR RCG cfg（0x32008） | 0x103：GPLL0 div 4 = **200 MHz** | 0x101：GPLL0 div 2 = **400 MHz** |

对 §15d 的更正：

1. 显式 0-vs-从未投票假设**已确认**，非驳斥：投票 0 使 RCG
   落在 div 4（200 MHz）；Android 的从未投票默认落在 div 2（400 MHz）。
   更早 Android memset（667 MB/s）远低于其自身 3.2 GB/s 上限 —— CPU 路径受限，
   因此基准从未揭示此。
2. 原始补丁 834 值精确解码：3200000 kBps / 8 = 400 MHz（Android
   默认），8528000 / 8 = 1066 MHz（PLL 最大）。用补丁 860 现清除 INT_MAX
   下限，每 OPP `opp-peak = 3200000` 将保持恒定 400 MHz = 精确 Android
   时钟对等；`0` 给出 200 MHz（更凉，但相对 Android 欠投票）。

开放船型决策：保持 0（热证明，额外裕量，轻微吞吐
上限 1.6 GB/s）或切换恒定 3200000（精确 Android 时钟状态）。3200000 上空闲+负载
A/B 是干净的下一步测试；任一方式预期热对等（Android
本身运行 400 MHz 且是凉爽参考）。

## 17. opp-peak=3200000 交付到测试设备 —— 400 MHz 验证（2026-10-24）

补丁 834/838/846 从 opp-peak=0 切换到恒定 3200000（15:57 构建，提交
待定），保留配置刷写。刷写后寄存器真相（相同 devmem 方法）：

- DDR RCG cfg = **0x101 = GPLL0（800 MHz）/ 2 = 400 MHz —— 精确 Android 对等**
  （Android 在同一寄存器读 0x101；§16）。
- BIMC PLL status 0（关）—— 与 Android 相同。ICC 摘要：cpu0 峰值投票 3200000 实时。
- 健全性：wwan0 附着，互联网 OK。
- 基准：memset 回到约 3.0 GB/s（3.2 GB/s 时钟上限下的 CPU 受限状态 ——
  Android 的状态也如此）。

MEM_CLK 梯级状态（今日全部寄存器验证）：

| opp-peak | MEM_CLK | 说明 |
|---|---|---|
| （pre-860 INT_MAX） | 1066 MHz（PLL 开） | 该 bug |
| 0 | 200 MHz（GPLL0/4） | RPM 下限；最凉；1.6 GB/s 上限 |
| **3200000** | **400 MHz（GPLL0/2）** | **Android 对等（当前）** |
| 8528000 | 1066 MHz | PLL 最大；永不交付 |

2.5 h 空闲浸泡运行中（soak400.log）以比较稳定 pm8916 vs 200 MHz
稳定基线（43.6-44.3 C）和 Android 同日（43.2-45.5 C）。Android 本身运行
400 MHz 且是凉爽参考，因此预期对等；浸泡量化额外 200 MHz 相对 0 值构建的成本。


### S17 附录 - 400 MHz 空闲浸泡最终（2.5 h，150 样本）

原始日志：Docs/Thermal/data/hmuf02v5-soak400-2026-10-24.log（epoch + pm8916 毫-C，
60 s 样本，设备全程空闲，opp-peak=3200000 镜像）。

| 窗口 | 最小 / 均值 / 最大（pm8916） |
|---|---|
| 前 10 分钟 | 48.4 / 49.3 / 50.7（刷写+基准残余） |
| 25-40%（约 1 h） | 39.5 / 41.3 / 46.9 |
| 50-75% | 39.3 / 41.0 / 43.8 |
| 最后 20%（稳定） | 39.7 / 40.6 / 42.2 |

读数：

- 400 MHz 构建稳定于约 40.6 C —— 等于或低于 Android 同日空闲带
  （43.2-45.5 C）。热差距目标在精确 Android 时钟下成立。
- 更早同日读数（200 MHz 构建约 2.5 h 稳定 43.6-44.3；30 分钟
  51-52 C 平台）都在仍在排放 —— 此浸泡延长至 2.5 h
  且**仍**在缓慢下降（中窗到最后窗均值 41.3 -> 40.6）。
  真正平衡需要比任何会话长日志器更长；将空闲比较
  视为稳定趋势，而非绝对平衡。
- 严格 200-vs-400 空闲归因混淆（环境在
  下午/傍晚下降；启动排放尾部重叠）。干净的是：在精确 Android
  时钟下单元匹配或优于 Android 空闲带，这是目标度量。
- 未来决定性空闲 A/B（可选）：同会话交叉（200 MHz 和 400 MHz
  镜像一晚背靠背刷写，每个 >=3 h 浸泡，同时 Android
  参考）—— 或接受目标基于上述证据达成。
