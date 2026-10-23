'use strict';

// Bond grant (genesis 888, BOND_GRANT.md) through the real /faucet/bond-grant
// handler: one grant of exactly the bond per node key, per peer id and per
// wallet, a global daily count cap, and a node that must be visibly synced on
// the faucet's own node. Each scenario runs in a child process so the server
// reads its env at load. Redis is an in-memory stand-in by default; set
// FAUCET_TEST_REDIS_URL to a throwaway local Redis to run the same scenarios
// through the real Lua scripts. The node is a local mock.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const helper = require('./bond-grant-request');

const REAL_REDIS_URL = process.env.FAUCET_TEST_REDIS_URL || '';
const GRANT_UNITS = 25036000000;
const PEER = (n) => helper.peerIdFromSeed(String(n).padStart(2, '0').repeat(32));
const PEER_KEY = (n) => { const seed = Buffer.from(String(n).padStart(2, '0').repeat(32), 'hex'); const key = crypto.createPrivateKey({key:Buffer.concat([Buffer.from('302e020100300506032b657004220420','hex'), seed]), format:'der',type:'pkcs8'}); return Buffer.concat([Buffer.from('08011240','hex'), seed, crypto.createPublicKey(key).export({format:'der',type:'spki'}).subarray(-32)]); };
const OWNER = (n) => `0x${String(n).repeat(40).slice(0, 40)}`;
const SEED = (n) => String(n).padStart(2, '0').repeat(32);

const HARNESS = String.raw`
const http = require('node:http');
const helper = require('./bond-grant-request');
const TIP = 1000;
const peerId = (n) => helper.peerIdFromSeed(String(n).padStart(2,'0').repeat(32));
const peerKey = (n) => { const seed = Buffer.from(String(n).padStart(2,'0').repeat(32),'hex'); const key = require('node:crypto').createPrivateKey({key:Buffer.concat([Buffer.from('302e020100300506032b657004220420','hex'),seed]),format:'der',type:'pkcs8'});return Buffer.concat([Buffer.from('08011240','hex'),seed,require('node:crypto').createPublicKey(key).export({format:'der',type:'spki'}).subarray(-32)]); };
const hashAt = (h) => require('node:crypto').createHash('sha256').update('block' + h).digest('hex');
let peers = [];
let submitMode = 'ok';
let chainMode = 'ok';
let nodeNonce = 7n;
const submits = [];
function setPeers(p) { peers = p; }
function setSubmitMode(m) { submitMode = m; }
function setChainMode(m) { chainMode = m; }
async function startMockNode() {
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      res.setHeader('content-type', 'application/json');
      if (req.method === 'GET' && req.url === '/network/info') {
        res.end(JSON.stringify({ chain_id: '888', network_id: 'testnet', chain_height: TIP, local_peer_id: peerId(1) }));
        return;
      }
      if (req.method === 'GET' && req.url.startsWith('/chain/block/')) {
        const h = Number(req.url.slice('/chain/block/'.length));
        if (!(h >= 1 && h <= TIP)) { res.statusCode = 404; res.end(JSON.stringify({ ok: false, error: { code: 'NOT_FOUND', message: 'x' } })); return; }
        res.end(JSON.stringify({ ok: true, data: { height: h, hash: hashAt(h) } }));
        return;
      }
      if (req.method === 'GET' && req.url === '/network/peers/sync') {
        if (chainMode === 'peers-down') { res.statusCode = 503; res.end('{"error":"P2P not enabled"}'); return; }
        res.end(JSON.stringify({ local_peer_id: 'faucet-node', total: peers.length, peers }));
        return;
      }
      if (req.method === 'GET' && req.url.startsWith('/addresses/')) {
        const address = req.url.slice('/addresses/'.length);
        res.end(JSON.stringify({ ok: true, data: { address, balance: '100000000000000', spendable_balance: '100000000000000', nonce: nodeNonce.toString() } }));
        return;
      }
      if (req.method === 'POST' && req.url === '/transactions/submit') {
        const t = JSON.parse(body);
        submits.push({ to: t.to, amount: t.amount, nonce: t.nonce });
        if (t.nonce !== nodeNonce.toString()) { res.statusCode = 400; res.end(JSON.stringify({ ok: false, data: null, error: { code: 'TRANSACTION_REJECTED', message: 'Invalid nonce' }, meta: { request_id: 'req_mock', timestamp: '2026-10-22T00:00:00Z', api_version: 'v1' } })); return; }
        if (submitMode === 'reject') { res.statusCode = 400; res.end(JSON.stringify({ ok: false, data: null, error: { code: 'TRANSACTION_REJECTED', message: 'insufficient spendable balance' }, meta: { request_id: 'req_mock', timestamp: '2026-10-22T00:00:00Z', api_version: 'v1' } })); return; }
        if (submitMode === 'server-error') { nodeNonce += 1n; res.statusCode = 503; res.end('{}'); return; }
        nodeNonce += 1n;
        res.end(JSON.stringify({ data: { accepted: true, tx_id: '0x' + 'ab'.repeat(32) } }));
        return;
      }
      res.statusCode = 404; res.end('{}');
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return server;
}
function memoryRedis() {
  const store = new Map();
  const live = (k) => { const e = store.get(k); if (e && e.expiresAt !== null && e.expiresAt <= Date.now()) { store.delete(k); return undefined; } return e; };
  return {
    async set(k, v, o = {}) { if (o.NX && live(k)) return null; store.set(k, { value: String(v), expiresAt: o.EX ? Date.now() + o.EX * 1000 : (live(k)?.expiresAt ?? null) }); return 'OK'; },
    async lRange(k, start, end) { return JSON.parse(live(k)?.value || '[]').slice(start, end + 1); },
    async get(k) { const e = live(k); return e ? e.value : null; },
    async del(k) { store.delete(k); return 1; },
    async ttl(k) { const e = live(k); if (!e) return -2; return e.expiresAt === null ? -1 : Math.ceil((e.expiresAt - Date.now()) / 1000); },
    async keys(p) { const prefix = p.replace(/\*$/, ''); return [...store.keys()].filter((k) => k.startsWith(prefix) && live(k)); },
    async decrBy(k, a) { const e = live(k); const n = Number(e ? e.value : 0) - Number(a); store.set(k, { value: String(n), expiresAt: e ? e.expiresAt : null }); return n; },
    async eval(script, { keys, arguments: args }) {
      if (script.includes('-- faucet-nonce-reserve')) { const e = live(keys[0]); if (e && BigInt(e.value.split(':')[0]) >= BigInt(args[0])) return 0; store.set(keys[0], { value: args[1], expiresAt: null }); return 1; }
      if (script.includes('-- faucet-nonce-release')) { const e = live(keys[0]); if (e?.value !== args[0]) return 0; store.delete(keys[0]); return 1; }
      if (script.includes('-- faucet-bond-grant-reserve')) {
        for (let i = 0; i < 3; i += 1) if (live(keys[i])) return [0, i + 1];
        const c = Number(live(keys[3])?.value ?? 0);
        if (c >= Number(args[1])) return [0, 4];
        const gap = live(keys[4]);
        if (gap) return [0, 5, Math.max(1, Math.ceil((gap.expiresAt - Date.now()) / 1000))];
        store.set(keys[4], { value: args[0], expiresAt: Date.now() + Number(args[3]) * 1000 });
        for (let i = 0; i < 3; i += 1) store.set(keys[i], { value: args[0], expiresAt: null });
        const e = live(keys[3]);
        store.set(keys[3], { value: String(c + 1), expiresAt: e ? e.expiresAt : Date.now() + Number(args[2]) * 1000 });
        return [1, c + 1];
      }
      if (script.includes('-- faucet-bond-grant-release')) {
        let released = 0;
        for (let i = 0; i < 3; i += 1) if (live(keys[i])?.value === args[0]) { store.delete(keys[i]); released = 1; }
        const e = live(keys[3]);
        if (released && e && Number(e.value) > 0) store.set(keys[3], { value: String(Number(e.value) - 1), expiresAt: e.expiresAt });
        if (live(keys[4])?.value === args[0]) store.delete(keys[4]);
        return released;
      }
      if (script.includes('-- faucet-bond-grant-publish')) {
        for (let i = 0; i < 3; i++) store.set(keys[i], { value: args[0], expiresAt: null });
        const rows = JSON.parse(live(keys[3])?.value || '[]'); rows.unshift(args[1]);
        store.set(keys[3], { value: JSON.stringify(rows.slice(0, Number(args[2]))), expiresAt: null });
        return 1;
      }
      const [amount, cap, ttl] = args.map(Number); const e = live(keys[0]); const cur = Number(e ? e.value : 0);
      if (cur + amount > cap) return [0, cur];
      store.set(keys[0], { value: String(cur + amount), expiresAt: e ? e.expiresAt : Date.now() + ttl * 1000 }); return [1, cur + amount];
    },
  };
}
async function boot() {
  const node = await startMockNode();
  process.env.FAUCET_NODE_URL = 'http://127.0.0.1:' + node.address().port;
  const server = require('./server');
  let reader;
  if (process.env.REDIS_URL) {
    await server.ensureRedis();
    reader = require('redis').createClient({ url: process.env.REDIS_URL });
    await reader.connect();
  } else {
    reader = memoryRedis();
    server.setRedisClientForTests(reader);
  }
  const http_ = server.app.listen(0, '127.0.0.1');
  await new Promise((r) => http_.once('listening', r));
  const base = 'http://127.0.0.1:' + http_.address().port;
  // A node: its seed, owner, peer id; sign a block 'behind' under the tip.
  function signed(n, { owner, peer, behind = 2, chainId = '888', hash, peerN = n } = {}) {
    const height = TIP - behind;
    return helper.signBondGrant({
      seedHex: String(n).padStart(2, '0').repeat(32), peerIdentityBytes: peerKey(peerN), chainId, networkId: 'testnet',
      ownerAddress: owner || '0x' + String(n).repeat(40).slice(0, 40),
      peerId: peer || peerId(peerN), height, blockHash: hash || hashAt(height),
    });
  }
  function visible(...ns) {
    setPeers(ns.map((n) => ({ peer_id: peerId(n), advertised_height: TIP, advertisement_age_secs: 3, connection_age_secs: 86400, banned: false })));
  }
  async function grant(body, { proxy = true, path = '/faucet/bond-grant' } = {}) {
    // Legacy identity/outcome scenarios isolate pacing; pacing scenarios retain the key.
    if (process.env.TEST_CLEAR_SPACING === 'true') await reader.del(process.env.FAUCET_BOND_GRANT_PREFIX + 'spacing');
    const r = await fetch(base + path, {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...(proxy ? { authorization: 'Bearer operator-token', 'x-client-ip': 'device-1' } : {}) },
      body: JSON.stringify(body),
    });
    const text = await r.text();
    return { status: r.status, retryAfter: r.headers.get('retry-after'), code: r.status === 200 ? 'OK' : JSON.parse(text).error.code, body: JSON.parse(text) };
  }
  async function marks() {
    const out = {};
    for (const k of (await reader.keys(process.env.FAUCET_BOND_GRANT_PREFIX + '*')).sort()) if (!k.endsWith(':spacing') && !k.endsWith(':audit')) out[k.slice(process.env.FAUCET_BOND_GRANT_PREFIX.length).split(':')[0] + ':' + k.split(':').pop().slice(0, 6)] = await reader.get(k);
    return out;
  }
  async function pending() {
    const out = [];
    for (const k of await reader.keys(process.env.FAUCET_PENDING_PREFIX + '*')) out.push(JSON.parse(await reader.get(k)));
    return out;
  }
  async function close() {
    if (process.env.REDIS_URL) await reader.quit();
    await new Promise((r) => http_.close(r));
    node.close();
    process.exit(0);
  }
  return { server, signed, visible, grant, marks, pending, close, submits, TIP, hashAt, reader, base };
}
`;

function runScenario(body, extraEnv = {}) {
  const script = `${HARNESS}
(async () => {
  const { server, signed, visible, grant, marks, pending, close, submits, TIP, hashAt, reader, base } = await boot();
  const out = {};
  ${body}
  process.stdout.write(JSON.stringify(out));
  await close();
})().catch((error) => { console.error(error); process.exit(1); });`;
  const run = `${process.pid}:${Date.now()}:${Math.random().toString(36).slice(2)}`;
  const env = {
    ...process.env,
    CAPTCHA_PROVIDER: 'off',
    FAUCET_API_TOKEN: 'operator-token',
    // Obviously fake signing key and faucet address; the node is a local mock.
    FAUCET_WALLET_PRIVKEY: '11'.repeat(32),
    FAUCET_WALLET_ADDRESS: '0x' + 'b'.repeat(40),
    WRFCOIN_CHAIN_ID: '888',
    WRFCOIN_NETWORK_ID: 'testnet',
    FAUCET_HIGH_WATER_MARK: '0',
    FAUCET_AMOUNT: '10',
    FAUCET_WALLET_DAILY_CAP: '10',
    FAUCET_DEVICE_DAILY_CAP: '10',
    FAUCET_GLOBAL_DAILY_CAP: '1000',
    FAUCET_WALLET_BALANCE_FLOOR: '10',
    FAUCET_BOND_GRANT_ENABLED: 'true',
    TEST_CLEAR_SPACING: 'true',
    REDIS_URL: REAL_REDIS_URL,
    FAUCET_RATE_LIMIT_PREFIX: `t${run}:ip:`,
    FAUCET_RATE_LIMIT_TSUSER_PREFIX: `t${run}:ts:`,
    FAUCET_WALLET_DAILY_PREFIX: `t${run}:wallet:`,
    FAUCET_GLOBAL_DAILY_PREFIX: `t${run}:global:`,
    FAUCET_DEVICE_DAILY_PREFIX: `t${run}:device:`,
    FAUCET_PENDING_PREFIX: `t${run}:pending:`,
    FAUCET_BOND_GRANT_PREFIX: `t${run}:bond:`,
    ...extraEnv,
  };
  return JSON.parse(execFileSync(process.execPath, ['-e', script], { cwd: __dirname, env, encoding: 'utf8', timeout: 20000 }));
}

test('helper and server build the same signed message, and the signature verifies', () => {
  process.env.WRFCOIN_CHAIN_ID = process.env.WRFCOIN_CHAIN_ID || '888';
  const req = helper.signBondGrant({
    seedHex: SEED(5), peerIdentityBytes: PEER_KEY(5), chainId: '888', networkId: 'testnet', ownerAddress: `wrf${'5'.repeat(40)}`,
    peerId: PEER(5), height: 42, blockHash: `0x${'AA'.repeat(32)}`,
  });
  assert.equal(req.ownerAddress, OWNER(5));
  assert.equal(req.blockHash, 'aa'.repeat(32));
  // Golden: the exact preimage layout (domain, length-prefixed fields, u64 LE height).
  const msg = helper.buildBondGrantMessage({ chainId: '888', networkId: 'testnet', ...req });
  const expected = Buffer.concat([
    Buffer.from('wrfcoin_faucet_bond_grant_v1'),
    Buffer.from([3, 0, 0, 0]), Buffer.from('888'),
    Buffer.from([7, 0, 0, 0]), Buffer.from('testnet'),
    Buffer.from([42, 0, 0, 0]), Buffer.from(OWNER(5)),
    Buffer.from([64, 0, 0, 0]), Buffer.from(req.serverKey),
    Buffer.from([PEER(5).length, 0, 0, 0]), Buffer.from(PEER(5)),
    Buffer.from([42, 0, 0, 0, 0, 0, 0, 0]),
    Buffer.from([64, 0, 0, 0]), Buffer.from('aa'.repeat(32)),
  ]);
  assert.deepEqual(msg, expected);
  const key = crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), Buffer.from(req.serverKey, 'hex')]), format: 'der', type: 'spki' });
  assert.equal(crypto.verify(null, msg, key, Buffer.from(req.signature, 'hex')), true);
  // Server parity, in a child so its env is read at load.
  const out = runScenario(`
    const req = signed(5, { behind: 2 });
    out.same = server.buildBondGrantMessage(req).equals(helper.buildBondGrantMessage({ chainId: '888', networkId: 'testnet', ...req }));
    out.ok = server.verifyBondGrantSignature(req, req.signature);
    out.otherChain = server.verifyBondGrantSignature(req, signed(5, { chainId: '777' }).signature);
  `);
  assert.deepEqual(out, { same: true, ok: true, otherChain: false });
});

test('default OFF: the route refuses and nothing is paid', () => {
  const out = runScenario(`
    visible(1);
    out.r = await grant(signed(1));
    out.submits = submits.length;
  `, { FAUCET_BOND_GRANT_ENABLED: '' });
  assert.equal(out.r.status, 404);
  assert.equal(out.r.code, 'BOND_GRANT_DISABLED');
  assert.equal(out.submits, 0);
});

test('a synced, visible node gets exactly the bond once; key, peer and wallet are each spent', () => {
  const out = runScenario(`
    visible(1, 2, 3, 4, 9);
    out.first = await grant(signed(1));
    out.paid = submits.slice();
    out.marks = await marks();
    out.sameKey = await grant(signed(1, { owner: '0x' + '9'.repeat(40), peerN: 9 }));
    out.samePeer = await grant(signed(2, { peerN: 1 }));
    out.sameWallet = await grant(signed(3, { owner: '0x' + '1'.repeat(40) }));
    out.fresh = await grant(signed(4));
    out.submits = submits.length;
  `);
  assert.equal(out.first.status, 200, JSON.stringify(out.first));
  assert.equal(out.first.body.amount, '250.36');
  assert.deepEqual(out.paid, [{ to: OWNER(1), amount: GRANT_UNITS, nonce: '7' }]);
  const records = Object.values(out.marks).filter((v) => v.startsWith('{')).map((v) => JSON.parse(v));
  assert.equal(records.length, 3);
  for (const r of records) {
    assert.equal(r.state, 'granted');
    assert.equal(r.txHash, '0x' + 'ab'.repeat(32));
    assert.equal(r.ownerAddress, OWNER(1));
  }
  assert.equal(out.sameKey.status, 409);
  assert.match(out.sameKey.body.error.message, /node key/);
  assert.equal(out.samePeer.status, 409);
  assert.match(out.samePeer.body.error.message, /peer id/);
  assert.equal(out.sameWallet.status, 409);
  assert.match(out.sameWallet.body.error.message, /wallet/);
  assert.equal(out.fresh.status, 200);
  assert.equal(out.submits, 2);
});

test('the node must be visible and synced on the faucet node; nothing is reserved when it is not', () => {
  const out = runScenario(`
    visible(2);
    out.invisible = await grant(signed(1));
    out.staleBlock = await grant(signed(2, { behind: 21 }));
    out.futureBlock = await grant(signed(2, { behind: -1 }));
    out.wrongHash = await grant(signed(2, { hash: 'ee'.repeat(32) }));
    out.synced = await grant(signed(2));
    out.marks = await marks();
    out.submits = submits.length;
  `);
  assert.equal(out.invisible.status, 409);
  assert.equal(out.invisible.code, 'NODE_NOT_VISIBLE');
  for (const k of ['staleBlock', 'futureBlock', 'wrongHash']) {
    assert.equal(out[k].status, 409, k);
    assert.equal(out[k].code, 'NODE_NOT_SYNCED', k);
  }
  assert.equal(out.synced.status, 200);
  assert.equal(Object.keys(out.marks).filter((k) => !k.startsWith('daily')).length, 3);
  assert.equal(out.submits, 1);
});

test('a lagging, stale or banned peer is refused', () => {
  const out = runScenario(`
    const p = peerId;
    const peerBase = { advertisement_age_secs: 3, connection_age_secs: 86400, banned: false };
    out.r = [];
    for (const peer of [
      { ...peerBase, peer_id: p(1), advertised_height: TIP - 21 },
      { ...peerBase, peer_id: p(1), advertised_height: TIP, advertisement_age_secs: 301 },
      { ...peerBase, peer_id: p(1), advertised_height: TIP, banned: true },
    ]) {
      setPeers([peer]);
      out.r.push((await grant(signed(1))).code);
    }
    out.submits = submits.length;
    out.marks = await marks();
  `);
  assert.deepEqual(out.r, ['NODE_NOT_SYNCED', 'NODE_NOT_SYNCED', 'NODE_NOT_SYNCED']);
  assert.equal(out.submits, 0);
  assert.deepEqual(out.marks, {});
});

test('bad signatures and malformed requests are refused before any chain read or reservation', () => {
  const out = runScenario(`
    visible(1);
    const good = signed(1);
    out.otherOwner = await grant({ ...good, ownerAddress: '0x' + '7'.repeat(40) });
    out.otherChain = await grant(signed(1, { chainId: '777' }));
    out.badKey = await grant({ ...good, serverKey: 'zz' });
    out.badPeer = await grant({ ...good, peerId: 'not a peer' });
    out.badHeight = await grant({ ...good, height: '998' });
    out.marks = await marks();
    out.submits = submits.length;
  `);
  assert.equal(out.otherOwner.code, 'INVALID_BOND_GRANT_REQUEST');
  assert.equal(out.otherChain.code, 'INVALID_BOND_GRANT_REQUEST');
  for (const k of ['badKey', 'badPeer', 'badHeight']) assert.equal(out[k].code, 'INVALID_BOND_GRANT_REQUEST', k);
  assert.deepEqual(out.marks, {});
  assert.equal(out.submits, 0);
});

test('global daily count cap refuses with Retry-After and charges no drip caps', () => {
  const out = runScenario(`
    visible(1, 2);
    out.first = await grant(signed(1));
    out.second = await grant(signed(2));
    out.marks = await marks();
    out.drip = await grant({ walletAddress: '0x' + '1'.repeat(40) }, { path: '/faucet/request' });
    out.paid = submits.map((s) => s.amount);
  `, { FAUCET_BOND_GRANT_DAILY_COUNT_CAP: '1' });
  assert.equal(out.first.status, 200);
  assert.equal(out.second.status, 429);
  assert.equal(out.second.code, 'BOND_GRANT_DAILY_LIMIT');
  assert.ok(Number(out.second.retryAfter) > 0);
  // Node 2 was not marked: it can claim after the day resets.
  assert.equal(Object.keys(out.marks).filter((k) => k.startsWith('server')).length, 1);
  // The same owner still gets the normal drip: the grant spent no drip wallet/global cap.
  assert.equal(out.drip.status, 200, JSON.stringify(out.drip));
  assert.deepEqual(out.paid, [GRANT_UNITS, 1000000000]);
});

test('a definitive node rejection releases the marks; an unknown outcome keeps them and records a pending claim', () => {
  const out = runScenario(`
    visible(1);
    setSubmitMode('reject');
    out.rejected = await grant(signed(1));
    out.afterReject = await marks();
    setSubmitMode('ok');
    out.retry = await grant(signed(1));
    visible(2);
    setSubmitMode('server-error');
    out.unknown = await grant(signed(2));
    out.pending = await pending();
    setSubmitMode('ok');
    out.again = await grant(signed(2));
    out.submits = submits.length;
  `);
  assert.equal(out.rejected.status, 502);
  assert.equal(out.rejected.code, 'FAUCET_TRANSFER_FAILED');
  assert.deepEqual(Object.keys(out.afterReject).filter((k) => !k.startsWith('daily')), []);
  assert.equal(out.retry.status, 200);
  assert.equal(out.unknown.status, 409);
  assert.equal(out.unknown.code, 'CLAIM_PENDING');
  assert.equal(out.pending.length, 1);
  assert.equal(out.pending[0].kind, 'bond_grant');
  assert.equal(out.pending[0].amountBaseUnits, GRANT_UNITS);
  assert.equal(out.again.status, 409);
  assert.equal(out.again.code, 'BOND_GRANT_ALREADY_USED');
  assert.equal(out.submits, 3);
});

test('chain reads failing is a 503 that reserves nothing; public path needs a captcha provider', () => {
  const out = runScenario(`
    visible(1);
    setChainMode('peers-down');
    out.down = await grant(signed(1));
    setChainMode('ok');
    out.publicNoCaptcha = await grant(signed(1), { proxy: false });
    out.marks = await marks();
    out.submits = submits.length;
  `);
  assert.equal(out.down.status, 503);
  assert.equal(out.down.code, 'BOND_GRANT_CHAIN_UNAVAILABLE');
  assert.notEqual(out.publicNoCaptcha.status, 200);
  assert.deepEqual(out.marks, {});
  assert.equal(out.submits, 0);
});


test('operator required by default; public switch permits captcha path but never a wrong bearer', () => {
  const out = runScenario(`visible(1); out.r = await grant(signed(1), { proxy: false }); out.marks = await marks();`);
  assert.equal(out.r.status, 401);
  assert.equal(out.r.code, 'OPERATOR_REQUIRED');
  assert.deepEqual(out.marks, {});
  const pub = runScenario(`visible(1); out.r = await grant(signed(1), { proxy: false }); out.proxy = await grant(signed(1)); out.wrong = (await fetch(base+'/faucet/bond-grant', {method:'POST',headers:{'content-type':'application/json',authorization:'Bearer wrong'},body:JSON.stringify(signed(2))})).status;`, { FAUCET_BOND_GRANT_PUBLIC: 'true' });
  assert.notEqual(pub.r.code, 'OPERATOR_REQUIRED');
  assert.equal(pub.proxy.status, 200); assert.equal(pub.wrong, 403);
  assert.notEqual(pub.r.status, 200); // captcha is still required for direct callers
});

test('probation rejects young, absent, non-numeric and non-finite ages without reservations; threshold passes', () => {
  const out = runScenario(`
    out.rejected = [];
    for (const age of [86399, undefined, null, '86400', 'old', -1]) {
      setPeers([{ peer_id: signed(1).peerId, advertised_height: TIP, advertisement_age_secs: 3, connection_age_secs: age }]);
      out.rejected.push(await grant(signed(1)));
    }
    out.marks = await marks(); visible(1); out.pass = await grant(signed(1));
  `);
  for (const r of out.rejected) {
    assert.equal(r.status, 409); assert.equal(r.code, 'NODE_TOO_NEW');
    assert.ok(r.body.error.details.retryAfterSeconds > 0);
  }
  assert.deepEqual(out.marks, {});
  assert.equal(out.pass.status, 200);
});

test('spacing returns 429 and Retry-After, default gap is six hours; definitive failure releases gap', () => {
  const out = runScenario(`
    visible(1, 2); out.first = await grant(signed(1)); out.second = await grant(signed(2));
    out.ttl = await reader.ttl(process.env.FAUCET_BOND_GRANT_PREFIX + 'spacing');
    out.marks = await marks();
  `, { TEST_CLEAR_SPACING: 'false' });
  assert.equal(out.first.status, 200); assert.equal(out.second.status, 429);
  assert.equal(out.second.code, 'BOND_GRANT_SPACING');
  assert.ok(Number(out.second.retryAfter) > 21590);
  assert.ok(out.ttl <= 21600 && out.ttl > 21590);
  assert.equal(Object.keys(out.marks).filter(k => k.startsWith('server')).length, 1);
  const release = runScenario(`visible(1); setSubmitMode('reject'); out.rejected = await grant(signed(1)); setSubmitMode('ok'); out.retry = await grant(signed(1));`, { TEST_CLEAR_SPACING: 'false' });
  assert.equal(release.rejected.status, 502); assert.equal(release.retry.status, 200);
});

test('two simultaneous independent Redis reservations cannot both pass the spacing gate', () => {
  const out = runScenario(`
    const prefix = process.env.FAUCET_BOND_GRANT_PREFIX;
    const reserve = (n) => reader.eval(server.BOND_GRANT_RESERVE_LUA, {
      keys: [prefix+'server:'+n, prefix+'peer:'+n, prefix+'wallet:'+n, prefix+'daily:test', prefix+'spacing'],
      arguments: [JSON.stringify({n}), '2', '86400', '21600'],
    });
    out.results = await Promise.all([reserve(1), reserve(2)]);
  `, { TEST_CLEAR_SPACING: 'false' });
  assert.equal(out.results.filter(r => Number(r[0]) === 1).length, 1);
  assert.equal(out.results.filter(r => Number(r[0]) === 0 && Number(r[1]) === 5).length, 1);
});

test('daily cap defaults to two grants', () => {
  const out = runScenario(`visible(1, 2, 3); out.r = [await grant(signed(1)), await grant(signed(2)), await grant(signed(3))];`);
  assert.deepEqual(out.r.map(r => r.status), [200, 200, 429]);
  assert.equal(out.r[2].code, 'BOND_GRANT_DAILY_LIMIT');
});

test('audit is reader gated, contains exactly public fields, bounded to 100, bonded unavailable per addendum', () => {
  const out = runScenario(`
    visible(1); await grant(signed(1));
    out.anon = (await fetch(base+'/faucet/bond-grants')).status;
    out.wrong = (await fetch(base+'/faucet/bond-grants', {headers:{authorization:'Bearer wrong'}})).status;
    const read = await fetch(base+'/faucet/bond-grants', {headers:{authorization:'Bearer reader-token'}});
    out.operator = (await fetch(base+'/faucet/bond-grants', {headers:{authorization:'Bearer operator-token'}})).status;
    out.status = read.status; out.body = await read.json();
    const raw = {...out.body.grants[0], ip:'private', token:'secret', body:{private:true}};
    // Exercise bounded read even if an old/manual writer leaves a longer list.
    for (let n=0;n<120;n++) await reader.eval(server.BOND_GRANT_PUBLISH_LUA, {keys:['a','b','c',process.env.FAUCET_BOND_GRANT_PREFIX+'audit'],arguments:['{}',JSON.stringify(raw),'200']});
    out.bounded = await (await fetch(base+'/faucet/bond-grants', {headers:{authorization:'Bearer reader-token'}})).json();
  `, { FAUCET_READER_TOKEN: 'reader-token' });
  assert.equal(out.anon, 401); assert.equal(out.wrong, 403); assert.equal(out.status, 200); assert.equal(out.operator, 200);
  const row = out.body.grants[0];
  assert.deepEqual(Object.keys(row).sort(), ['bonded','ownerAddress','peerId','serverKey','time','txHash']);
  assert.equal(row.ownerAddress, OWNER(1)); assert.equal(row.bonded, null);
  assert.equal(row.txHash, '0x'+'ab'.repeat(32)); assert.ok(Date.parse(row.time));
  assert.equal(out.bounded.grants.length, 100);
  assert.ok(out.bounded.grants.every(r => Object.keys(r).length === 6 && r.bonded === null));
  const pub = runScenario(`out.r = await fetch(base+'/faucet/bond-grants'); out.status=out.r.status; out.body=await out.r.json();`, { FAUCET_BOND_GRANT_PUBLIC:'true' });
  assert.equal(pub.status, 200); assert.deepEqual(pub.body, {grants:[]});
});

test('invalid pacing env overrides fall back to approved defaults', () => {
  for (const value of ['-1', '0', 'NaN', 'Infinity', '999999999999999999', '2garbage', '1.5', '']) {
    const out = runScenario(`
      out.integer = server.bondGrantInteger(process.env.BAD_VALUE, 2, 1, 100);
      visible(1, 2); out.first=await grant(signed(1)); out.next=await grant(signed(2));
      setPeers([{peer_id:signed(3).peerId, advertised_height:TIP, connection_age_secs:86399}]);
      out.young=await grant(signed(3));
    `, { BAD_VALUE:value, FAUCET_BOND_GRANT_DAILY_COUNT_CAP:value, FAUCET_BOND_GRANT_MIN_INTERVAL_SECONDS:value, FAUCET_BOND_GRANT_MIN_PEER_AGE_SECONDS:value, TEST_CLEAR_SPACING:'false' });
    assert.equal(out.integer, 2, value); assert.equal(out.first.status, 200, value);
    assert.equal(out.next.code, 'BOND_GRANT_SPACING', value); assert.ok(Number(out.next.retryAfter)>21590, value);
    assert.equal(out.young.code, 'NODE_TOO_NEW', value);
  }
});

test('concurrent valid HTTP requests never both pay; unknown outcome keeps the spacing reservation', () => {
  const out = runScenario(`
    visible(1, 2); out.concurrent = await Promise.all([grant(signed(1)), grant(signed(2))]);
    out.submits = submits.length;
  `, { TEST_CLEAR_SPACING: 'false' });
  assert.equal(out.concurrent.filter(r => r.status === 200).length, 1);
  assert.equal(out.submits, 1);
  const pending = runScenario(`
    visible(1, 2); setSubmitMode('server-error'); out.first = await grant(signed(1));
    setSubmitMode('ok'); out.second = await grant(signed(2));
  `, { TEST_CLEAR_SPACING: 'false' });
  assert.equal(pending.first.code, 'CLAIM_PENDING');
  assert.equal(pending.second.status, 429); assert.equal(pending.second.code, 'BOND_GRANT_SPACING');
});

test('audit storage failure returns a generic response without error internals', () => {
  const out = runScenario(`
    server.setRedisClientForTests({lRange: async () => {throw new Error('operator-token private-host stack trace')}});
    const r = await fetch(base+'/faucet/bond-grants', {headers:{authorization:'Bearer operator-token'}});
    out.status = r.status; out.text = await r.text();
  `);
  assert.equal(out.status, 503);
  assert.doesNotMatch(out.text, /operator-token|private-host|stack trace/);
});

test('reference libp2p peer vector fixes both messages, protobuf identity, and signatures byte-for-byte', () => {
  const v = require('./bond-grant-peer-vector.json');
  assert.equal(helper.decodePeerPublicKey(v.request.peerId).toString('hex'), v.peerPublicKeyHex);
  assert.equal(helper.peerIdFromSeed(v.testOnlyPeerSeedHex), v.request.peerId);
  const req = helper.signBondGrant({seedHex:v.testOnlyServerSeedHex, peerIdentityBytes:Buffer.from(v.peerPrivateKeyProtobufHex,'hex'), chainId:v.chainId,networkId:v.networkId,...v.request});
  assert.deepEqual(req,v.request);
  const message = helper.buildBondGrantMessage({chainId:v.chainId,networkId:v.networkId,...v.request});
  assert.equal(message.toString('hex'),v.serverMessageHex);
  assert.equal(helper.peerMessage(message).toString('hex'),v.peerMessageHex);
  assert.equal(helper.verifyPeerSignature(req.peerId,req.peerSignature,message),true);
});

test('fresh server key cannot borrow an old peer without peer possession; both caller paths fail before reservation', () => {
  for (const publicMode of ['false','true']) {
    const out = runScenario(`
      visible(1); const oldPeer = signed(1).peerId;
      // Attacker controls its server key, but only its own peer key.
      const stolen = { ...signed(2), peerId: oldPeer };
      const crypto = require('node:crypto');
      const seed = Buffer.from('02'.repeat(32),'hex');
      const key = crypto.createPrivateKey({key:Buffer.concat([Buffer.from('302e020100300506032b657004220420','hex'),seed]),format:'der',type:'pkcs8'});
      stolen.signature = crypto.sign(null, server.buildBondGrantMessage(stolen),key).toString('hex');
      out.borrowed = await grant(stolen);
      out.missing = await grant({...stolen,peerSignature:undefined});
      out.direct = await grant({...stolen,peerSignature:undefined},{proxy:false});
      out.marks = await marks(); out.submits = submits.length;
      out.valid = await grant(signed(1));
    `,{FAUCET_BOND_GRANT_PUBLIC:publicMode});
    for(const k of ['borrowed','missing']) {assert.equal(out[k].status,400,k);assert.equal(out[k].code,'INVALID_BOND_GRANT_REQUEST',k);}
    assert.equal(out.direct.status, publicMode === 'true' ? 400 : 401);
    assert.deepEqual(out.marks,{});assert.equal(out.submits,0);assert.equal(out.valid.status,200);
  }
});

test('peer proof rejects wrong message, wrong domain, malformed and non-identity peer ids', () => {
  const out = runScenario(`
    visible(1); const good = signed(1);
    const crypto = require('node:crypto');
    const key = helper.keyFromIdentityFile(peerKey(1));
    out.bad = [];
    for (const request of [
      {...good,peerSignature:'00'.repeat(64)},
      {...good,peerSignature:crypto.sign(null,server.buildBondGrantMessage(good),key).toString('hex')},
      {...good,peerSignature:crypto.sign(null,Buffer.concat([Buffer.from('wrong_domain'),server.buildBondGrantMessage(good)]),key).toString('hex')},
      {...good,peerSignature:signed(1,{behind:3}).peerSignature},
      {...good,peerId:'12D3KooW'+'1'.repeat(44)},
      {...good,peerId:'QmYwAPJzv5CZsnAzt8auVZRnGi2CzBfo7UkWQp6R9kDkZ4'},
      {...good,peerId:'z'+good.peerId},
    ]) out.bad.push(await grant(request));
    out.marks = await marks(); out.submits = submits.length;
  `);
  for(const r of out.bad){assert.equal(r.status,400);assert.equal(r.code,'INVALID_BOND_GRANT_REQUEST');}
  assert.deepEqual(out.marks,{});assert.equal(out.submits,0);
});

test('request CLI reads Core4 protobuf identity and emits dual signatures without echoing keys', () => {
  const out = runScenario(`
    const fs = require('node:fs'); const path = require('node:path');
    const dir = fs.mkdtempSync(path.join(require('node:os').tmpdir(),'bond-grant-builder-'));
    try {
      const seedPath = path.join(dir,'server-seed'); const peerPath = path.join(dir,'peer_identity.key');
      fs.writeFileSync(seedPath,'01'.repeat(32),{mode:0o600});fs.writeFileSync(peerPath,peerKey(1),{mode:0o600});
      const {stdout,stderr} = await new Promise((resolve,reject)=>require('node:child_process').execFile(process.execPath,[require.resolve('./bond-grant-request'),'--owner','0x'+'1'.repeat(40),'--server-key-file',seedPath,'--peer-key-file',peerPath,'--chain-id','888','--network-id','testnet','--node',process.env.FAUCET_NODE_URL],(error,stdout,stderr)=>error?reject(error):resolve({stdout,stderr})));
      out.request = JSON.parse(stdout);out.stderr = stderr;
      out.verified = server.parseBondGrantRequest(out.request).peerSignature === out.request.peerSignature;
      out.serverValid = server.verifyBondGrantSignature(out.request,out.request.signature);
      fs.chmodSync(peerPath,0o644);try{helper.readPeerKeyFile(peerPath);out.insecureAccepted=true;}catch{out.insecureAccepted=false;}
    } finally {fs.rmSync(dir,{recursive:true,force:true});}
  `);
  assert.equal(out.verified,true);assert.equal(out.serverValid,true);assert.equal(out.insecureAccepted,false);assert.equal(out.stderr,'');
  assert.ok(out.request.peerSignature);assert.ok(!Object.values(out.request).includes('01'.repeat(32)));
});
