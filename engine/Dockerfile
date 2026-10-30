FROM docker:29.8.0-cli AS docker-cli

FROM node:26.12.0-bookworm-slim AS node_runtime

FROM python:3.12.14-slim-bookworm

# Optional public CA certificates approved by the user in prepare.ps1 (for networks
# that inspect TLS, e.g. a filtering provider). Empty by default; TLS verification stays on.
COPY local-certs/ /usr/local/share/ca-certificates/
RUN for cert in /usr/local/share/ca-certificates/*.crt; do [ ! -f "$cert" ] || cat "$cert" >> /etc/ssl/certs/ca-certificates.crt; done
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    PIP_CERT=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt


WORKDIR /app

# Copy the Node runtime as a tree so the npm/npx symlinks retain their targets.
COPY --from=node_runtime /usr/local/ /usr/local/

# INCLUDE_VENDOR_CLIS=0 builds the publishable image: Claude Code is proprietary
# and is then installed on the user's machine at first start (runtime_tools.py).
ARG INCLUDE_VENDOR_CLIS=1
RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl git util-linux \
    && npm install --global --no-audit --no-fund npm@12.0.1 \
    && npm install --global --no-audit --no-fund @openai/codex@0.145.0 \
    && codex --version \
    && if [ "$INCLUDE_VENDOR_CLIS" = "1" ]; then npm install --global --no-audit --no-fund --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code@2.1.215; fi \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Keep sensitive bind mounts below one root-only traversal boundary. The legacy
# paths remain root-visible symlinks for runtime config and existing installs.
RUN mkdir -p /run/open-kritt-secrets \
    && chmod 0700 /run/open-kritt-secrets \
    && ln -s /run/open-kritt-secrets/credentials /credentials \
    && ln -s /run/open-kritt-secrets/codex-accounts /codex-accounts \
    && ln -s /run/open-kritt-secrets/claude-accounts /claude-accounts \
    && ln -s /run/open-kritt-secrets/grok-accounts /grok-accounts \
    && ln -s /run/open-kritt-secrets/codex-home-source /codex-home-source \
    && ln -s /run/open-kritt-secrets/local-repos /local_repos

# Cursor Agent is a proprietary, optional provider CLI. It is NOT installed by
# default; INSTALL_CURSOR=1 (after reading the vendor terms) downloads the pinned
# official archive and the build stops unless its SHA-256 matches. Grok Build is
# optional in the same way (INSTALL_GROK=1); both are off by default because the
# vendor download sites are blocked on some filtered networks.
# A verified copy placed in app/vendor-cache (for example downloaded on another
# network when the vendor site is filtered) is used instead of downloading. The
# same SHA-256 check applies either way, so a modified file stops the build.
ARG TARGETARCH
ARG INSTALL_CURSOR=0
ARG CURSOR_AGENT_VERSION=2026.07.09-a3815c0
ARG INSTALL_GROK=0
ARG GROK_BUILD_VERSION=1.0.5
RUN --mount=type=bind,from=vendor-cache,target=/tmp/vendor-cache set -e; \
    if [ "$INSTALL_CURSOR" = "1" ]; then \
      case "${TARGETARCH}" in \
        amd64) cursor_arch=x64; cursor_sha256=c7c1f32249cedb99cc20cd4eed1f9308dc2299a78c283bbc6efd6d658cd4977e ;; \
        arm64) cursor_arch=arm64; cursor_sha256=11b2b6801136a11a3632a4b1080ea3bfc7d97d0a68382be9ede1faf5333207fb ;; \
        *) echo "unsupported Cursor Agent architecture: ${TARGETARCH}" >&2; exit 1 ;; \
      esac; \
      local_file="/tmp/vendor-cache/cursor-agent-${CURSOR_AGENT_VERSION}-linux-${cursor_arch}.tar.gz"; \
      if [ -f "$local_file" ]; then cp "$local_file" /tmp/cursor-agent.tar.gz; \
      else curl -fsSL "https://downloads.cursor.com/lab/${CURSOR_AGENT_VERSION}/linux/${cursor_arch}/agent-cli-package.tar.gz" -o /tmp/cursor-agent.tar.gz; fi; \
      echo "${cursor_sha256}  /tmp/cursor-agent.tar.gz" | sha256sum -c -; \
      mkdir -p "/opt/cursor-agent/versions/${CURSOR_AGENT_VERSION}"; \
      tar --strip-components=1 -xzf /tmp/cursor-agent.tar.gz -C "/opt/cursor-agent/versions/${CURSOR_AGENT_VERSION}"; \
      ln -s "/opt/cursor-agent/versions/${CURSOR_AGENT_VERSION}/cursor-agent" /usr/local/bin/agent; \
      ln -s "/opt/cursor-agent/versions/${CURSOR_AGENT_VERSION}/cursor-agent" /usr/local/bin/cursor-agent; \
      rm /tmp/cursor-agent.tar.gz; \
    fi; \
    if [ "$INSTALL_GROK" = "1" ]; then \
      case "${TARGETARCH}" in \
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

COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
# Local scanners (Semgrep, Gitleaks, OSV-Scanner, Trivy). Versions and official
# SHA-256 values live in security-tools.json, refreshed by
# scripts/update-security-tools.mjs (stable releases at least 14 days old).
COPY security-tools.json install_security_tools.py ./
RUN python -m venv /opt/security-tools \
    && python install_security_tools.py \
    && ln -s /opt/security-tools/bin/semgrep /usr/local/bin/semgrep \
    && semgrep --version

COPY . .

ENV ENGINE_DATA_DIR=/data \
    ENGINE_CHECKOUT_CACHE_DIR=/checkout-cache \
    ENGINE_WORKER_COUNT=25 \
    CODEX_HOME=/root/.codex \
    PATH="/root/.local/bin:${PATH}"

# Runtime CA bundle from user-approved certificates and tools installed on this
# machine (see runtime-env.sh); TLS verification stays on.
COPY runtime-env.sh /usr/local/bin/runtime-env
RUN sed -i 's/\r$//' /usr/local/bin/runtime-env && chmod 0755 /usr/local/bin/runtime-env
ENTRYPOINT ["/usr/local/bin/runtime-env"]
CMD ["python", "-m", "open_kritt_engine"]
