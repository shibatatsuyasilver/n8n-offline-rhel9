#!/usr/bin/env bash
# PostgreSQL 18 offline installer for Red Hat 9.x.
# Installs PostgreSQL 18 from a local RPM repository, initializes the data
# directory, and starts the systemd service on an offline RHEL 9 host.
# Production mode does not create the n8n role/database automatically and does
# not change listen_addresses or pg_hba.conf. Follow the final instructions.
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

# Print command-line help.
usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --bundle-dir DIR        Use DIR as the offline bundle directory.
  --verify-no-systemd     Verification mode for Docker containers without systemd.
                          Requires N8N_DB_PASSWORD.
  -h, --help              Show this help message.
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

# Parse command-line arguments.
parse_args() {
  while (($#)); do
    case "$1" in
      --bundle-dir) shift; BUNDLE_DIR="$1" ;; # Set the bundle path.
      --verify-no-systemd) VERIFY_NO_SYSTEMD=1 ;; # Enable no-systemd verification mode.
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

# Configure a local yum repository and install PostgreSQL packages from it.
install_rpm_packages() {
  log "Installing PostgreSQL ${PG_MAJOR} from the local offline repository..."
  cat > /etc/yum.repos.d/postgres-offline.repo <<REPO
[postgres-offline]
name=PostgreSQL ${PG_MAJOR} Offline Packages
baseurl=file://${BUNDLE_DIR}/${RPM_REPO_DIR}
enabled=1
gpgcheck=0
REPO

  # Disable every other repository so the install remains offline.
  dnf --disablerepo='*' --enablerepo='postgres-offline' install -y --allowerasing \
    "postgresql${PG_MAJOR}-server" \
    "postgresql${PG_MAJOR}-contrib" \
    "postgresql${PG_MAJOR}" \
    "pgvector_${PG_MAJOR}"
}

# Initialize the PostgreSQL data directory only.
initdb_only() {
  # If base exists, the data directory was already initialized.
  if [[ -d "${PG_DATA}/base" ]]; then
    log "Data directory already exists, skipping initdb"
    return 0
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

# Enable and start the PostgreSQL systemd service.
start_pg_systemd() {
  systemctl enable --now "postgresql-${PG_MAJOR}"
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

# Create or update the n8n role and database.
bootstrap_n8n_db() {
  : "${N8N_DB_PASSWORD:?N8N_DB_PASSWORD is required in --verify-no-systemd mode}"
  local pw_escaped pw
  # Escape single quotes for PostgreSQL string literals.
  pw_escaped="$(printf '%s' "$N8N_DB_PASSWORD" | sed "s/'/''/g")"
  pw="'${pw_escaped}'"

  log "Creating/updating n8n role and database (idempotent)..."
  # Create or update the n8n role.
  if su - postgres -c "${PG_BIN}/psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='n8n'\"" | grep -q 1; then
    su - postgres -c "${PG_BIN}/psql -v ON_ERROR_STOP=1 -c \"ALTER ROLE n8n WITH LOGIN PASSWORD ${pw};\""
  else
    su - postgres -c "${PG_BIN}/psql -v ON_ERROR_STOP=1 -c \"CREATE ROLE n8n LOGIN PASSWORD ${pw};\""
  fi

  # Create the n8n database when missing.
  if ! su - postgres -c "${PG_BIN}/psql -tAc \"SELECT 1 FROM pg_database WHERE datname='n8n'\"" | grep -q 1; then
    su - postgres -c "${PG_BIN}/createdb --owner=n8n n8n"
  fi
}

# Enable the pgvector extension in the n8n database.
enable_pgvector_in_n8n_db() {
  log "Enabling pgvector in the n8n database (idempotent)..."
  su - postgres -c "${PG_BIN}/psql -v ON_ERROR_STOP=1 -d n8n -c 'CREATE EXTENSION IF NOT EXISTS vector;'"
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
}

# Main installer entry point.
main() {
  parse_args "$@"
  need_root
  need_command sha256sum

  load_manifest
  preflight
  install_rpm_packages
  initdb_only

  # In production mode, start the systemd service and print manual next steps.
  if [[ "$VERIFY_NO_SYSTEMD" == "0" ]]; then
    start_pg_systemd
    print_post_install_hint
  else
    # Docker verification mode configures remote access, bootstraps n8n, and
    # then keeps PostgreSQL in the foreground.
    configure_for_remote
    start_pg_no_systemd_bg
    bootstrap_n8n_db
    enable_pgvector_in_n8n_db
    stop_pg_no_systemd
    exec_pg_foreground   # Does not return.
  fi
}
main "$@"
