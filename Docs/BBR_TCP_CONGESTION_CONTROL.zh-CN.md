> 📄 本文件是 [BBR_TCP_CONGESTION_CONTROL.md](BBR_TCP_CONGESTION_CONTROL.md) 的英文原文中文译本，内容以英文版为准。

# 将 BBR 作为默认 TCP 拥塞控制

**状态：** 已随附（自 25.12.6 起为默认）· **文件：** `msm89xx/base-files/etc/sysctl.d/10-bbr.conf`、`msm89xx/modules.mk`、`msm89xx/Makefile`、`msm89xx/config-6.12`

## TL;DR

OpenWrt 以 **CUBIC** 作为默认 TCP 拥塞控制出厂。 在这个移植版里我们把默认值
换成 **BBR**，因为本项目中每块板子的主 WAN 都是 **4G/LTE 承载**，而 CUBIC
的核心假设——“*丢包意味着网络拥塞*”——在无线链路上是不成立的。

这次切换只是启动时的一个 sysctl：

~~~conf
net.ipv4.tcp_congestion_control = bbr
~~~

没有用户态守护进程，没有按连接调优，没有任何要配置的东西。 具体接线见
[我们改了什么](#4-我们在代码树中改了什么)，回退见 [回滚](#6-回滚)。

---

## 1. 拥塞控制算法到底做什么

TCP 根本不知道路径能跑多快。 因此每个 TCP 发送端都运行一个算法来猜测路径
容量，并设定两个数字：

| 旋钮 | 含义 |
| :--- | :--- |
| **cwnd**（拥塞窗口） | 在 ACK 返回之前允许有多少字节在途 |
| **pacing rate**（发送速率） | 这些字节以多快的速度注入网卡 |

设得太低，链路利用不足；设得太高，多余的数据会在路由器或基站里排队——
延迟攀升，最终有东西开始丢包。 该算法的全部工作就是恰好停在队列开始
堆积的那个点之下。

两大类算法的区别在于*用什么信号找到那个点*：

- **基于丢包**（Reno、CUBIC——OpenWrt 的默认）：不断增大窗口直到丢包，
  然后猛砍窗口。 丢包*就是*拥塞信号。
- **基于模型**（BBR）：直接测量**交付速率**和**最小 RTT**，并按该速率发送。
  丢包被视为噪声，而不是信号。

---

## 2. 为什么 CUBIC 不适合 LTE 链路

CUBIC（RFC 9438）对有线路径是出色的算法，那里的丢包几乎总是意味着某处
缓冲已满。 LTE 承载从五个不同方面打破了那个假设。

### 2.1 LTE 上的丢包大多*不是*拥塞

蜂窝链路丢包的原因与队列已满毫无关系：

- **射频衰落与干扰。** SINR 持续变化；深衰落会丢块。
- **链路自适应按设计工作在约 10 % BLER。** LTE 的自适应调制与编码故意以
  约 10 % 的首次传输块错误率为目标——这就是它探测最高可用 MCS 的方式。
  HARQ 能恢复其中大部分，但残余丢包，更重要的是**重排序和数百毫秒级的
  延迟尖峰**，仍会漏到 TCP。
- **切换（handover）。** 小区变更会让承载停顿片刻，并可能重排序在途数据包。
- **调度器授权。** 上行是基于授权的；一串 TCP ACK 会与数据竞争授权，
  因此 ACK 流本身是突发且抖动的。

CUBIC 把其中每一个都读成“路径拥塞了”并砍窗口——哪怕路径离跑满还差得远。
在信号边缘的情况下，这会变成远低于可达速率的永久锯齿波。

### 2.2 缓冲巨大（bufferbloat）

eNodeB 和运营商的网关为每条承载缓冲数百毫秒的流量。 基于丢包的发送端
在*看到*告诉它停止的丢包之前就把缓冲填满了。 那个常驻队列就是经典的
bufferbloat 模式，而在 LTE 上相当严重：

- 空闲 RTT 通常为 **30–80 ms**
- 在 CUBIC 大文件下载下，同一条路径可能停在 **300–2000 ms**

于是交互式流量（SSH、DNS、LuCI、调制解调器自身的 QMI 往返）与该队列
共享，并在*下载进行期间*变得不可用，尽管下载本身报告的吞吐数字很健康。

### 2.3 RTT 高且多变

CUBIC 的窗口增长是 RTT 的函数，因此在长 RTT 路径上收敛缓慢，而且每个
延迟尖峰（见 2.1）都会重置它的状态。 LTE 的 RTT 还会因与负载无关的原因
变化——DRX 睡眠周期、调制解调器的功耗状态、承载重建，都会增加几十到
几百毫秒。

### 2.4 容量每隔几毫秒就变

LTE 几乎在每个子帧上都重新选择 MCS，因此承载的瞬时容量是个移动靶。
基于丢包的算法无法区分“容量刚因为 SINR 下降而下降”和“容量没变而我冲过了
缓冲”——两者看起来都像丢包，两者触发同样的退避。

### 2.5 上行通常是稀缺方向

在许多消费级 LTE 套餐和小区里，上行是瓶颈，并以小授权调度。 CUBIC
突发式、窗口驱动的发送与基于授权的调度器配合得很糟：突发超过授权、在
调制解调器里排队，并把算法用来做决策的那个 RTT 自己给吹大了。

---

## 3. BBR 改而做什么

BBR（Bottleneck Bandwidth and Round-trip propagation time，瓶颈带宽与
往返传播时间，Cardwell 等，ACM Queue 2017）维护两个持续估计值：

| 估计值 | 如何测量 |
| :--- | :--- |
| **BtlBw**——瓶颈带宽 | 最近约 10 个往返内测得交付速率（被 ACK 的字节数 / 时间）的窗口**最大值** |
| **RTprop**——传播 RTT | 最近 10 秒内 RTT 的窗口**最小值** |

然后它按 `pacing_gain × BtlBw` 发送，且 `cwnd = cwnd_gain × BtlBw × RTprop`。
因为 RTprop 是*最小* RTT——没有队列时的 RTT——所以该窗口恰好是路径在
**没有常驻队列**的情况下能容纳的数据量。 BBR 让管道保持满的同时让缓冲
保持空。

它的状态机有四个阶段：

- **Startup（启动）**——指数增长，直到交付速率连续三轮不再上升
  （它直接检测平台期，而不是等丢包）。
- **Drain（排空）**——短暂放慢发送，清空 Startup 造成的队列。
- **ProbeBW（探测带宽）**——稳态：一个八阶段循环（1.25 → 0.75 → 1 ×6），
  每个循环向上探测一次更多带宽，并退避以排空。
- **ProbeRTT（探测 RTT）**——每 10 s，如果最小 RTT 尚未被重新测量，
  短暂排空到 4 个数据包、持续 200 ms，以重新采样真实传播延迟。

在蜂窝链路上的实际结果：

1. **丢包不再造成窗口塌陷。** 衰落或切换不再损失吞吐；BBR 只是继续按它
   测得的速率发送。
2. **没有常驻队列，因此负载下延迟保持接近空闲水平。** 这是口袋路由器的
   头号好处：大文件下载不再让 SSH 和 Web 管理界面变得不可用。
3. **容量变化被直接跟踪。** 交付速率的下降会在几个往返内被观测到并适配，
   而不是在缓冲已经填满之后从丢包反推。
4. **平滑发送端。** BBR 对数据包做 pacing，而不是一次倾倒整个窗口，这与
   基于授权的 LTE 上行调度器以及调制解调器的内部队列都匹配得好得多。

### 坦诚的局限

- **BBRv1 公平性。** Linux 6.12 出厂的是 BBRv1。 当一条 BBR 流与基于丢包的
  流共享瓶颈时，BBRv1 可能拿走超过其份额的带宽。 在这台设备上并非这种
  情形：瓶颈是单个订阅用户的 LTE 承载，其中竞争的流全是我们自己的。
  如果你把这台设备当作繁忙的多客户端热点、放在一个拥塞的共享小区后面，
  请先评估再部署。
- **它不会让弱信号变快。** 它让延迟可预测，并把吞吐保持在无线电实际能
  交付的水平附近。 如果 SINR 差，链路仍然慢。
- **它不影响 UDP 或 QUIC。** 那些协议自带拥塞控制；该 sysctl 只改 TCP。
- **它不改变调制解调器的队列。** BBR pacing 的是*AP 上的* TCP 发送端。
  eNodeB 的缓冲和调制解调器固件自身的队列原封不动。

---

## 4. 我们在代码树中改了什么

| 文件 | 改动 |
| :--- | :--- |
| `msm89xx/config-6.12`（目标 kernel 配置，全部 7 块板子共享） | `CONFIG_TCP_CONG_BBR=m` —— 以模块方式构建 `net/ipv4/tcp_bbr.ko` |
| `msm89xx/modules.mk` | `KernelPackage/sched-bbr` → 软件包 `kmod-sched-bbr`，随附 `tcp_bbr.ko`，`AUTOLOAD := $(call AutoLoad,30,tcp_bbr)` |
| `msm89xx/Makefile` | `kmod-sched-bbr` 进入 `DEFAULT_PACKAGES` —— 每个镜像都预装 |
| `msm89xx/base-files/etc/sysctl.d/10-bbr.conf` | `net.ipv4.tcp_congestion_control = bbr` —— 使其成为**默认值** |

### 为什么用 sysctl 而不是守护进程

自动加载模块只是让算法*可用*；kernel 保持 `net.ipv4.tcp_congestion_control`
当前的值，而 kernel 内建默认值是 `cubic`。 `/etc/sysctl.d/` 里一行就够了，
因为启动顺序本来就排好了：

| 步骤 | Init 脚本 | `START` | 效果 |
| :--- | :--- | :--- | :--- |
| 1 | `/etc/init.d/boot` | **10** | 运行 `/sbin/kmodloader`，它从 autoload 段加载 `tcp_bbr` 并注册该算法 |
| 2 | `/etc/init.d/sysctl` | **11** | 应用 `/etc/sysctl.d/*.conf` 和 `/etc/sysctl.conf` |

所以 `bbr` 在选择它的 sysctl 之前就已注册。 不需要重试循环、不需要
`preinit` 技巧、不需要 `sleep`。（如果顺序哪天回退了，kernel 会以 `ENOENT`
拒绝写入，系统会默默留在 CUBIC 上——值得每个镜像检查一次，见下文。）

### 为什么不设 `CONFIG_DEFAULT_TCP_CONG="bbr"`？

因为做不到。 `CONFIG_DEFAULT_TCP_CONG` 由 kernel 内建 TCP 协议栈在启动时
解析，所以它只能指定**内建进** `vmlinux` 的算法。 这里 `tcp_bbr` 是 `=m`
（而且上游也没有把它内建为默认的 Kconfig 选项），因此 kernel 启动时回退到
`cubic`，而在模块加载一秒后运行的 sysctl 是选择它的唯一正确方式。

### 为什么不动 qdisc

BBR 常与 `fq` qdisc 搭配。 这种配对源自 4.20 之前的内核，那时 `fq` 是实现
BBR pacing 的东西。 自 4.20 起 BBR 通过 TCP 协议栈自身的高精度定时器在
内部做 pacing，所以**任何** qdisc 都可以。 OpenWrt 的默认值是 `fq_codel`，
对共享 Wi-Fi AP 是个好选择（它也处理非 TCP 流量），所以我们保留它：

~~~text
# tc qdisc show dev wwan0
qdisc fq_codel 0: root refcnt 2 limit 10240p flows 1024 quantum 1514 target 5ms interval 100ms ...
~~~

---

## 5. 在实机上验证

~~~sh
# 1. the module is loaded
lsmod | grep tcp_bbr

# 2. bbr is registered and is the active default
cat /proc/sys/net/ipv4/tcp_available_congestion_control   # cubic reno bbr
cat /proc/sys/net/ipv4/tcp_congestion_control             # bbr

# 3. a live connection is actually using it
ss -tin state established '( dport = :443 )' | head -20
~~~

`ss -tin` 在每个套接字上打印所用算法以及 BBR 自身的诊断
（`bbr (bw,rtt)`），因此你可以确认新连接——而不只是默认值——跑在 BBR 上。

### 测量收益

要检验的主张是“*负载下延迟保持平稳*”，而不是“*吞吐上升*”。 打满下行并
观察 RTT：

~~~sh
# baseline RTT with the link idle
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

用 CUBIC 时，负载下的 RTT 通常会爬到几百毫秒甚至更高。 用 BBR 时它应保持
在接近空闲值的水平。 也对比一下 `wget` 报告的吞吐——在信号干净时两者应
该差不多，因为赢的是延迟，不是原始带宽。

---

## 6. 回滚

单次启动（直到下次重启为止）：

~~~sh
sysctl -w net.ipv4.tcp_congestion_control=cubic
~~~

永久——要么删掉这个 drop-in：

~~~sh
rm /etc/sysctl.d/10-bbr.conf
~~~

要么保留文件并把它的值改成 `cubic`。 按目标覆盖也可以，只要你的
`iproute2` 支持该路由属性：

~~~sh
ip route change default via 10.64.64.64 dev wwan0 congctl cubic
~~~

在任何情况下 `kmod-sched-bbr` 软件包都可以保持安装——它只让算法可用，
并不选择它。

---

## 7. 参考资料

- **RFC 9438** —— CUBIC for Fast and Long-Distance Networks
- **RFC 5681** —— TCP Congestion Control
- Cardwell、Cheng、Gunn、Hassas Yeganeh、Jacobson——*BBR: Congestion-Based
  Congestion Control*，ACM Queue，2017
- Linux `Documentation/networking/tcp_bbr.rst`

## 相关

- [**Docs/Custom Packages/Kernel-Modules.md**](Custom%20Packages/Kernel-Modules.md)
  —— `kmod-sched-bbr` 软件包那一行
- [**Docs/ARCHITECTURE.md**](ARCHITECTURE.md) —— `base-files`、`modules.mk`
  和 `config-6.12` 在代码树中的位置
