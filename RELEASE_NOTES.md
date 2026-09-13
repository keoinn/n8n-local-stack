# n8n-local-stack v1.1.0

用 Docker 在自己的電腦跑 n8n。資料存在專案的 `data/`。依資料要放哪裡，分成三種場景。

## 安裝

請 clone **main**（不要用 feature 分支）：

```bash
git clone https://github.com/keoinn/n8n-local-stack.git
cd n8n-local-stack

# macOS / Linux
./n8n-開關機(macOS).sh

# Windows（請用 .cmd，不要直接執行 .ps1）
.\n8n-開關機(Win).cmd
```

編輯器：[http://localhost:5678](http://localhost:5678)

完整說明見 [README.md](README.md)。

## 這個版本能做什麼

- **場景 A**：本機 Postgres，空白環境自行註冊
- **場景 B**：把 Cloud Run / Supabase 的資料複製到本機，兩邊互不影響；匯入後流程會全部取消發布
- **場景 C**：本機 n8n 直連線上 Supabase（進階；請先停 Cloud Run 或暫停雲端流程，避免排程／webhook 跑兩次）
- **開關機入口**：`./n8n-開關機(macOS).sh`（Windows：`.\n8n-開關機(Win).cmd`）。已有 `.env` 時，容器在跑就關、沒在跑就開；第一次沒有 `.env` 才引導建立設定
- **工具入口**：`./n8n工具程式(macOS).sh`（Windows：`.\n8n工具程式(Win).cmd`）可轉發 start / stop / update / uninstall / 檢查 / 同步
- 場景 B / C：密鑰寫進 `.env` 之後，再開機不檢查 gcloud、不重拉密鑰；場景 B 資料也只在第一次自動複製
- ngrok 預設關閉；需要對外 webhook / OAuth 時再開
- task runners 映像已建立且套件清單沒改時，重啟不會重建
- 只關閉、不啟動：`./n8n工具程式(macOS).sh stop` 或 `./scripts/shutdown-n8n.sh`
- 卸載：`./n8n工具程式(macOS).sh uninstall` 或 `./scripts/uninstall-local-n8n.sh`
- 更新專案程式碼：`./n8n工具程式(macOS).sh update` 或 `./scripts/update-n8n.sh`。不會還原本機改過的檔案；若偵測到專案檔有修改，會停止更新

## 使用前請準備

- [Docker](https://docs.docker.com/get-started/get-docker/)（Windows 請用 Docker Desktop）
- 場景 B / C **第一次**：本機 `gcloud`（不要用瀏覽器 Cloud Shell），並能讀取 GCP Secret Manager 與 Cloud Run。密鑰寫入後不必再裝、也不必再登入
- 對外 webhook / OAuth：ngrok Auth Token 與固定網域

密鑰請只放本機 `.env`，不要提交到 git，也不要放進 zip 傳給別人。

## 已知限制

- 場景 C 與線上共用同一顆資料庫，兩邊同時開著可能重複觸發
- 免費 ngrok 固定網域同時只能一台使用；被佔用時本機會停掉 tunnel，仍可用 localhost 編輯
- 請只改 `.env`。改腳本或 `compose.yml` 會讓 `./scripts/update-n8n.sh` 停止更新
- 本機與 Cloud Run 必須同一版 n8n（目前預設 `n8nio/n8n:2.36.8`）。雲端請固定版本，不要用 `n8nio/n8n:latest`

## 之後更新

再執行同一支開關機腳本即可開關機。映像若已在本機，啟動只會啟動容器，不會重新下載。

要更新專案程式碼，請執行 `./n8n工具程式(macOS).sh update`（Windows：`.\n8n工具程式(Win).cmd update`）。
