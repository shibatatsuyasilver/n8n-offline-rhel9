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
#   N8N_PORT          (預設 5678，僅綁 127.0.0.1，由 nginx 反代)
#   GENERIC_TIMEZONE  (預設 Asia/Taipei)
#   N8N_TLS_HOSTNAME  (預設 hostname -f) self-signed 憑證 CN/SAN 與 N8N_HOST
#   N8N_TLS_EXTRA_IP  (預設自動偵測主預設路由 IP) 加入 cert SAN
#   N8N_TLS_DAYS      (預設 3650) self-signed 憑證有效天數
#   N8N_HTTPS_PORT    (預設 443) nginx 對外監聽埠

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
  --skip-smoke            跳過最後的 n8n HTTPS 冒煙測試。
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

resolve_tls_env() {
  if [[ -z "${N8N_TLS_HOSTNAME:-}" ]]; then
    N8N_TLS_HOSTNAME="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo localhost)"
  fi
  if [[ -z "${N8N_TLS_EXTRA_IP:-}" ]]; then
    N8N_TLS_EXTRA_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || true)"
    [[ -n "$N8N_TLS_EXTRA_IP" ]] || N8N_TLS_EXTRA_IP="127.0.0.1"
  fi
  N8N_TLS_DAYS="${N8N_TLS_DAYS:-3650}"
  N8N_HTTPS_PORT="${N8N_HTTPS_PORT:-443}"
  export N8N_TLS_HOSTNAME N8N_TLS_EXTRA_IP N8N_TLS_DAYS N8N_HTTPS_PORT
}

public_https_url() {
  if [[ "$N8N_HTTPS_PORT" == "443" ]]; then
    printf 'https://%s/' "$N8N_TLS_HOSTNAME"
  else
    printf 'https://%s:%s/' "$N8N_TLS_HOSTNAME" "$N8N_HTTPS_PORT"
  fi
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
  chown -R n8n:n8n /var/lib/n8n /var/log/n8n
}

generate_secret_hex() { openssl rand -hex "$1"; }

write_env_file() {
  log "正在寫入 /etc/n8n/n8n.env..."
  local env_file="/etc/n8n/n8n.env"
  local webhook_url

  N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-$(generate_secret_hex 32)}"
  N8N_PORT="${N8N_PORT:-5678}"
  GENERIC_TIMEZONE="${GENERIC_TIMEZONE:-Asia/Taipei}"
  webhook_url="$(public_https_url)"

  umask 077
  cat > "$env_file" <<ENV
NODE_ENV=production
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HOME=/var/lib/n8n
N8N_USER_FOLDER=/var/lib/n8n
N8N_LISTEN_ADDRESS=127.0.0.1
N8N_PORT=${N8N_PORT}
N8N_PROTOCOL=https
N8N_HOST=${N8N_TLS_HOSTNAME}
WEBHOOK_URL=${webhook_url}
N8N_PROXY_HOPS=1
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

generate_self_signed_cert() {
  local tls_dir=/etc/n8n/tls
  local key_file="$tls_dir/server.key"
  local crt_file="$tls_dir/server.crt"

  install -d -o root -g root -m 0750 "$tls_dir"
  if [[ -s "$key_file" && -s "$crt_file" ]]; then
    log "self-signed 憑證已存在，跳過產生 (${crt_file})"
  else
    log "產生 self-signed 憑證 CN=${N8N_TLS_HOSTNAME} SAN=DNS:${N8N_TLS_HOSTNAME},IP:${N8N_TLS_EXTRA_IP} (${N8N_TLS_DAYS} 天)..."
    umask 077
    openssl req -x509 -nodes \
      -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
      -keyout "${key_file}.tmp" \
      -out "${crt_file}.tmp" \
      -days "$N8N_TLS_DAYS" \
      -subj "/CN=${N8N_TLS_HOSTNAME}" \
      -addext "subjectAltName=DNS:${N8N_TLS_HOSTNAME},IP:${N8N_TLS_EXTRA_IP}" \
      >/dev/null 2>&1
    mv "${key_file}.tmp" "$key_file"
    mv "${crt_file}.tmp" "$crt_file"
  fi

  if getent group nginx >/dev/null; then
    chown root:nginx "$key_file" "$crt_file"
  else
    chown root:root "$key_file" "$crt_file"
  fi
  chmod 0640 "$key_file" "$crt_file"
}

write_nginx_config() {
  log "寫入 nginx 反向代理設定..."

  cat > /etc/nginx/nginx.conf <<'NGINXCONF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    tcp_nopush      on;
    keepalive_timeout 65;
    server_tokens   off;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    include /etc/nginx/conf.d/*.conf;
}
NGINXCONF

  cat > /etc/nginx/conf.d/n8n.conf <<NGINXSITE
server {
    listen ${N8N_HTTPS_PORT} ssl http2;
    listen [::]:${N8N_HTTPS_PORT} ssl http2;
    server_name _;

    ssl_certificate     /etc/n8n/tls/server.crt;
    ssl_certificate_key /etc/n8n/tls/server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    client_max_body_size 100M;
    proxy_read_timeout   3600s;
    proxy_send_timeout   3600s;

    location / {
        proxy_pass http://127.0.0.1:${N8N_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host              \$http_host;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        \$connection_upgrade;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host  \$http_host;
    }
}
NGINXSITE
}

test_nginx_config() {
  log "驗證 nginx 設定..."
  /usr/sbin/nginx -t
}

configure_host_for_nginx() {
  [[ "$VERIFY_NO_SYSTEMD" == "0" ]] || return 0

  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
    if command -v setsebool >/dev/null 2>&1; then
      log "設定 SELinux: httpd_can_network_connect=on"
      setsebool -P httpd_can_network_connect 1 || log "warning: setsebool 失敗，可能需手動處理"
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    log "firewalld: 開放 ${N8N_HTTPS_PORT}/tcp"
    firewall-cmd --permanent --add-port="${N8N_HTTPS_PORT}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
  fi
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
  systemctl enable --now nginx
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

wait_for_https() {
  log "正在等待 https://127.0.0.1:${N8N_HTTPS_PORT}/healthz (透過 nginx 反代到 n8n:${N8N_PORT})..."
  for _ in $(seq 1 90); do
    if curl -kfsS --max-time 2 "https://127.0.0.1:${N8N_HTTPS_PORT}/healthz" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  die "n8n / nginx 未能在時間內響應 HTTPS。"
}

systemd_smoke_test() {
  [[ "$SKIP_SMOKE" == "0" ]] || return 0
  log "正在執行 n8n 冒煙測試 (systemd)..."
  wait_for_https
  systemctl is-active --quiet n8n
  systemctl is-active --quiet nginx
}

verify_no_systemd_smoke_test() {
  [[ "$SKIP_SMOKE" == "0" ]] || return 0
  log "正在執行 n8n + nginx 冒煙測試 (背景啟動，無 systemd)..."
  install -d -o n8n -g n8n -m 0750 /var/log/n8n
  install -d -o root -g root -m 0755 /var/log/nginx
  set -a; source /etc/n8n/n8n.env; set +a
  su -s /bin/bash n8n -c '/usr/local/bin/n8n start' \
    >/var/log/n8n/n8n.log 2>/var/log/n8n/n8n.err &
  local n8n_pid=$!
  test_nginx_config
  /usr/sbin/nginx
  trap "kill ${n8n_pid} >/dev/null 2>&1 || true; /usr/sbin/nginx -s quit >/dev/null 2>&1 || true" EXIT
  wait_for_https
  /usr/sbin/nginx -s quit >/dev/null 2>&1 || true
  kill "${n8n_pid}" >/dev/null 2>&1 || true
  trap - EXIT
}

main() {
  parse_args "$@"
  need_root
  need_command sha256sum
  require_db_env
  resolve_tls_env

  load_manifest
  preflight
  install_rpm_packages
  install_node
  install_n8n
  create_user_and_dirs
  write_env_file
  verify_pg_connection
  generate_self_signed_cert
  write_nginx_config
  test_nginx_config
  configure_host_for_nginx
  install_systemd_service

  if [[ "$VERIFY_NO_SYSTEMD" == "0" ]]; then
    systemd_smoke_test
  else
    verify_no_systemd_smoke_test
  fi

  log "安裝完成。n8n 已配置於 $(public_https_url) (self-signed, 瀏覽器首次會出現憑證警告)"
}
main "$@"
