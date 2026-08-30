# 在自己電腦搭建 n8n

用 Docker 在本機跑 n8n，資料預設寫進專案裡的 `data/`，不用 Docker named volume。依資料要放哪裡，分成三種場景：

| 場景 | 資料庫 | 和 Cloud Run 的關係 | 適合 |
| --- | --- | --- | --- |
| A | 本機 Postgres | 無關 | 從空白環境自己註冊 |
| B | 本機 Postgres | 複製一份雲端資料過來，兩邊互不寫入 | 本機練習，但不想動到線上庫 |
| C | Cloud Run 那顆 Supabase | 共用同一顆庫 | 本機編輯，資料就是線上那份 |

編輯器一律開 [http://localhost:5678](http://localhost:5678)。有開 ngrok 時，檢查頁在 [http://127.0.0.1:4040](http://127.0.0.1:4040)。

---

## 前置需求

三種場景都需要 Docker 與 Docker Compose。

要用外網 webhook（Google OAuth、對外 callback）時，再準備 [ngrok](https://ngrok.com/) 的 Auth Token 與固定網域。`NGROK_DOMAIN` 只填網域，不要加 `https://`。compose 會組成 `https://<NGROK_DOMAIN>/` 當 webhook。只在本機編輯、不對外開洞時，可不上 ngrok。

場景 B、C 還要本機的 `gcloud`（不是瀏覽器裡的 Cloud Shell），並能讀 GCP 專案的 Secret Manager 與 Cloud Run。

```bash
# Windows
winget install -e --id Google.CloudSDK

# macOS
brew install --cask google-cloud-sdk

gcloud auth login
gcloud config set project <你的 GCP 專案 ID>
```

官方安裝見 [Install the gcloud CLI](https://cloud.google.com/sdk/docs/install)。確認登入與專案：

```bash
gcloud auth list
gcloud config get-value project
```

`.env` 裡的 `GCP_PROJECT`、`GCP_REGION`、`GCP_RUN_SERVICE` 請改成你的 Cloud Run 服務。

---

## 準備設定檔

```bash
cp .env.example .env
```

依 `.env.example` 的區塊填：

- **必填區**：場景 A / B 要設本機 `POSTGRES_PASSWORD`（不要填雲端資料庫密碼）。要用 ngrok 再填 `NGROK_AUTHTOKEN`、`NGROK_DOMAIN`。
- **場景 B / C**：填好 GCP 三項後執行 `./scripts/pull-secrets.sh`，讓腳本寫入 encryption key 與 Supabase 連線。不要手填「由指令或腳本產生」那一區。

---

## 場景 A：從空白環境開始

不連 Cloud Run，也不需要 `gcloud`。不必填 `N8N_ENCRYPTION_KEY` 與 `CLOUD_DB_*`，n8n 會自己產生本機 encryption key。

```bash
docker compose --profile tunnel up -d
```

開 [http://localhost:5678](http://localhost:5678)，依畫面建立管理員帳號。不上 ngrok 時改用：

```bash
docker compose up -d postgres n8n
```

---

## 場景 B：把 Cloud Run 的資料複製到本機

雲端的使用者、Credentials、工作流程會複製進本機 Postgres。Cloud Run 與 Supabase **不會被改寫**。請先完成 `gcloud` 登入。

務必先拉密鑰再啟動容器，n8n 才會用和 Cloud Run 同一把 encryption key，Credentials 才能解密。

```bash
./scripts/pull-secrets.sh
docker compose --profile tunnel up -d
./scripts/sync-from-cloud.sh
```

啟動後本機暫時是空白的，屬正常現象；資料在同步完成後才會進來。同步期間腳本會暫停 n8n，ngrok 不用關。

完成後用 Cloud Run 同一組帳密登入。若同步前已經走過「建立管理員」精靈，匯入會用雲端帳號蓋掉本機帳號。

匯入後工作流程會全部取消發布，避免和 Cloud Run 同時跑排程或 webhook。要測哪一條，再在本機逐筆發布。

之後若只要再拉一次 Credentials：

```bash
./scripts/sync-from-cloud.sh --credentials-only
```

完整同步會清空本機對應資料表再匯入。除錯要留暫存檔時加上 `--keep-exports`。

`N8N_IMAGE` 請盡量和 Cloud Run 同一版，否則 `import:entities` 可能因 schema 對不起來。預設是 `n8nio/n8n:2.36.8`。

---

## 場景 C：本機 n8n 直連遠端 Supabase

本機只跑 n8n（以及選用的 ngrok），資料庫就是 Cloud Run 正在用的那顆 Supabase。帳號與流程已經在雲端，**不要**跑 `sync-from-cloud.sh`。

這會和 Cloud Run 共用同一顆庫。兩邊同時開著時，排程與 webhook 可能各執行一次。本機測試前，請把 Cloud Run 縮成 0，或先暫停雲端流程。

```bash
./scripts/pull-secrets.sh
docker compose -f compose.yml -f compose.remote-supabase.yml --profile tunnel up -d
```

若剛才在跑場景 A / B，先停掉本機 Postgres：

```bash
docker compose --profile tunnel down
```

完成後用 Cloud Run 同一組帳密登入。不上 ngrok 時，拿掉指令裡的 `--profile tunnel` 即可。

---

## OAuth2 拿到本機之後（場景 B、C）

從雲端沿用的 Google OAuth Credentials，Client ID 與 Secret 可以繼續用，但 Redirect URL 仍指向 Cloud Run。本機解除綁定再授權時，Google 會拒絕舊的 callback。

到 [Google Cloud Console 憑證](https://console.cloud.google.com/apis/credentials) →「API 和服務」→「憑證」→ 對應的 OAuth 2.0 用戶端，在「已授權的重新導向 URI」加上本機入口：

```text
https://<你的 ngrok 網域>/rest/oauth2-credential/callback
http://localhost:5678/rest/oauth2-credential/callback
```

建議保留 Cloud Run 那一筆，讓雲端與本機可以並存。存檔後回到 n8n，對該 Credential 解除綁定再重新 Connect。

正式走 Google OAuth 請用 ngrok 的 HTTPS；`localhost` 只適合本機測試用戶端。

---

## 日常開關

```bash
# 場景 A / B：本機編輯器
docker compose up -d postgres n8n

# 場景 A / B：加上 ngrok
docker compose --profile tunnel up -d

# 場景 C：本機 n8n + 遠端 Supabase
docker compose -f compose.yml -f compose.remote-supabase.yml --profile tunnel up -d

# 關閉（A / B）
docker compose --profile tunnel down

# 關閉（C）
docker compose -f compose.yml -f compose.remote-supabase.yml --profile tunnel down
```

從 A / B 切到 C，或反過來，都先 `down` 再依新場景 `up`。

要拆掉這個專案的 container、映像，並清空 `data/`、`exports/`（不會刪 `.env`）：

```bash
./scripts/uninstall-local-n8n.sh
```

---

## 資料放哪

| 路徑 | 用途 |
| --- | --- |
| `data/n8n/` | n8n 設定與二進位資料（容器內 `/home/node/.n8n`） |
| `data/postgres/` | 本機 Postgres（場景 A / B；場景 C 不用） |
| `exports/` | 場景 B 同步暫存，預設同步完會刪 |

`.env`、`data/`、`exports/` 已列入 `.gitignore`。不要把 encryption key 或資料庫密碼提交進 git。
