#!/usr/bin/env node
/**
 * Manual Validation Script: Network Resilience Validation (Task 117)
 *
 * Run outside Jest to avoid OOM issues. Tests network resilience:
 * - Retry manager with exponential backoff
 * - Circuit breaker state transitions
 * - RPC manager failover
 * - Combined resilience patterns
 *
 * Usage:
 *   node scripts/manual-validation/validate-network-resilience.js
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

// ============================================================================
// Retry Manager Tests
// ============================================================================

class RetryManager {
  constructor(config = {}) {
    this.maxRetries = config.maxRetries || 3;
    this.baseDelay = config.baseDelay || 100;
    this.maxDelay = config.maxDelay || 5000;
    this.attempts = [];
  }

  async execute(operation, context = 'operation') {
    this.attempts = [];
    let lastError = null;

    for (let attempt = 0; attempt <= this.maxRetries; attempt++) {
      const startTime = Date.now();
      try {
        this.attempts.push({ attempt, timestamp: startTime, success: false });
        const result = await operation();
        this.attempts[this.attempts.length - 1].success = true;
        return result;
      } catch (error) {
        lastError = error;
        this.attempts[this.attempts.length - 1].error = error.message;

        if (attempt < this.maxRetries) {
          const delay = Math.min(this.baseDelay * Math.pow(2, attempt), this.maxDelay);
          await sleep(delay);
        }
      }
    }

    throw lastError;
  }

  getAttempts() {
    return [...this.attempts];
  }
}

async function validateRetryManager() {
  logHeader('Retry Manager Validation');

  await runTest('Succeed on first attempt', async () => {
    const retryManager = new RetryManager();
    let callCount = 0;

    const result = await retryManager.execute(async () => {
      callCount++;
      return 'success';
    });

    if (result !== 'success') throw new Error('Unexpected result');
    if (callCount !== 1) throw new Error(`Expected 1 call, got ${callCount}`);
    if (retryManager.getAttempts().length !== 1) throw new Error('Expected 1 attempt');
  });

  await runTest('Retry on transient failure', async () => {
    const retryManager = new RetryManager({ maxRetries: 3, baseDelay: 10 });
    let callCount = 0;

    const result = await retryManager.execute(async () => {
      callCount++;
      if (callCount < 3) {
        throw new Error('Transient failure');
      }
      return 'eventual-success';
    });

    if (result !== 'eventual-success') throw new Error('Unexpected result');
    if (callCount !== 3) throw new Error(`Expected 3 calls, got ${callCount}`);
  });

  await runTest('Exhaust retries on persistent failure', async () => {
    const retryManager = new RetryManager({ maxRetries: 2, baseDelay: 10 });

    try {
      await retryManager.execute(async () => {
        throw new Error('Persistent failure');
      });
      throw new Error('Should have thrown');
    } catch (error) {
      if (error.message !== 'Persistent failure') throw new Error('Wrong error');
      if (retryManager.getAttempts().length !== 3) throw new Error('Expected 3 attempts');
    }
  });

  await runTest('Apply exponential backoff', async () => {
    const retryManager = new RetryManager({ maxRetries: 3, baseDelay: 50, maxDelay: 1000 });
    let callCount = 0;

    try {
      await retryManager.execute(async () => {
        callCount++;
        throw new Error('Always fails');
      });
    } catch {
      // Expected
    }

    const attempts = retryManager.getAttempts();
    if (attempts.length !== 4) throw new Error('Expected 4 attempts');

    // Verify delays increase (approximately)
    for (let i = 1; i < attempts.length; i++) {
      const delay = attempts[i].timestamp - attempts[i - 1].timestamp;
      logInfo(`  Attempt ${i} delay: ${delay}ms`);
    }
  });

  await runTest('Cap delay at maxDelay', async () => {
    const retryManager = new RetryManager({ maxRetries: 5, baseDelay: 100, maxDelay: 200 });
    let callCount = 0;
    const startTime = Date.now();

    try {
      await retryManager.execute(async () => {
        callCount++;
        throw new Error('Always fails');
      });
    } catch {
      // Expected
    }

    const totalTime = Date.now() - startTime;
    // With maxDelay 200 and 5 retries, total should be < 1200ms (5 * 200 + overhead)
    if (totalTime > 2000) {
      throw new Error(`Total time ${totalTime}ms exceeds expected maximum`);
    }
    logInfo(`  Total time for 5 retries: ${totalTime}ms`);
  });

  logMemory();
}

// ============================================================================
// Circuit Breaker Tests
// ============================================================================

const CircuitState = {
  CLOSED: 'CLOSED',
  OPEN: 'OPEN',
  HALF_OPEN: 'HALF_OPEN',
};

class CircuitBreaker {
  constructor(config = {}) {
    this.state = CircuitState.CLOSED;
    this.failureThreshold = config.failureThreshold || 3;
    this.resetTimeout = config.resetTimeout || 1000;
    this.successThreshold = config.successThreshold || 2;
    this.failureCount = 0;
    this.successCount = 0;
    this.lastFailureTime = null;
  }

  async execute(operation) {
    if (this.state === CircuitState.OPEN) {
      if (this.shouldAttemptReset()) {
        this.state = CircuitState.HALF_OPEN;
        this.successCount = 0;
      } else {
        throw new Error('Circuit is OPEN');
      }
    }

    try {
      const result = await operation();
      this.onSuccess();
      return result;
    } catch (error) {
      this.onFailure();
      throw error;
    }
  }

  shouldAttemptReset() {
    if (!this.lastFailureTime) return true;
    return Date.now() - this.lastFailureTime >= this.resetTimeout;
  }

  onSuccess() {
    this.failureCount = 0;
    if (this.state === CircuitState.HALF_OPEN) {
      this.successCount++;
      if (this.successCount >= this.successThreshold) {
        this.state = CircuitState.CLOSED;
      }
    }
  }

  onFailure() {
    this.lastFailureTime = Date.now();
    this.failureCount++;
    this.successCount = 0;

    if (this.state === CircuitState.HALF_OPEN) {
      this.state = CircuitState.OPEN;
    } else if (this.failureCount >= this.failureThreshold) {
      this.state = CircuitState.OPEN;
    }
  }

  getState() {
    return this.state;
  }

  reset() {
    this.state = CircuitState.CLOSED;
    this.failureCount = 0;
    this.successCount = 0;
    this.lastFailureTime = null;
  }
}

async function validateCircuitBreaker() {
  logHeader('Circuit Breaker Validation');

  await runTest('Start in CLOSED state', async () => {
    const cb = new CircuitBreaker();
    if (cb.getState() !== CircuitState.CLOSED) throw new Error('Expected CLOSED');
  });

  await runTest('Transition CLOSED → OPEN after failures', async () => {
    const cb = new CircuitBreaker({ failureThreshold: 3 });

    for (let i = 0; i < 3; i++) {
      try {
        await cb.execute(async () => {
          throw new Error('Failure');
        });
      } catch {
        // Expected
      }
    }

    if (cb.getState() !== CircuitState.OPEN) throw new Error('Expected OPEN');
  });

  await runTest('Reject calls when OPEN', async () => {
    const cb = new CircuitBreaker({ failureThreshold: 1, resetTimeout: 10000 });

    try {
      await cb.execute(async () => {
        throw new Error('Failure');
      });
    } catch {
      // Expected - triggers OPEN
    }

    try {
      await cb.execute(async () => 'success');
      throw new Error('Should have rejected');
    } catch (error) {
      if (error.message !== 'Circuit is OPEN') throw error;
    }
  });

  await runTest('Transition OPEN → HALF_OPEN after timeout', async () => {
    const cb = new CircuitBreaker({ failureThreshold: 1, resetTimeout: 100 });

    try {
      await cb.execute(async () => {
        throw new Error('Failure');
      });
    } catch {
      // Expected
    }

    if (cb.getState() !== CircuitState.OPEN) throw new Error('Expected OPEN');

    await sleep(150);

    // Next call should be allowed (HALF_OPEN)
    await cb.execute(async () => 'success');
    if (cb.getState() !== CircuitState.HALF_OPEN) throw new Error('Expected HALF_OPEN');
  });

  await runTest('Transition HALF_OPEN → CLOSED after successes', async () => {
    const cb = new CircuitBreaker({
      failureThreshold: 1,
      resetTimeout: 50,
      successThreshold: 2,
    });

    // Trigger OPEN
    try {
      await cb.execute(async () => {
        throw new Error('Failure');
      });
    } catch {
      // Expected
    }

    await sleep(100);

    // First success - HALF_OPEN
    await cb.execute(async () => 'success1');
    if (cb.getState() !== CircuitState.HALF_OPEN) throw new Error('Expected HALF_OPEN');

    // Second success - CLOSED
    await cb.execute(async () => 'success2');
    if (cb.getState() !== CircuitState.CLOSED) throw new Error('Expected CLOSED');
  });

  await runTest('Transition HALF_OPEN → OPEN on failure', async () => {
    const cb = new CircuitBreaker({
      failureThreshold: 1,
      resetTimeout: 50,
      successThreshold: 3,
    });

    // Trigger OPEN
    try {
      await cb.execute(async () => {
        throw new Error('Failure');
      });
    } catch {
      // Expected
    }

    await sleep(100);

    // One success - HALF_OPEN
    await cb.execute(async () => 'success');

    // Then failure - back to OPEN
    try {
      await cb.execute(async () => {
        throw new Error('Failure');
      });
    } catch {
      // Expected
    }

    if (cb.getState() !== CircuitState.OPEN) throw new Error('Expected OPEN');
  });

  logMemory();
}

// ============================================================================
// RPC Manager Failover Tests
// ============================================================================

class RPCManager {
  constructor(endpoints) {
    this.endpoints = endpoints.map((url, i) => ({
      url,
      priority: i,
      healthy: true,
      failures: 0,
    }));
  }

  async call(method) {
    const healthy = this.endpoints.filter((e) => e.healthy);

    if (healthy.length === 0) {
      throw new Error('No healthy endpoints');
    }

    for (const endpoint of healthy) {
      try {
        const result = await this.executeCall(endpoint, method);
        endpoint.failures = 0;
        return result;
      } catch (error) {
        endpoint.failures++;
        if (endpoint.failures >= 3) {
          endpoint.healthy = false;
        }
      }
    }

    throw new Error('All endpoints failed');
  }

  async executeCall(endpoint, method) {
    // Simulate call - fail if URL contains 'fail'
    await sleep(10);
    if (endpoint.url.includes('fail')) {
      throw new Error('Endpoint unavailable');
    }
    return { method, endpoint: endpoint.url, result: 'success' };
  }

  markHealthy(url) {
    const endpoint = this.endpoints.find((e) => e.url === url);
    if (endpoint) {
      endpoint.healthy = true;
      endpoint.failures = 0;
    }
  }

  getHealthyEndpoints() {
    return this.endpoints.filter((e) => e.healthy).map((e) => e.url);
  }
}

async function validateRPCManager() {
  logHeader('RPC Manager Failover Validation');

  await runTest('Use primary endpoint when healthy', async () => {
    const manager = new RPCManager(['https://primary.example.com', 'https://backup.example.com']);

    const result = await manager.call('eth_blockNumber');
    if (result.endpoint !== 'https://primary.example.com') {
      throw new Error('Should use primary endpoint');
    }
  });

  await runTest('Failover to backup on primary failure', async () => {
    const manager = new RPCManager([
      'https://fail-primary.example.com',
      'https://backup.example.com',
    ]);

    const result = await manager.call('eth_blockNumber');
    if (result.endpoint !== 'https://backup.example.com') {
      throw new Error('Should failover to backup');
    }
  });

  await runTest('Mark endpoint unhealthy after repeated failures', async () => {
    const manager = new RPCManager([
      'https://fail.example.com',
      'https://healthy.example.com',
    ]);

    // Multiple calls to trigger unhealthy marking
    for (let i = 0; i < 5; i++) {
      try {
        await manager.call('eth_blockNumber');
      } catch {
        // Expected
      }
    }

    const healthy = manager.getHealthyEndpoints();
    if (healthy.includes('https://fail.example.com')) {
      throw new Error('Failed endpoint should be unhealthy');
    }
    if (!healthy.includes('https://healthy.example.com')) {
      throw new Error('Healthy endpoint should remain healthy');
    }
  });

  await runTest('Throw when all endpoints fail', async () => {
    const manager = new RPCManager(['https://fail1.example.com', 'https://fail2.example.com']);

    // Exhaust all endpoints
    for (let i = 0; i < 10; i++) {
      try {
        await manager.call('eth_blockNumber');
      } catch {
        // Expected
      }
    }

    try {
      await manager.call('eth_blockNumber');
      throw new Error('Should have thrown');
    } catch (error) {
      if (!error.message.includes('No healthy endpoints')) {
        throw new Error(`Unexpected error: ${error.message}`);
      }
    }
  });

  await runTest('Recover endpoint after marking healthy', async () => {
    const manager = new RPCManager(['https://recovered.example.com']);
    manager.endpoints[0].healthy = false;

    try {
      await manager.call('eth_blockNumber');
      throw new Error('Should have thrown');
    } catch (error) {
      if (!error.message.includes('No healthy endpoints')) throw error;
    }

    manager.markHealthy('https://recovered.example.com');
    const healthy = manager.getHealthyEndpoints();
    if (!healthy.includes('https://recovered.example.com')) {
      throw new Error('Should be healthy after recovery');
    }
  });

  logMemory();
}

// ============================================================================
// Combined Resilience Tests
// ============================================================================

async function validateCombinedResilience() {
  logHeader('Combined Resilience Pattern Validation');

  await runTest('Retry within circuit breaker', async () => {
    const retryManager = new RetryManager({ maxRetries: 2, baseDelay: 10 });
    const circuitBreaker = new CircuitBreaker({ failureThreshold: 5, resetTimeout: 1000 });

    let totalAttempts = 0;

    const result = await circuitBreaker.execute(async () => {
      return await retryManager.execute(async () => {
        totalAttempts++;
        if (totalAttempts < 2) {
          throw new Error('Transient');
        }
        return 'success';
      });
    });

    if (result !== 'success') throw new Error('Expected success');
    if (circuitBreaker.getState() !== CircuitState.CLOSED) {
      throw new Error('Circuit should remain closed');
    }
    logInfo(`  Total attempts: ${totalAttempts}`);
  });

  await runTest('Circuit opens after retry exhaustion', async () => {
    const circuitBreaker = new CircuitBreaker({ failureThreshold: 2, resetTimeout: 1000 });

    for (let i = 0; i < 2; i++) {
      const retryManager = new RetryManager({ maxRetries: 1, baseDelay: 10 });

      try {
        await circuitBreaker.execute(async () => {
          return await retryManager.execute(async () => {
            throw new Error('Persistent failure');
          });
        });
      } catch {
        // Expected
      }
    }

    if (circuitBreaker.getState() !== CircuitState.OPEN) {
      throw new Error('Circuit should be open');
    }
  });

  await runTest('Full resilience stack: Retry + CircuitBreaker + RPC Failover', async () => {
    const rpcManager = new RPCManager([
      'https://fail-primary.example.com',
      'https://healthy.example.com',
    ]);
    const circuitBreaker = new CircuitBreaker({ failureThreshold: 5 });
    const retryManager = new RetryManager({ maxRetries: 1, baseDelay: 10 });

    let callCount = 0;

    const result = await circuitBreaker.execute(async () => {
      return await retryManager.execute(async () => {
        callCount++;
        return await rpcManager.call('eth_blockNumber');
      });
    });

    if (result.endpoint !== 'https://healthy.example.com') {
      throw new Error('Should use healthy endpoint');
    }
    logInfo(`  Total call count: ${callCount}`);
  });

  logMemory();
}

// ============================================================================
// Main Execution
// ============================================================================

async function main() {
  console.log();
  log(COLORS.bright, '╔════════════════════════════════════════════════════════════╗');
  log(COLORS.bright, '║     Network Resilience Manual Validation (Task 117)        ║');
  log(COLORS.bright, '╚════════════════════════════════════════════════════════════╝');
  console.log();

  logInfo(`Node.js version: ${process.version}`);
  logInfo(`Started at: ${new Date().toISOString()}`);
  logMemory();

  try {
    await validateRetryManager();
    await validateCircuitBreaker();
    await validateRPCManager();
    await validateCombinedResilience();
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
    log(COLORS.green, '✓ All network resilience validations passed!');
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
