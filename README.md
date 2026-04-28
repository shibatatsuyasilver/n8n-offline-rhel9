# n8n + PostgreSQL 18 離線安裝套件 (Red Hat 9)

兩台離線 RHEL 9 主機的安裝方案：

```
┌──────────────────────────┐         ┌──────────────────────────────┐
│  RHEL host A — n8n       │ ──────▶ │  RHEL host B — PostgreSQL 18 │
│  systemd / n8n.service   │  5432   │  systemd / postgresql-18     │
│  /etc/n8n/n8n.env        │         │  /var/lib/pgsql/18/data      │
└──────────────────────────┘         └──────────────────────────────┘
```

兩台主機各自從一份獨立的離線 bundle 安裝；n8n 主機透過 `n8n.env` 內的 `DB_POSTGRESDB_*` 連到 PG 主機。安裝腳本不會跨主機操作，也不會自動建立 n8n 角色 / 資料庫，由管理員依照 `install-pg-offline.sh` 結束後的提示手動完成。

## 套件版本

| 元件 | 版本 |
|---|---|
| n8n | 2.17.7 |
| Node.js | v22.22.2 |
| PostgreSQL | 18 (PGDG yum repo) |
| 目標 OS | RHEL 9.x x86_64 |

完整 RPM 清單以各 bundle 內的 `rpm-packages.tsv` 為準。

## 檔案

- `prepare-online.sh` — 在連網主機產出 **n8n** bundle (`dist/n8n-offline-rhel9.6-x86_64/`)
- `install-offline.sh` — 自動拷貝進 n8n bundle，於離線 RHEL 9 host A 執行
- `prepare-pg-online.sh` — 在連網主機產出 **PostgreSQL 18** bundle (`dist/postgres-offline-rhel9-x86_64/`)
- `install-pg-offline.sh` — 自動拷貝進 PG bundle，於離線 RHEL 9 host B 執行
- `verify-offline.sh` — 在開發機用 `docker network --internal` 起 `postgres:18` + `ubi9` 跨容器跑一次 `install-offline.sh --verify-no-systemd`，端到端驗證

## 1. 取得 bundle

兩個選項：

### 1a. 直接下載預先建構好的 bundle（離線主機需要 RHEL 9.x / x86_64）

從 [Releases](https://github.com/shibatatsuyasilver/n8n-offline-rhel9/releases) 取得：

```bash
gh release download v0.1.0 -R shibatatsuyasilver/n8n-offline-rhel9
tar -xf n8n-offline-rhel9.6-x86_64.tar
tar -xf postgres-offline-rhel9-x86_64.tar
```

或用 curl 直接下載 asset URL。SHA-256 在 release notes 內。

### 1b. 自己從原始碼建構

需要：本機可用 `docker`（拉 rockylinux:9 / postgres:18 映像，並在容器內 `dnf download` / `npm install`）。

```bash
./prepare-online.sh        # → dist/n8n-offline-rhel9.6-x86_64/
./prepare-pg-online.sh     # → dist/postgres-offline-rhel9-x86_64/
```

`prepare-online.sh` 在最後會自動呼叫 `verify-offline.sh` 做端到端離線驗證。維護用旗標：

```bash
./prepare-online.sh --skip-verify
./prepare-online.sh --keep-existing --reuse-n8n-prefix
./prepare-pg-online.sh --keep-existing
```

## 2. 離線 host B：安裝 PostgreSQL 18

把 `dist/postgres-offline-rhel9-x86_64/` 拷貝到 RHEL 9 host B：

```bash
cd postgres-offline-rhel9-x86_64
sudo ./install-pg-offline.sh
```

腳本會：
- 從本地 RPM 倉庫安裝 `postgresql18-server` + `postgresql18-contrib` + `postgresql18`
- `postgresql-18-setup initdb` 初始化 datadir
- `systemctl enable --now postgresql-18`

**安裝完成後依腳本提示手動完成**：
1. `postgresql.conf` 設 `listen_addresses = '*'`
2. `pg_hba.conf` 加入 `host  n8n  n8n  <n8n_host_ip>/32  scram-sha-256`
3. `systemctl restart postgresql-18`
4. `sudo -u postgres psql -c "CREATE ROLE n8n LOGIN PASSWORD '<chosen-password>';"`
5. `sudo -u postgres createdb --owner=n8n n8n`

## 3. 離線 host A：安裝 n8n

把 `dist/n8n-offline-rhel9.6-x86_64/` 拷貝到 RHEL 9 host A，提供必填環境變數後執行：

```bash
cd n8n-offline-rhel9.6-x86_64
sudo N8N_DB_HOST='<host_b_ip>' \
     N8N_DB_PASSWORD='<chosen-password>' \
     ./install-offline.sh
```

必填環境變數：

| 變數 | 說明 |
|---|---|
| `N8N_DB_HOST` | host B 的 IP 或 DNS 名稱 |
| `N8N_DB_PASSWORD` | host B 上 `n8n` 角色的密碼 |

選填環境變數（皆有預設）：

| 變數 | 預設 |
|---|---|
| `N8N_DB_PORT` | `5432` |
| `N8N_DB_NAME` | `n8n` |
| `N8N_DB_USER` | `n8n` |
| `N8N_ENCRYPTION_KEY` | 自動產生 64 字元 hex |
| `N8N_PORT` | `5678` |
| `GENERIC_TIMEZONE` | `Asia/Taipei` |

腳本流程：預檢 → 從本地 RPM 倉庫裝系統套件 → 解壓 Node.js → 解壓 n8n prefix → 寫 `/etc/n8n/n8n.env` → **用 bundle 內附的 `pg` 模組驗證對 host B 的連線** → 安裝 systemd unit → `systemctl enable --now n8n` → `curl /healthz` 冒煙測試。

完成後 n8n 監聽在 `http://0.0.0.0:5678`。

## 4. 在開發機跨容器模擬驗證

`prepare-online.sh` 會自動呼叫；要單獨重跑：

```bash
./verify-offline.sh --bundle-dir dist/n8n-offline-rhel9.6-x86_64
```

機制：建立 `docker network create --internal`（無 internet 出口）→ `postgres:18` 容器 + `ubi9` 容器互連 → `ubi9` 內 mount bundle 跑 `install-offline.sh --verify-no-systemd`，模擬 host A 連到外部 PG。

注意：兩個映像必須**事先**已經 pull 到本地（腳本會處理），internal 網路內無法 pull。

### 雙 bundle 完整端到端驗證

把 `verify-offline.sh` 的 `postgres:18` 替換成「自家 PG bundle 也跑一次離線安裝」的完整版：

```bash
./verify-offline-full.sh
```

兩個 ubi9 容器，一個跑 `install-pg-offline.sh --verify-no-systemd`，另一個跑 `install-offline.sh --verify-no-systemd`，同 internal 網路互連。

## 5. 在 Docker 上實際運行（開發或試用）

如果想直接在開發機（macOS / Linux）跑起來試用 n8n 而不用真正的 RHEL 主機：

```bash
./run-stack.sh up        # 起 n8n + PG 兩個容器，n8n 公開到 :5678
./run-stack.sh status    # 看狀態
./run-stack.sh logs      # 跟 n8n log
./run-stack.sh down      # 停止 (volume 留著)
./run-stack.sh destroy   # 清空 (含 docker volume)
```

啟動後開瀏覽器到 `http://localhost:5678`。憑證 (`PG_PASSWORD`、`N8N_ENCRYPTION_KEY`) 寫在 `.stack-env`，重啟容器資料延續。

> **注意**：`.stack-env` 含密鑰與密碼，已在 `.gitignore`。若要分享環境，請各自產生新檔，不要把 `.stack-env` 推上版控。
