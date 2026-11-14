# WRFCoin testnet claim mailbox (CLAIM_MAILBOX.md). Default OFF.
# Holds no key and no chain client: it stores and serves public claim hex only.

FROM node:24-slim@sha256:ba849c60be29959425b8734d57b8b4b7d56f98edd9504c9af091d5281095a71e AS deps

WORKDIR /app

COPY testnet/services/claim-mailbox/package.json testnet/services/claim-mailbox/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

FROM node:24-slim@sha256:ba849c60be29959425b8734d57b8b4b7d56f98edd9504c9af091d5281095a71e AS runtime

WORKDIR /app

ENV NODE_ENV=production

RUN groupadd -g 1001 wrfcoin && \
    useradd -M -u 1001 -g wrfcoin -s /usr/sbin/nologin wrfcoin

ARG WRFCOIN_BUILD_REVISION
ARG WRFCOIN_BUILD_CREATED
LABEL org.opencontainers.image.revision="$WRFCOIN_BUILD_REVISION" \
      org.opencontainers.image.created="$WRFCOIN_BUILD_CREATED"

COPY --from=deps /app/node_modules ./node_modules
COPY --chown=wrfcoin:wrfcoin testnet/services/claim-mailbox/server.js testnet/services/claim-mailbox/store.js ./

USER wrfcoin

ENV PORT=8095

EXPOSE 8095

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:8095/health').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"

CMD ["node", "server.js"]
