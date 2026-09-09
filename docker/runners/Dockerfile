# Code 節點在 external mode 由 n8nio/runners sidecar 執行。
# 不可在 task-runner-javascript 目錄跑 pnpm add，那會把映像內建依賴刪掉。
# runners 映像沒有 npm，JS 套件改在 node 映像安裝後複製進來。
# Python runners 是 Alpine musl，pymupdf 沒有 musllinux wheel；改從 Debian 安裝官方 abi3 wheel 再複製。
ARG N8N_RUNNERS_IMAGE=n8nio/runners:2.36.8
ARG EXTRA_JS_PACKAGES=pdf-lib
ARG EXTRA_PY_PACKAGES=

FROM node:24-alpine AS js-extra
ARG EXTRA_JS_PACKAGES=pdf-lib
WORKDIR /opt/n8n-extra-js
RUN set -eu; \
    pkgs=$(printf '%s' "${EXTRA_JS_PACKAGES}" | tr ',;' ' '); \
    if [ -n "$(printf '%s' "$pkgs" | tr -d '[:space:]')" ]; then \
      npm init -y >/dev/null; \
      npm install --omit=dev $pkgs; \
    else \
      mkdir -p node_modules; \
    fi

FROM python:3.13-slim-bookworm AS py-extra
ARG EXTRA_PY_PACKAGES=
WORKDIR /opt/py-extra
RUN set -eu; \
    pkgs=$(printf '%s' "${EXTRA_PY_PACKAGES}" | tr ',;' ' '); \
    mkdir -p /opt/py-extra; \
    if [ -n "$(printf '%s' "$pkgs" | tr -d '[:space:]')" ]; then \
      pip install --no-cache-dir --target /opt/py-extra $pkgs; \
    fi

FROM ${N8N_RUNNERS_IMAGE}

ARG NODE_FUNCTION_ALLOW_BUILTIN=crypto
ARG NODE_FUNCTION_ALLOW_EXTERNAL=pdf-lib
ARG N8N_RUNNERS_STDLIB_ALLOW=*
ARG N8N_RUNNERS_EXTERNAL_ALLOW=
ARG N8N_RUNNERS_ALLOW_TRANSITIVE_IMPORTS=true

USER root

COPY --from=js-extra /opt/n8n-extra-js /opt/n8n-extra-js
RUN set -eu; \
    if [ -d /opt/n8n-extra-js/node_modules ]; then \
      mkdir -p /opt/runners/task-runner-javascript/node_modules; \
      for d in /opt/n8n-extra-js/node_modules/*; do \
        name=${d#/opt/n8n-extra-js/node_modules/}; \
        if [ "$name" = "*" ] || [ "$name" = ".bin" ] || [ "$name" = ".package-lock.json" ]; then \
          continue; \
        fi; \
        if [ ! -e "/opt/runners/task-runner-javascript/node_modules/$name" ]; then \
          cp -a "$d" /opt/runners/task-runner-javascript/node_modules/; \
        fi; \
      done; \
    fi

ENV NODE_PATH=/opt/n8n-extra-js/node_modules

COPY --from=py-extra /opt/py-extra /tmp/py-extra
RUN set -eu; \
    site="/opt/runners/task-runner-python/.venv/lib/python3.13/site-packages"; \
    mkdir -p "$site"; \
    if [ -n "$(ls -A /tmp/py-extra 2>/dev/null || true)" ]; then \
      cp -a /tmp/py-extra/. "$site/"; \
    fi; \
    rm -rf /tmp/py-extra

COPY n8n-task-runners.json /tmp/n8n-task-runners.json.in
RUN set -eu; \
    sed \
      -e "s|__NODE_FUNCTION_ALLOW_BUILTIN__|${NODE_FUNCTION_ALLOW_BUILTIN}|g" \
      -e "s|__NODE_FUNCTION_ALLOW_EXTERNAL__|${NODE_FUNCTION_ALLOW_EXTERNAL}|g" \
      -e "s|__N8N_RUNNERS_STDLIB_ALLOW__|${N8N_RUNNERS_STDLIB_ALLOW}|g" \
      -e "s|__N8N_RUNNERS_EXTERNAL_ALLOW__|${N8N_RUNNERS_EXTERNAL_ALLOW}|g" \
      -e "s|__N8N_RUNNERS_ALLOW_TRANSITIVE_IMPORTS__|${N8N_RUNNERS_ALLOW_TRANSITIVE_IMPORTS}|g" \
      /tmp/n8n-task-runners.json.in > /etc/n8n-task-runners.json; \
    chown runner:runner /etc/n8n-task-runners.json; \
    chmod 644 /etc/n8n-task-runners.json; \
    rm -f /tmp/n8n-task-runners.json.in

USER runner
WORKDIR /home/runner
