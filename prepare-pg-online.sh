#!/usr/bin/env bash
# PostgreSQL 18 offline bundle preparation script for Red Hat 9.x.
# Run this script on an online host to download PostgreSQL server, contrib,
# pgvector, and all RPM dependencies into a portable offline bundle.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PG_MAJOR="${PG_MAJOR:-18}"
PG_COMPAT_LIBURING_SPEC="${PG_COMPAT_LIBURING_SPEC:-liburing-2.12-1.el9.x86_64}"
PGADMIN4_VERSION="${PGADMIN4_VERSION:-9.15}"
PG_COMPAT_RPM_DIR="${PG_COMPAT_RPM_DIR:-}"

# Pin the preparation container and RPM source repos to the target RHEL minor
# release. Floating rockylinux:9 can roll forward to newer minor RPMs.
TARGET_RHEL_MINOR="${TARGET_RHEL_MINOR:-9.2}"
if [[ -z "${PGDG_RHEL_MINOR:-}" ]]; then
  minor_num="${TARGET_RHEL_MINOR##*.}"
  if [[ "$minor_num" -lt 6 ]]; then
    PGDG_RHEL_MINOR="9"
  else
    PGDG_RHEL_MINOR="${TARGET_RHEL_MINOR}"
  fi
fi
BUNDLE_NAME="${BUNDLE_NAME:-postgres-offline-rhel${TARGET_RHEL_MINOR}-x86_64}"
DIST_ROOT="${DIST_ROOT:-${SCRIPT_DIR}/dist}"
BUNDLE_DIR="${BUNDLE_DIR:-${DIST_ROOT}/${BUNDLE_NAME}}"
RHEL_IMAGE="${RHEL_IMAGE:-registry.access.redhat.com/ubi9/ubi:${TARGET_RHEL_MINOR}}"
ROCKY_VAULT_BASE="${ROCKY_VAULT_BASE:-https://download.rockylinux.org/vault/rocky/${TARGET_RHEL_MINOR}}"
PGADMIN_REPO_BASE="${PGADMIN_REPO_BASE:-https://ftp.postgresql.org/pub/pgadmin/pgadmin4/yum/redhat/rhel-${TARGET_RHEL_MINOR%%.*}-x86_64}"
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
  PG_COMPAT_LIBURING_SPEC
                     Exact UBI/RHEL liburing package used when Rocky 9.2 lacks liburing.so.2.
  PGADMIN4_VERSION   pgAdmin4 RPM version. Defaults to 9.15.
  PG_COMPAT_RPM_DIR  Optional directory containing previously vetted PG/pgvector/liburing RPMs.
  TARGET_RHEL_MINOR  Target RHEL minor release. Defaults to 9.2.
  RHEL_IMAGE         Preparation image. Defaults to UBI for TARGET_RHEL_MINOR.
  ROCKY_VAULT_BASE   Rocky vault base URL. Defaults to Rocky TARGET_RHEL_MINOR.
  PGDG_RHEL_MINOR    PGDG repo release. Defaults to 9 for RHEL 9.2.
  PGADMIN_REPO_BASE  pgAdmin4 RPM repo base URL. Defaults to official RHEL major repo.
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

  local target_minor="${TARGET_RHEL_MINOR##*.}"
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
  ' "$manifest" >&2; then
    die "RPM manifest contains packages from a newer RHEL release (> 9.${target_minor}); rebuild with target ${TARGET_RHEL_MINOR} repos"
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
  local docker_args=(
    --rm -i
    --platform "$DOCKER_PLATFORM"
    -v "${BUNDLE_DIR}:/bundle"
    -e PG_MAJOR="$PG_MAJOR"
    -e PG_COMPAT_LIBURING_SPEC="$PG_COMPAT_LIBURING_SPEC"
    -e PGADMIN4_VERSION="$PGADMIN4_VERSION"
    -e PGADMIN_REPO_BASE="$PGADMIN_REPO_BASE"
    -e PGDG_RHEL_MINOR="$PGDG_RHEL_MINOR"
    -e TARGET_RHEL_MINOR="$TARGET_RHEL_MINOR"
    -e ROCKY_VAULT_BASE="$ROCKY_VAULT_BASE"
  )
  if [[ -n "$PG_COMPAT_RPM_DIR" ]]; then
    [[ -d "$PG_COMPAT_RPM_DIR" ]] || die "PG_COMPAT_RPM_DIR is not a directory: $PG_COMPAT_RPM_DIR"
    PG_COMPAT_RPM_DIR="$(cd "$PG_COMPAT_RPM_DIR" && pwd)"
    docker_args+=(-v "${PG_COMPAT_RPM_DIR}:/pg-compat-rpms:ro" -e PG_COMPAT_RPM_DIR=/pg-compat-rpms)
  fi
  docker run "${docker_args[@]}" "$RHEL_IMAGE" bash -s <<'IN_CONTAINER'
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

[pgadmin4]
name=pgAdmin4 for RHEL ${TARGET_RHEL_MINOR%%.*}
baseurl=${PGADMIN_REPO_BASE}/
enabled=1
gpgcheck=0
REPO

dnf -qy --disablerepo='*' --enablerepo='rocky-*' module disable postgresql || true
dnf --disablerepo='*' --enablerepo='rocky-*' install -y dnf-plugins-core createrepo_c

rm -rf /bundle/rpm-repo
mkdir -p /bundle/rpm-repo
cd /bundle/rpm-repo

  limit_minor="${TARGET_RHEL_MINOR##*.}"

  package_requires_target_openssl() {
    local spec="$1"
    local limit="$2"
    local repos="${3:-pgdg-*}"
    if [[ "$limit" -le 2 ]] && dnf -q --disablerepo='*' --enablerepo="$repos" \
      repoquery --requires "$spec" 2>/dev/null | grep -Eq 'OPENSSL_3\.[1-9][0-9]*\.'; then
      return 1
    fi
    return 0
  }

  query_compat_candidates() {
    local pkg="$1"
    local limit="$2"
    local repos="${3:-pgdg-*}"
    dnf -q --disablerepo='*' --enablerepo="$repos" \
      repoquery --queryformat '%{VERSION}-%{RELEASE}\t%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' \
      --available --showduplicates "$pkg" 2>/dev/null | awk -v limit="$limit" -F'\t' '
        NF < 2 { next }
        {
          version = $1;
          compatible = 1;
          str = version;
          while (match(str, /el9_[0-9]+/)) {
            val = substr(str, RSTART + 4, RLENGTH - 4);
            if (val + 0 > limit) { compatible = 0; }
            str = substr(str, RSTART + RLENGTH);
          }
          str = version;
          while (match(str, /rhel9[._][0-9]+/)) {
            val = substr(str, RSTART + 6, RLENGTH - 6);
            if (val + 0 > limit) { compatible = 0; }
            str = substr(str, RSTART + RLENGTH);
          }
          if (compatible) { print $1 "\t" $2; }
        }
      ' | sort -t $'\t' -k1,1Vr
  }

  resolve_compat_pkg() {
    local pkg="$1"
    local limit="$2"
    local repos="${3:-pgdg-*}"
    local candidate version spec
    while IFS=$'\t' read -r version spec; do
      [[ -n "$version" && -n "$spec" ]] || continue
      if package_requires_target_openssl "$spec" "$limit" "$repos"; then
        printf '%s\t%s\n' "$version" "$spec"
        return 0
      fi
      printf 'Skipping %s because it requires newer OpenSSL symbols than RHEL 9.%s provides\n' "$spec" "$limit" >&2
    done < <(query_compat_candidates "$pkg" "$limit" "$repos")
    printf 'No RHEL 9.%s-compatible PGDG package found for %s\n' "$limit" "$pkg" >&2
    return 1
  }

  spec_for_pkg_version() {
    local pkg="$1"
    local version="$2"
    local limit="$3"
    local repos="${4:-pgdg-*}"
    local spec
    spec="$(query_compat_candidates "$pkg" "$limit" "$repos" | awk -F'\t' -v version="$version" '$1 == version { print $2; exit }')"
    if [[ -z "$spec" ]]; then
      printf 'No PGDG package found for %s version %s\n' "$pkg" "$version" >&2
      return 1
    fi
    if ! package_requires_target_openssl "$spec" "$limit" "$repos"; then
      printf '%s requires newer OpenSSL symbols than RHEL 9.%s provides\n' "$spec" "$limit" >&2
      return 1
    fi
    printf '%s\n' "$spec"
  }

  copy_compat_pkg_from_dir() {
    local pkg="$1"
    local found=""
    local rpm name
    [[ -d "${PG_COMPAT_RPM_DIR:-}" ]] || return 1
    while IFS= read -r rpm; do
      name="$(rpm -qp --nosignature --nodigest --queryformat '%{NAME}' "$rpm")"
      if [[ "$name" == "$pkg" ]]; then
        if [[ -n "$found" ]]; then
          printf 'Multiple RPMs for %s found in %s; keep exactly one compatible version\n' "$pkg" "$PG_COMPAT_RPM_DIR" >&2
          return 1
        fi
        found="$rpm"
      fi
    done < <(find "$PG_COMPAT_RPM_DIR" -maxdepth 1 -type f -name '*.rpm' | LC_ALL=C sort)
    [[ -n "$found" ]] || { printf 'No RPM for %s found in %s\n' "$pkg" "$PG_COMPAT_RPM_DIR" >&2; return 1; }
    cp "$found" "$pinned_repo/"
    rpm -qp --nosignature --nodigest --queryformat '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' "$found"
  }

  pinned_repo=/tmp/pgdg-pinned
  rm -rf "$pinned_repo"
  mkdir -p "$pinned_repo"

  if [[ -n "${PG_COMPAT_RPM_DIR:-}" ]]; then
    printf 'Using previously vetted PostgreSQL RPMs from %s\n' "$PG_COMPAT_RPM_DIR"
    pkg_server="$(copy_compat_pkg_from_dir "postgresql${PG_MAJOR}-server")"
    pkg_contrib="$(copy_compat_pkg_from_dir "postgresql${PG_MAJOR}-contrib")"
    pkg_client="$(copy_compat_pkg_from_dir "postgresql${PG_MAJOR}")"
    pkg_libs="$(copy_compat_pkg_from_dir "postgresql${PG_MAJOR}-libs")"
    pkg_vector="$(copy_compat_pkg_from_dir "pgvector_${PG_MAJOR}")"
    if [[ -n "${PG_COMPAT_LIBURING_SPEC:-}" ]]; then
      copy_compat_pkg_from_dir "liburing" >/dev/null
    fi
  else
    contrib_selection="$(resolve_compat_pkg "postgresql${PG_MAJOR}-contrib" "$limit_minor")"
    pg_core_version="${contrib_selection%%$'\t'*}"
    pkg_contrib="${contrib_selection#*$'\t'}"
    pkg_server="$(spec_for_pkg_version "postgresql${PG_MAJOR}-server" "$pg_core_version" "$limit_minor")"
    pkg_client="$(spec_for_pkg_version "postgresql${PG_MAJOR}" "$pg_core_version" "$limit_minor")"
    pkg_libs="$(spec_for_pkg_version "postgresql${PG_MAJOR}-libs" "$pg_core_version" "$limit_minor")"
    vector_selection="$(resolve_compat_pkg "pgvector_${PG_MAJOR}" "$limit_minor")"
    pkg_vector="${vector_selection#*$'\t'}"

    dnf --disablerepo='*' --enablerepo='pgdg-*' \
      download --destdir "$pinned_repo" \
      "$pkg_server" \
      "$pkg_contrib" \
      "$pkg_client" \
      "$pkg_libs" \
      "$pkg_vector"
    if [[ -n "${PG_COMPAT_LIBURING_SPEC:-}" ]]; then
      dnf --disablerepo='*' --enablerepo='ubi-9-appstream-rpms' \
        download --destdir "$pinned_repo" "$PG_COMPAT_LIBURING_SPEC"
    fi
  fi

  pgadmin_web_spec="pgadmin4-web-${PGADMIN4_VERSION}-1.el${TARGET_RHEL_MINOR%%.*}.noarch"
  pgadmin_server_spec="pgadmin4-server-${PGADMIN4_VERSION}-1.el${TARGET_RHEL_MINOR%%.*}.x86_64"
  libpq_selection="$(resolve_compat_pkg "libpq5" "$limit_minor" "pgadmin4")"
  pkg_libpq="${libpq_selection#*$'\t'}"

  printf 'Selected RHEL 9.%s-compatible PGDG package specs:\n' "$limit_minor"
  printf '  %s\n' "$pkg_server" "$pkg_contrib" "$pkg_client" "$pkg_libs" "$pkg_vector"
  printf 'Selected pgAdmin4 package specs:\n'
  printf '  %s\n' "$pgadmin_web_spec" "$pgadmin_server_spec" "$pkg_libpq"

  createrepo_c "$pinned_repo"

  pgadmin_pinned_repo=/tmp/pgadmin-pinned
  rm -rf "$pgadmin_pinned_repo"
  mkdir -p "$pgadmin_pinned_repo"
  dnf --disablerepo='*' --enablerepo='pgadmin4' \
    download --destdir "$pgadmin_pinned_repo" \
    "$pgadmin_web_spec" \
    "$pgadmin_server_spec" \
    "$pkg_libpq"
  createrepo_c "$pgadmin_pinned_repo"

  cat > /etc/yum.repos.d/pgdg-pinned.repo <<REPO
[pgdg-pinned]
name=Selected PostgreSQL ${PG_MAJOR} packages for RHEL ${TARGET_RHEL_MINOR}
baseurl=file://${pinned_repo}
enabled=1
gpgcheck=0

[pgadmin-pinned]
name=Selected pgAdmin4 ${PGADMIN4_VERSION} packages for RHEL ${TARGET_RHEL_MINOR}
baseurl=file://${pgadmin_pinned_repo}
enabled=1
gpgcheck=0
REPO

  dnf --disablerepo='*' \
    --enablerepo='rocky-*' \
    --enablerepo='pgdg-pinned' \
    --enablerepo='pgadmin-pinned' \
    --setopt=install_weak_deps=False \
    download --resolve --alldeps \
    "postgresql${PG_MAJOR}-server" \
    "postgresql${PG_MAJOR}-contrib" \
    "postgresql${PG_MAJOR}" \
    "postgresql${PG_MAJOR}-libs" \
    "pgvector_${PG_MAJOR}" \
    "pgadmin4-web" \
    "mod_ssl"

dnf --disablerepo='*' --enablerepo='ubi-9-appstream-rpms' \
  download --destdir /bundle/rpm-repo redhat-logos-httpd

# RHEL hosts already provide their own release identity packages.
rm -f rocky-gpg-keys-*.rpm rocky-release-*.rpm rocky-repos-*.rpm rocky-logos-*.rpm

createrepo_c .

manifest_tmp=/bundle/rpm-packages.tsv.tmp
{
  printf 'package\tversion\tarchitecture\tfilename\tsha256\n'
  for rpm in *.rpm; do
    package="$(rpm -qp --nosignature --nodigest --queryformat '%{NAME}' "$rpm")"
    version="$(rpm -qp --nosignature --nodigest --queryformat '%{VERSION}-%{RELEASE}' "$rpm")"
    architecture="$(rpm -qp --nosignature --nodigest --queryformat '%{ARCH}' "$rpm")"
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
PG_COMPAT_LIBURING_SPEC='${PG_COMPAT_LIBURING_SPEC}'
PG_COMPAT_RPM_DIR='${PG_COMPAT_RPM_DIR}'
PGADMIN4_VERSION='${PGADMIN4_VERSION}'
PGADMIN_REPO_BASE='${PGADMIN_REPO_BASE}'
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
