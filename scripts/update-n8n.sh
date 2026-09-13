#!/usr/bin/env bash
# 從 origin/main 更新本專案程式碼（fetch、checkout、快轉）。相容 macOS 內建 Bash 3.2。
# 不會改 .env 或 data/。若本機改過專案檔，會停止以免覆蓋。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPDATE_REF="${N8N_UPDATE_REF:-main}"

usage() {
  cat <<'EOF'
從 origin/main 更新本專案程式碼。

會 fetch、切到 main，再快轉合併。不會還原或丟棄你改過的檔案。
.env 與 data/ 不受影響。若偵測到本機改過專案檔，會停止更新。

用法：
  ./scripts/update-n8n.sh
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
done

pause_on_exit() {
  if [[ -t 0 ]]; then
    printf '\n按下任意鍵關閉視窗'
    read -r -n 1 -s || true
    printf '\n'
  fi
}
trap pause_on_exit EXIT

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
body() { printf '%b\n' "${C_WHITE}$*${C_RESET}"; }
muted() { printf '%b\n' "${C_DIM}$*${C_RESET}"; }
success() { printf '%b\n' "${C_GREEN}$*${C_RESET}"; }
warn() { printf '%b\n' "${C_YELLOW}$*${C_RESET}"; }
error() { printf '%b\n' "${C_RED}$*${C_RESET}" >&2; }

print_git_install_hint() {
  error "找不到 git，無法更新程式碼。"
  body "請先安裝 git 原始碼控制工具："
  printf '%b\n' "  ${C_CYAN}https://git-scm.com/${C_RESET}"
}

has_local_tracked_changes() {
  local status
  status="$(git -C "${ROOT}" status --porcelain --untracked-files=no 2>/dev/null || true)"
  [[ -n "$status" ]]
}

printf '\n'
title "════════════════════════════════════════════════════════════"
title "  更新本機 n8n 專案"
title "════════════════════════════════════════════════════════════"
printf '\n'

if ! command -v git >/dev/null 2>&1; then
  print_git_install_hint
  exit 1
fi
if ! git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  print_git_install_hint
  exit 1
fi

body "正在從 origin/${UPDATE_REF} 更新專案 ..."

if has_local_tracked_changes; then
  error "偵測到本機改過專案檔，已停止更新以免覆蓋你的修改。"
  warn "設定請只改 .env。若要更新，請先自行處理本機變更後再執行 ./scripts/update-n8n.sh。"
  exit 1
fi

before="$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || true)"

if ! git -C "${ROOT}" fetch origin "${UPDATE_REF}"; then
  error "從 origin/${UPDATE_REF} 更新失敗。"
  exit 1
fi

current_branch="$(git -C "${ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
if [[ "$current_branch" != "$UPDATE_REF" ]]; then
  if ! git -C "${ROOT}" checkout -q "${UPDATE_REF}"; then
    if ! git -C "${ROOT}" checkout -q -B "${UPDATE_REF}" "origin/${UPDATE_REF}"; then
      error "無法切換到 ${UPDATE_REF}。"
      exit 1
    fi
  fi
fi

if ! git -C "${ROOT}" merge --ff-only "origin/${UPDATE_REF}"; then
  error "無法快轉到 origin/${UPDATE_REF}。"
  exit 1
fi

after="$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || true)"
printf '\n'
if [[ -n "$before" && "$before" = "$after" ]]; then
  success "────────────────────────────────────────────────────────────"
  success "  專案已是最新。"
  success "────────────────────────────────────────────────────────────"
else
  success "────────────────────────────────────────────────────────────"
  success "  專案已更新。"
  success "────────────────────────────────────────────────────────────"
fi
printf '\n'
muted "之後要啟動，請執行 ./n8n-開關機(macOS).sh"
printf '\n'
