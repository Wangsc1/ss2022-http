# SS2022 + HTTP 一键脚本

只安装一个节点，不提供其他模式：

- Shadowsocks 2022：`2022-blake3-aes-128-gcm`
- TCP：经 `simple-obfs` HTTP 伪装
- UDP：可选，使用相同公网端口直连 Shadowsocks
- 自动生成 SS URI、Surge 与 Clash 配置；安装完成或查看配置时直接输出 Surge 节点行
- systemd 守护、UFW/firewalld 自动放行
- 下载 shadowsocks-rust 时校验官方 SHA-256
- 安装成功后自动保存 `ss2022` 管理命令，卸载时一并删除

## 支持环境

- Debian / Ubuntu
- RHEL / CentOS / AlmaLinux / Rocky Linux
- `x86_64`、`aarch64`、`armv7`
- 必须使用 `root`，系统须采用 `systemd`

> 客户端必须同时支持 Shadowsocks 2022 和 `simple-obfs`（HTTP）。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Wangsc1/ss2022-http/main/ss2022-http.sh)
```

或显式运行安装命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Wangsc1/ss2022-http/main/ss2022-http.sh) install
```

安装时可设置：公网端口、SS2022 密钥、HTTP Host 和 UDP 开关；直接回车采用安全随机值/推荐默认值。本地后端端口在后台自动随机选择 `40000–59999` 范围内的空闲端口，并避开公网端口，不提供设置选项。

## 管理命令

安装成功后会自动保存 `/usr/local/sbin/ss2022`，无需另外下载。直接使用：

```bash
ss2022 info           # 查看配置、SS 链接和 Surge 节点行
ss2022 port 23456     # 修改公网端口
ss2022 reset          # 生成并启用新密钥
ss2022 restart        # 重启服务
ss2022 logs           # 查看最近日志
ss2022 uninstall      # 卸载（同时删除管理命令）
```

终端输出的 `Surge 节点` 可直接复制到 Surge 配置的 `[Proxy]` 段；完整文件仍保存在 `/etc/ss2022-http/subscribe/surge.conf`。

旧版已安装但没有管理命令，或需要更新管理脚本时，只需下载脚本，不必重新安装服务：

```bash
curl -fsSL https://raw.githubusercontent.com/Wangsc1/ss2022-http/main/ss2022-http.sh -o /usr/local/sbin/ss2022
chmod +x /usr/local/sbin/ss2022
```

如果当前 shell 的 PATH 不包含 `/usr/local/sbin`，可直接使用 `/usr/local/sbin/ss2022`。

配置与订阅位于：

```text
/etc/ss2022-http/
├── config.json
├── server.env
└── subscribe/
    ├── uri.txt
    ├── subscribe.txt
    ├── surge.conf
    └── clash.yaml
```

## 说明

- 若检测到早期 `ss-rust.service` / `ss-rust-obfs.service` 正在运行，安装时会先停用旧服务，以避免端口冲突；不会删除其旧配置。
- 脚本会处理服务器的 UFW 或 firewalld；云厂商安全组仍需自行放行所选端口。
- `simple-obfs` 只伪装 TCP，UDP 无法经过 HTTP obfs。
- `simple-obfs` 项目本身使用 GPL-3.0；本仓库不分发其源码或二进制，仅在安装时从官方仓库编译。

## 致谢

- shadowsocks-rust：<https://github.com/shadowsocks/shadowsocks-rust>
- simple-obfs：<https://github.com/shadowsocks/simple-obfs>
