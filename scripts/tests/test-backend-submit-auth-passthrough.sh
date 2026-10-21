#!/usr/bin/env bash
# wrfcoin-backend passes WEATHER_SUBMIT_AUTH_MODE from the host .env (backend#932). Without the entry the variable
# never reaches the container (the service uses an explicit environment list), so an operator setting
# WEATHER_SUBMIT_AUTH_MODE=enforce in .env would silently get `off`.
#
# Render-only: `docker compose config` with dummy values; nothing is built, pulled or started. A RED control removes the
# entry from a copy and must fail, so a check that goes blind is caught.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE="${ROOT}/testnet/docker-compose.testnet.yml"

fail() { printf 'SUBMIT_AUTH_PASSTHROUGH=FAIL %s\n' "$*" >&2; exit 1; }

if ! docker compose version >/dev/null 2>&1; then
  printf '%s\n' 'SUBMIT_AUTH_PASSTHROUGH=VOID docker compose is not available; nothing was rendered' >&2
  exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Placeholders only: every `${NAME:?...}` in the compose file needs a name.
grep -oh '\${[A-Z0-9_]*:?' "$COMPOSE" | sort -u | sed 's/^\${//; s/:?$//' | while read -r name; do
  printf '%s=placeholder\n' "$name"
done > "${tmp}/base.env"

mode() { # mode <compose> <env-file> -> the rendered WEATHER_SUBMIT_AUTH_MODE of wrfcoin-backend ("ABSENT" if none)
  bash "${ROOT}/testnet/tests/render-testnet-compose.sh" --project-directory "${ROOT}/testnet" --env-file "$2" -f "$1" config --format json \
    | python3 -c 'import json, sys
e = json.load(sys.stdin)["services"]["wrfcoin-backend"]["environment"]
print(e.get("WEATHER_SUBMIT_AUTH_MODE", "ABSENT"))'
}

cp "${tmp}/base.env" "${tmp}/enforce.env"; echo 'WEATHER_SUBMIT_AUTH_MODE=enforce' >> "${tmp}/enforce.env"
cp "${tmp}/base.env" "${tmp}/off.env"; echo 'WEATHER_SUBMIT_AUTH_MODE=off' >> "${tmp}/off.env"

[[ "$(mode "$COMPOSE" "${tmp}/base.env")" == off ]] || fail 'unset must render off (behaviour-preserving default)'
[[ "$(mode "$COMPOSE" "${tmp}/off.env")" == off ]] || fail 'off must render off'
[[ "$(mode "$COMPOSE" "${tmp}/enforce.env")" == enforce ]] || fail 'enforce must render enforce'

# RED control: without the entry the variable is ABSENT even when .env says enforce.
grep -v 'WEATHER_SUBMIT_AUTH_MODE' "$COMPOSE" > "${tmp}/mutated.yml"
[[ "$(mode "${tmp}/mutated.yml" "${tmp}/enforce.env")" == ABSENT ]] || fail 'RED control did not go red (check is blind)'

printf '%s\n' 'SUBMIT_AUTH_PASSTHROUGH=PASS unset->off, off->off, enforce->enforce; RED control (entry removed) renders ABSENT'
