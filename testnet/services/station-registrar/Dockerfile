# WRFCoin testnet station registrar service (STATION_REGISTRAR.md). Default OFF.
#
# The image carries the core4 CLI (`wrfcoin`), which checks every row and signs
# it (`station registrar-sign`). The binary is NOT built here: the deploy kit
# copies the release CLI (built on CT102 in rust:*-bookworm, from a core4
# revision with the chain 888 registrar pins) to
# testnet/services/station-registrar/bin/wrfcoin, and the build refuses unless
# its sha256 equals WRFCOIN_CLI_SHA256. The image holds no key: the online
# registrar seed is a read-only bind mount at run time.

# node:24-slim (Debian bookworm): the CLI is a glibc binary and links libssl.
# The service has no npm dependencies, so there is no install stage.
FROM node:24-slim@sha256:ba849c60be29959425b8734d57b8b4b7d56f98edd9504c9af091d5281095a71e

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

WORKDIR /app

ENV NODE_ENV=production

# The state directory is created here, owned by the service user, so a fresh
# named volume mounted on it starts with that owner and mode.
# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends libssl3 ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    groupadd -g 1001 wrfcoin && \
    useradd -M -u 1001 -g wrfcoin -s /usr/sbin/nologin wrfcoin && \
    install -d -m 0700 -o wrfcoin -g wrfcoin /var/lib/station-registrar

ARG WRFCOIN_BUILD_REVISION
ARG WRFCOIN_BUILD_CREATED
ARG WRFCOIN_CLI_SHA256
LABEL org.opencontainers.image.revision="$WRFCOIN_BUILD_REVISION" \
      org.opencontainers.image.created="$WRFCOIN_BUILD_CREATED" \
      org.wrfcoin.cli.sha256="$WRFCOIN_CLI_SHA256"

COPY testnet/services/station-registrar/bin/wrfcoin /usr/local/bin/wrfcoin
# Fail closed: no pin, a different binary, or a CLI without the registrar signer.
RUN test -n "$WRFCOIN_CLI_SHA256" || { echo "WRFCOIN_CLI_SHA256 is required"; exit 1; }; \
    echo "$WRFCOIN_CLI_SHA256  /usr/local/bin/wrfcoin" | sha256sum -c - && \
    chmod 0755 /usr/local/bin/wrfcoin && \
    /usr/local/bin/wrfcoin station registrar-sign --help > /dev/null

COPY --chown=wrfcoin:wrfcoin testnet/services/station-registrar/package.json testnet/services/station-registrar/server.js testnet/services/station-registrar/store.js testnet/services/station-registrar/policy.js ./

USER wrfcoin

ENV STATION_REGISTRAR_CLI=/usr/local/bin/wrfcoin \
    HOME=/tmp \
    PORT=8095

EXPOSE 8095

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:8095/health').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"

CMD ["node", "server.js"]
