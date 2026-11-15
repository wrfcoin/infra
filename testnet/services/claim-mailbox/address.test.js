'use strict';

// Node address records through the real HTTP handler, the in-memory store and
// a fake node. Set CLAIM_MAILBOX_TEST_REDIS_URL to a throwaway local Redis to
// also run the store through the real Lua. Every key, address and token below
// is synthetic test data (198.51.99.0/24 stands in for a home address).

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const http = require('node:http');
const { createMemoryAddressStore, createMemoryStore, createRedisAddressStore } = require('./store');
const { createService, loadConfig, registeredServerKey } = require('./server');
const { parseRecord, publicAddress, recordMessage, recordPeerMessage } = require('./address-record');

const READ_TOKEN = 'synthetic-node-address-read-token-0123456789'; // secret-leak-ok: fixed synthetic test bearer
const GENESIS = 'ab'.repeat(32);
const CHAIN = { chainId: '888', networkId: 'testnet', genesisHash: GENESIS };
const PKCS8 = Buffer.from('302e020100300506032b657004220420', 'hex');
const BASE58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

function keyFromSeed(byte) {
  const key = crypto.createPrivateKey({ key: Buffer.concat([PKCS8, Buffer.alloc(32, byte)]), format: 'der', type: 'pkcs8' });
  const spki = crypto.createPublicKey(key).export({ format: 'der', type: 'spki' });
  return { key, pub: spki.subarray(spki.length - 32) };
}

function base58(bytes) {
  let n = BigInt(`0x${bytes.toString('hex')}`);
  let out = '';
  while (n > 0n) { out = BASE58[Number(n % 58n)] + out; n /= 58n; }
  for (const b of bytes) { if (b !== 0) break; out = `1${out}`; }
  return out;
}

function peerIdOf(pub) {
  return base58(Buffer.concat([Buffer.from('002408011220', 'hex'), pub]));
}

// Seeds as in core4 node_address.rs tests: server key [11; 32], peer key [2; 32].
const SERVER = keyFromSeed(11);
const PEER = keyFromSeed(2);
const PEER_ID = peerIdOf(PEER.pub);
const K = SERVER.pub.toString('hex');
const BOND = '01'.repeat(32);

function signed(fields = {}, { server = SERVER, peer = PEER } = {}) {
  const peerId = fields.peer_id || peerIdOf(peer.pub);
  const r = {
    version: 1, chain_id: '888', network_id: 'testnet', genesis_hash: GENESIS, deployment_id: BOND,
    server_key: server.pub.toString('hex'), peer_id: peerId, epoch: '41', height: '27300',
    multiaddrs: [`/ip4/198.51.99.7/tcp/9000/p2p/${peerId}`], signature: '', peer_signature: '', ...fields,
  };
  r.signature = crypto.sign(null, recordMessage(r), server.key).toString('hex');
  r.peer_signature = crypto.sign(null, recordPeerMessage(r), peer.key).toString('hex');
  return r;
}

// A fake node: `/node/bonds/<id>` as core4 answers it (server key as a 32-number array).
function fakeNode(state) {
  const reads = [];
  const readNode = async (route) => {
    reads.push(route);
    if (state.down) throw new Error('down');
    const id = route.replace('/node/bonds/', '');
    const bond = state.bonds[id];
    if (!bond) return { deployment_id: id, status: 'UNKNOWN', epoch: String(state.epoch), height: String(state.height), registration: null };
    return {
      deployment_id: id, status: 'REGISTERED', jailed: !!bond.jailed, epoch: String(state.epoch), height: String(state.height),
      registration: { binding: { server_key: [...Buffer.from(bond.serverKey, 'hex')] } },
    };
  };
  return { readNode, reads };
}

async function withService(overrides, fn, { state, store } = {}) {
  const config = { ...loadConfig({}), addressEnabled: true, ...CHAIN, addressReadToken: READ_TOKEN, ...overrides };
  const nodeState = state || { epoch: 41, height: 27300, bonds: { [BOND]: { serverKey: K } } };
  const node = fakeNode(nodeState);
  const lines = [];
  const service = createService({
    config, store: createMemoryStore(config), addressStore: store || createMemoryAddressStore(config),
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
  const post = (record) => call('POST', '/addresses', { body: record });
  const get = (path, auth = `Bearer ${READ_TOKEN}`) => call('GET', path, { auth });
  try { await fn({ call, post, get, lines, reads: node.reads, state: nodeState }); } finally { await new Promise((resolve) => server.close(resolve)); }
}

test('the preimage and both signatures match core4 byte for byte (frozen vector)', () => {
  assert.equal(PEER_ID, '12D3KooWJWoaqZhDaoEFshF7Rh1bpY9ohihFhzcW6d69Lr2NASuq');
  const r = signed();
  // core4 tools/cli/WrfcoinCLI/src/commands/node_address.rs `address_record_message_layout_is_frozen`.
  assert.equal(r.signature, 'bb8cad257bc2e8ce5f67be29f9757e1c5144e8dabb8080067445a955dfc0f8bc91408e8317a4f9593517702e01a7343fe329b862544e8ee464ae3a389a022a0e');
  assert.equal(r.peer_signature, '5a695757d6c8345da86e9dcb73dfc17905971e9cc23492f6b47aaf669aacee956586427b36697c8536abb555425b1f8a1cceb27de39dd53affb1a9649aa5aa08');
  assert.deepEqual(parseRecord(r, CHAIN), r);
  const m = recordMessage(r);
  assert.equal(m.subarray(0, 30).toString(), 'wrfcoin_node_address_record_v1');
  assert.equal(recordPeerMessage(r).subarray(0, 35).toString(), 'wrfcoin_node_address_record_peer_v1');
});

test('default off: every address route is 404', async () => {
  await withService({ addressEnabled: false }, async ({ post, get, reads }) => {
    assert.equal((await post(signed())).body.error.code, 'ADDRESSES_DISABLED');
    assert.equal((await get('/addresses')).status, 404);
    assert.equal((await get(`/addresses/${K}`)).status, 404);
    assert.equal(reads.length, 0);
  });
});

test('a bonded node publishes; replays and older records never win and cost no node read', async () => {
  await withService({}, async ({ post, get, lines, reads }) => {
    const first = signed();
    const stored = await post(first);
    assert.equal(stored.status, 200, JSON.stringify(stored.body));
    assert.equal(stored.body.data.status, 'STORED');
    assert.deepEqual((await get(`/addresses/${K}`)).body.data, first);
    assert.equal(reads.length, 1);

    // The same bytes again (the node's timer, or anyone replaying it): unchanged, no node read.
    assert.equal((await post(first)).body.data.status, 'UNCHANGED');
    assert.equal(reads.length, 1);

    // A home IP change later in the epoch: newer height wins.
    const moved = signed({ height: '27310', multiaddrs: [`/ip4/198.51.99.9/tcp/9000/p2p/${PEER_ID}`] });
    assert.equal((await post(moved)).body.data.status, 'STORED');
    assert.deepEqual((await get(`/addresses/${K}`)).body.data, moved);

    // Replaying the first record now: refused, nothing changes, no node read.
    const n = reads.length;
    const stale = await post(first);
    assert.equal(stale.status, 409);
    assert.equal(stale.body.error.code, 'STALE_RECORD');
    assert.equal(reads.length, n);
    assert.deepEqual((await get(`/addresses/${K}`)).body.data, moved);

    // Logs: decision, first 8 hex of K, epoch. Never an address.
    assert.ok(lines.length > 0);
    for (const line of lines) {
      assert.match(line, /^\[claim-mailbox\] address decision=[A-Z_]+ key=[0-9a-f]{8} epoch=\d+$/);
      assert.ok(!line.includes('198.51.99'), line);
    }
  });
});

test('only the registered server key of a live bond, for this epoch, is accepted', async () => {
  const other = keyFromSeed(12);
  const state = { epoch: 41, height: 27300, bonds: { [BOND]: { serverKey: K }, ['02'.repeat(32)]: { serverKey: K, jailed: true } } };
  await withService({}, async ({ post, get, reads }) => {
    const code = async (record) => { const r = await post(record); return `${r.status} ${r.body.error && r.body.error.code}`; };
    // Signed by another key than the bond's registered one.
    assert.equal(await code(signed({}, { server: other })), '403 SERVER_KEY_MISMATCH');
    // A bond that does not exist, or is jailed.
    assert.equal(await code(signed({ deployment_id: '03'.repeat(32) })), '403 NOT_BONDED');
    assert.equal(await code(signed({ deployment_id: '02'.repeat(32) })), '403 NOT_BONDED');
    // Old epoch, future epoch, height ahead of the chain.
    assert.equal(await code(signed({ epoch: '40' })), '409 STALE_EPOCH');
    assert.equal(await code(signed({ epoch: '42' })), '409 FUTURE_EPOCH');
    assert.equal(await code(signed({ height: '27311' })), '409 FUTURE_HEIGHT');
    assert.equal((await post(signed({ height: '27310' }))).status, 200);
    // An older record is refused from the store, even with the node down; a new one needs the node: 503.
    state.down = true;
    assert.equal(await code(signed({ height: '27305', multiaddrs: [`/ip4/198.51.99.8/tcp/9000/p2p/${PEER_ID}`] }) ), '409 STALE_RECORD');
    const fresh = keyFromSeed(13);
    state.bonds['04'.repeat(32)] = { serverKey: fresh.pub.toString('hex') };
    assert.equal(await code(signed({ deployment_id: '04'.repeat(32) }, { server: fresh })), '503 NODE_UNAVAILABLE');
    state.down = false;
    assert.ok(reads.length >= 7);
    assert.equal((await get(`/addresses/${other.pub.toString('hex')}`)).status, 404);
  }, { state });
});

test('the chain identity, both signatures and the shape are checked before any node read', async () => {
  await withService({}, async ({ post, call, reads }) => {
    const code = async (record) => { const r = await post(record); return `${r.status} ${r.body.error && r.body.error.code}`; };
    assert.equal(await code(signed({ chain_id: '777' })), '400 WRONG_CHAIN');
    assert.equal(await code(signed({ network_id: 'mainnet' })), '400 WRONG_CHAIN');
    assert.equal(await code(signed({ genesis_hash: 'cd'.repeat(32) })), '400 WRONG_CHAIN');
    const good = signed();
    assert.equal(await code({ ...good, height: '27299' }), '403 BAD_SIGNATURE');
    assert.equal(await code({ ...good, signature: good.peer_signature, peer_signature: good.signature }), '403 BAD_SIGNATURE');
    // A peer id that is not the peer key that signed.
    const otherPeer = keyFromSeed(3);
    const wrongPeer = signed({}, { peer: otherPeer });
    assert.equal(await code({ ...wrongPeer, peer_id: PEER_ID, multiaddrs: good.multiaddrs }), '403 BAD_SIGNATURE');
    for (const addr of ['10.0.0.5', '192.168.0.110', '100.64.1.1', '127.0.0.1', '203.0.113.7']) {
      assert.equal(await code(signed({ multiaddrs: [`/ip4/${addr}/tcp/9000/p2p/${PEER_ID}`] })), '422 ADDRESS_NOT_PUBLIC', addr);
    }
    for (const addr of ['::1', '::ffff:198.51.99.7', 'fd00::1', 'fe80::1', '2002:c633:6307::1', '2001:0:1::1', '2001:db8::1']) {
      assert.equal(await code(signed({ multiaddrs: [`/ip6/${addr}/tcp/9000/p2p/${PEER_ID}`] })), '422 ADDRESS_NOT_PUBLIC', addr);
    }
    const shapes = [
      { ...good, extra: 1 }, (({ peer_signature, ...rest }) => rest)(good), { ...good, version: 2 },
      { ...good, epoch: 41 }, { ...good, epoch: '041' }, { ...good, server_key: K.toUpperCase() },
      { ...good, multiaddrs: [] }, { ...good, multiaddrs: Array(5).fill(good.multiaddrs[0]) },
      { ...good, multiaddrs: [good.multiaddrs[0], good.multiaddrs[0]] },
      { ...good, multiaddrs: [`/dns4/node.example.org/tcp/9000/p2p/${PEER_ID}`] },
      { ...good, multiaddrs: [`/ip4/198.51.99.7/tcp/9000/p2p/${peerIdOf(keyFromSeed(3).pub)}`] },
      { ...good, multiaddrs: [`/ip4/198.51.99.7/tcp/99999/p2p/${PEER_ID}`] },
      [], null,
    ];
    for (const body of shapes) {
      assert.equal((await post(body)).status, 400, JSON.stringify(body).slice(0, 100));
    }
    assert.equal((await call('POST', '/addresses', { raw: '{' })).status, 400);
    const huge = await call('POST', '/addresses', { raw: JSON.stringify({ ...good, pad: 'x'.repeat(5000) }) }).catch(() => ({ status: 413 }));
    assert.equal(huge.status, 413);
    assert.equal(reads.length, 0);
  });
});

test('abuse limits: 6 new records an hour per K, and a bounded node-read budget', async () => {
  const state = { epoch: 41, height: 30000, bonds: { [BOND]: { serverKey: K } } };
  await withService({}, async ({ post }) => {
    for (let i = 0; i < 6; i += 1) {
      assert.equal((await post(signed({ height: String(27300 + i) }))).status, 200);
    }
    const limited = await post(signed({ height: '27400' }));
    assert.equal(limited.status, 429);
    assert.equal(limited.body.error.code, 'RATE_LIMITED');
    // Replays of the stored record still answer (and cost nothing).
    assert.equal((await post(signed({ height: '27305' }))).body.data.status, 'UNCHANGED');
  }, { state });
  const keys = [21, 22, 23].map(keyFromSeed);
  const busy = { epoch: 41, height: 27300, bonds: {} };
  keys.forEach((k, i) => { busy.bonds[String(i + 5).padStart(2, '0').repeat(32)] = { serverKey: k.pub.toString('hex') }; });
  await withService({ nodeReadsPerMinute: 2 }, async ({ post }) => {
    const results = [];
    for (const [i, k] of keys.entries()) {
      results.push((await post(signed({ deployment_id: String(i + 5).padStart(2, '0').repeat(32) }, { server: k }))).status);
    }
    assert.deepEqual(results, [200, 200, 429]);
  }, { state: busy });
});

test('reads need the house consumer bearer; records expire after the TTL', async () => {
  let now = 5_000_000;
  const config = { ...loadConfig({}), addressTtlSeconds: 3600 };
  const store = createMemoryAddressStore(config);
  store.setClock(() => now);
  await withService({ addressTtlSeconds: 3600 }, async ({ post, get }) => {
    await post(signed());
    assert.equal((await get(`/addresses/${K}`, null)).status, 401);
    assert.equal((await get(`/addresses/${K}`, `Bearer ${'x'.repeat(40)}`)).status, 401);
    assert.equal((await get(`/addresses/${K}`, READ_TOKEN)).status, 401);
    assert.equal((await get('/addresses/not-hex')).body.error.code, 'INVALID_ADDRESS_ROUTE');
    const list = await get('/addresses');
    assert.deepEqual(list.body.data.records.map((r) => r.server_key), [K]);
    now += 3599 * 1000;
    assert.equal((await get(`/addresses/${K}`)).status, 200);
    now += 2000;
    assert.equal((await get(`/addresses/${K}`)).body.error.code, 'NO_RECORD');
    assert.deepEqual((await get('/addresses')).body.data.records, []);
  }, { store });
  // No read token configured: reads refused even with a bearer.
  await withService({ addressReadToken: '' }, async ({ get }) => {
    assert.equal((await get('/addresses')).status, 503);
  });
  // Chain identity not configured: publishing refused.
  await withService({ genesisHash: '' }, async ({ post }) => {
    assert.equal((await post(signed())).body.error.code, 'NOT_CONFIGURED');
  });
});

test('config: address defaults and strict numbers', () => {
  const c = loadConfig({});
  assert.equal(c.addressEnabled, false);
  assert.equal(c.addressTtlSeconds, 118272);
  assert.equal(c.addressWritesPerHour, 6);
  assert.equal(c.nodeReadsInFlight, 2);
  assert.equal(c.nodeReadsPerMinute, 60);
  assert.equal(loadConfig({ NODE_ADDRESS_ENABLED: '1' }).addressEnabled, false);
  assert.equal(loadConfig({ WRFCOIN_GENESIS_HASH: `0x${'AB'.repeat(32)}` }).genesisHash, GENESIS);
  assert.equal(loadConfig({ NODE_ADDRESS_TTL_SECONDS: '60' }).addressTtlSeconds, 118272);
  assert.equal(registeredServerKey({ registration: { binding: { server_key: [...SERVER.pub] } } }), K);
  assert.equal(registeredServerKey({ registration: { binding: { server_key: [1, 2] } } }), null);
  assert.equal(publicAddress('ip4', '198.51.99.7'), true);
  assert.equal(publicAddress('ip6', '2a01:4f8::1'), true);
  assert.equal(publicAddress('ip4', '010.0.0.1'), false);
});

test('redis address store: newer wins, replay unchanged, index and expiry through the real Lua', { skip: !process.env.CLAIM_MAILBOX_TEST_REDIS_URL }, async () => {
  const { createClient } = require('redis');
  const client = createClient({ url: process.env.CLAIM_MAILBOX_TEST_REDIS_URL });
  await client.connect();
  const prefix = `claim-mailbox-addr-test-${process.pid}:`;
  try {
    const store = createRedisAddressStore(client, { prefix, addressTtlSeconds: 3600 });
    const a = signed();
    const b = signed({ height: '27310' });
    assert.equal(await store.put(a), 'STORED');
    assert.equal(await store.put(a), 'UNCHANGED');
    assert.equal(await store.put(b), 'STORED');
    assert.equal(await store.put(a), 'STALE_RECORD');
    assert.deepEqual(await store.get(K), b);
    assert.deepEqual((await store.list()).map((r) => r.height), ['27310']);
    const ttl = await client.ttl(`${prefix}addr:${K}`);
    assert.ok(ttl > 3500 && ttl <= 3600, String(ttl));
    assert.equal(await store.hit(K), 1);
    assert.equal(await store.hit(K), 2);
  } finally {
    for (const key of await client.keys(`${prefix}*`)) await client.del(key);
    await client.quit();
  }
});
