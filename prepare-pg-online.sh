#!/usr/bin/env bash
# PostgreSQL 18 離線 bundle 準備腳本 (針對 Red Hat 9.x)
# 在具備網路的主機上以 ubi9 容器加載 PGDG 倉庫，下載 postgresql18-server / contrib
# 與其全部 RPM 依賴，產出可拷貝至離線 RHEL 9 主機的 bundle 目錄。

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PG_MAJOR="${PG_MAJOR:-18}"
BUNDLE_NAME="postgres-offline-rhel9-x86_64"
DIST_ROOT="${DIST_ROOT:-${SCRIPT_DIR}/dist}"
BUNDLE_DIR="${BUNDLE_DIR:-${DIST_ROOT}/${BUNDLE_NAME}}"

# 用 Rocky Linux 9 (RHEL 9 二進位相容)；UBI9 的 CRB 是精簡版不含 createrepo_c。
RHEL_IMAGE="rockylinux:9"
DOCKER_PLATFORM="linux/amd64"

KEEP_EXISTING=0

usage() {
  cat <<USAGE
用法: $0 [選項]

選項:
  --bundle-dir DIR   將生成的 bundle 寫入指定目錄
  --keep-existing    保留現有的 bundle 目錄，不刪除後重建
  -h, --help         顯示此幫助訊息

環境變數:
  PG_MAJOR           PostgreSQL 主版本 (預設 18)
USAGE
}

log() { printf '[prepare-pg-online] %s\n' "$*"; }
die() { printf '[prepare-pg-online] 錯誤: %s\n' "$*" >&2; exit 1; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
write_sha256_line() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"
  else shasum -a 256 "$1"; fi
}

parse_args() {
  while (($#)); do
    case "$1" in
      --bundle-dir) shift; BUNDLE_DIR="$1" ;;
      --keep-existing) KEEP_EXISTING=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知選項: $1" ;;
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
  log "在 ubi9 容器內下載 PostgreSQL ${PG_MAJOR} 與依賴 RPM..."
  docker run --rm -i --platform "$DOCKER_PLATFORM" \
    -v "${BUNDLE_DIR}:/bundle" \
    -e PG_MAJOR="$PG_MAJOR" \
    "$RHEL_IMAGE" bash -s <<'IN_CONTAINER'
set -Eeuo pipefail

dnf install -y "https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
dnf -qy module disable postgresql || true
dnf install -y dnf-plugins-core createrepo_c

rm -rf /bundle/rpm-repo
mkdir -p /bundle/rpm-repo
cd /bundle/rpm-repo

dnf download --resolve --alldeps \
  "postgresql${PG_MAJOR}-server" \
  "postgresql${PG_MAJOR}-contrib" \
  "postgresql${PG_MAJOR}"

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
  local created_at; created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  cat > "${BUNDLE_DIR}/manifest.env" <<MANIFEST
BUNDLE_NAME='${BUNDLE_NAME}'
TARGET_OS_ID='rhel'
TARGET_VERSION_ID='9'
TARGET_ARCH='x86_64'
DOCKER_PREP_IMAGE='${RHEL_IMAGE}'
DOCKER_PLATFORM='${DOCKER_PLATFORM}'
PG_MAJOR='${PG_MAJOR}'
RPM_REPO_DIR='rpm-repo'
RPM_PACKAGES_MANIFEST='rpm-packages.tsv'
CREATED_AT_UTC='${created_at}'
MANIFEST
}

write_checksums() {
  log "生成 SHA256SUMS..."
  local tmp_file="${BUNDLE_DIR}/SHA256SUMS.tmp"
  ( cd "$BUNDLE_DIR"
    while IFS= read -r file; do write_sha256_line "$file"; done < <(find . -type f ! -name SHA256SUMS ! -name SHA256SUMS.tmp -print | sed 's#^\./##' | LC_ALL=C sort)
  ) > "$tmp_file"
  mv "$tmp_file" "${BUNDLE_DIR}/SHA256SUMS"
}

verify_bundle_files() {
  log "驗證 bundle 檔案..."
  [[ -s "${BUNDLE_DIR}/rpm-repo/repodata/repomd.xml" ]] || die "缺少 repodata"
  ( cd "$BUNDLE_DIR"
    if command -v sha256sum >/dev/null 2>&1; then sha256sum -c SHA256SUMS
    else shasum -a 256 -c SHA256SUMS; fi )
}

main() {
  parse_args "$@"
  command -v docker >/dev/null 2>&1 || die "找不到 docker"
  [[ -f "${SCRIPT_DIR}/install-pg-offline.sh" ]] || die "找不到 install-pg-offline.sh"
  prepare_bundle_dir
  build_dnf_repo
  write_manifest
  write_checksums
  verify_bundle_files
  log "完成: ${BUNDLE_DIR}"
}
main "$@"
