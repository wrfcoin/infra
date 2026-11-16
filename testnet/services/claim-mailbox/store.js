'use strict';

// Claim storage (CLAIM_MAILBOX.md). One hash per bond and epoch: field =
// receipt id, value = claim hex. A write merges by receipt id, all or nothing,
// and refuses a set that would exceed MAX_CLAIMS. Every key expires.

const MAX_CLAIMS = 8; // core4 MAX_NODE_CLAIMS: one batch holds at most 8 claims

const PUT_LUA = `-- claim-mailbox-put
local n = #ARGV - 1
local new = 0
for i = 2, #ARGV, 2 do
  if redis.call('HEXISTS', KEYS[1], ARGV[i]) == 0 then new = new + 1 end
end
local have = redis.call('HLEN', KEYS[1])
if have + new > ${MAX_CLAIMS} then return {-1, have} end
for i = 2, #ARGV, 2 do
  redis.call('HSET', KEYS[1], ARGV[i], ARGV[i + 1])
end
redis.call('EXPIRE', KEYS[1], tonumber(ARGV[1]))
return {1, redis.call('HLEN', KEYS[1])}`;

function claimsKey(prefix, deploymentId, epoch) {
  return `${prefix}claims:${deploymentId}:${epoch}`;
}

function sorted(map) {
  return Object.entries(map)
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([receipt_id, claim_hex]) => ({ claim_hex, receipt_id }));
}

function putOutcome([code, count]) {
  return Number(code) === 1
    ? { ok: true, count: Number(count) }
    : { ok: false, code: 'TOO_MANY_CLAIMS', count: Number(count) };
}

function createRedisStore(client, { prefix, ttlSeconds }) {
  return {
    async put(deploymentId, epoch, claims) {
      const args = [String(ttlSeconds)];
      for (const c of claims) args.push(c.receipt_id, c.claim_hex);
      return putOutcome(await client.eval(PUT_LUA, { keys: [claimsKey(prefix, deploymentId, epoch)], arguments: args }));
    },
    async get(deploymentId, epoch) {
      return sorted(await client.hGetAll(claimsKey(prefix, deploymentId, epoch)));
    },
  };
}

// Same rules in memory, for tests and a single-process rehearsal.
function createMemoryStore({ prefix, ttlSeconds }) {
  const values = new Map(); // key -> { fields: Map, expiresAt }
  let clock = () => Date.now();
  const live = (key) => {
    const entry = values.get(key);
    if (entry && entry.expiresAt <= clock()) { values.delete(key); return null; }
    return entry || null;
  };
  return {
    setClock(fn) { clock = fn; },
    async put(deploymentId, epoch, claims) {
      const key = claimsKey(prefix, deploymentId, epoch);
      const entry = live(key);
      const fields = entry ? entry.fields : new Map();
      const fresh = new Set(claims.map((c) => c.receipt_id).filter((id) => !fields.has(id)));
      if (fields.size + fresh.size > MAX_CLAIMS) return putOutcome([-1, fields.size]);
      for (const c of claims) fields.set(c.receipt_id, c.claim_hex);
      values.set(key, { fields, expiresAt: clock() + ttlSeconds * 1000 });
      return putOutcome([1, fields.size]);
    },
    async get(deploymentId, epoch) {
      const entry = live(claimsKey(prefix, deploymentId, epoch));
      return entry ? sorted(Object.fromEntries(entry.fields)) : [];
    },
  };
}


// Address records (NODE_ADDRESSES.md): one hash per server key K holding the
// whole record and its (epoch, height). A write replaces it only when newer;
// the same bytes again are UNCHANGED; older is STALE. An index (sorted set,
// score = expiry ms) lets the house consumer list live records; every key
// expires. A per-K counter bounds accepted-signature writes per hour.
const ADDRESS_PUT_LUA = `-- node-address-put
local epoch = tonumber(ARGV[1])
local height = tonumber(ARGV[2])
local now = tonumber(ARGV[5])
local ttl = tonumber(ARGV[4])
local old = redis.call('HMGET', KEYS[1], 'epoch', 'height', 'record')
if old[3] then
  if old[3] == ARGV[3] then return 0 end
  local oe = tonumber(old[1])
  local oh = tonumber(old[2])
  if epoch < oe or (epoch == oe and height <= oh) then return -1 end
end
redis.call('HSET', KEYS[1], 'epoch', ARGV[1], 'height', ARGV[2], 'record', ARGV[3])
redis.call('EXPIRE', KEYS[1], ttl)
redis.call('ZADD', KEYS[2], now + ttl * 1000, ARGV[6])
redis.call('ZREMRANGEBYSCORE', KEYS[2], '-inf', now)
return 1`;

const RATE_LUA = `-- node-address-rate
local n = redis.call('INCR', KEYS[1])
if n == 1 then redis.call('EXPIRE', KEYS[1], tonumber(ARGV[1])) end
return n`;

const PUT_OUTCOME = { 1: 'STORED', 0: 'UNCHANGED', '-1': 'STALE_RECORD' };
// Never more records than this in one list answer (the bond ceiling is 16-32).
const MAX_LISTED = 256;

function addressKey(prefix, serverKey) { return `${prefix}addr:${serverKey}`; }
function addressIndex(prefix) { return `${prefix}addr-index`; }
function rateKey(prefix, serverKey) { return `${prefix}addr-rate:${serverKey}`; }

function createRedisAddressStore(client, { prefix, addressTtlSeconds }) {
  return {
    async put(record, nowMs = Date.now()) {
      const code = await client.eval(ADDRESS_PUT_LUA, {
        keys: [addressKey(prefix, record.server_key), addressIndex(prefix)],
        arguments: [record.epoch, record.height, JSON.stringify(record), String(addressTtlSeconds), String(nowMs), record.server_key],
      });
      return PUT_OUTCOME[String(code)];
    },
    async get(serverKey) {
      const text = await client.hGet(addressKey(prefix, serverKey), 'record');
      return text ? JSON.parse(text) : null;
    },
    async list(nowMs = Date.now()) {
      await client.zRemRangeByScore(addressIndex(prefix), '-inf', nowMs);
      const keys = await client.zRange(addressIndex(prefix), 0, MAX_LISTED - 1);
      const out = [];
      for (const k of keys) {
        const record = await this.get(k);
        if (record) out.push(record);
      }
      return out.sort((a, b) => (a.server_key < b.server_key ? -1 : 1));
    },
    async hit(serverKey) {
      return Number(await client.eval(RATE_LUA, { keys: [rateKey(prefix, serverKey)], arguments: ['3600'] }));
    },
  };
}

function createMemoryAddressStore({ addressTtlSeconds }) {
  const records = new Map(); // K -> { record, text, epoch, height, expiresAt }
  const rates = new Map(); // K -> { n, resetAt }
  let clock = () => Date.now();
  const live = (k) => {
    const entry = records.get(k);
    if (entry && entry.expiresAt <= clock()) { records.delete(k); return null; }
    return entry || null;
  };
  return {
    setClock(fn) { clock = fn; },
    async put(record) {
      const text = JSON.stringify(record);
      const old = live(record.server_key);
      const epoch = BigInt(record.epoch);
      const height = BigInt(record.height);
      if (old) {
        if (old.text === text) return 'UNCHANGED';
        if (epoch < old.epoch || (epoch === old.epoch && height <= old.height)) return 'STALE_RECORD';
      }
      records.set(record.server_key, { record, text, epoch, height, expiresAt: clock() + addressTtlSeconds * 1000 });
      return 'STORED';
    },
    async get(serverKey) {
      const entry = live(serverKey);
      return entry ? JSON.parse(entry.text) : null;
    },
    async list() {
      return [...records.keys()].map(live).filter(Boolean).slice(0, MAX_LISTED)
        .map((e) => JSON.parse(e.text)).sort((a, b) => (a.server_key < b.server_key ? -1 : 1));
    },
    async hit(serverKey) {
      const now = clock();
      const entry = rates.get(serverKey);
      if (!entry || entry.resetAt <= now) { rates.set(serverKey, { n: 1, resetAt: now + 3600 * 1000 }); return 1; }
      entry.n += 1;
      return entry.n;
    },
  };
}


// Attester applications (ATTESTER_APPLICATIONS.md): one hash per bond holding the whole
// record, its (epoch, height) and its oracle key, plus a string per oracle key naming the
// bond that holds it, so one oracle key has at most one live application. A write replaces
// the bond's record only when newer; the same bytes again are UNCHANGED; older is STALE;
// an oracle key another live bond holds is ORACLE_KEY_IN_USE. A newer record that names a
// different oracle key releases the old one. An index (sorted set, score = expiry ms) lists
// live records; every key expires. A per-K counter bounds accepted writes per hour.
const APPLICATION_PUT_LUA = `-- attester-application-put
local epoch = tonumber(ARGV[1])
local height = tonumber(ARGV[2])
local ttl = tonumber(ARGV[4])
local now = tonumber(ARGV[5])
local old = redis.call('HMGET', KEYS[1], 'epoch', 'height', 'record', 'oracle')
if old[3] then
  if old[3] == ARGV[3] then return 0 end
  local oe = tonumber(old[1])
  local oh = tonumber(old[2])
  if epoch < oe or (epoch == oe and height <= oh) then return -1 end
end
local holder = redis.call('GET', KEYS[2])
if holder and holder ~= ARGV[6] then return -2 end
redis.call('HSET', KEYS[1], 'epoch', ARGV[1], 'height', ARGV[2], 'record', ARGV[3], 'oracle', ARGV[7])
redis.call('EXPIRE', KEYS[1], ttl)
redis.call('SET', KEYS[2], ARGV[6], 'EX', ttl)
if old[4] and old[4] ~= ARGV[7] then
  local oldKey = ARGV[8] .. old[4]
  if redis.call('GET', oldKey) == ARGV[6] then redis.call('DEL', oldKey) end
end
redis.call('ZADD', KEYS[3], now + ttl * 1000, ARGV[6])
redis.call('ZREMRANGEBYSCORE', KEYS[3], '-inf', now)
return 1`;

const APPLICATION_OUTCOME = { 1: 'STORED', 0: 'UNCHANGED', '-1': 'STALE_RECORD', '-2': 'ORACLE_KEY_IN_USE' };

function applicationKey(prefix, bondId) { return `${prefix}attapp:${bondId}`; }
function applicationOracleKey(prefix, oracle) { return `${prefix}attapp-oracle:${oracle}`; }
function applicationIndex(prefix) { return `${prefix}attapp-index`; }
function applicationRateKey(prefix, serverKey) { return `${prefix}attapp-rate:${serverKey}`; }

function applicationCounts(records) {
  const counts = { apply: 0, step_down: 0 };
  for (const r of records) counts[r.kind] += 1;
  return counts;
}

function createRedisApplicationStore(client, { prefix, attesterTtlSeconds }) {
  return {
    async put(record, nowMs = Date.now()) {
      const code = await client.eval(APPLICATION_PUT_LUA, {
        keys: [applicationKey(prefix, record.bond_id), applicationOracleKey(prefix, record.oracle_pubkey), applicationIndex(prefix)],
        arguments: [record.epoch, record.height, JSON.stringify(record), String(attesterTtlSeconds), String(nowMs),
          record.bond_id, record.oracle_pubkey, applicationOracleKey(prefix, '')],
      });
      return APPLICATION_OUTCOME[String(code)];
    },
    async get(bondId) {
      const text = await client.hGet(applicationKey(prefix, bondId), 'record');
      return text ? JSON.parse(text) : null;
    },
    async list(nowMs = Date.now()) {
      await client.zRemRangeByScore(applicationIndex(prefix), '-inf', nowMs);
      const ids = await client.zRange(applicationIndex(prefix), 0, MAX_LISTED - 1);
      const out = [];
      for (const id of ids) {
        const record = await this.get(id);
        if (record) out.push(record);
      }
      return out.sort((a, b) => (a.bond_id < b.bond_id ? -1 : 1));
    },
    async counts(nowMs = Date.now()) {
      return applicationCounts(await this.list(nowMs));
    },
    async hit(serverKey) {
      return Number(await client.eval(RATE_LUA, { keys: [applicationRateKey(prefix, serverKey)], arguments: ['3600'] }));
    },
  };
}

function createMemoryApplicationStore({ attesterTtlSeconds }) {
  const records = new Map(); // bond -> { record, text, epoch, height, expiresAt }
  const rates = new Map();
  let clock = () => Date.now();
  const live = (bond) => {
    const entry = records.get(bond);
    if (entry && entry.expiresAt <= clock()) { records.delete(bond); return null; }
    return entry || null;
  };
  const holderOf = (oracle) => [...records.keys()].map((b) => [b, live(b)]).find(([, e]) => e && e.record.oracle_pubkey === oracle)?.[0];
  const store = {
    setClock(fn) { clock = fn; },
    async put(record) {
      const text = JSON.stringify(record);
      const old = live(record.bond_id);
      const epoch = BigInt(record.epoch);
      const height = BigInt(record.height);
      if (old) {
        if (old.text === text) return 'UNCHANGED';
        if (epoch < old.epoch || (epoch === old.epoch && height <= old.height)) return 'STALE_RECORD';
      }
      const holder = holderOf(record.oracle_pubkey);
      if (holder && holder !== record.bond_id) return 'ORACLE_KEY_IN_USE';
      records.set(record.bond_id, { record, text, epoch, height, expiresAt: clock() + attesterTtlSeconds * 1000 });
      return 'STORED';
    },
    async get(bondId) {
      const entry = live(bondId);
      return entry ? JSON.parse(entry.text) : null;
    },
    async list() {
      return [...records.keys()].map(live).filter(Boolean).slice(0, MAX_LISTED)
        .map((e) => JSON.parse(e.text)).sort((a, b) => (a.bond_id < b.bond_id ? -1 : 1));
    },
    async counts() { return applicationCounts(await store.list()); },
    async hit(serverKey) {
      const now = clock();
      const entry = rates.get(serverKey);
      if (!entry || entry.resetAt <= now) { rates.set(serverKey, { n: 1, resetAt: now + 3600 * 1000 }); return 1; }
      entry.n += 1;
      return entry.n;
    },
  };
  return store;
}

module.exports = {
  ADDRESS_PUT_LUA, APPLICATION_PUT_LUA, MAX_CLAIMS, MAX_LISTED, PUT_LUA, addressKey, applicationKey, applicationOracleKey, claimsKey,
  createMemoryAddressStore, createMemoryApplicationStore, createMemoryStore, createRedisAddressStore, createRedisApplicationStore,
  createRedisStore,
};
