'use strict';

// Bond admission service (design: BOND_ADMISSION.md). Default OFF.
//
// A node operator sends one Deposit (or Update) packet that names the pinned
// bond admission key as its co-signer and already carries the server and
// consumer signatures, plus a peer-identity proof of the node's public P2P
// address (`wrfcoin node bond admission-request`). If the packet and the node
// pass every rule below, the service co-signs it with the admission key and
// returns it. It never submits anything: the owner adds the payout approval
// and submits the Deposit from their own machine, inside the epoch.
//
// The service holds no private key material in this process. Every packet
// check and the co-sign run in the core4 CLI (`wrfcoin node bond admit`), which
// reads the admission key file only when the policy has already passed. The
// key file is provisioned by the operator (BOND_ADMISSION_KEY_FILE); this
// service never generates, copies, prints or logs a key. The chain still
// refuses the co-sign until Tony schedules `bond_admission_key`.

const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { execFile } = require('node:child_process');
const { verifyAdmissionPeerSignature } = require('./peer');
const { createMemoryStore, createRedisStore } = require('./store');

const MAX_BODY_BYTES = 48 * 1024;
const HEX64 = /^[0-9a-f]{64}$/;

class AdmissionError extends Error {
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
    enabled: env.BOND_ADMISSION_ENABLED === 'true',
    chainId: env.WRFCOIN_CHAIN_ID || '',
    networkId: env.WRFCOIN_NETWORK_ID || '',
    cli: env.BOND_ADMISSION_CLI || 'wrfcoin',
    keyFile: env.BOND_ADMISSION_KEY_FILE || '',
    nodeUrl: (env.BOND_ADMISSION_NODE_URL || 'http://127.0.0.1:8556').replace(/\/+$/, ''),
    readerToken: env.BOND_ADMISSION_READER_TOKEN || '',
    ipSalt: env.BOND_ADMISSION_IP_SALT || '',
    redisUrl: env.REDIS_URL || '',
    prefix: env.BOND_ADMISSION_PREFIX || 'bond-admission:',
    port: int(env.PORT, 8094, 1, 65535),
    softCeiling: int(env.BOND_ADMISSION_SOFT_CEILING, 16, 1, 32),
    minPeerAgeSeconds: int(env.BOND_ADMISSION_MIN_PEER_AGE_SECONDS, 86400, 1, 2592000),
    maxLagBlocks: int(env.BOND_ADMISSION_MAX_LAG_BLOCKS, 20, 1, 1000),
    maxAdvertAgeSeconds: int(env.BOND_ADMISSION_MAX_ADVERT_AGE_SECONDS, 300, 1, 86400),
    maxInFlight: int(env.BOND_ADMISSION_MAX_IN_FLIGHT, 2, 1, 16),
    limits: {
      dailyCap: int(env.BOND_ADMISSION_DAILY_CAP, 2, 1, 100),
      minIntervalSeconds: int(env.BOND_ADMISSION_MIN_INTERVAL_SECONDS, 21600, 1, 604800),
      ipTtlSeconds: int(env.BOND_ADMISSION_IP_TTL_SECONDS, 2592000, 3600, 31536000),
      // How much of an IPv6 address counts as one public address: 48, 56 or 64 bits.
      ipv6PrefixBits: [48, 56, 64].includes(Number(env.BOND_ADMISSION_IPV6_PREFIX_BITS)) ? Number(env.BOND_ADMISSION_IPV6_PREFIX_BITS) : 64,
    },
  };
}

// Addresses a home node can't be reached on from outside, plus documentation
// ranges. CGNAT (100.64/10) is refused on purpose: no port forward, no bond.
const NOT_PUBLIC = new net.BlockList();
for (const [address, prefix] of [
  ['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8], ['169.254.0.0', 16],
  ['172.16.0.0', 12], ['192.0.0.0', 24], ['192.0.2.0', 24], ['192.168.0.0', 16], ['198.18.0.0', 15],
  ['198.51.100.0', 24], ['203.0.113.0', 24], ['224.0.0.0', 4], ['240.0.0.0', 4],
]) NOT_PUBLIC.addSubnet(address, prefix, 'ipv4');
for (const [address, prefix] of [
  // IPv4-mapped (::ffff:0:0/96) is refused in parseRequest instead: a
  // BlockList ipv6 rule for it would also match every plain IPv4 address.
  // 2001::/32 (Teredo) and 2002::/16 (6to4) are tunnels over one IPv4 address.
  ['::', 128], ['::1', 128], ['64:ff9b::', 96], ['100::', 64], ['2001::', 32], ['2001:db8::', 32], ['2002::', 16],
  ['fc00::', 7], ['fe80::', 10], ['ff00::', 8],
]) NOT_PUBLIC.addSubnet(address, prefix, 'ipv6');

const MULTIADDR = /^\/(ip4|ip6)\/([0-9A-Fa-f:.]+)\/tcp\/(\d{1,5})\/p2p\/([1-9A-HJ-NP-Za-km-z]{40,60})$/;

function parseRequest(body, ipv6PrefixBits = 64) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    throw new AdmissionError(400, 'INVALID_ADMISSION_REQUEST', 'Expected a JSON object');
  }
  const { transaction, peerId, multiaddr, peerSignature } = body;
  if (!transaction || typeof transaction !== 'object' || Array.isArray(transaction)) {
    throw new AdmissionError(400, 'INVALID_ADMISSION_REQUEST', 'transaction must be the packet object');
  }
  if (typeof multiaddr !== 'string' || multiaddr.length > 200) {
    throw new AdmissionError(400, 'INVALID_ADMISSION_REQUEST', 'multiaddr must be /ip4|ip6/<address>/tcp/<port>/p2p/<peer id>');
  }
  const match = MULTIADDR.exec(multiaddr);
  if (!match) {
    throw new AdmissionError(400, 'INVALID_ADMISSION_REQUEST', 'multiaddr must be /ip4|ip6/<address>/tcp/<port>/p2p/<peer id>');
  }
  const [, family, address, portText, addrPeer] = match;
  const port = Number(portText);
  const version = net.isIP(address);
  if ((family === 'ip4' && version !== 4) || (family === 'ip6' && version !== 6) || port < 1 || port > 65535) {
    throw new AdmissionError(400, 'INVALID_ADMISSION_REQUEST', 'multiaddr address or port is invalid');
  }
  const mapped = family === 'ip6' && /^::ffff:/i.test(address);
  if (mapped || NOT_PUBLIC.check(address, family === 'ip4' ? 'ipv4' : 'ipv6')) {
    throw new AdmissionError(422, 'ADDRESS_NOT_PUBLIC', 'The node must announce a public address with an open port');
  }
  if (typeof peerId !== 'string' || addrPeer !== peerId) {
    throw new AdmissionError(400, 'INVALID_ADMISSION_REQUEST', 'peerId must be the peer id the multiaddr ends in');
  }
  if (typeof peerSignature !== 'string' || !/^[0-9a-f]{128}$/.test(peerSignature)) {
    throw new AdmissionError(400, 'INVALID_ADMISSION_REQUEST', 'peerSignature must be 128 lowercase hex');
  }
  return { transaction, peerId, multiaddr, peerSignature, address: addressGroup(family, address, ipv6PrefixBits) };
}

function normalizeHex(value) {
  return typeof value === 'string' ? value.toLowerCase().replace(/^0x/, '') : '';
}

// What "one public address" means for the limits. IPv4: the address itself.
// IPv6: its network prefix (default /64), in one canonical spelling. A home
// connection is handed a whole /64 or more, and one IPv6 address can be written
// many ways, so the exact text would count one home as many addresses.
function addressGroup(family, address, ipv6PrefixBits = 64) {
  if (family === 'ip4') return address;
  let text = address.toLowerCase();
  const dotted = /^(.*:)(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(text);
  if (dotted) {
    const [a, b, c, d] = dotted.slice(2).map(Number);
    text = `${dotted[1]}${((a << 8) | b).toString(16)}:${((c << 8) | d).toString(16)}`;
  }
  const [head, tail] = text.split('::');
  const left = head ? head.split(':') : [];
  const right = tail ? tail.split(':') : [];
  const groups = tail === undefined ? left : [...left, ...Array(8 - left.length - right.length).fill('0'), ...right];
  const top = groups.slice(0, 4).reduce((value, group) => (value << 16n) | BigInt(parseInt(group, 16)), 0n);
  const kept = (top >> BigInt(64 - ipv6PrefixBits)) << BigInt(64 - ipv6PrefixBits);
  const words = [48n, 32n, 16n, 0n].map((shift) => ((kept >> shift) & 0xffffn).toString(16));
  return `${words.join(':')}::/${ipv6PrefixBits}`;
}

function addressHash(salt, address) {
  return crypto.createHmac('sha256', salt).update(address).digest('hex');
}

// The CLI gets PATH and HOME only: never this service's tokens or salt.
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

function createNodeReader({ nodeUrl, readerToken }) {
  return async (route) => {
    const response = await fetch(`${nodeUrl}${route}`, {
      headers: readerToken ? { Authorization: `Bearer ${readerToken}` } : {},
      redirect: 'manual',
      signal: AbortSignal.timeout(5000),
    });
    const text = await response.text();
    if (text.length > 1024 * 1024) throw new Error('node answer too large');
    const body = JSON.parse(text);
    if (!response.ok || body?.ok === false || body?.error) throw new Error('node read refused');
    return body?.data ?? body;
  };
}

function createService({ config, store, runCli, readNode, now = () => new Date(), log = () => {} }) {
  let inFlight = 0;

  function configured() {
    return config.chainId && config.networkId === 'testnet' && config.keyFile && config.ipSalt.length >= 16;
  }

  async function withPacketDir(fn) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bond-admission-'));
    try {
      return await fn(dir);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }

  async function checkPacket(dir, transaction) {
    const file = path.join(dir, 'request.json');
    fs.writeFileSync(file, JSON.stringify(transaction), { mode: 0o600 });
    const result = await runCli(['node', 'bond', 'admit', '--transaction-file', file,
      '--chain-id', config.chainId, '--network-id', config.networkId]);
    if (!result.ok) throw new AdmissionError(422, 'ADMISSION_PACKET_REFUSED', result.message);
    const summary = result.data?.summary;
    if (!summary || summary.chain_id !== config.chainId || summary.network_id !== config.networkId
      || !HEX64.test(summary.authorization_hash || '') || !HEX64.test(summary.server_key || '')
      || !HEX64.test(summary.deployment_id || '') || !['Deposit', 'Update'].includes(summary.action)
      || !Number.isSafeInteger(summary.effective_epoch)) {
      throw new AdmissionError(503, 'ADMISSION_UNAVAILABLE', 'The admission check returned an unexpected answer');
    }
    return { file, summary };
  }

  async function assertSyncedPeer(peerId) {
    let tip;
    let peers;
    try {
      const info = await readNode('/network/info');
      tip = Number(info?.chain_height ?? info?.height);
      if (!Number.isSafeInteger(tip) || tip < 1) throw new Error('tip');
      peers = await readNode('/network/peers/sync');
      if (!Array.isArray(peers?.peers)) throw new Error('peers');
    } catch (_error) {
      throw new AdmissionError(503, 'ADMISSION_CHAIN_UNAVAILABLE', 'The service cannot check the chain right now; try later');
    }
    const peer = peers.peers.find((entry) => entry?.peer_id === peerId);
    if (!peer) throw new AdmissionError(409, 'NODE_NOT_VISIBLE', 'The node is not a visible sync peer of the network node');
    const age = peer.connection_age_secs;
    if (typeof age !== 'number' || !Number.isFinite(age) || age < config.minPeerAgeSeconds) {
      throw new AdmissionError(409, 'NODE_TOO_NEW', 'The node must stay connected through the probation period', {
        retryAfterSeconds: typeof age === 'number' && Number.isFinite(age) && age >= 0
          ? Math.ceil(config.minPeerAgeSeconds - age) : config.minPeerAgeSeconds,
      });
    }
    const advertised = Number(peer.advertised_height);
    const advertAge = peer.advertisement_age_secs;
    if (peer.banned === true || !Number.isSafeInteger(advertised) || tip - advertised > config.maxLagBlocks
      || (advertAge !== null && advertAge !== undefined && Number(advertAge) > config.maxAdvertAgeSeconds)) {
      throw new AdmissionError(409, 'NODE_NOT_SYNCED', 'The node is visible but not advertising a recent height');
    }
  }

  async function assertBelowCeiling() {
    let bonds;
    try {
      const page = await readNode('/node/bonds?limit=200');
      bonds = page?.bonds;
      if (!Array.isArray(bonds) || page.next_after) throw new Error('bonds');
    } catch (_error) {
      throw new AdmissionError(503, 'ADMISSION_CHAIN_UNAVAILABLE', 'The service cannot read the bond list right now; try later');
    }
    if (bonds.length >= config.softCeiling) {
      throw new AdmissionError(409, 'ADMISSION_CEILING', 'The testnet bond ceiling is reached; no new bonds are admitted for now', {
        bonds: bonds.length, ceiling: config.softCeiling,
      });
    }
  }

  async function assertReachable(multiaddr, peerId, summary) {
    const result = await runCli(['node', 'bond', 'probe', '--addr', multiaddr]);
    const info = result.data;
    if (!result.ok || info?.reachable !== true || info.peer_id !== peerId) {
      throw new AdmissionError(409, 'NODE_NOT_REACHABLE', 'The service could not reach the node at its announced address; check the port forward');
    }
    if (info.chain_id !== config.chainId || info.network_id !== config.networkId
      || normalizeHex(info.genesis_hash) !== normalizeHex(summary.genesis_hash)) {
      throw new AdmissionError(409, 'NODE_WRONG_CHAIN', 'The node at that address is on another chain');
    }
  }

  async function sign(dir, file) {
    const out = path.join(dir, 'admitted.json');
    const result = await runCli(['node', 'bond', 'admit', '--transaction-file', file,
      '--chain-id', config.chainId, '--network-id', config.networkId,
      '--key-file', config.keyFile, '--out', out]);
    if (!result.ok || result.data?.signed !== true) return null;
    try {
      return JSON.parse(fs.readFileSync(out, 'utf8'));
    } catch (_error) {
      return null;
    }
  }

  async function admit(body) {
    if (!config.enabled) throw new AdmissionError(404, 'ADMISSION_DISABLED', 'Bond admission is not enabled');
    if (!configured()) throw new AdmissionError(503, 'ADMISSION_UNAVAILABLE', 'Bond admission is not configured');
    const request = parseRequest(body, config.limits.ipv6PrefixBits);
    return withPacketDir(async (dir) => {
      const { file, summary } = await checkPacket(dir, request.transaction);
      if (!verifyAdmissionPeerSignature(request.peerId, request.peerSignature, {
        chainId: config.chainId, networkId: config.networkId,
        authorizationHash: summary.authorization_hash, multiaddr: request.multiaddr,
      })) {
        throw new AdmissionError(400, 'INVALID_PEER_SIGNATURE', 'peerSignature does not verify for this packet and address');
      }
      const deposit = summary.action === 'Deposit';
      if (deposit) {
        const expected = `node-${summary.server_key.slice(0, 8)}`;
        if (summary.service_alias !== expected) {
          throw new AdmissionError(422, 'ALIAS_NOT_GENERATED', `Use the generated service alias ${expected}`, { expectedAlias: expected });
        }
      }
      await assertSyncedPeer(request.peerId);
      if (deposit) await assertBelowCeiling();
      await assertReachable(request.multiaddr, request.peerId, summary);

      const reservation = {
        serverKey: summary.server_key,
        deploymentId: summary.deployment_id,
        effectiveEpoch: summary.effective_epoch,
        ipHash: addressHash(config.ipSalt, request.address),
      };
      const reserved = deposit ? await store.reserveDeposit(reservation, now()) : await store.reserveUpdate(reservation);
      if (!reserved.ok) {
        const status = ['ADMISSION_SPACING', 'ADMISSION_DAILY_LIMIT'].includes(reserved.code) ? 429 : 409;
        throw new AdmissionError(status, reserved.code, 'This admission is refused by the testnet limits', {
          retryAfterSeconds: reserved.retryAfterSeconds,
        });
      }
      const transaction = await sign(dir, file);
      if (!transaction) {
        if (reserved.kind === 'new') await store.releaseDeposit(reservation, now());
        if (reserved.kind === 'update') await store.releaseUpdate(reservation);
        throw new AdmissionError(503, 'ADMISSION_SIGN_FAILED', 'The co-sign failed; nothing was reserved, try later');
      }
      await store.record({
        action: summary.action,
        deploymentId: summary.deployment_id,
        serverKey: summary.server_key,
        serviceAlias: summary.service_alias,
        effectiveEpoch: summary.effective_epoch,
        renewal: reserved.kind === 'renewal',
        time: now().toISOString(),
      });
      return {
        admitted: true,
        included: false,
        action: summary.action,
        deploymentId: summary.deployment_id,
        effectiveEpoch: summary.effective_epoch,
        transaction,
        next: 'Add the payout approval, then submit with your owner key before this epoch closes. Admission is good for this epoch only.',
      };
    });
  }

  function send(res, status, body, headers = {}) {
    res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', ...headers });
    res.end(JSON.stringify(body));
  }

  function sendError(res, error) {
    if (error instanceof AdmissionError) {
      const headers = error.extra.retryAfterSeconds ? { 'retry-after': String(error.extra.retryAfterSeconds) } : {};
      return send(res, error.status, { ok: false, error: { code: error.code, message: error.message, ...error.extra } }, headers);
    }
    console.error('[bond-admission] unexpected failure:', error && error.name);
    return send(res, 500, { ok: false, error: { code: 'ADMISSION_FAILED', message: 'Bond admission failed' } });
  }

  async function handle(req, res) {
    const url = new URL(req.url, 'http://local');
    if (req.method === 'GET' && url.pathname === '/health') {
      return send(res, 200, { ok: true, enabled: config.enabled, configured: Boolean(configured()) });
    }
    if (req.method === 'GET' && url.pathname === '/bond-admissions') {
      if (!config.enabled) return sendError(res, new AdmissionError(404, 'ADMISSION_DISABLED', 'Bond admission is not enabled'));
      try {
        return send(res, 200, { admissions: await store.recent() });
      } catch (_error) {
        return sendError(res, new AdmissionError(503, 'ADMISSION_UNAVAILABLE', 'Admission history is unavailable'));
      }
    }
    if (req.method === 'POST' && url.pathname === '/bond-admission') {
      if (inFlight >= config.maxInFlight) {
        return sendError(res, new AdmissionError(429, 'ADMISSION_BUSY', 'The service is busy; try again shortly', { retryAfterSeconds: 30 }));
      }
      inFlight += 1;
      try {
        const body = await readBody(req);
        const data = await admit(body);
        // One line per decision: the outcome and public chain fields only. Never an address, a peer id or a key.
        log(`[bond-admission] decision=ADMITTED action=${data.action} deployment=${data.deploymentId.slice(0, 8)} epoch=${data.effectiveEpoch}`);
        return send(res, 200, { ok: true, data });
      } catch (error) {
        log(`[bond-admission] decision=${error instanceof AdmissionError ? error.code : 'ADMISSION_FAILED'}`);
        return sendError(res, error);
      } finally {
        inFlight -= 1;
      }
    }
    return send(res, 404, { ok: false, error: { code: 'NOT_FOUND', message: 'Not found' } });
  }

  return { handle, admit };
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new AdmissionError(413, 'ADMISSION_REQUEST_TOO_LARGE', 'Request too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch (_error) {
        reject(new AdmissionError(400, 'INVALID_ADMISSION_REQUEST', 'Body must be JSON'));
      }
    });
    req.on('error', reject);
  });
}

async function main() {
  const config = loadConfig();
  let store;
  if (config.redisUrl) {
    const { createClient } = require('redis');
    const client = createClient({ url: config.redisUrl });
    client.on('error', (error) => console.error('[bond-admission] redis error:', error && error.code));
    await client.connect();
    store = createRedisStore(client, config);
  } else {
    if (config.enabled) throw new Error('REDIS_URL is required when BOND_ADMISSION_ENABLED=true');
    store = createMemoryStore(config);
  }
  const service = createService({
    config,
    store,
    runCli: createCliRunner(config.cli),
    readNode: createNodeReader(config),
    log: console.log,
  });
  http.createServer((req, res) => { service.handle(req, res); }).listen(config.port, () => {
    console.log(`[bond-admission] listening on ${config.port}; enabled=${config.enabled}`);
  });
}

if (require.main === module) {
  main().catch((error) => {
    console.error('[bond-admission] failed to start:', error.message);
    process.exit(1);
  });
}

module.exports = {
  AdmissionError, addressGroup, addressHash, cliEnv, createCliRunner, createService, loadConfig, parseCliOutput, parseRequest,
};
