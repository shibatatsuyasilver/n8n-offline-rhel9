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

## 套件清單

> 以下為當前 bundle 版本（n8n 2.17.7 / PostgreSQL 18）的快照；重新打 bundle 後請以 `rpm-packages.tsv` / `npm-packages.json` 為準。

### n8n bundle (`dist/n8n-offline-rhel9.6-x86_64/`)

#### Node.js 執行環境

- Node.js v22.22.2 — 來源 tarball `node-v22.22.2-linux-x64.tar.xz`

#### RPM 套件（198 個，含遞移相依）

直接安裝（seed，由 `prepare-online.sh` 指定）：`ca-certificates`, `tzdata`, `curl`, `openssl`, `git`, `GraphicsMagick`, `fontconfig`, `xz`

完整清單（依字母排序）：

```
GraphicsMagick, alternatives, audit-libs, basesystem, bash, bzip2-libs,
ca-certificates, coreutils, coreutils-common, cracklib, cracklib-dicts,
crypto-policies, curl, cyrus-sasl-lib, dejavu-sans-fonts, emacs-filesystem,
expat, filesystem, findutils, fontconfig, fonts-filesystem, freetype,
gawk, gawk-all-langpacks, gdbm-libs, git, git-core, git-core-doc, glib2,
glibc, glibc-common, glibc-gconv-extra, glibc-minimal-langpack, gmp,
gnutls, graphite2, grep, groff-base, gzip, harfbuzz, jasper-libs,
jbigkit-libs, keyutils-libs, krb5-libs, langpacks-core-font-en, lcms2,
less, libICE, libSM, libX11, libX11-common, libXau, libXext, libacl,
libattr, libblkid, libbrotli, libcap, libcap-ng, libcbor, libcom_err,
libcurl, libdb, libeconf, libedit, libevent, libfdisk, libffi, libfido2,
libgcc, libgcrypt, libgomp, libgpg-error, libidn2, libjpeg-turbo,
libmount, libnghttp2, libpng, libpsl, libpwquality, libselinux,
libsemanage, libsepol, libsigsegv, libsmartcols, libssh, libssh-config,
libstdc++, libtasn1, libtiff, libtool-ltdl, libunistring, libutempter,
libuuid, libverto, libwebp, libwmf-lite, libxcb, libxcrypt, libxml2,
libzstd, lz4-libs, mpfr, ncurses, ncurses-base, ncurses-libs, nettle,
openldap, openssh, openssh-clients, openssl, openssl-fips-provider,
openssl-libs, p11-kit, p11-kit-trust, pam, pcre, pcre2, pcre2-syntax,
perl-AutoLoader, perl-B, perl-Carp, perl-Class-Struct, perl-Data-Dumper,
perl-Digest, perl-Digest-MD5, perl-DynaLoader, perl-Encode, perl-Errno,
perl-Error, perl-Exporter, perl-Fcntl, perl-File-Basename, perl-File-Find,
perl-File-Path, perl-File-Temp, perl-File-stat, perl-FileHandle,
perl-Getopt-Long, perl-Getopt-Std, perl-Git, perl-HTTP-Tiny, perl-IO,
perl-IO-Socket-IP, perl-IO-Socket-SSL, perl-IPC-Open3, perl-MIME-Base64,
perl-Mozilla-CA, perl-NDBM_File, perl-Net-SSLeay, perl-POSIX,
perl-PathTools, perl-Pod-Escapes, perl-Pod-Perldoc, perl-Pod-Simple,
perl-Pod-Usage, perl-Scalar-List-Utils, perl-SelectSaver, perl-Socket,
perl-Storable, perl-Symbol, perl-Term-ANSIColor, perl-Term-Cap,
perl-TermReadKey, perl-Text-ParseWords, perl-Text-Tabs+Wrap,
perl-Time-Local, perl-URI, perl-base, perl-constant, perl-if,
perl-interpreter, perl-lib, perl-libnet, perl-libs, perl-mro,
perl-overload, perl-overloading, perl-parent, perl-podlators, perl-subs,
perl-vars, publicsuffix-list-dafsa, readline, rocky-gpg-keys,
rocky-release, rocky-repos, sed, setup, shadow-utils, systemd-libs,
tzdata, util-linux, util-linux-core, xml-common, xz, xz-libs, zlib
```

#### npm 套件（n8n@2.17.7 的 114 個 top-level 直接相依）

| 套件 | 版本 |
|---|---|
| @1password/connect | 1.4.2 |
| @ai-sdk/anthropic | 2.0.61 |
| @apidevtools/json-schema-ref-parser | 12.0.2 |
| @aws-sdk/client-secrets-manager | 3.808.0 |
| @azure/identity | 4.13.0 |
| @azure/keyvault-secrets | 4.8.0 |
| @google-cloud/secret-manager | 5.6.0 |
| @modelcontextprotocol/sdk | 1.26.0 |
| @n8n/ai-node-sdk | 0.8.0 |
| @n8n/ai-utilities | 0.11.0 |
| @n8n/ai-workflow-builder | 1.17.3 |
| @n8n/api-types | 1.17.3 |
| @n8n/backend-common | 1.17.3 |
| @n8n/chat-hub | 1.10.3 |
| @n8n/client-oauth2 | 1.1.1 |
| @n8n/config | 2.16.0 |
| @n8n/constants | 0.21.1 |
| @n8n/db | 1.17.3 |
| @n8n/decorators | 1.17.3 |
| @n8n/di | 0.10.0 |
| @n8n/errors | 0.7.0 |
| @n8n/instance-ai | 1.2.3 |
| @n8n/n8n-nodes-langchain | 2.17.4 |
| @n8n/permissions | 0.56.0 |
| @n8n/syslog-client | 1.2.0 |
| @n8n/task-runner | 2.17.3 |
| @n8n/typeorm | 0.3.20-16 |
| @n8n/utils | 1.28.1 |
| @n8n/workflow-sdk | 0.10.2 |
| @n8n_io/ai-assistant-sdk | 1.21.0 |
| @n8n_io/license-sdk | 2.25.0 |
| @opentelemetry/api | 1.9.1 |
| @opentelemetry/exporter-trace-otlp-proto | 0.213.0 |
| @opentelemetry/instrumentation | 0.213.0 |
| @opentelemetry/resources | 2.7.0 |
| @opentelemetry/sdk-node | 0.213.0 |
| @opentelemetry/sdk-trace-node | 2.7.0 |
| @opentelemetry/semantic-conventions | 1.40.0 |
| @parcel/watcher | 2.5.6 |
| @rudderstack/rudder-sdk-node | 3.0.0 |
| @sentry/node | 10.50.0 |
| aws4 | 1.11.0 |
| axios | 1.15.0 |
| bcryptjs | 2.4.3 |
| bull | 4.16.4 |
| cache-manager | 5.2.3 |
| change-case | 4.1.2 |
| class-transformer | 0.5.1 |
| class-validator | 0.14.0 |
| compression | 1.8.1 |
| convict | 6.2.5 |
| cookie-parser | 1.4.7 |
| csrf | 3.1.0 |
| dotenv | 17.2.3 |
| express | 5.1.0 |
| express-handlebars | 8.0.1 |
| express-openapi-validator | 5.5.3 |
| express-prom-bundle | 8.0.0 |
| express-rate-limit | 7.5.0 |
| fast-glob | 3.2.12 |
| flat | 5.0.2 |
| flatted | 3.4.2 |
| formidable | 3.5.4 |
| handlebars | 4.7.9 |
| helmet | 8.1.0 |
| http-proxy-middleware | 3.0.5 |
| infisical-node | 1.3.0 |
| ioredis | 5.3.2 |
| isbot | 3.6.13 |
| json-diff | 1.0.6 |
| jsonschema | 1.4.1 |
| jsonwebtoken | 9.0.3 |
| ldapts | 4.2.6 |
| lodash | 4.18.1 |
| luxon | 3.7.2 |
| n8n-core | 2.17.3 |
| n8n-editor-ui | 2.17.6 |
| n8n-nodes-base | 2.17.3 |
| n8n-workflow | 2.17.2 |
| nanoid | 3.3.8 |
| nodemailer | 7.0.11 |
| oauth-1.0a | 2.2.6 |
| open | 7.4.2 |
| openid-client | 6.5.0 |
| otpauth | 9.1.1 |
| p-cancelable | 2.1.1 |
| p-lazy | 3.1.0 |
| pg | 8.17.0 |
| picocolors | 1.0.1 |
| pkce-challenge | 5.0.0 |
| posthog-node | 3.2.1 |
| prom-client | 15.1.3 |
| psl | 1.9.0 |
| raw-body | 3.0.0 |
| reflect-metadata | 0.2.2 |
| replacestream | 4.0.3 |
| samlify | 2.10.0 |
| semver | 7.5.4 |
| shelljs | 0.8.5 |
| simple-git | 3.32.3 |
| source-map-support | 0.5.21 |
| sqlite3 | 5.1.7 |
| sshpk | 1.18.0 |
| swagger-ui-express | 5.0.1 |
| undici | 7.25.0 |
| uuid | 10.0.0 |
| validator | 13.15.22 |
| ws | 8.17.1 |
| xml2js | 0.6.2 |
| xmllint-wasm | 3.0.1 |
| xss | 1.0.15 |
| yaml | 2.8.2 |
| yargs-parser | 21.1.1 |
| zod | 3.25.67 |

### PostgreSQL bundle (`dist/postgres-offline-rhel9-x86_64/`)

**PostgreSQL 版本**：18（PGDG yum repo，安裝為 18.3-1PGDG.rhel9.7）

#### RPM 套件（167 個，含遞移相依）

直接安裝（seed，由 `prepare-pg-online.sh` 指定）：`postgresql18-server`, `postgresql18-contrib`, `postgresql18`

完整清單（依字母排序）：

```
acl, alternatives, audit-libs, basesystem, bash, bzip2-libs,
ca-certificates, coreutils, coreutils-common, cracklib, cracklib-dicts,
crypto-policies, cyrus-sasl-lib, dbus, dbus-broker, dbus-common, expat,
filesystem, findutils, gawk, gawk-all-langpacks, gdbm-libs, glibc,
glibc-common, glibc-gconv-extra, glibc-minimal-langpack, gmp, grep,
groff-base, gzip, keyutils-libs, kmod-libs, krb5-libs, libacl, libattr,
libblkid, libcap, libcap-ng, libcom_err, libdb, libeconf, libevent,
libfdisk, libffi, libgcc, libgcrypt, libgpg-error, libicu, libmount,
libpwquality, libseccomp, libselinux, libsemanage, libsepol, libsigsegv,
libsmartcols, libstdc++, libtasn1, libtool-ltdl, liburing, libutempter,
libuuid, libverto, libxcrypt, libxcrypt-compat, libxml2, libxslt,
libzstd, lz4-libs, mpfr, ncurses, ncurses-base, ncurses-libs,
numactl-libs, openldap, openssl, openssl-fips-provider, openssl-libs,
p11-kit, p11-kit-trust, pam, pcre, pcre2, pcre2-syntax, perl-AutoLoader,
perl-B, perl-Carp, perl-Class-Struct, perl-Data-Dumper, perl-Digest,
perl-Digest-MD5, perl-Encode, perl-Errno, perl-Exporter, perl-Fcntl,
perl-File-Basename, perl-File-Path, perl-File-Temp, perl-File-stat,
perl-FileHandle, perl-Getopt-Long, perl-Getopt-Std, perl-HTTP-Tiny,
perl-IO, perl-IO-Socket-IP, perl-IO-Socket-SSL, perl-IPC-Open3,
perl-MIME-Base64, perl-Mozilla-CA, perl-NDBM_File, perl-Net-SSLeay,
perl-POSIX, perl-PathTools, perl-Pod-Escapes, perl-Pod-Perldoc,
perl-Pod-Simple, perl-Pod-Usage, perl-Scalar-List-Utils, perl-SelectSaver,
perl-Socket, perl-Storable, perl-Symbol, perl-Term-ANSIColor,
perl-Term-Cap, perl-Text-ParseWords, perl-Text-Tabs+Wrap, perl-Time-Local,
perl-URI, perl-base, perl-constant, perl-if, perl-interpreter,
perl-libnet, perl-libs, perl-mro, perl-overload, perl-overloading,
perl-parent, perl-podlators, perl-subs, perl-vars, postgresql18,
postgresql18-contrib, postgresql18-libs, postgresql18-server,
python-unversioned-command, python3, python3-libs, python3-pip-wheel,
python3-setuptools-wheel, readline, rocky-gpg-keys, rocky-release,
rocky-repos, sed, setup, shadow-utils, sqlite-libs, systemd, systemd-libs,
systemd-pam, systemd-rpm-macros, tzdata, util-linux, util-linux-core,
xz-libs, zlib
```

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
