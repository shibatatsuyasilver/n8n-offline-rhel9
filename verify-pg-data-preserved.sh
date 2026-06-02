#!/usr/bin/env bash
# Data-preservation verifier for the PostgreSQL 18 + pgAdmin4 bundle.
# Proves that re-running install-pg-offline.sh on a host that ALREADY has a
# PostgreSQL data directory does NOT reinitialize or wipe it.
#
# Method: mount a persistent Docker volume at /var/lib/pgsql and run the
# bundle's installer twice on --network none.
#   Run 1 (empty volume): initdb runs and a cluster is created.
#   A sentinel file is then dropped into the data directory.
#   Run 2 (same volume): the installer must DETECT the existing cluster, skip
#   initdb, and leave the data directory — including the sentinel — untouched.
# The volume is removed at the end.

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

# Persistent volume, container names, and throwaway passwords (PID-scoped).
DATA_VOLUME="pg-preserve-data-$$"
RUN1_CONTAINER="pg-preserve-run1-$$"
RUN2_CONTAINER="pg-preserve-run2-$$"
PG_PASSWORD="pg-preserve-pass-$$"
PGADMIN_PASSWORD="pgadmin-preserve-pass-$$"

# The data directory inside the container, derived from the bundle PG major.
DATA_DIR_IN_VOL=""
SENTINEL="PRESERVE_SENTINEL"

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
log() { printf '[verify-pg-data-preserved] %s\n' "$*"; }
# Print an error and exit.
die() { printf '[verify-pg-data-preserved] ERROR: %s\n' "$*" >&2; exit 1; }

# Clean up all Docker resources created by the test.
cleanup() {
  docker rm -f "$RUN1_CONTAINER" "$RUN2_CONTAINER" >/dev/null 2>&1 || true
  docker volume rm "$DATA_VOLUME" >/dev/null 2>&1 || true
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
  [[ -f "${PG_BUNDLE}/manifest.env" ]] || die "manifest.env not found in bundle: $PG_BUNDLE"
  # shellcheck disable=SC1091
  local pg_major
  pg_major="$(. "${PG_BUNDLE}/manifest.env"; printf '%s' "$PG_MAJOR")"
  [[ -n "$pg_major" ]] || die "Could not read PG_MAJOR from bundle manifest"
  DATA_DIR_IN_VOL="/var/lib/pgsql/${pg_major}/data"
}

# Ensure the UBI image is available locally before going offline.
ensure_image() {
  log "Ensuring the UBI ${TARGET_RHEL_MINOR} image is available locally..."
  docker pull --platform "$DOCKER_PLATFORM" "$RHEL_IMAGE"
}

# Run the bundle installer once against the persistent volume, capturing its log.
run_installer() {
  local container="$1" logfile="$2"
  docker run --rm --name "$container" \
    --network none \
    --platform "$DOCKER_PLATFORM" \
    -v "$PG_BUNDLE:/bundle:ro" \
    -v "$DATA_VOLUME:/var/lib/pgsql" \
    -e N8N_DB_PASSWORD="$PG_PASSWORD" \
    -e PGADMIN_ADMIN_PASSWORD="$PGADMIN_PASSWORD" \
    "$RHEL_IMAGE" \
    /bundle/install-pg-offline.sh --verify-no-systemd --verify-pgadmin --bundle-dir /bundle \
    > "$logfile" 2>&1
}

# Run a tiny helper container against the volume (no network, no PostgreSQL).
vol_exec() {
  docker run --rm --network none --platform "$DOCKER_PLATFORM" \
    -v "$DATA_VOLUME:/var/lib/pgsql" "$RHEL_IMAGE" bash -c "$1"
}

# Main verifier entry point.
main() {
  parse_args "$@"
  command -v docker >/dev/null 2>&1 || die "docker not found"
  ensure_image

  log "Creating persistent data volume $DATA_VOLUME..."
  docker volume create "$DATA_VOLUME" >/dev/null

  local run1_log run2_log
  run1_log="$(mktemp)"; run2_log="$(mktemp)"

  log "Run 1: installing into an empty volume (expect initdb to run)..."
  run_installer "$RUN1_CONTAINER" "$run1_log" || { cat "$run1_log" >&2; die "Run 1 installer failed"; }
  grep -q "Initializing data directory" "$run1_log" \
    || { cat "$run1_log" >&2; die "Run 1 did not initialize a data directory as expected"; }
  log "Run 1 OK: a fresh cluster was initialized"

  log "Dropping sentinel file ${SENTINEL} into ${DATA_DIR_IN_VOL}..."
  vol_exec "touch '${DATA_DIR_IN_VOL}/${SENTINEL}' && test -f '${DATA_DIR_IN_VOL}/${SENTINEL}'" \
    || die "Could not write sentinel into the data directory"

  log "Run 2: re-installing against the SAME volume (expect initdb to be skipped)..."
  run_installer "$RUN2_CONTAINER" "$run2_log" || { cat "$run2_log" >&2; die "Run 2 installer failed"; }
  if grep -q "Initializing data directory" "$run2_log"; then
    cat "$run2_log" >&2
    die "Run 2 RE-INITIALIZED the data directory — existing data would be lost!"
  fi
  grep -q "Existing PostgreSQL data directory detected" "$run2_log" \
    || { cat "$run2_log" >&2; die "Run 2 did not report preserving the existing data directory"; }
  log "Run 2 OK: initdb was skipped and the existing cluster was preserved"

  log "Verifying the sentinel survived the second install..."
  vol_exec "test -f '${DATA_DIR_IN_VOL}/${SENTINEL}'" \
    || die "Sentinel file is gone — the data directory was clobbered!"

  rm -f "$run1_log" "$run2_log"
  log "Data-preservation verification passed: re-running the installer preserves the existing PostgreSQL ${DATA_DIR_IN_VOL#*/pgsql/} data directory (initdb skipped, sentinel intact)."
}
main "$@"
