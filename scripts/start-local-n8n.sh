#!/usr/bin/env bash
# 依 .env 啟動本機 n8n，完成後顯示內部與外部網址。
# 相容 macOS 內建 Bash 3.2。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT}/.env"

usage() {
  cat <<'EOF'
依 .env 的場景與 ngrok 設定啟動本機 n8n，完成後顯示內部與外部網址。

用法：
  ./scripts/start-local-n8n.sh
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
  C_CYAN=$'\033[36m'
  C_WHITE=$'\033[97m'
else
  C_RESET=''
  C_BOLD=''
  C_DIM=''
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_CYAN=''
  C_WHITE=''
fi

title() { printf '%b\n' "${C_BOLD}${C_CYAN}$*${C_RESET}"; }
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

if ! command -v docker >/dev/null 2>&1; then
  error "找不到 docker。"
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  error "找不到 ${ENV_FILE}。請先執行 ./scripts/create-envfile.sh"
  exit 1
fi

cd "${ROOT}"

SCENARIO="$(get_env_value N8N_SCENARIO)"
ENABLE_NGROK="$(get_env_value ENABLE_NGROK)"
NGROK_DOMAIN="$(get_env_value NGROK_DOMAIN)"

SCENARIO="$(printf '%s' "$SCENARIO" | tr '[:lower:]' '[:upper:]')"
ENABLE_NGROK="$(printf '%s' "$ENABLE_NGROK" | tr '[:upper:]' '[:lower:]')"
if [[ -z "$SCENARIO" ]]; then
  SCENARIO="A"
fi
if [[ -z "$ENABLE_NGROK" ]]; then
  ENABLE_NGROK="true"
fi

compose_args=(compose)
if [[ "$SCENARIO" = "C" ]]; then
  compose_args+=(-f compose.yml -f compose.remote-supabase.yml)
fi
if [[ "$ENABLE_NGROK" = "true" ]]; then
  compose_args+=(--profile tunnel up -d)
else
  if [[ "$SCENARIO" = "C" ]]; then
    compose_args+=(up -d)
  else
    compose_args+=(up -d postgres n8n)
  fi
fi

body "啟動 n8n（場景 ${SCENARIO}）..."
muted "  docker ${compose_args[*]}"
printf '\n'
docker "${compose_args[@]}"

INTERNAL_URL="http://localhost:5678"
EXTERNAL_URL=""
if [[ "$ENABLE_NGROK" = "true" && -n "$NGROK_DOMAIN" && "$NGROK_DOMAIN" != "YOUR_NGROK_DOMAIN" ]]; then
  EXTERNAL_URL="https://${NGROK_DOMAIN}"
fi

printf '\n'
title "════════════════════════════════════════════════════════════"
title "  n8n 已啟動"
title "════════════════════════════════════════════════════════════"
printf '\n'
printf '%b\n' "  ${C_WHITE}內部網址${C_RESET}      ${C_CYAN}${INTERNAL_URL}${C_RESET}"
if [[ -n "$EXTERNAL_URL" ]]; then
  printf '%b\n' "  ${C_WHITE}外部網址${C_RESET}      ${C_CYAN}${EXTERNAL_URL}${C_RESET}"
  printf '%b\n' "  ${C_WHITE}ngrok 檢查頁${C_RESET}  ${C_CYAN}http://127.0.0.1:4040${C_RESET}"
else
  printf '%b\n' "  ${C_WHITE}外部網址${C_RESET}      ${C_YELLOW}未啟用 ngrok，無法使用對外 webhook${C_RESET}"
fi
printf '\n'
success "請以內部網址開啟本機編輯器；OAuth / Webhook 請使用外部網址。"
