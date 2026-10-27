#!/usr/bin/env bash
#
# CloakMesh Linux 一键部署脚本
#
# 流程：
#   1. 检查 docker / docker compose
#   2. 生成 .env（随机管理员密码、对外地址、路由器名）
#   3. 构建镜像（可用 --no-build 复用）
#   4. 先起 controller，等健康检查通过
#   5. 在 controller 内自动签发路由器登记令牌（JWT），写入 .env
#   6. 再起 router（可选 console），最后打印访问地址与凭据
#
# 用法（在 cloakmesh-core 仓库根目录执行）：
#   ./deploy/linux/install.sh                          # 自动探测本机 IP 作为对外地址
#   ./deploy/linux/install.sh --host 10.0.0.5          # 指定对外地址（证书 SAN）
#   ./deploy/linux/install.sh --console /path/cloakmesh-console   # 同时部署中文控制台
#   ./deploy/linux/install.sh --pwd 'MyPassw0rd!'      # 指定管理员密码
#   ./deploy/linux/install.sh --no-build               # 复用已构建镜像
#   ./deploy/linux/install.sh --router-port 443        # 改路由器数据面端口（默认 3022）
#
# 卸载：
#   ./deploy/linux/install.sh --uninstall
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/deploy/linux/docker-compose.yml"
ENV_FILE="$REPO_ROOT/deploy/linux/.env"
CONSOLE_DIR=""
CLOAKMESH_HOST=""
CLOAKMESH_PWD=""
ROUTER_NAME="router-1"
ROUTER_PORT="3022"
CONSOLE_PORT="8080"
UNINSTALL="false"
NO_BUILD="false"

log()  { printf '\033[1;32m[cloakmesh]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[cloakmesh]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[cloakmesh]\033[0m %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host)         CLOAKMESH_HOST="${2:?}"; shift 2 ;;
        --pwd)          CLOAKMESH_PWD="${2:?}"; shift 2 ;;
        --router-name)  ROUTER_NAME="${2:?}"; shift 2 ;;
        --router-port)  ROUTER_PORT="${2:?}"; shift 2 ;;
        --console)      CONSOLE_DIR="${2:?}"; shift 2 ;;
        --console-port) CONSOLE_PORT="${2:?}"; shift 2 ;;
        --uninstall)    UNINSTALL="true"; shift ;;
        --no-build)     NO_BUILD="true"; shift ;;
        -h|--help)      sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)              die "未知参数：$1（用 --help 查看用法）" ;;
    esac
done

require_docker() {
    command -v docker >/dev/null 2>&1 || die "未安装 docker，请先安装 Docker Engine"
    docker compose version >/dev/null 2>&1 || die "未检测到 docker compose v2 插件（Debian/Ubuntu 可 apt install docker-compose）"
    docker info >/dev/null 2>&1 || die "当前用户无法访问 docker daemon（试 sudo 或加入 docker 组）"
}

compose() {
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

detect_host() {
    if [ -n "$CLOAKMESH_HOST" ]; then
        printf '%s' "$CLOAKMESH_HOST"
        return
    fi
    local ip
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -n "$ip" ] || ip="127.0.0.1"
    printf '%s' "$ip"
}

random_pwd() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 24 | tr -d '\n/+=' | cut -c1-20
    else
        head -c 32 /dev/urandom | base64 | tr -d '\n/+=' | cut -c1-20
    fi
}

do_uninstall() {
    [ -f "$ENV_FILE" ] && compose down -v --remove-orphans || true
    rm -f "$ENV_FILE"
    log "已卸载（含数据卷）"
}

write_env() {
    local host="$1" pwd="$2"
    if [ -f "$ENV_FILE" ]; then
        warn "检测到已有 $ENV_FILE，沿用其中配置（如需重置请先 --uninstall）"
        return
    fi
    cat > "$ENV_FILE" <<EOF
# 由 deploy/linux/install.sh 生成 $(date -Iseconds)
CLOAKMESH_HOST=$host
CLOAKMESH_ROUTER_NAME=$ROUTER_NAME
CLOAKMESH_ROUTER_PORT=$ROUTER_PORT
CLOAKMESH_PWD=$pwd
CLOAKMESH_CONSOLE_PORT=$CONSOLE_PORT
EOF
    chmod 600 "$ENV_FILE"
}

build_console_image() {
    local dir="$1"
    [ -d "$dir" ] || die "控制台目录不存在：$dir"
    [ -f "$dir/package.json" ] || die "控制台目录不像 cloakmesh-console 仓库：$dir"
    if [ "$NO_BUILD" = "true" ] && docker image inspect cloakmesh/console:local >/dev/null 2>&1; then
        log "跳过控制台镜像构建（--no-build，已存在 cloakmesh/console:local）"
    else
        log "构建中文控制台镜像（首次约需数分钟）"
        docker build -f "$dir/docker-images/cloakmesh-console/Dockerfile" -t cloakmesh/console:local "$dir"
        docker create --name cm-console-extract cloakmesh/console:local >/dev/null
        rm -rf "$REPO_ROOT/deploy/linux/console-dist"
        docker cp cm-console-extract:/usr/share/nginx/html "$REPO_ROOT/deploy/linux/console-dist" >/dev/null
        docker rm cm-console-extract >/dev/null
    fi
    [ -d "$REPO_ROOT/deploy/linux/console-dist" ] || die "未取到控制台静态资源（console-dist 不存在）"
    export CLOAKMESH_CONSOLE_DIST="$REPO_ROOT/deploy/linux/console-dist"
}

# 在 controller 内登录并签发路由器登记令牌，结果写入 .env 的 CLOAKMESH_ENROLL_TOKEN
# 注意：compose exec 是容器内的新进程，不会继承 entrypoint 里映射出来的 ZITI_*，
#       所以这里必须用容器配置里的 CLOAKMESH_*（compose 的 environment 段）
enroll_router() {
    local name="$1" attempt out jwt=""
    for attempt in 1 2 3 4 5; do
        out="$(compose exec -T controller bash -lc "
            ziti edge login -u \"\${CLOAKMESH_USER:-admin}\" -p \"\${CLOAKMESH_PWD:-}\" -y https://127.0.0.1:1280 2>&1 &&
            { ziti edge create edge-router \"${name}\" -o /tmp/router.jwt 2>&1 ||
              ziti edge re-enroll edge-router \"${name}\" -o /tmp/router.jwt 2>&1; } &&
            cat /tmp/router.jwt" 2>&1 || true)"
        jwt="$(printf '%s' "$out" | awk '/^eyJ/{print; exit}' | tr -d '\r\n')"
        [ -n "$jwt" ] && break
        [ "$attempt" -lt 5 ] && sleep 4
    done

    if [ -z "$jwt" ]; then
        warn "自动签发登记令牌失败，最后一次输出："
        printf '%s\n' "$out" | tail -5 >&2
        warn "可手动执行："
        warn "  docker compose exec controller ziti edge login -u admin -p <密码> -y https://127.0.0.1:1280"
        warn "  docker compose exec controller ziti edge create edge-router ${name} -o /tmp/router.jwt"
        warn "  然后把 /tmp/router.jwt 内容写入 .env 的 CLOAKMESH_ENROLL_TOKEN"
        return 1
    fi
    if grep -q '^CLOAKMESH_ENROLL_TOKEN=' "$ENV_FILE" 2>/dev/null; then
        sed -i '/^CLOAKMESH_ENROLL_TOKEN=/d' "$ENV_FILE"
    fi
    printf 'CLOAKMESH_ENROLL_TOKEN=%s\n' "$jwt" >> "$ENV_FILE"
    log "登记令牌已写入 $ENV_FILE（${#jwt} 字节）"
}

wait_healthy() {
    local i
    log "等待 controller 就绪..."
    for i in $(seq 1 90); do
        if compose ps controller --format '{{.Health}}' 2>/dev/null | grep -qi healthy; then
            return 0
        fi
        sleep 2
    done
    warn "controller 健康检查超时，请执行 docker logs cloakmesh-controller 排查"
    return 1
}

main() {
    require_docker
    if [ "$UNINSTALL" = "true" ]; then do_uninstall; exit 0; fi

    local host pwd
    host="$(detect_host)"
    pwd="${CLOAKMESH_PWD:-$(random_pwd)}"
    write_env "$host" "$pwd"

    # .env 已存在时以文件为准
    # shellcheck source=/dev/null
    . "$ENV_FILE" 2>/dev/null || true
    host="${CLOAKMESH_HOST:-$host}"
    pwd="${CLOAKMESH_PWD:-$pwd}"
    log "对外地址（证书 SAN）：$host"

    if [ "$NO_BUILD" = "true" ]; then
        log "跳过镜像构建（--no-build）"
    else
        log "构建镜像：cloakmesh/controller、cloakmesh/router"
        compose build controller router
    fi

    # 1) 控制器先行：它是 PKI / 数据库 / 管理 API 的基础
    log "启动 controller"
    compose up -d controller
    wait_healthy || true

    # 2) 自动签发路由器登记令牌
    enroll_router "$ROUTER_NAME" || warn "路由器登记令牌缺失，router 将无法注册到控制器"

    # 3) 再起 router（与控制台）
    if [ -n "$CONSOLE_DIR" ]; then
        build_console_image "$CONSOLE_DIR"
        log "启动 router + 中文控制台"
        compose --profile console up -d router console
    else
        warn "未指定 --console，跳过中文控制台（可后续补 --console <cloakmesh-console 路径> 重跑）"
        log "启动 router"
        compose up -d router
    fi

    sleep 5
    local router_status
    router_status="$(docker inspect -f '{{.State.Status}}' cloakmesh-router 2>/dev/null || echo unknown)"

    cat <<EOF

================ CloakMesh 部署完成 ================
 控制器 API : https://${host}:1280
 边缘路由器 : ${ROUTER_NAME}（tcp://${host}:${ROUTER_PORT}，容器状态：${router_status}）
 管理员用户 : ${CLOAKMESH_USER:-admin}
 管理员密码 : ${pwd}
$( [ -n "$CONSOLE_DIR" ] && printf ' 中文控制台 : http://<本机IP>:%s （登录时填 https://%s:1280）\n' "$CONSOLE_PORT" "$host" )
---------------------------------------------------
 提示：自签证书的 SAN 为 ${host}，浏览器访问前请在客户端 hosts 添加
       ${host} -> <本机IP>
 常用命令：
   docker compose -f deploy/linux/docker-compose.yml --env-file deploy/linux/.env ps
   docker logs -f cloakmesh-controller
   docker logs -f cloakmesh-router
   ./deploy/linux/install.sh --uninstall
====================================================
EOF
}

main "$@"