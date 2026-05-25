#!/usr/bin/env bash
# PostgreSQL 18 offline bundle preparation script for Red Hat 9.x.
# Run this script on an online host to download PostgreSQL server, contrib,
# pgvector, and all RPM dependencies into a portable offline bundle.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PG_MAJOR="${PG_MAJOR:-18}"
BUNDLE_NAME="postgres-offline-rhel9-x86_64"
DIST_ROOT="${DIST_ROOT:-${SCRIPT_DIR}/dist}"
BUNDLE_DIR="${BUNDLE_DIR:-${DIST_ROOT}/${BUNDLE_NAME}}"

# Pin the preparation container and RPM source repos to the target RHEL minor
# release. Floating rockylinux:9 can roll forward to newer minor RPMs.
TARGET_RHEL_MINOR="${TARGET_RHEL_MINOR:-9.6}"
PGDG_RHEL_MINOR="${PGDG_RHEL_MINOR:-${TARGET_RHEL_MINOR}}"
RHEL_IMAGE="${RHEL_IMAGE:-registry.access.redhat.com/ubi9/ubi:${TARGET_RHEL_MINOR}}"
ROCKY_VAULT_BASE="${ROCKY_VAULT_BASE:-https://download.rockylinux.org/vault/rocky/${TARGET_RHEL_MINOR}}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/amd64}"

KEEP_EXISTING=0

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --bundle-dir DIR   Write the generated bundle to DIR.
  --keep-existing    Keep the existing bundle directory instead of rebuilding it.
  -h, --help         Show this help message.

Environment variables:
  PG_MAJOR           PostgreSQL major version. Defaults to 18.
  TARGET_RHEL_MINOR  Target RHEL minor release. Defaults to 9.6.
  RHEL_IMAGE         Preparation image. Defaults to UBI for TARGET_RHEL_MINOR.
  ROCKY_VAULT_BASE   Rocky vault base URL. Defaults to Rocky TARGET_RHEL_MINOR.
  PGDG_RHEL_MINOR    PGDG repo minor release. Defaults to TARGET_RHEL_MINOR.
USAGE
}

log() { printf '[prepare-pg-online] %s\n' "$*"; }
die() { printf '[prepare-pg-online] ERROR: %s\n' "$*" >&2; exit 1; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
write_sha256_line() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"
  else shasum -a 256 "$1"; fi
}

validate_rpm_manifest() {
  local manifest="${BUNDLE_DIR}/rpm-packages.tsv"
  [[ -s "$manifest" ]] || die "RPM package manifest not found: $manifest"

  if grep -Eq '(el9_7|rhel9\.7)' "$manifest"; then
    grep -E '(el9_7|rhel9\.7)' "$manifest" >&2 || true
    die "RPM manifest contains RHEL/Rocky 9.7 packages; rebuild with target ${TARGET_RHEL_MINOR} repos"
  fi

  if awk -F'\t' 'NR > 1 && $1 ~ /^(rocky-release|rocky-repos|rocky-gpg-keys|rocky-logos.*)$/ { print; found=1 } END { exit found ? 0 : 1 }' "$manifest" >&2; then
    die "RPM manifest contains Rocky release identity packages; RHEL hosts must keep their own release packages"
  fi
}

parse_args() {
  while (($#)); do
    case "$1" in
      --bundle-dir) shift; BUNDLE_DIR="$1" ;;
      --keep-existing) KEEP_EXISTING=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
}

prepare_bundle_dir() {
  local parent base
  parent="$(dirname "$BUNDLE_DIR")"
  base="$(basename "$BUNDLE_DIR")"
  mkdir -p "$parent"
  BUNDLE_DIR="$(cd "$parent" && pwd)/${base}"
  if [[ "$KEEP_EXISTING" == "0" ]]; then rm -rf "$BUNDLE_DIR"; fi
  mkdir -p "$BUNDLE_DIR/rpm-repo"
  cp "${SCRIPT_DIR}/install-pg-offline.sh" "$BUNDLE_DIR/install-pg-offline.sh"
  chmod +x "$BUNDLE_DIR/install-pg-offline.sh"
}

build_dnf_repo() {
  log "Downloading PostgreSQL ${PG_MAJOR} and dependency RPMs for RHEL ${TARGET_RHEL_MINOR}..."
  docker run --rm -i --platform "$DOCKER_PLATFORM" \
    -v "${BUNDLE_DIR}:/bundle" \
    -e PG_MAJOR="$PG_MAJOR" \
    -e PGDG_RHEL_MINOR="$PGDG_RHEL_MINOR" \
    -e ROCKY_VAULT_BASE="$ROCKY_VAULT_BASE" \
    "$RHEL_IMAGE" bash -s <<'IN_CONTAINER'
set -Eeuo pipefail

cat > /etc/yum.repos.d/rhel-minor-compat.repo <<REPO
[rocky-baseos]
name=Rocky target-minor BaseOS
baseurl=${ROCKY_VAULT_BASE}/BaseOS/\$basearch/os/
enabled=1
gpgcheck=0

[rocky-appstream]
name=Rocky target-minor AppStream
baseurl=${ROCKY_VAULT_BASE}/AppStream/\$basearch/os/
enabled=1
gpgcheck=0

[rocky-crb]
name=Rocky target-minor CRB
baseurl=${ROCKY_VAULT_BASE}/CRB/\$basearch/os/
enabled=1
gpgcheck=0

[pgdg-major]
name=PostgreSQL ${PG_MAJOR} for RHEL ${PGDG_RHEL_MINOR}
baseurl=https://download.postgresql.org/pub/repos/yum/${PG_MAJOR}/redhat/rhel-${PGDG_RHEL_MINOR}-\$basearch/
enabled=1
gpgcheck=0

[pgdg-common]
name=PostgreSQL common for RHEL ${PGDG_RHEL_MINOR}
baseurl=https://download.postgresql.org/pub/repos/yum/common/redhat/rhel-${PGDG_RHEL_MINOR}-\$basearch/
enabled=1
gpgcheck=0
REPO

dnf -qy --disablerepo='*' --enablerepo='rocky-*' module disable postgresql || true
dnf --disablerepo='*' --enablerepo='rocky-*' install -y dnf-plugins-core createrepo_c

rm -rf /bundle/rpm-repo
mkdir -p /bundle/rpm-repo
cd /bundle/rpm-repo

dnf --disablerepo='*' --enablerepo='rocky-*' --enablerepo='pgdg-*' \
  --setopt=install_weak_deps=False \
  download --resolve --alldeps \
  "postgresql${PG_MAJOR}-server" \
  "postgresql${PG_MAJOR}-contrib" \
  "postgresql${PG_MAJOR}" \
  "pgvector_${PG_MAJOR}"

# RHEL hosts already provide their own release identity packages.
rm -f rocky-gpg-keys-*.rpm rocky-release-*.rpm rocky-repos-*.rpm

createrepo_c .

manifest_tmp=/bundle/rpm-packages.tsv.tmp
{
  printf 'package\tversion\tarchitecture\tfilename\tsha256\n'
  for rpm in *.rpm; do
    package="$(rpm -qp --queryformat '%{NAME}' "$rpm")"
    version="$(rpm -qp --queryformat '%{VERSION}-%{RELEASE}' "$rpm")"
    architecture="$(rpm -qp --queryformat '%{ARCH}' "$rpm")"
    sha="$(sha256sum "$rpm" | awk '{print $1}')"
    printf '%s\t%s\t%s\t%s\t%s\n' "$package" "$version" "$architecture" "$rpm" "$sha"
  done | sort -t $'\t' -k1,1 -k2,2
} > "$manifest_tmp"
mv "$manifest_tmp" /bundle/rpm-packages.tsv
IN_CONTAINER
}

write_manifest() {
  local created_at target_major
  created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  target_major="${TARGET_RHEL_MINOR%%.*}"
  cat > "${BUNDLE_DIR}/manifest.env" <<MANIFEST
BUNDLE_NAME='${BUNDLE_NAME}'
TARGET_OS_ID='rhel'
TARGET_VERSION_ID='${target_major}'
TARGET_RHEL_MINOR='${TARGET_RHEL_MINOR}'
TARGET_ARCH='x86_64'
DOCKER_PREP_IMAGE='${RHEL_IMAGE}'
DOCKER_PLATFORM='${DOCKER_PLATFORM}'
ROCKY_VAULT_BASE='${ROCKY_VAULT_BASE}'
PGDG_RHEL_MINOR='${PGDG_RHEL_MINOR}'
PG_MAJOR='${PG_MAJOR}'
RPM_REPO_DIR='rpm-repo'
RPM_PACKAGES_MANIFEST='rpm-packages.tsv'
CREATED_AT_UTC='${created_at}'
MANIFEST
}

write_checksums() {
  log "Generating SHA256SUMS..."
  local tmp_file="${BUNDLE_DIR}/SHA256SUMS.tmp"
  ( cd "$BUNDLE_DIR"
    while IFS= read -r file; do write_sha256_line "$file"; done < <(find . -type f ! -name SHA256SUMS ! -name SHA256SUMS.tmp -print | sed 's#^\./##' | LC_ALL=C sort)
  ) > "$tmp_file"
  mv "$tmp_file" "${BUNDLE_DIR}/SHA256SUMS"
}

verify_bundle_files() {
  log "Verifying bundle files..."
  [[ -s "${BUNDLE_DIR}/rpm-repo/repodata/repomd.xml" ]] || die "Missing repodata"
  ( cd "$BUNDLE_DIR"
    if command -v sha256sum >/dev/null 2>&1; then sha256sum -c SHA256SUMS
    else shasum -a 256 -c SHA256SUMS; fi )
}

main() {
  parse_args "$@"
  command -v docker >/dev/null 2>&1 || die "docker not found"
  [[ -f "${SCRIPT_DIR}/install-pg-offline.sh" ]] || die "install-pg-offline.sh not found"
  prepare_bundle_dir
  build_dnf_repo
  validate_rpm_manifest
  write_manifest
  write_checksums
  verify_bundle_files
  log "Done: ${BUNDLE_DIR}"
}
main "$@"
