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

RUN pip install --no-cache-dir psycopg[binary]==3.2.3

COPY server.py ./

ENV EXECUTOR_VIEW_HOST=0.0.0.0 \
    EXECUTOR_VIEW_PORT=8090

# Runtime CA bundle from user-approved certificates and tools installed on this
# machine (see runtime-env.sh); TLS verification stays on.
COPY runtime-env.sh /usr/local/bin/runtime-env
RUN sed -i 's/\r$//' /usr/local/bin/runtime-env && chmod 0755 /usr/local/bin/runtime-env
ENTRYPOINT ["/usr/local/bin/runtime-env"]
CMD ["python", "server.py"]
