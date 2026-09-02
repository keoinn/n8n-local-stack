#!/usr/bin/env bash
# 檢查本機是否已具備啟動 n8n 的條件（macOS / Linux）。
# 相容 macOS 內建 Bash 3.2，請勿使用關聯陣列或 ${var,,}。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT}/.env"
PASS=0
WARN=0
FAIL=0

usage() {
  cat <<'EOF'
檢查本機是否已具備啟動 n8n 的條件。

會檢查：
  1. .env 是否存在
  2. N8N_SCENARIO 是否為 A / B / C
  3. 該場景必填變數是否已填（非空白、非範本值）
  4. Docker 是否安裝，且 daemon 是否在執行
  5. 場景 B / C 是否已安裝 gcloud，並已登入

用法：
  ./scripts/check-env.sh
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
muted() { printf '%b\n' "${C_DIM}$*${C_RESET}"; }
body() { printf '%b\n' "${C_WHITE}$*${C_RESET}"; }

ok() {
  printf '  %b[OK]%b    %s\n' "${C_GREEN}" "${C_RESET}" "$1"
  PASS=$((PASS + 1))
}

warn_item() {
  printf '  %b[WARN]%b  %s\n' "${C_YELLOW}" "${C_RESET}" "$1"
  if [[ $# -ge 2 && -n "$2" ]]; then
    muted "          $2"
  fi
  WARN=$((WARN + 1))
}

fail_item() {
  printf '  %b[FAIL]%b  %s\n' "${C_RED}" "${C_RESET}" "$1"
  if [[ $# -ge 2 && -n "$2" ]]; then
    muted "          $2"
  fi
  FAIL=$((FAIL + 1))
}

skip_item() {
  printf '  %b[—]%b     %s\n' "${C_DIM}" "${C_RESET}" "$1"
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

is_secret_key() {
  case "$1" in
    POSTGRES_PASSWORD|NGROK_AUTHTOKEN|N8N_ENCRYPTION_KEY|CLOUD_DB_POSTGRESDB_PASSWORD)
      return 0
      ;;
  esac
  return 1
}

require_env() {
  local key="$1"
  local hint="$2"
  local value
  value="$(get_env_value "$key")"
  if is_placeholder "$value"; then
    fail_item "${key} 未設定或仍為範本值" "$hint"
    return 1
  fi
  if is_secret_key "$key"; then
    ok "${key} 已設定"
  else
    ok "${key}=${value}"
  fi
  return 0
}

warn_if_missing_env() {
  local key="$1"
  local hint="$2"
  local value
  value="$(get_env_value "$key")"
  if is_placeholder "$value"; then
    warn_item "${key} 尚未寫入" "$hint"
    return 1
  fi
  if is_secret_key "$key"; then
    ok "${key} 已設定"
  else
    ok "${key}=${value}"
  fi
  return 0
}

normalize_bool() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

print_banner() {
  printf '\n'
  title "════════════════════════════════════════════════════════════"
  title "  n8n 本機環境檢查"
  title "════════════════════════════════════════════════════════════"
}

SCENARIO=""
ENABLE_NGROK=""
HAS_ENV=0

print_banner

section "【設定檔】"

if [[ -f "$ENV_FILE" ]]; then
  ok ".env 存在（${ENV_FILE}）"
  HAS_ENV=1
else
  fail_item ".env 不存在" "請先執行 ./scripts/create-envfile.sh"
fi

if [[ "$HAS_ENV" -eq 1 ]]; then
  SCENARIO="$(get_env_value N8N_SCENARIO)"
  SCENARIO="$(printf '%s' "$SCENARIO" | tr '[:lower:]' '[:upper:]')"
  ENABLE_NGROK="$(normalize_bool "$(get_env_value ENABLE_NGROK)")"

  if [[ -z "$SCENARIO" ]]; then
    fail_item "N8N_SCENARIO 未設定" "請填 A、B 或 C，或重新執行 ./scripts/create-envfile.sh"
  else
    case "$SCENARIO" in
      A|B|C)
        ok "N8N_SCENARIO=${SCENARIO}"
        ;;
      *)
        fail_item "N8N_SCENARIO=${SCENARIO} 不是有效場景" "請改為 A、B 或 C"
        SCENARIO=""
        ;;
    esac
  fi

  case "$SCENARIO" in
    A)
      require_env POSTGRES_PASSWORD "場景 A 需要本機 Postgres 密碼，請勿填雲端資料庫帳密。"
      require_env POSTGRES_DB "請在 .env 設定 POSTGRES_DB（預設 n8n）。"
      require_env POSTGRES_USER "請在 .env 設定 POSTGRES_USER（預設 n8n）。"
      ;;
    B)
      require_env POSTGRES_PASSWORD "場景 B 需要本機 Postgres 密碼，請勿填雲端資料庫帳密。"
      require_env POSTGRES_DB "請在 .env 設定 POSTGRES_DB（預設 n8n）。"
      require_env POSTGRES_USER "請在 .env 設定 POSTGRES_USER（預設 n8n）。"
      require_env GCP_PROJECT "請填 Google Cloud 專案 ID。"
      require_env GCP_REGION "請填 Cloud Run 區域，例如 asia-east1。"
      require_env GCP_RUN_SERVICE "請填 Cloud Run 服務名稱。"
      warn_if_missing_env N8N_ENCRYPTION_KEY "啟動前請執行 ./scripts/pull-secrets.sh，否則無法解密雲端 Credentials。"
      warn_if_missing_env CLOUD_DB_POSTGRESDB_HOST "同步雲端資料前請執行 ./scripts/pull-secrets.sh。"
      warn_if_missing_env CLOUD_DB_POSTGRESDB_USER "同步雲端資料前請執行 ./scripts/pull-secrets.sh。"
      warn_if_missing_env CLOUD_DB_POSTGRESDB_PASSWORD "同步雲端資料前請執行 ./scripts/pull-secrets.sh。"
      ;;
    C)
      require_env GCP_PROJECT "請填 Google Cloud 專案 ID。"
      require_env GCP_REGION "請填 Cloud Run 區域，例如 asia-east1。"
      require_env GCP_RUN_SERVICE "請填 Cloud Run 服務名稱。"
      warn_if_missing_env N8N_ENCRYPTION_KEY "啟動前請執行 ./scripts/pull-secrets.sh。"
      warn_if_missing_env CLOUD_DB_POSTGRESDB_HOST "場景 C 直連遠端 Supabase，啟動前請執行 ./scripts/pull-secrets.sh。"
      warn_if_missing_env CLOUD_DB_POSTGRESDB_USER "場景 C 直連遠端 Supabase，啟動前請執行 ./scripts/pull-secrets.sh。"
      warn_if_missing_env CLOUD_DB_POSTGRESDB_PASSWORD "場景 C 直連遠端 Supabase，啟動前請執行 ./scripts/pull-secrets.sh。"
      if [[ -f "${ROOT}/compose.remote-supabase.yml" ]]; then
        ok "compose.remote-supabase.yml 存在"
      else
        fail_item "找不到 compose.remote-supabase.yml" "場景 C 啟動時需要此檔。"
      fi
      ;;
    *)
      skip_item "場景必填變數：因 N8N_SCENARIO 無效而略過"
      ;;
  esac

  case "$ENABLE_NGROK" in
    true|yes|1|y)
      ok "ENABLE_NGROK=true"
      require_env NGROK_AUTHTOKEN "可於 https://ngrok.com/ 儀表板取得 Auth Token。"
      NGROK_DOMAIN="$(get_env_value NGROK_DOMAIN)"
      if is_placeholder "$NGROK_DOMAIN"; then
        fail_item "NGROK_DOMAIN 未設定或仍為範本值" "只填主機名，不要加 https://。"
      else
        lower_domain="$(printf '%s' "$NGROK_DOMAIN" | tr '[:upper:]' '[:lower:]')"
        if printf '%s' "$lower_domain" | grep -qE 'https?://'; then
          fail_item "NGROK_DOMAIN=${NGROK_DOMAIN} 含有通訊協定" "請只填主機名，例如 example.ngrok-free.dev。"
        elif ! printf '%s' "$NGROK_DOMAIN" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'; then
          fail_item "NGROK_DOMAIN=${NGROK_DOMAIN} 格式不正確" "請填至少包含主域名與頂級網域的主機名。"
        else
          ok "NGROK_DOMAIN=${NGROK_DOMAIN}"
        fi
      fi
      ;;
    false|no|0|n)
      ok "ENABLE_NGROK=false（僅本機編輯，無法使用對外 webhook）"
      ;;
    '')
      warn_item "ENABLE_NGROK 未設定" "啟動腳本會預設為 true。請在 .env 明確填 true 或 false。"
      ;;
    *)
      fail_item "ENABLE_NGROK=${ENABLE_NGROK} 不是有效值" "請填 true 或 false。"
      ;;
  esac
else
  skip_item "場景與必填變數：因缺少 .env 而略過"
fi

section "【Docker】"

if command -v docker >/dev/null 2>&1; then
  docker_ver="$(docker --version 2>/dev/null || true)"
  if [[ -n "$docker_ver" ]]; then
    ok "Docker 已安裝（${docker_ver}）"
  else
    ok "Docker 已安裝"
  fi
else
  fail_item "找不到 docker 指令" "請安裝 Docker Desktop，然後重新開啟終端機。"
fi

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    ok "Docker daemon 正在執行"
  else
    fail_item "Docker 已安裝但 daemon 未啟動" "請開啟 Docker Desktop，等到引擎就緒後再重試。"
  fi

  if docker compose version >/dev/null 2>&1; then
    compose_ver="$(docker compose version 2>/dev/null | head -n 1 || true)"
    if [[ -n "$compose_ver" ]]; then
      ok "Docker Compose 可用（${compose_ver}）"
    else
      ok "Docker Compose 可用"
    fi
  else
    fail_item "找不到 docker compose 外掛" "本專案使用 Docker Compose V2（docker compose，不是 docker-compose）。"
  fi
else
  skip_item "Docker daemon / Compose：因找不到 docker 而略過"
fi

section "【Google Cloud SDK】"

case "$SCENARIO" in
  B|C)
    if command -v gcloud >/dev/null 2>&1; then
      ok "gcloud 已安裝（$(command -v gcloud)）"
    else
      fail_item "找不到 gcloud" "macOS 可執行：brew install --cask google-cloud-sdk"
    fi

    if command -v gcloud >/dev/null 2>&1; then
      gcloud_account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1 || true)"
      gcloud_account="$(sanitize_env_value "$gcloud_account")"
      if [[ -n "$gcloud_account" ]]; then
        ok "gcloud 已登入（${gcloud_account}）"
      else
        fail_item "gcloud 尚未登入" "請執行：gcloud auth login"
      fi

      gcloud_project="$(gcloud config get-value project 2>/dev/null || true)"
      gcloud_project="$(sanitize_env_value "$gcloud_project")"
      case "$gcloud_project" in
        ''|'(unset)')
          warn_item "gcloud 尚未設定預設專案" "請執行：gcloud config set project <你的 GCP 專案 ID>"
          ;;
        *)
          env_project="$(get_env_value GCP_PROJECT)"
          if ! is_placeholder "$env_project" && [[ "$gcloud_project" != "$env_project" ]]; then
            warn_item "gcloud 目前專案是 ${gcloud_project}，與 .env 的 GCP_PROJECT=${env_project} 不同" "pull-secrets 會使用 .env 的 GCP_PROJECT；若不對請執行 gcloud config set project ${env_project}"
          else
            ok "gcloud 專案=${gcloud_project}"
          fi
          ;;
      esac
    else
      skip_item "gcloud 登入與專案：因找不到 gcloud 而略過"
    fi
    ;;
  A)
    skip_item "場景 A 不需要 gcloud"
    ;;
  *)
    skip_item "gcloud：因場景未確定而略過"
    ;;
esac

printf '\n'
title "────────────────────────────────────────────────────────────"
if [[ "$FAIL" -eq 0 && "$WARN" -eq 0 ]]; then
  printf '%b\n' "${C_GREEN}${C_BOLD}  摘要：${PASS} 項通過，環境已就緒。${C_RESET}"
elif [[ "$FAIL" -eq 0 ]]; then
  printf '%b\n' "${C_YELLOW}${C_BOLD}  摘要：${PASS} 項通過、${WARN} 項警告。可繼續，但建議先處理警告。${C_RESET}"
else
  printf '%b\n' "${C_RED}${C_BOLD}  摘要：${PASS} 項通過、${WARN} 項警告、${FAIL} 項失敗。${C_RESET}"
fi
title "────────────────────────────────────────────────────────────"
printf '\n'

if [[ "$FAIL" -gt 0 ]]; then
  body "建議下一步："
  if [[ "$HAS_ENV" -eq 0 ]]; then
    muted "  ./scripts/create-envfile.sh"
  else
    case "$SCENARIO" in
      B|C)
        muted "  修正上方失敗項目後，若密鑰尚未寫入，再執行 ./scripts/pull-secrets.sh"
        ;;
      *)
        muted "  修正 .env 或安裝缺少的工具後，再執行本檢查。"
        ;;
    esac
  fi
elif [[ "$WARN" -gt 0 ]]; then
  body "建議下一步："
  case "$SCENARIO" in
    B|C)
      muted "  ./scripts/pull-secrets.sh"
      muted "  完成後再執行 ./scripts/start-local-n8n.sh"
      ;;
    *)
      muted "  ./scripts/start-local-n8n.sh"
      ;;
  esac
else
  body "建議下一步："
  muted "  ./scripts/start-local-n8n.sh"
fi
printf '\n'

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
