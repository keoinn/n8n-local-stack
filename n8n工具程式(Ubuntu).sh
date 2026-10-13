#!/usr/bin/env bash
# 本機 n8n 工具入口（Ubuntu）。不帶參數時顯示選單，有指令時轉發既有腳本。
# 用 sh 執行時，Ubuntu 的 /bin/sh 是 dash，不支援 [[。先改由 bash 重新執行。
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "找不到 bash。請先安裝：sudo apt-get install -y bash" >&2
  exit 1
fi

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TARGET="${ROOT}/n8n工具程式(macOS).sh"

if [ ! -f "$TARGET" ]; then
  echo "找不到 ${TARGET}，無法繼續。" >&2
  exit 1
fi

export N8N_TOOLS_LAUNCHER="n8n工具程式(Ubuntu).sh"
exec "$TARGET" "$@"
