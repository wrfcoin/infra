'use strict';

const http = require('node:http');
const fs = require('node:fs');
const { performance } = require('node:perf_hooks');

const HEALTH_FILE = '/tmp/block-heartbeat-health.json';

// Rotation roster: fixed order, mirrors core4 genesis_producer_pins.rs PAYOUT_ADDRESSES
// (verified against origin/main). A host may only ever mine to its OWN pinned address;
// anything else is WrongPayoutAddress and the block is refused by every node.
const ROSTER = ['n5-node-a', 'producer-standby', 'mango-mini'];
const PINNED_ADDRESSES = {
    'n5-node-a': '0x680d51f7543ca70029866956376306d47ce60ed0',
    'producer-standby': '0x39ee2e595a55c71256282fe5c42a398594985b1a',
    'mango-mini': '0xc536d2026661522cb8631b3c723d4af43784a990',
};
const POLL_MS = 5000;
const RETRY_MS = 15000;

function config(env = process.env) {
    const value = env.BLOCK_HEARTBEAT_INTERVAL_SECONDS ?? '77';
    if (!/^\d+$/.test(value) || Number(value) < 30 || Number(value) > 600) {
        throw new Error('invalid interval');
    }
    if ((!/^[1-9][0-9]*$/.test(env.WRFCOIN_CHAIN_ID || '') || env.WRFCOIN_CHAIN_ID === '1') || env.WRFCOIN_NETWORK_ID !== 'testnet') {
        throw new Error('invalid network');
    }
    if (!/^0x[0-9a-fA-F]{40}$/.test(env.WRFCOIN_MINER_ADDRESS || '')
        || !env.WRFCOIN_OPERATOR_TOKEN) throw new Error('invalid authorization');
    const port = Number(env.WRFCOIN_API_PORT || '8556');
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('invalid port');
    const settings = {
        intervalMs: Number(value) * 1000,
        host: env.WRFCOIN_API_HOST || 'wrfcoin-node', port,
        miner: env.WRFCOIN_MINER_ADDRESS, token: env.WRFCOIN_OPERATOR_TOKEN,
    };
    const rotationVars = ['BLOCK_HEARTBEAT_ROTATION', 'BLOCK_HEARTBEAT_SELF',
        'BLOCK_HEARTBEAT_FALLBACK_STEP_SECONDS', 'BLOCK_HEARTBEAT_MAX_SKEW_SECONDS'];
    const requested = rotationVars.some((name) => env[name] !== undefined && env[name] !== '');
    if (!requested) return settings; // legacy mode: byte-for-byte unchanged
    if (env.BLOCK_HEARTBEAT_ROTATION !== ROSTER.join(',')) throw new Error('invalid rotation roster');
    const self = env.BLOCK_HEARTBEAT_SELF;
    if (!ROSTER.includes(self)) throw new Error('invalid rotation self');
    if (env.WRFCOIN_MINER_ADDRESS.toLowerCase() !== PINNED_ADDRESSES[self]) {
        throw new Error('payout address does not match pinned address');
    }
    const step = env.BLOCK_HEARTBEAT_FALLBACK_STEP_SECONDS ?? '60';
    if (!/^\d+$/.test(step) || Number(step) < 1 || Number(step) > 600) throw new Error('invalid fallback step');
    const skew = env.BLOCK_HEARTBEAT_MAX_SKEW_SECONDS ?? '5';
    if (!/^\d+$/.test(skew) || Number(skew) > 60) throw new Error('invalid max skew');
    return {
        ...settings, miner: PINNED_ADDRESSES[self],
        rotation: { roster: ROSTER, self, stepMs: Number(step) * 1000, maxSkewMs: Number(skew) * 1000 },
    };
}

// Pure turn rule. next = tip+1 is owned by roster[next % 3]; the owner mines once the tip is
// `interval` old; others only after interval + rank*step (rank = distance after the owner).
function decide({ tip, tipMs, nowMs, intervalMs, rotation }) {
    if (tipMs - nowMs > rotation.maxSkewMs) return { action: 'clock_skew' };
    const { roster, self, stepMs } = rotation;
    const owner = (tip + 1) % roster.length;
    const rank = (roster.indexOf(self) - owner + roster.length) % roster.length;
    const age = nowMs - tipMs;
    return { action: age >= intervalMs + rank * stepMs ? 'mine' : 'wait', rank };
}

function getJson(settings, path) {
    return new Promise((resolve) => {
        let finished = false;
        const done = (value) => { if (!finished) { finished = true; resolve(value); } };
        const request = http.request({ hostname: settings.host, port: settings.port, path, method: 'GET' },
            (response) => {
                let data = '';
                response.on('data', (chunk) => {
                    data += chunk;
                    if (data.length > 262144) request.destroy(); // /network/upgrade is large; cap, never log
                });
                response.on('error', () => done(null));
                response.on('end', () => {
                    if (response.statusCode !== 200) return done(null);
                    try { done(JSON.parse(data)); } catch { done(null); }
                });
            });
        const timer = setTimeout(() => request.destroy(), 10000);
        request.on('close', () => { clearTimeout(timer); done(null); });
        request.on('error', () => done(null));
        request.end();
    });
}

// GET /network/upgrade -> bare { tip_height }; GET /chain/block/{h} -> envelope { data: { timestamp } }.
async function readTip(settings) {
    const upgrade = await getJson(settings, '/network/upgrade');
    const tip = upgrade && upgrade.tip_height;
    if (!Number.isSafeInteger(tip) || tip < 0) return null;
    const block = await getJson(settings, `/chain/block/${tip}`);
    const tipMs = Date.parse(block && block.data && block.data.timestamp);
    if (!Number.isFinite(tipMs)) return null;
    return { tip, tipMs };
}

function mine(settings) {
    return new Promise((resolve) => {
        const body = JSON.stringify({ miner_address: settings.miner });
        let finished = false;
        const done = (result) => {
            if (!finished) { finished = true; resolve(result); }
        };
        const request = http.request({
            hostname: settings.host, port: settings.port, path: '/blocks/mine', method: 'POST',
            headers: {
                Authorization: `Bearer ${settings.token}`,
                'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body),
            },
        }, (response) => {
            let data = '';
            response.on('data', (chunk) => {
                data += chunk;
                if (data.length > 65536) request.destroy();
            });
            response.on('error', () => done({ status: 'network_error' }));
            response.on('end', () => {
                let height;
                try { height = JSON.parse(data).height; } catch { /* never log response bodies */ }
                done({ status: response.statusCode,
                    ...(Number.isSafeInteger(height) && height >= 0 ? { height } : {}) });
            });
        });
        // Absolute timeout bounds the entire request, including a trickling body.
        const timer = setTimeout(() => request.destroy(), 10000);
        request.on('close', () => clearTimeout(timer));
        request.on('error', () => done({ status: 'network_error' }));
        request.end(body);
    });
}

async function runRotation(settings, dependencies = {}) {
    const sleep = dependencies.sleep || ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
    const wall = dependencies.wallNow || (() => Date.now());
    const read = dependencies.read || (() => readTip(settings));
    const request = dependencies.mine || (() => mine(settings));
    const touch = dependencies.touch || (() => {
        fs.writeFileSync(HEALTH_FILE, JSON.stringify({ at: Date.now(), intervalMs: settings.intervalMs }));
    });
    const record = dependencies.record || ((result) => console.log(JSON.stringify(result)));
    const stopped = dependencies.stopped || (() => false);
    let lastSkew = false;
    while (!stopped()) {
        let pause = POLL_MS;
        let state = null;
        try { state = await read(); } catch { state = null; }
        if (state) {
            const verdict = decide({ ...state, nowMs: wall(), intervalMs: settings.intervalMs,
                rotation: settings.rotation });
            if (verdict.action === 'clock_skew') {
                if (!lastSkew) record({ status: 'clock_skew' });
                lastSkew = true;
            } else {
                lastSkew = false;
                if (typeof touch === 'function') { try { touch(); } catch { /* health is best effort */ } }
                if (verdict.action === 'mine') {
                    let result;
                    try { result = await request(); } catch { result = { status: 'network_error' }; }
                    record({ status: result.status,
                        ...(Number.isSafeInteger(result.height) && result.height >= 0 ? { height: result.height } : {}) });
                    if (result.status !== 201) pause = RETRY_MS;
                }
            }
        }
        if (stopped()) break;
        await sleep(pause);
    }
}

async function run(settings, dependencies = {}) {
    if (settings.rotation) return runRotation(settings, dependencies);
    const now = dependencies.now || (() => performance.now());
    const sleep = dependencies.sleep || ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
    const request = dependencies.mine || (() => mine(settings));
    const record = dependencies.record || ((result) => {
        console.log(JSON.stringify(result));
        if (result.status === 201 && Number.isSafeInteger(result.height)) {
            fs.writeFileSync(HEALTH_FILE, JSON.stringify({ at: Date.now(), intervalMs: settings.intervalMs }));
        }
    });
    const stopped = dependencies.stopped || (() => false);
    const epoch = now();
    let deadline = epoch;
    let failures = 0;
    while (!stopped()) {
        await sleep(Math.max(0, deadline - now()));
        if (stopped()) break;
        let result;
        try { result = await request(); } catch { result = { status: 'network_error' }; }
        // Serialize every call; no credentials, response bodies, or error messages reach logs.
        record({ status: result.status,
            ...(Number.isSafeInteger(result.height) && result.height >= 0 ? { height: result.height } : {}) });
        failures = result.status === 201 ? 0 : Math.min(failures + 1, 10);
        const backoff = failures ? Math.min(600000, settings.intervalMs * 2 ** failures) : 0;
        const earliest = now() + backoff;
        // Retain the original monotonic grid, skipping missed slots without catch-up bursts.
        deadline = epoch + (Math.floor((earliest - epoch) / settings.intervalMs) + 1) * settings.intervalMs;
    }
}

function healthy(now = Date.now(), filename = HEALTH_FILE) {
    try {
        const state = JSON.parse(fs.readFileSync(filename, 'utf8'));
        return Number.isFinite(state.at) && Number.isFinite(state.intervalMs)
            && state.intervalMs >= 30000 && state.intervalMs <= 600000
            && now >= state.at && now - state.at <= 3 * state.intervalMs + 10000;
    } catch { return false; }
}

if (require.main === module) {
    if (process.argv[2] === '--healthcheck') process.exit(healthy() ? 0 : 1);
    let settings;
    try { settings = config(); } catch {
        console.log(JSON.stringify({ status: 'invalid_configuration' }));
        process.exit(1);
    }
    run(settings).catch(() => { console.log(JSON.stringify({ status: 'fatal' })); process.exit(1); });
}

module.exports = { config, mine, run, runRotation, decide, readTip, healthy, ROSTER, PINNED_ADDRESSES };
