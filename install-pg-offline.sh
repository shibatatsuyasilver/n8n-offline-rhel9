#!/usr/bin/env bash
# PostgreSQL 18 offline installer for Red Hat 9.x.
# Installs PostgreSQL 18 from a local RPM repository, initializes the data
# directory, and starts the systemd service on an offline RHEL 9 host.
# When pgAdmin4 is enabled, it also configures Apache HTTPS and creates the
# requested PostgreSQL admin role. When N8N_HOST_IP is provided, production mode
# additionally makes the host "n8n-ready": it sets listen_addresses to
# localhost + the host IP (never '*'), adds a pg_hba rule allowing only that n8n
# host over scram-sha-256, creates the n8n role/database with pgvector and full
# privileges, opens the firewall for 5432 from that host, and restarts. With
# N8N_HOST_IP unset it leaves listen_addresses/pg_hba untouched and only prints
# the manual follow-up steps.
#
# --verify-no-systemd mode is for Docker end-to-end verification:
#   It configures listen_addresses='*' and pg_hba for remote scram-sha-256,
#   creates the n8n role/database when N8N_DB_PASSWORD is set, and finally
#   runs PostgreSQL in the foreground so the container stays alive.

# Enable strict Bash behavior so failures stop the installer immediately.
set -Eeuo pipefail

# Resolve the absolute directory that contains this installer.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$SCRIPT_DIR"
VERIFY_NO_SYSTEMD=0
# Verification mode can optionally bring pgAdmin4 up too (httpd without systemd).
VERIFY_PGADMIN=0
# Serve mode keeps PostgreSQL + pgAdmin4 running instead of exiting after the check.
SERVE=0

# pgAdmin4 production install defaults. Verification mode skips pgAdmin setup.
PGADMIN_ENABLE="${PGADMIN_ENABLE:-1}"
PGADMIN_ADMIN_EMAIL="${PGADMIN_ADMIN_EMAIL:-tonystark@local.com}"
PGADMIN_DB_ADMIN_USER="${PGADMIN_DB_ADMIN_USER:-tonystark}"
PGADMIN_LISTEN_ADDRESS="${PGADMIN_LISTEN_ADDRESS:-0.0.0.0}"
PGADMIN_HTTPS_PORT="${PGADMIN_HTTPS_PORT:-5050}"
PGADMIN_TLS_CERT_FILE="${PGADMIN_TLS_CERT_FILE:-}"
PGADMIN_TLS_KEY_FILE="${PGADMIN_TLS_KEY_FILE:-}"
PGADMIN_TLS_DAYS="${PGADMIN_TLS_DAYS:-3650}"
PGADMIN_ADMIN_PASSWORD="${PGADMIN_ADMIN_PASSWORD:-${PGADMIN_PASSWORD:-}}"
# Open the pgAdmin4 HTTPS port in firewalld so external browsers can reach it.
# Default: open to all sources; set PGADMIN_ALLOW_CIDR to restrict the source.
PGADMIN_AUTO_FIREWALL="${PGADMIN_AUTO_FIREWALL:-1}"
PGADMIN_ALLOW_CIDR="${PGADMIN_ALLOW_CIDR:-}"

# n8n-ready production auto-configuration. When N8N_HOST_IP is set, the production
# install also configures remote access for that host (listen_addresses + pg_hba),
# creates the n8n role/database, grants privileges, opens the firewall for 5432,
# and restarts PostgreSQL. When N8N_HOST_IP is empty the installer only prints the
# manual follow-up steps, preserving the previous behavior.
N8N_HOST_IP="${N8N_HOST_IP:-}"
POSTGRES_HOST_IP="${POSTGRES_HOST_IP:-}"
N8N_DB_NAME="${N8N_DB_NAME:-n8n}"
N8N_DB_USER="${N8N_DB_USER:-n8n}"
PG_PORT="${PG_PORT:-5432}"
PG_AUTO_FIREWALL="${PG_AUTO_FIREWALL:-1}"

# Verify-mode toggle: apply the secure n8n-access config instead of the permissive
# verify-only listen='*' config, so the production logic can be tested offline.
VERIFY_N8N_ACCESS=0

# Print command-line help.
usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --bundle-dir DIR        Use DIR as the offline bundle directory.
  --verify-no-systemd     Verification mode for Docker containers without systemd.
                          Requires N8N_DB_PASSWORD.
  --verify-pgadmin        With --verify-no-systemd, also install pgAdmin4, start
                          httpd in the background, and smoke-test HTTPS. Requires
                          PGADMIN_ADMIN_PASSWORD. The container exits 0 on success.
  --verify-n8n-access     With --verify-no-systemd, apply the secure n8n-access
                          config (listen on the host IP + /32 pg_hba) and serve in
                          the foreground, for offline testing of the production
                          n8n-ready logic. Requires N8N_HOST_IP + N8N_DB_PASSWORD.
  --serve                 With --verify-no-systemd --verify-pgadmin, keep
                          PostgreSQL and pgAdmin4 running in the foreground after
                          the smoke test (for a local demo) instead of exiting.
  --pgadmin-enable        Install and configure pgAdmin4 web mode. Default.
  --no-pgadmin            Install PostgreSQL only.
  --pgadmin-admin-email EMAIL
                          pgAdmin4 admin email. Default: tonystark@local.com.
  --pgadmin-db-admin-user USER
                          PostgreSQL admin role to create. Default: tonystark.
  --pgadmin-listen-address ADDR
                          Apache listen address for pgAdmin4. Default: 0.0.0.0.
  --pgadmin-https-port PORT
                          HTTPS port for pgAdmin4. Default: 5050.
  --pgadmin-tls-cert-file FILE
                          Existing TLS certificate for pgAdmin4 HTTPS.
  --pgadmin-tls-key-file FILE
                          Existing TLS private key for pgAdmin4 HTTPS.
  -h, --help              Show this help message.

Environment variables:
  PGADMIN_ENABLE          Set to 0 to skip pgAdmin4. Default: 1.
  PGADMIN_ADMIN_EMAIL     pgAdmin4 admin email. Default: tonystark@local.com.
  PGADMIN_ADMIN_PASSWORD  pgAdmin4 and PostgreSQL admin password. Prompted when unset.
  PGADMIN_DB_ADMIN_USER   PostgreSQL admin role. Default: tonystark.
  PGADMIN_LISTEN_ADDRESS  Apache listen address. Default: 0.0.0.0.
  PGADMIN_HTTPS_PORT      Apache HTTPS port. Default: 5050.
  PGADMIN_TLS_CERT_FILE   Optional existing TLS certificate path.
  PGADMIN_TLS_KEY_FILE    Optional existing TLS key path.
  PGADMIN_AUTO_FIREWALL   Set to 0 to skip opening the pgAdmin4 port. Default: 1.
  PGADMIN_ALLOW_CIDR      Restrict pgAdmin4 ${PGADMIN_HTTPS_PORT} to this source CIDR. Default: all.

  n8n-ready production auto-configuration (only when N8N_HOST_IP is set):
  N8N_HOST_IP             n8n host IP or CIDR allowed to connect (enables auto-config).
  N8N_DB_PASSWORD         Password for the n8n role. Required when N8N_HOST_IP is set.
  POSTGRES_HOST_IP        IP added to listen_addresses. Default: auto-detected.
  N8N_DB_NAME             n8n database name. Default: n8n.
  N8N_DB_USER             n8n role name. Default: n8n.
  PG_PORT                 PostgreSQL port for firewall/summary. Default: 5432.
  PG_AUTO_FIREWALL        Set to 0 to skip the firewalld change. Default: 1.
USAGE
}

# Print normal log messages.
log() { printf '[install-pg-offline] %s\n' "$*"; }
# Print an error and exit.
die() { printf '[install-pg-offline] ERROR: %s\n' "$*" >&2; exit 1; }
# Require root because the installer writes system paths and services.
need_root() { [[ "$(id -u)" == "0" ]] || die "Run this installer as root"; }
# Require a command to exist before using it.
need_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

sql_literal() {
  local escaped
  escaped="$(printf '%s' "$1" | sed "s/'/''/g")"
  printf "'%s'" "$escaped"
}

sql_identifier() {
  local escaped
  escaped="$(printf '%s' "$1" | sed 's/"/""/g')"
  printf '"%s"' "$escaped"
}

pgadmin_enabled() {
  if [[ "$VERIFY_NO_SYSTEMD" != "0" ]]; then
    # Verification mode only touches pgAdmin4 when explicitly asked to verify it.
    [[ "$VERIFY_PGADMIN" == "1" ]] && return 0 || return 1
  fi
  case "$PGADMIN_ENABLE" in
    0|false|FALSE|False|no|NO|No) return 1 ;;
    *) return 0 ;;
  esac
}

read_pgadmin_password() {
  pgadmin_enabled || return 0

  if [[ -z "$PGADMIN_ADMIN_PASSWORD" ]]; then
    if [[ -t 0 ]]; then
      printf '[install-pg-offline] Enter pgAdmin/PostgreSQL admin password for %s: ' "$PGADMIN_ADMIN_EMAIL" >&2
      IFS= read -r -s PGADMIN_ADMIN_PASSWORD
      printf '\n' >&2
    else
      die "PGADMIN_ADMIN_PASSWORD is required when pgAdmin4 is enabled and stdin is not interactive"
    fi
  fi

  [[ "${#PGADMIN_ADMIN_PASSWORD}" -ge 6 ]] || die "PGADMIN_ADMIN_PASSWORD must be at least 6 characters"
}

# Parse command-line arguments.
parse_args() {
  while (($#)); do
    case "$1" in
      --bundle-dir) shift; BUNDLE_DIR="$1" ;; # Set the bundle path.
      --verify-no-systemd) VERIFY_NO_SYSTEMD=1 ;; # Enable no-systemd verification mode.
      --verify-pgadmin) VERIFY_PGADMIN=1 ;; # Also verify pgAdmin4 in no-systemd mode.
      --verify-n8n-access) VERIFY_N8N_ACCESS=1 ;; # Test the secure n8n-access config offline.
      --serve) SERVE=1 ;; # Keep PG + pgAdmin4 running after the check (local demo).
      --pgadmin-enable) PGADMIN_ENABLE=1 ;;
      --no-pgadmin) PGADMIN_ENABLE=0 ;;
      --pgadmin-admin-email) shift; PGADMIN_ADMIN_EMAIL="$1" ;;
      --pgadmin-db-admin-user) shift; PGADMIN_DB_ADMIN_USER="$1" ;;
      --pgadmin-listen-address) shift; PGADMIN_LISTEN_ADDRESS="$1" ;;
      --pgadmin-https-port) shift; PGADMIN_HTTPS_PORT="$1" ;;
      --pgadmin-tls-cert-file) shift; PGADMIN_TLS_CERT_FILE="$1" ;;
      --pgadmin-tls-key-file) shift; PGADMIN_TLS_KEY_FILE="$1" ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
}

# Load bundle metadata created by prepare-pg-online.sh.
load_manifest() {
  BUNDLE_DIR="$(cd "$BUNDLE_DIR" && pwd)"
  local manifest="${BUNDLE_DIR}/manifest.env"
  [[ -f "$manifest" ]] || die "Bundle manifest not found: $manifest"
  # shellcheck disable=SC1090
  source "$manifest"
  # Derive the PostgreSQL data and binary directories from the manifest.
  PG_DATA="/var/lib/pgsql/${PG_MAJOR}/data"
  PG_BIN="/usr/pgsql-${PG_MAJOR}/bin"
}

# Reject bundles that contain RPMs known to drift away from the target RHEL version.
validate_rpm_manifest() {
  local rpm_manifest="${BUNDLE_DIR}/${RPM_PACKAGES_MANIFEST:-rpm-packages.tsv}"
  [[ -s "$rpm_manifest" ]] || die "RPM package manifest not found: $rpm_manifest"

  local target_minor="${TARGET_RHEL_MINOR:-9.2}"
  target_minor="${target_minor##*.}"
  if awk -v limit="$target_minor" -F'\t' '
    NR > 1 {
      str = $0;
      while (match(str, /el9_[0-9]+/)) {
        val = substr(str, RSTART + 4, RLENGTH - 4);
        if (val + 0 > limit) { found = 1; print $0; }
        str = substr(str, RSTART + RLENGTH);
      }
      str = $0;
      while (match(str, /rhel9[._][0-9]+/)) {
        val = substr(str, RSTART + 6, RLENGTH - 6);
        if (val + 0 > limit) { found = 1; print $0; }
        str = substr(str, RSTART + RLENGTH);
      }
    }
    END { exit found ? 0 : 1 }
  ' "$rpm_manifest" >&2; then
    die "Bundle contains RHEL/Rocky packages newer than 9.${target_minor}; rebuild it for RHEL ${TARGET_RHEL_MINOR:-9.2}"
  fi

  if awk -F'\t' 'NR > 1 && $1 ~ /^(rocky-release|rocky-repos|rocky-gpg-keys|rocky-logos.*)$/ { print; found=1 } END { exit found ? 0 : 1 }' "$rpm_manifest" >&2; then
    die "Bundle contains Rocky release identity packages; refusing to alter this host release identity"
  fi
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

  if [[ -n "${TARGET_RHEL_MINOR:-}" ]]; then
    [[ "${VERSION_ID:-}" == "$TARGET_RHEL_MINOR"* ]] || die "Expected RHEL minor version ${TARGET_RHEL_MINOR}, got ${VERSION_ID:-unknown}"
  fi

  # Verify CPU architecture.
  [[ "$(uname -m)" == "$TARGET_ARCH" ]] || die "Expected architecture ${TARGET_ARCH}, got $(uname -m)"

  # Production mode requires a running systemd instance.
  if [[ "$VERIFY_NO_SYSTEMD" == "0" ]]; then
    need_command systemctl
    [[ -d /run/systemd/system ]] || die "systemd is not running"
  fi

  # Verify the local RPM repository and all bundle checksums.
  [[ -d "${BUNDLE_DIR}/${RPM_REPO_DIR}" ]] || die "RPM repository directory not found"
  validate_rpm_manifest
  log "Verifying bundle checksums..."
  ( cd "$BUNDLE_DIR"; sha256sum -c SHA256SUMS )
}

# Configure a local yum repository and install PostgreSQL packages from it.
install_rpm_packages() {
  log "Installing PostgreSQL ${PG_MAJOR} from the local offline repository..."
  local packages=(
    "postgresql${PG_MAJOR}-server"
    "postgresql${PG_MAJOR}-contrib"
    "postgresql${PG_MAJOR}"
    "pgvector_${PG_MAJOR}"
  )

  if pgadmin_enabled; then
    log "pgAdmin4 web mode is enabled; Apache/httpd and TLS support will also be installed"
    packages+=("pgadmin4-web" "mod_ssl")
  fi

  cat > /etc/yum.repos.d/postgres-offline.repo <<REPO
[postgres-offline]
name=PostgreSQL ${PG_MAJOR} Offline Packages
baseurl=file://${BUNDLE_DIR}/${RPM_REPO_DIR}
enabled=1
gpgcheck=0
REPO

  # Disable every other repository so the install remains offline. Avoid
  # --allowerasing so dependency conflicts cannot remove host SSH packages.
  dnf --disablerepo='*' --enablerepo='postgres-offline' install -y \
    --setopt=install_weak_deps=False \
    --setopt=allow_vendor_change=False \
    "${packages[@]}"
}

# Initialize the PostgreSQL data directory only.
initdb_only() {
  # Never reinitialize an existing cluster: PG_VERSION (and base/) mark an already
  # initialized data directory, so we preserve any prior PostgreSQL data and skip
  # initdb. This makes re-running the installer safe on a host that already has a
  # PostgreSQL ${PG_MAJOR} cluster with real data.
  if [[ -f "${PG_DATA}/PG_VERSION" || -d "${PG_DATA}/base" ]]; then
    log "Existing PostgreSQL data directory detected at ${PG_DATA}; preserving it and skipping initdb"
    return 0
  fi

  # If the directory exists and is not empty but is not a valid cluster, refuse to
  # initialize it rather than risk clobbering unrelated contents.
  if [[ -d "$PG_DATA" && -n "$(ls -A "$PG_DATA" 2>/dev/null)" ]]; then
    die "Data directory ${PG_DATA} is non-empty but is not an initialized PostgreSQL cluster; refusing to initdb to avoid data loss. Inspect it manually."
  fi

  log "Initializing data directory: ${PG_DATA}"

  # Without systemd, call initdb directly. Otherwise use the packaged setup script.
  if [[ "$VERIFY_NO_SYSTEMD" == "1" ]]; then
    # postgresql-N-setup reads PGDATA through systemctl, so it fails without systemd.
    install -d -o postgres -g postgres -m 0700 "$(dirname "$PG_DATA")"
    su - postgres -c "${PG_BIN}/initdb -D ${PG_DATA} --auth-local=peer --auth-host=scram-sha-256 --encoding=UTF8"
  else
    "${PG_BIN}/postgresql-${PG_MAJOR}-setup" initdb
  fi
}

# Wait until PostgreSQL accepts connections via the local socket.
wait_pg_ready() {
  for _ in $(seq 1 30); do
    if su - postgres -c "${PG_BIN}/pg_isready -q"; then
      log "PostgreSQL is ready"
      return 0
    fi
    sleep 1
  done
  return 1
}

# Enable and start the PostgreSQL systemd service.
start_pg_systemd() {
  systemctl enable --now "postgresql-${PG_MAJOR}"
  if wait_pg_ready; then
    return 0
  fi
  systemctl status "postgresql-${PG_MAJOR}" --no-pager || true
  die "PostgreSQL was not ready within 30 seconds"
}

create_pgadmin_db_admin_role() {
  pgadmin_enabled || return 0

  local role_ident role_lit pw_lit role_exists
  role_ident="$(sql_identifier "$PGADMIN_DB_ADMIN_USER")"
  role_lit="$(sql_literal "$PGADMIN_DB_ADMIN_USER")"
  pw_lit="$(sql_literal "$PGADMIN_ADMIN_PASSWORD")"

  log "Creating/updating PostgreSQL admin role ${PGADMIN_DB_ADMIN_USER}..."
  role_exists="$(su - postgres -c "${PG_BIN}/psql -tA" <<SQL
SELECT 1 FROM pg_roles WHERE rolname=${role_lit};
SQL
)"

  if [[ "$role_exists" == "1" ]]; then
    su - postgres -c "${PG_BIN}/psql -v ON_ERROR_STOP=1" <<SQL
ALTER ROLE ${role_ident} WITH LOGIN SUPERUSER CREATEDB CREATEROLE REPLICATION BYPASSRLS PASSWORD ${pw_lit};
SQL
  else
    su - postgres -c "${PG_BIN}/psql -v ON_ERROR_STOP=1" <<SQL
CREATE ROLE ${role_ident} WITH LOGIN SUPERUSER CREATEDB CREATEROLE REPLICATION BYPASSRLS PASSWORD ${pw_lit};
SQL
  fi
}

prepare_pgadmin_tls() {
  pgadmin_enabled || return 0

  if [[ -n "$PGADMIN_TLS_CERT_FILE" || -n "$PGADMIN_TLS_KEY_FILE" ]]; then
    [[ -n "$PGADMIN_TLS_CERT_FILE" && -n "$PGADMIN_TLS_KEY_FILE" ]] || die "Provide both PGADMIN_TLS_CERT_FILE and PGADMIN_TLS_KEY_FILE"
    [[ -r "$PGADMIN_TLS_CERT_FILE" ]] || die "Cannot read PGADMIN_TLS_CERT_FILE: $PGADMIN_TLS_CERT_FILE"
    [[ -r "$PGADMIN_TLS_KEY_FILE" ]] || die "Cannot read PGADMIN_TLS_KEY_FILE: $PGADMIN_TLS_KEY_FILE"
    return 0
  fi

  local tls_dir cn primary_ip openssl_conf
  tls_dir="/etc/pgadmin/tls"
  PGADMIN_TLS_CERT_FILE="${tls_dir}/server.crt"
  PGADMIN_TLS_KEY_FILE="${tls_dir}/server.key"

  if [[ -s "$PGADMIN_TLS_CERT_FILE" && -s "$PGADMIN_TLS_KEY_FILE" ]]; then
    log "Reusing existing pgAdmin4 TLS certificate at ${PGADMIN_TLS_CERT_FILE}"
    return 0
  fi

  need_command openssl
  log "Generating self-signed pgAdmin4 TLS certificate..."
  install -d -m 0700 "$tls_dir"
  cn="$(hostname -f 2>/dev/null || hostname || printf 'localhost')"
  primary_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  openssl_conf="$(mktemp)"
  cat > "$openssl_conf" <<CONF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = ${cn}

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${cn}
DNS.2 = localhost
IP.1 = 127.0.0.1
CONF
  if [[ -n "$primary_ip" ]]; then
    printf 'IP.2 = %s\n' "$primary_ip" >> "$openssl_conf"
  fi

  openssl req -x509 -nodes -newkey rsa:2048 \
    -days "$PGADMIN_TLS_DAYS" \
    -keyout "$PGADMIN_TLS_KEY_FILE" \
    -out "$PGADMIN_TLS_CERT_FILE" \
    -config "$openssl_conf" >/dev/null 2>&1
  rm -f "$openssl_conf"
  chmod 0600 "$PGADMIN_TLS_KEY_FILE"
  chmod 0644 "$PGADMIN_TLS_CERT_FILE"
}

disable_apache_conf() {
  local conf="$1"
  local disabled="${conf}.postgres-offline-disabled"
  if [[ -f "$conf" && ! -f "$disabled" ]]; then
    mv "$conf" "$disabled"
  fi
}

disable_default_httpd_listen() {
  local httpd_conf="/etc/httpd/conf/httpd.conf"
  [[ -f "$httpd_conf" ]] || return 0
  if grep -Eq '^[[:space:]]*Listen[[:space:]]+([^[:space:]]+:)?80([[:space:]]|$)' "$httpd_conf"; then
    cp -n "$httpd_conf" "${httpd_conf}.postgres-offline.bak"
    sed -i -E \
      's/^([[:space:]]*)Listen[[:space:]]+([^[:space:]]+:)?80([[:space:]]*)$/# Listen 80 disabled by install-pg-offline for pgAdmin4 HTTPS on 5050/' \
      "$httpd_conf"
  fi
}

write_pgadmin_apache_config() {
  pgadmin_enabled || return 0

  log "Writing Apache pgAdmin4 HTTPS configuration..."
  disable_apache_conf /etc/httpd/conf.d/pgadmin4.conf
  disable_apache_conf /etc/httpd/conf.d/ssl.conf
  disable_default_httpd_listen

  cat > /etc/httpd/conf.d/pgadmin4-offline-ssl.conf <<CONF
Listen ${PGADMIN_LISTEN_ADDRESS}:${PGADMIN_HTTPS_PORT} https

<VirtualHost ${PGADMIN_LISTEN_ADDRESS}:${PGADMIN_HTTPS_PORT}>
    ServerName $(hostname -f 2>/dev/null || hostname || printf 'localhost')

    SSLEngine on
    SSLCertificateFile ${PGADMIN_TLS_CERT_FILE}
    SSLCertificateKeyFile ${PGADMIN_TLS_KEY_FILE}
    SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1

    WSGIDaemonProcess pgadmin processes=1 threads=25 python-home=/usr/pgadmin4/venv
    WSGIScriptAlias /pgadmin4 /usr/pgadmin4/web/pgAdmin4.wsgi

    <Directory /usr/pgadmin4/web>
        WSGIProcessGroup pgadmin
        WSGIApplicationGroup %{GLOBAL}
        Require all granted
    </Directory>

    ErrorLog /var/log/httpd/pgadmin4_error.log
    CustomLog /var/log/httpd/pgadmin4_access.log combined
</VirtualHost>
CONF
}

configure_pgadmin_selinux() {
  pgadmin_enabled || return 0

  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
    log "Configuring SELinux for pgAdmin4/httpd..."
    setsebool -P httpd_tmp_exec 1 >/dev/null || true
    setsebool -P httpd_can_network_connect 1 >/dev/null || true
    setsebool -P httpd_can_network_connect_db 1 >/dev/null || true
    semanage fcontext -a -t httpd_var_lib_t '/var/lib/pgadmin(/.*)?' >/dev/null 2>&1 || true
    restorecon -R /var/lib/pgadmin >/dev/null 2>&1 || true
    semanage fcontext -a -t httpd_log_t '/var/log/pgadmin(/.*)?' >/dev/null 2>&1 || true
    restorecon -R /var/log/pgadmin >/dev/null 2>&1 || true
    semanage port -a -t http_port_t -p tcp "$PGADMIN_HTTPS_PORT" >/dev/null 2>&1 || \
      semanage port -m -t http_port_t -p tcp "$PGADMIN_HTTPS_PORT" >/dev/null 2>&1 || true
  fi
}

configure_pgadmin_web() {
  pgadmin_enabled || return 0

  log "Configuring pgAdmin4 web mode..."
  install -d -m 0750 -o apache -g apache /var/lib/pgadmin /var/log/pgadmin
  # pgAdmin server-mode setup-db runs a migration that prompts for the initial
  # admin email/password via input(); supply them through the environment so the
  # migration stays non-interactive (otherwise it raises EOFError on closed stdin).
  # In server mode this also creates the initial administrator account from the
  # PGADMIN_SETUP_* values, so no separate add-user/update-user call is needed
  # (the standalone user CLI is broken in pgAdmin 9.x). To change the password
  # later, use the pgAdmin web UI.
  PGADMIN_SETUP_EMAIL="$PGADMIN_ADMIN_EMAIL" \
  PGADMIN_SETUP_PASSWORD="$PGADMIN_ADMIN_PASSWORD" \
    /usr/pgadmin4/venv/bin/python3 /usr/pgadmin4/web/setup.py setup-db

  chown -R apache:apache /var/lib/pgadmin /var/log/pgadmin
  prepare_pgadmin_tls
  write_pgadmin_apache_config
  configure_pgadmin_selinux
  httpd -t
  start_httpd
}

# Start Apache/httpd. Production uses systemd; no-systemd verification starts it
# directly so the bundle can be exercised inside a container.
start_httpd() {
  if [[ "$VERIFY_NO_SYSTEMD" == "1" ]]; then
    log "Starting httpd in the background (no systemd)..."
    httpd -k start
  else
    systemctl enable --now httpd
  fi
}

# Confirm pgAdmin4 actually serves over HTTPS. Used by --verify-pgadmin.
smoke_test_pgadmin() {
  need_command curl
  local url="https://127.0.0.1:${PGADMIN_HTTPS_PORT}/pgadmin4/"
  log "Smoke-testing pgAdmin4 at ${url}..."
  for _ in $(seq 1 30); do
    if curl -k -fsS -o /dev/null "$url"; then
      log "pgAdmin4 responded successfully"
      return 0
    fi
    sleep 1
  done
  tail -n 50 /var/log/httpd/pgadmin4_error.log 2>/dev/null >&2 || true
  die "pgAdmin4 did not respond on ${url}"
}

# Configure remote access for verification mode.
configure_for_remote() {
  log "Configuring listen_addresses and pg_hba for remote access in verify mode..."
  # Allow PostgreSQL to listen on every interface inside the isolated test network.
  if ! grep -q "^listen_addresses" "${PG_DATA}/postgresql.conf"; then
    echo "listen_addresses = '*'" >> "${PG_DATA}/postgresql.conf"
  else
    sed -i "s/^listen_addresses.*/listen_addresses = '*'/" "${PG_DATA}/postgresql.conf"
  fi

  # Allow password authentication from the isolated test network.
  if ! grep -qE '^host\s+all\s+all\s+0\.0\.0\.0/0' "${PG_DATA}/pg_hba.conf"; then
    cat >> "${PG_DATA}/pg_hba.conf" <<HBA
host  all  all  0.0.0.0/0  scram-sha-256
host  all  all  ::/0       scram-sha-256
HBA
  fi
  chown postgres:postgres "${PG_DATA}/postgresql.conf" "${PG_DATA}/pg_hba.conf"
}

# Start PostgreSQL in the background with pg_ctl when systemd is unavailable.
start_pg_no_systemd_bg() {
  log "Starting PostgreSQL in the background with pg_ctl..."
  install -d -o postgres -g postgres -m 0700 "${PG_DATA}/log"
  su - postgres -c "${PG_BIN}/pg_ctl -D ${PG_DATA} -l ${PG_DATA}/log/startup.log start"

  # Wait up to 30 seconds for PostgreSQL to accept connections.
  for _ in $(seq 1 30); do
    if su - postgres -c "${PG_BIN}/pg_isready -q"; then
      log "PostgreSQL is ready"
      return 0
    fi
    sleep 1
  done
  die "PostgreSQL was not ready within 30 seconds"
}

# Create or update the n8n role and database (idempotent).
bootstrap_n8n_db() {
  : "${N8N_DB_PASSWORD:?N8N_DB_PASSWORD is required to create the ${N8N_DB_USER} role}"
  local role_ident role_lit db_ident db_lit pw_lit role_exists db_exists
  role_ident="$(sql_identifier "$N8N_DB_USER")"
  role_lit="$(sql_literal "$N8N_DB_USER")"
  db_ident="$(sql_identifier "$N8N_DB_NAME")"
  db_lit="$(sql_literal "$N8N_DB_NAME")"
  pw_lit="$(sql_literal "$N8N_DB_PASSWORD")"

  log "Creating/updating ${N8N_DB_USER} role and ${N8N_DB_NAME} database (idempotent)..."
  role_exists="$(su - postgres -c "${PG_BIN}/psql -tA" <<SQL
SELECT 1 FROM pg_roles WHERE rolname=${role_lit};
SQL
)"
  if [[ "$role_exists" == "1" ]]; then
    su - postgres -c "${PG_BIN}/psql -v ON_ERROR_STOP=1" <<SQL
ALTER ROLE ${role_ident} WITH LOGIN PASSWORD ${pw_lit};
SQL
  else
    su - postgres -c "${PG_BIN}/psql -v ON_ERROR_STOP=1" <<SQL
CREATE ROLE ${role_ident} LOGIN PASSWORD ${pw_lit};
SQL
  fi

  # Create the database (owned by the n8n role) when missing.
  db_exists="$(su - postgres -c "${PG_BIN}/psql -tA" <<SQL
SELECT 1 FROM pg_database WHERE datname=${db_lit};
SQL
)"
  if [[ "$db_exists" != "1" ]]; then
    su - postgres -c "${PG_BIN}/psql -v ON_ERROR_STOP=1" <<SQL
CREATE DATABASE ${db_ident} OWNER ${role_ident};
SQL
  fi
}

# Enable the pgvector extension in the n8n database.
enable_pgvector_in_n8n_db() {
  log "Enabling pgvector in the ${N8N_DB_NAME} database (idempotent)..."
  su - postgres -c "${PG_BIN}/psql -v ON_ERROR_STOP=1 -d ${N8N_DB_NAME} -c 'CREATE EXTENSION IF NOT EXISTS vector;'"
}

# Resolve the n8n host into a CIDR for pg_hba/firewall (bare IP -> /32).
n8n_host_cidr() {
  case "$N8N_HOST_IP" in
    */*) printf '%s' "$N8N_HOST_IP" ;;
    *)   printf '%s/32' "$N8N_HOST_IP" ;;
  esac
}

# Determine the host IP to add to listen_addresses (auto-detect when unset).
resolve_postgres_host_ip() {
  if [[ -z "$POSTGRES_HOST_IP" ]]; then
    POSTGRES_HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  [[ -n "$POSTGRES_HOST_IP" ]] || die "Could not determine POSTGRES_HOST_IP; set it explicitly"
}

# Production secure remote access: listen on localhost + the host IP only (never
# '*'), and allow just the n8n host to reach the n8n database over scram-sha-256.
configure_for_n8n_access() {
  resolve_postgres_host_ip
  local cidr hba_rule
  cidr="$(n8n_host_cidr)"

  log "Configuring listen_addresses (localhost,${POSTGRES_HOST_IP}) and pg_hba for ${cidr}..."
  if ! grep -q "^listen_addresses" "${PG_DATA}/postgresql.conf"; then
    echo "listen_addresses = 'localhost,${POSTGRES_HOST_IP}'" >> "${PG_DATA}/postgresql.conf"
  else
    sed -i "s/^listen_addresses.*/listen_addresses = 'localhost,${POSTGRES_HOST_IP}'/" "${PG_DATA}/postgresql.conf"
  fi

  hba_rule="host  ${N8N_DB_NAME}  ${N8N_DB_USER}  ${cidr}  scram-sha-256"
  if ! grep -qF "$hba_rule" "${PG_DATA}/pg_hba.conf"; then
    printf '%s\n' "$hba_rule" >> "${PG_DATA}/pg_hba.conf"
  fi
  chown postgres:postgres "${PG_DATA}/postgresql.conf" "${PG_DATA}/pg_hba.conf"
}

# Give the n8n role ownership and full privileges on its database and public
# schema, including default privileges for future objects (idempotent).
grant_n8n_privileges() {
  local role_ident db_ident
  role_ident="$(sql_identifier "$N8N_DB_USER")"
  db_ident="$(sql_identifier "$N8N_DB_NAME")"

  log "Granting ${N8N_DB_USER} full privileges on ${N8N_DB_NAME}..."
  su - postgres -c "${PG_BIN}/psql -v ON_ERROR_STOP=1" <<SQL
ALTER DATABASE ${db_ident} OWNER TO ${role_ident};
GRANT ALL PRIVILEGES ON DATABASE ${db_ident} TO ${role_ident};
SQL

  su - postgres -c "${PG_BIN}/psql -v ON_ERROR_STOP=1 -d ${N8N_DB_NAME}" <<SQL
GRANT USAGE, CREATE ON SCHEMA public TO ${role_ident};
ALTER SCHEMA public OWNER TO ${role_ident};
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${role_ident};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${role_ident};
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${role_ident};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO ${role_ident};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO ${role_ident};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON FUNCTIONS TO ${role_ident};
SQL
}

# Open the firewall so only the n8n host can reach PostgreSQL on PG_PORT.
open_firewall_for_n8n() {
  case "$PG_AUTO_FIREWALL" in
    0|false|FALSE|False|no|NO|No) log "PG_AUTO_FIREWALL disabled; leaving the firewall unchanged"; return 0 ;;
  esac
  if ! command -v firewall-cmd >/dev/null 2>&1 || ! firewall-cmd --state >/dev/null 2>&1; then
    log "firewalld is not active; skipping firewall change (open ${PG_PORT}/tcp for $(n8n_host_cidr) manually if needed)"
    return 0
  fi
  local cidr; cidr="$(n8n_host_cidr)"
  log "Opening ${PG_PORT}/tcp to ${cidr} via firewalld..."
  firewall-cmd --permanent \
    --add-rich-rule="rule family=\"ipv4\" source address=\"${cidr}\" port port=\"${PG_PORT}\" protocol=\"tcp\" accept" >/dev/null || true
  firewall-cmd --reload >/dev/null || true
}

# Open the firewall so external browsers can reach pgAdmin4 on its HTTPS port.
open_firewall_for_pgadmin() {
  pgadmin_enabled || return 0
  case "$PGADMIN_AUTO_FIREWALL" in
    0|false|FALSE|False|no|NO|No) log "PGADMIN_AUTO_FIREWALL disabled; leaving the firewall unchanged"; return 0 ;;
  esac
  if ! command -v firewall-cmd >/dev/null 2>&1 || ! firewall-cmd --state >/dev/null 2>&1; then
    log "firewalld is not active; skipping firewall change (open ${PGADMIN_HTTPS_PORT}/tcp manually if needed)"
    return 0
  fi
  if [[ -n "$PGADMIN_ALLOW_CIDR" ]]; then
    log "Opening pgAdmin4 ${PGADMIN_HTTPS_PORT}/tcp to ${PGADMIN_ALLOW_CIDR} via firewalld..."
    firewall-cmd --permanent \
      --add-rich-rule="rule family=\"ipv4\" source address=\"${PGADMIN_ALLOW_CIDR}\" port port=\"${PGADMIN_HTTPS_PORT}\" protocol=\"tcp\" accept" >/dev/null || true
  else
    log "Opening pgAdmin4 ${PGADMIN_HTTPS_PORT}/tcp to all sources via firewalld..."
    firewall-cmd --permanent --add-port="${PGADMIN_HTTPS_PORT}/tcp" >/dev/null || true
  fi
  firewall-cmd --reload >/dev/null || true
}

# Print a summary of the n8n-ready configuration that was applied.
print_n8n_ready_summary() {
  cat <<MSG

[install-pg-offline] PostgreSQL ${PG_MAJOR} is n8n-ready.
  listen_addresses : localhost,${POSTGRES_HOST_IP}   (config dir: ${PG_DATA}/)
  pg_hba rule      : host ${N8N_DB_NAME} ${N8N_DB_USER} $(n8n_host_cidr) scram-sha-256
  database / role  : ${N8N_DB_NAME} owned by ${N8N_DB_USER}; pgvector enabled; full privileges granted
  firewall         : ${PG_PORT}/tcp allowed from $(n8n_host_cidr) (only when firewalld is active)

On the n8n host (${N8N_HOST_IP}) run install-offline.sh with:
  N8N_DB_HOST=${POSTGRES_HOST_IP}
  N8N_DB_PORT=${PG_PORT}
  N8N_DB_NAME=${N8N_DB_NAME}
  N8N_DB_USER=${N8N_DB_USER}
  N8N_DB_PASSWORD=<the password you set for the ${N8N_DB_USER} role>
MSG
}

# Stop the background server before switching to foreground mode.
stop_pg_no_systemd() {
  log "Stopping background PostgreSQL before switching to foreground mode..."
  su - postgres -c "${PG_BIN}/pg_ctl -D ${PG_DATA} stop -m fast" || true
}

# Run PostgreSQL in the foreground so the Docker container stays alive.
exec_pg_foreground() {
  log "Running PostgreSQL in the foreground as postgres..."
  exec su - postgres -c "${PG_BIN}/postgres -D ${PG_DATA}"
}

# Print production follow-up steps for manual remote access setup.
print_post_install_hint() {
  cat <<MSG

[install-pg-offline] PostgreSQL ${PG_MAJOR} is running on 5432 and listens on localhost by default.
                     Config directory: ${PG_DATA}/

Complete these manual steps before the n8n host can connect:

  1. Edit ${PG_DATA}/postgresql.conf and change listen_addresses so it listens
     only on localhost and the internal host interface. Avoid '*'.

       listen_addresses = 'localhost,<host_b_internal_ip>'

  2. Edit ${PG_DATA}/pg_hba.conf and allow only the n8n host:

       host  n8n  n8n  <n8n_host_ip>/32  scram-sha-256

  3. Restart PostgreSQL:

       sudo systemctl restart postgresql-${PG_MAJOR}

  4. Create the n8n role. Use \\password interactively so the password does not
     enter shell history:

       sudo -u postgres ${PG_BIN}/psql -c "CREATE ROLE n8n LOGIN;"
       sudo -u postgres ${PG_BIN}/psql -c "\\password n8n"

  5. Create the n8n database:

       sudo -u postgres ${PG_BIN}/createdb --owner=n8n n8n

  6. Enable pgvector in the n8n database:

       sudo -u postgres ${PG_BIN}/psql -d n8n -c 'CREATE EXTENSION IF NOT EXISTS vector;'

  7. Verify the listen scope:

       ss -ltn | grep 5432
       sudo -u postgres ${PG_BIN}/psql -c "SHOW listen_addresses;"

  8. Provide these values when running install-offline.sh on the n8n host:

       N8N_DB_HOST=<this_host_ip>
       N8N_DB_PASSWORD=<password_from_step_4>
MSG

  if pgadmin_enabled; then
    cat <<MSG

pgAdmin4 web mode is also configured:

  URL:
       https://<this_host_ip>:${PGADMIN_HTTPS_PORT}/pgadmin4

  Login:
       Email: ${PGADMIN_ADMIN_EMAIL}
       PostgreSQL admin role: ${PGADMIN_DB_ADMIN_USER}

  TLS:
       Certificate: ${PGADMIN_TLS_CERT_FILE}
       Key:         ${PGADMIN_TLS_KEY_FILE}
       Browsers will warn because the generated certificate is self-signed.

  Firewall: TCP ${PGADMIN_HTTPS_PORT} is opened automatically when firewalld is active
            (PGADMIN_AUTO_FIREWALL=1; default all sources, set PGADMIN_ALLOW_CIDR to
            restrict, or PGADMIN_AUTO_FIREWALL=0 to skip).

  Verify:

       ss -ltn | grep ':${PGADMIN_HTTPS_PORT}'
       curl -k https://127.0.0.1:${PGADMIN_HTTPS_PORT}/pgadmin4/
MSG
  fi
}

# Main installer entry point.
main() {
  parse_args "$@"
  need_root
  need_command sha256sum

  load_manifest
  preflight
  read_pgadmin_password
  install_rpm_packages
  initdb_only

  # In production mode, start the systemd service and configure pgAdmin4.
  if [[ "$VERIFY_NO_SYSTEMD" == "0" ]]; then
    start_pg_systemd
    create_pgadmin_db_admin_role
    configure_pgadmin_web
    open_firewall_for_pgadmin

    if [[ -n "$N8N_HOST_IP" ]]; then
      # n8n-ready: configure remote access for the n8n host, provision the role/
      # database with privileges, open the firewall, and restart to apply config.
      : "${N8N_DB_PASSWORD:?N8N_HOST_IP is set; N8N_DB_PASSWORD is required to provision the ${N8N_DB_USER} role}"
      configure_for_n8n_access
      bootstrap_n8n_db
      enable_pgvector_in_n8n_db
      grant_n8n_privileges
      log "Restarting postgresql-${PG_MAJOR} to apply listen_addresses/pg_hba..."
      systemctl restart "postgresql-${PG_MAJOR}"
      wait_pg_ready || die "PostgreSQL was not ready after restart"
      open_firewall_for_n8n
      print_n8n_ready_summary
    else
      print_post_install_hint
    fi
  else
    # Docker verification mode configures remote access, bootstraps n8n, and
    # then keeps PostgreSQL in the foreground. --verify-n8n-access uses the secure
    # production config (specific host IP + /32 pg_hba) instead of the permissive
    # verify-only listen='*' config, so the production logic can be tested offline.
    if [[ "$VERIFY_N8N_ACCESS" == "1" ]]; then
      configure_for_n8n_access
    else
      configure_for_remote
    fi
    start_pg_no_systemd_bg
    bootstrap_n8n_db
    enable_pgvector_in_n8n_db

    if [[ "$VERIFY_N8N_ACCESS" == "1" ]]; then
      grant_n8n_privileges
      # Re-run PG in the foreground so it serves with the configured
      # listen_addresses/pg_hba and the container stays alive for assertions.
      stop_pg_no_systemd
      log "n8n-access verify mode: serving with listen=localhost,${POSTGRES_HOST_IP} and pg_hba for $(n8n_host_cidr)"
      exec_pg_foreground
    fi

    # Optionally exercise the full pgAdmin4 offline install: create the admin
    # role, configure Apache, start httpd, and confirm HTTPS serves. Then exit
    # 0 instead of holding PostgreSQL in the foreground, so the one-shot
    # verification container terminates cleanly.
    if [[ "$VERIFY_PGADMIN" == "1" ]]; then
      create_pgadmin_db_admin_role
      configure_pgadmin_web
      smoke_test_pgadmin
      log "pgAdmin4 offline verification passed (PostgreSQL ${PG_MAJOR} + pgvector + pgAdmin4)"
      # Stop the backgrounded postmaster before deciding how to finish so we never
      # start a second one on the same data directory.
      stop_pg_no_systemd
      if [[ "$SERVE" == "1" ]]; then
        log "Serve mode: keeping PostgreSQL and pgAdmin4 (httpd) running; open https://<host>:${PGADMIN_HTTPS_PORT}/pgadmin4"
        exec_pg_foreground   # Re-runs PG in the foreground; httpd already serves pgAdmin4 in the background.
      fi
      exit 0
    fi

    stop_pg_no_systemd
    exec_pg_foreground   # Does not return.
  fi
}
main "$@"
