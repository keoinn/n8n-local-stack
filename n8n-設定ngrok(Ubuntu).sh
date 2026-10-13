#!/usr/bin/env bash
# 在 Ubuntu 上修改 .env 的 NGROK_AUTHTOKEN 與 NGROK_DOMAIN，並重新建立 n8n 容器。
# 用 sh 執行時，Ubuntu 的 /bin/sh 是 dash，不支援 [[。先改由 bash 重新執行。
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "找不到 bash。請先安裝：sudo apt-get install -y bash" >&2
  exit 1
fi

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ROOT}/.env"
STOPPED=0
DONE=0

usage() {
  cat <<'EOF'
修改本機 .env 的 ngrok 設定，並重新建立 n8n 容器（Ubuntu）。

流程：
  1. 檢查 Docker、n8n 容器是否在跑，以及 .env 是否已完成場景設定
  2. 若 n8n 正在跑，先停止 n8n（ngrok 若在跑會一併停止；Postgres 保留）
  3. 先詢問是否開啟 ngrok
     Y：改寫 NGROK_AUTHTOKEN、NGROK_DOMAIN，並把 ENABLE_NGROK 設為 true
     N：ENABLE_NGROK 設為 false，NGROK_AUTHTOKEN 與 NGROK_DOMAIN 清空
  4. 重新建立並啟動 n8n（只 restart 不會套用新網址）

用法：
  ./n8n-設定ngrok(Ubuntu).sh

NGROK_DOMAIN 只填主機名，不要加 https://。
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

pause_on_exit() {
  if [[ -t 0 ]]; then
    printf '\n按下任意鍵關閉視窗'
    read -r -n 1 -s || true
    printf '\n'
  fi
}

restore_if_stopped() {
  if [[ "$STOPPED" -eq 1 && "$DONE" -eq 0 ]]; then
    DONE=1
    printf '\n'
    warn "設定沒有完成，正在依目前的 .env 把 n8n 啟動回來。"
    "${ROOT}/scripts/start-local-n8n.sh" --no-pull || true
  fi
}

on_exit() {
  restore_if_stopped
  pause_on_exit
}
trap on_exit EXIT

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_MAGENTA=$'\033[35m'
  C_CYAN=$'\033[36m'
  C_WHITE=$'\033[97m'
else
  C_RESET=''
  C_BOLD=''
  C_DIM=''
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_BLUE=''
  C_MAGENTA=''
  C_CYAN=''
  C_WHITE=''
fi

title() { printf '%b\n' "${C_BOLD}${C_CYAN}$*${C_RESET}"; }
section() { printf '\n%b\n' "${C_BOLD}${C_BLUE}$*${C_RESET}"; }
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

is_placeholder() {
  local v="$1"
  v="$(sanitize_env_value "$v")"
  if [[ -z "$v" ]]; then
    return 0
  fi
  case "$v" in
    YOUR_*) return 0 ;;
  esac
  return 1
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
  local value quoted tmp found
  value="$(sanitize_env_value "$2")"
  quoted="$(quote_env_value "$value")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/set-ngrok.XXXXXX")"
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

print_prompt() {
  printf '%b\n' "${C_BOLD}${C_MAGENTA}$1${C_RESET}"
  if [[ $# -ge 2 && -n "$2" ]]; then
    printf '%b' "${C_BOLD}${C_MAGENTA}$2${C_RESET} "
  fi
}

read_line() {
  local input=""
  IFS= read -r input || true
  sanitize_env_value "$input"
}

normalize_bool() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

mask_token() {
  local t="$1" n
  if is_placeholder "$t"; then
    printf '尚未設定'
    return 0
  fi
  n=${#t}
  if [[ "$n" -le 8 ]]; then
    printf '已設定（%s 字元）' "$n"
    return 0
  fi
  printf '%s…%s（%s 字元）' "${t:0:4}" "${t:$((n - 4)):4}" "$n"
}

validate_ngrok_domain() {
  local d="$1" lower
  if [[ -z "$d" ]]; then
    warn "網域為必填，請重新輸入。"
    return 1
  fi
  lower="$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')"
  if printf '%s' "$lower" | grep -qE 'https?://'; then
    warn "請勿加入 https://，只填主機名，例如 example.ngrok-free.dev。"
    return 1
  fi
  if ! printf '%s' "$d" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'; then
    warn "網域格式不正確。請填至少包含主域名與頂級網域的主機名，例如 example.ngrok-free.dev。"
    return 1
  fi
  return 0
}

require_env() {
  local key="$1" hint="$2" value
  value="$(get_env_value "$key")"
  if is_placeholder "$value"; then
    error "  ${key} 未設定或仍為範本值"
    muted "    ${hint}"
    return 1
  fi
  success "  ${key} 已設定"
  return 0
}

service_is_running() {
  local service="$1" ids
  ids="$(docker ps -q \
    --filter 'label=com.docker.compose.project=n8n-local' \
    --filter "label=com.docker.compose.service=${service}" 2>/dev/null || true)"
  [[ -n "$ids" ]]
}

compose_stop() {
  local service="$1"
  local -a args
  args=(compose)
  if [[ "$SCENARIO" = "C" ]]; then
    args+=(-f compose.yml -f compose.remote-supabase.yml)
  fi
  if [[ "$service" = "ngrok" ]]; then
    args+=(--profile tunnel)
  fi
  args+=(stop "$service")
  muted "  docker ${args[*]}"
  docker "${args[@]}"
}

cd "${ROOT}"

printf '\n'
title "════════════════════════════════════════════════════════════"
title "  修改 ngrok 並重啟 n8n"
title "════════════════════════════════════════════════════════════"

section "【步驟 1】檢查 Docker、容器與 .env"
CHECK_OK=1

if ! command -v docker >/dev/null 2>&1; then
  error "  找不到 docker。"
  muted "    sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2"
  muted "    sudo systemctl enable --now docker"
  muted "    sudo usermod -aG docker \"\$USER\"（登出再登入）"
  CHECK_OK=0
elif ! docker info >/dev/null 2>&1; then
  docker_err="$(docker info 2>&1 || true)"
  case "$docker_err" in
    *permission\ denied*|*Permission\ denied*)
      error "  目前的使用者無法使用 Docker。"
      muted "    sudo usermod -aG docker \"\$USER\"，然後登出再登入。"
      ;;
    *)
      error "  Docker 服務沒有在跑。"
      muted "    sudo systemctl enable --now docker"
      ;;
  esac
  CHECK_OK=0
elif ! docker compose version >/dev/null 2>&1; then
  error "  找不到 docker compose。"
  muted "    sudo apt-get install -y docker-compose-v2"
  CHECK_OK=0
else
  success "  Docker 可用。"
fi

if [[ ! -f "$ENV_FILE" ]]; then
  error "  找不到 .env。"
  muted "    請先執行 ./n8n-開關機(Ubuntu).sh 完成初始設定。"
  CHECK_OK=0
  SCENARIO=""
else
  success "  已找到 .env。"
  SCENARIO="$(get_env_value N8N_SCENARIO)"
  SCENARIO="$(printf '%s' "$SCENARIO" | tr '[:lower:]' '[:upper:]')"
  case "$SCENARIO" in
    A|B|C)
      success "  N8N_SCENARIO=${SCENARIO}"
      ;;
    "")
      error "  N8N_SCENARIO 未設定。"
      muted "    請先執行 ./n8n-開關機(Ubuntu).sh 完成初始設定。"
      CHECK_OK=0
      ;;
    *)
      error "  N8N_SCENARIO=${SCENARIO} 不是 A、B 或 C。"
      CHECK_OK=0
      SCENARIO=""
      ;;
  esac
  case "$SCENARIO" in
    A|B)
      require_env POSTGRES_PASSWORD "場景 ${SCENARIO} 需要本機 Postgres 密碼。" || CHECK_OK=0
      require_env POSTGRES_DB "請在 .env 設定 POSTGRES_DB。" || CHECK_OK=0
      require_env POSTGRES_USER "請在 .env 設定 POSTGRES_USER。" || CHECK_OK=0
      ;;
  esac
  case "$SCENARIO" in
    B|C)
      require_env GCP_PROJECT "請填 Google Cloud 專案 ID。" || CHECK_OK=0
      require_env GCP_REGION "請填 Cloud Run 區域。" || CHECK_OK=0
      require_env GCP_RUN_SERVICE "請填 Cloud Run 服務名稱。" || CHECK_OK=0
      require_env N8N_ENCRYPTION_KEY "請先執行 ./n8n工具程式(Ubuntu).sh pull-secrets。" || CHECK_OK=0
      ;;
  esac
  if [[ "$SCENARIO" = "C" && ! -f "${ROOT}/compose.remote-supabase.yml" ]]; then
    error "  找不到 compose.remote-supabase.yml。"
    CHECK_OK=0
  fi
fi

N8N_RUNNING=0
NGROK_RUNNING=0
if [[ "$CHECK_OK" -eq 1 ]]; then
  if service_is_running n8n; then
    N8N_RUNNING=1
    success "  n8n 容器正在執行。"
  else
    warn "  n8n 容器目前沒有在跑。略過關機，設定完成後會直接啟動。"
  fi
  if service_is_running ngrok; then
    NGROK_RUNNING=1
    success "  ngrok 容器正在執行。"
  fi
fi

if [[ "$CHECK_OK" -eq 0 ]]; then
  printf '\n'
  error "檢查未通過，尚未修改 .env，也沒有關閉容器。"
  exit 1
fi

if [[ ! -t 0 ]]; then
  error "這個腳本需要在終端機回答是否開啟 ngrok。"
  exit 1
fi

if [[ "$N8N_RUNNING" -eq 1 || "$NGROK_RUNNING" -eq 1 ]]; then
  section "【步驟 2】關閉 n8n"
  body "先停止容器，改完網址後才重新建立。Postgres 會保留。"
  printf '\n'
  if [[ "$NGROK_RUNNING" -eq 1 ]]; then
    body "停止 ngrok，避免舊網域繼續佔用。"
    compose_stop ngrok
    printf '\n'
  fi
  if [[ "$N8N_RUNNING" -eq 1 ]]; then
    body "停止 n8n。"
    compose_stop n8n
    printf '\n'
  fi
  STOPPED=1
  success "n8n 已停止。接下來修改 ngrok 設定。"
else
  section "【步驟 2】關閉 n8n"
  success "容器沒有在跑，略過關機。"
fi

section "【步驟 3】是否開啟 ngrok"
OLD_TOKEN="$(get_env_value NGROK_AUTHTOKEN)"
OLD_DOMAIN="$(get_env_value NGROK_DOMAIN)"
OLD_ENABLE="$(normalize_bool "$(get_env_value ENABLE_NGROK)")"
printf '\n'
body "目前 ENABLE_NGROK：${OLD_ENABLE:-（未設定）}"
body "目前 NGROK_AUTHTOKEN：$(mask_token "$OLD_TOKEN")"
if is_placeholder "$OLD_DOMAIN"; then
  body "目前 NGROK_DOMAIN：尚未設定"
else
  body "目前 NGROK_DOMAIN：${OLD_DOMAIN}"
fi
printf '\n'
body "Y：開啟 ngrok，並改寫 NGROK_AUTHTOKEN、NGROK_DOMAIN。"
body "N：關閉 ngrok。ENABLE_NGROK 設為 false，Token 與網域清空。"
printf '\n'

ENABLE_NGROK="false"
while :; do
  print_prompt "是否開啟 ngrok？" "[Y/N]："
  answer="$(normalize_bool "$(read_line)")"
  case "$answer" in
    y|yes|true|1|是)
      ENABLE_NGROK="true"
      break
      ;;
    n|no|false|0|否)
      ENABLE_NGROK="false"
      break
      ;;
    *)
      warn "請輸入 Y（開啟）或 N（關閉）。"
      ;;
  esac
done
printf '\n'

NEW_TOKEN=""
NEW_DOMAIN=""
if [[ "$ENABLE_NGROK" = "true" ]]; then
  body "Token 可在 https://dashboard.ngrok.com/get-started/your-authtoken 取得。"
  body "網域只填主機名，不要加 https://。"
  printf '\n'

  while :; do
    if is_placeholder "$OLD_TOKEN"; then
      print_prompt "請輸入 NGROK_AUTHTOKEN" "（必填）："
    else
      print_prompt "請輸入 NGROK_AUTHTOKEN" "（直接按 Enter 保留目前的 Token）："
    fi
    NEW_TOKEN="$(read_line)"
    if [[ -z "$NEW_TOKEN" ]]; then
      if is_placeholder "$OLD_TOKEN"; then
        warn "Token 為必填，請重新輸入。"
        continue
      fi
      NEW_TOKEN="$OLD_TOKEN"
    fi
    if is_placeholder "$NEW_TOKEN"; then
      warn "不能使用範本值 YOUR_NGROK_AUTHTOKEN。"
      continue
    fi
    if printf '%s' "$NEW_TOKEN" | grep -q '[[:space:]]'; then
      warn "Token 不能含有空白。"
      continue
    fi
    break
  done
  printf '\n'

  while :; do
    if is_placeholder "$OLD_DOMAIN"; then
      print_prompt "請輸入 NGROK_DOMAIN" "（只填主機名，例如 example.ngrok-free.dev）："
    else
      print_prompt "請輸入 NGROK_DOMAIN" "（直接按 Enter 保留 ${OLD_DOMAIN}）："
    fi
    NEW_DOMAIN="$(read_line)"
    if [[ -z "$NEW_DOMAIN" ]]; then
      if is_placeholder "$OLD_DOMAIN"; then
        warn "網域為必填，請重新輸入。"
        continue
      fi
      NEW_DOMAIN="$OLD_DOMAIN"
    fi
    if validate_ngrok_domain "$NEW_DOMAIN"; then
      break
    fi
  done
  printf '\n'

  body "即將寫入："
  muted "  ENABLE_NGROK=true"
  muted "  NGROK_AUTHTOKEN=$(mask_token "$NEW_TOKEN")"
  muted "  NGROK_DOMAIN=${NEW_DOMAIN}"
else
  body "即將寫入："
  muted "  ENABLE_NGROK=false"
  muted "  NGROK_AUTHTOKEN="
  muted "  NGROK_DOMAIN="
fi
printf '\n'

while :; do
  print_prompt "寫入並重新啟動 n8n？[Y/n]" "（直接按 Enter 表示同意）："
  answer="$(normalize_bool "$(read_line)")"
  case "$answer" in
    ""|y|yes|true|1|是)
      break
      ;;
    n|no|false|0|否)
      warn "已取消。沒有修改 .env。"
      exit 0
      ;;
    *)
      warn "請輸入 Y 或 n。"
      ;;
  esac
done

upsert_env ENABLE_NGROK "$ENABLE_NGROK"
upsert_env NGROK_AUTHTOKEN "$NEW_TOKEN"
upsert_env NGROK_DOMAIN "$NEW_DOMAIN"
success "已寫入 .env。"

section "【步驟 4】重新啟動 n8n"
if [[ "$ENABLE_NGROK" = "true" ]]; then
  body "重新建立容器以套用新的網址，並啟動 ngrok。映像已在本機時不會重新下載。"
else
  body "重新建立容器，且不會啟動 ngrok。映像已在本機時不會重新下載。"
fi
printf '\n'
DONE=1
"${ROOT}/scripts/start-local-n8n.sh" --no-pull

printf '\n'
success "────────────────────────────────────────────────────────────"
success "  ngrok 設定已更新，n8n 已重新啟動。"
success "────────────────────────────────────────────────────────────"
printf '\n'
if [[ "$ENABLE_NGROK" = "true" ]]; then
  muted "請用 https://${NEW_DOMAIN} 開啟編輯器。檢查頁：http://127.0.0.1:4040"
else
  muted "ngrok 已關閉。請用 http://localhost:5678 開啟編輯器。"
fi
printf '\n'
