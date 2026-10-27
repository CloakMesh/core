#!/usr/bin/env bash
#
# cloakmesh-env.sh — 环境变量前缀桥接层
#
# CloakMesh 对外只暴露 CLOAKMESH_* 前缀，而上游运行时（bootstrap.bash /
# entrypoint.bash / Go 二进制）读取的是 ZITI_*。本脚本在启动瞬间做一次单向映射，
# 因此无需改动上游任何脚本或 Go 代码，即可让用户只写 CLOAKMESH_PWD 这类变量。
#
# 用法：
#   source /opt/cloakmesh/share/env.sh        # 导入即完成映射
#   /opt/cloakmesh/share/env.sh <cmd> [args]  # 以映射后的环境执行命令
#
# 规则：
#   CLOAKMESH_<X>  →  ZITI_<X>   （仅当 ZITI_<X> 尚未定义时才写入，不覆盖显式旧变量）
#
# 例：
#   CLOAKMESH_PWD=xxx  → ZITI_PWD=xxx
#   CLOAKMESH_CTRL_ADVERTISED_ADDRESS=ctrl.example.com
#                      → ZITI_CTRL_ADVERTISED_ADDRESS=ctrl.example.com

cloakmesh_map_env() {
    local entry name value suffix target
    while IFS='=' read -r name value; do
        case "$name" in
            CLOAKMESH_*)
                suffix="${name#CLOAKMESH_}"
                [ -n "$suffix" ] || continue
                target="ZITI_${suffix}"
                # 未定义才写入：declare -p 对已存在的变量（含空值）返回成功
                if ! declare -p "$target" >/dev/null 2>&1; then
                    export "${target}=${value}"
                fi
                ;;
        esac
    done < <(env)
}

cloakmesh_map_env

# 以脚本方式调用时，透传命令
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if [ "$#" -eq 0 ]; then
        echo "用法：$0 <cmd> [args...]  或  source $0" >&2
        exit 64
    fi
    exec "$@"
fi