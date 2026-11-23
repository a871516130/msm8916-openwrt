> **更正 2026-10-24（迟到）：** 下方的"总线投票热惰性 / 与 OS 无关"
> 结论被 `Docs/Thermal/rpmfindings.md` **部分推翻**：共享 RPM
> 固件在 OpenWrt 下将 BIMC/DDR（MEM_CLK）时钟保持在 MAX，而在
> Android 下约为 1/4 速率（在相同 CPU 频率下测得 4-7x DDR 带宽差异），因为
> 每个 OS 发送的投票不同（OpenWrt 的 cpu0 opp-peak-kBps 投票映射到 1066 MHz PLL 最大值；
> Android 的 msm_bus 从不将 MEM_CLK 投票上调）。先读 rpmfindings.md 了解 RPM/DDR 的故事。
>
# HMU05：总线投票审计 - OpenWrt vs Android（2026-10-24 更正）

状态：杠杆对 OpenWrt-vs-Android 热差距已**关闭**（原因如下）。
设备（均已 root，从开发主机无密码 SSH）：
- OpenWrt：192.168.7.1 - 内核 6.12.94，msm8916-openwrt 25.12.5-r6
- Android：192.168.100.1 - 内核 3.10.28，msm8916_32_512-userdebug 4.4.4

原始捕获：scratch/thermal_baseline/bus_voting_ab_2026-10-24/（ab_openwrt.txt、ab_android.txt、ab.sh）。

---

## 下会话 TL;DR

1. 总线投票**已**接线并在主线 msm8916.c 中激活。真实 RPM ID 存在且
   带宽投票实时流动（测量：mas_apss / slv_ebi_ch0 cpu0 峰值 = 8,528,000 kBps，随 CPU 频率跟踪）。
2. 两个表明总线投票损坏/惰性的较早证据读数都是**伪影**：
   - 'all mas_rpm_id = -1' grep（仅匹配主侧；从侧 + 桥接 ID 存在），且
   - 从 Linux debugfs 读取 bimc_ddr_clk_src = 800 MHz（该时钟由 RPM 管理且**无频率表**；
     Linux 无法观察 RPM 驱动的频率变化，因此读数无定论，而非无缩放的证明）。
3. 总线投票**不能**解释 OpenWrt-vs-Android 温度差距，因为 RPM 固件是共享
   硅片（非 OS 相关）。Android（msm_bus）和 OpenWrt（interconnect）都向
   **同一** RPM 通过 SMD 发送带宽投票；若 RPM 缩放 DDR/BIMC 时钟，它对两个 OS 同样做。若要说，
   Android 投票**更多**带宽（更多带宽感知消费者）且会让总线**更热**，而非更凉。
4. **不要**将 Android 的 msm_bus 主/从 ID 移植到 OpenWrt 的 interconnect 驱动。错误命名空间，
   不必要（主线 ID 已正确），且不解决差距。
5. 温度差距的剩余 OS 相关杠杆：CPU 频率缩放策略、热调控器/跳闸点、
   以及吞吐量混杂。见底部的受控等吞吐量 A/B 计划。

---

## 更正 1：'all mas_rpm_id = -1' 是 grep 伪影

interconnect 节点结构有两个投票字段：mas_rpm_id（主侧）和 slv_rpm_id
（从侧）。对 'mas_rpm_id = -1' 的 grep 返回 88 个节点中的 81 个 —— 但这仅证明
大多数节点的**主侧**投票是 -1。实际将带宽投票带到 RPM 的节点使用
**从侧**和桥接 ID，它们**已填充**：

drivers/interconnect/qcom/msm8916.c（构建树，linux-6.12.94）中存在的真实 RPM ID：
- slv_ebi_ch0       slv_rpm_id = 0     （DDR/BIMC 从 —— 主 CPU->DDR 投票汇）
- bimc_snoc_mas     mas_rpm_id = 99
- bimc_snoc_slv     slv_rpm_id = 130
- snoc_bimc_mas     mas_rpm_id = 101
- snoc_bimc_slv     slv_rpm_id = 132
- pcnoc_snoc_mas    mas_rpm_id = 29
- pcnoc_snoc_slv    slv_rpm_id = 45
- slv_imem          slv_rpm_id = 26
- （加上 PNOC/IMEM 从上的 slv_rpm_id 0/24/30）

这些是**正确**的主线 RPM ID；无需 Android ID 移植。

## 更正 2：'bimc_ddr_clk_src = 800 MHz => 总线不缩放' 是 Linux 视图伪影

在 OpenWrt 设备上实况检查：
- bimc_ddr_clk_src/clk_possible_rates 为空（无频率表）；
- 其父为 gpll0_vote 且 clk_enable_count = 1，显示的速率为 800,000,000 Hz。

在 msm8916 上 BIMC/DDR 时钟由 RPM 管理：实际频率在 RPM 固件内根据
带宽投票设置。Linux 时钟框架仅持有固定占位符（无频率表），因此
从 Linux debugfs 读取 clk_rate **总是**返回占位符 800 MHz，无论 RPM 实际
驱动硬件为何。先前 A/B 因此对物理缩放**毫无证明**。

无 RPM 时钟 debugfs 暴露给 Linux（检查：无 /sys/kernel/debug/rpm*，无 BCM 投票器 —— msm8916
使用旧式 RPM_SMD 带宽请求，而非 BCM）。因此物理 DDR 频率无法从 AP 直接观察。

## 实况证据（本会话，2026-10-24，OpenWrt 设备）

$ cat /sys/kernel/debug/interconnect/interconnect_summary
 node                 tag          avg         peak
 bimc_snoc_mas                      0            0
 mas_apss                   2147483647   2147483647
   cpu0                            0      8528000
 slv_ebi_ch0               2147483647   2147483647
   cpu0                            0      8528000
 ... (all other masters read 0) ...

$ bimc_ddr_clk_src rate=800000000  (占位符; RPM-managed, no freq table)
$ scaling_cur_freq (cpu0) = 800000  (采样时设备处于 800 MHz)

投票随 CPU 频率跟踪（高 OPP 时 8.5M kBps），确认 interconnect 框架和
RPM 发送路径活跃。采样时 CPU 处于 800 MHz，因此 8.5M 是中/高投票，而非空闲 —— 真正的
空闲采样仍需要以查看投票范围的低端。

## Android 实际做什么（参考内核，GitIgnore/android_kernel_zte_msm8916）

Android 使用 drivers/platform/msm/msm_bus/（msm_bus_rpm_smd.c）—— 一个与
主线 drivers/interconnect/qcom/ 完全不同**的驱动。它通过 SMD 使用自己的 ID 方案
（msm_bus_id.c）向 RPM 投票带宽。**相同**硅片、**相同** RPM 固件、**相同** SMD 带宽请求协议。因此 Android 和
OpenWrt 都驱动相同的 RPM 带宽投票；得到的物理总线频率由
RPM 决定，对任一 OS 相同。=> 总线投票与 OS **无关**，不能是 OS
相关温度差异的来源。

## 为何 Android msm_bus ID 移植**不是**修复

1. 命名空间不匹配：Android msm_bus ID 和主线 interconnect RPM ID 是不同枚举。
   将一个复制到另一个会向 RPM 发送**错误** ID。
2. 不必要：主线 msm8916.c 已携带正确 RPM ID（见更正 1）且投票实时流动。
3. 脱靶：即使投票缺失，两个 OS 投票同一 RPM，因此它不会关闭差距。

## 原始 A/B 热差距（保留记录；仍混杂）

吞吐量**未**均衡（历史 OpenWrt vs Android LTE 吞吐量差约 2x），因此绝对
度数数字因果上不干净。聚合片上 TSENS：
- 空闲：  OpenWrt 约 53.2 C 均值  vs  Android 约 45 C 最大
- 负载（10 MB 拉取）：OpenWrt 约 54.4 C 均值（峰值 58）  vs  Android 约 45 C 最大
=> OpenWrt 约 9-12 C 更热，但被吞吐量 + 环境 + CPU 频率策略混杂。

## 结论 / 推荐下一步

总线投票作为 OS 差距的热杠杆已关闭（OS 无关，已激活）。诚实的
剩余问题是差距在控制 OS 相关混杂后是否仍存在 POST-CPR。

所需下一步（取代'实现总线投票'任务）：
1. 受控等吞吐量 A/B：将两设备限速到相同 LTE 吞吐量（或传输
   相同固定负载），匹配环境/频带，每 n>=3 次运行。决策规则：
   - 匹配吞吐量下差距 <= 约 3 C  => 轨修复（成因 #3）+ 混杂解释它；热
     工作流关闭。
   - 差距持续  => 调查 OS 相关杠杆：CPU 频率缩放策略 / 热调控器 /
     跳闸点，以及匹配吞吐量下的调制解调器/RF 活动（**非**总线投票）。
2. 可选地带外确认物理 DDR 缩放问题（例如，持最大带宽投票 vs 空闲时的功率/热差）——
   但按上述论证，这与 OS 差距无关。

## 实现状态（2026-10-24）
- 总线投票代码：已实现（CONFIG_INTERCONNECT_QCOM_MSM8916=y，补丁 834）且实况证明。
  为热目的无需写新代码。
- '移植 Android msm_bus ID'：已取消 —— 错误命名空间，不必要，脱靶。
- 剩余动作：受控等吞吐量 A/B（非代码变更）。
