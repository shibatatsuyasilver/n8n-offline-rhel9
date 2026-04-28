#!/usr/bin/env bash
# n8n + PostgreSQL 雙離線 bundle 端到端驗證
# 用 docker --internal 網路 + 兩個 ubi9 容器：
#   - PG host: 掛 PG bundle 跑 install-pg-offline.sh --verify-no-systemd
#   - n8n host: 掛 n8n bundle 跑 install-offline.sh --verify-no-systemd
# 完整模擬「兩台離線 RHEL 9 主機，n8n 連到外部 PG」的拓撲。

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_N8N_BUNDLE="${SCRIPT_DIR}/dist/n8n-offline-rhel9.6-x86_64"
DEFAULT_PG_BUNDLE="${SCRIPT_DIR}/dist/postgres-offline-rhel9-x86_64"
N8N_BUNDLE="${DEFAULT_N8N_BUNDLE}"
PG_BUNDLE="${DEFAULT_PG_BUNDLE}"

RHEL_IMAGE="registry.access.redhat.com/ubi9/ubi"
DOCKER_PLATFORM="linux/amd64"

NETWORK_NAME="n8n-full-verify-$$"
PG_CONTAINER="n8n-pg-full-$$"
INSTALL_CONTAINER="n8n-install-full-$$"
PG_PASSWORD="full-verify-pass-$$"

usage() {
  cat <<USAGE
用法: $0 [選項]

選項:
  --n8n-bundle DIR   n8n 離線 bundle 目錄 (預設: ${DEFAULT_N8N_BUNDLE})
  --pg-bundle DIR    PG 離線 bundle 目錄 (預設: ${DEFAULT_PG_BUNDLE})
  -h, --help         顯示此幫助訊息
USAGE
}

log() { printf '[verify-offline-full] %s\n' "$*"; }
die() { printf '[verify-offline-full] 錯誤: %s\n' "$*" >&2; exit 1; }

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
      --n8n-bundle) shift; N8N_BUNDLE="$1" ;;
      --pg-bundle) shift; PG_BUNDLE="$1" ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知選項: $1" ;;
    esac
    shift
  done
  [[ -d "$N8N_BUNDLE" ]] || die "n8n bundle 目錄不存在: $N8N_BUNDLE"
  [[ -d "$PG_BUNDLE" ]] || die "PG bundle 目錄不存在: $PG_BUNDLE"
  N8N_BUNDLE="$(cd "$N8N_BUNDLE" && pwd)"
  PG_BUNDLE="$(cd "$PG_BUNDLE" && pwd)"
}

ensure_image() {
  log "確認 ubi9 映像已在本地..."
  docker pull --platform "$DOCKER_PLATFORM" "$RHEL_IMAGE"
}

create_network() {
  log "建立 internal docker 網路 $NETWORK_NAME (無 internet 出口)..."
  docker network create --internal --driver bridge "$NETWORK_NAME" >/dev/null
}

start_pg_host() {
  log "啟動 PG 容器 $PG_CONTAINER (跑 install-pg-offline.sh --verify-no-systemd)..."
  docker run -d --name "$PG_CONTAINER" --network "$NETWORK_NAME" \
    --platform "$DOCKER_PLATFORM" \
    -v "$PG_BUNDLE:/bundle:ro" \
    -e N8N_DB_PASSWORD="$PG_PASSWORD" \
    "$RHEL_IMAGE" \
    /bundle/install-pg-offline.sh --verify-no-systemd --bundle-dir /bundle >/dev/null

  log "等待 PG host 完成安裝並進入前景模式 (可能需數分鐘)..."
  for i in $(seq 1 180); do
    if ! docker ps --format '{{.Names}}' | grep -q "^${PG_CONTAINER}$"; then
      docker logs "$PG_CONTAINER" >&2
      die "PG 容器在 ${i} 秒後終止，安裝失敗"
    fi
    if docker exec "$PG_CONTAINER" /usr/pgsql-18/bin/pg_isready -h /var/run/postgresql >/dev/null 2>&1; then
      log "PG 已就緒 (前景執行中)"
      return 0
    fi
    sleep 1
  done
  docker logs "$PG_CONTAINER" >&2
  die "PG 在 180 秒內未就緒"
}

run_n8n_install() {
  log "在 n8n 容器內執行 install-offline.sh --verify-no-systemd..."
  docker run --rm --name "$INSTALL_CONTAINER" --network "$NETWORK_NAME" \
    --platform "$DOCKER_PLATFORM" \
    -v "$N8N_BUNDLE:/bundle:ro" \
    -e N8N_DB_HOST="$PG_CONTAINER" \
    -e N8N_DB_PORT=5432 \
    -e N8N_DB_NAME=n8n \
    -e N8N_DB_USER=n8n \
    -e N8N_DB_PASSWORD="$PG_PASSWORD" \
    -e N8N_ENCRYPTION_KEY="$(openssl rand -hex 32)" \
    "$RHEL_IMAGE" \
    /bundle/install-offline.sh --verify-no-systemd --bundle-dir /bundle
}

verify_pgvector() {
  log "驗證 pgvector 擴充已在 n8n DB 啟用..."
  if docker exec "$PG_CONTAINER" su - postgres -c \
      "/usr/pgsql-18/bin/psql -d n8n -tAc \"SELECT extname FROM pg_extension WHERE extname='vector';\"" \
      | grep -q '^vector$'; then
    log "pgvector OK"
  else
    docker logs --tail 30 "$PG_CONTAINER" >&2
    die "n8n DB 未啟用 vector 擴充"
  fi
}

main() {
  parse_args "$@"
  command -v docker >/dev/null 2>&1 || die "找不到 docker"
  ensure_image
  create_network
  start_pg_host
  run_n8n_install
  verify_pgvector
  log "雙 bundle 端到端驗證通過：n8n install + PG install + pgvector + 跨主機連線。"
}
main "$@"
