#!/usr/bin/env bash
# 停止本機 n8n 容器，保留資料、映像與 .env。相容 macOS 內建 Bash 3.2。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ROOT}/.env"

usage() {
  cat <<'EOF'
停止本機 n8n 容器（含 ngrok，若有啟動）。

不會刪除 data/、映像或 .env。之後再開一次，執行同一支 ./start-n8n.sh 即可。
若要拆掉環境並清空資料，請改用 ./scripts/uninstall-local-n8n.sh。

用法：
  ./shutdown-n8n.sh
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
  C_CYAN=$'\033[36m'
  C_WHITE=$'\033[97m'
else
  C_RESET=''
  C_BOLD=''
  C_DIM=''
  C_RED=''
  C_GREEN=''
  C_CYAN=''
  C_WHITE=''
fi

title() { printf '%b\n' "${C_BOLD}${C_CYAN}$*${C_RESET}"; }
body() { printf '%b\n' "${C_WHITE}$*${C_RESET}"; }
muted() { printf '%b\n' "${C_DIM}$*${C_RESET}"; }
success() { printf '%b\n' "${C_GREEN}$*${C_RESET}"; }
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

cd "${ROOT}"

SCENARIO="$(get_env_value N8N_SCENARIO)"
SCENARIO="$(printf '%s' "$SCENARIO" | tr '[:lower:]' '[:upper:]')"
if [[ -z "$SCENARIO" ]]; then
  SCENARIO="A"
fi

compose_args=(compose)
if [[ "$SCENARIO" = "C" ]]; then
  compose_args+=(-f compose.yml -f compose.remote-supabase.yml)
fi
# 一律帶 tunnel profile，避免先前啟用的 ngrok 殘留在跑。
compose_args+=(--profile tunnel stop)

printf '\n'
title "════════════════════════════════════════════════════════════"
title "  關閉本機 n8n"
title "════════════════════════════════════════════════════════════"
printf '\n'
body "停止容器（場景 ${SCENARIO}）。資料、映像與 .env 都會保留。"
muted "  docker ${compose_args[*]}"
printf '\n'

docker "${compose_args[@]}"

printf '\n'
success "────────────────────────────────────────────────────────────"
success "  本機 n8n 已停止。"
success "────────────────────────────────────────────────────────────"
printf '\n'
muted "之後再開一次，執行同一支 ./start-n8n.sh 即可。"
muted "若要拆掉環境並清空資料，請執行 ./scripts/uninstall-local-n8n.sh"
printf '\n'
