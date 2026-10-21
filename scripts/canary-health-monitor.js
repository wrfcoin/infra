#!/usr/bin/env node

/**
 * Canary Deployment Health Monitoring
 * Monitors canary deployments and triggers automatic rollback on health issues
 */

const {
  CloudWatchClient,
  GetMetricStatisticsCommand,
} = require('@aws-sdk/client-cloudwatch');
const fetch = require('node-fetch');

class CanaryHealthMonitor {
  constructor(options = {}) {
    this.config = {
      canaryPercentage: options.canaryPercentage || 10,
      rollbackThreshold: options.rollbackThreshold || 5, // Error rate %
      monitoringDuration: options.monitoringDuration || 600, // 10 minutes
      checkInterval: options.checkInterval || 60, // 1 minute
      healthEndpoint: options.healthEndpoint || '/api/health',
      metricsNamespace: options.metricsNamespace || 'AWS/ApplicationELB',
      ...options,
    };

    this.cloudwatch = new CloudWatchClient({
      region: process.env.AWS_REGION || 'us-east-1',
    });

    this.metrics = {
      errorRate: 0,
      responseTime: 0,
      requestCount: 0,
      healthScore: 100,
    };

    this.healthHistory = [];
    this.alertsSent = new Set();
  }

  async monitor() {
    console.log('🔍 Starting canary health monitoring...');
    console.log(`Configuration:`, {
      canaryPercentage: this.config.canaryPercentage,
      rollbackThreshold: this.config.rollbackThreshold,
      monitoringDuration: this.config.monitoringDuration,
      checkInterval: this.config.checkInterval,
    });

    const startTime = Date.now();
    const endTime = startTime + this.config.monitoringDuration * 1000;

    while (Date.now() < endTime) {
      try {
        // Collect health metrics
        await this.collectMetrics();

        // Evaluate health status
        const healthStatus = this.evaluateHealth();

        // Log current status
        this.logHealthStatus(healthStatus);

        // Check if rollback is needed
        if (healthStatus.shouldRollback) {
          console.log('🚨 Rollback threshold exceeded! Triggering rollback...');
          await this.triggerRollback(healthStatus);
          return { status: 'rolled-back', reason: healthStatus.reason };
        }

        // Send alerts if needed
        await this.handleAlerts(healthStatus);

        // Wait for next check
        await this.sleep(this.config.checkInterval * 1000);
      } catch (error) {
        console.error('❌ Error during health monitoring:', error.message);

        // On monitoring errors, be conservative and trigger rollback
        if (
          error.message.includes('timeout') ||
          error.message.includes('connection')
        ) {
          console.log(
            '🚨 Monitoring failures detected, triggering rollback for safety...'
          );
          await this.triggerRollback({
            reason: 'monitoring-failure',
            error: error.message,
          });
          return { status: 'rolled-back', reason: 'monitoring-failure' };
        }
      }
    }

    // Monitoring completed successfully
    const finalHealth = this.evaluateHealth();
    console.log('✅ Canary monitoring completed successfully');

    return {
      status: 'healthy',
      metrics: this.metrics,
      healthScore: finalHealth.healthScore,
      duration: this.config.monitoringDuration,
    };
  }

  async collectMetrics() {
    const endTime = new Date();
    const startTime = new Date(endTime.getTime() - 5 * 60 * 1000); // Last 5 minutes

    try {
      // Collect error rate metrics
      const errorRate = await this.getCloudWatchMetric(
        'HTTPCode_Target_5XX_Count',
        'wrfcoin-frontend-canary',
        startTime,
        endTime
      );

      // Collect total request count
      const requestCount = await this.getCloudWatchMetric(
        'RequestCount',
        'wrfcoin-frontend-canary',
        startTime,
        endTime
      );

      // Collect response time
      const responseTime = await this.getCloudWatchMetric(
        'TargetResponseTime',
        'wrfcoin-frontend-canary',
        startTime,
        endTime
      );

      // Calculate error percentage
      const errorPercentage =
        requestCount > 0 ? (errorRate / requestCount) * 100 : 0;

      // Update metrics
      this.metrics = {
        errorRate: errorPercentage,
        responseTime: responseTime,
        requestCount: requestCount,
        healthScore: this.calculateHealthScore(errorPercentage, responseTime),
      };

      // Add to history
      this.healthHistory.push({
        timestamp: new Date().toISOString(),
        ...this.metrics,
      });

      // Keep only last 20 entries
      if (this.healthHistory.length > 20) {
        this.healthHistory = this.healthHistory.slice(-20);
      }
    } catch (error) {
      console.error('❌ Failed to collect CloudWatch metrics:', error.message);

      // Fallback to direct health check
      await this.performDirectHealthCheck();
    }
  }

  async getCloudWatchMetric(metricName, targetGroup, startTime, endTime) {
    const params = {
      Namespace: this.config.metricsNamespace,
      MetricName: metricName,
      Dimensions: [
        {
          Name: 'TargetGroup',
          Value: targetGroup,
        },
      ],
      StartTime: startTime,
      EndTime: endTime,
      Period: 300, // 5 minutes
      Statistics: ['Sum'],
    };

    const command = new GetMetricStatisticsCommand(params);
    const response = await this.cloudwatch.send(command);

    if (response.Datapoints && response.Datapoints.length > 0) {
      return response.Datapoints[0].Sum || 0;
    }

    return 0;
  }

  async performDirectHealthCheck() {
    try {
      const healthUrl = `${this.config.baseUrl}${this.config.healthEndpoint}`;
      const startTime = Date.now();

      const response = await fetch(healthUrl, {
        timeout: 10000,
        headers: {
          'X-Health-Check': 'canary-monitor',
          'User-Agent': 'WRFCoin-Canary-Monitor/1.0',
        },
      });

      const endTime = Date.now();
      const responseTime = endTime - startTime;

      if (response.ok) {
        const healthData = await response.json();

        this.metrics = {
          errorRate: 0,
          responseTime: responseTime,
          requestCount: 1,
          healthScore: healthData.score || 100,
        };
      } else {
        this.metrics = {
          errorRate: 100,
          responseTime: responseTime,
          requestCount: 1,
          healthScore: 0,
        };
      }
    } catch (error) {
      console.error('❌ Direct health check failed:', error.message);

      this.metrics = {
        errorRate: 100,
        responseTime: 30000, // Assume timeout
        requestCount: 1,
        healthScore: 0,
      };
    }
  }

  calculateHealthScore(errorRate, responseTime) {
    let score = 100;

    // Deduct points for error rate
    score -= Math.min(errorRate * 10, 50); // Max 50 points for errors

    // Deduct points for slow response time
    if (responseTime > 2000) {
      score -= Math.min((responseTime - 2000) / 100, 30); // Max 30 points for slowness
    }

    // Deduct points for very high response time
    if (responseTime > 10000) {
      score -= 20; // Additional penalty for very slow responses
    }

    return Math.max(0, Math.round(score));
  }

  evaluateHealth() {
    const { errorRate, responseTime, healthScore } = this.metrics;

    const status = {
      healthy: true,
      shouldRollback: false,
      reason: null,
      warnings: [],
      errorRate,
      responseTime,
      healthScore,
    };

    // Check error rate threshold
    if (errorRate > this.config.rollbackThreshold) {
      status.healthy = false;
      status.shouldRollback = true;
      status.reason = `Error rate ${errorRate.toFixed(2)}% exceeds threshold ${this.config.rollbackThreshold}%`;
    }

    // Check response time threshold
    if (responseTime > 15000) {
      // 15 seconds
      status.healthy = false;
      status.shouldRollback = true;
      status.reason = `Response time ${responseTime}ms exceeds threshold 15000ms`;
    }

    // Check health score
    if (healthScore < 50) {
      status.healthy = false;
      status.shouldRollback = true;
      status.reason = `Health score ${healthScore} is critically low`;
    }

    // Add warnings for concerning metrics
    if (errorRate > this.config.rollbackThreshold * 0.7) {
      status.warnings.push(
        `Error rate ${errorRate.toFixed(2)}% approaching threshold`
      );
    }

    if (responseTime > 5000) {
      status.warnings.push(`Response time ${responseTime}ms is elevated`);
    }

    if (healthScore < 80) {
      status.warnings.push(
        `Health score ${healthScore} is below optimal range`
      );
    }

    return status;
  }

  logHealthStatus(status) {
    const timestamp = new Date().toISOString();
    const { errorRate, responseTime, healthScore } = this.metrics;

    console.log(`📊 [${timestamp}] Health Status:`);
    console.log(`   Error Rate: ${errorRate.toFixed(2)}%`);
    console.log(`   Response Time: ${responseTime}ms`);
    console.log(`   Health Score: ${healthScore}/100`);
    console.log(`   Status: ${status.healthy ? '✅ Healthy' : '❌ Unhealthy'}`);

    if (status.warnings.length > 0) {
      console.log(`   Warnings: ${status.warnings.join(', ')}`);
    }

    if (status.shouldRollback) {
      console.log(`   🚨 ROLLBACK REQUIRED: ${status.reason}`);
    }
  }

  async handleAlerts(status) {
    const alertKey = `${status.healthy ? 'warning' : 'critical'}-${Date.now()}`;

    // Send critical alert for rollback situations
    if (status.shouldRollback && !this.alertsSent.has('critical')) {
      await this.sendAlert({
        level: 'critical',
        title: '🚨 Canary Deployment Critical Issue',
        message: `Canary deployment requires immediate rollback: ${status.reason}`,
        metrics: this.metrics,
      });
      this.alertsSent.add('critical');
    }

    // Send warning alerts for concerning metrics
    if (status.warnings.length > 0 && !this.alertsSent.has('warning')) {
      await this.sendAlert({
        level: 'warning',
        title: '⚠️ Canary Deployment Warning',
        message: `Canary deployment showing concerning metrics: ${status.warnings.join(', ')}`,
        metrics: this.metrics,
      });
      this.alertsSent.add('warning');
    }
  }

  async sendAlert(alert) {
    console.log(`📢 Sending ${alert.level} alert: ${alert.title}`);

    // Send to Slack if configured
    if (process.env.SLACK_WEBHOOK_URL) {
      try {
        const payload = {
          text: alert.title,
          attachments: [
            {
              color: alert.level === 'critical' ? 'danger' : 'warning',
              text: alert.message,
              fields: [
                {
                  title: 'Error Rate',
                  value: `${alert.metrics.errorRate.toFixed(2)}%`,
                  short: true,
                },
                {
                  title: 'Response Time',
                  value: `${alert.metrics.responseTime}ms`,
                  short: true,
                },
                {
                  title: 'Health Score',
                  value: `${alert.metrics.healthScore}/100`,
                  short: true,
                },
                {
                  title: 'Canary Traffic',
                  value: `${this.config.canaryPercentage}%`,
                  short: true,
                },
              ],
              timestamp: Math.floor(Date.now() / 1000),
            },
          ],
        };

        const response = await fetch(process.env.SLACK_WEBHOOK_URL, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload),
        });

        if (!response.ok) {
          console.error('❌ Failed to send Slack alert:', response.statusText);
        }
      } catch (error) {
        console.error('❌ Error sending Slack alert:', error.message);
      }
    }

    // Send to PagerDuty if configured
    if (process.env.PAGERDUTY_INTEGRATION_KEY && alert.level === 'critical') {
      try {
        const payload = {
          routing_key: process.env.PAGERDUTY_INTEGRATION_KEY,
          event_action: 'trigger',
          payload: {
            summary: alert.title,
            source: 'wrfcoin-canary-monitor',
            severity: 'critical',
            custom_details: {
              message: alert.message,
              metrics: alert.metrics,
              canary_percentage: this.config.canaryPercentage,
            },
          },
        };

        const response = await fetch(
          'https://events.pagerduty.com/v2/enqueue',
          {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload),
          }
        );

        if (!response.ok) {
          console.error(
            '❌ Failed to send PagerDuty alert:',
            response.statusText
          );
        }
      } catch (error) {
        console.error('❌ Error sending PagerDuty alert:', error.message);
      }
    }
  }

  async triggerRollback(healthStatus) {
    console.log('🔄 Triggering automatic canary rollback...');

    try {
      // Trigger GitHub workflow for rollback
      if (process.env.GITHUB_TOKEN) {
        const { Octokit } = require('@octokit/rest');
        const octokit = new Octokit({ auth: process.env.GITHUB_TOKEN });

        await octokit.actions.createWorkflowDispatch({
          owner: process.env.GITHUB_REPOSITORY_OWNER || 'wrfcoin',
          repo: process.env.GITHUB_REPOSITORY_NAME || 'wrfcoin',
          workflow_id: 'canary-rollback.yml',
          ref: 'main',
          inputs: {
            reason: healthStatus.reason || 'Health monitoring failure',
            error_rate: this.metrics.errorRate.toString(),
            response_time: this.metrics.responseTime.toString(),
            health_score: this.metrics.healthScore.toString(),
          },
        });

        console.log('✅ Rollback workflow triggered via GitHub API');
      }

      // Send rollback notification
      await this.sendAlert({
        level: 'critical',
        title: '🔄 Automatic Canary Rollback Triggered',
        message: `Canary deployment automatically rolled back due to: ${healthStatus.reason}`,
        metrics: this.metrics,
      });
    } catch (error) {
      console.error('❌ Failed to trigger rollback:', error.message);

      // Send emergency notification
      await this.sendAlert({
        level: 'critical',
        title: '🚨 EMERGENCY: Rollback Failed',
        message: `Failed to automatically rollback canary deployment. Manual intervention required! Error: ${error.message}`,
        metrics: this.metrics,
      });
    }
  }

  async sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
  }
}

// CLI interface
async function main() {
  const args = process.argv.slice(2);

  const options = {
    canaryPercentage:
      parseInt(
        args.find(arg => arg.startsWith('--canary-percentage='))?.split('=')[1]
      ) || 10,
    rollbackThreshold:
      parseFloat(
        args.find(arg => arg.startsWith('--rollback-threshold='))?.split('=')[1]
      ) || 5,
    monitoringDuration:
      parseInt(
        args.find(arg => arg.startsWith('--duration='))?.split('=')[1]
      ) || 600,
    checkInterval:
      parseInt(
        args.find(arg => arg.startsWith('--interval='))?.split('=')[1]
      ) || 60,
    baseUrl:
      args.find(arg => arg.startsWith('--base-url='))?.split('=')[1] ||
      'https://wrfcoin.io',
  };

  const monitor = new CanaryHealthMonitor(options);
  const result = await monitor.monitor();

  console.log('\n📋 Final Result:', result);

  // Exit with appropriate code
  process.exit(result.status === 'healthy' ? 0 : 1);
}

// Handle script execution
if (require.main === module) {
  main().catch(error => {
    console.error('❌ Monitoring failed:', error);
    process.exit(1);
  });
}

module.exports = {
  CanaryHealthMonitor,
  main,
};
