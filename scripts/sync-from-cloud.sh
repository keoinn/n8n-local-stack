#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT}/.env"
CREDENTIALS_ONLY=0
KEEP_EXPORTS=0

usage() {
  cat <<'EOF'
用法：
  ./scripts/sync-from-cloud.sh                 完整複製使用者、Credentials、工作流程
  ./scripts/sync-from-cloud.sh --credentials-only   只從雲端匯入 Credentials
  ./scripts/sync-from-cloud.sh --keep-exports       同步後保留 exports/ 暫存檔
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --credentials-only) CREDENTIALS_ONLY=1 ;;
    --keep-exports) KEEP_EXPORTS=1 ;;
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
  echo "找不到 ${ENV_FILE}，請先複製 .env.example 並執行 ./scripts/pull-secrets.sh" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "${ENV_FILE}"
set +a

N8N_IMAGE="${N8N_IMAGE:-n8nio/n8n:2.36.8}"
required_vars=(
  N8N_ENCRYPTION_KEY
  CLOUD_DB_POSTGRESDB_HOST
  CLOUD_DB_POSTGRESDB_PORT
  CLOUD_DB_POSTGRESDB_DATABASE
  CLOUD_DB_POSTGRESDB_USER
  CLOUD_DB_POSTGRESDB_PASSWORD
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "${var_name} 是空的。請先執行 ./scripts/pull-secrets.sh" >&2
    exit 1
  fi
done

if ! command -v docker >/dev/null 2>&1; then
  echo "找不到 docker。" >&2
  exit 1
fi

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

echo "確認本機 Postgres 與 n8n 已做過 migration ..."
docker compose up -d postgres n8n
wait_for_service postgres 90
wait_for_service n8n 240

echo "暫停本機 n8n，避免匯入時寫入衝突 ..."
docker compose stop n8n

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

export_from_cloud() {
  docker run --rm \
    --user node \
    "${cloud_db_env[@]}" \
    -v "${ROOT}/exports:/exports" \
    "${N8N_IMAGE}" \
    "$@"
}

if [[ "${CREDENTIALS_ONLY}" -eq 0 ]]; then
  echo "從 Supabase 匯出全部 entities ..."
  rm -rf "${ROOT}/exports/entities"
  mkdir -p "${ROOT}/exports/entities"
  chmod 777 "${ROOT}/exports/entities" 2>/dev/null || true
  export_from_cloud export:entities --outputDir=/exports/entities
fi

echo "從 Supabase 匯出 Credentials ..."
export_from_cloud export:credentials --all --output=/exports/credentials.json

if [[ "${CREDENTIALS_ONLY}" -eq 1 ]]; then
  echo "把 Credentials 匯入本機 ..."
  docker compose run --rm --no-deps n8n \
    import:credentials --input=/exports/credentials.json
else
  echo "把 entities 匯入本機（會清空本機對應資料表） ..."
  docker compose run --rm --no-deps n8n \
    import:entities --inputDir=/exports/entities --truncateTables true
  echo "取消發布本機全部工作流程，避免和 Cloud Run 同時觸發 ..."
  if ! docker compose run --rm --no-deps n8n unpublish:workflow --all; then
    echo "unpublish:workflow 失敗，改用 update:workflow --active=false ..."
    docker compose run --rm --no-deps n8n update:workflow --all --active=false
  fi
fi

echo "重新啟動本機 n8n ..."
docker compose up -d n8n
wait_for_service n8n 240

if [[ "${KEEP_EXPORTS}" -eq 0 ]]; then
  echo "清除 exports/ 暫存檔 ..."
  rm -rf "${ROOT}/exports/entities" "${ROOT}/exports/credentials.json"
fi

echo
echo "同步完成。編輯器：http://localhost:5678"
echo "請用 Cloud Run 同一組帳密登入。"
echo "需要外網 webhook 時：docker compose --profile tunnel up -d"
