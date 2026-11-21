#!/usr/bin/env bash
# The station registrar compose entry is inert by default: own profile, enabled=false,
# no host port, no key unless a host key directory is named, read-only container.
# The Dockerfile refuses a missing or wrong CLI hash and carries no key.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/render.env" <<'ENV'
WRFCOIN_OPERATOR_TOKEN=render-only-operator
WRFCOIN_CONTRIBUTOR_TOKEN=render-only-contributor
WRFCOIN_READER_TOKEN=render-only-reader
JWT_SECRET=render-only-jwt-not-a-deployment-secret
POSTGRES_PASSWORD=render-only-postgres
REDIS_PASSWORD=render-only-redis
ADMIN_TOKEN=render-only-admin
GRAFANA_ADMIN_PASSWORD=render-only-grafana
N8N_WEBHOOK_SECRET=render-only-webhook
OAUTH_STATE_SECRET=render-only-oauth
RPC_API_KEY=render-only-rpc
WRFCOIN_P2P_EXTERNAL_ADDR=/ip4/198.51.100.7/tcp/9000
WRFCOIN_SEED_P2P_EXTERNAL_ADDR=/ip4/203.0.113.9/tcp/9000
ENV
render() {
    bash "$repo/testnet/tests/render-testnet-compose.sh" --env-file "$scratch/render.env" "$@" \
        -f "$repo/testnet/docker-compose.testnet.yml" config --format json
}
render > "$scratch/off.json"
render --profile station-registrar > "$scratch/on.json"
STATION_REGISTRAR_KEY_DIR=/root/station-registrar render --profile station-registrar > "$scratch/keyed.json"
node - "$scratch" <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const read = (name) => JSON.parse(fs.readFileSync(`${process.argv[2]}/${name}.json`)).services;
const name = 'wrfcoin-station-registrar';
assert.equal(read('off')[name], undefined, 'not started without its profile');
const s = read('on')[name];
assert.deepEqual(s.profiles, ['station-registrar']);
assert.equal(s.environment.STATION_REGISTRAR_ENABLED, 'false');
assert.equal(s.environment.WRFCOIN_NETWORK_ID, 'testnet');
assert.equal(s.environment.STATION_REGISTRAR_SOFT_CEILING, '128');
assert.equal(s.environment.STATION_REGISTRAR_HOLD_SECONDS, '86400');
for (const k of ['STATION_REGISTRAR_GENESIS_HASH', 'STATION_REGISTRAR_NODE_TOKEN', 'STATION_REGISTRAR_IP_SALT', 'STATION_REGISTRAR_TRUSTED_PROXIES']) {
  assert.equal(s.environment[k], '', `${k} empty by default (fail closed)`);
}
assert.equal(s.environment.STATION_REGISTRAR_KEY_FILE, '/run/station-registrar/registrar-online.key');
assert.equal(s.ports, undefined, 'no host port');
assert.equal(s.read_only, true);
assert.deepEqual(s.cap_drop, ['ALL']);
const key = s.volumes.find((v) => v.target === '/run/station-registrar');
assert.ok(key && key.read_only === true, 'key mount is read-only');
assert.match(key.source, /station-registrar-key-absent$/, 'no key directory unless named');
const state = s.volumes.find((v) => v.target === '/var/lib/station-registrar');
assert.equal(state.type, 'volume');
assert.ok(s.environment.STATION_REGISTRAR_STOP_FILE.startsWith('/var/lib/station-registrar/'));
assert.ok(s.environment.STATION_REGISTRAR_STATE_FILE.startsWith('/var/lib/station-registrar/'));
const keyed = read('keyed')[name].volumes.find((v) => v.target === '/run/station-registrar');
assert.equal(keyed.source, '/root/station-registrar');
assert.equal(keyed.read_only, true);
// The profile adds this one service and touches no other.
const off = read('off');
const on = read('on');
assert.deepEqual(Object.keys(on).filter((k) => !(k in off)), [name]);
for (const k of Object.keys(off)) assert.deepEqual(on[k], off[k], `${k} unchanged by the profile`);
JS
dockerfile="$repo/testnet/services/station-registrar/Dockerfile"
# shellcheck disable=SC2016 # the literal Dockerfile text, not an expansion
grep -q 'test -n "$WRFCOIN_CLI_SHA256"' "$dockerfile"
grep -q 'sha256sum -c -' "$dockerfile"
grep -q 'wrfcoin station registrar-sign --help' "$dockerfile"
grep -q '^USER wrfcoin$' "$dockerfile"
if grep -nEi 'key-file|\.key\b|seed' "$dockerfile" | grep -v '^[0-9]*:#'; then
    echo "Dockerfile must not reference a key" >&2; exit 1
fi
# Every file server.js requires is copied into the image.
while read -r f; do
    grep -q "testnet/services/station-registrar/$f.js" "$dockerfile" || { echo "image misses $f.js" >&2; exit 1; }
done < <(grep -o "require('\./[a-z-]*')" "$repo/testnet/services/station-registrar/server.js" | sed "s/require('\.\/\(.*\)')/\1/")
git -C "$repo" check-ignore -q testnet/services/station-registrar/bin/wrfcoin || { echo "bin/wrfcoin must be git-ignored" >&2; exit 1; }
echo "station registrar compose entry: inert by default"
