FROM node:24.1.0-alpine3.20

# Optional public CA certificates approved by the user in prepare.ps1 (for networks
# that inspect TLS, e.g. a filtering provider). Empty by default; TLS verification stays on.
COPY local-certs/ /usr/local/share/ca-certificates/
RUN for cert in /usr/local/share/ca-certificates/*.crt; do [ ! -f "$cert" ] || cat "$cert" >> /etc/ssl/certs/ca-certificates.crt; done
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    PIP_CERT=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

WORKDIR /app

# Install deps + generate the Prisma client at build time. (The compose file also
# bind-mounts the source for live editing, with an anonymous volume keeping
# node_modules, so deps are installed again on first start to be safe.)
COPY package*.json ./
RUN npm ci
RUN npm install --global --no-audit --no-fund @openai/codex@0.145.0 \
    && codex --version \
    && npm install --global --no-audit --no-fund --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code@2.1.215
# Accounts spawns `grok login --device-auth` inside this image. Grok Build is
# optional (INSTALL_GROK=1, same pinned version and SHA-256 as the engine) and
# off by default because x.ai downloads are blocked on some filtered networks.
# A verified copy placed in app/vendor-cache (for example downloaded on another
# network when the vendor site is filtered) is used instead of downloading. The
# same SHA-256 check applies either way, so a modified file stops the build.
ARG TARGETARCH
ARG INSTALL_GROK=0
ARG GROK_BUILD_VERSION=1.0.5
RUN --mount=type=bind,from=vendor-cache,target=/tmp/vendor-cache if [ "$INSTALL_GROK" = "1" ]; then \
      apk add --no-cache curl \
      && case "${TARGETARCH}" in \
        amd64) grok_arch=linux-x86_64; grok_sha256=9ba87444e1819e8f6104adbbf4676a870c204380aa5c3e1c38a926c4ea677238 ;; \
        arm64) grok_arch=linux-aarch64; grok_sha256=1c1fe67d7c35497fb09f44a451f57acc3787add4c9aea2c56f5c7c75dc5ffcf1 ;; \
        *) echo "unsupported Grok Build architecture: ${TARGETARCH}" >&2; exit 1 ;; \
      esac \
      && if [ -f "/tmp/vendor-cache/grok-${GROK_BUILD_VERSION}-${grok_arch}" ]; then \
        cp "/tmp/vendor-cache/grok-${GROK_BUILD_VERSION}-${grok_arch}" /tmp/grok; \
      else curl -fsSL "https://x.ai/cli/grok-${GROK_BUILD_VERSION}-${grok_arch}" -o /tmp/grok; fi \
      && echo "${grok_sha256}  /tmp/grok" | sha256sum -c - \
      && install -m 0755 /tmp/grok /usr/local/bin/grok \
      && rm /tmp/grok \
      && grok --version; \
    fi
COPY . .
RUN npx prisma generate

EXPOSE 3002

# On start: ensure deps + client are present (handles the mounted-volume case),
# apply the schema idempotently (covers a persisted-but-empty DB), then launch.
CMD ["sh", "-c", "npm ci && npx prisma generate && npm run migrate && node src/server.js"]
