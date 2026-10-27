#!/usr/bin/env bash
#
# CloakMesh 二进制构建脚本
#
# 产物：dist/bin/cloakmesh（对外品牌名）
#       dist/bin/ziti       → cloakmesh 的符号链接（兼容上游脚本内部调用）
#
# 用法：
#   ./branding/build.sh                 # 本机构建
#   OUT_DIR=/tmp/out ./branding/build.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/dist/bin}"
BIN_NAME="${BIN_NAME:-cloakmesh}"

VERSION="${CLOAKMESH_VERSION:-$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo dev)}"

mkdir -p "$OUT_DIR"

echo "==> 构建 ${BIN_NAME}（版本 ${VERSION}）"
cd "$ROOT"

# 上游 dist/docker-images/cross-build/Dockerfile 使用 CGO_ENABLED=1 构建，
# 这里保持一致，确保与官方产物的运行时行为相同。
CGO_ENABLED="${CGO_ENABLED:-1}" go build \
    -trimpath \
    -ldflags "-s -w" \
    -o "$OUT_DIR/$BIN_NAME" \
    ./ziti

# 上游 bootstrap.bash / entrypoint.bash 内部仍以 ziti 名称调用，
# 保留同名符号链接，避免为品牌化而改动这些脚本。
ln -sf "$BIN_NAME" "$OUT_DIR/ziti"

echo "==> 完成：$OUT_DIR/$BIN_NAME"
"$OUT_DIR/$BIN_NAME" version 2>/dev/null | head -5 || true