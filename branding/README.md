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

## 6. 上游归属

本项目基于 [OpenZiti](https://github.com/openziti/ziti)（Apache License 2.0）修改，保留上游全部版权与许可声明。上游文档中的 `ZITI_*` 变量、`ziti` 命令与本文档的 `CLOAKMESH_*`、`cloakmesh` 命令一一对应，可直接对照阅读：https://openziti.io/docs/