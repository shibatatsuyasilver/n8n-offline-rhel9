#!/usr/bin/env bash
# 在當前 Docker 環境啟動「n8n + 外部 PostgreSQL 18」的雙容器堆疊，
# 把 n8n 的 5678 對外公開到宿主機，方便瀏覽器存取。
# 使用兩份離線 bundle (n8n / postgres) 並透過 docker volume 持久化資料。

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

N8N_BUNDLE="${N8N_BUNDLE:-${SCRIPT_DIR}/dist/n8n-offline-rhel9.6-x86_64}"
PG_BUNDLE="${PG_BUNDLE:-${SCRIPT_DIR}/dist/postgres-offline-rhel9-x86_64}"

RHEL_IMAGE="registry.access.redhat.com/ubi9/ubi"
DOCKER_PLATFORM="linux/amd64"

NETWORK_NAME="n8n-stack"
PG_CONTAINER="n8n-stack-pg"
N8N_CONTAINER="n8n-stack-n8n"
PG_VOLUME="n8n-stack-pg-data"
N8N_VOLUME="n8n-stack-n8n-data"

N8N_HOST_PORT="${N8N_HOST_PORT:-5678}"
ENV_FILE="${SCRIPT_DIR}/.stack-env"

log() { printf '[run-stack] %s\n' "$*"; }
die() { printf '[run-stack] 錯誤: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
用法: $0 <command>

commands:
  up        建立網路 / 容器，啟動 n8n + PG，並把 n8n 5678 公開到宿主機 ${N8N_HOST_PORT}
  down      停止並移除容器與網路 (volume 保留，資料不會丟失)
  destroy   down + 同時刪除 docker volume (清空 PG 與 n8n 資料！)
  status    顯示容器狀態
  logs      跟隨 n8n 容器 log (Ctrl-C 結束)
  pg-logs   跟隨 PG 容器 log

環境變數 (覆寫預設):
  N8N_HOST_PORT     n8n 在宿主機監聽的埠 (預設 5678)
  N8N_BUNDLE        n8n bundle 路徑
  PG_BUNDLE         PG bundle 路徑
USAGE
}

ensure_env_file() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi
  if [[ -z "${PG_PASSWORD:-}" || -z "${N8N_ENCRYPTION_KEY:-}" ]]; then
    PG_PASSWORD="${PG_PASSWORD:-$(openssl rand -hex 24)}"
    N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-$(openssl rand -hex 32)}"
    umask 077
    cat > "$ENV_FILE" <<EOF
PG_PASSWORD='${PG_PASSWORD}'
N8N_ENCRYPTION_KEY='${N8N_ENCRYPTION_KEY}'
EOF
    log "已產生新憑證並寫入 ${ENV_FILE} (請保留以利後續重啟)"
  fi
  export PG_PASSWORD N8N_ENCRYPTION_KEY
}

container_exists() {
  docker ps -a --format '{{.Names}}' | grep -q "^${1}$"
}

container_running() {
  docker ps --format '{{.Names}}' | grep -q "^${1}$"
}

cmd_up() {
  [[ -d "$N8N_BUNDLE" ]] || die "n8n bundle 不存在: $N8N_BUNDLE"
  [[ -d "$PG_BUNDLE" ]] || die "PG bundle 不存在: $PG_BUNDLE"
  command -v docker >/dev/null 2>&1 || die "找不到 docker"

  ensure_env_file
  docker pull --platform "$DOCKER_PLATFORM" "$RHEL_IMAGE" >/dev/null

  if ! docker network ls --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
    log "建立網路 ${NETWORK_NAME}"
    docker network create --driver bridge "$NETWORK_NAME" >/dev/null
  fi

  docker volume create "$PG_VOLUME" >/dev/null
  docker volume create "$N8N_VOLUME" >/dev/null

  if container_running "$PG_CONTAINER"; then
    log "PG 容器已在運行"
  else
    container_exists "$PG_CONTAINER" && docker rm -f "$PG_CONTAINER" >/dev/null
    log "啟動 PG 容器 ${PG_CONTAINER}"
    docker run -d --name "$PG_CONTAINER" --network "$NETWORK_NAME" \
      --platform "$DOCKER_PLATFORM" \
      --restart unless-stopped \
      -v "$PG_BUNDLE:/bundle:ro" \
      -v "$PG_VOLUME:/var/lib/pgsql" \
      -e N8N_DB_PASSWORD="$PG_PASSWORD" \
      "$RHEL_IMAGE" \
      /bundle/install-pg-offline.sh --verify-no-systemd --bundle-dir /bundle >/dev/null
  fi

  log "等待 PG 就緒..."
  for i in $(seq 1 180); do
    if ! container_running "$PG_CONTAINER"; then
      docker logs --tail 30 "$PG_CONTAINER" >&2
      die "PG 容器在 ${i} 秒後終止"
    fi
    if docker exec "$PG_CONTAINER" /usr/pgsql-18/bin/pg_isready -h /var/run/postgresql >/dev/null 2>&1; then
      log "PG 已就緒"
      break
    fi
    sleep 1
  done

  if container_running "$N8N_CONTAINER"; then
    log "n8n 容器已在運行"
  else
    container_exists "$N8N_CONTAINER" && docker rm -f "$N8N_CONTAINER" >/dev/null
    log "啟動 n8n 容器 ${N8N_CONTAINER} (對外公開 :${N8N_HOST_PORT})"
    docker run -d --name "$N8N_CONTAINER" --network "$NETWORK_NAME" \
      --platform "$DOCKER_PLATFORM" \
      --restart unless-stopped \
      -p "${N8N_HOST_PORT}:5678" \
      -v "$N8N_BUNDLE:/bundle:ro" \
      -v "$N8N_VOLUME:/var/lib/n8n" \
      -e N8N_DB_HOST="$PG_CONTAINER" \
      -e N8N_DB_PORT=5432 \
      -e N8N_DB_NAME=n8n \
      -e N8N_DB_USER=n8n \
      -e N8N_DB_PASSWORD="$PG_PASSWORD" \
      -e N8N_ENCRYPTION_KEY="$N8N_ENCRYPTION_KEY" \
      "$RHEL_IMAGE" \
      bash -c '
        set -Eeuo pipefail
        if [[ ! -f /opt/n8n/.installed ]]; then
          /bundle/install-offline.sh --verify-no-systemd --skip-smoke --bundle-dir /bundle
          touch /opt/n8n/.installed
        fi
        # 以 root 讀 env 後 export，再切到 n8n user 起 n8n。
        # runuser -m 保留環境變數 (DB_POSTGRESDB_*、N8N_ENCRYPTION_KEY 等)
        set -a; . /etc/n8n/n8n.env; set +a
        exec runuser -m -u n8n -- /usr/local/bin/n8n start
      ' >/dev/null
  fi

  cat <<EOF

[run-stack] 完成。n8n 即將在 http://localhost:${N8N_HOST_PORT} 上線。
            首次啟動需數十秒（容器內要解壓 n8n + 連 PG）。
            查看進度:    $0 logs
            停止 (留資料): $0 down
            完全清空:    $0 destroy
EOF
}

cmd_down() {
  log "停止並移除容器與網路 (volume 保留)"
  docker rm -f "$N8N_CONTAINER" >/dev/null 2>&1 || true
  docker rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
}

cmd_destroy() {
  cmd_down
  log "刪除 docker volume (資料將遺失)"
  docker volume rm "$N8N_VOLUME" >/dev/null 2>&1 || true
  docker volume rm "$PG_VOLUME" >/dev/null 2>&1 || true
  rm -f "$ENV_FILE"
}

cmd_status() {
  docker ps -a --filter "name=${PG_CONTAINER}" --filter "name=${N8N_CONTAINER}" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
}

cmd_logs() {
  docker logs -f "$N8N_CONTAINER"
}

cmd_pg_logs() {
  docker logs -f "$PG_CONTAINER"
}

case "${1:-}" in
  up) shift; cmd_up "$@" ;;
  down) shift; cmd_down "$@" ;;
  destroy) shift; cmd_destroy "$@" ;;
  status) cmd_status ;;
  logs) cmd_logs ;;
  pg-logs) cmd_pg_logs ;;
  ""|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
