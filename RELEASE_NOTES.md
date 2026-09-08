# n8n-local-stack v1.0.0

用 Docker 在自己的電腦跑 n8n。資料存在專案的 `data/`。依資料要放哪裡，分成三種場景。

## 安裝

請 clone **main**（不要用 feature 分支）：

```bash
git clone https://github.com/keoinn/n8n-local-stack.git
cd n8n-local-stack

# macOS / Linux
./start-n8n.sh

# Windows（請用 .cmd，不要直接執行 .ps1）
.\start-n8n.cmd
```

編輯器：[http://localhost:5678](http://localhost:5678)

## 這個版本能做什麼

- **場景 A**：本機 Postgres，空白環境自行註冊
- **場景 B**：把 Cloud Run / Supabase 的資料複製到本機，兩邊互不影響；匯入後流程會全部取消發布
- **場景 C**：本機 n8n 直連線上 Supabase（進階；請先停 Cloud Run 或暫停雲端流程，避免排程／webhook 跑兩次）
- 啟動精靈：建立 `.env`、檢查環境、拉密鑰、啟動容器；場景 B 第一次會同步資料
- Windows 與 macOS / Linux 同一套流程
- ngrok 預設關閉；需要對外 webhook / OAuth 時再開
- 關閉容器：`./shutdown-n8n.sh`（Windows：`.\shutdown-n8n.cmd`）
- 卸載：`./uninstall-local-n8n.sh`（Windows：`.\uninstall-local-n8n.cmd`）
- 之後再開會從 `origin/main` 更新程式碼。不會還原本機改過的檔案；若偵測到專案檔有修改，會略過更新

## 使用前請準備

- [Docker](https://docs.docker.com/get-started/get-docker/)（Windows 請用 Docker Desktop）
- 場景 B / C：本機 `gcloud`（不要用瀏覽器 Cloud Shell），並能讀取 GCP Secret Manager 與 Cloud Run
- 對外 webhook / OAuth：ngrok Auth Token 與固定網域

密鑰請只放本機 `.env`，不要提交到 git，也不要放進 zip 傳給別人。

## 已知限制

- 場景 C 與線上共用同一顆資料庫，兩邊同時開著可能重複觸發
- 免費 ngrok 固定網域同時只能一台使用；被佔用時本機會停掉 tunnel，仍可用 localhost 編輯
- 請只改 `.env`。改腳本或 `compose.yml` 會讓自動更新略過
- 建議本機 n8n 映像版本與 Cloud Run 相同（目前預設 `n8nio/n8n:2.36.8`）

## 之後更新

再執行同一支啟動腳本即可。映像若已在本機，只會啟動容器，不會重新下載。
