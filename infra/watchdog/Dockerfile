# Base image is node:24-alpine (Dockerfile has no inline comments — a trailing
# `#` on a FROM line is parsed as arguments, which broke this file, see infra#708).
#
# Build context: infra/watchdog/ (this directory). The service is self-contained
# and needs no sibling repository — see docker-compose.watchdog.yml alongside.
#
# Two stages because `dist/` is a TypeScript build product that is not committed
# (.gitignore:6 ignores `dist/` repo-wide). The single-stage version of this file
# COPYed `dist/` directly and so could never be built from a clean checkout —
# infra#748. The build step it needs already exists as `npm run build` (tsc);
# nothing invoked it.

# =============================================================================
# Stage 1: Build — compile src/ to dist/ with the project's own tsc
# =============================================================================
FROM node:24-alpine@sha256:06d7adf3e0ef61a13f1d28682726366f97a15aa1888c934d3ecec86c33918b53 AS build

WORKDIR /app

# Full install: typescript is a devDependency and is the compiler.
COPY package*.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src/ ./src/

RUN npm run build

# =============================================================================
# Stage 2: Runtime — production dependencies plus the compiled output
# =============================================================================
FROM node:24-alpine@sha256:06d7adf3e0ef61a13f1d28682726366f97a15aa1888c934d3ecec86c33918b53

WORKDIR /app

COPY package*.json ./
RUN npm ci --omit=dev

COPY --from=build /app/dist/ ./dist/
COPY config/ ./config/

# Non-root user matching core4/infra convention (UID 1001)
RUN addgroup -g 1001 wrfcoin && \
    adduser -D -u 1001 -G wrfcoin wrfcoin && \
    chown -R wrfcoin:wrfcoin /app && \
    mkdir -p /data/journal && chown wrfcoin:wrfcoin /data/journal

# Docker socket mount point (read-only) for container log access
VOLUME ["/var/run/docker.sock"]

# Journal output directory
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s \
  CMD node -e "fetch('http://localhost:3334/health').then(r => r.ok || process.exit(1)).catch(() => process.exit(1))"

USER wrfcoin

EXPOSE 3334

CMD ["node", "dist/index.js"]
