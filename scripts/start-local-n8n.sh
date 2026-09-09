#!/usr/bin/env bash
# 依 .env 啟動本機 n8n，完成後顯示內部與外部網址。
# 相容 macOS 內建 Bash 3.2。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT}/.env"

NO_PULL=0

usage() {
  cat <<'EOF'
依 .env 的場景與 ngrok 設定啟動本機 n8n，完成後顯示內部與外部網址。

用法：
  ./scripts/start-local-n8n.sh
  ./scripts/start-local-n8n.sh --no-pull   不重新下載映像，只建立或啟動 container
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pull)
      NO_PULL=1
      ;;
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
  shift
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

print_url_field() {
  local label="$1"
  local value="$2"
  local color="${3:-$C_CYAN}"
  local pad=""
  case "$label" in
    內部網址|外部網址) pad="    " ;;
  esac
  printf '%b\n' "  ${C_WHITE}${label}${pad}${C_RESET}  ${color}${value}${C_RESET}"
}

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

quote_env_value() {
  QUOTE_VAL="$1" awk 'BEGIN {
    v = ENVIRON["QUOTE_VAL"]
    gsub(/\047/, "\047\\\047\047", v)
    printf "\047%s\047", v
  }'
}

upsert_env() {
  local key="$1"
  local value
  local quoted tmp found
  value="$(sanitize_env_value "$2")"
  quoted="$(quote_env_value "$value")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/start-local-n8n.XXXXXX")"
  found=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "${key}="*)
        printf '%s=%s\n' "$key" "$quoted"
        found=1
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done < "${ENV_FILE}" > "$tmp"
  if [[ "$found" -eq 0 ]]; then
    printf '%s=%s\n' "$key" "$quoted" >> "$tmp"
  fi
  mv "$tmp" "${ENV_FILE}"
}

generate_runners_token() {
  local chars='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
  local pw="" i n
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32; do
    n="$(LC_ALL=C od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' \n')"
    if [[ -z "$n" ]]; then
      n="$(date +%s)"
    fi
    pw="${pw}${chars:$((n % 62)):1}"
  done
  printf '%s' "$pw"
}

ensure_runners_auth_token() {
  local token
  token="$(get_env_value N8N_RUNNERS_AUTH_TOKEN)"
  case "$token" in
    ''|YOUR_*)
      token="$(generate_runners_token)"
      upsert_env N8N_RUNNERS_AUTH_TOKEN "$token"
      muted "  已寫入 N8N_RUNNERS_AUTH_TOKEN（task runner 連線用）。"
      ;;
  esac
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

ensure_runners_auth_token

SCENARIO="$(get_env_value N8N_SCENARIO)"
ENABLE_NGROK="$(get_env_value ENABLE_NGROK)"
NGROK_DOMAIN="$(get_env_value NGROK_DOMAIN)"

SCENARIO="$(printf '%s' "$SCENARIO" | tr '[:lower:]' '[:upper:]')"
ENABLE_NGROK="$(printf '%s' "$ENABLE_NGROK" | tr '[:upper:]' '[:lower:]')"
if [[ -z "$SCENARIO" ]]; then
  SCENARIO="A"
fi
if [[ -z "$ENABLE_NGROK" ]]; then
  ENABLE_NGROK="false"
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
    compose_args+=(up -d postgres n8n task-runners)
  fi
fi
if [[ "$NO_PULL" -eq 1 ]]; then
  compose_args+=(--pull never)
fi
# Code 節點外部套件寫在 runners 映像裡；--build 有快取，套件清單沒改時幾乎不會重裝。
compose_args+=(--build)

if [[ "$NO_PULL" -eq 1 ]]; then
  body "啟動 n8n（場景 ${SCENARIO}，不下載映像）..."
else
  body "啟動 n8n（場景 ${SCENARIO}）..."
fi
muted "  docker ${compose_args[*]}"
printf '\n'
docker "${compose_args[@]}"

if [[ "$ENABLE_NGROK" = "true" && "${N8N_ORCHESTRATED:-}" != "1" ]]; then
  "${ROOT}/scripts/check-ngrok-service.sh" || true
fi

if [[ "${N8N_ORCHESTRATED:-}" != "1" ]]; then
  INTERNAL_URL="http://localhost:5678"
  EXTERNAL_URL=""
  NGROK_STATUS=""
  if [[ -f "${ROOT}/data/.ngrok-status" ]]; then
    NGROK_STATUS="$(tr -d '\r\n' < "${ROOT}/data/.ngrok-status")"
  fi
  if [[ "$ENABLE_NGROK" = "true" && -n "$NGROK_DOMAIN" && "$NGROK_DOMAIN" != "YOUR_NGROK_DOMAIN" ]]; then
    EXTERNAL_URL="https://${NGROK_DOMAIN}"
  fi

  printf '\n'
  title "════════════════════════════════════════════════════════════"
  title "  n8n 已啟動"
  title "════════════════════════════════════════════════════════════"
  printf '\n'
  print_url_field "內部網址" "$INTERNAL_URL"
  if [[ "$NGROK_STATUS" = "occupied" ]]; then
    print_url_field "外部網址" "固定網域已被其他設備佔用，無法使用對外 webhook" "$C_YELLOW"
  elif [[ -n "$EXTERNAL_URL" ]]; then
    print_url_field "外部網址" "$EXTERNAL_URL"
    print_url_field "ngrok 檢查頁" "http://127.0.0.1:4040"
  else
    print_url_field "外部網址" "未啟用 ngrok，無法使用對外 webhook" "$C_YELLOW"
  fi
  printf '\n'
  if [[ "$NGROK_STATUS" = "occupied" ]]; then
    success "  請以內部網址開啟本機編輯器；固定網域已被其他設備佔用。"
  else
    success "  請以內部網址開啟本機編輯器；OAuth / Webhook 請使用外部網址。"
  fi
fi
