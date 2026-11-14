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

module.exports = { MAX_CLAIMS, PUT_LUA, claimsKey, createMemoryStore, createRedisStore };
