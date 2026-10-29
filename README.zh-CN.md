# CloakMesh 核心（Controller + Router）

CloakMesh 是基于 [OpenZiti](https://github.com/openziti/ziti) 构建的零信任网络平台，本仓库对应上游的控制器与路由器实现。

> **上游说明**：本项目 fork 自 `openziti/ziti`（Apache License 2.0），保留完整上游历史与许可。所有协议、数据面能力均来自上游；CloakMesh 的差异集中在**品牌层**（二进制名、服务名、镜像名、环境变量前缀）与**中文文档/部署工具**。

## 仓库骨架

| 仓库 | 说明 |
|---|---|
| `cloakmesh-core` | 控制器 + 路由器（本仓库） |
| `cloakmesh-console` | 管理控制台（ZAC 中文汉化版） |
| `cloakmesh-desktop-edge-win` | Windows 桌面客户端（中文汉化版） |
| `cloakmesh-tunnel-apple` | Apple 客户端（macOS / iOS） |
| `cloakmesh-tunnel-android` | Android 客户端 |
| `cloakmesh-tunnel-sdk-c` | 隧道引擎（`cloakmesh-tunnel`） |

## 快速开始（Linux 一键部署）

> 国内网络可用 Gitee 镜像：`https://gitee.com/cloakmash/core.git`

前置：Docker Engine + `docker compose` v2。

```bash
git clone https://github.com/cloakmesh/core.git
cd cloakmesh-core

# 控制器 + 边缘路由器
./deploy/linux/install.sh

# 同时部署中文控制台
git clone https://github.com/cloakmesh/console.git ../cloakmesh-console
./deploy/linux/install.sh --console ../cloakmesh-console

# 自定义端口（控制面 / 数据面 / 控制台）
./deploy/linux/install.sh --ctrl-port 8443 --router-port 443 --console-port 8080
```

已部署环境改端口不需要重建数据库、不需要重签证书、不需要重新登记路由器：

```bash
./deploy/linux/install.sh --reconfigure --router-port 443
./deploy/linux/install.sh --reconfigure --ctrl-port 8443
```

端口存在哪几处、为什么不能只改一处、故障对照，见 [`deploy/linux/README.md`](deploy/linux/README.md)。

脚本会自动生成随机管理员密码、构建镜像、等待健康检查，并在结束时打印访问地址与凭据（凭据同时写入 `deploy/linux/.env`，权限 600）。

## 从源码构建

```bash
./branding/build.sh                  # 产出 dist/bin/cloakmesh
./dist/bin/cloakmesh version
```

容器镜像：

```bash
docker build -f branding/docker/Dockerfile.controller -t cloakmesh/controller:local .
docker build -f branding/docker/Dockerfile.router     -t cloakmesh/router:local     .
```

## 品牌与上游对照

| 上游 | CloakMesh |
|---|---|
| `ziti controller run` | `cloakmesh controller run` |
| `ZITI_PWD` | `CLOAKMESH_PWD` |
| `ziti-controller.service` | `cloakmesh-controller.service` |
| `openziti/ziti-controller` | `cloakmesh/controller` |

完整对照、桥接机制与「刻意保留上游命名」的部分见 [`branding/README.md`](branding/README.md)。

## 目录说明

```
branding/            品牌层（env 桥接、systemd 单元、Dockerfile、构建脚本）
deploy/linux/        一键部署脚本与 compose 定义
ziti/                上游主程序（Go）
controller/ router/  上游控制器与路由器实现
```

上游原有文档（英文）保持不变：`README.md`、`doc/`、`dist/` 等。

## 许可

Apache License 2.0，与上游一致。上游版权声明见 `LICENSE` 与各文件头部。