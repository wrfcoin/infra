#!/usr/bin/env bash
# infra#1121: the faucet on current main exits at startup unless
# FAUCET_HIGH_WATER_MARK is set (validateHighWaterConfig in
# testnet/services/faucet/server.js), and compose deliberately gives it no
# default. check-env-completeness.sh must catch that before `up`, whenever the
# chain defines the faucet and an active profile (faucet, seed or *) starts it,
# and must never print the value.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="${CHECK_UNDER_TEST:-$ROOT/testnet/check-env-completeness.sh}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/faucet-high-water-env.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# A chain that defines the faucet (profile-gated, as in docker-compose.testnet.yml)
# and one that does not. Neither has `:?` variables or CORS_ORIGIN readers, so
# only the checks under test can fail.
cat > "$TMP/with-faucet.yml" <<'YAML'
services:
  wrfcoin-faucet:
    image: fixture/faucet
    profiles: ["seed", "faucet"]
    environment:
      FAUCET_HIGH_WATER_MARK: ${FAUCET_HIGH_WATER_MARK:-}
YAML
cat > "$TMP/without-faucet.yml" <<'YAML'
services:
  wrfcoin-node:
    image: fixture/node
YAML
# Synthetic pins that pin no snapshot signer: the real cut-pins.env is not read.
printf 'WRFCOIN_CUT_CHAIN_ID=777\n' > "$TMP/pins.env"

MARKER_PREFIX="hw-marker-$RANDOM$RANDOM"
ERR_LINE='ERROR FAUCET_HIGH_WATER_MARK'

run_check() { # NAME CHAIN-FILE [ENV-LINES...]; honours an exported COMPOSE_PROFILES
  local name="$1" chain="$2"
  shift 2
  printf '%s\n' "$@" > "$TMP/$name.env"
  set +e
  "$CHECK" -f "$chain" --env "$TMP/$name.env" --cut-pins "$TMP/pins.env" > "$TMP/$name.out" 2>&1
  echo $? > "$TMP/$name.rc"
  set -e
}
expect() { # NAME WANT-RC WANT-TEXT|- CHAIN [ENV-LINES...]
  local name="$1" want_rc="$2" want="$3" chain="$4" rc
  shift 4
  run_check "$name" "$chain" "$@"
  rc="$(cat "$TMP/$name.rc")"
  if [[ "$rc" != "$want_rc" ]]; then
    sed 's/^/    /' "$TMP/$name.out" >&2
    fail "$name: exit $rc, expected $want_rc"
  fi
  if [[ "$want" == - ]]; then
    ! grep -Fq "$ERR_LINE" "$TMP/$name.out" || { sed 's/^/    /' "$TMP/$name.out" >&2; fail "$name: unexpected $ERR_LINE"; }
  else
    grep -Fq -- "$want" "$TMP/$name.out" || { sed 's/^/    /' "$TMP/$name.out" >&2; fail "$name: missing '$want'"; }
  fi
  # The value is operator configuration; the gate reports only its class.
  if grep -Fq "$MARKER_PREFIX" "$TMP/$name.out"; then
    fail "$name: the gate printed the FAUCET_HIGH_WATER_MARK value"
  fi
  echo "ok: $name"
}

unset COMPOSE_PROFILES
F="$TMP/with-faucet.yml"

echo "-- faucet profile active via .env: the mark is required"
expect absent_red         1 "$ERR_LINE: unset or empty" "$F" 'COMPOSE_PROFILES=faucet'
expect empty_red          1 "$ERR_LINE: unset or empty" "$F" 'COMPOSE_PROFILES=faucet' 'FAUCET_HIGH_WATER_MARK='
expect quoted_empty_red   1 "$ERR_LINE: unset or empty" "$F" 'COMPOSE_PROFILES=faucet' 'FAUCET_HIGH_WATER_MARK=""'
expect seed_profile_red   1 "$ERR_LINE: unset or empty" "$F" 'COMPOSE_PROFILES="seed,collector"'
expect star_profile_red   1 "$ERR_LINE: unset or empty" "$F" 'COMPOSE_PROFILES=*'
# The last assignment wins, as in compose's .env parsing.
expect last_line_wins_red 1 "$ERR_LINE: unset or empty" "$F" 'COMPOSE_PROFILES=faucet' 'FAUCET_HIGH_WATER_MARK=500' 'FAUCET_HIGH_WATER_MARK='

echo "-- malformed values (server.js toBaseUnits / parseRequiredBaseUnits), never printed"
i=0
for bad in "${MARKER_PREFIX}" "${MARKER_PREFIX}5" "0" "0.0" "000" "-5" "+5" "1.123456789" "1e3" "5." ".5" "1 000" "90071992.54740992"; do
  i=$((i + 1))
  expect "malformed_${i}_red" 1 "$ERR_LINE: malformed" "$F" 'COMPOSE_PROFILES=faucet' "FAUCET_HIGH_WATER_MARK=$bad"
done

echo "-- well-formed values pass"
expect whole_green        0 - "$F" 'COMPOSE_PROFILES=faucet' 'FAUCET_HIGH_WATER_MARK=500'
expect decimal_green      0 - "$F" 'COMPOSE_PROFILES=faucet' 'FAUCET_HIGH_WATER_MARK=250.12345678'
expect quoted_green       0 - "$F" 'COMPOSE_PROFILES=faucet' 'FAUCET_HIGH_WATER_MARK="1000"'
expect max_safe_green     0 - "$F" 'COMPOSE_PROFILES=faucet' 'FAUCET_HIGH_WATER_MARK=90071992.54740991'
grep -Fq 'faucet: FAUCET_HIGH_WATER_MARK set' "$TMP/whole_green.out" || fail "whole_green: no positive confirmation line"

echo "-- not required when the faucet cannot start"
expect no_profile_green      0 - "$F"
expect other_profile_green   0 - "$F" 'COMPOSE_PROFILES=collector'
expect faucet_not_in_chain   0 - "$TMP/without-faucet.yml" 'COMPOSE_PROFILES=faucet'

echo "-- an exported COMPOSE_PROFILES wins over the .env line, as in compose"
COMPOSE_PROFILES=faucet expect exported_profile_red 1 "$ERR_LINE: unset or empty" "$F" 'COMPOSE_PROFILES=collector'
COMPOSE_PROFILES=collector expect exported_other_green 0 - "$F" 'COMPOSE_PROFILES=faucet'
COMPOSE_PROFILES='' expect exported_empty_green 0 - "$F" 'COMPOSE_PROFILES=faucet'

echo "-- the repository example documents the mark"
grep -Eq '^FAUCET_HIGH_WATER_MARK=' "$ROOT/testnet/.env.testnet.example" \
  || fail ".env.testnet.example does not document FAUCET_HIGH_WATER_MARK"

echo "FAUCET_HIGH_WATER_ENV_TESTS=PASS"
