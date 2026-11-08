'use strict';

// The CLI and the node are stand-ins: core4 tests the signature and the chain
// rules. Nothing here reads or writes a real key; the key file path is a
// placeholder that the fake CLI only records.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const policy = require('./policy');
const { createFileStore } = require('./store');
const { cliEnv, clientAddress, createService, ipLimitKey, loadConfig } = require('./server');

const T0 = 1_800_000_000;
const KEY_FILE = '/run/secrets/test-only-placeholder.key';

function owner() {
  return `0x${crypto.randomBytes(20).toString('hex')}`;
}

function row(address = owner(), overrides = {}) {
  return {
    station_id: policy.mobileStationId(address, 0),
    owner_address: address,
    owner_pubkey: 'a'.repeat(64),
    owner_signature: 'b'.repeat(128),
    latitude: 37.7,
    longitude: -122.4,
    hardware_model: 'phone-barometer',
    provenance_class: 'real',
    data_quality_tier: 'unverified',
    ...overrides,
  };
}

function fakeNode() {
  const chain = {
    height: 100,
    features: ['station_registrar_key', 'station_registration_nonce'],
    chainId: '888',
    registered: new Set(),
    nonces: new Map(),
    stations: [],
    postStatus: 201,
    postThrows: false,
    posts: [],
    down: false,
  };
  const ok = (data, status = 200) => ({ status, body: { ok: true, data } });
  const node = {
    async get(route) {
      if (chain.down) throw new Error('down');
      if (route === '/network/info') return ok({ chain_id: chain.chainId, network_id: 'testnet', chain_height: chain.height });
      if (route.startsWith('/transactions/oracle/pending')) return ok({ active_features: chain.features });
      const ledger = /^\/transactions\/station\/registrations\/([^/?]+)\/owner-ledger$/.exec(route);
      if (ledger) {
        if (!chain.nonces.has(ledger[1])) return { status: 404, body: null };
        return ok({ owner_ledger: { owner_nonce: chain.nonces.get(ledger[1]) } });
      }
      const one = /^\/transactions\/station\/registrations\/([^/?]+)$/.exec(route);
      if (one) return chain.registered.has(one[1]) ? ok({ station_id: one[1] }) : { status: 404, body: null };
      if (route.startsWith('/transactions/station/registrations?')) {
        return ok({ stations: chain.stations, has_more: false, next_cursor: null });
      }
      return { status: 404, body: null };
    },
    async post(route, body) {
      chain.posts.push({ route, body });
      if (chain.postThrows) throw new Error('reset');
      return { status: chain.postStatus, body: { ok: true, data: { accepted: chain.postStatus === 201 ? 1 : 0 } } };
    },
  };
  return { chain, node };
}

function fakeCli() {
  const calls = [];
  const cli = { calls, refuseCheck: null, failSign: false };
  cli.run = async (args) => {
    calls.push(args);
    const flag = (name) => args[args.indexOf(name) + 1];
    const file = flag('--row-file');
    const r = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (args.includes('--check')) {
      if (cli.refuseCheck) return { ok: false, message: cli.refuseCheck };
      return { ok: true, data: { station_id: r.station_id, owner_proof: 'valid' } };
    }
    if (cli.failSign) return { ok: false, message: 'no' };
    const out = flag('--out');
    fs.writeFileSync(out, JSON.stringify({
      chain_id: '888', network_id: 'testnet',
      transactions: [{ id: `tx-${r.station_id}`, station_id: r.station_id, submitted_at: Number(flag('--submitted-at')) }],
    }));
    return { ok: true, data: { signed: true } };
  };
  return cli;
}

function setup(env = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'registrar-test-'));
  const config = loadConfig({
    STATION_REGISTRAR_ENABLED: 'true',
    WRFCOIN_CHAIN_ID: '888',
    WRFCOIN_NETWORK_ID: 'testnet',
    STATION_REGISTRAR_GENESIS_HASH: 'ab'.repeat(32),
    STATION_REGISTRAR_KEY_FILE: KEY_FILE,
    STATION_REGISTRAR_STATE_FILE: path.join(dir, 'state.json'),
    STATION_REGISTRAR_NODE_TOKEN: 'test-token-not-real',
    STATION_REGISTRAR_IP_SALT: 'test-salt-0123456789',
    STATION_REGISTRAR_TRUSTED_PROXIES: '127.0.0.1',
    STATION_REGISTRAR_STOP_FILE: path.join(dir, 'STOP'),
    ...env,
  });
  const store = createFileStore(config.stateFile, config);
  store.load();
  const { chain, node } = fakeNode();
  const cli = fakeCli();
  const clock = { now: T0 * 1000 };
  const service = createService({ config, store, runCli: cli.run, node, now: () => clock.now });
  return { dir, config, store, chain, cli, clock, service };
}

async function withServer(service, fn) {
  const server = http.createServer((req, res) => service.handle(req, res));
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    return await fn(base);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

async function post(base, body, ip = '203.0.113.7') {
  const res = await fetch(`${base}/station-registrar/requests`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-forwarded-for': ip },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: await res.json(), headers: res.headers };
}

test('off by default, and the stop file pauses it', async () => {
  const off = loadConfig({});
  assert.equal(off.enabled, false);
  assert.equal(off.limits.dailyTotal, 20);
  assert.equal(off.limits.dailyPerIp, 3);
  assert.equal(off.limits.dailyPerCell, 3);
  assert.equal(off.limits.holdSeconds, 86400);
  assert.equal(off.softCeiling, 128);
  // The soft ceiling can never be set above the chain's.
  assert.equal(loadConfig({ STATION_REGISTRAR_SOFT_CEILING: '500' }).softCeiling, 128);
  assert.equal(loadConfig({ STATION_REGISTRAR_HOLD_SECONDS: '60' }).limits.holdSeconds, 86400);

  const s = setup({ STATION_REGISTRAR_ENABLED: 'false' });
  await withServer(s.service, async (base) => {
    const r = await post(base, row());
    assert.equal(r.status, 503);
    assert.equal(r.body.error.code, 'REGISTRAR_STOPPED');
  });
  const t = setup();
  fs.writeFileSync(t.config.stopFile, '');
  await withServer(t.service, async (base) => {
    assert.equal((await post(base, row())).body.error.code, 'REGISTRAR_STOPPED');
  });
  assert.deepEqual(await t.service.tick(), { action: 'idle' });
  assert.equal(t.cli.calls.length, 0);
});

test('not configured is refused', async () => {
  const s = setup({ STATION_REGISTRAR_IP_SALT: 'short' });
  await withServer(s.service, async (base) => {
    assert.equal((await post(base, row())).body.error.code, 'REGISTRAR_UNAVAILABLE');
  });
  const m = setup({ WRFCOIN_NETWORK_ID: 'mainnet' });
  assert.equal(m.service.configured(), false);
});

test('a good request is held 24 h, then signed once and submitted', async () => {
  const s = setup();
  const r1 = row();
  await withServer(s.service, async (base) => {
    const r = await post(base, r1);
    assert.equal(r.status, 202);
    assert.equal(r.body.data.status, 'held');
    assert.equal(r.body.data.releaseAt, new Date((T0 + 86400) * 1000).toISOString());
    const status = await (await fetch(`${base}/station-registrar/requests/${r1.station_id}`)).json();
    assert.equal(status.data.status, 'held');
  });
  // The keyless check never names the key.
  assert.equal(s.cli.calls.length, 1);
  assert.ok(s.cli.calls[0].includes('--check'));
  assert.ok(!s.cli.calls[0].includes('--key-file'));
  assert.deepEqual(s.cli.calls[0].slice(0, 2), ['station', 'registrar-sign']);
  assert.equal(s.cli.calls[0][s.cli.calls[0].indexOf('--expected-nonce') + 1], '0');

  // Still held one second before the hold ends.
  s.clock.now = (T0 + 86399) * 1000;
  assert.deepEqual(await s.service.tick(), { action: 'idle' });
  assert.equal(s.chain.posts.length, 0);

  s.clock.now = (T0 + 86400) * 1000;
  assert.equal((await s.service.tick()).action, 'submitted');
  assert.equal(s.chain.posts.length, 1);
  const sign = s.cli.calls[1];
  assert.equal(sign[sign.indexOf('--key-file') + 1], KEY_FILE);
  assert.equal(sign[sign.indexOf('--submitted-at') + 1], String(T0 + 86400));
  assert.equal(s.chain.posts[0].route, '/transactions/station/registrations');
  assert.deepEqual(Object.keys(s.chain.posts[0].body).sort(), ['chain_id', 'network_id', 'transactions']);

  // The row (with its coordinates) is gone from the state file once submitted,
  // and no address was ever stored.
  const saved = fs.readFileSync(s.config.stateFile, 'utf8');
  assert.equal(fs.statSync(s.config.stateFile).mode & 0o777, 0o600);
  assert.ok(!saved.includes('203.0.113.7'));
  assert.ok(!saved.includes('122.4'));
  assert.ok(!saved.includes(r1.owner_signature));

  // In flight: nothing else moves until it is seen on chain.
  assert.equal((await s.service.tick()).reason, 'in-flight');
  s.chain.registered.add(r1.station_id);
  assert.equal((await s.service.tick()).action, 'confirmed');
  assert.equal(s.store.snapshot()[0].status, 'registered');
});

test('at most one registration per block', async () => {
  const s = setup();
  const rows = [row(), row()];
  await withServer(s.service, async (base) => {
    assert.equal((await post(base, rows[0], '198.51.100.1')).status, 202);
    assert.equal((await post(base, rows[1], '198.51.100.2')).status, 202);
  });
  s.clock.now = (T0 + 90000) * 1000;
  assert.equal((await s.service.tick()).stationId, rows[0].station_id);
  s.chain.registered.add(rows[0].station_id);
  assert.equal((await s.service.tick()).action, 'confirmed');
  // Same block height: wait.
  assert.equal((await s.service.tick()).reason, 'same-block');
  s.chain.height += 1;
  assert.equal((await s.service.tick()).stationId, rows[1].station_id);
  assert.equal(s.chain.posts.length, 2);
});

test('one request per station, ever', async () => {
  const s = setup();
  const r1 = row();
  await withServer(s.service, async (base) => {
    assert.equal((await post(base, r1)).status, 202);
    const again = await post(base, r1, '192.0.2.99');
    assert.equal(again.status, 409);
    assert.equal(again.body.error.code, 'ALREADY_REQUESTED');
  });
});

test('3 a day per address, then 429 with a retry hint', async () => {
  const s = setup();
  await withServer(s.service, async (base) => {
    for (let i = 0; i < 3; i += 1) {
      assert.equal((await post(base, row(owner(), { latitude: 10 + i }), '203.0.113.9')).status, 202);
    }
    const r = await post(base, row(owner(), { latitude: 20 }), '203.0.113.9');
    assert.equal(r.status, 429);
    assert.equal(r.body.error.code, 'DAILY_PER_IP');
    assert.equal(r.headers.get('retry-after'), '86400');
    // An IPv6 home shares one /64.
    for (let i = 0; i < 3; i += 1) {
      assert.equal((await post(base, row(owner(), { latitude: 30 + i }), `2001:db8:1:2::${i + 1}`)).status, 202);
    }
    assert.equal((await post(base, row(owner(), { latitude: 40 }), '2001:db8:1:2:ffff::1')).body.error.code, 'DAILY_PER_IP');
  });
  // A day later the address may ask again.
  s.clock.now = (T0 + 86400) * 1000;
  await withServer(s.service, async (base) => {
    assert.equal((await post(base, row(owner(), { latitude: 50 }), '203.0.113.9')).status, 202);
  });
});

test('3 a day per 0.1 degree cell, 20 a day in total', async () => {
  const s = setup();
  await withServer(s.service, async (base) => {
    for (let i = 0; i < 3; i += 1) assert.equal((await post(base, row(), `198.51.100.${i}`)).status, 202);
    assert.equal((await post(base, row(), '198.51.100.50')).body.error.code, 'DAILY_PER_CELL');
    for (let i = 3; i < 20; i += 1) {
      assert.equal((await post(base, row(owner(), { latitude: i }), `198.51.100.${i}`)).status, 202);
    }
    const r = await post(base, row(owner(), { latitude: 60 }), '198.51.100.99');
    assert.equal(r.status, 429);
    assert.equal(r.body.error.code, 'DAILY_TOTAL');
  });
  assert.equal(s.store.snapshot().length, 20);
});

test('chain refusals are refused up front, and nothing is stored', async () => {
  const s = setup();
  const r1 = row();
  await withServer(s.service, async (base) => {
    s.chain.registered.add(r1.station_id);
    assert.equal((await post(base, r1)).body.error.code, 'STATION_ALREADY_REGISTERED');
    s.chain.registered.clear();
    s.chain.nonces.set(r1.station_id, 1);
    assert.equal((await post(base, r1)).body.error.code, 'STATION_NOT_NEW');
    s.chain.nonces.set(r1.station_id, 0);

    s.chain.features = ['station_registration_nonce'];
    assert.equal((await post(base, r1)).body.error.code, 'REGISTRAR_NOT_ACTIVE');
    s.chain.features = ['station_registrar_key', 'station_coordinates_fixed_point'];
    assert.equal((await post(base, r1)).body.error.code, 'REGISTRAR_FORMAT_UNSUPPORTED');
    s.chain.features = ['station_registrar_key'];
    s.chain.chainId = '777';
    assert.equal((await post(base, r1)).body.error.code, 'REGISTRAR_WRONG_CHAIN');
    s.chain.chainId = '888';
    s.chain.down = true;
    assert.equal((await post(base, r1)).body.error.code, 'REGISTRAR_CHAIN_UNAVAILABLE');
    s.chain.down = false;

    s.cli.refuseCheck = 'owner proof does not verify';
    const bad = await post(base, r1);
    assert.equal(bad.status, 422);
    assert.equal(bad.body.error.message, 'owner proof does not verify');
    s.cli.refuseCheck = null;

    const shape = await post(base, row(owner(), { hardware_model: 'davis-vantage' }));
    assert.equal(shape.status, 422);
    assert.equal((await post(base, row(owner(), { latitude: 37.75 }))).body.error.message, 'coordinates must be on the 0.1 degree grid');
  });
  assert.equal(s.store.snapshot().length, 0);
});

test('the phone ceiling counts active phone stations only', async () => {
  const s = setup();
  const phone = (active = true) => ({ hardware_model: 'phone-barometer', is_active: active });
  s.chain.stations = [
    ...Array.from({ length: 127 }, () => phone()),
    phone(false),
    { hardware_model: 'davis-vantage', is_active: true },
  ];
  await withServer(s.service, async (base) => {
    assert.equal((await post(base, row())).status, 202);
    s.chain.stations.push(phone());
    const r = await post(base, row(owner(), { latitude: 1 }));
    assert.equal(r.status, 409);
    assert.equal(r.body.error.code, 'REGISTRAR_CEILING');
    assert.equal(r.body.error.ceiling, 128);
  });
  // A held request waits while the ceiling is full, and is not signed.
  s.clock.now = (T0 + 90000) * 1000;
  assert.equal((await s.service.tick()).reason, 'ceiling');
  assert.equal(s.chain.posts.length, 0);
});

test('a held request is checked again before signing', async () => {
  const s = setup();
  const r1 = row();
  await withServer(s.service, async (base) => { await post(base, r1); });
  s.chain.registered.add(r1.station_id); // registered another way during the hold
  s.clock.now = (T0 + 90000) * 1000;
  assert.equal((await s.service.tick()).action, 'refused');
  assert.equal(s.cli.calls.filter((c) => c.includes('--key-file')).length, 0);
  assert.equal(s.store.snapshot()[0].row, undefined);
});

test('stopping during the hold means nothing is signed', async () => {
  const s = setup();
  await withServer(s.service, async (base) => { await post(base, row()); });
  fs.writeFileSync(s.config.stopFile, '');
  s.clock.now = (T0 + 90000) * 1000;
  assert.deepEqual(await s.service.tick(), { action: 'idle' });
  fs.rmSync(s.config.stopFile);
  assert.equal((await s.service.tick()).action, 'submitted');
});

test('a possibly admitted submission pauses releases and is never resent', async () => {
  const s = setup();
  await withServer(s.service, async (base) => {
    await post(base, row(), '198.51.100.1');
    await post(base, row(owner(), { latitude: 1 }), '198.51.100.2');
  });
  s.clock.now = (T0 + 90000) * 1000;
  s.chain.postThrows = true;
  assert.equal((await s.service.tick()).action, 'review');
  s.chain.postThrows = false;
  s.chain.height += 10;
  assert.equal((await s.service.tick()).reason, 'review');
  assert.equal(s.chain.posts.length, 1);
});

test('a submission not seen on chain goes to review, not back in the queue', async () => {
  const s = setup();
  await withServer(s.service, async (base) => { await post(base, row()); });
  s.clock.now = (T0 + 90000) * 1000;
  assert.equal((await s.service.tick()).action, 'submitted');
  s.chain.height += 6;
  assert.equal((await s.service.tick()).action, 'review');
  assert.equal(s.store.snapshot()[0].code, 'NOT_SEEN_ON_CHAIN');
  s.chain.height += 1;
  assert.deepEqual(await s.service.tick(), { action: 'idle' });
  assert.equal(s.chain.posts.length, 1);
});

test('a node refusal or a signer failure is recorded', async () => {
  const s = setup();
  await withServer(s.service, async (base) => { await post(base, row()); });
  s.clock.now = (T0 + 90000) * 1000;
  s.chain.postStatus = 422;
  assert.equal((await s.service.tick()).action, 'refused');
  assert.equal(s.store.snapshot()[0].code, 'NODE_REFUSED');

  const t = setup();
  await withServer(t.service, async (base) => { await post(base, row()); });
  t.clock.now = (T0 + 90000) * 1000;
  t.cli.failSign = true;
  assert.equal((await t.service.tick()).action, 'review');
  assert.equal(t.chain.posts.length, 0);
});

test('state survives a restart', async () => {
  const s = setup();
  const r1 = row();
  await withServer(s.service, async (base) => { await post(base, r1); });
  const again = createFileStore(s.config.stateFile, s.config);
  again.load();
  assert.equal(again.snapshot()[0].stationId, r1.station_id);
  assert.equal(again.snapshot()[0].status, 'held');
  fs.writeFileSync(s.config.stateFile, '{"version":2}');
  assert.throws(() => createFileStore(s.config.stateFile, s.config).load(), /refusing to start/);
});

test('the client address comes from the edge only when the edge is trusted', () => {
  const req = (remoteAddress, xff) => ({ socket: { remoteAddress }, headers: xff ? { 'x-forwarded-for': xff } : {} });
  assert.equal(clientAddress(req('198.51.100.4', '203.0.113.1'), ['127.0.0.1']), '198.51.100.4');
  assert.equal(clientAddress(req('::ffff:127.0.0.1', '203.0.113.1'), ['127.0.0.1']), '203.0.113.1');
  assert.equal(clientAddress(req('127.0.0.1', '203.0.113.1, 10.0.0.1'), ['127.0.0.1']), null);
  assert.equal(clientAddress(req('127.0.0.1', 'garbage'), ['127.0.0.1']), null);
  assert.equal(clientAddress(req('127.0.0.1'), ['127.0.0.1']), null);
  assert.equal(ipLimitKey('2001:db8::1'), '2001:0db8:0000:0000::/64');
  assert.equal(ipLimitKey('203.0.113.1'), '203.0.113.1');
});

test('the CLI child gets PATH and HOME only', () => {
  assert.deepEqual(cliEnv({ PATH: '/bin', HOME: '/h', STATION_REGISTRAR_NODE_TOKEN: 'x', STATION_REGISTRAR_IP_SALT: 'y' }),
    { PATH: '/bin', HOME: '/h' });
});
