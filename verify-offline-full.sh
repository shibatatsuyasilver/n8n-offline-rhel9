#!/usr/bin/env bash
# End-to-end verifier for both n8n and PostgreSQL offline bundles.
# Uses an internal Docker network with two ubi9 containers:
#   - PG host: mounts the PG bundle and runs install-pg-offline.sh --verify-no-systemd.
#   - n8n host: mounts the n8n bundle and runs install-offline.sh --verify-no-systemd.
# This simulates two offline RHEL 9 hosts where n8n connects to external PG.

# Enable strict Bash behavior so failures stop the script immediately.
set -Eeuo pipefail

# Resolve the absolute directory that contains this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default n8n and PostgreSQL bundle directories.
DEFAULT_N8N_BUNDLE="${SCRIPT_DIR}/dist/n8n-offline-rhel9.6-x86_64"
DEFAULT_PG_BUNDLE="${SCRIPT_DIR}/dist/postgres-offline-rhel9-x86_64"
N8N_BUNDLE="${DEFAULT_N8N_BUNDLE}"
PG_BUNDLE="${DEFAULT_PG_BUNDLE}"

# Test image and platform.
RHEL_IMAGE="registry.access.redhat.com/ubi9/ubi"
DOCKER_PLATFORM="linux/amd64"

# Internal Docker network and container names. Include the PID to avoid clashes.
NETWORK_NAME="n8n-full-verify-$$"
PG_CONTAINER="n8n-pg-full-$$"
INSTALL_CONTAINER="n8n-install-full-$$"
PG_PASSWORD="full-verify-pass-$$"

# Print command-line help.
usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --n8n-bundle DIR   n8n offline bundle directory. Defaults to ${DEFAULT_N8N_BUNDLE}.
  --pg-bundle DIR    PG offline bundle directory. Defaults to ${DEFAULT_PG_BUNDLE}.
  -h, --help         Show this help message.
USAGE
}

# Print normal log messages.
log() { printf '[verify-offline-full] %s\n' "$*"; }
# Print an error and exit.
die() { printf '[verify-offline-full] ERROR: %s\n' "$*" >&2; exit 1; }

# Clean up Docker resources created by the test.
cleanup() {
  log "Cleaning up test resources..."
  docker rm -f "$INSTALL_CONTAINER" >/dev/null 2>&1 || true
  docker rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
}
# Always clean up containers and network on normal or failed exit.
trap cleanup EXIT

# Parse command-line arguments.
parse_args() {
  while (($#)); do
    case "$1" in
      --n8n-bundle) shift; N8N_BUNDLE="$1" ;; # Set the n8n bundle directory.
      --pg-bundle) shift; PG_BUNDLE="$1" ;;   # Set the PG bundle directory.
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
  # Validate the bundle directories.
  [[ -d "$N8N_BUNDLE" ]] || die "n8n bundle directory does not exist: $N8N_BUNDLE"
  [[ -d "$PG_BUNDLE" ]] || die "PG bundle directory does not exist: $PG_BUNDLE"
  # Convert the directories to absolute paths.
  N8N_BUNDLE="$(cd "$N8N_BUNDLE" && pwd)"
  PG_BUNDLE="$(cd "$PG_BUNDLE" && pwd)"
}

# Ensure the ubi9 Docker image is available locally.
ensure_image() {
  log "Ensuring the ubi9 image is available locally..."
  docker pull --platform "$DOCKER_PLATFORM" "$RHEL_IMAGE"
}

# Create an isolated Docker network to simulate offline hosts.
create_network() {
  log "Creating internal Docker network $NETWORK_NAME with no internet egress..."
  docker network create --internal --driver bridge "$NETWORK_NAME" >/dev/null
}

# Start the container that mounts the PostgreSQL bundle and runs its installer.
start_pg_host() {
  log "Starting PG container $PG_CONTAINER with install-pg-offline.sh --verify-no-systemd..."
  docker run -d --name "$PG_CONTAINER" --network "$NETWORK_NAME" \
    --platform "$DOCKER_PLATFORM" \
    -v "$PG_BUNDLE:/bundle:ro" \
    -e N8N_DB_PASSWORD="$PG_PASSWORD" \
    "$RHEL_IMAGE" \
    /bundle/install-pg-offline.sh --verify-no-systemd --bundle-dir /bundle >/dev/null

  log "Waiting for PG host installation to finish and enter foreground mode..."
  # Wait until PostgreSQL is installed and accepting connections.
  for i in $(seq 1 180); do
    # If the container exits, installation failed.
    if ! docker ps --format '{{.Names}}' | grep -q "^${PG_CONTAINER}$"; then
      docker logs "$PG_CONTAINER" >&2
      die "PG container exited after ${i} seconds; install failed"
    fi
    # Probe PostgreSQL readiness through pg_isready.
    if docker exec "$PG_CONTAINER" /usr/pgsql-18/bin/pg_isready -h /var/run/postgresql >/dev/null 2>&1; then
      log "PostgreSQL is ready and running in the foreground"
      return 0
    fi
    sleep 1
  done
  docker logs "$PG_CONTAINER" >&2
  die "PostgreSQL was not ready within 180 seconds"
}

# Run the n8n installer in a container that points at the PG container.
run_n8n_install() {
  log "Running install-offline.sh --verify-no-systemd in the n8n container..."
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

# Verify that pgvector was enabled in the n8n PostgreSQL database.
verify_pgvector() {
  log "Verifying pgvector is enabled in the n8n database..."
  if docker exec "$PG_CONTAINER" su - postgres -c \
      "/usr/pgsql-18/bin/psql -d n8n -tAc \"SELECT extname FROM pg_extension WHERE extname='vector';\"" \
      | grep -q '^vector$'; then
    log "pgvector OK"
  else
    docker logs --tail 30 "$PG_CONTAINER" >&2
    die "vector extension is not enabled in the n8n database"
  fi
}

# Main verifier entry point.
main() {
  parse_args "$@"
  command -v docker >/dev/null 2>&1 || die "docker not found"
  ensure_image
  create_network
  start_pg_host
  run_n8n_install
  verify_pgvector
  log "Dual-bundle end-to-end verification passed: n8n install, PG install, pgvector, and cross-host connection."
}
main "$@"
