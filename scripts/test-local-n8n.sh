#!/usr/bin/env bash
# 檢查本機 n8n 腳本與啟動前置邏輯。相容 macOS 內建 Bash 3.2。
# 預設不啟動、不卸載、不拉密鑰。加 --live 才會查 Docker 實際狀態。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT}/.env"
LIVE=0
PASS=0
FAIL=0
SKIP=0

usage() {
  cat <<'EOF'
檢查本機腳本路徑、語法、n8n-tools 轉發，以及啟動精靈的前置判斷。

預設只做安全檢查，不會啟動或停止容器。
加 --live 時會查 Docker 是否真的在跑，並核對啟動精靈會採取的動作。

用法：
  ./scripts/test-local-n8n.sh
  ./scripts/test-local-n8n.sh --live
  ./n8n工具程式(macOS).sh test
  ./n8n工具程式(macOS).sh test --live
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --live) LIVE=1 ;;
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

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
  C_WHITE=$'\033[97m'
else
  C_RESET=''
  C_BOLD=''
  C_DIM=''
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_CYAN=''
  C_WHITE=''
fi

title() { printf '%b\n' "${C_BOLD}${C_CYAN}$*${C_RESET}"; }
section() { printf '\n%b\n' "${C_BOLD}${C_CYAN}$*${C_RESET}"; }
muted() { printf '%b\n' "${C_DIM}$*${C_RESET}"; }

ok() {
  PASS=$((PASS + 1))
  printf '%b\n' "${C_GREEN}  PASS${C_RESET}  $*"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '%b\n' "${C_RED}  FAIL${C_RESET}  $*"
}

skip() {
  SKIP=$((SKIP + 1))
  printf '%b\n' "${C_YELLOW}  SKIP${C_RESET}  $*"
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

expect_file() {
  if [[ -f "${ROOT}/$1" ]]; then
    ok "存在 $1"
  else
    fail "找不到 $1"
  fi
}

expect_absent() {
  if [[ -e "${ROOT}/$1" ]]; then
    fail "不應再放在根目錄：$1"
  else
    ok "根目錄已移除 $1"
  fi
}

expect_contains() {
  local file="$1"
  local needle="$2"
  if grep -F -q "$needle" "${ROOT}/${file}"; then
    ok "${file} 含有「${needle}」"
  else
    fail "${file} 缺少「${needle}」"
  fi
}

run_help() {
  local rel="$1"
  if "${ROOT}/${rel}" --help >/dev/null 2>&1; then
    ok "${rel} --help"
  else
    fail "${rel} --help 失敗"
  fi
}

project_is_running() {
  local ids
  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi
  ids="$(docker ps -q --filter 'label=com.docker.compose.project=n8n-local' 2>/dev/null || true)"
  [[ -n "$ids" ]]
}

cd "${ROOT}"

printf '\n'
title "════════════════════════════════════════════════════════════"
title "  n8n 本機測試"
title "════════════════════════════════════════════════════════════"
if [[ "$LIVE" -eq 1 ]]; then
  muted "模式：--live（會查 Docker 實際狀態，仍不會啟動或卸載）"
else
  muted "模式：安全檢查（加 --live 才查 Docker 實際狀態）"
fi

section "檔案位置"
expect_file 'n8n-開關機(macOS).sh'
expect_file 'n8n-開關機(Win).cmd'
expect_file 'n8n工具程式(macOS).sh'
expect_file 'n8n工具程式(Win).cmd'
expect_file compose.yml
expect_file compose.remote-supabase.yml
expect_file .env.example
expect_file scripts/n8n-tools.ps1
expect_file scripts/start-n8n.ps1
expect_file scripts/shutdown-n8n.sh
expect_file scripts/shutdown-n8n.cmd
expect_file scripts/shutdown-n8n.ps1
expect_file scripts/update-n8n.sh
expect_file scripts/update-n8n.cmd
expect_file scripts/update-n8n.ps1
expect_file scripts/uninstall-local-n8n.sh
expect_file scripts/uninstall-local-n8n.cmd
expect_file scripts/uninstall-local-n8n.ps1
expect_file scripts/create-envfile.sh
expect_file scripts/check-env.sh
expect_file scripts/pull-secrets.sh
expect_file scripts/start-local-n8n.sh
expect_file scripts/check-ngrok-service.sh
expect_file scripts/sync-from-cloud.sh
expect_file scripts/sync-to-cloud.sh
expect_file scripts/test-local-n8n.sh
expect_file scripts/test-local-n8n.cmd
expect_file scripts/test-local-n8n.ps1
expect_absent shutdown-n8n.sh
expect_absent shutdown-n8n.cmd
expect_absent update-n8n.sh
expect_absent update-n8n.cmd
expect_absent uninstall-local-n8n.sh
expect_absent uninstall-local-n8n.cmd

section "Bash 語法"
while IFS= read -r sh; do
  if bash -n "${ROOT}/${sh}"; then
    ok "bash -n ${sh}"
  else
    fail "bash -n ${sh}"
  fi
done <<'EOF'
n8n-開關機(macOS).sh
n8n工具程式(macOS).sh
scripts/test-local-n8n.sh
scripts/shutdown-n8n.sh
scripts/update-n8n.sh
scripts/uninstall-local-n8n.sh
scripts/create-envfile.sh
scripts/check-env.sh
scripts/pull-secrets.sh
scripts/start-local-n8n.sh
scripts/check-ngrok-service.sh
scripts/sync-from-cloud.sh
scripts/sync-to-cloud.sh
EOF

section "n8n-tools 轉發"
if "${ROOT}/n8n工具程式(macOS).sh" --help >/dev/null 2>&1; then
  ok "n8n工具程式(macOS).sh --help"
else
  fail "n8n工具程式(macOS).sh --help"
fi
if "${ROOT}/n8n工具程式(macOS).sh" nope >/dev/null 2>&1; then
  fail "未知指令應失敗，卻成功了"
else
  ok "未知指令會失敗"
fi

# 只跑 --help，避免真的啟動、卸載或拉密鑰。
run_help 'n8n-開關機(macOS).sh'
run_help scripts/shutdown-n8n.sh
run_help scripts/update-n8n.sh
run_help scripts/uninstall-local-n8n.sh
run_help scripts/create-envfile.sh
run_help scripts/check-env.sh
run_help scripts/start-local-n8n.sh
run_help scripts/check-ngrok-service.sh
run_help scripts/sync-from-cloud.sh
run_help scripts/sync-to-cloud.sh

if "${ROOT}/n8n工具程式(macOS).sh" check-env --help >/dev/null 2>&1; then
  ok "n8n工具程式(macOS).sh check-env --help"
else
  fail "n8n工具程式(macOS).sh check-env --help"
fi
if "${ROOT}/n8n工具程式(macOS).sh" stop --help >/dev/null 2>&1; then
  ok "n8n工具程式(macOS).sh stop --help"
else
  fail "n8n工具程式(macOS).sh stop --help"
fi
if "${ROOT}/n8n工具程式(macOS).sh" update --help >/dev/null 2>&1; then
  ok "n8n工具程式(macOS).sh update --help"
else
  fail "n8n工具程式(macOS).sh update --help"
fi
if "${ROOT}/n8n工具程式(macOS).sh" uninstall --help >/dev/null 2>&1; then
  ok "n8n工具程式(macOS).sh uninstall --help"
else
  fail "n8n工具程式(macOS).sh uninstall --help"
fi
if "${ROOT}/n8n工具程式(macOS).sh" test --help >/dev/null 2>&1; then
  ok "n8n工具程式(macOS).sh test --help"
else
  fail "n8n工具程式(macOS).sh test --help"
fi

section "啟動前置邏輯"
expect_contains 'n8n-開關機(macOS).sh' '判定為已初始化'
expect_contains 'n8n-開關機(macOS).sh' '判定為尚未初始化'
expect_contains 'n8n-開關機(macOS).sh' 'project_is_running'
expect_contains 'n8n-開關機(macOS).sh' 'stop_running_stack'
expect_contains 'n8n-開關機(macOS).sh' '這次改為關閉'
expect_contains scripts/start-n8n.ps1 'Test-ProjectRunning'
expect_contains scripts/start-n8n.ps1 'Stop-RunningStack'
expect_contains scripts/start-n8n.ps1 '判定為已初始化'

if [[ -f "$ENV_FILE" ]]; then
  ok ".env 存在，啟動精靈會判定為已初始化"
  scenario="$(get_env_value N8N_SCENARIO)"
  scenario="$(printf '%s' "$scenario" | tr '[:lower:]' '[:upper:]')"
  if [[ -z "$scenario" ]]; then
    fail ".env 有檔，但 N8N_SCENARIO 是空的"
  else
    ok "N8N_SCENARIO=${scenario}"
  fi
else
  ok ".env 不存在，啟動精靈會判定為尚未初始化並建立設定檔"
fi

section "Docker 執行狀態"
if [[ "$LIVE" -eq 0 ]]; then
  skip "未加 --live，略過 Docker 實際狀態"
elif ! command -v docker >/dev/null 2>&1; then
  fail "找不到 docker（啟動精靈會略過執行狀態檢查）"
elif ! docker info >/dev/null 2>&1; then
  fail "docker daemon 未在執行"
else
  ok "docker 可用"
  if project_is_running; then
    ok "偵測到 n8n-local 相關容器正在執行；start-n8n 會關閉後結束"
    muted "  docker ps --filter label=com.docker.compose.project=n8n-local"
    docker ps --filter 'label=com.docker.compose.project=n8n-local' --format '  {{.Names}}\t{{.Status}}' || true
  else
    ok "目前沒有正在執行的 n8n-local 容器；start-n8n 會走啟動流程"
  fi
fi

printf '\n'
title "────────────────────────────────────────────────────────────"
if [[ "$FAIL" -eq 0 ]]; then
  printf '%b\n' "${C_GREEN}  測試通過：${PASS} 通過、${SKIP} 略過${C_RESET}"
else
  printf '%b\n' "${C_RED}  測試失敗：${FAIL} 失敗、${PASS} 通過、${SKIP} 略過${C_RESET}"
fi
title "────────────────────────────────────────────────────────────"
printf '\n'

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
exit 0
