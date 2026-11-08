# WRFCoin testnet bond admission service (BOND_ADMISSION.md). Default OFF.
#
# The image carries the core4 CLI (`wrfcoin`), which does every packet check and
# the co-sign. The binary is NOT built here: the deploy kit copies the release
# CLI (built on CT102 in rust:*-bookworm, with the admission keys pinned) to
# testnet/services/bond-admission/bin/wrfcoin, and the build refuses unless its
# sha256 equals WRFCOIN_CLI_SHA256. The image holds no key: the admission seed
# is a read-only bind mount at run time.

# node:24-slim (Debian bookworm): the CLI is a glibc binary and links libssl.
FROM node:24-slim@sha256:ba849c60be29959425b8734d57b8b4b7d56f98edd9504c9af091d5281095a71e AS deps

WORKDIR /app

COPY testnet/services/bond-admission/package.json testnet/services/bond-admission/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

FROM node:24-slim@sha256:ba849c60be29959425b8734d57b8b4b7d56f98edd9504c9af091d5281095a71e AS runtime

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

WORKDIR /app

ENV NODE_ENV=production

# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends libssl3 ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    groupadd -g 1001 wrfcoin && \
    useradd -M -u 1001 -g wrfcoin -s /usr/sbin/nologin wrfcoin

ARG WRFCOIN_BUILD_REVISION
ARG WRFCOIN_BUILD_CREATED
ARG WRFCOIN_CLI_SHA256
LABEL org.opencontainers.image.revision="$WRFCOIN_BUILD_REVISION" \
      org.opencontainers.image.created="$WRFCOIN_BUILD_CREATED" \
      org.wrfcoin.cli.sha256="$WRFCOIN_CLI_SHA256"

COPY testnet/services/bond-admission/bin/wrfcoin /usr/local/bin/wrfcoin
# Fail closed: no pin, a different binary, or a binary that cannot start.
RUN test -n "$WRFCOIN_CLI_SHA256" || { echo "WRFCOIN_CLI_SHA256 is required"; exit 1; }; \
    echo "$WRFCOIN_CLI_SHA256  /usr/local/bin/wrfcoin" | sha256sum -c - && \
    chmod 0755 /usr/local/bin/wrfcoin && \
    /usr/local/bin/wrfcoin node bond admit --help > /dev/null

COPY --from=deps /app/node_modules ./node_modules
COPY --chown=wrfcoin:wrfcoin testnet/services/bond-admission/server.js testnet/services/bond-admission/store.js testnet/services/bond-admission/peer.js ./

USER wrfcoin

ENV BOND_ADMISSION_CLI=/usr/local/bin/wrfcoin \
    HOME=/tmp \
    PORT=8094

EXPOSE 8094

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:8094/health').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"

CMD ["node", "server.js"]
