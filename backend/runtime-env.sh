#!/bin/sh
# Runtime environment for prebuilt images (identical copy in engine/, backend/,
# executor-view/; tests keep them equal).
#  * CA certificates the user approved in the wizard are mounted read-only at
#    /run/approved-ca and appended to the system bundle at start, so published
#    images contain no network-specific certificate. TLS verification stays on.
#  * Tools installed on the user's machine (Claude Code, optional Cursor/Grok)
#    live in the runtime volume and are added to PATH.
# Scan runners get the engine's bundle through the read-only runtime volume.
set -e
RUNTIME_ROOT="${OPEN_KRITT_RUNTIME_DIR:-/opt/runtime-tools}"
SYSTEM_BUNDLE=/etc/ssl/certs/ca-certificates.crt
bundle="$SYSTEM_BUNDLE"

if ls /run/approved-ca/*.crt >/dev/null 2>&1; then
  if [ -w "$RUNTIME_ROOT" ]; then
    mkdir -p "$RUNTIME_ROOT/ca"
    out="$RUNTIME_ROOT/ca/bundle.pem"
  else
    out=/tmp/open-kritt-ca-bundle.pem
  fi
  cat "$SYSTEM_BUNDLE" /run/approved-ca/*.crt > "$out.tmp"
  mv "$out.tmp" "$out"
  bundle="$out"
elif [ -w "$RUNTIME_ROOT" ]; then
  # No approved certificate any more (for example the user deleted it): drop the
  # shared bundle so scan runners stop trusting a revoked CA.
  rm -f "$RUNTIME_ROOT/ca/bundle.pem"
elif [ -f "$RUNTIME_ROOT/ca/bundle.pem" ]; then
  # Read-only consumers (scan runners) follow the engine, which rebuilds or
  # removes this file on every start.
  bundle="$RUNTIME_ROOT/ca/bundle.pem"
fi

export SSL_CERT_FILE="$bundle" NODE_EXTRA_CA_CERTS="$bundle" REQUESTS_CA_BUNDLE="$bundle" \
  PIP_CERT="$bundle" GIT_SSL_CAINFO="$bundle" npm_config_cafile="$bundle"
if [ -d "$RUNTIME_ROOT/bin" ]; then
  export PATH="$RUNTIME_ROOT/bin:$PATH"
fi
exec "$@"
