/**
 * Capacity Validation Manager
 *
 * Handles incremental load testing to identify system capacity limits,
 * bottlenecks, and performance characteristics under increasing load.
 */

const { performance } = require('perf_hooks');
const EventEmitter = require('events');

class CapacityValidationManager extends EventEmitter {
  constructor(config = {}) {
    super();

    this.config = {
      baselineCapacity: config.baselineCapacity || 10000,
      targetCapacity: config.targetCapacity || 100000,
      maxCapacity: config.maxCapacity || 200000,
      incrementStrategy: config.incrementStrategy || 'exponential', // linear, exponential, fibonacci, custom
      incrementSize: config.incrementSize || 0.25, // 25% for exponential, fixed amount for linear
      stabilizationTime: config.stabilizationTime || 30, // seconds to wait for stabilization
      maxPhaseFailures: config.maxPhaseFailures || 3, // max consecutive failures before stopping
      successThreshold: config.successThreshold || 0.95, // 95% success rate required
      latencyThreshold: config.latencyThreshold || 200, // ms
      stabilityThreshold: config.stabilityThreshold || 0.1, // 10% variance allowed
      phaseDuration: config.phaseDuration || 60, // seconds per phase
      warmupDuration: config.warmupDuration || 15, // seconds for warmup
    };

    this.state = {
      currentPhase: 0,
      currentCapacity: this.config.baselineCapacity,
      maxAchievedCapacity: 0,
      consecutiveFailures: 0,
      isValidating: false,
      phaseResults: [],
      bottlenecks: [],
      capacityLimitReached: false,
    };

    this.metrics = {
      totalPhases: 0,
      successfulPhases: 0,
      failedPhases: 0,
      averageLatency: 0,
      peakTPS: 0,
      stabilityIndex: 0,
    };
  }

  /**
   * Validate baseline capacity
   */
  async validateBaseline(baselineCapacity, workloadGenerator) {
    console.log(
      `🔍 Validating Baseline Capacity: ${baselineCapacity.toLocaleString()} TPS`
    );

    const baselineConfig = {
      targetTPS: baselineCapacity,
      testDuration: this.config.phaseDuration,
      rampUpTime: this.config.warmupDuration,
    };

    // Configure workload generator for baseline test
    if (workloadGenerator.updateConfig) {
      workloadGenerator.updateConfig(baselineConfig);
    } else {
      // Update config directly for existing generator
      Object.assign(workloadGenerator.config, baselineConfig);
    }

    const startTime = performance.now();
    const results =
      await workloadGenerator.startWorkloadGeneration(baselineCapacity);
    const duration = performance.now() - startTime;

    const analysisResults = this.analyzePhaseResults(
      results,
      baselineCapacity,
      'BASELINE'
    );

    console.log(`   ✅ Baseline Results:`);
    console.log(`      - Achieved TPS: ${analysisResults.achievedTPS}`);
    console.log(`      - Success Rate: ${analysisResults.successRate}`);
    console.log(`      - Average Latency: ${analysisResults.averageLatency}ms`);
    console.log(`      - Stability: ${analysisResults.stabilityRating}`);

    this.state.maxAchievedCapacity = Math.max(
      this.state.maxAchievedCapacity,
      analysisResults.achievedTPS
    );

    return {
      phase: 'BASELINE',
      targetCapacity: baselineCapacity,
      achievedCapacity: analysisResults.achievedTPS,
      successRate: analysisResults.successRate,
      averageLatency: analysisResults.averageLatency,
      stability: analysisResults.stabilityRating,
      passed: analysisResults.passed,
      totalTransactions: results.performanceMetrics.totalTransactions || 0,
      successfulTransactions:
        results.performanceMetrics.successfulTransactions || 0,
      duration: duration / 1000,
    };
  }

  /**
   * Execute incremental capacity testing
   */
  async executeIncrementalTesting(
    startCapacity,
    maxCapacity,
    workloadGenerator,
    bottleneckDetector
  ) {
    console.log(`📈 Starting Incremental Capacity Testing`);
    console.log(`   Strategy: ${this.config.incrementStrategy}`);
    console.log(
      `   Range: ${startCapacity.toLocaleString()} → ${maxCapacity.toLocaleString()} TPS`
    );
    console.log(`   Phase Duration: ${this.config.phaseDuration}s`);
    console.log('');

    this.state.isValidating = true;
    this.state.currentCapacity = startCapacity;
    this.state.consecutiveFailures = 0;
    this.state.phaseResults = [];

    const allBottlenecks = [];

    try {
      while (
        this.state.currentCapacity <= maxCapacity &&
        !this.state.capacityLimitReached
      ) {
        this.state.currentPhase++;

        console.log(
          `🚀 Phase ${this.state.currentPhase}: Testing ${this.state.currentCapacity.toLocaleString()} TPS`
        );

        // Execute capacity validation phase
        const phaseResult = await this.executeCapacityPhase(
          this.state.currentCapacity,
          workloadGenerator,
          bottleneckDetector
        );

        this.state.phaseResults.push(phaseResult);

        // Analyze phase results
        const phaseAnalysis = this.analyzePhaseCompletion(phaseResult);

        console.log(`   📊 Phase ${this.state.currentPhase} Results:`);
        console.log(
          `      - Achieved: ${phaseResult.achievedCapacity.toLocaleString()} TPS (${phaseAnalysis.efficiency}%)`
        );
        console.log(`      - Success Rate: ${phaseResult.successRate}`);
        console.log(`      - Latency: ${phaseResult.averageLatency}ms`);
        console.log(
          `      - Status: ${phaseResult.passed ? '✅ PASSED' : '❌ FAILED'}`
        );

        if (phaseResult.bottlenecks && phaseResult.bottlenecks.length > 0) {
          console.log(
            `      - Bottlenecks: ${phaseResult.bottlenecks.length} detected`
          );
          allBottlenecks.push(...phaseResult.bottlenecks);
        }

        // Update metrics
        this.updateMetrics(phaseResult);

        // Check if phase passed
        if (phaseResult.passed) {
          this.state.consecutiveFailures = 0;
          this.state.maxAchievedCapacity = Math.max(
            this.state.maxAchievedCapacity,
            phaseResult.achievedCapacity
          );

          // Calculate next capacity level
          this.state.currentCapacity = this.calculateNextCapacity(
            this.state.currentCapacity
          );
        } else {
          this.state.consecutiveFailures++;
          console.log(
            `   ⚠️  Phase failed (${this.state.consecutiveFailures}/${this.config.maxPhaseFailures})`
          );

          if (this.state.consecutiveFailures >= this.config.maxPhaseFailures) {
            console.log(
              `   🛑 Capacity limit reached after ${this.config.maxPhaseFailures} consecutive failures`
            );
            this.state.capacityLimitReached = true;
            break;
          }

          // Reduce capacity and try again
          this.state.currentCapacity = Math.floor(
            this.state.currentCapacity * 0.9
          );
          console.log(
            `   🔄 Reducing capacity to ${this.state.currentCapacity.toLocaleString()} TPS`
          );
        }

        // Brief pause between phases
        await this.sleep(5000);
      }

      const summary = this.generateIncrementalSummary(allBottlenecks);

      console.log('');
      console.log('📋 Incremental Testing Summary:');
      console.log('=============================');
      console.log(
        `   Max Capacity Achieved: ${this.state.maxAchievedCapacity.toLocaleString()} TPS`
      );
      console.log(`   Total Phases: ${this.state.phaseResults.length}`);
      console.log(
        `   Successful Phases: ${this.state.phaseResults.filter(p => p.passed).length}`
      );
      console.log(`   Bottlenecks Found: ${allBottlenecks.length}`);
      console.log(
        `   Capacity Limit: ${this.state.capacityLimitReached ? 'REACHED' : 'NOT REACHED'}`
      );

      return summary;
    } finally {
      this.state.isValidating = false;
    }
  }

  /**
   * Execute a single capacity validation phase
   */
  async executeCapacityPhase(
    targetCapacity,
    workloadGenerator,
    bottleneckDetector
  ) {
    const phaseStart = performance.now();

    // Configure workload generator for this phase
    const phaseConfig = {
      targetTPS: targetCapacity,
      testDuration: this.config.phaseDuration,
      rampUpTime: this.config.warmupDuration,
    };

    if (workloadGenerator.updateConfig) {
      workloadGenerator.updateConfig(phaseConfig);
    } else {
      // Update config directly for existing generator
      Object.assign(workloadGenerator.config, phaseConfig);
    }

    // Start bottleneck monitoring
    if (bottleneckDetector) {
      bottleneckDetector.startMonitoring();
    }

    try {
      // Execute workload
      const workloadResults =
        await workloadGenerator.startWorkloadGeneration(targetCapacity);

      // Get bottleneck detection results
      const bottlenecks = bottleneckDetector
        ? await bottleneckDetector.getDetectedBottlenecks()
        : [];

      const phaseDuration = (performance.now() - phaseStart) / 1000;

      // Analyze results
      const analysis = this.analyzePhaseResults(
        workloadResults,
        targetCapacity,
        `PHASE_${this.state.currentPhase}`
      );

      return {
        phase: this.state.currentPhase,
        targetCapacity,
        achievedCapacity: analysis.achievedTPS,
        successRate: analysis.successRate,
        averageLatency: analysis.averageLatency,
        stability: analysis.stabilityRating,
        efficiency: analysis.efficiency,
        passed: analysis.passed,
        bottlenecks,
        duration: phaseDuration,
        workloadResults,
        timestamp: new Date().toISOString(),
      };
    } finally {
      // Stop bottleneck monitoring
      if (bottleneckDetector) {
        bottleneckDetector.stopMonitoring();
      }
    }
  }

  /**
   * Analyze phase results and determine success/failure
   */
  analyzePhaseResults(workloadResults, targetCapacity, phaseName) {
    const metrics = workloadResults.performanceMetrics || {};

    // Extract key metrics
    const achievedTPS = parseFloat(metrics.actualTPS || '0');
    const successRate =
      parseFloat((metrics.successRate || '0%').replace('%', '')) / 100;
    const averageLatency = parseFloat(
      (metrics.averageLatency || '0ms').replace('ms', '')
    );

    // Calculate efficiency
    const efficiency =
      targetCapacity > 0 ? Math.round((achievedTPS / targetCapacity) * 100) : 0;

    // Determine if phase passed
    const tpsAcceptable = achievedTPS >= targetCapacity * 0.8; // 80% of target
    const successRateAcceptable = successRate >= this.config.successThreshold;
    const latencyAcceptable = averageLatency <= this.config.latencyThreshold;

    const passed = tpsAcceptable && successRateAcceptable && latencyAcceptable;

    // Calculate stability rating
    const stabilityRating = this.calculateStabilityRating(workloadResults);

    return {
      phaseName,
      achievedTPS,
      successRate: `${(successRate * 100).toFixed(1)}%`,
      averageLatency: averageLatency.toFixed(1),
      efficiency,
      stabilityRating,
      passed,
      criteria: {
        tpsAcceptable,
        successRateAcceptable,
        latencyAcceptable,
      },
    };
  }

  /**
   * Calculate stability rating based on performance variance
   */
  calculateStabilityRating(workloadResults) {
    // Mock stability calculation - in real implementation, this would analyze
    // variance in TPS, latency, and success rate over time
    const metrics = workloadResults.performanceMetrics || {};
    const successRate = parseFloat(
      (metrics.successRate || '95%').replace('%', '')
    );

    if (successRate >= 98) return 'EXCELLENT';
    if (successRate >= 95) return 'GOOD';
    if (successRate >= 90) return 'FAIR';
    return 'POOR';
  }

  /**
   * Calculate next capacity level based on increment strategy
   */
  calculateNextCapacity(currentCapacity) {
    switch (this.config.incrementStrategy) {
      case 'linear':
        return currentCapacity + this.config.incrementSize * 1000; // Fixed increment

      case 'exponential':
        return Math.floor(currentCapacity * (1 + this.config.incrementSize));

      case 'fibonacci':
        // Simplified fibonacci-like progression
        const fibIncrement = Math.floor(currentCapacity * 0.618); // Golden ratio
        return currentCapacity + Math.max(fibIncrement, 5000);

      case 'aggressive':
        return Math.floor(currentCapacity * 1.5); // 50% jumps

      case 'conservative':
        return Math.floor(currentCapacity * 1.1); // 10% jumps

      default:
        return Math.floor(currentCapacity * (1 + this.config.incrementSize));
    }
  }

  /**
   * Analyze phase completion and determine next steps
   */
  analyzePhaseCompletion(phaseResult) {
    const efficiency =
      phaseResult.targetCapacity > 0
        ? Math.round(
            (phaseResult.achievedCapacity / phaseResult.targetCapacity) * 100
          )
        : 0;

    return {
      efficiency,
      recommendation: this.getPhaseRecommendation(phaseResult),
      shouldContinue: phaseResult.passed && efficiency >= 70,
      bottleneckSeverity: this.assessBottleneckSeverity(
        phaseResult.bottlenecks || []
      ),
    };
  }

  /**
   * Get recommendation based on phase results
   */
  getPhaseRecommendation(phaseResult) {
    if (!phaseResult.passed) {
      if (
        parseFloat(phaseResult.successRate) <
        this.config.successThreshold * 100
      ) {
        return 'IMPROVE_RELIABILITY';
      }
      if (
        parseFloat(phaseResult.averageLatency) > this.config.latencyThreshold
      ) {
        return 'OPTIMIZE_LATENCY';
      }
      return 'SCALE_INFRASTRUCTURE';
    }

    if (phaseResult.achievedCapacity < phaseResult.targetCapacity * 0.9) {
      return 'INCREMENTAL_OPTIMIZATION';
    }

    return 'CONTINUE_SCALING';
  }

  /**
   * Assess bottleneck severity
   */
  assessBottleneckSeverity(bottlenecks) {
    if (bottlenecks.length === 0) return 'NONE';

    const critical = bottlenecks.filter(b => b.severity === 'critical').length;
    const high = bottlenecks.filter(b => b.severity === 'high').length;

    if (critical > 0) return 'CRITICAL';
    if (high > 2) return 'HIGH';
    if (bottlenecks.length > 5) return 'MODERATE';
    return 'LOW';
  }

  /**
   * Update internal metrics
   */
  updateMetrics(phaseResult) {
    this.metrics.totalPhases++;

    if (phaseResult.passed) {
      this.metrics.successfulPhases++;
    } else {
      this.metrics.failedPhases++;
    }

    this.metrics.peakTPS = Math.max(
      this.metrics.peakTPS,
      phaseResult.achievedCapacity
    );

    // Update average latency
    const totalLatency =
      this.metrics.averageLatency * (this.metrics.totalPhases - 1);
    this.metrics.averageLatency =
      (totalLatency + parseFloat(phaseResult.averageLatency)) /
      this.metrics.totalPhases;
  }

  /**
   * Generate incremental testing summary
   */
  generateIncrementalSummary(allBottlenecks) {
    const uniqueBottlenecks = this.deduplicateBottlenecks(allBottlenecks);

    return {
      maxAchievedCapacity: this.state.maxAchievedCapacity,
      totalPhases: this.metrics.totalPhases,
      successfulPhases: this.metrics.successfulPhases,
      failedPhases: this.metrics.failedPhases,
      phaseResults: this.state.phaseResults,
      bottlenecks: uniqueBottlenecks,
      capacityLimitReached: this.state.capacityLimitReached,
      metrics: this.metrics,
      recommendations: this.generateCapacityRecommendations(),
      summary: {
        targetMet: this.state.maxAchievedCapacity >= this.config.targetCapacity,
        efficiency: this.metrics.successfulPhases / this.metrics.totalPhases,
        bottleneckCount: uniqueBottlenecks.length,
        overallGrade: this.calculateOverallGrade(),
      },
    };
  }

  /**
   * Deduplicate bottlenecks by type and component
   */
  deduplicateBottlenecks(bottlenecks) {
    const unique = new Map();

    bottlenecks.forEach(bottleneck => {
      const key = `${bottleneck.type}-${bottleneck.component}`;
      if (!unique.has(key) || bottleneck.severity === 'critical') {
        unique.set(key, bottleneck);
      }
    });

    return Array.from(unique.values());
  }

  /**
   * Generate capacity recommendations
   */
  generateCapacityRecommendations() {
    const recommendations = [];

    if (this.state.maxAchievedCapacity < this.config.targetCapacity) {
      recommendations.push({
        type: 'SCALING',
        priority: 'HIGH',
        message: `Target capacity not achieved. Consider scaling infrastructure.`,
        details: `Achieved: ${this.state.maxAchievedCapacity}, Target: ${this.config.targetCapacity}`,
      });
    }

    if (this.metrics.failedPhases > this.metrics.successfulPhases * 0.3) {
      recommendations.push({
        type: 'RELIABILITY',
        priority: 'HIGH',
        message: 'High failure rate detected. Improve system reliability.',
      });
    }

    if (this.metrics.averageLatency > this.config.latencyThreshold) {
      recommendations.push({
        type: 'PERFORMANCE',
        priority: 'MEDIUM',
        message: 'Average latency exceeds threshold. Optimize response times.',
      });
    }

    return recommendations;
  }

  /**
   * Calculate overall grade
   */
  calculateOverallGrade() {
    const targetMet =
      this.state.maxAchievedCapacity >= this.config.targetCapacity;
    const successRate =
      this.metrics.successfulPhases / this.metrics.totalPhases;
    const efficiency =
      this.state.maxAchievedCapacity / this.config.targetCapacity;

    if (targetMet && successRate >= 0.9 && efficiency >= 1.0) {
      return 'A+ EXCELLENT';
    } else if (targetMet && successRate >= 0.8) {
      return 'A GOOD';
    } else if (efficiency >= 0.8 && successRate >= 0.7) {
      return 'B+ ACCEPTABLE';
    } else if (efficiency >= 0.6) {
      return 'B NEEDS_IMPROVEMENT';
    } else {
      return 'C SIGNIFICANT_ISSUES';
    }
  }

  /**
   * Check if manager is ready
   */
  async isReady() {
    return !this.state.isValidating;
  }

  /**
   * Get current state
   */
  getCurrentState() {
    return {
      ...this.state,
      metrics: this.metrics,
      config: this.config,
    };
  }

  /**
   * Reset manager state
   */
  reset() {
    this.state = {
      currentPhase: 0,
      currentCapacity: this.config.baselineCapacity,
      maxAchievedCapacity: 0,
      consecutiveFailures: 0,
      isValidating: false,
      phaseResults: [],
      bottlenecks: [],
      capacityLimitReached: false,
    };

    this.metrics = {
      totalPhases: 0,
      successfulPhases: 0,
      failedPhases: 0,
      averageLatency: 0,
      peakTPS: 0,
      stabilityIndex: 0,
    };
  }

  /**
   * Utility method for delays
   */
  sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
  }
}

module.exports = CapacityValidationManager;
