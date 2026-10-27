# CloakMesh 品牌层说明

本目录承载 CloakMesh 对 OpenZiti 的**品牌化封装**。设计原则：**不动上游 Go 代码**，把品牌差异集中在启动层，保证随时可以 `git merge upstream/main` 而不冲突。

## 1. 品牌映射表

| 项目 | 上游（OpenZiti） | CloakMesh | 实现方式 |
|---|---|---|---|
| 二进制名 | `ziti` | `cloakmesh` | `branding/build.sh` 以 `-o cloakmesh` 构建；同时保留 `ziti` 软链 |
| 子命令 | `ziti controller run` / `ziti router run` | `cloakmesh controller run` / `cloakmesh router run` | 同一二进制，无需改动 |
| 环境变量前缀 | `ZITI_*` | `CLOAKMESH_*` | `branding/env.sh` 启动瞬间映射 |
| systemd 服务 | `ziti-controller.service` / `ziti-router.service` | `cloakmesh-controller.service` / `cloakmesh-router.service` | `branding/systemd/` |
| 运行用户/组 | `ziti-controller` / `ziti-router` | `cloakmesh`（uid/gid 2171） | systemd 单元 + 镜像内 useradd |
| Docker 镜像 | `openziti/ziti-controller` / `openziti/ziti-router` | `cloakmesh/controller` / `cloakmesh/router` | `branding/docker/` |
| 配置目录 | `/opt/openziti/etc/...` | `/opt/cloakmesh/etc/...` | systemd 单元内路径 |
| 数据目录 | `/var/lib/ziti-controller` | `/var/lib/cloakmesh-controller` | systemd 单元内 `StateDirectory` |

## 2. 刻意保留上游命名的部分（重要）

以下内容**不做重命名**，因为它们是上游脚本与运行时的内部契约，改名需要动 `bootstrap.bash` / `entrypoint.bash` 的 2000+ 处引用，收益低而回归风险高：

- 容器内文件系统路径 `/ziti-controller`、`/ziti-router`（镜像 ENV `CLOAKMESH_HOME` 会映射到 `ZITI_HOME`）
- 上游脚本内部的 `ziti` 调用（通过 `/usr/bin/ziti → cloakmesh` 软链承接）
- 配置键名、证书文件名、PKI 目录结构
- Go 模块路径 `github.com/openziti/ziti/v2`

也就是说：**用户看到的全是 cloakmesh，内部契约仍是 ziti**。后续如需彻底改名，建议按“配置键 → 文件路径 → Go 模块”的顺序分阶段做，每阶段都能独立回归。

## 3. 环境变量桥接规则

`branding/env.sh` 执行单向映射，规则只有一条：

```
CLOAKMESH_<X>  →  ZITI_<X>     （若 ZITI_<X> 已存在则不覆盖）
```

例：

| 你写的 | 运行时收到的 |
|---|---|
| `CLOAKMESH_PWD=xxx` | `ZITI_PWD=xxx` |
| `CLOAKMESH_CTRL_ADVERTISED_ADDRESS=ctrl.example.com` | `ZITI_CTRL_ADVERTISED_ADDRESS=ctrl.example.com` |
| `CLOAKMESH_ROUTER_NAME=router-1` | `ZITI_ROUTER_NAME=router-1` |
| `CLOAKMESH_HOME=/var/lib/cm` | `ZITI_HOME=/var/lib/cm` |

保留了 `ZITI_*` 的写入优先级，所以老的上游配置/文档依然可用，实现平滑过渡。

## 4. 构建

```bash
# 本机直接产出二进制
./branding/build.sh
./dist/bin/cloakmesh version
./dist/bin/cloakmesh controller --help

# 容器镜像（仓库根目录构建）
docker build -f branding/docker/Dockerfile.controller -t cloakmesh/controller:local .
docker build -f branding/docker/Dockerfile.router     -t cloakmesh/router:local     .
```

## 5. 部署

```bash
./deploy/linux/install.sh                                   # 一键：controller + router
./deploy/linux/install.sh --console /path/to/cloakmesh-console   # 追加中文控制台
./deploy/linux/install.sh --uninstall
```

裸机（非容器）systemd 部署请参考 `branding/systemd/` 下的两个单元文件，配套目录约定：

```
/usr/local/bin/cloakmesh
/opt/cloakmesh/share/env.sh
/opt/cloakmesh/etc/controller/cloakmesh.env
/opt/cloakmesh/etc/router/cloakmesh.env
/var/lib/cloakmesh-controller
/var/lib/cloakmesh-router
```

## 7. 实测记录（Debian 13 / Docker 26.1.5 / 2C4G）

`./deploy/linux/install.sh --host <本机IP> --console <cloakmesh-console 路径>` 全流程跑通：

| 检查项 | 结果 |
|---|---|
| `cloakmesh/controller:local` 镜像 | 206 MB，`cloakmesh version` 可执行 |
| `cloakmesh/router:local` 镜像 | 206 MB（复用 builder 缓存） |
| `cloakmesh/console:local` 镜像 | 96 MB |
| 控制器 | `healthy`，edge API `HTTP 200`，日志出现 `cluster initialized successfully` |
| 路由器 | `ziti edge list edge-routers` → `online=True` |
| 中文控制台 | `HTTP 200`，`<title>CloakMesh 管理控制台</title>` |

### 踩过的坑（已修，改动都在本目录）

1. **`ARG` 作用域**：写在首个 `FROM` 之前的 `ARG` 不会进入 stage，`${DEBIAN_MIRROR}` 在 `RUN` 里展开为空，`sed` 把 apt 源域名替换成空串 → 必须在 stage 内重新声明。
2. **`ZITI_BOOTSTRAP_CLUSTER` 的真实语义**：不是「HA 集群成员」，而是「是否生成 root+intermediate PKI」。首个控制器设为 `false` 会导致 CA 不生成，后续创建证书必然失败；HA 成员用的是 `ZITI_CLUSTER_NODE_PKI`。
3. **`set -u` 崩溃**：上游脚本要求 `ZITI_BOOTSTRAP_CLUSTER` 等变量存在，容器入口需补齐默认值。
4. **含空格的变量值**：上游 `exportZitiVars()` 用 `export "${line%=*}"` 处理 `set` 输出，`ZITI_USER_NAME="Default Admin"` 这类含空格的值会报 `not a valid identifier`。
5. **路由器证书 SAN**：`create config router` 生成的 `csr.sans` 只有 `hostname/localhost/127.0.0.1`。公布地址是 IP 时必须补 `ip` 类型 SAN，否则 router 启动 `fatal: identity is not valid for provided host`。
6. **`compose exec` 不继承 entrypoint 的 env 映射**：容器内新进程看不到 entrypoint 里 `CLOAKMESH_*→ZITI_*` 的结果，脚本里要用 `CLOAKMESH_*`。
7. **compose 嵌套默认值**：`${A:-${B}}` 解析不可靠，会让变量静默丢失 → 用单层默认值。

## 8. 上游归属（原第 6 节）

本项目基于 [OpenZiti](https://github.com/openziti/ziti)（Apache License 2.0）修改，保留上游全部版权与许可声明。上游文档中的 `ZITI_*` 变量、`ziti` 命令与本文档的 `CLOAKMESH_*`、`cloakmesh` 命令一一对应，可直接对照阅读：https://openziti.io/docs/