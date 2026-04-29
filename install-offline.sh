#!/usr/bin/env bash
# n8n offline installer for Red Hat 9.x.
# Installs n8n and Node.js on an offline RHEL 9 host.
# PostgreSQL is expected to run on another host, installed from the PG bundle.
#
# Required environment variables:
#   N8N_DB_HOST       External PostgreSQL host, as an IP address or DNS name.
#   N8N_DB_PASSWORD   Password for the n8n PostgreSQL role.
# Optional environment variables:
#   N8N_DB_PORT        Defaults to 5432.
#   N8N_DB_NAME        Defaults to n8n.
#   N8N_DB_USER        Defaults to n8n.
#   N8N_ENCRYPTION_KEY Generated automatically when omitted.
#   N8N_PORT           Internal n8n port; defaults to 5678 and binds to 127.0.0.1.
#   GENERIC_TIMEZONE   Defaults to Asia/Taipei.
#   N8N_TLS_HOSTNAME   Defaults to hostname -f; used for cert CN/SAN and N8N_HOST.
#   N8N_TLS_EXTRA_IP   Defaults to the primary route IP; added to cert SAN.
#   N8N_TLS_DAYS       Defaults to 3650.
#   N8N_HTTPS_PORT     External nginx HTTPS port; defaults to 443.

# Enable strict Bash behavior so failures stop the installer immediately.
set -Eeuo pipefail

# Resolve the absolute directory that contains this installer.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$SCRIPT_DIR"
VERIFY_NO_SYSTEMD=0
SKIP_SMOKE=0

# Print command-line help.
usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --bundle-dir DIR        Use DIR as the offline bundle directory.
  --verify-no-systemd     Verification mode for Docker containers without systemd.
  --skip-smoke            Skip the final n8n HTTPS smoke test.
  -h, --help              Show this help message.
USAGE
}

# Print normal log messages.
log() { printf '[install-offline] %s\n' "$*"; }
# Print an error and exit.
die() { printf '[install-offline] ERROR: %s\n' "$*" >&2; exit 1; }
# Require root because the installer writes system paths and services.
need_root() { [[ "$(id -u)" == "0" ]] || die "Run this installer as root"; }
# Require a command to exist before using it.
need_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

# Parse command-line arguments.
parse_args() {
  while (($#)); do
    case "$1" in
      --bundle-dir) shift; BUNDLE_DIR="$1" ;; # Set the offline bundle path.
      --verify-no-systemd) VERIFY_NO_SYSTEMD=1 ;; # Docker verification mode without systemd.
      --skip-smoke) SKIP_SMOKE=1 ;; # Skip the final smoke test.
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
}

# Validate required database settings and export them for child processes.
require_db_env() {
  : "${N8N_DB_HOST:?N8N_DB_HOST is required, set it to the external PostgreSQL host name or IP}"
  : "${N8N_DB_PASSWORD:?N8N_DB_PASSWORD is required for the external PostgreSQL n8n role}"
  N8N_DB_PORT="${N8N_DB_PORT:-5432}"
  N8N_DB_NAME="${N8N_DB_NAME:-n8n}"
  N8N_DB_USER="${N8N_DB_USER:-n8n}"
  export N8N_DB_HOST N8N_DB_PORT N8N_DB_NAME N8N_DB_USER N8N_DB_PASSWORD
}

# Resolve TLS defaults for hostname, SAN IP, certificate duration, and HTTPS port.
resolve_tls_env() {
  if [[ -z "${N8N_TLS_HOSTNAME:-}" ]]; then
    N8N_TLS_HOSTNAME="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo localhost)"
  fi
  if [[ -z "${N8N_TLS_EXTRA_IP:-}" ]]; then
    # Detect the primary route IP and fall back to loopback.
    N8N_TLS_EXTRA_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || true)"
    [[ -n "$N8N_TLS_EXTRA_IP" ]] || N8N_TLS_EXTRA_IP="127.0.0.1"
  fi
  N8N_TLS_DAYS="${N8N_TLS_DAYS:-3650}"
  N8N_HTTPS_PORT="${N8N_HTTPS_PORT:-443}"
  export N8N_TLS_HOSTNAME N8N_TLS_EXTRA_IP N8N_TLS_DAYS N8N_HTTPS_PORT
}

# Build the public HTTPS URL used by webhooks and status output.
public_https_url() {
  if [[ "$N8N_HTTPS_PORT" == "443" ]]; then
    printf 'https://%s/' "$N8N_TLS_HOSTNAME"
  else
    printf 'https://%s:%s/' "$N8N_TLS_HOSTNAME" "$N8N_HTTPS_PORT"
  fi
}

# Load bundle metadata created by prepare-online.sh.
load_manifest() {
  BUNDLE_DIR="$(cd "$BUNDLE_DIR" && pwd)"
  local manifest="${BUNDLE_DIR}/manifest.env"
  [[ -f "$manifest" ]] || die "Bundle manifest not found: $manifest"
  # shellcheck disable=SC1090
  source "$manifest"
}

# Check OS, architecture, systemd availability, and bundle integrity before install.
preflight() {
  log "Running preflight checks..."
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release

  # Verify that this is a RHEL-family operating system.
  if [[ "${ID:-}" != "$TARGET_OS_ID" && "${ID_LIKE:-}" != *"$TARGET_OS_ID"* ]]; then
    die "Expected a RHEL-family operating system, got ${ID:-unknown}"
  fi

  # Verify the major OS version.
  local major_version="${VERSION_ID%%.*}"
  [[ "$major_version" == "$TARGET_VERSION_ID" ]] || die "Expected RHEL major version ${TARGET_VERSION_ID}, got ${VERSION_ID:-unknown}"

  # Verify CPU architecture.
  [[ "$(uname -m)" == "$TARGET_ARCH" ]] || die "Expected architecture ${TARGET_ARCH}, got $(uname -m)"

  # Production mode requires a running systemd instance.
  if [[ "$VERIFY_NO_SYSTEMD" == "0" ]]; then
    need_command systemctl
    [[ -d /run/systemd/system ]] || die "systemd is not running"
  fi

  # Verify the local RPM repository and all bundle checksums.
  [[ -d "${BUNDLE_DIR}/${RPM_REPO_DIR}" ]] || die "RPM repository directory not found"
  log "Verifying bundle checksums..."
  ( cd "$BUNDLE_DIR"; sha256sum -c SHA256SUMS )
}

# Install required RPM packages from the local offline repository.
install_rpm_packages() {
  log "Installing RPM packages from the local offline repository..."

  local repo_file="/etc/yum.repos.d/n8n-offline.repo"
  # Write a yum repository file that points only at the local bundle.
  cat > "$repo_file" <<REPO
[n8n-offline]
name=n8n Offline Packages
baseurl=file://${BUNDLE_DIR}/${RPM_REPO_DIR}
enabled=1
gpgcheck=0
REPO

  # Read the package seed list from the manifest and install offline.
  read -r -a seed_packages <<< "$DNF_SEED_PACKAGES"
  dnf --disablerepo="*" --enablerepo="n8n-offline" install -y --allowerasing "${seed_packages[@]}"
}

# Extract Node.js under /opt and expose global executables through /usr/local/bin.
install_node() {
  log "Installing Node.js ${NODE_VERSION}..."
  local node_prefix="/opt/${NODE_DIST}"
  rm -rf "$node_prefix"
  tar -xJf "${BUNDLE_DIR}/${NODE_TARBALL}" -C /opt

  ln -sfn "${node_prefix}/bin/node" /usr/local/bin/node
  ln -sfn "${node_prefix}/bin/npm" /usr/local/bin/npm
  ln -sfn "${node_prefix}/bin/npx" /usr/local/bin/npx
}

# Extract the prebuilt n8n prefix under /opt/n8n.
install_n8n() {
  log "Installing n8n ${N8N_VERSION}..."
  rm -rf /opt/n8n
  tar -xJf "${BUNDLE_DIR}/${N8N_PREFIX_TARBALL}" -C /opt
  ln -sfn /opt/n8n/bin/n8n /usr/local/bin/n8n
}

# Create the n8n system user and the required data, log, and config directories.
create_user_and_dirs() {
  log "Creating n8n user and directories..."
  if ! getent group n8n >/dev/null; then groupadd --system n8n; fi
  if ! id n8n >/dev/null 2>&1; then useradd --system --gid n8n --home-dir /var/lib/n8n --shell /usr/sbin/nologin n8n; fi

  install -d -o n8n -g n8n -m 0750 /var/lib/n8n
  install -d -o n8n -g n8n -m 0750 /var/log/n8n
  install -d -o root -g root -m 0750 /etc/n8n
  chown -R n8n:n8n /var/lib/n8n /var/log/n8n
}

# Generate a random hexadecimal secret.
generate_secret_hex() { openssl rand -hex "$1"; }

# Write the n8n environment file, including database settings and secrets.
write_env_file() {
  log "Writing /etc/n8n/n8n.env..."
  local env_file="/etc/n8n/n8n.env"
  local webhook_url

  # Generate N8N_ENCRYPTION_KEY when the caller did not provide one.
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
  # Restrict ownership and permissions for the environment file.
  chown root:n8n "$env_file"; chmod 640 "$env_file"
}

# Generate a self-signed TLS certificate for the nginx HTTPS reverse proxy.
generate_self_signed_cert() {
  local tls_dir=/etc/n8n/tls
  local key_file="$tls_dir/server.key"
  local crt_file="$tls_dir/server.crt"

  install -d -o root -g root -m 0750 "$tls_dir"
  if [[ -s "$key_file" && -s "$crt_file" ]]; then
    log "Self-signed certificate already exists, skipping generation (${crt_file})"
  else
    log "Generating self-signed certificate CN=${N8N_TLS_HOSTNAME} SAN=DNS:${N8N_TLS_HOSTNAME},IP:${N8N_TLS_EXTRA_IP} (${N8N_TLS_DAYS} days)..."
    umask 077
    # Generate an ECDSA P-256 self-signed certificate.
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

  # Ensure the nginx user can read the certificate and key.
  if getent group nginx >/dev/null; then
    chown root:nginx "$key_file" "$crt_file"
  else
    chown root:root "$key_file" "$crt_file"
  fi
  chmod 0640 "$key_file" "$crt_file"
}

# Write nginx main config and the n8n HTTPS reverse proxy site config.
write_nginx_config() {
  log "Writing nginx reverse proxy configuration..."

  # Replace the main nginx config with a minimal offline-stack config.
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

  # Write the n8n reverse proxy site.
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

    # Proxy all traffic to the local n8n listener.
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

# Validate nginx configuration syntax before enabling services.
test_nginx_config() {
  log "Validating nginx configuration..."
  /usr/sbin/nginx -t
}

# Configure SELinux and firewalld when they are present and active.
configure_host_for_nginx() {
  [[ "$VERIFY_NO_SYSTEMD" == "0" ]] || return 0

  # Allow nginx/httpd services to open outbound connections for reverse proxying.
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
    if command -v setsebool >/dev/null 2>&1; then
      log "Setting SELinux boolean: httpd_can_network_connect=on"
      setsebool -P httpd_can_network_connect 1 || log "warning: setsebool failed, manual SELinux handling may be required"
    fi
  fi

  # Open the configured HTTPS port in firewalld.
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    log "firewalld: opening ${N8N_HTTPS_PORT}/tcp"
    firewall-cmd --permanent --add-port="${N8N_HTTPS_PORT}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
  fi
}

# Create and enable the n8n systemd service.
install_systemd_service() {
  [[ "$VERIFY_NO_SYSTEMD" == "0" ]] || return 0
  log "Installing n8n systemd service..."

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

  # Reload systemd and enable both n8n and nginx at boot.
  systemctl daemon-reload
  systemctl enable --now nginx
  systemctl enable --now n8n
}

# Verify external PostgreSQL connectivity through n8n's bundled pg library.
verify_pg_connection() {
  log "Verifying external PostgreSQL connectivity (${N8N_DB_HOST}:${N8N_DB_PORT})..."
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
        .then(() => console.log("PG connection OK"))
        .catch(e => { console.error("PG connection failed:", e.message); process.exit(1); })
        .finally(() => c.end());
    '
  )
}

# Wait until nginx proxies the n8n /healthz endpoint successfully.
wait_for_https() {
  log "Waiting for https://127.0.0.1:${N8N_HTTPS_PORT}/healthz via nginx to n8n:${N8N_PORT}..."
  # Try up to 90 times, about 180 seconds total.
  for _ in $(seq 1 90); do
    if curl -kfsS --max-time 2 "https://127.0.0.1:${N8N_HTTPS_PORT}/healthz" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  die "n8n/nginx did not respond over HTTPS in time"
}

# Production smoke test for systemd-managed n8n and nginx.
systemd_smoke_test() {
  [[ "$SKIP_SMOKE" == "0" ]] || return 0
  log "Running n8n smoke test under systemd..."
  wait_for_https
  systemctl is-active --quiet n8n
  systemctl is-active --quiet nginx
}

# Docker verification smoke test without systemd.
verify_no_systemd_smoke_test() {
  [[ "$SKIP_SMOKE" == "0" ]] || return 0
  log "Running n8n + nginx smoke test without systemd..."
  install -d -o n8n -g n8n -m 0750 /var/log/n8n
  install -d -o root -g root -m 0755 /var/log/nginx

  # Load the generated environment and run n8n in the background.
  set -a; source /etc/n8n/n8n.env; set +a
  su -s /bin/bash n8n -c '/usr/local/bin/n8n start' \
    >/var/log/n8n/n8n.log 2>/var/log/n8n/n8n.err &
  local n8n_pid=$!

  test_nginx_config
  # Start nginx.
  /usr/sbin/nginx

  # Cleanly stop both processes when the script exits.
  trap "kill ${n8n_pid} >/dev/null 2>&1 || true; /usr/sbin/nginx -s quit >/dev/null 2>&1 || true" EXIT

  wait_for_https

  # Stop background processes after a successful smoke test.
  /usr/sbin/nginx -s quit >/dev/null 2>&1 || true
  kill "${n8n_pid}" >/dev/null 2>&1 || true
  trap - EXIT
}

# Main installer entry point.
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

  log "Install complete. n8n is available at $(public_https_url) with a self-signed certificate."
}
main "$@"
