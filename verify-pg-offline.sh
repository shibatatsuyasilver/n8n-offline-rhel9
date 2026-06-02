#!/usr/bin/env bash
# Offline verifier for the PostgreSQL 18 + pgAdmin4 bundle.
# Runs install-pg-offline.sh inside a single UBI 9.2 container attached to
# --network none (no network interfaces at all), so the install can only use
# the bundle's local file:// RPM repository. The installer initializes
# PostgreSQL, creates the n8n role/database, enables pgvector, installs and
# configures pgAdmin4, starts httpd in the background, and smoke-tests
# https://127.0.0.1:5050/pgadmin4/. The container exits 0 only when all of
# that succeeds, end to end, fully offline.

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

# Container name and throwaway passwords. Include the PID to avoid clashes.
VERIFY_CONTAINER="pg-pgadmin-verify-$$"
PG_PASSWORD="pg-verify-pass-$$"
PGADMIN_PASSWORD="pgadmin-verify-pass-$$"

# Print command-line help.
usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --pg-bundle DIR    PG offline bundle directory. Defaults to ${DEFAULT_PG_BUNDLE}.
  -h, --help         Show this help message.
USAGE
}

# Print normal log messages.
log() { printf '[verify-pg-offline] %s\n' "$*"; }
# Print an error and exit.
die() { printf '[verify-pg-offline] ERROR: %s\n' "$*" >&2; exit 1; }

# Clean up the verification container on normal or failed exit.
cleanup() {
  docker rm -f "$VERIFY_CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Parse command-line arguments.
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
  [[ -f "${PG_BUNDLE}/install-pg-offline.sh" ]] || die "install-pg-offline.sh not found in bundle: $PG_BUNDLE"
}

# Ensure the UBI image is available locally before going offline.
ensure_image() {
  log "Ensuring the UBI ${TARGET_RHEL_MINOR} image is available locally..."
  docker pull --platform "$DOCKER_PLATFORM" "$RHEL_IMAGE"
}

# Run the bundle's installer offline with full pgAdmin4 verification.
run_offline_install() {
  log "Running install-pg-offline.sh --verify-no-systemd --verify-pgadmin on --network none..."
  docker run --rm --name "$VERIFY_CONTAINER" \
    --network none \
    --platform "$DOCKER_PLATFORM" \
    -v "$PG_BUNDLE:/bundle:ro" \
    -e N8N_DB_PASSWORD="$PG_PASSWORD" \
    -e PGADMIN_ADMIN_PASSWORD="$PGADMIN_PASSWORD" \
    "$RHEL_IMAGE" \
    /bundle/install-pg-offline.sh --verify-no-systemd --verify-pgadmin --bundle-dir /bundle
}

# Main verifier entry point.
main() {
  parse_args "$@"
  command -v docker >/dev/null 2>&1 || die "docker not found"
  ensure_image
  run_offline_install
  log "Offline verification passed: PostgreSQL 18 + pgvector + pgAdmin4 all install and serve from the bundle with no network."
}
main "$@"
