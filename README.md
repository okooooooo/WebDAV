# davbox

一个概念只有两个的自建 WebDAV 服务：**admin 管账号，client 登账号管文件**。
面向需要 WebDAV 同步的 App（思源笔记、Joplin 等），一个应用一个账号一个目录，互不可见。

![License](https://img.shields.io/badge/license-MIT-blue)

## 为什么自己做

市面上的开源 WebDAV 服务要么是给运维用的平台（SFTPGo：十几个概念、管理端全英文），
要么只有启动参数没有管理界面（dufs），要么隔离实测不可信（hacdias/webdav）。
需要的缺口只有薄薄一层：**极简的账号管理 + 可信的目录隔离**。协议层不重写，用 Go 官方实现。

## 特性

- **一个应用一个账号一个目录**：每个账号只看得到自己的根目录，跨账号访问一律拒绝；路径逃逸（`../`、编码后的 `%2e`、反斜杠、空字节）一律 `400`
- **admin 页**：新增 / 停用 / 删除账号、换口令、查看每个账号的目录与用量，一键「复制连接信息」（地址 + 用户名 + 口令）
- **client 页**：账号登录后浏览 / 上传（含拖拽）/ 下载 / 重命名 / 新建文件夹 / 删除
- **只读账号**：写动词一律 `403`，读正常
- **协议用官方实现**：`golang.org/x/net/webdav`（含 `LOCK` / `UNLOCK` / `COPY` / `MOVE` / 死属性持久化），不自研协议
- **单二进制交付**：前端 `//go:embed` 打进二进制，无外部运行时、无数据库
- **管理端认证可切换**：默认自带管理员口令，也可以关闭自带口令、改由网关注入身份

## 快速开始

开发（可从源码编译后后台启动）：

```bash
git clone https://github.com/YLing2024/davbox.git
cd davbox
./start-dev.sh
```

生产（有源码时比对二进制，不一致则先编译；再后台启动或注册服务）：

```bash
make build
./start-prod.sh
```

两个脚本都会询问监听地址、数据目录与认证模式（回车即用默认值），然后在后台启动，不占用当前终端。

```bash
./start-dev.sh stop       # 开发实例
./start-prod.sh stop      # 生产实例
./start-prod.sh status
./start-prod.sh log
./start-prod.sh restart
./start-prod.sh service install    # 注册 systemd 并开机自启
```

也可以自行前台运行：

```bash
make build        # 先构建前端，再编译出单二进制 ./davbox
./davbox          # 默认监听 0.0.0.0:18900，数据落在 ./data
```

首次启动（`builtin` 模式）会在数据目录生成：

- `accounts.json` —— 账号表
- `admin.json` —— 管理员口令的 bcrypt 哈希
- `admin-password.txt` —— 管理员初始口令明文
- `secret.key` —— 会话 cookie 的签名密钥

管理员初始口令只在首次生成时于 stdout 打印一次，请立刻保存。

- 管理页 `/admin`，文件页 `/`
- App 的 WebDAV 地址填 `http(s)://<你的站点>/<应用名>`

启动参数：

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-addr` | `0.0.0.0:18900` | 监听地址。默认绑定所有网卡，内网设备可访问。公网入口仍建议由 nginx 反代提供 TLS |
| `-data` | `./data` | 数据目录（账号表、管理员凭据、会话密钥、各账号目录） |

Makefile 其他目标：`make frontend` 只构建前端，`make run` 编译后直接启动，`make vet` 静态检查，`make test` 跑测试，`make clean` 清理产物。

## 目录结构

```
cmd/davbox/     程序入口
internal/       账号、认证与会话，以及 WebDAV 和 admin/client 路由
web/            Vite + React + TS 前端（构建产物由 go:embed 嵌入）
start-dev.sh    开发环境启动（可编译）
start-prod.sh   生产环境启动（只跑二进制）
docs/           需求、选型与验收记录
```

## 配置

| 名称 | 默认值 | 说明 |
|---|---|---|
| `AUTH_MODE` | `builtin` | 管理端认证模式，取值 `builtin` 或 `sso` |

- `builtin`：自带管理员口令，`/admin` 输入口令登录，使用签名 cookie 会话（12 小时）。
- `sso`：不使用自带口令登录，管理端身份取自网关注入的 `X-Auth-User`；缺失或为空返回 `401 JSON`，不会回退到 cookie。仅当 davbox 只监听回环、且该请求头由网关注入并对外剥离时才可使用。

```bash
AUTH_MODE=builtin ./davbox -addr 0.0.0.0:18900 -data ./data     # 默认，可省略
AUTH_MODE=sso     ./davbox -addr 127.0.0.1:18900 -data ./data   # sso 只绑回环
```

两种模式都不受影响的部分：

- WebDAV 数据面 `/<账号名>/...`：始终用应用账号 + HTTP Basic
- 客户端接口 `/api/client/*` 与静态资源 `/assets/*`
- 应用账号的增删改查在两种模式下都需要管理端身份

## 部署（nginx 反代）

```nginx
server {
    listen 443 ssl;
    server_name dav.example.com;

    location / {
        proxy_pass http://127.0.0.1:18900;
        proxy_request_buffering off;   # WebDAV 请求体流式直传，大文件不落盘
        client_max_body_size 0;        # 不限体积
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

生产环境用 `./start-prod.sh` 拉起二进制（默认 `0.0.0.0:18900`，内网可访问）。公网入口仍建议 nginx 反代 TLS。脚本可用环境变量覆盖配置：

```bash
DAVBOX_ADDR=0.0.0.0:18900 DAVBOX_DATA=./data AUTH_MODE=builtin ./start-prod.sh
```

注册为系统服务并开机自启（需要 sudo，写入 `/etc/systemd/system/davbox.service`）：

```bash
./start-prod.sh service install
./start-prod.sh service status
./start-prod.sh service uninstall
```

已注册后，`./start-prod.sh start|stop|restart` 交给 systemd。首次管理员口令在 `journalctl -u davbox` 和数据目录的 `admin-password.txt`。

接 `sso` 时把 `/admin`、`/api/admin/` 交给你的认证入口，WebDAV 数据面与 `/assets/*` 直连 davbox ——
协议端点保持自带 Basic 认证，否则 App 无法同步。`start-prod.sh` 在 `AUTH_MODE=sso` 且监听不是回环时会拒绝启动。

## 已完成

- 账号隔离与 WebDAV 六动词：`GET` / `PUT` / `DELETE` / `MKCOL` / `MOVE` / `PROPFIND`（`Depth 0/1` 均返回合法 `207`）
- admin 页与 client 页
- 单二进制 + nginx 反代部署

## License

[MIT](LICENSE)
