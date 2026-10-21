#!/usr/bin/env node

/**
 * Turborepo Cache Performance Monitor
 * Tracks cache hit rates and build performance over time
 */

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const {
  GracefulShutdown,
  ShutdownPriority,
} = require('../backend/shared/graceful-shutdown/index.js');

class TurboCacheMonitor {
  constructor() {
    this.metricsFile = path.join(process.cwd(), '.turbo-metrics.json');
    this.metrics = this.loadMetrics();
  }

  loadMetrics() {
    if (fs.existsSync(this.metricsFile)) {
      try {
        return JSON.parse(fs.readFileSync(this.metricsFile, 'utf8'));
      } catch (error) {
        console.log('Creating new metrics file...');
      }
    }

    return {
      builds: [],
      cacheStats: {
        totalBuilds: 0,
        cacheHits: 0,
        cacheMisses: 0,
        averageBuildTime: 0,
        averageCachedTime: 0,
      },
      lastUpdated: new Date().toISOString(),
    };
  }

  saveMetrics() {
    this.metrics.lastUpdated = new Date().toISOString();
    fs.writeFileSync(this.metricsFile, JSON.stringify(this.metrics, null, 2));
  }

  analyzeBuildOutput(output) {
    const analysis = {
      timestamp: new Date().toISOString(),
      totalTasks: 0,
      cachedTasks: 0,
      fullTasks: 0,
      buildTime: 0,
      cacheHitRate: 0,
    };

    try {
      // Parse turbo output for cache statistics
      const lines = output.split('\n');

      for (const line of lines) {
        // Look for task execution info
        if (line.includes('CACHED')) {
          analysis.cachedTasks++;
        } else if (line.includes('FULL')) {
          analysis.fullTasks++;
        }

        // Extract timing information
        const timeMatch = line.match(/(\d+)ms/);
        if (timeMatch) {
          analysis.buildTime += parseInt(timeMatch[1]);
        }
      }

      analysis.totalTasks = analysis.cachedTasks + analysis.fullTasks;

      if (analysis.totalTasks > 0) {
        analysis.cacheHitRate =
          (analysis.cachedTasks / analysis.totalTasks) * 100;
      }
    } catch (error) {
      console.error('Error analyzing build output:', error.message);
    }

    return analysis;
  }

  runBuild(command = 'build', options = {}) {
    console.log(`🏗️ Running: turbo run ${command}`);

    const startTime = Date.now();
    let output = '';

    try {
      const args = ['turbo', 'run', command];

      if (options.force) args.push('--force');
      if (options.cacheDir) args.push(`--cache-dir=${options.cacheDir}`);
      if (options.summarize) args.push('--summarize');

      output = execSync(args.join(' '), {
        encoding: 'utf8',
        cwd: process.cwd(),
        timeout: 600000, // 10 minute timeout
      });
    } catch (error) {
      console.error('Build failed:', error.message);
      output = error.stdout || error.message;
    }

    const duration = Date.now() - startTime;
    const analysis = this.analyzeBuildOutput(output);
    analysis.buildTime = duration;
    analysis.command = command;
    analysis.options = options;

    return analysis;
  }

  recordBuild(analysis) {
    this.metrics.builds.push(analysis);

    // Update aggregate statistics
    this.metrics.cacheStats.totalBuilds++;

    if (analysis.cacheHitRate > 50) {
      this.metrics.cacheStats.cacheHits++;
    } else {
      this.metrics.cacheStats.cacheMisses++;
    }

    // Calculate averages
    const recentBuilds = this.metrics.builds.slice(-10);
    this.metrics.cacheStats.averageBuildTime =
      recentBuilds.reduce((sum, build) => sum + build.buildTime, 0) /
      recentBuilds.length;

    this.metrics.cacheStats.averageCachedTime =
      recentBuilds
        .filter(build => build.cacheHitRate > 80)
        .reduce((sum, build) => sum + build.buildTime, 0) /
      Math.max(1, recentBuilds.filter(build => build.cacheHitRate > 80).length);

    this.saveMetrics();
  }

  generateReport() {
    const stats = this.metrics.cacheStats;
    const recentBuilds = this.metrics.builds.slice(-5);

    console.log('\n📊 Turborepo Cache Performance Report');
    console.log('=' * 45);
    console.log(`Total Builds: ${stats.totalBuilds}`);
    console.log(`Cache Hits: ${stats.cacheHits}`);
    console.log(`Cache Misses: ${stats.cacheMisses}`);

    if (stats.totalBuilds > 0) {
      const hitRate = (stats.cacheHits / stats.totalBuilds) * 100;
      console.log(`Overall Cache Hit Rate: ${hitRate.toFixed(1)}%`);
    }

    console.log(
      `Average Build Time: ${(stats.averageBuildTime / 1000).toFixed(1)}s`
    );
    console.log(
      `Average Cached Build Time: ${(stats.averageCachedTime / 1000).toFixed(1)}s`
    );

    if (stats.averageBuildTime > 0 && stats.averageCachedTime > 0) {
      const improvement =
        ((stats.averageBuildTime - stats.averageCachedTime) /
          stats.averageBuildTime) *
        100;
      console.log(`Cache Performance Improvement: ${improvement.toFixed(1)}%`);
    }

    console.log('\n🕐 Recent Builds:');
    recentBuilds.forEach((build, index) => {
      const time = new Date(build.timestamp).toLocaleTimeString();
      console.log(
        `  ${index + 1}. ${time} - ${build.command} (${(build.buildTime / 1000).toFixed(1)}s, ${build.cacheHitRate.toFixed(1)}% cached)`
      );
    });

    // Performance recommendations
    this.generateRecommendations();
  }

  generateRecommendations() {
    const stats = this.metrics.cacheStats;
    const recommendations = [];

    if (stats.totalBuilds > 0) {
      const hitRate = (stats.cacheHits / stats.totalBuilds) * 100;

      if (hitRate < 50) {
        recommendations.push(
          'Low cache hit rate detected. Review cache inputs and outputs configuration.'
        );
      } else if (hitRate < 80) {
        recommendations.push(
          'Good cache performance. Consider optimizing cache keys for better hits.'
        );
      } else {
        recommendations.push(
          'Excellent cache performance! Monitor for consistency.'
        );
      }
    }

    if (stats.averageBuildTime > 300000) {
      // > 5 minutes
      recommendations.push(
        'Build times are high. Consider breaking down large tasks or optimizing dependencies.'
      );
    }

    if (recommendations.length > 0) {
      console.log('\n💡 Recommendations:');
      recommendations.forEach((rec, index) => {
        console.log(`  ${index + 1}. ${rec}`);
      });
    }
  }

  benchmark() {
    console.log('🚀 Running Turborepo cache benchmark...');

    // Clean build
    console.log('\nStep 1: Clean build (no cache)');
    const cleanBuild = this.runBuild('build', { force: true });
    this.recordBuild(cleanBuild);

    // Cached build
    console.log('\nStep 2: Cached build');
    const cachedBuild = this.runBuild('build');
    this.recordBuild(cachedBuild);

    // Test build
    console.log('\nStep 3: Test with cache');
    const testBuild = this.runBuild('test');
    this.recordBuild(testBuild);

    this.generateReport();

    return {
      cleanBuild,
      cachedBuild,
      testBuild,
      improvement:
        cleanBuild.buildTime > 0
          ? ((cleanBuild.buildTime - cachedBuild.buildTime) /
              cleanBuild.buildTime) *
            100
          : 0,
    };
  }

  watch() {
    console.log('👀 Starting Turborepo cache monitor (Ctrl+C to stop)...');

    const interval = setInterval(() => {
      const build = this.runBuild('build');
      this.recordBuild(build);

      console.log(
        `Build completed in ${(build.buildTime / 1000).toFixed(1)}s (${build.cacheHitRate.toFixed(1)}% cached)`
      );

      if (this.metrics.builds.length % 5 === 0) {
        this.generateReport();
      }
    }, 60000); // Every minute

    // Store interval reference for cleanup
    this.watchInterval = interval;
  }

  /**
   * Cleanup resources for graceful shutdown
   */
  cleanup() {
    if (this.watchInterval) {
      clearInterval(this.watchInterval);
      this.watchInterval = null;
    }
    console.log('🛑 Cache monitoring stopped');
    this.generateReport();
  }

  exportMetrics(format = 'json') {
    const timestamp = new Date().toISOString().split('T')[0];
    const filename = `turbo-cache-metrics-${timestamp}.${format}`;

    if (format === 'json') {
      fs.writeFileSync(filename, JSON.stringify(this.metrics, null, 2));
    } else if (format === 'csv') {
      const csvData = [
        'timestamp,command,buildTime,totalTasks,cachedTasks,cacheHitRate',
        ...this.metrics.builds.map(
          build =>
            `${build.timestamp},${build.command},${build.buildTime},${build.totalTasks},${build.cachedTasks},${build.cacheHitRate}`
        ),
      ].join('\n');
      fs.writeFileSync(filename, csvData);
    }

    console.log(`📄 Metrics exported to ${filename}`);
    return filename;
  }
}

// CLI interface
if (require.main === module) {
  const monitor = new TurboCacheMonitor();
  const command = process.argv[2];

  switch (command) {
    case 'benchmark':
      monitor.benchmark();
      break;
    case 'watch':
      // Setup graceful shutdown for watch mode
      const shutdown = GracefulShutdown.getInstance({
        globalTimeout: 10000,
      });

      shutdown.registerHandler({
        name: 'turbo-cache-monitor',
        priority: ShutdownPriority.STOP_BACKGROUND_JOBS,
        handler: () => monitor.cleanup(),
      });

      shutdown.setupSignalHandlers();

      monitor.watch();
      break;
    case 'report':
      monitor.generateReport();
      break;
    case 'export':
      const format = process.argv[3] || 'json';
      monitor.exportMetrics(format);
      break;
    default:
      console.log(`
Turborepo Cache Monitor

Usage:
  node turbo-cache-monitor.js <command>

Commands:
  benchmark   Run comprehensive cache benchmark
  watch       Monitor cache performance continuously
  report      Generate performance report
  export      Export metrics (json|csv)

Examples:
  node turbo-cache-monitor.js benchmark
  node turbo-cache-monitor.js export csv
      `);
  }
}

module.exports = TurboCacheMonitor;
