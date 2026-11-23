# Web 管理面板上的 HTTPS

每个镜像自首次启动起就**同时**通过 HTTP 和 HTTPS 提供 LuCI。无需启用任何
设置，也没有重定向：`http://<device>/` 照常工作，`https://<device>/` 同样可用。

---

## 随镜像提供的内容

| 组件 | 位置 |
| :---- | :---- |
| `px5g-mbedtls` | 每个板子——`DEFAULT_PACKAGES` 位于 `msm89xx/Makefile` |
| `listen_https 0.0.0.0:443` 和 `[::]:443` | uhttpd 默认配置 |
| `redirect_https 0` | uhttpd 默认配置——**有意为之** |
| `cert /etc/uhttpd.crt`、`key /etc/uhttpd.key` | uhttpd 默认配置 |

`px5g` 是证书生成器：当证书文件缺失时 `uhttpd` 会在首次启动时调用它，
因此密钥对是**在设备上**生成的，每个 U 盘唯一，且永不离开设备。

### 生成的证书长什么样

```
subject   CN=<主机名>            （msm8916-openwrt，除非你重命名了设备）
key       EC P-256                 （587 字节证书，121 字节密钥）
validity  397 天                （CA/Browser Forum 上限）
country   ZZ, state Somewhere, location Unknown
```

这些是上游 `config cert defaults` 的默认值；若想要不同的通用名或密钥类型，
可在 `/etc/config/uhttpd` 中覆盖。

---

## 为何没有重定向

`redirect_https=1` 会破坏所有纯 HTTP 客户端——脚本、从主机执行的 `curl`、
恢复镜像、以及告诉你打开 `http://192.168.8.1/` 的首次启动说明。
自签名证书还会触发浏览器警告，而重定向会把该警告变成所有非交互场景的硬性失败。

因此两个监听器都保持开启。如果你*想要*重定向，只需一个 uci 值：

```sh
uci set uhttpd.main.redirect_https='1'
uci commit uhttpd
/etc/init.d/uhttpd restart
```

> **陷阱：** 该值存在于 `/etc/config/uhttpd`，即在 **overlay** 中。
> 保留配置的 `sysupgrade` 会保留它，因此你曾设置为重定向的 U 盘在升级后
> 仍会重定向，尽管镜像默认携带 `0`。当 HTTP 意外失效时，
> 用 `uci get uhttpd.main.redirect_https` 检查，并与 `/rom/etc/config/uhttpd` 对比。

---

## 使用你自己的证书

将密钥对放入相应位置并重启 uhttpd：

```sh
cp my.crt /etc/uhttpd.crt
cp my.key /etc/uhttpd.key
chmod 600 /etc/uhttpd.key
/etc/init.d/uhttpd restart
```

要让浏览器接受证书，通用名 / SAN 必须与你实际访问该 U 盘所用的名称匹配
（其 IP，或你指向它的 DNS 名称）。公共 CA 不能为私有地址签发证书，
所以在局域网中你要么使用本地 CA，要么在每个浏览器中接受一次警告。

---

## 检查方法

```sh
# 从主机执行
curl -k -I https://192.168.8.1/          # HTTP/1.1 200 OK
curl -I  http://192.168.8.1/             # 仍可用，无 301

# 在设备上执行
ls -l /etc/uhttpd.crt /etc/uhttpd.key
netstat -ltn | grep -E ':80 |:443 '
logread | grep -i uhttpd
```

如果缺少 `:443`，说明 `px5g-mbedtls` 未安装——检查
`msm89xx/Makefile` 中的 `DEFAULT_PACKAGES`（它随每个板子一起发布）。

---

## 备注

* 证书**不**在设备间共享，因此每个 U 盘都会显示自己的警告。这是预期行为，不是 bug。
* 重新生成只需 `rm /etc/uhttpd.crt /etc/uhttpd.key` 然后
  `/etc/init.d/uhttpd restart`。
* `sysupgrade -n` 会擦除 overlay，所以证书会在下次启动时用新密钥重新生成。
