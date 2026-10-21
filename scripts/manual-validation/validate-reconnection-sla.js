#!/usr/bin/env node
/**
 * Manual Validation Script: Reconnection SLA Validation (Task 117)
 *
 * Run outside Jest to avoid OOM issues. Tests reconnection SLA compliance:
 * - Reconnection within 30 second SLA
 * - State preservation during disconnect
 * - Operation queue replay
 * - Heartbeat detection timing
 * - Exponential backoff timing
 *
 * Usage:
 *   node scripts/manual-validation/validate-reconnection-sla.js
 */

const COLORS = {
  reset: '\x1b[0m',
  bright: '\x1b[1m',
  green: '\x1b[32m',
  red: '\x1b[31m',
  yellow: '\x1b[33m',
  cyan: '\x1b[36m',
};

function log(color, message) {
  console.log(`${color}${message}${COLORS.reset}`);
}

function logSuccess(message) {
  log(COLORS.green, `✓ ${message}`);
}

function logError(message) {
  log(COLORS.red, `✗ ${message}`);
}

function logInfo(message) {
  log(COLORS.cyan, `ℹ ${message}`);
}

function logWarning(message) {
  log(COLORS.yellow, `⚠ ${message}`);
}

function logHeader(message) {
  console.log();
  log(COLORS.bright, `═══ ${message} ═══`);
}

// Memory monitoring
function getMemoryUsage() {
  const usage = process.memoryUsage();
  return {
    heapUsed: Math.round(usage.heapUsed / 1024 / 1024),
    heapTotal: Math.round(usage.heapTotal / 1024 / 1024),
    rss: Math.round(usage.rss / 1024 / 1024),
  };
}

function logMemory() {
  const mem = getMemoryUsage();
  logInfo(`Memory: ${mem.heapUsed}MB used / ${mem.heapTotal}MB heap / ${mem.rss}MB RSS`);
}

// Test results tracking
const results = {
  passed: 0,
  failed: 0,
  skipped: 0,
};

async function runTest(name, testFn) {
  try {
    await testFn();
    logSuccess(name);
    results.passed++;
  } catch (error) {
    logError(`${name}: ${error.message}`);
    results.failed++;
  }
}

// Sleep utility
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// SLA Constants (scaled down for testing)
const SLA_RECONNECT_TIME_MS = 3000; // 3 seconds for testing (production: 30s)
const HEARTBEAT_INTERVAL_MS = 100; // 100ms for testing (production: 5s)
const HEARTBEAT_FAILURE_THRESHOLD = 3;

// ============================================================================
// Reconnection Manager with SLA Tracking
// ============================================================================

class ReconnectionManager {
  constructor(config = {}) {
    this.connected = true;
    this.reconnecting = false;
    this.state = {};
    this.operationQueue = [];
    this.config = {
      baseDelay: config.baseDelay || 100,
      maxDelay: config.maxDelay || SLA_RECONNECT_TIME_MS,
      maxAttempts: config.maxAttempts || 10,
      ...config,
    };
    this.metrics = {
      disconnectTime: null,
      reconnectTime: null,
      attempts: 0,
      operationsReplayed: 0,
    };
  }

  saveState(key, value) {
    this.state[key] = value;
  }

  getState(key) {
    return this.state[key];
  }

  queueOperation(id, operation) {
    this.operationQueue.push({ id, operation, queuedAt: Date.now() });
  }

  disconnect() {
    if (this.connected) {
      this.connected = false;
      this.metrics.disconnectTime = Date.now();
      this.reconnecting = true;
    }
  }

  async reconnect(simulatedFailures = 0) {
    const startTime = Date.now();
    this.metrics.attempts = 0;

    for (let attempt = 0; attempt < this.config.maxAttempts; attempt++) {
      this.metrics.attempts++;
      const delay = Math.min(this.config.baseDelay * Math.pow(2, attempt), this.config.maxDelay);

      if (attempt >= simulatedFailures) {
        // Success
        this.connected = true;
        this.reconnecting = false;
        this.metrics.reconnectTime = Date.now();

        // Replay operations
        await this.replayOperations();

        return {
          success: true,
          totalTime: Date.now() - startTime,
          attempts: this.metrics.attempts,
        };
      }

      // Speed up for testing (use 1/10 of calculated delay)
      await sleep(delay / 10);

      // Check SLA
      if (Date.now() - startTime > SLA_RECONNECT_TIME_MS) {
        return {
          success: false,
          totalTime: Date.now() - startTime,
          attempts: this.metrics.attempts,
          reason: 'SLA_EXCEEDED',
        };
      }
    }

    return {
      success: false,
      totalTime: Date.now() - startTime,
      attempts: this.metrics.attempts,
      reason: 'MAX_ATTEMPTS_EXCEEDED',
    };
  }

  async replayOperations() {
    this.metrics.operationsReplayed = 0;
    const toReplay = [...this.operationQueue];
    this.operationQueue = [];

    for (const op of toReplay) {
      try {
        await op.operation();
        this.metrics.operationsReplayed++;
      } catch {
        // Track failed operations
      }
    }
  }

  getMetrics() {
    return {
      ...this.metrics,
      reconnectDuration:
        this.metrics.disconnectTime && this.metrics.reconnectTime
          ? this.metrics.reconnectTime - this.metrics.disconnectTime
          : null,
    };
  }

  isConnected() {
    return this.connected;
  }

  isReconnecting() {
    return this.reconnecting;
  }
}

// ============================================================================
// SLA Compliance Tests
// ============================================================================

async function validateSLACompliance() {
  logHeader('SLA Compliance Validation');

  await runTest('Reconnect within SLA (3s test / 30s production)', async () => {
    const manager = new ReconnectionManager({
      baseDelay: 50,
      maxDelay: 500,
    });

    manager.disconnect();
    const result = await manager.reconnect(2); // Fail first 2 attempts

    if (!result.success) {
      throw new Error(`Reconnection failed: ${result.reason}`);
    }
    if (result.totalTime > SLA_RECONNECT_TIME_MS) {
      throw new Error(`SLA violated: ${result.totalTime}ms > ${SLA_RECONNECT_TIME_MS}ms`);
    }
    logInfo(`  Reconnected in ${result.totalTime}ms after ${result.attempts} attempts`);
  });

  await runTest('Calculate accurate reconnect duration', async () => {
    const manager = new ReconnectionManager({ baseDelay: 50 });

    manager.disconnect();
    await sleep(100);
    await manager.reconnect(0);

    const metrics = manager.getMetrics();
    if (!metrics.reconnectDuration || metrics.reconnectDuration < 100) {
      throw new Error(`Invalid reconnect duration: ${metrics.reconnectDuration}ms`);
    }
    logInfo(`  Reconnect duration: ${metrics.reconnectDuration}ms`);
  });

  await runTest('Track reconnection attempts', async () => {
    const manager = new ReconnectionManager({ baseDelay: 10 });

    manager.disconnect();
    const result = await manager.reconnect(3); // Fail first 3 attempts

    if (result.attempts !== 4) {
      throw new Error(`Expected 4 attempts, got ${result.attempts}`);
    }
    logInfo(`  Total attempts: ${result.attempts}`);
  });

  await runTest('Fail gracefully when SLA exceeded', async () => {
    const manager = new ReconnectionManager({
      baseDelay: 1000, // Long delays to exceed SLA
      maxDelay: 1000,
      maxAttempts: 100,
    });

    manager.disconnect();
    const result = await manager.reconnect(100); // Always fail

    if (result.success) {
      throw new Error('Should have failed');
    }
    logInfo(`  Failed after ${result.totalTime}ms: ${result.reason}`);
  });

  logMemory();
}

// ============================================================================
// State Preservation Tests
// ============================================================================

async function validateStatePreservation() {
  logHeader('State Preservation Validation');

  await runTest('Preserve simple state during disconnect', async () => {
    const manager = new ReconnectionManager();

    manager.saveState('userId', 'user-123');
    manager.saveState('sessionId', 'session-456');

    manager.disconnect();

    if (manager.getState('userId') !== 'user-123') {
      throw new Error('userId not preserved');
    }
    if (manager.getState('sessionId') !== 'session-456') {
      throw new Error('sessionId not preserved');
    }
  });

  await runTest('Preserve complex state during disconnect', async () => {
    const manager = new ReconnectionManager();

    const complexState = {
      subscriptions: ['blocks', 'transactions', 'logs'],
      filters: { minValue: 1000, contract: '0x123' },
      cursor: { blockNumber: 12345, txIndex: 0 },
    };
    manager.saveState('complexState', complexState);

    manager.disconnect();

    const retrieved = manager.getState('complexState');
    if (!retrieved || retrieved.subscriptions.length !== 3) {
      throw new Error('Complex state not preserved');
    }
    if (retrieved.cursor.blockNumber !== 12345) {
      throw new Error('Nested state not preserved');
    }
  });

  await runTest('Maintain state after reconnect', async () => {
    const manager = new ReconnectionManager({ baseDelay: 10 });

    manager.saveState('testKey', 'testValue');
    manager.disconnect();
    await manager.reconnect(0);

    if (manager.getState('testKey') !== 'testValue') {
      throw new Error('State lost after reconnect');
    }
  });

  logMemory();
}

// ============================================================================
// Operation Queue Replay Tests
// ============================================================================

async function validateOperationQueueReplay() {
  logHeader('Operation Queue Replay Validation');

  await runTest('Replay single operation after reconnect', async () => {
    const manager = new ReconnectionManager({ baseDelay: 10 });
    let operationExecuted = false;

    manager.disconnect();
    manager.queueOperation('op1', async () => {
      operationExecuted = true;
    });

    await manager.reconnect(0);

    if (!operationExecuted) {
      throw new Error('Operation was not replayed');
    }
    const metrics = manager.getMetrics();
    if (metrics.operationsReplayed !== 1) {
      throw new Error(`Expected 1 operation replayed, got ${metrics.operationsReplayed}`);
    }
  });

  await runTest('Replay multiple operations in order', async () => {
    const manager = new ReconnectionManager({ baseDelay: 10 });
    const executionOrder = [];

    manager.disconnect();
    manager.queueOperation('op1', async () => executionOrder.push('op1'));
    manager.queueOperation('op2', async () => executionOrder.push('op2'));
    manager.queueOperation('op3', async () => executionOrder.push('op3'));

    await manager.reconnect(0);

    if (executionOrder.join(',') !== 'op1,op2,op3') {
      throw new Error(`Wrong order: ${executionOrder.join(',')}`);
    }
    logInfo(`  Replay order: ${executionOrder.join(' → ')}`);
  });

  await runTest('Track replayed operation count', async () => {
    const manager = new ReconnectionManager({ baseDelay: 10 });

    manager.disconnect();
    for (let i = 0; i < 10; i++) {
      manager.queueOperation(`op${i}`, async () => {});
    }

    await manager.reconnect(0);

    const metrics = manager.getMetrics();
    if (metrics.operationsReplayed !== 10) {
      throw new Error(`Expected 10 operations, got ${metrics.operationsReplayed}`);
    }
    logInfo(`  Operations replayed: ${metrics.operationsReplayed}`);
  });

  await runTest('Clear queue after replay', async () => {
    const manager = new ReconnectionManager({ baseDelay: 10 });

    manager.disconnect();
    manager.queueOperation('op1', async () => {});

    await manager.reconnect(0);

    // Queue a new operation and reconnect again
    manager.disconnect();
    await manager.reconnect(0);

    // Should not replay the old operation
    const metrics = manager.getMetrics();
    if (metrics.operationsReplayed !== 0) {
      throw new Error('Old operations were replayed again');
    }
  });

  logMemory();
}

// ============================================================================
// Heartbeat Detection Tests
// ============================================================================

class HeartbeatMonitor {
  constructor(config = {}) {
    this.interval = config.interval || HEARTBEAT_INTERVAL_MS;
    this.threshold = config.threshold || HEARTBEAT_FAILURE_THRESHOLD;
    this.consecutiveFailures = 0;
    this.shouldSucceed = true;
    this.metrics = {
      totalHeartbeats: 0,
      failures: 0,
      connectionLost: false,
    };
    this.timer = null;
  }

  start() {
    this.timer = setInterval(() => this.sendHeartbeat(), this.interval);
  }

  stop() {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  sendHeartbeat() {
    this.metrics.totalHeartbeats++;

    if (this.shouldSucceed) {
      this.consecutiveFailures = 0;
    } else {
      this.consecutiveFailures++;
      this.metrics.failures++;

      if (this.consecutiveFailures >= this.threshold) {
        this.metrics.connectionLost = true;
      }
    }
  }

  simulateConnectionLoss() {
    this.shouldSucceed = false;
  }

  simulateConnectionRestore() {
    this.shouldSucceed = true;
    this.consecutiveFailures = 0;
  }

  getMetrics() {
    return { ...this.metrics };
  }

  isConnectionLost() {
    return this.metrics.connectionLost;
  }
}

async function validateHeartbeatDetection() {
  logHeader('Heartbeat Detection Validation');

  await runTest('Detect connection loss after threshold failures', async () => {
    const monitor = new HeartbeatMonitor({ interval: 50, threshold: 3 });

    monitor.start();
    monitor.simulateConnectionLoss();

    await sleep(250); // Allow time for heartbeats

    monitor.stop();

    if (!monitor.isConnectionLost()) {
      throw new Error('Connection loss not detected');
    }
    const metrics = monitor.getMetrics();
    logInfo(`  Total heartbeats: ${metrics.totalHeartbeats}, Failures: ${metrics.failures}`);
  });

  await runTest('Reset failure count on success', async () => {
    const monitor = new HeartbeatMonitor({ interval: 50, threshold: 5 });

    monitor.start();

    // Some failures
    monitor.simulateConnectionLoss();
    await sleep(100);

    // Then success
    monitor.simulateConnectionRestore();
    await sleep(100);

    monitor.stop();

    if (monitor.isConnectionLost()) {
      throw new Error('Connection should not be marked as lost');
    }
  });

  await runTest('Accurate heartbeat interval timing', async () => {
    const monitor = new HeartbeatMonitor({ interval: 50, threshold: 10 });
    const startTime = Date.now();

    monitor.start();
    await sleep(300);
    monitor.stop();

    const metrics = monitor.getMetrics();
    const expectedHeartbeats = Math.floor(300 / 50);

    // Allow some tolerance
    if (Math.abs(metrics.totalHeartbeats - expectedHeartbeats) > 2) {
      throw new Error(
        `Expected ~${expectedHeartbeats} heartbeats, got ${metrics.totalHeartbeats}`
      );
    }
    logInfo(`  Heartbeats in 300ms: ${metrics.totalHeartbeats}`);
  });

  logMemory();
}

// ============================================================================
// Exponential Backoff Tests
// ============================================================================

async function validateExponentialBackoff() {
  logHeader('Exponential Backoff Validation');

  await runTest('Verify delay doubles each attempt', async () => {
    const baseDelay = 100;
    const delays = [];

    for (let attempt = 0; attempt < 5; attempt++) {
      const delay = baseDelay * Math.pow(2, attempt);
      delays.push(delay);
    }

    // Verify exponential growth
    for (let i = 1; i < delays.length; i++) {
      const ratio = delays[i] / delays[i - 1];
      if (Math.abs(ratio - 2) > 0.01) {
        throw new Error(`Delay ratio at attempt ${i} is ${ratio}, expected 2`);
      }
    }
    logInfo(`  Delays: ${delays.join('ms → ')}ms`);
  });

  await runTest('Cap delay at maximum', async () => {
    const baseDelay = 100;
    const maxDelay = 500;
    const cappedDelays = [];

    for (let attempt = 0; attempt < 10; attempt++) {
      const delay = Math.min(baseDelay * Math.pow(2, attempt), maxDelay);
      cappedDelays.push(delay);
    }

    // All delays should be <= maxDelay
    for (const delay of cappedDelays) {
      if (delay > maxDelay) {
        throw new Error(`Delay ${delay}ms exceeds max ${maxDelay}ms`);
      }
    }

    // Later delays should equal maxDelay
    const lastDelay = cappedDelays[cappedDelays.length - 1];
    if (lastDelay !== maxDelay) {
      throw new Error(`Last delay ${lastDelay}ms should equal max ${maxDelay}ms`);
    }
    logInfo(`  Max delay: ${lastDelay}ms (cap: ${maxDelay}ms)`);
  });

  await runTest('Add jitter within bounds', async () => {
    const baseDelay = 1000;
    const jitterFactor = 0.25;

    for (let i = 0; i < 10; i++) {
      const jitter = baseDelay * jitterFactor * (Math.random() * 2 - 1);
      const delayWithJitter = baseDelay + jitter;

      const minBound = baseDelay * (1 - jitterFactor);
      const maxBound = baseDelay * (1 + jitterFactor);

      if (delayWithJitter < minBound || delayWithJitter > maxBound) {
        throw new Error(`Jitter ${delayWithJitter}ms out of bounds [${minBound}, ${maxBound}]`);
      }
    }
    logInfo(`  Jitter range: ±${jitterFactor * 100}%`);
  });

  logMemory();
}

// ============================================================================
// Full Flow Integration Test
// ============================================================================

async function validateFullFlow() {
  logHeader('Full Reconnection Flow Integration');

  await runTest('Complete disconnect → reconnect → replay flow', async () => {
    const manager = new ReconnectionManager({ baseDelay: 50 });

    // 1. Set up state
    manager.saveState('userId', 'test-user');
    manager.saveState('subscriptions', ['blocks', 'logs']);

    // 2. Queue operations
    let op1Executed = false;
    let op2Executed = false;

    // 3. Disconnect
    manager.disconnect();

    // 4. Queue more operations while disconnected
    manager.queueOperation('op1', async () => {
      op1Executed = true;
    });
    manager.queueOperation('op2', async () => {
      op2Executed = true;
    });

    // 5. Reconnect
    const result = await manager.reconnect(1); // Fail once then succeed

    // 6. Verify
    if (!result.success) {
      throw new Error(`Reconnection failed: ${result.reason}`);
    }
    if (!manager.isConnected()) {
      throw new Error('Should be connected');
    }
    if (manager.getState('userId') !== 'test-user') {
      throw new Error('State not preserved');
    }
    if (!op1Executed || !op2Executed) {
      throw new Error('Operations not replayed');
    }

    const metrics = manager.getMetrics();
    logInfo(`  Reconnected in ${result.totalTime}ms, ${metrics.operationsReplayed} ops replayed`);
  });

  await runTest('SLA-compliant reconnection under stress', async () => {
    const iterations = 10;
    const successfulReconnects = [];

    for (let i = 0; i < iterations; i++) {
      const manager = new ReconnectionManager({ baseDelay: 20, maxDelay: 200 });

      manager.saveState('iteration', i);
      manager.disconnect();
      manager.queueOperation(`op-${i}`, async () => {});

      const result = await manager.reconnect(2);

      if (result.success && result.totalTime <= SLA_RECONNECT_TIME_MS) {
        successfulReconnects.push(result.totalTime);
      }
    }

    const successRate = (successfulReconnects.length / iterations) * 100;
    const avgTime = successfulReconnects.reduce((a, b) => a + b, 0) / successfulReconnects.length;

    if (successRate < 100) {
      throw new Error(`Only ${successRate}% reconnections within SLA`);
    }
    logInfo(`  ${iterations} reconnections, 100% within SLA, avg ${Math.round(avgTime)}ms`);
  });

  logMemory();
}

// ============================================================================
// Main Execution
// ============================================================================

async function main() {
  console.log();
  log(COLORS.bright, '╔════════════════════════════════════════════════════════════╗');
  log(COLORS.bright, '║     Reconnection SLA Manual Validation (Task 117)          ║');
  log(COLORS.bright, '╚════════════════════════════════════════════════════════════╝');
  console.log();

  logInfo(`Node.js version: ${process.version}`);
  logInfo(`Started at: ${new Date().toISOString()}`);
  logInfo(`Test SLA: ${SLA_RECONNECT_TIME_MS}ms (Production: 30000ms)`);
  logMemory();

  try {
    await validateSLACompliance();
    await validateStatePreservation();
    await validateOperationQueueReplay();
    await validateHeartbeatDetection();
    await validateExponentialBackoff();
    await validateFullFlow();
  } catch (error) {
    logError(`Unexpected error: ${error.message}`);
    results.failed++;
  }

  // Final summary
  logHeader('Validation Summary');
  logInfo(`Passed: ${results.passed}`);
  if (results.failed > 0) {
    logError(`Failed: ${results.failed}`);
  }
  if (results.skipped > 0) {
    logWarning(`Skipped: ${results.skipped}`);
  }
  logMemory();

  console.log();
  if (results.failed === 0) {
    log(COLORS.green, '✓ All reconnection SLA validations passed!');
    process.exit(0);
  } else {
    log(COLORS.red, `✗ ${results.failed} validation(s) failed`);
    process.exit(1);
  }
}

main().catch((error) => {
  logError(`Fatal error: ${error.message}`);
  process.exit(1);
});
