/**
 * Bottleneck Detection System
 *
 * Real-time monitoring and analysis system that identifies performance bottlenecks,
 * system limitations, and provides actionable insights for capacity optimization.
 */

const { performance } = require('perf_hooks');
const EventEmitter = require('events');

class BottleneckDetectionSystem extends EventEmitter {
  constructor(config = {}) {
    super();

    this.config = {
      // Monitoring configuration
      monitoringInterval: config.monitoringInterval || 5, // seconds
      analysisWindow: config.analysisWindow || 60, // seconds for trend analysis
      alertThreshold: config.alertThreshold || 0.8, // 80% utilization
      criticalThreshold: config.criticalThreshold || 0.95, // 95% utilization

      // Resource thresholds
      cpuThreshold: config.cpuThreshold || 0.85, // 85%
      memoryThreshold: config.memoryThreshold || 0.9, // 90%
      diskThreshold: config.diskThreshold || 0.85, // 85%
      networkThreshold: config.networkThreshold || 0.8, // 80%

      // Performance thresholds
      latencyThreshold: config.latencyThreshold || 200, // ms
      errorRateThreshold: config.errorRateThreshold || 0.05, // 5%
      queueDepthThreshold: config.queueDepthThreshold || 1000, // requests
      connectionThreshold: config.connectionThreshold || 5000, // concurrent connections

      // Database thresholds
      dbConnectionThreshold: config.dbConnectionThreshold || 80, // %
      dbQueryTimeThreshold: config.dbQueryTimeThreshold || 500, // ms
      lockWaitThreshold: config.lockWaitThreshold || 100, // ms

      // Analysis configuration
      trendAnalysisEnabled: config.trendAnalysisEnabled !== false,
      predictiveAnalysis: config.predictiveAnalysis !== false,
      detailedLogging: config.detailedLogging !== false,
    };

    this.state = {
      isMonitoring: false,
      monitoringStartTime: null,
      currentMetrics: {},
      historicalData: [],
      detectedBottlenecks: [],
      activeAlerts: new Map(),

      // Analysis state
      analysisResults: null,
      trendData: {
        cpu: [],
        memory: [],
        latency: [],
        errorRate: [],
        throughput: [],
      },
    };

    this.metrics = {
      totalBottlenecksDetected: 0,
      criticalBottlenecks: 0,
      resolvedBottlenecks: 0,
      averageDetectionTime: 0,
      falsePositiveRate: 0,
    };

    // Monitoring intervals
    this.monitoringTimer = null;
    this.analysisTimer = null;
  }

  /**
   * Start real-time monitoring
   */
  async startMonitoring() {
    if (this.state.isMonitoring) {
      console.log('⚠️  Bottleneck monitoring already active');
      return;
    }

    console.log('🔍 Starting Bottleneck Detection System...');
    console.log(`   Monitoring Interval: ${this.config.monitoringInterval}s`);
    console.log(`   Analysis Window: ${this.config.analysisWindow}s`);
    console.log(`   CPU Threshold: ${this.config.cpuThreshold * 100}%`);
    console.log(`   Memory Threshold: ${this.config.memoryThreshold * 100}%`);
    console.log(`   Latency Threshold: ${this.config.latencyThreshold}ms`);

    this.state.isMonitoring = true;
    this.state.monitoringStartTime = Date.now();
    this.state.detectedBottlenecks = [];
    this.state.activeAlerts.clear();

    // Start monitoring timer
    this.monitoringTimer = setInterval(
      () => this.collectMetrics(),
      this.config.monitoringInterval * 1000
    );

    // Start analysis timer
    this.analysisTimer = setInterval(
      () => this.performTrendAnalysis(),
      this.config.analysisWindow * 1000
    );

    console.log('   ✅ Monitoring started successfully');
    this.emit('monitoringStarted', { timestamp: Date.now() });
  }

  /**
   * Stop monitoring
   */
  async stopMonitoring() {
    if (!this.state.isMonitoring) {
      return;
    }

    console.log('🛑 Stopping Bottleneck Detection System...');

    this.state.isMonitoring = false;

    if (this.monitoringTimer) {
      clearInterval(this.monitoringTimer);
      this.monitoringTimer = null;
    }

    if (this.analysisTimer) {
      clearInterval(this.analysisTimer);
      this.analysisTimer = null;
    }

    // Perform final analysis
    await this.performFinalAnalysis();

    console.log('   ✅ Monitoring stopped');
    this.emit('monitoringStopped', {
      duration: Date.now() - this.state.monitoringStartTime,
      bottlenecksDetected: this.state.detectedBottlenecks.length,
    });
  }

  /**
   * Collect current system metrics
   */
  async collectMetrics() {
    const timestamp = Date.now();

    try {
      // Collect system resource metrics
      const resourceMetrics = await this.collectResourceMetrics();

      // Collect performance metrics
      const performanceMetrics = await this.collectPerformanceMetrics();

      // Collect database metrics
      const databaseMetrics = await this.collectDatabaseMetrics();

      // Collect network metrics
      const networkMetrics = await this.collectNetworkMetrics();

      const currentMetrics = {
        timestamp,
        resources: resourceMetrics,
        performance: performanceMetrics,
        database: databaseMetrics,
        network: networkMetrics,
      };

      this.state.currentMetrics = currentMetrics;
      this.state.historicalData.push(currentMetrics);

      // Keep only recent history (last hour)
      const hourAgo = timestamp - 60 * 60 * 1000;
      this.state.historicalData = this.state.historicalData.filter(
        data => data.timestamp > hourAgo
      );

      // Analyze for bottlenecks
      await this.analyzeMetricsForBottlenecks(currentMetrics);
    } catch (error) {
      console.log(`   ⚠️  Metrics collection error: ${error.message}`);
    }
  }

  /**
   * Collect system resource metrics
   */
  async collectResourceMetrics() {
    // Simulate realistic resource monitoring
    // In production, this would integrate with system monitoring tools

    const baseLoad = 0.3 + Math.random() * 0.4; // 30-70% base load
    const variance = (Math.random() - 0.5) * 0.1; // ±5% variance

    return {
      cpu: {
        usage: Math.min(0.98, baseLoad + variance),
        cores: 8,
        loadAverage: [1.2, 1.4, 1.6],
        processes: 156,
      },
      memory: {
        used: Math.min(0.95, baseLoad * 1.1 + variance),
        available: 16 * 1024, // 16GB
        cached: 2.1 * 1024, // 2.1GB
        buffers: 0.5 * 1024, // 0.5GB
        swapUsed: 0.02,
      },
      disk: {
        usage: 0.65 + variance * 0.5,
        readIOPS: 120 + Math.random() * 80,
        writeIOPS: 45 + Math.random() * 35,
        readLatency: 5 + Math.random() * 10,
        writeLatency: 12 + Math.random() * 15,
      },
      network: {
        bytesIn: 1024 * 1024 * (50 + Math.random() * 100), // 50-150 MB/s
        bytesOut: 1024 * 1024 * (30 + Math.random() * 60), // 30-90 MB/s
        packetsIn: 5000 + Math.random() * 3000,
        packetsOut: 3500 + Math.random() * 2000,
        errors: Math.floor(Math.random() * 5),
      },
    };
  }

  /**
   * Collect performance metrics
   */
  async collectPerformanceMetrics() {
    // Simulate performance metrics
    const baseLatency = 50 + Math.random() * 100; // 50-150ms base
    const errorRate = Math.random() * 0.03; // 0-3% error rate

    return {
      latency: {
        average: baseLatency,
        p50: baseLatency * 0.8,
        p95: baseLatency * 1.5,
        p99: baseLatency * 2.2,
        max: baseLatency * 3.0,
      },
      throughput: {
        requestsPerSecond: 2000 + Math.random() * 8000,
        transactionsPerSecond: 1500 + Math.random() * 6000,
        bytesPerSecond: 1024 * 1024 * (10 + Math.random() * 40),
      },
      errors: {
        rate: errorRate,
        total: Math.floor(errorRate * 10000),
        http4xx: Math.floor(errorRate * 7000),
        http5xx: Math.floor(errorRate * 3000),
        timeouts: Math.floor(errorRate * 500),
      },
      connections: {
        active: 800 + Math.random() * 1200,
        idle: 200 + Math.random() * 300,
        waiting: Math.floor(Math.random() * 50),
      },
      queues: {
        depth: Math.floor(Math.random() * 200),
        processing: Math.floor(Math.random() * 50),
        waiting: Math.floor(Math.random() * 150),
      },
    };
  }

  /**
   * Collect database metrics
   */
  async collectDatabaseMetrics() {
    return {
      connections: {
        active: 45 + Math.random() * 35,
        idle: 15 + Math.random() * 25,
        max: 100,
        utilization: (45 + Math.random() * 35) / 100,
      },
      queries: {
        activeQueries: Math.floor(Math.random() * 20),
        avgQueryTime: 25 + Math.random() * 75,
        slowQueries: Math.floor(Math.random() * 5),
        locksWaiting: Math.floor(Math.random() * 3),
      },
      storage: {
        size: 124.5, // GB
        growth: 0.1, // GB/day
        fragmentation: 0.05 + Math.random() * 0.03,
      },
      cache: {
        hitRatio: 0.92 + Math.random() * 0.06,
        size: 2048, // MB
        usage: 0.75 + Math.random() * 0.15,
      },
    };
  }

  /**
   * Collect network metrics
   */
  async collectNetworkMetrics() {
    return {
      bandwidth: {
        inbound: 85 + Math.random() * 30, // % of capacity
        outbound: 65 + Math.random() * 25, // % of capacity
        maxCapacity: 1000, // Mbps
      },
      latency: {
        internal: 1 + Math.random() * 3, // ms
        external: 15 + Math.random() * 10, // ms
        dns: 5 + Math.random() * 5, // ms
      },
      connections: {
        established: 450 + Math.random() * 200,
        timeWait: 50 + Math.random() * 30,
        closeWait: 10 + Math.random() * 10,
      },
    };
  }

  /**
   * Analyze metrics for bottlenecks
   */
  async analyzeMetricsForBottlenecks(metrics) {
    const bottlenecks = [];

    // CPU bottleneck analysis
    if (metrics.resources.cpu.usage > this.config.cpuThreshold) {
      bottlenecks.push({
        type: 'CPU',
        severity:
          metrics.resources.cpu.usage > this.config.criticalThreshold
            ? 'critical'
            : 'high',
        component: 'System CPU',
        description: `CPU utilization at ${(metrics.resources.cpu.usage * 100).toFixed(1)}%`,
        currentValue: metrics.resources.cpu.usage,
        threshold: this.config.cpuThreshold,
        impact: 'Performance degradation, increased latency',
        recommendation: 'Scale CPU resources or optimize workload distribution',
      });
    }

    // Memory bottleneck analysis
    if (metrics.resources.memory.used > this.config.memoryThreshold) {
      bottlenecks.push({
        type: 'MEMORY',
        severity:
          metrics.resources.memory.used > this.config.criticalThreshold
            ? 'critical'
            : 'high',
        component: 'System Memory',
        description: `Memory utilization at ${(metrics.resources.memory.used * 100).toFixed(1)}%`,
        currentValue: metrics.resources.memory.used,
        threshold: this.config.memoryThreshold,
        impact: 'Memory pressure, potential swapping, reduced performance',
        recommendation: 'Increase memory allocation or optimize memory usage',
      });
    }

    // Latency bottleneck analysis
    if (metrics.performance.latency.average > this.config.latencyThreshold) {
      bottlenecks.push({
        type: 'LATENCY',
        severity:
          metrics.performance.latency.average > this.config.latencyThreshold * 2
            ? 'critical'
            : 'medium',
        component: 'Application Response Time',
        description: `Average latency at ${metrics.performance.latency.average.toFixed(1)}ms`,
        currentValue: metrics.performance.latency.average,
        threshold: this.config.latencyThreshold,
        impact: 'Poor user experience, reduced throughput',
        recommendation:
          'Optimize application code, database queries, or infrastructure',
      });
    }

    // Error rate bottleneck analysis
    if (metrics.performance.errors.rate > this.config.errorRateThreshold) {
      bottlenecks.push({
        type: 'ERROR_RATE',
        severity:
          metrics.performance.errors.rate > this.config.errorRateThreshold * 2
            ? 'critical'
            : 'high',
        component: 'Application Errors',
        description: `Error rate at ${(metrics.performance.errors.rate * 100).toFixed(2)}%`,
        currentValue: metrics.performance.errors.rate,
        threshold: this.config.errorRateThreshold,
        impact: 'Service reliability issues, failed transactions',
        recommendation:
          'Investigate and fix application errors, improve error handling',
      });
    }

    // Database connection bottleneck analysis
    if (
      metrics.database.connections.utilization >
      this.config.dbConnectionThreshold / 100
    ) {
      bottlenecks.push({
        type: 'DATABASE_CONNECTIONS',
        severity:
          metrics.database.connections.utilization > 0.9
            ? 'critical'
            : 'medium',
        component: 'Database Connection Pool',
        description: `DB connection utilization at ${(metrics.database.connections.utilization * 100).toFixed(1)}%`,
        currentValue: metrics.database.connections.utilization,
        threshold: this.config.dbConnectionThreshold / 100,
        impact: 'Database access delays, connection timeouts',
        recommendation:
          'Increase connection pool size or optimize query patterns',
      });
    }

    // Queue depth bottleneck analysis
    if (metrics.performance.queues.depth > this.config.queueDepthThreshold) {
      bottlenecks.push({
        type: 'QUEUE_DEPTH',
        severity:
          metrics.performance.queues.depth > this.config.queueDepthThreshold * 2
            ? 'critical'
            : 'medium',
        component: 'Request Queue',
        description: `Queue depth at ${metrics.performance.queues.depth} requests`,
        currentValue: metrics.performance.queues.depth,
        threshold: this.config.queueDepthThreshold,
        impact: 'Increased wait times, potential request timeouts',
        recommendation:
          'Scale processing capacity or optimize request handling',
      });
    }

    // Network bandwidth bottleneck analysis
    if (
      metrics.network.bandwidth.inbound > this.config.networkThreshold * 100 ||
      metrics.network.bandwidth.outbound > this.config.networkThreshold * 100
    ) {
      bottlenecks.push({
        type: 'NETWORK_BANDWIDTH',
        severity:
          Math.max(
            metrics.network.bandwidth.inbound,
            metrics.network.bandwidth.outbound
          ) > 90
            ? 'critical'
            : 'medium',
        component: 'Network Interface',
        description: `Network utilization: ${metrics.network.bandwidth.inbound.toFixed(1)}% in, ${metrics.network.bandwidth.outbound.toFixed(1)}% out`,
        currentValue:
          Math.max(
            metrics.network.bandwidth.inbound,
            metrics.network.bandwidth.outbound
          ) / 100,
        threshold: this.config.networkThreshold,
        impact: 'Network congestion, increased latency, packet loss',
        recommendation:
          'Upgrade network capacity or optimize data transfer patterns',
      });
    }

    // Process detected bottlenecks
    for (const bottleneck of bottlenecks) {
      await this.processBottleneck(bottleneck, metrics.timestamp);
    }
  }

  /**
   * Process detected bottleneck
   */
  async processBottleneck(bottleneck, timestamp) {
    const bottleneckKey = `${bottleneck.type}-${bottleneck.component}`;

    // Check if this is a new bottleneck or update to existing
    const existingAlert = this.state.activeAlerts.get(bottleneckKey);

    if (existingAlert) {
      // Update existing alert
      existingAlert.lastSeen = timestamp;
      existingAlert.occurrences++;
      existingAlert.currentValue = bottleneck.currentValue;

      // Update severity if worse
      if (
        this.getSeverityLevel(bottleneck.severity) >
        this.getSeverityLevel(existingAlert.severity)
      ) {
        existingAlert.severity = bottleneck.severity;
      }
    } else {
      // Create new alert
      const newAlert = {
        ...bottleneck,
        id: `bottleneck-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
        firstDetected: timestamp,
        lastSeen: timestamp,
        occurrences: 1,
        status: 'active',
      };

      this.state.activeAlerts.set(bottleneckKey, newAlert);
      this.state.detectedBottlenecks.push(newAlert);
      this.metrics.totalBottlenecksDetected++;

      if (bottleneck.severity === 'critical') {
        this.metrics.criticalBottlenecks++;
      }

      console.log(
        `   🚨 Bottleneck detected: ${bottleneck.type} - ${bottleneck.description}`
      );
      this.emit('bottleneckDetected', newAlert);
    }
  }

  /**
   * Perform trend analysis
   */
  async performTrendAnalysis() {
    if (
      !this.config.trendAnalysisEnabled ||
      this.state.historicalData.length < 3
    ) {
      return;
    }

    const recentData = this.state.historicalData.slice(-12); // Last 12 data points

    // Analyze CPU trend
    const cpuTrend = this.analyzeTrend(
      recentData.map(d => d.resources.cpu.usage),
      'CPU Usage'
    );

    // Analyze memory trend
    const memoryTrend = this.analyzeTrend(
      recentData.map(d => d.resources.memory.used),
      'Memory Usage'
    );

    // Analyze latency trend
    const latencyTrend = this.analyzeTrend(
      recentData.map(d => d.performance.latency.average),
      'Average Latency'
    );

    // Analyze error rate trend
    const errorTrend = this.analyzeTrend(
      recentData.map(d => d.performance.errors.rate),
      'Error Rate'
    );

    // Update trend data
    this.state.trendData.cpu.push(cpuTrend);
    this.state.trendData.memory.push(memoryTrend);
    this.state.trendData.latency.push(latencyTrend);
    this.state.trendData.errorRate.push(errorTrend);

    // Keep only recent trends
    for (const key in this.state.trendData) {
      if (this.state.trendData[key].length > 20) {
        this.state.trendData[key] = this.state.trendData[key].slice(-20);
      }
    }

    // Check for concerning trends
    this.checkTrendAlerts([cpuTrend, memoryTrend, latencyTrend, errorTrend]);
  }

  /**
   * Analyze trend for a metric
   */
  analyzeTrend(values, metricName) {
    if (values.length < 3) {
      return { metric: metricName, trend: 'insufficient_data', slope: 0 };
    }

    // Calculate linear regression slope
    const n = values.length;
    const x = Array.from({ length: n }, (_, i) => i);
    const sumX = x.reduce((a, b) => a + b, 0);
    const sumY = values.reduce((a, b) => a + b, 0);
    const sumXY = x.reduce((sum, xi, i) => sum + xi * values[i], 0);
    const sumXX = x.reduce((sum, xi) => sum + xi * xi, 0);

    const slope = (n * sumXY - sumX * sumY) / (n * sumXX - sumX * sumX);
    const intercept = (sumY - slope * sumX) / n;

    // Calculate R-squared for trend strength
    const yMean = sumY / n;
    const ssRes = values.reduce((sum, yi, i) => {
      const predicted = slope * i + intercept;
      return sum + Math.pow(yi - predicted, 2);
    }, 0);
    const ssTot = values.reduce((sum, yi) => sum + Math.pow(yi - yMean, 2), 0);
    const rSquared = 1 - ssRes / ssTot;

    // Determine trend direction
    let trend = 'stable';
    if (Math.abs(slope) > 0.01 && rSquared > 0.6) {
      // Significant trend
      trend = slope > 0 ? 'increasing' : 'decreasing';
    }

    return {
      metric: metricName,
      trend,
      slope,
      rSquared,
      current: values[values.length - 1],
      predicted: slope * n + intercept,
      timestamp: Date.now(),
    };
  }

  /**
   * Check for trend alerts
   */
  checkTrendAlerts(trends) {
    for (const trend of trends) {
      if (trend.trend === 'increasing' && trend.rSquared > 0.7) {
        const concerningMetrics = [
          'CPU Usage',
          'Memory Usage',
          'Average Latency',
          'Error Rate',
        ];

        if (concerningMetrics.includes(trend.metric)) {
          console.log(
            `   📈 Trend alert: ${trend.metric} increasing (slope: ${trend.slope.toFixed(4)})`
          );

          this.emit('trendAlert', {
            metric: trend.metric,
            trend: trend.trend,
            confidence: trend.rSquared,
            slope: trend.slope,
            timestamp: Date.now(),
          });
        }
      }
    }
  }

  /**
   * Perform comprehensive analysis
   */
  async performComprehensiveAnalysis(capacityResults = [], scalingEvents = []) {
    console.log('🔬 Performing Comprehensive Bottleneck Analysis...');

    const analysis = {
      timestamp: Date.now(),
      monitoringDuration: this.state.isMonitoring
        ? Date.now() - this.state.monitoringStartTime
        : 0,

      // Bottleneck summary
      bottlenecks: this.state.detectedBottlenecks,
      criticalBottlenecks: this.state.detectedBottlenecks.filter(
        b => b.severity === 'critical'
      ).length,
      totalBottlenecks: this.state.detectedBottlenecks.length,

      // System health assessment
      systemHealth: this.assessSystemHealth(),

      // Capacity analysis integration
      capacityAnalysis: this.analyzeCapacityBottlenecks(capacityResults),

      // Scaling analysis integration
      scalingAnalysis: this.analyzeScalingBottlenecks(scalingEvents),

      // Recommendations
      recommendations: this.generateBottleneckRecommendations(),

      // Performance indicators
      performanceIndicators: this.calculatePerformanceIndicators(),

      // Trend analysis summary
      trendSummary: this.summarizeTrends(),
    };

    this.state.analysisResults = analysis;

    console.log(
      `   📊 Analysis completed - ${analysis.totalBottlenecks} bottlenecks identified`
    );
    console.log(`   🎯 System Health: ${analysis.systemHealth}`);
    console.log(`   🔴 Critical Issues: ${analysis.criticalBottlenecks}`);

    return analysis;
  }

  /**
   * Perform final analysis when monitoring stops
   */
  async performFinalAnalysis() {
    const finalAnalysis = await this.performComprehensiveAnalysis();

    // Calculate final metrics
    this.metrics.averageDetectionTime = this.calculateAverageDetectionTime();

    console.log('   📋 Final Analysis Summary:');
    console.log(`      - Total Bottlenecks: ${finalAnalysis.totalBottlenecks}`);
    console.log(
      `      - Critical Bottlenecks: ${finalAnalysis.criticalBottlenecks}`
    );
    console.log(`      - System Health: ${finalAnalysis.systemHealth}`);
    console.log(
      `      - Monitoring Duration: ${Math.round(finalAnalysis.monitoringDuration / 1000)}s`
    );

    return finalAnalysis;
  }

  /**
   * Get detected bottlenecks
   */
  async getDetectedBottlenecks() {
    return this.state.detectedBottlenecks;
  }

  /**
   * Assess overall system health
   */
  assessSystemHealth() {
    const criticalBottlenecks = this.state.detectedBottlenecks.filter(
      b => b.severity === 'critical'
    ).length;
    const highBottlenecks = this.state.detectedBottlenecks.filter(
      b => b.severity === 'high'
    ).length;
    const totalBottlenecks = this.state.detectedBottlenecks.length;

    if (criticalBottlenecks > 0) {
      return 'CRITICAL';
    } else if (highBottlenecks > 2) {
      return 'DEGRADED';
    } else if (totalBottlenecks > 5) {
      return 'WARNING';
    } else if (totalBottlenecks > 0) {
      return 'CAUTION';
    } else {
      return 'HEALTHY';
    }
  }

  /**
   * Analyze capacity-related bottlenecks
   */
  analyzeCapacityBottlenecks(capacityResults) {
    const capacityBottlenecks = [];

    for (const result of capacityResults) {
      if (!result.passed) {
        // Correlate capacity failures with detected bottlenecks
        const relatedBottlenecks = this.state.detectedBottlenecks.filter(
          b =>
            result.timestamp &&
            Math.abs(b.firstDetected - new Date(result.timestamp).getTime()) <
              30000
        );

        if (relatedBottlenecks.length > 0) {
          capacityBottlenecks.push({
            phase: result.phase,
            targetCapacity: result.targetCapacity,
            achievedCapacity: result.achievedCapacity,
            relatedBottlenecks: relatedBottlenecks.map(b => ({
              type: b.type,
              severity: b.severity,
              description: b.description,
            })),
          });
        }
      }
    }

    return {
      bottlenecksFound: capacityBottlenecks.length,
      details: capacityBottlenecks,
      impact: this.assessCapacityImpact(capacityBottlenecks),
    };
  }

  /**
   * Analyze scaling-related bottlenecks
   */
  analyzeScalingBottlenecks(scalingEvents) {
    const scalingBottlenecks = [];

    for (const event of scalingEvents) {
      if (event.type === 'scale-up') {
        // Check if scaling helped resolve bottlenecks
        const beforeBottlenecks = this.state.detectedBottlenecks.filter(
          b => b.firstDetected < event.timestamp
        ).length;

        const afterBottlenecks = this.state.detectedBottlenecks.filter(
          b =>
            b.firstDetected > event.timestamp &&
            b.firstDetected < event.timestamp + 60000 // Within 1 minute
        ).length;

        if (afterBottlenecks < beforeBottlenecks) {
          scalingBottlenecks.push({
            event: 'scale-up-effective',
            timestamp: event.timestamp,
            bottlenecksResolved: beforeBottlenecks - afterBottlenecks,
            nodeCount: event.nodeCount,
          });
        }
      }
    }

    return {
      effectiveScalingEvents: scalingBottlenecks.length,
      details: scalingBottlenecks,
      scalingEffectiveness: this.calculateScalingEffectiveness(
        scalingBottlenecks,
        scalingEvents
      ),
    };
  }

  /**
   * Generate bottleneck recommendations
   */
  generateBottleneckRecommendations() {
    const recommendations = [];
    const bottleneckTypes = {};

    // Categorize bottlenecks by type
    for (const bottleneck of this.state.detectedBottlenecks) {
      if (!bottleneckTypes[bottleneck.type]) {
        bottleneckTypes[bottleneck.type] = [];
      }
      bottleneckTypes[bottleneck.type].push(bottleneck);
    }

    // Generate type-specific recommendations
    for (const [type, bottlenecks] of Object.entries(bottleneckTypes)) {
      const criticalCount = bottlenecks.filter(
        b => b.severity === 'critical'
      ).length;
      const highCount = bottlenecks.filter(b => b.severity === 'high').length;

      switch (type) {
        case 'CPU':
          recommendations.push({
            type: 'INFRASTRUCTURE',
            priority: criticalCount > 0 ? 'CRITICAL' : 'HIGH',
            category: 'CPU Optimization',
            message: `CPU bottlenecks detected (${criticalCount} critical, ${highCount} high)`,
            actions: [
              'Scale CPU resources vertically or horizontally',
              'Optimize CPU-intensive operations',
              'Implement CPU-efficient algorithms',
              'Consider workload distribution',
            ],
          });
          break;

        case 'MEMORY':
          recommendations.push({
            type: 'INFRASTRUCTURE',
            priority: criticalCount > 0 ? 'CRITICAL' : 'HIGH',
            category: 'Memory Optimization',
            message: `Memory bottlenecks detected (${criticalCount} critical, ${highCount} high)`,
            actions: [
              'Increase memory allocation',
              'Optimize memory usage patterns',
              'Implement memory pooling',
              'Review garbage collection settings',
            ],
          });
          break;

        case 'LATENCY':
          recommendations.push({
            type: 'PERFORMANCE',
            priority: 'HIGH',
            category: 'Latency Optimization',
            message: `High latency detected in ${bottlenecks.length} components`,
            actions: [
              'Optimize database queries',
              'Implement caching strategies',
              'Reduce network round trips',
              'Profile and optimize slow code paths',
            ],
          });
          break;

        case 'DATABASE_CONNECTIONS':
          recommendations.push({
            type: 'DATABASE',
            priority: 'MEDIUM',
            category: 'Database Optimization',
            message: 'Database connection pool pressure detected',
            actions: [
              'Increase connection pool size',
              'Optimize query patterns',
              'Implement connection pooling',
              'Review transaction handling',
            ],
          });
          break;
      }
    }

    return recommendations;
  }

  /**
   * Calculate performance indicators
   */
  calculatePerformanceIndicators() {
    const indicators = {
      bottleneckDensity:
        this.state.detectedBottlenecks.length /
        (this.state.historicalData.length || 1),
      criticalityRatio:
        this.state.detectedBottlenecks.filter(b => b.severity === 'critical')
          .length / (this.state.detectedBottlenecks.length || 1),
      resolutionTime: this.calculateAverageResolutionTime(),
      systemStability: this.calculateSystemStability(),
      performanceScore: this.calculatePerformanceScore(),
    };

    return indicators;
  }

  /**
   * Summarize trends
   */
  summarizeTrends() {
    const summary = {};

    for (const [metric, trends] of Object.entries(this.state.trendData)) {
      if (trends.length > 0) {
        const latestTrend = trends[trends.length - 1];
        summary[metric] = {
          direction: latestTrend.trend,
          strength: latestTrend.rSquared,
          slope: latestTrend.slope,
          concern:
            latestTrend.trend === 'increasing' && latestTrend.rSquared > 0.7,
        };
      }
    }

    return summary;
  }

  // Helper methods
  getSeverityLevel(severity) {
    const levels = { low: 1, medium: 2, high: 3, critical: 4 };
    return levels[severity] || 0;
  }

  calculateAverageDetectionTime() {
    // Simulate detection time calculation
    return 5.2; // seconds
  }

  calculateAverageResolutionTime() {
    // Simulate resolution time calculation
    return 45.7; // seconds
  }

  calculateSystemStability() {
    const totalMetrics = this.state.historicalData.length;
    const metricsWithBottlenecks = this.state.detectedBottlenecks.length;

    return Math.max(0, 100 - (metricsWithBottlenecks / totalMetrics) * 100);
  }

  calculatePerformanceScore() {
    const health = this.assessSystemHealth();
    const scores = {
      HEALTHY: 95,
      CAUTION: 85,
      WARNING: 70,
      DEGRADED: 50,
      CRITICAL: 25,
    };

    return scores[health] || 0;
  }

  assessCapacityImpact(capacityBottlenecks) {
    if (capacityBottlenecks.length === 0) return 'NONE';
    if (capacityBottlenecks.length >= 3) return 'HIGH';
    if (capacityBottlenecks.length >= 2) return 'MEDIUM';
    return 'LOW';
  }

  calculateScalingEffectiveness(scalingBottlenecks, allEvents) {
    if (allEvents.length === 0) return 0;
    return (scalingBottlenecks.length / allEvents.length) * 100;
  }

  /**
   * Check if system is ready
   */
  async isReady() {
    return true; // Always ready for monitoring
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
}

module.exports = BottleneckDetectionSystem;
