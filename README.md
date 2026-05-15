# n8n + PostgreSQL 18 離線安裝套件 (Red Hat 9)

兩台離線 RHEL 9 主機的安裝方案：

```
┌──────────────────────────────┐       ┌──────────────────────────────┐
│  RHEL host A — nginx + n8n   │ ────▶ │  RHEL host B — PostgreSQL 18 │
│  HTTPS 443 → 127.0.0.1:5678  │ 5432  │  systemd / postgresql-18     │
│  /etc/n8n/n8n.env + tls cert │       │  /var/lib/pgsql/18/data      │
└──────────────────────────────┘       └──────────────────────────────┘
```

兩台主機各自從一份獨立的離線 bundle 安裝；n8n 主機透過 `n8n.env` 內的 `DB_POSTGRESDB_*` 連到 PG 主機。安裝腳本不會跨主機操作，也不會自動建立 n8n 角色 / 資料庫，由管理員依照 `install-pg-offline.sh` 結束後的提示手動完成。

## 套件版本

| 元件 | 版本 |
|---|---|
| n8n | 2.17.7 |
| Node.js | v22.22.2 |
| PostgreSQL | 18 (PGDG yum repo) |
| pgvector | PGDG `pgvector_18` (安裝後在 n8n DB 自動 `CREATE EXTENSION vector`) |
| 目標 OS | RHEL 9.x x86_64 |

完整 RPM 清單以各 bundle 內的 `rpm-packages.tsv` 為準。

## 套件清單

> 以下為當前 bundle 版本（n8n 2.17.7 / PostgreSQL 18）的快照；重新打 bundle 後請以 `rpm-packages.tsv` / `npm-packages.json` 為準。

### n8n bundle (`dist/n8n-offline-rhel9.6-x86_64/`)

#### Node.js 執行環境

- Node.js v22.22.2 — 來源 tarball `node-v22.22.2-linux-x64.tar.xz`

#### RPM 套件（241 個 RPM 檔，213 個套件名稱，含遞移相依）

直接安裝（seed，由 `prepare-online.sh` 指定）：`ca-certificates`, `tzdata`, `curl`, `openssl`, `git`, `GraphicsMagick`, `fontconfig`, `xz`, `nginx`

套件名稱清單（依字母排序；版本、架構、檔名與 SHA-256 以 bundle 內 `rpm-packages.tsv` 為準）：

| 套件 | 用途 |
|---|---|
| GraphicsMagick | 影像轉換與處理工具 |
| acl | 檔案 ACL 權限工具 |
| alternatives | 管理系統替代命令連結 |
| audit-libs | Linux audit 稽核程式庫 |
| basesystem | Rocky/RHEL 基礎系統定義 |
| bash | Shell 指令執行環境 |
| bzip2-libs | bzip2 壓縮格式程式庫 |
| ca-certificates | 信任根憑證集合 |
| coreutils | 基本檔案與文字命令 |
| coreutils-common | coreutils 共用資料檔 |
| cracklib | 密碼強度檢查程式庫 |
| cracklib-dicts | 密碼檢查字典資料 |
| crypto-policies | 系統加密政策設定 |
| curl | HTTP/HTTPS 下載與測試工具 |
| cyrus-sasl-lib | SASL 認證支援程式庫 |
| dbus | 系統服務訊息匯流排 |
| dbus-broker | D-Bus 訊息代理服務 |
| dbus-common | D-Bus 共用設定檔 |
| dejavu-sans-fonts | DejaVu Sans 字型 |
| emacs-filesystem | Emacs 套件目錄結構 |
| expat | XML 解析程式庫 |
| filesystem | 基本檔案系統目錄 |
| findutils | 檔案搜尋工具 |
| fontconfig | 字型探索與設定工具 |
| fonts-filesystem | 系統字型目錄結構 |
| freetype | 字型渲染程式庫 |
| gawk | AWK 文字處理工具 |
| gawk-all-langpacks | gawk 多語系支援資料 |
| gdbm-libs | GNU dbm 資料庫程式庫 |
| git | Git 版本控制工具 |
| git-core | Git 核心命令 |
| git-core-doc | Git 文件頁面 |
| glib2 | GLib 基礎工具程式庫 |
| glibc | GNU C 標準程式庫 |
| glibc-common | glibc 共用資料與工具 |
| glibc-gconv-extra | glibc 額外字元轉換模組 |
| glibc-minimal-langpack | glibc 最小語系資料 |
| gmp | 任意精度數學程式庫 |
| gnutls | TLS/SSL 加密通訊程式庫 |
| graphite2 | Graphite 字型排版程式庫 |
| grep | 文字搜尋工具 |
| groff-base | man page 排版工具 |
| gzip | gzip 壓縮工具 |
| harfbuzz | OpenType 文字塑形程式庫 |
| jasper-libs | JPEG-2000 影像程式庫 |
| jbigkit-libs | JBIG 影像壓縮程式庫 |
| keyutils-libs | Linux keyring 程式庫 |
| kmod-libs | Kernel module 管理程式庫 |
| krb5-libs | Kerberos 認證程式庫 |
| langpacks-core-font-en | 英文核心字型支援 |
| lcms2 | 色彩管理程式庫 |
| less | 終端分頁檢視工具 |
| libICE | X11 ICE 連線程式庫 |
| libSM | X11 session 管理程式庫 |
| libX11 | X11 用戶端程式庫 |
| libX11-common | X11 共用資料檔 |
| libXau | X11 授權程式庫 |
| libXext | X11 擴充程式庫 |
| libacl | ACL 權限程式庫 |
| libattr | 延伸屬性程式庫 |
| libblkid | 區塊裝置識別程式庫 |
| libbrotli | Brotli 壓縮程式庫 |
| libcap | Linux capability 程式庫 |
| libcap-ng | Capability 管理程式庫 |
| libcbor | CBOR 編碼程式庫 |
| libcom_err | 通用錯誤處理程式庫 |
| libcurl | curl 用戶端程式庫 |
| libdb | Berkeley DB 程式庫 |
| libeconf | 設定檔解析程式庫 |
| libedit | 命令列編輯程式庫 |
| libevent | 事件通知程式庫 |
| libfdisk | 磁碟分割程式庫 |
| libffi | 外部函式介面程式庫 |
| libfido2 | FIDO2/WebAuthn 程式庫 |
| libgcc | GCC 執行時期程式庫 |
| libgcrypt | 通用加密程式庫 |
| libgomp | OpenMP 執行時期程式庫 |
| libgpg-error | GnuPG 錯誤碼程式庫 |
| libidn2 | 國際化網域名稱程式庫 |
| libjpeg-turbo | JPEG 影像編解碼程式庫 |
| libmount | 檔案系統掛載程式庫 |
| libnghttp2 | HTTP/2 通訊程式庫 |
| libpng | PNG 影像程式庫 |
| libpsl | Public Suffix List 程式庫 |
| libpwquality | 密碼品質檢查程式庫 |
| libseccomp | 系統呼叫過濾程式庫 |
| libselinux | SELinux 執行時期程式庫 |
| libsemanage | SELinux 政策管理程式庫 |
| libsepol | SELinux 政策程式庫 |
| libsigsegv | 記憶體錯誤處理程式庫 |
| libsmartcols | 表格輸出格式程式庫 |
| libssh | SSH 通訊程式庫 |
| libssh-config | libssh 系統設定 |
| libstdc++ | C++ 標準程式庫 |
| libtasn1 | ASN.1 解析程式庫 |
| libtiff | TIFF 影像程式庫 |
| libtool-ltdl | 動態載入模組程式庫 |
| libunistring | Unicode 字串處理程式庫 |
| libutempter | 終端登入記錄程式庫 |
| libuuid | UUID 產生與解析程式庫 |
| libverto | 事件迴圈抽象程式庫 |
| libwebp | WebP 影像程式庫 |
| libwmf-lite | WMF 影像格式程式庫 |
| libxcb | X11 C Binding 程式庫 |
| libxcrypt | 密碼雜湊程式庫 |
| libxml2 | XML 解析程式庫 |
| libzstd | Zstandard 壓縮程式庫 |
| logrotate | 日誌輪替管理工具 |
| lz4-libs | LZ4 壓縮程式庫 |
| mpfr | 高精度浮點數程式庫 |
| ncurses | 終端文字介面工具 |
| ncurses-base | 終端能力資料庫 |
| ncurses-libs | 終端控制程式庫 |
| nettle | 低階加密程式庫 |
| nginx | HTTPS 反向代理服務 |
| nginx-core | nginx 核心服務程式 |
| nginx-filesystem | nginx 目錄與使用者設定 |
| openldap | LDAP 用戶端程式庫 |
| openssh | SSH 基礎工具 |
| openssh-clients | SSH 用戶端工具 |
| openssl | TLS/SSL 憑證與加密工具 |
| openssl-fips-provider | OpenSSL FIPS 加密模組 |
| openssl-libs | OpenSSL 執行時期程式庫 |
| p11-kit | PKCS#11 模組管理 |
| p11-kit-trust | 系統信任憑證整合 |
| pam | PAM 身分驗證模組 |
| pcre | Perl 相容正規表示式庫 |
| pcre2 | PCRE2 正規表示式庫 |
| pcre2-syntax | PCRE2 語法文件 |
| perl-AutoLoader | Perl 延遲載入模組 |
| perl-B | Perl 編譯器後端模組 |
| perl-Carp | Perl 錯誤回報模組 |
| perl-Class-Struct | Perl 結構類別模組 |
| perl-Data-Dumper | Perl 資料序列化模組 |
| perl-Digest | Perl digest 基礎模組 |
| perl-Digest-MD5 | Perl MD5 雜湊模組 |
| perl-DynaLoader | Perl 動態載入模組 |
| perl-Encode | Perl 字元編碼模組 |
| perl-Errno | Perl 系統錯誤碼模組 |
| perl-Error | Perl 例外處理模組 |
| perl-Exporter | Perl 符號匯出模組 |
| perl-Fcntl | Perl 檔案控制模組 |
| perl-File-Basename | Perl 路徑名稱處理模組 |
| perl-File-Find | Perl 檔案搜尋模組 |
| perl-File-Path | Perl 目錄建立刪除模組 |
| perl-File-Temp | Perl 暫存檔模組 |
| perl-File-stat | Perl 檔案狀態模組 |
| perl-FileHandle | Perl 檔案控制代碼模組 |
| perl-Getopt-Long | Perl 長參數解析模組 |
| perl-Getopt-Std | Perl 標準參數解析模組 |
| perl-Git | Git 的 Perl 整合模組 |
| perl-HTTP-Tiny | Perl 輕量 HTTP 用戶端 |
| perl-IO | Perl 輸入輸出模組 |
| perl-IO-Socket-IP | Perl IP socket 模組 |
| perl-IO-Socket-SSL | Perl SSL socket 模組 |
| perl-IPC-Open3 | Perl 子程序通訊模組 |
| perl-MIME-Base64 | Perl Base64 編解碼模組 |
| perl-Mozilla-CA | Perl Mozilla CA 憑證 |
| perl-NDBM_File | Perl NDBM 檔案模組 |
| perl-Net-SSLeay | Perl OpenSSL 綁定模組 |
| perl-POSIX | Perl POSIX 介面模組 |
| perl-PathTools | Perl 路徑工具模組 |
| perl-Pod-Escapes | Perl POD escape 模組 |
| perl-Pod-Perldoc | Perl 文件檢視工具 |
| perl-Pod-Simple | Perl POD 解析模組 |
| perl-Pod-Usage | Perl usage 文件模組 |
| perl-Scalar-List-Utils | Perl scalar/list 工具模組 |
| perl-SelectSaver | Perl select 狀態保存模組 |
| perl-Socket | Perl socket 網路模組 |
| perl-Storable | Perl 資料持久化模組 |
| perl-Symbol | Perl symbol 操作模組 |
| perl-Term-ANSIColor | Perl 終端色彩模組 |
| perl-Term-Cap | Perl 終端能力模組 |
| perl-TermReadKey | Perl 終端按鍵讀取模組 |
| perl-Text-ParseWords | Perl shell 文字解析模組 |
| perl-Text-Tabs+Wrap | Perl 文字縮排換行模組 |
| perl-Time-Local | Perl 本地時間轉換模組 |
| perl-URI | Perl URI 解析模組 |
| perl-base | Perl 基礎模組集合 |
| perl-constant | Perl 常數宣告模組 |
| perl-if | Perl 條件載入模組 |
| perl-interpreter | Perl 執行環境 |
| perl-lib | Perl 函式庫路徑支援 |
| perl-libnet | Perl 網路協定模組 |
| perl-libs | Perl 核心程式庫 |
| perl-mro | Perl 方法解析順序模組 |
| perl-overload | Perl 運算子重載模組 |
| perl-overloading | Perl 重載控制模組 |
| perl-parent | Perl 父類別宣告模組 |
| perl-podlators | Perl POD 轉換工具 |
| perl-subs | Perl 子程序預宣告模組 |
| perl-vars | Perl 全域變數宣告模組 |
| popt | 命令列選項解析程式庫 |
| publicsuffix-list-dafsa | 網域後綴清單資料 |
| readline | 互動式命令列編輯庫 |
| rocky-gpg-keys | Rocky Linux 套件簽章金鑰 |
| rocky-logos-httpd | Rocky HTTPD 預設頁素材 |
| rocky-release | Rocky Linux 發行版資訊 |
| rocky-repos | Rocky Linux yum repo 設定 |
| sed | 串流文字編輯工具 |
| setup | 系統基礎設定檔 |
| shadow-utils | 系統帳號管理工具 |
| systemd | 系統服務管理器 |
| systemd-libs | systemd 共用程式庫 |
| systemd-pam | systemd PAM 整合模組 |
| systemd-rpm-macros | systemd RPM 打包巨集 |
| tzdata | 時區資料 |
| util-linux | Linux 系統管理工具集 |
| util-linux-core | util-linux 核心工具 |
| xml-common | XML 共用目錄資料 |
| xz | xz 壓縮工具 |
| xz-libs | xz 壓縮程式庫 |
| zlib | zlib 壓縮程式庫 |

#### npm 套件（n8n@2.17.7 的 114 個 top-level 直接相依）

| 套件 | 版本 | 用途 |
|---|---|---|
| @1password/connect | 1.4.2 | 整合 1Password Connect 秘密管理 |
| @ai-sdk/anthropic | 2.0.61 | Anthropic AI 模型串接 |
| @apidevtools/json-schema-ref-parser | 12.0.2 | 解析 JSON Schema 參照 |
| @aws-sdk/client-secrets-manager | 3.808.0 | 串接 AWS Secrets Manager |
| @azure/identity | 4.13.0 | Azure 身分驗證 |
| @azure/keyvault-secrets | 4.8.0 | 串接 Azure Key Vault 秘密 |
| @google-cloud/secret-manager | 5.6.0 | 串接 Google Secret Manager |
| @modelcontextprotocol/sdk | 1.26.0 | MCP 伺服器與客戶端 SDK |
| @n8n/ai-node-sdk | 0.8.0 | n8n AI 節點 SDK |
| @n8n/ai-utilities | 0.11.0 | n8n AI 共用工具 |
| @n8n/ai-workflow-builder | 1.17.3 | AI 工作流程建構功能 |
| @n8n/api-types | 1.17.3 | n8n API 型別定義 |
| @n8n/backend-common | 1.17.3 | n8n 後端共用元件 |
| @n8n/chat-hub | 1.10.3 | n8n 聊天功能整合 |
| @n8n/client-oauth2 | 1.1.1 | OAuth2 用戶端支援 |
| @n8n/config | 2.16.0 | n8n 設定管理 |
| @n8n/constants | 0.21.1 | n8n 共用常數 |
| @n8n/db | 1.17.3 | n8n 資料庫層 |
| @n8n/decorators | 1.17.3 | n8n 裝飾器工具 |
| @n8n/di | 0.10.0 | n8n 依賴注入容器 |
| @n8n/errors | 0.7.0 | n8n 錯誤型別 |
| @n8n/instance-ai | 1.2.3 | n8n 執行個體 AI 功能 |
| @n8n/n8n-nodes-langchain | 2.17.4 | LangChain 節點套件 |
| @n8n/permissions | 0.56.0 | n8n 權限模型 |
| @n8n/syslog-client | 1.2.0 | Syslog 日誌傳送 |
| @n8n/task-runner | 2.17.3 | n8n 任務執行器 |
| @n8n/typeorm | 0.3.20-16 | n8n 客製 TypeORM |
| @n8n/utils | 1.28.1 | n8n 共用工具 |
| @n8n/workflow-sdk | 0.10.2 | n8n 工作流程 SDK |
| @n8n_io/ai-assistant-sdk | 1.21.0 | n8n AI 助理 SDK |
| @n8n_io/license-sdk | 2.25.0 | n8n 授權驗證 SDK |
| @opentelemetry/api | 1.9.1 | OpenTelemetry API 介面 |
| @opentelemetry/exporter-trace-otlp-proto | 0.213.0 | OTLP trace 匯出器 |
| @opentelemetry/instrumentation | 0.213.0 | OpenTelemetry 自動儀表化 |
| @opentelemetry/resources | 2.7.0 | Telemetry 資源描述 |
| @opentelemetry/sdk-node | 0.213.0 | Node.js telemetry SDK |
| @opentelemetry/sdk-trace-node | 2.7.0 | Node.js trace SDK |
| @opentelemetry/semantic-conventions | 1.40.0 | Telemetry 語意慣例 |
| @parcel/watcher | 2.5.6 | 檔案變更監看 |
| @rudderstack/rudder-sdk-node | 3.0.0 | RudderStack 事件追蹤 |
| @sentry/node | 10.50.0 | Sentry 錯誤監控 |
| aws4 | 1.11.0 | AWS Signature v4 簽章 |
| axios | 1.15.0 | HTTP 用戶端 |
| bcryptjs | 2.4.3 | 密碼雜湊處理 |
| bull | 4.16.4 | Redis 佇列處理 |
| cache-manager | 5.2.3 | 快取管理抽象層 |
| change-case | 4.1.2 | 字串命名格式轉換 |
| class-transformer | 0.5.1 | 物件與類別轉換 |
| class-validator | 0.14.0 | 類別驗證規則 |
| compression | 1.8.1 | HTTP 回應壓縮 |
| convict | 6.2.5 | 設定結構與驗證 |
| cookie-parser | 1.4.7 | Express cookie 解析 |
| csrf | 3.1.0 | CSRF token 產生驗證 |
| dotenv | 17.2.3 | 載入環境變數檔 |
| express | 5.1.0 | HTTP API 服務框架 |
| express-handlebars | 8.0.1 | Handlebars 視圖引擎 |
| express-openapi-validator | 5.5.3 | OpenAPI 請求驗證 |
| express-prom-bundle | 8.0.0 | Express Prometheus 指標 |
| express-rate-limit | 7.5.0 | API rate limit 防護 |
| fast-glob | 3.2.12 | 檔案樣式快速搜尋 |
| flat | 5.0.2 | 物件扁平化處理 |
| flatted | 3.4.2 | 循環 JSON 序列化 |
| formidable | 3.5.4 | 表單與檔案上傳解析 |
| handlebars | 4.7.9 | 樣板渲染引擎 |
| helmet | 8.1.0 | HTTP 安全標頭 |
| http-proxy-middleware | 3.0.5 | HTTP 代理中介層 |
| infisical-node | 1.3.0 | Infisical 秘密管理整合 |
| ioredis | 5.3.2 | Redis 用戶端 |
| isbot | 3.6.13 | 搜尋引擎 bot 偵測 |
| json-diff | 1.0.6 | JSON 差異比較 |
| jsonschema | 1.4.1 | JSON Schema 驗證 |
| jsonwebtoken | 9.0.3 | JWT 簽發與驗證 |
| ldapts | 4.2.6 | LDAP 用戶端 |
| lodash | 4.18.1 | 常用資料處理工具 |
| luxon | 3.7.2 | 日期時間處理 |
| n8n-core | 2.17.3 | n8n 核心執行功能 |
| n8n-editor-ui | 2.17.6 | n8n 編輯器前端 |
| n8n-nodes-base | 2.17.3 | n8n 內建節點 |
| n8n-workflow | 2.17.2 | n8n 工作流程模型 |
| nanoid | 3.3.8 | 短唯一 ID 產生 |
| nodemailer | 7.0.11 | SMTP 郵件寄送 |
| oauth-1.0a | 2.2.6 | OAuth 1.0a 簽章 |
| open | 7.4.2 | 開啟系統瀏覽器或檔案 |
| openid-client | 6.5.0 | OpenID Connect 用戶端 |
| otpauth | 9.1.1 | TOTP/HOTP 驗證 |
| p-cancelable | 2.1.1 | 可取消 Promise |
| p-lazy | 3.1.0 | 延遲執行 Promise |
| pg | 8.17.0 | PostgreSQL 用戶端驅動 |
| picocolors | 1.0.1 | 終端彩色輸出 |
| pkce-challenge | 5.0.0 | OAuth PKCE challenge 產生 |
| posthog-node | 3.2.1 | PostHog 事件追蹤 |
| prom-client | 15.1.3 | Prometheus 指標收集 |
| psl | 1.9.0 | Public Suffix List 解析 |
| raw-body | 3.0.0 | HTTP raw body 讀取 |
| reflect-metadata | 0.2.2 | 裝飾器 metadata 支援 |
| replacestream | 4.0.3 | 串流文字替換 |
| samlify | 2.10.0 | SAML 身分驗證支援 |
| semver | 7.5.4 | 語意版本解析 |
| shelljs | 0.8.5 | Shell 命令工具 |
| simple-git | 3.32.3 | Git 操作封裝 |
| source-map-support | 0.5.21 | Source map 堆疊追蹤 |
| sqlite3 | 5.1.7 | SQLite 資料庫驅動 |
| sshpk | 1.18.0 | SSH 金鑰解析 |
| swagger-ui-express | 5.0.1 | Swagger UI 路由 |
| undici | 7.25.0 | 高效能 HTTP 用戶端 |
| uuid | 10.0.0 | UUID 產生與解析 |
| validator | 13.15.22 | 字串驗證工具 |
| ws | 8.17.1 | WebSocket 用戶端與伺服器 |
| xml2js | 0.6.2 | XML 與 JS 物件轉換 |
| xmllint-wasm | 3.0.1 | WASM XML 驗證工具 |
| xss | 1.0.15 | HTML XSS 過濾 |
| yaml | 2.8.2 | YAML 解析與輸出 |
| yargs-parser | 21.1.1 | CLI 參數解析 |
| zod | 3.25.67 | TypeScript schema 驗證 |

### PostgreSQL bundle (`dist/postgres-offline-rhel9-x86_64/`)

**PostgreSQL 版本**：18（PGDG yum repo，安裝為 18.3-1PGDG.rhel9.7）

#### RPM 套件（168 個，含遞移相依）

直接安裝（seed，由 `prepare-pg-online.sh` 指定）：`postgresql18-server`, `postgresql18-contrib`, `postgresql18`, `pgvector_18`

套件名稱清單（依字母排序；版本、架構、檔名與 SHA-256 以 bundle 內 `rpm-packages.tsv` 為準）：

| 套件 | 用途 |
|---|---|
| acl | 檔案 ACL 權限工具 |
| alternatives | 管理系統替代命令連結 |
| audit-libs | Linux audit 稽核程式庫 |
| basesystem | Rocky/RHEL 基礎系統定義 |
| bash | Shell 指令執行環境 |
| bzip2-libs | bzip2 壓縮格式程式庫 |
| ca-certificates | 信任根憑證集合 |
| coreutils | 基本檔案與文字命令 |
| coreutils-common | coreutils 共用資料檔 |
| cracklib | 密碼強度檢查程式庫 |
| cracklib-dicts | 密碼檢查字典資料 |
| crypto-policies | 系統加密政策設定 |
| cyrus-sasl-lib | SASL 認證支援程式庫 |
| dbus | 系統服務訊息匯流排 |
| dbus-broker | D-Bus 訊息代理服務 |
| dbus-common | D-Bus 共用設定檔 |
| expat | XML 解析程式庫 |
| filesystem | 基本檔案系統目錄 |
| findutils | 檔案搜尋工具 |
| gawk | AWK 文字處理工具 |
| gawk-all-langpacks | gawk 多語系支援資料 |
| gdbm-libs | GNU dbm 資料庫程式庫 |
| glibc | GNU C 標準程式庫 |
| glibc-common | glibc 共用資料與工具 |
| glibc-gconv-extra | glibc 額外字元轉換模組 |
| glibc-minimal-langpack | glibc 最小語系資料 |
| gmp | 任意精度數學程式庫 |
| grep | 文字搜尋工具 |
| groff-base | man page 排版工具 |
| gzip | gzip 壓縮工具 |
| keyutils-libs | Linux keyring 程式庫 |
| kmod-libs | Kernel module 管理程式庫 |
| krb5-libs | Kerberos 認證程式庫 |
| libacl | ACL 權限程式庫 |
| libattr | 延伸屬性程式庫 |
| libblkid | 區塊裝置識別程式庫 |
| libcap | Linux capability 程式庫 |
| libcap-ng | Capability 管理程式庫 |
| libcom_err | 通用錯誤處理程式庫 |
| libdb | Berkeley DB 程式庫 |
| libeconf | 設定檔解析程式庫 |
| libevent | 事件通知程式庫 |
| libfdisk | 磁碟分割程式庫 |
| libffi | 外部函式介面程式庫 |
| libgcc | GCC 執行時期程式庫 |
| libgcrypt | 通用加密程式庫 |
| libgpg-error | GnuPG 錯誤碼程式庫 |
| libicu | Unicode 與國際化程式庫 |
| libmount | 檔案系統掛載程式庫 |
| libpwquality | 密碼品質檢查程式庫 |
| libseccomp | 系統呼叫過濾程式庫 |
| libselinux | SELinux 執行時期程式庫 |
| libsemanage | SELinux 政策管理程式庫 |
| libsepol | SELinux 政策程式庫 |
| libsigsegv | 記憶體錯誤處理程式庫 |
| libsmartcols | 表格輸出格式程式庫 |
| libstdc++ | C++ 標準程式庫 |
| libtasn1 | ASN.1 解析程式庫 |
| libtool-ltdl | 動態載入模組程式庫 |
| liburing | Linux io_uring 程式庫 |
| libutempter | 終端登入記錄程式庫 |
| libuuid | UUID 產生與解析程式庫 |
| libverto | 事件迴圈抽象程式庫 |
| libxcrypt | 密碼雜湊程式庫 |
| libxcrypt-compat | 舊版密碼雜湊相容庫 |
| libxml2 | XML 解析程式庫 |
| libxslt | XSLT 轉換程式庫 |
| libzstd | Zstandard 壓縮程式庫 |
| lz4-libs | LZ4 壓縮程式庫 |
| mpfr | 高精度浮點數程式庫 |
| ncurses | 終端文字介面工具 |
| ncurses-base | 終端能力資料庫 |
| ncurses-libs | 終端控制程式庫 |
| numactl-libs | NUMA 記憶體控制程式庫 |
| openldap | LDAP 用戶端程式庫 |
| openssl | TLS/SSL 憑證與加密工具 |
| openssl-fips-provider | OpenSSL FIPS 加密模組 |
| openssl-libs | OpenSSL 執行時期程式庫 |
| p11-kit | PKCS#11 模組管理 |
| p11-kit-trust | 系統信任憑證整合 |
| pam | PAM 身分驗證模組 |
| pcre | Perl 相容正規表示式庫 |
| pcre2 | PCRE2 正規表示式庫 |
| pcre2-syntax | PCRE2 語法文件 |
| perl-AutoLoader | Perl 延遲載入模組 |
| perl-B | Perl 編譯器後端模組 |
| perl-Carp | Perl 錯誤回報模組 |
| perl-Class-Struct | Perl 結構類別模組 |
| perl-Data-Dumper | Perl 資料序列化模組 |
| perl-Digest | Perl digest 基礎模組 |
| perl-Digest-MD5 | Perl MD5 雜湊模組 |
| perl-Encode | Perl 字元編碼模組 |
| perl-Errno | Perl 系統錯誤碼模組 |
| perl-Exporter | Perl 符號匯出模組 |
| perl-Fcntl | Perl 檔案控制模組 |
| perl-File-Basename | Perl 路徑名稱處理模組 |
| perl-File-Path | Perl 目錄建立刪除模組 |
| perl-File-Temp | Perl 暫存檔模組 |
| perl-File-stat | Perl 檔案狀態模組 |
| perl-FileHandle | Perl 檔案控制代碼模組 |
| perl-Getopt-Long | Perl 長參數解析模組 |
| perl-Getopt-Std | Perl 標準參數解析模組 |
| perl-HTTP-Tiny | Perl 輕量 HTTP 用戶端 |
| perl-IO | Perl 輸入輸出模組 |
| perl-IO-Socket-IP | Perl IP socket 模組 |
| perl-IO-Socket-SSL | Perl SSL socket 模組 |
| perl-IPC-Open3 | Perl 子程序通訊模組 |
| perl-MIME-Base64 | Perl Base64 編解碼模組 |
| perl-Mozilla-CA | Perl Mozilla CA 憑證 |
| perl-NDBM_File | Perl NDBM 檔案模組 |
| perl-Net-SSLeay | Perl OpenSSL 綁定模組 |
| perl-POSIX | Perl POSIX 介面模組 |
| perl-PathTools | Perl 路徑工具模組 |
| perl-Pod-Escapes | Perl POD escape 模組 |
| perl-Pod-Perldoc | Perl 文件檢視工具 |
| perl-Pod-Simple | Perl POD 解析模組 |
| perl-Pod-Usage | Perl usage 文件模組 |
| perl-Scalar-List-Utils | Perl scalar/list 工具模組 |
| perl-SelectSaver | Perl select 狀態保存模組 |
| perl-Socket | Perl socket 網路模組 |
| perl-Storable | Perl 資料持久化模組 |
| perl-Symbol | Perl symbol 操作模組 |
| perl-Term-ANSIColor | Perl 終端色彩模組 |
| perl-Term-Cap | Perl 終端能力模組 |
| perl-Text-ParseWords | Perl shell 文字解析模組 |
| perl-Text-Tabs+Wrap | Perl 文字縮排換行模組 |
| perl-Time-Local | Perl 本地時間轉換模組 |
| perl-URI | Perl URI 解析模組 |
| perl-base | Perl 基礎模組集合 |
| perl-constant | Perl 常數宣告模組 |
| perl-if | Perl 條件載入模組 |
| perl-interpreter | Perl 執行環境 |
| perl-libnet | Perl 網路協定模組 |
| perl-libs | Perl 核心程式庫 |
| perl-mro | Perl 方法解析順序模組 |
| perl-overload | Perl 運算子重載模組 |
| perl-overloading | Perl 重載控制模組 |
| perl-parent | Perl 父類別宣告模組 |
| perl-podlators | Perl POD 轉換工具 |
| perl-subs | Perl 子程序預宣告模組 |
| perl-vars | Perl 全域變數宣告模組 |
| pgvector_18 | PostgreSQL 向量搜尋擴充 |
| postgresql18 | PostgreSQL 18 用戶端工具 |
| postgresql18-contrib | PostgreSQL 18 擴充模組 |
| postgresql18-libs | PostgreSQL 18 共用程式庫 |
| postgresql18-server | PostgreSQL 18 伺服器 |
| python-unversioned-command | 提供未帶版本的 python 命令 |
| python3 | Python 3 執行環境 |
| python3-libs | Python 3 標準程式庫 |
| python3-pip-wheel | pip 安裝工具 wheel |
| python3-setuptools-wheel | setuptools 建置工具 wheel |
| readline | 互動式命令列編輯庫 |
| rocky-gpg-keys | Rocky Linux 套件簽章金鑰 |
| rocky-release | Rocky Linux 發行版資訊 |
| rocky-repos | Rocky Linux yum repo 設定 |
| sed | 串流文字編輯工具 |
| setup | 系統基礎設定檔 |
| shadow-utils | 系統帳號管理工具 |
| sqlite-libs | SQLite 資料庫程式庫 |
| systemd | 系統服務管理器 |
| systemd-libs | systemd 共用程式庫 |
| systemd-pam | systemd PAM 整合模組 |
| systemd-rpm-macros | systemd RPM 打包巨集 |
| tzdata | 時區資料 |
| util-linux | Linux 系統管理工具集 |
| util-linux-core | util-linux 核心工具 |
| xz-libs | xz 壓縮程式庫 |
| zlib | zlib 壓縮程式庫 |

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
- 從本地 RPM 倉庫安裝 `postgresql18-server` + `postgresql18-contrib` + `postgresql18` + `pgvector_18`
- `postgresql-18-setup initdb` 初始化 datadir
- `systemctl enable --now postgresql-18`

**安裝完成後依腳本提示手動完成**（設定檔位置：`/var/lib/pgsql/18/data/`）：

1. 編輯 `postgresql.conf`，把 `#listen_addresses = 'localhost'` 註解打開，改成**只 listen 內網介面**（避免用 `'*'`，會無差別接受所有來源）：

   ```conf
   listen_addresses = 'localhost,<host_b_internal_ip>'
   ```

2. 編輯 `pg_hba.conf`，加入只允許 n8n host 的規則：

   ```conf
   host  n8n  n8n  <n8n_host_ip>/32  scram-sha-256
   ```

3. 重啟服務：

   ```bash
   sudo systemctl restart postgresql-18
   ```

4. 建 n8n 角色（用 `\password` 互動式輸入，**避免密碼進 shell history**）：

   ```bash
   sudo -u postgres psql -c "CREATE ROLE n8n LOGIN;"
   sudo -u postgres psql -c "\password n8n"
   ```

5. 建 n8n 資料庫：

   ```bash
   sudo -u postgres createdb --owner=n8n n8n
   ```

6. 啟用 pgvector：

   ```bash
   sudo -u postgres psql -d n8n -c 'CREATE EXTENSION IF NOT EXISTS vector;'
   ```

7. 驗證 listen 範圍：

   ```bash
   ss -ltn | grep 5432
   sudo -u postgres psql -c "SHOW listen_addresses;"
   ```

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
| `N8N_PORT` | `5678`（僅綁 127.0.0.1，由 nginx 反代） |
| `GENERIC_TIMEZONE` | `Asia/Taipei` |
| `N8N_TLS_HOSTNAME` | `hostname -f`（寫入 self-signed cert CN/SAN 與 `N8N_HOST`） |
| `N8N_TLS_EXTRA_IP` | 自動偵測主預設路由 IP（加進 cert SAN） |
| `N8N_TLS_DAYS` | `3650` |
| `N8N_HTTPS_PORT` | `443` |

腳本流程：預檢 → 從本地 RPM 倉庫裝系統套件（含 nginx） → 解壓 Node.js → 解壓 n8n prefix → 寫 `/etc/n8n/n8n.env` → **用 bundle 內附的 `pg` 模組驗證對 host B 的連線** → 產生 self-signed 憑證 (`/etc/n8n/tls/server.{crt,key}`) → 寫 nginx 反代設定 (`/etc/nginx/conf.d/n8n.conf`) → `nginx -t` → 設定 SELinux (`httpd_can_network_connect`) + firewalld (開 `N8N_HTTPS_PORT`) → 安裝 systemd unit → `systemctl enable --now nginx n8n` → `curl -k https://127.0.0.1:${N8N_HTTPS_PORT}/healthz` 冒煙測試。

完成後 n8n 在 `https://<host>/` 上線；若 `N8N_HTTPS_PORT` 不是 `443`，入口與 `WEBHOOK_URL` 會是 `https://<host>:<port>/`。nginx 會反代到內部 `127.0.0.1:5678`。

> **第一次連線會出現瀏覽器憑證警告**，因為是 self-signed。可選：
> - 直接在瀏覽器點「進階 → 仍要前往」（最快，內網用）
> - 把 `/etc/n8n/tls/server.crt` 加進客戶端的信任鏈（避免每次警告）
> - 想換成自家 CA 簽的證書，直接覆寫 `/etc/n8n/tls/server.{crt,key}` 後 `systemctl reload nginx` 即可。

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
./run-stack.sh up        # 起 n8n + PG 兩個容器，HTTPS 公開到 :8443
./run-stack.sh status    # 看狀態
./run-stack.sh logs      # 跟 n8n log
./run-stack.sh down      # 停止 (volume 留著)
./run-stack.sh destroy   # 清空 (含 docker volume)
```

啟動後開瀏覽器到 `https://localhost:8443`，第一次會看到 self-signed 憑證警告。要改宿主機 HTTPS port 可設定 `N8N_HOST_HTTPS_PORT`；舊的 `N8N_HOST_PORT` 仍可作為 fallback。憑證 (`PG_PASSWORD`、`N8N_ENCRYPTION_KEY`) 寫在 `.stack-env`，重啟容器資料延續。

n8n 容器內會跑同一份 `install-offline.sh`，所以裡面也是 nginx (TLS) → `127.0.0.1:5678` 的反代結構，跟第 3 節 RHEL 部署是同一份配置（差別只在沒 systemd，nginx 與 n8n 由容器入口腳本各自背景啟動，見 `run-stack.sh`）。反代細節見第 6 節。

> **注意**：`.stack-env` 含密鑰與密碼，已在 `.gitignore`。若要分享環境，請各自產生新檔，不要把 `.stack-env` 推上版控。

## 6. 反向代理架構

整個 stack 的對外入口都是 nginx；n8n 本身只在 `127.0.0.1:5678`（`N8N_PORT`）監聽，外部無法直連。

```
┌─ 瀏覽器 / webhook caller
│   https://<host>:<N8N_HTTPS_PORT>
▼
┌─────────────────────────────┐
│  nginx (TLS 在這裡終結)      │   /etc/nginx/conf.d/n8n.conf
│  listen :443 ssl http2      │   /etc/n8n/tls/server.{crt,key}
└──────────────┬──────────────┘
               │  proxy_pass http://127.0.0.1:5678
               ▼
┌─────────────────────────────┐
│  n8n (僅綁 127.0.0.1)        │   /etc/n8n/n8n.env
│  N8N_PORT=5678              │   N8N_HOST / WEBHOOK_URL
└─────────────────────────────┘
```

RHEL 部署（第 3 節）與 Docker stack（第 5 節）用的是**同一份** `install-offline.sh` 寫出來的 nginx 配置，差別只在 systemd vs. 容器入口腳本啟動。

**為什麼不讓 n8n 直接 listen 443**：

- n8n 以非 root user (`n8n`) 執行，特權埠交給 nginx 處理
- TLS、headers、上傳上限、長連線超時都集中在反代層
- 換證書（包含改成自家 CA 簽的）只要 reload nginx，不用重啟 n8n

### 關鍵 nginx 設定（出處 `install-offline.sh` `write_nginx_config`）

| 設定 | 值 | 為什麼需要 |
|---|---|---|
| `listen ${N8N_HTTPS_PORT} ssl http2` | 預設 443 | 對外 HTTPS 入口，由 `N8N_HTTPS_PORT` 控制 |
| `proxy_pass http://127.0.0.1:${N8N_PORT}` | 預設 5678 | n8n 不公開到外網，只能經反代進入 |
| `proxy_http_version 1.1` + `Upgrade` / `Connection` headers | — | n8n editor 與 webhook 用 WebSocket，沒升級會斷線 |
| `client_max_body_size 100M` | — | 上傳檔 / 大 payload 不被擋 |
| `proxy_read_timeout` / `proxy_send_timeout` | `3600s` | 長執行 workflow / SSE 不會被反代切掉 |
| `Host` / `X-Forwarded-Host` | `$http_host`（**不是 `$host`**） | 保留原始 `Host`（含 port）。n8n push / chat WebSocket 會驗證 `Origin`，預期 host 從這兩個 header 推算；用 `$host` 會被 nginx 去掉 port，導致 `localhost:8443` ≠ `localhost` 而被拒絕 |
| `X-Forwarded-Proto https` | — | n8n 才知道對外是 HTTPS，產生的回呼 URL 才會是 `https://...` |
| `X-Forwarded-For` / `X-Real-IP` | — | n8n 看到真實來源 IP（log、rate limit） |
| `ssl_certificate` | `/etc/n8n/tls/server.{crt,key}` | self-signed，可直接覆寫換成自家 CA 簽的 |
| `ssl_protocols` | `TLSv1.2 TLSv1.3` | 不接受更舊的協定 |

### `N8N_HOST` / `WEBHOOK_URL` 與反代的關係

`install-offline.sh` 寫到 `/etc/n8n/n8n.env`：

- `N8N_HOST=${N8N_TLS_HOSTNAME}` — n8n 知道自己「對外的 hostname」
- `WEBHOOK_URL=https://<hostname>:<port>/` — 外部 webhook 呼叫的完整 URL，**必須與 nginx 對外監聽一致**（同一個 hostname、同一個 `N8N_HTTPS_PORT`）

如果之後改 `N8N_HTTPS_PORT`、換證書 hostname、或把服務搬到別的網域名後面，記得同步這兩個變數，不然 webhook callback URL 會指錯地方。

### 換成自家 CA 簽的證書

直接覆寫 `/etc/n8n/tls/server.crt` 與 `/etc/n8n/tls/server.key`，然後 reload nginx：

- RHEL 部署：`systemctl reload nginx`
- Docker stack：`docker exec n8n-stack-n8n nginx -s reload`

n8n 不用重啟。
