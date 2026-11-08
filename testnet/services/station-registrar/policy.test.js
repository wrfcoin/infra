'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const policy = require('./policy');

const OWNER = '0x00112233445566778899aabbccddeeff00112233';

function row(overrides = {}) {
  return {
    station_id: policy.mobileStationId(OWNER, 0),
    owner_address: OWNER,
    owner_pubkey: 'a'.repeat(64),
    owner_signature: 'b'.repeat(128),
    latitude: 37.7,
    longitude: -122.4,
    hardware_model: 'phone-barometer',
    provenance_class: 'real',
    data_quality_tier: 'unverified',
    ...overrides,
  };
}

test('mobile station id matches the core4 and backend vector', () => {
  // core4 station_registrar::tests::mobile_station_id_matches_the_backend_derivation
  assert.equal(policy.mobileStationId(OWNER, 0), 'mob-5d270fa8c768f23260a9f9f8de63ab64');
  assert.equal(policy.mobileStationId(OWNER, 1), 'mob-1aef6cb885098fadc032bac1bf32f47f');
  assert.equal(policy.mobileStationId('0xABC', 0), null);
  assert.equal(policy.mobileStationId(OWNER.toUpperCase().replace('0X', '0x'), 0), null);
});

test('the 0.1 degree grid is checked bit for bit', () => {
  for (const value of [0, -0, 0.1, 37.7, -122.4, 90, -180, 12.3, -45.6]) {
    assert.equal(policy.onTenthDegreeGrid(value), true, String(value));
  }
  for (const value of [37.75, 0.05, -0.05, 45.123, 37.70000001, NaN, Infinity, '37.7', null]) {
    assert.equal(policy.onTenthDegreeGrid(value), false, String(value));
  }
});

test('a cell is integer tenths', () => {
  assert.equal(policy.cellOf(37.7, -122.4), '377:-1224');
  assert.equal(policy.cellOf(0, 0.1), '0:1');
});

test('a phone row inside the registrar limits passes', () => {
  assert.equal(policy.shapeRefusal(row()), null);
});

test('every registrar limit refuses', () => {
  const cases = [
    [{ hardware_model: 'reference-station' }, /phone-barometer/],
    [{ data_quality_tier: 'gold' }, /unverified/],
    [{ provenance_class: 'synthetic' }, /real/],
    [{ owner_address: 'wrf00112233445566778899aabbccddeeff00112233' }, /owner_address/],
    [{ owner_pubkey: 'A'.repeat(64) }, /owner_pubkey/],
    [{ owner_signature: 'b'.repeat(127) }, /owner_signature/],
    [{ station_id: policy.mobileStationId(OWNER, 1) }, /slot-0/],
    [{ station_id: 'PWS-A' }, /slot-0/],
    [{ latitude: 37.75 }, /grid/],
    [{ longitude: -122.41 }, /grid/],
    [{ latitude: 91 }, /range/],
    [{ latitude: '37.7' }, /range/],
  ];
  for (const [overrides, message] of cases) {
    assert.match(policy.shapeRefusal(row(overrides)), message, JSON.stringify(overrides));
  }
  assert.match(policy.shapeRefusal({ ...row(), elevation_meters: 10 }), /exactly/);
  assert.match(policy.shapeRefusal({ ...row(), submitted_at: 1 }), /exactly/);
  const missing = row();
  delete missing.latitude;
  assert.match(policy.shapeRefusal(missing), /exactly/);
  assert.match(policy.shapeRefusal([]), /object/);
  assert.match(policy.shapeRefusal(null), /object/);
});

test('daily limits apply in order over a trailing 24 h', () => {
  const limits = { dailyTotal: 20, dailyPerIp: 3, dailyPerCell: 3 };
  const now = 1_000_000;
  const rec = (i, extra = {}) => ({ stationId: `s${i}`, ipHash: `ip${i}`, cell: `c${i}`, acceptedAt: now - 10, ...extra });
  const ask = (extra = {}) => ({ stationId: 'new', ipHash: 'ipX', cell: 'cX', ...extra });

  assert.equal(policy.limitRefusal(limits, [], ask(), now), null);
  assert.equal(policy.limitRefusal(limits, [rec(1, { stationId: 'new', acceptedAt: 0 })], ask(), now), 'ALREADY_REQUESTED');

  const sameIp = [1, 2, 3].map((i) => rec(i, { ipHash: 'ipX' }));
  assert.equal(policy.limitRefusal(limits, sameIp, ask(), now), 'DAILY_PER_IP');
  const sameCell = [1, 2, 3].map((i) => rec(i, { cell: 'cX' }));
  assert.equal(policy.limitRefusal(limits, sameCell, ask(), now), 'DAILY_PER_CELL');
  const full = Array.from({ length: 20 }, (_, i) => rec(i));
  assert.equal(policy.limitRefusal(limits, full, ask(), now), 'DAILY_TOTAL');

  // A day later they no longer count.
  const old = full.map((r) => ({ ...r, acceptedAt: now - policy.DAY_SECONDS }));
  assert.equal(policy.limitRefusal(limits, old, ask(), now), null);
  // The retry hint is when the oldest blocking record ages out.
  const retry = policy.limitRetryAfter('DAILY_PER_IP', sameIp, ask(), now);
  assert.equal(retry, policy.DAY_SECONDS - 10);
});

test('the ceiling constant is the chain ceiling', () => {
  assert.equal(policy.CHAIN_PHONE_CEILING, 128);
});
