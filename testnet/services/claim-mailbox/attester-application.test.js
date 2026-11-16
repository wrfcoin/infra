'use strict';

// Attester applications through the real HTTP handler, the in-memory store and a
// fake node. Set CLAIM_MAILBOX_TEST_REDIS_URL to a throwaway local Redis to also run
// the store through the real Lua. Every key and token below is synthetic test data.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const http = require('node:http');
const { createMemoryApplicationStore, createMemoryStore, createRedisApplicationStore } = require('./store');
const { createService, loadConfig } = require('./server');
const { applicationMessage, applicationOracleMessage, parseApplication } = require('./attester-application');

const OWNER_TOKEN = 'synthetic-attester-owner-read-token-0123456789'; // secret-leak-ok: fixed synthetic test bearer
const GENESIS = 'ab'.repeat(32);
const CHAIN = { chainId: '888', networkId: 'testnet', genesisHash: GENESIS };
const PKCS8 = Buffer.from('302e020100300506032b657004220420', 'hex');

function keyFromSeed(byte) {
  const key = crypto.createPrivateKey({ key: Buffer.concat([PKCS8, Buffer.alloc(32, byte)]), format: 'der', type: 'pkcs8' });
  const spki = crypto.createPublicKey(key).export({ format: 'der', type: 'spki' });
  return { key, pub: spki.subarray(spki.length - 32) };
}

// Seeds for the frozen vector: server key K = [11; 32] (as in the address-record vector), oracle key = [7; 32].
const SERVER = keyFromSeed(11);
const ORACLE = keyFromSeed(7);
const K = SERVER.pub.toString('hex');
const ORACLE_PUB = ORACLE.pub.toString('hex');
const BOND = '01'.repeat(32);
const SEATED = ['bc'.repeat(32), 'de'.repeat(32), 'ef'.repeat(32)];

function signed(fields = {}, { server = SERVER, oracle = ORACLE } = {}) {
  const r = {
    version: 1, kind: 'apply', chain_id: '888', network_id: 'testnet', genesis_hash: GENESIS, bond_id: BOND,
    server_key: server.pub.toString('hex'), oracle_pubkey: oracle.pub.toString('hex'), epoch: '55', height: '28100',
    settings_version: '1', client_version: '0.9.0-preview9', signature: '', oracle_signature: '', ...fields,
  };
  r.signature = crypto.sign(null, applicationMessage(r), server.key).toString('hex');
  r.oracle_signature = crypto.sign(null, applicationOracleMessage(r), oracle.key).toString('hex');
  return r;
}

function fakeNode(state) {
  const reads = [];
  const readNode = async (route) => {
    if (state.down) throw new Error('down');
    if (route.startsWith('/node/bonds?')) {
      return {
        epoch: String(state.epoch), next_after: null,
        bonds: Object.entries(state.bonds).map(([id, b]) => ({
          deployment_id: id, status: 'REGISTERED', jailed: !!b.jailed, last_change_epoch: '1', update_pending: false,
          exit_effective_height: b.exitAt != null ? String(b.exitAt) : null,
        })),
      };
    }
    reads.push(route);
    if (route === '/transactions/oracle/config') return { oracle_set: [...state.seated].sort(), oracle_quorum: 2 };
    const id = route.replace('/node/bonds/', '');
    const bond = state.bonds[id];
    if (!bond) return { deployment_id: id, status: 'UNKNOWN', epoch: String(state.epoch), height: String(state.height), registration: null };
    return {
      deployment_id: id, status: 'REGISTERED', jailed: !!bond.jailed, epoch: String(state.epoch), height: String(state.height),
      registration: { binding: { server_key: [...Buffer.from(bond.serverKey, 'hex')], effective_epoch: 1 }, exit_effective_height: null },
    };
  };
  return { readNode, reads };
}

async function withService(overrides, fn, { state, store } = {}) {
  const config = { ...loadConfig({}), attesterEnabled: true, ...CHAIN, attesterOwnerToken: OWNER_TOKEN, ...overrides };
  const nodeState = state || { epoch: 55, height: 28100, seated: [...SEATED], bonds: { [BOND]: { serverKey: K } } };
  const node = fakeNode(nodeState);
  const lines = [];
  const service = createService({
    config, store: createMemoryStore(config), applicationStore: store || createMemoryApplicationStore(config),
    readNode: node.readNode, log: (l) => lines.push(l),
  });
  const server = http.createServer((req, res) => { service.handle(req, res); });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const call = async (method, path, { body, auth, raw } = {}) => {
    const headers = {};
    if (auth) headers.authorization = auth;
    if (body !== undefined || raw !== undefined) headers['content-type'] = 'application/json';
    const r = await fetch(base + path, { method, headers, body: raw !== undefined ? raw : body === undefined ? undefined : JSON.stringify(body) });
    return { status: r.status, body: await r.json() };
  };
  const post = (record) => call('POST', '/attester-applications', { body: record });
  const get = (path, auth = `Bearer ${OWNER_TOKEN}`) => call('GET', path, { auth });
  const anon = (path) => call('GET', path);
  try { await fn({ call, post, get, anon, lines, reads: node.reads, state: nodeState }); } finally { await new Promise((resolve) => server.close(resolve)); }
}

test('the signing preimage and both signatures are frozen (vector for the core4 CLI)', () => {
  assert.equal(K, '66be7e332c7a453332bd9d0a7f7db055f5c5ef1a06ada66d98b39fb6810c473a');
  assert.equal(ORACLE_PUB, 'ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c');
  const r = signed();
  const m = applicationMessage(r);
  assert.equal(m.length, 368);
  assert.equal(m.toString('hex'),
    '777266636f696e5f61747465737465725f6170706c69636174696f6e5f7631' // "wrfcoin_attester_application_v1"
    + '05000000' + '6170706c79' // str("apply")
    + '03000000' + '383838' // str("888")
    + '07000000' + '746573746e6574' // str("testnet")
    + '40000000' + Buffer.from(GENESIS).toString('hex') // str(genesis_hash)
    + '40000000' + Buffer.from(BOND).toString('hex') // str(bond_id)
    + '40000000' + Buffer.from(K).toString('hex') // str(server_key)
    + '40000000' + Buffer.from(ORACLE_PUB).toString('hex') // str(oracle_pubkey)
    + '3700000000000000' // u64LE(55)
    + 'c46d000000000000' // u64LE(28100)
    + '01000000' // u32LE(1)
    + '0e000000' + Buffer.from('0.9.0-preview9').toString('hex')); // str(client_version)
  assert.equal(crypto.createHash('sha256').update(m).digest('hex'), 'daad9c1093ed7de1b819c4badb3d54ed8bc50c6d4d750f4a45990976b4f76d6e');
  assert.equal(r.signature, '8bbbf8a9436afb51dfd2fd1a8270a531866dd53bd2bfa7d395f6aa8bf4c7e105ad9fab30ee98fc6a19ceec340292a5aebbdd7985af52543b6418b08da4c22900');
  assert.equal(r.oracle_signature, 'f6e28039f00c61485ac398eb91a294977bb977005cdbcfaf08d8e7f4dd65b25156637faa7b1a8a493db0a941c4296fbbddb1547acd93f72b80d95e36a828930c');
  assert.deepEqual(applicationOracleMessage(r), Buffer.concat([Buffer.from('wrfcoin_attester_application_oracle_v1'), m]));
  const s = signed({ kind: 'step_down' });
  assert.equal(crypto.createHash('sha256').update(applicationMessage(s)).digest('hex'), 'fd0ab3306948aa491192143857759f97b139cfc8b7c13ed9d183099db82af192');
  assert.equal(s.signature, '2ce98586689359a54c977576f62cefa16a994485c82c7c5efb57d07d0bea665951939ede38f7c43da56c1ce8ea0f0e23667fb72837cd4b12ccc6187e6c79fb08');
  assert.equal(s.oracle_signature, 'a6ac52e6856c76d812d28385f0d533d46dc5daeb32af31b27e87f2c5015a44681aa542da9283e2ede337bea318561ae92f952c55b53b27c14f8f2908abe65d01');
  // The two signatures are domain-separated: neither verifies under the other key's message.
  assert.equal(crypto.verify(null, applicationOracleMessage(r), crypto.createPublicKey(SERVER.key), Buffer.from(r.signature, 'hex')), false);
  assert.equal(crypto.verify(null, m, crypto.createPublicKey(ORACLE.key), Buffer.from(r.oracle_signature, 'hex')), false);
});

test('default off: every attester route is 404, other routes unaffected', async () => {
  await withService({ attesterEnabled: false }, async ({ post, get, call }) => {
    assert.equal((await post(signed())).body.error.code, 'APPLICATIONS_DISABLED');
    assert.equal((await get('/attester-applications')).status, 404);
    assert.equal((await get('/attester-applications/counts')).status, 404);
    const health = await call('GET', '/health');
    assert.deepEqual(health.body.attesters, { enabled: false, configured: true, readable: true });
  });
  assert.equal(loadConfig({}).attesterEnabled, false);
});

test('a bonded node applies; replays and older records never win and cost no node read', async () => {
  await withService({}, async ({ post, get, lines, reads }) => {
    const r = signed();
    const first = await post(r);
    assert.equal(first.status, 200, JSON.stringify(first.body));
    assert.deepEqual(first.body.data, { status: 'STORED', bond_id: BOND, kind: 'apply', epoch: '55', height: '28100' });
    const before = reads.length;
    assert.equal((await post(r)).body.data.status, 'UNCHANGED');
    assert.equal((await post(signed({ height: '28090' }))).body.error.code, 'STALE_RECORD');
    assert.equal(reads.length, before, 'replays cost no node read');
    // Newest record wins (same bond).
    assert.equal((await post(signed({ height: '28101' }))).body.data.status, 'STORED');
    const one = await get(`/attester-applications/${BOND}`);
    assert.equal(one.status, 200);
    assert.equal(one.body.data.height, '28101');
    const all = await get('/attester-applications');
    assert.equal(all.body.data.applications.length, 1);
    // Logs: kind, 8-hex prefixes and the epoch only.
    assert.ok(lines.some((l) => l === `[claim-mailbox] attester decision=STORED kind=apply bond=${BOND.slice(0, 8)} oracle=${ORACLE_PUB.slice(0, 8)} epoch=55`));
    assert.ok(lines.every((l) => !l.includes(K) && !l.includes(ORACLE_PUB) && !/127\.0\.0\.1|::1/.test(l)));
  });
});

test('reads need the owner bearer; the public sees only counts', async () => {
  await withService({}, async ({ post, get, anon }) => {
    await post(signed());
    assert.equal((await anon('/attester-applications')).status, 401);
    assert.equal((await get('/attester-applications', 'Bearer wrong-token-wrong-token-wrong-token-0')).status, 401);
    assert.equal((await anon(`/attester-applications/${BOND}`)).status, 401);
    assert.equal((await get('/attester-applications/not-hex')).body.error.code, 'INVALID_APPLICATION_ROUTE');
    assert.equal((await get(`/attester-applications/${'02'.repeat(32)}`)).status, 404);
    const counts = await anon('/attester-applications/counts');
    assert.equal(counts.status, 200);
    assert.deepEqual(counts.body.data, { apply: 1, step_down: 0 });
  });
  await withService({ attesterOwnerToken: 'short' }, async ({ get }) => {
    assert.equal((await get('/attester-applications', 'Bearer short')).body.error.code, 'APPLICATIONS_NOT_READABLE');
  });
});

test('chain identity, shape and both strict signatures are checked before any node read', async () => {
  await withService({}, async ({ post, call, reads }) => {
    const cases = [
      [signed({ chain_id: '777' }), 400, 'WRONG_CHAIN'],
      [signed({ network_id: 'mainnet' }), 400, 'WRONG_CHAIN'],
      [signed({ genesis_hash: 'cd'.repeat(32) }), 400, 'WRONG_CHAIN'],
      [{ ...signed(), signature: signed({ height: '1' }).signature }, 403, 'BAD_SIGNATURE'],
      [{ ...signed(), oracle_signature: signed({ height: '1' }).oracle_signature }, 403, 'BAD_SIGNATURE'],
      // The oracle key signs without its domain prefix: refused.
      [{ ...signed(), oracle_signature: crypto.sign(null, applicationMessage(signed()), ORACLE.key).toString('hex') }, 403, 'BAD_SIGNATURE'],
      // Oracle key swapped for one the applicant does not hold.
      [{ ...signed(), oracle_pubkey: 'ef'.repeat(32) }, 403, 'BAD_SIGNATURE'],
      [signed({}, { oracle: SERVER }), 403, 'KEY_REUSE'],
      [signed({ kind: 'seat_me' }), 400, 'INVALID_RECORD'],
      [signed({ version: 2 }), 400, 'INVALID_RECORD'],
      [signed({ epoch: 55 }), 400, 'INVALID_RECORD'],
      [signed({ settings_version: '0' }), 400, 'INVALID_RECORD'],
      [signed({ client_version: 'x y' }), 400, 'INVALID_RECORD'],
      [{ ...signed(), extra: 1 }, 400, 'INVALID_RECORD'],
      [signed({ bond_id: 'AB'.repeat(32) }), 400, 'INVALID_RECORD'],
    ];
    for (const [body, status, code] of cases) {
      const r = await post(body);
      assert.equal(r.status, status, `${code}: ${JSON.stringify(r.body)}`);
      assert.equal(r.body.error.code, code);
    }
    // Over 4 KiB: refused (413 RECORD_TOO_LARGE, or the socket is cut mid-upload).
    const big = await call('POST', '/attester-applications', { raw: JSON.stringify({ pad: 'x'.repeat(5000) }) }).catch(() => null);
    if (big) assert.equal(big.body.error.code, 'RECORD_TOO_LARGE');
    assert.equal(reads.length, 0, 'nothing above reached the node');
  });
  await withService({ genesisHash: '' }, async ({ post }) => {
    assert.equal((await post(signed())).body.error.code, 'NOT_CONFIGURED');
  });
});

test('small-order oracle keys and the universal signature are refused (strict Ed25519)', async () => {
  await withService({}, async ({ post, reads }) => {
    const r = signed();
    const weak = { ...r, oracle_pubkey: '01' + '00'.repeat(31), oracle_signature: '01' + '00'.repeat(63) };
    assert.equal((await post(weak)).body.error.code, 'BAD_SIGNATURE');
    // S + L (malleated) on K's signature.
    const L = (1n << 252n) + 27742317777372353535851937790883648493n;
    const sig = Buffer.from(r.signature, 'hex');
    let s = 0n;
    for (let i = 63; i >= 32; i -= 1) s = (s << 8n) | BigInt(sig[i]);
    s += L;
    for (let i = 32; i < 64; i += 1) { sig[i] = Number(s & 0xffn); s >>= 8n; }
    assert.equal((await post({ ...r, signature: sig.toString('hex') })).body.error.code, 'BAD_SIGNATURE');
    assert.equal(reads.length, 0);
  });
});

test('only a live bond with K, at the current epoch; unbonded fresh keys cost no node read', async () => {
  const stranger = keyFromSeed(31);
  await withService({}, async ({ post, reads }) => {
    for (let i = 0; i < 10; i += 1) {
      const r = await post(signed({ bond_id: (i + 16).toString(16).repeat(64).slice(0, 64), height: String(28100 + i) }, { server: stranger }));
      assert.equal(r.body.error.code, 'NOT_BONDED');
    }
    assert.equal((await post(signed({}, { server: stranger }))).body.error.code, 'SERVER_KEY_MISMATCH');
    assert.deepEqual(reads, [`/node/bonds/${BOND}`], 'only the roster refresh read the one bonded bond');
    assert.equal((await post(signed({ epoch: '54' }))).body.error.code, 'STALE_EPOCH');
    assert.equal((await post(signed({ epoch: '56' }))).body.error.code, 'FUTURE_EPOCH');
    assert.equal((await post(signed({ height: '28200' }))).body.error.code, 'FUTURE_HEIGHT');
  });
  await withService({}, async ({ post }) => {
    assert.equal((await post(signed())).status, 503);
  }, { state: { down: true, epoch: 55, height: 28100, seated: SEATED, bonds: {} } });
});

test('seated keys: apply refuses a seated oracle key, step_down needs one; forbidden role keys refused', async () => {
  await withService({}, async ({ post, state }) => {
    state.seated.push(ORACLE_PUB);
    assert.equal((await post(signed())).body.error.code, 'ALREADY_SEATED');
    const down = await post(signed({ kind: 'step_down', height: '28099' }));
    assert.equal(down.status, 200, JSON.stringify(down.body));
    assert.equal(down.body.data.kind, 'step_down');
  });
  await withService({}, async ({ post }) => {
    assert.equal((await post(signed({ kind: 'step_down' }))).body.error.code, 'NOT_SEATED');
  });
  await withService({ attesterForbiddenKeys: [ORACLE_PUB] }, async ({ post, reads }) => {
    assert.equal((await post(signed())).body.error.code, 'FORBIDDEN_KEY');
    assert.equal(reads.length, 0);
  });
  await withService({}, async ({ post }) => {
    assert.equal((await post(signed())).body.error.code, 'FORBIDDEN_KEY');
  }, { state: { epoch: 55, height: 28100, seated: [...SEATED, K], bonds: { [BOND]: { serverKey: K } } } });
  const env = loadConfig({ ATTESTER_APPLICATION_FORBIDDEN_KEYS: ` ${'AA'.repeat(32)}, nothex ,${'bb'.repeat(32)}` });
  assert.deepEqual(env.attesterForbiddenKeys, ['aa'.repeat(32), 'bb'.repeat(32)]);
});

test('one live application per oracle key across bonds; a newer record releases the old key', async () => {
  const otherServer = keyFromSeed(41);
  const otherBond = '02'.repeat(32);
  const otherOracle = keyFromSeed(42);
  const state = { epoch: 55, height: 28100, seated: [...SEATED], bonds: { [BOND]: { serverKey: K }, [otherBond]: { serverKey: otherServer.pub.toString('hex') } } };
  await withService({}, async ({ post }) => {
    assert.equal((await post(signed())).body.data.status, 'STORED');
    // Another bond names the same oracle key: refused.
    const clash = await post(signed({ bond_id: otherBond }, { server: otherServer }));
    assert.equal(clash.body.error.code, 'ORACLE_KEY_IN_USE');
    // The first bond moves to a different oracle key; the old key is then free.
    assert.equal((await post(signed({ height: '28101' }, { oracle: otherOracle }))).body.data.status, 'STORED');
    assert.equal((await post(signed({ bond_id: otherBond, height: '28102' }, { server: otherServer }))).body.data.status, 'STORED');
  }, { state });
});

test('rate limit: 6 accepted writes an hour per K; expiry after the TTL', async () => {
  await withService({}, async ({ post }) => {
    for (let i = 0; i < 6; i += 1) assert.equal((await post(signed({ height: String(28090 + i) }))).status, 200);
    assert.equal((await post(signed({ height: '28100' }))).body.error.code, 'RATE_LIMITED');
  });
  const config = { ...loadConfig({}), attesterTtlSeconds: 3600 };
  const store = createMemoryApplicationStore(config);
  let t = 1_000_000;
  store.setClock(() => t);
  await withService({ attesterTtlSeconds: 3600 }, async ({ post, get }) => {
    assert.equal((await post(signed())).status, 200);
    t += 3599 * 1000;
    assert.equal((await get(`/attester-applications/${BOND}`)).status, 200);
    t += 2000;
    assert.equal((await get(`/attester-applications/${BOND}`)).status, 404);
    assert.deepEqual((await get('/attester-applications/counts')).body.data, { apply: 0, step_down: 0 });
  }, { store });
});

test('config: attester defaults and strict numbers', () => {
  const c = loadConfig({});
  assert.equal(c.attesterTtlSeconds, 236544); // 6 epochs x 512 blocks x 77 s
  assert.equal(c.attesterWritesPerHour, 6);
  assert.equal(c.attesterOwnerToken, '');
  assert.equal(loadConfig({ ATTESTER_APPLICATION_TTL_SECONDS: '10' }).attesterTtlSeconds, 236544);
  assert.equal(loadConfig({ ATTESTER_APPLICATIONS_ENABLED: 'yes' }).attesterEnabled, false);
  assert.equal(loadConfig({ ATTESTER_APPLICATIONS_ENABLED: 'true' }).attesterEnabled, true);
  assert.throws(() => parseApplication(null, CHAIN), /JSON object/);
});

test('redis application store: newer wins, replay unchanged, oracle-key lock, index and expiry through the real Lua', { skip: !process.env.CLAIM_MAILBOX_TEST_REDIS_URL }, async () => {
  const { createClient } = require('redis');
  const client = createClient({ url: process.env.CLAIM_MAILBOX_TEST_REDIS_URL });
  await client.connect();
  const prefix = `claim-mailbox-test-${process.pid}-${Date.now()}:`;
  try {
    const store = createRedisApplicationStore(client, { prefix, attesterTtlSeconds: 60 });
    const r = signed();
    assert.equal(await store.put(r), 'STORED');
    assert.equal(await store.put(r), 'UNCHANGED');
    assert.equal(await store.put(signed({ height: '28000' })), 'STALE_RECORD');
    assert.deepEqual(await store.get(BOND), r);
    const otherServer = keyFromSeed(41);
    const otherBond = '02'.repeat(32);
    assert.equal(await store.put(signed({ bond_id: otherBond }, { server: otherServer })), 'ORACLE_KEY_IN_USE');
    assert.equal(await store.put(signed({ height: '28101' }, { oracle: keyFromSeed(42) })), 'STORED');
    assert.equal(await client.exists(`${prefix}attapp-oracle:${ORACLE_PUB}`), 0, 'old oracle key released');
    assert.equal(await store.put(signed({ bond_id: otherBond }, { server: otherServer })), 'STORED');
    assert.equal((await store.list()).length, 2);
    assert.deepEqual(await store.counts(), { apply: 2, step_down: 0 });
    assert.ok(await client.ttl(`${prefix}attapp:${BOND}`) <= 60);
    assert.ok(await client.ttl(`${prefix}attapp-oracle:${ORACLE_PUB.replace(/./g, (c) => c)}`) <= 60);
    // An expired index entry drops out of the list.
    assert.deepEqual((await store.list(Date.now() + 61_000)).length, 0);
    assert.equal(await store.hit(K), 1);
    assert.equal(await store.hit(K), 2);
  } finally {
    const keys = await client.keys(`${prefix}*`);
    if (keys.length) await client.del(keys);
    await client.quit();
  }
});
