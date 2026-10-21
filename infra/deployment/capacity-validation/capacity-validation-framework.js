/**
 * Capacity Validation Framework for Layer 2 Scaling
 *
 * Main orchestrator for capacity validation and horizontal scalability testing.
 * Integrates with existing PerformanceValidationSuite and provides modular
 * architecture for incremental load testing and dynamic node scaling.
 */

const fs = require('fs');
const path = require('path');
const { performance } = require('perf_hooks');
const EventEmitter = require('events');

// Import existing components
const PerformanceValidationSuite = require('../enterprise-testing/performance-validation-suite');
const EnterpriseWorkloadGenerator = require('../enterprise-testing/enterprise-workload-generator');

// Import new capacity validation components
const CapacityValidationManager = require('./capacity-validation-manager');
const HorizontalScalabilityManager = require('./horizontal-scalability-manager');
const BottleneckDetectionSystem = require('./bottleneck-detection-system');

class CapacityValidationFramework extends EventEmitter {
  constructor(config = {}) {
    super();

    this.config = {
      // Capacity testing configuration
      baselineCapacity: config.baselineCapacity || 10000, // Starting TPS
      targetCapacity: config.targetCapacity || 100000, // Target TPS
      maxCapacity: config.maxCapacity || 200000, // Maximum TPS to test
      loadIncrementStrategy: config.loadIncrementStrategy || 'exponential', // linear, exponential, custom
      loadIncrementSize: config.loadIncrementSize || 0.25, // 25% increments
      stabilizationTime: config.stabilizationTime || 30, // seconds
      maxTestDuration: config.maxTestDuration || 3600, // 1 hour max

      // Scalability testing configuration
      initialNodeCount: config.initialNodeCount || 1,
      maxNodeCount: config.maxNodeCount || 10,
      scaleUpThreshold: config.scaleUpThreshold || 0.8, // 80% capacity utilization
      scaleDownThreshold: config.scaleDownThreshold || 0.4, // 40% capacity utilization
      nodeStartupTime: config.nodeStartupTime || 60, // seconds

      // Bottleneck detection configuration
      monitoringInterval: config.monitoringInterval || 5, // seconds
      cpuThreshold: config.cpuThreshold || 0.85, // 85%
      memoryThreshold: config.memoryThreshold || 0.9, // 90%
      latencyThreshold: config.latencyThreshold || 200, // ms
      errorRateThreshold: config.errorRateThreshold || 0.05, // 5%

      // Integration configuration
      integrationMode: config.integrationMode || 'extend', // extend, replace, standalone
      reportingEnabled: config.reportingEnabled !== false,
      realTimeMonitoring: config.realTimeMonitoring !== false,

      // Logging and debugging
      logLevel: config.logLevel || 'info', // debug, info, warn, error
      logToFile: config.logToFile !== false,
      debugMode: config.debugMode || false,
    };

    this.state = {
      currentPhase: 'INITIALIZING',
      startTime: null,
      endTime: null,
      totalTestDuration: 0,

      // Capacity validation state
      currentCapacity: this.config.baselineCapacity,
      achievedCapacity: 0,
      maxAchievedCapacity: 0,
      capacityValidationResults: [],

      // Scalability state
      currentNodeCount: this.config.initialNodeCount,
      maxNodeCount: 0,
      scalingEvents: [],

      // System state
      bottlenecks: [],
      systemHealth: 'UNKNOWN',
      overallStatus: 'PENDING',
    };

    this.metrics = {
      totalTransactions: 0,
      successfulTransactions: 0,
      failedTransactions: 0,
      averageLatency: 0,
      peakTPS: 0,
      sustainedTPS: 0,
      resourceUtilization: {},
      scalingEfficiency: 0,
      bottleneckCount: 0,
    };

    // Initialize components
    this.capacityValidator = null;
    this.scalabilityManager = null;
    this.bottleneckDetector = null;
    this.performanceSuite = null;
    this.workloadGenerator = null;

    this.initializeLogging();
  }

  /**
   * Initialize the capacity validation framework
   */
  async initialize() {
    this.log('info', 'Initializing Capacity Validation Framework...');
    this.state.currentPhase = 'INITIALIZING';

    try {
      // Initialize components
      await this.initializeComponents();

      // Validate configuration
      await this.validateConfiguration();

      // Set up event listeners
      this.setupEventListeners();

      // Perform pre-validation checks
      await this.performPreValidationChecks();

      this.state.currentPhase = 'READY';
      this.log(
        'info',
        'Capacity Validation Framework initialized successfully'
      );
      this.emit('initialized', { config: this.config, state: this.state });

      return {
        status: 'SUCCESS',
        message: 'Framework initialized successfully',
        config: this.config,
        capabilities: this.getCapabilities(),
      };
    } catch (error) {
      this.state.currentPhase = 'ERROR';
      this.log('error', `Framework initialization failed: ${error.message}`);
      this.emit('error', error);
      throw error;
    }
  }

  /**
   * Execute comprehensive capacity validation and scalability testing
   */
  async executeCapacityValidation() {
    this.log(
      'info',
      'Starting Comprehensive Capacity Validation & Scalability Testing'
    );
    this.log(
      'info',
      '================================================================='
    );
    this.log(
      'info',
      `Target Capacity: ${this.config.targetCapacity.toLocaleString()} TPS`
    );
    this.log(
      'info',
      `Max Test Capacity: ${this.config.maxCapacity.toLocaleString()} TPS`
    );
    this.log(
      'info',
      `Scalability Range: ${this.config.initialNodeCount}-${this.config.maxNodeCount} nodes`
    );
    this.log(
      'info',
      `Load Increment Strategy: ${this.config.loadIncrementStrategy}`
    );
    this.log('info', '');

    this.state.startTime = Date.now();
    this.state.currentPhase = 'EXECUTING';

    try {
      // Phase 1: Baseline Capacity Validation
      await this.executeBaselineValidation();

      // Phase 2: Incremental Capacity Testing
      await this.executeIncrementalCapacityTesting();

      // Phase 3: Horizontal Scalability Testing
      await this.executeHorizontalScalabilityTesting();

      // Phase 4: Bottleneck Analysis and System Limits
      await this.executeBottleneckAnalysis();

      // Phase 5: Integration Validation
      await this.executeIntegrationValidation();

      // Phase 6: Generate comprehensive report
      const report = await this.generateCapacityReport();

      this.state.endTime = Date.now();
      this.state.totalTestDuration = this.state.endTime - this.state.startTime;
      this.state.currentPhase = 'COMPLETED';
      this.state.overallStatus = 'SUCCESS';

      this.log(
        'info',
        'Capacity validation and scalability testing completed successfully'
      );
      this.emit('completed', {
        report,
        metrics: this.metrics,
        state: this.state,
      });

      return report;
    } catch (error) {
      this.state.currentPhase = 'FAILED';
      this.state.overallStatus = 'FAILED';
      this.state.endTime = Date.now();
      this.log('error', `Capacity validation failed: ${error.message}`);
      this.emit('error', error);
      throw error;
    }
  }

  /**
   * Initialize framework components
   */
  async initializeComponents() {
    this.log('debug', 'Initializing framework components...');

    // Initialize capacity validation manager
    this.capacityValidator = new CapacityValidationManager({
      baselineCapacity: this.config.baselineCapacity,
      targetCapacity: this.config.targetCapacity,
      maxCapacity: this.config.maxCapacity,
      incrementStrategy: this.config.loadIncrementStrategy,
      incrementSize: this.config.loadIncrementSize,
      stabilizationTime: this.config.stabilizationTime,
    });

    // Initialize horizontal scalability manager
    this.scalabilityManager = new HorizontalScalabilityManager({
      initialNodeCount: this.config.initialNodeCount,
      maxNodeCount: this.config.maxNodeCount,
      scaleUpThreshold: this.config.scaleUpThreshold,
      scaleDownThreshold: this.config.scaleDownThreshold,
      nodeStartupTime: this.config.nodeStartupTime,
    });

    // Initialize bottleneck detection system
    this.bottleneckDetector = new BottleneckDetectionSystem({
      monitoringInterval: this.config.monitoringInterval,
      cpuThreshold: this.config.cpuThreshold,
      memoryThreshold: this.config.memoryThreshold,
      latencyThreshold: this.config.latencyThreshold,
      errorRateThreshold: this.config.errorRateThreshold,
    });

    // Initialize existing performance suite for integration
    if (this.config.integrationMode === 'extend') {
      this.performanceSuite = new PerformanceValidationSuite({
        targetTPS: this.config.targetCapacity,
        acceptableLatency: this.config.latencyThreshold,
        minimumSuccessRate: 1 - this.config.errorRateThreshold,
      });
    }

    // Initialize workload generator
    this.workloadGenerator = new EnterpriseWorkloadGenerator({
      targetTPS: this.config.baselineCapacity,
      testDuration: 60, // Will be adjusted per test
    });

    this.log('debug', 'All components initialized successfully');
  }

  /**
   * Execute baseline capacity validation
   */
  async executeBaselineValidation() {
    this.log('info', 'Phase 1: Baseline Capacity Validation');
    this.log('info', '=====================================');

    const baselineResults = await this.capacityValidator.validateBaseline(
      this.config.baselineCapacity,
      this.workloadGenerator
    );

    this.state.achievedCapacity = baselineResults.achievedCapacity;
    this.metrics.totalTransactions += baselineResults.totalTransactions;
    this.metrics.successfulTransactions +=
      baselineResults.successfulTransactions;

    this.log(
      'info',
      `Baseline Results: ${baselineResults.achievedCapacity} TPS achieved`
    );
    this.log('info', `Success Rate: ${baselineResults.successRate}`);
    this.log('info', `Average Latency: ${baselineResults.averageLatency}ms`);

    this.emit('baselineCompleted', baselineResults);
    return baselineResults;
  }

  /**
   * Execute incremental capacity testing
   */
  async executeIncrementalCapacityTesting() {
    this.log('info', 'Phase 2: Incremental Capacity Testing');
    this.log('info', '====================================');

    const incrementalResults =
      await this.capacityValidator.executeIncrementalTesting(
        this.config.baselineCapacity,
        this.config.maxCapacity,
        this.workloadGenerator,
        this.bottleneckDetector
      );

    this.state.capacityValidationResults = incrementalResults.phaseResults;
    this.state.maxAchievedCapacity = incrementalResults.maxAchievedCapacity;
    this.metrics.peakTPS = incrementalResults.maxAchievedCapacity;

    // Update metrics
    incrementalResults.phaseResults.forEach(phase => {
      this.metrics.totalTransactions += phase.totalTransactions || 0;
      this.metrics.successfulTransactions += phase.successfulTransactions || 0;
    });

    this.log(
      'info',
      `Max Capacity Achieved: ${incrementalResults.maxAchievedCapacity.toLocaleString()} TPS`
    );
    this.log(
      'info',
      `Bottlenecks Identified: ${incrementalResults.bottlenecks.length}`
    );

    this.emit('incrementalCompleted', incrementalResults);
    return incrementalResults;
  }

  /**
   * Execute horizontal scalability testing
   */
  async executeHorizontalScalabilityTesting() {
    this.log('info', 'Phase 3: Horizontal Scalability Testing');
    this.log('info', '======================================');

    const scalabilityResults =
      await this.scalabilityManager.executeScalabilityTesting(
        this.capacityValidator,
        this.workloadGenerator,
        this.bottleneckDetector
      );

    this.state.scalingEvents = scalabilityResults.scalingEvents;
    this.state.maxNodeCount = scalabilityResults.maxNodeCount;
    this.metrics.scalingEfficiency = scalabilityResults.efficiency;

    this.log('info', `Max Nodes Tested: ${scalabilityResults.maxNodeCount}`);
    this.log(
      'info',
      `Scaling Efficiency: ${scalabilityResults.efficiency.toFixed(1)}%`
    );
    this.log(
      'info',
      `Scaling Events: ${scalabilityResults.scalingEvents.length}`
    );

    this.emit('scalabilityCompleted', scalabilityResults);
    return scalabilityResults;
  }

  /**
   * Execute bottleneck analysis
   */
  async executeBottleneckAnalysis() {
    this.log('info', 'Phase 4: Bottleneck Analysis & System Limits');
    this.log('info', '===========================================');

    const bottleneckResults =
      await this.bottleneckDetector.performComprehensiveAnalysis(
        this.state.capacityValidationResults,
        this.state.scalingEvents
      );

    this.state.bottlenecks = bottleneckResults.bottlenecks;
    this.state.systemHealth = bottleneckResults.systemHealth;
    this.metrics.bottleneckCount = bottleneckResults.bottlenecks.length;

    this.log('info', `System Health: ${bottleneckResults.systemHealth}`);
    this.log(
      'info',
      `Critical Bottlenecks: ${bottleneckResults.criticalBottlenecks}`
    );
    this.log(
      'info',
      `Performance Recommendations: ${bottleneckResults.recommendations.length}`
    );

    this.emit('bottleneckAnalysisCompleted', bottleneckResults);
    return bottleneckResults;
  }

  /**
   * Execute integration validation
   */
  async executeIntegrationValidation() {
    this.log('info', 'Phase 5: Integration Validation');
    this.log('info', '==============================');

    if (this.config.integrationMode === 'extend' && this.performanceSuite) {
      const integrationResults =
        await this.performanceSuite.executePerformanceValidation();

      this.log(
        'info',
        `Integration Test Grade: ${integrationResults.executionSummary.overallGrade}`
      );
      this.log(
        'info',
        `Integration TPS: ${integrationResults.executionSummary.maxTPSAchieved.toLocaleString()}`
      );

      this.emit('integrationCompleted', integrationResults);
      return integrationResults;
    }

    this.log('info', 'Integration validation skipped (standalone mode)');
    return { status: 'SKIPPED', reason: 'Standalone mode' };
  }

  /**
   * Generate comprehensive capacity validation report
   */
  async generateCapacityReport() {
    const timestamp = new Date().toISOString();

    const report = {
      timestamp,
      configuration: this.config,
      executionSummary: {
        totalDuration: this.state.totalTestDuration,
        maxCapacityAchieved: this.state.maxAchievedCapacity,
        targetCapacityMet:
          this.state.maxAchievedCapacity >= this.config.targetCapacity,
        maxNodesUsed: this.state.maxNodeCount,
        scalingEfficiency: this.metrics.scalingEfficiency,
        bottlenecksIdentified: this.metrics.bottleneckCount,
        overallStatus: this.state.overallStatus,
      },
      capacityValidation: {
        baselineCapacity: this.config.baselineCapacity,
        achievedCapacity: this.state.maxAchievedCapacity,
        targetCapacity: this.config.targetCapacity,
        capacityUtilization:
          (this.state.maxAchievedCapacity / this.config.targetCapacity) * 100,
        phaseResults: this.state.capacityValidationResults,
      },
      horizontalScalability: {
        initialNodeCount: this.config.initialNodeCount,
        maxNodeCount: this.state.maxNodeCount,
        scalingEvents: this.state.scalingEvents,
        scalingEfficiency: this.metrics.scalingEfficiency,
      },
      bottleneckAnalysis: {
        systemHealth: this.state.systemHealth,
        bottlenecks: this.state.bottlenecks,
        criticalIssues: this.state.bottlenecks.filter(
          b => b.severity === 'critical'
        ).length,
        recommendations: this.generateRecommendations(),
      },
      performanceMetrics: this.metrics,
      recommendations: this.generateRecommendations(),
      nextSteps: this.generateNextSteps(),
    };

    // Save report
    const reportPath = path.join(
      __dirname,
      'data',
      'capacity-validation-report.json'
    );
    if (!fs.existsSync(path.dirname(reportPath))) {
      fs.mkdirSync(path.dirname(reportPath), { recursive: true });
    }
    fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));

    // Generate executive summary
    this.generateExecutiveSummary(report);

    this.log('info', '');
    this.log('info', 'Capacity Validation Report Generated');
    this.log('info', '===================================');
    this.log(
      'info',
      `Max Capacity: ${report.executionSummary.maxCapacityAchieved.toLocaleString()} TPS`
    );
    this.log(
      'info',
      `Target Met: ${report.executionSummary.targetCapacityMet ? 'YES' : 'NO'}`
    );
    this.log(
      'info',
      `Scaling Efficiency: ${report.executionSummary.scalingEfficiency.toFixed(1)}%`
    );
    this.log(
      'info',
      `System Health: ${report.bottleneckAnalysis.systemHealth}`
    );
    this.log('info', `Report Path: ${reportPath}`);

    return report;
  }

  // Helper methods
  setupEventListeners() {
    this.on('error', error => {
      this.log('error', `Framework error: ${error.message}`);
    });

    this.on('warning', warning => {
      this.log('warn', `Framework warning: ${warning.message || warning}`);
    });
  }

  async validateConfiguration() {
    const issues = [];

    if (this.config.baselineCapacity >= this.config.targetCapacity) {
      issues.push('Baseline capacity must be less than target capacity');
    }

    if (this.config.targetCapacity > this.config.maxCapacity) {
      issues.push('Target capacity cannot exceed maximum capacity');
    }

    if (this.config.initialNodeCount > this.config.maxNodeCount) {
      issues.push('Initial node count cannot exceed maximum node count');
    }

    if (issues.length > 0) {
      throw new Error(`Configuration validation failed: ${issues.join(', ')}`);
    }
  }

  async performPreValidationChecks() {
    // Validate component readiness
    const checks = [
      {
        name: 'Capacity Validator',
        check: () =>
          this.capacityValidator && this.capacityValidator.isReady
            ? this.capacityValidator.isReady()
            : Promise.resolve(true),
      },
      {
        name: 'Scalability Manager',
        check: () =>
          this.scalabilityManager && this.scalabilityManager.isReady
            ? this.scalabilityManager.isReady()
            : Promise.resolve(true),
      },
      {
        name: 'Bottleneck Detector',
        check: () =>
          this.bottleneckDetector && this.bottleneckDetector.isReady
            ? this.bottleneckDetector.isReady()
            : Promise.resolve(true),
      },
      {
        name: 'Workload Generator',
        check: () =>
          this.workloadGenerator && this.workloadGenerator.config
            ? Promise.resolve(true)
            : Promise.resolve(false),
      },
    ];

    for (const check of checks) {
      try {
        await check.check();
        this.log('debug', `Pre-validation check passed: ${check.name}`);
      } catch (error) {
        throw new Error(
          `Pre-validation check failed for ${check.name}: ${error.message}`
        );
      }
    }
  }

  getCapabilities() {
    return {
      capacityTesting: true,
      horizontalScaling: true,
      bottleneckDetection: true,
      realTimeMonitoring: this.config.realTimeMonitoring,
      integration: this.config.integrationMode !== 'standalone',
      maxCapacity: this.config.maxCapacity,
      maxNodes: this.config.maxNodeCount,
    };
  }

  generateRecommendations() {
    const recommendations = [];

    if (this.state.maxAchievedCapacity < this.config.targetCapacity) {
      recommendations.push({
        type: 'CAPACITY',
        priority: 'HIGH',
        message:
          'Target capacity not achieved - consider infrastructure scaling',
      });
    }

    if (this.metrics.scalingEfficiency < 70) {
      recommendations.push({
        type: 'SCALABILITY',
        priority: 'MEDIUM',
        message: 'Scaling efficiency below 70% - optimize node orchestration',
      });
    }

    if (this.metrics.bottleneckCount > 5) {
      recommendations.push({
        type: 'BOTTLENECK',
        priority: 'HIGH',
        message: 'Multiple bottlenecks detected - prioritize resolution',
      });
    }

    return recommendations;
  }

  generateNextSteps() {
    const nextSteps = [];

    if (this.state.overallStatus === 'SUCCESS') {
      nextSteps.push('Proceed with production capacity planning');
      nextSteps.push('Implement automated scaling policies');
    } else {
      nextSteps.push('Address identified bottlenecks');
      nextSteps.push('Re-run capacity validation after optimizations');
    }

    return nextSteps;
  }

  generateExecutiveSummary(report) {
    const summaryPath = path.join(
      __dirname,
      'data',
      'capacity-validation-executive-summary.md'
    );
    const summary = `# Capacity Validation & Scalability Testing - Executive Summary

**Date:** ${new Date().toLocaleDateString()}
**Duration:** ${Math.round(report.executionSummary.totalDuration / 1000 / 60)} minutes

## Key Results
- **Peak Capacity:** ${report.executionSummary.maxCapacityAchieved.toLocaleString()} TPS
- **Target Achievement:** ${report.executionSummary.targetCapacityMet ? 'ACHIEVED' : 'NOT ACHIEVED'}
- **Scaling Efficiency:** ${report.executionSummary.scalingEfficiency.toFixed(1)}%
- **System Health:** ${report.bottleneckAnalysis.systemHealth}

## Scalability Analysis
- **Max Nodes Utilized:** ${report.executionSummary.maxNodesUsed}
- **Scaling Events:** ${report.horizontalScalability.scalingEvents.length}
- **Critical Bottlenecks:** ${report.bottleneckAnalysis.criticalIssues}

## Recommendations
${report.recommendations.map(r => `- ${r.message}`).join('\n')}

## Next Steps
${report.nextSteps.map(s => `- ${s}`).join('\n')}
`;

    fs.writeFileSync(summaryPath, summary);
  }

  initializeLogging() {
    this.logFile = path.join(
      __dirname,
      'logs',
      `capacity-validation-${Date.now()}.log`
    );
    if (this.config.logToFile && !fs.existsSync(path.dirname(this.logFile))) {
      fs.mkdirSync(path.dirname(this.logFile), { recursive: true });
    }
  }

  log(level, message) {
    const timestamp = new Date().toISOString();
    const logMessage = `[${timestamp}] [${level.toUpperCase()}] ${message}`;

    if (
      level === 'error' ||
      this.config.logLevel === 'debug' ||
      (this.config.logLevel === 'info' &&
        ['info', 'warn', 'error'].includes(level))
    ) {
      console.log(logMessage);
    }

    if (this.config.logToFile) {
      fs.appendFileSync(this.logFile, logMessage + '\n');
    }
  }
}

// Execute if run directly
if (require.main === module) {
  const framework = new CapacityValidationFramework({
    targetCapacity: 100000,
    maxCapacity: 200000,
    maxNodeCount: 5,
    debugMode: true,
  });

  framework
    .initialize()
    .then(() => framework.executeCapacityValidation())
    .then(report => {
      console.log('\nCapacity validation completed successfully');
      process.exit(0);
    })
    .catch(error => {
      console.error('Capacity validation failed:', error.message);
      process.exit(1);
    });
}

module.exports = CapacityValidationFramework;
