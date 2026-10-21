'use strict';

// End-to-end daily caps and cooldown through the real /faucet/request handler
// (W18 W16): per-device and per-wallet caps hold independently, the cooldown
// expires, every 429 carries Retry-After, the wallet/device refusal is one
// fixed message that names no other wallet, and (with a real Redis) the
// counters survive a faucet restart.
//
// Each scenario runs in a child process so the server reads its env at load.
// Redis is an in-memory stand-in by default. Set FAUCET_TEST_REDIS_URL to a
// throwaway local Redis (e.g. `docker run --rm -d --name <unique> -p
// 127.0.0.1:<port>:6379 redis:7-alpine`) to run the same scenarios against
// real Redis, including its Lua reservation script and the restart case.
// The node is a local mock; nothing leaves the machine.

const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');

const REAL_REDIS_URL = process.env.FAUCET_TEST_REDIS_URL || '';

// Child-side harness: a mock node, the Redis client (real or stand-in), and a
// claim helper that goes through the trusted-proxy path with a chosen device.
const HARNESS = String.raw`
const http = require('node:http');
// The mock node's answer to a transfer submit (infra#1157 review controls):
//   ok                 accept, with a receipt
//   accept-then-reset  accept, then drop the connection before answering
//   accept-no-receipt  accept, answer 200 without a transaction id
//   server-error       answer 503 (outcome unknown to the faucet)
//   reject             answer 400 with core4's error envelope (not admitted)
//   accept-then-redirect-refused  accept, then 307 to a closed port
//   accept-then-redirect-400      accept, then 307 to a hop that answers 400
//   contradictory-400  accept, then 400 whose body also carries a tx_id
let submitMode = 'ok';
let acceptedSubmits = 0;
let attemptedSubmits = 0;
let accountReads = 0;
let nodeNonce = 7n;
const accountNonces = new Map();
let nonceReadMode = 'ok';
let heldSubmit = null;
function setNodeNonce(n) { nodeNonce = BigInt(n); }
function setAccountNonce(address, n) { accountNonces.set(address, BigInt(n)); }
function setNonceReadMode(m) { nonceReadMode = m; }
function finishHeldSubmit() { heldSubmit(); }
let redirectHops = 0;
let closedPort = 0;
// core4 65134a64 launch_api envelope_error.
const coreError = (code, message, data = null) => JSON.stringify({
  ok: false,
  data,
  error: { code, message },
  meta: { request_id: 'req_mock', timestamp: '2026-10-01T00:00:00Z', api_version: 'v1' },
});
function setSubmitMode(mode) { submitMode = mode; }
async function startMockNode() {
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      res.setHeader('content-type', 'application/json');
      const accountPrefix = process.env.FAUCET_WALLET_BALANCE_PATH?.split('{address}')[0] || '/addresses/';
      if (req.method === 'GET' && req.url.startsWith(accountPrefix)) {
        accountReads += 1;
        if (nonceReadMode === 'denied') { res.statusCode = 403; res.end(coreError('FORBIDDEN', 'Reader required')); return; }
        if (nonceReadMode === 'oversize') { res.end(' '.repeat(65537)); return; }
        if (nonceReadMode === 'bad-json') { res.end('{oops'); return; }
        if (nonceReadMode === 'redirect') { res.statusCode = 307; res.setHeader('location', '/redirected-hop'); res.end(); return; }
        const accountNonce = accountNonces.get(req.url.slice(accountPrefix.length)) ?? nodeNonce;
        const nonce = nonceReadMode === 'missing' ? undefined : nonceReadMode === 'unsafe' ? 9007199254740992 : nonceReadMode === 'overflow' ? '18446744073709551615' : nonceReadMode === 'malformed' ? '7oops' : accountNonce.toString();
        const data = { address: nonceReadMode === 'wrong-account' ? '0x' + 'c'.repeat(40) : req.url.slice(accountPrefix.length), balance: '100000000000000', spendable_balance: '100000000000000', nonce };
        res.end(JSON.stringify({ ok: true, data }));
        return;
      }
      if (req.url === '/redirected-hop') {
        redirectHops += 1;
        res.statusCode = 400;
        res.end(coreError('VALIDATION_ERROR', 'from, to, and positive amount are required'));
        return;
      }
      if (req.method === 'POST' && req.url === '/transactions/submit') {
        attemptedSubmits += 1;
        const transfer = JSON.parse(body);
        const expectedNonce = accountNonces.get(transfer.from) ?? nodeNonce;
        if (transfer.nonce !== expectedNonce.toString()) {
          res.statusCode = 400;
          res.end(coreError('TRANSACTION_REJECTED', 'Invalid nonce'));
          return;
        }
        if (submitMode === 'hold') {
          nodeNonce += 1n; acceptedSubmits += 1;
          heldSubmit = () => { res.end(JSON.stringify({ data: { accepted: true, tx_id: '0x' + 'ab'.repeat(32) } })); };
          return;
        }
        if (submitMode === 'stale-conflict') {
          res.statusCode = 400; res.end(coreError('TRANSACTION_REJECTED', 'Invalid nonce')); return;
        }
        if (submitMode === 'reject') {
          res.statusCode = 400;
          res.end(coreError('TRANSACTION_REJECTED', 'insufficient spendable balance'));
          return;
        }
        acceptedSubmits += 1;
        if (submitMode !== 'accept-unmined' && submitMode !== 'server-error') {
          if (accountNonces.has(transfer.from)) accountNonces.set(transfer.from, expectedNonce + 1n);
          else nodeNonce += 1n;
        }
        if (submitMode === 'accept-then-redirect-refused') {
          res.statusCode = 307;
          res.setHeader('location', 'http://127.0.0.1:' + closedPort + '/transactions/submit');
          res.end();
          return;
        }
        if (submitMode === 'accept-then-redirect-400') {
          res.statusCode = 307;
          res.setHeader('location', '/redirected-hop');
          res.end();
          return;
        }
        if (submitMode === 'contradictory-400') {
          res.statusCode = 400;
          res.end(coreError('VALIDATION_ERROR', 'rejected', { accepted: true, tx_id: '0x' + 'cd'.repeat(32) }));
          return;
        }
        if (submitMode === 'accept-then-reset') {
          req.socket.destroy();
          return;
        }
        if (submitMode === 'accept-no-receipt') {
          res.end(JSON.stringify({ data: { accepted: true } }));
          return;
        }
        if (submitMode === 'server-error') {
          res.statusCode = 503;
          res.end('{}');
          return;
        }
        res.end(JSON.stringify({ data: { accepted: true, tx_id: '0x' + 'ab'.repeat(32) } }));
        return;
      }
      res.statusCode = 404;
      res.end('{}');
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return server;
}

// In-memory stand-in for the four Redis calls the handler makes. The eval
// mirrors reserveDailyCap's Lua script.
function memoryRedis() {
  const store = new Map();
  const live = (key) => {
    const entry = store.get(key);
    if (entry && entry.expiresAt !== null && entry.expiresAt <= Date.now()) {
      store.delete(key);
      return undefined;
    }
    return entry;
  };
  return {
    async set(key, value, opts = {}) {
      if (opts.NX && live(key)) return null;
      store.set(key, { value: String(value), expiresAt: opts.EX ? Date.now() + opts.EX * 1000 : null });
      return 'OK';
    },
    async ttl(key) {
      const entry = live(key);
      if (!entry) return -2;
      return entry.expiresAt === null ? -1 : Math.ceil((entry.expiresAt - Date.now()) / 1000);
    },
    async del(key) { store.delete(key); return 1; },
    async get(key) { const entry = live(key); return entry ? entry.value : null; },
    async keys(pattern) {
      const prefix = pattern.replace(/\*$/, '');
      return [...store.keys()].filter((key) => key.startsWith(prefix) && live(key));
    },
    async decrBy(key, amount) {
      const entry = live(key);
      const next = Number(entry ? entry.value : 0) - Number(amount);
      store.set(key, { value: String(next), expiresAt: entry ? entry.expiresAt : null });
      return next;
    },
    async eval(_script, { keys, arguments: args }) {
      if (_script.includes('-- faucet-nonce-reserve')) {
        const entry = live(keys[0]);
        if (entry && BigInt(entry.value.split(':')[0]) >= BigInt(args[0])) return 0;
        store.set(keys[0], { value: args[1] || args[0], expiresAt: null }); return 1;
      }
      if (_script.includes('-- faucet-nonce-release')) {
        const entry = live(keys[0]);
        if (entry?.value !== args[0]) return 0;
        store.delete(keys[0]); return 1;
      }
      const [key] = keys;
      const [amount, cap, ttl] = args.map(Number);
      const entry = live(key);
      const current = Number(entry ? entry.value : 0);
      if (current + amount > cap) return [0, current];
      const next = current + amount;
      store.set(key, { value: String(next), expiresAt: entry ? entry.expiresAt : Date.now() + ttl * 1000 });
      return [1, next];
    },
  };
}

async function boot() {
  // A port with nothing listening: the redirect target that refuses.
  const probe = http.createServer();
  await new Promise((resolve) => probe.listen(0, '127.0.0.1', resolve));
  closedPort = probe.address().port;
  await new Promise((resolve) => probe.close(resolve));
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
  let releaseAttempts = 0;
  function releaseFaults(count, replaceAfterDelete = false, neverReply = false) {
    const client = Object.create(reader);
    client.eval = async (script, options) => {
      if (script.includes('-- faucet-nonce-release')) {
        releaseAttempts += 1;
        if (count-- > 0) {
          if (neverReply) return new Promise(() => {});
          if (replaceAfterDelete) {
            await reader.eval(script, options);
            await reader.set(options.keys[0], '7:another-owner');
          }
          throw new Error('synthetic release transport failure');
        }
      }
      return reader.eval(script, options);
    };
    for (const method of ['set', 'get', 'del', 'ttl', 'decrBy']) client[method] = reader[method].bind(reader);
    server.setRedisClientForTests(client);
  }
  // Every daily counter, cooldown and pending record this run wrote, by kind.
  async function state() {
    const kinds = {
      wallet: process.env.FAUCET_WALLET_DAILY_PREFIX,
      device: process.env.FAUCET_DEVICE_DAILY_PREFIX,
      global: process.env.FAUCET_GLOBAL_DAILY_PREFIX,
      cooldown: process.env.FAUCET_RATE_LIMIT_PREFIX,
      pending: process.env.FAUCET_PENDING_PREFIX,
      nonceFence: process.env.FAUCET_GLOBAL_DAILY_PREFIX + 'nonce:',
    };
    const out = { acceptedSubmits, attemptedSubmits, accountReads, redirectHops, releaseAttempts };
    for (const [kind, prefix] of Object.entries(kinds)) {
      const keys = (await reader.keys(prefix + '*')).filter(key => kind !== 'global' || !key.startsWith(prefix + 'nonce:')).sort();
      out[kind] = [];
      for (const key of keys) out[kind].push(await reader.get(key));
    }
    return out;
  }
  const http_ = server.app.listen(0, '127.0.0.1');
  await new Promise((resolve) => http_.once('listening', resolve));
  const url = 'http://127.0.0.1:' + http_.address().port + '/faucet/request';
  async function claim(device, wallet) {
    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: 'Bearer operator-token',
        'x-client-ip': device,
      },
      body: JSON.stringify({ walletAddress: wallet }),
    });
    const text = await response.text();
    return {
      status: response.status,
      retryAfter: response.headers.get('retry-after'),
      code: response.status === 200 ? 'OK' : JSON.parse(text).error.code,
      text,
    };
  }
  async function close() {
    if (process.env.REDIS_URL) await reader.quit();
    await new Promise((resolve) => http_.close(resolve));
    node.close();
    process.exit(0);
  }
  return { claim, close, state, releaseFaults, reader, server, reload: () => server.setRedisClientForTests(reader), amount: server.toBaseUnits('10') };
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
`;

function runScenario(body, extraEnv = {}) {
  const script = `${HARNESS}
(async () => {
  const { claim, close, state, releaseFaults, reader, server, reload, amount } = await boot();
  const out = {};
  ${body}
  process.stdout.write(JSON.stringify(out));
  await close();
})().catch((error) => { console.error(error); process.exit(1); });`;
  const env = {
    ...process.env,
    CAPTCHA_PROVIDER: 'off',
    FAUCET_API_TOKEN: 'operator-token',
    // Obviously fake signing key and faucet address; the node is a local mock.
    FAUCET_WALLET_PRIVKEY: '11'.repeat(32),
    FAUCET_WALLET_ADDRESS: '0x' + 'b'.repeat(40),
    FAUCET_HIGH_WATER_MARK: '0',
    FAUCET_AMOUNT: '10',
    FAUCET_WALLET_DAILY_CAP: '10',
    FAUCET_DEVICE_DAILY_CAP: '10',
    FAUCET_GLOBAL_DAILY_CAP: '1000',
    FAUCET_WALLET_BALANCE_FLOOR: '10',
    FAUCET_RATE_LIMIT_SECONDS: '2',
    REDIS_URL: REAL_REDIS_URL,
    // A fresh key space per run, so a real Redis needs no flush.
    FAUCET_RATE_LIMIT_PREFIX: `t${process.pid}:${Date.now()}:ip:`,
    FAUCET_RATE_LIMIT_TSUSER_PREFIX: `t${process.pid}:${Date.now()}:ts:`,
    FAUCET_WALLET_DAILY_PREFIX: `t${process.pid}:${Date.now()}:wallet:`,
    FAUCET_GLOBAL_DAILY_PREFIX: `t${process.pid}:${Date.now()}:global:`,
    FAUCET_DEVICE_DAILY_PREFIX: `t${process.pid}:${Date.now()}:device:`,
    FAUCET_PENDING_PREFIX: `t${process.pid}:${Date.now()}:pending:`,
    ...extraEnv,
  };
  return JSON.parse(execFileSync(process.execPath, ['-e', script], { cwd: __dirname, env, encoding: 'utf8', timeout: 20000 }));
}

const W = (n) => '0x' + String(n).repeat(40).slice(0, 40);
// Seconds to the next 00:00:00Z from the calendar (minimum 1), as the faucet computes it.
const untilUtcMidnight = () => {
  const now = new Date();
  return Math.max(1, Math.ceil((Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1) - now.getTime()) / 1000));
};
const nearCalendar = (value) => Math.abs(Number(value) - untilUtcMidnight()) <= 5;

test('device and wallet daily caps hold independently; the cooldown expires; 429s carry Retry-After', () => {
  const out = runScenario(`
    out.first = await claim('203.0.113.1', '${W(1)}');
    out.cooldown = await claim('203.0.113.1', '${W(2)}');
    await sleep(2300);
    out.deviceCap = await claim('203.0.113.1', '${W(2)}');
    out.walletCap = await claim('203.0.113.2', '${W(1)}');
    out.walletCapProbeCostsCooldown = await claim('203.0.113.2', '${W(3)}');
    out.otherDeviceOtherWallet = await claim('203.0.113.3', '${W(4)}');
  `);

  assert.equal(out.first.status, 200, out.first.text);

  // Cooldown: same device, any wallet, inside the window.
  assert.equal(out.cooldown.status, 429);
  assert.equal(out.cooldown.code, 'RATE_LIMITED');
  assert.ok(Number(out.cooldown.retryAfter) >= 1 && Number(out.cooldown.retryAfter) <= 2, out.cooldown.retryAfter);

  // After the cooldown expires the device is still at its daily cap, even for
  // a fresh wallet (the device cap is independent of the wallet cap).
  assert.equal(out.deviceCap.status, 429, out.deviceCap.text);
  assert.equal(out.deviceCap.code, 'DAILY_LIMIT_REACHED');
  assert.ok(nearCalendar(out.deviceCap.retryAfter), out.deviceCap.retryAfter);

  // A fresh device cannot draw a wallet that is at its daily cap.
  assert.equal(out.walletCap.status, 429, out.walletCap.text);
  assert.equal(out.walletCap.code, 'DAILY_LIMIT_REACHED');
  assert.ok(nearCalendar(out.walletCap.retryAfter), out.walletCap.retryAfter);

  // The two refusals are byte-identical bodies: nothing says which cap, and
  // nothing names another wallet or a spend figure.
  assert.equal(out.deviceCap.text, out.walletCap.text);
  for (const refusal of [out.deviceCap, out.walletCap, out.cooldown]) {
    assert.doesNotMatch(refusal.text, /0x1{40}|0x2{40}|current|spent|balance/i);
  }

  // Probing another wallet's cap spends the probing device's cooldown.
  assert.equal(out.walletCapProbeCostsCooldown.code, 'RATE_LIMITED');

  // Neither cap touches an unrelated device and wallet.
  assert.equal(out.otherDeviceOtherWallet.status, 200, out.otherDeviceOtherWallet.text);
});

test('a raised device cap allows a second payout per device; the wallet cap still binds', () => {
  const out = runScenario(`
    out.a = await claim('198.51.100.7', '${W(5)}');
    await sleep(2300);
    out.b = await claim('198.51.100.7', '${W(6)}');
    await sleep(2300);
    out.c = await claim('198.51.100.7', '${W(7)}');
    out.sameWallet = await claim('198.51.100.8', '${W(5)}');
  `, { FAUCET_DEVICE_DAILY_CAP: '20' });
  assert.equal(out.a.status, 200, out.a.text);
  assert.equal(out.b.status, 200, out.b.text);
  assert.equal(out.c.code, 'DAILY_LIMIT_REACHED');
  assert.equal(out.sameWallet.code, 'DAILY_LIMIT_REACHED');
});

test('daily counters survive a faucet restart (real Redis only)', { skip: REAL_REDIS_URL ? false : 'set FAUCET_TEST_REDIS_URL to a throwaway local Redis' }, () => {
  const prefixes = {
    FAUCET_RATE_LIMIT_PREFIX: `r${process.pid}:${Date.now()}:ip:`,
    FAUCET_RATE_LIMIT_TSUSER_PREFIX: `r${process.pid}:${Date.now()}:ts:`,
    FAUCET_WALLET_DAILY_PREFIX: `r${process.pid}:${Date.now()}:wallet:`,
    FAUCET_GLOBAL_DAILY_PREFIX: `r${process.pid}:${Date.now()}:global:`,
    FAUCET_DEVICE_DAILY_PREFIX: `r${process.pid}:${Date.now()}:device:`,
  };
  const before = runScenario(`out.claim = await claim('192.0.2.9', '${W(8)}');`, prefixes);
  assert.equal(before.claim.status, 200, before.claim.text);
  // A new process, the same Redis: the cooldown and both caps are still spent.
  const after = runScenario(`
    out.cooldown = await claim('192.0.2.9', '${W(9)}');
    await sleep(2300);
    out.device = await claim('192.0.2.9', '${W(9)}');
    out.wallet = await claim('192.0.2.10', '${W(8)}');
  `, prefixes);
  assert.equal(after.cooldown.code, 'RATE_LIMITED');
  assert.equal(after.device.code, 'DAILY_LIMIT_REACHED');
  assert.equal(after.wallet.code, 'DAILY_LIMIT_REACHED');
});

// infra#1157 review: once the transfer request has left, only a definitive
// rejection may release the claim's reservations. An unknown outcome keeps the
// cooldown and every daily reservation, so a retry can never pay twice.
for (const [mode, reason] of [
  ['accept-then-reset', 'no_response'],
  ['accept-no-receipt', 'no_receipt'],
  ['server-error', 'http_503'],
  // infra#1157 review r2: redirects are never followed, and a contradictory
  // 4xx body is not a rejection.
  ['accept-then-redirect-refused', 'redirect_307'],
  ['accept-then-redirect-400', 'redirect_307'],
  ['contradictory-400', 'http_400'],
]) {
  test(`${mode}: claim pending, reservations kept, a second claim is refused`, () => {
    const out = runScenario(`
      setSubmitMode('${mode}');
      out.first = await claim('203.0.113.21', '${W(1)}');
      out.afterFirst = await state();
      setSubmitMode('ok');
      out.retrySameDevice = await claim('203.0.113.21', '${W(1)}');
      await sleep(2300);
      out.retryAfterCooldown = await claim('203.0.113.21', '${W(1)}');
      out.otherDeviceSameWallet = await claim('203.0.113.22', '${W(1)}');
      out.end = await state();
      out.amount = amount;
    `);
    assert.equal(out.first.status, 409, out.first.text);
    assert.equal(out.first.code, 'CLAIM_PENDING');
    assert.match(out.first.text, /Do not retry/);
    // A fixed answer: no node error text, no transfer details.
    assert.doesNotMatch(out.first.text, /\breset\b|socket|503|transaction id|nonce/i);
    const retryAfter = Number(out.first.retryAfter);
    assert.ok(retryAfter >= 1 && retryAfter <= 86400, out.first.retryAfter);

    // The accepted amount stays on every counter; the claim is recorded.
    const amount = String(out.amount);
    assert.equal(out.afterFirst.acceptedSubmits, 1);
    assert.deepEqual(out.afterFirst.wallet, [amount]);
    assert.deepEqual(out.afterFirst.device, [amount]);
    assert.deepEqual(out.afterFirst.global, [amount]);
    assert.equal(out.afterFirst.cooldown.length, 1);
    assert.equal(out.afterFirst.pending.length, 1);
    const pending = JSON.parse(out.afterFirst.pending[0]);
    assert.equal(pending.reason, reason);
    assert.equal(pending.walletAddress, W(1));
    assert.ok(pending.nonce);

    // Every retry is refused, and nothing more is paid.
    assert.equal(out.retrySameDevice.code, 'RATE_LIMITED');
    assert.equal(out.retryAfterCooldown.code, 'DAILY_LIMIT_REACHED');
    assert.equal(out.otherDeviceSameWallet.code, 'DAILY_LIMIT_REACHED');
    assert.equal(out.end.acceptedSubmits, 1);
    assert.equal(out.end.redirectHops, 0);
    assert.deepEqual(out.end.wallet, [amount]);
    // The claiming device keeps the amount; the other device's refused probe rolled back to 0.
    assert.deepEqual([...out.end.device].sort(), ['0', amount].sort());
    assert.deepEqual(out.end.global, [amount]);
    // Retry-After: the calendar wait to the next UTC day, or the retained
    // cooldown if that is longer (here the 2 s test cooldown is shorter).
    assert.ok(nearCalendar(retryAfter), `${retryAfter} vs ${untilUtcMidnight()}`);
  });
}

test('a definitive rejection (4xx with a rejection body) releases everything, as before', () => {
  const out = runScenario(`
    setSubmitMode('reject');
    out.first = await claim('203.0.113.31', '${W(2)}');
    out.afterFirst = await state();
    setSubmitMode('ok');
    out.retry = await claim('203.0.113.31', '${W(2)}');
    out.end = await state();
    out.amount = amount;
  `);
  assert.equal(out.first.status, 502, out.first.text);
  assert.equal(out.first.code, 'FAUCET_TRANSFER_FAILED');
  assert.equal(out.afterFirst.acceptedSubmits, 0);
  for (const kind of ['wallet', 'device', 'global']) {
    assert.ok(out.afterFirst[kind].every((value) => Number(value) === 0), `${kind}: ${out.afterFirst[kind]}`);
  }
  assert.equal(out.afterFirst.cooldown.length, 0);
  assert.equal(out.afterFirst.pending.length, 0);
  // The same device and wallet may claim at once, and are paid exactly once.
  assert.equal(out.retry.status, 200, out.retry.text);
  assert.equal(out.end.acceptedSubmits, 1);
  assert.deepEqual(out.end.wallet, [String(out.amount)]);
});

test('a retained cooldown longer than the UTC day sets Retry-After (the max of the two)', () => {
  // 200000 s is longer than any wait to midnight.
  const out = runScenario(`
    out.first = await claim('203.0.113.51', '${W(1)}');
    out.walletCap = await claim('203.0.113.52', '${W(1)}');
    setSubmitMode('accept-then-reset');
    out.pending = await claim('203.0.113.53', '${W(2)}');
  `, { FAUCET_RATE_LIMIT_SECONDS: '200000' });
  assert.equal(out.first.status, 200, out.first.text);
  assert.equal(out.walletCap.code, 'DAILY_LIMIT_REACHED');
  assert.equal(out.pending.code, 'CLAIM_PENDING');
  for (const refusal of [out.walletCap, out.pending]) {
    const value = Number(refusal.retryAfter);
    assert.ok(value > 86400 && value <= 200000, refusal.retryAfter);
  }
});

// Exact account nonce gate: the node double rejects the former clock nonce.
test('authoritative nonce succeeds, zero and large u64 strings are signed exactly', () => {
  const out = runScenario(`
    out.first = await claim('192.0.2.31', '${W(1)}');
    setNodeNonce('9007199254740993');
    out.large = await claim('192.0.2.32', '${W(2)}');
    out.end = await state();
  `);
  assert.equal(out.first.status, 200, out.first.text);
  assert.equal(out.large.status, 200, out.large.text);
  assert.equal(out.end.attemptedSubmits, 2);
  assert.equal(out.end.acceptedSubmits, 2);
  const zero = runScenario(`setNodeNonce('0'); out.zero = await claim('192.0.2.33', '${W(3)}');`);
  assert.equal(zero.zero.status, 200, zero.zero.text);
});

test('one in-flight transfer: another caller is refused without a second POST', () => {
  const out = runScenario(`
    setSubmitMode('hold');
    const first = claim('192.0.2.41', '${W(1)}');
    for (let i=0; i<200 && !heldSubmit; i++) await sleep(5);
    if (!heldSubmit) throw new Error('first transfer never reached node');
    setSubmitMode('ok');
    out.other = await claim('192.0.2.42', '${W(2)}');
    out.during = await state();
    finishHeldSubmit(); out.first = await first;
    setSubmitMode('ok'); out.after = await claim('192.0.2.42', '${W(2)}');
  `);
  assert.equal(out.other.status, 503, out.other.text);
  assert.equal(out.other.code, 'FAUCET_TRANSFER_BUSY');
  assert.equal(out.during.attemptedSubmits, 1);
  assert.equal(out.first.status, 200);
  assert.equal(out.after.status, 200, out.after.text);
});

test('unmined acceptance and unknown outcome retain nonce fence for other wallets', () => {
  for (const mode of ['accept-unmined', 'server-error']) {
    const out = runScenario(`
      setSubmitMode('${mode}'); out.first = await claim('192.0.2.51', '${W(1)}');
      reload(); setSubmitMode('ok'); out.other = await claim('192.0.2.52', '${W(2)}');
      out.blocked = await state(); setNodeNonce('8');
      out.advanced = await claim('192.0.2.52', '${W(2)}');
    `);
    assert.equal(out.first.status, mode === 'accept-unmined' ? 200 : 409, out.first.text);
    assert.equal(out.other.status, 503, out.other.text);
    assert.equal(out.blocked.attemptedSubmits, 1);
    assert.equal(out.blocked.nonceFence.length, 1);
    assert.equal(out.blocked.nonceFence[0].split(':')[0], '7');
    assert.equal(out.advanced.status, 200, out.advanced.text);
  }
});

test('nonce-conflict rejection is definitive and never retried automatically', () => {
  const out = runScenario(`
    setSubmitMode('stale-conflict'); out.first = await claim('192.0.2.61', '${W(1)}'); out.rejected = await state();
    setSubmitMode('ok'); out.retry = await claim('192.0.2.61', '${W(1)}'); out.end = await state();
  `);
  assert.equal(out.first.status, 502, out.first.text);
  assert.equal(out.rejected.attemptedSubmits, 1);
  assert.deepEqual(out.rejected.wallet, ['0']);
  assert.deepEqual(out.rejected.device, ['0']);
  assert.deepEqual(out.rejected.pending, []);
  assert.equal(out.retry.status, 200, out.retry.text);
  assert.equal(out.end.attemptedSubmits, 2);
});

for (const mode of ['missing', 'unsafe', 'overflow', 'malformed', 'wrong-account', 'denied', 'redirect', 'oversize', 'bad-json']) {
  test(`nonce ${mode}: no submit, no reservations retained`, () => {
    const out = runScenario(`
      setNonceReadMode('${mode}'); out.refusal = await claim('192.0.2.71', '${W(1)}'); out.end = await state();
      setNonceReadMode('ok'); out.next = await claim('192.0.2.71', '${W(1)}');
    `);
    assert.equal(out.refusal.status, 503, out.refusal.text);
    assert.equal(out.refusal.code, 'FAUCET_WALLET_NONCE_UNAVAILABLE');
    assert.equal(out.end.attemptedSubmits, 0);
    assert.equal(out.end.accountReads, 1);
    assert.equal(out.end.redirectHops, 0);
    assert.deepEqual(out.end.pending, []);
    assert.equal(out.next.status, 200, out.next.text);
  });
}

if (REAL_REDIS_URL) {
  test('durable nonce fence survives a fresh faucet process on real Redis', () => {
    const prefix = `nonce-restart:${process.pid}:${Date.now()}:global:`;
    const before = runScenario(`setSubmitMode('accept-unmined'); out.claim = await claim('192.0.2.81', '${W(1)}');`, { FAUCET_GLOBAL_DAILY_PREFIX: prefix });
    assert.equal(before.claim.status, 200, before.claim.text);
    const after = runScenario(`
      out.blocked = await claim('192.0.2.82', '${W(2)}'); out.state = await state();
      setNodeNonce('8'); out.advanced = await claim('192.0.2.82', '${W(2)}');
    `, { FAUCET_GLOBAL_DAILY_PREFIX: prefix });
    assert.equal(after.blocked.status, 503, after.blocked.text);
    assert.equal(after.state.attemptedSubmits, 0);
    assert.equal(after.advanced.status, 200, after.advanced.text);
  });
}

test('configured account path supplies the signed nonce', () => {
  const out = runScenario(`out.claim = await claim('192.0.2.91', '${W(1)}'); out.end = await state();`, {
    FAUCET_WALLET_BALANCE_PATH: '/reader/account/{address}',
  });
  assert.equal(out.claim.status, 200, out.claim.text);
  assert.equal(out.end.accountReads, 1);
  assert.equal(out.end.attemptedSubmits, 1);
});

test('documented funding command reads the source account nonce before signing', () => {
  const out = runScenario(String.raw`
    const fs = require('node:fs');
    const doc = fs.readFileSync('./DEPLOY.md', 'utf8');
    const section = doc.split('**(a) Signed transparent transfer')[1].split('**(b) Genesis')[0];
    const block = section.match(/\x60\x60\x60javascript\n([\s\S]*?)\n\x60\x60\x60/);
    const old = section.match(/const f = require([\s\S]*?)\n  "'/);
    const snippet = block ? block[1] : ('const f = require' + old[1]).replace(/\\"/g, '"').replace('/app/server.js', './server.js');
    process.env.SRC = '${W(9)}'; process.env.DEST = '${W(1)}';
    process.env.SRC_KEY = '11'.repeat(32); process.env.AMOUNT_BASE = '1000000000';
    setAccountNonce(process.env.SRC, '9007199254740993');
    const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
    await new AsyncFunction('require', 'process', 'fetch', 'console', snippet + (block ? '\nawait fundingAttempt;' : ''))(
      require, process, fetch, { log() {}, error() {} });
    out.end = await state();
  `);
  assert.equal(out.end.accountReads, 1);
  assert.equal(out.end.acceptedSubmits, 1);
  assert.equal(out.end.attemptedSubmits, 1);
});

test('definitive rejection retries transient fence cleanup without resubmitting', () => {
  const out = runScenario(`
    releaseFaults(1); setSubmitMode('reject'); out.first = await claim('192.0.2.92', '${W(1)}');
    out.rejected = await state(); setSubmitMode('ok'); out.next = await claim('192.0.2.92', '${W(1)}');
  `);
  assert.equal(out.first.status, 502, out.first.text);
  assert.equal(out.rejected.releaseAttempts, 2);
  assert.equal(out.rejected.attemptedSubmits, 1);
  assert.deepEqual(out.rejected.nonceFence, []);
  assert.equal(out.next.status, 200, out.next.text);
});

test('persistent fence cleanup is surfaced and retried before the next claim', () => {
  const out = runScenario(`
    releaseFaults(6); setSubmitMode('reject'); out.first = await claim('192.0.2.93', '${W(1)}');
    out.rejected = await state(); setSubmitMode('ok'); out.stillDown = await claim('192.0.2.93', '${W(1)}');
    out.down = await state(); reload(); out.recovered = await claim('192.0.2.93', '${W(1)}'); out.end = await state();
  `);
  assert.equal(out.first.status, 503, out.first.text);
  assert.equal(out.first.code, 'FAUCET_NONCE_CLEANUP_PENDING');
  assert.equal(out.rejected.releaseAttempts, 3);
  assert.equal(out.rejected.attemptedSubmits, 1);
  assert.equal(out.stillDown.code, 'FAUCET_NONCE_CLEANUP_PENDING');
  assert.equal(out.down.releaseAttempts, 6);
  assert.equal(out.down.attemptedSubmits, 1);
  assert.equal(out.recovered.status, 200, out.recovered.text);
  assert.equal(out.end.attemptedSubmits, 2);
});

test('fence cleanup response deadlines bound a stalled Redis release', () => {
  const out = runScenario(`
    releaseFaults(3, false, true); setSubmitMode('reject'); const start = Date.now();
    out.first = await claim('192.0.2.98', '${W(1)}'); out.elapsed = Date.now() - start;
    out.rejected = await state(); reload(); setSubmitMode('ok'); out.next = await claim('192.0.2.98', '${W(1)}');
  `);
  assert.equal(out.first.code, 'FAUCET_NONCE_CLEANUP_PENDING');
  assert.equal(out.rejected.releaseAttempts, 3);
  assert.equal(out.rejected.attemptedSubmits, 1);
  assert.ok(out.elapsed >= 2900 && out.elapsed < 6000, String(out.elapsed));
  assert.equal(out.next.status, 200, out.next.text);
});

test('lost cleanup reply cannot delete another ownership token at the same nonce', () => {
  const out = runScenario(`
    releaseFaults(1, true); setSubmitMode('reject'); out.first = await claim('192.0.2.94', '${W(1)}');
    out.rejected = await state(); reload(); setSubmitMode('ok'); out.next = await claim('192.0.2.94', '${W(1)}');
  `);
  assert.equal(out.first.status, 502, out.first.text);
  assert.equal(out.rejected.releaseAttempts, 2);
  assert.deepEqual(out.rejected.nonceFence, ['7:another-owner']);
  assert.equal(out.next.status, 503, out.next.text);
  assert.equal(out.rejected.attemptedSubmits, 1);
});

test('unknown submission never schedules fence release', () => {
  const out = runScenario(`
    releaseFaults(6); setSubmitMode('server-error'); out.first = await claim('192.0.2.95', '${W(1)}');
    out.pending = await state(); setSubmitMode('ok'); out.next = await claim('192.0.2.96', '${W(2)}'); out.end = await state();
  `);
  assert.equal(out.first.code, 'CLAIM_PENDING');
  assert.equal(out.end.releaseAttempts, 0);
  assert.equal(out.end.attemptedSubmits, 1);
  assert.equal(out.next.status, 503, out.next.text);
  assert.equal(out.pending.pending.length, 1);
});

test('numeric fences from the earlier image retain custody until nonce advancement', () => {
  const out = runScenario(`
    await reader.set(process.env.FAUCET_GLOBAL_DAILY_PREFIX + 'nonce:' + process.env.FAUCET_WALLET_ADDRESS, '7');
    out.blocked = await claim('192.0.2.97', '${W(1)}'); setNodeNonce('8');
    out.next = await claim('192.0.2.97', '${W(1)}'); out.end = await state();
  `);
  assert.equal(out.blocked.status, 503, out.blocked.text);
  assert.equal(out.next.status, 200, out.next.text);
  assert.equal(out.end.attemptedSubmits, 1);
});
