#!/usr/bin/env bash
# 本機 n8n 人工測試清單。相容 macOS 內建 Bash 3.2。
# 只提示步驟與預期結果，不會自動啟動、停止或卸載。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT}/.env"
PRINT_ONLY=0
PASS=0
FAIL=0
SKIP=0

usage() {
  cat <<'EOF'
本機 n8n 人工測試清單。會依案例提示你要做什麼、看到什麼。
不會自動改 .env、也不會自動啟動或卸載。

用法：
  ./scripts/manual-test-local-n8n.sh           逐步走完並記錄通過／失敗
  ./scripts/manual-test-local-n8n.sh --print   只印清單，不互動
  ./n8n工具程式(macOS).sh manual-test

Windows：
  .\scripts\manual-test-local-n8n.cmd
  .\n8n工具程式(Win).cmd manual-test
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print) PRINT_ONLY=1 ;;
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
  C_BLUE=$'\033[34m'
  C_MAGENTA=$'\033[35m'
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
  C_MAGENTA=''
  C_CYAN=''
  C_WHITE=''
fi

title() { printf '%b\n' "${C_BOLD}${C_CYAN}$*${C_RESET}"; }
section() { printf '\n%b\n' "${C_BOLD}${C_BLUE}$*${C_RESET}"; }
body() { printf '%b\n' "${C_WHITE}$*${C_RESET}"; }
muted() { printf '%b\n' "${C_DIM}$*${C_RESET}"; }
warn() { printf '%b\n' "${C_YELLOW}$*${C_RESET}"; }

sanitize_line() {
  printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

env_status() {
  if [[ -f "$ENV_FILE" ]]; then
    printf '已有 .env（啟動精靈會判定為已初始化）'
  else
    printf '沒有 .env（啟動精靈會判定為尚未初始化）'
  fi
}

docker_status() {
  local ids
  if ! command -v docker >/dev/null 2>&1; then
    printf '找不到 docker'
    return 0
  fi
  if ! docker info >/dev/null 2>&1; then
    printf 'docker daemon 未在執行'
    return 0
  fi
  ids="$(docker ps -q --filter 'label=com.docker.compose.project=n8n-local' 2>/dev/null || true)"
  if [[ -n "$ids" ]]; then
    printf 'n8n-local 容器正在執行'
  else
    printf 'n8n-local 容器未在執行'
  fi
}

print_case() {
  local id="$1"
  local name="$2"
  shift 2
  printf '\n'
  title "────────────────────────────────────────────────────────────"
  title "  ${id}  ${name}"
  title "────────────────────────────────────────────────────────────"
  printf '\n'
  while [[ $# -gt 0 ]]; do
    case "$1" in
      準備)
        printf '%b\n' "${C_BOLD}${C_MAGENTA}準備${C_RESET}"
        ;;
      操作)
        printf '\n%b\n' "${C_BOLD}${C_MAGENTA}操作${C_RESET}"
        ;;
      預期)
        printf '\n%b\n' "${C_BOLD}${C_MAGENTA}預期${C_RESET}"
        ;;
      *)
        body "  $1"
        ;;
    esac
    shift
  done
  printf '\n'
}

record_result() {
  local id="$1"
  local name="$2"
  local raw
  if [[ "$PRINT_ONLY" -eq 1 ]]; then
    return 0
  fi
  while :; do
    printf '%b' "${C_BOLD}${C_MAGENTA}${id} 結果 [P 通過 / F 失敗 / S 略過]：${C_RESET} "
    IFS= read -r raw || true
    raw="$(sanitize_line "$raw" | tr '[:upper:]' '[:lower:]')"
    case "$raw" in
      p|pass|y|yes|通過)
        PASS=$((PASS + 1))
        printf '%b\n' "${C_GREEN}  已記 ${id} 通過${C_RESET}"
        return 0
        ;;
      f|fail|n|no|失敗)
        FAIL=$((FAIL + 1))
        printf '%b\n' "${C_RED}  已記 ${id} 失敗${C_RESET}"
        return 0
        ;;
      s|skip|略過)
        SKIP=$((SKIP + 1))
        printf '%b\n' "${C_YELLOW}  已記 ${id} 略過${C_RESET}"
        return 0
        ;;
      *)
        warn "請輸入 P、F 或 S。"
        ;;
    esac
  done
}

cd "${ROOT}"

printf '\n'
title "════════════════════════════════════════════════════════════"
title "  n8n 人工測試"
title "════════════════════════════════════════════════════════════"
printf '\n'
body "請先開 Docker Desktop。下列案例請依序做；不適用的案例可略過。"
body "macOS / Linux 用 .sh；Windows 用對應的 .cmd。"
printf '\n'
muted "目前狀態：$(env_status)"
muted "目前狀態：$(docker_status)"
if [[ "$PRINT_ONLY" -eq 0 ]]; then
  printf '\n'
  muted "每個案例做完後，輸入 P（通過）、F（失敗）或 S（略過）。"
fi

print_case 'T1' '尚未初始化：沒有 .env' \
  準備 \
  '暫時把根目錄 .env 改名（例如 .env.bak）。測完再改回來。' \
  '確認 Docker 已開。容器有沒有在跑都可以。' \
  操作 \
  './n8n-開關機(macOS).sh' \
  'Windows：.\\n8n-開關機(Win).cmd' \
  預期 \
  '畫面寫「尚未找到 .env，判定為尚未初始化，開始引導建立。」' \
  '接著進入 create-envfile，詢問場景與 ngrok。' \
  '建立 .env 後繼續走啟動流程（這次剛建立設定，不會立刻變成關機）。'
record_result T1 '尚未初始化：沒有 .env'

print_case 'T2' '已初始化、容器未在跑' \
  準備 \
  '根目錄要有 .env。' \
  '若容器還在跑，先執行：./scripts/shutdown-n8n.sh' \
  'Windows：.\\scripts\\shutdown-n8n.cmd' \
  操作 \
  './n8n-開關機(macOS).sh' \
  'Windows：.\\n8n-開關機(Win).cmd' \
  預期 \
  '畫面寫「已有 .env，判定為已初始化。」' \
  '接著寫「目前沒有正在執行的容器，這次改為啟動。」' \
  '不會執行 docker compose stop。' \
  '之後繼續 runners、check-env，並啟動容器。' \
  '可用 http://localhost:5678 開啟編輯器。'
record_result T2 '已初始化、容器未在跑'

print_case 'T3' '已初始化、容器正在跑（開關機關機）' \
  準備 \
  '根目錄要有 .env。' \
  '本機 n8n 必須已在跑（可先做完 T2）。' \
  '可用瀏覽器開 http://localhost:5678 確認。' \
  操作 \
  '再開一次 ./n8n-開關機(macOS).sh' \
  'Windows：再執行一次 .\\n8n-開關機(Win).cmd' \
  預期 \
  '畫面寫「已有 .env，判定為已初始化。」' \
  '接著寫「本機 n8n 正在執行，這次改為關閉。」' \
  '會執行 docker compose ... stop（含 tunnel、runners profile）。' \
  '然後寫「本機 n8n 已停止。」並結束，不會再啟動。' \
  'http://localhost:5678 應打不開。' \
  '再執行一次同一支腳本才會重新開機。'
record_result T3 '已初始化、容器正在跑'

print_case 'T4' 'n8n-tools 選單與轉發' \
  準備 \
  '在專案根目錄。' \
  操作 \
  './n8n工具程式(macOS).sh' \
  '選 2 或輸入 stop' \
  '再執行：./n8n工具程式(macOS).sh start' \
  'Windows：.\\n8n工具程式(Win).cmd' \
  預期 \
  '不帶參數會出現選單（含 start / stop / test / manual-test）。' \
  'stop 會轉到 scripts/shutdown-n8n.sh，容器停止，.env 與 data/ 還在。' \
  'start 會轉到 n8n-開關機(macOS).sh，並走 T2 或 T3 的前置判斷。'
record_result T4 'n8n-tools 選單與轉發'

print_case 'T5' '關閉腳本已改到 scripts/' \
  準備 \
  '容器最好正在跑，才看得出停止效果。' \
  操作 \
  './scripts/shutdown-n8n.sh' \
  'Windows：.\\scripts\\shutdown-n8n.cmd' \
  '確認根目錄沒有 shutdown-n8n.sh / .cmd' \
  預期 \
  '容器停止。data/、映像、.env 都還在。' \
  '畫面提示之後用 ./n8n-開關機(macOS).sh 再開。' \
  '根目錄不該再有 shutdown-n8n.sh。'
record_result T5 '關閉腳本已改到 scripts/'

print_case 'T6' '更新腳本已改到 scripts/' \
  準備 \
  '這台電腦有 git。本機若改過專案檔，案例會停住，這是預期。' \
  操作 \
  './scripts/update-n8n.sh' \
  'Windows：.\\scripts\\update-n8n.cmd' \
  預期 \
  '沒有本機改檔：顯示「專案已是最新」或「專案已更新」。' \
  '有本機改檔：停止更新，並提示只改 .env。' \
  '根目錄不該再有 update-n8n.sh。'
record_result T6 '更新腳本已改到 scripts/'

print_case 'T7' '卸載腳本已改到 scripts/（選測，會清空環境）' \
  準備 \
  '會刪容器、映像，預設也刪 data/ 與 .env。' \
  '正式資料請略過，或先備份 .env。' \
  操作 \
  './scripts/uninstall-local-n8n.sh' \
  '若要保留設定：./scripts/uninstall-local-n8n.sh --keep-env' \
  'Windows：.\\scripts\\uninstall-local-n8n.cmd' \
  預期 \
  '容器與本專案映像被移除。' \
  '沒加 --keep-env 時 .env 會消失。' \
  '加 --keep-env 時 .env 還在。' \
  '根目錄不該再有 uninstall-local-n8n.sh。' \
  '測完若要還原，再跑 ./n8n-開關機(macOS).sh。'
record_result T7 '卸載腳本'

print_case 'T8' '場景 B / C 與 ngrok（選測）' \
  準備 \
  '.env 的 N8N_SCENARIO 為 B 或 C。' \
  '場景 B / C 需要 gcloud 已登入。' \
  '若 ENABLE_NGROK=true，需已填 NGROK_AUTHTOKEN 與 NGROK_DOMAIN。' \
  操作 \
  './n8n-開關機(macOS).sh' \
  預期 \
  '場景 B / C 會跑 pull-secrets。' \
  '場景 B 只有第一次（或卸載後再啟動）才同步雲端資料。' \
  '有 ngrok 時，完成畫面會出現外部網址與 http://127.0.0.1:4040。' \
  'OAuth / Webhook 請用外部網址；編輯器用內部網址即可。'
record_result T8 '場景 B / C 與 ngrok'

printf '\n'
title "────────────────────────────────────────────────────────────"
if [[ "$PRINT_ONLY" -eq 1 ]]; then
  body "以上為人工測試清單。實際操作請拿掉 --print 再跑一次。"
else
  if [[ "$FAIL" -eq 0 ]]; then
    printf '%b\n' "${C_GREEN}  人工測試結束：${PASS} 通過、${SKIP} 略過、${FAIL} 失敗${C_RESET}"
  else
    printf '%b\n' "${C_RED}  人工測試結束：${FAIL} 失敗、${PASS} 通過、${SKIP} 略過${C_RESET}"
  fi
fi
title "────────────────────────────────────────────────────────────"
printf '\n'

if [[ "$PRINT_ONLY" -eq 0 && "$FAIL" -ne 0 ]]; then
  exit 1
fi
exit 0
