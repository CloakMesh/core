#!/usr/bin/env bash
#
# CloakMesh Linux 一键部署 / 运维脚本
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/deploy/linux/docker-compose.yml"
ENV_FILE="$REPO_ROOT/deploy/linux/.env"
CONSOLE_DIR=""
CLOAKMESH_HOST=""
CLOAKMESH_PWD=""
ROUTER_NAME="router-1"
CTRL_PORT=""
ROUTER_PORT=""
CONSOLE_PORT="8080"
UNINSTALL="false"
NO_BUILD="false"
RECONFIG="false"

log()  { printf '\033[1;32m[cloakmesh]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[cloakmesh]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[cloakmesh]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
CloakMesh Linux 部署脚本

首次部署：
  ./deploy/linux/install.sh [--host <地址>] [--console <cloakmesh-console 路径>]
                           [--pwd <密码>] [--ctrl-port 1280] [--router-port 3022]
                           [--console-port 8080] [--no-build]

改端口（已部署环境原地修改，不需要重建控制器数据库、不需要重新登记路由器）：
  ./deploy/linux/install.sh --reconfigure --router-port 443
  ./deploy/linux/install.sh --reconfigure --ctrl-port 8443 --router-port 443

卸载（含数据卷）：
  ./deploy/linux/install.sh --uninstall

端口说明：
  --ctrl-port    控制器 API 端口（控制面，HTTPS）。客户端登记/认证/取会话都走它。
  --router-port  路由器数据面端口（自定义 TLS 协议）。业务流量与会话建立都走它。
  两者都在安装时写进 .env；--reconfigure 会同步改写容器内的 config.yml 并重建容器。
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host)         CLOAKMESH_HOST="${2:?}"; shift 2 ;;
        --pwd)          CLOAKMESH_PWD="${2:?}"; shift 2 ;;
        --router-name)  ROUTER_NAME="${2:?}"; shift 2 ;;
        --ctrl-port)    CTRL_PORT="${2:?}"; shift 2 ;;
        --router-port)  ROUTER_PORT="${2:?}"; shift 2 ;;
        --console)      CONSOLE_DIR="${2:?}"; shift 2 ;;
        --console-port) CONSOLE_PORT="${2:?}"; shift 2 ;;
        --no-build)     NO_BUILD="true"; shift ;;
        --reconfigure)  RECONFIG="true"; shift ;;
        --uninstall)    UNINSTALL="true"; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              die "未知参数：$1（用 --help 查看用法）" ;;
    esac
done

require_docker() {
    command -v docker >/dev/null 2>&1 || die "未安装 docker，请先安装 Docker Engine"
    docker compose version >/dev/null 2>&1 || die "未检测到 docker compose v2 插件（Debian/Ubuntu 可 apt install docker-compose）"
    docker info >/dev/null 2>&1 || die "当前用户无法访问 docker daemon（试 sudo 或加入 docker 组）"
}

compose() { docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }

load_env() { set -a; . "$ENV_FILE"; set +a; }

env_get() {
    # 键不存在时不能因 set -e + pipefail 直接退出
    local v
    v="$(grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    printf '%s' "$v"
}

detect_host() {
    if [ -n "$CLOAKMESH_HOST" ]; then printf '%s' "$CLOAKMESH_HOST"; return; fi
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
    local host="$1" pwd="$2" ctrl="$3" router="$4"
    if [ -f "$ENV_FILE" ]; then
        warn "检测到已有 $ENV_FILE，沿用其中配置（如需重置请先 --uninstall；只改端口请用 --reconfigure）"
        return
    fi
    cat > "$ENV_FILE" <<EOF
# 由 deploy/linux/install.sh 生成 $(date -Iseconds)
CLOAKMESH_HOST=$host
CLOAKMESH_ROUTER_NAME=$ROUTER_NAME
CLOAKMESH_PWD=$pwd
CLOAKMESH_CONSOLE_PORT=$CONSOLE_PORT
# 控制面（控制器 API，HTTPS）
CLOAKMESH_CTRL_PORT=$ctrl
# 数据面（路由器 edge listener，自定义 TLS 协议）
CLOAKMESH_ROUTER_PORT=$router
EOF
    chmod 600 "$ENV_FILE"
}

build_console_image() {
    local dir="$1"
    [ -d "$dir" ] || die "控制台目录不存在：$dir"
    [ -f "$dir/package.json" ] || die "控制台目录不像 cloakmesh-console 仓库：$dir"
    if [ "$NO_BUILD" = "true" ] && docker image inspect cloakmesh/console:local >/dev/null 2>&1; then
        log "跳过控制台镜像构建（--no-build）"
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

enroll_router() {
    local name="$1" attempt out jwt=""
    for attempt in 1 2 3 4 5; do
        out="$(compose exec -T controller bash -lc "
            ziti edge login -u \"\${CLOAKMESH_USER:-admin}\" -p \"\${CLOAKMESH_PWD:-}\" -y https://127.0.0.1:\${CLOAKMESH_CTRL_ADVERTISED_PORT:-1280} >/dev/null 2>&1 &&
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
        warn "可手动执行第 4 节文档中的命令，把 JWT 写入 .env 的 CLOAKMESH_ENROLL_TOKEN"
        return 1
    fi
    sed -i '/^CLOAKMESH_ENROLL_TOKEN=/d' "$ENV_FILE" 2>/dev/null || true
    printf 'CLOAKMESH_ENROLL_TOKEN=%s\n' "$jwt" >> "$ENV_FILE"
    log "登记令牌已写入 $ENV_FILE（${#jwt} 字节）"
}

wait_healthy() {
    local i
    log "等待 controller 就绪..."
    for i in $(seq 1 90); do
        if compose ps controller --format '{{.Health}}' 2>/dev/null | grep -qi healthy; then return 0; fi
        sleep 2
    done
    warn "controller 健康检查超时，请执行 docker logs cloakmesh-controller 排查"
    return 1
}

# 在容器内的 config.yml 里把旧端口替换成新端口（端口感只在 config 与端口映射两处）
patch_config_ports() {
    local vol="$1" image="$2" old_a="$3" new_a="$4" old_b="$5" new_b="$6" label="$7"
    docker run --rm -v "${vol}:/cfgdir" --entrypoint sh "$image" -c "
        set -e
        f=/cfgdir/config.yml
        [ -s \"\$f\" ] || { echo 'config.yml 不存在'; exit 1; }
        if [ '${old_a}' != '${new_a}' ]; then sed -i -E 's|:${old_a}\b|:${new_a}|g' \"\$f\"; fi
        if [ -n '${old_b}' ] && [ '${old_b}' != '${new_b}' ]; then sed -i -E 's|:${old_b}\b|:${new_b}|g' \"\$f\"; fi
        echo '--- ${label} 端口现状 ---'
        grep -nE 'address:|advertise:|endpoint:|interface:' \"\$f\" | grep -E ':[0-9]+' | head -8
    "
}

do_reconfigure() {
    [ -f "$ENV_FILE" ] || die "--reconfigure 需要已有部署（未找到 $ENV_FILE）"

    local old_ctrl old_router new_ctrl new_router
    old_ctrl="$(env_get CLOAKMESH_CTRL_PORT)";   old_ctrl="${old_ctrl:-1280}"
    old_router="$(env_get CLOAKMESH_ROUTER_PORT)"; old_router="${old_router:-3022}"
    new_ctrl="${CTRL_PORT:-$old_ctrl}"
    new_router="${ROUTER_PORT:-$old_router}"

    if [ "$new_ctrl" = "$old_ctrl" ] && [ "$new_router" = "$old_router" ]; then
        die "端口未变化（ctrl=$old_ctrl router=$old_router），无需 --reconfigure"
    fi

    # 端口冲突自检（宿主机层）——只检查真正变化的端口，否则会被自己当前监听误判
    for p in "$new_ctrl" "$new_router"; do
        case "$p" in "$old_ctrl"|"$old_router") continue ;; esac
        if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"; then
            die "端口 $p 已被占用，请换一个（当前监听：$(ss -lnt 2>/dev/null | awk '{print $4}' | grep -E "[:.]${p}$" | head -1)）"
        fi
    done

    log "改端口：控制面 ${old_ctrl} → ${new_ctrl}，数据面 ${old_router} → ${new_router}"

    # 1) 更新 .env
    sed -i '/^CLOAKMESH_CTRL_PORT=/d; /^CLOAKMESH_ROUTER_PORT=/d' "$ENV_FILE"
    printf 'CLOAKMESH_CTRL_PORT=%s\nCLOAKMESH_ROUTER_PORT=%s\n' "$new_ctrl" "$new_router" >> "$ENV_FILE"

    # 2) 改容器内 config.yml（证书 SAN 不含端口，无需重签；路由器身份不变，无需重新登记）
    log "改写控制器 config.yml"
    patch_config_ports "cloakmesh_controller-data" "cloakmesh/controller:local" \
        "$old_ctrl" "$new_ctrl" "" "" "controller"
    log "改写路由器 config.yml（含控制器 endpoint）"
    patch_config_ports "cloakmesh_router-data" "cloakmesh/router:local" \
        "$old_router" "$new_router" "$old_ctrl" "$new_ctrl" "router"

    # 2.1) 路由器登记时把控制器地址写进了 endpoints.yml，改控制面端口必须同步
    if [ "$old_ctrl" != "$new_ctrl" ]; then
        log "改写路由器 endpoints.yml（登记时记录的控制器地址）"
        docker run --rm -v cloakmesh_router-data:/cfgdir --entrypoint sh cloakmesh/router:local -c "
            set -e
            f=/cfgdir/endpoints.yml
            [ -s \"\$f\" ] || exit 0
            sed -i -E 's|:${old_ctrl}\\b|:${new_ctrl}|g' \"\$f\"
            echo '--- endpoints.yml 现状 ---'
            grep -n ':${new_ctrl}' \"\$f\" | head -3
        "
    fi

    # 3) 重建容器：端口映射变了必须 force-recreate
    log "重建 controller"
    compose up -d --force-recreate controller >/dev/null
    wait_healthy || die "控制器未就绪，请查看 docker logs cloakmesh-controller"
    log "重建 router"
    compose up -d --force-recreate router >/dev/null
    sleep 10

    log "核对路由器状态"
    compose exec -T controller bash -lc "
        ziti edge login -u \"\${CLOAKMESH_USER:-admin}\" -p \"\${CLOAKMESH_PWD:-}\" -y https://127.0.0.1:${new_ctrl} >/dev/null 2>&1 &&
        ziti edge list edge-routers" 2>/dev/null || warn "无法查询路由器状态，请手动核对"

    cat <<EOF

================ 端口已更新 ================
 控制面（控制器 API）  : https://$(env_get CLOAKMESH_HOST):${new_ctrl}
 数据面（路由器）      : tcp://$(env_get CLOAKMESH_HOST):${new_router}
 已建立会话不受影响；如客户端已配置旧地址，需要改用新端口重新添加身份。
============================================
EOF
}

main() {
    require_docker

    if [ "$UNINSTALL" = "true" ]; then do_uninstall; exit 0; fi
    if [ "$RECONFIG" = "true" ]; then do_reconfigure; exit 0; fi

    local host pwd ctrl router
    host="$(detect_host)"
    pwd="${CLOAKMESH_PWD:-$(random_pwd)}"
    ctrl="${CTRL_PORT:-1280}"
    router="${ROUTER_PORT:-3022}"

    write_env "$host" "$pwd" "$ctrl" "$router"
    load_env

    # 已有部署时以 .env 为准；若要改端口必须走 --reconfigure
    if [ -n "$CTRL_PORT" ] && [ "${CTRL_PORT}" != "${CLOAKMESH_CTRL_PORT:-1280}" ]; then
        die "检测到已有部署且控制面端口不同，请用 --reconfigure --ctrl-port ${CTRL_PORT}"
    fi
    if [ -n "$ROUTER_PORT" ] && [ "${ROUTER_PORT}" != "${CLOAKMESH_ROUTER_PORT:-3022}" ]; then
        die "检测到已有部署且数据面端口不同，请用 --reconfigure --router-port ${ROUTER_PORT}"
    fi

    host="${CLOAKMESH_HOST:-$host}"
    pwd="${CLOAKMESH_PWD:-$pwd}"
    ctrl="${CLOAKMESH_CTRL_PORT:-$ctrl}"
    router="${CLOAKMESH_ROUTER_PORT:-$router}"
    ROUTER_NAME="${CLOAKMESH_ROUTER_NAME:-$ROUTER_NAME}"

    log "对外地址（证书 SAN）：$host"
    log "控制面端口：$ctrl   数据面端口：$router"

    if [ "$NO_BUILD" = "true" ]; then
        log "跳过镜像构建（--no-build）"
    else
        log "构建镜像：cloakmesh/controller、cloakmesh/router"
        compose build controller router
    fi

    log "启动 controller"
    compose up -d controller
    wait_healthy || true

    enroll_router "$ROUTER_NAME" || warn "路由器登记令牌缺失，router 将无法注册到控制器"

    if [ -n "$CONSOLE_DIR" ]; then
        build_console_image "$CONSOLE_DIR"
        log "启动 router + 中文控制台"
        compose --profile console up -d router console
    else
        warn "未指定 --console，跳过中文控制台"
        log "启动 router"
        compose up -d router
    fi

    sleep 5
    local router_status
    router_status="$(docker inspect -f '{{.State.Status}}' cloakmesh-router 2>/dev/null || echo unknown)"

    cat <<EOF

================ CloakMesh 部署完成 ================
 控制器 API : https://${host}:${ctrl}
 边缘路由器 : ${ROUTER_NAME}（tcp://${host}:${router}，容器状态：${router_status}）
 管理员用户 : ${CLOAKMESH_USER:-admin}
 管理员密码 : ${pwd}
$( [ -n "$CONSOLE_DIR" ] && printf ' 中文控制台 : http://<本机IP>:%s （登录时填 https://%s:%s）\n' "$CONSOLE_PORT" "$host" "$ctrl" )
---------------------------------------------------
 改端口：./deploy/linux/install.sh --reconfigure --router-port <新端口>
 提示：自签证书 SAN 为 ${host}，客户端访问前需能解析该地址
 常用命令：
   docker compose -f deploy/linux/docker-compose.yml --env-file deploy/linux/.env ps
   docker logs -f cloakmesh-controller / cloakmesh-router
   ./deploy/linux/install.sh --uninstall
====================================================
EOF
}

main "$@"