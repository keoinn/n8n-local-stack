#!/usr/bin/env bash
# 場景 B：把本機 n8n 資料回寫到 Supabase（Cloud Run 正在用的那份）。
# 相容 macOS 內建 Bash 3.2。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT}/.env"
CREDENTIALS_ONLY=0
KEEP_EXPORTS=0
ASSUME_YES=0

usage() {
  cat <<'EOF'
把本機 n8n 資料回寫到 Supabase。僅限場景 B。

會清空雲端對應資料表再匯入。Cloud Run 若仍在跑，可能與回寫衝突。
回寫後，雲端工作流程的發布狀態會與本機相同。

用法：
  ./scripts/sync-to-cloud.sh                 完整回寫使用者、Credentials、工作流程
  ./scripts/sync-to-cloud.sh --credentials-only   只把本機 Credentials 寫回雲端
  ./scripts/sync-to-cloud.sh --keep-exports       回寫後保留 exports/ 暫存檔
  ./scripts/sync-to-cloud.sh --yes                略過確認（非互動或腳本使用）
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --credentials-only) CREDENTIALS_ONLY=1 ;;
    --keep-exports) KEEP_EXPORTS=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
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

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "找不到 ${ENV_FILE}，請先執行 ./start-n8n.sh 或 ./scripts/create-envfile.sh" >&2
  exit 1
fi

sanitize_env_value() {
  printf '%s' "$1" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

get_env_value() {
  local key="$1"
  local raw=""
  raw="$(grep -E "^${key}=" "$ENV_FILE" | tail -n 1 || true)"
  raw="${raw#${key}=}"
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

# shellcheck disable=SC1090
set -a
source "${ENV_FILE}"
set +a

N8N_IMAGE="${N8N_IMAGE:-n8nio/n8n:2.36.8}"
SCENARIO="$(get_env_value N8N_SCENARIO)"
SCENARIO="$(printf '%s' "$SCENARIO" | tr '[:lower:]' '[:upper:]')"

if [[ "$SCENARIO" != "B" ]]; then
  echo "此腳本只適用場景 B（本機 Postgres 複本回寫雲端）。目前 N8N_SCENARIO=${SCENARIO:-未設定}。" >&2
  if [[ "$SCENARIO" = "C" ]]; then
    echo "場景 C 已直連 Supabase，不需要回寫。" >&2
  fi
  exit 1
fi

required_vars=(
  N8N_ENCRYPTION_KEY
  POSTGRES_DB
  POSTGRES_USER
  POSTGRES_PASSWORD
  CLOUD_DB_POSTGRESDB_HOST
  CLOUD_DB_POSTGRESDB_PORT
  CLOUD_DB_POSTGRESDB_DATABASE
  CLOUD_DB_POSTGRESDB_USER
  CLOUD_DB_POSTGRESDB_PASSWORD
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "$(get_env_value "$var_name")" ]]; then
    echo "${var_name} 是空的。請先執行 ./scripts/pull-secrets.sh" >&2
    exit 1
  fi
done

if ! command -v docker >/dev/null 2>&1; then
  echo "找不到 docker。" >&2
  exit 1
fi

confirm_writeback() {
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "非互動環境請加上 --yes。" >&2
    exit 1
  fi
  echo
  echo "即將用本機 n8n 資料覆寫 Supabase（Cloud Run 正在用的那份）。"
  echo "  · 雲端使用者、憑證與工作流程會先被清空再匯入"
  echo "  · 雲端流程的發布狀態會變成與本機相同"
  echo "  · 請先把 Cloud Run 縮成 0，或暫停雲端流程，避免兩邊同時寫入"
  echo
  printf '確定回寫請輸入 WRITE：'
  local answer=""
  IFS= read -r answer || true
  answer="$(printf '%s' "$answer" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ "$answer" != "WRITE" ]]; then
    echo "已取消。" >&2
    exit 1
  fi
  echo
}

mkdir -p "${ROOT}/data/n8n" "${ROOT}/data/postgres" "${ROOT}/exports/entities"
chmod 777 "${ROOT}/data/n8n" "${ROOT}/exports" "${ROOT}/exports/entities" 2>/dev/null || true
cd "${ROOT}"

wait_for_service() {
  local service="$1"
  local timeout="${2:-180}"
  local elapsed=0
  echo "等待 ${service} 就緒 ..."
  until docker compose exec -T "${service}" sh -c '
    if command -v pg_isready >/dev/null 2>&1; then
      pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"
    else
      wget -qO- http://127.0.0.1:5678/health >/dev/null
    fi
  ' >/dev/null 2>&1; do
    if [[ "${elapsed}" -ge "${timeout}" ]]; then
      echo "${service} 在 ${timeout} 秒內沒有變成 healthy。" >&2
      docker compose logs --tail=80 "${service}" >&2 || true
      exit 1
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
}

ENABLE_RUNNERS="$(printf '%s' "$(get_env_value ENABLE_N8N_RUNNERS)" | tr '[:upper:]' '[:lower:]')"
compose_up=(compose)
compose_stop=(compose)
if [[ "$ENABLE_RUNNERS" = "true" ]]; then
  compose_up+=(--profile runners up -d postgres n8n task-runners)
  compose_stop+=(--profile runners stop n8n task-runners)
else
  compose_up+=(up -d postgres n8n)
  compose_stop+=(stop n8n)
fi

confirm_writeback

echo "確認本機 Postgres 與 n8n 已做過 migration ..."
docker "${compose_up[@]}"
wait_for_service postgres 90
wait_for_service n8n 240

echo "暫停本機 n8n，避免匯出時寫入衝突 ..."
docker "${compose_stop[@]}"

cloud_db_env=(
  -e "N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}"
  -e "DB_TYPE=postgresdb"
  -e "DB_POSTGRESDB_HOST=${CLOUD_DB_POSTGRESDB_HOST}"
  -e "DB_POSTGRESDB_PORT=${CLOUD_DB_POSTGRESDB_PORT}"
  -e "DB_POSTGRESDB_DATABASE=${CLOUD_DB_POSTGRESDB_DATABASE}"
  -e "DB_POSTGRESDB_USER=${CLOUD_DB_POSTGRESDB_USER}"
  -e "DB_POSTGRESDB_PASSWORD=${CLOUD_DB_POSTGRESDB_PASSWORD}"
  -e "DB_POSTGRESDB_SCHEMA=${CLOUD_DB_POSTGRESDB_SCHEMA:-public}"
  -e "DB_POSTGRESDB_SSL_ENABLED=true"
  -e "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED=false"
  -e "DB_POSTGRESDB_CONNECTION_TIMEOUT=30000"
  -e "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true"
)

import_to_cloud() {
  docker run --rm \
    --user node \
    "${cloud_db_env[@]}" \
    -v "${ROOT}/exports:/exports" \
    "${N8N_IMAGE}" \
    "$@"
}

rm -rf "${ROOT}/exports/entities"
mkdir -p "${ROOT}/exports/entities"
chmod 777 "${ROOT}/exports/entities" 2>/dev/null || true

if [[ "${CREDENTIALS_ONLY}" -eq 0 ]]; then
  echo "從本機匯出全部 entities ..."
  docker compose run --rm --no-deps n8n \
    export:entities --outputDir=/exports/entities
fi

echo "從本機匯出 Credentials ..."
docker compose run --rm --no-deps n8n \
  export:credentials --all --output=/exports/credentials.json

if [[ "${CREDENTIALS_ONLY}" -eq 1 ]]; then
  echo "把本機 Credentials 寫回 Supabase ..."
  import_to_cloud import:credentials --input=/exports/credentials.json
else
  echo "把本機 entities 寫回 Supabase（會清空雲端對應資料表） ..."
  import_to_cloud import:entities --inputDir=/exports/entities --truncateTables true
fi

echo "重新啟動本機 n8n ..."
if [[ "$ENABLE_RUNNERS" = "true" ]]; then
  docker compose --profile runners up -d n8n task-runners
else
  docker compose up -d n8n
fi
wait_for_service n8n 240

if [[ "${KEEP_EXPORTS}" -eq 0 ]]; then
  echo "清除 exports/ 暫存檔 ..."
  rm -rf "${ROOT}/exports/entities" "${ROOT}/exports/credentials.json"
fi

echo
echo "本機資料已回寫到 Supabase。"
if [[ "${CREDENTIALS_ONLY}" -eq 0 ]]; then
  echo "請到 Cloud Run 確認工作流程發布狀態是否符合預期。"
fi
