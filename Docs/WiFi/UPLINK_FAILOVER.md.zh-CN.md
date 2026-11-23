# 双上行链路故障切换（调制解调器 + Wi-Fi station）

HMU05 / HMUF02 板卡有两条通往互联网的路径：

- LTE 调制解调器 —— wwan0，由 ModemManager 驱动（network.modem）。netifd 拥有其第三层并安装默认路由。
- Wi-Fi station —— phy0-sta0，由 wifi-sta-late / wifi-sta-up 延迟启动（Station Mode）。netifd 被刻意避开这个 vif：netifd 管理的 station 接口会让 netifd 重启无线电，这会崩溃 WCNSS 固件。

uplink-manager 用健康探测和用户策略选择其中一条作为活动的默认路由。它从不触碰 netifd 的调制解调器配置，也从不重启无线电——它只添加/移除一条覆盖路由，并把 dnsmasq 指向活动链路的 DNS。

## 路由阶梯

度量（metric）越小越优先。管理器维护三个度量：

    Metric  Owner              Meaning
    40      uplink-manager     STA 覆盖 —— 仅在 STA 活动时安装
    50      netifd + manager   调制解调器默认路由（管理器将其归一化为 50）
    100     wifi-sta-dhcp.sh   STA 候选 —— 回退，存在时调制解调器获胜

结果：
- 调制解调器健康，STA 关闭 → 调制解调器（50）是唯一路由。
- 调制解调器健康，STA 启动 → 调制解调器（50）仍胜出；STA 是 100 处的备用。
- 调制解调器不健康，STA 健康 → STA 覆盖（40）胜出。
- 两者都关闭 → active=none，无默认路由，无互联网。

如果 uplink-manager 整个死掉，netifd 的调制解调器路由（50）与 STA 候选（100）仍提供调制解调器优先的服务，无覆盖——板卡优雅降级。

## 策略

在 "uci set uplink.general.policy=..."（或 LuCI 的 Network → Station Mode → Uplink）中设置：

- auto（默认）——调制解调器健康时胜出；仅当调制解调器无路由或健康探测失败时 station 接管。
- modem —— 仅调制解调器；即使调制解调器关闭也从不选择 station。
- sta —— 优先 station；station 不健康时回退到调制解调器。

## 健康探测

每条链路每 probe_interval 秒用 "ping -I <device> <probe_target>" 探测（默认 30s，目标 1.1.1.1）。连续 fail_threshold 次探测失败（默认 3）后链路标记为关闭，连续 recover_threshold 次成功（默认 2）后重新标记为开启。更改配置并保存 LuCI 页面（或对管理器 "kill -USR1"）会立即重新评估。

## DNS

当 station 是活动链路时，dnsmasq 被指向 uplink.general.sta_dns（默认 8.8.8.8 8.8.4.4，优先于 AP 的 DNS）。当调制解调器活动时，显式服务器列表被清空，使 dnsmasq 使用调制解调器的上游解析器。station DHCP 脚本也会在租约时写入 sta_dns，所以该偏好甚至在 uplink-manager 运行前就存活。

## 文件

msm89xx-scripts：
- /usr/sbin/uplink-manager —— 管理器循环。
- /etc/init.d/uplink-manager —— procd 服务（START=97，respawn）。
- /etc/config/uplink —— 策略与探测调优。
- /usr/sbin/wifi-sta-dhcp.sh —— 租约时安装地址 + 路由（metric 100）+ DNS 并记录 /tmp/wifi-sta-lease；deconfig 时拆除它们并通知管理器。
- /usr/sbin/wifi-sta-up —— apply_firewall() 将 phy0-sta0 绑定到 wan 区（仅防火墙层；netifd 从不看到该 vif）。
- /etc/uci-defaults/95-wifi-sta-late —— 首次开机启用管理器服务。

luci-app-wifi-sta：
- htdocs/luci-static/resources/view/wifi-sta/uplink.js —— Network → Station Mode → Uplink 页面：实时状态（活动链路、每链路状态/设备/网关/DNS）加策略表单。保存会重启 uplink-manager。
- menu.d / acl.d —— Uplink 菜单条目与授予 uplink uci 访问、/tmp/uplink.json 读取以及 /etc/init.d/uplink-manager exec 的 rpcd ACL。

## 实时状态

/tmp/uplink.json 每个探测周期重写一次：

    {
      "active": "sta",
      "policy": "auto",
      "modem": { "present": 0, "healthy": 0, "device": "", "gateway": "" },
      "sta":   { "present": 1, "healthy": 1, "device": "phy0-sta0", "gateway": "10.0.0.1", "dns": "8.8.8.8 8.8.4.4" }
    }

## station 关闭时会发生什么

wifi-sta-late stop（或 DHCP deconfig / 关联丢失）移除 station 地址。wifi-sta-dhcp.sh 删除路由 + DNS + 租约并通知管理器。管理器的 read_sta 仅在 phy0-sta0 仍携带地址时信任租约，所以不干净的 udhcpc 退出后残留的租约永远不会被误认为活动链路。station 消失且调制解调器健康时，调制解调器路由（50）成为唯一路径，流量自动流动。如果调制解调器也关闭，active=none 且无互联网。无无线电重启、无固件崩溃。
