#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/infra/docker/assert-migration-image-freshness.sh"
DOCKERFILE="${ROOT}/infra/docker/Dockerfile.backend"
COMPOSE="${ROOT}/testnet/docker-compose.testnet.yml"
EXPECTED="0029_user_achievements_no_authorizing_defaults"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'DB_MIGRATION_FRESHNESS_TESTS=FAIL %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP/migrations/meta"
touch "$TMP/migrations/0023_referrals.sql"
touch "$TMP/migrations/0025_mobile_station_registrations.sql"
touch "$TMP/migrations/${EXPECTED}.sql"
cat > "$TMP/migrations/meta/_journal.json" <<'JSON'
{"entries":[{"idx":23,"tag":"0023_referrals"},{"idx":24,"tag":"0024_weather_data_freshness_index"},{"idx":25,"tag":"0025_mobile_station_registrations"},{"idx":29,"tag":"0029_user_achievements_no_authorizing_defaults"}]}
JSON

echo fresh_image_passes
WRFCOIN_EXPECTED_DB_MIGRATION="$EXPECTED" \
  WRFCOIN_MIGRATIONS_DIR="$TMP/migrations" \
  sh "$CHECKER" | grep -Fq "latest=${EXPECTED}"

echo stale_image_names_missing_migration
rm "$TMP/migrations/${EXPECTED}.sql"
set +e
WRFCOIN_EXPECTED_DB_MIGRATION="$EXPECTED" \
  WRFCOIN_MIGRATIONS_DIR="$TMP/migrations" \
  sh "$CHECKER" >"$TMP/stale.out" 2>&1
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "stale image returned ${rc}, expected 1"
grep -Fq "missing migration ${EXPECTED}.sql" "$TMP/stale.out" || \
  fail "stale image failure did not name ${EXPECTED}.sql"

echo journal_behind_fails
touch "$TMP/migrations/${EXPECTED}.sql"
cat > "$TMP/migrations/meta/_journal.json" <<'JSON'
{"entries":[{"idx":23,"tag":"0023_referrals"},{"idx":24,"tag":"0024_weather_data_freshness_index"},{"idx":25,"tag":"0025_mobile_station_registrations"}]}
JSON
set +e
WRFCOIN_EXPECTED_DB_MIGRATION="$EXPECTED" \
  WRFCOIN_MIGRATIONS_DIR="$TMP/migrations" \
  sh "$CHECKER" >"$TMP/journal.out" 2>&1
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "behind journal returned ${rc}, expected 1"
grep -Fq "ends at 0025_mobile_station_registrations; expected ${EXPECTED}" "$TMP/journal.out" || \
  fail "behind journal failure did not name actual and expected migrations"

echo deployed_path_is_wired
grep -Fq 'COPY infra/infra/docker/assert-migration-image-freshness.sh /usr/local/bin/assert-migration-image-freshness' "$DOCKERFILE" || \
  fail "Dockerfile does not bake the assertion into the migration image"
grep -Fq '/usr/local/bin/assert-migration-image-freshness' "$COMPOSE" || \
  fail "db-migrate does not execute the assertion"
grep -Fq "WRFCOIN_EXPECTED_DB_MIGRATION: \"${EXPECTED}\"" "$COMPOSE" || \
  fail "db-migrate does not pin ${EXPECTED}"

echo DB_MIGRATION_FRESHNESS_TESTS=PASS
