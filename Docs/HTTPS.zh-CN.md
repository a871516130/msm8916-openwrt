> 📄 本文件是 [HTTPS.md](HTTPS.md) 的英文原文中文译本，内容以英文版为准。

# Web 管理面板上的 HTTPS

每个镜像从首次启动起就**同时**通过 HTTP 和 HTTPS 提供 LuCI。 不需要启用
任何东西，也没有重定向：`http://<device>/` 照常工作，`https://<device>/`
同样可用。

---

## 随附内容

| 组件 | 位置 |
| :---- | :---- |
| `px5g-mbedtls` | 每块板子 —— `msm89xx/Makefile` 中的 `DEFAULT_PACKAGES` |
| `listen_https 0.0.0.0:443` 和 `[::]:443` | uhttpd 默认配置 |
| `redirect_https 0` | uhttpd 默认配置 —— **有意为之** |
| `cert /etc/uhttpd.crt`、`key /etc/uhttpd.key` | uhttpd 默认配置 |

`px5g` 是证书生成器：当证书文件缺失时，`uhttpd` 在首次启动时调用它，
因此密钥对是**在设备上**创建的，每根棒状设备唯一，且永不离开设备。

### 生成的证书长什么样

```
subject   CN=<hostname>            (msm8916-openwrt unless you renamed the device)
key       EC P-256                 (587-byte cert, 121-byte key)
validity  397 days                (the CA/Browser Forum maximum)
country   ZZ, state Somewhere, location Unknown
```

这些是上游的 `config cert defaults`；如果你想要不同的通用名或密钥类型，
在 `/etc/config/uhttpd` 中覆盖它们。

---

## 为什么没有重定向

`redirect_https=1` 会破坏每一个纯 HTTP 客户端——脚本、主机上的 `curl`、
恢复镜像、以及告诉你打开 `http://192.168.8.1/` 的首次启动说明。
自签名证书本身也会产生浏览器警告，而重定向会把这个警告变成对任何
非交互式程序的硬失败。

所以两个监听器都保持运行。 如果你*想要*重定向，只需一个 uci 值：

```sh
uci set uhttpd.main.redirect_https='1'
uci commit uhttpd
/etc/init.d/uhttpd restart
```

> **陷阱：** 该值位于 `/etc/config/uhttpd`，也就是在 **overlay** 中。
> 保留配置的 `sysupgrade` 会保留它，因此你曾设为重定向的棒状设备在升级后
> 仍会继续重定向，尽管镜像出厂值是 `0`。 当 HTTP 意外停止工作时，用
> `uci get uhttpd.main.redirect_https` 检查，并与
> `/rom/etc/config/uhttpd` 对比。

---

## 使用你自己的证书

把证书对放到位并重启 uhttpd：

```sh
cp my.crt /etc/uhttpd.crt
cp my.key /etc/uhttpd.key
chmod 600 /etc/uhttpd.key
/etc/init.d/uhttpd restart
```

要让浏览器接受证书，通用名 / SAN 必须与你实际用来访问该棒状设备的名字
（它的 IP，或你指向它的 DNS 名称）匹配。 公共 CA 无法为私有地址签发证书，
因此在局域网上你要么使用本地 CA，要么每个浏览器接受一次警告。

---

## 检查

```sh
# from a host
curl -k -I https://192.168.8.1/          # HTTP/1.1 200 OK
curl -I  http://192.168.8.1/             # still works, no 301

# on the device
ls -l /etc/uhttpd.crt /etc/uhttpd.key
netstat -ltn | grep -E ':80 |:443 '
logread | grep -i uhttpd
```

如果 `:443` 缺失，说明 `px5g-mbedtls` 未安装——检查
`msm89xx/Makefile` 中的 `DEFAULT_PACKAGES`（它随每块板子发行）。

---

## 说明

* 证书**不在**设备之间共享，因此每根棒状设备显示自己的警告。 这是预期行为，
  不是 bug。
* 重新生成只需 `rm /etc/uhttpd.crt /etc/uhttpd.key`，然后
  `/etc/init.d/uhttpd restart`。
* `sysupgrade -n` 会清空 overlay，因此证书会在下次启动时用新密钥重新生成。
