# xa_wg · WireGuard 一键安装管理脚本（xa 重制版）

单文件 WireGuard 部署脚本：一条命令搞定服务端 + 客户端，内置 Web 管理面板、流量限额、
独立上下行限速（QoS）、到期管理、备份恢复、审计日志与 HTTP JSON API。

> 本脚本基于 [hwdsl2/wireguard-install](https://github.com/hwdsl2/wireguard-install)（MIT）二次开发，
> 在此基础上重构为单文件、并加入 Web UI、API v1、QoS 限速、身份审计等大量新功能。感谢原作者。

- 仓库：https://github.com/xaxanb/xa_wg
- 交付文件：`wg.sh`（单文件）、`API.md`（接口文档）
- 支持系统：Ubuntu 20.04+ / Debian 11+ / CentOS 8+ / AlmaLinux / Rocky / Fedora / openSUSE

---

## 功能特性

- **一键安装**：自动检测公网 IP、系统、DNS，安装依赖并配置防火墙与内核转发。
- **Web 管理面板**：客户端增删改查、二维码、配置下载、流量图表、系统资源、审计日志。
- **流量限额 / 到期管理**：按客户端设置流量上限与到期日，超额自动处理，支持周期自动重置。
- **QoS 限速**：全局与单客户端独立上行/下行限速，基于 `tc`（HTB / TBF），重启自动恢复。
- **超配额降速**：超额后可选择「降速」而非直接封禁，周期重置自动解除。
- **HTTP JSON API v1**：面向 App / 自动化，双令牌体系（管理员令牌 + 客户端订阅令牌）。
- **备份 / 恢复**：一键打包配置、数据、服务与脚本，恢复后自动重载。
- **自愈与体检**：定时检查并重启异常服务；`wgd doctor` 一键体检。
- **安全**：Cookie `HttpOnly`、CSRF 同源校验、登录限流、备份路径穿越防护、身份 ID 反泄露审计。

---

## 快速开始

### 一键安装（推荐）

```bash
curl -fsSL -o wg.sh https://raw.githubusercontent.com/xaxanb/xa_wg/main/wg.sh
bash wg.sh --auto
```
```bash
bash wg.sh --auto --555
```
- bash wg.sh --auto --555 这样就是使用555端口

- 默认 WireGuard 监听 **53/UDP**，自动选择 DNS，并部署 + 对外暴露 Web/API（**5666**）。
- 安装完成后会打印 **Web 访问地址、用户名/密码、API 管理员令牌**，请妥善保存。

### 指定端口 / 服务器地址 / 不装 Web

```bash
# 指定 WireGuard 端口
bash wg.sh --auto --7777

# 指定端口 + 服务器地址 + 不部署 Web/API
bash wg.sh --auto --7777 --serveraddr vpn.example.com --no-web
```

### 交互式安装

```bash
bash wg.sh
```

---

## 命令行参数

| 参数 | 说明 |
|------|------|
| `--auto` | 自动安装（默认端口 53，自动 DNS，部署并暴露 Web UI） |
| `--auto --<端口>` | 自动安装并指定 WireGuard 监听端口，如 `--auto --7777` |
| `--port [端口]` | 显式指定监听端口（默认 53，范围 1-65535） |
| `--serveraddr [DNS/IP]` | 指定服务器地址 |
| `--clientname [名称]` | 首个客户端名称（默认 `client`） |
| `--dns1 [IP]` / `--dns2 [IP]` | 指定首选 / 备用 DNS |
| `--no-web` | 不部署 Web/API |
| `--web-port [端口]` | Web UI / API 端口（默认 5666） |
| `--trust-proxy` | 部署在反向代理后时启用，信任 `X-Forwarded-For` |
| `--addclient [名称]` | 添加客户端 |
| `--removeclient [名称]` | 删除客户端 |
| `--listclients` | 列出所有客户端 |
| `--showclientqr [名称]` | 显示客户端二维码 |
| `--uninstall` | 卸载 WireGuard |
| `-y, --yes` | 全部默认回答「是」 |
| `-h, --help` | 显示帮助 |

---

## 服务端管理命令 `wgd`

| 命令 | 说明 |
|------|------|
| `wgd add <名称>` | 添加客户端 |
| `wgd remove <名称>` | 删除客户端 |
| `wgd list` | 列出客户端 |
| `wgd qr <名称>` | 显示客户端二维码 |
| `wgd rename <旧> <新>` | 重命名客户端 |
| `wgd enable/disable <名称>` | 启用 / 停用客户端 |
| `wgd dns <名称> [IP]` | 查看 / 设置客户端 DNS |
| `wgd limit <名称> [值]` | 查看 / 设置流量上限 |
| `wgd expire <名称> [日期]` | 查看 / 设置到期日 |
| `wgd reset <名称>` | 重置已用流量 |
| `wgd status` | 服务与客户端概览 |
| `wgd qos [show\|algo\|total-down\|total-up]` | 全局限速管理 |
| `wgd rate <名称> [下行] [上行]\|clear` | 单客户端限速（MB/s） |
| `wgd rate-overquota <名称> [值]` | 超配额降速（MB/s） |
| `wgd admin-token [reset]` | 查看 / 重置 API 管理员令牌 |
| `wgd web [status\|restart]` | Web 服务管理 |
| `wgd web-port [端口]` | 查看 / 修改 Web 端口 |
| `wgd passwd` | 修改 Web 登录密码 |
| `wgd backup` / `wgd restore <文件>` | 备份 / 恢复 |
| `wgd doctor` | 系统体检 |
| `wgd uninstall` | 卸载 |

---

## Web 管理面板 / API

- Web UI 与 API 默认端口 **5666**（与 WireGuard 监听端口相互独立）。
- 访问：`http://<服务器IP>:5666`
- 接口基址：`http://<服务器IP>:5666/api/v1`
- 完整接口说明见 [`API.md`](API.md)。

> ⚠️ API 默认走 HTTP 明文，令牌与配置会明文传输。公网部署请在 Nginx/Caddy 上配置 HTTPS，
> 并仅对可信来源开放端口；经反代访问时安装加 `--trust-proxy`。

---

## 常见问题

- **DNS 无法解析**：脚本会按能否访问海外站点自动选择 DNS（可访问→`1.1.1.1`，否则→`223.5.5.5`）。
- **端口 53 被占用**：使用 `--auto --<端口>` 指定其它端口。
- **忘记 Web 密码**：`wgd passwd` 重设。
- **API 管理员令牌丢失**：`wgd admin-token reset` 重新生成。
- **卸载**：`wgd uninstall`（会清理服务、防火墙规则、tc 限速与相关文件）。

---

## 许可证

本项目基于 MIT 许可的 [hwdsl2/wireguard-install](https://github.com/hwdsl2/wireguard-install) 二次开发。

原始版权：

```
The MIT License (MIT)
Copyright (c) 2022-2026 Lin Song <linsongui@gmail.com>
Copyright (c) 2020-2023 Nyr
```

二次开发部分（xa 重制版）同样以 MIT 许可发布。
