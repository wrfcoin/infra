# WRFCoin Testnet Faucet Service
#
# Self-contained Express service for faucet claims. Builds locally only and
# keeps all secrets in environment variables.

# Pinned 2026-07-09. Next CVE review: 2026-08-08 (see infra#336).
FROM node:24-alpine@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1 AS deps

WORKDIR /app

# npm ci installs exactly the committed lockfile (infra#1124) and fails if it and
# package.json disagree, so one infra revision always ships the same node_modules.
COPY testnet/services/faucet/package.json testnet/services/faucet/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

FROM node:24-alpine@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1 AS runtime

WORKDIR /app

ENV NODE_ENV=production

RUN apk add --no-cache curl && \
    addgroup -g 1001 -S wrfcoin && \
    adduser -S -D -H -u 1001 -G wrfcoin wrfcoin

# Release provenance (infra#991, infra#1121): the release gate classifies this
# image by these labels. export-build-provenance.sh sets the args; a build
# without them still succeeds, but its empty labels classify UNAVAILABLE.
ARG WRFCOIN_BUILD_REVISION
ARG WRFCOIN_BUILD_CREATED
LABEL org.opencontainers.image.revision="$WRFCOIN_BUILD_REVISION" \
      org.opencontainers.image.created="$WRFCOIN_BUILD_CREATED"

COPY --from=deps /app/node_modules ./node_modules
COPY --chown=wrfcoin:wrfcoin testnet/services/faucet/server.js testnet/services/faucet/bond-grant-peer.js ./

USER wrfcoin

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:8080/health || exit 1

CMD ["node", "server.js"]
