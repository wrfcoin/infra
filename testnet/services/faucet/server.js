const crypto = require('crypto');
const express = require('express');
const promClient = require('prom-client');
const { createClient } = require('redis');

const PORT = Number.parseInt(process.env.PORT || '8080', 10);
// Base URL of the core4 node's REST launch_api. `FAUCET_NODE_URL` is the
// preferred name; `FAUCET_RPC_URL` is kept as a backwards-compatible alias.
// Trailing slashes are trimmed so endpoint paths concatenate cleanly.
const FAUCET_NODE_URL = (
  process.env.FAUCET_NODE_URL ||
  process.env.FAUCET_RPC_URL ||
  'http://wrfcoin-node:8556'
).replace(/\/+$/, '');
// REST path used to submit a structured (operator-signed) transfer. The node
// exposes POST /transactions/submit (routes/mod.rs); there is NO JSON-RPC
// wrf_transfer method. Overridable for forward compatibility.
const FAUCET_SUBMIT_PATH = process.env.FAUCET_SUBMIT_PATH || '/transactions/submit';
// Bearer token the node maps to a Contributor (or higher) role. The node's
// operator token satisfies Contributor, so this defaults to it.
const FAUCET_API_TOKEN =
  process.env.FAUCET_API_TOKEN || process.env.WRFCOIN_OPERATOR_TOKEN || '';
// Chain identity folded into the v2 signing preimage (#2034/core4 PR #2064).
// MUST resolve to the same value the core4 node signer/verifier resolves
// (shared-protocol/src/crypto/domain_signing.rs: signing_chain_id() /
// signing_network_id()) or auth_signature will fail to verify. Same env vars
// the node reads; empty/unset falls back to the mainnet constants exactly
// like the Rust side, so an operator who forgets to set these on a non-mainnet
// deployment gets a loud auth failure rather than a silent mismatch.
const WRFCOIN_CHAIN_ID =
  (process.env.WRFCOIN_CHAIN_ID || '').trim() || 'wrfcoin-main';
const WRFCOIN_NETWORK_ID =
  (process.env.WRFCOIN_NETWORK_ID || '').trim() || 'mainnet';
// Separate token accepted on /metrics so the Prometheus scraper can authenticate
// without needing the operator (node API) token.  Set this to the same value as
// the prometheus-bearer-token file in testnet/.  Falls back to FAUCET_API_TOKEN
// when not set (compatible with single-token deployments).
const FAUCET_METRICS_TOKEN = process.env.FAUCET_METRICS_TOKEN || '';
// Whole-coin display amount; converted to u64 base units for the node.
const FAUCET_AMOUNT = process.env.FAUCET_AMOUNT || '10';
const FAUCET_DENOMINATION = process.env.FAUCET_DENOMINATION || 'WRF';
// 1 WRF = 10^8 base units (WRF_UNITS_PER_COIN). The node's amount field is a
// u64 of base units, sent as a JSON number (see backend PR #770).
const WRF_UNITS_PER_COIN = 100000000n;
const FAUCET_WALLET_PRIVKEY = process.env.FAUCET_WALLET_PRIVKEY || '';
const FAUCET_WALLET_ADDRESS = process.env.FAUCET_WALLET_ADDRESS || '';
const FAUCET_WALLET_BALANCE_PATH =
  process.env.FAUCET_WALLET_BALANCE_PATH || '/addresses/{address}';
const FAUCET_RATE_LIMIT_SECONDS = Number.parseInt(
  process.env.FAUCET_RATE_LIMIT_SECONDS || String(24 * 60 * 60),
  10,
);
const FAUCET_WALLET_DAILY_CAP = process.env.FAUCET_WALLET_DAILY_CAP || FAUCET_AMOUNT;
const FAUCET_GLOBAL_DAILY_CAP = process.env.FAUCET_GLOBAL_DAILY_CAP || '1000';
// Per-device daily payout cap (whole WRF). A device is the request's rate-limit
// identity: the authenticated tailnet user behind `tailscale serve`, otherwise
// the peer IP (or the trusted proxy's forwarded client IP). The default is one
// payout per device per UTC day. It is independent of the cooldown, which
// spaces claims, and of the per-wallet cap, which follows the address.
const FAUCET_DEVICE_DAILY_CAP = process.env.FAUCET_DEVICE_DAILY_CAP || FAUCET_AMOUNT;
// Daily limits are policy inputs in whole WRF for operator readability, but
// every payout/refill accounting decision is made in the node's base units.
// Parsing at startup also fails closed on malformed cap configuration instead
// of waiting for the first payout request.
const FAUCET_WALLET_DAILY_CAP_BASE_UNITS = toBaseUnits(FAUCET_WALLET_DAILY_CAP);
const FAUCET_GLOBAL_DAILY_CAP_BASE_UNITS = toBaseUnits(FAUCET_GLOBAL_DAILY_CAP);
const FAUCET_DEVICE_DAILY_CAP_BASE_UNITS = toBaseUnits(FAUCET_DEVICE_DAILY_CAP);
const FAUCET_WALLET_BALANCE_FLOOR =
  process.env.FAUCET_WALLET_BALANCE_FLOOR || FAUCET_AMOUNT;
// Required absolute high-water mark for the faucet bucket. There is
// intentionally no live-safe default: a deployment must choose its mark.
const FAUCET_HIGH_WATER_MARK = process.env.FAUCET_HIGH_WATER_MARK || '';
const FAUCET_REFILL_SOURCE = process.env.FAUCET_REFILL_SOURCE || 'manual';
const CAPTCHA_PROVIDER = normalizeCaptchaProvider(process.env.CAPTCHA_PROVIDER || 'off');
const HCAPTCHA_SECRET = process.env.HCAPTCHA_SECRET || '';
const HCAPTCHA_SITEKEY = process.env.HCAPTCHA_SITEKEY || '';
const RECAPTCHA_SECRET = process.env.RECAPTCHA_SECRET || '';
const RECAPTCHA_SITEKEY = process.env.RECAPTCHA_SITEKEY || '';
const RECAPTCHA_MIN_SCORE = Number.parseFloat(process.env.RECAPTCHA_MIN_SCORE || '0.5');
const DISCORD_WEBHOOK_URL = process.env.DISCORD_WEBHOOK_URL || '';
const DISCORD_WEBHOOK_USERNAME = process.env.DISCORD_WEBHOOK_USERNAME || 'WRFCoin Faucet';
const DISCORD_WEBHOOK_AVATAR_URL = process.env.DISCORD_WEBHOOK_AVATAR_URL || '';
const DISCORD_INVITE_URL = process.env.DISCORD_INVITE_URL || 'https://discord.gg/wrfcoin-testnet';
const EXPLORER_URL = process.env.EXPLORER_URL || 'http://localhost:8081';

const REDIS_URL = process.env.REDIS_URL || '';
const REDIS_KEY_PREFIX = process.env.FAUCET_RATE_LIMIT_PREFIX || 'faucet:ip:';
// Per-user cooldown bucket used when the request carries an authenticated
// Tailscale identity (see getRateLimitIdentity). Keeping it on a distinct
// prefix from the peer-IP bucket means tailnet users and direct/LAN callers
// never collide in the same key space.
const REDIS_TSUSER_PREFIX =
  process.env.FAUCET_RATE_LIMIT_TSUSER_PREFIX || 'faucet:tsuser:';
const REDIS_WALLET_DAILY_PREFIX =
  process.env.FAUCET_WALLET_DAILY_PREFIX || 'faucet:wallet-daily:';
const REDIS_GLOBAL_DAILY_PREFIX =
  process.env.FAUCET_GLOBAL_DAILY_PREFIX || 'faucet:global-daily:';
const REDIS_DEVICE_DAILY_PREFIX =
  process.env.FAUCET_DEVICE_DAILY_PREFIX || 'faucet:device-daily:';
// infra#1157 review: a claim whose transfer outcome is unknown (sent, but no
// definitive rejection and no usable receipt) is recorded here for an
// operator or a later reconciler. Kept for a week.
const REDIS_PENDING_PREFIX = process.env.FAUCET_PENDING_PREFIX || 'faucet:pending:';
const PENDING_CLAIM_TTL_SECONDS = 7 * 24 * 60 * 60;
const RATE_LIMIT_LABEL = `${Math.max(1, Math.round(FAUCET_RATE_LIMIT_SECONDS / 3600))}h`;
const TRUST_PROXY_SETTING = parseTrustProxySetting(process.env.FAUCET_TRUST_PROXY || 'false');

const app = express();
app.set('trust proxy', TRUST_PROXY_SETTING);
app.disable('x-powered-by');
app.use(express.json({ limit: '32kb' }));
app.use(express.urlencoded({ extended: false }));

const registry = new promClient.Registry();
promClient.collectDefaultMetrics({ register: registry, prefix: 'wrfcoin_faucet_' });

const requestsTotal = new promClient.Counter({
  name: 'wrfcoin_faucet_requests_total',
  help: 'Total faucet request attempts.',
  labelNames: ['result'],
});
const captchaChecksTotal = new promClient.Counter({
  name: 'wrfcoin_faucet_captcha_checks_total',
  help: 'Total captcha verification attempts.',
  labelNames: ['provider', 'result'],
});
const transfersTotal = new promClient.Counter({
  name: 'wrfcoin_faucet_transfers_total',
  help: 'Total faucet transfers requested from the node.',
  labelNames: ['result'],
});
const discordNotificationsTotal = new promClient.Counter({
  name: 'wrfcoin_faucet_discord_notifications_total',
  help: 'Total Discord webhook notifications sent by the faucet.',
  labelNames: ['result'],
});
const requestDuration = new promClient.Histogram({
  name: 'wrfcoin_faucet_request_duration_seconds',
  help: 'Wall clock time spent handling faucet requests.',
  buckets: [0.1, 0.25, 0.5, 1, 2, 5, 10],
});
// infra#629: faucet depletion visibility. The faucet is the only new-user
// onramp; without a balance gauge it can go silently dry with zero operator
// signal. This gauge is refreshed periodically from getFaucetWalletBalance()
// (see startWalletBalancePolling) and drives the FaucetWalletLow/FaucetWalletDry
// alerts. Values are WRF base units (10^8 per WRF).
const walletBalanceGauge = new promClient.Gauge({
  name: 'wrfcoin_faucet_wallet_balance',
  help: 'Faucet wallet balance in WRF base units (10^8 per WRF), refreshed periodically from the node.',
});
// The configured post-transfer floor, exported so alerts can compare the live
// balance against it without hard-coding the threshold in the rule.
const walletBalanceFloorGauge = new promClient.Gauge({
  name: 'wrfcoin_faucet_wallet_balance_floor',
  help: 'Configured faucet post-transfer balance floor in WRF base units (10^8 per WRF).',
});
// 1 when the last balance refresh succeeded, 0 when it failed (node down, auth
// broken, unparseable response). Lets operators distinguish "faucet is dry"
// from "faucet cannot read its own balance".
const walletBalanceScrapeSuccess = new promClient.Gauge({
  name: 'wrfcoin_faucet_wallet_balance_scrape_success',
  help: '1 if the last faucet wallet balance refresh succeeded, 0 if it failed.',
});

registry.registerMetric(requestsTotal);
registry.registerMetric(captchaChecksTotal);
registry.registerMetric(transfersTotal);
registry.registerMetric(discordNotificationsTotal);
registry.registerMetric(requestDuration);
registry.registerMetric(walletBalanceGauge);
registry.registerMetric(walletBalanceFloorGauge);
registry.registerMetric(walletBalanceScrapeSuccess);

// How often the wallet-balance gauge is refreshed from the node (seconds).
const FAUCET_BALANCE_POLL_SECONDS = Math.max(
  5,
  Number.parseInt(process.env.FAUCET_BALANCE_POLL_SECONDS || '30', 10) || 30,
);

let redisClient;

// A transfer submission that did not produce a receipt. `definitive` is true
// only when the node cannot have admitted the transfer: nothing was sent
// (signing failed, connection refused, the host did not resolve), or the node
// answered 4xx with a rejection body. Everything else after the request left
// (a reset, a timeout, a 5xx, a 2xx without a usable receipt) is UNKNOWN: the
// node may already have accepted it, so the claim's reservations are kept.
class TransferSubmitError extends Error {
  constructor(message, { definitive, reason }) {
    super(message);
    this.name = 'TransferSubmitError';
    this.definitive = definitive === true;
    this.reason = reason;
  }
}

// fetch() failures that happen before any byte of the request is sent. Only
// meaningful because redirects are never followed (redirect: 'manual'): the
// submit is one hop, so a connect error cannot come from a later hop.
const NOT_SENT_NETWORK_CODES = new Set(['ECONNREFUSED', 'ENOTFOUND', 'EAI_AGAIN']);

// Any trace of an admitted transfer, anywhere in a body.
const ACCEPTANCE_KEYS = new Set([
  'tx_id', 'txId', 'transaction_id', 'transactionId', 'tx_hash', 'txHash',
  'hash', 'transactionHash', 'transaction_hash', 'receipt',
]);
// A body nested deeper than the scan can read is treated as carrying
// evidence: an unread subtree may hold an acceptance (infra#1157 review r3).
const ACCEPTANCE_SCAN_MAX_DEPTH = 32;
function hasAcceptanceEvidence(value, depth = 0) {
  if (value === null || typeof value !== 'object') return false;
  if (depth > ACCEPTANCE_SCAN_MAX_DEPTH) return true;
  if (Array.isArray(value)) return value.some((item) => hasAcceptanceEvidence(item, depth + 1));
  for (const [key, child] of Object.entries(value)) {
    if (key === 'accepted' && child === true) return true;
    if (ACCEPTANCE_KEYS.has(key) && child !== null && child !== undefined && child !== '') return true;
    if (hasAcceptanceEvidence(child, depth + 1)) return true;
  }
  return false;
}

// A definitive non-admission from the node (infra#1157 review r2): a DIRECT 4xx
// whose body is exactly core4's LawBook error envelope (launch_api
// helpers.rs envelope_error at core4 65134a64:
// {ok:false, data:null, error:{code, message, correlation_id?},
//  meta:{request_id, timestamp, api_version:"v1"}}) and carries no acceptance
// evidence. REPLAY_REJECTED is never definitive: on a fresh nonce it means the
// nonce was already admitted. Every other answer, including an unrecognised or
// contradictory body, is UNKNOWN.
const ENVELOPE_KEYS = new Set(['ok', 'data', 'error', 'meta']);
function isDefinitiveRejection(status, body) {
  if (!(status >= 400 && status < 500)) return false;
  if (!body || typeof body !== 'object' || Array.isArray(body)) return false;
  if (!Object.keys(body).every((key) => ENVELOPE_KEYS.has(key))) return false;
  if (body.ok !== false || body.data !== null) return false;
  const error = body.error;
  if (!error || typeof error !== 'object' || Array.isArray(error)) return false;
  if (!Object.keys(error).every((key) => key === 'code' || key === 'message' || key === 'correlation_id')) {
    return false;
  }
  if ('correlation_id' in error && typeof error.correlation_id !== 'string') return false;
  if (typeof error.code !== 'string' || !/^[A-Z][A-Z0-9_]*$/.test(error.code)) return false;
  if (typeof error.message !== 'string') return false;
  if (error.code === 'REPLAY_REJECTED') return false;
  // meta is exactly core4's LawBookEnvelopeMeta: request_id, timestamp
  // (both strings) and api_version "v1", nothing else.
  const meta = body.meta;
  if (!meta || typeof meta !== 'object' || Array.isArray(meta)) return false;
  const metaKeys = Object.keys(meta).sort();
  if (metaKeys.join(',') !== 'api_version,request_id,timestamp') return false;
  if (typeof meta.request_id !== 'string' || typeof meta.timestamp !== 'string' || meta.api_version !== 'v1') {
    return false;
  }
  return !hasAcceptanceEvidence(body);
}

class FaucetRequestError extends Error {
  constructor(status, code, message, details) {
    super(message);
    this.name = 'FaucetRequestError';
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

function hashIp(ipAddress) {
  return crypto.createHash('sha256').update(ipAddress).digest('hex');
}

function parseTrustProxySetting(value) {
  const text = String(value || 'false').trim().toLowerCase();
  if (!text || text === 'false' || text === 'off' || text === '0' || text === 'none') {
    return false;
  }
  if (/^\d+$/.test(text)) {
    const hopCount = Number.parseInt(text, 10);
    return hopCount > 0 ? hopCount : false;
  }
  return false;
}

function getClientIp(req) {
  const peerIp = req.socket?.remoteAddress || req.connection?.remoteAddress;
  if (TRUST_PROXY_SETTING) {
    return req.ip || peerIp || 'unknown';
  }

  return peerIp || req.ip || 'unknown';
}

// Identity headers injected by `tailscale serve`. Tailscale strips any
// client-supplied copies of these headers before adding its own, so when they
// are present they authentically identify the tailnet user that originated the
// request. Node lower-cases header names, so we match in lower case.
const TAILSCALE_LOGIN_HEADER = 'tailscale-user-login';
const TAILSCALE_NAME_HEADER = 'tailscale-user-name';

// Coerce a header value to a single trimmed string. Node usually joins repeated
// headers into one comma-separated string, but be defensive about arrays.
function firstHeaderValue(value) {
  if (Array.isArray(value)) {
    return value.length > 0 ? String(value[0]).trim() : '';
  }
  return value === undefined || value === null ? '' : String(value).trim();
}

// Resolve the authenticated tailnet user from `tailscale serve` headers,
// preferring the stable login (email-like) over the mutable display name.
// Returns null when no Tailscale identity header is present.
function getTailscaleIdentity(req) {
  const headers = req?.headers || {};
  const login = firstHeaderValue(headers[TAILSCALE_LOGIN_HEADER]);
  if (login) {
    return { source: 'login', value: login };
  }
  const name = firstHeaderValue(headers[TAILSCALE_NAME_HEADER]);
  if (name) {
    return { source: 'name', value: name };
  }
  return null;
}

// Resolve the per-user rate-limit identity for a faucet request.
//
// Behind `tailscale serve` the faucet listens on 127.0.0.1, so the peer IP
// collapses to loopback for EVERY user and an IP-keyed cooldown degenerates
// into a single shared bucket. When Tailscale supplies an authenticated user
// identity we key the cooldown on that user instead. We fall back to the peer
// IP — the original, pre-tailnet behavior — whenever no Tailscale identity
// header is present, keeping direct/LAN access backward-compatible.
//
// Both branches return a sha256 fingerprint (never the raw email/IP) so redis
// keys, logs, and receipts do not leak the underlying identity.
function getRateLimitIdentity(req) {
  const tsIdentity = getTailscaleIdentity(req);
  if (tsIdentity) {
    // Lower-case so the same user maps to one bucket regardless of header case.
    const fingerprint = hashIp(`tsuser:${tsIdentity.value.toLowerCase()}`);
    return {
      kind: 'tsuser',
      source: tsIdentity.source,
      fingerprint,
      key: `${REDIS_TSUSER_PREFIX}${fingerprint}`,
    };
  }

  const ip = getClientIp(req);
  const fingerprint = hashIp(ip);
  return {
    kind: 'ip',
    source: 'peer',
    fingerprint,
    key: `${REDIS_KEY_PREFIX}${fingerprint}`,
  };
}

// Resolve the effective client IP and rate-limit identity for a faucet
// request. For trusted-proxy requests (#857 Option B — backend onboarding
// proxy authenticated via the operator token) the identity comes from the
// forwarded x-client-ip header, otherwise every proxied user after the first
// would share the backend container's IP bucket. x-client-ip is honored ONLY
// when trustedProxy is true.
function resolveRequestIdentity(req, trustedProxy) {
  const forwardedClientIp = trustedProxy
    ? firstHeaderValue(req.headers?.['x-client-ip'])
    : '';
  if (forwardedClientIp) {
    const fingerprint = hashIp(forwardedClientIp);
    return {
      remoteIp: forwardedClientIp,
      rateLimitIdentity: {
        kind: 'ip',
        source: 'trusted-proxy',
        fingerprint,
        key: `${REDIS_KEY_PREFIX}${fingerprint}`,
      },
    };
  }
  return {
    remoteIp: getClientIp(req),
    rateLimitIdentity: getRateLimitIdentity(req),
  };
}

function normalizeCaptchaProvider(value) {
  const provider = String(value || 'off').trim().toLowerCase();
  if (provider === 'recaptcha') {
    return 'recaptcha-v3';
  }
  return provider;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function jsonError(res, status, code, message, details) {
  // Every refusal that names a wait also says it in the standard header.
  const retryAfter = Number(details?.retryAfterSeconds);
  if ((status === 429 || status === 409) && Number.isFinite(retryAfter) && retryAfter > 0) {
    res.set('Retry-After', String(Math.ceil(retryAfter)));
  }
  res.status(status).json({
    error: {
      code,
      message,
      ...(details ? { details } : {}),
    },
  });
}

const EVM_ADDRESS_PATTERN = /^0x[0-9a-fA-F]{40}$/;
const NATIVE_ADDRESS_PATTERN = /^wrf[0-9a-fA-F]{40}$/i;

function isSupportedWalletAddress(walletAddress) {
  const value = String(walletAddress || '').trim();
  return EVM_ADDRESS_PATTERN.test(value) || NATIVE_ADDRESS_PATTERN.test(value);
}

function normalizeWalletAddress(walletAddress) {
  const value = String(walletAddress || '').trim().toLowerCase();
  // `wrf…` is a display encoding of the same 20 bytes. core4 transfer APIs
  // accept canonical 0x hex only, and the daily cap must not split one account
  // into two namespaces just because the caller used the display form.
  return NATIVE_ADDRESS_PATTERN.test(value) ? `0x${value.slice(3)}` : value;
}

// Convert a whole-WRF amount string to a u64 base-unit value (×10^8).
// Supports fractional input (e.g. "0.5"). Throws on malformed input.
function toBaseUnits(wholeAmount) {
  const text = String(wholeAmount).trim();
  if (!/^\d+(\.\d+)?$/.test(text)) {
    throw new Error(`FAUCET_AMOUNT must be a non-negative decimal, got "${wholeAmount}"`);
  }
  const [intPart, fracPartRaw = ''] = text.split('.');
  const fracPart = fracPartRaw.slice(0, 8).padEnd(8, '0');
  if (fracPartRaw.length > 8) {
    throw new Error('FAUCET_AMOUNT has more precision than 8 decimal places');
  }
  const base = BigInt(intPart) * WRF_UNITS_PER_COIN + BigInt(fracPart || '0');
  // The node decodes amount into a u64 and the value is sent as a JSON number,
  // so it must be a safe integer.
  if (base > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error('FAUCET_AMOUNT in base units exceeds the safe JSON integer range');
  }
  return Number(base);
}

function parseRequiredBaseUnits(value, name) {
  if (value === undefined || value === null || String(value).trim() === '') {
    throw new Error(`${name} must be set in whole WRF before faucet startup`);
  }
  const parsed = toBaseUnits(value);
  if (parsed <= 0) {
    throw new Error(`${name} must be greater than zero`);
  }
  return parsed;
}

function validateHighWaterConfig({
  highWaterMark = FAUCET_HIGH_WATER_MARK,
  refillSource = FAUCET_REFILL_SOURCE,
} = {}) {
  const highWaterMarkBaseUnits = parseRequiredBaseUnits(highWaterMark, 'FAUCET_HIGH_WATER_MARK');
  if (!['manual', 'emission', 'treasury'].includes(refillSource)) {
    throw new Error('FAUCET_REFILL_SOURCE must be manual, emission, or treasury');
  }
  return { highWaterMarkBaseUnits, refillSource };
}

function assertSafeBaseUnitValue(value, name) {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error(`${name} must be a non-negative safe base-unit integer`);
  }
}

// Compute the only amount a refill source may add. `sourceEarnedBaseUnits`
// and `totalRefilledBaseUnits` make the long-term earned-funds invariant
// explicit, while the mark makes withdrawal-triggered refill bounded.
function calculateRefillAmount({
  balanceBaseUnits,
  sourceEarnedBaseUnits,
  totalRefilledBaseUnits,
  highWaterMarkBaseUnits,
}) {
  assertSafeBaseUnitValue(balanceBaseUnits, 'balanceBaseUnits');
  assertSafeBaseUnitValue(sourceEarnedBaseUnits, 'sourceEarnedBaseUnits');
  assertSafeBaseUnitValue(totalRefilledBaseUnits, 'totalRefilledBaseUnits');
  assertSafeBaseUnitValue(highWaterMarkBaseUnits, 'highWaterMarkBaseUnits');
  if (highWaterMarkBaseUnits === 0) {
    throw new Error('highWaterMarkBaseUnits must be greater than zero');
  }
  if (balanceBaseUnits >= highWaterMarkBaseUnits) {
    return 0;
  }
  const sourceRemaining = Math.max(0, sourceEarnedBaseUnits - totalRefilledBaseUnits);
  const room = highWaterMarkBaseUnits - balanceBaseUnits;
  return Math.min(room, sourceRemaining);
}

// Funding is deliberately an interface, not a selected consensus source.
// Implementations must provide the source's cumulative earned amount and a
// transfer operation. The transfer is awaited before callers account for it.
async function refillFaucetBucket({
  balanceBaseUnits,
  sourceEarnedBaseUnits,
  totalRefilledBaseUnits,
  highWaterMarkBaseUnits = validateHighWaterConfig().highWaterMarkBaseUnits,
  fundingSource,
}) {
  if (!fundingSource || typeof fundingSource.transferToBucket !== 'function') {
    throw new Error('fundingSource.transferToBucket is required for a refill');
  }
  const amountBaseUnits = calculateRefillAmount({
    balanceBaseUnits,
    sourceEarnedBaseUnits,
    totalRefilledBaseUnits,
    highWaterMarkBaseUnits,
  });
  if (amountBaseUnits === 0) {
    return { amountBaseUnits: 0, refilledBaseUnits: totalRefilledBaseUnits };
  }
  await fundingSource.transferToBucket(amountBaseUnits);
  return {
    amountBaseUnits,
    refilledBaseUnits: totalRefilledBaseUnits + amountBaseUnits,
  };
}

function parseBalanceBaseUnits(value) {
  if (value === null || value === undefined) {
    return null;
  }
  if (typeof value === 'number' && Number.isFinite(value)) {
    return Math.trunc(value);
  }
  if (typeof value === 'bigint') {
    if (value > BigInt(Number.MAX_SAFE_INTEGER)) {
      throw new Error('Wallet balance exceeds safe JSON integer range');
    }
    return Number(value);
  }
  const text = String(value).trim();
  if (!text) {
    return null;
  }
  if (/^\d+$/.test(text)) {
    const parsed = BigInt(text);
    if (parsed > BigInt(Number.MAX_SAFE_INTEGER)) {
      throw new Error('Wallet balance exceeds safe JSON integer range');
    }
    return Number(parsed);
  }
  if (/^\d+(\.\d+)?$/.test(text)) {
    return toBaseUnits(text);
  }
  return null;
}

function extractWalletBalanceBaseUnits(result) {
  const candidate = result?.data ?? result ?? {};
  return parseBalanceBaseUnits(
    candidate.balance ??
      candidate.availableBalance ??
      candidate.available_balance ??
      candidate.spendableBalance ??
      candidate.spendable_balance ??
      candidate.account?.balance ??
      candidate.account?.availableBalance ??
      candidate.account?.available_balance ??
      candidate.account?.spendableBalance ??
      candidate.account?.spendable_balance ??
      candidate.wallet?.balance ??
      candidate.wallet?.availableBalance ??
      candidate.wallet?.available_balance ??
      candidate.wallet?.spendableBalance ??
      candidate.wallet?.spendable_balance ??
      null,
  );
}

function dailyKeySuffix(now = new Date()) {
  return now.toISOString().slice(0, 10);
}

// Retry-After for a per-UTC-day limit: whole seconds until the next
// 00:00:00Z, from the calendar, at least 1 (23:59:59.500Z -> 1, exactly
// 00:00:00Z -> 86400). infra#1157 review: the Redis key margin is NOT added.
function secondsUntilNextUtcDay(now = new Date()) {
  const nextDay = Date.UTC(
    now.getUTCFullYear(),
    now.getUTCMonth(),
    now.getUTCDate() + 1,
    0,
    0,
    0,
  );
  return Math.max(1, Math.ceil((nextDay - now.getTime()) / 1000));
}

// The Redis TTL of a daily counter key: the same calendar wait plus a margin,
// so a key never expires before its day ends. Never sent to a client.
const DAILY_KEY_TTL_MARGIN_SECONDS = 60;
function dailyKeyTtlSeconds(now = new Date()) {
  return secondsUntilNextUtcDay(now) + DAILY_KEY_TTL_MARGIN_SECONDS;
}

function buildDailyPayoutKeys(walletAddress, now = new Date(), deviceId = null) {
  const day = dailyKeySuffix(now);
  const normalizedWallet = normalizeWalletAddress(walletAddress);
  return {
    walletKey: `${REDIS_WALLET_DAILY_PREFIX}${normalizedWallet}:${day}`,
    globalKey: `${REDIS_GLOBAL_DAILY_PREFIX}${day}`,
    ...(deviceId ? { deviceKey: `${REDIS_DEVICE_DAILY_PREFIX}${deviceId}:${day}` } : {}),
    day,
  };
}

// The device id stored in Redis: the identity kind plus its sha256
// fingerprint. A raw IP or tailnet login never reaches a key.
function deviceIdForIdentity(identity) {
  return `${identity.kind}:${identity.fingerprint}`;
}

// One uniform refusal for the wallet and device caps. A caller cannot tell
// which cap it hit, so submitting someone else's address reveals nothing
// about that address's claims today.
const DAILY_LIMIT_CODE = 'DAILY_LIMIT_REACHED';
const DAILY_LIMIT_MESSAGE =
  "This wallet or device has reached today's faucet limit. Try again after the UTC day resets.";

function captchaReadiness({
  provider = CAPTCHA_PROVIDER,
  walletConfigured = Boolean(FAUCET_WALLET_PRIVKEY),
  hcaptchaSecret = HCAPTCHA_SECRET,
  hcaptchaSitekey = HCAPTCHA_SITEKEY,
  recaptchaSecret = RECAPTCHA_SECRET,
  recaptchaSitekey = RECAPTCHA_SITEKEY,
} = {}) {
  if (!walletConfigured) {
    return { ok: true };
  }
  if (provider === 'off') {
    return {
      ok: false,
      reason: 'CAPTCHA_PROVIDER must be hcaptcha or recaptcha-v3 before faucet payouts are enabled',
    };
  }
  if (provider === 'hcaptcha' && (!hcaptchaSecret || !hcaptchaSitekey)) {
    return {
      ok: false,
      reason: 'HCAPTCHA_SECRET and HCAPTCHA_SITEKEY are required before faucet payouts are enabled',
    };
  }
  if (provider === 'recaptcha-v3' && (!recaptchaSecret || !recaptchaSitekey)) {
    return {
      ok: false,
      reason: 'RECAPTCHA_SECRET and RECAPTCHA_SITEKEY are required before faucet payouts are enabled',
    };
  }
  return { ok: true };
}

function faucetDispenseReadiness({
  walletConfigured = Boolean(FAUCET_WALLET_PRIVKEY && FAUCET_WALLET_ADDRESS),
  apiTokenConfigured = Boolean(FAUCET_API_TOKEN),
  captcha = captchaReadiness({ walletConfigured }),
} = {}) {
  if (!walletConfigured || !apiTokenConfigured) {
    return { directClaimsEnabled: false, dispenseMode: 'unconfigured' };
  }
  if (!captcha.ok) {
    return { directClaimsEnabled: false, dispenseMode: 'proxy-only' };
  }
  return { directClaimsEnabled: true, dispenseMode: 'direct' };
}

function assertFaucetConfiguredForPayout({ requireCaptcha = true } = {}) {
  if (!FAUCET_WALLET_PRIVKEY) {
    throw new FaucetRequestError(
      503,
      'FAUCET_NOT_CONFIGURED',
      'FAUCET_WALLET_PRIVKEY must be set before the faucet can send WRF',
    );
  }
  if (!FAUCET_WALLET_ADDRESS) {
    throw new FaucetRequestError(
      503,
      'FAUCET_NOT_CONFIGURED',
      'FAUCET_WALLET_ADDRESS must be set before the faucet can send WRF',
    );
  }
  if (!FAUCET_API_TOKEN) {
    throw new FaucetRequestError(
      503,
      'FAUCET_NOT_CONFIGURED',
      'FAUCET_API_TOKEN (or WRFCOIN_OPERATOR_TOKEN) is required to authenticate to the node',
    );
  }

  if (requireCaptcha) {
    const readiness = captchaReadiness();
    if (!readiness.ok) {
      throw new FaucetRequestError(503, 'CAPTCHA_NOT_CONFIGURED', readiness.reason);
    }
  }
}

function parseReceipt(result, fallbackAddress) {
  const candidate = result || {};
  const txHash =
    candidate.tx_id ||
    candidate.txId ||
    candidate.txHash ||
    candidate.tx_hash ||
    candidate.hash ||
    candidate.transactionHash ||
    candidate.transaction_hash ||
    candidate.receipt?.tx_id ||
    candidate.receipt?.txHash ||
    candidate.receipt?.hash ||
    candidate.receipt?.transactionHash ||
    null;

  const balance =
    candidate.balance ??
    candidate.newBalance ??
    candidate.remainingBalance ??
    candidate.result?.balance ??
    null;

  return {
    txHash,
    balance,
    address: candidate.address || candidate.to || fallbackAddress,
    raw: candidate,
  };
}

async function ensureRedis() {
  if (!REDIS_URL) {
    throw new Error('REDIS_URL is required for faucet rate limiting');
  }

  redisClient = createClient({
    url: REDIS_URL,
    socket: {
      // Auto-reconnect with capped backoff so a transient Redis outage
      // self-heals without a process restart. Returning a delay (never an
      // Error) keeps the client retrying indefinitely.
      reconnectStrategy: (retries) => Math.min(retries * 200, 5000),
    },
  });
  redisClient.on('error', (error) => {
    console.error('[faucet] redis error:', error);
  });
  await redisClient.connect();
  await redisClient.ping();
}

async function verifyCaptcha({ token, remoteIp }) {
  if (CAPTCHA_PROVIDER === 'off') {
    return { ok: true, provider: 'off' };
  }

  if (!token) {
    throw new Error('Captcha token is required');
  }

  let verifyUrl;
  let params;
  let secret;

  if (CAPTCHA_PROVIDER === 'hcaptcha') {
    secret = HCAPTCHA_SECRET;
    verifyUrl = 'https://hcaptcha.com/siteverify';
    params = {
      secret,
      response: token,
      remoteip: remoteIp,
    };
  } else if (CAPTCHA_PROVIDER === 'recaptcha-v3') {
    secret = RECAPTCHA_SECRET;
    verifyUrl = 'https://www.google.com/recaptcha/api/siteverify';
    params = {
      secret,
      response: token,
      remoteip: remoteIp,
    };
  } else {
    throw new Error(`Unsupported captcha provider: ${CAPTCHA_PROVIDER}`);
  }

  if (!secret) {
    throw new Error(`Captcha secret is required for provider ${CAPTCHA_PROVIDER}`);
  }

  const response = await fetch(verifyUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams(params),
  });

  const result = await response.json().catch(() => ({}));
  const providerKey = CAPTCHA_PROVIDER === 'hcaptcha' ? 'hcaptcha' : 'recaptcha-v3';

  if (!response.ok || !result.success) {
    captchaChecksTotal.inc({ provider: providerKey, result: 'fail' });
    throw new Error(
      result['error-codes']?.join(', ') || 'Captcha verification failed',
    );
  }

  if (CAPTCHA_PROVIDER === 'recaptcha-v3') {
    const score = Number.parseFloat(result.score || '0');
    if (Number.isFinite(score) && score < RECAPTCHA_MIN_SCORE) {
      captchaChecksTotal.inc({ provider: providerKey, result: 'fail' });
      throw new Error(`Captcha score ${score} is below threshold ${RECAPTCHA_MIN_SCORE}`);
    }
  }

  captchaChecksTotal.inc({ provider: providerKey, result: 'ok' });
  return {
    ok: true,
    provider: providerKey,
    score: result.score ?? null,
  };
}

async function getFaucetWalletBalance() {
  const balancePath = FAUCET_WALLET_BALANCE_PATH.replace(
    '{address}',
    encodeURIComponent(FAUCET_WALLET_ADDRESS),
  );
  const response = await fetch(`${FAUCET_NODE_URL}${balancePath}`, {
    headers: {
      Authorization: `Bearer ${FAUCET_API_TOKEN}`,
    },
  });
  const result = await response.json().catch(() => ({}));

  if (!response.ok) {
    throw new Error(
      result?.error?.message ||
        result?.message ||
        `Faucet wallet balance check returned ${response.status}`,
    );
  }

  const balance = extractWalletBalanceBaseUnits(result);
  if (balance === null) {
    throw new Error('Faucet wallet balance response did not include a parseable balance');
  }
  return balance;
}

async function assertWalletBalanceFloor(amountBaseUnits, suppliedBalance) {
  let balance;
  try {
    balance = suppliedBalance ?? await getFaucetWalletBalance();
  } catch (error) {
    throw new FaucetRequestError(
      503,
      'FAUCET_WALLET_BALANCE_UNAVAILABLE',
      error instanceof Error ? error.message : 'Faucet wallet balance check failed',
    );
  }
  const floor = toBaseUnits(FAUCET_WALLET_BALANCE_FLOOR);
  if (balance - amountBaseUnits < floor) {
    throw new FaucetRequestError(
      503,
      'FAUCET_WALLET_LOW_BALANCE',
      'Faucet wallet balance is below the configured post-transfer floor',
      {
        balance,
        requiredPostTransferFloor: floor,
      },
    );
  }
}

async function reserveDailyCap({ key, amountBaseUnits, capBaseUnits, ttlSeconds }) {
  const script = `
local current = tonumber(redis.call('GET', KEYS[1]) or '0')
local amount = tonumber(ARGV[1])
local cap = tonumber(ARGV[2])
local ttl = tonumber(ARGV[3])
if current + amount > cap then
  return {0, current}
end
local next_value = redis.call('INCRBY', KEYS[1], amount)
if next_value == amount then
  redis.call('EXPIRE', KEYS[1], ttl)
end
return {1, next_value}
`;

  const result = await redisClient.eval(script, {
    keys: [key],
    arguments: [String(amountBaseUnits), String(capBaseUnits), String(ttlSeconds)],
  });

  const accepted = Array.isArray(result) && Number(result[0]) === 1;
  return {
    accepted,
    current: Array.isArray(result) ? Number(result[1]) : 0,
  };
}

// Pure policy calculation shared by payout and future refill paths. Redis is
// still the atomic authority for concurrent reservations; this helper defines
// the invariant those paths must apply to every amount, including a refill.
function evaluateDailyPayoutCaps({
  walletSpentBaseUnits,
  globalSpentBaseUnits,
  amountBaseUnits,
  walletCapBaseUnits = FAUCET_WALLET_DAILY_CAP_BASE_UNITS,
  globalCapBaseUnits = FAUCET_GLOBAL_DAILY_CAP_BASE_UNITS,
}) {
  const values = [
    walletSpentBaseUnits,
    globalSpentBaseUnits,
    amountBaseUnits,
    walletCapBaseUnits,
    globalCapBaseUnits,
  ];
  if (values.some((value) => !Number.isSafeInteger(value) || value < 0)) {
    throw new Error('daily payout caps require non-negative safe base-unit integers');
  }
  if (walletSpentBaseUnits + amountBaseUnits > walletCapBaseUnits) {
    return { accepted: false, reason: 'wallet', walletNext: walletSpentBaseUnits, globalNext: globalSpentBaseUnits };
  }
  if (globalSpentBaseUnits + amountBaseUnits > globalCapBaseUnits) {
    return { accepted: false, reason: 'global', walletNext: walletSpentBaseUnits, globalNext: globalSpentBaseUnits };
  }
  return {
    accepted: true,
    reason: null,
    walletNext: walletSpentBaseUnits + amountBaseUnits,
    globalNext: globalSpentBaseUnits + amountBaseUnits,
  };
}

async function reserveDailyPayoutCaps(walletAddress, amountBaseUnits, deviceId = null) {
  const now = new Date();
  const { walletKey, globalKey, deviceKey } = buildDailyPayoutKeys(walletAddress, now, deviceId);
  const ttlSeconds = dailyKeyTtlSeconds(now);
  const retryAfterSeconds = secondsUntilNextUtcDay(now);
  const reservations = [];
  const dailyLimit = () => {
    const error = new FaucetRequestError(429, DAILY_LIMIT_CODE, DAILY_LIMIT_MESSAGE, {
      retryAfterSeconds,
    });
    // The device's cooldown stays spent: a refused probe of another wallet's
    // cap costs a claim slot, like a successful claim would.
    error.keepCooldown = true;
    return error;
  };

  const caps = [
    ...(deviceKey ? [{ key: deviceKey, capBaseUnits: FAUCET_DEVICE_DAILY_CAP_BASE_UNITS }] : []),
    { key: walletKey, capBaseUnits: FAUCET_WALLET_DAILY_CAP_BASE_UNITS },
  ];
  for (const { key, capBaseUnits } of caps) {
    const reservation = await reserveDailyCap({ key, amountBaseUnits, capBaseUnits, ttlSeconds });
    if (!reservation.accepted) {
      await rollbackDailyReservations(reservations);
      throw dailyLimit();
    }
    reservations.push({ key, amountBaseUnits });
  }

  const globalReservation = await reserveDailyCap({
    key: globalKey,
    amountBaseUnits,
    capBaseUnits: FAUCET_GLOBAL_DAILY_CAP_BASE_UNITS,
    ttlSeconds,
  });
  if (!globalReservation.accepted) {
    await rollbackDailyReservations(reservations);
    throw new FaucetRequestError(
      429,
      'GLOBAL_DAILY_LIMIT_EXCEEDED',
      'The faucet has reached its global daily payout cap',
      {
        dailyCap: FAUCET_GLOBAL_DAILY_CAP,
        denomination: FAUCET_DENOMINATION,
        retryAfterSeconds,
      },
    );
  }
  reservations.push({ key: globalKey, amountBaseUnits });

  return reservations;
}

async function rollbackDailyReservations(reservations) {
  await Promise.all(
    reservations.map(({ key, amountBaseUnits }) =>
      redisClient.decrBy(key, amountBaseUnits).catch(() => {}),
    ),
  );
}

async function sendDiscordNotification({ title, description, fields, color = 0x4db6ff }) {
  if (!DISCORD_WEBHOOK_URL) {
    return;
  }

  try {
    const payload = {
      username: DISCORD_WEBHOOK_USERNAME,
      ...(DISCORD_WEBHOOK_AVATAR_URL ? { avatar_url: DISCORD_WEBHOOK_AVATAR_URL } : {}),
      embeds: [
        {
          title,
          description,
          color,
          fields,
          timestamp: new Date().toISOString(),
        },
      ],
    };

    const response = await fetch(DISCORD_WEBHOOK_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });

    if (!response.ok) {
      throw new Error(`Discord webhook returned ${response.status}`);
    }

    discordNotificationsTotal.inc({ result: 'ok' });
  } catch (error) {
    discordNotificationsTotal.inc({ result: 'fail' });
    console.warn('[faucet] discord webhook failed:', error instanceof Error ? error.message : error);
  }
}

// Submit a faucet transfer against the node's REST launch_api.
//
// Endpoint: POST {FAUCET_NODE_URL}/transactions/submit  (routes/mod.rs)
// Auth:     Authorization: Bearer <token>  (Contributor role; Operator satisfies it)
// Body:     { from, to, amount (u64 base units), transparent_opt_out: true }
//           transparent_opt_out=true makes a transparent Transfer so recipients
//           immediately see/spend the funds (the default is a confidential
//           transfer, which is wrong for an onboarding faucet).
// Response: LawBook envelope { ok, data: { accepted, tx_id, ... }, error, meta }.

// core4 65134a64 state.rs:7103 requires the exact account nonce.
// Never manufacture a nonce from wall time or randomness.
function parseAccountNonce(account, expectedAddress = FAUCET_WALLET_ADDRESS) {
  const value = account?.nonce;
  const nonce = typeof value === 'number' && Number.isSafeInteger(value)
    ? String(value) : value;
  if (typeof nonce !== 'string' || !/^(0|[1-9][0-9]{0,19})$/.test(nonce) ||
      BigInt(nonce) >= 18446744073709551615n) {
    throw new Error('Account nonce is missing, malformed or exhausted');
  }
  if (normalizeWalletAddress(account.address) !== normalizeWalletAddress(expectedAddress)) {
    throw new Error('Account nonce belongs to another address');
  }
  return nonce;
}

// One account read, five seconds, 64 KiB, no redirect and no retry.
async function readBoundedNodeJson(response) {
  const chunks = [];
  let size = 0;
  for await (const chunk of response.body) {
    size += chunk.byteLength;
    if (size > 65536) throw new Error('Node response exceeds the account-read budget');
    chunks.push(Buffer.from(chunk));
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

async function getFaucetAccount(sourceAddress = FAUCET_WALLET_ADDRESS) {
  try {
    if (!isSupportedWalletAddress(sourceAddress)) throw new Error('Invalid source account');
    const address = normalizeWalletAddress(sourceAddress);
    const accountPath = FAUCET_WALLET_BALANCE_PATH.replace('{address}', encodeURIComponent(address));
    const response = await fetch(`${FAUCET_NODE_URL}${accountPath}`, {
      headers: { Authorization: `Bearer ${FAUCET_API_TOKEN}` },
      redirect: 'manual',
      signal: AbortSignal.timeout(5000),
    });
    const result = await readBoundedNodeJson(response);
    if (!response.ok || result?.ok !== true || result?.error) throw new Error('Account read refused');
    const nonce = parseAccountNonce(result.data, address);
    const balance = extractWalletBalanceBaseUnits(result);
    if (balance === null) throw new Error('Account balance unavailable');
    return { nonce, balance };
  } catch (_error) {
    throw new FaucetRequestError(503, 'FAUCET_WALLET_NONCE_UNAVAILABLE', 'Faucet account state is unavailable');
  }
}

// The process guard bounds concurrent HTTP submissions. The durable Redis
// fence also prevents another process/restart from reusing an admitted or
// uncertain nonce while the node still reports it as current. No expiry:
// only authoritative nonce advancement or definitive non-admission permits
// reuse. One key per faucet account; decimal comparisons avoid Lua doubles.
let transferInFlight = false;
let pendingNonceRelease = null;
const NONCE_FENCE_KEY = `${REDIS_GLOBAL_DAILY_PREFIX}nonce:${normalizeWalletAddress(FAUCET_WALLET_ADDRESS)}`;
const NONCE_RESERVE_LUA = `-- faucet-nonce-reserve
local old = redis.call('GET', KEYS[1])
local nonce = ARGV[1]
if old then
  local old_nonce = string.match(old, '^(%d+):') or string.match(old, '^%d+$')
  if not old_nonce then return 0 end
  if #old_nonce > #nonce or (#old_nonce == #nonce and old_nonce >= nonce) then return 0 end
end
redis.call('SET', KEYS[1], ARGV[2])
return 1
`;
const NONCE_RELEASE_LUA = `-- faucet-nonce-release
if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
return redis.call('DEL', KEYS[1])
`;

// Retries concern only an idempotent, ownership-bound Redis deletion, never
// the transfer POST or daily-cap refunds. A lost response may leave a late
// command queued: comparing the full token protects a newer same-nonce owner.
async function releaseNonceFence(value) {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    let timer;
    try {
      const result = await Promise.race([
        redisClient.eval(NONCE_RELEASE_LUA, { keys: [NONCE_FENCE_KEY], arguments: [value] }),
        new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Nonce release deadline')), 1000); }),
      ]);
      if (result === 0 || result === 1) return true;
    } catch (_error) {
      // Keep the matching release pending; the next admitted request retries it.
    } finally {
      clearTimeout(timer);
    }
  }
  return false;
}

function nonceCleanupError(res) {
  return jsonError(res, 503, 'FAUCET_NONCE_CLEANUP_PENDING', 'Faucet nonce cleanup is pending; try later');
}

// Transparent transfers must carry a from-account ed25519 authorization
// (#1727/#1848): sign the node's canonical message with the faucet wallet key
// and attach auth_pubkey/auth_signature (raw hex). The server independently
// binds sha3-256(pubkey)[..20] to `from`, so a mismatched key fails closed.
//
// v2 (#2034/core4 PR #2064, infra#626): the node now folds the runtime chain
// identity (chain_id, network_id) into the preimage immediately after the
// domain tag and verifies fail-closed against it, so a v1 signature no
// longer verifies at all — bump the tag and fold chain_domain to match.
const TRANSPARENT_TRANSFER_AUTH_DOMAIN = 'wrfcoin_transparent_transfer_auth_v2';
// PKCS8 DER prefix that wraps a raw 32-byte ed25519 seed (RFC 8410).
const ED25519_PKCS8_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');

function ed25519KeyFromSeedHex(seedHex) {
  const seed = Buffer.from(String(seedHex).replace(/^0x/i, ''), 'hex');
  if (seed.length !== 32) {
    throw new Error('FAUCET_WALLET_PRIVKEY must be a 32-byte hex ed25519 seed');
  }
  return crypto.createPrivateKey({
    key: Buffer.concat([ED25519_PKCS8_PREFIX, seed]),
    format: 'der',
    type: 'pkcs8',
  });
}

// Mirrors core4 shared-protocol transparent_transfer_authorization_message_with_domain()
// (shared-protocol/src/blockchain/transaction.rs, push_chain_domain):
// domain || chain_domain || u32LE(len(from)) || from || u32LE(len(to)) || to
//   || u64LE(amount) || u64LE(nonce)
// where chain_domain = str(chain_id) || str(network_id) and str(s) is
// u32LE(len(s_bytes)) || s_bytes (see docs/specifications/SIGNING_PREIMAGE_V2.md
// in core4). chain_id/network_id are resolved from WRFCOIN_CHAIN_ID /
// WRFCOIN_NETWORK_ID — MUST match what the node signer/verifier resolves.
const u32le = (n) => {
  const b = Buffer.alloc(4);
  b.writeUInt32LE(n);
  return b;
};
const u64le = (v) => {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(BigInt(v));
  return b;
};
// str(s) per SIGNING_PREIMAGE_V2.md: u32LE(len(utf8 bytes)) || utf8 bytes.
function encodeLenPrefixedString(s) {
  const bytes = Buffer.from(String(s), 'utf8');
  return Buffer.concat([u32le(bytes.length), bytes]);
}

// chainId/networkId default to the resolved deployment identity; overridable
// so tests can reproduce the core4 golden vector (docs/specifications/
// SIGNING_PREIMAGE_V2.md) for a fixed chain_id/network_id without depending
// on process.env at module-load time.
function buildTransferAuthMessage(
  from,
  to,
  amountBaseUnits,
  nonce,
  chainId = WRFCOIN_CHAIN_ID,
  networkId = WRFCOIN_NETWORK_ID,
) {
  return Buffer.concat([
    Buffer.from(TRANSPARENT_TRANSFER_AUTH_DOMAIN, 'utf8'),
    encodeLenPrefixedString(chainId),
    encodeLenPrefixedString(networkId),
    encodeLenPrefixedString(from),
    encodeLenPrefixedString(to),
    u64le(amountBaseUnits),
    u64le(nonce),
  ]);
}

function signTransferAuthorization({ from, to, amountBaseUnits, nonce, privkeyHex }) {
  const key = ed25519KeyFromSeedHex(privkeyHex);
  const message = buildTransferAuthMessage(from, to, amountBaseUnits, nonce);
  const signature = crypto.sign(null, message, key);
  // Raw 32-byte pubkey = last 32 bytes of the SPKI DER export.
  const spki = crypto.createPublicKey(key).export({ format: 'der', type: 'spki' });
  return {
    auth_pubkey: spki.subarray(spki.length - 32).toString('hex'),
    auth_signature: signature.toString('hex'),
  };
}

async function requestTransfer({ walletAddress, nonce, amountBaseUnits = toBaseUnits(FAUCET_AMOUNT) }) {
  let auth_pubkey;
  let auth_signature;
  try {
    ({ auth_pubkey, auth_signature } = signTransferAuthorization({
      from: FAUCET_WALLET_ADDRESS,
      to: walletAddress,
      amountBaseUnits,
      nonce,
      privkeyHex: FAUCET_WALLET_PRIVKEY,
    }));
  } catch (error) {
    throw new TransferSubmitError(`Faucet transfer was not signed: ${error.message}`, {
      definitive: true,
      reason: 'not_sent',
    });
  }

  const body = {
    from: FAUCET_WALLET_ADDRESS,
    to: walletAddress,
    amount: amountBaseUnits,
    transparent_opt_out: true,
    transparent_opt_out_reason: 'testnet-faucet',
    nonce,
    auth_pubkey,
    auth_signature,
  };

  let response;
  try {
    response = await fetch(`${FAUCET_NODE_URL}${FAUCET_SUBMIT_PATH}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${FAUCET_API_TOKEN}`,
      },
      body: JSON.stringify(body),
      // Never follow a redirect: the transfer may already be admitted, and a
      // later hop's answer says nothing about it (infra#1157 review r2).
      redirect: 'manual',
      signal: AbortSignal.timeout(10000),
    });
  } catch (error) {
    const code = error?.cause?.code || error?.code || '';
    const notSent = NOT_SENT_NETWORK_CODES.has(code);
    throw new TransferSubmitError(`Faucet node submit failed: ${code || error.message}`, {
      definitive: notSent,
      reason: notSent ? 'not_sent' : 'no_response',
    });
  }

  let result = null;
  try {
    result = await readBoundedNodeJson(response);
  } catch (_error) {
    result = null;
  }

  if (response.status >= 300 && response.status < 400) {
    throw new TransferSubmitError(`Faucet node submit answered a redirect (${response.status})`, {
      definitive: false,
      reason: `redirect_${response.status}`,
    });
  }

  if (!response.ok) {
    if (isDefinitiveRejection(response.status, result)) {
      // The node refused the transfer before admitting it.
      throw new TransferSubmitError(
        `Faucet node submit returned ${response.status}: ${result.error.code}: ${result.error.message}`,
        { definitive: true, reason: 'rejected' },
      );
    }
    throw new TransferSubmitError(`Faucet node submit returned ${response.status}`, {
      definitive: false,
      reason: `http_${response.status}`,
    });
  }

  // LawBook envelope: prefer data; tolerate a bare body for forward compat.
  // A 2xx is never a definitive rejection, whatever its body says.
  if (result?.ok === false || result?.error) {
    throw new TransferSubmitError('Node answered 2xx with an error envelope', {
      definitive: false,
      reason: 'error_envelope_on_2xx',
    });
  }

  let receipt;
  try {
    receipt = parseReceipt(result?.data ?? result, walletAddress);
  } catch (_error) {
    receipt = null;
  }
  if (!receipt?.txHash) {
    throw new TransferSubmitError('Faucet node submit response did not include a transaction id', {
      definitive: false,
      reason: 'no_receipt',
    });
  }

  return receipt;
}

// The fixed answer for a claim whose transfer outcome is unknown. It names no
// node error, and tells the caller not to retry: the cooldown and the daily
// reservations are kept, so a retry today is refused anyway.
const CLAIM_PENDING_CODE = 'CLAIM_PENDING';
const CLAIM_PENDING_MESSAGE =
  'Your claim was sent but its outcome is not confirmed. Do not retry: it is pending review. ' +
  'Check your wallet balance; you can claim again after the UTC day resets.';

async function recordPendingClaim(record) {
  try {
    await redisClient.set(`${REDIS_PENDING_PREFIX}${record.nonce}`, JSON.stringify(record), {
      EX: PENDING_CLAIM_TTL_SECONDS,
    });
  } catch (error) {
    console.error('[faucet] could not record a pending claim', { nonce: record.nonce, error: error.message });
  }
  console.warn('[faucet] claim outcome unknown; reservations kept', {
    nonce: record.nonce,
    reason: record.reason,
  });
}

function buildPageConfig({
  walletConfigured = Boolean(FAUCET_WALLET_PRIVKEY && FAUCET_WALLET_ADDRESS),
  apiTokenConfigured = Boolean(FAUCET_API_TOKEN),
  captcha = captchaReadiness({ walletConfigured }),
} = {}) {
  const dispense = faucetDispenseReadiness({
    walletConfigured,
    apiTokenConfigured,
    captcha,
  });
  return {
    appName: 'WRFCoin Faucet',
    amount: FAUCET_AMOUNT,
    denomination: FAUCET_DENOMINATION,
    captchaProvider: CAPTCHA_PROVIDER,
    hcaptchaSitekey: HCAPTCHA_SITEKEY,
    recaptchaSitekey: RECAPTCHA_SITEKEY,
    explorerUrl: EXPLORER_URL,
    discordInviteUrl: DISCORD_INVITE_URL,
    hasDiscordWebhook: Boolean(DISCORD_WEBHOOK_URL),
    rateLimitHours: Math.max(1, Math.round(FAUCET_RATE_LIMIT_SECONDS / 3600)),
    walletDailyCap: FAUCET_WALLET_DAILY_CAP,
    globalDailyCap: FAUCET_GLOBAL_DAILY_CAP,
    walletBalanceFloor: FAUCET_WALLET_BALANCE_FLOOR,
    trustProxy: TRUST_PROXY_SETTING,
    nodeUrl: FAUCET_NODE_URL,
    submitPath: FAUCET_SUBMIT_PATH,
    walletConfigured: walletConfigured && apiTokenConfigured,
    ...dispense,
  };
}

function renderPage(overrides = {}) {
  const configObject = buildPageConfig(overrides);
  const pageConfig = JSON.stringify(configObject);
  const claimDisabled = configObject.directClaimsEnabled ? '' : ' disabled';
  const disabledNotice = configObject.directClaimsEnabled
    ? ''
    : `<div id="direct-claims-notice" class="status error">Direct claims are disabled on this faucet. Use the onboarding flow in the WRFCoin app.</div>`;
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>WRFCoin Faucet</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #06111d;
      --bg-soft: #0c1726;
      --panel: rgba(8, 18, 31, 0.88);
      --panel-border: rgba(120, 183, 255, 0.18);
      --text: #eff6ff;
      --muted: #95aecf;
      --accent: #6fd3ff;
      --accent-2: #9ef3cb;
      --shadow: 0 24px 70px rgba(0, 0, 0, 0.35);
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; min-height: 100%; }
    body {
      font-family: Inter, "Segoe UI", system-ui, sans-serif;
      color: var(--text);
      background:
        radial-gradient(circle at top left, rgba(111, 211, 255, 0.16), transparent 22%),
        radial-gradient(circle at 85% 12%, rgba(158, 243, 203, 0.12), transparent 18%),
        linear-gradient(160deg, #04111d 0%, #071423 44%, #06111d 100%);
    }
    a { color: inherit; }
    .shell {
      max-width: 1180px;
      margin: 0 auto;
      padding: 48px 20px 56px;
      display: grid;
      grid-template-columns: minmax(0, 1.03fr) minmax(340px, 0.97fr);
      gap: 28px;
    }
    .hero, .panel {
      border-radius: 28px;
      border: 1px solid var(--panel-border);
      background: var(--panel);
      box-shadow: var(--shadow);
      backdrop-filter: blur(16px);
    }
    .hero { padding: 36px; }
    .panel { padding: 28px; }
    .eyebrow, .section-title, .receipt-title {
      text-transform: uppercase;
      letter-spacing: 0.18em;
      font-size: 0.76rem;
      color: var(--accent);
    }
    h1 {
      margin: 18px 0 14px;
      font-size: clamp(2.6rem, 6vw, 4.8rem);
      line-height: 0.95;
      max-width: 10ch;
    }
    .lede {
      margin: 0;
      color: var(--muted);
      font-size: 1.03rem;
      line-height: 1.7;
      max-width: 58ch;
    }
    .pill-row, .ops-row, .field-row {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
    }
    .pill-row { margin-top: 26px; }
    .pill, .ops-pill {
      border-radius: 999px;
      padding: 8px 12px;
      background: rgba(146, 169, 199, 0.1);
      border: 1px solid rgba(146, 169, 199, 0.18);
      color: var(--text);
      font-size: 0.9rem;
    }
    .info-card {
      margin-top: 18px;
      padding: 18px 20px;
      border-radius: 20px;
      border: 1px solid rgba(146, 169, 199, 0.16);
      background: rgba(3, 9, 18, 0.5);
    }
    .info-card p { margin: 6px 0 0; color: var(--muted); line-height: 1.55; }
    .info-grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 10px;
      margin-top: 14px;
    }
    .info-grid .ops-pill { justify-self: start; }
    .section-head, .receipt-head {
      display: flex;
      justify-content: space-between;
      gap: 12px;
      align-items: center;
    }
    .hint, .status, .meta {
      color: var(--muted);
      line-height: 1.55;
    }
    .meta { margin: 10px 0 0; font-size: 0.94rem; }
    .panel form {
      display: grid;
      gap: 16px;
      margin-top: 18px;
    }
    label {
      display: grid;
      gap: 8px;
      color: var(--muted);
      font-size: 0.95rem;
    }
    input, textarea {
      width: 100%;
      border-radius: 16px;
      border: 1px solid rgba(146, 169, 199, 0.2);
      background: rgba(3, 9, 18, 0.76);
      color: var(--text);
      padding: 14px 16px;
      font: inherit;
      outline: none;
    }
    input:focus, textarea:focus {
      border-color: rgba(111, 211, 255, 0.75);
      box-shadow: 0 0 0 4px rgba(111, 211, 255, 0.12);
    }
    .captcha-box {
      padding: 14px 16px;
      border-radius: 18px;
      border: 1px solid rgba(146, 169, 199, 0.16);
      background: rgba(3, 9, 18, 0.54);
    }
    .captcha-box strong { display: block; margin-bottom: 8px; }
    .captcha-widget { margin-top: 12px; min-height: 78px; }
    .actions {
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      align-items: center;
    }
    button {
      border: 0;
      border-radius: 16px;
      padding: 14px 18px;
      cursor: pointer;
      font: inherit;
      font-weight: 700;
    }
    .primary {
      background: linear-gradient(135deg, var(--accent), #d2fbff);
      color: #05101f;
    }
    .ghost {
      background: rgba(146, 169, 199, 0.12);
      color: var(--text);
    }
    button:disabled { cursor: not-allowed; opacity: 0.55; }
    .status {
      margin-top: 10px;
      padding: 12px 14px;
      border-radius: 16px;
      border: 1px solid rgba(146, 169, 199, 0.16);
      background: rgba(3, 9, 18, 0.5);
    }
    .status.ok {
      color: #d6fff0;
      border-color: rgba(158, 243, 203, 0.24);
      background: rgba(12, 49, 35, 0.45);
    }
    .status.error {
      color: #ffe0e0;
      border-color: rgba(255, 154, 154, 0.24);
      background: rgba(61, 18, 18, 0.45);
    }
    .receipt {
      margin-top: 18px;
      border-radius: 22px;
      padding: 18px;
      border: 1px solid rgba(111, 211, 255, 0.18);
      background: rgba(4, 12, 21, 0.55);
    }
    .receipt.hidden { display: none; }
    .receipt-grid {
      display: grid;
      gap: 12px;
      margin-top: 14px;
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }
    .receipt-grid span {
      display: block;
      color: var(--muted);
      font-size: 0.84rem;
      margin-bottom: 5px;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }
    .receipt-grid code, .receipt-grid strong {
      font-size: 0.95rem;
      overflow-wrap: anywhere;
    }
    .receipt-actions {
      margin-top: 16px;
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      align-items: center;
    }
    .link {
      color: var(--accent);
      text-decoration: none;
    }
    @media (max-width: 960px) {
      .shell { grid-template-columns: 1fr; }
    }
    @media (max-width: 640px) {
      .hero, .panel { padding: 24px; border-radius: 22px; }
      .receipt-grid, .info-grid { grid-template-columns: 1fr; }
      h1 { max-width: none; }
    }
  </style>
</head>
<body>
  <main class="shell">
    <section class="hero">
      <div class="eyebrow">Testnet onboarding</div>
      <h1>Claim WRF, join the seed, and keep moving.</h1>
      <p class="lede">
        The faucet keeps the token drip simple: verify a captcha, pass the Redis-backed IP cooldown,
        and submit a transparent WRF transfer through the node's REST transaction API.
      </p>
      <div class="pill-row">
        <span class="pill">Captcha: <span id="captcha-provider"></span></span>
        <span class="pill">Peer IP, wallet, and global caps</span>
        <span class="pill">Discord alerts optional</span>
      </div>

      <div class="info-card">
        <strong>Operator wiring</strong>
        <p id="operator-copy"></p>
        <div class="info-grid">
          <span id="rpc-pill" class="ops-pill">RPC</span>
          <span id="redis-pill" class="ops-pill">Redis</span>
          <span id="wallet-pill" class="ops-pill">Wallet key</span>
          <span id="discord-pill" class="ops-pill">Discord</span>
        </div>
      </div>

      <div class="info-card">
        <strong>Discord support</strong>
        <p id="discord-copy"></p>
        <div class="field-row" style="margin-top: 12px;">
          <a id="discord-link" class="primary link" href="#" rel="noreferrer">Open Discord</a>
          <a id="explorer-link" class="ghost link" href="#" rel="noreferrer">Open explorer</a>
        </div>
      </div>
    </section>

    <section class="panel">
      <div class="section-head">
        <span class="section-title">Faucet request</span>
        <span class="hint">${escapeHtml(RATE_LIMIT_LABEL)} per peer IP</span>
      </div>

      ${disabledNotice}
      <form id="faucet-form" aria-disabled="${String(!configObject.directClaimsEnabled)}">
        <label>
          Wallet address
          <input id="wallet-address" autocomplete="off" spellcheck="false" placeholder="0x..." required${claimDisabled} />
        </label>

        <label>
          Captcha token
          <div class="captcha-box">
            <strong id="captcha-title"></strong>
            <div id="captcha-hint" class="hint"></div>
            <div id="captcha-widget" class="captcha-widget"></div>
            <input id="captcha-token" name="captchaToken" autocomplete="off" spellcheck="false" placeholder="Paste or generate a token"${claimDisabled} />
          </div>
        </label>

        <div class="actions">
          <button id="request-button" class="primary" type="submit"${claimDisabled}>Request WRF</button>
          <button id="refresh-button" class="ghost" type="button">Refresh config</button>
        </div>
      </form>

      <div id="status" class="status">Waiting for the first request.</div>

      <article id="receipt" class="receipt hidden">
        <div class="receipt-head">
          <div class="receipt-title">Receipt</div>
          <span id="receipt-state" class="hint"></span>
        </div>
        <div class="receipt-grid">
          <div>
            <span>Tx hash</span>
            <code id="receipt-hash">-</code>
          </div>
          <div>
            <span>Amount</span>
            <strong id="receipt-amount">-</strong>
          </div>
          <div>
            <span>Rate limit resets</span>
            <strong id="receipt-reset">-</strong>
          </div>
          <div>
            <span>Request fingerprint</span>
            <code id="receipt-fingerprint">-</code>
          </div>
        </div>
        <div class="receipt-actions">
          <a id="receipt-explorer" class="link" href="#" rel="noreferrer">View in explorer</a>
          <button id="copy-receipt" class="ghost" type="button">Copy receipt</button>
        </div>
      </article>
    </section>
  </main>

  <script>
    window.__FAUCET_CONFIG__ = ${pageConfig};
  </script>
  <script>
    const config = window.__FAUCET_CONFIG__ || {};
    const form = document.getElementById('faucet-form');
    const walletInput = document.getElementById('wallet-address');
    const captchaInput = document.getElementById('captcha-token');
    const captchaTitle = document.getElementById('captcha-title');
    const captchaHint = document.getElementById('captcha-hint');
    const captchaWidget = document.getElementById('captcha-widget');
    const captchaProviderEl = document.getElementById('captcha-provider');
    const operatorCopy = document.getElementById('operator-copy');
    const rpcPill = document.getElementById('rpc-pill');
    const redisPill = document.getElementById('redis-pill');
    const walletPill = document.getElementById('wallet-pill');
    const discordPill = document.getElementById('discord-pill');
    const discordCopy = document.getElementById('discord-copy');
    const discordLink = document.getElementById('discord-link');
    const explorerLink = document.getElementById('explorer-link');
    const receiptExplorer = document.getElementById('receipt-explorer');
    const requestButton = document.getElementById('request-button');
    const refreshButton = document.getElementById('refresh-button');
    const statusEl = document.getElementById('status');
    const receiptEl = document.getElementById('receipt');
    const receiptHash = document.getElementById('receipt-hash');
    const receiptAmount = document.getElementById('receipt-amount');
    const receiptReset = document.getElementById('receipt-reset');
    const receiptFingerprint = document.getElementById('receipt-fingerprint');
    const receiptState = document.getElementById('receipt-state');
    const copyReceiptButton = document.getElementById('copy-receipt');

    let lastReceipt = null;

    function setStatus(kind, text) {
      statusEl.className = kind ? 'status ' + kind : 'status';
      statusEl.textContent = text;
    }

    function showReceipt(receipt) {
      lastReceipt = receipt;
      receiptHash.textContent = receipt.txHash || '-';
      receiptAmount.textContent = receipt.amount + ' ' + receipt.denomination;
      receiptReset.textContent = receipt.rateLimitResetsAt || '-';
      receiptFingerprint.textContent = receipt.ipFingerprint || '-';
      receiptState.textContent = receipt.state || 'approved';
      receiptExplorer.href = receipt.explorerUrl || config.explorerUrl || '#';
      receiptEl.classList.remove('hidden');
    }

    function renderConfig() {
      const directClaimsEnabled = config.directClaimsEnabled === true;
      walletInput.disabled = !directClaimsEnabled;
      captchaInput.disabled = !directClaimsEnabled;
      requestButton.disabled = !directClaimsEnabled;
      captchaProviderEl.textContent = config.captchaProvider || 'off';
      rpcPill.textContent = 'Node API: ' + (config.nodeUrl || 'unset') + (config.submitPath || '');
      redisPill.textContent = 'Redis: ' + (config.rateLimitHours || 24) + 'h cooldown';
      walletPill.textContent = 'Wallet + token: ' + (config.walletConfigured ? 'configured' : 'missing');
      discordPill.textContent = 'Discord: ' + (config.hasDiscordWebhook ? 'webhook enabled' : 'invite available');
      operatorCopy.textContent = 'This faucet submits a transparent transfer to ' + (config.nodeUrl || 'the local node') + (config.submitPath || '') + ' using the ' + (config.walletConfigured ? 'configured wallet + node API token' : 'wallet/token placeholders (not yet configured)') + ', enforces peer IP, wallet, and global daily caps, keeps a ' + (config.walletBalanceFloor || '-') + ' ' + (config.denomination || 'WRF') + ' wallet balance floor, and publishes claims to Prometheus.';
      discordCopy.textContent = config.hasDiscordWebhook
        ? 'Discord webhook alerts are active for claim monitoring and support.'
        : 'Discord alerts are not configured; the faucet will still work, but no webhook notifications will be sent.';
      if (config.discordInviteUrl) {
        discordLink.href = config.discordInviteUrl;
      }
      explorerLink.href = config.explorerUrl || '#';
      const provider = (config.captchaProvider || 'off').toLowerCase();
      if (provider === 'hcaptcha') {
        captchaTitle.textContent = 'hCaptcha';
        captchaHint.textContent = config.hcaptchaSitekey
          ? 'Enter the token from hCaptcha. If you embed the widget, post its token into this field.'
          : 'hCaptcha is enabled but no sitekey was provided.';
      } else if (provider === 'recaptcha-v3') {
        captchaTitle.textContent = 'reCAPTCHA v3';
        captchaHint.textContent = config.recaptchaSitekey
          ? 'Enter the v3 token generated for the current action.'
          : 'reCAPTCHA v3 is enabled but no sitekey was provided.';
      } else {
        captchaTitle.textContent = 'Captcha disabled for local dev';
        captchaHint.textContent = 'Set CAPTCHA_PROVIDER to hcaptcha or recaptcha-v3 in .env to require a token.';
      }
    }

    async function copyText(text) {
      await navigator.clipboard.writeText(text);
    }

    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      receiptEl.classList.add('hidden');

      if (config.directClaimsEnabled !== true) {
        setStatus('error', 'Direct claims are disabled on this faucet. Use the onboarding flow in the WRFCoin app.');
        return;
      }

      const walletAddress = walletInput.value.trim();
      const captchaToken = captchaInput.value.trim();

      if (!/^(?:0x|wrf)[0-9a-fA-F]{40}$/i.test(walletAddress)) {
        setStatus('error', 'Wallet address must be a 0x- or wrf-prefixed 40-character hex string.');
        walletInput.focus();
        return;
      }

      if ((config.captchaProvider || 'off') !== 'off' && !captchaToken) {
        setStatus('error', 'Enter a captcha token before requesting WRF.');
        captchaInput.focus();
        return;
      }

      requestButton.disabled = true;
      setStatus('', 'Submitting faucet request...');

      try {
        const response = await fetch('/faucet/request', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ walletAddress, captchaToken }),
        });

        const payload = await response.json();
        if (!response.ok) {
          const error = payload && payload.error ? payload.error : {};
          throw new Error((error.code ? error.code + ': ' : '') + (error.message || 'Request failed'));
        }

        showReceipt(payload.receipt || payload);
        setStatus('ok', 'Claim approved. ' + payload.amount + ' ' + payload.denomination + ' sent to ' + walletAddress + '.');
      } catch (error) {
        setStatus('error', error && error.message ? error.message : 'Request failed.');
      } finally {
        requestButton.disabled = config.directClaimsEnabled !== true;
      }
    });

    refreshButton.addEventListener('click', () => {
      renderConfig();
      setStatus('', 'Config refreshed.');
    });

    copyReceiptButton.addEventListener('click', async () => {
      if (!lastReceipt) {
        return;
      }

      const receipt = [
        'WRFCoin faucet receipt',
        'txHash: ' + (lastReceipt.txHash || '-'),
        'amount: ' + (lastReceipt.amount || '-') + ' ' + (lastReceipt.denomination || 'WRF'),
        'rateLimitResetsAt: ' + (lastReceipt.rateLimitResetsAt || '-'),
        'requestFingerprint: ' + (lastReceipt.ipFingerprint || '-'),
      ].join('\\n');

      try {
        await copyText(receipt);
        setStatus('ok', 'Receipt copied to clipboard.');
      } catch (_error) {
        setStatus('error', 'Clipboard copy failed.');
      }
    });

    renderConfig();
    setStatus(
      config.directClaimsEnabled === true ? '' : 'error',
      config.directClaimsEnabled === true
        ? 'Ready. Submit a wallet address and captcha token.'
        : 'Direct claims are disabled. Use the onboarding flow in the WRFCoin app.',
    );
  </script>
</body>
</html>`;
}

async function handleFaucetRequest(req, res) {
  const stopTimer = requestDuration.startTimer();
  let walletAddress = String(req.body?.walletAddress || req.body?.wallet || '').trim();
  const captchaToken = String(
    req.body?.captchaToken ||
      req.body?.captcha ||
      req.body?.['h-captcha-response'] ||
      req.body?.['g-recaptcha-response'] ||
      '',
  ).trim();
  // #857 Option B: the backend onboarding proxy authenticates with the faucet
  // operator token (constant-time check). Trusted-proxy requests skip captcha
  // — the proxy enforces its own math-captcha, 24h address cooldown, and IP
  // rate-limit — and their rate-limit identity comes from the forwarded
  // x-client-ip header, otherwise every proxied user after the first would
  // share the backend container's IP bucket. x-client-ip is honored ONLY on
  // token-authenticated requests. A supplied-but-wrong bearer fails closed
  // (403) instead of silently downgrading to the captcha path so a
  // misconfigured proxy is diagnosable.
  const suppliedBearer = String(req.headers?.['authorization'] || '').startsWith('Bearer ');
  const trustedProxy = suppliedBearer && checkBearerToken(req, FAUCET_API_TOKEN).ok;
  if (suppliedBearer && !trustedProxy) {
    requestsTotal.inc({ result: 'invalid_proxy_token' });
    stopTimer();
    return jsonError(
      res,
      403,
      'INVALID_PROXY_TOKEN',
      'Bearer token does not match the faucet operator token',
    );
  }
  // Captcha verification still needs the real peer IP (the captcha providers
  // score it), but the rate-limit cooldown keys on the tailnet user when behind
  // `tailscale serve`, falling back to the peer IP otherwise.
  const { remoteIp, rateLimitIdentity } = resolveRequestIdentity(req, trustedProxy);
  const rateLimitKey = rateLimitIdentity.key;
  // Keep the `ipFingerprint` name for response/observability backward-compat;
  // it now reflects whichever identity (tailnet user or peer IP) was used.
  const ipFingerprint = rateLimitIdentity.fingerprint;
  let ipReservationMade = false;
  let dailyReservations = [];
  // Set just before the transfer is submitted. From then on only a definitive
  // rejection releases the reservations (infra#1157 review).
  let transferStarted = false;
  let transferNonce = null;
  let ownsInFlight = false;
  let ownsNonceFence = false;
  let nonceFenceValue = null;

  requestsTotal.inc({ result: 'attempt' });

  // A refusal that keeps the device's cooldown names the longer of the two
  // waits: the calendar day and the retained cooldown (infra#1157 review r2).
  async function retryAfterWithCooldown(calendarSeconds) {
    if (!ipReservationMade) return calendarSeconds;
    const cooldown = await redisClient.ttl(rateLimitKey).catch(() => -2);
    return Math.max(calendarSeconds, cooldown > 0 ? cooldown : 0);
  }

  async function cleanupReservations({ keepCooldown = false } = {}) {
    const cleanup = [];
    let fenceReleased = true;
    if (ownsNonceFence) {
      fenceReleased = await releaseNonceFence(nonceFenceValue);
      if (!fenceReleased) pendingNonceRelease = nonceFenceValue;
      ownsNonceFence = false;
    }
    if (ipReservationMade && !keepCooldown) {
      cleanup.push(redisClient.del(rateLimitKey).catch(() => {}));
    }
    if (dailyReservations.length > 0) {
      cleanup.push(rollbackDailyReservations(dailyReservations));
      dailyReservations = [];
    }
    await Promise.all(cleanup);
    return fenceReleased;
  }

  try {
    if (!isSupportedWalletAddress(walletAddress)) {
      requestsTotal.inc({ result: 'invalid_wallet' });
      return jsonError(
        res,
        400,
        'INVALID_WALLET',
        'Wallet address must be a 0x- or wrf-prefixed 40-character hex string',
      );
    }
    walletAddress = normalizeWalletAddress(walletAddress);

    const amountBaseUnits = toBaseUnits(FAUCET_AMOUNT);
    // Trusted-proxy dispenses do not require a public captcha provider to be
    // configured — the proxy layer supplies the abuse controls (#857).
    assertFaucetConfiguredForPayout({ requireCaptcha: !trustedProxy });
    if (!trustedProxy) {
      await verifyCaptcha({ token: captchaToken, remoteIp });
    }
    if (transferInFlight) {
      throw new FaucetRequestError(503, 'FAUCET_TRANSFER_BUSY', 'Faucet transfer is busy; try later');
    }
    transferInFlight = true;
    ownsInFlight = true;
    if (pendingNonceRelease !== null) {
      if (!await releaseNonceFence(pendingNonceRelease)) {
        throw new FaucetRequestError(503, 'FAUCET_NONCE_CLEANUP_PENDING', 'Faucet nonce cleanup is pending; try later');
      }
      pendingNonceRelease = null;
    }
    const account = await getFaucetAccount();
    transferNonce = account.nonce;
    await assertWalletBalanceFloor(amountBaseUnits, account.balance);

    const queued = await redisClient.set(rateLimitKey, JSON.stringify({
      walletAddress,
      ipFingerprint,
      identityKind: rateLimitIdentity.kind,
      requestedAt: new Date().toISOString(),
    }), {
      EX: FAUCET_RATE_LIMIT_SECONDS,
      NX: true,
    });

    if (queued !== 'OK') {
      const ttlSeconds = await redisClient.ttl(rateLimitKey);
      requestsTotal.inc({ result: 'rate_limited' });
      return jsonError(
        res,
        429,
        'RATE_LIMITED',
        rateLimitIdentity.kind === 'tsuser'
          ? 'This tailnet user has already claimed from the faucet in the last 24 hours'
          : 'This peer has already claimed from the faucet in the last 24 hours',
        {
          retryAfterSeconds: ttlSeconds > 0 ? ttlSeconds : FAUCET_RATE_LIMIT_SECONDS,
        },
      );
    }
    ipReservationMade = true;

    dailyReservations = await reserveDailyPayoutCaps(
      walletAddress,
      amountBaseUnits,
      deviceIdForIdentity(rateLimitIdentity),
    );

    nonceFenceValue = `${transferNonce}:${crypto.randomUUID()}`;
    const reserved = await redisClient.eval(NONCE_RESERVE_LUA, {
      keys: [NONCE_FENCE_KEY], arguments: [transferNonce, nonceFenceValue],
    });
    if (Number(reserved) !== 1) {
      throw new FaucetRequestError(503, 'FAUCET_TRANSFER_BUSY', 'Faucet transfer is awaiting account confirmation');
    }
    ownsNonceFence = true;
    transferStarted = true;
    const receipt = await requestTransfer({ walletAddress, nonce: transferNonce });

    transfersTotal.inc({ result: 'success' });
    await sendDiscordNotification({
      title: 'WRFCoin faucet claim approved',
      description: `Claim approved for ${walletAddress}`,
      color: 0x2ecc71,
      fields: [
        { name: 'Amount', value: `${FAUCET_AMOUNT} ${FAUCET_DENOMINATION}`, inline: true },
        { name: 'Tx hash', value: receipt.txHash, inline: false },
        {
          name: rateLimitIdentity.kind === 'tsuser' ? 'Tailnet user fingerprint' : 'IP fingerprint',
          value: ipFingerprint,
          inline: true,
        },
        {
          name: 'Rate limit',
          value: `${RATE_LIMIT_LABEL} per ${
            rateLimitIdentity.kind === 'tsuser' ? 'tailnet user' : 'peer IP'
          } + daily device/wallet/global caps`,
          inline: true,
        },
      ],
    });

    requestsTotal.inc({ result: 'success' });
    res.json({
      ok: true,
      amount: FAUCET_AMOUNT,
      denomination: FAUCET_DENOMINATION,
      rateLimitResetsAt: new Date(Date.now() + FAUCET_RATE_LIMIT_SECONDS * 1000).toISOString(),
      ipFingerprint,
      receipt: {
        txHash: receipt.txHash,
        balance: receipt.balance,
        amount: FAUCET_AMOUNT,
        denomination: FAUCET_DENOMINATION,
        rateLimitResetsAt: new Date(Date.now() + FAUCET_RATE_LIMIT_SECONDS * 1000).toISOString(),
        ipFingerprint,
        explorerUrl: EXPLORER_URL,
        state: 'approved',
      },
    });
  } catch (error) {
    if (error instanceof FaucetRequestError) {
      await cleanupReservations({ keepCooldown: error.keepCooldown === true });
      if (error.keepCooldown === true && error.details?.retryAfterSeconds) {
        error.details.retryAfterSeconds = await retryAfterWithCooldown(error.details.retryAfterSeconds);
      }
      requestsTotal.inc({
        result: error.status >= 500 ? 'misconfigured' : error.code.toLowerCase(),
      });
      jsonError(res, error.status, error.code, error.message, error.details);
      return;
    }

    if (error && typeof error.message === 'string') {
      if (error.message.includes('Captcha')) {
        await cleanupReservations();
        requestsTotal.inc({ result: 'captcha_failed' });
        jsonError(res, 400, 'CAPTCHA_FAILED', error.message);
        return;
      }

      if (error instanceof TransferSubmitError && error.definitive) {
        // A definitive non-admission: the claim never happened.
        const fenceReleased = await cleanupReservations();
        transfersTotal.inc({ result: 'fail' });
        requestsTotal.inc({ result: 'transfer_failed' });
        if (!fenceReleased) {
          nonceCleanupError(res);
          return;
        }
        await sendDiscordNotification({
          title: 'WRFCoin faucet claim failed',
          description: `Claim failed for ${walletAddress}`,
          color: 0xe74c3c,
          fields: [
            { name: 'Error', value: error.message.slice(0, 1000), inline: false },
            { name: 'IP fingerprint', value: ipFingerprint, inline: true },
          ],
        });
        jsonError(res, 502, 'FAUCET_TRANSFER_FAILED', error.message);
        return;
      }
    }

    if (transferStarted) {
      // UNKNOWN outcome: the node may already have accepted the transfer.
      // Keep the cooldown and every daily reservation, record the claim, and
      // tell the caller not to retry. No automatic reconciler here.
      dailyReservations = [];
      await recordPendingClaim({
        nonce: transferNonce,
        walletAddress,
        from: FAUCET_WALLET_ADDRESS,
        amountBaseUnits: toBaseUnits(FAUCET_AMOUNT),
        identityFingerprint: ipFingerprint,
        reason: error instanceof TransferSubmitError ? error.reason : 'after_submit',
        recordedAt: new Date().toISOString(),
      });
      transfersTotal.inc({ result: 'unknown' });
      requestsTotal.inc({ result: 'claim_pending' });
      await sendDiscordNotification({
        title: 'WRFCoin faucet claim outcome unknown',
        description: `Claim for ${walletAddress} needs review; reservations kept`,
        color: 0xf1c40f,
        fields: [
          { name: 'Nonce', value: String(transferNonce), inline: true },
          { name: 'Reason', value: String(error instanceof TransferSubmitError ? error.reason : 'after_submit'), inline: true },
        ],
      });
      if (!res.headersSent) {
        jsonError(res, 409, CLAIM_PENDING_CODE, CLAIM_PENDING_MESSAGE, {
          retryAfterSeconds: await retryAfterWithCooldown(secondsUntilNextUtcDay()),
        });
      }
      return;
    }

    const fenceReleased = await cleanupReservations();
    transfersTotal.inc({ result: 'fail' });
    requestsTotal.inc({ result: 'fail' });
    if (!fenceReleased) {
      nonceCleanupError(res);
      return;
    }
    jsonError(
      res,
      500,
      'FAUCET_REQUEST_FAILED',
      error instanceof Error ? error.message : 'Faucet request failed',
    );
  } finally {
    if (ownsInFlight) transferInFlight = false;
    stopTimer();
  }
}

// ---------------------------------------------------------------------------
// Bond grant (genesis 888, Refs infra#1332 / core4#3592; design: BOND_GRANT.md)
//
// One grant of exactly the node bond (default 250.36 WRF = the 250 WRF bond
// plus 0.36 WRF lifecycle fee headroom) per new node identity, paid to the
// bond OWNER account the node names. Default OFF.
//
// The request is signed by the node's bond server key (the ed25519 key that
// signs NodeBondPossession in a Deposit). The signature binds the chain, the
// owner account, the node's libp2p peer id and a recent block the node holds.
// The faucet then checks, on its own node, that:
//   - the block at that height has that hash and is within the lag window;
//   - the peer id is a sync peer, not banned, advertising a height near tip.
// Abuse controls (Redis, no expiry except the daily count):
//   one grant per server key, one per peer id, one per owner wallet, and a
//   global daily COUNT cap. The drip's daily WRF caps are not charged.
// ---------------------------------------------------------------------------
const FAUCET_BOND_GRANT_ENABLED = (process.env.FAUCET_BOND_GRANT_ENABLED || 'false').trim() === 'true';
const FAUCET_BOND_GRANT_AMOUNT = process.env.FAUCET_BOND_GRANT_AMOUNT || '250.36';
const FAUCET_BOND_GRANT_DAILY_COUNT_CAP = Math.max(
  0,
  Number.parseInt(process.env.FAUCET_BOND_GRANT_DAILY_COUNT_CAP || '4', 10) || 0,
);
const FAUCET_BOND_GRANT_MAX_LAG_BLOCKS = Math.max(
  1,
  Number.parseInt(process.env.FAUCET_BOND_GRANT_MAX_LAG_BLOCKS || '20', 10) || 20,
);
const FAUCET_BOND_GRANT_MAX_ADVERT_AGE_SECONDS = Math.max(
  1,
  Number.parseInt(process.env.FAUCET_BOND_GRANT_MAX_ADVERT_AGE_SECONDS || '300', 10) || 300,
);
// Reader is enough for these reads; the operator token also satisfies Reader.
const FAUCET_READER_TOKEN = process.env.FAUCET_READER_TOKEN || FAUCET_API_TOKEN;
const FAUCET_TIP_PATH = process.env.FAUCET_TIP_PATH || '/network/info';
const FAUCET_BLOCK_PATH = process.env.FAUCET_BLOCK_PATH || '/chain/block/{height}';
const FAUCET_SYNC_PEERS_PATH = process.env.FAUCET_SYNC_PEERS_PATH || '/network/peers/sync';
const REDIS_BOND_GRANT_PREFIX = process.env.FAUCET_BOND_GRANT_PREFIX || 'faucet:bond-grant:';
const BOND_GRANT_DOMAIN = 'wrfcoin_faucet_bond_grant_v1';
const HEX64 = /^[0-9a-f]{64}$/;
const HEX128 = /^[0-9a-f]{128}$/;
// libp2p peer ids are base58btc multihashes (12D3KooW… for ed25519).
const PEER_ID_PATTERN = /^[1-9A-HJ-NP-Za-km-z]{30,128}$/;
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

const bondGrantsTotal = new promClient.Counter({
  name: 'wrfcoin_faucet_bond_grants_total',
  help: 'Bond grant requests by result.',
  labelNames: ['result'],
});
registry.registerMetric(bondGrantsTotal);

function normalizeHashHex(value) {
  return String(value ?? '').trim().replace(/^0x/i, '').toLowerCase();
}

// domain || str(chain_id) || str(network_id) || str(owner) || str(server_key)
//   || str(peer_id) || u64LE(height) || str(block_hash)
// str(s) = u32LE(len(utf8)) || utf8, as in the transfer authorization.
// owner is the normalized 0x form; keys and hashes are lowercase hex, no 0x.
function buildBondGrantMessage({
  ownerAddress,
  serverKey,
  peerId,
  height,
  blockHash,
  chainId = WRFCOIN_CHAIN_ID,
  networkId = WRFCOIN_NETWORK_ID,
}) {
  return Buffer.concat([
    Buffer.from(BOND_GRANT_DOMAIN, 'utf8'),
    encodeLenPrefixedString(chainId),
    encodeLenPrefixedString(networkId),
    encodeLenPrefixedString(ownerAddress),
    encodeLenPrefixedString(serverKey),
    encodeLenPrefixedString(peerId),
    u64le(height),
    encodeLenPrefixedString(blockHash),
  ]);
}

function verifyBondGrantSignature(fields, signatureHex) {
  try {
    const key = crypto.createPublicKey({
      key: Buffer.concat([ED25519_SPKI_PREFIX, Buffer.from(fields.serverKey, 'hex')]),
      format: 'der',
      type: 'spki',
    });
    return crypto.verify(null, buildBondGrantMessage(fields), key, Buffer.from(signatureHex, 'hex'));
  } catch (_error) {
    return false;
  }
}

function parseBondGrantRequest(body) {
  const invalid = (message) => new FaucetRequestError(400, 'INVALID_BOND_GRANT_REQUEST', message);
  const owner = String(body?.ownerAddress || '').trim();
  if (!isSupportedWalletAddress(owner)) throw invalid('ownerAddress must be a 0x- or wrf-prefixed 40-character hex address');
  const serverKey = String(body?.serverKey || '').trim().toLowerCase();
  if (!HEX64.test(serverKey)) throw invalid('serverKey must be the 32-byte node bond server key in hex');
  const peerId = String(body?.peerId || '').trim();
  if (!PEER_ID_PATTERN.test(peerId)) throw invalid('peerId must be the node libp2p peer id');
  const height = body?.height;
  if (!Number.isSafeInteger(height) || height < 1) throw invalid('height must be a positive integer');
  const blockHash = normalizeHashHex(body?.blockHash);
  if (!HEX64.test(blockHash)) throw invalid('blockHash must be a 32-byte hex block hash');
  const signature = String(body?.signature || '').trim().toLowerCase();
  if (!HEX128.test(signature)) throw invalid('signature must be a 64-byte ed25519 signature in hex');
  return { ownerAddress: normalizeWalletAddress(owner), serverKey, peerId, height, blockHash, signature };
}

async function readNodeJson(path) {
  const response = await fetch(`${FAUCET_NODE_URL}${path}`, {
    headers: { Authorization: `Bearer ${FAUCET_READER_TOKEN}` },
    redirect: 'manual',
    signal: AbortSignal.timeout(5000),
  });
  const body = await readBoundedNodeJson(response);
  if (!response.ok || body?.ok === false || body?.error) throw new Error('node read refused');
  return body?.data ?? body;
}

// The node must be visibly synced on the faucet's own node. Reads are bounded;
// any failure is a 503 that reserves nothing.
async function assertNodeSyncedAndVisible({ peerId, height, blockHash }) {
  const unavailable = () =>
    new FaucetRequestError(503, 'BOND_GRANT_CHAIN_UNAVAILABLE', 'The faucet cannot check the chain right now; try later');
  let tip;
  let block;
  let peers;
  try {
    const info = await readNodeJson(FAUCET_TIP_PATH);
    tip = Number(info?.chain_height ?? info?.height);
    if (!Number.isSafeInteger(tip) || tip < 1) throw new Error('tip unavailable');
    block = await readNodeJson(FAUCET_BLOCK_PATH.replace('{height}', String(height))).catch(() => null);
    peers = await readNodeJson(FAUCET_SYNC_PEERS_PATH);
    if (!Array.isArray(peers?.peers)) throw new Error('peers unavailable');
  } catch (_error) {
    throw unavailable();
  }
  const notSynced = (message) => new FaucetRequestError(409, 'NODE_NOT_SYNCED', message, {
    tipHeight: tip,
    maxLagBlocks: FAUCET_BOND_GRANT_MAX_LAG_BLOCKS,
  });
  if (height > tip || tip - height > FAUCET_BOND_GRANT_MAX_LAG_BLOCKS) {
    throw notSynced('The signed block is not within the recent window; sign a block near the current tip');
  }
  if (!block || Number(block.height) !== height || normalizeHashHex(block.hash) !== blockHash) {
    throw notSynced('The signed block hash does not match the chain at that height');
  }
  const peer = peers.peers.find((entry) => entry?.peer_id === peerId);
  if (!peer) {
    throw new FaucetRequestError(409, 'NODE_NOT_VISIBLE', 'The node is not a visible sync peer of the faucet node');
  }
  const advertised = Number(peer.advertised_height);
  const age = peer.advertisement_age_secs;
  if (
    peer.banned === true ||
    !Number.isSafeInteger(advertised) ||
    tip - advertised > FAUCET_BOND_GRANT_MAX_LAG_BLOCKS ||
    (age !== null && age !== undefined && Number(age) > FAUCET_BOND_GRANT_MAX_ADVERT_AGE_SECONDS)
  ) {
    throw notSynced('The node is visible but not advertising a recent height');
  }
}

function buildBondGrantKeys({ serverKey, peerId, ownerAddress }, now = new Date()) {
  return {
    serverKeyKey: `${REDIS_BOND_GRANT_PREFIX}server:${serverKey}`,
    peerKey: `${REDIS_BOND_GRANT_PREFIX}peer:${peerId}`,
    walletKey: `${REDIS_BOND_GRANT_PREFIX}wallet:${ownerAddress}`,
    dailyCountKey: `${REDIS_BOND_GRANT_PREFIX}daily:${dailyKeySuffix(now)}`,
  };
}

// All-or-nothing: refuse if any identity already has a grant (or a pending
// one), or if today's count is spent; otherwise mark all three and count it.
const BOND_GRANT_RESERVE_LUA = `-- faucet-bond-grant-reserve
for i = 1, 3 do
  if redis.call('EXISTS', KEYS[i]) == 1 then return {0, i} end
end
local count = tonumber(redis.call('GET', KEYS[4]) or '0')
if count >= tonumber(ARGV[2]) then return {0, 4} end
for i = 1, 3 do redis.call('SET', KEYS[i], ARGV[1]) end
local n = redis.call('INCR', KEYS[4])
if n == 1 then redis.call('EXPIRE', KEYS[4], tonumber(ARGV[3])) end
return {1, n}
`;
// Only after a DEFINITIVE non-admission. Deletes only this request's marks.
const BOND_GRANT_RELEASE_LUA = `-- faucet-bond-grant-release
local released = 0
for i = 1, 3 do
  if redis.call('GET', KEYS[i]) == ARGV[1] then redis.call('DEL', KEYS[i]); released = 1 end
end
if released == 1 and tonumber(redis.call('GET', KEYS[4]) or '0') > 0 then redis.call('DECR', KEYS[4]) end
return released
`;
const BOND_GRANT_REFUSALS = {
  1: ['BOND_GRANT_ALREADY_USED', 'This node key has already received its bond grant'],
  2: ['BOND_GRANT_ALREADY_USED', 'This node peer id has already received its bond grant'],
  3: ['BOND_GRANT_ALREADY_USED', 'This wallet has already received a bond grant'],
};

async function handleBondGrantRequest(req, res) {
  let reserved = null;
  let transferStarted = false;
  let transferNonce = null;
  let ownsInFlight = false;
  let ownsNonceFence = false;
  let nonceFenceValue = null;
  let request = null;

  const releaseReservation = async () => {
    if (!reserved) return;
    const { keys, token } = reserved;
    reserved = null;
    await redisClient.eval(BOND_GRANT_RELEASE_LUA, {
      keys: [keys.serverKeyKey, keys.peerKey, keys.walletKey, keys.dailyCountKey],
      arguments: [token],
    }).catch(() => {});
  };
  const releaseFence = async () => {
    if (!ownsNonceFence) return true;
    ownsNonceFence = false;
    const released = await releaseNonceFence(nonceFenceValue);
    if (!released) pendingNonceRelease = nonceFenceValue;
    return released;
  };

  try {
    if (!FAUCET_BOND_GRANT_ENABLED) {
      throw new FaucetRequestError(404, 'BOND_GRANT_DISABLED', 'Bond grants are not enabled on this faucet');
    }
    const suppliedBearer = String(req.headers?.['authorization'] || '').startsWith('Bearer ');
    const trustedProxy = suppliedBearer && checkBearerToken(req, FAUCET_API_TOKEN).ok;
    if (suppliedBearer && !trustedProxy) {
      throw new FaucetRequestError(403, 'INVALID_PROXY_TOKEN', 'Bearer token does not match the faucet operator token');
    }
    request = parseBondGrantRequest(req.body);
    const amountBaseUnits = toBaseUnits(FAUCET_BOND_GRANT_AMOUNT);
    assertFaucetConfiguredForPayout({ requireCaptcha: !trustedProxy });
    if (!trustedProxy) {
      const { remoteIp } = resolveRequestIdentity(req, false);
      const captchaToken = String(
        req.body?.captchaToken || req.body?.['h-captcha-response'] || req.body?.['g-recaptcha-response'] || '',
      ).trim();
      try {
        await verifyCaptcha({ token: captchaToken, remoteIp });
      } catch (error) {
        throw new FaucetRequestError(400, 'CAPTCHA_FAILED', error instanceof Error ? error.message : 'Captcha failed');
      }
    }
    if (!verifyBondGrantSignature(request, request.signature)) {
      throw new FaucetRequestError(400, 'INVALID_BOND_GRANT_SIGNATURE', 'The node server key signature does not verify');
    }
    await assertNodeSyncedAndVisible(request);

    if (transferInFlight) {
      throw new FaucetRequestError(503, 'FAUCET_TRANSFER_BUSY', 'Faucet transfer is busy; try later');
    }
    transferInFlight = true;
    ownsInFlight = true;
    if (pendingNonceRelease !== null) {
      if (!await releaseNonceFence(pendingNonceRelease)) {
        throw new FaucetRequestError(503, 'FAUCET_NONCE_CLEANUP_PENDING', 'Faucet nonce cleanup is pending; try later');
      }
      pendingNonceRelease = null;
    }
    const account = await getFaucetAccount();
    transferNonce = account.nonce;
    await assertWalletBalanceFloor(amountBaseUnits, account.balance);

    const now = new Date();
    const keys = buildBondGrantKeys(request, now);
    const token = crypto.randomUUID();
    const record = JSON.stringify({
      token,
      state: 'reserved',
      ownerAddress: request.ownerAddress,
      serverKey: request.serverKey,
      peerId: request.peerId,
      amountBaseUnits,
      requestedAt: now.toISOString(),
    });
    const result = await redisClient.eval(BOND_GRANT_RESERVE_LUA, {
      keys: [keys.serverKeyKey, keys.peerKey, keys.walletKey, keys.dailyCountKey],
      arguments: [record, String(FAUCET_BOND_GRANT_DAILY_COUNT_CAP), String(dailyKeyTtlSeconds(now))],
    });
    if (!Array.isArray(result) || Number(result[0]) !== 1) {
      const which = Array.isArray(result) ? Number(result[1]) : 0;
      if (which === 4) {
        throw new FaucetRequestError(429, 'BOND_GRANT_DAILY_LIMIT', 'Today\'s bond grants are used up; try after the UTC day resets', {
          retryAfterSeconds: secondsUntilNextUtcDay(now),
        });
      }
      const [code, message] = BOND_GRANT_REFUSALS[which] || ['BOND_GRANT_ALREADY_USED', 'A bond grant was already given'];
      throw new FaucetRequestError(409, code, message);
    }
    reserved = { keys, token: record };

    nonceFenceValue = `${transferNonce}:${crypto.randomUUID()}`;
    const fenced = await redisClient.eval(NONCE_RESERVE_LUA, {
      keys: [NONCE_FENCE_KEY], arguments: [transferNonce, nonceFenceValue],
    });
    if (Number(fenced) !== 1) {
      throw new FaucetRequestError(503, 'FAUCET_TRANSFER_BUSY', 'Faucet transfer is awaiting account confirmation');
    }
    ownsNonceFence = true;
    transferStarted = true;
    const receipt = await requestTransfer({ walletAddress: request.ownerAddress, nonce: transferNonce, amountBaseUnits });

    const granted = JSON.stringify({ ...JSON.parse(record), state: 'granted', txHash: receipt.txHash });
    await Promise.all([keys.serverKeyKey, keys.peerKey, keys.walletKey]
      .map((key) => redisClient.set(key, granted).catch(() => {})));
    reserved = null;
    bondGrantsTotal.inc({ result: 'granted' });
    transfersTotal.inc({ result: 'success' });
    await sendDiscordNotification({
      title: 'WRFCoin faucet bond grant paid',
      description: `Bond grant paid to ${request.ownerAddress}`,
      color: 0x2ecc71,
      fields: [
        { name: 'Amount', value: `${FAUCET_BOND_GRANT_AMOUNT} ${FAUCET_DENOMINATION}`, inline: true },
        { name: 'Tx hash', value: receipt.txHash, inline: false },
      ],
    });
    res.json({
      ok: true,
      amount: FAUCET_BOND_GRANT_AMOUNT,
      denomination: FAUCET_DENOMINATION,
      receipt: { txHash: receipt.txHash, ownerAddress: request.ownerAddress, explorerUrl: EXPLORER_URL, state: 'approved' },
      next: 'Use this balance for the node bond Deposit of the same server key.',
    });
  } catch (error) {
    if (error instanceof TransferSubmitError && error.definitive) {
      await releaseReservation();
      const fenceReleased = await releaseFence();
      bondGrantsTotal.inc({ result: 'transfer_failed' });
      transfersTotal.inc({ result: 'fail' });
      if (!fenceReleased) return nonceCleanupError(res);
      return jsonError(res, 502, 'FAUCET_TRANSFER_FAILED', error.message);
    }
    if (transferStarted) {
      // UNKNOWN outcome: keep the marks so the identities cannot claim again.
      reserved = null;
      await recordPendingClaim({
        kind: 'bond_grant',
        nonce: transferNonce,
        walletAddress: request.ownerAddress,
        serverKey: request.serverKey,
        peerId: request.peerId,
        from: FAUCET_WALLET_ADDRESS,
        amountBaseUnits: toBaseUnits(FAUCET_BOND_GRANT_AMOUNT),
        reason: error instanceof TransferSubmitError ? error.reason : 'after_submit',
        recordedAt: new Date().toISOString(),
      });
      bondGrantsTotal.inc({ result: 'pending' });
      transfersTotal.inc({ result: 'unknown' });
      if (!res.headersSent) {
        jsonError(res, 409, CLAIM_PENDING_CODE, CLAIM_PENDING_MESSAGE);
      }
      return undefined;
    }
    await releaseReservation();
    const fenceReleased = await releaseFence();
    if (!fenceReleased) return nonceCleanupError(res);
    if (error instanceof FaucetRequestError) {
      bondGrantsTotal.inc({ result: error.code.toLowerCase() });
      return jsonError(res, error.status, error.code, error.message, error.details);
    }
    bondGrantsTotal.inc({ result: 'fail' });
    return jsonError(res, 500, 'FAUCET_REQUEST_FAILED', 'Bond grant request failed');
  } finally {
    if (ownsInFlight) transferInFlight = false;
  }
}

app.get('/', (_req, res) => {
  res.type('html').send(renderPage());
});

app.get('/faucet', (_req, res) => {
  res.type('html').send(renderPage());
});

app.get('/health', async (_req, res) => {
  let redisHealthy = false;
  let redisError = null;

  try {
    if (!redisClient) {
      throw new Error('redis client not initialized yet');
    }
    await redisClient.ping();
    redisHealthy = true;
  } catch (error) {
    redisError = error instanceof Error ? error.message : 'redis ping failed';
  }

  const captcha = captchaReadiness();
  const dispense = faucetDispenseReadiness({ captcha });
  const health = {
    status: redisHealthy ? 'ok' : 'degraded',
    service: 'wrfcoin-faucet',
    nodeConfigured: Boolean(FAUCET_NODE_URL),
    nodeUrl: FAUCET_NODE_URL,
    submitPath: FAUCET_SUBMIT_PATH,
    walletConfigured: Boolean(FAUCET_WALLET_PRIVKEY && FAUCET_WALLET_ADDRESS),
    apiTokenConfigured: Boolean(FAUCET_API_TOKEN),
    redisConfigured: Boolean(REDIS_URL),
    redisHealthy,
    redisError,
    captchaProvider: CAPTCHA_PROVIDER,
    captchaReady: captcha.ok,
    ...dispense,
    hcaptchaConfigured: Boolean(HCAPTCHA_SECRET || HCAPTCHA_SITEKEY),
    recaptchaConfigured: Boolean(RECAPTCHA_SECRET || RECAPTCHA_SITEKEY),
    trustProxy: TRUST_PROXY_SETTING,
    walletDailyCap: FAUCET_WALLET_DAILY_CAP,
    globalDailyCap: FAUCET_GLOBAL_DAILY_CAP,
    walletBalanceFloor: FAUCET_WALLET_BALANCE_FLOOR,
    bondGrantEnabled: FAUCET_BOND_GRANT_ENABLED,
    bondGrantAmount: FAUCET_BOND_GRANT_AMOUNT,
    bondGrantDailyCountCap: FAUCET_BOND_GRANT_DAILY_COUNT_CAP,
    discordConfigured: Boolean(DISCORD_WEBHOOK_URL),
  };

  // Always 200 while the process is listening. Redis being unreachable
  // degrades functionality (rate limiting / payouts) but must NOT mark the
  // container dead — that previously turned a transient Redis blip into a full
  // "unhealthy, not listening" outage (infra#604). Per-request handlers still
  // fail closed when Redis is unavailable; the `status` field reflects health.
  res.status(200).json(health);
});

// Validate an Authorization: Bearer <token> request header against a known
// token using a constant-time comparison.  Returns an object with:
//   { ok: true,  status: 200 }          — authenticated
//   { ok: false, status: 401 }          — no credential supplied
//   { ok: false, status: 403 }          — wrong credential
//   { ok: false, status: 503 }          — no token configured (operator error)
//
// Exported for unit testing (pure function, no I/O).
function checkBearerToken(req, expectedToken) {
  if (!expectedToken) {
    // Fail closed: if no operator token is configured the endpoint is
    // unavailable rather than world-readable.
    return { ok: false, status: 503 };
  }
  const authHeader = (req.headers && req.headers['authorization']) || '';
  const supplied = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
  if (!supplied) {
    return { ok: false, status: 401 };
  }
  let match = false;
  try {
    const a = Buffer.from(expectedToken, 'utf8');
    const b = Buffer.from(supplied, 'utf8');
    // Constant-time comparison to prevent timing-based oracle attacks.
    match = a.length === b.length && crypto.timingSafeEqual(a, b);
  } catch {
    match = false;
  }
  return match ? { ok: true, status: 200 } : { ok: false, status: 403 };
}

app.get('/metrics', async (req, res) => {
  // Gate behind the metrics token (preferred for Prometheus scraper) or the
  // operator token as fallback.  FAUCET_METRICS_TOKEN should be set to the
  // value from testnet/prometheus-bearer-token so the scraper can authenticate
  // without sharing the node operator credential.
  //
  // Priority:
  //   1. FAUCET_METRICS_TOKEN — dedicated Prometheus bearer token
  //   2. FAUCET_API_TOKEN / WRFCOIN_OPERATOR_TOKEN — operator token fallback
  //
  // If neither is configured the endpoint is unavailable (503) rather than
  // world-readable (fail-closed).
  const effectiveToken = FAUCET_METRICS_TOKEN || FAUCET_API_TOKEN;
  const authResult = checkBearerToken(req, effectiveToken);
  if (!authResult.ok) {
    if (authResult.status === 401) {
      res.set('WWW-Authenticate', 'Bearer realm="wrfcoin-faucet-metrics"');
    }
    return res.status(authResult.status).end();
  }
  res.set('Content-Type', registry.contentType);
  res.send(await registry.metrics());
});

app.post('/faucet/request', (req, res) => {
  handleFaucetRequest(req, res).catch((error) => {
    console.error('[faucet] request handler failed:', error);
    jsonError(res, 500, 'FAUCET_REQUEST_FAILED', 'Unhandled faucet request failure');
  });
});

app.post('/faucet/bond-grant', (req, res) => {
  handleBondGrantRequest(req, res).catch((error) => {
    console.error('[faucet] bond grant handler failed:', error);
    jsonError(res, 500, 'FAUCET_REQUEST_FAILED', 'Unhandled bond grant failure');
  });
});

// Connect to Redis in the background, retrying until it succeeds. The HTTP
// listener is already bound by the time this runs, so Redis being slow or
// briefly unreachable never prevents the container from listening or serving
// /health — it only degrades /faucet/request until Redis attaches (infra#604).
async function connectRedisWithRetry() {
  for (let attempt = 1; ; attempt += 1) {
    try {
      await ensureRedis();
      console.log('[faucet] redis connection established');
      return;
    } catch (error) {
      console.error(
        `[faucet] redis connect attempt ${attempt} failed; retrying:`,
        error instanceof Error ? error.message : error,
      );
      await new Promise((resolve) => setTimeout(resolve, Math.min(attempt * 1000, 10000)));
    }
  }
}

// infra#629: refresh the faucet wallet-balance gauge from the node. Reuses the
// existing getFaucetWalletBalance() helper. Never throws — a failed refresh sets
// the scrape-success gauge to 0 and leaves the last-known balance in place so a
// transient node blip does not read as "balance = 0".
async function refreshWalletBalanceGauge() {
  try {
    const balance = await getFaucetWalletBalance();
    walletBalanceGauge.set(Number(balance));
    walletBalanceScrapeSuccess.set(1);
  } catch (error) {
    walletBalanceScrapeSuccess.set(0);
    console.error(
      '[faucet] wallet balance gauge refresh failed:',
      error instanceof Error ? error.message : error,
    );
  }
}

// Start the periodic wallet-balance poll. Sets the static floor gauge once, does
// an immediate refresh, then polls on an interval. Returns the timer (unref'd so
// it never keeps the process alive on its own).
function startWalletBalancePolling() {
  try {
    walletBalanceFloorGauge.set(Number(toBaseUnits(FAUCET_WALLET_BALANCE_FLOOR)));
  } catch (error) {
    console.error(
      '[faucet] failed to set wallet balance floor gauge:',
      error instanceof Error ? error.message : error,
    );
  }
  refreshWalletBalanceGauge();
  const timer = setInterval(refreshWalletBalanceGauge, FAUCET_BALANCE_POLL_SECONDS * 1000);
  if (typeof timer.unref === 'function') {
    timer.unref();
  }
  return timer;
}

async function main() {
  // Do not bind a payout service with an unlimited bucket. The owner must
  // provide an explicit absolute mark before any listener or refill loop runs.
  validateHighWaterConfig();
  // Bind the HTTP listener FIRST so the container is always reachable on PORT
  // (and /health always responds) even if Redis is temporarily unreachable.
  // Connecting Redis before listening turned a transient dependency blip into a
  // process that never bound :8080 and looked dead to the healthcheck — the
  // infra#604 outage class. Redis is now connected in the background.
  app.listen(PORT, '0.0.0.0', () => {
    console.log(`wrfcoin-faucet listening on ${PORT}`);
  });
  connectRedisWithRetry();
  // infra#629: begin polling the faucet wallet balance so depletion is visible
  // in Prometheus (wrfcoin_faucet_wallet_balance) and pages via FaucetWalletDry.
  startWalletBalancePolling();
}

// Only boot (connect Redis + listen) when run directly. Requiring the module
// for unit tests must be side-effect free.
if (require.main === module) {
  main().catch((error) => {
    console.error('[faucet] startup failed:', error);
    process.exit(1);
  });
}

// Exported for unit tests — pure helpers, no I/O.
// Test hook: drive the real handler against a supplied Redis client (a
// throwaway local Redis, or an in-memory stand-in). Never used in production.
function setRedisClientForTests(client) {
  redisClient = client;
}

module.exports = {
  app,
  main,
  ensureRedis,
  setRedisClientForTests,
  deviceIdForIdentity,
  DAILY_LIMIT_CODE,
  CLAIM_PENDING_CODE,
  TransferSubmitError,
  isSupportedWalletAddress,
  normalizeWalletAddress,
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
  buildPageConfig,
  renderPage,
  checkBearerToken,
  resolveRequestIdentity,
  assertFaucetConfiguredForPayout,
  parseAccountNonce,
  getFaucetAccount,
  readBoundedNodeJson,
  buildTransferAuthMessage,
  signTransferAuthorization,
  parseRequiredBaseUnits,
  validateHighWaterConfig,
  calculateRefillAmount,
  refillFaucetBucket,
  refreshWalletBalanceGauge,
  startWalletBalancePolling,
  registry,
  BOND_GRANT_DOMAIN,
  buildBondGrantMessage,
  verifyBondGrantSignature,
  parseBondGrantRequest,
  buildBondGrantKeys,
};
