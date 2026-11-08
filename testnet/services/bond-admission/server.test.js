'use strict';

// Bond admission service through its real HTTP handler. The core4 CLI and the
// network node are stand-ins: the CLI's packet rules are tested in core4
// (node_bond_admit.rs); here the CLI answer is whatever each scenario needs.
// Redis is the in-memory store; set BOND_ADMISSION_TEST_REDIS_URL to a
// throwaway local Redis to run the store scenarios through the real Lua.
// Every key and seed below is synthetic public test data.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const { admissionPeerMessage, verifyAdmissionPeerSignature } = require('./peer');
const { createMemoryStore, createRedisStore } = require('./store');
const { createService, loadConfig, parseCliOutput, cliEnv, parseRequest } = require('./server');

const PKCS8 = Buffer.from('302e020100300506032b657004220420', 'hex');
const PEER_PREFIX = Buffer.from('002408011220', 'hex');
const BASE58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
const GENESIS = 'ab'.repeat(32);

function seedKey(n) {
  return crypto.createPrivateKey({ key: Buffer.concat([PKCS8, Buffer.alloc(32, n)]), format: 'der', type: 'pkcs8' });
}
function peerIdOf(n) {
  const pub = crypto.createPublicKey(seedKey(n)).export({ format: 'der', type: 'spki' }).subarray(-32);
  let v = BigInt('0x' + Buffer.concat([PEER_PREFIX, pub]).toString('hex'));
  let out = '';
  while (v > 0n) { out = BASE58[Number(v % 58n)] + out; v /= 58n; }
  return '1' + out; // one leading 0x00 byte (identity multihash code)
}
function hex32(n) { return n.toString(16).padStart(2, '0').repeat(32); }

// One node operator: peer seed n, server key hex32(n+100), deployment hex32(n+50).
function node(n, { ip = `81.2.69.${n}`, action = 'Deposit', epoch = 40, alias } = {}) {
  const peerId = peerIdOf(n);
  const serverKey = hex32(n + 100);
  const summary = {
    action, chain_id: '888', network_id: 'testnet', genesis_hash: GENESIS,
    deployment_id: hex32(n + 50), server_key: serverKey, service_alias: alias ?? `node-${serverKey.slice(0, 8)}`,
    effective_epoch: epoch, authorization_hash: crypto.createHash('sha256').update(`auth-${n}-${epoch}-${action}`).digest('hex'),
  };
  const multiaddr = `/ip4/${ip}/tcp/9000/p2p/${peerId}`;
  const peerSignature = crypto.sign(null, admissionPeerMessage({
    chainId: '888', networkId: 'testnet', authorizationHash: summary.authorization_hash, multiaddr,
  }), seedKey(n)).toString('hex');
  return { n, peerId, summary, body: { transaction: { synthetic: true, __summary: summary }, peerId, multiaddr, peerSignature } };
}

function fakes() {
  const state = {
    peers: [],
    bonds: [],
    probe: (addr) => ({ ok: true, data: { reachable: true, peer_id: addr.split('/p2p/')[1], chain_id: '888', network_id: 'testnet', genesis_hash: GENESIS } }),
    signFails: false,
    calls: [],
  };
  const runCli = async (args) => {
    state.calls.push(args);
    const [, , command] = args;
    if (command === 'probe') return state.probe(args[args.indexOf('--addr') + 1]);
    const tx = JSON.parse(fs.readFileSync(args[args.indexOf('--transaction-file') + 1], 'utf8'));
    if (!tx.__summary) return { ok: false, message: 'co-signer is not a bond admission key this binary pins for the packet\'s genesis' };
    if (!args.includes('--key-file')) return { ok: true, data: { admissible: true, signed: false, summary: tx.__summary } };
    if (state.signFails) return { ok: false, message: 'admission key file refused (owner-only 64-hex seed file)' };
    fs.writeFileSync(args[args.indexOf('--out') + 1], JSON.stringify({ ...tx, cosigned: true }));
    return { ok: true, data: { admissible: true, signed: true, summary: tx.__summary } };
  };
  const readNode = async (route) => {
    if (route === '/network/info') return { chain_height: 5000 };
    if (route === '/network/peers/sync') return { peers: state.peers };
    if (route.startsWith('/node/bonds')) return { bonds: state.bonds, next_after: null };
    throw new Error('unexpected route');
  };
  return { state, runCli, readNode };
}

function visible(peerId, extra = {}) {
  return { peer_id: peerId, connection_age_secs: 90000, advertised_height: 4999, advertisement_age_secs: 10, banned: false, ...extra };
}

function config(overrides = {}) {
  return {
    ...loadConfig({
      BOND_ADMISSION_ENABLED: 'true', WRFCOIN_CHAIN_ID: '888', WRFCOIN_NETWORK_ID: 'testnet',
      BOND_ADMISSION_KEY_FILE: '/run/secrets/synthetic-admission.seed', BOND_ADMISSION_IP_SALT: 'synthetic-test-salt-0123456789',
    }),
    ...overrides,
  };
}

async function harness({ cfg = config(), store } = {}) {
  const f = fakes();
  let clock = Date.parse('2026-11-20T01:00:00Z');
  const s = store || createMemoryStore(cfg);
  if (s.setClock) s.setClock(() => clock);
  const service = createService({ config: cfg, store: s, runCli: f.runCli, readNode: f.readNode, now: () => new Date(clock) });
  const server = http.createServer((req, res) => service.handle(req, res));
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = async (body) => {
    const res = await fetch(`${base}/bond-admission`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
    return { status: res.status, body: await res.json(), retryAfter: res.headers.get('retry-after') };
  };
  return {
    ...f, store: s, post, base,
    advance(seconds) { clock += seconds * 1000; },
    close: () => new Promise((resolve) => { server.closeAllConnections(); server.close(resolve); }),
  };
}

test('peer message matches the frozen core4 vector', () => {
  // core4 node_bond_admit.rs admission_peer_message_layout_is_frozen.
  const multiaddr = '/ip4/203.0.113.7/tcp/9000/p2p/12D3KooWJWoaqZhDaoEFshF7Rh1bpY9ohihFhzcW6d69Lr2NASuq';
  const fields = { chainId: '888', networkId: 'testnet', authorizationHash: 'ab'.repeat(32), multiaddr };
  assert.equal(peerIdOf(2), '12D3KooWJWoaqZhDaoEFshF7Rh1bpY9ohihFhzcW6d69Lr2NASuq');
  const signature = '07fb6838d507d91edb0a9ab6f4b5df81b9be5f26d67d32bbda883cb1ac4f49ebbc1290f4ef89e34017ae85d6cdc26a566ccb406a6461af8684d560bab994f308';
  assert.equal(crypto.sign(null, admissionPeerMessage(fields), seedKey(2)).toString('hex'), signature);
  assert.equal(verifyAdmissionPeerSignature(peerIdOf(2), signature, fields), true);
  assert.equal(verifyAdmissionPeerSignature(peerIdOf(3), signature, fields), false);
  assert.equal(verifyAdmissionPeerSignature(peerIdOf(2), signature, { ...fields, multiaddr: multiaddr.replace('9000', '9001') }), false);
});

test('a synced, reachable, new node is admitted and gets the co-signed packet back', async () => {
  const h = await harness();
  const a = node(1);
  h.state.peers = [visible(a.peerId)];
  const res = await h.post(a.body);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.data.admitted, true);
  assert.equal(res.body.data.included, false);
  assert.equal(res.body.data.transaction.cosigned, true);
  // Check, then probe, then sign with the key file: the key is named only on the sign call.
  const commands = h.state.calls.map((args) => `${args[2]}${args.includes('--key-file') ? '+key' : ''}`);
  assert.deepEqual(commands, ['admit', 'probe', 'admit+key']);
  const audit = await (await fetch(`${h.base}/bond-admissions`)).json();
  assert.equal(audit.admissions.length, 1);
  assert.equal(audit.admissions[0].serviceAlias, a.summary.service_alias);
  assert.ok(!JSON.stringify(audit).includes('81.2.69'), 'no address in the audit list');
  assert.ok(!JSON.stringify(h.store._keys()).includes('81.2.69'), 'only salted address hashes are stored');
  await h.close();
});

test('switched off, misconfigured, or off testnet: nothing runs', async () => {
  for (const [cfg, status, code] of [
    [config({ enabled: false }), 404, 'ADMISSION_DISABLED'],
    [config({ keyFile: '' }), 503, 'ADMISSION_UNAVAILABLE'],
    [config({ ipSalt: 'short' }), 503, 'ADMISSION_UNAVAILABLE'],
    [config({ networkId: 'mainnet' }), 503, 'ADMISSION_UNAVAILABLE'],
  ]) {
    const h = await harness({ cfg });
    const a = node(1);
    h.state.peers = [visible(a.peerId)];
    const res = await h.post(a.body);
    assert.equal(res.status, status);
    assert.equal(res.body.error.code, code);
    assert.equal(h.state.calls.length, 0);
    await h.close();
  }
});

test('request shape, address and peer proof are checked before the node is asked', async () => {
  const h = await harness();
  const a = node(1);
  h.state.peers = [visible(a.peerId)];
  const cases = [
    [{ ...a.body, multiaddr: a.body.multiaddr.replace('81.2.69.1', '192.168.0.36') }, 422, 'ADDRESS_NOT_PUBLIC'],
    [{ ...a.body, multiaddr: a.body.multiaddr.replace('81.2.69.1', '100.64.1.2') }, 422, 'ADDRESS_NOT_PUBLIC'],
    [{ ...a.body, multiaddr: `/ip6/::ffff:81.2.69.1/tcp/9000/p2p/${a.peerId}` }, 422, 'ADDRESS_NOT_PUBLIC'],
    [{ ...a.body, multiaddr: `/dns4/example.org/tcp/9000/p2p/${a.peerId}` }, 400, 'INVALID_ADMISSION_REQUEST'],
    [{ ...a.body, peerId: peerIdOf(9) }, 400, 'INVALID_ADMISSION_REQUEST'],
    [{ ...a.body, peerSignature: 'zz' }, 400, 'INVALID_ADMISSION_REQUEST'],
    [{ ...a.body, transaction: 'x' }, 400, 'INVALID_ADMISSION_REQUEST'],
    // Signed for another address on the same node.
    [{ ...a.body, multiaddr: a.body.multiaddr.replace('/tcp/9000/', '/tcp/9001/') }, 400, 'INVALID_PEER_SIGNATURE'],
    // The CLI refuses the packet (e.g. not the pinned key).
    [{ ...a.body, transaction: { synthetic: true } }, 422, 'ADMISSION_PACKET_REFUSED'],
    [node(1, { alias: 'tony-laptop' }).body, 422, 'ALIAS_NOT_GENERATED'],
  ];
  for (const [body, status, code] of cases) {
    const res = await h.post(body);
    assert.equal(res.status, status, `${code}: ${JSON.stringify(res.body)}`);
    assert.equal(res.body.error.code, code);
  }
  assert.ok(h.state.calls.every((args) => !args.includes('--key-file')), 'never signed');
  assert.equal((await h.store.recent()).length, 0);
  await h.close();
});

test('node must be visible, 24 h connected, synced and reachable', async () => {
  const h = await harness();
  const a = node(1);
  const cases = [
    [[], 409, 'NODE_NOT_VISIBLE'],
    [[visible(a.peerId, { connection_age_secs: 3600 })], 409, 'NODE_TOO_NEW'],
    [[visible(a.peerId, { advertised_height: 4000 })], 409, 'NODE_NOT_SYNCED'],
    [[visible(a.peerId, { banned: true })], 409, 'NODE_NOT_SYNCED'],
  ];
  for (const [peers, status, code] of cases) {
    h.state.peers = peers;
    const res = await h.post(a.body);
    assert.equal(res.status, status);
    assert.equal(res.body.error.code, code);
  }
  h.state.peers = [visible(a.peerId)];
  h.state.probe = () => ({ ok: false, message: 'connect to /ip4/…: timed out' });
  assert.equal((await h.post(a.body)).body.error.code, 'NODE_NOT_REACHABLE');
  h.state.probe = (addr) => ({ ok: true, data: { reachable: true, peer_id: addr.split('/p2p/')[1], chain_id: '777', network_id: 'testnet', genesis_hash: GENESIS } });
  assert.equal((await h.post(a.body)).body.error.code, 'NODE_WRONG_CHAIN');
  assert.ok(h.state.calls.every((args) => !args.includes('--key-file')), 'never signed');
  await h.close();
});

test('soft ceiling stops new Deposits but not Updates', async () => {
  const h = await harness({ cfg: config({ softCeiling: 3 }) });
  h.state.bonds = [{}, {}, {}];
  const a = node(1);
  h.state.peers = [visible(a.peerId)];
  const res = await h.post(a.body);
  assert.equal(res.status, 409);
  assert.equal(res.body.error.code, 'ADMISSION_CEILING');
  const u = node(1, { action: 'Update' });
  assert.equal((await h.post(u.body)).status, 200);
  await h.close();
});

async function limitScenarios(makeStore) {
  const h = await harness({ store: makeStore ? await makeStore() : undefined });
  const peers = [1, 2, 3, 4, 5].map((n) => visible(peerIdOf(n)));
  h.state.peers = peers;

  assert.equal((await h.post(node(1).body)).status, 200);
  // Same server key again, same epoch: refused.
  assert.equal((await h.post(node(1).body)).body.error.code, 'SERVER_KEY_ALREADY_ADMITTED');
  // Another node behind the same public address.
  assert.equal((await h.post(node(2, { ip: '81.2.69.1' }).body)).body.error.code, 'ADDRESS_ALREADY_ADMITTED');
  // A second address within 6 h of the first admission.
  const spaced = await h.post(node(2).body);
  assert.equal(spaced.status, 429);
  assert.equal(spaced.body.error.code, 'ADMISSION_SPACING');
  assert.ok(Number(spaced.retryAfter) > 0);

  h.advance(6 * 3600 + 1);
  assert.equal((await h.post(node(2).body)).status, 200);
  h.advance(6 * 3600 + 1);
  // Two today already (01:00Z and 07:00Z): the third waits for the UTC day.
  const third = await h.post(node(3).body);
  assert.equal(third.status, 429);
  assert.equal(third.body.error.code, 'ADMISSION_DAILY_LIMIT');

  // The first node's packet missed its epoch: a renewal for a later epoch from
  // the same address is allowed and is not charged to today's count.
  assert.equal((await h.post(node(1, { epoch: 41 }).body)).status, 200);
  // But not for an epoch it already had.
  assert.equal((await h.post(node(1, { epoch: 41 }).body)).body.error.code, 'SERVER_KEY_ALREADY_ADMITTED');

  h.advance(24 * 3600);
  assert.equal((await h.post(node(3).body)).status, 200);

  // A failed co-sign releases what it reserved.
  h.advance(6 * 3600 + 1);
  h.state.signFails = true;
  assert.equal((await h.post(node(4).body)).body.error.code, 'ADMISSION_SIGN_FAILED');
  h.state.signFails = false;
  assert.equal((await h.post(node(4).body)).status, 200);

  // Update: one per deployment per effective epoch, no slot limits.
  assert.equal((await h.post(node(1, { action: 'Update', epoch: 50 }).body)).status, 200);
  assert.equal((await h.post(node(1, { action: 'Update', epoch: 50 }).body)).body.error.code, 'UPDATE_ALREADY_ADMITTED');
  await h.close();
}

test('limits: one per server key, one per address, 6 h apart, 2 a day (memory store)', () => limitScenarios());

test('limits through the real Lua (needs BOND_ADMISSION_TEST_REDIS_URL)', { skip: !process.env.BOND_ADMISSION_TEST_REDIS_URL }, async () => {
  // The Lua uses Redis's own clock for TTLs, so this scenario only checks the
  // rules that don't need time to pass.
  const { createClient } = require('redis');
  const client = createClient({ url: process.env.BOND_ADMISSION_TEST_REDIS_URL });
  await client.connect();
  const prefix = `bond-admission-test-${process.pid}:`;
  const store = createRedisStore(client, { prefix, limits: config().limits });
  const now = new Date();
  const r = (n, ip, epoch = 40) => ({ serverKey: hex32(n + 100), deploymentId: hex32(n + 50), effectiveEpoch: epoch, ipHash: `h${ip}` });
  try {
    assert.equal((await store.reserveDeposit(r(1, 1), now)).kind, 'new');
    assert.equal((await store.reserveDeposit(r(1, 1), now)).code, 'SERVER_KEY_ALREADY_ADMITTED');
    assert.equal((await store.reserveDeposit(r(1, 1, 41), now)).kind, 'renewal');
    assert.equal((await store.reserveDeposit(r(2, 1), now)).code, 'ADDRESS_ALREADY_ADMITTED');
    assert.equal((await store.reserveDeposit(r(2, 2), now)).code, 'ADMISSION_SPACING');
    await store.releaseDeposit(r(1, 1, 41), now);
    assert.equal((await store.reserveDeposit(r(2, 2), now)).kind, 'new');
  } finally {
    const keys = await client.keys(`${prefix}*`);
    if (keys.length) await client.del(keys);
    await client.quit();
  }
});

test('the CLI child gets no service secrets, and its output is parsed safely', () => {
  const env = cliEnv({ PATH: '/usr/bin', HOME: '/home/x', BOND_ADMISSION_IP_SALT: 's', BOND_ADMISSION_READER_TOKEN: 't', REDIS_URL: 'r' });
  assert.deepEqual(Object.keys(env).sort(), ['HOME', 'PATH']);
  assert.deepEqual(parseCliOutput('{"ok":true,"data":{"a":1}}\n'), { ok: true, data: { a: 1 } });
  assert.deepEqual(parseCliOutput('{"ok":false,"error":{"message":"refused"}}'), { ok: false, message: 'refused' });
  assert.equal(parseCliOutput('garbage').ok, false);
  assert.throws(() => parseRequest(null));
});

test('busy service refuses rather than queueing CLI work', async () => {
  const cfg = config({ maxInFlight: 1 });
  const f = fakes();
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const slowCli = async (args) => { await gate; return f.runCli(args); };
  const service = createService({ config: cfg, store: createMemoryStore(cfg), runCli: slowCli, readNode: f.readNode });
  const server = http.createServer((req, res) => service.handle(req, res));
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}/bond-admission`;
  const a = node(1);
  f.state.peers = [visible(a.peerId)];
  const first = fetch(url, { method: 'POST', body: JSON.stringify(a.body) });
  await new Promise((resolve) => setTimeout(resolve, 50));
  const second = await fetch(url, { method: 'POST', body: JSON.stringify(node(2).body) });
  assert.equal(second.status, 429);
  release();
  assert.equal((await first).status, 200);
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
});
