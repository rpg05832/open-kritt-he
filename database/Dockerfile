FROM postgres:17.5-alpine3.20

# Optional public CA certificates approved by the user in prepare.ps1 (for networks
# that inspect TLS, e.g. a filtering provider). Empty by default; TLS verification stays on.
COPY local-certs/ /usr/local/share/ca-certificates/
RUN for cert in /usr/local/share/ca-certificates/*.crt; do [ ! -f "$cert" ] || cat "$cert" >> /etc/ssl/certs/ca-certificates.crt; done
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    PIP_CERT=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

RUN apk add --no-cache musl-locales musl-locales-lang tzdata

# Alpine does not ship locale data by default, which makes initdb warn and fall
# back implicitly. Keep initialization deterministic and avoid trust-auth
# warnings on new data directories. POSTGRES_INITDB_ARGS can still be overridden
# by an operator when a different locale or authentication policy is required.
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    POSTGRES_INITDB_ARGS="--locale=en_US.UTF-8 --encoding=UTF8 --auth-local=scram-sha-256 --auth-host=scram-sha-256"
