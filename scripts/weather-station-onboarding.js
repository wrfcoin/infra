#!/usr/bin/env node

/**
 * Weather station onboarding helpers for launch/testnet operations.
 *
 * Security-sensitive behavior:
 * - Deterministic commit hash generation for commit/reveal flow
 * - Strict replay key derivation using station_id + timestamp + nonce + commit_hash
 * - Reward/seniority gating on oracle quorum approval
 */

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export const SUPPORTED_STATION_TYPES = Object.freeze([
  'acurite',
  'davis_vantage',
  'ambient_weather',
  'ecowitt',
]);

function sha3Hex(value) {
  return crypto.createHash('sha3-256').update(value).digest('hex');
}

function toFiniteNumber(value, fieldName) {
  const num = Number(value);
  if (!Number.isFinite(num)) {
    throw new Error(`${fieldName} must be a finite number`);
  }
  return num;
}

function toCelsiusFromF(fahrenheit) {
  return ((fahrenheit - 32) * 5) / 9;
}

function canonicalizeJson(value) {
  if (Array.isArray(value)) {
    return value.map(canonicalizeJson);
  }
  if (value && typeof value === 'object') {
    return Object.keys(value)
      .sort()
      .reduce((acc, key) => {
        acc[key] = canonicalizeJson(value[key]);
        return acc;
      }, {});
  }
  return value;
}

function normalizeAcurite(raw) {
  return {
    temperature_c: toCelsiusFromF(toFiniteNumber(raw.tempF, 'tempF')),
    humidity_pct: toFiniteNumber(raw.humidity, 'humidity'),
    pressure_hpa: toFiniteNumber(raw.pressureInHg, 'pressureInHg') * 33.8638866667,
    wind_mps: toFiniteNumber(raw.windMph || 0, 'windMph') * 0.44704,
    rainfall_mm: toFiniteNumber(raw.rainInches || 0, 'rainInches') * 25.4,
  };
}

function normalizeDavis(raw) {
  return {
    temperature_c: toFiniteNumber(raw.temp_out_c, 'temp_out_c'),
    humidity_pct: toFiniteNumber(raw.humidity_out_pct, 'humidity_out_pct'),
    pressure_hpa: toFiniteNumber(raw.barometer_hpa, 'barometer_hpa'),
    wind_mps: toFiniteNumber(raw.wind_avg_mps || 0, 'wind_avg_mps'),
    rainfall_mm: toFiniteNumber(raw.rain_rate_mm || 0, 'rain_rate_mm'),
  };
}

function normalizeAmbient(raw) {
  return {
    temperature_c: toCelsiusFromF(toFiniteNumber(raw.tempf, 'tempf')),
    humidity_pct: toFiniteNumber(raw.humidity, 'humidity'),
    pressure_hpa: toFiniteNumber(raw.baromabsin, 'baromabsin') * 33.8638866667,
    wind_mps: toFiniteNumber(raw.windspeedmph || 0, 'windspeedmph') * 0.44704,
    rainfall_mm: toFiniteNumber(raw.hourlyrainin || 0, 'hourlyrainin') * 25.4,
  };
}

function normalizeEcowitt(raw) {
  return {
    temperature_c: toCelsiusFromF(toFiniteNumber(raw.tempf, 'tempf')),
    humidity_pct: toFiniteNumber(raw.humidity, 'humidity'),
    pressure_hpa: toFiniteNumber(raw.baromabsin, 'baromabsin') * 33.8638866667,
    wind_mps: toFiniteNumber(raw.windgustmph || 0, 'windgustmph') * 0.44704,
    rainfall_mm: toFiniteNumber(raw.totalrainin || 0, 'totalrainin') * 25.4,
  };
}

const ADAPTERS = Object.freeze({
  acurite: normalizeAcurite,
  davis_vantage: normalizeDavis,
  ambient_weather: normalizeAmbient,
  ecowitt: normalizeEcowitt,
});

export function normalizeStationReading(stationType, rawReading) {
  const adapter = ADAPTERS[stationType];
  if (!adapter) {
    throw new Error(
      `Unsupported station type "${stationType}". Supported types: ${SUPPORTED_STATION_TYPES.join(', ')}`
    );
  }

  const normalized = adapter(rawReading);

  if (normalized.temperature_c < -80 || normalized.temperature_c > 80) {
    throw new Error('temperature_c out of realistic range');
  }
  if (normalized.humidity_pct < 0 || normalized.humidity_pct > 100) {
    throw new Error('humidity_pct out of range 0..100');
  }
  if (normalized.pressure_hpa < 850 || normalized.pressure_hpa > 1100) {
    throw new Error('pressure_hpa out of realistic range');
  }

  return normalized;
}

export function makeCommitHash({
  payload,
  nonce,
  stationId,
  timestamp,
  contributionType = 'contribution',
}) {
  const canonicalPayload = canonicalizeJson(payload);
  const preimage = `${JSON.stringify(canonicalPayload)}||${nonce}||${stationId}||${timestamp}||${contributionType}`;
  return sha3Hex(preimage);
}

export function makeReplayKey({ stationId, timestamp, nonce, commitHash }) {
  const preimage = `${stationId}||${timestamp}||${nonce}||${commitHash}`;
  return sha3Hex(preimage);
}

export function buildCommitRevealPayload({
  stationType,
  stationId,
  contributor,
  rawReading,
  timestamp = Math.floor(Date.now() / 1000),
  nonce = crypto.randomUUID(),
  contributionType = 'contribution',
}) {
  if (!stationId || !contributor) {
    throw new Error('stationId and contributor are required');
  }

  const payload = normalizeStationReading(stationType, rawReading);
  const commitHash = makeCommitHash({
    payload,
    nonce,
    stationId,
    timestamp,
    contributionType,
  });
  const replayKey = makeReplayKey({
    stationId,
    timestamp,
    nonce,
    commitHash,
  });

  return {
    payload,
    nonce,
    timestamp,
    commitHash,
    replayKey,
    commitRequest: {
      contributor,
      station_id: stationId,
      commit_hash: commitHash,
    },
    revealRequest: {
      contributor,
      station_id: stationId,
      payload,
      nonce,
      commit_hash: commitHash,
      timestamp,
    },
  };
}

export class ReplayGuard {
  constructor({
    filePath = path.join(__dirname, '..', 'configs', 'testnet', 'replay-keys.json'),
    maxEntries = 100000,
  } = {}) {
    this.filePath = filePath;
    this.maxEntries = maxEntries;
    this.replayKeys = new Map();
    this._load();
  }

  _load() {
    if (!fs.existsSync(this.filePath)) {
      return;
    }

    const raw = fs.readFileSync(this.filePath, 'utf8');
    if (!raw.trim()) {
      return;
    }

    const parsed = JSON.parse(raw);
    for (const entry of parsed.entries || []) {
      this.replayKeys.set(entry.replayKey, entry);
    }
  }

  _persist() {
    const dir = path.dirname(this.filePath);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }

    const entries = Array.from(this.replayKeys.values());
    const body = JSON.stringify({ entries }, null, 2);
    fs.writeFileSync(this.filePath, body);
  }

  assertNotSeen(replayKey) {
    if (this.replayKeys.has(replayKey)) {
      throw new Error('Replay key already exists; duplicate contribution detected');
    }
  }

  remember({ replayKey, stationId, commitHash, timestamp }) {
    this.assertNotSeen(replayKey);
    this.replayKeys.set(replayKey, {
      replayKey,
      stationId,
      commitHash,
      timestamp,
      recordedAt: new Date().toISOString(),
    });

    if (this.replayKeys.size > this.maxEntries) {
      const oldestKey = this.replayKeys.keys().next().value;
      this.replayKeys.delete(oldestKey);
    }
    this._persist();
  }
}

export function isQuorumApprovedReveal(statusResponse) {
  return (
    statusResponse &&
    statusResponse.status === 'revealed_attested' &&
    statusResponse.has_quorum === true
  );
}

function clamp01(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    return 0;
  }
  return Math.max(0, Math.min(1, numeric));
}

export class SeniorityLedger {
  constructor() {
    this.records = new Map();
  }

  recordContribution({
    stationId,
    qualityScore,
    uptimeScore,
    consistencyScore,
    hasOracleQuorum,
    commitHash,
    timestamp,
  }) {
    if (!hasOracleQuorum) {
      return { accepted: false, reason: 'oracle_quorum_not_met' };
    }

    const quality = clamp01(qualityScore);
    const uptime = clamp01(uptimeScore);
    const consistency = clamp01(consistencyScore);
    const delta = quality * 0.6 + uptime * 0.25 + consistency * 0.15;

    const current = this.records.get(stationId) || {
      stationId,
      nonTransferableScore: 0,
      acceptedContributions: 0,
      averageQuality: 0,
      averageUptime: 0,
      averageConsistency: 0,
      lastCommitHash: null,
      lastTimestamp: null,
    };

    const nextCount = current.acceptedContributions + 1;
    const weighted = (oldValue, newValue) =>
      (oldValue * current.acceptedContributions + newValue) / nextCount;

    current.nonTransferableScore = Number(
      (current.nonTransferableScore + delta).toFixed(6)
    );
    current.acceptedContributions = nextCount;
    current.averageQuality = Number(weighted(current.averageQuality, quality).toFixed(6));
    current.averageUptime = Number(weighted(current.averageUptime, uptime).toFixed(6));
    current.averageConsistency = Number(
      weighted(current.averageConsistency, consistency).toFixed(6)
    );
    current.lastCommitHash = commitHash || current.lastCommitHash;
    current.lastTimestamp = timestamp || current.lastTimestamp;

    this.records.set(stationId, current);
    return { accepted: true, delta, score: current.nonTransferableScore };
  }

  snapshot(epochId) {
    const stations = Array.from(this.records.values()).sort(
      (a, b) => b.nonTransferableScore - a.nonTransferableScore
    );

    return {
      epochId,
      generatedAt: new Date().toISOString(),
      stations: stations.map((station, index) => ({
        rank: index + 1,
        ...station,
      })),
    };
  }
}

function haversineMeters(a, b) {
  const toRad = deg => (deg * Math.PI) / 180;
  const earthMeters = 6371000;
  const dLat = toRad(b.lat - a.lat);
  const dLon = toRad(b.lon - a.lon);
  const lat1 = toRad(a.lat);
  const lat2 = toRad(b.lat);
  const x =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.sin(dLon / 2) * Math.sin(dLon / 2) * Math.cos(lat1) * Math.cos(lat2);
  const y = 2 * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
  return earthMeters * y;
}

export function assessStationVerificationEvidence({
  stationId,
  claimedLocation,
  geotaggedPhoto,
  mapPin,
  satelliteCrossCheck,
}) {
  if (!stationId) {
    throw new Error('stationId is required');
  }
  if (!claimedLocation || !Number.isFinite(claimedLocation.lat) || !Number.isFinite(claimedLocation.lon)) {
    throw new Error('claimedLocation {lat, lon} is required');
  }

  const findings = [];
  let confidence = 0;

  if (geotaggedPhoto) {
    if (!geotaggedPhoto.fileHash) {
      throw new Error('geotaggedPhoto.fileHash is required');
    }
    const distance = haversineMeters(claimedLocation, geotaggedPhoto);
    findings.push({
      check: 'geotagged_photo_distance_meters',
      value: Number(distance.toFixed(2)),
      pass: distance <= 100,
    });
    if (distance <= 100) {
      confidence += 0.45;
    }
  }

  if (mapPin) {
    const supported = ['google_maps', 'openstreetmap'];
    if (!supported.includes(mapPin.provider)) {
      throw new Error(`mapPin.provider must be one of: ${supported.join(', ')}`);
    }
    if (!mapPin.url) {
      throw new Error('mapPin.url is required');
    }
    findings.push({
      check: 'map_pin_present',
      provider: mapPin.provider,
      pass: true,
    });
    confidence += 0.25;
  }

  if (satelliteCrossCheck) {
    if (!satelliteCrossCheck.provider || !satelliteCrossCheck.referenceHash) {
      throw new Error(
        'satelliteCrossCheck.provider and satelliteCrossCheck.referenceHash are required'
      );
    }
    const distance = Number(satelliteCrossCheck.distanceMeters || Number.POSITIVE_INFINITY);
    findings.push({
      check: 'satellite_crosscheck_distance_meters',
      value: Number(distance.toFixed(2)),
      pass: distance <= 150,
    });
    if (distance <= 150) {
      confidence += 0.3;
    }
  }

  const autoApproved = confidence >= 0.75;
  return {
    stationId,
    confidence: Number(confidence.toFixed(4)),
    autoApproved,
    recommendedAction: autoApproved ? 'approve' : 'manual_review',
    findings,
    reviewHints: autoApproved
      ? []
      : [
          'Collect at least one geotagged installation photo',
          'Include map pin evidence (Google Maps or OpenStreetMap)',
          'Add satellite cross-check distance proof where possible',
        ],
  };
}

function demo() {
  const flow = buildCommitRevealPayload({
    stationType: 'acurite',
    stationId: 'station-demo-001',
    contributor: '0x0000000000000000000000000000000000000001',
    rawReading: {
      tempF: 74.3,
      humidity: 58,
      pressureInHg: 29.92,
      windMph: 5.1,
      rainInches: 0.02,
    },
  });

  const replayGuard = new ReplayGuard();
  replayGuard.remember({
    replayKey: flow.replayKey,
    stationId: flow.commitRequest.station_id,
    commitHash: flow.commitHash,
    timestamp: flow.timestamp,
  });

  console.log(JSON.stringify(flow, null, 2));
  console.log(
    JSON.stringify(
      assessStationVerificationEvidence({
        stationId: flow.commitRequest.station_id,
        claimedLocation: { lat: 37.776, lon: -122.417 },
        geotaggedPhoto: {
          lat: 37.77599,
          lon: -122.41702,
          fileHash: sha3Hex('demo-photo'),
        },
        mapPin: {
          provider: 'google_maps',
          url: 'https://maps.google.com/?q=37.776,-122.417',
        },
        satelliteCrossCheck: {
          provider: 'sentinel2',
          distanceMeters: 82,
          referenceHash: sha3Hex('demo-satellite'),
        },
      }),
      null,
      2
    )
  );
}

if (process.argv[1] === __filename && process.argv.includes('--demo')) {
  demo();
}
