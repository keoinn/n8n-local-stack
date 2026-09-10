#!/usr/bin/env bash
# 拆掉本機 n8n 環境（container、映像，預設連 data/ 與 .env）。相容 macOS 內建 Bash 3.2。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "${ROOT}"

KEEP_DATA=0
KEEP_IMAGES=0
KEEP_ENV=0

usage() {
  cat <<'EOF'
移除本專案的 container、network、Docker volume，以及 compose 用到的 image。
預設一併清空 bind mount 資料夾 data/、exports/，並刪除 .env。
不會刪各目錄的 .gitkeep。

用法：
  ./uninstall-local-n8n.sh
  ./uninstall-local-n8n.sh --keep-data     只拆 Docker，保留 data/ 與 exports/
  ./uninstall-local-n8n.sh --keep-env      保留 .env
  ./uninstall-local-n8n.sh --keep-images   不刪 n8n / postgres / ngrok 映像
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-data) KEEP_DATA=1 ;;
    --keep-env) KEEP_ENV=1 ;;
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

pause_on_exit() {
  if [[ -t 0 ]]; then
    printf '\n按下任意鍵關閉視窗'
    read -r -n 1 -s || true
    printf '\n'
  fi
}
trap pause_on_exit EXIT

if ! command -v docker >/dev/null 2>&1; then
  echo "找不到 docker。" >&2
  exit 1
fi

down_args=(--profile tunnel --profile runners down --volumes --remove-orphans)
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
  rm -f "${ROOT}/data/.local-bootstrapped" "${ROOT}/.n8n-local-bootstrapped"
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

if [[ "${KEEP_ENV}" -eq 0 ]]; then
  echo "刪除 .env ..."
  rm -f "${ROOT}/.env"
elif [[ "${KEEP_DATA}" -eq 0 && -f "${ROOT}/.env" ]]; then
  echo "資料已清空，清除 .env 的 N8N_LOCAL_BOOTSTRAPPED ..."
  tmp="$(mktemp "${TMPDIR:-/tmp}/uninstall-n8n.XXXXXX")"
  found=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      N8N_LOCAL_BOOTSTRAPPED=*)
        printf "N8N_LOCAL_BOOTSTRAPPED=''\n"
        found=1
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done < "${ROOT}/.env" > "$tmp"
  if [[ "$found" -eq 0 ]]; then
    printf "N8N_LOCAL_BOOTSTRAPPED=''\n" >> "$tmp"
  fi
  mv "$tmp" "${ROOT}/.env"
fi

echo
if [[ "${KEEP_ENV}" -eq 0 ]]; then
  echo "完成。.env 已刪除。"
else
  echo "完成。.env 有保留。"
fi
if [[ "${KEEP_DATA}" -eq 0 ]]; then
  echo "本機 n8n / Postgres 資料已清空，重新測試請再 compose up。"
fi
