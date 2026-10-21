'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { config, mine, run, runRotation, decide, readTip, healthy, PINNED_ADDRESSES } = require('./heartbeat.cjs');
const fixture = { WRFCOIN_CHAIN_ID: '777', WRFCOIN_NETWORK_ID: 'testnet',
    WRFCOIN_MINER_ADDRESS: `0x${'1'.repeat(40)}`, WRFCOIN_OPERATOR_TOKEN: 'test-only' };

test('interval validation and network refusal', () => {
    assert.equal(config(fixture).intervalMs, 77000);
    for (const interval of ['30', '600']) assert.ok(config({ ...fixture, BLOCK_HEARTBEAT_INTERVAL_SECONDS: interval }));
    for (const interval of ['', '29', '601', '77x', '77.5', '-1']) {
        assert.throws(() => config({ ...fixture, BLOCK_HEARTBEAT_INTERVAL_SECONDS: interval }));
    }
    assert.ok(config({ ...fixture, WRFCOIN_CHAIN_ID: '888' }));
    for (const id of ['1', '', '888x', '0', '-888']) {
        assert.throws(() => config({ ...fixture, WRFCOIN_CHAIN_ID: id }));
    }
    assert.throws(() => config({ ...fixture, WRFCOIN_NETWORK_ID: 'mainnet' }));
});

async function simulation(durations, statuses) {
    let clock = 5000;
    let index = 0;
    let active = 0;
    const starts = [];
    const logs = [];
    await run({ intervalMs: 77000 }, {
        now: () => clock,
        sleep: async (ms) => { clock += ms; },
        stopped: () => index === durations.length,
        mine: async () => {
            assert.equal(active++, 0);
            starts.push(clock - 5000);
            clock += durations[index];
            await Promise.resolve();
            active--;
            const status = statuses?.[index] || 201;
            index++;
            return { status, height: 42, token: 'MUST-NOT-LOG' };
        },
        record: (result) => logs.push(result),
    });
    assert.ok(logs.every((result) => Object.keys(result).sort().join() === 'height,status'));
    return starts;
}

test('latency does not accumulate drift', async () => {
    assert.deepEqual(await simulation([4000, 9000, 1000, 500]), [0, 77000, 154000, 231000]);
});
test('overlong calls never overlap or catch up', async () => {
    assert.deepEqual(await simulation([180000, 1000, 1000]), [0, 231000, 308000]);
});
test('503 and network failures back off then return to the original grid', async () => {
    assert.deepEqual(await simulation([1000, 1000, 1000, 1000], [503, 'network_error', 201, 201]),
        [0, 231000, 616000, 693000]);
});
test('HTTP request uses operator auth and miner; response bodies are discarded', async (t) => {
    const server = http.createServer((request, response) => {
        assert.equal(request.url, '/blocks/mine');
        assert.equal(request.headers.authorization, 'Bearer test-only');
        let body = '';
        request.on('data', (data) => { body += data; });
        request.on('end', () => {
            assert.deepEqual(JSON.parse(body), { miner_address: fixture.WRFCOIN_MINER_ADDRESS });
            response.writeHead(201, { 'Content-Type': 'application/json' });
            response.end(JSON.stringify({ height: 123, secret: 'MUST-NOT-LOG' }));
        });
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(() => server.close());
    assert.deepEqual(await mine({ ...config(fixture), host: '127.0.0.1', port: server.address().port }),
        { status: 201, height: 123 });
});
test('healthcheck requires recent successful production and rejects missing/corrupt state', (t) => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'heartbeat-health-'));
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
    const file = path.join(dir, 'health.json');
    assert.equal(healthy(1000, file), false);
    fs.writeFileSync(file, JSON.stringify({ at: 1000, intervalMs: 77000 }));
    assert.equal(healthy(242000, file), true);
    assert.equal(healthy(242001, file), false);
    assert.equal(healthy(999, file), false);
    fs.writeFileSync(file, 'broken');
    assert.equal(healthy(1000, file), false);
});

// ---- Rotation mode (#1327) ----
const rot = (self, extra = {}) => ({ ...fixture, WRFCOIN_MINER_ADDRESS: PINNED_ADDRESSES[self],
    BLOCK_HEARTBEAT_ROTATION: 'n5-node-a,producer-standby,mango-mini', BLOCK_HEARTBEAT_SELF: self, ...extra });

test('legacy mode is unchanged when rotation env is unset', () => {
    assert.deepEqual(config(fixture), { intervalMs: 77000, host: 'wrfcoin-node', port: 8556,
        miner: fixture.WRFCOIN_MINER_ADDRESS, token: 'test-only' });
    assert.equal(config({ ...fixture, BLOCK_HEARTBEAT_ROTATION: '' }).rotation, undefined);
});
test('rotation config pins the payout address and defaults', () => {
    const c = config(rot('producer-standby'));
    assert.equal(c.miner, '0x39ee2e595a55c71256282fe5c42a398594985b1a');
    assert.equal(c.rotation.stepMs, 60000);
    assert.equal(c.rotation.maxSkewMs, 5000);
    assert.ok(config({ ...rot('n5-node-a'), WRFCOIN_MINER_ADDRESS: PINNED_ADDRESSES['n5-node-a'].toUpperCase().replace('0X', '0x') }));
});
test('rotation refuses payout mismatch and bad env', () => {
    assert.throws(() => config({ ...rot('n5-node-a'), WRFCOIN_MINER_ADDRESS: PINNED_ADDRESSES['mango-mini'] }), /pinned/);
    assert.throws(() => config({ ...rot('n5-node-a'), WRFCOIN_MINER_ADDRESS: fixture.WRFCOIN_MINER_ADDRESS }));
    assert.throws(() => config(rot('nobody')));
    assert.throws(() => config({ ...rot('n5-node-a'), BLOCK_HEARTBEAT_ROTATION: 'mango-mini,n5-node-a,producer-standby' }));
    assert.throws(() => config({ ...rot('n5-node-a'), BLOCK_HEARTBEAT_ROTATION: undefined }));
    assert.throws(() => config({ ...fixture, BLOCK_HEARTBEAT_SELF: 'n5-node-a' }));
    for (const bad of ['0', '601', 'x', '1.5']) {
        assert.throws(() => config({ ...rot('n5-node-a'), BLOCK_HEARTBEAT_FALLBACK_STEP_SECONDS: bad }));
    }
    for (const bad of ['61', '-1', 'x']) {
        assert.throws(() => config({ ...rot('n5-node-a'), BLOCK_HEARTBEAT_MAX_SKEW_SECONDS: bad }));
    }
});
const decideFor = (self, tip, ageS, tipMs = 1_000_000) => decide({ tip, tipMs, nowMs: tipMs + ageS * 1000,
    intervalMs: 77000, rotation: config(rot(self)).rotation });
test('turn rule: owner of tip+1 mines at interval; non-owner waits', () => {
    // tip 2 -> next 3 -> roster[0] = n5
    assert.equal(decideFor('n5-node-a', 2, 76).action, 'wait');
    assert.equal(decideFor('n5-node-a', 2, 77).action, 'mine');
    assert.equal(decideFor('producer-standby', 2, 77).action, 'wait');
    assert.equal(decideFor('mango-mini', 2, 77).action, 'wait');
    // tip 3 -> next 4 -> roster[1] = ws
    assert.equal(decideFor('producer-standby', 3, 77).action, 'mine');
    assert.equal(decideFor('n5-node-a', 3, 77).action, 'wait');
    // tip 4 -> next 5 -> roster[2] = mango
    assert.equal(decideFor('mango-mini', 4, 77).action, 'mine');
});
test('fallback ranks: rank 1 at +step, rank 2 at +2*step, never both within one step', () => {
    // next 3 owned by n5; ws rank 1, mango rank 2
    assert.equal(decideFor('producer-standby', 2, 136).action, 'wait');
    assert.equal(decideFor('producer-standby', 2, 137).action, 'mine');
    assert.equal(decideFor('mango-mini', 2, 137).action, 'wait');
    assert.equal(decideFor('mango-mini', 2, 196).action, 'wait');
    assert.equal(decideFor('mango-mini', 2, 197).action, 'mine');
    assert.equal(decideFor('producer-standby', 2, 137).rank, 1);
    assert.equal(decideFor('mango-mini', 2, 137).rank, 2);
    // wrap-around: next 5 owned by mango; n5 rank 1, ws rank 2
    assert.equal(decideFor('n5-node-a', 4, 137).action, 'mine');
    assert.equal(decideFor('producer-standby', 4, 137).action, 'wait');
    assert.equal(decideFor('producer-standby', 4, 197).action, 'mine');
    // For every age, at most one non-owner is eligible within any single step window after the owner
    for (let age = 77; age < 400; age++) {
        const ready = ['n5-node-a', 'producer-standby', 'mango-mini']
            .filter((id) => decideFor(id, 2, age).action === 'mine').length;
        if (age < 137) assert.equal(ready, 1);
        else if (age < 197) assert.equal(ready, 2); // owner (still mining) + rank 1 only
        else assert.equal(ready, 3);
    }
});
test('clock skew: tip timestamp too far in the future refuses to mine', () => {
    assert.equal(decideFor('n5-node-a', 2, -5).action, 'wait');
    assert.equal(decideFor('n5-node-a', 2, -6).action, 'clock_skew');
});

async function rotationRun({ self, tip, ageS, results = [{ status: 201, height: 3 }] }) {
    const logs = []; let mined = 0; let touched = 0; let loops = 0;
    const tipMs = 1_000_000;
    await runRotation(config(rot(self)), {
        wallNow: () => tipMs + ageS * 1000,
        read: async () => ({ tip, tipMs }),
        mine: async () => results[mined++] || { status: 201 },
        touch: () => { touched++; },
        record: (r) => logs.push(r),
        sleep: async () => { loops++; },
        stopped: () => loops >= 2,
    });
    return { logs, mined, touched };
}

test('rotation loop: owner mines and logs only status/height; non-owner does not call mine', async () => {
    const owner = await rotationRun({ self: 'n5-node-a', tip: 2, ageS: 80,
        results: [{ status: 201, height: 3, token: 'MUST-NOT-LOG' }] });
    assert.equal(owner.mined, 2); // two ticks, tip stays stale in this stub
    assert.deepEqual(owner.logs[0], { status: 201, height: 3 });
    assert.ok(owner.logs.every((r) => Object.keys(r).every((k) => ['status', 'height'].includes(k))));
    const waiter = await rotationRun({ self: 'mango-mini', tip: 2, ageS: 80 });
    assert.equal(waiter.mined, 0);
    assert.equal(waiter.logs.length, 0);
    assert.ok(waiter.touched > 0);
});
test('rotation loop: clock skew logs once, never mines, no health touch', async () => {
    const r = await rotationRun({ self: 'n5-node-a', tip: 2, ageS: -30 });
    assert.equal(r.mined, 0);
    assert.deepEqual(r.logs, [{ status: 'clock_skew' }]);
    assert.equal(r.touched, 0);
});
test('rotation reads real API shapes: bare /network/upgrade and enveloped /chain/block', async (t) => {
    const server = http.createServer((request, response) => {
        response.writeHead(200, { 'Content-Type': 'application/json' });
        if (request.url === '/network/upgrade') return response.end(JSON.stringify({ status: 'none', tip_height: 44370 }));
        assert.equal(request.url, '/chain/block/44370');
        assert.equal(request.headers.authorization, undefined);
        response.end(JSON.stringify({ ok: true, data: { height: 44370, timestamp: '2026-10-18T07:05:00+00:00' } }));
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(() => server.close());
    assert.deepEqual(await readTip({ host: '127.0.0.1', port: server.address().port }),
        { tip: 44370, tipMs: Date.parse('2026-10-18T07:05:00Z') });
});
