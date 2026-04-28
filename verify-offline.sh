#!/usr/bin/env bash
# n8n 離線安裝端到端驗證腳本
# 在當前主機 (有 docker daemon 的開發機) 用 docker --internal 網路模擬
# 「離線 RHEL 9 + 外部 PostgreSQL 18」拓撲，跑一次完整 install-offline.sh。
#
# 不會驗證 install-pg-offline.sh —— PG 端使用官方 postgres:18 映像作為替身。

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_BUNDLE_DIR="${SCRIPT_DIR}/dist/n8n-offline-rhel9.6-x86_64"
BUNDLE_DIR="${DEFAULT_BUNDLE_DIR}"

PG_IMAGE="postgres:18"
RHEL_IMAGE="registry.access.redhat.com/ubi9/ubi"
DOCKER_PLATFORM="linux/amd64"

NETWORK_NAME="n8n-offline-verify-$$"
PG_CONTAINER="n8n-pg-verify-$$"
INSTALL_CONTAINER="n8n-install-verify-$$"
PG_PASSWORD="verify-pg-pass-$$"

usage() {
  cat <<USAGE
用法: $0 [選項]

選項:
  --bundle-dir DIR   指定 n8n 離線 bundle 目錄 (預設: ${DEFAULT_BUNDLE_DIR})
  -h, --help         顯示此幫助訊息
USAGE
}

log() { printf '[verify-offline] %s\n' "$*"; }
die() { printf '[verify-offline] 錯誤: %s\n' "$*" >&2; exit 1; }

cleanup() {
  log "清理測試資源..."
  docker rm -f "$INSTALL_CONTAINER" >/dev/null 2>&1 || true
  docker rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

parse_args() {
  while (($#)); do
    case "$1" in
      --bundle-dir) shift; BUNDLE_DIR="$1" ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知選項: $1" ;;
    esac
    shift
  done
  [[ -d "$BUNDLE_DIR" ]] || die "bundle 目錄不存在: $BUNDLE_DIR"
  BUNDLE_DIR="$(cd "$BUNDLE_DIR" && pwd)"
}

ensure_images() {
  log "確認映像檔已在本地 (internal network 中無法 pull)..."
  docker pull --platform "$DOCKER_PLATFORM" "$PG_IMAGE"
  docker pull --platform "$DOCKER_PLATFORM" "$RHEL_IMAGE"
}

create_network() {
  log "建立 internal docker 網路 $NETWORK_NAME (無 internet 出口)..."
  docker network create --internal --driver bridge "$NETWORK_NAME" >/dev/null
}

start_pg() {
  log "啟動 PostgreSQL 18 容器 $PG_CONTAINER..."
  docker run -d --name "$PG_CONTAINER" --network "$NETWORK_NAME" \
    --platform "$DOCKER_PLATFORM" \
    -e POSTGRES_USER=n8n \
    -e POSTGRES_PASSWORD="$PG_PASSWORD" \
    -e POSTGRES_DB=n8n \
    "$PG_IMAGE" >/dev/null

  log "等待 PG 就緒..."
  for _ in $(seq 1 60); do
    if docker exec "$PG_CONTAINER" pg_isready -U n8n -d n8n >/dev/null 2>&1; then
      log "PG 已就緒"
      return 0
    fi
    sleep 1
  done
  docker logs "$PG_CONTAINER" >&2 || true
  die "PG 在 60 秒內未就緒"
}

run_install() {
  log "在 ubi9 容器內執行 install-offline.sh --verify-no-systemd..."
  docker run --rm --name "$INSTALL_CONTAINER" --network "$NETWORK_NAME" \
    --platform "$DOCKER_PLATFORM" \
    -v "$BUNDLE_DIR:/bundle:ro" \
    -e N8N_DB_HOST="$PG_CONTAINER" \
    -e N8N_DB_PORT=5432 \
    -e N8N_DB_NAME=n8n \
    -e N8N_DB_USER=n8n \
    -e N8N_DB_PASSWORD="$PG_PASSWORD" \
    -e N8N_ENCRYPTION_KEY="$(openssl rand -hex 32)" \
    "$RHEL_IMAGE" \
    /bundle/install-offline.sh --verify-no-systemd --bundle-dir /bundle
}

main() {
  parse_args "$@"
  command -v docker >/dev/null 2>&1 || die "找不到 docker"
  ensure_images
  create_network
  start_pg
  run_install
  log "離線安裝端到端驗證通過。"
}
main "$@"
