#!/usr/bin/env bash
# 從 GCP Secret Manager / Cloud Run 寫入 .env（macOS / Linux）。
# 相容 macOS 內建 Bash 3.2，請勿使用關聯陣列或 ${var,,}。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${ROOT}/.env.example" "${ENV_FILE}"
  echo "已從 .env.example 建立 ${ENV_FILE}"
fi

# shellcheck disable=SC1090
set -a
source "${ENV_FILE}"
set +a

GCP_PROJECT="${GCP_PROJECT:-n8n-and-ai-168888}"
GCP_REGION="${GCP_REGION:-asia-east1}"
GCP_RUN_SERVICE="${GCP_RUN_SERVICE:-n8n}"

mkdir -p "${ROOT}/data/n8n" "${ROOT}/data/postgres" "${ROOT}/exports"
chmod 777 "${ROOT}/data/n8n" "${ROOT}/exports" 2>/dev/null || true

if ! command -v gcloud >/dev/null 2>&1; then
  echo "找不到 gcloud，請先安裝 Google Cloud SDK 並登入。" >&2
  exit 1
fi

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
  value="$(printf '%s' "$2" | tr -d '\r')"
  quoted="$(quote_env_value "$value")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/pull-secrets.XXXXXX")"
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

# 從 gcloud --format=text 取出第一個 container 某個 env 的 value（略過 valueFrom）。
env_from_text() {
  local file="$1"
  local name="$2"
  local idx value
  idx="$(
    grep -E 'spec\.template\.spec\.containers\[0\]\.env\[[0-9]+\]\.name:' "$file" \
      | grep -E ":[[:space:]]*${name}[[:space:]]*$" \
      | sed -n 's/.*\.env\[\([0-9][0-9]*\)\]\.name:.*/\1/p' \
      | head -n 1 \
      || true
  )"
  if [[ -z "$idx" ]]; then
    return 0
  fi
  value="$(
    grep -E "spec\\.template\\.spec\\.containers\\[0\\]\\.env\\[${idx}\\]\\.value:" "$file" \
      | head -n 1 \
      | sed 's/.*\.value:[[:space:]]*//' \
      | tr -d '\r' \
      | sed 's/[[:space:]]*$//' \
      || true
  )"
  printf '%s' "$value"
}

write_mapped_cloud_env() {
  local text_file="$1"
  local pair cloud_key env_key value
  for pair in \
    "DB_POSTGRESDB_HOST:CLOUD_DB_POSTGRESDB_HOST" \
    "DB_POSTGRESDB_PORT:CLOUD_DB_POSTGRESDB_PORT" \
    "DB_POSTGRESDB_DATABASE:CLOUD_DB_POSTGRESDB_DATABASE" \
    "DB_POSTGRESDB_USER:CLOUD_DB_POSTGRESDB_USER" \
    "DB_POSTGRESDB_SCHEMA:CLOUD_DB_POSTGRESDB_SCHEMA"
  do
    cloud_key="${pair%%:*}"
    env_key="${pair#*:}"
    value="$(env_from_text "$text_file" "$cloud_key")"
    if [[ -n "$value" ]]; then
      upsert_env "$env_key" "$value"
      echo "已寫入 ${env_key}"
    fi
  done
}

echo "從 Secret Manager 讀取 n8n-encryption-key ..."
encryption_key="$(
  gcloud secrets versions access latest \
    --secret=n8n-encryption-key \
    --project="${GCP_PROJECT}"
)"
if [[ -z "${encryption_key}" ]]; then
  echo "n8n-encryption-key 是空的。" >&2
  exit 1
fi
upsert_env N8N_ENCRYPTION_KEY "${encryption_key}"
echo "已寫入 N8N_ENCRYPTION_KEY"

echo "從 Secret Manager 讀取 supabase-db-password ..."
db_password="$(
  gcloud secrets versions access latest \
    --secret=supabase-db-password \
    --project="${GCP_PROJECT}"
)"
if [[ -z "${db_password}" ]]; then
  echo "supabase-db-password 是空的。" >&2
  exit 1
fi
upsert_env CLOUD_DB_POSTGRESDB_PASSWORD "${db_password}"
echo "已寫入 CLOUD_DB_POSTGRESDB_PASSWORD"

echo "從 Cloud Run 讀取 Supabase 連線設定 ..."
cloud_text_file="$(mktemp "${TMPDIR:-/tmp}/pull-secrets-run.XXXXXX")"
trap 'rm -f "${cloud_text_file}"' EXIT
if gcloud run services describe "${GCP_RUN_SERVICE}" \
  --project="${GCP_PROJECT}" \
  --region="${GCP_REGION}" \
  --format=text \
  > "${cloud_text_file}"; then
  write_mapped_cloud_env "${cloud_text_file}"
else
  echo "無法讀取 Cloud Run 服務，請自行確認 .env 裡的 CLOUD_DB_POSTGRESDB_*。" >&2
fi

upsert_env GCP_PROJECT "${GCP_PROJECT}"
upsert_env GCP_REGION "${GCP_REGION}"
upsert_env GCP_RUN_SERVICE "${GCP_RUN_SERVICE}"

echo
echo "完成。請確認 .env 的勿動區已寫入 N8N_ENCRYPTION_KEY 與 CLOUD_DB_*。"
echo
echo "場景 B（複製到本機 Postgres，不改雲端資料）："
echo "  docker compose --profile tunnel up -d"
echo "  ./scripts/sync-from-cloud.sh"
echo
echo "場景 C（本機 n8n 直連遠端 Supabase）："
echo "  docker compose -f compose.yml -f compose.remote-supabase.yml --profile tunnel up -d"
echo "  不要跑 ./scripts/sync-from-cloud.sh"
echo
echo "注意："
echo "  - 請先 pull-secrets 再啟動容器，n8n 才會用 Cloud Run 同一把 encryption key。"
echo "  - 場景 C 與 Cloud Run 共用同一顆庫；兩邊同時開著，排程 / webhook 可能各跑一次。"
echo "  - 從 A / B 切到 C 時，先 docker compose --profile tunnel down。"
echo "  - 只要本機編輯、不上 ngrok，把指令裡的 --profile tunnel 拿掉即可。"
