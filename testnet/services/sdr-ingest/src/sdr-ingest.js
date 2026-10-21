#!/usr/bin/env node

/**
 * SDR Ingest Service — RTL-SDR enrichment prototype
 *
 * Ingests RTL-SDR weather packets, normalizes to WRF schema, and submits
 * to the WRF weather ingestion endpoint. Experimental/enrichment-only —
 * not a blockchain peer.
 *
 * Usage:
 *  - With rtl_433 installed: ./sdr-ingest.js
 *  - Fixture mode (development): SDR_FIXTURE_FILE=/path/to/fixture.json ./sdr-ingest.js
 *
 * Environment:
 *  - SDR_FIXTURE_FILE: Path to JSON fixture file of captured rtl_433 output (optional)
 *  - WRF_INGEST_URL: Target WRF ingestion endpoint (default: http://localhost:8080/ingest)
 *  - SDR_POLL_INTERVAL: rtl_433 poll interval in seconds (default: 5)
 *  - SDR_PROTOCOLS: Comma-separated list of allowed protocols (default: acurite,oregon,fine_offset)
 *  - LOG_LEVEL: debug|info|warn|error (default: info)
 *  - PORT: Health check port (default: 9000)
 */

const http = require('http');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 9000;
const WRF_INGEST_URL = process.env.WRF_INGEST_URL || 'http://localhost:8080/ingest';
const SDR_POLL_INTERVAL = parseInt(process.env.SDR_POLL_INTERVAL || '5');
const SDR_FIXTURE_FILE = process.env.SDR_FIXTURE_FILE;
const ALLOWED_PROTOCOLS = (process.env.SDR_PROTOCOLS || 'acurite,oregon,fine_offset').split(',');
const LOG_LEVEL = process.env.LOG_LEVEL || 'info';

// Health tracking
let lastSuccessfulIngest = Date.now();
let ingestCount = 0;
let errorCount = 0;

// Logger
const logger = {
  debug: (msg) => LOG_LEVEL === 'debug' && console.log(`[DEBUG] ${msg}`),
  info: (msg) => console.log(`[INFO] ${msg}`),
  warn: (msg) => console.warn(`[WARN] ${msg}`),
  error: (msg) => console.error(`[ERROR] ${msg}`),
};

/**
 * Normalize RTL-SDR observation to WRF schema
 */
function normalizeToWRF(sdrObs) {
  const wrf = {
    timestamp: sdrObs.time || new Date().toISOString(),
    source: {
      type: 'sdr',
      device_id: sdrObs.id || sdrObs.model || 'unknown',
      protocol: sdrObs.protocol || 'unknown',
      rssi: sdrObs.rssi !== undefined ? sdrObs.rssi : null,
    },
    observations: {},
  };

  // Protocol-specific field mapping
  if (sdrObs.protocol === 'Acurite' || sdrObs.protocol === 'acurite') {
    wrf.observations = {
      temperature_c: sdrObs.temperature_C || null,
      humidity: sdrObs.humidity || null,
      battery: sdrObs.battery_ok !== undefined ? sdrObs.battery_ok : null,
    };
  } else if (sdrObs.protocol === 'Oregon' || sdrObs.protocol === 'oregon' || sdrObs.protocol === 'Oregon Scientific') {
    wrf.observations = {
      temperature_c: sdrObs.temp_c || sdrObs.temperature_C || null,
      humidity: sdrObs.humidity || null,
      pressure_mb: sdrObs.pressure_mb || null,
      battery: sdrObs.battery_ok !== undefined ? sdrObs.battery_ok : null,
    };
  } else if (sdrObs.protocol === 'Fine Offset' || sdrObs.protocol === 'fine_offset') {
    wrf.observations = {
      temperature_c: sdrObs.temp_c || sdrObs.temperature_C || null,
      humidity: sdrObs.humidity || null,
      wind_speed_ms: sdrObs.wind_avg_m_s || null,
      wind_direction_deg: sdrObs.wind_dir_deg || null,
      rain_mm: sdrObs.rain_mm || null,
      battery: sdrObs.battery_ok !== undefined ? sdrObs.battery_ok : null,
    };
  } else {
    // Generic mapping
    wrf.observations = {
      temperature_c: sdrObs.temperature_C || sdrObs.temp_c || null,
      humidity: sdrObs.humidity || null,
    };
  }

  return wrf;
}

/**
 * Filter observation by allowed protocols
 */
function isAllowedProtocol(protocol) {
  if (!protocol) return false;
  const normalized = protocol.toLowerCase().replace(/\s+/g, '_');
  return ALLOWED_PROTOCOLS.some((p) => normalized.includes(p));
}

/**
 * Ingest observation to WRF endpoint
 */
async function ingestToWRF(wrfObs) {
  try {
    const payload = JSON.stringify(wrfObs);
    const [urlBase, query] = WRF_INGEST_URL.split('?');
    const url = new URL(urlBase);

    const options = {
      hostname: url.hostname,
      port: url.port || (url.protocol === 'https:' ? 443 : 80),
      path: url.pathname + (query ? `?${query}` : ''),
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload),
        'User-Agent': 'sdr-ingest-service/1.0',
      },
    };

    return new Promise((resolve, reject) => {
      const req = http.request(options, (res) => {
        let body = '';
        res.on('data', (chunk) => {
          body += chunk;
        });
        res.on('end', () => {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            ingestCount++;
            lastSuccessfulIngest = Date.now();
            logger.debug(`Ingest success (${res.statusCode}): ${body.slice(0, 100)}`);
            resolve({ success: true, status: res.statusCode });
          } else {
            errorCount++;
            logger.warn(`Ingest failed (${res.statusCode}): ${body.slice(0, 200)}`);
            reject(new Error(`HTTP ${res.statusCode}`));
          }
        });
      });

      req.on('error', (err) => {
        errorCount++;
        logger.error(`Ingest request error: ${err.message}`);
        reject(err);
      });

      req.write(payload);
      req.end();
    });
  } catch (err) {
    errorCount++;
    logger.error(`Ingest error: ${err.message}`);
    throw err;
  }
}

/**
 * Read fixture file (development/testing mode)
 */
async function readFixtureMode() {
  try {
    if (!fs.existsSync(SDR_FIXTURE_FILE)) {
      logger.error(`Fixture file not found: ${SDR_FIXTURE_FILE}`);
      return [];
    }

    const content = fs.readFileSync(SDR_FIXTURE_FILE, 'utf8');
    const lines = content.trim().split('\n');
    const observations = [];

    for (const line of lines) {
      try {
        const obs = JSON.parse(line);
        if (isAllowedProtocol(obs.protocol)) {
          observations.push(obs);
        }
      } catch (e) {
        logger.debug(`Failed to parse fixture line: ${e.message}`);
      }
    }

    logger.info(`Loaded ${observations.length} observations from fixture`);
    return observations;
  } catch (err) {
    logger.error(`Fixture read error: ${err.message}`);
    return [];
  }
}

/**
 * Stream and parse rtl_433 output
 */
async function streamRTL433() {
  return new Promise((resolve, reject) => {
    const rtl = spawn('rtl_433', [
      '-F', 'json',
      '-R', '0',  // All devices
      '-a', '*.* ~0x00',  // Minimal filtering, let the normalized list handle it
    ]);

    const observations = [];
    let buffer = '';

    rtl.stdout.on('data', (data) => {
      buffer += data.toString();
      const lines = buffer.split('\n');
      buffer = lines.pop(); // Keep incomplete line in buffer

      for (const line of lines) {
        if (!line.trim()) continue;
        try {
          const obs = JSON.parse(line);
          if (isAllowedProtocol(obs.protocol)) {
            observations.push(obs);
            logger.debug(`Received: ${obs.protocol} / ${obs.model} (#${obs.id || '?'})`);
          }
        } catch (e) {
          logger.debug(`Parse error: ${e.message}`);
        }
      }
    });

    rtl.stderr.on('data', (data) => {
      logger.warn(`rtl_433: ${data.toString().trim()}`);
    });

    rtl.on('error', (err) => {
      logger.error(`rtl_433 spawn error: ${err.message}`);
      reject(err);
    });

    rtl.on('close', (code) => {
      logger.info(`rtl_433 exited with code ${code}, collected ${observations.length} observations`);
      resolve(observations);
    });

    // Timeout after poll interval
    setTimeout(() => {
      rtl.kill('SIGTERM');
    }, SDR_POLL_INTERVAL * 1000);
  });
}

/**
 * Main ingest loop
 */
async function ingestLoop() {
  while (true) {
    try {
      const observations = SDR_FIXTURE_FILE
        ? await readFixtureMode()
        : await streamRTL433();

      for (const obs of observations) {
        try {
          const wrfObs = normalizeToWRF(obs);
          await ingestToWRF(wrfObs);
          logger.info(`Ingested: ${wrfObs.source.protocol} (${wrfObs.source.device_id})`);
        } catch (err) {
          logger.error(`Failed to ingest observation: ${err.message}`);
        }
      }

      if (!SDR_FIXTURE_FILE) {
        // In live mode, wait before next poll
        await new Promise((resolve) => setTimeout(resolve, SDR_POLL_INTERVAL * 1000));
      } else {
        // In fixture mode, exit after one pass
        logger.info('Fixture mode: processed all observations, exiting');
        break;
      }
    } catch (err) {
      logger.error(`Ingest loop error: ${err.message}`);
      // Continue on error
      await new Promise((resolve) => setTimeout(resolve, SDR_POLL_INTERVAL * 1000));
    }
  }
}

/**
 * Health check endpoint
 */
function startHealthCheck() {
  const server = http.createServer((req, res) => {
    if (req.url === '/health') {
      const isHealthy =
        Date.now() - lastSuccessfulIngest < 120000 && // Healthy if ingest in last 2 min
        ingestCount > 0;

      const status = {
        status: isHealthy ? 'healthy' : 'degraded',
        ingests: ingestCount,
        errors: errorCount,
        lastIngest: new Date(lastSuccessfulIngest).toISOString(),
        uptime: Math.floor((Date.now() - startTime) / 1000),
      };

      res.writeHead(isHealthy ? 200 : 503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(status));
    } else {
      res.writeHead(404);
      res.end('Not Found');
    }
  });

  server.listen(PORT, () => {
    logger.info(`Health check listening on port ${PORT}`);
  });

  return server;
}

// Main
const startTime = Date.now();

logger.info('SDR Ingest Service starting...');
logger.info(`Mode: ${SDR_FIXTURE_FILE ? 'fixture' : 'live rtl_433'}`);
logger.info(`WRF endpoint: ${WRF_INGEST_URL}`);
logger.info(`Poll interval: ${SDR_POLL_INTERVAL}s`);
logger.info(`Allowed protocols: ${ALLOWED_PROTOCOLS.join(', ')}`);

startHealthCheck();
ingestLoop().catch((err) => {
  logger.error(`Fatal error: ${err.message}`);
  process.exit(1);
});
