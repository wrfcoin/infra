#!/usr/bin/env node

/**
 * Test Analytics Processor
 *
 * Processes test execution data, calculates trends, detects regressions,
 * and generates comprehensive analytics for the WRFCoin testing system.
 */

const fs = require('fs-extra');
const path = require('path');
const moment = require('moment');
const { Client } = require('pg');
const { createClient } = require('redis');
const winston = require('winston');
const yargs = require('yargs/yargs');
const { hideBin } = require('yargs/helpers');

// Configure logging
const logger = winston.createLogger({
  level: 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.errors({ stack: true }),
    winston.format.json()
  ),
  transports: [
    new winston.transports.File({
      filename: 'logs/test-analytics-error.log',
      level: 'error',
    }),
    new winston.transports.File({ filename: 'logs/test-analytics.log' }),
    new winston.transports.Console({
      format: winston.format.combine(
        winston.format.colorize(),
        winston.format.simple()
      ),
    }),
  ],
});

class TestAnalyticsProcessor {
  constructor(config) {
    this.config = {
      database: {
        host: process.env.DATABASE_HOST || 'localhost',
        port: process.env.DATABASE_PORT || 5432,
        database: process.env.DATABASE_NAME || 'wrfcoin_analytics',
        username: process.env.DATABASE_USERNAME || 'postgres',
        password: process.env.DATABASE_PASSWORD || 'postgres',
      },
      redis: {
        url: process.env.REDIS_URL || 'redis://localhost:6379',
      },
      retention: {
        rawData: 90, // days
        aggregated: 365, // days
        trends: 730, // days
      },
      thresholds: {
        responseTime: {
          warning: 300, // ms
          critical: 500, // ms
        },
        errorRate: {
          warning: 0.01, // 1%
          critical: 0.05, // 5%
        },
        availability: {
          warning: 0.99, // 99%
          critical: 0.95, // 95%
        },
        regression: {
          minor: 0.1, // 10% degradation
          major: 0.25, // 25% degradation
          critical: 0.5, // 50% degradation
        },
      },
      ...config,
    };

    this.pgClient = null;
    this.redisClient = null;
  }

  async initialize() {
    try {
      // Initialize PostgreSQL connection
      this.pgClient = new Client(this.config.database);
      await this.pgClient.connect();
      logger.info('Connected to PostgreSQL database');

      // Initialize Redis connection
      this.redisClient = createClient({ url: this.config.redis.url });
      await this.redisClient.connect();
      logger.info('Connected to Redis cache');

      // Create necessary tables
      await this.createTables();

      logger.info('Test Analytics Processor initialized successfully');
    } catch (error) {
      logger.error('Failed to initialize Test Analytics Processor', error);
      throw error;
    }
  }

  async createTables() {
    const schemas = [
      `CREATE TABLE IF NOT EXISTS test_executions (
        id SERIAL PRIMARY KEY,
        test_id VARCHAR(255) NOT NULL,
        test_name VARCHAR(255) NOT NULL,
        test_type VARCHAR(100) NOT NULL,
        test_suite VARCHAR(255),
        status VARCHAR(50) NOT NULL,
        started_at TIMESTAMP NOT NULL,
        completed_at TIMESTAMP,
        duration_ms INTEGER,
        browser VARCHAR(50),
        environment VARCHAR(50),
        commit_hash VARCHAR(40),
        branch VARCHAR(255),
        build_number VARCHAR(50),
        metadata JSONB,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )`,

      `CREATE TABLE IF NOT EXISTS test_metrics (
        id SERIAL PRIMARY KEY,
        execution_id INTEGER REFERENCES test_executions(id),
        metric_name VARCHAR(255) NOT NULL,
        metric_value DECIMAL(12,4),
        metric_unit VARCHAR(50),
        labels JSONB,
        timestamp TIMESTAMP NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )`,

      `CREATE TABLE IF NOT EXISTS performance_baselines (
        id SERIAL PRIMARY KEY,
        test_name VARCHAR(255) NOT NULL,
        metric_name VARCHAR(255) NOT NULL,
        baseline_value DECIMAL(12,4) NOT NULL,
        confidence_interval DECIMAL(8,4),
        sample_size INTEGER,
        calculated_at TIMESTAMP NOT NULL,
        valid_until TIMESTAMP,
        environment VARCHAR(50),
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(test_name, metric_name, environment)
      )`,

      `CREATE TABLE IF NOT EXISTS regression_detections (
        id SERIAL PRIMARY KEY,
        execution_id INTEGER REFERENCES test_executions(id),
        test_name VARCHAR(255) NOT NULL,
        metric_name VARCHAR(255) NOT NULL,
        baseline_value DECIMAL(12,4),
        actual_value DECIMAL(12,4),
        regression_percentage DECIMAL(8,4),
        severity VARCHAR(50) NOT NULL,
        detected_at TIMESTAMP NOT NULL,
        acknowledged BOOLEAN DEFAULT FALSE,
        acknowledged_by VARCHAR(255),
        acknowledged_at TIMESTAMP,
        resolution VARCHAR(50),
        resolution_notes TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )`,

      `CREATE TABLE IF NOT EXISTS quality_trends (
        id SERIAL PRIMARY KEY,
        date DATE NOT NULL,
        test_type VARCHAR(100),
        total_tests INTEGER NOT NULL,
        passed_tests INTEGER NOT NULL,
        failed_tests INTEGER NOT NULL,
        skipped_tests INTEGER NOT NULL,
        avg_duration_ms DECIMAL(10,2),
        total_duration_ms BIGINT,
        flaky_tests INTEGER DEFAULT 0,
        new_tests INTEGER DEFAULT 0,
        regression_count INTEGER DEFAULT 0,
        quality_score DECIMAL(4,2),
        environment VARCHAR(50),
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(date, test_type, environment)
      )`,

      `CREATE TABLE IF NOT EXISTS flaky_test_tracking (
        id SERIAL PRIMARY KEY,
        test_name VARCHAR(255) NOT NULL,
        test_type VARCHAR(100),
        failure_count INTEGER DEFAULT 0,
        success_count INTEGER DEFAULT 0,
        total_runs INTEGER DEFAULT 0,
        flakiness_score DECIMAL(4,3),
        first_flaky_at TIMESTAMP,
        last_flaky_at TIMESTAMP,
        consecutive_passes INTEGER DEFAULT 0,
        environments TEXT[],
        failure_patterns JSONB,
        is_quarantined BOOLEAN DEFAULT FALSE,
        quarantined_at TIMESTAMP,
        quarantined_by VARCHAR(255),
        notes TEXT,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(test_name, test_type)
      )`,
    ];

    for (const schema of schemas) {
      await this.pgClient.query(schema);
    }

    // Create indexes for better performance
    const indexes = [
      'CREATE INDEX IF NOT EXISTS idx_test_executions_test_name ON test_executions(test_name)',
      'CREATE INDEX IF NOT EXISTS idx_test_executions_started_at ON test_executions(started_at)',
      'CREATE INDEX IF NOT EXISTS idx_test_executions_status ON test_executions(status)',
      'CREATE INDEX IF NOT EXISTS idx_test_metrics_execution_id ON test_metrics(execution_id)',
      'CREATE INDEX IF NOT EXISTS idx_test_metrics_metric_name ON test_metrics(metric_name)',
      'CREATE INDEX IF NOT EXISTS idx_regression_detections_detected_at ON regression_detections(detected_at)',
      'CREATE INDEX IF NOT EXISTS idx_quality_trends_date ON quality_trends(date)',
      'CREATE INDEX IF NOT EXISTS idx_flaky_test_tracking_test_name ON flaky_test_tracking(test_name)',
    ];

    for (const index of indexes) {
      await this.pgClient.query(index);
    }

    logger.info('Database tables and indexes created successfully');
  }

  async processTestResults(resultsDir) {
    logger.info(`Processing test results from: ${resultsDir}`);

    try {
      // Find all result files
      const resultFiles = await this.findResultFiles(resultsDir);

      let totalProcessed = 0;
      let totalRegressions = 0;

      for (const resultFile of resultFiles) {
        const results = await this.processResultFile(resultFile);
        if (results) {
          totalProcessed += results.processed;
          totalRegressions += results.regressions;
        }
      }

      // Update quality trends
      await this.updateQualityTrends();

      // Update flaky test tracking
      await this.updateFlakyTestTracking();

      // Calculate and store performance baselines
      await this.updatePerformanceBaselines();

      // Generate analytics summary
      const summary = await this.generateAnalyticsSummary();

      logger.info(
        `Processing complete: ${totalProcessed} executions processed, ${totalRegressions} regressions detected`
      );

      return summary;
    } catch (error) {
      logger.error('Error processing test results', error);
      throw error;
    }
  }

  async findResultFiles(directory) {
    const resultFiles = [];
    const files = await fs.readdir(directory);

    for (const file of files) {
      const fullPath = path.join(directory, file);
      const stat = await fs.stat(fullPath);

      if (stat.isDirectory()) {
        const subFiles = await this.findResultFiles(fullPath);
        resultFiles.push(...subFiles);
      } else if (
        file.endsWith('.json') &&
        (file.includes('results') ||
          file.includes('report') ||
          file.includes('junit'))
      ) {
        resultFiles.push(fullPath);
      }
    }

    return resultFiles;
  }

  async processResultFile(filePath) {
    try {
      const content = await fs.readJson(filePath);
      const fileType = this.detectResultFileType(content);

      let processed = 0;
      let regressions = 0;

      switch (fileType) {
        case 'playwright':
          ({ processed, regressions } =
            await this.processPlaywrightResults(content));
          break;
        case 'k6':
          ({ processed, regressions } = await this.processK6Results(content));
          break;
        case 'jest':
          ({ processed, regressions } = await this.processJestResults(content));
          break;
        case 'artillery':
          ({ processed, regressions } =
            await this.processArtilleryResults(content));
          break;
        default:
          logger.warn(`Unknown result file type: ${filePath}`);
      }

      return { processed, regressions };
    } catch (error) {
      logger.error(`Error processing result file: ${filePath}`, error);
      return null;
    }
  }

  detectResultFileType(content) {
    if (content.suites && content.tests) return 'playwright';
    if (content.metrics && content.root_group) return 'k6';
    if (content.testResults) return 'jest';
    if (content.aggregate && content.phases) return 'artillery';
    return 'unknown';
  }

  async processPlaywrightResults(results) {
    let processed = 0;
    let regressions = 0;

    for (const suite of results.suites || []) {
      for (const test of suite.tests || []) {
        const executionId = await this.storeTestExecution({
          testId: test.testId || `${suite.title}_${test.title}`,
          testName: test.title,
          testType: 'e2e',
          testSuite: suite.title,
          status: test.outcome,
          startedAt: new Date(results.stats.startTime),
          completedAt: new Date(results.stats.endTime),
          durationMs: test.duration,
          browser: test.browser || 'chromium',
          environment: process.env.TEST_ENVIRONMENT || 'local',
          commitHash: process.env.GITHUB_SHA || 'unknown',
          branch: process.env.GITHUB_REF_NAME || 'unknown',
          buildNumber: process.env.GITHUB_RUN_NUMBER || 'unknown',
          metadata: {
            retries: test.retries,
            annotations: test.annotations,
            errors: test.errors,
          },
        });

        // Store performance metrics if available
        if (test.performanceMetrics) {
          await this.storePerformanceMetrics(
            executionId,
            test.performanceMetrics
          );
        }

        // Check for regressions
        const testRegressions = await this.detectRegressions(
          executionId,
          test.title,
          test.performanceMetrics
        );
        regressions += testRegressions;

        processed++;
      }
    }

    return { processed, regressions };
  }

  async processK6Results(results) {
    let processed = 0;
    let regressions = 0;

    const executionId = await this.storeTestExecution({
      testId: `k6_${Date.now()}`,
      testName: 'K6 Load Test',
      testType: 'performance',
      testSuite: 'load-testing',
      status: results.root_group.checks.passes > 0 ? 'passed' : 'failed',
      startedAt: new Date(),
      completedAt: new Date(),
      durationMs: results.state.testRunDurationMs,
      environment: process.env.TEST_ENVIRONMENT || 'local',
      commitHash: process.env.GITHUB_SHA || 'unknown',
      branch: process.env.GITHUB_REF_NAME || 'unknown',
      buildNumber: process.env.GITHUB_RUN_NUMBER || 'unknown',
      metadata: {
        vus: results.options?.scenarios,
        thresholds: results.options?.thresholds,
        summary: results.root_group,
      },
    });

    // Store all metrics
    for (const [metricName, metricData] of Object.entries(results.metrics)) {
      await this.storeTestMetric(executionId, {
        metricName,
        metricValue: metricData.avg || metricData.rate || metricData.value,
        metricUnit: metricData.type === 'rate' ? 'rate' : 'ms',
        labels: { type: metricData.type },
        timestamp: new Date(),
      });
    }

    // Check for performance regressions
    const performanceMetrics = this.extractK6PerformanceMetrics(
      results.metrics
    );
    const testRegressions = await this.detectRegressions(
      executionId,
      'K6 Load Test',
      performanceMetrics
    );
    regressions += testRegressions;

    processed = 1;
    return { processed, regressions };
  }

  extractK6PerformanceMetrics(metrics) {
    return {
      responseTime: metrics.http_req_duration?.avg,
      responseTimeP95: metrics.http_req_duration?.p95,
      responseTimeP99: metrics.http_req_duration?.p99,
      errorRate: metrics.http_req_failed?.rate,
      requestRate: metrics.http_reqs?.rate,
      dataReceived: metrics.data_received?.rate,
      dataSent: metrics.data_sent?.rate,
    };
  }

  async storeTestExecution(execution) {
    const query = `
      INSERT INTO test_executions 
      (test_id, test_name, test_type, test_suite, status, started_at, completed_at, 
       duration_ms, browser, environment, commit_hash, branch, build_number, metadata)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
      RETURNING id
    `;

    const values = [
      execution.testId,
      execution.testName,
      execution.testType,
      execution.testSuite,
      execution.status,
      execution.startedAt,
      execution.completedAt,
      execution.durationMs,
      execution.browser,
      execution.environment,
      execution.commitHash,
      execution.branch,
      execution.buildNumber,
      JSON.stringify(execution.metadata),
    ];

    const result = await this.pgClient.query(query, values);
    return result.rows[0].id;
  }

  async storeTestMetric(executionId, metric) {
    const query = `
      INSERT INTO test_metrics 
      (execution_id, metric_name, metric_value, metric_unit, labels, timestamp)
      VALUES ($1, $2, $3, $4, $5, $6)
    `;

    const values = [
      executionId,
      metric.metricName,
      metric.metricValue,
      metric.metricUnit,
      JSON.stringify(metric.labels),
      metric.timestamp,
    ];

    await this.pgClient.query(query, values);
  }

  async storePerformanceMetrics(executionId, metrics) {
    for (const [name, value] of Object.entries(metrics)) {
      await this.storeTestMetric(executionId, {
        metricName: name,
        metricValue: value,
        metricUnit:
          name.includes('time') || name.includes('duration') ? 'ms' : 'count',
        labels: { category: 'performance' },
        timestamp: new Date(),
      });
    }
  }

  async detectRegressions(executionId, testName, performanceMetrics) {
    if (!performanceMetrics) return 0;

    let regressions = 0;

    for (const [metricName, value] of Object.entries(performanceMetrics)) {
      if (value == null || isNaN(value)) continue;

      // Get baseline for this metric
      const baseline = await this.getBaseline(testName, metricName);
      if (!baseline) continue;

      // Calculate regression percentage
      const regressionPercentage =
        (value - baseline.baseline_value) / baseline.baseline_value;

      // Determine if this is a significant regression
      let severity = null;
      if (
        Math.abs(regressionPercentage) >
        this.config.thresholds.regression.critical
      ) {
        severity = 'critical';
      } else if (
        Math.abs(regressionPercentage) > this.config.thresholds.regression.major
      ) {
        severity = 'major';
      } else if (
        Math.abs(regressionPercentage) > this.config.thresholds.regression.minor
      ) {
        severity = 'minor';
      }

      if (severity) {
        await this.storeRegressionDetection({
          executionId,
          testName,
          metricName,
          baselineValue: baseline.baseline_value,
          actualValue: value,
          regressionPercentage: regressionPercentage * 100,
          severity,
          detectedAt: new Date(),
        });

        regressions++;

        logger.warn(`Regression detected: ${testName}.${metricName}`, {
          baseline: baseline.baseline_value,
          actual: value,
          regression: `${(regressionPercentage * 100).toFixed(2)}%`,
          severity,
        });
      }
    }

    return regressions;
  }

  async getBaseline(testName, metricName) {
    const query = `
      SELECT * FROM performance_baselines 
      WHERE test_name = $1 AND metric_name = $2 
      AND (valid_until IS NULL OR valid_until > CURRENT_TIMESTAMP)
      ORDER BY calculated_at DESC 
      LIMIT 1
    `;

    const result = await this.pgClient.query(query, [testName, metricName]);
    return result.rows[0] || null;
  }

  async storeRegressionDetection(regression) {
    const query = `
      INSERT INTO regression_detections 
      (execution_id, test_name, metric_name, baseline_value, actual_value, 
       regression_percentage, severity, detected_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
    `;

    const values = [
      regression.executionId,
      regression.testName,
      regression.metricName,
      regression.baselineValue,
      regression.actualValue,
      regression.regressionPercentage,
      regression.severity,
      regression.detectedAt,
    ];

    await this.pgClient.query(query, values);
  }

  async updateQualityTrends() {
    const today = moment().format('YYYY-MM-DD');

    // Get today's test results by type
    const query = `
      SELECT 
        test_type,
        environment,
        COUNT(*) as total_tests,
        COUNT(*) FILTER (WHERE status = 'passed') as passed_tests,
        COUNT(*) FILTER (WHERE status = 'failed') as failed_tests,
        COUNT(*) FILTER (WHERE status = 'skipped') as skipped_tests,
        AVG(duration_ms) as avg_duration_ms,
        SUM(duration_ms) as total_duration_ms
      FROM test_executions 
      WHERE DATE(started_at) = $1 
      GROUP BY test_type, environment
    `;

    const result = await this.pgClient.query(query, [today]);

    for (const row of result.rows) {
      // Get flaky tests count
      const flakyQuery = `
        SELECT COUNT(*) as flaky_count
        FROM flaky_test_tracking 
        WHERE test_type = $1 AND last_flaky_at >= $2
      `;
      const flakyResult = await this.pgClient.query(flakyQuery, [
        row.test_type,
        moment().subtract(1, 'day').toDate(),
      ]);

      // Get regression count
      const regressionQuery = `
        SELECT COUNT(*) as regression_count
        FROM regression_detections r
        JOIN test_executions e ON r.execution_id = e.id
        WHERE e.test_type = $1 AND DATE(r.detected_at) = $2
      `;
      const regressionResult = await this.pgClient.query(regressionQuery, [
        row.test_type,
        today,
      ]);

      // Calculate quality score (0-10 scale)
      const passRate = row.passed_tests / row.total_tests;
      const flakyPenalty = Math.min(flakyResult.rows[0].flaky_count * 0.1, 2);
      const regressionPenalty = Math.min(
        regressionResult.rows[0].regression_count * 0.2,
        3
      );
      const qualityScore = Math.max(
        0,
        passRate * 10 - flakyPenalty - regressionPenalty
      );

      // Upsert quality trend
      const upsertQuery = `
        INSERT INTO quality_trends 
        (date, test_type, total_tests, passed_tests, failed_tests, skipped_tests,
         avg_duration_ms, total_duration_ms, flaky_tests, regression_count, 
         quality_score, environment)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
        ON CONFLICT (date, test_type, environment) 
        DO UPDATE SET
          total_tests = EXCLUDED.total_tests,
          passed_tests = EXCLUDED.passed_tests,
          failed_tests = EXCLUDED.failed_tests,
          skipped_tests = EXCLUDED.skipped_tests,
          avg_duration_ms = EXCLUDED.avg_duration_ms,
          total_duration_ms = EXCLUDED.total_duration_ms,
          flaky_tests = EXCLUDED.flaky_tests,
          regression_count = EXCLUDED.regression_count,
          quality_score = EXCLUDED.quality_score
      `;

      await this.pgClient.query(upsertQuery, [
        today,
        row.test_type,
        row.total_tests,
        row.passed_tests,
        row.failed_tests,
        row.skipped_tests,
        row.avg_duration_ms,
        row.total_duration_ms,
        flakyResult.rows[0].flaky_count,
        regressionResult.rows[0].regression_count,
        qualityScore,
        row.environment,
      ]);
    }

    logger.info('Quality trends updated successfully');
  }

  async updateFlakyTestTracking() {
    // Update flaky test tracking based on recent results
    const query = `
      WITH test_outcomes AS (
        SELECT 
          test_name,
          test_type,
          status,
          started_at,
          environment
        FROM test_executions 
        WHERE started_at >= NOW() - INTERVAL '7 days'
      ),
      test_stats AS (
        SELECT 
          test_name,
          test_type,
          COUNT(*) as total_runs,
          COUNT(*) FILTER (WHERE status = 'passed') as success_count,
          COUNT(*) FILTER (WHERE status = 'failed') as failure_count,
          array_agg(DISTINCT environment) as environments,
          MIN(started_at) FILTER (WHERE status = 'failed') as first_failure,
          MAX(started_at) FILTER (WHERE status = 'failed') as last_failure
        FROM test_outcomes
        GROUP BY test_name, test_type
        HAVING COUNT(*) FILTER (WHERE status = 'failed') > 0
      )
      SELECT 
        test_name,
        test_type,
        total_runs,
        success_count,
        failure_count,
        CASE 
          WHEN total_runs > 0 THEN ROUND(failure_count::decimal / total_runs::decimal, 3)
          ELSE 0 
        END as flakiness_score,
        environments,
        first_failure,
        last_failure
      FROM test_stats
      WHERE total_runs >= 3 -- Only consider tests with at least 3 runs
      AND failure_count::decimal / total_runs::decimal BETWEEN 0.1 AND 0.9 -- Flaky (not consistently failing)
    `;

    const result = await this.pgClient.query(query);

    for (const row of result.rows) {
      const upsertQuery = `
        INSERT INTO flaky_test_tracking 
        (test_name, test_type, failure_count, success_count, total_runs, 
         flakiness_score, first_flaky_at, last_flaky_at, environments)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        ON CONFLICT (test_name, test_type) 
        DO UPDATE SET
          failure_count = EXCLUDED.failure_count,
          success_count = EXCLUDED.success_count,
          total_runs = EXCLUDED.total_runs,
          flakiness_score = EXCLUDED.flakiness_score,
          last_flaky_at = EXCLUDED.last_flaky_at,
          environments = EXCLUDED.environments,
          updated_at = CURRENT_TIMESTAMP
      `;

      await this.pgClient.query(upsertQuery, [
        row.test_name,
        row.test_type,
        row.failure_count,
        row.success_count,
        row.total_runs,
        row.flakiness_score,
        row.first_failure,
        row.last_failure,
        row.environments,
      ]);
    }

    logger.info(`Updated flaky test tracking for ${result.rows.length} tests`);
  }

  async updatePerformanceBaselines() {
    // Calculate new baselines for performance metrics
    const query = `
      WITH recent_metrics AS (
        SELECT 
          e.test_name,
          m.metric_name,
          m.metric_value,
          e.environment
        FROM test_metrics m
        JOIN test_executions e ON m.execution_id = e.id
        WHERE e.started_at >= NOW() - INTERVAL '30 days'
        AND e.status = 'passed'
        AND m.metric_value IS NOT NULL
      ),
      baseline_stats AS (
        SELECT 
          test_name,
          metric_name,
          environment,
          COUNT(*) as sample_size,
          AVG(metric_value) as avg_value,
          STDDEV(metric_value) as std_dev,
          PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY metric_value) as median_value,
          PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY metric_value) as p95_value
        FROM recent_metrics
        GROUP BY test_name, metric_name, environment
        HAVING COUNT(*) >= 10 -- Need at least 10 samples for a baseline
      )
      SELECT 
        test_name,
        metric_name,
        environment,
        sample_size,
        -- Use P95 for response time metrics, median for others
        CASE 
          WHEN metric_name ILIKE '%response%time%' OR metric_name ILIKE '%duration%' THEN p95_value
          ELSE median_value
        END as baseline_value,
        std_dev / avg_value as confidence_interval
      FROM baseline_stats
      WHERE std_dev IS NOT NULL
    `;

    const result = await this.pgClient.query(query);

    for (const row of result.rows) {
      const upsertQuery = `
        INSERT INTO performance_baselines 
        (test_name, metric_name, baseline_value, confidence_interval, 
         sample_size, calculated_at, valid_until, environment)
        VALUES ($1, $2, $3, $4, $5, CURRENT_TIMESTAMP, 
                CURRENT_TIMESTAMP + INTERVAL '30 days', $6)
        ON CONFLICT (test_name, metric_name, environment) 
        DO UPDATE SET
          baseline_value = EXCLUDED.baseline_value,
          confidence_interval = EXCLUDED.confidence_interval,
          sample_size = EXCLUDED.sample_size,
          calculated_at = EXCLUDED.calculated_at,
          valid_until = EXCLUDED.valid_until
      `;

      await this.pgClient.query(upsertQuery, [
        row.test_name,
        row.metric_name,
        row.baseline_value,
        row.confidence_interval,
        row.sample_size,
        row.environment,
      ]);
    }

    logger.info(`Updated ${result.rows.length} performance baselines`);
  }

  async generateAnalyticsSummary() {
    const today = moment().format('YYYY-MM-DD');

    // Get overall statistics
    const statsQuery = `
      SELECT 
        COUNT(*) as total_executions,
        COUNT(*) FILTER (WHERE status = 'passed') as passed_executions,
        COUNT(*) FILTER (WHERE status = 'failed') as failed_executions,
        COUNT(DISTINCT test_name) as unique_tests,
        AVG(duration_ms) as avg_duration
      FROM test_executions 
      WHERE DATE(started_at) = $1
    `;
    const statsResult = await this.pgClient.query(statsQuery, [today]);
    const stats = statsResult.rows[0];

    // Get regression summary
    const regressionQuery = `
      SELECT 
        COUNT(*) as total_regressions,
        COUNT(*) FILTER (WHERE severity = 'critical') as critical_regressions,
        COUNT(*) FILTER (WHERE severity = 'major') as major_regressions,
        COUNT(*) FILTER (WHERE severity = 'minor') as minor_regressions
      FROM regression_detections 
      WHERE DATE(detected_at) = $1
    `;
    const regressionResult = await this.pgClient.query(regressionQuery, [
      today,
    ]);
    const regressions = regressionResult.rows[0];

    // Get quality trends
    const qualityQuery = `
      SELECT 
        test_type,
        quality_score,
        total_tests,
        passed_tests,
        flaky_tests
      FROM quality_trends 
      WHERE date = $1
      ORDER BY quality_score DESC
    `;
    const qualityResult = await this.pgClient.query(qualityQuery, [today]);

    const summary = {
      timestamp: new Date().toISOString(),
      date: today,
      overview: {
        totalExecutions: parseInt(stats.total_executions),
        passedExecutions: parseInt(stats.passed_executions),
        failedExecutions: parseInt(stats.failed_executions),
        uniqueTests: parseInt(stats.unique_tests),
        averageDuration: parseFloat(stats.avg_duration),
        successRate:
          stats.total_executions > 0
            ? (
                (stats.passed_executions / stats.total_executions) *
                100
              ).toFixed(2)
            : 0,
      },
      regressions: {
        total: parseInt(regressions.total_regressions),
        critical: parseInt(regressions.critical_regressions),
        major: parseInt(regressions.major_regressions),
        minor: parseInt(regressions.minor_regressions),
      },
      qualityTrends: qualityResult.rows.map(row => ({
        testType: row.test_type,
        qualityScore: parseFloat(row.quality_score),
        totalTests: parseInt(row.total_tests),
        passedTests: parseInt(row.passed_tests),
        flakyTests: parseInt(row.flaky_tests),
        successRate: ((row.passed_tests / row.total_tests) * 100).toFixed(2),
      })),
      overallHealthScore: this.calculateOverallHealthScore(
        stats,
        regressions,
        qualityResult.rows
      ),
    };

    // Store summary in Redis for quick access
    await this.redisClient.setEx(
      `analytics:summary:${today}`,
      3600, // 1 hour TTL
      JSON.stringify(summary)
    );

    logger.info('Analytics summary generated successfully');
    return summary;
  }

  calculateOverallHealthScore(stats, regressions, qualityTrends) {
    // Calculate overall health score (0-100)
    const successRate =
      stats.total_executions > 0
        ? stats.passed_executions / stats.total_executions
        : 0;

    const avgQualityScore =
      qualityTrends.length > 0
        ? qualityTrends.reduce(
            (sum, trend) => sum + parseFloat(trend.quality_score),
            0
          ) / qualityTrends.length
        : 0;

    const regressionPenalty = Math.min(
      parseInt(regressions.critical_regressions) * 10 +
        parseInt(regressions.major_regressions) * 5 +
        parseInt(regressions.minor_regressions) * 2,
      30
    );

    const healthScore = Math.max(
      0,
      successRate * 40 + // 40% weight on success rate
        avgQualityScore * 4 + // 40% weight on quality score (0-10 -> 0-40)
        20 - // Base 20 points
        regressionPenalty
    );

    return Math.round(healthScore);
  }

  async cleanup() {
    try {
      if (this.pgClient) {
        await this.pgClient.end();
      }
      if (this.redisClient) {
        await this.redisClient.disconnect();
      }
      logger.info('Cleanup completed successfully');
    } catch (error) {
      logger.error('Error during cleanup', error);
    }
  }
}

// CLI Interface
const argv = yargs(hideBin(process.argv))
  .command(
    'process <resultsDir>',
    'Process test results from directory',
    yargs => {
      yargs.positional('resultsDir', {
        describe: 'Directory containing test result files',
        type: 'string',
      });
    }
  )
  .command('summary', 'Generate analytics summary for today')
  .command('trends [days]', 'Generate trend analysis', yargs => {
    yargs.positional('days', {
      describe: 'Number of days to analyze',
      type: 'number',
      default: 7,
    });
  })
  .option('config', {
    alias: 'c',
    describe: 'Configuration file path',
    type: 'string',
  })
  .option('output', {
    alias: 'o',
    describe: 'Output file for results',
    type: 'string',
  })
  .demandCommand(1)
  .help().argv;

// Main execution
async function main() {
  const processor = new TestAnalyticsProcessor(
    argv.config ? require(path.resolve(argv.config)) : {}
  );

  try {
    await processor.initialize();

    let result;
    switch (argv._[0]) {
      case 'process':
        result = await processor.processTestResults(argv.resultsDir);
        break;
      case 'summary':
        result = await processor.generateAnalyticsSummary();
        break;
      case 'trends':
        result = await processor.generateTrendAnalysis(argv.days);
        break;
    }

    if (argv.output) {
      await fs.writeJson(argv.output, result, { spaces: 2 });
      logger.info(`Results written to ${argv.output}`);
    } else {
      console.log(JSON.stringify(result, null, 2));
    }
  } catch (error) {
    logger.error('Failed to execute command', error);
    process.exit(1);
  } finally {
    await processor.cleanup();
  }
}

if (require.main === module) {
  main();
}

module.exports = TestAnalyticsProcessor;
