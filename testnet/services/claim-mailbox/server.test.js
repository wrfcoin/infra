'use strict';

// Claim mailbox through its real HTTP handler, with the in-memory store. Set
// CLAIM_MAILBOX_TEST_REDIS_URL to a throwaway local Redis to also run the store
// scenarios through the real Lua. Every value below is synthetic test data.

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { MAX_CLAIMS, createMemoryStore, createRedisStore } = require('./store');
const { createService, loadConfig, parseRoute } = require('./server');

const TOKEN = 'synthetic-claim-mailbox-write-token-0123456789'; // secret-leak-ok: fixed synthetic test bearer
const BOND = 'ab'.repeat(32);
const OTHER = 'cd'.repeat(32);
function rid(n) { return n.toString(16).padStart(2, '0').repeat(32); }
function claim(n, hex = `0a${n.toString(16).padStart(2, '0')}ff`) { return { claim_hex: hex, receipt_id: rid(n) }; }

async function withService(overrides, fn, store) {
  const config = { ...loadConfig({}), enabled: true, writeToken: TOKEN, ...overrides };
  const lines = [];
  const service = createService({ config, store: store || createMemoryStore(config), log: (l) => lines.push(l) });
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
  try { await fn(call, lines); } finally { await new Promise((resolve) => server.close(resolve)); }
}

const put = (call, bond, epoch, claims, auth = `Bearer ${TOKEN}`) => call('PUT', `/claims/${bond}/${epoch}`, { body: { claims }, auth });

test('default off: every claim route is 404, health says disabled', async () => {
  await withService({ enabled: false }, async (call) => {
    assert.equal((await call('GET', `/claims/${BOND}/40`)).status, 404);
    assert.equal((await put(call, BOND, 40, [claim(1)])).body.error.code, 'MAILBOX_DISABLED');
    assert.equal((await call('GET', '/claims/not-hex/40')).body.error.code, 'MAILBOX_DISABLED');
    const health = await call('GET', '/health');
    assert.deepEqual(health.body, { ok: true, enabled: false, writable: true });
  });
});

test('a written claim is read back in the shape `wrfcoin node receipt auto` reads', async () => {
  await withService({}, async (call, lines) => {
    assert.equal((await call('GET', `/claims/${BOND}/40`)).status, 404);
    const stored = await put(call, BOND, 40, [claim(2), claim(1)]);
    assert.equal(stored.status, 200);
    assert.equal(stored.body.data.count, 2);
    const read = await call('GET', `/claims/${BOND}/40`);
    assert.equal(read.status, 200);
    // Sorted by receipt id; exactly the fields the CLI stages.
    assert.deepEqual(read.body, { deployment_id: BOND, epoch: '40', claims: [claim(1), claim(2)] });
    // Other bonds and epochs are separate.
    assert.equal((await call('GET', `/claims/${OTHER}/40`)).status, 404);
    assert.equal((await call('GET', `/claims/${BOND}/41`)).status, 404);
    assert.deepEqual(lines, [`[claim-mailbox] decision=STORED deployment=${BOND.slice(0, 8)} epoch=40 count=2`]);
  });
});

test('writes merge by receipt id and stop at 8 claims, all or nothing', async () => {
  await withService({}, async (call) => {
    const first = Array.from({ length: 6 }, (_, i) => claim(i + 1));
    assert.equal((await put(call, BOND, 40, first)).body.data.count, 6);
    // Same ids again (a retry, or a newer copy) do not add slots.
    assert.equal((await put(call, BOND, 40, [claim(1, 'beef'), claim(7)])).body.data.count, 7);
    // Two new ids would make 9: refused, and nothing from it is stored.
    const over = await put(call, BOND, 40, [claim(8), claim(9)]);
    assert.equal(over.status, 409);
    assert.equal(over.body.error.code, 'TOO_MANY_CLAIMS');
    const read = (await call('GET', `/claims/${BOND}/40`)).body.claims;
    assert.equal(read.length, 7);
    assert.equal(read.find((c) => c.receipt_id === rid(1)).claim_hex, 'beef');
    assert.equal((await put(call, BOND, 40, [claim(8)])).body.data.count, MAX_CLAIMS);
  });
});

test('writing needs the bearer; reading never does', async () => {
  await withService({}, async (call) => {
    assert.equal((await put(call, BOND, 40, [claim(1)], null)).status, 401);
    assert.equal((await put(call, BOND, 40, [claim(1)], 'Bearer wrong-token-wrong-token-wrong-token')).status, 401);
    assert.equal((await put(call, BOND, 40, [claim(1)], TOKEN)).status, 401); // no "Bearer " scheme
    assert.equal((await call('GET', `/claims/${BOND}/40`)).status, 404);
    assert.equal((await put(call, BOND, 40, [claim(1)])).status, 200);
    assert.equal((await call('GET', `/claims/${BOND}/40`)).status, 200);
  });
  // Enabled with no (or a short) token: writes are refused, reads still work.
  for (const writeToken of ['', 'short']) {
    await withService({ writeToken }, async (call) => {
      const r = await put(call, BOND, 40, [claim(1)], `Bearer ${writeToken}`);
      assert.equal(r.status, 503);
      assert.equal(r.body.error.code, 'MAILBOX_NOT_WRITABLE');
      assert.equal((await call('GET', `/claims/${BOND}/40`)).status, 404);
    });
  }
});

test('bad routes and bodies are refused', async () => {
  await withService({}, async (call) => {
    for (const path of [`/claims/${BOND.toUpperCase()}/40`, `/claims/${BOND.slice(2)}/40`, `/claims/${BOND}/040`, `/claims/${BOND}/-1`, `/claims/${BOND}/1e3`]) {
      assert.equal((await call('GET', path)).body.error.code, 'INVALID_CLAIM_ROUTE', path);
    }
    assert.equal((await call('GET', `/claims/${BOND}/40/x`)).status, 404);
    assert.equal((await call('DELETE', `/claims/${BOND}/40`)).status, 405);
    const bad = [
      {}, { claims: [] }, { claims: 'x' },
      { claims: Array.from({ length: MAX_CLAIMS + 1 }, (_, i) => claim(i + 1)) },
      { claims: [{ claim_hex: 'abc', receipt_id: rid(1) }] }, // odd length
      { claims: [{ claim_hex: 'ABCD', receipt_id: rid(1) }] }, // upper case
      { claims: [{ claim_hex: 'ab'.repeat(1537), receipt_id: rid(1) }] }, // over 1536 bytes
      { claims: [{ claim_hex: 'abcd', receipt_id: '../../etc' }] },
      { claims: [claim(1), claim(1)] },
      { claims: [null] },
    ];
    for (const body of bad) {
      const r = await call('PUT', `/claims/${BOND}/40`, { body, auth: `Bearer ${TOKEN}` });
      assert.equal(r.status, 400, JSON.stringify(body).slice(0, 80));
      assert.equal(r.body.error.code, 'INVALID_CLAIMS');
    }
    const notJson = await call('PUT', `/claims/${BOND}/40`, { raw: '{', auth: `Bearer ${TOKEN}` });
    assert.equal(notJson.status, 400);
    const huge = await call('PUT', `/claims/${BOND}/40`, { raw: JSON.stringify({ claims: [], pad: 'x'.repeat(70 * 1024) }), auth: `Bearer ${TOKEN}` }).catch(() => ({ status: 413 }));
    assert.equal(huge.status, 413);
    assert.equal((await call('GET', `/claims/${BOND}/40`)).status, 404);
  });
});

test('claims expire after the TTL', async () => {
  let now = 1_000_000;
  const config = { ...loadConfig({}), ttlSeconds: 3600 };
  const store = createMemoryStore(config);
  store.setClock(() => now);
  await withService({ ttlSeconds: 3600 }, async (call) => {
    await put(call, BOND, 40, [claim(1)]);
    now += 3599 * 1000;
    assert.equal((await call('GET', `/claims/${BOND}/40`)).status, 200);
    now += 2 * 1000;
    assert.equal((await call('GET', `/claims/${BOND}/40`)).status, 404);
  }, store);
});

test('config: defaults, strict numbers', () => {
  const c = loadConfig({});
  assert.equal(c.enabled, false);
  assert.equal(c.port, 8095);
  assert.equal(c.ttlSeconds, 129600);
  assert.equal(loadConfig({ CLAIM_MAILBOX_ENABLED: 'yes' }).enabled, false);
  assert.equal(loadConfig({ CLAIM_MAILBOX_TTL_SECONDS: '60' }).ttlSeconds, 129600); // under the 1 h floor
  assert.equal(loadConfig({ CLAIM_MAILBOX_TTL_SECONDS: '7200' }).ttlSeconds, 7200);
  assert.equal(parseRoute('/health'), null);
});

test('redis store: the same merge, cap and expiry through the real Lua', { skip: !process.env.CLAIM_MAILBOX_TEST_REDIS_URL }, async () => {
  const { createClient } = require('redis');
  const client = createClient({ url: process.env.CLAIM_MAILBOX_TEST_REDIS_URL });
  await client.connect();
  const prefix = `claim-mailbox-test-${process.pid}:`;
  try {
    const store = createRedisStore(client, { prefix, ttlSeconds: 3600 });
    assert.deepEqual(await store.get(BOND, '40'), []);
    assert.deepEqual(await store.put(BOND, '40', Array.from({ length: 7 }, (_, i) => claim(i + 1))), { ok: true, count: 7 });
    assert.deepEqual(await store.put(BOND, '40', [claim(1, 'beef'), claim(8), claim(9)]), { ok: false, code: 'TOO_MANY_CLAIMS', count: 7 });
    assert.equal((await store.get(BOND, '40')).find((c) => c.receipt_id === rid(1)).claim_hex, claim(1).claim_hex);
    assert.deepEqual(await store.put(BOND, '40', [claim(8)]), { ok: true, count: 8 });
    const ttl = await client.ttl(`${prefix}claims:${BOND}:40`);
    assert.ok(ttl > 3500 && ttl <= 3600, String(ttl));
  } finally {
    for (const key of await client.keys(`${prefix}*`)) await client.del(key);
    await client.quit();
  }
});
