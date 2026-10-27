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

# ---------------------------------------------------------------------------
# 注意：不要给 ZITI_* 变量设置含空格的值——上游 exportZitiVars() 用
# `export "${line%=*}"` 处理 `set` 输出，含空格的值会被截断并报 not a valid identifier。
#
# 上游 bootstrap/entrypoint 脚本启用 `set -u`，下列变量在上游 compose / systemd
# 中由调用方显式提供，缺失时会直接以 unbound variable 崩溃。这里给出安全默认值，
# 仍可用 CLOAKMESH_* （映射为 ZITI_*）覆盖。
# ---------------------------------------------------------------------------
: "${ZITI_BOOTSTRAP_CLUSTER:=false}"
: "${ZITI_BOOTSTRAP_CONFIG_ARGS:=}"
: "${ZITI_ENROLL_TOKEN:=}"
: "${ZITI_ROUTER_LAN_INTERFACE:=}"
: "${ZITI_ROUTER_IDENTITY_CERT:=}"
export ZITI_BOOTSTRAP_CLUSTER ZITI_BOOTSTRAP_CONFIG_ARGS \
       ZITI_ENROLL_TOKEN ZITI_ROUTER_LAN_INTERFACE ZITI_ROUTER_IDENTITY_CERT

# 开启 root/intermediate PKI bootstrap 时，上游会按「集群模式」生成配置并要求节点名
if [ "${ZITI_BOOTSTRAP_CLUSTER}" = "true" ] && [ -z "${ZITI_CLUSTER_NODE_NAME}" ]; then
    export ZITI_CLUSTER_NODE_NAME="${HOSTNAME:-controller-1}"
fi


# ---------------------------------------------------------------------------
# 路由器：上游 `create config router` 生成的 csr.sans 只含 hostname/localhost/127.0.0.1，
# 若对外公布的是 IP，证书里就没有 IP 类型 SAN，router 启动会 fatal：
#   identity is not valid for provided host: [...]
# 这里在首次生成 config.yml 后把公布地址补进 csr.sans 的 ip/dns 列表（幂等）。
# ---------------------------------------------------------------------------
ensure_router_csr_sans() {
    local cfg="${ZITI_HOME}/config.yml"
    local addr="${ZITI_ROUTER_ADVERTISED_ADDRESS:-}"
    [ -n "${ZITI_ROUTER_NAME:-}" ] || return 0
    [ -n "$addr" ] || return 0

    if [ ! -s "$cfg" ]; then
        cloakmesh create config router "${ZITI_ROUTER_TYPE:-edge}" \
            --routerName "${ZITI_ROUTER_NAME}" \
            --output "$cfg" \
            --tunnelerMode "${ZITI_ROUTER_MODE:-host}" >/dev/null 2>&1 || {
                echo "[cloakmesh] 警告：预生成 config.yml 失败，回退上游 bootstrap 默认行为" >&2
                return 0
            }
    fi

    grep -q 'sans:' "$cfg" 2>/dev/null || return 0
    grep -q -- "- \"${addr}\"" "$cfg" 2>/dev/null && return 0

    case "$addr" in
        *[!0-9.]*)  _kind=dns ;;
        *)          _kind=ip  ;;
    esac

    local tmp="${cfg}.cloakmesh.tmp"
    awk -v addr="$addr" -v kind="$_kind" '
        { print }
        !done && $0 ~ ("^      " kind ":") {
            match($0, /^ */); pad = substr($0, 1, RLENGTH) "  ";
            print pad "- \"" addr "\"";
            done = 1
        }
    ' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
    echo "[cloakmesh] 已在 csr.sans.${_kind} 中补充：${addr}" >&2
}

ensure_router_csr_sans

echo "[cloakmesh] 启动：binary=/usr/local/bin/cloakmesh home=${ZITI_HOME:-<unset>}" >&2

exec /entrypoint.bash "$@"