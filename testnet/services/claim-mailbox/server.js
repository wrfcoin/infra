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
const {
  MAX_CLAIMS, createMemoryAddressStore, createMemoryApplicationStore, createMemoryStore, createRedisAddressStore, createRedisApplicationStore, createRedisStore,
} = require('./store');
const { RecordError, parseRecord } = require('./address-record');
const { parseApplication } = require('./attester-application');

const MAX_BODY_BYTES = 64 * 1024;
const MAX_RECORD_BYTES = 4 * 1024;
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
    // Node address records (NODE_ADDRESSES.md). A separate switch, default OFF.
    addressEnabled: env.NODE_ADDRESS_ENABLED === 'true',
    chainId: env.WRFCOIN_CHAIN_ID || '',
    networkId: env.WRFCOIN_NETWORK_ID || '',
    genesisHash: (env.WRFCOIN_GENESIS_HASH || '').toLowerCase().replace(/^0x/, ''),
    nodeUrl: (env.NODE_ADDRESS_NODE_URL || 'http://127.0.0.1:8556').replace(/\/+$/, ''),
    nodeReaderToken: env.NODE_ADDRESS_NODE_READER_TOKEN || '',
    // The house consumer's bearer for reads; under 32 characters = reads refused (503).
    addressReadToken: env.NODE_ADDRESS_READ_TOKEN || '',
    // Three chain-888 epochs: 3 x 512 blocks x ~77 s.
    addressTtlSeconds: int(env.NODE_ADDRESS_TTL_SECONDS, 118272, 3600, 1209600),
    addressWritesPerHour: int(env.NODE_ADDRESS_WRITES_PER_HOUR, 6, 1, 60),
    nodeReadsInFlight: int(env.NODE_ADDRESS_NODE_READS_IN_FLIGHT, 2, 1, 16),
    nodeReadsPerMinute: int(env.NODE_ADDRESS_NODE_READS_PER_MINUTE, 60, 1, 600),
    maxHeightAhead: int(env.NODE_ADDRESS_MAX_HEIGHT_AHEAD, 10, 0, 512),
    // The cached roster of bonded server keys: refreshed at most this often.
    rosterTtlSeconds: int(env.NODE_ADDRESS_ROSTER_TTL_SECONDS, 60, 0, 3600),
    // Attester applications (ATTESTER_APPLICATIONS.md). A separate switch, default OFF. They share the
    // chain identity, node reader, roster and node-read budget above.
    attesterEnabled: env.ATTESTER_APPLICATIONS_ENABLED === 'true',
    // The owner's bearer for reads; under 32 characters = reads refused (503).
    attesterOwnerToken: env.ATTESTER_APPLICATION_OWNER_TOKEN || '',
    // Six chain-888 epochs: 6 x 512 blocks x ~77 s (outlives a weekend).
    attesterTtlSeconds: int(env.ATTESTER_APPLICATION_TTL_SECONDS, 236544, 3600, 2419200),
    attesterWritesPerHour: int(env.ATTESTER_APPLICATION_WRITES_PER_HOUR, 6, 1, 60),
    // Public keys no application may name as its oracle key (governance, producers, snapshot signers).
    attesterForbiddenKeys: String(env.ATTESTER_APPLICATION_FORBIDDEN_KEYS || '').split(',').map((k) => k.trim().toLowerCase())
      .filter((k) => /^[0-9a-f]{64}$/.test(k)),
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

function readBody(req, limit = MAX_BODY_BYTES, tooLarge = 'CLAIMS_TOO_LARGE') {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(new MailboxError(413, tooLarge, 'Request too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch (_error) {
        reject(new MailboxError(400, tooLarge === 'CLAIMS_TOO_LARGE' ? 'INVALID_CLAIMS' : 'INVALID_RECORD', 'Body must be JSON'));
      }
    });
    req.on('error', reject);
  });
}

function createNodeReader({ nodeUrl, nodeReaderToken }) {
  return async (route) => {
    const response = await fetch(`${nodeUrl}${route}`, {
      headers: nodeReaderToken ? { Authorization: `Bearer ${nodeReaderToken}` } : {},
      redirect: 'manual',
      signal: AbortSignal.timeout(5000),
    });
    const text = await response.text();
    if (text.length > 256 * 1024) throw new Error('node answer too large');
    const body = JSON.parse(text);
    if (!response.ok || body?.ok === false || body?.error) throw new Error('node read refused');
    return body?.data ?? body;
  };
}

// `/node/bonds/<id>` names the binding's server key as a 32-number array
// (serde of [u8; 32]); hex is accepted too.
function registeredServerKey(bond) {
  const key = bond?.registration?.binding?.server_key;
  if (typeof key === 'string') return key.toLowerCase().replace(/^0x/, '');
  if (Array.isArray(key) && key.length === 32 && key.every((b) => Number.isInteger(b) && b >= 0 && b <= 255)) {
    return Buffer.from(key).toString('hex');
  }
  return null;
}

function addressConfigured(config) {
  return /^[0-9A-Za-z_-]{1,32}$/.test(config.chainId) && /^[0-9A-Za-z_-]{1,32}$/.test(config.networkId)
    && /^[0-9a-f]{64}$/.test(config.genesisHash);
}

// The roster of bonded server keys, cached so an unknown K is refused without any
// per-request node read (anyone can make a fresh key that signs a valid record).
// Refreshed at most once per rosterTtlSeconds, on demand: one keyset-paged
// /node/bonds list, then /node/bonds/<id> only for bonds that are new or changed
// since the last refresh. Only REGISTERED (not exiting), not jailed bonds are kept.
// Bounded at MAX_ROSTER bonds. A failed refresh keeps the last roster for up to
// 10 TTLs, then refuses with NODE_UNAVAILABLE.
const MAX_ROSTER = 256;

function createRoster({ readNode, ttlMs, now }) {
  let bonds = new Map(); // deployment id -> { key, change }
  let refreshedAt = -Infinity;
  let pending = null;

  async function refresh() {
    const next = new Map();
    let after = '';
    for (let page = 0; page < Math.ceil(MAX_ROSTER / 200) + 1 && next.size < MAX_ROSTER; page += 1) {
      const list = await readNode(`/node/bonds?limit=200${after ? `&after=${after}` : ''}`);
      for (const row of Array.isArray(list?.bonds) ? list.bonds : []) {
        if (next.size >= MAX_ROSTER) break;
        const id = row?.deployment_id;
        if (typeof id !== 'string' || !/^[0-9a-f]{64}$/.test(id)) continue;
        if (row.status !== 'REGISTERED' || row.jailed === true || row.exit_effective_height != null) continue;
        const change = `${row.last_change_epoch}|${row.update_pending === true}`;
        const old = bonds.get(id);
        if (old && old.change === change) { next.set(id, old); continue; }
        const bond = await readNode(`/node/bonds/${id}`);
        const key = registeredServerKey(bond);
        if (key) next.set(id, { key, change });
      }
      after = typeof list?.next_after === 'string' && /^[0-9a-f]{64}$/.test(list.next_after) ? list.next_after : '';
      if (!after) break;
    }
    bonds = next;
    refreshedAt = now();
  }

  return {
    // The registered server key of a live bond, or null. Throws when no fresh-enough roster exists.
    async keyOf(deploymentId) {
      if (now() - refreshedAt >= ttlMs) {
        pending = pending || refresh().finally(() => { pending = null; });
        try {
          await pending;
        } catch (_error) {
          if (now() - refreshedAt >= Math.max(ttlMs, 1000) * 10) {
            throw new MailboxError(503, 'NODE_UNAVAILABLE', 'The bond roster could not be read from the node');
          }
        }
      }
      return bonds.get(deploymentId)?.key || null;
    },
  };
}

// The node-facing checks both signed-record routes share: one cached roster and one
// node-read budget for the whole process, so a second route never doubles the load.
function createBondChecks({ config, readNode, now }) {
  const roster = createRoster({ readNode, ttlMs: config.rosterTtlSeconds * 1000, now });
  let inFlight = 0;
  let windowStart = 0;
  let windowReads = 0;
  let oracleSet = null; // { ids: Set, at }

  // Bounds node reads: a few in flight and a per-minute budget, else 429 BUSY.
  async function throttledRead(route) {
    const t = now();
    if (t - windowStart >= 60000) { windowStart = t; windowReads = 0; }
    if (inFlight >= config.nodeReadsInFlight || windowReads >= config.nodeReadsPerMinute) {
      throw new MailboxError(429, 'BUSY', 'Too many signed records right now; try again later');
    }
    inFlight += 1;
    windowReads += 1;
    try {
      return await readNode(route);
    } catch (_error) {
      throw new MailboxError(503, 'NODE_UNAVAILABLE', 'The bond could not be read from the node');
    } finally {
      inFlight -= 1;
    }
  }

  // Step 5 (no node read): the bond is in the cached roster and K is its server key.
  async function rosterCheck(deploymentId, serverKey, decide) {
    const rosterKey = await roster.keyOf(deploymentId);
    if (!rosterKey) throw decide(403, 'NOT_BONDED', 'This bond is not registered (or is exiting or jailed) on chain');
    if (rosterKey !== serverKey) throw decide(403, 'SERVER_KEY_MISMATCH', 'K is not this bond\'s registered server key');
  }

  // Step 7 (one budgeted node read): live bond, K, the current epoch, height not ahead.
  async function liveBondCheck(deploymentId, serverKey, recordEpoch, recordHeight, decide) {
    const bond = await throttledRead(`/node/bonds/${deploymentId}`);
    // An exiting bond still reads REGISTERED until its exit takes effect: refuse it too.
    if (bond?.status !== 'REGISTERED' || bond?.jailed === true || bond?.registration?.exit_effective_height != null) {
      throw decide(403, 'NOT_BONDED', 'This bond is not registered (or is exiting or jailed) on chain');
    }
    if (registeredServerKey(bond) !== serverKey) {
      throw decide(403, 'SERVER_KEY_MISMATCH', 'K is not this bond\'s registered server key');
    }
    const epoch = typeof bond.epoch === 'string' && /^\d{1,15}$/.test(bond.epoch) ? BigInt(bond.epoch) : null;
    const height = typeof bond.height === 'string' && /^\d{1,15}$/.test(bond.height) ? BigInt(bond.height) : null;
    if (epoch === null || height === null) throw decide(503, 'NODE_UNAVAILABLE', 'The node did not report the epoch');
    const effective = bond?.registration?.binding?.effective_epoch;
    if (!Number.isSafeInteger(effective) || BigInt(effective) > BigInt(recordEpoch)) {
      throw decide(403, 'NOT_BONDED', 'This bond is not in effect for the record epoch');
    }
    if (BigInt(recordEpoch) < epoch) throw decide(409, 'STALE_EPOCH', 'The record is for an earlier epoch');
    if (BigInt(recordEpoch) > epoch) throw decide(409, 'FUTURE_EPOCH', 'The record is for a later epoch than the chain');
    if (BigInt(recordHeight) > height + BigInt(config.maxHeightAhead)) {
      throw decide(409, 'FUTURE_HEIGHT', 'The record height is ahead of the chain');
    }
    return bond;
  }

  // The seated oracle set (GET /transactions/oracle/config, Reader), cached for the roster TTL and
  // read through the same budget. Fails closed: no fresh set = 503.
  async function seatedOracles() {
    const t = now();
    if (oracleSet && t - oracleSet.at < Math.max(config.rosterTtlSeconds * 1000, 1000)) return oracleSet.ids;
    const answer = await throttledRead('/transactions/oracle/config');
    const ids = Array.isArray(answer?.oracle_set) ? answer.oracle_set : null;
    if (!ids || !ids.every((id) => typeof id === 'string' && /^[0-9a-f]{64}$/.test(id))) {
      throw new MailboxError(503, 'NODE_UNAVAILABLE', 'The node did not report the oracle set');
    }
    oracleSet = { ids: new Set(ids), at: t };
    return oracleSet.ids;
  }

  return { rosterCheck, liveBondCheck, seatedOracles };
}

function createAddressService({ config, addressStore, bonds, log }) {

  async function publish(req) {
    if (!addressConfigured(config)) throw new MailboxError(503, 'NOT_CONFIGURED', 'Chain identity is not configured');
    let record;
    try {
      record = parseRecord(await readBody(req, MAX_RECORD_BYTES, 'RECORD_TOO_LARGE'), config);
    } catch (error) {
      if (error instanceof RecordError) {
        const status = error.code === 'BAD_SIGNATURE' ? 403 : error.code === 'ADDRESS_NOT_PUBLIC' ? 422 : 400;
        throw new MailboxError(status, error.code, error.message);
      }
      throw error;
    }
    const k = record.server_key.slice(0, 8);
    const decide = (status, code, message) => {
      log(`[claim-mailbox] address decision=${code} key=${k} epoch=${record.epoch}`);
      return new MailboxError(status, code, message);
    };
    // A replay of what is stored, or of anything older, is answered from the
    // store without a node read and without spending K's budget: only a record
    // newer than the stored one (which only K's holder can sign) counts.
    const current = await addressStore.get(record.server_key);
    if (current) {
      if (JSON.stringify(current) === JSON.stringify(record)) {
        return { status: 'UNCHANGED', server_key: record.server_key, epoch: record.epoch, height: record.height };
      }
      const [ce, ch, re, rh] = [current.epoch, current.height, record.epoch, record.height].map(BigInt);
      if (re < ce || (re === ce && rh <= ch)) throw decide(409, 'STALE_RECORD', 'A newer record for this server key is already stored');
    }
    // Only a bonded node's K gets past here, from the cached roster: a fresh key
    // costs no per-request node read and no budget.
    await bonds.rosterCheck(record.deployment_id, record.server_key, decide);
    // Counted only after both signatures verified and K is bonded: only K's holder spends K's budget.
    if (await addressStore.hit(record.server_key) > config.addressWritesPerHour) {
      throw decide(429, 'RATE_LIMITED', `At most ${config.addressWritesPerHour} records an hour per server key`);
    }
    await bonds.liveBondCheck(record.deployment_id, record.server_key, record.epoch, record.height, decide);
    const outcome = await addressStore.put(record);
    if (outcome === 'STALE_RECORD') throw decide(409, 'STALE_RECORD', 'A newer record for this server key is already stored');
    // One line per decision: first 8 hex of K and the epoch only. Never the address.
    log(`[claim-mailbox] address decision=${outcome} key=${k} epoch=${record.epoch}`);
    return { status: outcome, server_key: record.server_key, epoch: record.epoch, height: record.height };
  }

  async function read(req, pathname) {
    if (config.addressReadToken.length < MIN_TOKEN_LENGTH) {
      throw new MailboxError(503, 'ADDRESSES_NOT_READABLE', 'No read token is configured');
    }
    if (!bearerMatches(req.headers.authorization, config.addressReadToken)) {
      throw new MailboxError(401, 'UNAUTHORIZED', 'A valid bearer is required to read');
    }
    if (pathname === '/addresses') return { records: await addressStore.list() };
    const match = /^\/addresses\/([0-9a-f]{64})$/.exec(pathname);
    if (!match) throw new MailboxError(400, 'INVALID_ADDRESS_ROUTE', 'Expected /addresses/<64 lowercase hex server key>');
    const record = await addressStore.get(match[1]);
    if (!record) throw new MailboxError(404, 'NO_RECORD', 'No live address record for this server key');
    return record;
  }

  return { publish, read };
}

// Attester applications (ATTESTER_APPLICATIONS.md): a bonded node asks to be seated as an
// oracle attester (kind "apply") or to leave (kind "step_down"). Signed by the bond's server
// key K AND the oracle key; one live record per bond and per oracle key; owner-bearer reads.
function createAttesterService({ config, applicationStore, bonds, log }) {
  async function publish(req) {
    if (!addressConfigured(config)) throw new MailboxError(503, 'NOT_CONFIGURED', 'Chain identity is not configured');
    let record;
    try {
      record = parseApplication(await readBody(req, MAX_RECORD_BYTES, 'RECORD_TOO_LARGE'), config);
    } catch (error) {
      if (error instanceof RecordError) {
        const status = error.code === 'BAD_SIGNATURE' || error.code === 'KEY_REUSE' ? 403 : 400;
        throw new MailboxError(status, error.code, error.message);
      }
      throw error;
    }
    // One line per decision: first 8 hex of the bond and the oracle key, the kind and epoch. No address, no IP.
    const tag = `kind=${record.kind} bond=${record.bond_id.slice(0, 8)} oracle=${record.oracle_pubkey.slice(0, 8)} epoch=${record.epoch}`;
    const decide = (status, code, message) => {
      log(`[claim-mailbox] attester decision=${code} ${tag}`);
      return new MailboxError(status, code, message);
    };
    if (config.attesterForbiddenKeys.includes(record.oracle_pubkey)) {
      throw decide(403, 'FORBIDDEN_KEY', 'That key holds another network role and cannot be an oracle key');
    }
    // A replay of what is stored, or of anything older, is answered without a node read or budget.
    const current = await applicationStore.get(record.bond_id);
    if (current) {
      if (JSON.stringify(current) === JSON.stringify(record)) {
        return { status: 'UNCHANGED', bond_id: record.bond_id, kind: record.kind, epoch: record.epoch, height: record.height };
      }
      const [ce, ch, re, rh] = [current.epoch, current.height, record.epoch, record.height].map(BigInt);
      if (re < ce || (re === ce && rh <= ch)) throw decide(409, 'STALE_RECORD', 'A newer application for this bond is already stored');
    }
    await bonds.rosterCheck(record.bond_id, record.server_key, decide);
    if (await applicationStore.hit(record.server_key) > config.attesterWritesPerHour) {
      throw decide(429, 'RATE_LIMITED', `At most ${config.attesterWritesPerHour} applications an hour per server key`);
    }
    await bonds.liveBondCheck(record.bond_id, record.server_key, record.epoch, record.height, decide);
    const seated = await bonds.seatedOracles();
    if (seated.has(record.server_key)) throw decide(403, 'FORBIDDEN_KEY', 'The bond server key is a seated oracle key');
    if (record.kind === 'apply' && seated.has(record.oracle_pubkey)) {
      throw decide(409, 'ALREADY_SEATED', 'This oracle key is already seated');
    }
    if (record.kind === 'step_down' && !seated.has(record.oracle_pubkey)) {
      throw decide(409, 'NOT_SEATED', 'This oracle key is not seated, so there is nothing to step down from');
    }
    const outcome = await applicationStore.put(record);
    if (outcome === 'STALE_RECORD') throw decide(409, 'STALE_RECORD', 'A newer application for this bond is already stored');
    if (outcome === 'ORACLE_KEY_IN_USE') throw decide(409, 'ORACLE_KEY_IN_USE', 'Another bond has a live application for this oracle key');
    log(`[claim-mailbox] attester decision=${outcome} ${tag}`);
    return { status: outcome, bond_id: record.bond_id, kind: record.kind, epoch: record.epoch, height: record.height };
  }

  async function read(req, pathname) {
    if (pathname === '/attester-applications/counts') return applicationStore.counts();
    if (config.attesterOwnerToken.length < MIN_TOKEN_LENGTH) {
      throw new MailboxError(503, 'APPLICATIONS_NOT_READABLE', 'No owner read token is configured');
    }
    if (!bearerMatches(req.headers.authorization, config.attesterOwnerToken)) {
      throw new MailboxError(401, 'UNAUTHORIZED', 'The owner bearer is required to read applications');
    }
    if (pathname === '/attester-applications') return { applications: await applicationStore.list() };
    const match = /^\/attester-applications\/([0-9a-f]{64})$/.exec(pathname);
    if (!match) throw new MailboxError(400, 'INVALID_APPLICATION_ROUTE', 'Expected /attester-applications/<64 lowercase hex bond id>');
    const record = await applicationStore.get(match[1]);
    if (!record) throw new MailboxError(404, 'NO_RECORD', 'No live application for this bond');
    return record;
  }

  return { publish, read };
}

function createService({ config, store, addressStore, applicationStore, readNode, log = () => {}, now = () => Date.now() }) {
  const bonds = createBondChecks({ config, readNode: readNode || createNodeReader(config), now });
  const addresses = createAddressService({
    config,
    addressStore: addressStore || createMemoryAddressStore(config),
    bonds,
    log,
  });
  const attesters = createAttesterService({
    config,
    applicationStore: applicationStore || createMemoryApplicationStore(config),
    bonds,
    log,
  });

  async function handleAttesters(req, res, pathname) {
    if (!config.attesterEnabled) {
      return send(res, 404, { ok: false, error: { code: 'APPLICATIONS_DISABLED', message: 'Attester applications are not enabled' } });
    }
    try {
      if (req.method === 'POST' && pathname === '/attester-applications') {
        return send(res, 200, { ok: true, data: await attesters.publish(req) });
      }
      if (req.method === 'GET') return send(res, 200, { ok: true, data: await attesters.read(req, pathname) });
      return send(res, 405, { ok: false, error: { code: 'METHOD_NOT_ALLOWED', message: 'POST /attester-applications or GET with the owner bearer' } });
    } catch (error) {
      if (!(error instanceof MailboxError)) console.error('[claim-mailbox] unexpected attester failure:', error && error.name);
      return sendError(res, error);
    }
  }

  async function handleAddresses(req, res, pathname) {
    if (!config.addressEnabled) {
      return send(res, 404, { ok: false, error: { code: 'ADDRESSES_DISABLED', message: 'Node address records are not enabled' } });
    }
    try {
      if (req.method === 'POST' && pathname === '/addresses') {
        return send(res, 200, { ok: true, data: await addresses.publish(req) });
      }
      if (req.method === 'GET') return send(res, 200, { ok: true, data: await addresses.read(req, pathname) });
      return send(res, 405, { ok: false, error: { code: 'METHOD_NOT_ALLOWED', message: 'POST /addresses or GET with the read bearer' } });
    } catch (error) {
      if (!(error instanceof MailboxError)) console.error('[claim-mailbox] unexpected address failure:', error && error.name);
      return sendError(res, error);
    }
  }

  async function handle(req, res) {
    let url;
    try {
      url = new URL(req.url, 'http://local');
    } catch (_error) {
      return send(res, 400, { ok: false, error: { code: 'INVALID_CLAIM_ROUTE', message: 'Bad URL' } });
    }
    if (req.method === 'GET' && url.pathname === '/health') {
      return send(res, 200, {
        ok: true,
        enabled: config.enabled,
        writable: config.writeToken.length >= MIN_TOKEN_LENGTH,
        addresses: { enabled: config.addressEnabled, configured: addressConfigured(config), readable: config.addressReadToken.length >= MIN_TOKEN_LENGTH },
        attesters: { enabled: config.attesterEnabled, configured: addressConfigured(config), readable: config.attesterOwnerToken.length >= MIN_TOKEN_LENGTH },
      });
    }
    if (url.pathname === '/attester-applications' || url.pathname.startsWith('/attester-applications/')) {
      return handleAttesters(req, res, url.pathname);
    }
    if (url.pathname === '/addresses' || url.pathname.startsWith('/addresses/')) {
      return handleAddresses(req, res, url.pathname);
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
  let addressStore;
  let applicationStore;
  if (config.redisUrl) {
    const { createClient } = require('redis');
    const client = createClient({ url: config.redisUrl });
    client.on('error', (error) => console.error('[claim-mailbox] redis error:', error && error.code));
    await client.connect();
    store = createRedisStore(client, config);
    addressStore = createRedisAddressStore(client, config);
    applicationStore = createRedisApplicationStore(client, config);
  } else {
    if (config.enabled || config.addressEnabled || config.attesterEnabled) {
      throw new Error('REDIS_URL is required when the mailbox, address records or attester applications are enabled');
    }
    store = createMemoryStore(config);
    addressStore = createMemoryAddressStore(config);
    applicationStore = createMemoryApplicationStore(config);
  }
  const service = createService({ config, store, addressStore, applicationStore, log: console.log });
  http.createServer((req, res) => { service.handle(req, res); }).listen(config.port, () => {
    console.log(`[claim-mailbox] listening on ${config.port}; enabled=${config.enabled} addresses=${config.addressEnabled} attesters=${config.attesterEnabled}`);
  });
}

if (require.main === module) {
  main().catch((error) => {
    console.error('[claim-mailbox] failed to start:', error.message);
    process.exit(1);
  });
}

module.exports = {
  MailboxError, MIN_TOKEN_LENGTH, bearerMatches, createNodeReader, createService, loadConfig, parseClaims, parseRoute, registeredServerKey,
};
