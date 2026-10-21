#!/usr/bin/env node

/**
 * Quality Alerting System for WRFCoin Platform
 *
 * Monitors quality metrics and sends alerts through various channels
 * when thresholds are breached. Supports Slack, email, webhooks, and more.
 */

const fs = require('fs');
const path = require('path');
const https = require('https');
const { execSync } = require('child_process');
const {
  GracefulShutdown,
  ShutdownPriority,
} = require('../backend/shared/graceful-shutdown/index.js');

class QualityAlertingSystem {
  constructor() {
    this.config = this.loadConfig();
    this.alertHistory = this.loadAlertHistory();
    this.thresholds = {
      quality_score: {
        critical: 50,
        warning: 70,
      },
      coverage: {
        critical: 60,
        warning: 80,
      },
      lint_issues: {
        critical: 20,
        warning: 10,
      },
      security_vulnerabilities: {
        critical: 1,
        warning: 0,
      },
    };
  }

  /**
   * Load alerting configuration
   */
  loadConfig() {
    const configPath = path.join(
      process.cwd(),
      'config',
      'quality-alerting-config.json'
    );

    if (fs.existsSync(configPath)) {
      return JSON.parse(fs.readFileSync(configPath, 'utf8'));
    }

    // Default configuration
    return {
      channels: {
        console: { enabled: true },
        slack: {
          enabled: false,
          webhook_url: process.env.SLACK_WEBHOOK_URL,
          channel: '#quality-alerts',
        },
        email: {
          enabled: false,
          smtp_host: process.env.SMTP_HOST,
          smtp_port: process.env.SMTP_PORT || 587,
          smtp_user: process.env.SMTP_USER,
          smtp_pass: process.env.SMTP_PASS,
          from: process.env.ALERT_EMAIL_FROM,
          to: process.env.ALERT_EMAIL_TO?.split(',') || [],
        },
        webhook: {
          enabled: false,
          url: process.env.QUALITY_WEBHOOK_URL,
        },
      },
      rate_limiting: {
        max_alerts_per_hour: 10,
        cooldown_minutes: 30,
      },
    };
  }

  /**
   * Load alert history for rate limiting
   */
  loadAlertHistory() {
    const historyPath = path.join(process.cwd(), 'logs', 'alert-history.json');

    if (fs.existsSync(historyPath)) {
      try {
        return JSON.parse(fs.readFileSync(historyPath, 'utf8'));
      } catch (error) {
        console.warn('Failed to load alert history:', error.message);
      }
    }

    return { alerts: [] };
  }

  /**
   * Save alert history
   */
  saveAlertHistory() {
    const historyPath = path.join(process.cwd(), 'logs', 'alert-history.json');
    const logsDir = path.dirname(historyPath);

    if (!fs.existsSync(logsDir)) {
      fs.mkdirSync(logsDir, { recursive: true });
    }

    // Keep only alerts from last 7 days
    const weekAgo = Date.now() - 7 * 24 * 60 * 60 * 1000;
    this.alertHistory.alerts = this.alertHistory.alerts.filter(
      alert => new Date(alert.timestamp).getTime() > weekAgo
    );

    fs.writeFileSync(historyPath, JSON.stringify(this.alertHistory, null, 2));
  }

  /**
   * Check if we should rate limit alerts
   */
  shouldRateLimit(alertType) {
    const now = Date.now();
    const hourAgo = now - 60 * 60 * 1000;
    const cooldownMs = this.config.rate_limiting.cooldown_minutes * 60 * 1000;

    // Count alerts in the last hour
    const recentAlerts = this.alertHistory.alerts.filter(
      alert => new Date(alert.timestamp).getTime() > hourAgo
    );

    // Check if we've exceeded the hourly limit
    if (recentAlerts.length >= this.config.rate_limiting.max_alerts_per_hour) {
      console.log(
        `⏱️ Rate limiting: ${recentAlerts.length} alerts in the last hour`
      );
      return true;
    }

    // Check if there's a recent alert of the same type (cooldown)
    const recentSameType = this.alertHistory.alerts.find(
      alert =>
        alert.type === alertType &&
        now - new Date(alert.timestamp).getTime() < cooldownMs
    );

    if (recentSameType) {
      console.log(`⏱️ Cooldown active for ${alertType} alerts`);
      return true;
    }

    return false;
  }

  /**
   * Record alert in history
   */
  recordAlert(alertType, level, message) {
    this.alertHistory.alerts.push({
      type: alertType,
      level,
      message,
      timestamp: new Date().toISOString(),
    });

    this.saveAlertHistory();
  }

  /**
   * Check metrics and trigger alerts if necessary
   */
  async checkMetrics(metrics) {
    const alerts = [];

    // Check quality score
    if (metrics.overall_score < this.thresholds.quality_score.critical) {
      alerts.push({
        type: 'quality_score',
        level: 'critical',
        title: '🚨 Critical Quality Score Alert',
        message: `Quality score has dropped to ${metrics.overall_score}/100 (threshold: ${this.thresholds.quality_score.critical})`,
        value: metrics.overall_score,
        threshold: this.thresholds.quality_score.critical,
      });
    } else if (metrics.overall_score < this.thresholds.quality_score.warning) {
      alerts.push({
        type: 'quality_score',
        level: 'warning',
        title: '⚠️ Quality Score Warning',
        message: `Quality score is ${metrics.overall_score}/100 (threshold: ${this.thresholds.quality_score.warning})`,
        value: metrics.overall_score,
        threshold: this.thresholds.quality_score.warning,
      });
    }

    // Check coverage
    const jsCoverage = metrics.javascript?.coverage || 0;
    if (jsCoverage < this.thresholds.coverage.critical) {
      alerts.push({
        type: 'coverage',
        level: 'critical',
        title: '🚨 Critical Coverage Alert',
        message: `JavaScript coverage has dropped to ${jsCoverage}% (threshold: ${this.thresholds.coverage.critical}%)`,
        value: jsCoverage,
        threshold: this.thresholds.coverage.critical,
      });
    } else if (jsCoverage < this.thresholds.coverage.warning) {
      alerts.push({
        type: 'coverage',
        level: 'warning',
        title: '⚠️ Coverage Warning',
        message: `JavaScript coverage is ${jsCoverage}% (threshold: ${this.thresholds.coverage.warning}%)`,
        value: jsCoverage,
        threshold: this.thresholds.coverage.warning,
      });
    }

    // Check lint issues
    const totalIssues =
      (metrics.javascript?.lint_issues || 0) +
      (metrics.rust?.clippy_warnings || 0) +
      (metrics.contracts?.solhint_issues || 0);

    if (totalIssues > this.thresholds.lint_issues.critical) {
      alerts.push({
        type: 'lint_issues',
        level: 'critical',
        title: '🚨 Critical Lint Issues Alert',
        message: `Total lint issues: ${totalIssues} (threshold: ${this.thresholds.lint_issues.critical})`,
        value: totalIssues,
        threshold: this.thresholds.lint_issues.critical,
      });
    } else if (totalIssues > this.thresholds.lint_issues.warning) {
      alerts.push({
        type: 'lint_issues',
        level: 'warning',
        title: '⚠️ Lint Issues Warning',
        message: `Total lint issues: ${totalIssues} (threshold: ${this.thresholds.lint_issues.warning})`,
        value: totalIssues,
        threshold: this.thresholds.lint_issues.warning,
      });
    }

    // Check security vulnerabilities
    const vulnerabilities = metrics.security?.vulnerabilities || 0;
    if (vulnerabilities > 0) {
      alerts.push({
        type: 'security',
        level: 'critical',
        title: '🚨 Security Vulnerabilities Detected',
        message: `${vulnerabilities} security vulnerabilities found in dependencies`,
        value: vulnerabilities,
        threshold: 0,
      });
    }

    // Send alerts
    for (const alert of alerts) {
      if (!this.shouldRateLimit(alert.type)) {
        await this.sendAlert(alert);
        this.recordAlert(alert.type, alert.level, alert.message);
      }
    }

    return alerts;
  }

  /**
   * Send alert through configured channels
   */
  async sendAlert(alert) {
    const promises = [];

    // Console output
    if (this.config.channels.console.enabled) {
      promises.push(this.sendConsoleAlert(alert));
    }

    // Slack
    if (
      this.config.channels.slack.enabled &&
      this.config.channels.slack.webhook_url
    ) {
      promises.push(this.sendSlackAlert(alert));
    }

    // Email
    if (this.config.channels.email.enabled) {
      promises.push(this.sendEmailAlert(alert));
    }

    // Webhook
    if (
      this.config.channels.webhook.enabled &&
      this.config.channels.webhook.url
    ) {
      promises.push(this.sendWebhookAlert(alert));
    }

    try {
      await Promise.all(promises);
      console.log(`📤 Alert sent: ${alert.title}`);
    } catch (error) {
      console.error('Failed to send alert:', error.message);
    }
  }

  /**
   * Send console alert
   */
  async sendConsoleAlert(alert) {
    const timestamp = new Date().toISOString();
    const separator = '='.repeat(60);

    console.log(`\n${separator}`);
    console.log(`${alert.title}`);
    console.log(`${separator}`);
    console.log(`Message: ${alert.message}`);
    console.log(`Level: ${alert.level.toUpperCase()}`);
    console.log(`Value: ${alert.value}`);
    console.log(`Threshold: ${alert.threshold}`);
    console.log(`Time: ${timestamp}`);
    console.log(`${separator}\n`);
  }

  /**
   * Send Slack alert
   */
  async sendSlackAlert(alert) {
    const webhook_url = this.config.channels.slack.webhook_url;
    if (!webhook_url) return;

    const color = alert.level === 'critical' ? 'danger' : 'warning';
    const emoji = alert.level === 'critical' ? '🚨' : '⚠️';

    const payload = {
      channel: this.config.channels.slack.channel,
      username: 'Quality Gates Bot',
      icon_emoji: ':warning:',
      attachments: [
        {
          color,
          title: `${emoji} ${alert.title}`,
          text: alert.message,
          fields: [
            {
              title: 'Current Value',
              value: alert.value.toString(),
              short: true,
            },
            {
              title: 'Threshold',
              value: alert.threshold.toString(),
              short: true,
            },
            {
              title: 'Level',
              value: alert.level.toUpperCase(),
              short: true,
            },
            {
              title: 'Project',
              value: 'WRFCoin Platform',
              short: true,
            },
          ],
          footer: 'Quality Gates Alert System',
          ts: Math.floor(Date.now() / 1000),
        },
      ],
    };

    return this.sendHttpRequest(webhook_url, 'POST', payload);
  }

  /**
   * Send email alert (simplified - would need proper SMTP implementation)
   */
  async sendEmailAlert(alert) {
    // This is a placeholder - in a real implementation, you would use
    // a proper email library like nodemailer
    console.log(`📧 Email alert would be sent: ${alert.title}`);

    // For now, just log the email content
    const emailContent = `
Subject: ${alert.title}

Dear Team,

A quality gate alert has been triggered for the WRFCoin platform:

${alert.message}

Details:
- Level: ${alert.level.toUpperCase()}
- Current Value: ${alert.value}
- Threshold: ${alert.threshold}
- Time: ${new Date().toISOString()}

Please review and take appropriate action.

Best regards,
Quality Gates Alert System
        `.trim();

    console.log('Email content:\n', emailContent);
  }

  /**
   * Send webhook alert
   */
  async sendWebhookAlert(alert) {
    const url = this.config.channels.webhook.url;
    if (!url) return;

    const payload = {
      event: 'quality_gate_alert',
      timestamp: new Date().toISOString(),
      alert: {
        type: alert.type,
        level: alert.level,
        title: alert.title,
        message: alert.message,
        value: alert.value,
        threshold: alert.threshold,
      },
      metadata: {
        project: 'wrfcoin',
        system: 'quality_gates',
      },
    };

    return this.sendHttpRequest(url, 'POST', payload);
  }

  /**
   * Send HTTP request helper
   */
  sendHttpRequest(url, method, data) {
    return new Promise((resolve, reject) => {
      const urlObj = new URL(url);
      const postData = JSON.stringify(data);

      const options = {
        hostname: urlObj.hostname,
        port: urlObj.port || (urlObj.protocol === 'https:' ? 443 : 80),
        path: urlObj.pathname + urlObj.search,
        method,
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(postData),
          'User-Agent': 'WRFCoin-Quality-Alerts/1.0',
        },
      };

      const client = urlObj.protocol === 'https:' ? https : require('http');

      const req = client.request(options, res => {
        let responseData = '';

        res.on('data', chunk => {
          responseData += chunk;
        });

        res.on('end', () => {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            resolve(responseData);
          } else {
            reject(new Error(`HTTP ${res.statusCode}: ${responseData}`));
          }
        });
      });

      req.on('error', reject);
      req.write(postData);
      req.end();
    });
  }

  /**
   * Test alert system
   */
  async testAlerts() {
    console.log('🧪 Testing alert system...');

    const testAlert = {
      type: 'test',
      level: 'warning',
      title: '🧪 Quality Alert System Test',
      message:
        'This is a test alert to verify the alerting system is working correctly.',
      value: 'N/A',
      threshold: 'N/A',
    };

    await this.sendAlert(testAlert);
    console.log('✅ Alert system test completed');
  }

  /**
   * Monitor quality metrics continuously
   */
  async startMonitoring(intervalMinutes = 5) {
    console.log(
      `🎯 Starting quality monitoring (every ${intervalMinutes} minutes)...`
    );

    const checkQuality = async () => {
      try {
        // Run quality metrics collection
        const QualityMetricsReporter = require('./quality-metrics-reporter');
        const reporter = new QualityMetricsReporter();
        const result = await reporter.run();

        // Check for alerts
        const alerts = await this.checkMetrics(result.metrics);

        if (alerts.length > 0) {
          console.log(`🚨 ${alerts.length} quality alerts triggered`);
        } else {
          console.log('✅ Quality check passed - no alerts triggered');
        }
      } catch (error) {
        console.error('Error during quality monitoring:', error.message);
      }
    };

    // Initial check
    await checkQuality();

    // Set up periodic checks and store interval reference
    this.monitoringInterval = setInterval(
      checkQuality,
      intervalMinutes * 60 * 1000
    );
  }

  /**
   * Stop monitoring and cleanup resources
   */
  stopMonitoring() {
    if (this.monitoringInterval) {
      clearInterval(this.monitoringInterval);
      this.monitoringInterval = null;
    }
    console.log('🛑 Quality monitoring stopped');
    this.saveAlertHistory();
  }
}

// CLI execution
if (require.main === module) {
  const alertSystem = new QualityAlertingSystem();

  const command = process.argv[2] || 'help';

  switch (command) {
    case 'test':
      alertSystem
        .testAlerts()
        .then(() => process.exit(0))
        .catch(error => {
          console.error('Test failed:', error);
          process.exit(1);
        });
      break;

    case 'check':
      // Check current metrics and send alerts if needed
      const QualityMetricsReporter = require('./quality-metrics-reporter');
      const reporter = new QualityMetricsReporter();
      reporter
        .run()
        .then(result => alertSystem.checkMetrics(result.metrics))
        .then(alerts => {
          console.log(
            `Quality check completed - ${alerts.length} alerts triggered`
          );
          process.exit(0);
        })
        .catch(error => {
          console.error('Quality check failed:', error);
          process.exit(1);
        });
      break;

    case 'monitor':
      const interval = parseInt(process.argv[3]) || 5;

      // Setup graceful shutdown for continuous monitoring
      const shutdown = GracefulShutdown.getInstance({
        globalTimeout: 10000,
      });

      shutdown.registerHandler({
        name: 'quality-alerting-system',
        priority: ShutdownPriority.STOP_BACKGROUND_JOBS,
        handler: () => alertSystem.stopMonitoring(),
      });

      shutdown.setupSignalHandlers();

      alertSystem.startMonitoring(interval);
      break;

    default:
      console.log(`
WRFCoin Quality Alerting System

Usage:
  node quality-alerting-system.js test     - Test alert channels
  node quality-alerting-system.js check    - Check current metrics and send alerts
  node quality-alerting-system.js monitor [interval] - Start continuous monitoring

Environment variables:
  SLACK_WEBHOOK_URL - Slack webhook for alerts
  QUALITY_WEBHOOK_URL - Custom webhook URL
  SMTP_HOST, SMTP_USER, SMTP_PASS - Email configuration
  ALERT_EMAIL_FROM, ALERT_EMAIL_TO - Email addresses

Examples:
  npm run quality:alert:test
  npm run quality:alert:check
  npm run quality:alert:monitor 10  # Check every 10 minutes
            `);
      break;
  }
}

module.exports = QualityAlertingSystem;
