#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

KEEP_DATA=0
KEEP_IMAGES=0

usage() {
  cat <<'EOF'
移除本專案的 container、network、Docker volume，以及 compose 用到的 image。
預設一併清空 bind mount 資料夾 data/、exports/（本機 n8n / Postgres 資料）。
不會刪除 .env，也不會刪各目錄的 .gitkeep。

用法：
  ./scripts/uninstall-local-n8n.sh
  ./scripts/uninstall-local-n8n.sh --keep-data     只拆 Docker，保留 data/ 與 exports/
  ./scripts/uninstall-local-n8n.sh --keep-images   不刪 n8n / postgres / ngrok 映像
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-data) KEEP_DATA=1 ;;
    --keep-images) KEEP_IMAGES=1 ;;
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

if ! command -v docker >/dev/null 2>&1; then
  echo "找不到 docker。" >&2
  exit 1
fi

down_args=(--profile tunnel down --volumes --remove-orphans)
if [[ "${KEEP_IMAGES}" -eq 0 ]]; then
  down_args+=(--rmi all)
fi

echo "停止並移除本專案 container / network / volume ..."
docker compose "${down_args[@]}"
if [[ -f "${ROOT}/compose.remote-supabase.yml" ]]; then
  docker compose -f compose.yml -f compose.remote-supabase.yml "${down_args[@]}"
fi

project_containers="$(docker ps -aq --filter label=com.docker.compose.project=n8n-local || true)"
if [[ -n "${project_containers}" ]]; then
  echo "清除殘留 container ..."
  # shellcheck disable=SC2086
  docker rm -f ${project_containers}
fi

project_volumes="$(docker volume ls -q --filter label=com.docker.compose.project=n8n-local || true)"
if [[ -n "${project_volumes}" ]]; then
  echo "清除殘留 Docker volume ..."
  # shellcheck disable=SC2086
  docker volume rm ${project_volumes}
fi

if [[ "${KEEP_DATA}" -eq 0 ]]; then
  echo "清空 bind mount：data/n8n、data/postgres、exports/（保留 .gitkeep）..."
  clear_bind_mount() {
    local dir="$1"
    mkdir -p "${dir}"
    find "${dir}" -mindepth 1 -maxdepth 1 ! -name '.gitkeep' -exec rm -rf {} +
    [[ -f "${dir}/.gitkeep" ]] || : > "${dir}/.gitkeep"
  }
  clear_bind_mount "${ROOT}/data/n8n"
  clear_bind_mount "${ROOT}/data/postgres"
  clear_bind_mount "${ROOT}/exports"
  chmod 777 "${ROOT}/data/n8n" "${ROOT}/exports" 2>/dev/null || true
fi

echo
echo "完成。.env 有保留。"
if [[ "${KEEP_DATA}" -eq 0 ]]; then
  echo "本機 n8n / Postgres 資料已清空，重新測試請再 compose up。"
fi
