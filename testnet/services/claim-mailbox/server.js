'use strict';

// Claim mailbox (design: CLAIM_MAILBOX.md). Default OFF.
//
// A bonded node is paid for an epoch only if its OWNER submits a receipt batch
// holding claims that ANOTHER bonded node (the consumer) made by fetching from
// it. The consumer has the claims; the owner needs them. This service carries
// them across:
//
//   PUT /claims/<deployment_id>/<epoch>   the house consumer, with a bearer
//   GET /claims/<deployment_id>/<epoch>   anyone; read by `wrfcoin node receipt auto`
//
// Claims hold no secrets (public chain data once included), so the read is
// public. The service checks only the shape; the owner's CLI checks every
// signature and binding again before it signs anything. It holds no key, reads
// no chain state and never submits anything.

const http = require('node:http');
const crypto = require('node:crypto');
const { MAX_CLAIMS, createMemoryStore, createRedisStore } = require('./store');

const MAX_BODY_BYTES = 64 * 1024;
const MAX_CLAIM_HEX = 2 * 1536; // core4 MAX_NODE_CLAIM_BYTES
const HEX64 = /^[0-9a-f]{64}$/;
const HEX = /^(?:[0-9a-f]{2})+$/;
const EPOCH = /^(0|[1-9][0-9]{0,8})$/;
const ROUTE = /^\/claims\/([^/]+)\/([^/]+)$/;

class MailboxError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function int(value, fallback, min, max) {
  if (value === undefined || value === '') return fallback;
  if (!/^\d+$/.test(String(value))) return fallback;
  const n = Number(value);
  return Number.isSafeInteger(n) && n >= min && n <= max ? n : fallback;
}

function loadConfig(env = process.env) {
  return {
    enabled: env.CLAIM_MAILBOX_ENABLED === 'true',
    writeToken: env.CLAIM_MAILBOX_WRITE_TOKEN || '',
    redisUrl: env.REDIS_URL || '',
    prefix: env.CLAIM_MAILBOX_PREFIX || 'claim-mailbox:',
    port: int(env.PORT, 8095, 1, 65535),
    // About three chain-888 epochs (512 blocks at ~77 s is ~11 h each).
    ttlSeconds: int(env.CLAIM_MAILBOX_TTL_SECONDS, 129600, 3600, 1209600),
  };
}

// A write token shorter than this is treated as unset: writes answer 503.
const MIN_TOKEN_LENGTH = 32;

function bearerMatches(header, token) {
  if (!token || token.length < MIN_TOKEN_LENGTH || typeof header !== 'string') return false;
  const match = /^Bearer (.+)$/.exec(header);
  if (!match) return false;
  const a = crypto.createHash('sha256').update(match[1]).digest();
  const b = crypto.createHash('sha256').update(token).digest();
  return crypto.timingSafeEqual(a, b);
}

function parseRoute(pathname) {
  const match = ROUTE.exec(pathname);
  if (!match) return null;
  const [, deploymentId, epoch] = match;
  if (!HEX64.test(deploymentId) || !EPOCH.test(epoch)) {
    throw new MailboxError(400, 'INVALID_CLAIM_ROUTE', 'Expected /claims/<64 lowercase hex bond id>/<epoch>');
  }
  return { deploymentId, epoch };
}

function parseClaims(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body) || !Array.isArray(body.claims)) {
    throw new MailboxError(400, 'INVALID_CLAIMS', 'Expected {"claims":[{"claim_hex":..,"receipt_id":..}]}');
  }
  if (body.claims.length === 0 || body.claims.length > MAX_CLAIMS) {
    throw new MailboxError(400, 'INVALID_CLAIMS', `Between 1 and ${MAX_CLAIMS} claims`);
  }
  const seen = new Set();
  return body.claims.map((claim) => {
    if (!claim || typeof claim !== 'object' || Array.isArray(claim)) {
      throw new MailboxError(400, 'INVALID_CLAIMS', 'Each claim is an object');
    }
    const { claim_hex: claimHex, receipt_id: receiptId } = claim;
    if (typeof receiptId !== 'string' || !HEX64.test(receiptId)) {
      throw new MailboxError(400, 'INVALID_CLAIMS', 'receipt_id must be 64 lowercase hex');
    }
    if (typeof claimHex !== 'string' || claimHex.length > MAX_CLAIM_HEX || !HEX.test(claimHex)) {
      throw new MailboxError(400, 'INVALID_CLAIMS', `claim_hex must be lowercase hex, at most ${MAX_CLAIM_HEX} characters`);
    }
    if (seen.has(receiptId)) throw new MailboxError(400, 'INVALID_CLAIMS', 'A receipt_id appears twice');
    seen.add(receiptId);
    return { claim_hex: claimHex, receipt_id: receiptId };
  });
}

function send(res, status, body) {
  const text = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json',
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    'content-length': Buffer.byteLength(text),
  });
  res.end(text);
}

function sendError(res, error) {
  if (error instanceof MailboxError) {
    return send(res, error.status, { ok: false, error: { code: error.code, message: error.message } });
  }
  return send(res, 500, { ok: false, error: { code: 'MAILBOX_FAILED', message: 'Claim mailbox failed' } });
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new MailboxError(413, 'CLAIMS_TOO_LARGE', 'Request too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch (_error) {
        reject(new MailboxError(400, 'INVALID_CLAIMS', 'Body must be JSON'));
      }
    });
    req.on('error', reject);
  });
}

function createService({ config, store, log = () => {} }) {
  async function handle(req, res) {
    let url;
    try {
      url = new URL(req.url, 'http://local');
    } catch (_error) {
      return send(res, 400, { ok: false, error: { code: 'INVALID_CLAIM_ROUTE', message: 'Bad URL' } });
    }
    if (req.method === 'GET' && url.pathname === '/health') {
      return send(res, 200, { ok: true, enabled: config.enabled, writable: config.writeToken.length >= MIN_TOKEN_LENGTH });
    }
    let route;
    try {
      route = parseRoute(url.pathname);
    } catch (error) {
      return config.enabled ? sendError(res, error) : send(res, 404, { ok: false, error: { code: 'MAILBOX_DISABLED', message: 'The claim mailbox is not enabled' } });
    }
    if (!route) return send(res, 404, { ok: false, error: { code: 'NOT_FOUND', message: 'Not found' } });
    if (!config.enabled) {
      return send(res, 404, { ok: false, error: { code: 'MAILBOX_DISABLED', message: 'The claim mailbox is not enabled' } });
    }
    const { deploymentId, epoch } = route;
    try {
      if (req.method === 'GET') {
        const claims = await store.get(deploymentId, epoch);
        if (claims.length === 0) {
          return send(res, 404, { ok: false, error: { code: 'NO_CLAIM', message: 'No claim for this bond and epoch yet' } });
        }
        return send(res, 200, { deployment_id: deploymentId, epoch, claims });
      }
      if (req.method === 'PUT') {
        if (config.writeToken.length < MIN_TOKEN_LENGTH) {
          throw new MailboxError(503, 'MAILBOX_NOT_WRITABLE', 'No write token is configured');
        }
        if (!bearerMatches(req.headers.authorization, config.writeToken)) {
          throw new MailboxError(401, 'UNAUTHORIZED', 'A valid bearer is required to write');
        }
        const claims = parseClaims(await readBody(req));
        const result = await store.put(deploymentId, epoch, claims);
        if (!result.ok) {
          log(`[claim-mailbox] decision=TOO_MANY_CLAIMS deployment=${deploymentId.slice(0, 8)} epoch=${epoch}`);
          throw new MailboxError(409, 'TOO_MANY_CLAIMS', `This bond and epoch already hold ${result.count} of ${MAX_CLAIMS} claims`);
        }
        // One line per write: public chain fields only.
        log(`[claim-mailbox] decision=STORED deployment=${deploymentId.slice(0, 8)} epoch=${epoch} count=${result.count}`);
        return send(res, 200, { ok: true, data: { deployment_id: deploymentId, epoch, count: result.count } });
      }
      return send(res, 405, { ok: false, error: { code: 'METHOD_NOT_ALLOWED', message: 'GET or PUT' } });
    } catch (error) {
      if (!(error instanceof MailboxError)) console.error('[claim-mailbox] unexpected failure:', error && error.name);
      return sendError(res, error);
    }
  }
  return { handle };
}

async function main() {
  const config = loadConfig();
  let store;
  if (config.redisUrl) {
    const { createClient } = require('redis');
    const client = createClient({ url: config.redisUrl });
    client.on('error', (error) => console.error('[claim-mailbox] redis error:', error && error.code));
    await client.connect();
    store = createRedisStore(client, config);
  } else {
    if (config.enabled) throw new Error('REDIS_URL is required when CLAIM_MAILBOX_ENABLED=true');
    store = createMemoryStore(config);
  }
  const service = createService({ config, store, log: console.log });
  http.createServer((req, res) => { service.handle(req, res); }).listen(config.port, () => {
    console.log(`[claim-mailbox] listening on ${config.port}; enabled=${config.enabled}`);
  });
}

if (require.main === module) {
  main().catch((error) => {
    console.error('[claim-mailbox] failed to start:', error.message);
    process.exit(1);
  });
}

module.exports = { MailboxError, MIN_TOKEN_LENGTH, bearerMatches, createService, loadConfig, parseClaims, parseRoute };
