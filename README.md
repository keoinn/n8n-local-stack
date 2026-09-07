# 在自己的電腦安裝 n8n

用 Docker 在這台電腦執行 n8n。資料會存在專案的 `data/` 資料夾。依照資料要放在哪裡，分成三種場景：

| 場景 | 資料庫 | 與 Cloud Run 的關係 | 適合 |
| --- | --- | --- | --- |
| A | 本機 Postgres | 沒有關聯 | 從空白環境自行註冊 |
| B | 本機 Postgres | 複製一份雲端資料，兩邊互不影響 | 想在本機練習，又不想改到線上資料 |
| C | Cloud Run 使用的 Supabase | 共用同一個資料庫 | 在本機編輯，資料就是線上那份 |

編輯器請開啟 [http://localhost:5678](http://localhost:5678)。若已啟用 ngrok，檢查頁在 [http://127.0.0.1:4040](http://127.0.0.1:4040)。

---

## 事前準備

三種場景都需要 Docker（Windows 請安裝 [Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/)）。

若需要從外網接收 webhook（例如 Google OAuth 回呼），請準備 [ngrok](https://ngrok.com/) 的 Auth Token 與固定網域。`NGROK_DOMAIN` 只填網域，不要加 `https://`。若只在本機編輯、不需要對外 webhook，可以不啟用 ngrok。

場景 B、C 還需要在這台電腦安裝 `gcloud`（請勿使用瀏覽器裡的 Cloud Shell），並能讀取 GCP 專案的 Secret Manager 與 Cloud Run。

```bash
# Windows
winget install -e --id Google.CloudSDK

# macOS
brew install --cask google-cloud-sdk

gcloud auth login
gcloud config set project <你的 GCP 專案 ID>
```

官方安裝說明見 [Install the gcloud CLI](https://cloud.google.com/sdk/docs/install)。確認登入與專案：

```bash
gcloud auth list
gcloud config get-value project
```

---

## 開始使用

請在專案根目錄執行啟動精靈。它會依序建立設定檔、檢查環境，再依場景啟動。

```bash
# macOS / Linux
./start-n8n.sh

# Windows（請用 .cmd，不要直接執行 .ps1）
.\start-n8n.cmd
```

macOS 與 Linux 請執行根目錄的 `.sh`；Windows 請執行根目錄的 `.cmd`。

| 場景 | 啟動時會多做的事 |
| --- | --- |
| A | 啟動本機 Postgres 與 n8n |
| B | 先取得雲端密鑰，啟動後再複製雲端資料 |
| C | 先取得雲端密鑰並改連遠端資料庫，**不會**複製資料 |

之後要再開一次，執行同一支腳本即可。映像檔若已在本機，只會啟動容器，不會重新下載。

場景 B 第一次會複製雲端資料，之後再開不會自動再複製。若要再同步一次，請執行 `./scripts/sync-from-cloud.sh`（Windows：`.\scripts\sync-from-cloud.cmd`）。

要關閉容器但保留資料、映像檔與設定檔，請執行 `./shutdown-n8n.sh`（Windows：`.\shutdown-n8n.cmd`）。

若曾執行卸載再重新啟動，會當成第一次：會再取得密鑰；場景 B 也會再複製雲端資料。

---

## 各場景注意事項

### 場景 A

不連接 Cloud Run，也不需要 `gcloud`。第一次開啟編輯器時，請依畫面建立管理員帳號。

### 場景 B

會把雲端的使用者、憑證與工作流程複製到本機 Postgres。Cloud Run 與 Supabase **不會被更改**。

啟動後本機暫時沒有資料是正常的，資料會在複製完成後才出現。完成後請用 Cloud Run 的同一組帳號密碼登入。

複製進來的工作流程會全部取消發布，避免與雲端同時執行排程或 webhook。要測試哪一條，再在本機逐筆發布。

若只要再匯入憑證：

```bash
# macOS / Linux
./scripts/sync-from-cloud.sh --credentials-only

# Windows
.\scripts\sync-from-cloud.cmd --credentials-only
```

完整同步會先清空本機對應資料再匯入。建議本機 n8n 版本與 Cloud Run 相同。

### 場景 C

本機 n8n 直接使用 Cloud Run 正在用的 Supabase。帳號與流程已在雲端，**不要**執行資料同步。

這會與 Cloud Run 共用同一個資料庫。兩邊同時開著時，排程與 webhook 可能各執行一次。本機測試前，請先把 Cloud Run 縮成 0，或暫停雲端流程。

完成後請用 Cloud Run 的同一組帳號密碼登入。

從場景 A / B 改成 C，或從 C 改回 A / B，請先關閉再依新場景啟動。

---

## 自行填寫設定檔

若不想使用啟動精靈，可自行複製後填寫：

```bash
# macOS / Linux
cp .env.example .env

# Windows
copy .env.example .env
```

請依 `.env.example` 的區塊填寫：

- 場景 A / B 要設定本機 `POSTGRES_PASSWORD`（不要填雲端資料庫密碼）。若要使用 ngrok，再填 `NGROK_AUTHTOKEN`、`NGROK_DOMAIN`。
- 場景 B / C：填好 GCP 三項後，執行 `./scripts/pull-secrets.sh`（Windows：`.\scripts\pull-secrets.cmd`）。加密金鑰與雲端資料庫連線請勿手填。

設定完成後，可檢查本機是否就緒：

```bash
# macOS / Linux
./scripts/check-env.sh

# Windows
.\scripts\check-env.cmd
```

---

## 綁定 Google OAuth（場景 B、C）

從雲端沿用的 Google OAuth 憑證，Client ID 與 Secret 可以繼續使用，但重新導向網址仍指向 Cloud Run。本機解除綁定再授權時，Google 會拒絕舊的回呼網址。

請到 [Google Cloud Console 憑證](https://console.cloud.google.com/apis/credentials) →「API 和服務」→「憑證」→ 對應的 OAuth 2.0 用戶端，在「已授權的重新導向 URI」加上本機入口：

```text
https://<你的 ngrok 網域>/rest/oauth2-credential/callback
http://localhost:5678/rest/oauth2-credential/callback
```

建議保留 Cloud Run 那一筆，讓雲端與本機可以並存。存檔後回到 n8n，對該憑證解除綁定再重新 Connect。

綁定時請用 ngrok 的 HTTPS 開啟編輯器再按 Connect，不要用 `http://localhost:5678`：

```text
https://<你的 ngrok 網域>
```

免費 ngrok 第一次開啟會出現警告頁，請先按 Visit Site。

---

## 日常開關與卸載

```bash
# 啟動（已啟動過則不會重新下載映像檔）
./start-n8n.sh              # Windows：.\start-n8n.cmd

# 關閉容器（保留資料、映像檔與 .env）
./shutdown-n8n.sh           # Windows：.\shutdown-n8n.cmd
```

要移除這個專案的容器與映像檔，並清空 `data/`、`exports/` 與 `.env`（可用 `--keep-env` 保留設定檔）：

```bash
# macOS / Linux
./uninstall-local-n8n.sh

# Windows
.\uninstall-local-n8n.cmd
```

---

## 資料存放位置

| 路徑 | 用途 |
| --- | --- |
| `data/n8n/` | n8n 設定與本機資料 |
| `data/postgres/` | 本機 Postgres（場景 A / B；場景 C 不使用） |
| `exports/` | 場景 B 同步時的暫存檔，預設完成後會刪除 |

請勿把加密金鑰或資料庫密碼提交到 git。

---

## 疑難排解

### 啟用 ngrok 後啟動失敗

多半是 `.env` 的 `NGROK_AUTHTOKEN` 或 `NGROK_DOMAIN` 還沒填，或仍是範本的 `YOUR_NGROK_*`。請到 [ngrok](https://ngrok.com/) 取得後寫進 `.env`，再執行一次啟動腳本。網域只要主機名，不要加 `https://`。

若只在本機編輯、不需要對外 webhook，啟動精靈詢問是否啟用 ngrok 時請選擇停用。

### OAuth 重新導向網址仍是 `http://localhost:5678`

請確認 `.env` 已填 `NGROK_DOMAIN`，然後先關閉再重新啟動。改完設定後必須重新建立 n8n 容器，只重新啟動不會套用新的網址。

瀏覽器請強制重新整理後再打開憑證。若這筆憑證是在 localhost 時期建立的，請解除綁定再 Connect，或新增一筆。Google Cloud Console 也要有同一條重新導向 URI。

### OAuth 綁定出現 `Error: Unauthorized`

Google 同意畫面通過後，彈窗卻顯示 `Failed to connect. The window can be closed now.` 時，通常是用 `localhost` 開啟編輯器，回呼卻走到 ngrok 網址。

請依序確認：

1. `.env` 已填 `NGROK_DOMAIN`，並已關閉後重新啟動。
2. 用 `https://<NGROK_DOMAIN>` 開啟編輯器並登入，不要用 `http://localhost:5678`。免費 ngrok 請先通過 Visit Site 警告頁。
3. Google Cloud Console 的重新導向 URI 與憑證畫面顯示的完全一致（含 `https://`、網域、`/rest/oauth2-credential/callback`）。
4. 再解除綁定後重新 Connect。
