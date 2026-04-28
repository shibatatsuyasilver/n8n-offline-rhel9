#!/usr/bin/env bash
# n8n 離線安裝腳本 (針對 Red Hat 9.x)
# 在離線 RHEL 9 主機安裝 n8n + Node.js，連線至外部既有的 PostgreSQL。
# PostgreSQL server 由另一份 bundle (install-pg-offline.sh) 安裝在另一台 RHEL 主機。
#
# 必填環境變數：
#   N8N_DB_HOST       外部 PostgreSQL 主機 (IP 或 DNS 名稱)
#   N8N_DB_PASSWORD   PostgreSQL 上 n8n 角色的密碼
# 選填環境變數：
#   N8N_DB_PORT       (預設 5432)
#   N8N_DB_NAME       (預設 n8n)
#   N8N_DB_USER       (預設 n8n)
#   N8N_ENCRYPTION_KEY (未提供則自動產生)
#   N8N_PORT          (預設 5678)
#   GENERIC_TIMEZONE  (預設 Asia/Taipei)

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$SCRIPT_DIR"
VERIFY_NO_SYSTEMD=0
SKIP_SMOKE=0

usage() {
  cat <<USAGE
用法: $0 [選項]

選項:
  --bundle-dir DIR        使用指定的 DIR 作為離線 bundle 目錄。
  --verify-no-systemd     驗證模式（適用於沒有 systemd 的 Docker 容器）。
  --skip-smoke            跳過最後的 n8n HTTP 冒煙測試。
  -h, --help              顯示此幫助訊息。
USAGE
}

log() { printf '[install-offline] %s\n' "$*"; }
die() { printf '[install-offline] 錯誤: %s\n' "$*" >&2; exit 1; }
need_root() { [[ "$(id -u)" == "0" ]] || die "請以 root 權限執行此腳本"; }
need_command() { command -v "$1" >/dev/null 2>&1 || die "找不到必要的命令: $1"; }

parse_args() {
  while (($#)); do
    case "$1" in
      --bundle-dir) shift; BUNDLE_DIR="$1" ;;
      --verify-no-systemd) VERIFY_NO_SYSTEMD=1 ;;
      --skip-smoke) SKIP_SMOKE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知選項: $1" ;;
    esac
    shift
  done
}

require_db_env() {
  : "${N8N_DB_HOST:?必須提供 N8N_DB_HOST（外部 PostgreSQL 主機名稱或 IP）}"
  : "${N8N_DB_PASSWORD:?必須提供 N8N_DB_PASSWORD（外部 PostgreSQL n8n 角色密碼）}"
  N8N_DB_PORT="${N8N_DB_PORT:-5432}"
  N8N_DB_NAME="${N8N_DB_NAME:-n8n}"
  N8N_DB_USER="${N8N_DB_USER:-n8n}"
  export N8N_DB_HOST N8N_DB_PORT N8N_DB_NAME N8N_DB_USER N8N_DB_PASSWORD
}

load_manifest() {
  BUNDLE_DIR="$(cd "$BUNDLE_DIR" && pwd)"
  local manifest="${BUNDLE_DIR}/manifest.env"
  [[ -f "$manifest" ]] || die "找不到 bundle 清單文件: $manifest"
  # shellcheck disable=SC1090
  source "$manifest"
}

preflight() {
  log "正在執行預檢..."
  [[ -r /etc/os-release ]] || die "無法讀取 /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release

  if [[ "${ID:-}" != "$TARGET_OS_ID" && "${ID_LIKE:-}" != *"$TARGET_OS_ID"* ]]; then
    die "預期作業系統為 RHEL 家族，但目前為 ${ID:-unknown}"
  fi
  
  local major_version="${VERSION_ID%%.*}"
  [[ "$major_version" == "$TARGET_VERSION_ID" ]] || die "預期 RHEL 主版本為 ${TARGET_VERSION_ID}，但目前為 ${VERSION_ID:-unknown}"
  [[ "$(uname -m)" == "$TARGET_ARCH" ]] || die "預期架構為 ${TARGET_ARCH}，但目前為 $(uname -m)"

  if [[ "$VERIFY_NO_SYSTEMD" == "0" ]]; then
    need_command systemctl
    [[ -d /run/systemd/system ]] || die "systemd 並未在運行中"
  fi

  [[ -d "${BUNDLE_DIR}/${RPM_REPO_DIR}" ]] || die "找不到 rpm 倉庫目錄"
  log "正在驗證 bundle 檔案校驗碼..."
  ( cd "$BUNDLE_DIR"; sha256sum -c SHA256SUMS )
}

install_rpm_packages() {
  log "正在從本地離線倉庫安裝 rpm 軟體包..."

  local repo_file="/etc/yum.repos.d/n8n-offline.repo"
  cat > "$repo_file" <<REPO
[n8n-offline]
name=n8n Offline Packages
baseurl=file://${BUNDLE_DIR}/${RPM_REPO_DIR}
enabled=1
gpgcheck=0
REPO

  read -r -a seed_packages <<< "$DNF_SEED_PACKAGES"
  dnf --disablerepo="*" --enablerepo="n8n-offline" install -y --allowerasing "${seed_packages[@]}"
}

install_node() {
  log "正在安裝 Node.js ${NODE_VERSION}..."
  local node_prefix="/opt/${NODE_DIST}"
  rm -rf "$node_prefix"
  tar -xJf "${BUNDLE_DIR}/${NODE_TARBALL}" -C /opt

  ln -sfn "${node_prefix}/bin/node" /usr/local/bin/node
  ln -sfn "${node_prefix}/bin/npm" /usr/local/bin/npm
  ln -sfn "${node_prefix}/bin/npx" /usr/local/bin/npx
}

install_n8n() {
  log "正在安裝 n8n ${N8N_VERSION}..."
  rm -rf /opt/n8n
  tar -xJf "${BUNDLE_DIR}/${N8N_PREFIX_TARBALL}" -C /opt
  ln -sfn /opt/n8n/bin/n8n /usr/local/bin/n8n
}

create_user_and_dirs() {
  log "正在建立 n8n 用戶與相關目錄..."
  if ! getent group n8n >/dev/null; then groupadd --system n8n; fi
  if ! id n8n >/dev/null 2>&1; then useradd --system --gid n8n --home-dir /var/lib/n8n --shell /usr/sbin/nologin n8n; fi
  install -d -o n8n -g n8n -m 0750 /var/lib/n8n
  install -d -o n8n -g n8n -m 0750 /var/log/n8n
  install -d -o root -g root -m 0750 /etc/n8n
}

generate_secret_hex() { openssl rand -hex "$1"; }

write_env_file() {
  log "正在寫入 /etc/n8n/n8n.env..."
  local env_file="/etc/n8n/n8n.env"

  N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-$(generate_secret_hex 32)}"
  N8N_PORT="${N8N_PORT:-5678}"
  GENERIC_TIMEZONE="${GENERIC_TIMEZONE:-Asia/Taipei}"

  umask 077
  cat > "$env_file" <<ENV
NODE_ENV=production
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HOME=/var/lib/n8n
N8N_USER_FOLDER=/var/lib/n8n
N8N_LISTEN_ADDRESS=0.0.0.0
N8N_PORT=${N8N_PORT}
N8N_PROTOCOL=http
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_RUNNERS_ENABLED=true
GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
TZ=${GENERIC_TIMEZONE}
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=${N8N_DB_HOST}
DB_POSTGRESDB_PORT=${N8N_DB_PORT}
DB_POSTGRESDB_DATABASE=${N8N_DB_NAME}
DB_POSTGRESDB_USER=${N8N_DB_USER}
DB_POSTGRESDB_PASSWORD=${N8N_DB_PASSWORD}
DB_POSTGRESDB_SCHEMA=public
ENV
  chown root:n8n "$env_file"; chmod 640 "$env_file"
}

install_systemd_service() {
  [[ "$VERIFY_NO_SYSTEMD" == "0" ]] || return 0
  log "正在安裝 n8n systemd 服務..."

  cat > /etc/systemd/system/n8n.service <<'UNIT'
[Unit]
Description=n8n workflow automation
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=n8n
Group=n8n
EnvironmentFile=/etc/n8n/n8n.env
WorkingDirectory=/var/lib/n8n
ExecStart=/usr/local/bin/n8n start
Restart=on-failure
RestartSec=10
TimeoutStopSec=60
ReadWritePaths=/var/lib/n8n /var/log/n8n
StandardOutput=append:/var/log/n8n/n8n.log
StandardError=append:/var/log/n8n/n8n.err

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now n8n
}

verify_pg_connection() {
  log "正在驗證對外部 PostgreSQL (${N8N_DB_HOST}:${N8N_DB_PORT}) 的連線..."
  ( cd /opt/n8n/lib/node_modules/n8n && \
    DB_POSTGRESDB_HOST="$N8N_DB_HOST" \
    DB_POSTGRESDB_PORT="$N8N_DB_PORT" \
    DB_POSTGRESDB_USER="$N8N_DB_USER" \
    DB_POSTGRESDB_PASSWORD="$N8N_DB_PASSWORD" \
    DB_POSTGRESDB_DATABASE="$N8N_DB_NAME" \
    /usr/local/bin/node -e '
      const { Client } = require("pg");
      const c = new Client({
        host: process.env.DB_POSTGRESDB_HOST,
        port: +process.env.DB_POSTGRESDB_PORT,
        user: process.env.DB_POSTGRESDB_USER,
        password: process.env.DB_POSTGRESDB_PASSWORD,
        database: process.env.DB_POSTGRESDB_DATABASE,
      });
      c.connect()
        .then(() => c.query("SELECT 1"))
        .then(() => console.log("PG 連線 OK"))
        .catch(e => { console.error("PG 連線失敗:", e.message); process.exit(1); })
        .finally(() => c.end());
    '
  )
}

wait_for_http() {
  log "正在等待埠號 ${N8N_PORT} 上的 n8n HTTP 端點..."
  for _ in $(seq 1 90); do
    if curl -fsS --max-time 2 "http://127.0.0.1:${N8N_PORT}/healthz" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  die "n8n 未能在時間內響應 HTTP。"
}

systemd_smoke_test() {
  [[ "$SKIP_SMOKE" == "0" ]] || return 0
  log "正在執行 n8n 冒煙測試 (systemd)..."
  wait_for_http
  systemctl is-active --quiet n8n
}

verify_no_systemd_smoke_test() {
  [[ "$SKIP_SMOKE" == "0" ]] || return 0
  log "正在執行 n8n 冒煙測試 (背景啟動，無 systemd)..."
  install -d -o n8n -g n8n -m 0750 /var/log/n8n
  set -a; source /etc/n8n/n8n.env; set +a
  su -s /bin/bash n8n -c '/usr/local/bin/n8n start' \
    >/var/log/n8n/n8n.log 2>/var/log/n8n/n8n.err &
  local n8n_pid=$!
  trap "kill ${n8n_pid} >/dev/null 2>&1 || true" EXIT
  wait_for_http
  kill "${n8n_pid}" >/dev/null 2>&1 || true
  trap - EXIT
}

main() {
  parse_args "$@"
  need_root
  need_command sha256sum
  require_db_env

  load_manifest
  preflight
  install_rpm_packages
  install_node
  install_n8n
  create_user_and_dirs
  write_env_file
  verify_pg_connection
  install_systemd_service

  if [[ "$VERIFY_NO_SYSTEMD" == "0" ]]; then
    systemd_smoke_test
  else
    verify_no_systemd_smoke_test
  fi

  log "安裝完成。n8n 已配置於 http://0.0.0.0:${N8N_PORT}"
}
main "$@"