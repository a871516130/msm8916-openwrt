# BBR 作为默认 TCP 拥塞控制

**状态：** 已发布（自 25.12.6 起默认）· **文件：** `msm89xx/base-files/etc/sysctl.d/10-bbr.conf`、`msm89xx/modules.mk`、`msm89xx/Makefile`、`msm89xx/config-6.12`

## TL;DR

OpenWrt 将 **CUBIC** 作为默认 TCP 拥塞控制发布。在此移植版上，我们把默认切换为 **BBR**，因为本项目中每个板卡的主要 WAN 都是 **4G/LTE 承载**，而 CUBIC 的核心假设 —— *“丢包意味着网络拥塞”* —— 在无线电链路上是错的。

切换是启动时的一个 sysctl：

~~~conf
net.ipv4.tcp_congestion_control = bbr
~~~

没有用户空间守护进程，没有按连接调优，无需配置。参见 [我们改了什么](#what-we-changed-in-the-tree) 了解确切的管道，[回退](#reverting) 了解如何回去。

---

## 1. 拥塞控制算法到底做什么

TCP 不知道路径能承载多快。因此每个 TCP 发送端都运行一个猜测路径容量的算法，并设置两个数字：

| 旋钮 | 含义 |
| :--- | :--- |
| **cwnd**（拥塞窗口） | ACK 回来前可有多少字节在途 |
| **pacing rate**（发送速率） | 这些字节被注入 NIC 的速度 |

设得太低，链路利用不足。设得太高，多余部分在路由器或基站排队 —— 延迟上升，最终有东西丢包。算法的全部工作就是刚好停在队列开始堆积点之下。

两类算法的区别在于*它们用哪个信号找到那个点*：

- **基于丢包**（Reno、CUBIC —— OpenWrt 默认）：持续增大窗口直到丢包，然后猛砍窗口。丢包*就是*拥塞信号。
- **基于模型**（BBR）：直接测量**投递速率**和**最小 RTT**，并按该速率发送。丢包被视为噪声，而非信号。

---

## 2. 为什么 CUBIC 不适合 LTE 链路

CUBIC（RFC 9438）对有线路径是极好的算法，那里丢包几乎总是意味着某个缓冲区满。LTE 承载从五个方面打破这一假设。

### 2.1 LTE 上的丢包大多*不是*拥塞

蜂窝链路因与满队列无关的原因丢包：

- **射频衰落和干扰。** SINR 持续变化；深度衰落会丢块。
- **链路自适应按设计运行在约 10 % BLER。** LTE 的自适应调制编码刻意瞄准约 10 % 的首次传输块错误率 —— 它就是这样探测最高可用 MCS 的。HARQ 恢复大部分，但残余丢失，更重要的是**乱序和数百毫秒级的延迟尖峰**泄漏到 TCP。
- **切换。** 小区切换会使承载停顿片刻，并可能重排正在传输的包。
- **调度器授权。** 上行链路是授权制的；一阵 TCP ACK 与数据竞争授权，所以 ACK 流本身是突发且抖动的。

CUBIC 把这些都解读为“路径拥塞”并砍窗口 —— 即使路径远未接近满。在边缘信号上，这变成以可达速率的一小部分进行的永久锯齿。

### 2.2 缓冲区巨大（bufferbloat）

一个 eNodeB 和运营商的网关为每个承载缓冲数百毫秒的流量。基于丢包的发送端在*看到*告诉它停止的丢包之前就填满了那个缓冲区。那种排队积压是经典的 bufferbloat 模式，在 LTE 上很严重：

- 空闲 RTT 通常是 **30–80 ms**
- 在 CUBIC 批量下载下，同一路径可以停在 **300–2000 ms**

交互式流量（SSH、DNS、LuCI、调制解调器自己的 QMI 往返）随后共享那个队列，并在*下载运行时*变得不可用，尽管下载本身报告健康的吞吐量数字。

### 2.3 RTT 高且多变

CUBIC 的窗口增长是 RTT 的函数，所以它在长 RTT 路径上收敛缓慢，而每个延迟尖峰（见 2.1）都重置其状态。LTE RTT 也因与负载无关的原因变动 —— DRX 睡眠周期、调制解调器的电源状态、承载重建都会增加数十到数百毫秒。

### 2.4 容量每几毫秒就变化

LTE 在几乎每个子帧上重新选择 MCS，所以承载的瞬时容量是个移动目标。基于丢包的算法无法区分“容量刚因 SINR 下降而下降”和“容量未变而我溢出了缓冲区” —— 两者看起来都像丢包，都触发相同的退避。

### 2.5 上行通常才是稀缺方向

在许多消费级 LTE 套餐和小区上，上行是瓶颈，并以小授权调度。CUBIC 突发、窗口驱动的发送与授权制调度器交互不良：突发超过授权，在调制解调器中排队，并膨胀算法用来决策的那个 RTT。

---

## 3. BBR 改为做什么

BBR（瓶颈带宽和往返传播时间，Cardwell 等，ACM Queue 2017）维护两个运行估计：

| 估计 | 如何测量 |
| :--- | :--- |
| **BtlBw** —— 瓶颈带宽 | 约最近 10 个往返内的实测投递速率（ACK 的字节 / 时间）的窗口化**最大值** |
| **RTprop** —— 传播 RTT | 最近 10 秒内的**最小** RTT 窗口 |

然后它以 `pacing_gain × BtlBw` 发送，`cwnd = cwnd_gain × BtlBw × RTprop`。因为 RTprop 是*最小* RTT —— 无队列的 RTT —— 那个窗口正是路径在**无积压队列**下能容纳的数据量。BBR 同时保持管道满和缓冲区空。

其状态机是四个阶段：

- **Startup** —— 指数增长，直到投递速率连续三轮不再增加（它直接检测平台，不等待丢包）。
- **Drain** —— 短暂慢发以清空 Startup 创建的队列。
- **ProbeBW** —— 稳态：八阶段循环（1.25 → 0.75 → 1 ×6），每循环向上探测一次更多带宽，然后退避以排空。
- **ProbeRTT** —— 每 10 秒，如果最小 RTT 未被重新测量，短暂降到 4 包发送 200 ms 以重新采样真实传播延迟。

在蜂窝链路上的实际后果：

1. **丢包不再导致窗口塌缩。** 衰落或切换不再损耗吞吐量；BBR 只是按它测得的速率继续发送。
2. **无积压队列，所以负载下延迟保持接近空闲。** 这是口袋路由器的头条收益：批量下载不再让 SSH 和 Web UI 不可用。
3. **容量变化被直接跟踪。** 投递速率下降在几个往返内被观察并适应，而不是在缓冲区已满后从丢包推断。
4. **发送平滑（pacing）。** BBR 对包做 pacing 而不是一次倒出整个窗口，这更适合授权制的 LTE 上行调度器和调制解调器内部队列。

### 诚实的局限

- **BBRv1 公平性。** Linux 6.12 发布 BBRv1。当 BBR 流与基于丢包的流共享瓶颈时，BBRv1 可能拿走超出其份额。在此设备上不是这种情况：瓶颈是单个用户的 LTE 承载，内部竞争的流都是我们的。如果你把这台盒子当作拥塞共享小区后繁忙的多客户端热点，部署前请评估。
- **它不会让弱信号更快。** 它让延迟可预测，并把吞吐量保持在无线电实际能投递的附近。如果 SINR 差，链路仍然慢。
- **它不影响 UDP 或 QUIC。** 那些协议自带拥塞控制；sysctl 只改 TCP。
- **它不改变调制解调器的队列。** BBR 对 *AP 的* TCP 发送端做 pacing。eNodeB 的缓冲区和调制解调器固件自己的队列不受影响。

---

## 4. 我们在树中改了什么

| 文件 | 变更 |
| :--- | :--- |
| `msm89xx/config-6.12`（目标内核配置，所有 7 个板卡共享） | `CONFIG_TCP_CONG_BBR=m` —— 以模块构建 `net/ipv4/tcp_bbr.ko` |
| `msm89xx/modules.mk` | `KernelPackage/sched-bbr` → 包 `kmod-sched-bbr`，发布 `tcp_bbr.ko`，`AUTOLOAD := $(call AutoLoad,30,tcp_bbr)` |
| `msm89xx/Makefile` | `kmod-sched-bbr` 在 `DEFAULT_PACKAGES` 中 —— 预装到每个镜像 |
| `msm89xx/base-files/etc/sysctl.d/10-bbr.conf` | `net.ipv4.tcp_congestion_control = bbr` —— 使其成为**默认** |

### 为什么用 sysctl 而不是守护进程

自动加载模块只让算法*可用*；内核保持 `net.ipv4.tcp_congestion_control` 已有的值，而内核内建默认是 `cubic`。`/etc/sysctl.d/` 中一行就够，因为启动顺序已经理顺：

| 步骤 | Init 脚本 | `START` | 效果 |
| :--- | :--- | :--- | :--- |
| 1 | `/etc/init.d/boot` | **10** | 运行 `/sbin/kmodloader`，它从自动加载段落加载 `tcp_bbr` 并注册该算法 |
| 2 | `/etc/init.d/sysctl` | **11** | 应用 `/etc/sysctl.d/*.conf` 和 `/etc/sysctl.conf` |

所以 `bbr` 在选择它的 sysctl 之前注册。没有重试循环，没有 `preinit` 技巧，没有 `sleep`。（如果顺序曾退化，内核会用 `ENOENT` 拒绝写入，系统会静默停留在 CUBIC —— 值得每个镜像检查一次，见下文。）

### 为什么不用 `CONFIG_DEFAULT_TCP_CONG="bbr"`？

因为做不到。`CONFIG_DEFAULT_TCP_CONG` 由内核内建 TCP 栈在启动时解析，所以它只能命名**内建到** `vmlinux` 的算法。`tcp_bbr` 此处是 `=m`（上游也没有把它内建为默认的 Kconfig 选项），所以内核启动时回退到 `cubic`，而 sysctl —— 在模块加载后一秒运行 —— 是选择它的唯一正确方式。

### 为什么不动 qdisc

BBR 常与 `fq` qdisc 配对。这种配对源于 4.20 之前的内核，那时 `fq` 实现了 BBR 的 pacing。自 4.20 起 BBR 通过 TCP 栈自己的高分辨率定时器内部 pacing，所以**任何** qdisc 都行。OpenWrt 的默认是 `fq_codel`，这对共享 Wi-Fi AP 是好的选择（它也处理非 TCP 流量），所以我们保留它：

~~~text
# tc qdisc show dev wwan0
qdisc fq_codel 0: root refcnt 2 limit 10240p flows 1024 quantum 1514 target 5ms interval 100ms ...
~~~

---

## 5. 在实机上验证

~~~sh
# 1. 模块已加载
lsmod | grep tcp_bbr

# 2. bbr 已注册且是活动默认
cat /proc/sys/net/ipv4/tcp_available_congestion_control   # cubic reno bbr
cat /proc/sys/net/ipv4/tcp_congestion_control             # bbr

# 3. 活动连接确实在用
ss -tin state established '( dport = :443 )' | head -20
~~~

`ss -tin` 在每个 socket 上打印使用的算法加上 BBR 自己的诊断（`bbr (bw,rtt)`），所以你可以确认新连接 —— 不只是默认 —— 在 BBR 上。

### 测量收益

要检验的主张是*“延迟在负载下保持平稳”*，而非*“吞吐量上升”*。饱和下行链路并观察 RTT：

~~~sh
# 链路空闲时的基线 RTT
ping -c 20 1.1.1.1 | tail -2

# CUBIC
sysctl -w net.ipv4.tcp_congestion_control=cubic
wget -q -O /dev/null http://<a-large-file-on-the-internet> &
sleep 5; ping -c 40 -i 0.2 1.1.1.1 | tail -2; kill %1

# BBR
sysctl -w net.ipv4.tcp_congestion_control=bbr
wget -q -O /dev/null http://<a-large-file-on-the-internet> &
sleep 5; ping -c 40 -i 0.2 1.1.1.1 | tail -2; kill %1
~~~

在 CUBIC 下，负载 RTT 通常攀升到数百毫秒或更多。在 BBR 下应保持接近空闲值。也比较报告的 `wget` 吞吐量 —— 在干净信号下两者应相似，因为赢的是延迟，而非原始带宽。

---

## 6. 回退

每次启动（直到下次重启）：

~~~sh
sysctl -w net.ipv4.tcp_congestion_control=cubic
~~~

永久 —— 要么删除 drop-in 文件：

~~~sh
rm /etc/sysctl.d/10-bbr.conf
~~~

要么保留文件并把值改为 `cubic`。按目的地的覆盖也有效，如果你的 `iproute2` 支持该路由属性：

~~~sh
ip route change default via 10.64.64.64 dev wwan0 congctl cubic
~~~

`kmod-sched-bbr` 包在每种情况下都可以保持安装 —— 它只让算法可用，不选择它。

---

## 7. 参考资料

- **RFC 9438** —— 快速与长距离网络的 CUBIC
- **RFC 5681** —— TCP 拥塞控制
- Cardwell、Cheng、Gunn、Hassas Yeganeh、Jacobson —— *BBR：基于拥塞的拥塞控制*，ACM Queue，2017
- Linux `Documentation/networking/tcp_bbr.rst`

## 相关

- [**Docs/Custom Packages/Kernel-Modules.md**](Custom%20Packages/Kernel-Modules.md) —— `kmod-sched-bbr` 包行
- [**Docs/ARCHITECTURE.md**](ARCHITECTURE.md) —— `base-files`、`modules.mk` 和 `config-6.12` 在树中的位置
