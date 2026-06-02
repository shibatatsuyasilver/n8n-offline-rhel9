#!/usr/bin/env bash
# n8n-access verifier for the PostgreSQL 18 bundle.
# Proves the production "n8n-ready" auto-configuration is correct and secure by
# running install-pg-offline.sh --verify-no-systemd --verify-n8n-access inside a
# single container on an --internal Docker network (no internet egress) with a
# fixed IP. It then asserts, via docker exec:
#   - listen_addresses is localhost + the host IP (never '*')
#   - pg_hba allows only the n8n host /32 over scram-sha-256 (no 0.0.0.0/0)
#   - the n8n role/database exist, n8n owns the database, pgvector is enabled
#   - a real remote login as n8n can CREATE/INSERT/SELECT/DROP in schema public
# The last check is the end-to-end proof that listen + pg_hba + scram + the
# ownership/privilege grants all work together.

# Enable strict Bash behavior so failures stop the script immediately.
set -Eeuo pipefail

# Resolve the absolute directory that contains this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default PostgreSQL bundle directory.
DEFAULT_PG_BUNDLE="${SCRIPT_DIR}/dist/postgres-offline-rhel9.2-x86_64"
PG_BUNDLE="${DEFAULT_PG_BUNDLE}"

# Test image and platform.
TARGET_RHEL_MINOR="${TARGET_RHEL_MINOR:-9.2}"
RHEL_IMAGE="${RHEL_IMAGE:-registry.access.redhat.com/ubi9/ubi:${TARGET_RHEL_MINOR}}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/amd64}"

# Internal network with a fixed subnet/IP so we know the host IP in advance and
# can drive the secure config + connect from the matching source address.
NET_NAME="pg-n8n-access-net-$$"
CONTAINER="pg-n8n-access-$$"
PG_SUBNET="${PG_SUBNET:-10.211.83.0/24}"
PG_IP="${PG_IP:-10.211.83.10}"
N8N_DB_PASSWORD="n8n-access-pass-$$"

# Derived from the bundle manifest in main().
PG_BIN=""
PG_DATA=""

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --pg-bundle DIR    PG offline bundle directory. Defaults to ${DEFAULT_PG_BUNDLE}.
  -h, --help         Show this help message.
USAGE
}

log() { printf '[verify-pg-n8n-access] %s\n' "$*"; }
die() { printf '[verify-pg-n8n-access] ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NET_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

parse_args() {
  while (($#)); do
    case "$1" in
      --pg-bundle) shift; PG_BUNDLE="$1" ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
  [[ -d "$PG_BUNDLE" ]] || die "PG bundle directory does not exist: $PG_BUNDLE"
  PG_BUNDLE="$(cd "$PG_BUNDLE" && pwd)"
  [[ -f "${PG_BUNDLE}/manifest.env" ]] || die "manifest.env not found in bundle: $PG_BUNDLE"
  local pg_major
  pg_major="$(. "${PG_BUNDLE}/manifest.env"; printf '%s' "$PG_MAJOR")"
  [[ -n "$pg_major" ]] || die "Could not read PG_MAJOR from bundle manifest"
  PG_BIN="/usr/pgsql-${pg_major}/bin"
  PG_DATA="/var/lib/pgsql/${pg_major}/data"
}

ensure_image() {
  log "Ensuring the UBI ${TARGET_RHEL_MINOR} image is available locally..."
  docker pull --platform "$DOCKER_PLATFORM" "$RHEL_IMAGE"
}

# Run a command inside the running container.
cexec() { docker exec "$CONTAINER" bash -lc "$1"; }

main() {
  parse_args "$@"
  command -v docker >/dev/null 2>&1 || die "docker not found"
  ensure_image

  log "Creating internal network $NET_NAME ($PG_SUBNET, no internet egress)..."
  docker network create --internal --subnet "$PG_SUBNET" "$NET_NAME" >/dev/null

  log "Starting $CONTAINER at $PG_IP with --verify-n8n-access..."
  docker run -d --name "$CONTAINER" \
    --network "$NET_NAME" --ip "$PG_IP" \
    --platform "$DOCKER_PLATFORM" \
    -v "$PG_BUNDLE:/bundle:ro" \
    -e POSTGRES_HOST_IP="$PG_IP" \
    -e N8N_HOST_IP="$PG_IP" \
    -e N8N_DB_PASSWORD="$N8N_DB_PASSWORD" \
    "$RHEL_IMAGE" \
    /bundle/install-pg-offline.sh --verify-no-systemd --verify-n8n-access --bundle-dir /bundle >/dev/null

  log "Waiting for PostgreSQL to come up on $PG_IP..."
  local ready=0 i
  for i in $(seq 1 180); do
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
      docker logs "$CONTAINER" >&2; die "Container exited during install"
    fi
    if docker exec "$CONTAINER" "${PG_BIN}/pg_isready" -h "$PG_IP" -q >/dev/null 2>&1; then
      ready=1; break
    fi
    sleep 1
  done
  [[ "$ready" == 1 ]] || { docker logs --tail 40 "$CONTAINER" >&2; die "PostgreSQL not ready in time"; }

  log "Assertion 1/5: listen_addresses is localhost + ${PG_IP}, not '*'..."
  cexec "grep -E \"^listen_addresses *= *'localhost,${PG_IP}'\" ${PG_DATA}/postgresql.conf" >/dev/null \
    || { cexec "grep '^listen_addresses' ${PG_DATA}/postgresql.conf" >&2; die "listen_addresses not set to localhost,${PG_IP}"; }
  if cexec "grep -E \"^listen_addresses *= *'\\*'\" ${PG_DATA}/postgresql.conf" >/dev/null 2>&1; then
    die "listen_addresses is '*' — too permissive for production"
  fi

  log "Assertion 2/5: pg_hba allows only ${PG_IP}/32 (scram), no 0.0.0.0/0..."
  cexec "grep -E \"^host[[:space:]]+n8n[[:space:]]+n8n[[:space:]]+${PG_IP}/32[[:space:]]+scram-sha-256\" ${PG_DATA}/pg_hba.conf" >/dev/null \
    || { cexec "grep -E '^host' ${PG_DATA}/pg_hba.conf" >&2; die "expected narrow pg_hba rule not found"; }
  if cexec "grep -E '^host.*0\\.0\\.0\\.0/0' ${PG_DATA}/pg_hba.conf" >/dev/null 2>&1; then
    die "pg_hba contains a 0.0.0.0/0 rule — too permissive for production"
  fi

  log "Assertion 3/5: n8n role exists and owns the n8n database..."
  [[ "$(cexec "su - postgres -c \"${PG_BIN}/psql -tAc \\\"SELECT 1 FROM pg_roles WHERE rolname='n8n' AND rolcanlogin\\\"\"")" == "1" ]] \
    || die "n8n login role missing"
  [[ "$(cexec "su - postgres -c \"${PG_BIN}/psql -tAc \\\"SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='n8n'\\\"\"")" == "n8n" ]] \
    || die "n8n database is not owned by the n8n role"

  log "Assertion 4/5: pgvector is enabled in the n8n database..."
  [[ "$(cexec "su - postgres -c \"${PG_BIN}/psql -d n8n -tAc \\\"SELECT extname FROM pg_extension WHERE extname='vector'\\\"\"")" == "vector" ]] \
    || die "pgvector not enabled in the n8n database"

  log "Assertion 5/5: remote login as n8n can create/insert/select/drop in public..."
  docker exec -e PGPASSWORD="$N8N_DB_PASSWORD" "$CONTAINER" \
    "${PG_BIN}/psql" -h "$PG_IP" -U n8n -d n8n -v ON_ERROR_STOP=1 \
    -c "CREATE TABLE n8n_access_check (id int);" \
    -c "INSERT INTO n8n_access_check VALUES (1);" \
    -c "SELECT count(*) FROM n8n_access_check;" \
    -c "DROP TABLE n8n_access_check;" >/dev/null \
    || die "remote n8n login could not create/insert/select/drop in public"

  log "n8n-access verification passed: secure remote config + n8n role/db/pgvector + full public-schema privileges all confirmed on ${PG_IP}."
}
main "$@"
