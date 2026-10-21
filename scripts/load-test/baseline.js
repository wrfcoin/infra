/**
 * WRFCoin Testnet API — k6 baseline load test
 *
 * Tests all major service health endpoints plus key API routes.
 * Designed for smoke, soak, and stress test phases.
 *
 * Issue: #122
 *
 * Usage:
 *   # Quick smoke (1 VU, 30s)
 *   k6 run --env BASE_URL=http://localhost:4001 scripts/load-test/baseline.js
 *
 *   # Light soak (10 VUs, 5 min)
 *   k6 run --env BASE_URL=http://localhost:4001 \
 *          --env PHASE=soak \
 *          --vus 10 --duration 5m \
 *          scripts/load-test/baseline.js
 *
 *   # Stress ramp-up
 *   k6 run --env BASE_URL=http://localhost:4001 \
 *          --env PHASE=stress \
 *          scripts/load-test/baseline.js
 *
 * Environment variables:
 *   BASE_URL           - API gateway base (default: http://localhost:4001)
 *   CROSSCHAIN_URL     - Cross-chain service (default: http://localhost:3000)
 *   WALLET_URL         - Wallet service     (default: http://localhost:4000)
 *   COMPUTE_URL        - Compute service    (default: http://localhost:6000)
 *   WEATHER_URL        - Weather service    (default: http://localhost:8080)
 *   GOVERNANCE_URL     - Governance service (default: http://localhost:8000)
 *   PHASE              - smoke|soak|stress  (default: smoke)
 *   WEATHER_STATION_ID - Station ID for weather POST (default: TEST-STATION-001)
 */

import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// ---------------------------------------------------------------------------
// Service base URLs
// ---------------------------------------------------------------------------
const BASE_URL        = __ENV.BASE_URL        || 'http://localhost:4001';
const CROSSCHAIN_URL  = __ENV.CROSSCHAIN_URL  || 'http://localhost:3000';
const WALLET_URL      = __ENV.WALLET_URL      || 'http://localhost:4000';
const COMPUTE_URL     = __ENV.COMPUTE_URL     || 'http://localhost:6000';
const WEATHER_URL     = __ENV.WEATHER_URL     || 'http://localhost:8080';
const GOVERNANCE_URL  = __ENV.GOVERNANCE_URL  || 'http://localhost:8000';

const STATION_ID = __ENV.WEATHER_STATION_ID || 'TEST-STATION-001';

// ---------------------------------------------------------------------------
// Custom metrics
// ---------------------------------------------------------------------------
const errorRate       = new Rate('errors');
const healthLatency   = new Trend('health_check_latency', true);
const blockLatency    = new Trend('blocks_latest_latency', true);
const weatherLatency  = new Trend('weather_post_latency', true);

// ---------------------------------------------------------------------------
// Load scenario configs by phase
// ---------------------------------------------------------------------------
const PHASES = {
  smoke: {
    vus: 1,
    duration: '30s',
  },
  soak: {
    stages: [
      { duration: '1m',  target: 10 },
      { duration: '3m',  target: 10 },
      { duration: '1m',  target: 0  },
    ],
  },
  stress: {
    stages: [
      { duration: '30s', target: 10  },
      { duration: '1m',  target: 50  },
      { duration: '2m',  target: 100 },
      { duration: '1m',  target: 50  },
      { duration: '30s', target: 0   },
    ],
  },
};

const phase = __ENV.PHASE || 'smoke';
const scenarioCfg = PHASES[phase] || PHASES.smoke;

export const options = {
  ...(scenarioCfg.stages
    ? { stages: scenarioCfg.stages }
    : { vus: scenarioCfg.vus, duration: scenarioCfg.duration }),

  thresholds: {
    // 95th-percentile response time under 500ms for health checks
    'health_check_latency': ['p(95)<500'],
    // Blocks endpoint: 95p under 1s
    'blocks_latest_latency': ['p(95)<1000'],
    // Weather POST: 95p under 2s
    'weather_post_latency': ['p(95)<2000'],
    // Overall error rate under 1%
    'errors': ['rate<0.01'],
    // HTTP failure rate under 5%
    'http_req_failed': ['rate<0.05'],
  },
};

// ---------------------------------------------------------------------------
// Health checks — one per service
// ---------------------------------------------------------------------------
function checkHealth() {
  const services = [
    { name: 'api',        url: `${BASE_URL}/health` },
    { name: 'crosschain', url: `${CROSSCHAIN_URL}/health` },
    { name: 'wallet',     url: `${WALLET_URL}/health` },
    { name: 'compute',    url: `${COMPUTE_URL}/health` },
    { name: 'weather',    url: `${WEATHER_URL}/health` },
    { name: 'governance', url: `${GOVERNANCE_URL}/health` },
  ];

  for (const svc of services) {
    const t0 = Date.now();
    const res = http.get(svc.url, {
      tags: { service: svc.name, endpoint: 'health' },
      timeout: '10s',
    });
    healthLatency.add(Date.now() - t0);

    const ok = check(res, {
      [`${svc.name} /health status 2xx`]: (r) => r.status >= 200 && r.status < 300,
    });
    errorRate.add(!ok);
  }
}

// ---------------------------------------------------------------------------
// Blocks endpoint
// ---------------------------------------------------------------------------
function checkBlocksLatest() {
  const t0 = Date.now();
  const res = http.get(`${BASE_URL}/api/v1/blocks/latest`, {
    tags: { service: 'api', endpoint: 'blocks_latest' },
    timeout: '15s',
  });
  blockLatency.add(Date.now() - t0);

  const ok = check(res, {
    'GET /api/v1/blocks/latest → 200': (r) => r.status === 200,
    'blocks/latest has block_hash field': (r) => {
      try {
        const body = JSON.parse(r.body);
        return body.block_hash !== undefined || body.hash !== undefined || body.data !== undefined;
      } catch (_) {
        return false;
      }
    },
  });
  errorRate.add(!ok);
}

// ---------------------------------------------------------------------------
// Weather observation POST
// ---------------------------------------------------------------------------
function postWeatherObservation() {
  const payload = JSON.stringify({
    station_id: STATION_ID,
    timestamp: new Date().toISOString(),
    temperature_c: 20.5 + Math.random() * 5,
    humidity_pct: 50 + Math.random() * 20,
    pressure_hpa: 1013.0 + Math.random() * 10,
    wind_speed_ms: Math.random() * 10,
    wind_direction_deg: Math.floor(Math.random() * 360),
    precipitation_mm: Math.random() < 0.2 ? Math.random() * 5 : 0,
  });

  const params = {
    headers: { 'Content-Type': 'application/json' },
    tags: { service: 'weather', endpoint: 'observation_post' },
    timeout: '20s',
  };

  const t0 = Date.now();
  const res = http.post(`${WEATHER_URL}/api/v1/weather/observation`, payload, params);
  weatherLatency.add(Date.now() - t0);

  const ok = check(res, {
    'POST /api/v1/weather/observation → 200 or 201': (r) =>
      r.status === 200 || r.status === 201,
  });
  errorRate.add(!ok);
}

// ---------------------------------------------------------------------------
// Default function — executed once per VU iteration
// ---------------------------------------------------------------------------
export default function () {
  group('Health checks', checkHealth);
  sleep(0.5);

  group('Blocks latest', checkBlocksLatest);
  sleep(0.5);

  group('Weather observation POST', postWeatherObservation);
  sleep(1);
}

// ---------------------------------------------------------------------------
// Setup / teardown hooks (optional — useful for seeding/cleanup)
// ---------------------------------------------------------------------------
export function setup() {
  // Verify API gateway is reachable before starting the run
  const res = http.get(`${BASE_URL}/health`, { timeout: '10s' });
  if (res.status < 200 || res.status >= 300) {
    throw new Error(
      `API gateway at ${BASE_URL} is not healthy (status ${res.status}). ` +
      'Start the testnet before running k6.'
    );
  }
  console.log(`[setup] API gateway healthy — running phase: ${phase}`);
  return { phase, baseUrl: BASE_URL };
}

export function teardown(data) {
  console.log(`[teardown] Load test complete — phase: ${data.phase}`);
}
