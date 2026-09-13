#!/usr/bin/env bash
# 引導建立專案根目錄的 .env（macOS / Linux）。
# 相容 macOS 內建 Bash 3.2，請勿使用關聯陣列或 ${var,,}。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT}/.env"
EXAMPLE_FILE="${ROOT}/.env.example"
BACKUP_FILE="${ROOT}/.env.backup.$(date +%Y%m%d-%H%M%S)"

usage() {
  cat <<'EOF'
引導建立本專案根目錄的 .env 設定檔。

流程：
  1. 若已有 .env，先改名為 .env.backup.YYYYMMDD-HHMMSS（不會覆蓋舊備份）
  2. 由 .env.example 複製出新的 .env
  3. 詢問部署場景與是否啟用 ngrok，並寫入對應變數
  4. 依場景以互動方式填入必要機密資訊
  5. 詢問是否啟用 Code 節點 task runners 與套件清單

用法：
  ./scripts/create-envfile.sh
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
section() { printf '%b\n' "${C_BOLD}${C_BLUE}$*${C_RESET}"; }
body() { printf '%b\n' "${C_WHITE}$*${C_RESET}"; }
muted() { printf '%b\n' "${C_DIM}$*${C_RESET}"; }
success() { printf '%b\n' "${C_GREEN}$*${C_RESET}"; }
warn() { printf '%b\n' "${C_YELLOW}$*${C_RESET}"; }
error() { printf '%b\n' "${C_RED}$*${C_RESET}" >&2; }

sanitize_env_value() {
  printf '%s' "$1" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
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
  tmp="$(mktemp "${TMPDIR:-/tmp}/create-envfile.XXXXXX")"
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

read_line() {
  local input=""
  IFS= read -r input || true
  sanitize_env_value "$input"
}

print_prompt() {
  printf '%b\n' "${C_BOLD}${C_MAGENTA}$1${C_RESET}"
  if [[ $# -ge 2 && -n "$2" ]]; then
    printf '%b' "${C_BOLD}${C_MAGENTA}$2${C_RESET} "
  fi
}

print_summary_item() {
  muted "$(printf '  %-20s %s' "$1" "$2")"
}

next_step3() {
  STEP3=$((STEP3 + 1))
  STEP3_PREFIX="【步驟 3-${STEP3}】"
}

next_step4() {
  STEP4=$((STEP4 + 1))
  STEP4_PREFIX="【步驟 4-${STEP4}】"
}

read_required() {
  local line1="$1"
  local line2="$2"
  local dest="$3"
  local input=""
  while :; do
    print_prompt "$line1" "$line2"
    input="$(read_line)"
    if [[ -n "$input" ]]; then
      printf -v "$dest" '%s' "$input"
      printf '\n'
      return 0
    fi
    warn "此欄位為必填，請重新輸入。"
  done
}

read_with_default() {
  local line1="$1"
  local line2="$2"
  local default="$3"
  local dest="$4"
  local input=""
  print_prompt "$line1" "$line2"
  input="$(read_line)"
  if [[ -z "$input" ]]; then
    input="$default"
    success "已採用預設值 ${input}。"
  fi
  printf -v "$dest" '%s' "$input"
  printf '\n'
}

generate_alnum_password() {
  local chars='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
  local pw="" i n
  for i in 1 2 3 4 5 6 7 8 9 10; do
    n="$(LC_ALL=C od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' \n')"
    if [[ -z "$n" ]]; then
      n="$(date +%s)"
    fi
    pw="${pw}${chars:$((n % 62)):1}"
  done
  printf '%s' "$pw"
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

read_postgres_password() {
  local dest="$1"
  local input=""
  print_prompt "${STEP3_PREFIX}請提供本機 Postgres 資料庫密碼（POSTGRES_PASSWORD）" "此密碼僅供本機容器使用，請勿填寫雲端資料庫帳密（直接按 Enter 產生 10 字元隨機密碼）："
  input="$(read_line)"
  if [[ -z "$input" ]]; then
    input="$(generate_alnum_password)"
    success "已產生 10 字元隨機密碼並寫入 .env。"
    muted "  POSTGRES_PASSWORD=${input}"
  fi
  printf -v "$dest" '%s' "$input"
  printf '\n'
}

validate_ngrok_domain() {
  local d="$1"
  local lower
  if [[ -z "$d" ]]; then
    warn "此欄位為必填，請重新輸入。"
    return 1
  fi
  lower="$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')"
  if printf '%s' "$lower" | grep -qE 'https?://'; then
    warn "請勿加入通訊協定 (https://)，僅填寫主機名稱。"
    return 1
  fi
  if ! printf '%s' "$d" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'; then
    warn "網域格式不正確。請填寫至少包含主域名與頂級網域的主機名，例如 example.ngrok-free.dev。"
    return 1
  fi
  return 0
}

print_banner() {
  printf '\n'
  title "════════════════════════════════════════════════════════════"
  title "  n8n 本機環境設定精靈"
  title "════════════════════════════════════════════════════════════"
  printf '\n'
  section "【事前準備】"
  printf '\n'
  body "若需啟用 ngrok 對外通道（Webhook、OAuth 回呼），請先前往"
  printf '%b\n' "  ${C_CYAN}https://ngrok.com/${C_RESET}"
  body "註冊帳號，並備妥 Auth Token 與固定網域。"
  printf '\n'
  body "若需同步 Google Cloud Run 既有服務（場景 B、C），請先安裝 Google Cloud SDK，"
  body "再以 gcloud 完成身分驗證。"
  printf '\n'
  muted "  Windows："
  printf '%b\n' "    ${C_CYAN}winget install -e --id Google.CloudSDK${C_RESET}"
  muted "  macOS："
  printf '%b\n' "    ${C_CYAN}brew install --cask google-cloud-sdk${C_RESET}"
  muted "  安裝完成後執行："
  printf '%b\n' "    ${C_CYAN}gcloud auth login${C_RESET}"
  printf '\n'
  body "本精靈將引導您建立專案根目錄的 .env 設定檔。"
  body "既有的 .env 會先備份為 .env.backup.YYYYMMDD-HHMMSS，每次執行各自保留。"
  printf '\n'
}

print_scenario_help() {
  section "【步驟 1】選擇部署場景"
  printf '\n'
  body "請依資料存放位置選擇下列其中一種場景："
  printf '\n'
  printf '%b\n' "  ${C_BOLD}${C_CYAN}A${C_RESET}  從空白環境開始"
  muted "     使用本機 Postgres。不連線 Google Cloud Run，亦無須設定 gcloud。"
  muted "     適合全新註冊與獨立開發。"
  printf '\n'
  printf '%b\n' "  ${C_BOLD}${C_CYAN}B${C_RESET}  繼承 Google Cloud Run 的資料到本機 Postgres"
  muted "     將雲端使用者、憑證與工作流程複製到本機。Cloud Run 與 Supabase 不會被改寫。"
  muted "     適合本機練習，且不想影響線上資料。"
  printf '\n'
  printf '%b\n' "  ${C_BOLD}${C_CYAN}C${C_RESET}  本機 n8n 直連遠端 Supabase"
  muted "     與 Cloud Run 共用同一顆資料庫。帳號與流程即為線上那份。"
  muted "     兩邊同時執行時，排程與 Webhook 可能重複觸發。"
  printf '\n'
}

print_ngrok_help() {
  section "【步驟 2】是否啟用 ngrok 對外通道"
  printf '\n'
  body "n8n 若需接收外部 Webhook（例如 Google OAuth 回呼、對外 callback），"
  body "必須透過 ngrok 建立可從外網存取的 HTTPS 通道。"
  printf '\n'
  warn "若停用 ngrok，僅能在本機編輯器操作，將無法使用 n8n webhook 對外連線。"
  body "啟用時，稍後將請您提供 Ngrok Auth Token 與固定網域（僅填主機名，請勿加入通訊協定 (https://)）。"
  printf '\n'
}

print_runners_help() {
  section "【步驟 4】Code 節點與 task runners"
  printf '\n'
  body "Code 節點若要使用額外的 JavaScript / Python 套件（例如 pdf-lib、pymupdf），"
  body "需要另外啟動 task runners，並建立含這些套件的映像。"
  printf '\n'
  body "若你只編輯流程、不需要在 Code 節點安裝額外套件，建議關閉。"
  body "關閉後不會下載 runners 基底映像，也不會建立自訂映像，啟動較快。"
  printf '\n'
}

print_secrets_help() {
  section "【步驟 3】填寫場景 ${SCENARIO} 所需設定"
  printf '\n'
  case "$SCENARIO" in
    A)
      body "場景 A 僅需本機 Postgres 密碼。請勿填寫 Cloud Run 或 Supabase 的帳密。"
      ;;
    B)
      body "場景 B 需要本機 Postgres 密碼，以及 Google Cloud Run 的專案、區域與服務名稱。"
      body "後續請再執行 pull-secrets，以寫入加密金鑰與雲端資料庫連線。"
      ;;
    C)
      body "場景 C 使用遠端 Supabase，無需本機 Postgres 密碼。"
      body "請提供 Google Cloud Run 的專案、區域與服務名稱，後續再執行 pull-secrets。"
      ;;
  esac
  if [[ "$ENABLE_NGROK" = "true" ]]; then
    body "您已選擇啟用 ngrok，稍後將一併詢問 Auth Token 與網域。"
  fi
  printf '\n'
}

if [[ ! -f "$EXAMPLE_FILE" ]]; then
  error "找不到 ${EXAMPLE_FILE}，無法建立 .env。"
  exit 1
fi

print_banner

if [[ -f "$ENV_FILE" ]]; then
  warn "偵測到既有 .env，將改名為帶時間戳的備份檔。"
  mv -f "$ENV_FILE" "$BACKUP_FILE"
  success "已備份為 ${BACKUP_FILE}"
else
  muted "未發現既有 .env，將直接由範本建立。"
fi

cp "$EXAMPLE_FILE" "$ENV_FILE"
success "已由 .env.example 建立 ${ENV_FILE}"
printf '\n'

print_scenario_help
SCENARIO=""
while :; do
  print_prompt "請選擇欲採用的場景 [A/B/C]" "（直接按 Enter 採用預設值 A）："
  raw="$(read_line)"
  raw="$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]')"
  if [[ -z "$raw" ]]; then
    raw="A"
  fi
  case "$raw" in
    A|B|C)
      SCENARIO="$raw"
      break
      ;;
    *)
      warn "無效的選項。請輸入 A、B 或 C。"
      ;;
  esac
done
success "已選擇場景 ${SCENARIO}。"
printf '\n'

print_ngrok_help
ENABLE_NGROK=""
while :; do
  print_prompt "是否啟用 ngrok 整合？[Y/N]" "（直接按 Enter 採用預設值：停用）："
  raw="$(read_line)"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "$raw" ]]; then
    ENABLE_NGROK="false"
    break
  fi
  case "$raw" in
    y|yes|true|1|是)
      ENABLE_NGROK="true"
      break
      ;;
    n|no|false|0|否)
      ENABLE_NGROK="false"
      break
      ;;
    *)
      warn "無效的選項。請輸入 Y（啟用）或 N（停用）。"
      ;;
  esac
done
if [[ "$ENABLE_NGROK" = "true" ]]; then
  success "已啟用 ngrok 整合。"
else
  warn "已停用 ngrok。本機將無法使用對外 webhook。"
fi
printf '\n'

print_secrets_help

POSTGRES_PASSWORD=""
GCP_PROJECT=""
GCP_REGION=""
GCP_RUN_SERVICE=""
NGROK_AUTHTOKEN=""
NGROK_DOMAIN=""
STEP3=0
STEP3_PREFIX=""

case "$SCENARIO" in
  A|B)
    next_step3
    read_postgres_password POSTGRES_PASSWORD
    ;;
esac

case "$SCENARIO" in
  B|C)
    next_step3
    read_required "${STEP3_PREFIX}請提供 Google Cloud 專案 ID（GCP_PROJECT）" "請填寫 Cloud Run 服務所屬的 GCP 專案：" GCP_PROJECT
    next_step3
    read_with_default "${STEP3_PREFIX}請提供 Google Cloud Run 服務所在區域（GCP_REGION）" "（直接按 Enter 採用預設值 asia-east1）：" "asia-east1" GCP_REGION
    next_step3
    read_with_default "${STEP3_PREFIX}請提供 Google Cloud Run 服務名稱（GCP_RUN_SERVICE）" "（直接按 Enter 採用預設值 n8n）：" "n8n" GCP_RUN_SERVICE
    ;;
esac

if [[ "$ENABLE_NGROK" = "true" ]]; then
  next_step3
  read_required "${STEP3_PREFIX}請提供 Ngrok Auth Token（NGROK_AUTHTOKEN）" "可於 ngrok 官方網站儀表板取得：" NGROK_AUTHTOKEN
  next_step3
  while :; do
    print_prompt "${STEP3_PREFIX}請提供 Ngrok 固定網域（NGROK_DOMAIN）" "僅填主機名，例如 example.ngrok-free.dev，請勿加入通訊協定 (https://)："
    NGROK_DOMAIN="$(read_line)"
    if validate_ngrok_domain "$NGROK_DOMAIN"; then
      printf '\n'
      break
    fi
  done
fi

print_runners_help
ENABLE_N8N_RUNNERS=""
STEP4=0
STEP4_PREFIX=""
next_step4
while :; do
  print_prompt "${STEP4_PREFIX}是否啟用 task runners（Code 節點額外套件）？[Y/N]" "（直接按 Enter 採用預設值：停用）："
  raw="$(read_line)"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "$raw" ]]; then
    ENABLE_N8N_RUNNERS="false"
    break
  fi
  case "$raw" in
    y|yes|true|1|是)
      ENABLE_N8N_RUNNERS="true"
      break
      ;;
    n|no|false|0|否)
      ENABLE_N8N_RUNNERS="false"
      break
      ;;
    *)
      warn "無效的選項。請輸入 Y（啟用）或 N（停用）。"
      ;;
  esac
done

JS_BUILTIN=""
JS_EXTERNAL=""
PY_STDLIB=""
PY_PACKAGES=""
PY_IMPORTS=""
if [[ "$ENABLE_N8N_RUNNERS" = "true" ]]; then
  success "已啟用 task runners。接下來請確認套件清單，直接按 Enter 即採用預設值。"
  printf '\n'
  js_builtin="crypto"
  js_external="pdf-lib"
  py_stdlib="*"
  py_packages="pymupdf"
  py_imports="pymupdf,fitz"

  body "JavaScript Code 節點可 require 的 Node 內建模組。多數情況保留 crypto 即可。"
  next_step4
  read_with_default "${STEP4_PREFIX}請輸入允許的內建模組（逗號分隔）" "（直接按 Enter 採用預設值 ${js_builtin}）：" "$js_builtin" JS_BUILTIN

  body "要預先裝進 runners 映像、供 JavaScript Code 節點使用的 npm 套件。"
  body "改過清單後，下次啟動會重建映像。"
  next_step4
  read_with_default "${STEP4_PREFIX}請輸入要安裝的 npm 套件（逗號分隔）" "（直接按 Enter 採用預設值 ${js_external}）：" "$js_external" JS_EXTERNAL

  body "Python Code 節點可使用的標準庫。填 * 代表全部開放。"
  next_step4
  read_with_default "${STEP4_PREFIX}請輸入 N8N_RUNNERS_STDLIB_ALLOW" "（直接按 Enter 採用預設值 ${py_stdlib}）：" "$py_stdlib" PY_STDLIB

  body "要 pip 安裝進映像的 Python 套件名稱（安裝名，例如 pymupdf）。"
  next_step4
  read_with_default "${STEP4_PREFIX}請輸入要安裝的 Python 套件（逗號分隔）" "（直接按 Enter 採用預設值 ${py_packages}）：" "$py_packages" PY_PACKAGES

  body "Python Code 節點允許 import 的模組名稱。安裝名與 import 名可能不同"
  body "（例如安裝 pymupdf，程式裡要 import fitz）。"
  next_step4
  read_with_default "${STEP4_PREFIX}請輸入允許 import 的模組（逗號分隔）" "（直接按 Enter 採用預設值 ${py_imports}）：" "$py_imports" PY_IMPORTS
else
  warn "已停用 task runners。Code 節點只能使用 n8n 內建能力，不會建立 runners 映像。"
  printf '\n'
fi

upsert_env N8N_SCENARIO "$SCENARIO"
upsert_env ENABLE_NGROK "$ENABLE_NGROK"
upsert_env N8N_LOCAL_BOOTSTRAPPED ""
upsert_env ENABLE_N8N_RUNNERS "$ENABLE_N8N_RUNNERS"
if [[ "$ENABLE_N8N_RUNNERS" = "true" ]]; then
  upsert_env N8N_RUNNERS_MODE external
  upsert_env N8N_NATIVE_PYTHON_RUNNER true
  upsert_env N8N_RUNNERS_AUTH_TOKEN "$(generate_runners_token)"
  upsert_env NODE_FUNCTION_ALLOW_BUILTIN "$JS_BUILTIN"
  upsert_env NODE_FUNCTION_ALLOW_EXTERNAL "$JS_EXTERNAL"
  upsert_env N8N_RUNNERS_STDLIB_ALLOW "$PY_STDLIB"
  upsert_env N8N_RUNNERS_PY_PACKAGES "$PY_PACKAGES"
  upsert_env N8N_RUNNERS_EXTERNAL_ALLOW "$PY_IMPORTS"
else
  upsert_env N8N_RUNNERS_MODE internal
  upsert_env N8N_NATIVE_PYTHON_RUNNER false
fi

if [[ -n "$POSTGRES_PASSWORD" ]]; then
  upsert_env POSTGRES_PASSWORD "$POSTGRES_PASSWORD"
fi
if [[ -n "$GCP_PROJECT" ]]; then
  upsert_env GCP_PROJECT "$GCP_PROJECT"
  upsert_env GCP_REGION "$GCP_REGION"
  upsert_env GCP_RUN_SERVICE "$GCP_RUN_SERVICE"
fi
if [[ "$ENABLE_NGROK" = "true" ]]; then
  upsert_env NGROK_AUTHTOKEN "$NGROK_AUTHTOKEN"
  upsert_env NGROK_DOMAIN "$NGROK_DOMAIN"
else
  upsert_env NGROK_AUTHTOKEN ""
  upsert_env NGROK_DOMAIN ""
fi

printf '\n'
success "────────────────────────────────────────────────────────────"
success "  .env 已建立完成。"
success "────────────────────────────────────────────────────────────"
printf '\n'
body "寫入摘要（機密值不會顯示）："
print_summary_item "N8N_SCENARIO" "$SCENARIO"
print_summary_item "ENABLE_NGROK" "$ENABLE_NGROK"
print_summary_item "ENABLE_N8N_RUNNERS" "$ENABLE_N8N_RUNNERS"
if [[ "$ENABLE_N8N_RUNNERS" = "true" ]]; then
  print_summary_item "N8N_RUNNERS_AUTH_TOKEN" "（已產生）"
  print_summary_item "NODE_FUNCTION_ALLOW_BUILTIN" "$JS_BUILTIN"
  print_summary_item "NODE_FUNCTION_ALLOW_EXTERNAL" "$JS_EXTERNAL"
  print_summary_item "N8N_RUNNERS_STDLIB_ALLOW" "$PY_STDLIB"
  print_summary_item "N8N_RUNNERS_PY_PACKAGES" "$PY_PACKAGES"
  print_summary_item "N8N_RUNNERS_EXTERNAL_ALLOW" "$PY_IMPORTS"
fi
case "$SCENARIO" in
  A|B) print_summary_item "POSTGRES_PASSWORD" "（已設定）" ;;
esac
case "$SCENARIO" in
  B|C)
    print_summary_item "GCP_PROJECT" "$GCP_PROJECT"
    print_summary_item "GCP_REGION" "$GCP_REGION"
    print_summary_item "GCP_RUN_SERVICE" "$GCP_RUN_SERVICE"
    ;;
esac
if [[ "$ENABLE_NGROK" = "true" ]]; then
  print_summary_item "NGROK_AUTHTOKEN" "（已設定）"
  print_summary_item "NGROK_DOMAIN" "$NGROK_DOMAIN"
else
  print_summary_item "NGROK_AUTHTOKEN" "（已留空）"
  print_summary_item "NGROK_DOMAIN" "（已留空）"
fi
if [[ -f "$BACKUP_FILE" ]]; then
  muted "  先前設定備份：${BACKUP_FILE}"
fi

printf '\n'
success "設定精靈結束。"
