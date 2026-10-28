# 端口配置与自定义（deploy/linux）

本文说明 CloakMesh 单机部署里有哪些端口、它们分别存在哪些位置、以及**改端口的标准做法**。
不需要手工 sed config.yml —— `install.sh` 已经把这个流程做成开关。

## 1. 端口总览

| 变量 | 默认值 | 组件 | 对外协议 | 谁需要访问 |
|---|---|---|---|---|
| `CLOAKMESH_CTRL_PORT` | `1280` | 控制器 API（控制面） | HTTPS / REST（`/edge/client/v1`、`/edge/management/v1`...） | 所有客户端、ZAC、CLI、管理员 |
| `CLOAKMESH_ROUTER_PORT` | `3022` | 边缘路由器 edge listener（数据面） | Ziti channel 协议 over TLS（非 HTTP） | 所有客户端（业务流量） |
| `CLOAKMESH_CONSOLE_PORT` | `8080` | 中文控制台（ZAC node 服务，容器内 1408） | HTTP(S) | 管理员浏览器 |
| （固定）`10080` | `10080` | 路由器 link listener | 同上私有协议 | 仅多路由器互联，单路由器不需要 |

> 控制台跑的是 ZAC 自带的 `server.js`（不是 nginx 静态托管）：SPA 与控制器 API 同源、令牌存 httpOnly cookie，登录与设置持久化才可用。

**一句话记住**：改客户端能不能连，看 1280 + 3022；改管理员能不能看，看 8080；10080 只跟路由器之间的 mesh 有关。

## 2. 端口为什么存在四个地方

改端口失败通常不是"改错了"，而是"只改了一处"。端口实际出现在：

| 位置 | 内容 | 改漏的后果 |
|---|---|---|
| `deploy/linux/.env` | `CLOAKMESH_CTRL_PORT` / `CLOAKMESH_ROUTER_PORT` | compose 端口映射仍用默认值 |
| `docker-compose.yml` | `ports:` 映射、`CLOAKMESH_*_PORT` 环境变量、健康检查 URL | 宿主机没映射新端口 / 容器内仍监听旧端口 |
| 控制器卷 `config.yml` | `web.bindPoints[].interface` 与 `address` | 控制器仍在旧端口监听，或返回给客户端的地址带旧端口 |
| 路由器卷 `config.yml` | `listeners[].address`（监听）与 `options.advertise`（告诉客户端连哪） | 客户端被指向旧端口 |
| 路由器卷 `endpoints.yml` | **登记时记录的控制器地址** | 改控制面端口后路由器一直 `dial tcp ...:旧端口: connection refused` |

前两项由脚本/`.env` 管理；后三项都在容器命名卷里，所以**必须用脚本改**，不要手改 `.env` 就重启。

## 3. 首次部署：直接指定端口

```bash
./deploy/linux/install.sh \
  --host ziti.example.com \
  --ctrl-port 8443 \
  --router-port 443 \
  --console-port 8080 \
  --console ../cloakmesh-console
```

脚本会把端口写进 `.env`，compose 的映射、健康检查、路由器上报的地址全部跟随，新建的 `config.yml` 也按新端口生成。

## 4. 已部署环境：`--reconfigure`

```bash
# 只改数据面
./deploy/linux/install.sh --reconfigure --router-port 443

# 只改控制面（会同时同步路由器的 endpoints.yml）
./deploy/linux/install.sh --reconfigure --ctrl-port 8443

# 两个一起改
./deploy/linux/install.sh --reconfigure --ctrl-port 8443 --router-port 443
```

脚本做四件事：

1. **冲突自检**：要改的端口若已被宿主机占用，直接报错退出（不会把服务改挂）；
2. **改写 `.env`**；
3. **改写容器内 `config.yml`**（控制器 interface/address、路由器 address/advertise），改动控制面端口时**额外同步路由器 `endpoints.yml`**；
4. **`--force-recreate` 重建容器**（端口映射变了，`docker restart` 不生效），然后自动登录控制器打印路由器在线状态。

### 为什么不用重签证书、不用重新登记路由器

- 证书 SAN 里只有地址，**不含端口** → 改端口不影响 TLS 校验；
- 路由器身份（`router.cert/key`、控制器里的登记记录）与端口无关 → 不需要重新签发 JWT。

只有**改地址**（`--host`）才需要重新 bootstrap（重新签证书），这条路 `--reconfigure` 故意不支持，避免半途改坏。

## 5. 实测矩阵（.201 / Debian 13 / Docker 26.1.5）

| 步骤 | 命令 | 结果 |
|---|---|---|
| 初始 | — | 监听 1280 / 3022，`router-1=ONLINE` |
| 只改数据面 | `--reconfigure --router-port 4433` | 监听 4433，`router-1=ONLINE` |
| 只改控制面 | `--reconfigure --ctrl-port 1281` | 监听 1281，`endpoints.yml` 已同步，`router-1=ONLINE` |
| 双改 | `--reconfigure --ctrl-port 1281 --router-port 4433` | `router-1=ONLINE` |
| 回滚 | `--reconfigure --ctrl-port 1280 --router-port 3022` | 回到初始监听，`router-1=ONLINE` |

## 6. 注意事项

1. **443 常被占用**：本机 `.201` 的 443 由 Caddy 持有，直接 `--router-port 443` 会被自检拦下。要么先腾端口，要么用四层 SNI 分流后再让容器监听内部端口。
2. **客户端要重新添加身份**：端口变了，控制器下发给客户端的路由器地址也变；已存在的 ZDEW 身份里缓存的地址不会自动更新，需要重新添加或重新拉取配置。
3. **link 端口 10080 不在本机制内**：多路由器/HA 场景需要单独改路由器 `config.yml` 的 `link.listeners[].bind/advertise`，并在防火墙放通。
4. **改地址请重建**：`--host` 变更涉及证书 SAN，必须 `--uninstall` 后重新部署。
5. **端口不是安全边界**：换端口只是避开冲突/合规要求，访问控制仍靠身份、策略与服务配置。

## 7. 故障对照

| 现象 | 大概率原因 |
|---|---|
| 客户端能加身份、能登录，但服务连不上/一直 Connecting | `CLOAKMESH_ROUTER_PORT` 没放通，或 `advertise` 写的是内网地址 |
| 命令行能登录，浏览器/ZAC 打不开 | `CLOAKMESH_CTRL_PORT` 对外映射不对，或证书 SAN 与访问地址不一致 |
| 改完控制面端口后路由器一直 offline，日志 `dial tcp ...:旧端口: connection refused` | 路由器卷里的 `endpoints.yml` 没同步（用 `--reconfigure` 会自动处理） |
| 端口自检报"已被占用" | 换端口，或先停掉占用进程（`ss -lntp | grep :端口`） |