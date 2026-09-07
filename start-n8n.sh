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
  2. 檢查環境（check-env）
  3. 場景 B / C：必要時拉取雲端密鑰（pull-secrets）
  4. 依 .env 啟動 container（start-local-n8n）
  5. 場景 B：首次啟動時同步雲端資料（sync-from-cloud）

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

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
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

write_marker() {
  mkdir -p "${ROOT}/data"
  printf 'N8N_SCENARIO=%s\nBOOTSTRAPPED_AT=%s\n' "$1" "$(date +%Y-%m-%dT%H:%M:%S)" > "${MARKER_FILE}"
}

print_ready_banner() {
  local enable_ngrok domain internal_url external_url
  enable_ngrok="$(get_env_value ENABLE_NGROK)"
  domain="$(get_env_value NGROK_DOMAIN)"
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
  printf '%b\n' "  ${C_WHITE}內部網址${C_RESET}      ${C_CYAN}${internal_url}${C_RESET}"
  if [[ -n "$external_url" ]]; then
    printf '%b\n' "  ${C_WHITE}外部網址${C_RESET}      ${C_CYAN}${external_url}${C_RESET}"
    printf '%b\n' "  ${C_WHITE}ngrok 檢查頁${C_RESET}  ${C_CYAN}http://127.0.0.1:4040${C_RESET}"
  else
    printf '%b\n' "  ${C_WHITE}外部網址${C_RESET}      ${C_YELLOW}未啟用 ngrok，無法使用對外 webhook${C_RESET}"
  fi
  printf '\n'
  success "請以內部網址開啟本機編輯器；OAuth / Webhook 請使用外部網址。"
}

marker_scenario() {
  if [[ ! -f "$MARKER_FILE" ]]; then
    return 0
  fi
  local raw
  raw="$(grep -E '^N8N_SCENARIO=' "$MARKER_FILE" | tail -n 1 || true)"
  raw="${raw#N8N_SCENARIO=}"
  sanitize_env_value "$raw"
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
  success "設定已寫入，接著檢查環境並啟動 n8n。"
fi

SCENARIO="$(get_env_value N8N_SCENARIO)"
SCENARIO="$(printf '%s' "$SCENARIO" | tr '[:lower:]' '[:upper:]')"
N8N_IMAGE="$(get_env_value N8N_IMAGE)"
if [[ -z "$N8N_IMAGE" ]]; then
  N8N_IMAGE="n8nio/n8n:2.36.8"
fi

PREV_SCENARIO="$(marker_scenario)"
BOOTSTRAPPED=0
if [[ -n "$PREV_SCENARIO" && "$PREV_SCENARIO" = "$SCENARIO" ]]; then
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

section "【步驟 2】檢查環境"
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

section "【步驟 3】雲端密鑰"
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

section "【步驟 4】啟動 n8n"
if [[ "$NO_PULL" -eq 1 ]]; then
  body "偵測到先前已啟動過，且映像已在本機。此次只啟動 container，不下載映像。"
  run_script scripts/start-local-n8n.sh --no-pull || exit 1
else
  body "依 .env 啟動容器；本機沒有的映像會在此時下載。"
  run_script scripts/start-local-n8n.sh || exit 1
fi

STEP5_SUMMARY=""
case "$SCENARIO" in
  B)
    if [[ "$NEED_SYNC" -eq 1 ]]; then
      section "【步驟 5】雲端資料"
      body "場景 B 首次啟動：將 Cloud Run 資料複製到本機 Postgres。"
      run_script scripts/sync-from-cloud.sh || exit 1
      STEP5_SUMMARY="場景 B 已將 Cloud Run 資料複製到本機。"
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
  write_marker "$SCENARIO" || warn "無法寫入啟動紀錄。"
fi

print_ready_banner
printf '\n'
section "【步驟 5】雲端資料"
body "${STEP5_SUMMARY}"
printf '\n'
success "────────────────────────────────────────────────────────────"
success "  啟動流程完成。"
success "────────────────────────────────────────────────────────────"
printf '\n'
muted "之後只要再開一次，執行同一支 ./start-n8n.sh 即可。"
printf '\n'
