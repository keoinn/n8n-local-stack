#!/usr/bin/env bash
# 本機 n8n 工具入口：依指令轉發既有腳本。相容 macOS 內建 Bash 3.2。
# 不帶參數時顯示互動選單。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'EOF'
本機 n8n 工具入口。不帶參數時會顯示選單；有指令時轉發到對應腳本。

用法：
  ./n8n工具程式(macOS).sh
  ./n8n工具程式(macOS).sh <指令> [腳本參數...]

日常：
  start                         開關機（在跑就關、沒在跑就開；尚無 .env 則先建立）
  stop                          關閉容器（保留資料、映像與 .env）
  update                        從 origin/main 更新專案程式碼
  uninstall [--keep-data] [--keep-env] [--keep-images]
                                卸載本機環境

設定與檢查：
  create-env                    引導建立 .env
  check-env                     檢查本機是否就緒
  pull-secrets                  從 GCP 寫入雲端密鑰（場景 B / C）
  start-local [--no-pull]       只依 .env 啟動容器（不跑精靈）
  check-ngrok                   檢查 ngrok 固定網域是否被佔用

資料同步（場景 B）：
  sync-from [--credentials-only] [--keep-exports]
                                從雲端複製到本機
  sync-to [--credentials-only] [--keep-exports] [--yes]
                                把本機資料回寫到雲端

別名：shutdown=stop、env=create-env、check=check-env、
      secrets=pull-secrets、ngrok=check-ngrok

既有的 ./n8n-開關機(macOS).sh、./scripts/shutdown-n8n.sh 等仍可單獨執行。
EOF
}

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
body() { printf '%b\n' "${C_WHITE}$*${C_RESET}"; }
muted() { printf '%b\n' "${C_DIM}$*${C_RESET}"; }
success() { printf '%b\n' "${C_GREEN}$*${C_RESET}"; }
warn() { printf '%b\n' "${C_YELLOW}$*${C_RESET}"; }
error() { printf '%b\n' "${C_RED}$*${C_RESET}" >&2; }

sanitize_line() {
  printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

normalize_cmd() {
  local raw
  raw="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
    start|1) printf 'start' ;;
    stop|shutdown|2) printf 'stop' ;;
    update|3) printf 'update' ;;
    uninstall|4) printf 'uninstall' ;;
    create-env|create-envfile|env|5) printf 'create-env' ;;
    check-env|check|6) printf 'check-env' ;;
    pull-secrets|secrets|7) printf 'pull-secrets' ;;
    start-local|start-local-n8n|8) printf 'start-local' ;;
    check-ngrok|check-ngrok-service|ngrok|9) printf 'check-ngrok' ;;
    sync-from|sync-from-cloud|10) printf 'sync-from' ;;
    sync-to|sync-to-cloud|11) printf 'sync-to' ;;
    0|q|quit|exit) printf 'quit' ;;
    -h|--help|help|h) printf 'help' ;;
    *) printf '%s' "$raw" ;;
  esac
}

script_relpath() {
  case "$1" in
    start) printf 'n8n-開關機(macOS).sh' ;;
    stop) printf 'scripts/shutdown-n8n.sh' ;;
    update) printf 'scripts/update-n8n.sh' ;;
    uninstall) printf 'scripts/uninstall-local-n8n.sh' ;;
    create-env) printf 'scripts/create-envfile.sh' ;;
    check-env) printf 'scripts/check-env.sh' ;;
    pull-secrets) printf 'scripts/pull-secrets.sh' ;;
    start-local) printf 'scripts/start-local-n8n.sh' ;;
    check-ngrok) printf 'scripts/check-ngrok-service.sh' ;;
    sync-from) printf 'scripts/sync-from-cloud.sh' ;;
    sync-to) printf 'scripts/sync-to-cloud.sh' ;;
    *) return 1 ;;
  esac
}

print_menu() {
  printf '\n'
  title "════════════════════════════════════════════════════════════"
  title "  n8n 工具選單"
  title "════════════════════════════════════════════════════════════"
  printf '\n'
  printf '%b\n' "${C_BOLD}${C_BLUE}日常${C_RESET}"
  body "  1) start         開關機（在跑就關）"
  body "  2) stop          關閉容器"
  body "  3) update        更新專案程式碼"
  body "  4) uninstall     卸載本機環境"
  printf '\n'
  printf '%b\n' "${C_BOLD}${C_BLUE}設定與檢查${C_RESET}"
  body "  5) create-env    引導建立 .env"
  body "  6) check-env     檢查本機是否就緒"
  body "  7) pull-secrets  從 GCP 寫入雲端密鑰"
  body "  8) start-local   只啟動容器（不跑精靈）"
  body "  9) check-ngrok   檢查 ngrok 是否被佔用"
  printf '\n'
  printf '%b\n' "${C_BOLD}${C_BLUE}資料同步（場景 B）${C_RESET}"
  body " 10) sync-from     從雲端複製到本機"
  body " 11) sync-to       把本機回寫到雲端"
  printf '\n'
  muted "  也可輸入指令與參數，例如：sync-from --credentials-only"
  muted "  0) 離開    h) 說明"
  printf '\n'
}

run_command() {
  local cmd rel rc
  cmd="$(normalize_cmd "$1")"
  shift || true

  case "$cmd" in
    '' )
      error "請指定指令。"
      usage >&2
      return 1
      ;;
    help)
      usage
      return 0
      ;;
    quit)
      return 0
      ;;
  esac

  rel="$(script_relpath "$cmd" || true)"
  if [[ -z "$rel" ]]; then
    error "未知指令：$cmd"
    usage >&2
    return 1
  fi

  if [[ ! -x "${ROOT}/${rel}" && ! -f "${ROOT}/${rel}" ]]; then
    error "找不到 ${rel}"
    return 1
  fi

  if [[ $# -gt 0 ]]; then
    muted "  → ${rel} $*"
  else
    muted "  → ${rel}"
  fi
  printf '\n'

  set +e
  "${ROOT}/${rel}" "$@"
  rc=$?
  set -e
  return "$rc"
}

interactive_menu() {
  local line first cmd rc
  while :; do
    print_menu
    printf '%b' "${C_BOLD}${C_MAGENTA}請輸入編號或指令：${C_RESET} "
    IFS= read -r line || true
    line="$(sanitize_line "$line")"
    if [[ -z "$line" ]]; then
      warn "沒有輸入。請輸入編號或指令，或按 0 離開。"
      continue
    fi

    # 第一個詞當指令，其餘原樣轉給腳本。
    first="${line%% *}"
    cmd="$(normalize_cmd "$first")"
    if [[ "$cmd" = "quit" ]]; then
      success "已離開。"
      return 0
    fi
    if [[ "$cmd" = "help" ]]; then
      printf '\n'
      usage
      continue
    fi

    set --
    if [[ "$line" != "$first" ]]; then
      remainder="$(sanitize_line "${line#"${first}"}")"
      if [[ -n "$remainder" ]]; then
        # 選單輸入的額外參數以空白分隔轉發（例如 --credentials-only）。
        set -f
        set -- $remainder
        set +f
      fi
    fi

    printf '\n'
    set +e
    run_command "$cmd" "$@"
    rc=$?
    set -e
    printf '\n'
    if [[ "$rc" -eq 0 ]]; then
      success "指令完成。"
    else
      warn "指令結束代碼：${rc}"
    fi
  done
}

pause_if_tty() {
  if [[ -t 0 ]]; then
    printf '\n按下任意鍵關閉視窗'
    read -r -n 1 -s || true
    printf '\n'
  fi
}

cd "${ROOT}"

if [[ $# -eq 0 ]]; then
  interactive_menu
  pause_if_tty
  exit 0
fi

case "$1" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

run_command "$@"
exit $?
