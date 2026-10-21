#!/usr/bin/env node

/**
 * Security Gatekeeping Validation Script
 * Comprehensive validation of CI/CD security systems implementation
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

class SecurityGatekeepingValidator {
  constructor() {
    this.results = {
      security: { passed: 0, failed: 0, tests: [] },
      monitoring: { passed: 0, failed: 0, tests: [] },
      rollback: { passed: 0, failed: 0, tests: [] },
      dependencies: { passed: 0, failed: 0, tests: [] },
      overall: { score: 0, status: 'unknown' },
    };

    this.requiredFiles = [
      '.github/workflows/enhanced-security-gate.yml',
      '.github/workflows/automated-rollback.yml',
      '.github/dependabot.yml',
      'infra/monitoring/docker-compose.comprehensive-monitoring.yml',
      'infra/monitoring/alert-rules-enhanced.yml',
      'docs/CICD_SECURITY_GATEKEEPING.md',
    ];
  }

  async validate() {
    console.log('🔍 Starting Security Gatekeeping Validation...\n');

    try {
      await this.validateFileStructure();
      await this.validateSecurityWorkflows();
      await this.validateDependabotConfig();
      await this.validateMonitoringSetup();
      await this.validateRollbackMechanisms();
      await this.validateSecurityScanning();
      await this.generateValidationReport();
    } catch (error) {
      console.error('❌ Validation failed:', error.message);
      process.exit(1);
    }
  }

  async validateFileStructure() {
    console.log('📁 Validating File Structure...');

    for (const file of this.requiredFiles) {
      const fullPath = path.join(process.cwd(), file);

      if (fs.existsSync(fullPath)) {
        this.recordTest('security', `File exists: ${file}`, true);
        console.log(`  ✅ ${file}`);
      } else {
        this.recordTest('security', `File missing: ${file}`, false);
        console.log(`  ❌ ${file} - MISSING`);
      }
    }

    console.log('');
  }

  async validateSecurityWorkflows() {
    console.log('🔒 Validating Security Workflows...');

    try {
      // Check enhanced security gate workflow
      const securityGateFile = '.github/workflows/enhanced-security-gate.yml';
      if (fs.existsSync(securityGateFile)) {
        const content = fs.readFileSync(securityGateFile, 'utf8');

        // Check for required security scans
        const requiredScans = [
          'snyk/actions/node@master',
          'SonarSource/sonarqube-scan-action',
          'zaproxy/action-baseline@v0.12.0',
          'aquasec/trivy-action@master',
        ];

        for (const scan of requiredScans) {
          if (content.includes(scan)) {
            this.recordTest('security', `Security scan present: ${scan}`, true);
            console.log(`  ✅ ${scan}`);
          } else {
            this.recordTest(
              'security',
              `Security scan missing: ${scan}`,
              false
            );
            console.log(`  ❌ ${scan} - MISSING`);
          }
        }

        // Check for security gate enforcement
        if (
          content.includes('security-gate-status') &&
          content.includes('failure()')
        ) {
          this.recordTest(
            'security',
            'Security gate enforcement configured',
            true
          );
          console.log('  ✅ Security gate enforcement');
        } else {
          this.recordTest(
            'security',
            'Security gate enforcement missing',
            false
          );
          console.log('  ❌ Security gate enforcement - MISSING');
        }
      }
    } catch (error) {
      this.recordTest(
        'security',
        `Security workflow validation failed: ${error.message}`,
        false
      );
      console.log(`  ❌ Security workflow validation failed: ${error.message}`);
    }

    console.log('');
  }

  async validateDependabotConfig() {
    console.log('📦 Validating Dependabot Configuration...');

    try {
      const dependabotFile = '.github/dependabot.yml';
      if (fs.existsSync(dependabotFile)) {
        const content = fs.readFileSync(dependabotFile, 'utf8');

        // Check for required ecosystems
        const requiredEcosystems = ['npm', 'cargo', 'docker', 'github-actions'];

        for (const ecosystem of requiredEcosystems) {
          if (content.includes(`package-ecosystem: "${ecosystem}"`)) {
            this.recordTest(
              'dependencies',
              `Ecosystem configured: ${ecosystem}`,
              true
            );
            console.log(`  ✅ ${ecosystem}`);
          } else {
            this.recordTest(
              'dependencies',
              `Ecosystem missing: ${ecosystem}`,
              false
            );
            console.log(`  ❌ ${ecosystem} - MISSING`);
          }
        }

        // Check for security update scheduling
        if (
          content.includes('schedule:') &&
          content.includes('interval: "daily"')
        ) {
          this.recordTest(
            'dependencies',
            'Daily security updates configured',
            true
          );
          console.log('  ✅ Daily security updates');
        } else {
          this.recordTest(
            'dependencies',
            'Daily security updates not configured',
            false
          );
          console.log('  ❌ Daily security updates - NOT CONFIGURED');
        }

        // Check for grouping rules
        if (content.includes('groups:')) {
          this.recordTest(
            'dependencies',
            'Dependency grouping configured',
            true
          );
          console.log('  ✅ Dependency grouping');
        } else {
          this.recordTest('dependencies', 'Dependency grouping missing', false);
          console.log('  ❌ Dependency grouping - MISSING');
        }
      }
    } catch (error) {
      this.recordTest(
        'dependencies',
        `Dependabot validation failed: ${error.message}`,
        false
      );
      console.log(`  ❌ Dependabot validation failed: ${error.message}`);
    }

    console.log('');
  }

  async validateMonitoringSetup() {
    console.log('📊 Validating Monitoring Setup...');

    try {
      // Check monitoring docker compose
      const monitoringFile =
        'infra/monitoring/docker-compose.comprehensive-monitoring.yml';
      if (fs.existsSync(monitoringFile)) {
        const content = fs.readFileSync(monitoringFile, 'utf8');

        // Check for required monitoring services
        const requiredServices = [
          'prometheus',
          'grafana',
          'elasticsearch',
          'logstash',
          'kibana',
          'jaeger',
          'falco',
        ];

        for (const service of requiredServices) {
          if (content.includes(`${service}:`)) {
            this.recordTest(
              'monitoring',
              `Service configured: ${service}`,
              true
            );
            console.log(`  ✅ ${service}`);
          } else {
            this.recordTest('monitoring', `Service missing: ${service}`, false);
            console.log(`  ❌ ${service} - MISSING`);
          }
        }
      }

      // Check alert rules
      const alertRulesFile = 'infra/monitoring/alert-rules-enhanced.yml';
      if (fs.existsSync(alertRulesFile)) {
        const content = fs.readFileSync(alertRulesFile, 'utf8');

        // Check for critical alert types
        const requiredAlerts = [
          'SecurityScanFailed',
          'HighVulnerabilityDetected',
          'RollbackTriggered',
          'DeploymentFailed',
        ];

        for (const alert of requiredAlerts) {
          if (content.includes(alert)) {
            this.recordTest('monitoring', `Alert rule present: ${alert}`, true);
            console.log(`  ✅ ${alert}`);
          } else {
            this.recordTest(
              'monitoring',
              `Alert rule missing: ${alert}`,
              false
            );
            console.log(`  ❌ ${alert} - MISSING`);
          }
        }
      }
    } catch (error) {
      this.recordTest(
        'monitoring',
        `Monitoring validation failed: ${error.message}`,
        false
      );
      console.log(`  ❌ Monitoring validation failed: ${error.message}`);
    }

    console.log('');
  }

  async validateRollbackMechanisms() {
    console.log('🔄 Validating Rollback Mechanisms...');

    try {
      // Check rollback workflow
      const rollbackFile = '.github/workflows/automated-rollback.yml';
      if (fs.existsSync(rollbackFile)) {
        const content = fs.readFileSync(rollbackFile, 'utf8');

        // Check for rollback triggers
        const rollbackFeatures = [
          'health-check-failure',
          'error-rate-threshold',
          'performance-degradation',
          'database-backup',
        ];

        for (const feature of rollbackFeatures) {
          if (
            content.includes(feature) ||
            content.includes(feature.replace(/-/g, '_'))
          ) {
            this.recordTest('rollback', `Feature present: ${feature}`, true);
            console.log(`  ✅ ${feature}`);
          } else {
            this.recordTest('rollback', `Feature missing: ${feature}`, false);
            console.log(`  ❌ ${feature} - MISSING`);
          }
        }

        // Check for multi-region support
        if (content.includes('region') && content.includes('kubectl')) {
          this.recordTest('rollback', 'Multi-region rollback support', true);
          console.log('  ✅ Multi-region rollback support');
        } else {
          this.recordTest(
            'rollback',
            'Multi-region rollback support missing',
            false
          );
          console.log('  ❌ Multi-region rollback support - MISSING');
        }
      }

      // Check canary health monitor
      const canaryMonitorFile = 'scripts/canary-health-monitor.js';
      if (fs.existsSync(canaryMonitorFile)) {
        this.recordTest('rollback', 'Canary health monitor implemented', true);
        console.log('  ✅ Canary health monitor');
      } else {
        this.recordTest('rollback', 'Canary health monitor missing', false);
        console.log('  ❌ Canary health monitor - MISSING');
      }
    } catch (error) {
      this.recordTest(
        'rollback',
        `Rollback validation failed: ${error.message}`,
        false
      );
      console.log(`  ❌ Rollback validation failed: ${error.message}`);
    }

    console.log('');
  }

  async validateSecurityScanning() {
    console.log('🛡️ Validating Security Scanning Tools...');

    try {
      // Check if Node.js security tools are available
      try {
        execSync('npm audit --version', { stdio: 'pipe' });
        this.recordTest('security', 'npm audit available', true);
        console.log('  ✅ npm audit');
      } catch {
        this.recordTest('security', 'npm audit not available', false);
        console.log('  ❌ npm audit - NOT AVAILABLE');
      }

      // Check if package.json has security scripts
      const packageJsonFile = 'package.json';
      if (fs.existsSync(packageJsonFile)) {
        const content = JSON.parse(fs.readFileSync(packageJsonFile, 'utf8'));

        const securityScripts = [
          'security:audit',
          'security:fix',
          'test:security',
        ];

        for (const script of securityScripts) {
          if (content.scripts && content.scripts[script]) {
            this.recordTest(
              'security',
              `Security script present: ${script}`,
              true
            );
            console.log(`  ✅ ${script}`);
          } else {
            this.recordTest(
              'security',
              `Security script missing: ${script}`,
              false
            );
            console.log(`  ❌ ${script} - MISSING`);
          }
        }
      }

      // Check for Rust security tools in blockchain-core
      const cargoTomlFile = 'blockchain-core/Cargo.toml';
      if (fs.existsSync(cargoTomlFile)) {
        try {
          execSync('cargo audit --version', {
            stdio: 'pipe',
            cwd: 'blockchain-core',
          });
          this.recordTest('security', 'cargo audit available', true);
          console.log('  ✅ cargo audit');
        } catch {
          this.recordTest('security', 'cargo audit not available', false);
          console.log('  ❌ cargo audit - NOT AVAILABLE');
        }
      }
    } catch (error) {
      this.recordTest(
        'security',
        `Security tool validation failed: ${error.message}`,
        false
      );
      console.log(`  ❌ Security tool validation failed: ${error.message}`);
    }

    console.log('');
  }

  recordTest(category, description, passed) {
    this.results[category].tests.push({ description, passed });
    if (passed) {
      this.results[category].passed++;
    } else {
      this.results[category].failed++;
    }
  }

  calculateOverallScore() {
    const categories = ['security', 'monitoring', 'rollback', 'dependencies'];
    let totalTests = 0;
    let totalPassed = 0;

    for (const category of categories) {
      totalTests +=
        this.results[category].passed + this.results[category].failed;
      totalPassed += this.results[category].passed;
    }

    const score =
      totalTests > 0 ? Math.round((totalPassed / totalTests) * 100) : 0;

    this.results.overall.score = score;
    this.results.overall.status =
      score >= 90
        ? 'excellent'
        : score >= 80
          ? 'good'
          : score >= 70
            ? 'acceptable'
            : 'needs-improvement';

    return { score, status: this.results.overall.status };
  }

  async generateValidationReport() {
    console.log('📋 Generating Validation Report...\n');

    const { score, status } = this.calculateOverallScore();

    console.log('='.repeat(60));
    console.log('🛡️  SECURITY GATEKEEPING VALIDATION REPORT');
    console.log('='.repeat(60));

    // Overall score
    const statusEmoji = {
      excellent: '🟢',
      good: '🟡',
      acceptable: '🟠',
      'needs-improvement': '🔴',
    };

    console.log(
      `\n${statusEmoji[status]} OVERALL SCORE: ${score}% (${status.toUpperCase()})\n`
    );

    // Category breakdown
    const categories = [
      { key: 'security', name: 'Security Scanning' },
      { key: 'dependencies', name: 'Dependency Management' },
      { key: 'monitoring', name: 'Monitoring & Alerting' },
      { key: 'rollback', name: 'Rollback Mechanisms' },
    ];

    for (const category of categories) {
      const results = this.results[category.key];
      const total = results.passed + results.failed;
      const percentage =
        total > 0 ? Math.round((results.passed / total) * 100) : 0;

      console.log(`📊 ${category.name}:`);
      console.log(`   Passed: ${results.passed}/${total} (${percentage}%)`);

      if (results.failed > 0) {
        console.log('   Failed tests:');
        results.tests
          .filter(test => !test.passed)
          .forEach(test => console.log(`     ❌ ${test.description}`));
      }
      console.log('');
    }

    // Recommendations
    console.log('💡 RECOMMENDATIONS:\n');

    if (score < 100) {
      if (this.results.security.failed > 0) {
        console.log(
          '🔒 Security: Complete missing security scanning integrations'
        );
      }
      if (this.results.dependencies.failed > 0) {
        console.log(
          '📦 Dependencies: Configure missing dependency management features'
        );
      }
      if (this.results.monitoring.failed > 0) {
        console.log(
          '📊 Monitoring: Set up missing monitoring services and alerts'
        );
      }
      if (this.results.rollback.failed > 0) {
        console.log('🔄 Rollback: Implement missing rollback mechanisms');
      }
    } else {
      console.log(
        '✅ All security gatekeeping components are properly configured!'
      );
    }

    console.log('\n📚 Next Steps:');
    console.log('1. Review and address any failed validations');
    console.log('2. Test security workflows with sample vulnerabilities');
    console.log('3. Verify monitoring alerts are properly routed');
    console.log('4. Test rollback mechanisms in staging environment');
    console.log('5. Set up remote caching for Turborepo builds');

    // Save detailed report
    const detailedReport = {
      timestamp: new Date().toISOString(),
      overall: this.results.overall,
      categories: this.results,
      recommendations: this.generateDetailedRecommendations(),
    };

    fs.writeFileSync(
      'security-gatekeeping-validation-report.json',
      JSON.stringify(detailedReport, null, 2)
    );

    console.log(
      '\n📄 Detailed report saved to: security-gatekeeping-validation-report.json'
    );

    console.log('\n' + '='.repeat(60));
    console.log('✅ Security Gatekeeping Validation Complete');
    console.log('='.repeat(60));
  }

  generateDetailedRecommendations() {
    const recommendations = [];

    // Security recommendations
    if (this.results.security.failed > 0) {
      recommendations.push({
        category: 'Security',
        priority: 'High',
        actions: [
          'Install and configure missing security scanning tools',
          'Set up Snyk for dependency vulnerability scanning',
          'Configure SonarQube for code quality and security analysis',
          'Implement OWASP ZAP for dynamic security testing',
        ],
      });
    }

    // Dependency management recommendations
    if (this.results.dependencies.failed > 0) {
      recommendations.push({
        category: 'Dependencies',
        priority: 'High',
        actions: [
          'Complete Dependabot configuration for all package ecosystems',
          'Set up automatic security update grouping',
          'Configure daily security update schedules',
          'Implement dependency approval workflows',
        ],
      });
    }

    // Monitoring recommendations
    if (this.results.monitoring.failed > 0) {
      recommendations.push({
        category: 'Monitoring',
        priority: 'Medium',
        actions: [
          'Deploy comprehensive monitoring stack',
          'Configure security-specific alerting rules',
          'Set up distributed tracing for security events',
          'Implement log aggregation and analysis',
        ],
      });
    }

    // Rollback recommendations
    if (this.results.rollback.failed > 0) {
      recommendations.push({
        category: 'Rollback',
        priority: 'Medium',
        actions: [
          'Implement automated health check monitoring',
          'Configure multi-region rollback capabilities',
          'Set up database backup automation',
          'Test emergency rollback procedures',
        ],
      });
    }

    return recommendations;
  }
}

// CLI interface
async function main() {
  const validator = new SecurityGatekeepingValidator();
  await validator.validate();
}

// Handle script execution
if (require.main === module) {
  main().catch(error => {
    console.error('❌ Validation failed:', error);
    process.exit(1);
  });
}

module.exports = { SecurityGatekeepingValidator };
