#!/usr/bin/env bash
# n8n 離線 bundle 準備腳本 (針對 Red Hat 9.x)
# 此腳本在具備網路連接的環境中執行，用於下載與打包 n8n、Node.js 及其 RPM 依賴項。

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUNDLE_NAME="n8n-offline-rhel9.6-x86_64"
DIST_ROOT="${DIST_ROOT:-${SCRIPT_DIR}/dist}"
BUNDLE_DIR="${BUNDLE_DIR:-${DIST_ROOT}/${BUNDLE_NAME}}"
# 用 Rocky Linux 9 (RHEL 9 二進位相容) 作為 prepare 容器映像。
# 改用 Rocky 的原因: 官方 UBI9 的 CodeReady Builder repo 是精簡版，
# 不含 createrepo_c；Rocky 的 AppStream 預設就有，且不需 RHEL 訂閱。
# 產出的 RPM 與 RHEL 9 / UBI9 / Alma 9 完全相容，install 端不受影響。
RHEL_IMAGE="rockylinux:9"
DOCKER_PLATFORM="linux/amd64"

NODE_VERSION="v22.22.2"
NODE_DIST="node-${NODE_VERSION}-linux-x64"
NODE_TARBALL="${NODE_DIST}.tar.xz"
NODE_URL="https://nodejs.org/dist/${NODE_VERSION}/${NODE_TARBALL}"
NODE_SHA256="88fd1ce767091fd8d4a99fdb2356e98c819f93f3b1f8663853a2dee9b438068a"

N8N_VERSION="2.17.7"
N8N_PREFIX_TARBALL="n8n-prefix-${N8N_VERSION}-node-${NODE_VERSION}-rhel9-x86_64.tar.xz"

# RPM 依賴包列表 (n8n 主機本身需要的系統套件；PostgreSQL server 由另一份 bundle 提供)
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

usage() {
  cat <<USAGE
用法: $0 [選項]

選項:
  --bundle-dir DIR      將生成的 bundle 寫入指定目錄。
  --skip-verify        跳過 Docker --network none 離線驗證。
  --keep-existing      保留現有的 bundle 目錄，而不是刪除後重建。
  --reuse-n8n-prefix   重複使用現有的 n8n 壓縮包與 npm 清單。
  -h, --help           顯示此幫助訊息。
USAGE
}

log() { printf '[prepare-online] %s\n' "$*"; }
die() { printf '[prepare-online] 錯誤: %s\n' "$*" >&2; exit 1; }
need_command() { command -v "$1" >/dev/null 2>&1 || die "找不到必要的命令: $1"; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
write_sha256_line() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"
  else shasum -a 256 "$1"; fi
}
verify_sha256() {
  local actual; actual="$(sha256_file "$2")"
  [[ "$actual" == "$1" ]] || die "$2 的校驗碼不符: 預期 $1，得到 $actual"
}

parse_args() {
  while (($#)); do
    case "$1" in
      --bundle-dir) shift; BUNDLE_DIR="$1" ;;
      --skip-verify) VERIFY_OFFLINE=0 ;;
      --keep-existing) KEEP_EXISTING=1 ;;
      --reuse-n8n-prefix) REUSE_N8N_PREFIX=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知選項: $1" ;;
    esac
    shift
  done
}

prepare_bundle_dir() {
  local bundle_parent bundle_base
  bundle_parent="$(dirname "$BUNDLE_DIR")"
  bundle_base="$(basename "$BUNDLE_DIR")"
  mkdir -p "$bundle_parent"
  BUNDLE_DIR="$(cd "$bundle_parent" && pwd)/${bundle_base}"
  if [[ "$KEEP_EXISTING" == "0" ]]; then rm -rf "$BUNDLE_DIR"; fi

  mkdir -p "$BUNDLE_DIR/rpm-repo"
  cp "${SCRIPT_DIR}/install-offline.sh" "$BUNDLE_DIR/install-offline.sh"
  chmod +x "$BUNDLE_DIR/install-offline.sh"
}

download_node() {
  local target="${BUNDLE_DIR}/${NODE_TARBALL}"
  if [[ -f "$target" ]] && [[ "$(sha256_file "$target")" == "$NODE_SHA256" ]]; then
    log "Node 壓縮包已存在且校驗正確"
    return
  fi
  rm -f "$target"
  log "正在下載 ${NODE_TARBALL}..."
  curl -fL --retry 3 --retry-delay 2 -o "${target}.tmp" "$NODE_URL"
  verify_sha256 "$NODE_SHA256" "${target}.tmp"
  mv "${target}.tmp" "$target"
}

build_dnf_repo() {
  log "正在下載 RHEL dnf 依賴項至本地倉庫..."

  docker run --rm -i --platform "$DOCKER_PLATFORM" -v "${BUNDLE_DIR}:/bundle" "$RHEL_IMAGE" bash -s -- "${DNF_SEED_PACKAGES[@]}" <<'IN_CONTAINER'
set -Eeuo pipefail

seed_packages=("$@")

# Rocky 9 預設啟用 BaseOS / AppStream / extras。
# createrepo_c 在 AppStream；GraphicsMagick 在 EPEL，需額外啟用。
dnf install -y dnf-plugins-core
dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
dnf install -y createrepo_c

rm -rf /bundle/rpm-repo
mkdir -p /bundle/rpm-repo

cd /bundle/rpm-repo
# 解析並下載所有依賴包
dnf download --resolve --alldeps "${seed_packages[@]}"

# 生成倉庫元數據
createrepo_c .

manifest_tmp=/bundle/rpm-packages.tsv.tmp
{
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

build_n8n_prefix() {
  log "正在建構 n8n@${N8N_VERSION} 的 /opt/n8n 預安裝包..."

  if [[ "$REUSE_N8N_PREFIX" == "1" && -s "${BUNDLE_DIR}/${N8N_PREFIX_TARBALL}" ]]; then
    log "重複使用現有的 ${N8N_PREFIX_TARBALL}"; return
  fi

  rm -f "${BUNDLE_DIR}/${N8N_PREFIX_TARBALL}" "${BUNDLE_DIR}/npm-packages.json"
  docker run --rm -i --platform "$DOCKER_PLATFORM" -v "${BUNDLE_DIR}:/bundle" "$RHEL_IMAGE" bash -s -- "$NODE_TARBALL" "$NODE_DIST" "$N8N_VERSION" "$N8N_PREFIX_TARBALL" <<'IN_CONTAINER'
set -Eeuo pipefail
node_tarball="$1"; node_dist="$2"; n8n_version="$3"; n8n_prefix_tarball="$4"

dnf install -y --allowerasing make gcc-c++ python3 xz tar curl

tar -xJf "/bundle/${node_tarball}" -C /opt
export PATH="/opt/${node_dist}/bin:/opt/n8n/bin:${PATH}"

mkdir -p /opt/n8n
npm config set fund false
npm config set audit false
npm install -g --prefix /opt/n8n "n8n@${n8n_version}" --omit=dev --no-audit --no-fund

npm ls --prefix /opt/n8n -g --all --json > /bundle/npm-packages.json || true
export XZ_OPT="${XZ_OPT:--T0}"
tar --numeric-owner --owner=0 --group=0 -C /opt -cJf "/bundle/${n8n_prefix_tarball}" n8n
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

write_checksums() {
  local tmp_file="${BUNDLE_DIR}/SHA256SUMS.tmp"
  log "正在生成 SHA256SUMS..."
  ( cd "$BUNDLE_DIR"
    while IFS= read -r file; do write_sha256_line "$file"; done < <(find . -type f ! -name SHA256SUMS ! -name SHA256SUMS.tmp -print | sed 's#^\./##' | LC_ALL=C sort)
  ) > "$tmp_file"
  mv "$tmp_file" "${BUNDLE_DIR}/SHA256SUMS"
}

verify_bundle_files() {
  log "正在驗證生成的 bundle 檔案..."
  [[ -s "${BUNDLE_DIR}/rpm-repo/repodata/repomd.xml" ]] || die "缺少 repodata"
  ( cd "$BUNDLE_DIR"
    if command -v sha256sum >/dev/null 2>&1; then sha256sum -c SHA256SUMS
    else shasum -a 256 -c SHA256SUMS; fi )
}

run_offline_verify() {
  [[ "$VERIFY_OFFLINE" == "1" ]] || return 0
  log "正在執行 Docker 離線驗證 (internal network + postgres:18 容器)..."
  "${SCRIPT_DIR}/verify-offline.sh" --bundle-dir "$BUNDLE_DIR"
}

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
  log "完成: ${BUNDLE_DIR}"
}
main "$@"