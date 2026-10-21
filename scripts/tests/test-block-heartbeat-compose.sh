#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/render.env" <<'EOF'
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
EOF
render() {
    local heartbeat_args=(--profile block-heartbeat-n5)
    if [[ "${1:-}" == ws ]]; then heartbeat_args=(--profile block-heartbeat-ws); fi
    if [[ "${1:-}" == mango ]]; then heartbeat_args=(--profile block-heartbeat-mango); fi
    local overlay_args=(-f "$repo/testnet/docker-compose.block-heartbeat.yml")
    if [[ "${1:-}" == baseline ]]; then heartbeat_args=(--profile block-heartbeat-n5); overlay_args=(-f "$BASELINE_OVERLAY"); fi
    if [[ "${1:-}" == n5rot ]]; then overlay_args+=(-f "$repo/testnet/docker-compose.block-heartbeat-rotation.n5.yml"); fi
    if [[ "${1:-}" == off ]]; then heartbeat_args=(); fi
    if [[ "${1:-}" == base ]]; then heartbeat_args=(); overlay_args=(); fi
    bash "$repo/testnet/tests/render-testnet-compose.sh" --env-file "$scratch/render.env" "${heartbeat_args[@]}" --profile collector \
        -f "$repo/testnet/docker-compose.testnet.yml" \
        -f "$repo/testnet/docker-compose.override.yml" \
        -f "$repo/testnet/docker-compose.cut-miner.yml" \
        "${overlay_args[@]}" config --format json
}
render > "$scratch/default.json"
render off > "$scratch/off.json"
render base > "$scratch/base.json"
render n5rot > "$scratch/n5rot.json"
# Golden guard: the default N5 block-heartbeat render must equal the committed fixture (generated from
# the pre-#1327 overlay). A diff, or a missing fixture, FAILS. Regenerate: see the fixture header.
fixture="$repo/scripts/tests/fixtures/block-heartbeat-n5-default.render.yml"
if [[ -n "${BASELINE_OVERLAY:-}" ]]; then
    render baseline > "$scratch/baseline.json"; src="$scratch/baseline.json"
    node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1])).services["block-heartbeat"];console.log(JSON.stringify(s,null,2))' "$src"
    exit 0
fi
[[ -f "$fixture" ]] || { echo "missing golden fixture $fixture" >&2; exit 1; }
node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1])).services["block-heartbeat"];console.log(JSON.stringify(s,null,2))' "$scratch/default.json" > "$scratch/n5-default.render"
grep -v '^#' "$fixture" > "$scratch/fixture.body"
diff "$scratch/fixture.body" "$scratch/n5-default.render" || { echo "N5 default block-heartbeat render differs from golden fixture" >&2; exit 1; }
echo "N5 default render matches golden fixture"
render ws > "$scratch/ws.json"
render mango > "$scratch/mango.json"
COLLECTOR_CORE4_PATH=/reviewed/core4 WEATHER_COLLECTOR_MINE=false render > "$scratch/first.json"
COLLECTOR_CORE4_PATH=/reviewed/core4 COLLECTOR_MINE=false render > "$scratch/both.json"
node - "$scratch" <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const read = (name) => JSON.parse(fs.readFileSync(`${process.argv[2]}/${name}.json`));
const base = read('default').services;
const first = read('first').services;
const both = read('both').services;
const original = read('base').services;
assert.equal(read('off').services['block-heartbeat'], undefined);
assert.deepEqual(base['block-heartbeat'].profiles, ['block-heartbeat-n5']);
assert.equal(base['block-heartbeat'].environment.BLOCK_HEARTBEAT_INTERVAL_SECONDS, '77');
assert.equal(base['block-heartbeat'].environment.WRFCOIN_MINER_ADDRESS, base['weather-collector'].environment.WRFCOIN_MINER_ADDRESS);
assert.equal(base['block-heartbeat'].environment.WRFCOIN_OPERATOR_TOKEN, base['weather-collector'].environment.WRFCOIN_OPERATOR_TOKEN);
assert.equal(base['weather-collector'].environment.COLLECTOR_MINE, 'true');
assert.equal(base['weather-collector-multi'].environment.COLLECTOR_MINE, 'true');
assert.equal(first['weather-collector'].environment.COLLECTOR_MINE, 'false');
assert.equal(first['weather-collector-multi'].environment.COLLECTOR_MINE, 'true');
for (const name of ['weather-collector', 'weather-collector-multi']) {
    assert.deepEqual(base[name].volumes, original[name].volumes);
    assert.deepEqual(base[name].command, original[name].command);
    assert.equal(both[name].environment.COLLECTOR_MINE, 'false');
    const mounted = both[name].volumes.filter((v) => ['/app/tests/security', '/app/tests/utils'].includes(v.target));
    assert.equal(mounted.length, 2);
    assert.ok(mounted.every((v) => v.source.startsWith('/reviewed/core4/') && v.read_only));
}
assert.deepEqual(first['wrfcoin-node'], base['wrfcoin-node']);
assert.ok(base['block-heartbeat'].healthcheck.test.includes('--healthcheck'));
// Docker rejects tmpfs options split into separate entries ('nosuid' is not an absolute mount path):
// the flow-sequence entry must stay ONE string, so every rendered tmpfs entry is an absolute path.
assert.deepEqual(base['block-heartbeat'].tmpfs, ['/tmp:noexec,nosuid,size=1m']);
for (const entry of base['block-heartbeat'].tmpfs) assert.ok(entry.startsWith('/'), `tmpfs entry ${entry} is not absolute`);
// Rotation profiles (#1327): off by default, each pinned to its own address with matching SELF.
assert.equal(base['block-heartbeat-ws'], undefined);
assert.equal(base['block-heartbeat-mango'], undefined);
const n5env = base['block-heartbeat'].environment;
assert.ok(!Object.keys(n5env).some((k) => ['BLOCK_HEARTBEAT_ROTATION', 'BLOCK_HEARTBEAT_SELF', 'BLOCK_HEARTBEAT_FALLBACK_STEP_SECONDS'].includes(k)));
const rotEnv = read('n5rot').services['block-heartbeat'].environment;
const added = Object.keys(rotEnv).filter((k) => !(k in n5env)).sort();
assert.deepEqual(added, ['BLOCK_HEARTBEAT_FALLBACK_STEP_SECONDS', 'BLOCK_HEARTBEAT_ROTATION', 'BLOCK_HEARTBEAT_SELF']);
assert.equal(rotEnv.BLOCK_HEARTBEAT_SELF, 'n5-node-a');
assert.equal(rotEnv.WRFCOIN_MINER_ADDRESS, n5env.WRFCOIN_MINER_ADDRESS);
for (const k of Object.keys(n5env)) assert.equal(rotEnv[k], n5env[k]);
const ws = read('ws').services['block-heartbeat-ws'];
const mango = read('mango').services['block-heartbeat-mango'];
assert.deepEqual(ws.profiles, ['block-heartbeat-ws']);
assert.deepEqual(mango.profiles, ['block-heartbeat-mango']);
assert.equal(ws.environment.BLOCK_HEARTBEAT_SELF, 'producer-standby');
assert.equal(ws.environment.WRFCOIN_MINER_ADDRESS, '0x39ee2e595a55c71256282fe5c42a398594985b1a');
assert.equal(mango.environment.BLOCK_HEARTBEAT_SELF, 'mango-mini');
assert.equal(mango.environment.WRFCOIN_MINER_ADDRESS, '0xc536d2026661522cb8631b3c723d4af43784a990');
for (const svc of [ws, mango]) {
    assert.equal(svc.environment.BLOCK_HEARTBEAT_ROTATION, 'n5-node-a,producer-standby,mango-mini');
    assert.equal(svc.environment.BLOCK_HEARTBEAT_FALLBACK_STEP_SECONDS, '60');
    assert.deepEqual(svc.tmpfs, ['/tmp:noexec,nosuid,size=1m']);
    assert.equal(svc.read_only, true);
}
console.log('Compose: five render controls + tmpfs shape passed');
JS
