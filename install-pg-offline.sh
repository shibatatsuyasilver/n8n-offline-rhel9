#!/usr/bin/env bash
# PostgreSQL 18 離線安裝腳本 (針對 Red Hat 9.x)
# 在離線 RHEL 9 主機從本地 RPM 倉庫安裝 PostgreSQL 18，初始化 datadir 並啟動 systemd 服務。
# 預設不會自動建立 n8n 角色 / 資料庫，也不修改 listen_addresses / pg_hba.conf —
# 安裝完成後依腳本最後輸出的提示手動完成。
#
# --verify-no-systemd 模式 (供 docker 端到端驗證使用)：
#   會自動配置 listen_addresses='*' + pg_hba 允許遠端 scram-sha-256，
#   並建立 n8n role / database (需提供 N8N_DB_PASSWORD)，
#   最後以 postgres 使用者前景執行 PG 讓容器持續存活。

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$SCRIPT_DIR"
VERIFY_NO_SYSTEMD=0

usage() {
  cat <<USAGE
用法: $0 [選項]

選項:
  --bundle-dir DIR        使用指定的 DIR 作為離線 bundle 目錄
  --verify-no-systemd     驗證模式（適用於沒有 systemd 的 Docker 容器）
                          需要環境變數 N8N_DB_PASSWORD
  -h, --help              顯示此幫助訊息
USAGE
}

log() { printf '[install-pg-offline] %s\n' "$*"; }
die() { printf '[install-pg-offline] 錯誤: %s\n' "$*" >&2; exit 1; }
need_root() { [[ "$(id -u)" == "0" ]] || die "請以 root 權限執行"; }
need_command() { command -v "$1" >/dev/null 2>&1 || die "找不到必要的命令: $1"; }

parse_args() {
  while (($#)); do
    case "$1" in
      --bundle-dir) shift; BUNDLE_DIR="$1" ;;
      --verify-no-systemd) VERIFY_NO_SYSTEMD=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知選項: $1" ;;
    esac
    shift
  done
}

load_manifest() {
  BUNDLE_DIR="$(cd "$BUNDLE_DIR" && pwd)"
  local manifest="${BUNDLE_DIR}/manifest.env"
  [[ -f "$manifest" ]] || die "找不到 bundle 清單文件: $manifest"
  # shellcheck disable=SC1090
  source "$manifest"
  PG_DATA="/var/lib/pgsql/${PG_MAJOR}/data"
  PG_BIN="/usr/pgsql-${PG_MAJOR}/bin"
}

preflight() {
  log "執行預檢..."
  [[ -r /etc/os-release ]] || die "無法讀取 /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release

  if [[ "${ID:-}" != "$TARGET_OS_ID" && "${ID_LIKE:-}" != *"$TARGET_OS_ID"* ]]; then
    die "預期作業系統為 RHEL 家族，但目前為 ${ID:-unknown}"
  fi
  local major_version="${VERSION_ID%%.*}"
  [[ "$major_version" == "$TARGET_VERSION_ID" ]] || die "預期 RHEL 主版本為 ${TARGET_VERSION_ID}，但目前為 ${VERSION_ID:-unknown}"
  [[ "$(uname -m)" == "$TARGET_ARCH" ]] || die "預期架構為 ${TARGET_ARCH}，但目前為 $(uname -m)"

  if [[ "$VERIFY_NO_SYSTEMD" == "0" ]]; then
    need_command systemctl
    [[ -d /run/systemd/system ]] || die "systemd 並未在運行中"
  fi

  [[ -d "${BUNDLE_DIR}/${RPM_REPO_DIR}" ]] || die "找不到 rpm 倉庫目錄"
  log "驗證 bundle 檔案校驗碼..."
  ( cd "$BUNDLE_DIR"; sha256sum -c SHA256SUMS )
}

install_rpm_packages() {
  log "從本地離線倉庫安裝 PostgreSQL ${PG_MAJOR}..."
  cat > /etc/yum.repos.d/postgres-offline.repo <<REPO
[postgres-offline]
name=PostgreSQL ${PG_MAJOR} Offline Packages
baseurl=file://${BUNDLE_DIR}/${RPM_REPO_DIR}
enabled=1
gpgcheck=0
REPO

  dnf --disablerepo='*' --enablerepo='postgres-offline' install -y --allowerasing \
    "postgresql${PG_MAJOR}-server" \
    "postgresql${PG_MAJOR}-contrib" \
    "postgresql${PG_MAJOR}" \
    "pgvector_${PG_MAJOR}"
}

initdb_only() {
  if [[ -d "${PG_DATA}/base" ]]; then
    log "datadir 已存在，跳過 initdb"
    return 0
  fi
  log "初始化 datadir: ${PG_DATA}"
  if [[ "$VERIFY_NO_SYSTEMD" == "1" ]]; then
    # postgresql-N-setup 會透過 systemctl 讀 PGDATA，無 systemd 時失敗 → 直接呼叫 initdb。
    install -d -o postgres -g postgres -m 0700 "$(dirname "$PG_DATA")"
    su - postgres -c "${PG_BIN}/initdb -D ${PG_DATA} --auth-local=peer --auth-host=scram-sha-256 --encoding=UTF8"
  else
    "${PG_BIN}/postgresql-${PG_MAJOR}-setup" initdb
  fi
}

start_pg_systemd() {
  systemctl enable --now "postgresql-${PG_MAJOR}"
}

configure_for_remote() {
  log "配置 listen_addresses 與 pg_hba 允許遠端連線 (verify mode)..."
  if ! grep -q "^listen_addresses" "${PG_DATA}/postgresql.conf"; then
    echo "listen_addresses = '*'" >> "${PG_DATA}/postgresql.conf"
  else
    sed -i "s/^listen_addresses.*/listen_addresses = '*'/" "${PG_DATA}/postgresql.conf"
  fi
  if ! grep -qE '^host\s+all\s+all\s+0\.0\.0\.0/0' "${PG_DATA}/pg_hba.conf"; then
    cat >> "${PG_DATA}/pg_hba.conf" <<HBA
host  all  all  0.0.0.0/0  scram-sha-256
host  all  all  ::/0       scram-sha-256
HBA
  fi
  chown postgres:postgres "${PG_DATA}/postgresql.conf" "${PG_DATA}/pg_hba.conf"
}

start_pg_no_systemd_bg() {
  log "在背景以 pg_ctl 啟動 PG..."
  install -d -o postgres -g postgres -m 0700 "${PG_DATA}/log"
  su - postgres -c "${PG_BIN}/pg_ctl -D ${PG_DATA} -l ${PG_DATA}/log/startup.log start"
  for _ in $(seq 1 30); do
    if su - postgres -c "${PG_BIN}/pg_isready -q"; then
      log "PG 已就緒"
      return 0
    fi
    sleep 1
  done
  die "PG 未在 30 秒內就緒"
}

bootstrap_n8n_db() {
  : "${N8N_DB_PASSWORD:?--verify-no-systemd 模式需要 N8N_DB_PASSWORD}"
  local pw_escaped pw
  pw_escaped="$(printf '%s' "$N8N_DB_PASSWORD" | sed "s/'/''/g")"
  pw="'${pw_escaped}'"
  log "建立 / 更新 n8n role 與 database (idempotent)..."
  if su - postgres -c "${PG_BIN}/psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='n8n'\"" | grep -q 1; then
    su - postgres -c "${PG_BIN}/psql -v ON_ERROR_STOP=1 -c \"ALTER ROLE n8n WITH LOGIN PASSWORD ${pw};\""
  else
    su - postgres -c "${PG_BIN}/psql -v ON_ERROR_STOP=1 -c \"CREATE ROLE n8n LOGIN PASSWORD ${pw};\""
  fi
  if ! su - postgres -c "${PG_BIN}/psql -tAc \"SELECT 1 FROM pg_database WHERE datname='n8n'\"" | grep -q 1; then
    su - postgres -c "${PG_BIN}/createdb --owner=n8n n8n"
  fi
}

enable_pgvector_in_n8n_db() {
  log "在 n8n DB 啟用 pgvector 擴充 (idempotent)..."
  su - postgres -c "${PG_BIN}/psql -v ON_ERROR_STOP=1 -d n8n -c 'CREATE EXTENSION IF NOT EXISTS vector;'"
}

stop_pg_no_systemd() {
  log "停止背景 PG 以便切換為前景模式..."
  su - postgres -c "${PG_BIN}/pg_ctl -D ${PG_DATA} stop -m fast" || true
}

exec_pg_foreground() {
  log "以 postgres 使用者前景執行 PG (容器持續存活)..."
  exec su - postgres -c "${PG_BIN}/postgres -D ${PG_DATA}"
}

print_post_install_hint() {
  cat <<MSG

[install-pg-offline] PostgreSQL ${PG_MAJOR} 已啟動於 5432 (預設僅監聽 localhost)。
                     設定檔位置：${PG_DATA}/

下一步請手動完成以下設定，才能讓 n8n 主機連入：

  1. 編輯 ${PG_DATA}/postgresql.conf 把 #listen_addresses = 'localhost'
     註解打開，改成只 listen 內網介面 (避免用 '*'，會無差別接受所有來源)：

       listen_addresses = 'localhost,<host_b_internal_ip>'

  2. 編輯 ${PG_DATA}/pg_hba.conf 加入只允許 n8n host 的規則：

       host  n8n  n8n  <n8n_host_ip>/32  scram-sha-256

  3. 重啟服務：

       sudo systemctl restart postgresql-${PG_MAJOR}

  4. 建 n8n 角色 (用 \\password 互動式輸入，避免密碼進 shell history)：

       sudo -u postgres ${PG_BIN}/psql -c "CREATE ROLE n8n LOGIN;"
       sudo -u postgres ${PG_BIN}/psql -c "\\password n8n"

  5. 建 n8n 資料庫：

       sudo -u postgres ${PG_BIN}/createdb --owner=n8n n8n

  6. 在 n8n 資料庫啟用 pgvector：

       sudo -u postgres ${PG_BIN}/psql -d n8n -c 'CREATE EXTENSION IF NOT EXISTS vector;'

  7. 驗證 listen 範圍：

       ss -ltn | grep 5432
       sudo -u postgres ${PG_BIN}/psql -c "SHOW listen_addresses;"

  8. 在 n8n 主機執行 install-offline.sh 時提供：

       N8N_DB_HOST=<this_host_ip>
       N8N_DB_PASSWORD=<上一步設的密碼>
MSG
}

main() {
  parse_args "$@"
  need_root
  need_command sha256sum
  load_manifest
  preflight
  install_rpm_packages
  initdb_only

  if [[ "$VERIFY_NO_SYSTEMD" == "0" ]]; then
    start_pg_systemd
    print_post_install_hint
  else
    configure_for_remote
    start_pg_no_systemd_bg
    bootstrap_n8n_db
    enable_pgvector_in_n8n_db
    stop_pg_no_systemd
    exec_pg_foreground   # 不返回
  fi
}
main "$@"
