'use strict';

// The registrar's off-chain rules (STATION_REGISTRAR.md). Pure functions, no I/O.
//
// Two layers, on purpose:
//   - shapeRefusal(): the same stateless limits core4 enforces on a
//     registrar-signed registration (`consensus::station_registrar::
//     registrar_shape_refusal`). A request outside them would be mined as an
//     inert no-op, so the service refuses it up front with a clear code.
//   - the daily limits (total, per IP, per 0.1 degree cell) and the hold. These
//     are NOT consensus: they decide whether the online key signs at all, and
//     they mirror `consensus::station_registrar::policy` in core4.

const crypto = require('node:crypto');

const PHONE_HARDWARE_MODEL = 'phone-barometer';
const MOBILE_STATION_ID_DOMAIN = Buffer.from('wrfcoin_mobile_station_v1', 'utf8');
const MOBILE_STATION_SLOT = 0;
// core4 `PHONE_STATION_CEILING`. The chain refuses past it whatever we do.
const CHAIN_PHONE_CEILING = 128;
const DAY_SECONDS = 24 * 60 * 60;

// Exactly the fields a phone row carries (the activation tool's ROW_KEYS minus
// `submitted_at`, which the service stamps when it signs).
const ROW_KEYS = [
  'station_id', 'owner_address', 'owner_pubkey', 'owner_signature',
  'latitude', 'longitude', 'hardware_model', 'provenance_class', 'data_quality_tier',
];

const ADDRESS = /^0x[0-9a-f]{40}$/;
const HEX64 = /^[0-9a-f]{64}$/;
const HEX128 = /^[0-9a-f]{128}$/;

// `mob-` + first 32 hex of SHA-256(domain || 0x00 || address20 || slot).
// Same as core4 `mobile_station_id` and the backend's `deriveMobileStationId`.
function mobileStationId(ownerAddress, slot = MOBILE_STATION_SLOT) {
  if (typeof ownerAddress !== 'string' || !ADDRESS.test(ownerAddress)) return null;
  const hash = crypto.createHash('sha256');
  hash.update(MOBILE_STATION_ID_DOMAIN);
  hash.update(Buffer.from([0]));
  hash.update(Buffer.from(ownerAddress.slice(2), 'hex'));
  hash.update(Buffer.from([slot]));
  return `mob-${hash.digest('hex').slice(0, 32)}`;
}

// core4 `on_tenth_degree_grid`: does round(value * 10) / 10 reproduce the value
// bit for bit? Math.round and Rust's f64::round differ only at an exact .5,
// and a value whose tenths end in .5 is off the grid under both.
function onTenthDegreeGrid(value) {
  if (typeof value !== 'number' || !Number.isFinite(value)) return false;
  return Object.is(Math.round(value * 10) / 10, value);
}

// Integer tenths of a degree: the cell a request counts against. No finer
// location is kept.
function cellOf(latitude, longitude) {
  return `${Math.round(latitude * 10)}:${Math.round(longitude * 10)}`;
}

// Why a request row is outside the registrar's stateless limits, or null.
function shapeRefusal(row) {
  if (!row || typeof row !== 'object' || Array.isArray(row)) return 'row must be a JSON object';
  const keys = Object.keys(row).sort();
  if (keys.length !== ROW_KEYS.length || ROW_KEYS.some((key) => !keys.includes(key))) {
    return `row must carry exactly: ${ROW_KEYS.join(', ')}`;
  }
  if (row.hardware_model !== PHONE_HARDWARE_MODEL) return 'hardware_model must be phone-barometer';
  if (row.data_quality_tier !== 'unverified') return 'data_quality_tier must be unverified';
  if (row.provenance_class !== 'real') return 'provenance_class must be real';
  if (typeof row.owner_address !== 'string' || !ADDRESS.test(row.owner_address)) {
    return 'owner_address must be 0x + 40 lowercase hex';
  }
  if (typeof row.owner_pubkey !== 'string' || !HEX64.test(row.owner_pubkey)) {
    return 'owner_pubkey must be 64 lowercase hex';
  }
  if (typeof row.owner_signature !== 'string' || !HEX128.test(row.owner_signature)) {
    return 'owner_signature must be 128 lowercase hex';
  }
  if (row.station_id !== mobileStationId(row.owner_address, MOBILE_STATION_SLOT)) {
    return "station_id must be the owner's slot-0 mob- id";
  }
  if (typeof row.latitude !== 'number' || row.latitude < -90 || row.latitude > 90
    || typeof row.longitude !== 'number' || row.longitude < -180 || row.longitude > 180) {
    return 'latitude and longitude must be numbers in range';
  }
  if (!onTenthDegreeGrid(row.latitude) || !onTenthDegreeGrid(row.longitude)) {
    return 'coordinates must be on the 0.1 degree grid';
  }
  return null;
}

// The daily limits over the accepted records (trailing 24 h), in core4's
// order. `records` is every record the store holds; `request` is
// { stationId, ipHash, cell }. Returns null or a refusal code.
function limitRefusal(limits, records, request, nowSeconds) {
  if (records.some((r) => r.stationId === request.stationId)) return 'ALREADY_REQUESTED';
  const recent = records.filter((r) => r.acceptedAt + DAY_SECONDS > nowSeconds);
  if (recent.length >= limits.dailyTotal) return 'DAILY_TOTAL';
  if (recent.filter((r) => r.ipHash === request.ipHash).length >= limits.dailyPerIp) return 'DAILY_PER_IP';
  if (recent.filter((r) => r.cell === request.cell).length >= limits.dailyPerCell) return 'DAILY_PER_CELL';
  return null;
}

// Seconds until the oldest record in the window that is blocking `code` ages out.
function limitRetryAfter(code, records, request, nowSeconds) {
  const match = {
    DAILY_TOTAL: () => true,
    DAILY_PER_IP: (r) => r.ipHash === request.ipHash,
    DAILY_PER_CELL: (r) => r.cell === request.cell,
  }[code];
  if (!match) return undefined;
  const times = records.filter((r) => r.acceptedAt + DAY_SECONDS > nowSeconds && match(r)).map((r) => r.acceptedAt);
  if (times.length === 0) return undefined;
  return Math.max(1, Math.min(...times) + DAY_SECONDS - nowSeconds);
}

module.exports = {
  CHAIN_PHONE_CEILING, DAY_SECONDS, MOBILE_STATION_SLOT, PHONE_HARDWARE_MODEL, ROW_KEYS,
  cellOf, limitRefusal, limitRetryAfter, mobileStationId, onTenthDegreeGrid, shapeRefusal,
};
