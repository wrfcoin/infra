#!/usr/bin/env bash
# infra#1124: the faucet image must install from package-lock.json (npm ci), so the
# same revision always ships the same node_modules. Static check with a RED control.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKERFILE="${DOCKERFILE_UNDER_TEST:-$ROOT/testnet/services/faucet/Dockerfile}"
fail() { echo "FAUCET_LOCKFILE=FAIL $*" >&2; return 1; }

# check FILE -> 0 when the deps stage copies the lockfile and installs with npm ci.
check() {
  local f="$1" rc=0
  grep -Eq '^COPY[[:space:]]+testnet/services/faucet/package\.json[[:space:]]+testnet/services/faucet/package-lock\.json[[:space:]]+\./' "$f" \
    || { fail "deps stage does not COPY package.json AND package-lock.json"; rc=1; }
  grep -Eq '^RUN[[:space:]]+npm ci[[:space:]].*--omit=dev' "$f" \
    || { fail "deps stage does not run 'npm ci --omit=dev'"; rc=1; }
  if grep -Eq '^RUN[[:space:]]+npm install' "$f"; then fail "'npm install' still present (ignores the lockfile)"; rc=1; fi
  return "$rc"
}

# RED control: the pre-fix shape must be rejected.
T="$(mktemp)"; trap 'rm -f "$T"' EXIT
printf 'FROM node:24-alpine AS deps\nCOPY testnet/services/faucet/package.json ./\nRUN npm install --omit=dev --no-audit --no-fund\n' > "$T"
if check "$T" >/dev/null 2>&1; then fail "RED control: pre-fix Dockerfile was accepted"; exit 1; fi
echo "ok red control rejects npm install without the lockfile"

check "$DOCKERFILE" || exit 1
[[ -f "$ROOT/testnet/services/faucet/package-lock.json" ]] || { fail "package-lock.json missing"; exit 1; }
echo "FAUCET_LOCKFILE=PASS"
