#!/bin/sh
set -eu

expected="${WRFCOIN_EXPECTED_DB_MIGRATION:-}"
migrations_dir="${WRFCOIN_MIGRATIONS_DIR:-/app/backend/drizzle/migrations}"

if [ -z "$expected" ]; then
  echo "ERROR: WRFCOIN_EXPECTED_DB_MIGRATION is not set; refusing to run db-migrate" >&2
  exit 1
fi

expected_sql="${migrations_dir}/${expected}.sql"
journal="${migrations_dir}/meta/_journal.json"

if [ ! -f "$expected_sql" ]; then
  echo "ERROR: stale db-migrate image is missing migration ${expected}.sql" >&2
  exit 1
fi

if [ ! -f "$journal" ]; then
  echo "ERROR: stale db-migrate image is missing migration journal ${journal}" >&2
  exit 1
fi

last_tag="$(node - "$journal" <<'NODE'
const fs = require('node:fs');
const journal = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const entries = Array.isArray(journal.entries) ? journal.entries : [];
if (entries.length === 0 || typeof entries.at(-1)?.tag !== 'string') process.exit(2);
process.stdout.write(entries.at(-1).tag);
NODE
)" || {
  echo "ERROR: migration journal is empty or invalid: ${journal}" >&2
  exit 1
}

if [ "$last_tag" != "$expected" ]; then
  echo "ERROR: stale db-migrate image ends at ${last_tag}; expected ${expected}" >&2
  exit 1
fi

echo "DB_MIGRATION_IMAGE_FRESHNESS=PASS latest=${last_tag}"
