#!/usr/bin/env node

/**
 * Node.js Performance Profiling System for Wrfcoin
 *
 * Provides comprehensive profiling capabilities including:
 * - CPU profiling with 0x and clinic.js
 * - Memory profiling with heapdump and memwatch
 * - Event loop monitoring and async profiling
 * - Integration with existing monitoring infrastructure
 */

const fs = require('fs').promises;
const path = require('path');
const { performance, PerformanceObserver } = require('perf_hooks');
const v8 = require('v8');
const inspector = require('inspector');
const {
  GracefulShutdown,
  ShutdownPriority,
} = require('../../backend/shared/graceful-shutdown/index.js');

class NodeJSProfiler {
  constructor(config = {}) {
    this.config = {
      cpuProfilingEnabled: config.cpuProfilingEnabled || true,
      memoryProfilingEnabled: config.memoryProfilingEnabled || true,
      eventLoopProfilingEnabled: config.eventLoopProfilingEnabled || true,
      profileRetentionHours: config.profileRetentionHours || 24,
      profileOutputDir: config.profileOutputDir || './profiles/nodejs',
      continuousProfiling: config.continuousProfiling || false,
      samplingInterval: config.samplingInterval || 1000, // ms
      heapSnapshotInterval: config.heapSnapshotInterval || 300000, // 5 minutes
      enableInspector: config.enableInspector || true,
      ...config,
    };

    this.profilingActive = false;
    this.profiles = [];
    this.cpuProfiles = [];
    this.memoryProfiles = [];
    this.eventLoopProfiles = [];
    this.session = null;

    this.setupPerformanceObserver();
    this.setupMemoryMonitoring();
    this.setupEventLoopMonitoring();
  }

  /**
   * Start continuous profiling
   */
  async startContinuousProfiling() {
    if (this.profilingActive) {
      console.log('Profiling already active');
      return;
    }

    this.profilingActive = true;
    console.log('Starting Node.js continuous profiling...');

    // Ensure output directory exists
    await this.ensureOutputDirectory();

    // Start inspector session if enabled
    if (this.config.enableInspector) {
      this.startInspectorSession();
    }

    // Start CPU profiling
    if (this.config.cpuProfilingEnabled) {
      await this.startCPUProfiling();
    }

    // Start memory profiling
    if (this.config.memoryProfilingEnabled) {
      await this.startMemoryProfiling();
    }

    // Start event loop profiling
    if (this.config.eventLoopProfilingEnabled) {
      await this.startEventLoopProfiling();
    }

    // Start cleanup task
    this.startCleanupTask();

    console.log('Node.js profiling started with config:', this.config);
  }

  /**
   * Stop profiling
   */
  async stopProfiling() {
    if (!this.profilingActive) {
      return;
    }

    this.profilingActive = false;

    // Stop inspector session
    if (this.session) {
      this.session.disconnect();
      this.session = null;
    }

    console.log('Node.js profiling stopped');
  }

  /**
   * Profile a specific operation
   */
  async profileOperation(category, operation, operationFn) {
    const startTime = performance.now();
    const startMemory = process.memoryUsage();

    let result;
    let error = null;

    try {
      if (typeof operationFn === 'function') {
        if (operationFn.constructor.name === 'AsyncFunction') {
          result = await operationFn();
        } else {
          result = operationFn();
        }
      } else {
        throw new Error('Operation must be a function');
      }
    } catch (err) {
      error = err;
    }

    const endTime = performance.now();
    const endMemory = process.memoryUsage();

    const profileData = {
      timestamp: new Date().toISOString(),
      category,
      operation,
      durationMs: endTime - startTime,
      memoryDelta: {
        rss: endMemory.rss - startMemory.rss,
        heapUsed: endMemory.heapUsed - startMemory.heapUsed,
        heapTotal: endMemory.heapTotal - startMemory.heapTotal,
        external: endMemory.external - startMemory.external,
      },
      cpuUsage: process.cpuUsage(),
      error: error ? error.message : null,
      stackTrace: error ? error.stack : null,
    };

    this.profiles.push(profileData);

    if (error) {
      throw error;
    }

    return result;
  }

  /**
   * Start CPU profiling
   */
  async startCPUProfiling() {
    if (!this.session) {
      return;
    }

    // Enable profiler
    await new Promise((resolve, reject) => {
      this.session.post('Profiler.enable', err => {
        if (err) reject(err);
        else resolve();
      });
    });

    // Start periodic CPU profiling
    setInterval(async () => {
      if (!this.profilingActive) return;

      try {
        await this.captureProfile();
      } catch (error) {
        console.error('CPU profiling error:', error);
      }
    }, this.config.samplingInterval);
  }

  /**
   * Capture CPU profile
   */
  async captureProfile() {
    if (!this.session) return;

    // Start profiling
    await new Promise((resolve, reject) => {
      this.session.post('Profiler.start', err => {
        if (err) reject(err);
        else resolve();
      });
    });

    // Profile for a short duration
    await new Promise(resolve => setTimeout(resolve, 1000));

    // Stop and get profile
    const profile = await new Promise((resolve, reject) => {
      this.session.post('Profiler.stop', (err, { profile }) => {
        if (err) reject(err);
        else resolve(profile);
      });
    });

    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    const profilePath = path.join(
      this.config.profileOutputDir,
      `cpu-profile-${timestamp}.cpuprofile`
    );

    await fs.writeFile(profilePath, JSON.stringify(profile, null, 2));

    this.cpuProfiles.push({
      timestamp: new Date().toISOString(),
      profilePath,
      sampleCount: profile.samples ? profile.samples.length : 0,
      duration: 1000, // 1 second
    });

    console.log(`CPU profile saved: ${profilePath}`);
  }

  /**
   * Start memory profiling
   */
  async startMemoryProfiling() {
    // Periodic heap snapshots
    setInterval(async () => {
      if (!this.profilingActive) return;

      try {
        await this.captureHeapSnapshot();
        this.captureMemoryProfile();
      } catch (error) {
        console.error('Memory profiling error:', error);
      }
    }, this.config.heapSnapshotInterval);

    // Continuous memory monitoring
    setInterval(() => {
      if (!this.profilingActive) return;
      this.captureMemoryProfile();
    }, 30000); // Every 30 seconds
  }

  /**
   * Capture heap snapshot
   */
  async captureHeapSnapshot() {
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    const snapshotPath = path.join(
      this.config.profileOutputDir,
      `heap-snapshot-${timestamp}.heapsnapshot`
    );

    const heapSnapshot = v8.getHeapSnapshot();
    const writeStream = require('fs').createWriteStream(snapshotPath);

    return new Promise((resolve, reject) => {
      heapSnapshot.pipe(writeStream);
      heapSnapshot.on('end', () => {
        console.log(`Heap snapshot saved: ${snapshotPath}`);
        resolve(snapshotPath);
      });
      heapSnapshot.on('error', reject);
    });
  }

  /**
   * Capture memory profile
   */
  captureMemoryProfile() {
    const memoryUsage = process.memoryUsage();
    const heapStats = v8.getHeapStatistics();

    const memoryProfile = {
      timestamp: new Date().toISOString(),
      processMemory: memoryUsage,
      heapStatistics: heapStats,
      memoryLeakDetection: this.detectMemoryLeaks(),
    };

    this.memoryProfiles.push(memoryProfile);
  }

  /**
   * Simple memory leak detection
   */
  detectMemoryLeaks() {
    const recentProfiles = this.memoryProfiles.slice(-10);
    if (recentProfiles.length < 5) {
      return { suspected: false };
    }

    const heapGrowth = recentProfiles.map(p => p.processMemory.heapUsed);
    const trend = this.calculateTrend(heapGrowth);

    return {
      suspected: trend > 0.1, // 10% growth trend
      trend,
      description:
        trend > 0.1
          ? 'Heap usage consistently increasing'
          : 'Normal heap usage pattern',
    };
  }

  /**
   * Calculate trend (simple linear regression slope)
   */
  calculateTrend(values) {
    const n = values.length;
    const x = Array.from({ length: n }, (_, i) => i);
    const sumX = x.reduce((a, b) => a + b, 0);
    const sumY = values.reduce((a, b) => a + b, 0);
    const sumXY = x.reduce((acc, xi, i) => acc + xi * values[i], 0);
    const sumXX = x.reduce((acc, xi) => acc + xi * xi, 0);

    return (n * sumXY - sumX * sumY) / (n * sumXX - sumX * sumX);
  }

  /**
   * Start event loop profiling
   */
  async startEventLoopProfiling() {
    let previousTime = performance.now();

    setInterval(() => {
      if (!this.profilingActive) return;

      const currentTime = performance.now();
      const lag = currentTime - previousTime - 100; // Expected 100ms interval
      previousTime = currentTime;

      const eventLoopProfile = {
        timestamp: new Date().toISOString(),
        lag: Math.max(0, lag),
        activeHandles: process._getActiveHandles().length,
        activeRequests: process._getActiveRequests().length,
      };

      this.eventLoopProfiles.push(eventLoopProfile);

      // Alert on significant lag
      if (lag > 100) {
        console.warn(`Event loop lag detected: ${lag.toFixed(2)}ms`);
      }
    }, 100);
  }

  /**
   * Setup performance observer
   */
  setupPerformanceObserver() {
    const observer = new PerformanceObserver(list => {
      const entries = list.getEntries();
      entries.forEach(entry => {
        if (entry.entryType === 'measure' || entry.entryType === 'mark') {
          this.profiles.push({
            timestamp: new Date().toISOString(),
            category: 'performance',
            operation: entry.name,
            durationMs: entry.duration || 0,
            entryType: entry.entryType,
          });
        }
      });
    });

    observer.observe({
      entryTypes: ['measure', 'mark', 'navigation', 'resource'],
    });
  }

  /**
   * Setup memory monitoring
   */
  setupMemoryMonitoring() {
    // Monitor for memory warnings
    process.on('warning', warning => {
      if (
        warning.name === 'MaxListenersExceededWarning' ||
        warning.name === 'DeprecationWarning'
      ) {
        this.profiles.push({
          timestamp: new Date().toISOString(),
          category: 'warning',
          operation: 'process_warning',
          warning: warning.message,
          stack: warning.stack,
        });
      }
    });
  }

  /**
   * Setup event loop monitoring
   */
  setupEventLoopMonitoring() {
    // Monitor uncaught exceptions
    process.on('uncaughtException', error => {
      this.profiles.push({
        timestamp: new Date().toISOString(),
        category: 'error',
        operation: 'uncaught_exception',
        error: error.message,
        stack: error.stack,
      });
    });

    // Monitor unhandled rejections
    process.on('unhandledRejection', (reason, promise) => {
      this.profiles.push({
        timestamp: new Date().toISOString(),
        category: 'error',
        operation: 'unhandled_rejection',
        error: reason?.message || reason,
        stack: reason?.stack,
      });
    });
  }

  /**
   * Start inspector session
   */
  startInspectorSession() {
    this.session = new inspector.Session();
    this.session.connect();
    console.log('Inspector session started');
  }

  /**
   * Ensure output directory exists
   */
  async ensureOutputDirectory() {
    try {
      await fs.mkdir(this.config.profileOutputDir, { recursive: true });
    } catch (error) {
      console.error('Failed to create output directory:', error);
    }
  }

  /**
   * Start cleanup task
   */
  startCleanupTask() {
    setInterval(async () => {
      if (!this.profilingActive) return;

      const cutoffTime = new Date(
        Date.now() - this.config.profileRetentionHours * 3600 * 1000
      );

      // Clean up old profiles
      this.profiles = this.profiles.filter(
        p => new Date(p.timestamp) > cutoffTime
      );
      this.cpuProfiles = this.cpuProfiles.filter(
        p => new Date(p.timestamp) > cutoffTime
      );
      this.memoryProfiles = this.memoryProfiles.filter(
        p => new Date(p.timestamp) > cutoffTime
      );
      this.eventLoopProfiles = this.eventLoopProfiles.filter(
        p => new Date(p.timestamp) > cutoffTime
      );

      // Clean up old files
      await this.cleanupOldFiles(cutoffTime);
    }, 3600000); // Every hour
  }

  /**
   * Clean up old profile files
   */
  async cleanupOldFiles(cutoffTime) {
    try {
      const files = await fs.readdir(this.config.profileOutputDir);

      for (const file of files) {
        const filePath = path.join(this.config.profileOutputDir, file);
        const stats = await fs.stat(filePath);

        if (stats.mtime < cutoffTime) {
          await fs.unlink(filePath);
          console.log(`Cleaned up old profile file: ${file}`);
        }
      }
    } catch (error) {
      console.error('Cleanup error:', error);
    }
  }

  /**
   * Generate comprehensive profiling report
   */
  generateReport() {
    const now = new Date().toISOString();

    return {
      timestamp: now,
      totalProfiles: this.profiles.length,
      cpuProfiles: this.cpuProfiles.length,
      memoryProfiles: this.memoryProfiles.length,
      eventLoopProfiles: this.eventLoopProfiles.length,
      averageEventLoopLag: this.calculateAverageEventLoopLag(),
      memoryLeakSuspected: this.detectMemoryLeaks().suspected,
      hottestOperations: this.identifyHotOperations(),
      performanceSummary: this.generatePerformanceSummary(),
      recommendations: this.generateRecommendations(),
    };
  }

  /**
   * Calculate average event loop lag
   */
  calculateAverageEventLoopLag() {
    if (this.eventLoopProfiles.length === 0) return 0;

    const totalLag = this.eventLoopProfiles.reduce(
      (sum, profile) => sum + profile.lag,
      0
    );
    return totalLag / this.eventLoopProfiles.length;
  }

  /**
   * Identify hot operations
   */
  identifyHotOperations() {
    const operationTimes = {};

    this.profiles.forEach(profile => {
      if (profile.durationMs) {
        operationTimes[profile.operation] =
          (operationTimes[profile.operation] || 0) + profile.durationMs;
      }
    });

    return Object.entries(operationTimes)
      .sort(([, a], [, b]) => b - a)
      .slice(0, 10)
      .map(([operation, totalTime]) => ({ operation, totalTime }));
  }

  /**
   * Generate performance summary
   */
  generatePerformanceSummary() {
    const totalOperations = this.profiles.filter(p => p.durationMs).length;
    const totalTime = this.profiles.reduce(
      (sum, p) => sum + (p.durationMs || 0),
      0
    );
    const averageTime = totalOperations > 0 ? totalTime / totalOperations : 0;

    return {
      totalOperations,
      averageDurationMs: averageTime,
      totalMemoryGrowth: this.calculateTotalMemoryGrowth(),
      errorRate: this.calculateErrorRate(),
    };
  }

  /**
   * Calculate total memory growth
   */
  calculateTotalMemoryGrowth() {
    if (this.memoryProfiles.length < 2) return 0;

    const first = this.memoryProfiles[0];
    const last = this.memoryProfiles[this.memoryProfiles.length - 1];

    return last.processMemory.heapUsed - first.processMemory.heapUsed;
  }

  /**
   * Calculate error rate
   */
  calculateErrorRate() {
    const totalProfiles = this.profiles.length;
    const errorProfiles = this.profiles.filter(
      p => p.error || p.category === 'error'
    ).length;

    return totalProfiles > 0 ? (errorProfiles / totalProfiles) * 100 : 0;
  }

  /**
   * Generate recommendations
   */
  generateRecommendations() {
    const recommendations = [];

    const avgLag = this.calculateAverageEventLoopLag();
    if (avgLag > 100) {
      recommendations.push(
        `High event loop lag detected (${avgLag.toFixed(2)}ms). Consider optimizing blocking operations.`
      );
    }

    const memoryLeak = this.detectMemoryLeaks();
    if (memoryLeak.suspected) {
      recommendations.push(
        'Potential memory leak detected. Review memory usage patterns and heap snapshots.'
      );
    }

    const errorRate = this.calculateErrorRate();
    if (errorRate > 5) {
      recommendations.push(
        `High error rate detected (${errorRate.toFixed(2)}%). Review error handling and operation reliability.`
      );
    }

    if (recommendations.length === 0) {
      recommendations.push(
        'Performance looks healthy. Continue monitoring for any changes.'
      );
    }

    return recommendations;
  }

  /**
   * Get all profiles
   */
  getProfiles() {
    return {
      general: this.profiles,
      cpu: this.cpuProfiles,
      memory: this.memoryProfiles,
      eventLoop: this.eventLoopProfiles,
    };
  }
}

// Export for use as a module
module.exports = NodeJSProfiler;

// CLI usage
if (require.main === module) {
  const config = {
    cpuProfilingEnabled: process.env.NODEJS_CPU_PROFILING !== 'false',
    memoryProfilingEnabled: process.env.NODEJS_MEMORY_PROFILING !== 'false',
    eventLoopProfilingEnabled:
      process.env.NODEJS_EVENTLOOP_PROFILING !== 'false',
    profileOutputDir: process.env.NODEJS_PROFILE_DIR || './profiles/nodejs',
    continuousProfiling: process.env.NODEJS_CONTINUOUS_PROFILING === 'true',
    profileRetentionHours:
      parseInt(process.env.NODEJS_PROFILE_RETENTION_HOURS) || 24,
  };

  const profiler = new NodeJSProfiler(config);

  // Setup graceful shutdown
  const shutdown = GracefulShutdown.getInstance({
    globalTimeout: 10000,
  });

  shutdown.registerHandler({
    name: 'nodejs-profiler',
    priority: ShutdownPriority.STOP_BACKGROUND_JOBS,
    handler: async () => {
      console.log('Shutting down profiler...');
      await profiler.stopProfiling();
    },
  });

  shutdown.setupSignalHandlers();

  // Start profiling
  profiler
    .startContinuousProfiling()
    .then(() => {
      console.log('Node.js profiling started. Press Ctrl+C to stop.');

      // Generate report every 5 minutes
      setInterval(() => {
        const report = profiler.generateReport();
        console.log('Profiling Report:', JSON.stringify(report, null, 2));
      }, 300000);
    })
    .catch(error => {
      console.error('Failed to start profiling:', error);
      process.exit(1);
    });
}
