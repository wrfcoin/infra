'use strict';

// Station registrar service (design: STATION_REGISTRAR.md). Default OFF.
//
// A phone owner asks for their station to be registered on chain. The service
// checks the request against the chain's own registrar limits and the
// off-chain abuse limits, holds it for 24 h, and only then has the core4 CLI
// sign it with the online `station_registrar_key` key and submits it, at most
// one per block.
//
// This process never holds key material. The CLI reads the key file
// (STATION_REGISTRAR_KEY_FILE, provisioned by the operator, mode 0600) only on
// the final sign call, after every rule passed. The service never generates,
// copies, prints or logs a key. The chain refuses every registrar
// registration until Tony pins the keys in a release and schedules
// `station_registrar_key`.

const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { execFile } = require('node:child_process');
const policy = require('./policy');
const { createFileStore } = require('./store');

const MAX_BODY_BYTES = 8 * 1024;
const HEX64 = /^[0-9a-f]{64}$/;
const STATION_ID = /^mob-[0-9a-f]{32}$/;
const FEATURE = 'station_registrar_key';
// From this feature a registration needs integer coordinates; the CLI
// contract below does not build them yet, so the service stops rather than
// sign a registration the chain would apply as nothing.
const UNSUPPORTED_FEATURES = ['station_coordinates_fixed_point'];

class RegistrarError extends Error {
  constructor(status, code, message, extra = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.extra = extra;
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
    enabled: env.STATION_REGISTRAR_ENABLED === 'true',
    stopFile: env.STATION_REGISTRAR_STOP_FILE || '',
    chainId: env.WRFCOIN_CHAIN_ID || '',
    networkId: env.WRFCOIN_NETWORK_ID || '',
    genesisHash: (env.STATION_REGISTRAR_GENESIS_HASH || '').toLowerCase(),
    cli: env.STATION_REGISTRAR_CLI || 'wrfcoin',
    keyFile: env.STATION_REGISTRAR_KEY_FILE || '',
    stateFile: env.STATION_REGISTRAR_STATE_FILE || '',
    nodeUrl: (env.STATION_REGISTRAR_NODE_URL || 'http://127.0.0.1:8556').replace(/\/+$/, ''),
    nodeToken: env.STATION_REGISTRAR_NODE_TOKEN || '',
    ipSalt: env.STATION_REGISTRAR_IP_SALT || '',
    trustedProxies: (env.STATION_REGISTRAR_TRUSTED_PROXIES || '').split(',').map((s) => s.trim()).filter(Boolean),
    port: int(env.PORT, 8095, 1, 65535),
    softCeiling: int(env.STATION_REGISTRAR_SOFT_CEILING, policy.CHAIN_PHONE_CEILING, 1, policy.CHAIN_PHONE_CEILING),
    tickSeconds: int(env.STATION_REGISTRAR_TICK_SECONDS, 30, 5, 3600),
    confirmBlocks: int(env.STATION_REGISTRAR_CONFIRM_BLOCKS, 6, 1, 1000),
    retentionSeconds: int(env.STATION_REGISTRAR_RETENTION_SECONDS, 30 * policy.DAY_SECONDS, policy.DAY_SECONDS, 365 * policy.DAY_SECONDS),
    limits: {
      dailyTotal: int(env.STATION_REGISTRAR_DAILY_TOTAL, 20, 1, 100),
      dailyPerIp: int(env.STATION_REGISTRAR_DAILY_PER_IP, 3, 1, 100),
      dailyPerCell: int(env.STATION_REGISTRAR_DAILY_PER_CELL, 3, 1, 100),
      holdSeconds: int(env.STATION_REGISTRAR_HOLD_SECONDS, policy.DAY_SECONDS, 3600, 7 * policy.DAY_SECONDS),
    },
  };
}

// --- client address --------------------------------------------------------

function normalizeIp(address) {
  if (typeof address !== 'string') return null;
  const bare = address.replace(/^::ffff:(?=\d+\.\d+\.\d+\.\d+$)/i, '');
  return net.isIP(bare) ? bare.toLowerCase() : null;
}

// The limit key for an address: the IPv4 address, or the /64 an IPv6 address
// sits in (one home gets a whole /64, so per-address IPv6 limits stop nothing).
function ipLimitKey(address) {
  if (net.isIP(address) === 4) return address;
  if (address.includes('.')) return address; // IPv6 with an embedded IPv4 tail: keep it whole
  return `${expandIpv6(address).slice(0, 4).join(':')}::/64`;
}

function expandIpv6(address) {
  const [head, tail = ''] = address.split('::');
  const a = head ? head.split(':') : [];
  const b = tail ? tail.split(':') : [];
  const fill = address.includes('::') ? Array(8 - a.length - b.length).fill('0') : [];
  return [...a, ...fill, ...b].map((group) => group.padStart(4, '0'));
}

// The visitor's address. Behind the public edge it is the single value the edge
// writes into X-Forwarded-For, trusted only from a listed proxy address.
function clientAddress(req, trustedProxies) {
  const peer = normalizeIp(req.socket?.remoteAddress);
  if (!peer) return null;
  if (!trustedProxies.includes(peer)) return peer;
  const forwarded = req.headers['x-forwarded-for'];
  if (typeof forwarded !== 'string' || forwarded.includes(',')) return null;
  return normalizeIp(forwarded.trim());
}

function ipHash(salt, address) {
  return crypto.createHmac('sha256', salt).update(ipLimitKey(address)).digest('hex');
}

// --- the core4 CLI ---------------------------------------------------------

// The CLI gets PATH and HOME only: never this service's token or salt.
function cliEnv(env = process.env) {
  const out = {};
  for (const name of ['PATH', 'HOME']) if (env[name]) out[name] = env[name];
  return out;
}

function parseCliOutput(stdout) {
  let envelope;
  try {
    envelope = JSON.parse(String(stdout).trim().split('\n').pop());
  } catch (_error) {
    return { ok: false, message: 'CLI output unreadable' };
  }
  if (envelope && envelope.ok === true) return { ok: true, data: envelope.data };
  const message = envelope?.error?.message;
  return { ok: false, message: typeof message === 'string' ? message.slice(0, 300) : 'CLI refused' };
}

function createCliRunner(cli, { timeoutMs = 60000 } = {}) {
  return (args) => new Promise((resolve) => {
    execFile(cli, ['--json', ...args], { env: cliEnv(), timeout: timeoutMs, maxBuffer: 512 * 1024 }, (error, stdout) => {
      const parsed = parseCliOutput(stdout || '');
      if (!error && parsed.ok) return resolve(parsed);
      resolve(parsed.ok ? { ok: false, message: 'CLI failed' } : parsed);
    });
  });
}

// --- the node --------------------------------------------------------------

function createNodeClient({ nodeUrl, nodeToken }) {
  async function request(method, route, body) {
    const headers = nodeToken ? { Authorization: `Bearer ${nodeToken}` } : {};
    if (body !== undefined) headers['content-type'] = 'application/json';
    const response = await fetch(`${nodeUrl}${route}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      redirect: 'manual',
      signal: AbortSignal.timeout(10000),
    });
    const text = await response.text();
    if (text.length > 4 * 1024 * 1024) throw new Error('node answer too large');
    let parsed = null;
    try {
      parsed = text ? JSON.parse(text) : null;
    } catch (_error) {
      parsed = null;
    }
    return { status: response.status, body: parsed };
  }
  return {
    get: (route) => request('GET', route),
    post: (route, body) => request('POST', route, body),
  };
}

function unwrap(body) {
  return body && typeof body === 'object' && 'data' in body ? body.data : body;
}

// --- the service -----------------------------------------------------------

function createService({ config, store, runCli, node, now = () => Date.now() }) {
  const seconds = () => Math.floor(now() / 1000);
  let ticking = false;

  function stopped() {
    if (!config.enabled) return true;
    return Boolean(config.stopFile) && fs.existsSync(config.stopFile);
  }

  function configured() {
    return Boolean(config.chainId && config.networkId === 'testnet' && HEX64.test(config.genesisHash)
      && config.keyFile && config.stateFile && config.nodeToken && config.ipSalt.length >= 16);
  }

  function unavailable(message) {
    return new RegistrarError(503, 'REGISTRAR_CHAIN_UNAVAILABLE', message);
  }

  async function readJson(route) {
    const { status, body } = await node.get(route);
    return { status, data: unwrap(body) };
  }

  // Chain identity, height and the features that decide whether a registrar
  // registration can apply at all.
  async function chainHead() {
    let info;
    let pending;
    try {
      info = await readJson('/network/info');
      pending = await readJson('/transactions/oracle/pending?limit=1');
    } catch (_error) {
      throw unavailable('The service cannot read the chain right now; try later');
    }
    const height = Number(info.data?.chain_height ?? info.data?.height);
    const features = pending.data?.active_features;
    if (info.status !== 200 || pending.status !== 200 || !Number.isSafeInteger(height) || height < 1
      || !Array.isArray(features)) {
      throw unavailable('The service cannot read the chain right now; try later');
    }
    if (String(info.data?.chain_id) !== config.chainId || String(info.data?.network_id ?? config.networkId) !== config.networkId) {
      throw new RegistrarError(503, 'REGISTRAR_WRONG_CHAIN', 'The node is on another chain');
    }
    if (!features.includes(FEATURE)) {
      throw new RegistrarError(503, 'REGISTRAR_NOT_ACTIVE', 'Registrar registration is not active on this chain yet');
    }
    if (UNSUPPORTED_FEATURES.some((name) => features.includes(name))) {
      throw new RegistrarError(503, 'REGISTRAR_FORMAT_UNSUPPORTED', 'The chain needs a registration form this service does not build yet');
    }
    return { height };
  }

  // Is the station new on chain? Not in the registry and owner-ledger nonce 0.
  async function stationState(stationId) {
    let reg;
    let ledger;
    try {
      reg = await readJson(`/transactions/station/registrations/${stationId}`);
      ledger = await readJson(`/transactions/station/registrations/${stationId}/owner-ledger`);
    } catch (_error) {
      throw unavailable('The service cannot read the station registry right now; try later');
    }
    if (reg.status === 200) return { registered: true };
    if (reg.status !== 404) throw unavailable('The service cannot read the station registry right now; try later');
    if (ledger.status === 404) return { registered: false, nonce: 0 };
    const nonce = ledger.data?.owner_ledger?.owner_nonce;
    if (ledger.status !== 200 || !Number.isSafeInteger(nonce) || nonce < 0) {
      throw unavailable('The service cannot read the owner ledger right now; try later');
    }
    return { registered: false, nonce };
  }

  // Active phone stations in the registry. The chain's own count also leaves
  // out owner-suspended stations, so this count is never below the chain's:
  // stopping here is never later than the chain would.
  async function phoneCount() {
    let count = 0;
    let after = '';
    for (let page = 0; page < 100; page += 1) {
      let answer;
      try {
        answer = await readJson(`/transactions/station/registrations?limit=1000${after ? `&after=${encodeURIComponent(after)}` : ''}`);
      } catch (_error) {
        throw unavailable('The service cannot read the station list right now; try later');
      }
      const rows = answer.data?.stations;
      if (answer.status !== 200 || !Array.isArray(rows)) throw unavailable('The service cannot read the station list right now; try later');
      count += rows.filter((s) => s?.hardware_model === policy.PHONE_HARDWARE_MODEL && s?.is_active === true).length;
      if (answer.data.has_more !== true) return count;
      after = answer.data.next_cursor;
      if (typeof after !== 'string' || !after) throw unavailable('The station list could not be paged');
    }
    throw unavailable('The station list is longer than this service reads');
  }

  async function assertBelowCeiling() {
    const count = await phoneCount();
    if (count >= config.softCeiling) {
      throw new RegistrarError(409, 'REGISTRAR_CEILING', 'The testnet phone station ceiling is reached; no new phone stations for now', {
        phoneStations: count, ceiling: config.softCeiling,
      });
    }
  }

  async function withDir(fn) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'station-registrar-'));
    try {
      return await fn(dir);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }

  function cliArgs(file) {
    return ['station', 'registrar-sign', '--row-file', file, '--chain-id', config.chainId,
      '--network-id', config.networkId, '--genesis-hash', config.genesisHash, '--expected-nonce', '0'];
  }

  // Keyless: the CLI checks the owner proof and the registrar shape exactly as
  // the chain will. No key file is read.
  async function checkRow(row) {
    return withDir(async (dir) => {
      const file = path.join(dir, 'row.json');
      fs.writeFileSync(file, JSON.stringify(row), { mode: 0o600 });
      const result = await runCli([...cliArgs(file), '--check']);
      if (!result.ok) throw new RegistrarError(422, 'REGISTRATION_REFUSED', result.message);
      if (result.data?.station_id !== row.station_id || result.data?.owner_proof !== 'valid') {
        throw new RegistrarError(503, 'REGISTRAR_UNAVAILABLE', 'The registration check returned an unexpected answer');
      }
    });
  }

  async function request(body, address) {
    if (stopped()) throw new RegistrarError(503, 'REGISTRAR_STOPPED', 'Station registration is paused');
    if (!configured()) throw new RegistrarError(503, 'REGISTRAR_UNAVAILABLE', 'Station registration is not configured');
    if (!address) throw new RegistrarError(400, 'CLIENT_ADDRESS_UNKNOWN', 'The service could not tell where the request came from');
    const refusal = policy.shapeRefusal(body);
    if (refusal) throw new RegistrarError(422, 'REGISTRATION_REFUSED', refusal);
    const row = Object.fromEntries(policy.ROW_KEYS.map((key) => [key, body[key]]));

    await chainHead();
    const station = await stationState(row.station_id);
    if (station.registered) throw new RegistrarError(409, 'STATION_ALREADY_REGISTERED', 'This station is already on chain');
    if (station.nonce !== 0) throw new RegistrarError(409, 'STATION_NOT_NEW', 'This station has owner history; the registrar registers new stations only');
    await assertBelowCeiling();
    await checkRow(row);

    const at = seconds();
    const entry = {
      stationId: row.station_id,
      ipHash: ipHash(config.ipSalt, address),
      cell: policy.cellOf(row.latitude, row.longitude),
    };
    return store.transact(at, (records) => {
      const code = policy.limitRefusal(config.limits, records, entry, at);
      if (code) {
        const status = code === 'ALREADY_REQUESTED' ? 409 : 429;
        throw new RegistrarError(status, code, code === 'ALREADY_REQUESTED'
          ? 'This station was already requested' : 'Registration is refused by the testnet limits; try later', {
          retryAfterSeconds: policy.limitRetryAfter(code, records, entry, at),
        });
      }
      const releaseAt = at + config.limits.holdSeconds;
      records.push({ ...entry, acceptedAt: at, releaseAt, status: 'held', row, updatedAt: at });
      return { stationId: row.station_id, status: 'held', releaseAt: new Date(releaseAt * 1000).toISOString() };
    });
  }

  function publicStatus(record) {
    const out = { stationId: record.stationId, status: record.status };
    if (record.status === 'held') out.releaseAt = new Date(record.releaseAt * 1000).toISOString();
    if (record.transactionId) out.transactionId = record.transactionId;
    if (record.code) out.code = record.code;
    return out;
  }

  async function update(stationId, at, fields) {
    await store.transact(at, (records) => {
      const record = records.find((r) => r.stationId === stationId);
      if (record) Object.assign(record, fields, { updatedAt: at });
    });
  }

  // Sign with the online key and submit. Only here does the CLI read the key.
  async function signAndSubmit(record, at) {
    return withDir(async (dir) => {
      const file = path.join(dir, 'row.json');
      const out = path.join(dir, 'signed.json');
      fs.writeFileSync(file, JSON.stringify(record.row), { mode: 0o600 });
      const result = await runCli([...cliArgs(file), '--submitted-at', String(at), '--key-file', config.keyFile, '--out', out]);
      if (!result.ok || result.data?.signed !== true) return { signed: false };
      let artifact;
      try {
        artifact = JSON.parse(fs.readFileSync(out, 'utf8'));
      } catch (_error) {
        return { signed: false };
      }
      const transactions = artifact?.transactions;
      if (String(artifact?.chain_id) !== config.chainId || artifact?.network_id !== config.networkId
        || !Array.isArray(transactions) || transactions.length !== 1) {
        return { signed: false };
      }
      let answer;
      try {
        answer = await node.post('/transactions/station/registrations', {
          chain_id: artifact.chain_id, network_id: artifact.network_id, transactions,
        });
      } catch (_error) {
        return { signed: true, submitted: 'unknown' };
      }
      const accepted = unwrap(answer.body)?.accepted;
      if (answer.status === 201 && accepted === 1) {
        const id = transactions[0]?.id ?? transactions[0]?.transaction_id;
        return { signed: true, submitted: 'yes', transactionId: typeof id === 'string' ? id : undefined };
      }
      if (answer.status >= 400 && answer.status < 500) return { signed: true, submitted: 'refused' };
      return { signed: true, submitted: 'unknown' };
    });
  }

  // One step of the release loop. At most one registration is in flight: the
  // next is signed only when the previous one is in the registry, or it is
  // marked for review, and the chain has moved past the block it went into.
  async function tick() {
    if (ticking || stopped() || !configured()) return { action: 'idle' };
    ticking = true;
    try {
      const at = seconds();
      let head;
      try {
        head = await chainHead();
      } catch (_error) {
        return { action: 'wait', reason: 'chain' };
      }
      const records = store.snapshot();
      const inFlight = records.find((r) => r.status === 'submitted');
      if (inFlight) {
        const state = await stationState(inFlight.stationId).catch(() => null);
        if (state?.registered) {
          await update(inFlight.stationId, at, { status: 'registered' });
          return { action: 'confirmed', stationId: inFlight.stationId };
        }
        if (head.height >= inFlight.submittedHeight + config.confirmBlocks) {
          // Mined as a no-op, dropped, or still queued. Never resubmitted by
          // the service: a person reads it back first.
          await update(inFlight.stationId, at, { status: 'needs_review', code: 'NOT_SEEN_ON_CHAIN' });
          return { action: 'review', stationId: inFlight.stationId };
        }
        return { action: 'wait', reason: 'in-flight' };
      }
      // A possibly admitted submission, or a signer that failed, pauses
      // releases until a person has read it back and cleared it.
      if (records.some((r) => r.status === 'needs_review' && ['SUBMIT_UNKNOWN', 'SIGN_FAILED'].includes(r.code))) {
        return { action: 'wait', reason: 'review' };
      }
      const last = Math.max(0, ...records.map((r) => r.submittedHeight || 0));
      if (head.height <= last) return { action: 'wait', reason: 'same-block' };

      const next = records.filter((r) => r.status === 'held' && r.releaseAt <= at)
        .sort((a, b) => a.acceptedAt - b.acceptedAt)[0];
      if (!next) return { action: 'idle' };

      let state;
      try {
        state = await stationState(next.stationId);
      } catch (_error) {
        return { action: 'wait', reason: 'chain' };
      }
      if (state.registered || state.nonce !== 0) {
        await update(next.stationId, at, {
          status: 'refused', code: state.registered ? 'STATION_ALREADY_REGISTERED' : 'STATION_NOT_NEW', row: undefined,
        });
        return { action: 'refused', stationId: next.stationId };
      }
      try {
        await assertBelowCeiling();
      } catch (_error) {
        return { action: 'wait', reason: 'ceiling' };
      }
      if (stopped()) return { action: 'idle' };

      const outcome = await signAndSubmit(next, at);
      if (!outcome.signed) {
        await update(next.stationId, at, { status: 'needs_review', code: 'SIGN_FAILED' });
        return { action: 'review', stationId: next.stationId };
      }
      if (outcome.submitted === 'yes') {
        await update(next.stationId, at, {
          status: 'submitted', submittedAt: at, submittedHeight: head.height, transactionId: outcome.transactionId, row: undefined,
        });
        return { action: 'submitted', stationId: next.stationId };
      }
      if (outcome.submitted === 'refused') {
        await update(next.stationId, at, { status: 'refused', code: 'NODE_REFUSED', row: undefined });
        return { action: 'refused', stationId: next.stationId };
      }
      // Possibly admitted: stop releasing until a person reads it back.
      await update(next.stationId, at, {
        status: 'needs_review', code: 'SUBMIT_UNKNOWN', submittedHeight: head.height, row: undefined,
      });
      return { action: 'review', stationId: next.stationId };
    } finally {
      ticking = false;
    }
  }

  function send(res, status, body, headers = {}) {
    res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', ...headers });
    res.end(JSON.stringify(body));
  }

  function sendError(res, error) {
    if (error instanceof RegistrarError) {
      const headers = error.extra.retryAfterSeconds ? { 'retry-after': String(error.extra.retryAfterSeconds) } : {};
      return send(res, error.status, { ok: false, error: { code: error.code, message: error.message, ...error.extra } }, headers);
    }
    console.error('[station-registrar] unexpected failure:', error && error.name);
    return send(res, 500, { ok: false, error: { code: 'REGISTRAR_FAILED', message: 'Station registration failed' } });
  }

  async function handle(req, res) {
    const url = new URL(req.url, 'http://local');
    if (req.method === 'GET' && url.pathname === '/health') {
      return send(res, 200, { ok: true, enabled: config.enabled, stopped: stopped(), configured: configured() });
    }
    if (req.method === 'GET' && url.pathname.startsWith('/station-registrar/requests/')) {
      const stationId = url.pathname.slice('/station-registrar/requests/'.length);
      if (!STATION_ID.test(stationId)) return sendError(res, new RegistrarError(400, 'INVALID_STATION_ID', 'Not a phone station id'));
      const record = store.snapshot().find((r) => r.stationId === stationId);
      if (!record) return sendError(res, new RegistrarError(404, 'NOT_REQUESTED', 'No request for this station'));
      return send(res, 200, { ok: true, data: publicStatus(record) });
    }
    if (req.method === 'POST' && url.pathname === '/station-registrar/requests') {
      try {
        const body = await readBody(req);
        const data = await request(body, clientAddress(req, config.trustedProxies));
        return send(res, 202, { ok: true, data });
      } catch (error) {
        return sendError(res, error);
      }
    }
    return send(res, 404, { ok: false, error: { code: 'NOT_FOUND', message: 'Not found' } });
  }

  return { handle, request, tick, stopped, configured };
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new RegistrarError(413, 'REQUEST_TOO_LARGE', 'Request too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch (_error) {
        reject(new RegistrarError(400, 'INVALID_REQUEST', 'Body must be JSON'));
      }
    });
    req.on('error', reject);
  });
}

async function main() {
  const config = loadConfig();
  if (config.enabled && !config.stateFile) throw new Error('STATION_REGISTRAR_STATE_FILE is required when enabled');
  const store = createFileStore(config.stateFile || path.join(os.tmpdir(), 'station-registrar-disabled.json'), config);
  if (config.stateFile) store.load();
  const service = createService({
    config,
    store,
    runCli: createCliRunner(config.cli),
    node: createNodeClient(config),
  });
  http.createServer((req, res) => { service.handle(req, res); }).listen(config.port, () => {
    console.log(`[station-registrar] listening on ${config.port}; enabled=${config.enabled}`);
  });
  setInterval(() => {
    service.tick().catch((error) => console.error('[station-registrar] release step failed:', error && error.name));
  }, config.tickSeconds * 1000).unref();
}

if (require.main === module) {
  main().catch((error) => {
    console.error('[station-registrar] failed to start:', error.message);
    process.exit(1);
  });
}

module.exports = {
  RegistrarError, clientAddress, cliEnv, createCliRunner, createNodeClient, createService, ipHash, ipLimitKey,
  loadConfig, normalizeIp, parseCliOutput,
};
