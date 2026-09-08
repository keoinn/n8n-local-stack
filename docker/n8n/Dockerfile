# 官方 n8n 映像的 package.json 使用 pnpm catalog:，不可在該目錄跑 npm install。
# 套件改裝到獨立目錄，再複製進 n8n/node_modules，讓 internal task runner 的 require() 找得到。
ARG N8N_BASE_IMAGE=n8nio/n8n:2.36.8
FROM ${N8N_BASE_IMAGE}

ARG EXTRA_JS_PACKAGES=pdf-lib

USER root
WORKDIR /opt/n8n-extra
RUN set -eu; \
    pkgs=$(printf '%s' "${EXTRA_JS_PACKAGES}" | tr ',;' ' '); \
    if [ -n "$(printf '%s' "$pkgs" | tr -d '[:space:]')" ]; then \
      npm init -y >/dev/null; \
      npm install --omit=dev $pkgs; \
      mkdir -p /usr/local/lib/node_modules/n8n/node_modules; \
      for d in node_modules/*; do \
        name=${d#node_modules/}; \
        if [ "$name" = "*" ] || [ "$name" = ".bin" ] || [ "$name" = ".package-lock.json" ]; then \
          continue; \
        fi; \
        if [ ! -e "/usr/local/lib/node_modules/n8n/node_modules/$name" ]; then \
          cp -a "$d" /usr/local/lib/node_modules/n8n/node_modules/; \
        fi; \
      done; \
    fi

ENV NODE_PATH=/opt/n8n-extra/node_modules

USER node
WORKDIR /home/node
