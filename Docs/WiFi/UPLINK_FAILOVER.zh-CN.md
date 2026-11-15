> 📄 本文件是 [UPLINK_FAILOVER.md](UPLINK_FAILOVER.md) 的英文原文中文译本，内容以英文版为准。

# 双上行 failover（调制解调器 + Wi-Fi station）

HMU05 / HMUF02 板子有两条通往互联网的路径：

- LTE 调制解调器 —— wwan0，由 ModemManager 驱动（network.modem）。 netifd
  拥有它的三层并安装默认路由。
- Wi-Fi station —— phy0-sta0，由 wifi-sta-late / wifi-sta-up（Station Mode）
  延迟拉起。 netifd 被有意隔离在这个 vif 之外：由 netifd 管理的 station
  接口会让 netifd 重启无线电，那会崩溃 WCNSS 固件。

uplink-manager 用健康探测和用户策略从这两者中选一个作为活动默认路由。 它
从不碰 netifd 的调制解调器配置、也从不重启无线电——它只添加/删除一条覆盖
路由，并把 dnsmasq 指向活动链路的 DNS。

## 路由阶梯

metric 更低者胜。 管理器维护三个 metric：

    Metric  Owner              Meaning
    40      uplink-manager     STA override -- installed only when the STA is active
    50      netifd + manager   modem default route (manager normalises it to 50)
    100     wifi-sta-dhcp.sh   STA candidate -- fallback, modem wins while present

结果：
- 调制解调器健康、STA down —— 调制解调器（50）是唯一路由。
- 调制解调器健康、STA up —— 调制解调器（50）仍然胜出；STA 以 100 待命。
- 调制解调器不健康、STA 健康 —— STA 覆盖路由（40）胜出。
- 两者都 down —— active=none，没有默认路由，没有互联网。

如果 uplink-manager 完全挂掉，netifd 的调制解调器路由（50）和 STA 候选
（100）仍提供无覆盖的调制解调器优先服务——板子优雅降级。

## 策略

在 "uci set uplink.general.policy=..."（或 LuCI 的 Network -> Station Mode ->
Uplink）中设置：

- auto（默认）—— 调制解调器健康时胜出；只有在调制解调器没有路由或健康探测
  失败时，station 才接管。
- modem —— 只用调制解调器；即使调制解调器 down 也绝不选择 station。
- sta —— 优先 station；station 不健康时回退到调制解调器。

## 健康探测

每条链路每隔 probe_interval 秒用 "ping -I <device> <probe_target>" 探测
（默认 30s，目标 1.1.1.1）。 连续 fail_threshold 次探测失败（默认 3）后
链路被标记为 down，连续 recover_threshold 次成功（默认 2）后恢复 up。
修改配置并保存 LuCI 页面（或对管理器 "kill -USR1"）会立即重新评估。

## DNS

当 station 是活动链路时，dnsmasq 被指向 uplink.general.sta_dns
（默认 8.8.8.8 8.8.4.4，优先于 AP 的 DNS）。 当调制解调器活动时，显式
服务器列表被清空，于是 dnsmasq 使用调制解调器的上游解析器。 station 的
DHCP 脚本在拿到租约时也会写入 sta_dns，因此即使在 uplink-manager 运行之前
该优先级也存在。

## 文件

msm89xx-scripts：
- /usr/sbin/uplink-manager —— 管理器循环。
- /etc/init.d/uplink-manager —— procd 服务（START=97，respawn）。
- /etc/config/uplink —— 策略与探测调优。
- /usr/sbin/wifi-sta-dhcp.sh —— 拿到租约时安装地址 + 路由（metric 100）+ DNS
  并记录 /tmp/wifi-sta-lease；deconfig 时拆除它们并通知管理器。
- /usr/sbin/wifi-sta-up —— apply_firewall() 把 phy0-sta0 绑到 wan zone（只在
  防火墙层；netifd 永远看不到该 vif）。
- /etc/uci-defaults/95-wifi-sta-late —— 首次启动时启用管理器服务。

luci-app-wifi-sta：
- htdocs/luci-static/resources/view/wifi-sta/uplink.js —— Network -> Station Mode ->
  Uplink 页面：实时状态（活动链路、每条链路的 state/device/gateway/DNS）以及
  策略表单。 保存会重启 uplink-manager。
- menu.d / acl.d —— Uplink 菜单项，以及授予 uplink uci 访问、
  /tmp/uplink.json 读取和 /etc/init.d/uplink-manager exec 的 rpcd ACL。

## 实时状态

/tmp/uplink.json 每个探测周期重写一次：

    {
      "active": "sta",
      "policy": "auto",
      "modem": { "present": 0, "healthy": 0, "device": "", "gateway": "" },
      "sta":   { "present": 1, "healthy": 1, "device": "phy0-sta0", "gateway": "10.0.0.1", "dns": "8.8.8.8 8.8.4.4" }
    }

## station down 时会发生什么

wifi-sta-late stop（或 DHCP deconfig / 关联丢失）会移除 station 地址。
wifi-sta-dhcp.sh 删除路由 + DNS + 租约并通知管理器。 管理器的 read_sta
只在 phy0-sta0 仍承载地址时才信任租约，因此 udhcpc 不干净退出后残留的租约
绝不会被误认为活链路。 station 没了而调制解调器健康时，调制解调器路由
（50）成为唯一路径，流量自动流动。 如果调制解调器也 down，active=none，
没有互联网。 没有无线电重启，没有固件崩溃。
