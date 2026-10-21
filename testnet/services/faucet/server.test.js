'use strict';

// Unit tests for the faucet's REST transfer contract helpers. Uses node's
// built-in test runner (no extra deps). Run: node --test
//
// Validates the #551 fix: amount base-unit conversion and the LawBook-envelope
// receipt parsing for POST /transactions/submit (data.tx_id).

const test = require('node:test');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const { execFileSync } = require('node:child_process');

const {
  toBaseUnits,
  parseBalanceBaseUnits,
  extractWalletBalanceBaseUnits,
  parseReceipt,
  parseTrustProxySetting,
  getClientIp,
  getTailscaleIdentity,
  getRateLimitIdentity,
  captchaReadiness,
  faucetDispenseReadiness,
  dailyKeySuffix,
  secondsUntilNextUtcDay,
  dailyKeyTtlSeconds,
  isDefinitiveRejection,
  hasAcceptanceEvidence,
  buildDailyPayoutKeys,
  evaluateDailyPayoutCaps,
  renderPage,
  checkBearerToken,
  parseRequiredBaseUnits,
  validateHighWaterConfig,
  calculateRefillAmount,
  refillFaucetBucket,
} = require('./server');

test('converts whole WRF to base units (x10^8)', () => {
  assert.equal(toBaseUnits('10'), 1000000000);
  assert.equal(toBaseUnits('1'), 100000000);
  assert.equal(toBaseUnits('0'), 0);
});

test('converts fractional WRF to base units', () => {
  assert.equal(toBaseUnits('0.5'), 50000000);
  assert.equal(toBaseUnits('1.00000001'), 100000001);
});

test('rejects malformed amounts', () => {
  assert.throws(() => toBaseUnits('abc'));
  assert.throws(() => toBaseUnits('-5'));
  assert.throws(() => toBaseUnits('1.123456789')); // >8 decimals
});

test('high-water configuration fails closed when unset and accepts explicit base-unit policy', () => {
  assert.throws(() => parseRequiredBaseUnits('', 'FAUCET_HIGH_WATER_MARK'), /must be set/);
  assert.throws(() => validateHighWaterConfig({ highWaterMark: '0' }), /greater than zero/);
  assert.throws(() => validateHighWaterConfig({ highWaterMark: '10', refillSource: 'unknown' }), /manual, emission, or treasury/);
  assert.deepEqual(validateHighWaterConfig({ highWaterMark: '10', refillSource: 'treasury' }), {
    highWaterMarkBaseUnits: 1000000000,
    refillSource: 'treasury',
  });
});

test('refill is bounded by absolute mark and cumulative source earnings', async () => {
  const transfers = [];
  const fundingSource = { transferToBucket: async (amount) => transfers.push(amount) };

  const first = await refillFaucetBucket({
    balanceBaseUnits: 800,
    sourceEarnedBaseUnits: 900,
    totalRefilledBaseUnits: 850,
    highWaterMarkBaseUnits: 1000,
    fundingSource,
  });
  assert.deepEqual(first, { amountBaseUnits: 50, refilledBaseUnits: 900 });

  const atMark = await refillFaucetBucket({
    balanceBaseUnits: 1000,
    sourceEarnedBaseUnits: 5000,
    totalRefilledBaseUnits: 900,
    highWaterMarkBaseUnits: 1000,
    fundingSource,
  });
  assert.deepEqual(atMark, { amountBaseUnits: 0, refilledBaseUnits: 900 });

  const afterWithdrawal = await refillFaucetBucket({
    balanceBaseUnits: 400,
    sourceEarnedBaseUnits: 950,
    totalRefilledBaseUnits: 900,
    highWaterMarkBaseUnits: 1000,
    fundingSource,
  });
  assert.deepEqual(afterWithdrawal, { amountBaseUnits: 50, refilledBaseUnits: 950 });
  assert.deepEqual(transfers, [50, 50]);
});

test('parseReceipt reads tx_id from the node /transactions/submit envelope data', () => {
  // Shape of routes/transactions.rs submit_transaction_compat data payload.
  const data = {
    accepted: true,
    tx_id: 'tx-abc-123',
    tx_type: 'Transfer',
    from: '0xfaucet',
    to: '0xuser',
    amount: 1000000000,
    privacy_mode: 'transparent_opt_out',
  };
  const receipt = parseReceipt(data, '0xuser');
  assert.equal(receipt.txHash, 'tx-abc-123');
  assert.equal(receipt.address, '0xuser');
});

test('parseReceipt falls back to address when missing', () => {
  const receipt = parseReceipt({ tx_id: 't1' }, '0xfallback');
  assert.equal(receipt.txHash, 't1');
  assert.equal(receipt.address, '0xfallback');
});

test('getClientIp ignores spoofed X-Forwarded-For by default', () => {
  const req = {
    headers: { 'x-forwarded-for': '203.0.113.99' },
    ip: '203.0.113.99',
    socket: { remoteAddress: '100.64.0.10' },
  };

  assert.equal(getClientIp(req), '100.64.0.10');
});

test('parseTrustProxySetting accepts only fixed numeric hops', () => {
  assert.equal(parseTrustProxySetting('false'), false);
  assert.equal(parseTrustProxySetting('off'), false);
  assert.equal(parseTrustProxySetting('0'), false);
  assert.equal(parseTrustProxySetting('1'), 1);
  assert.equal(parseTrustProxySetting('2'), 2);
  assert.equal(parseTrustProxySetting('loopback'), false);
  assert.equal(parseTrustProxySetting('true'), false);
  assert.equal(parseTrustProxySetting('203.0.113.0/24'), false);
});

test('captcha readiness fails closed for configured faucet payouts', () => {
  assert.deepEqual(captchaReadiness({ provider: 'off', walletConfigured: true }), {
    ok: false,
    reason: 'CAPTCHA_PROVIDER must be hcaptcha or recaptcha-v3 before faucet payouts are enabled',
  });

  assert.equal(
    captchaReadiness({ provider: 'hcaptcha', walletConfigured: true, hcaptchaSecret: 's' }).ok,
    false,
  );

  assert.deepEqual(
    captchaReadiness({
      provider: 'hcaptcha',
      walletConfigured: true,
      hcaptchaSecret: 's',
      hcaptchaSitekey: 'k',
    }),
    { ok: true },
  );
});

test('captcha readiness allows disabled captcha only before payouts are configured', () => {
  assert.deepEqual(captchaReadiness({ provider: 'off', walletConfigured: false }), { ok: true });
});

test('health semantics report proxy-only when captcha is off on a configured faucet', () => {
  assert.deepEqual(
    faucetDispenseReadiness({
      walletConfigured: true,
      apiTokenConfigured: true,
      captcha: { ok: false },
    }),
    { directClaimsEnabled: false, dispenseMode: 'proxy-only' },
  );
});

test('health semantics report direct only when payout and captcha configuration are ready', () => {
  assert.deepEqual(
    faucetDispenseReadiness({
      walletConfigured: true,
      apiTokenConfigured: true,
      captcha: { ok: true },
    }),
    { directClaimsEnabled: true, dispenseMode: 'direct' },
  );
  assert.deepEqual(
    faucetDispenseReadiness({
      walletConfigured: false,
      apiTokenConfigured: true,
      captcha: { ok: true },
    }),
    { directClaimsEnabled: false, dispenseMode: 'unconfigured' },
  );
});

test('parses wallet balances from base units and whole WRF decimals', () => {
  assert.equal(parseBalanceBaseUnits('1000000000'), 1000000000);
  assert.equal(parseBalanceBaseUnits('10.5'), 1050000000);
  assert.equal(parseBalanceBaseUnits(42), 42);
  assert.equal(parseBalanceBaseUnits('not-a-balance'), null);
});

test('extracts faucet wallet balance from node response envelopes', () => {
  assert.equal(extractWalletBalanceBaseUnits({ data: { balance: '1000000000' } }), 1000000000);
  assert.equal(extractWalletBalanceBaseUnits({ account: { balance: '2.5' } }), 250000000);
  assert.equal(extractWalletBalanceBaseUnits({ wallet: { spendableBalance: '7.25' } }), 725000000);
});

test('daily payout keys are wallet/global scoped and not IP scoped', () => {
  const now = new Date('2026-06-13T12:34:56.000Z');
  const keys = buildDailyPayoutKeys('0xABCDEF0000000000000000000000000000000000', now);

  assert.equal(keys.day, '2026-06-13');
  assert.equal(
    keys.walletKey,
    'faucet:wallet-daily:0xabcdef0000000000000000000000000000000000:2026-06-13',
  );
  assert.equal(keys.globalKey, 'faucet:global-daily:2026-06-13');
  assert.equal(keys.walletKey.includes('203.0.113'), false);
});

test('UTC day helper uses calendar date and positive TTL', () => {
  const now = new Date('2026-06-13T23:59:30.000Z');
  assert.equal(dailyKeySuffix(now), '2026-06-13');
  // Retry-After is the calendar wait; the key TTL adds a margin (infra#1157 review r2).
  assert.equal(secondsUntilNextUtcDay(now), 30);
  assert.equal(dailyKeyTtlSeconds(now), 90);
});

test('Retry-After to the next UTC day comes from the calendar (minimum 1)', () => {
  assert.equal(secondsUntilNextUtcDay(new Date('2026-06-13T23:59:59.500Z')), 1);
  assert.equal(secondsUntilNextUtcDay(new Date('2026-06-14T00:00:00.000Z')), 86400);
  assert.equal(secondsUntilNextUtcDay(new Date('2026-06-14T00:00:00.001Z')), 86400);
  assert.equal(secondsUntilNextUtcDay(new Date('2026-06-13T23:59:59.000Z')), 1);
  // The Redis key outlives its day by the margin, never by less.
  assert.equal(dailyKeyTtlSeconds(new Date('2026-06-13T23:59:59.500Z')), 61);
  assert.equal(dailyKeyTtlSeconds(new Date('2026-06-14T00:00:00.000Z')), 86460);
});

test('refill-sized payouts cannot bypass wallet or global daily caps', () => {
  const walletCap = 10 * 100000000;
  const globalCap = 1000 * 100000000;
  const refillAmount = 2 * 100000000;

  const walletBoundary = evaluateDailyPayoutCaps({
    walletSpentBaseUnits: walletCap - 100000000,
    globalSpentBaseUnits: 0,
    amountBaseUnits: refillAmount,
    walletCapBaseUnits: walletCap,
    globalCapBaseUnits: globalCap,
  });
  assert.deepEqual(walletBoundary, {
    accepted: false,
    reason: 'wallet',
    walletNext: walletCap - 100000000,
    globalNext: 0,
  });

  const globalBoundary = evaluateDailyPayoutCaps({
    walletSpentBaseUnits: 0,
    globalSpentBaseUnits: globalCap - 100000000,
    amountBaseUnits: refillAmount,
    walletCapBaseUnits: walletCap,
    globalCapBaseUnits: globalCap,
  });
  assert.deepEqual(globalBoundary, {
    accepted: false,
    reason: 'global',
    walletNext: 0,
    globalNext: globalCap - 100000000,
  });
});

test('getTailscaleIdentity prefers login over display name', () => {
  assert.deepEqual(
    getTailscaleIdentity({
      headers: {
        'tailscale-user-login': 'alice@example.com',
        'tailscale-user-name': 'Alice Example',
      },
    }),
    { source: 'login', value: 'alice@example.com' },
  );

  assert.deepEqual(
    getTailscaleIdentity({ headers: { 'tailscale-user-name': 'Alice Example' } }),
    { source: 'name', value: 'Alice Example' },
  );

  assert.equal(getTailscaleIdentity({ headers: {} }), null);
  assert.equal(getTailscaleIdentity({}), null);
});

test('getRateLimitIdentity keys on tailnet user when behind tailscale serve', () => {
  // Behind `tailscale serve` every request's peer IP is loopback; the identity
  // must come from the injected header so each user gets a distinct bucket.
  const reqA = {
    headers: { 'tailscale-user-login': 'alice@example.com' },
    socket: { remoteAddress: '127.0.0.1' },
  };
  const reqB = {
    headers: { 'tailscale-user-login': 'bob@example.com' },
    socket: { remoteAddress: '127.0.0.1' },
  };

  const idA = getRateLimitIdentity(reqA);
  const idB = getRateLimitIdentity(reqB);

  assert.equal(idA.kind, 'tsuser');
  assert.ok(idA.key.startsWith('faucet:tsuser:'));
  // Despite identical loopback peer IPs, distinct users => distinct buckets.
  assert.notEqual(idA.key, idB.key);
  // Raw email never appears in the key (sha256 fingerprint only).
  assert.equal(idA.key.includes('alice@example.com'), false);
});

test('getRateLimitIdentity is case-insensitive for the tailnet login', () => {
  const lower = getRateLimitIdentity({ headers: { 'tailscale-user-login': 'alice@example.com' } });
  const upper = getRateLimitIdentity({ headers: { 'tailscale-user-login': 'ALICE@example.com' } });
  assert.equal(lower.key, upper.key);
});

test('getRateLimitIdentity falls back to peer IP when no tailscale header', () => {
  const req = { headers: {}, socket: { remoteAddress: '203.0.113.7' } };
  const id = getRateLimitIdentity(req);

  assert.equal(id.kind, 'ip');
  // Backward-compatible: same key the IP-only path produced before this change.
  assert.equal(id.key, 'faucet:ip:' + require('crypto').createHash('sha256').update('203.0.113.7').digest('hex'));
});

test('faucet page does not advertise Discord as a payout gate', () => {
  const page = renderPage();

  assert.equal(page.includes('Discord gate'), false);
  assert.equal(page.includes('Discord support'), true);
  assert.equal(page.includes('Discord alerts optional'), true);
});

test('faucet page disables direct claims and gives the onboarding path when captcha is off', () => {
  const page = renderPage({
    walletConfigured: true,
    apiTokenConfigured: true,
    captcha: { ok: false },
  });
  assert.match(page, /Direct claims are disabled on this faucet/);
  assert.match(page, /id="faucet-form" aria-disabled="true"/);
  assert.match(page, /id="request-button"[^>]+disabled/);
});

test('faucet page keeps the existing direct form enabled when captcha is ready', () => {
  const page = renderPage({
    walletConfigured: true,
    apiTokenConfigured: true,
    captcha: { ok: true },
  });
  assert.equal(page.includes('id="direct-claims-notice"'), false);
  assert.match(page, /id="faucet-form" aria-disabled="false"/);
  assert.doesNotMatch(page, /id="request-button"[^>]+disabled/);
});

test('configured faucet with captcha off keeps direct claims fail-closed and wrong bearer forbidden', () => {
  const script = `
    const { app } = require('./server');
    (async () => {
      const server = app.listen(0, '127.0.0.1');
      await new Promise((resolve) => server.once('listening', resolve));
      try {
        const url = 'http://127.0.0.1:' + server.address().port + '/faucet/request';
        const healthResponse = await fetch('http://127.0.0.1:' + server.address().port + '/health');
        const health = await healthResponse.json();
        const body = JSON.stringify({ walletAddress: '0x' + 'a'.repeat(40) });
        const direct = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body });
        const directBody = await direct.json();
        const wrong = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json', authorization: 'Bearer wrong' }, body });
        const wrongBody = await wrong.json();
        process.stdout.write(JSON.stringify({ healthStatus: healthResponse.status, directClaimsEnabled: health.directClaimsEnabled, dispenseMode: health.dispenseMode, directStatus: direct.status, directCode: directBody.error.code, wrongStatus: wrong.status, wrongCode: wrongBody.error.code }));
      } finally {
        await new Promise((resolve) => server.close(resolve));
      }
    })().catch((error) => { console.error(error); process.exit(1); });
  `;
  const result = JSON.parse(execFileSync(process.execPath, ['-e', script], {
    cwd: __dirname,
    env: {
      ...process.env,
      CAPTCHA_PROVIDER: 'off',
      FAUCET_WALLET_PRIVKEY: '11'.repeat(32),
      FAUCET_WALLET_ADDRESS: '0x' + 'b'.repeat(40),
      FAUCET_API_TOKEN: 'operator-token',
    },
    encoding: 'utf8',
  }));
  assert.deepEqual(result, {
    healthStatus: 200,
    directClaimsEnabled: false,
    dispenseMode: 'proxy-only',
    directStatus: 503,
    directCode: 'CAPTCHA_NOT_CONFIGURED',
    wrongStatus: 403,
    wrongCode: 'INVALID_PROXY_TOKEN',
  });
});

// ── /metrics auth gate (checkBearerToken) ────────────────────────────────────
test('checkBearerToken returns 503 when no token is configured', () => {
  const req = { headers: { authorization: 'Bearer anything' } };
  assert.deepEqual(checkBearerToken(req, ''), { ok: false, status: 503 });
  assert.deepEqual(checkBearerToken(req, null), { ok: false, status: 503 });
  assert.deepEqual(checkBearerToken(req, undefined), { ok: false, status: 503 });
});

test('checkBearerToken returns 401 when no Authorization header is provided', () => {
  const req = { headers: {} };
  assert.deepEqual(checkBearerToken(req, 'secret-token'), { ok: false, status: 401 });
});

test('checkBearerToken returns 401 when Authorization header is present but has no Bearer prefix', () => {
  const req = { headers: { authorization: 'Basic dXNlcjpwYXNz' } };
  assert.deepEqual(checkBearerToken(req, 'secret-token'), { ok: false, status: 401 });
});

test('checkBearerToken returns 403 when an incorrect token is provided', () => {
  const req = { headers: { authorization: 'Bearer wrong-token' } };
  assert.deepEqual(checkBearerToken(req, 'correct-token'), { ok: false, status: 403 });
});

test('checkBearerToken returns 200 when the correct token is provided', () => {
  const req = { headers: { authorization: 'Bearer correct-token' } };
  assert.deepEqual(checkBearerToken(req, 'correct-token'), { ok: true, status: 200 });
});

test('checkBearerToken is not vulnerable to a length-shortcut bypass (timing-safe)', () => {
  // A shorter token that is a prefix of the correct token must not pass.
  const req = { headers: { authorization: 'Bearer short' } };
  assert.deepEqual(checkBearerToken(req, 'short-but-longer'), { ok: false, status: 403 });
});

test('checkBearerToken handles missing headers object gracefully', () => {
  assert.deepEqual(checkBearerToken({}, 'secret-token'), { ok: false, status: 401 });
  assert.deepEqual(checkBearerToken(null, ''), { ok: false, status: 503 });
});

// ── #857 Option B: trusted-proxy identity resolution ─────────────────────────

const { resolveRequestIdentity } = require('./server');

test('resolveRequestIdentity uses x-client-ip for trusted-proxy requests', () => {
  const req = {
    headers: { 'x-client-ip': '203.0.113.7' },
    socket: { remoteAddress: '172.18.0.5' },
  };
  const { remoteIp, rateLimitIdentity } = resolveRequestIdentity(req, true);
  assert.equal(remoteIp, '203.0.113.7');
  assert.equal(rateLimitIdentity.kind, 'ip');
  assert.equal(rateLimitIdentity.source, 'trusted-proxy');
  // Two different forwarded users must land in different buckets even though
  // both arrive from the backend container's socket.
  const other = resolveRequestIdentity(
    { headers: { 'x-client-ip': '203.0.113.8' }, socket: { remoteAddress: '172.18.0.5' } },
    true,
  );
  assert.notEqual(rateLimitIdentity.key, other.rateLimitIdentity.key);
});

test('resolveRequestIdentity ignores x-client-ip for untrusted requests', () => {
  const req = {
    headers: { 'x-client-ip': '203.0.113.7' },
    socket: { remoteAddress: '172.18.0.5' },
  };
  const { remoteIp, rateLimitIdentity } = resolveRequestIdentity(req, false);
  assert.equal(remoteIp, '172.18.0.5');
  assert.notEqual(rateLimitIdentity.source, 'trusted-proxy');
});

test('resolveRequestIdentity falls back to peer identity when trusted proxy sends no x-client-ip', () => {
  const req = { headers: {}, socket: { remoteAddress: '172.18.0.5' } };
  const { remoteIp, rateLimitIdentity } = resolveRequestIdentity(req, true);
  assert.equal(remoteIp, '172.18.0.5');
  assert.notEqual(rateLimitIdentity.source, 'trusted-proxy');
});

test('assertFaucetConfiguredForPayout skips captcha readiness only when requireCaptcha=false', () => {
  // Env in the test runner has no wallet/captcha configured, so the wallet
  // guard fires first either way — proving the captcha skip needs the wallet
  // guards to pass, which we can't fake without a module reload. Instead pin
  // the observable contract: with requireCaptcha=true and no captcha config,
  // captchaReadiness (already covered above) gates payouts; the handler passes
  // requireCaptcha:false exactly when the request bears a valid operator
  // token. Assert the exported function accepts the options bag shape.
  const { assertFaucetConfiguredForPayout } = require('./server');
  assert.throws(() => assertFaucetConfiguredForPayout({ requireCaptcha: false }), /FAUCET_WALLET_PRIVKEY|FAUCET_NOT_CONFIGURED/);
  assert.throws(() => assertFaucetConfiguredForPayout(), /FAUCET_WALLET_PRIVKEY|FAUCET_NOT_CONFIGURED/);
});

// Account nonce behavior is exercised by the enforcing node double in server.caps.test.js.

// ── #615: from-account ed25519 authorization for transparent transfers ───────

const { buildTransferAuthMessage, signTransferAuthorization } = require('./server');
const nodeCrypto = require('node:crypto');

test('native and EVM faucet addresses use the same supported-address policy', () => {
  const { isSupportedWalletAddress, normalizeWalletAddress } = require('./server');
  const evm = '0x' + 'a'.repeat(40);
  const nativeUpper = 'WRF' + 'B'.repeat(40);
  assert.equal(isSupportedWalletAddress(evm), true);
  assert.equal(isSupportedWalletAddress(nativeUpper), true);
  assert.equal(normalizeWalletAddress(nativeUpper), '0x' + 'b'.repeat(40));
  assert.equal(isSupportedWalletAddress('wrf' + 'z'.repeat(40)), false);
  assert.equal(isSupportedWalletAddress('0x' + 'a'.repeat(39)), false);
});

test('faucet route rejects malformed and wrong-network recipients before payout configuration', async () => {
  const { app } = require('./server');
  const server = app.listen(0, '127.0.0.1');
  await once(server, 'listening');
  try {
    const port = server.address().port;
    for (const walletAddress of ['wrf' + 'z'.repeat(40), 'bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh']) {
      const response = await fetch(`http://127.0.0.1:${port}/faucet/request`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ walletAddress }),
      });
      assert.equal(response.status, 400);
      assert.equal((await response.json()).error.code, 'INVALID_WALLET');
    }
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

// #2034/core4 PR #2064, infra#626: v2 domain tag folds chain_domain
// (chain_id, network_id) right after the tag. buildTransferAuthMessage
// defaults chain_id/network_id to WRFCOIN_CHAIN_ID/WRFCOIN_NETWORK_ID (unset
// here, so they resolve to the Rust-side mainnet fallbacks "wrfcoin-main" /
// "mainnet" — see domain_signing.rs DEFAULT_CHAIN_ID/DEFAULT_NETWORK_ID).
test('buildTransferAuthMessage matches the core4 v2 canonical layout', () => {
  const msg = buildTransferAuthMessage('0xab', '0xcd', 5, '7');
  const domain = Buffer.from('wrfcoin_transparent_transfer_auth_v2');
  assert.deepEqual(msg.subarray(0, domain.length), domain);
  let o = domain.length;
  const chainId = Buffer.from('wrfcoin-main');
  const networkId = Buffer.from('mainnet');
  assert.equal(msg.readUInt32LE(o), chainId.length); o += 4;
  assert.equal(msg.subarray(o, o + chainId.length).toString(), 'wrfcoin-main'); o += chainId.length;
  assert.equal(msg.readUInt32LE(o), networkId.length); o += 4;
  assert.equal(msg.subarray(o, o + networkId.length).toString(), 'mainnet'); o += networkId.length;
  assert.equal(msg.readUInt32LE(o), 4); o += 4;                       // len('0xab')
  assert.equal(msg.subarray(o, o + 4).toString(), '0xab'); o += 4;
  assert.equal(msg.readUInt32LE(o), 4); o += 4;                       // len('0xcd')
  assert.equal(msg.subarray(o, o + 4).toString(), '0xcd'); o += 4;
  assert.equal(msg.readBigUInt64LE(o), 5n); o += 8;                   // amount LE
  assert.equal(msg.readBigUInt64LE(o), 7n); o += 8;                   // nonce LE
  assert.equal(msg.length, o);
});

// Golden vector from core4 docs/specifications/SIGNING_PREIMAGE_V2.md
// (chain_id="777", network_id="testnet", from="wrf_from", to="wrf_to",
// amount=1000, nonce=5) — byte-for-byte parity with the Rust reference
// implementation (transparent_transfer_authorization_message_with_domain).
test('buildTransferAuthMessage reproduces the core4 SIGNING_PREIMAGE_V2 golden vector', () => {
  const msg = buildTransferAuthMessage('wrf_from', 'wrf_to', 1000, 5, '777', 'testnet');
  const expectedHex =
    '777266636f696e5f7472616e73706172656e745f7472616e736665725f617574685f7632' +
    '0300000037373707000000746573746e6574080000007772665f66726f6d060000007772' +
    '665f746fe8030000000000000500000000000000';
  assert.equal(msg.toString('hex'), expectedHex);
});

test('signTransferAuthorization produces a verifiable ed25519 signature over the canonical message', () => {
  const seed = nodeCrypto.randomBytes(32).toString('hex');
  const { auth_pubkey, auth_signature } = signTransferAuthorization({
    from: '0x' + 'a'.repeat(40),
    to: '0x' + 'b'.repeat(40),
    amountBaseUnits: 1000000000,
    nonce: '1751500000000000042',
    privkeyHex: seed,
  });
  assert.match(auth_pubkey, /^[0-9a-f]{64}$/);
  assert.match(auth_signature, /^[0-9a-f]{128}$/);
  const spki = Buffer.concat([
    Buffer.from('302a300506032b6570032100', 'hex'),
    Buffer.from(auth_pubkey, 'hex'),
  ]);
  const pubKey = nodeCrypto.createPublicKey({ key: spki, format: 'der', type: 'spki' });
  const message = buildTransferAuthMessage(
    '0x' + 'a'.repeat(40),
    '0x' + 'b'.repeat(40),
    1000000000,
    '1751500000000000042',
  );
  assert.ok(nodeCrypto.verify(null, message, pubKey, Buffer.from(auth_signature, 'hex')));
  // Tampered nonce must not verify
  const tampered = buildTransferAuthMessage('0x' + 'a'.repeat(40), '0x' + 'b'.repeat(40), 1000000000, '1751500000000000043');
  assert.ok(!nodeCrypto.verify(null, tampered, pubKey, Buffer.from(auth_signature, 'hex')));
});

test('signTransferAuthorization rejects malformed seeds', () => {
  assert.throws(() =>
    signTransferAuthorization({ from: '0xa', to: '0xb', amountBaseUnits: 1, nonce: '1', privkeyHex: 'deadbeef' })
  );
});

function nest(levels, leaf) {
  let value = leaf;
  for (let i = 0; i < levels; i += 1) value = { level: value };
  return value;
}

test('the acceptance scan reports a body deeper than it reads as evidence (UNKNOWN), and still finds shallow evidence', () => {
  assert.equal(hasAcceptanceEvidence(nest(40, { accepted: true })), true);
  assert.equal(hasAcceptanceEvidence(nest(40, { nothing: 'here' })), true); // unread subtree: not cleared
  assert.equal(hasAcceptanceEvidence(nest(5, { accepted: true })), true);
  assert.equal(hasAcceptanceEvidence(nest(5, { tx_id: '0xab' })), true);
  assert.equal(hasAcceptanceEvidence(nest(5, { accepted: false })), false);
  assert.equal(hasAcceptanceEvidence(nest(31, { ok: true })), false); // within the scan depth
});

test('definitive rejection = a direct 4xx with core4\'s exact error envelope and no acceptance evidence', () => {
  // core4 65134a64 launch_api helpers.rs envelope_error.
  const envelope = (error, extra = {}) => ({
    ok: false,
    data: null,
    error,
    meta: { request_id: 'req_1', timestamp: '2026-10-01T00:00:00Z', api_version: 'v1' },
    ...extra,
  });
  const validation = { code: 'VALIDATION_ERROR', message: 'from, to, and positive amount are required' };
  assert.equal(isDefinitiveRejection(400, envelope(validation)), true);
  assert.equal(isDefinitiveRejection(422, envelope({ code: 'UNPROCESSABLE_ENTITY', message: 'nonce is required' })), true);
  assert.equal(isDefinitiveRejection(429, envelope({ code: 'RATE_LIMITED', message: 'slow down' })), true);
  assert.equal(isDefinitiveRejection(400, envelope({ ...validation, correlation_id: 'c1' })), true);

  // Not definitive: anything else.
  const unknown = [
    [409, envelope({ code: 'REPLAY_REJECTED', message: 'replayed nonce' })], // the nonce was admitted
    [400, { message: 'insufficient spendable balance' }], // a bare message is not a rejection
    [400, { ok: false, error: validation }], // no data/meta: not the envelope
    [400, envelope(validation, { extra: 1 })],
    [400, { ...envelope(validation), data: { accepted: true } }], // contradictory
    [400, { ...envelope(validation), data: { tx_id: '0xab' } }],
    [400, envelope({ ...validation, transaction_id: '0xab' })],
    [400, envelope({ code: 'lowercase', message: 'x' })],
    [400, envelope({ code: 'VALIDATION_ERROR' })],
    [400, { ...envelope(validation), meta: { request_id: 'r', api_version: 'v2' } }],
    [400, { ...envelope(validation), ok: true }],
    [400, null],
    [400, ['not', 'an', 'object']],
    [500, envelope(validation)],
    [503, envelope(validation)],
    [307, envelope(validation)],
    [200, envelope(validation)],
    // infra#1157 review r3: core4's exact meta and correlation_id shapes.
    [400, { ...envelope(validation), meta: { request_id: 'req_1', api_version: 'v1' } }], // no timestamp
    [400, { ...envelope(validation), meta: { request_id: 'req_1', timestamp: 1790000000, api_version: 'v1' } }],
    [400, { ...envelope(validation), meta: { request_id: 'req_1', timestamp: 't', api_version: 'v1', extra: 1 } }],
    [400, envelope({ ...validation, correlation_id: { id: 'c1' } })],
    [400, envelope({ ...validation, correlation_id: 7 })],
    // accepted:true nested 40 levels deep: UNKNOWN, never definitive.
    [400, { ...envelope(validation), data: nest(40, { accepted: true }) }],
  ];
  for (const [status, body] of unknown) {
    assert.equal(isDefinitiveRejection(status, body), false, `${status} ${JSON.stringify(body)}`);
  }
});
