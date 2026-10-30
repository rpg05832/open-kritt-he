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

COPY package*.json ./
RUN npm ci
COPY . .

EXPOSE 5173

# Reinstall on start to cover the bind-mounted source + anonymous node_modules
# volume, then run the Vite dev server bound to 0.0.0.0 so it's reachable.
CMD ["sh", "-c", "npm ci && npm run dev -- --host 0.0.0.0"]
