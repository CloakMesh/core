#!/usr/bin/env bash
#
# CloakMesh 容器入口（controller / router 共用）
#
# 职责只有一件事：把 CLOAKMESH_* 环境变量映射为上游运行时读取的 ZITI_*，
# 然后把控制权交回上游的 entrypoint.bash（bootstrap + 启动）。
set -euo pipefail

# shellcheck source=/dev/null
[ -f /opt/cloakmesh/share/env.sh ] && . /opt/cloakmesh/share/env.sh

# 上游脚本约定：controller 用 /bootstrap.bash，router 用同名变量指向自己的脚本
if [ -z "${ZITI_HOME:-}" ]; then
    echo "[cloakmesh] 警告：未设置 CLOAKMESH_HOME/ZITI_HOME，回退到镜像默认值" >&2
fi

echo "[cloakmesh] 启动：binary=/usr/local/bin/cloakmesh home=${ZITI_HOME:-<unset>}" >&2

exec /entrypoint.bash "$@"