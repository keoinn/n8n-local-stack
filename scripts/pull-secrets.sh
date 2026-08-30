#!/usr/bin/env bash
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

if ! command -v python3 >/dev/null 2>&1; then
  echo "找不到 python3，寫入 .env 需要它。" >&2
  exit 1
fi

upsert_env() {
  local key="$1"
  local value="$2"
  python3 - "$key" "$value" "${ENV_FILE}" <<'PY'
import sys
from pathlib import Path

key, value, path = sys.argv[1], sys.argv[2], Path(sys.argv[3])
quoted = "'" + value.replace("'", "'\\''") + "'"
line = f"{key}={quoted}"
text = path.read_text() if path.exists() else ""
lines = text.splitlines()
found = False
out = []
for existing in lines:
    if existing.startswith(f"{key}=") and not existing.startswith("#"):
        out.append(line)
        found = True
    else:
        out.append(existing)
if not found:
    if out and out[-1] != "":
        out.append("")
    out.append(line)
path.write_text("\n".join(out) + "\n")
PY
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
cloud_json_file="$(mktemp)"
trap 'rm -f "${cloud_json_file}"' EXIT
if gcloud run services describe "${GCP_RUN_SERVICE}" \
  --project="${GCP_PROJECT}" \
  --region="${GCP_REGION}" \
  --format=json > "${cloud_json_file}"; then
  python3 - "${ENV_FILE}" "${cloud_json_file}" <<'PY'
import json, sys
from pathlib import Path

env_path = Path(sys.argv[1])
svc = json.loads(Path(sys.argv[2]).read_text())
envs = svc["spec"]["template"]["spec"]["containers"][0].get("env", [])
mapping = {
    "DB_POSTGRESDB_HOST": "CLOUD_DB_POSTGRESDB_HOST",
    "DB_POSTGRESDB_PORT": "CLOUD_DB_POSTGRESDB_PORT",
    "DB_POSTGRESDB_DATABASE": "CLOUD_DB_POSTGRESDB_DATABASE",
    "DB_POSTGRESDB_USER": "CLOUD_DB_POSTGRESDB_USER",
    "DB_POSTGRESDB_SCHEMA": "CLOUD_DB_POSTGRESDB_SCHEMA",
}
values = {}
for item in envs:
    name = item.get("name")
    if name in mapping and "value" in item and item["value"]:
        values[mapping[name]] = item["value"]

def upsert(key, value):
    quoted = "'" + value.replace("'", "'\\''") + "'"
    line = f"{key}={quoted}"
    text = env_path.read_text() if env_path.exists() else ""
    lines = text.splitlines()
    found = False
    out = []
    for existing in lines:
        if existing.startswith(f"{key}=") and not existing.startswith("#"):
            out.append(line)
            found = True
        else:
            out.append(existing)
    if not found:
        if out and out[-1] != "":
            out.append("")
        out.append(line)
    env_path.write_text("\n".join(out) + "\n")

for key, value in values.items():
    upsert(key, value)
    print(f"已寫入 {key}")
PY
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
