#!/usr/bin/env bash
# 本機 n8n 開關機入口（Ubuntu）。
# 已有 .env 且容器在跑 → 關閉；容器沒在跑 → 啟動。尚無 .env 則先建立再啟動。
# 開關流程與 macOS 版相同；這裡先檢查 Docker 服務與使用權限。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TARGET="${ROOT}/n8n-開關機(macOS).sh"

usage() {
  cat <<'EOF'
本機 n8n 開關機入口（Ubuntu）：

  • 已有 .env、容器正在跑 → 關閉容器（保留 data/、映像與 .env）後結束
  • 已有 .env、容器沒在跑 → 啟動
  • 尚無 .env → 先建立設定，再啟動

啟動時會依序：

  1. 檢查或建立 .env
  2. 詢問是否啟用 Code 節點 task runners 與套件清單
  3. 檢查環境（check-env）
  4. 場景 B / C：必要時拉取雲端密鑰（pull-secrets）
  5. 依 .env 啟動 container（start-local-n8n）
  6. 場景 B：首次啟動時同步雲端資料（sync-from-cloud）

之後再執行同一支腳本即可開關。映像已在本機時，啟動不會重新下載。

用法：
  ./n8n-開關機(Ubuntu).sh

事前準備（只需一次）：

  sudo apt-get update
  sudo apt-get install -y docker.io docker-compose-v2
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$USER"

加入 docker 群組後請登出再登入，之後不必加 sudo。

場景 B、C 還需要 gcloud：

  sudo snap install google-cloud-cli --classic
  gcloud auth login
  gcloud config set project <你的 GCP 專案 ID>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

pause_on_exit() {
  if [[ -t 0 ]]; then
    printf '\n按下任意鍵關閉視窗'
    read -r -n 1 -s || true
    printf '\n'
  fi
}
trap pause_on_exit EXIT

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'
  C_CYAN=$'\033[36m'
  C_WHITE=$'\033[97m'
else
  C_RESET=''
  C_BOLD=''
  C_RED=''
  C_CYAN=''
  C_WHITE=''
fi

say() { printf '%b\n' "${C_WHITE}$*${C_RESET}"; }
cmd() { printf '%b\n' "  ${C_CYAN}$*${C_RESET}"; }
error() { printf '%b\n' "${C_BOLD}${C_RED}$*${C_RESET}" >&2; }

if [[ ! -f "$TARGET" ]]; then
  error "找不到 ${TARGET}，無法繼續。"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  error "找不到 docker。"
  say "請先安裝 Docker 與 Compose V2："
  cmd "sudo apt-get update"
  cmd "sudo apt-get install -y docker.io docker-compose-v2"
  cmd "sudo systemctl enable --now docker"
  cmd "sudo usermod -aG docker \"\$USER\""
  say "加入 docker 群組後請登出再登入，然後再執行 ./n8n-開關機(Ubuntu).sh"
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  docker_err="$(docker info 2>&1 || true)"
  case "$docker_err" in
    *permission\ denied*|*Permission\ denied*)
      error "目前的使用者無法使用 Docker。"
      say "請加入 docker 群組後登出再登入："
      cmd "sudo usermod -aG docker \"\$USER\""
      exit 1
      ;;
  esac
  error "Docker 服務沒有在跑。"
  say "請啟動服務後再執行本腳本："
  cmd "sudo systemctl enable --now docker"
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  error "找不到 docker compose。"
  say "請安裝 Compose V2（指令是 docker compose，不是 docker-compose）："
  cmd "sudo apt-get install -y docker-compose-v2"
  exit 1
fi

export N8N_LAUNCHER_NAME="n8n-開關機(Ubuntu).sh"
exec "$TARGET" "$@"
