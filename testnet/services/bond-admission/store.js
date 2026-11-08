'use strict';

// Admission marks, in one atomic step per request (BOND_ADMISSION.md, "Limits").
//
// Deposit reservation, refused in this order:
//   1. this server key was already admitted          -> SERVER_KEY_ALREADY_ADMITTED
//      (unless it is a renewal: the same deployment asks again for a later
//      effective epoch from the same address hash, because the first packet
//      missed its epoch; a renewal is not charged against the limits)
//   2. this public address hash holds an admission   -> ADDRESS_ALREADY_ADMITTED
//   3. the global gap since the last admission       -> ADMISSION_SPACING
//   4. today's (UTC) count is used up                -> ADMISSION_DAILY_LIMIT
// then it marks the server key (no expiry), the address hash (expires after
// ipTtlSeconds), the gap and today's count.
//
// Update reservation: at most one per deployment per effective epoch (the chain
// allows one change per epoch anyway). Updates take no slot, so they are not
// charged against the address, gap or daily limits.
//
// Only salted address hashes are stored, never an address.

const RESERVE_DEPOSIT_LUA = `-- bond-admission-reserve-deposit
local srv = redis.call('GET', KEYS[1])
local ip = redis.call('GET', KEYS[2])
if srv then
  local dep, ep = string.match(srv, '^(%x+):(%d+)$')
  if dep == ARGV[1] and tonumber(ARGV[2]) > tonumber(ep) and ip == ARGV[1] then
    redis.call('SET', KEYS[1], ARGV[1] .. ':' .. ARGV[2])
    redis.call('SET', KEYS[2], ARGV[1], 'EX', tonumber(ARGV[3]))
    return {2, 0}
  end
  return {-1, 0}
end
if ip then return {-2, redis.call('TTL', KEYS[2])} end
local gap = redis.call('TTL', KEYS[4])
if gap > 0 then return {-3, gap} end
local count = tonumber(redis.call('GET', KEYS[3]) or '0')
if count >= tonumber(ARGV[6]) then return {-4, redis.call('TTL', KEYS[3])} end
redis.call('INCR', KEYS[3])
redis.call('EXPIRE', KEYS[3], tonumber(ARGV[4]))
redis.call('SET', KEYS[4], ARGV[1], 'EX', tonumber(ARGV[5]))
redis.call('SET', KEYS[1], ARGV[1] .. ':' .. ARGV[2])
redis.call('SET', KEYS[2], ARGV[1], 'EX', tonumber(ARGV[3]))
return {1, 0}`;

const RELEASE_DEPOSIT_LUA = `-- bond-admission-release-deposit
if redis.call('GET', KEYS[1]) == ARGV[1] .. ':' .. ARGV[2] then redis.call('DEL', KEYS[1]) end
if redis.call('GET', KEYS[2]) == ARGV[1] then redis.call('DEL', KEYS[2]) end
if redis.call('GET', KEYS[4]) == ARGV[1] then redis.call('DEL', KEYS[4]) end
local count = tonumber(redis.call('GET', KEYS[3]) or '0')
if count > 0 then redis.call('DECR', KEYS[3]) end
return 1`;

const REFUSALS = {
  '-1': 'SERVER_KEY_ALREADY_ADMITTED',
  '-2': 'ADDRESS_ALREADY_ADMITTED',
  '-3': 'ADMISSION_SPACING',
  '-4': 'ADMISSION_DAILY_LIMIT',
};

function utcDay(now) {
  return now.toISOString().slice(0, 10);
}
function secondsToUtcMidnight(now) {
  const next = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1);
  return Math.max(1, Math.ceil((next - now.getTime()) / 1000));
}

function depositKeys(prefix, { serverKey, ipHash }, now) {
  return [
    `${prefix}server:${serverKey}`,
    `${prefix}ip:${ipHash}`,
    `${prefix}day:${utcDay(now)}`,
    `${prefix}gap`,
  ];
}

function depositArgs(limits, { deploymentId, effectiveEpoch }, now) {
  return [
    deploymentId, String(effectiveEpoch), String(limits.ipTtlSeconds),
    String(secondsToUtcMidnight(now) + 3600), String(limits.minIntervalSeconds), String(limits.dailyCap),
  ];
}

function outcome(result) {
  const [code, ttl] = result.map(Number);
  if (code === 1) return { ok: true, kind: 'new' };
  if (code === 2) return { ok: true, kind: 'renewal' };
  return { ok: false, code: REFUSALS[String(code)] || 'ADMISSION_REFUSED', retryAfterSeconds: ttl > 0 ? ttl : undefined };
}

function createRedisStore(client, { prefix, limits }) {
  return {
    async reserveDeposit(request, now = new Date()) {
      const result = await client.eval(RESERVE_DEPOSIT_LUA, {
        keys: depositKeys(prefix, request, now), arguments: depositArgs(limits, request, now),
      });
      return outcome(result);
    },
    async releaseDeposit(request, now = new Date()) {
      await client.eval(RELEASE_DEPOSIT_LUA, {
        keys: depositKeys(prefix, request, now), arguments: depositArgs(limits, request, now),
      });
    },
    async reserveUpdate({ deploymentId, effectiveEpoch }) {
      const set = await client.set(`${prefix}update:${deploymentId}:${effectiveEpoch}`, '1', { NX: true, EX: 7 * 86400 });
      return set ? { ok: true, kind: 'update' } : { ok: false, code: 'UPDATE_ALREADY_ADMITTED' };
    },
    async releaseUpdate({ deploymentId, effectiveEpoch }) {
      await client.del(`${prefix}update:${deploymentId}:${effectiveEpoch}`);
    },
    async record(row) {
      await client.lPush(`${prefix}audit`, JSON.stringify(row));
      await client.lTrim(`${prefix}audit`, 0, 99);
    },
    async recent() {
      return (await client.lRange(`${prefix}audit`, 0, 99)).map((row) => JSON.parse(row));
    },
  };
}

// Same rules in memory, for tests and a single-process rehearsal.
function createMemoryStore({ prefix, limits }) {
  const values = new Map(); // key -> { value, expiresAt|null }
  const audit = [];
  let clock = () => Date.now();
  const get = (key) => {
    const entry = values.get(key);
    if (!entry) return null;
    if (entry.expiresAt !== null && entry.expiresAt <= clock()) { values.delete(key); return null; }
    return entry.value;
  };
  const ttl = (key) => {
    const entry = get(key) === null ? null : values.get(key);
    if (!entry) return -2;
    return entry.expiresAt === null ? -1 : Math.ceil((entry.expiresAt - clock()) / 1000);
  };
  const set = (key, value, seconds) => values.set(key, { value, expiresAt: seconds ? clock() + seconds * 1000 : null });
  return {
    setClock(fn) { clock = fn; },
    async reserveDeposit(request, now = new Date(clock())) {
      const [srvKey, ipKey, dayKey, gapKey] = depositKeys(prefix, request, now);
      const [token, epoch, ipTtl, dayTtl, gapSeconds, cap] = depositArgs(limits, request, now);
      const srv = get(srvKey);
      const ip = get(ipKey);
      if (srv) {
        const [dep, ep] = srv.split(':');
        if (dep === token && Number(epoch) > Number(ep) && ip === token) {
          set(srvKey, `${token}:${epoch}`);
          set(ipKey, token, Number(ipTtl));
          return outcome([2, 0]);
        }
        return outcome([-1, 0]);
      }
      if (ip) return outcome([-2, ttl(ipKey)]);
      if (ttl(gapKey) > 0) return outcome([-3, ttl(gapKey)]);
      const count = Number(get(dayKey) || 0);
      if (count >= Number(cap)) return outcome([-4, ttl(dayKey)]);
      set(dayKey, String(count + 1), Number(dayTtl));
      set(gapKey, token, Number(gapSeconds));
      set(srvKey, `${token}:${epoch}`);
      set(ipKey, token, Number(ipTtl));
      return outcome([1, 0]);
    },
    async releaseDeposit(request, now = new Date(clock())) {
      const [srvKey, ipKey, dayKey, gapKey] = depositKeys(prefix, request, now);
      const token = request.deploymentId;
      if (get(srvKey) === `${token}:${request.effectiveEpoch}`) values.delete(srvKey);
      if (get(ipKey) === token) values.delete(ipKey);
      if (get(gapKey) === token) values.delete(gapKey);
      const count = Number(get(dayKey) || 0);
      if (count > 0) values.get(dayKey).value = String(count - 1);
    },
    async reserveUpdate({ deploymentId, effectiveEpoch }) {
      const key = `${prefix}update:${deploymentId}:${effectiveEpoch}`;
      if (get(key)) return { ok: false, code: 'UPDATE_ALREADY_ADMITTED' };
      set(key, '1', 7 * 86400);
      return { ok: true, kind: 'update' };
    },
    async releaseUpdate({ deploymentId, effectiveEpoch }) {
      values.delete(`${prefix}update:${deploymentId}:${effectiveEpoch}`);
    },
    async record(row) { audit.unshift(row); audit.length = Math.min(audit.length, 100); },
    async recent() { return audit.slice(); },
    _keys() { return [...values.keys()].filter((key) => get(key) !== null); },
  };
}

module.exports = { createRedisStore, createMemoryStore, RESERVE_DEPOSIT_LUA, RELEASE_DEPOSIT_LUA };
