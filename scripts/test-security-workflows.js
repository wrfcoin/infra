#!/usr/bin/env node

/**
 * Security Workflow Testing Script
 * Tests all security gatekeeping workflows and mechanisms
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

class SecurityWorkflowTester {
  constructor() {
    this.testResults = [];
    this.testSummary = {
      total: 0,
      passed: 0,
      failed: 0,
      skipped: 0,
    };
  }

  async runTests() {
    console.log('🧪 Starting Security Workflow Tests...\n');

    try {
      await this.testSecurityScanning();
      await this.testDependencyScanning();
      await this.testMonitoringSetup();
      await this.testRollbackMechanisms();
      await this.testComplianceChecks();

      this.generateTestReport();
    } catch (error) {
      console.error('❌ Testing failed:', error.message);
      process.exit(1);
    }
  }

  async testSecurityScanning() {
    console.log('🔍 Testing Security Scanning...');

    // Test 1: npm audit
    await this.runTest('Security Scanning', 'npm audit execution', async () => {
      try {
        const result = execSync('npm audit --audit-level=moderate --json', {
          stdio: 'pipe',
          encoding: 'utf8',
        });

        const auditData = JSON.parse(result);
        console.log(
          `  📊 Found ${auditData.metadata?.vulnerabilities?.total || 0} vulnerabilities`
        );

        return {
          success: true,
          message: `npm audit completed successfully`,
          details: auditData.metadata,
        };
      } catch (error) {
        // npm audit exits with non-zero for vulnerabilities, parse output
        try {
          const auditData = JSON.parse(error.stdout);
          console.log(
            `  📊 Found ${auditData.metadata?.vulnerabilities?.total || 0} vulnerabilities`
          );

          return {
            success: true,
            message: 'npm audit completed with vulnerabilities detected',
            details: auditData.metadata,
          };
        } catch (parseError) {
          throw error;
        }
      }
    });

    // Test 2: ESLint security plugin
    await this.runTest(
      'Security Scanning',
      'ESLint security rules',
      async () => {
        try {
          // Check if ESLint security plugin is configured
          const eslintrcFiles = [
            '.eslintrc.js',
            '.eslintrc.json',
            '.eslintrc.yml',
          ];
          let eslintConfig = null;

          for (const file of eslintrcFiles) {
            if (fs.existsSync(file)) {
              const content = fs.readFileSync(file, 'utf8');
              eslintConfig = content;
              break;
            }
          }

          if (eslintConfig && eslintConfig.includes('security')) {
            return {
              success: true,
              message: 'ESLint security plugin configured',
            };
          } else {
            return {
              success: false,
              message: 'ESLint security plugin not found in configuration',
            };
          }
        } catch (error) {
          throw error;
        }
      }
    );

    // Test 3: Cargo audit (for Rust blockchain core)
    await this.runTest(
      'Security Scanning',
      'Cargo audit for Rust dependencies',
      async () => {
        if (!fs.existsSync('blockchain-core/Cargo.toml')) {
          return {
            success: true,
            message: 'Skipped - Rust project not found',
            skipped: true,
          };
        }

        try {
          const result = execSync('cargo audit --json', {
            stdio: 'pipe',
            encoding: 'utf8',
            cwd: 'blockchain-core',
          });

          const auditData = JSON.parse(result);
          const vulnCount = auditData.vulnerabilities?.list?.length || 0;
          console.log(`  📊 Found ${vulnCount} Rust vulnerabilities`);

          return {
            success: true,
            message: `Cargo audit completed - ${vulnCount} vulnerabilities found`,
            details: { vulnerabilities: vulnCount },
          };
        } catch (error) {
          // Check if cargo-audit is installed
          if (error.message.includes('cargo-audit')) {
            return {
              success: false,
              message:
                'cargo-audit not installed. Run: cargo install cargo-audit',
            };
          }
          throw error;
        }
      }
    );

    // Test 4: Hardhat security for smart contracts
    await this.runTest(
      'Security Scanning',
      'Smart contract security tools',
      async () => {
        if (
          !fs.existsSync('contracts') ||
          !fs.existsSync('hardhat.config.js')
        ) {
          return {
            success: true,
            message: 'Skipped - Smart contracts not found',
            skipped: true,
          };
        }

        try {
          // Check if slither or mythril are configured
          const packageJson = JSON.parse(
            fs.readFileSync('package.json', 'utf8')
          );
          const hasSecurityTools =
            packageJson.devDependencies &&
            (packageJson.devDependencies['@crytic/slither'] ||
              packageJson.devDependencies['mythx-cli'] ||
              packageJson.scripts?.['security:contracts']);

          if (hasSecurityTools) {
            return {
              success: true,
              message: 'Smart contract security tools configured',
            };
          } else {
            return {
              success: false,
              message: 'Smart contract security tools not configured',
            };
          }
        } catch (error) {
          throw error;
        }
      }
    );

    console.log('');
  }

  async testDependencyScanning() {
    console.log('📦 Testing Dependency Management...');

    // Test 1: Dependabot configuration
    await this.runTest(
      'Dependency Management',
      'Dependabot configuration',
      async () => {
        const dependabotFile = '.github/dependabot.yml';
        if (!fs.existsSync(dependabotFile)) {
          return {
            success: false,
            message: 'Dependabot configuration file not found',
          };
        }

        const content = fs.readFileSync(dependabotFile, 'utf8');

        // Check for required ecosystems
        const requiredEcosystems = ['npm', 'cargo', 'docker', 'github-actions'];
        const missingEcosystems = requiredEcosystems.filter(
          eco => !content.includes(`package-ecosystem: "${eco}"`)
        );

        if (missingEcosystems.length === 0) {
          return {
            success: true,
            message: 'All required ecosystems configured',
          };
        } else {
          return {
            success: false,
            message: `Missing ecosystems: ${missingEcosystems.join(', ')}`,
          };
        }
      }
    );

    // Test 2: Package.json security scripts
    await this.runTest(
      'Dependency Management',
      'Security scripts in package.json',
      async () => {
        const packageJson = JSON.parse(fs.readFileSync('package.json', 'utf8'));

        const requiredScripts = ['security:audit', 'security:fix'];
        const missingScripts = requiredScripts.filter(
          script => !packageJson.scripts || !packageJson.scripts[script]
        );

        if (missingScripts.length === 0) {
          return {
            success: true,
            message: 'All security scripts configured',
          };
        } else {
          return {
            success: false,
            message: `Missing scripts: ${missingScripts.join(', ')}`,
          };
        }
      }
    );

    // Test 3: Dependency update automation
    await this.runTest(
      'Dependency Management',
      'Automated dependency updates',
      async () => {
        const dependabotFile = '.github/dependabot.yml';
        if (!fs.existsSync(dependabotFile)) {
          return {
            success: false,
            message: 'Dependabot not configured',
          };
        }

        const content = fs.readFileSync(dependabotFile, 'utf8');

        // Check for daily schedule
        if (content.includes('interval: "daily"')) {
          return {
            success: true,
            message: 'Daily security updates configured',
          };
        } else {
          return {
            success: false,
            message: 'Daily security updates not configured',
          };
        }
      }
    );

    console.log('');
  }

  async testMonitoringSetup() {
    console.log('📊 Testing Monitoring Setup...');

    // Test 1: Monitoring configuration files
    await this.runTest(
      'Monitoring',
      'Monitoring configuration files',
      async () => {
        const requiredFiles = [
          'infra/monitoring/docker-compose.comprehensive-monitoring.yml',
          'infra/monitoring/alert-rules-enhanced.yml',
        ];

        const missingFiles = requiredFiles.filter(file => !fs.existsSync(file));

        if (missingFiles.length === 0) {
          return {
            success: true,
            message: 'All monitoring configuration files present',
          };
        } else {
          return {
            success: false,
            message: `Missing files: ${missingFiles.join(', ')}`,
          };
        }
      }
    );

    // Test 2: Docker compose monitoring services
    await this.runTest(
      'Monitoring',
      'Monitoring services configuration',
      async () => {
        const monitoringFile =
          'infra/monitoring/docker-compose.comprehensive-monitoring.yml';
        if (!fs.existsSync(monitoringFile)) {
          return {
            success: false,
            message: 'Monitoring docker-compose file not found',
          };
        }

        const content = fs.readFileSync(monitoringFile, 'utf8');

        // Check for required services
        const requiredServices = [
          'prometheus',
          'grafana',
          'elasticsearch',
          'kibana',
        ];
        const missingServices = requiredServices.filter(
          service => !content.includes(`${service}:`)
        );

        if (missingServices.length === 0) {
          return {
            success: true,
            message: 'All monitoring services configured',
          };
        } else {
          return {
            success: false,
            message: `Missing services: ${missingServices.join(', ')}`,
          };
        }
      }
    );

    // Test 3: Alert rules configuration
    await this.runTest('Monitoring', 'Security alert rules', async () => {
      const alertRulesFile = 'infra/monitoring/alert-rules-enhanced.yml';
      if (!fs.existsSync(alertRulesFile)) {
        return {
          success: false,
          message: 'Alert rules file not found',
        };
      }

      const content = fs.readFileSync(alertRulesFile, 'utf8');

      // Check for security-specific alerts
      const requiredAlerts = [
        'SecurityScanFailed',
        'HighVulnerabilityDetected',
      ];
      const missingAlerts = requiredAlerts.filter(
        alert => !content.includes(alert)
      );

      if (missingAlerts.length === 0) {
        return {
          success: true,
          message: 'Security alert rules configured',
        };
      } else {
        return {
          success: false,
          message: `Missing alerts: ${missingAlerts.join(', ')}`,
        };
      }
    });

    console.log('');
  }

  async testRollbackMechanisms() {
    console.log('🔄 Testing Rollback Mechanisms...');

    // Test 1: Rollback workflow configuration
    await this.runTest('Rollback', 'Automated rollback workflow', async () => {
      const rollbackFile = '.github/workflows/automated-rollback.yml';
      if (!fs.existsSync(rollbackFile)) {
        return {
          success: false,
          message: 'Automated rollback workflow not found',
        };
      }

      const content = fs.readFileSync(rollbackFile, 'utf8');

      // Check for rollback triggers
      const requiredFeatures = ['health-check', 'error-rate', 'kubectl'];
      const missingFeatures = requiredFeatures.filter(
        feature => !content.includes(feature)
      );

      if (missingFeatures.length === 0) {
        return {
          success: true,
          message: 'Rollback workflow properly configured',
        };
      } else {
        return {
          success: false,
          message: `Missing features: ${missingFeatures.join(', ')}`,
        };
      }
    });

    // Test 2: Canary monitoring script
    await this.runTest('Rollback', 'Canary deployment monitoring', async () => {
      const canaryScript = 'scripts/canary-health-monitor.js';
      if (!fs.existsSync(canaryScript)) {
        return {
          success: false,
          message: 'Canary health monitor script not found',
        };
      }

      // Test that the script can be loaded without errors
      try {
        const { CanaryHealthMonitor } = require(path.resolve(canaryScript));
        const monitor = new CanaryHealthMonitor({
          canaryPercentage: 10,
          rollbackThreshold: 5,
          monitoringDuration: 60,
        });

        return {
          success: true,
          message: 'Canary health monitor script valid',
        };
      } catch (error) {
        return {
          success: false,
          message: `Canary script error: ${error.message}`,
        };
      }
    });

    // Test 3: Health check endpoints (mock test)
    await this.runTest('Rollback', 'Health check configuration', async () => {
      // Check if health check configurations exist
      const possibleHealthFiles = [
        'backend/routes/health.js',
        'backend/api/health.js',
        'backend/src/health.js',
      ];

      const healthFileExists = possibleHealthFiles.some(file =>
        fs.existsSync(file)
      );

      if (healthFileExists) {
        return {
          success: true,
          message: 'Health check endpoints configured',
        };
      } else {
        return {
          success: false,
          message: 'Health check endpoints not found',
        };
      }
    });

    console.log('');
  }

  async testComplianceChecks() {
    console.log('📋 Testing Compliance...');

    // Test 1: Security documentation
    await this.runTest('Compliance', 'Security documentation', async () => {
      const docFile = 'docs/CICD_SECURITY_GATEKEEPING.md';
      if (!fs.existsSync(docFile)) {
        return {
          success: false,
          message: 'Security documentation not found',
        };
      }

      const content = fs.readFileSync(docFile, 'utf8');

      // Check for required sections
      const requiredSections = [
        'Security Gates',
        'Emergency Response',
        'Compliance',
      ];
      const missingSections = requiredSections.filter(
        section => !content.includes(section)
      );

      if (missingSections.length === 0) {
        return {
          success: true,
          message: 'Complete security documentation',
        };
      } else {
        return {
          success: false,
          message: `Missing sections: ${missingSections.join(', ')}`,
        };
      }
    });

    // Test 2: Audit trail configuration
    await this.runTest('Compliance', 'Audit trail setup', async () => {
      // Check for logging configuration
      const logConfigFiles = [
        'infra/monitoring/docker-compose.comprehensive-monitoring.yml',
      ];

      let auditTrailConfigured = false;

      for (const file of logConfigFiles) {
        if (fs.existsSync(file)) {
          const content = fs.readFileSync(file, 'utf8');
          if (
            content.includes('elasticsearch') &&
            content.includes('logstash')
          ) {
            auditTrailConfigured = true;
            break;
          }
        }
      }

      if (auditTrailConfigured) {
        return {
          success: true,
          message: 'Audit trail logging configured',
        };
      } else {
        return {
          success: false,
          message: 'Audit trail logging not configured',
        };
      }
    });

    // Test 3: Security gate enforcement
    await this.runTest('Compliance', 'Security gate enforcement', async () => {
      const securityGateFile = '.github/workflows/enhanced-security-gate.yml';
      if (!fs.existsSync(securityGateFile)) {
        return {
          success: false,
          message: 'Security gate workflow not found',
        };
      }

      const content = fs.readFileSync(securityGateFile, 'utf8');

      // Check for gate enforcement logic
      if (
        content.includes('security-gate-status') &&
        content.includes('failure()')
      ) {
        return {
          success: true,
          message: 'Security gate enforcement configured',
        };
      } else {
        return {
          success: false,
          message: 'Security gate enforcement not configured',
        };
      }
    });

    console.log('');
  }

  async runTest(category, name, testFunction) {
    this.testSummary.total++;

    try {
      const result = await testFunction();

      if (result.skipped) {
        this.testSummary.skipped++;
        console.log(`  ⏭️  ${name} - SKIPPED (${result.message})`);
        this.testResults.push({
          category,
          name,
          status: 'skipped',
          message: result.message,
        });
      } else if (result.success) {
        this.testSummary.passed++;
        console.log(`  ✅ ${name} - PASSED`);
        this.testResults.push({
          category,
          name,
          status: 'passed',
          message: result.message,
          details: result.details,
        });
      } else {
        this.testSummary.failed++;
        console.log(`  ❌ ${name} - FAILED (${result.message})`);
        this.testResults.push({
          category,
          name,
          status: 'failed',
          message: result.message,
        });
      }
    } catch (error) {
      this.testSummary.failed++;
      console.log(`  ❌ ${name} - ERROR (${error.message})`);
      this.testResults.push({
        category,
        name,
        status: 'error',
        message: error.message,
      });
    }
  }

  generateTestReport() {
    console.log('📋 Generating Test Report...\n');

    const passRate =
      this.testSummary.total > 0
        ? Math.round((this.testSummary.passed / this.testSummary.total) * 100)
        : 0;

    console.log('='.repeat(60));
    console.log('🧪 SECURITY WORKFLOW TEST REPORT');
    console.log('='.repeat(60));

    console.log(`\n📊 TEST SUMMARY:`);
    console.log(`   Total Tests: ${this.testSummary.total}`);
    console.log(`   Passed: ${this.testSummary.passed}`);
    console.log(`   Failed: ${this.testSummary.failed}`);
    console.log(`   Skipped: ${this.testSummary.skipped}`);
    console.log(`   Pass Rate: ${passRate}%\n`);

    // Group results by category
    const categories = [...new Set(this.testResults.map(r => r.category))];

    for (const category of categories) {
      const categoryTests = this.testResults.filter(
        r => r.category === category
      );
      const categoryPassed = categoryTests.filter(
        r => r.status === 'passed'
      ).length;
      const categoryTotal = categoryTests.length;
      const categoryRate = Math.round((categoryPassed / categoryTotal) * 100);

      console.log(
        `📂 ${category} (${categoryPassed}/${categoryTotal} - ${categoryRate}%):`
      );

      for (const test of categoryTests) {
        const emoji =
          test.status === 'passed'
            ? '✅'
            : test.status === 'skipped'
              ? '⏭️'
              : '❌';
        console.log(`   ${emoji} ${test.name}`);
        if (test.status === 'failed' || test.status === 'error') {
          console.log(`      Reason: ${test.message}`);
        }
      }
      console.log('');
    }

    // Recommendations
    console.log('💡 RECOMMENDATIONS:\n');

    const failedTests = this.testResults.filter(
      r => r.status === 'failed' || r.status === 'error'
    );

    if (failedTests.length === 0) {
      console.log(
        '✅ All security workflows are properly configured and tested!'
      );
    } else {
      console.log('🔧 Address the following issues:');
      failedTests.forEach((test, index) => {
        console.log(`${index + 1}. ${test.category}: ${test.name}`);
        console.log(`   Issue: ${test.message}`);
      });
    }

    console.log('\n📚 Next Steps:');
    console.log('1. Address any failed tests');
    console.log('2. Run security workflows in GitHub Actions');
    console.log('3. Test rollback mechanisms in staging');
    console.log('4. Verify monitoring alerts work correctly');
    console.log('5. Document any custom security procedures');

    // Save detailed report
    const detailedReport = {
      timestamp: new Date().toISOString(),
      summary: this.testSummary,
      results: this.testResults,
      passRate: passRate,
    };

    fs.writeFileSync(
      'security-workflow-test-report.json',
      JSON.stringify(detailedReport, null, 2)
    );

    console.log(
      '\n📄 Detailed report saved to: security-workflow-test-report.json'
    );

    console.log('\n' + '='.repeat(60));
    console.log('✅ Security Workflow Testing Complete');
    console.log('='.repeat(60));

    // Exit with error code if tests failed
    if (this.testSummary.failed > 0) {
      process.exit(1);
    }
  }
}

// CLI interface
async function main() {
  const tester = new SecurityWorkflowTester();
  await tester.runTests();
}

// Handle script execution
if (require.main === module) {
  main().catch(error => {
    console.error('❌ Testing failed:', error);
    process.exit(1);
  });
}

module.exports = { SecurityWorkflowTester };
