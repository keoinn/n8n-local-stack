#!/usr/bin/env bash
# 服務啟動後檢查 ngrok 固定網域是否已被其他設備佔用。
# 相容 macOS 內建 Bash 3.2。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT}/.env"
STATUS_FILE="${ROOT}/data/.ngrok-status"

usage() {
  cat <<'EOF'
服務啟動後，透過 Docker 日誌檢查 ngrok 固定網域是否已被其他設備佔用。
若被佔用，會停止本機 ngrok 容器（n8n / Postgres 不受影響）。

用法：
  ./scripts/check-ngrok-service.sh
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知參數：$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_WHITE=$'\033[97m'
else
  C_RESET=''
  C_BOLD=''
  C_DIM=''
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_WHITE=''
fi

body() { printf '%b\n' "${C_WHITE}$*${C_RESET}"; }
muted() { printf '%b\n' "${C_DIM}$*${C_RESET}"; }
success() { printf '%b\n' "${C_GREEN}$*${C_RESET}"; }
warn() { printf '%b\n' "${C_YELLOW}$*${C_RESET}"; }
error() { printf '%b\n' "${C_RED}$*${C_RESET}" >&2; }

sanitize_env_value() {
  printf '%s' "$1" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

get_env_value() {
  local key="$1"
  local raw=""
  if [[ -f "$ENV_FILE" ]]; then
    raw="$(grep -E "^${key}=" "$ENV_FILE" | tail -n 1 || true)"
    raw="${raw#${key}=}"
  fi
  raw="$(sanitize_env_value "$raw")"
  case "$raw" in
    \'*)
      raw="${raw#\'}"
      raw="${raw%\'}"
      raw="${raw//\'\\\'\'/\'}"
      ;;
    \"*)
      raw="${raw#\"}"
      raw="${raw%\"}"
      ;;
    *)
      raw="${raw%% #*}"
      raw="$(sanitize_env_value "$raw")"
      ;;
  esac
  printf '%s' "$raw"
}

write_status() {
  mkdir -p "${ROOT}/data"
  printf '%s\n' "$1" > "$STATUS_FILE"
}

logs_indicate_occupied() {
  printf '%s' "$1" | grep -qiE 'ERR_NGROK_334|ERR_NGROK_108|already online|already bound|simultaneous ngrok agent|another ngrok agent'
}

logs_indicate_ready() {
  printf '%s' "$1" | grep -qiE 'started tunnel'
}

if ! command -v docker >/dev/null 2>&1; then
  error "找不到 docker。"
  write_status unknown
  exit 0
fi

if [[ ! -f "$ENV_FILE" ]]; then
  error "找不到 ${ENV_FILE}。"
  write_status unknown
  exit 0
fi

cd "${ROOT}"

SCENARIO="$(get_env_value N8N_SCENARIO)"
ENABLE_NGROK="$(get_env_value ENABLE_NGROK)"
SCENARIO="$(printf '%s' "$SCENARIO" | tr '[:lower:]' '[:upper:]')"
ENABLE_NGROK="$(printf '%s' "$ENABLE_NGROK" | tr '[:upper:]' '[:lower:]')"
if [[ -z "$SCENARIO" ]]; then
  SCENARIO="A"
fi
if [[ -z "$ENABLE_NGROK" ]]; then
  ENABLE_NGROK="false"
fi

if [[ "$ENABLE_NGROK" != "true" ]]; then
  write_status skipped
  muted "未啟用 ngrok，略過通道檢查。"
  exit 0
fi

compose_ngrok() {
  if [[ "$SCENARIO" = "C" ]]; then
    docker compose -f compose.yml -f compose.remote-supabase.yml --profile tunnel "$@"
  else
    docker compose --profile tunnel "$@"
  fi
}

body "檢查 ngrok 通道是否可用 ..."
cid="$(compose_ngrok ps -a -q ngrok 2>/dev/null || true)"
if [[ -z "$cid" ]]; then
  warn "找不到 ngrok 容器，略過通道檢查。"
  write_status unknown
  exit 0
fi

occupied=0
ready=0
i=0
while [[ "$i" -lt 12 ]]; do
  logs="$(compose_ngrok logs --no-color --tail 120 ngrok 2>/dev/null || true)"
  if logs_indicate_occupied "$logs"; then
    occupied=1
    break
  fi
  if logs_indicate_ready "$logs"; then
    ready=1
    break
  fi
  sleep 2
  i=$((i + 1))
done

if [[ "$occupied" -eq 0 && "$ready" -eq 0 ]]; then
  logs="$(compose_ngrok logs --no-color --tail 120 ngrok 2>/dev/null || true)"
  if logs_indicate_occupied "$logs"; then
    occupied=1
  elif logs_indicate_ready "$logs"; then
    ready=1
  fi
fi

if [[ "$occupied" -eq 1 ]]; then
  warn "固定網域已被其他設備佔用，已停止本機 ngrok。"
  muted "  請先在另一台裝置關閉 ngrok 後，再執行同一支啟動腳本。"
  compose_ngrok stop ngrok >/dev/null 2>&1 || true
  write_status occupied
  exit 0
fi

if [[ "$ready" -eq 1 ]]; then
  success "ngrok 通道已就緒。"
  write_status ok
  exit 0
fi

warn "暫時無法確認 ngrok 是否已連上，容器仍會繼續執行。"
write_status unknown
exit 0
