#!/usr/bin/env bash
# End-to-end verifier for the n8n offline installer.
# On a Docker-enabled development host, this script uses an internal Docker
# network to simulate an offline RHEL 9 host using an external PostgreSQL 18 DB.
#
# This does not verify install-pg-offline.sh; it uses the official postgres:18
# image as a stand-in for the external database host.

# Enable strict Bash behavior so failures stop the script immediately.
set -Eeuo pipefail

# Resolve the absolute directory that contains this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default n8n bundle directory.
DEFAULT_BUNDLE_DIR="${SCRIPT_DIR}/dist/n8n-offline-rhel9.6-x86_64"
BUNDLE_DIR="${DEFAULT_BUNDLE_DIR}"

# Test images.
PG_IMAGE="postgres:18"
RHEL_IMAGE="registry.access.redhat.com/ubi9/ubi"
DOCKER_PLATFORM="linux/amd64"

# Internal Docker network and container names. Include the PID to avoid clashes.
NETWORK_NAME="n8n-offline-verify-$$"
PG_CONTAINER="n8n-pg-verify-$$"
INSTALL_CONTAINER="n8n-install-verify-$$"
PG_PASSWORD="verify-pg-pass-$$"

# Print command-line help.
usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --bundle-dir DIR   n8n offline bundle directory. Defaults to ${DEFAULT_BUNDLE_DIR}.
  -h, --help         Show this help message.
USAGE
}

# Print normal log messages.
log() { printf '[verify-offline] %s\n' "$*"; }
# Print an error and exit.
die() { printf '[verify-offline] ERROR: %s\n' "$*" >&2; exit 1; }

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
      --bundle-dir) shift; BUNDLE_DIR="$1" ;; # Set the bundle directory.
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
  # Validate and absolutize the bundle directory.
  [[ -d "$BUNDLE_DIR" ]] || die "Bundle directory does not exist: $BUNDLE_DIR"
  BUNDLE_DIR="$(cd "$BUNDLE_DIR" && pwd)"
}

# Ensure required Docker images are available locally before using an internal network.
ensure_images() {
  log "Ensuring required images are available locally before internal-network use..."
  docker pull --platform "$DOCKER_PLATFORM" "$PG_IMAGE"
  docker pull --platform "$DOCKER_PLATFORM" "$RHEL_IMAGE"
}

# Create an isolated Docker network with no internet egress.
create_network() {
  log "Creating internal Docker network $NETWORK_NAME with no internet egress..."
  docker network create --internal --driver bridge "$NETWORK_NAME" >/dev/null
}

# Start the official PostgreSQL container as the external database stand-in.
start_pg() {
  log "Starting PostgreSQL 18 container $PG_CONTAINER..."
  docker run -d --name "$PG_CONTAINER" --network "$NETWORK_NAME" \
    --platform "$DOCKER_PLATFORM" \
    -e POSTGRES_USER=n8n \
    -e POSTGRES_PASSWORD="$PG_PASSWORD" \
    -e POSTGRES_DB=n8n \
    "$PG_IMAGE" >/dev/null

  log "Waiting for PostgreSQL to become ready..."
  # Poll until PostgreSQL accepts connections.
  for _ in $(seq 1 60); do
    if docker exec "$PG_CONTAINER" pg_isready -U n8n -d n8n >/dev/null 2>&1; then
      log "PostgreSQL is ready"
      return 0
    fi
    sleep 1
  done
  docker logs "$PG_CONTAINER" >&2 || true
  die "PostgreSQL was not ready within 60 seconds"
}

# Mount the n8n bundle into a test container and run the offline installer.
run_install() {
  log "Running install-offline.sh --verify-no-systemd in a ubi9 container..."
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

# Main verifier entry point.
main() {
  parse_args "$@"
  command -v docker >/dev/null 2>&1 || die "docker not found"
  ensure_images
  create_network
  start_pg
  run_install
  log "Offline install end-to-end verification passed."
}
main "$@"
