#!/usr/bin/env bash
# 把 Cloud Run 的 n8n 固定成與本機相同的映像（預設 n8nio/n8n:2.36.8）。
# 不可使用 n8nio/n8n:latest：場景 B 匯出會因雲端 schema 與本機版本不一致而失敗。
# 相容 macOS 內建 Bash 3.2。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT}/.env"
ASSUME_YES=0

usage() {
  cat <<'EOF'
把 Cloud Run 服務 n8n 部署成固定版本映像（與本機 N8N_IMAGE 相同，預設 2.36.8）。

會沿用你現有的 Cloud Run 連線與 Secret（encryption key、Supabase 密碼）。
不要用 n8nio/n8n:latest。

用法：
  ./scripts/deploy-cloud-run.sh
  ./scripts/deploy-cloud-run.sh --yes    略過確認
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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

if [[ ! -f "$ENV_FILE" ]]; then
  echo "找不到 ${ENV_FILE}，請先執行 ./n8n-開關機(macOS).sh 或 ./scripts/create-envfile.sh" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "${ENV_FILE}"
set +a

sanitize() {
  printf '%s' "$1" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

GCP_PROJECT="$(sanitize "${GCP_PROJECT:-}")"
GCP_REGION="$(sanitize "${GCP_REGION:-asia-east1}")"
GCP_RUN_SERVICE="$(sanitize "${GCP_RUN_SERVICE:-n8n}")"
GCP_RUN_SERVICE_ACCOUNT="$(sanitize "${GCP_RUN_SERVICE_ACCOUNT:-}")"
N8N_IMAGE="$(sanitize "${N8N_IMAGE:-n8nio/n8n:2.36.8}")"
CLOUD_HOST="$(sanitize "${CLOUD_DB_POSTGRESDB_HOST:-}")"
CLOUD_PORT="$(sanitize "${CLOUD_DB_POSTGRESDB_PORT:-5432}")"
CLOUD_DB="$(sanitize "${CLOUD_DB_POSTGRESDB_DATABASE:-postgres}")"
CLOUD_USER="$(sanitize "${CLOUD_DB_POSTGRESDB_USER:-}")"

case "$N8N_IMAGE" in
  *:latest|n8nio/n8n:latest)
    echo "N8N_IMAGE 不可用 latest。請改成 n8nio/n8n:2.36.8（與本機相同）。" >&2
    exit 1
    ;;
esac

if ! command -v gcloud >/dev/null 2>&1; then
  echo "找不到 gcloud。" >&2
  exit 1
fi

if [[ -z "$GCP_PROJECT" || -z "$CLOUD_HOST" || -z "$CLOUD_USER" ]]; then
  echo "請先填 .env 的 GCP_PROJECT，並執行 ./scripts/pull-secrets.sh 寫入 CLOUD_DB_*。" >&2
  exit 1
fi

if [[ -z "$GCP_RUN_SERVICE_ACCOUNT" ]]; then
  GCP_RUN_SERVICE_ACCOUNT="$(
    gcloud run services describe "${GCP_RUN_SERVICE}" \
      --project="${GCP_PROJECT}" \
      --region="${GCP_REGION}" \
      --format='value(spec.template.spec.serviceAccountName)' 2>/dev/null || true
  )"
  GCP_RUN_SERVICE_ACCOUNT="$(sanitize "$GCP_RUN_SERVICE_ACCOUNT")"
fi
if [[ -z "$GCP_RUN_SERVICE_ACCOUNT" ]]; then
  echo "找不到 Cloud Run 服務帳號。請在 .env 填 GCP_RUN_SERVICE_ACCOUNT。" >&2
  exit 1
fi

echo
echo "即將部署 Cloud Run："
echo "  專案：${GCP_PROJECT}"
echo "  服務：${GCP_RUN_SERVICE}（${GCP_REGION}）"
echo "  映像：${N8N_IMAGE}"
echo "  帳號：${GCP_RUN_SERVICE_ACCOUNT}"
echo
echo "注意：若雲端資料庫已經被較新版本（例如 2.38.7）跑過 migration，"
echo "降回 2.36.8 可能無法開機。請先把 Cloud Run 縮成 0 再部署，並備援資料。"
echo

if [[ "$ASSUME_YES" -eq 0 ]]; then
  printf '確認部署請輸入 DEPLOY：'
  read -r confirm || true
  confirm="$(sanitize "$confirm")"
  if [[ "$confirm" != "DEPLOY" ]]; then
    echo "已取消。"
    exit 1
  fi
fi

gcloud run deploy "${GCP_RUN_SERVICE}" \
  --project="${GCP_PROJECT}" \
  --image="${N8N_IMAGE}" \
  --command="/bin/sh" \
  --args="-c,sleep 5;n8n start" \
  --region="${GCP_REGION}" \
  --allow-unauthenticated \
  --port=5678 \
  --memory=2Gi \
  --no-cpu-throttling \
  --service-account="${GCP_RUN_SERVICE_ACCOUNT}" \
  --set-env-vars="N8N_PORT=5678,N8N_PROTOCOL=https,N8N_ENDPOINT_HEALTH=health,GENERIC_TIMEZONE=Asia/Taipei,QUEUE_HEALTH_CHECK_ACTIVE=true,DB_TYPE=postgresdb,DB_POSTGRESDB_HOST=${CLOUD_HOST},DB_POSTGRESDB_PORT=${CLOUD_PORT},DB_POSTGRESDB_DATABASE=${CLOUD_DB},DB_POSTGRESDB_USER=${CLOUD_USER},DB_POSTGRESDB_SCHEMA=public,DB_POSTGRESDB_SSL_ENABLED=true,DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED=false,DB_POSTGRESDB_CONNECTION_TIMEOUT=30000,DB_POSTGRESDB_POOL_SIZE=5" \
  --set-secrets="DB_POSTGRESDB_PASSWORD=supabase-db-password:latest,N8N_ENCRYPTION_KEY=n8n-encryption-key:latest"

echo
echo "完成。Cloud Run 映像已固定為 ${N8N_IMAGE}。"
echo "請到 Cloud Run 確認修訂使用的不是 n8nio/n8n:latest。"
