'use strict';

/**
 * Synthetic weather-contribution submitter for the WRFCoin testnet.
 *
 * Purpose
 * -------
 * Keeps the testnet self-sustaining: it submits a valid
 * ContributionCommit + ContributionReveal pair every cycle and then mines a
 * single block, so the chain advances continuously WITHOUT the operator
 * `/blocks/mine` loop and WITHOUT requiring the real Ambient Weather collector
 * (which needs external API credentials for Jon's WS-5000 station).
 *
 * Every block it produces therefore contains:
 *   Coinbase + ContributionCommit + ContributionReveal   (transaction_count >= 3)
 *
 * This is the same on-chain commit/reveal contract the real collector uses
 * (core4/tests/security/fetch-ambient-weather.cjs); the only difference is the
 * weather reading is generated locally instead of fetched from an external PWS.
 *
 * Commit/reveal hash contract (must match shared-protocol
 * `Transaction::compute_commit_id`):
 *   commit_hash = sha3-256(
 *       JSON.stringify(sortKeys(reading)) || nonce || station_id ||
 *       timestamp(seconds) || "contribution"
 *   )
 * The node recomputes this on reveal and rejects mismatches, so the JSON
 * serialization (sorted keys) and the seconds-resolution timestamp must match
 * exactly on both the commit and reveal legs.
 *
 * Zero external dependencies — pure Node stdlib (runs in a bare node:20-alpine
 * container). No host sensors, no RTL-SDR, no external API keys.
 *
 * Environment variables:
 *   WRFCOIN_OPERATOR_TOKEN   (required) testnet operator bearer token
 *   WRFCOIN_API_HOST         default wrfcoin-node
 *   WRFCOIN_API_PORT         default 8556
 *   SYNTH_STATION_ID         default PWS-SYNTH-TESTNET-01
 *   SYNTH_CONTRIBUTOR        default dedicated synthetic testnet address
 *   SYNTH_REAL_CONTRIBUTOR   real collector address that synthetic must not use
 *   SYNTH_MINER_ADDRESS      required authorized producer payout address
 *   SYNTH_INTERVAL_SECONDS   default 60 (loop cadence; <=0 = run once and exit)
 *   SYNTH_LAT / SYNTH_LON / SYNTH_ELEVATION_M   station coords (optional)
 */

const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOST = process.env.WRFCOIN_API_HOST || 'wrfcoin-node';
const PORT = parseInt(process.env.WRFCOIN_API_PORT || '8556', 10);
const TOKEN = process.env.WRFCOIN_OPERATOR_TOKEN;
const STATION_ID = process.env.SYNTH_STATION_ID || 'PWS-SYNTH-TESTNET-01';
// Encodes "SYNTHETIC" in the leading bytes. This is a dedicated testnet
// contributor identity, not Jon's real Ambient Weather wallet.
const DEFAULT_SYNTH_CONTRIBUTOR = '0x53594e5448455449430000000000000000000001';
const DEFAULT_REAL_CONTRIBUTOR = '0x5Eaf842a8341CD38812A63De6B5dcc5103f071c0';
const CONTRIBUTOR =
    process.env.SYNTH_CONTRIBUTOR || DEFAULT_SYNTH_CONTRIBUTOR;
const REAL_CONTRIBUTOR =
    process.env.SYNTH_REAL_CONTRIBUTOR || DEFAULT_REAL_CONTRIBUTOR;
const MINER_ADDRESS = process.env.SYNTH_MINER_ADDRESS;
const INTERVAL_SECONDS = parseInt(process.env.SYNTH_INTERVAL_SECONDS || '60', 10);
const LAT = process.env.SYNTH_LAT != null ? parseFloat(process.env.SYNTH_LAT) : 10.0;
const LON = process.env.SYNTH_LON != null ? parseFloat(process.env.SYNTH_LON) : 20.0;
const ELEVATION_M =
    process.env.SYNTH_ELEVATION_M != null ? parseFloat(process.env.SYNTH_ELEVATION_M) : 220;

function normalizedContributorAddress(value, label) {
    if (!/^0x[0-9a-fA-F]{40}$/.test(value || '')) {
        throw new Error(`${label} must be a 20-byte 0x-prefixed address`);
    }
    return value.toLowerCase();
}

function assertDistinctContributorIdentities(synthetic = CONTRIBUTOR, real = REAL_CONTRIBUTOR) {
    const syntheticAddress = normalizedContributorAddress(synthetic, 'SYNTH_CONTRIBUTOR');
    const realAddress = normalizedContributorAddress(real, 'SYNTH_REAL_CONTRIBUTOR');
    if (syntheticAddress === realAddress) {
        throw new Error(
            'SYNTH_CONTRIBUTOR must differ from SYNTH_REAL_CONTRIBUTOR; ' +
            'synthetic and real reward identities must never collapse',
        );
    }
}

// ---------------------------------------------------------------------------
// Commit/reveal hashing (matches serde_json default BTreeMap key ordering on
// the Rust side, i.e. sorted object keys).
// ---------------------------------------------------------------------------
function sortKeys(obj) {
    if (Array.isArray(obj)) return obj.map(sortKeys);
    if (obj !== null && typeof obj === 'object') {
        return Object.keys(obj)
            .sort()
            .reduce((acc, key) => {
                acc[key] = sortKeys(obj[key]);
                return acc;
            }, {});
    }
    return obj;
}

function computeCommitId(data, nonce, stationId, timestamp, contributionType) {
    const dataStr = JSON.stringify(sortKeys(data));
    const preimage = `${dataStr}||${nonce}||${stationId}||${timestamp}||${contributionType}`;
    return crypto.createHash('sha3-256').update(preimage).digest('hex');
}

// ---------------------------------------------------------------------------
// Commit-authorization signing (#1848, v2 domain #2034/#2076).
//
// The node's mempool admission is fail-closed: a ContributionCommit is rejected
// ("commit sender authorization failed") unless its payload carries a valid
// `auth_pubkey` + `auth_signature` over the canonical authorization message.
// There is NO binding of the pubkey to the contributor address, so any ed25519
// keypair whose signature verifies over the correct message is accepted — this
// collector manages its own stable key.
//
// Ported verbatim from the proven reference implementation in
// core4/tests/security/lib/ambient-pipeline.cjs (mirrors shared-protocol
// `commit_authorization_message_with_domain` / `push_chain_domain` exactly):
//
//   b"wrfcoin_commit_auth_v2"
//     ++ u32_LE(chain_id.len)   ++ chain_id_utf8       (chain_domain)
//     ++ u32_LE(network_id.len) ++ network_id_utf8      (chain_domain)
//     ++ u32_LE(station_id.len) ++ station_id_utf8
//     ++ u32_LE(commit_id.len)  ++ commit_id_utf8
//     ++ u32_LE(type.len)       ++ contribution_type_utf8
//
// Crypto interop: ed25519-dalek raw-hex. `auth_pubkey` = raw 32-byte public key
// hex; `auth_signature` = raw 64-byte signature hex (Ed25519 over the raw
// message bytes via Node `crypto.sign(null, ...)`).
// ---------------------------------------------------------------------------
// v2 (#2034/#2076) folds chain identity into the preimage. The collector signs
// **v2 and only v2**.
//
// GENESIS_CUT_PLAN §5 P3: the former v2->v1 compatibility fallback (#638) was
// deleted here, before the cut window. After the fresh-genesis cut every node is
// a post-#2034 build that verifies v2 only, so a v1 fallback is dead code that
// could silently mask a v2 signing regression — the collector would quietly
// downgrade instead of failing loudly. A commit the node rejects must now be a
// hard, visible failure.
const COMMIT_AUTH_DOMAIN_V2 = Buffer.from('wrfcoin_commit_auth_v2', 'utf8');
// Testnet defaults; the node resolves the same identity from WRFCOIN_CHAIN_ID /
// WRFCOIN_NETWORK_ID, so the signed preimage must fold in the SAME values.
const CHAIN_ID = process.env.WRFCOIN_CHAIN_ID && process.env.WRFCOIN_CHAIN_ID.trim() !== ''
    ? process.env.WRFCOIN_CHAIN_ID
    : '777';
const NETWORK_ID = process.env.WRFCOIN_NETWORK_ID && process.env.WRFCOIN_NETWORK_ID.trim() !== ''
    ? process.env.WRFCOIN_NETWORK_ID
    : 'testnet';
const COLLECTOR_SIGNING_KEY_PATH =
    process.env.COLLECTOR_SIGNING_KEY_FILE ||
    path.join(os.homedir(), '.wrfcoin', 'collector-state', 'collector-signing-key.json');

function u32le(n) {
    const b = Buffer.allocUnsafe(4);
    b.writeUInt32LE(n >>> 0, 0);
    return b;
}

function pushChainDomain(chainId, networkId) {
    const chainBuf = Buffer.from(String(chainId), 'utf8');
    const netBuf = Buffer.from(String(networkId), 'utf8');
    return Buffer.concat([u32le(chainBuf.length), chainBuf, u32le(netBuf.length), netBuf]);
}

// v2 only (chain-folded, #2034). There is deliberately no version parameter:
// the collector has exactly one preimage, so there is nothing to downgrade to.
function commitAuthorizationMessageWithDomain(
    chainId,
    networkId,
    stationId,
    commitId,
    contributionType,
) {
    const stationBuf = Buffer.from(String(stationId), 'utf8');
    const commitBuf = Buffer.from(String(commitId), 'utf8');
    const typeBuf = Buffer.from(String(contributionType), 'utf8');
    return Buffer.concat([
        COMMIT_AUTH_DOMAIN_V2,
        pushChainDomain(chainId, networkId),
        u32le(stationBuf.length), stationBuf,
        u32le(commitBuf.length), commitBuf,
        u32le(typeBuf.length), typeBuf,
    ]);
}

function commitAuthorizationMessage(stationId, commitId, contributionType) {
    return commitAuthorizationMessageWithDomain(
        CHAIN_ID,
        NETWORK_ID,
        stationId,
        commitId,
        contributionType,
    );
}

function rawEd25519PublicKeyHex(publicKeyObject) {
    const jwk = publicKeyObject.export({ format: 'jwk' });
    return Buffer.from(jwk.x, 'base64url').toString('hex');
}

function keyPairFromSeed(seedBytes) {
    if (!Buffer.isBuffer(seedBytes) || seedBytes.length !== 32) {
        throw new Error('ed25519 seed must be exactly 32 bytes');
    }
    // PKCS#8 prefix for an Ed25519 private key (RFC 8410); trailing 32 = seed.
    const pkcs8Prefix = Buffer.from('302e020100300506032b657004220420', 'hex');
    const der = Buffer.concat([pkcs8Prefix, seedBytes]);
    const privateKey = crypto.createPrivateKey({ key: der, format: 'der', type: 'pkcs8' });
    const publicKey = crypto.createPublicKey(privateKey);
    return { privateKey, publicKey, pubHex: rawEd25519PublicKeyHex(publicKey) };
}

// Load a stable signing key: COLLECTOR_SIGNING_SEED env → persisted file →
// freshly generated + persisted (best-effort). A non-persisted key still
// authorizes, so failure to persist is non-fatal.
function loadCollectorSigningKey() {
    const seed = process.env.COLLECTOR_SIGNING_SEED;
    if (seed) {
        const seedBytes = /^[0-9a-fA-F]{64}$/.test(seed)
            ? Buffer.from(seed, 'hex')
            : crypto.createHash('sha256').update(String(seed), 'utf8').digest();
        return keyPairFromSeed(seedBytes);
    }
    try {
        if (fs.existsSync(COLLECTOR_SIGNING_KEY_PATH)) {
            const raw = JSON.parse(fs.readFileSync(COLLECTOR_SIGNING_KEY_PATH, 'utf8'));
            if (raw && typeof raw.seed_hex === 'string' && /^[0-9a-fA-F]{64}$/.test(raw.seed_hex)) {
                return keyPairFromSeed(Buffer.from(raw.seed_hex, 'hex'));
            }
        }
    } catch (_) {
        /* fall through to generation */
    }
    const seedBytes = crypto.randomBytes(32);
    const key = keyPairFromSeed(seedBytes);
    try {
        fs.mkdirSync(path.dirname(COLLECTOR_SIGNING_KEY_PATH), { recursive: true });
        fs.writeFileSync(
            COLLECTOR_SIGNING_KEY_PATH,
            JSON.stringify({ seed_hex: seedBytes.toString('hex'), pub_hex: key.pubHex }, null, 2),
            { mode: 0o600 },
        );
    } catch (_) {
        /* persistence best-effort */
    }
    return key;
}

// One stable key for the process lifetime.
const SIGNING_KEY = loadCollectorSigningKey();

function signCommitAuthorization(stationId, commitId, contributionType) {
    const message = commitAuthorizationMessage(stationId, commitId, contributionType);
    const signature = crypto.sign(null, message, SIGNING_KEY.privateKey);
    return {
        auth_pubkey: SIGNING_KEY.pubHex,
        auth_signature: Buffer.from(signature).toString('hex'),
    };
}

// §5 P3: `COLLECTOR_AUTH_VERSION` and `authVersionOrder` were removed with the
// fallback. Nothing else in the repo read that env var, and post-cut it could
// only ever hold 'v2' — a knob that can hold exactly one value is a trap, not a
// control.

// ---------------------------------------------------------------------------
// HTTP helper
// ---------------------------------------------------------------------------
function post(urlPath, body) {
    return new Promise((resolve, reject) => {
        const payload = JSON.stringify(body);
        const req = http.request(
            {
                hostname: HOST,
                port: PORT,
                path: urlPath,
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Content-Length': Buffer.byteLength(payload),
                    ...(TOKEN ? { Authorization: `Bearer ${TOKEN}` } : {}),
                },
            },
            (res) => {
                let raw = '';
                res.on('data', (c) => (raw += c));
                res.on('end', () => {
                    let data = raw;
                    try {
                        data = JSON.parse(raw);
                    } catch (_) {
                        /* leave as string */
                    }
                    resolve({ status: res.statusCode, data });
                });
            },
        );
        req.on('error', reject);
        req.setTimeout(15000, () => req.destroy(new Error('request timeout')));
        req.write(payload);
        req.end();
    });
}

function getJson(urlPath) {
    return new Promise((resolve) => {
        const req = http.get({ hostname: HOST, port: PORT, path: urlPath }, (res) => {
            let raw = '';
            res.on('data', (chunk) => (raw += chunk));
            res.on('end', () => {
                try {
                    resolve({ status: res.statusCode, data: JSON.parse(raw) });
                } catch (_) {
                    resolve({ status: res.statusCode, data: raw });
                }
            });
        });
        req.on('error', (error) => resolve({ status: 0, data: error.message }));
        req.setTimeout(10000, () => {
            req.destroy();
            resolve({ status: 0, data: 'request timeout' });
        });
    });
}

function canonicalRevealIncluded(response, commitHash, stationId) {
    const body = response && (response.data?.data || response.data);
    return Boolean(
        response?.status === 200
        && body
        && String(body.commit_id || '') === String(commitHash)
        && String(body.station_id || '') === String(stationId)
        && (
            (Number.isInteger(body.revealed_at) && body.revealed_at > 0)
            || body.reward_finalized === true
        )
        && typeof body.status === 'string'
        && (body.status.startsWith('revealed_') || body.status === 'reward_finalized')
    );
}

function getHealth() {
    return new Promise((resolve) => {
        const req = http.get(
            { hostname: HOST, port: PORT, path: '/health' },
            (res) => {
                res.resume();
                resolve(res.statusCode);
            },
        );
        req.on('error', () => resolve(0));
        req.setTimeout(10000, () => {
            req.destroy();
            resolve(0);
        });
    });
}

// ---------------------------------------------------------------------------
// Synthetic reading generation. A smooth diurnal-ish curve plus jitter so the
// values look plausible and vary every cycle (each reading is unique, which
// keeps each commit_hash unique).
// ---------------------------------------------------------------------------
function round(value, dp) {
    const f = 10 ** dp;
    return Math.round(value * f) / f;
}

function generateReading(tsSeconds) {
    const hourOfDay = ((tsSeconds % 86400) / 3600); // 0..24
    const diurnal = Math.sin(((hourOfDay - 6) / 24) * 2 * Math.PI); // peak ~midday
    const tempC = round(8 + diurnal * 12 + (Math.random() - 0.5) * 1.5, 1);
    const humidity = round(Math.max(15, Math.min(99, 70 - diurnal * 25 + (Math.random() - 0.5) * 6)), 0);
    // Pressure must be temporally continuous. Independent per-cycle jitter of
    // +/-9 hPa regularly exceeded Core4's 0.05 hPa/s consensus bound at the
    // default one-minute cadence while the collector still called the block a
    // success. A slow six-hour wave stays well inside the protocol bound.
    const pressureWave = Math.sin((tsSeconds / (6 * 3600)) * 2 * Math.PI);
    // MillihPa precision keeps the rounded one-second step far below 0.05
    // hPa/s, including an immediate restart on a rounding boundary.
    const pressure = round(1013 + pressureWave * 4, 3);
    const windMs = round(Math.max(0, 3 + (Math.random() - 0.3) * 6), 1);

    return {
        temperature_c: tempC,
        humidity_pct: humidity,
        pressure_hpa: pressure,
        wind_speed_ms: windMs,
        wind_direction_deg: round(Math.random() * 359, 0),
        wind_gust_ms: round(windMs + Math.random() * 4, 1),
        precipitation_mm: round(Math.random() < 0.2 ? Math.random() * 3 : 0, 1),
        dew_point_c: round(tempC - (100 - humidity) / 5, 1),
        source: 'synthetic_testnet_collector',
        source_id: STATION_ID,
        source_device: 'synthetic-v1',
        location: 'Synthetic Station, Testnet',
        latitude: LAT,
        longitude: LON,
        elevation_m: ELEVATION_M,
        recorded_at: new Date(tsSeconds * 1000).toISOString(),
    };
}

// ---------------------------------------------------------------------------
// One commit -> reveal -> mine cycle.
// ---------------------------------------------------------------------------
async function runCycle() {
    const ts = Math.floor(Date.now() / 1000);
    const reading = generateReading(ts);
    const sorted = sortKeys(reading);
    const nonce = crypto.randomBytes(16).toString('hex');
    const commitHash = computeCommitId(sorted, nonce, STATION_ID, ts, 'contribution');

    // #1848/#2034: sign the canonical commit-authorization message. The node
    // stamps contribution_type="contribution" into the CommitPayload it
    // verifies, so we MUST sign over that exact value. Try the preferred auth
    // version, then fall back to the other so we work against both node builds.
    const auth = signCommitAuthorization(STATION_ID, commitHash, 'contribution');
    const commitRes = await post('/transactions/contribution/commit', {
        contributor: CONTRIBUTOR,
        station_id: STATION_ID,
        commit_hash: commitHash,
        auth_pubkey: auth.auth_pubkey,
        auth_signature: auth.auth_signature,
    });
    // §5 P3: v2 only. A rejection is terminal and loud — there is no downgrade
    // path that could mask a v2 signing regression behind a quiet retry.
    if (!(commitRes.status === 200 || commitRes.status === 201)) {
        console.error(
            `COMMIT FAIL (${commitRes && commitRes.status}) [commit-auth v2, no fallback]: ` +
            `${JSON.stringify(commitRes && commitRes.data).slice(0, 300)}`,
        );
        return false;
    }

    const revealRes = await post('/transactions/contribution/reveal', {
        contributor: CONTRIBUTOR,
        station_id: STATION_ID,
        payload: sorted,
        nonce,
        commit_hash: commitHash,
        timestamp: ts,
    });
    if (revealRes.status !== 200 && revealRes.status !== 201) {
        console.error(
            `REVEAL FAIL (${revealRes.status}): ${JSON.stringify(revealRes.data).slice(0, 300)}`,
        );
        return false;
    }

    const mineRes = await post('/blocks/mine', { miner_address: MINER_ADDRESS });
    if (mineRes.status !== 200 && mineRes.status !== 201) {
        console.error(
            `MINE FAIL (${mineRes.status}): ${JSON.stringify(mineRes.data).slice(0, 300)}`,
        );
        return false;
    }

    const height = mineRes.data && mineRes.data.height;
    const txCount = mineRes.data && mineRes.data.transaction_count;
    const canonical = await getJson(
        `/transactions/commit/${encodeURIComponent(commitHash)}/status`,
    );
    if (!canonicalRevealIncluded(canonical, commitHash, STATION_ID)) {
        const body = canonical && (canonical.data?.data || canonical.data);
        console.error(JSON.stringify({
            metric_type: 'collector_cycle_outcome',
            outcome: 'rejected',
            reason: 'reveal_not_canonically_included',
            commit_hash: commitHash,
            station_id: STATION_ID,
            block_height: height || null,
            canonical_status: body?.status || null,
        }));
        return false;
    }
    console.log(
        `COMMIT+REVEAL INCLUDED: ${reading.temperature_c}C @ ${reading.recorded_at} ` +
            `-> MINED block ${height} (tx_count=${txCount})`,
    );
    return true;
}

async function main() {
    // Fail before the health wait or any contribution/mine request. Falling
    // back to a legacy address turns a missing overlay into a silent chain stall.
    normalizedContributorAddress(MINER_ADDRESS, 'SYNTH_MINER_ADDRESS');
    assertDistinctContributorIdentities();
    if (!TOKEN) {
        console.error('FATAL: WRFCOIN_OPERATOR_TOKEN is not set — cannot submit contributions.');
        process.exit(1);
    }
    console.log(
        `synthetic-collector starting: node=${HOST}:${PORT} station=${STATION_ID} ` +
            `contributor=${CONTRIBUTOR} interval=${INTERVAL_SECONDS}s`,
    );

    // Wait for the node /health to be ready (the node may still be replaying
    // its WAL when this container starts even with depends_on healthy).
    for (let i = 0; i < 60; i++) {
        if ((await getHealth()) === 200) break;
        if (i === 0) console.log('waiting for node /health ...');
        await new Promise((r) => setTimeout(r, 5000));
    }

    if (INTERVAL_SECONDS <= 0) {
        const ok = await runCycle();
        process.exit(ok ? 0 : 1);
    }

    // Continuous loop. Never throw out of the loop — a transient node restart
    // should not kill the collector; restart: unless-stopped handles process
    // death, but we prefer to keep ticking through transient HTTP errors.
    // eslint-disable-next-line no-constant-condition
    while (true) {
        try {
            await runCycle();
        } catch (err) {
            console.error(`cycle error: ${err && err.message ? err.message : err}`);
        }
        await new Promise((r) => setTimeout(r, INTERVAL_SECONDS * 1000));
    }
}

if (require.main === module) {
    main().catch((err) => {
        console.error(`fatal: ${err && err.stack ? err.stack : err}`);
        process.exit(1);
    });
}

module.exports = {
    COMMIT_AUTH_DOMAIN_V2,
    DEFAULT_REAL_CONTRIBUTOR,
    DEFAULT_SYNTH_CONTRIBUTOR,
    assertDistinctContributorIdentities,
    commitAuthorizationMessage,
    commitAuthorizationMessageWithDomain,
    keyPairFromSeed,
    signCommitAuthorization,
    generateReading,
    canonicalRevealIncluded,
};
