#!/usr/bin/env bash
# n8n offline bundle preparation script for Red Hat 9.x.
# Run this script on an online host to download and package n8n, Node.js, and
# the required RPM dependencies.

# Enable strict Bash behavior so failures stop the script immediately.
set -Eeuo pipefail

# Resolve the absolute directory that contains this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configure the output bundle name and directory.
BUNDLE_NAME="n8n-offline-rhel9.6-x86_64"
DIST_ROOT="${DIST_ROOT:-${SCRIPT_DIR}/dist}"
BUNDLE_DIR="${BUNDLE_DIR:-${DIST_ROOT}/${BUNDLE_NAME}}"

# Use Rocky Linux 9 as the preparation container image. It is binary compatible
# with RHEL 9 and includes createrepo_c through AppStream without a subscription.
# The resulting RPMs remain compatible with RHEL 9, UBI 9, Alma 9, and Rocky 9.
RHEL_IMAGE="rockylinux:9"
DOCKER_PLATFORM="linux/amd64"

# Node.js version and download metadata.
NODE_VERSION="v22.22.2"
NODE_DIST="node-${NODE_VERSION}-linux-x64"
NODE_TARBALL="${NODE_DIST}.tar.xz"
NODE_URL="https://nodejs.org/dist/${NODE_VERSION}/${NODE_TARBALL}"
NODE_SHA256="88fd1ce767091fd8d4a99fdb2356e98c819f93f3b1f8663853a2dee9b438068a"

# n8n version metadata.
N8N_VERSION="2.17.7"
N8N_PREFIX_TARBALL="n8n-prefix-${N8N_VERSION}-node-${NODE_VERSION}-rhel9-x86_64.tar.xz"

# RPM seed package list for the n8n host. PostgreSQL server packages are built
# by prepare-pg-online.sh into a separate bundle.
DNF_SEED_PACKAGES=(
  ca-certificates
  tzdata
  curl
  openssl
  git
  GraphicsMagick
  fontconfig
  xz
  nginx
)

VERIFY_OFFLINE=1
KEEP_EXISTING=0
REUSE_N8N_PREFIX=0

# Print command-line help.
usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --bundle-dir DIR      Write the generated bundle to DIR.
  --skip-verify         Skip Docker offline verification.
  --keep-existing       Keep the existing bundle directory instead of rebuilding it.
  --reuse-n8n-prefix    Reuse an existing n8n tarball and npm package manifest.
  -h, --help            Show this help message.
USAGE
}

# Print normal log messages.
log() { printf '[prepare-online] %s\n' "$*"; }
# Print an error and exit.
die() { printf '[prepare-online] ERROR: %s\n' "$*" >&2; exit 1; }
# Require a command to exist before using it.
need_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

# Return the sha256 hash for a file, supporting sha256sum or shasum.
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
# Print one checksum line for use in SHA256SUMS.
write_sha256_line() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"
  else shasum -a 256 "$1"; fi
}
# Verify a file hash against an expected sha256 value.
verify_sha256() {
  local actual; actual="$(sha256_file "$2")"
  [[ "$actual" == "$1" ]] || die "$2 checksum mismatch: expected $1, got $actual"
}

# Parse command-line arguments.
parse_args() {
  while (($#)); do
    case "$1" in
      --bundle-dir) shift; BUNDLE_DIR="$1" ;; # Set the output bundle directory.
      --skip-verify) VERIFY_OFFLINE=0 ;; # Skip local Docker verification.
      --keep-existing) KEEP_EXISTING=1 ;; # Keep the existing bundle directory.
      --reuse-n8n-prefix) REUSE_N8N_PREFIX=1 ;; # Reuse a previously built n8n tarball.
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
}

# Prepare the bundle directory, clearing old files and copying the installer.
prepare_bundle_dir() {
  local bundle_parent bundle_base
  bundle_parent="$(dirname "$BUNDLE_DIR")"
  bundle_base="$(basename "$BUNDLE_DIR")"
  mkdir -p "$bundle_parent"
  BUNDLE_DIR="$(cd "$bundle_parent" && pwd)/${bundle_base}"
  # Clear and rebuild the bundle directory unless the caller asked to keep it.
  if [[ "$KEEP_EXISTING" == "0" ]]; then rm -rf "$BUNDLE_DIR"; fi

  # Create the local RPM repository directory.
  mkdir -p "$BUNDLE_DIR/rpm-repo"
  # Copy the offline installer into the bundle.
  cp "${SCRIPT_DIR}/install-offline.sh" "$BUNDLE_DIR/install-offline.sh"
  chmod +x "$BUNDLE_DIR/install-offline.sh"
}

# Download the Node.js tarball and verify its checksum.
download_node() {
  local target="${BUNDLE_DIR}/${NODE_TARBALL}"
  # Reuse the file when it already exists with the expected checksum.
  if [[ -f "$target" ]] && [[ "$(sha256_file "$target")" == "$NODE_SHA256" ]]; then
    log "Node tarball already exists and its checksum is valid"
    return
  fi
  rm -f "$target"
  log "Downloading ${NODE_TARBALL}..."
  # Download through curl with retries.
  curl -fL --retry 3 --retry-delay 2 -o "${target}.tmp" "$NODE_URL"
  # Verify the downloaded file before moving it into place.
  verify_sha256 "$NODE_SHA256" "${target}.tmp"
  mv "${target}.tmp" "$target"
}

# Use Docker to download required RPMs and create the local repository metadata.
build_dnf_repo() {
  log "Downloading RHEL-compatible dnf dependencies into the local repository..."

  docker run --rm -i --platform "$DOCKER_PLATFORM" -v "${BUNDLE_DIR}:/bundle" "$RHEL_IMAGE" bash -s -- "${DNF_SEED_PACKAGES[@]}" <<'IN_CONTAINER'
set -Eeuo pipefail

seed_packages=("$@")

# Rocky 9 enables BaseOS, AppStream, and extras by default. createrepo_c is in
# AppStream; GraphicsMagick is in EPEL, so enable EPEL as well.
dnf install -y dnf-plugins-core
dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
dnf install -y createrepo_c

# Recreate the repository directory.
rm -rf /bundle/rpm-repo
mkdir -p /bundle/rpm-repo

cd /bundle/rpm-repo
# Resolve and download all package dependencies into the current directory.
dnf download --resolve --alldeps "${seed_packages[@]}"

# Generate dnf repository metadata.
createrepo_c .

manifest_tmp=/bundle/rpm-packages.tsv.tmp
{
  # Write an RPM package manifest for later inspection.
  printf 'package\tversion\tarchitecture\tfilename\tsha256\n'
  for rpm in *.rpm; do
    package="$(rpm -qp --queryformat '%{NAME}' "$rpm")"
    version="$(rpm -qp --queryformat '%{VERSION}-%{RELEASE}' "$rpm")"
    architecture="$(rpm -qp --queryformat '%{ARCH}' "$rpm")"
    filename="$rpm"
    sha="$(sha256sum "$rpm" | awk '{print $1}')"
    printf '%s\t%s\t%s\t%s\t%s\n' "$package" "$version" "$architecture" "$filename" "$sha"
  done | sort -t $'\t' -k1,1 -k2,2
} > "$manifest_tmp"
mv "$manifest_tmp" /bundle/rpm-packages.tsv
IN_CONTAINER
}

# Use Docker to install and package the global n8n prefix.
build_n8n_prefix() {
  log "Building preinstalled /opt/n8n package for n8n@${N8N_VERSION}..."

  # Skip rebuilding when the caller asked to reuse an existing tarball.
  if [[ "$REUSE_N8N_PREFIX" == "1" && -s "${BUNDLE_DIR}/${N8N_PREFIX_TARBALL}" ]]; then
    log "Reusing existing ${N8N_PREFIX_TARBALL}"; return
  fi

  rm -f "${BUNDLE_DIR}/${N8N_PREFIX_TARBALL}" "${BUNDLE_DIR}/npm-packages.json"
  docker run --rm -i --platform "$DOCKER_PLATFORM" -v "${BUNDLE_DIR}:/bundle" "$RHEL_IMAGE" bash -s -- "$NODE_TARBALL" "$NODE_DIST" "$N8N_VERSION" "$N8N_PREFIX_TARBALL" <<'IN_CONTAINER'
set -Eeuo pipefail
node_tarball="$1"; node_dist="$2"; n8n_version="$3"; n8n_prefix_tarball="$4"

# Install build tools needed by npm modules.
dnf install -y --allowerasing make gcc-c++ python3 xz tar curl

# Extract Node.js and configure PATH.
tar -xJf "/bundle/${node_tarball}" -C /opt
export PATH="/opt/${node_dist}/bin:/opt/n8n/bin:${PATH}"

# Create the n8n prefix and install n8n through npm.
mkdir -p /opt/n8n
npm config set fund false
npm config set audit false
npm install -g --prefix /opt/n8n "n8n@${n8n_version}" --omit=dev --no-audit --no-fund

# Export the npm dependency manifest.
npm ls --prefix /opt/n8n -g --all --json > /bundle/npm-packages.json || true
# Package /opt/n8n and force root ownership in the tarball.
export XZ_OPT="${XZ_OPT:--T0}"
tar --numeric-owner --owner=0 --group=0 -C /opt -cJf "/bundle/${n8n_prefix_tarball}" n8n
IN_CONTAINER
}

# Write manifest.env with bundle metadata and build parameters.
write_manifest() {
  local created_at; created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  cat > "${BUNDLE_DIR}/manifest.env" <<MANIFEST
BUNDLE_NAME='${BUNDLE_NAME}'
TARGET_OS_ID='rhel'
TARGET_VERSION_ID='9'
TARGET_ARCH='x86_64'
DOCKER_PREP_IMAGE='${RHEL_IMAGE}'
DOCKER_PLATFORM='${DOCKER_PLATFORM}'
NODE_VERSION='${NODE_VERSION}'
NODE_DIST='${NODE_DIST}'
NODE_TARBALL='${NODE_TARBALL}'
NODE_SHA256='${NODE_SHA256}'
N8N_VERSION='${N8N_VERSION}'
N8N_PREFIX_TARBALL='${N8N_PREFIX_TARBALL}'
RPM_REPO_DIR='rpm-repo'
RPM_PACKAGES_MANIFEST='rpm-packages.tsv'
NPM_PACKAGES_MANIFEST='npm-packages.json'
DNF_SEED_PACKAGES='${DNF_SEED_PACKAGES[*]}'
CREATED_AT_UTC='${created_at}'
MANIFEST
}

# Generate SHA256SUMS for every file in the bundle directory.
write_checksums() {
  local tmp_file="${BUNDLE_DIR}/SHA256SUMS.tmp"
  log "Generating SHA256SUMS..."
  ( cd "$BUNDLE_DIR"
    # Hash every file except SHA256SUMS itself and the temporary file.
    while IFS= read -r file; do write_sha256_line "$file"; done < <(find . -type f ! -name SHA256SUMS ! -name SHA256SUMS.tmp -print | sed 's#^\./##' | LC_ALL=C sort)
  ) > "$tmp_file"
  mv "$tmp_file" "${BUNDLE_DIR}/SHA256SUMS"
}

# Verify generated bundle files, repository metadata, and checksums.
verify_bundle_files() {
  log "Verifying generated bundle files..."
  [[ -s "${BUNDLE_DIR}/rpm-repo/repodata/repomd.xml" ]] || die "Missing repodata"
  ( cd "$BUNDLE_DIR"
    if command -v sha256sum >/dev/null 2>&1; then sha256sum -c SHA256SUMS
    else shasum -a 256 -c SHA256SUMS; fi )
}

# Run offline Docker verification unless the caller skipped it.
run_offline_verify() {
  [[ "$VERIFY_OFFLINE" == "1" ]] || return 0
  log "Running Docker offline verification with an internal network and postgres:18..."
  "${SCRIPT_DIR}/verify-offline.sh" --bundle-dir "$BUNDLE_DIR"
}

# Main script entry point.
main() {
  parse_args "$@"
  need_command docker
  need_command curl
  prepare_bundle_dir
  download_node
  build_dnf_repo
  build_n8n_prefix
  write_manifest
  write_checksums
  verify_bundle_files
  run_offline_verify
  log "Done: ${BUNDLE_DIR}"
}
main "$@"
