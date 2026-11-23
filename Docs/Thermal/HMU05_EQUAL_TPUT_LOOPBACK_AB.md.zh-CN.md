# 等吞吐量环回 A/B —— OpenWrt vs Android（2026-10-24）

状态：实验完成。与 `HMU05_LIVE_BUS_VOTING_AB.md`（总线投票关闭）
和 `HMU05_DEFINITIVE_THERMAL_FINDINGS.md` 配套。这是总线投票
文档计划的受控负载实验；负载生成器固定且速率匹配。

## 问题

OpenWrt 在等吞吐量下是否比 Android 更热？先前证据：真实 LTE 拉取
在 400 KB/s 下两者热相同；总线投票与 OS 无关（共享 RPM 硅片）。
本实验添加匹配速率、实测吞吐量的比较，含空闲基线和
CPU 利用率统计。

## 为何环回，而非 LTE

真实 LTE 高速 A/B 无法运行：OpenWrt busybox wget 对常见
速度测试主机仅解析 AAAA，其防火墙 REJECT v6 发送（`Failed to send request: Operation not
permitted`；到 speedtest.tele2.net 的 `uclient-fetch -4` 挂起）；Android 有 LTE L3 上（ping 8.8.8.8
正常）但解析器损坏（`nslookup` 应答 127.0.0.1；带字面 IP 的 `curl --resolve` 也
停滞）。批量 LTE 拉取也会烧 SIM 配额。环回保持一切
设备本地，无需外部主机，节流在**客户端**中，因此速率精确。
注意：环回锻炼 shell/HTTP 路径，而非调制解调器数据路径 —— 见注意事项。

## 方法

每设备：一个静态 4 MB 文件由设备自己的 HTTP 服务器服务，由 K 个并行
客户端循环通过 127.0.0.1 拉取；每次迭代拉 4 MB（busybox `dd bs=65536 count=64` —— 单次
`dd bs=4M` 读取仅返回管道缓冲，约 64 KB）然后睡眠 `usleep USLEEP`。日志器
每 5 s 采样：所有热区域、所有 `scaling_cur_freq`、以及前五个 `/proc/stat`
刻度（user nice sys idle iowait）。

- OpenWrt 服务器：已运行的 `uhttpd`（`/www/bigfile` 于端口 80）
- Android 服务器：busybox `httpd -p 8080 -h /data/local/tmp`（Android 无 `/tmp`；其 busybox
  `nc -l` 被拒：accept-gap 竞态在并发下给出 connection-refused）
- 标定：K=4 配相同 400 ms usleep 给出 OWRT 10.2 MB/s vs AND 16.0 MB/s。速率被
  通过减慢 Android（`usleep 800000`）匹配：最终匹配 10.78 vs 11.07 MB/s（相差 2.7%）。
- 每设备协议：空闲 30 s（K=0），然后负载 60 s（K=4）。相同物理类别单元
  （HMU05 系列）；单元间绝对基线不同，因此**匹配负载下的上升**是度量。
- 途中修复的陷阱：`pkill -f "httpd -p 8080"` 匹配自身远程 shell 的 cmdline 并
  杀死 ssh 会话（用 `pkill -x`）；后台监听器持有 ssh 管道 fd 打开，
  除非 stdout/stderr/stdin 全部重定向；主机侧 Bash 工具无法后台化
  长寿命服务器（每次此类调用挂起）—— 所有服务器都存在于设备上。

## 结果（60 s 负载阶段）

| 度量 | OpenWrt（hmuf02v5） | Android |
|---|---|---|
| 吞吐量 | 10.78 MB/s（646.7 MB） | 11.07 MB/s（664.2 MB） |
| CPU 忙（proc/stat，4 核，100 Hz） | 约 36% | 约 24% |
| pm8916（zone5）空闲基线 | 55.4 C | 43.6 C |
| 负载下 pm8916 上升 | +3.2 C（55.6 -> 58.9，仍在上升） | +1.9 C（44.2 -> 46.1） |
| 负载下 CPU 频率 | 800 MHz x4 | 800 MHz x4 |
| 空闲时 CPU 频率 | 多数 800 MHz（schedutil，偶发下探） | 钉住 800 MHz |
| 空闲时调制解调器区域 | 63-64 C（zone0 modem-thermal） | 52-53 C（tsens sensor0） |

标度：OpenWrt 区域是毫度。Android tsens 区域 0-4 是整数摄氏度
（已验证：它们在 CPU 压力下从 48 升至 60，而 pm8916_tz 移动毫度）；
`pm8916`/`pm8916_tz`（zone5）在**两者**上都是毫度，是苹果对苹果的传感器。
Android zone6 = 电池（33 C，惰性）。

## 分析

1. 在匹配吞吐量下 OpenWrt 燃烧约 1.5x CPU（36% vs 24% 忙）且板卡加热
   约 1.7x（pm8916 上升 +3.2 vs +1.9 C）。热随每字节 CPU 工作，而非 OS 本身。
2. 频率在负载下**不是**差异项：两者都将四核钉在 800 MHz。
3. 与真实 LTE 400 KB/s 对等结果（两者无上升）和总线投票
   关闭（共享 RPM 硅片，投票在两者上实时流动）结合，热差距**由
   每字节 CPU 工作差异解释**，即负载/效率混杂 —— 而非总线、核数、
   或频率缩放缺陷。
4. 单元间基线偏移（空闲 pm8916 55.4 vs 43.6 C）是为何绝对温度**永不**
   跨设备比较的原因；仅匹配负载下的上升有效。OpenWrt 单元也
   以调制解调器区域 63-64 C 空闲，在任何 AP 侧负载前预热整个板卡 ——
   调制解调器侧热状态主导板卡起点。

## 注意事项

- 测试台本身不对称：uhttpd（OpenWrt）是比
  busybox httpd（Android）更重的每请求服务器，且 busybox wget/uclient 进程派生成本不同。部分
  测得的 1.5x CPU 惩罚是测试台，而非 LTE 数据路径（其完全没有 HTTP 服务器）。
  方向上，在两个 OS 上更多每字节 CPU 工作 = 更多热。
- 60 s 短于板卡热时间常数；两个上升在截止时仍在上升。**比率**，而非绝对上升，是发现。
- 每配置单次试验。标定运行（20 s）重现相同排序
  （+1.9 vs +0.4 C 于 10.07 vs 10.7 MB/s），因此方向可重复。

## 开放问题

- 约 1.5x 每字节 CPU 惩罚是否在**真实**数据路径（调制解调器 -> USB -> NAT ->
  LAN）中持续？需要可靠的高速 LTE 负载源（或 USB 主机到 USB 设备 iperf 装置）。
- OpenWrt 空闲：为何 schedutil 在空闲时保持 800 MHz？（可能的轮询器保持 CPU
  忙足够；值得 `perf`/trace 查看 —— 它消耗空闲热。）
- Android 损坏的 DNS（解析 127.0.0.1）本身是差分表的 OS 差距数据点，
  与热无关。

## 测试台（可复现）

设备：OWRT root@192.168.7.1，AND root@192.168.100.1（无密码）。每设备客户端循环：

    while running; do N=$(wget -q -O - $URL | dd bs=65536 count=64 | wc -c); B+=N; usleep $US; done

K 个并行循环 + 一个 5 s 日志器（区域、频率、/proc/stat 头部）。脚本是临时的
（/tmp）；上面的数字和陷阱列表是记录。

## 跟进（同会话）：空闲差距也**非** OS 差距

A/B 之后，明显的剩余问题是 12 C 空闲 pm8916 偏移（55.4 vs 43.6）。
测量：

- cpuidle：OpenWrt 6.12 = `psci_idle` + `menu`，状态 WFI（lat 1）+ cpu-sleep-0（lat 280 us）。
  Android 3.10 = `msm_idle` + `menu`，状态 C0/C1/C2（lat 1/180/230 us）。深度相当 ——
  OpenWrt **确实**功率收起；无空闲路径缺陷。
- 空闲忙%：两者约 7%（来自空闲阶段 /proc/stat 刻度）。
- loadavg：OpenWrt 0.29；Android **3.5-5.5（15 分钟 5.46）** —— Android 单元运行长期更重
  AP 负载（框架）却是**更凉**的单元。这单独杀死任何'OpenWrt 空闲燃烧
  更多'理论。
- RF 对等：OpenWrt RSRP **-81.00 dBm** / RSRQ -12.0 / SNR 13.0 / RSSI -52（mmcli signal-setup
  5，然后读；轮询后重置为 0）。Android RSRP **-81** / RSRQ -11 / SNR 11.4
  （dumpsys telephony.registry）。同塔、同 TX 功率条件 —— TX 驱动的调制解调器热
  排除。
- 空闲流量：OpenWrt wwan0 约 2 KB/s keepalive（40 个 conntrack 条目，无真实流）；
  Android 约 0。两个调制解调器均不承载数据，但 OpenWrt 单元的调制解调器晶粒（zone0）空闲
  63-64 C vs Android 单元的 52-53 C。

固件逐字节相同、A2 策略对等（两者 a2_pin=1）、轨对等（1.0625 V == 1.05 V，
先前会话）、总线投票共享、核/频率/cpuidle/忙%/RF 全部对等，剩余空闲
调制解调器差距是**单元级/物理**（外壳贴合、USB 端口热耦合、天线/线缆放置），
而非 OS 属性。为实验性关闭它：交换两个单元的 USB 端口（或位置）并
重新记录空闲区域 30 分钟 —— 差距应跟随单元/端口，而非 OS。

## 最终对等矩阵（全部测量）

| 轴 | OpenWrt | Android | 对等 |
|---|---|---|---|
| CPU 核在线 | 4 | 4 | 是 |
| 负载下 CPU 频率 | 800 MHz x4 | 800 MHz x4 | 是 |
| CPU 轨 | 1.0625 V（CPR，先前会话） | 1.05 V | 是 |
| 总线投票 | 实时，RPM（共享硅片） | 实时，同一 RPM | 是 |
| cpuidle | WFI + cpu-sleep-0 @280 us | C0/C1/C2 @180/230 us | 是 |
| 空闲忙% | 约 7% | 约 7% | 是 |
| LTE RSRP | -81.0 dBm | -81 dBm | 是 |
| 空闲数据流量 | 约 2 KB/s | 约 0 | 可忽略 |
| A2 策略 | a2_pin=1（保持开） | 保持开 | 是 |
| 调制解调器固件 | 逐字节相同（已证明） | 相同 | 是 |
| 空闲 loadavg | 0.29 | 3.5-5.5 | Android 更忙且更凉 |

结论：在已收集的证据上无 OS 可控热杠杆剩余。差距是
(a) 持续负载下每字节 CPU 工作（合成路径中 OpenWrt 1.5x；真实 LTE 路径
未验证）和 (b) 空闲时单元级物理差异。
