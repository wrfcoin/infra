#!/usr/bin/env node
/**
 * Manual Stress Test: IoT Sensor Network Concurrent Submissions
 * Task 114.6 - IoT sensor network stress testing (runs outside Jest to avoid OOM)
 *
 * Tests:
 * 1. 100+ concurrent weather station registrations
 * 2. Concurrent data submissions from all stations
 * 3. Memory usage monitoring during load
 * 4. Throughput measurement
 *
 * Run: node scripts/manual-validation/stress-test-iot.js
 */

const PASS = '\x1b[32mPASS\x1b[0m';
const FAIL = '\x1b[31mFAIL\x1b[0m';
const INFO = '\x1b[36mINFO\x1b[0m';
const WARN = '\x1b[33mWARN\x1b[0m';

// Configuration
const STATION_COUNT = 100;
const BATCH_SIZE = 10;
const READINGS_PER_STATION = 3;

// Mock sensor platforms
const SensorPlatform = {
  ACURITE: 'acurite',
  AMBIENT_WEATHER: 'ambient_weather',
  DAVIS_INSTRUMENTS: 'davis_instruments',
  NETATMO: 'netatmo',
  ECOWITT: 'ecowitt',
  HELIUM: 'helium',
  IOTEX: 'iotex',
  STREAMR: 'streamr',
  SENSOR_COMMUNITY: 'sensor_community',
  PURPLE_AIR: 'purple_air',
};

const platforms = Object.values(SensorPlatform);

// Simple in-memory sensor service simulation
class MockSensorService {
  constructor() {
    this.stations = new Map();
    this.readings = new Map();
  }

  async registerStation(name, platform, location, ownerId) {
    const id = `station_${this.stations.size + 1}_${Date.now()}`;
    const station = {
      id,
      name,
      platform,
      location,
      ownerId,
      dataCount: 0,
      qualityScore: 1.0,
      registeredAt: new Date(),
    };
    this.stations.set(id, station);
    this.readings.set(id, []);
    return station;
  }

  async submitReading(reading) {
    const station = this.stations.get(reading.stationId);
    if (!station) {
      return { isValid: false, error: 'Station not found' };
    }

    // Physics-based validation
    const isValid = this.validateReading(reading);

    if (isValid) {
      const stationReadings = this.readings.get(reading.stationId) || [];
      stationReadings.push({ ...reading, validatedAt: new Date() });
      this.readings.set(reading.stationId, stationReadings);
      station.dataCount++;
    }

    return { isValid, stationId: reading.stationId };
  }

  validateReading(reading) {
    // Temperature: -89.2°C to 70.7°C (WMO standards)
    if (reading.temperature < -89.2 || reading.temperature > 70.7) return false;
    // Humidity: 0-100%
    if (reading.humidity < 0 || reading.humidity > 100) return false;
    // Pressure: 870-1084 hPa
    if (reading.pressure && (reading.pressure < 870 || reading.pressure > 1084)) return false;
    return true;
  }

  getStation(id) {
    return this.stations.get(id);
  }

  getStats() {
    return {
      totalStations: this.stations.size,
      totalReadings: Array.from(this.readings.values()).reduce((sum, r) => sum + r.length, 0),
    };
  }
}

// Memory monitoring
function getMemoryUsageMB() {
  const used = process.memoryUsage();
  return {
    heapUsed: Math.round(used.heapUsed / 1024 / 1024),
    heapTotal: Math.round(used.heapTotal / 1024 / 1024),
    rss: Math.round(used.rss / 1024 / 1024),
  };
}

// Main stress test
async function runStressTest() {
  console.log('\n' + '='.repeat(70));
  console.log('  IoT SENSOR NETWORK STRESS TEST');
  console.log('  Concurrent Station Registration & Data Submission');
  console.log('='.repeat(70) + '\n');

  const sensorService = new MockSensorService();
  const startTime = Date.now();
  const initialMemory = getMemoryUsageMB();
  let passed = 0;
  let failed = 0;

  console.log(`${INFO} Initial memory: ${initialMemory.heapUsed}MB heap, ${initialMemory.rss}MB RSS`);
  console.log(`${INFO} Target: ${STATION_COUNT} stations, ${READINGS_PER_STATION} readings each\n`);

  // Test 1: Station Registration (batched)
  console.log('─'.repeat(50));
  console.log('TEST 1: Concurrent Station Registration');
  console.log('─'.repeat(50));

  const stations = [];
  const registrationStart = Date.now();

  try {
    for (let batch = 0; batch < STATION_COUNT; batch += BATCH_SIZE) {
      const batchPromises = [];
      const batchEnd = Math.min(batch + BATCH_SIZE, STATION_COUNT);

      for (let i = batch; i < batchEnd; i++) {
        batchPromises.push(
          sensorService.registerStation(
            `Stress Test Station ${i}`,
            platforms[i % platforms.length],
            { lat: 30 + (i * 0.1), lng: -100 + (i * 0.1), elevation: 10 + i },
            `user_${i}`
          )
        );
      }

      const batchResults = await Promise.all(batchPromises);
      stations.push(...batchResults);

      // Progress indicator
      if ((batch + BATCH_SIZE) % 50 === 0 || batch + BATCH_SIZE >= STATION_COUNT) {
        const mem = getMemoryUsageMB();
        console.log(`  Registered ${Math.min(batch + BATCH_SIZE, STATION_COUNT)}/${STATION_COUNT} stations (${mem.heapUsed}MB heap)`);
      }
    }

    const registrationTime = Date.now() - registrationStart;
    console.log(`  ${PASS} Registered ${stations.length} stations in ${registrationTime}ms`);
    console.log(`  Throughput: ${Math.round(stations.length / (registrationTime / 1000))} registrations/sec`);
    passed++;
  } catch (error) {
    console.log(`  ${FAIL} Registration failed: ${error.message}`);
    failed++;
  }

  // Test 2: Concurrent Data Submissions
  console.log('\n' + '─'.repeat(50));
  console.log('TEST 2: Concurrent Data Submissions');
  console.log('─'.repeat(50));

  const submissionStart = Date.now();
  const allResults = [];

  try {
    for (let round = 0; round < READINGS_PER_STATION; round++) {
      console.log(`  Round ${round + 1}/${READINGS_PER_STATION}:`);

      for (let batch = 0; batch < stations.length; batch += BATCH_SIZE) {
        const batchStations = stations.slice(batch, batch + BATCH_SIZE);
        const batchResults = await Promise.all(
          batchStations.map(station =>
            sensorService.submitReading({
              stationId: station.id,
              platform: station.platform,
              timestamp: new Date(),
              temperature: 15 + Math.random() * 20,
              humidity: 40 + Math.random() * 40,
              pressure: 1000 + Math.random() * 30,
            })
          )
        );
        allResults.push(...batchResults);
      }

      const mem = getMemoryUsageMB();
      console.log(`    Submitted ${stations.length} readings (${mem.heapUsed}MB heap)`);
    }

    const submissionTime = Date.now() - submissionStart;
    const validCount = allResults.filter(r => r.isValid).length;
    const expectedCount = STATION_COUNT * READINGS_PER_STATION;

    console.log(`  ${PASS} Submitted ${allResults.length} readings in ${submissionTime}ms`);
    console.log(`  Valid readings: ${validCount}/${expectedCount} (${Math.round(validCount / expectedCount * 100)}%)`);
    console.log(`  Throughput: ${Math.round(allResults.length / (submissionTime / 1000))} submissions/sec`);

    if (validCount === expectedCount) {
      passed++;
    } else {
      console.log(`  ${WARN} Some readings failed validation`);
      failed++;
    }
  } catch (error) {
    console.log(`  ${FAIL} Submission failed: ${error.message}`);
    failed++;
  }

  // Test 3: Data Integrity Verification
  console.log('\n' + '─'.repeat(50));
  console.log('TEST 3: Data Integrity Verification');
  console.log('─'.repeat(50));

  try {
    const sampleIndices = [0, 24, 49, 74, 99].filter(i => i < stations.length);
    let integrityPassed = true;

    for (const idx of sampleIndices) {
      const station = sensorService.getStation(stations[idx].id);
      if (!station) {
        console.log(`  ${FAIL} Station ${idx} not found`);
        integrityPassed = false;
      } else if (station.dataCount !== READINGS_PER_STATION) {
        console.log(`  ${FAIL} Station ${idx} has ${station.dataCount} readings, expected ${READINGS_PER_STATION}`);
        integrityPassed = false;
      }
    }

    const stats = sensorService.getStats();
    console.log(`  Total stations: ${stats.totalStations}`);
    console.log(`  Total readings: ${stats.totalReadings}`);

    if (integrityPassed && stats.totalReadings === STATION_COUNT * READINGS_PER_STATION) {
      console.log(`  ${PASS} Data integrity verified`);
      passed++;
    } else {
      console.log(`  ${FAIL} Data integrity check failed`);
      failed++;
    }
  } catch (error) {
    console.log(`  ${FAIL} Integrity check failed: ${error.message}`);
    failed++;
  }

  // Test 4: Memory Usage
  console.log('\n' + '─'.repeat(50));
  console.log('TEST 4: Memory Usage Analysis');
  console.log('─'.repeat(50));

  const finalMemory = getMemoryUsageMB();
  const memoryIncrease = finalMemory.heapUsed - initialMemory.heapUsed;

  console.log(`  Initial heap: ${initialMemory.heapUsed}MB`);
  console.log(`  Final heap: ${finalMemory.heapUsed}MB`);
  console.log(`  Memory increase: ${memoryIncrease}MB`);
  console.log(`  Memory per station: ~${Math.round(memoryIncrease / STATION_COUNT * 1000) / 1000}MB`);

  // Check if memory usage is reasonable (< 500MB for this test)
  if (finalMemory.heapUsed < 500) {
    console.log(`  ${PASS} Memory usage within acceptable limits`);
    passed++;
  } else {
    console.log(`  ${WARN} High memory usage detected`);
    failed++;
  }

  // Summary
  const totalTime = Date.now() - startTime;
  console.log('\n' + '='.repeat(70));
  console.log('  STRESS TEST SUMMARY');
  console.log('='.repeat(70));
  console.log(`  Total time: ${totalTime}ms`);
  console.log(`  Tests passed: ${passed}/4`);
  console.log(`  Tests failed: ${failed}/4`);
  console.log(`  Status: ${failed === 0 ? PASS : FAIL}`);
  console.log('='.repeat(70) + '\n');

  // Force garbage collection if available
  if (global.gc) {
    global.gc();
    const afterGC = getMemoryUsageMB();
    console.log(`${INFO} After GC: ${afterGC.heapUsed}MB heap\n`);
  }

  process.exit(failed > 0 ? 1 : 0);
}

// Run the stress test
runStressTest().catch(error => {
  console.error(`${FAIL} Stress test crashed: ${error.message}`);
  console.error(error.stack);
  process.exit(1);
});
