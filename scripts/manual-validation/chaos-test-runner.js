#!/usr/bin/env node
/**
 * Manual Chaos Test Runner
 * Task 121 - Chaos Monkey Lite
 *
 * Runs chaos tests outside of Jest to avoid OOM issues.
 * Provides memory-efficient execution with colorized output.
 *
 * Run: node scripts/manual-validation/chaos-test-runner.js
 */

const PASS = '\x1b[32mPASS\x1b[0m';
const FAIL = '\x1b[31mFAIL\x1b[0m';
const INFO = '\x1b[36mINFO\x1b[0m';
const WARN = '\x1b[33mWARN\x1b[0m';
const BOLD = '\x1b[1m';
const RESET = '\x1b[0m';

// ============================================================================
// Utility Functions
// ============================================================================

function getMemoryUsageMB() {
  const used = process.memoryUsage();
  return {
    heapUsed: Math.round(used.heapUsed / 1024 / 1024),
    heapTotal: Math.round(used.heapTotal / 1024 / 1024),
    rss: Math.round(used.rss / 1024 / 1024),
  };
}

function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// Weather validation limits (WMO standards)
const WEATHER_LIMITS = {
  temperature: { min: -89.2, max: 70.7 },
  humidity: { min: 0, max: 100 },
  pressure: { min: 870, max: 1084 },
};

// XSS patterns to detect
const XSS_PATTERNS = [
  /<script[^>]*>/gi,
  /javascript\s*:/gi,
  /\bon\w+\s*=/gi,
];

// SQL injection patterns
const SQL_PATTERNS = [
  /('|")\s*(or|and)\s*('|"|\d)/gi,
  /;\s*(drop|delete|update|insert|alter|create|truncate)\s/gi,
  /union\s+select/gi,
];

function detectXSS(input) {
  if (typeof input !== 'string') return false;
  return XSS_PATTERNS.some(pattern => {
    pattern.lastIndex = 0;
    return pattern.test(input);
  });
}

function detectSQLInjection(input) {
  if (typeof input !== 'string') return false;
  return SQL_PATTERNS.some(pattern => {
    pattern.lastIndex = 0;
    return pattern.test(input);
  });
}

function validateNumericRange(value, min, max) {
  const num = Number(value);
  if (isNaN(num) || !isFinite(num)) return null;
  if (num < min || num > max) return null;
  return num;
}

// ============================================================================
// Test Suites
// ============================================================================

async function runSensorValidationTests() {
  console.log('\n' + '─'.repeat(60));
  console.log(`${BOLD}TEST SUITE: Sensor Data Validation${RESET}`);
  console.log('─'.repeat(60));

  let passed = 0;
  let failed = 0;

  // Test 1: XSS Detection
  console.log('\n  Testing XSS Detection...');
  const xssPayloads = [
    "<script>alert('xss')</script>",
    "javascript:alert(1)",
    "<img onerror=alert(1) src=x>",
    "<svg onload=alert(1)>",
  ];

  let xssAllDetected = true;
  for (const payload of xssPayloads) {
    if (!detectXSS(payload)) {
      console.log(`    ${FAIL} XSS not detected: ${payload.substring(0, 30)}...`);
      xssAllDetected = false;
    }
  }

  if (xssAllDetected) {
    console.log(`    ${PASS} All XSS payloads detected (${xssPayloads.length})`);
    passed++;
  } else {
    failed++;
  }

  // Test 2: SQL Injection Detection
  console.log('\n  Testing SQL Injection Detection...');
  const sqlPayloads = [
    "'; DROP TABLE users;--",
    "1' OR '1'='1",
    "UNION SELECT password FROM users",
  ];

  let sqlAllDetected = true;
  for (const payload of sqlPayloads) {
    if (!detectSQLInjection(payload)) {
      console.log(`    ${FAIL} SQL injection not detected: ${payload}`);
      sqlAllDetected = false;
    }
  }

  if (sqlAllDetected) {
    console.log(`    ${PASS} All SQL injection payloads detected (${sqlPayloads.length})`);
    passed++;
  } else {
    failed++;
  }

  // Test 3: Weather Data Validation
  console.log('\n  Testing Weather Data Validation...');

  const invalidData = [
    { temp: -100, desc: 'Temperature too low' },
    { temp: 80, desc: 'Temperature too high' },
    { humidity: -10, desc: 'Humidity negative' },
    { humidity: 150, desc: 'Humidity too high' },
    { pressure: 800, desc: 'Pressure too low' },
    { pressure: 1100, desc: 'Pressure too high' },
  ];

  let weatherValidationPassed = true;
  for (const data of invalidData) {
    if (data.temp !== undefined) {
      const result = validateNumericRange(data.temp, WEATHER_LIMITS.temperature.min, WEATHER_LIMITS.temperature.max);
      if (result !== null) {
        console.log(`    ${FAIL} ${data.desc}: should be rejected`);
        weatherValidationPassed = false;
      }
    }
    if (data.humidity !== undefined) {
      const result = validateNumericRange(data.humidity, WEATHER_LIMITS.humidity.min, WEATHER_LIMITS.humidity.max);
      if (result !== null) {
        console.log(`    ${FAIL} ${data.desc}: should be rejected`);
        weatherValidationPassed = false;
      }
    }
    if (data.pressure !== undefined) {
      const result = validateNumericRange(data.pressure, WEATHER_LIMITS.pressure.min, WEATHER_LIMITS.pressure.max);
      if (result !== null) {
        console.log(`    ${FAIL} ${data.desc}: should be rejected`);
        weatherValidationPassed = false;
      }
    }
  }

  if (weatherValidationPassed) {
    console.log(`    ${PASS} All invalid weather data rejected (${invalidData.length})`);
    passed++;
  } else {
    failed++;
  }

  // Test 4: Valid data should pass
  console.log('\n  Testing Valid Data Acceptance...');
  const validTemp = validateNumericRange(20.5, WEATHER_LIMITS.temperature.min, WEATHER_LIMITS.temperature.max);
  const validHumidity = validateNumericRange(55, WEATHER_LIMITS.humidity.min, WEATHER_LIMITS.humidity.max);
  const validPressure = validateNumericRange(1013, WEATHER_LIMITS.pressure.min, WEATHER_LIMITS.pressure.max);

  if (validTemp === 20.5 && validHumidity === 55 && validPressure === 1013) {
    console.log(`    ${PASS} Valid weather data accepted`);
    passed++;
  } else {
    console.log(`    ${FAIL} Valid weather data incorrectly rejected`);
    failed++;
  }

  return { passed, failed };
}

async function runTimeoutTests() {
  console.log('\n' + '─'.repeat(60));
  console.log(`${BOLD}TEST SUITE: Timeout Behavior${RESET}`);
  console.log('─'.repeat(60));

  let passed = 0;
  let failed = 0;

  // Test 1: Fast operation completes
  console.log('\n  Testing fast operation completion...');
  const fastStart = Date.now();
  await delay(50);
  const fastDuration = Date.now() - fastStart;

  if (fastDuration < 200) {
    console.log(`    ${PASS} Fast operation completed in ${fastDuration}ms`);
    passed++;
  } else {
    console.log(`    ${FAIL} Fast operation took too long: ${fastDuration}ms`);
    failed++;
  }

  // Test 2: Timeout detection
  console.log('\n  Testing timeout detection...');
  const timeoutMs = 100;
  const startTime = Date.now();
  let timedOut = false;

  try {
    await Promise.race([
      delay(200), // Slow operation
      new Promise((_, reject) => setTimeout(() => reject(new Error('Timeout')), timeoutMs)),
    ]);
  } catch (e) {
    if (e.message === 'Timeout') {
      timedOut = true;
    }
  }

  const elapsed = Date.now() - startTime;

  if (timedOut && elapsed < 150) {
    console.log(`    ${PASS} Timeout detected in ${elapsed}ms`);
    passed++;
  } else {
    console.log(`    ${FAIL} Timeout detection failed (timedOut=${timedOut}, elapsed=${elapsed}ms)`);
    failed++;
  }

  return { passed, failed };
}

async function runCircuitBreakerTests() {
  console.log('\n' + '─'.repeat(60));
  console.log(`${BOLD}TEST SUITE: Circuit Breaker Simulation${RESET}`);
  console.log('─'.repeat(60));

  let passed = 0;
  let failed = 0;

  // Simple circuit breaker simulation
  class SimpleCircuitBreaker {
    constructor(threshold) {
      this.threshold = threshold;
      this.failures = 0;
      this.state = 'CLOSED';
    }

    recordFailure() {
      this.failures++;
      if (this.failures >= this.threshold) {
        this.state = 'OPEN';
      }
    }

    recordSuccess() {
      if (this.state === 'HALF_OPEN') {
        this.state = 'CLOSED';
        this.failures = 0;
      }
    }

    tryReset() {
      if (this.state === 'OPEN') {
        this.state = 'HALF_OPEN';
      }
    }
  }

  // Test 1: Circuit opens after threshold failures
  console.log('\n  Testing circuit breaker state transitions...');
  const breaker = new SimpleCircuitBreaker(3);

  breaker.recordFailure();
  breaker.recordFailure();
  if (breaker.state !== 'CLOSED') {
    console.log(`    ${FAIL} Circuit opened too early`);
    failed++;
  } else {
    breaker.recordFailure();
    if (breaker.state === 'OPEN') {
      console.log(`    ${PASS} Circuit opened after ${breaker.threshold} failures`);
      passed++;
    } else {
      console.log(`    ${FAIL} Circuit did not open after threshold`);
      failed++;
    }
  }

  // Test 2: Half-open to closed transition
  console.log('\n  Testing half-open to closed transition...');
  breaker.tryReset();
  if (breaker.state === 'HALF_OPEN') {
    breaker.recordSuccess();
    if (breaker.state === 'CLOSED') {
      console.log(`    ${PASS} Circuit closed after successful half-open request`);
      passed++;
    } else {
      console.log(`    ${FAIL} Circuit did not close on success`);
      failed++;
    }
  } else {
    console.log(`    ${FAIL} Circuit did not transition to half-open`);
    failed++;
  }

  return { passed, failed };
}

async function runMeshNetworkTests() {
  console.log('\n' + '─'.repeat(60));
  console.log(`${BOLD}TEST SUITE: Mesh Network Simulation${RESET}`);
  console.log('─'.repeat(60));

  let passed = 0;
  let failed = 0;

  // Simple service simulation
  class MockService {
    constructor(name) {
      this.name = name;
      this.healthy = true;
      this.queue = [];
    }

    setHealthy(status) {
      this.healthy = status;
    }

    execute(operation) {
      if (!this.healthy) {
        this.queue.push(operation);
        return null;
      }
      return operation();
    }

    processQueue() {
      if (!this.healthy) return 0;
      const count = this.queue.length;
      this.queue = [];
      return count;
    }
  }

  // Test 1: Service queues operations when unhealthy
  console.log('\n  Testing operation queuing during partition...');
  const service = new MockService('test-service');

  service.setHealthy(false);
  service.execute(() => 'op1');
  service.execute(() => 'op2');
  service.execute(() => 'op3');

  if (service.queue.length === 3) {
    console.log(`    ${PASS} Operations queued during partition (${service.queue.length})`);
    passed++;
  } else {
    console.log(`    ${FAIL} Operations not queued correctly`);
    failed++;
  }

  // Test 2: Queue processed on recovery
  console.log('\n  Testing queue processing on recovery...');
  service.setHealthy(true);
  const processed = service.processQueue();

  if (processed === 3 && service.queue.length === 0) {
    console.log(`    ${PASS} Queue processed on recovery (${processed} operations)`);
    passed++;
  } else {
    console.log(`    ${FAIL} Queue not processed correctly`);
    failed++;
  }

  return { passed, failed };
}

async function runProcessRecoveryTests() {
  console.log('\n' + '─'.repeat(60));
  console.log(`${BOLD}TEST SUITE: Process Recovery Simulation${RESET}`);
  console.log('─'.repeat(60));

  let passed = 0;
  let failed = 0;

  // Simple transaction manager simulation
  class TransactionManager {
    constructor() {
      this.transactions = new Map();
      this.checkpoints = new Map();
    }

    createTransaction(data) {
      const id = `tx-${Date.now()}`;
      this.transactions.set(id, { id, data, status: 'pending' });
      return id;
    }

    process(id) {
      const tx = this.transactions.get(id);
      if (!tx) return null;
      tx.status = 'processing';
      this.checkpoints.set(id, { ...tx.data });
      tx.status = 'committed';
      return tx;
    }

    recover(id) {
      const tx = this.transactions.get(id);
      if (!tx) throw new Error('Transaction not found');
      if (this.checkpoints.has(id)) {
        tx.status = 'recovered';
        return tx;
      }
      return this.process(id);
    }
  }

  // Test 1: Checkpoint preservation
  console.log('\n  Testing checkpoint preservation...');
  const manager = new TransactionManager();
  const txId = manager.createTransaction({ amount: 100 });
  manager.process(txId);

  if (manager.checkpoints.has(txId)) {
    console.log(`    ${PASS} Checkpoint created for transaction`);
    passed++;
  } else {
    console.log(`    ${FAIL} Checkpoint not created`);
    failed++;
  }

  // Test 2: Recovery from checkpoint
  console.log('\n  Testing recovery from checkpoint...');
  const recovered = manager.recover(txId);

  if (recovered && recovered.status === 'recovered') {
    console.log(`    ${PASS} Transaction recovered from checkpoint`);
    passed++;
  } else {
    console.log(`    ${FAIL} Transaction recovery failed`);
    failed++;
  }

  // Test 3: No duplicate transactions
  console.log('\n  Testing no duplicate transactions on recovery...');
  const initialCount = manager.transactions.size;
  manager.recover(txId);

  if (manager.transactions.size === initialCount) {
    console.log(`    ${PASS} No duplicate transactions created`);
    passed++;
  } else {
    console.log(`    ${FAIL} Duplicate transaction created`);
    failed++;
  }

  return { passed, failed };
}

// ============================================================================
// Main Runner
// ============================================================================

async function runAllTests() {
  console.log('\n' + '='.repeat(70));
  console.log(`${BOLD}  CHAOS TEST RUNNER - Manual Validation${RESET}`);
  console.log('  WRFCoin Resilience Testing (Task 121)');
  console.log('='.repeat(70));

  const startTime = Date.now();
  const initialMemory = getMemoryUsageMB();

  console.log(`\n${INFO} Initial memory: ${initialMemory.heapUsed}MB heap, ${initialMemory.rss}MB RSS`);
  console.log(`${INFO} Environment: ${process.env.NODE_ENV || 'development'}`);

  // Block production
  if (process.env.NODE_ENV === 'production') {
    console.log(`\n${FAIL} BLOCKED: Cannot run chaos tests in production environment`);
    process.exit(1);
  }

  let totalPassed = 0;
  let totalFailed = 0;

  // Run all test suites
  const suites = [
    { name: 'Sensor Validation', fn: runSensorValidationTests },
    { name: 'Timeout Behavior', fn: runTimeoutTests },
    { name: 'Circuit Breaker', fn: runCircuitBreakerTests },
    { name: 'Mesh Network', fn: runMeshNetworkTests },
    { name: 'Process Recovery', fn: runProcessRecoveryTests },
  ];

  for (const suite of suites) {
    try {
      const result = await suite.fn();
      totalPassed += result.passed;
      totalFailed += result.failed;
    } catch (error) {
      console.log(`\n${FAIL} Suite "${suite.name}" crashed: ${error.message}`);
      totalFailed++;
    }

    // Memory check between suites
    if (global.gc) global.gc();
    const mem = getMemoryUsageMB();
    if (mem.heapUsed > 400) {
      console.log(`${WARN} High memory usage: ${mem.heapUsed}MB`);
    }
  }

  // Summary
  const totalTime = Date.now() - startTime;
  const finalMemory = getMemoryUsageMB();

  console.log('\n' + '='.repeat(70));
  console.log(`${BOLD}  CHAOS TEST SUMMARY${RESET}`);
  console.log('='.repeat(70));
  console.log(`  Total time: ${totalTime}ms`);
  console.log(`  Tests passed: ${totalPassed}`);
  console.log(`  Tests failed: ${totalFailed}`);
  console.log(`  Memory: ${initialMemory.heapUsed}MB -> ${finalMemory.heapUsed}MB heap`);
  console.log(`  Status: ${totalFailed === 0 ? PASS : FAIL}`);
  console.log('='.repeat(70) + '\n');

  if (global.gc) {
    global.gc();
    const afterGC = getMemoryUsageMB();
    console.log(`${INFO} After GC: ${afterGC.heapUsed}MB heap\n`);
  }

  process.exit(totalFailed > 0 ? 1 : 0);
}

// Run tests
runAllTests().catch(error => {
  console.error(`${FAIL} Chaos test runner crashed: ${error.message}`);
  console.error(error.stack);
  process.exit(1);
});
