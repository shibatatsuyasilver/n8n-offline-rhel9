#!/usr/bin/env bash
# Start a two-container Docker stack with n8n and external PostgreSQL 18.
# The n8n container runs nginx with self-signed TLS and proxies to n8n on
# 127.0.0.1. Both containers use the offline bundles and Docker volumes.

# Enable strict Bash behavior so failures stop the script immediately.
set -Eeuo pipefail

# Resolve the absolute directory that contains this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configure offline bundle paths for n8n and PostgreSQL.
N8N_BUNDLE="${N8N_BUNDLE:-${SCRIPT_DIR}/dist/n8n-offline-rhel9.6-x86_64}"
PG_BUNDLE="${PG_BUNDLE:-${SCRIPT_DIR}/dist/postgres-offline-rhel9-x86_64}"

# Container base image and platform.
RHEL_IMAGE="registry.access.redhat.com/ubi9/ubi"
DOCKER_PLATFORM="linux/amd64"

# Docker network, container names, and data volume names.
NETWORK_NAME="n8n-stack"
PG_CONTAINER="n8n-stack-pg"
N8N_CONTAINER="n8n-stack-n8n"
PG_VOLUME="n8n-stack-pg-data"
N8N_VOLUME="n8n-stack-n8n-data"

# Public HTTPS port on the Docker host.
N8N_HOST_HTTPS_PORT="${N8N_HOST_HTTPS_PORT:-${N8N_HOST_PORT:-8443}}"
# Local file used to persist generated secrets such as the database password.
ENV_FILE="${SCRIPT_DIR}/.stack-env"

# Print normal log messages.
log() { printf '[run-stack] %s\n' "$*"; }
# Print an error and exit.
die() { printf '[run-stack] ERROR: %s\n' "$*" >&2; exit 1; }

# Print command-line help.
usage() {
  cat <<USAGE
Usage: $0 <command>

commands:
  up        Create the network/containers, start n8n + PG, and publish HTTPS on ${N8N_HOST_HTTPS_PORT}
  down      Stop and remove containers and network. Volumes are kept.
  destroy   Run down and remove Docker volumes, deleting PG and n8n data.
  status    Show container status.
  logs      Follow the n8n container logs. Press Ctrl-C to stop following.
  pg-logs   Follow the PG container logs.

Environment variables:
  N8N_HOST_HTTPS_PORT  HTTPS port on the Docker host. Defaults to 8443.
  N8N_HOST_PORT        Legacy fallback used only when N8N_HOST_HTTPS_PORT is unset.
  N8N_BUNDLE           n8n bundle path.
  PG_BUNDLE            PostgreSQL bundle path.
USAGE
}

# Ensure .stack-env exists and contains generated database and n8n secrets.
ensure_env_file() {
  if [[ -f "$ENV_FILE" ]]; then
    # Read existing generated values.
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi
  # Generate missing secrets and persist them for later restarts.
  if [[ -z "${PG_PASSWORD:-}" || -z "${N8N_ENCRYPTION_KEY:-}" ]]; then
    PG_PASSWORD="${PG_PASSWORD:-$(openssl rand -hex 24)}"
    N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-$(openssl rand -hex 32)}"
    umask 077
    cat > "$ENV_FILE" <<EOF
PG_PASSWORD='${PG_PASSWORD}'
N8N_ENCRYPTION_KEY='${N8N_ENCRYPTION_KEY}'
EOF
    log "Generated new secrets and wrote ${ENV_FILE}; keep it for restarts"
  fi
  export PG_PASSWORD N8N_ENCRYPTION_KEY
}

# Return success when a container with the given name exists, even if stopped.
container_exists() {
  docker ps -a --format '{{.Names}}' | grep -q "^${1}$"
}

# Return success when a container with the given name is running.
container_running() {
  docker ps --format '{{.Names}}' | grep -q "^${1}$"
}

# Wait until the n8n container HTTPS health endpoint responds.
wait_for_https() {
  log "Waiting for n8n HTTPS at https://localhost:${N8N_HOST_HTTPS_PORT}/healthz..."
  # Try up to 180 times with a one-second delay.
  for i in $(seq 1 180); do
    # If the container exits while waiting, print recent logs and fail.
    if ! container_running "$N8N_CONTAINER"; then
      docker logs --tail 80 "$N8N_CONTAINER" >&2 || true
      die "n8n container exited after ${i} seconds"
    fi
    # Probe the health endpoint over HTTPS with the self-signed certificate.
    if curl -kfsS --max-time 2 "https://localhost:${N8N_HOST_HTTPS_PORT}/healthz" >/dev/null 2>&1; then
      log "n8n HTTPS is ready"
      return 0
    fi
    sleep 1
  done
  # Print recent logs when the service does not become ready in time.
  docker logs --tail 120 "$N8N_CONTAINER" >&2 || true
  die "n8n HTTPS did not respond within 180 seconds"
}

# Handle the up command by starting PostgreSQL and n8n containers.
cmd_up() {
  # Ensure the required bundle directories exist.
  [[ -d "$N8N_BUNDLE" ]] || die "n8n bundle not found: $N8N_BUNDLE"
  [[ -d "$PG_BUNDLE" ]] || die "PostgreSQL bundle not found: $PG_BUNDLE"
  # Ensure required host commands exist.
  command -v docker >/dev/null 2>&1 || die "docker not found"
  command -v curl >/dev/null 2>&1 || die "curl not found"

  ensure_env_file

  # Pull the UBI base image used by the runtime containers.
  docker pull --platform "$DOCKER_PLATFORM" "$RHEL_IMAGE" >/dev/null

  # Create the dedicated Docker network used by both containers.
  if ! docker network ls --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
    log "Creating network ${NETWORK_NAME}"
    docker network create --driver bridge "$NETWORK_NAME" >/dev/null
  fi

  # Create persistent data volumes for PostgreSQL and n8n.
  docker volume create "$PG_VOLUME" >/dev/null
  docker volume create "$N8N_VOLUME" >/dev/null

  # Start the PostgreSQL container.
  if container_running "$PG_CONTAINER"; then
    log "PostgreSQL container is already running"
  else
    # Remove a stale stopped container before creating a new one.
    container_exists "$PG_CONTAINER" && docker rm -f "$PG_CONTAINER" >/dev/null
    log "Starting PostgreSQL container ${PG_CONTAINER}"
    # Mount the offline bundle and let the installer configure PostgreSQL.
    docker run -d --name "$PG_CONTAINER" --network "$NETWORK_NAME" \
      --platform "$DOCKER_PLATFORM" \
      --restart unless-stopped \
      -v "$PG_BUNDLE:/bundle:ro" \
      -v "$PG_VOLUME:/var/lib/pgsql" \
      -e N8N_DB_PASSWORD="$PG_PASSWORD" \
      "$RHEL_IMAGE" \
      /bundle/install-pg-offline.sh --verify-no-systemd --bundle-dir /bundle >/dev/null
  fi

  # Wait until PostgreSQL accepts connections.
  log "Waiting for PostgreSQL to become ready..."
  for i in $(seq 1 180); do
    if ! container_running "$PG_CONTAINER"; then
      docker logs --tail 30 "$PG_CONTAINER" >&2
      die "PostgreSQL container exited after ${i} seconds"
    fi
    # Probe the local PostgreSQL socket inside the container.
    if docker exec "$PG_CONTAINER" /usr/pgsql-18/bin/pg_isready -h /var/run/postgresql >/dev/null 2>&1; then
      log "PostgreSQL is ready"
      break
    fi
    sleep 1
  done

  # Start the n8n container.
  if container_running "$N8N_CONTAINER"; then
    log "n8n container is already running"
  else
    # Remove a stale stopped container before creating a new one.
    container_exists "$N8N_CONTAINER" && docker rm -f "$N8N_CONTAINER" >/dev/null
    log "Starting n8n container ${N8N_CONTAINER} with HTTPS published on :${N8N_HOST_HTTPS_PORT}"

    # Bind the configured public HTTPS port and pass database connection settings.
    docker run -d --name "$N8N_CONTAINER" --network "$NETWORK_NAME" \
      --platform "$DOCKER_PLATFORM" \
      --restart unless-stopped \
      -p "${N8N_HOST_HTTPS_PORT}:${N8N_HOST_HTTPS_PORT}" \
      -v "$N8N_BUNDLE:/bundle:ro" \
      -v "$N8N_VOLUME:/var/lib/n8n" \
      -e N8N_DB_HOST="$PG_CONTAINER" \
      -e N8N_DB_PORT=5432 \
      -e N8N_DB_NAME=n8n \
      -e N8N_DB_USER=n8n \
      -e N8N_DB_PASSWORD="$PG_PASSWORD" \
      -e N8N_ENCRYPTION_KEY="$N8N_ENCRYPTION_KEY" \
      -e N8N_TLS_HOSTNAME=localhost \
      -e N8N_TLS_EXTRA_IP=127.0.0.1 \
      -e N8N_HTTPS_PORT="$N8N_HOST_HTTPS_PORT" \
      "$RHEL_IMAGE" \
      bash -c '
        set -Eeuo pipefail
        # On first start, run the offline installer and mark the image initialized.
        if [[ ! -f /opt/n8n/.installed ]]; then
          /bundle/install-offline.sh --verify-no-systemd --skip-smoke --bundle-dir /bundle
          touch /opt/n8n/.installed
        fi

        # Ensure data ownership is correct after Docker volume mounting.
        chown -R n8n:n8n /var/lib/n8n

        # Load the generated environment and start n8n plus nginx.
        set -a; . /etc/n8n/n8n.env; set +a
        # Run n8n as the n8n user in the background.
        runuser -m -u n8n -- /usr/local/bin/n8n start &
        n8n_pid=$!

        # Run nginx in the foreground mode, supervised by this shell.
        /usr/sbin/nginx -g "daemon off;" &
        nginx_pid=$!

        # Stop both child processes when this shell receives a termination signal.
        trap "kill ${n8n_pid} ${nginx_pid} >/dev/null 2>&1 || true" TERM INT
        wait -n "${n8n_pid}" "${nginx_pid}"
      ' >/dev/null
  fi

  # Wait for the HTTPS endpoint before returning success.
  wait_for_https

  cat <<EOF

[run-stack] Done. n8n is available at https://localhost:${N8N_HOST_HTTPS_PORT}.
            The self-signed certificate will trigger a first-visit browser warning.
            First startup can take tens of seconds while n8n is unpacked and PG connects.
            View progress:       $0 logs
            Stop and keep data:  $0 down
            Delete all data:     $0 destroy
EOF
}

# Handle the down command by removing containers and the network.
cmd_down() {
  log "Stopping and removing containers and network; volumes are kept"
  docker rm -f "$N8N_CONTAINER" >/dev/null 2>&1 || true
  docker rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
}

# Handle the destroy command by deleting volumes and generated secrets.
cmd_destroy() {
  cmd_down
  log "Deleting Docker volumes; data will be lost"
  docker volume rm "$N8N_VOLUME" >/dev/null 2>&1 || true
  docker volume rm "$PG_VOLUME" >/dev/null 2>&1 || true
  rm -f "$ENV_FILE"
}

# Handle the status command by showing container state.
cmd_status() {
  docker ps -a --filter "name=${PG_CONTAINER}" --filter "name=${N8N_CONTAINER}" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
}

# Handle the logs command by following n8n logs.
cmd_logs() {
  docker logs -f "$N8N_CONTAINER"
}

# Handle the pg-logs command by following PostgreSQL logs.
cmd_pg_logs() {
  docker logs -f "$PG_CONTAINER"
}

# Dispatch commands.
case "${1:-}" in
  up) shift; cmd_up "$@" ;;
  down) shift; cmd_down "$@" ;;
  destroy) shift; cmd_destroy "$@" ;;
  status) cmd_status ;;
  logs) cmd_logs ;;
  pg-logs) cmd_pg_logs ;;
  ""|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
