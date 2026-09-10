#!/usr/bin/env bash
# 引導建立設定、檢查環境，並依 .env 啟動本機 n8n（macOS / Linux）。
# 實際步驟委派 scripts/ 既有腳本。相容 macOS 內建 Bash 3.2。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ROOT}/.env"
MARKER_FILE="${ROOT}/data/.local-bootstrapped"

usage() {
  cat <<'EOF'
引導完成本機 n8n 啟動：

  1. 若尚無 .env，執行 create-envfile
  2. 詢問是否啟用 Code 節點 task runners 與套件清單
  3. 檢查環境（check-env）
  4. 場景 B / C：必要時拉取雲端密鑰（pull-secrets）
  5. 依 .env 啟動 container（start-local-n8n）
  6. 場景 B：首次啟動時同步雲端資料（sync-from-cloud）

之後再執行本腳本，若映像已在本機，只會啟動既有 container，不會重新下載映像。

用法：
  ./start-n8n.sh
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
trap pause_on_exit EXIT

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

run_script() {
  local rel="$1"
  local rc
  shift
  if [[ $# -gt 0 ]]; then
    muted "  → ${rel} $*"
  else
    muted "  → ${rel}"
  fi
  printf '\n'
  set +e
  "${ROOT}/${rel}" "$@"
  rc=$?
  set -e
  return "$rc"
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

normalize_bool() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
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

apply_runners_mode() {
  local enabled="$1"
  if [[ "$enabled" = "true" ]]; then
    upsert_env ENABLE_N8N_RUNNERS true
    upsert_env N8N_RUNNERS_MODE external
    upsert_env N8N_NATIVE_PYTHON_RUNNER true
    if is_placeholder "$(get_env_value N8N_RUNNERS_AUTH_TOKEN)"; then
      upsert_env N8N_RUNNERS_AUTH_TOKEN "$(generate_runners_token)"
    fi
  else
    upsert_env ENABLE_N8N_RUNNERS false
    upsert_env N8N_RUNNERS_MODE internal
    upsert_env N8N_NATIVE_PYTHON_RUNNER false
  fi
}

configure_runners() {
  local current raw
  current="$(normalize_bool "$(get_env_value ENABLE_N8N_RUNNERS)")"
  case "$current" in
    true|false)
      section "【步驟 2】Code 節點與 task runners"
      apply_runners_mode "$current"
      if [[ "$current" = "true" ]]; then
        success "已啟用 task runners，將依 .env 建立映像並啟動 sidecar。"
        muted "  若要關閉或改套件清單，請編輯 .env 後再執行本腳本。"
      else
        success "未啟用 task runners，略過建立映像。"
        muted "  若之後需要 Code 節點額外套件，請把 .env 的 ENABLE_N8N_RUNNERS 改成 true，或刪除該列後再啟動。"
      fi
      printf '\n'
      return 0
      ;;
  esac

  section "【步驟 2】Code 節點與 task runners"
  printf '\n'
  body "Code 節點若要使用額外的 JavaScript / Python 套件（例如 pdf-lib、pymupdf），"
  body "需要另外啟動 task runners，並建立含這些套件的映像。"
  printf '\n'
  body "若你只編輯流程、不需要在 Code 節點安裝額外套件，建議關閉。"
  body "關閉後不會下載 runners 基底映像，也不會建立自訂映像，啟動較快。"
  printf '\n'

  while :; do
    print_prompt "是否啟用 task runners（Code 節點額外套件）？[Y/N]" "（直接按 Enter 採用預設值：停用）："
    raw="$(normalize_bool "$(read_line)")"
    if [[ -z "$raw" ]]; then
      apply_runners_mode false
      warn "已停用 task runners。Code 節點只能使用 n8n 內建能力，不會建立 runners 映像。"
      printf '\n'
      return 0
    fi
    case "$raw" in
      y|yes|true|1|是)
        apply_runners_mode true
        success "已啟用 task runners。接下來請確認套件清單，直接按 Enter 即採用預設值。"
        printf '\n'
        break
        ;;
      n|no|false|0|否)
        apply_runners_mode false
        warn "已停用 task runners。Code 節點只能使用 n8n 內建能力，不會建立 runners 映像。"
        printf '\n'
        return 0
        ;;
      *)
        warn "無效的選項。請輸入 Y（啟用）或 N（停用）。"
        ;;
    esac
  done

  local js_builtin js_external py_stdlib py_packages py_imports
  js_builtin="$(get_env_value NODE_FUNCTION_ALLOW_BUILTIN)"
  js_external="$(get_env_value NODE_FUNCTION_ALLOW_EXTERNAL)"
  py_stdlib="$(get_env_value N8N_RUNNERS_STDLIB_ALLOW)"
  py_packages="$(get_env_value N8N_RUNNERS_PY_PACKAGES)"
  py_imports="$(get_env_value N8N_RUNNERS_EXTERNAL_ALLOW)"
  [[ -n "$js_builtin" ]] || js_builtin="crypto"
  [[ -n "$js_external" ]] || js_external="pdf-lib"
  [[ -n "$py_stdlib" ]] || py_stdlib="*"
  [[ -n "$py_packages" ]] || py_packages="pymupdf"
  [[ -n "$py_imports" ]] || py_imports="pymupdf,fitz"

  body "JavaScript Code 節點可 require 的 Node 內建模組。多數情況保留 crypto 即可。"
  read_with_default \
    "請輸入允許的內建模組（逗號分隔）" \
    "（直接按 Enter 採用預設值 ${js_builtin}）：" \
    "$js_builtin" \
    js_builtin

  body "要預先裝進 runners 映像、供 JavaScript Code 節點使用的 npm 套件。"
  body "改過清單後，下次啟動會重建映像。"
  read_with_default \
    "請輸入要安裝的 npm 套件（逗號分隔）" \
    "（直接按 Enter 採用預設值 ${js_external}）：" \
    "$js_external" \
    js_external

  body "Python Code 節點可使用的標準庫。填 * 代表全部開放。"
  read_with_default \
    "請輸入 N8N_RUNNERS_STDLIB_ALLOW" \
    "（直接按 Enter 採用預設值 ${py_stdlib}）：" \
    "$py_stdlib" \
    py_stdlib

  body "要 pip 安裝進映像的 Python 套件名稱（安裝名，例如 pymupdf）。"
  read_with_default \
    "請輸入要安裝的 Python 套件（逗號分隔）" \
    "（直接按 Enter 採用預設值 ${py_packages}）：" \
    "$py_packages" \
    py_packages

  body "Python Code 節點允許 import 的模組名稱。安裝名與 import 名可能不同"
  body "（例如安裝 pymupdf，程式裡要 import fitz）。"
  read_with_default \
    "請輸入允許 import 的模組（逗號分隔）" \
    "（直接按 Enter 採用預設值 ${py_imports}）：" \
    "$py_imports" \
    py_imports

  upsert_env NODE_FUNCTION_ALLOW_BUILTIN "$js_builtin"
  upsert_env NODE_FUNCTION_ALLOW_EXTERNAL "$js_external"
  upsert_env N8N_RUNNERS_STDLIB_ALLOW "$py_stdlib"
  upsert_env N8N_RUNNERS_PY_PACKAGES "$py_packages"
  upsert_env N8N_RUNNERS_EXTERNAL_ALLOW "$py_imports"

  success "task runners 套件設定已寫入 .env。"
  muted "  JS 內建：${js_builtin}"
  muted "  JS 外部：${js_external}"
  muted "  Python 標準庫：${py_stdlib}"
  muted "  Python 安裝套件：${py_packages}"
  muted "  Python 可 import：${py_imports}"
  printf '\n'
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
  tmp="$(mktemp "${TMPDIR:-/tmp}/start-n8n.XXXXXX")"
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

write_bootstrapped() {
  upsert_env N8N_LOCAL_BOOTSTRAPPED "$1"
  write_marker "$1" || warn "無法寫入啟動紀錄檔。"
}

write_marker() {
  mkdir -p "${ROOT}/data"
  local text
  text="$(printf 'N8N_SCENARIO=%s\nBOOTSTRAPPED_AT=%s\n' "$1" "$(date +%Y-%m-%dT%H:%M:%S)")"
  printf '%s' "$text" > "${MARKER_FILE}"
  printf '%s' "$text" > "${ROOT}/.n8n-local-bootstrapped"
}

print_url_field() {
  local label="$1"
  local value="$2"
  local color="${3:-$C_CYAN}"
  local pad=""
  # 標籤欄顯示寬度 12（與「ngrok 檢查頁」對齊）；CJK 以雙寬計算。
  case "$label" in
    內部網址|外部網址) pad="    " ;;
  esac
  printf '%b\n' "  ${C_WHITE}${label}${pad}${C_RESET}  ${color}${value}${C_RESET}"
}

get_ngrok_check_status() {
  local path="${ROOT}/data/.ngrok-status"
  if [[ ! -f "$path" ]]; then
    printf ''
    return 0
  fi
  tr -d '\r\n' < "$path"
}

print_ready_banner() {
  local enable_ngrok domain internal_url external_url ngrok_status
  enable_ngrok="$(get_env_value ENABLE_NGROK)"
  domain="$(get_env_value NGROK_DOMAIN)"
  ngrok_status="$(get_ngrok_check_status)"
  enable_ngrok="$(printf '%s' "$enable_ngrok" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "$enable_ngrok" ]]; then
    enable_ngrok="false"
  fi
  internal_url="http://localhost:5678"
  external_url=""
  if [[ "$enable_ngrok" = "true" && -n "$domain" && "$domain" != "YOUR_NGROK_DOMAIN" ]]; then
    external_url="https://${domain}"
  fi

  printf '\n'
  title "════════════════════════════════════════════════════════════"
  title "  n8n 已啟動"
  title "════════════════════════════════════════════════════════════"
  printf '\n'
  print_url_field "內部網址" "$internal_url"
  if [[ "$ngrok_status" = "occupied" ]]; then
    print_url_field "外部網址" "固定網域已被其他設備佔用，無法使用對外 webhook" "$C_YELLOW"
  elif [[ -n "$external_url" ]]; then
    print_url_field "外部網址" "$external_url"
    print_url_field "ngrok 檢查頁" "http://127.0.0.1:4040"
  else
    print_url_field "外部網址" "未啟用 ngrok，無法使用對外 webhook" "$C_YELLOW"
  fi
  printf '\n'
  if [[ "$ngrok_status" = "occupied" ]]; then
    success "  請以內部網址開啟本機編輯器；固定網域已被其他設備佔用。"
  else
    success "  請以內部網址開啟本機編輯器；OAuth / Webhook 請使用外部網址。"
  fi
}

marker_scenario() {
  local file raw
  for file in "$MARKER_FILE" "${ROOT}/.n8n-local-bootstrapped"; do
    if [[ ! -f "$file" ]]; then
      continue
    fi
    raw="$(grep -E '^N8N_SCENARIO=' "$file" | tail -n 1 || true)"
    raw="${raw#N8N_SCENARIO=}"
    raw="$(sanitize_env_value "$raw")"
    if [[ -n "$raw" ]]; then
      printf '%s' "$raw"
      return 0
    fi
  done
  return 0
}

project_has_containers() {
  local ids
  ids="$(docker ps -aq --filter 'label=com.docker.compose.project=n8n-local' 2>/dev/null || true)"
  [[ -n "$ids" ]]
}

image_exists() {
  local image="$1"
  docker image inspect "$image" >/dev/null 2>&1
}

UPDATE_REF="${N8N_UPDATE_REF:-main}"

print_git_install_hint() {
  warn "目前無法自動更新程式碼。"
  warn "若要更新，請先安裝 git 原始碼控制工具："
  printf '%b\n' "  ${C_CYAN}https://git-scm.com/${C_RESET}"
  printf '\n'
}

has_local_tracked_changes() {
  local status
  status="$(git -C "${ROOT}" status --porcelain --untracked-files=no 2>/dev/null || true)"
  [[ -n "$status" ]]
}

update_project_if_possible() {
  if [[ "${N8N_SKIP_SELF_UPDATE:-}" = "1" ]]; then
    return 0
  fi

  printf '\n'
  if ! command -v git >/dev/null 2>&1; then
    print_git_install_hint
    return 0
  fi
  if ! git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    print_git_install_hint
    return 0
  fi

  body "正在從 origin/${UPDATE_REF} 更新專案 ..."

  if has_local_tracked_changes; then
    warn "偵測到本機改過專案檔，已略過自動更新以免覆蓋你的修改。"
    warn "設定請只改 .env。若要更新，請先自行處理本機變更後再啟動。"
    printf '\n'
    return 0
  fi

  local before after current_branch
  before="$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || true)"

  if ! git -C "${ROOT}" fetch origin "${UPDATE_REF}"; then
    warn "更新失敗，將以目前的程式碼繼續啟動。"
    printf '\n'
    return 0
  fi

  # 暫時略過切回 main，方便在 feature/allow-external-lib 上測試。
  # current_branch="$(git -C "${ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  # if [[ "$current_branch" != "$UPDATE_REF" ]]; then
  #   if ! git -C "${ROOT}" checkout -q "${UPDATE_REF}"; then
  #     if ! git -C "${ROOT}" checkout -q -B "${UPDATE_REF}" "origin/${UPDATE_REF}"; then
  #       warn "無法切換到 ${UPDATE_REF}，將以目前的程式碼繼續啟動。"
  #       printf '\n'
  #       return 0
  #     fi
  #   fi
  # fi

  if ! git -C "${ROOT}" merge --ff-only "origin/${UPDATE_REF}"; then
    warn "無法快轉到 origin/${UPDATE_REF}，將以目前的程式碼繼續啟動。"
    printf '\n'
    return 0
  fi

  after="$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$before" && "$before" = "$after" ]]; then
    success "專案已是最新。"
    printf '\n'
    return 0
  fi

  success "專案已更新。"
  trap - EXIT
  N8N_SKIP_SELF_UPDATE=1 exec "${ROOT}/start-n8n.sh" "$@"
}

update_project_if_possible

export N8N_ORCHESTRATED=1
cd "${ROOT}"

printf '\n'
title "════════════════════════════════════════════════════════════"
title "  n8n 本機啟動精靈"
title "════════════════════════════════════════════════════════════"

section "【步驟 1】設定檔"
if [[ -f "$ENV_FILE" ]]; then
  success "已有 .env，略過建立。"
  muted "  若要重建，請自行執行 ./scripts/create-envfile.sh"
else
  body "尚未找到 .env，開始引導建立。"
  run_script scripts/create-envfile.sh || exit 1
  if [[ ! -f "$ENV_FILE" ]]; then
    error "仍找不到 .env，無法繼續。"
    exit 1
  fi
  success "設定已寫入，接著設定 Code 節點並啟動 n8n。"
fi

configure_runners

SCENARIO="$(get_env_value N8N_SCENARIO)"
SCENARIO="$(printf '%s' "$SCENARIO" | tr '[:lower:]' '[:upper:]')"
N8N_IMAGE="$(get_env_value N8N_IMAGE)"
if [[ -z "$N8N_IMAGE" ]]; then
  N8N_IMAGE="n8nio/n8n:2.36.8"
fi

ENV_BOOT="$(get_env_value N8N_LOCAL_BOOTSTRAPPED)"
ENV_BOOT="$(printf '%s' "$ENV_BOOT" | tr '[:lower:]' '[:upper:]')"
PREV_SCENARIO="$(marker_scenario)"
BOOTSTRAPPED=0
if [[ -n "$ENV_BOOT" && "$ENV_BOOT" = "$SCENARIO" ]]; then
  BOOTSTRAPPED=1
elif [[ -n "$PREV_SCENARIO" && "$PREV_SCENARIO" = "$SCENARIO" ]]; then
  BOOTSTRAPPED=1
fi

SECRETS_READY=0
if ! is_placeholder "$(get_env_value N8N_ENCRYPTION_KEY)" \
  && ! is_placeholder "$(get_env_value CLOUD_DB_POSTGRESDB_HOST)"; then
  SECRETS_READY=1
fi

NEED_SECRETS=0
NEED_SYNC=0
case "$SCENARIO" in
  B)
    if [[ "$BOOTSTRAPPED" -eq 0 || "$SECRETS_READY" -eq 0 ]]; then
      NEED_SECRETS=1
    fi
    if [[ "$BOOTSTRAPPED" -eq 0 ]]; then
      NEED_SYNC=1
    fi
    ;;
  C)
    if [[ "$BOOTSTRAPPED" -eq 0 || "$SECRETS_READY" -eq 0 ]]; then
      NEED_SECRETS=1
    fi
    ;;
esac

section "【步驟 3】檢查環境"
if [[ "$NEED_SECRETS" -eq 1 ]]; then
  muted "  場景 ${SCENARIO} 首次或密鑰尚未寫入時，check-env 對密鑰的警告可先忽略，下一步會自動拉取。"
fi
printf '\n'
if ! run_script scripts/check-env.sh; then
  error "環境檢查未通過。請修正後再執行 ./start-n8n.sh"
  exit 1
fi

NO_PULL=0
if image_exists "$N8N_IMAGE" && { [[ "$BOOTSTRAPPED" -eq 1 ]] || project_has_containers; }; then
  NO_PULL=1
fi

section "【步驟 4】雲端密鑰"
case "$SCENARIO" in
  B|C)
    body "場景 ${SCENARIO} 需要 encryption key 與雲端資料庫連線，開始拉取密鑰。"
    run_script scripts/pull-secrets.sh || exit 1
    if is_placeholder "$(get_env_value N8N_ENCRYPTION_KEY)"; then
      error "pull-secrets 完成後 N8N_ENCRYPTION_KEY 仍是空的，無法繼續。"
      exit 1
    fi
    ;;
  *)
    success "場景 ${SCENARIO:-A} 不需要雲端密鑰。"
    ;;
esac

section "【步驟 5】啟動 n8n"
if [[ "$NO_PULL" -eq 1 ]]; then
  body "偵測到先前已啟動過，且映像已在本機。此次只啟動 container，不下載映像。"
  run_script scripts/start-local-n8n.sh --no-pull || exit 1
else
  body "依 .env 啟動容器；本機沒有的映像會在此時下載。"
  run_script scripts/start-local-n8n.sh || exit 1
fi

ENABLE_NGROK="$(get_env_value ENABLE_NGROK)"
ENABLE_NGROK="$(printf '%s' "$ENABLE_NGROK" | tr '[:upper:]' '[:lower:]')"
if [[ "$ENABLE_NGROK" = "true" ]]; then
  run_script scripts/check-ngrok-service.sh || true
fi

STEP5_SUMMARY=""
case "$SCENARIO" in
  B)
    if [[ "$NEED_SYNC" -eq 1 ]]; then
      section "【步驟 6】雲端資料"
      body "場景 B 首次啟動：將 Cloud Run 資料複製到本機 Postgres。"
      run_script scripts/sync-from-cloud.sh || exit 1
      STEP5_SUMMARY="場景 B 已將 Cloud Run 資料複製到本機。"
      write_bootstrapped "$SCENARIO" || warn "無法寫入啟動紀錄。"
    else
      STEP5_SUMMARY="場景 B 資料先前已同步，無需再次複製雲端資料。"
    fi
    ;;
  C)
    STEP5_SUMMARY="場景 C 直連遠端資料庫，無需同步雲端資料。"
    ;;
  *)
    STEP5_SUMMARY="場景 A 從空白環境開始，無需同步雲端資料。"
    ;;
esac

if [[ -n "$SCENARIO" ]]; then
  write_bootstrapped "$SCENARIO" || warn "無法寫入啟動紀錄。"
fi

print_ready_banner
printf '\n'
section "【步驟 6】雲端資料"
body "${STEP5_SUMMARY}"
printf '\n'
success "────────────────────────────────────────────────────────────"
success "  啟動流程完成。"
success "────────────────────────────────────────────────────────────"
printf '\n'
muted "之後只要再開一次，執行同一支 ./start-n8n.sh 即可。"
printf '\n'
