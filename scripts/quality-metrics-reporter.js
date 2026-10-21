#!/usr/bin/env node

/**
 * Quality Metrics Reporter for WRFCoin Platform
 *
 * This script collects and reports quality metrics from various sources:
 * - ESLint/Prettier results
 * - Jest coverage reports
 * - Rust Clippy/cargo test results
 * - SonarQube metrics (if available)
 * - Hardhat test/coverage results
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

class QualityMetricsReporter {
  constructor() {
    this.metrics = {
      timestamp: new Date().toISOString(),
      overall_score: 0,
      javascript: {
        lint_issues: 0,
        coverage: 0,
        test_results: null,
      },
      rust: {
        clippy_warnings: 0,
        coverage: 0,
        test_results: null,
      },
      contracts: {
        solhint_issues: 0,
        coverage: 0,
        test_results: null,
      },
      security: {
        vulnerabilities: 0,
        audit_issues: 0,
      },
    };
  }

  /**
   * Collect JavaScript/TypeScript metrics
   */
  async collectJavaScriptMetrics() {
    console.log('📊 Collecting JavaScript/TypeScript metrics...');

    try {
      // Run ESLint and capture output
      try {
        execSync('npm run lint 2>&1', { stdio: 'pipe' });
        this.metrics.javascript.lint_issues = 0;
      } catch (error) {
        const output = error.stdout?.toString() || '';
        const issues = (output.match(/problem/g) || []).length;
        this.metrics.javascript.lint_issues = issues;
        console.log(`  Found ${issues} ESLint issues`);
      }

      // Check Jest coverage
      const coveragePath = path.join(
        process.cwd(),
        'coverage',
        'coverage-summary.json'
      );
      if (fs.existsSync(coveragePath)) {
        const coverage = JSON.parse(fs.readFileSync(coveragePath, 'utf8'));
        this.metrics.javascript.coverage = coverage.total?.lines?.pct || 0;
        console.log(`  Coverage: ${this.metrics.javascript.coverage}%`);
      } else {
        console.log('  No coverage report found, running tests...');
        try {
          execSync('npm run test:coverage', { stdio: 'inherit' });
          if (fs.existsSync(coveragePath)) {
            const coverage = JSON.parse(fs.readFileSync(coveragePath, 'utf8'));
            this.metrics.javascript.coverage = coverage.total?.lines?.pct || 0;
          }
        } catch (error) {
          console.log('  Failed to generate coverage report');
        }
      }
    } catch (error) {
      console.error('Error collecting JavaScript metrics:', error.message);
    }
  }

  /**
   * Collect Rust metrics
   */
  async collectRustMetrics() {
    console.log('🦀 Collecting Rust metrics...');

    const rustDir = path.join(process.cwd(), 'blockchain-core');
    if (!fs.existsSync(rustDir)) {
      console.log('  No Rust directory found, skipping...');
      return;
    }

    try {
      // Run Clippy
      try {
        execSync(
          'cargo clippy --all-targets --all-features -- -D warnings 2>&1',
          {
            cwd: rustDir,
            stdio: 'pipe',
          }
        );
        this.metrics.rust.clippy_warnings = 0;
      } catch (error) {
        const output = error.stdout?.toString() || '';
        const warnings = (output.match(/warning:/g) || []).length;
        this.metrics.rust.clippy_warnings = warnings;
        console.log(`  Found ${warnings} Clippy warnings`);
      }

      // Run Rust tests
      try {
        const testOutput = execSync('cargo test --all-features 2>&1', {
          cwd: rustDir,
          encoding: 'utf8',
        });

        // Parse test results
        const testMatches = testOutput.match(
          /test result: (\w+)\. (\d+) passed; (\d+) failed/
        );
        if (testMatches) {
          this.metrics.rust.test_results = {
            status: testMatches[1],
            passed: parseInt(testMatches[2]),
            failed: parseInt(testMatches[3]),
          };
          console.log(
            `  Tests: ${testMatches[2]} passed, ${testMatches[3]} failed`
          );
        }
      } catch (error) {
        console.log('  Rust tests failed or incomplete');
        this.metrics.rust.test_results = { status: 'failed' };
      }

      // Try to get Rust coverage (if tarpaulin is available)
      try {
        const coverageOutput = execSync(
          'cargo tarpaulin --all-features --out Json 2>/dev/null',
          {
            cwd: rustDir,
            encoding: 'utf8',
          }
        );
        const coverage = JSON.parse(coverageOutput);
        this.metrics.rust.coverage = coverage.coverage || 0;
        console.log(`  Rust coverage: ${this.metrics.rust.coverage}%`);
      } catch (error) {
        console.log(
          '  Rust coverage not available (install cargo-tarpaulin for coverage)'
        );
      }
    } catch (error) {
      console.error('Error collecting Rust metrics:', error.message);
    }
  }

  /**
   * Collect Smart Contract metrics
   */
  async collectContractMetrics() {
    console.log('📜 Collecting Smart Contract metrics...');

    const contractsDir = path.join(process.cwd(), 'contracts');
    if (!fs.existsSync(contractsDir)) {
      console.log('  No contracts directory found, skipping...');
      return;
    }

    try {
      // Run Solhint
      try {
        execSync('npm run security:solhint 2>&1', { stdio: 'pipe' });
        this.metrics.contracts.solhint_issues = 0;
      } catch (error) {
        const output = error.stdout?.toString() || '';
        const issues = (output.match(/warning|error/g) || []).length;
        this.metrics.contracts.solhint_issues = issues;
        console.log(`  Found ${issues} Solhint issues`);
      }

      // Run contract tests and coverage
      try {
        execSync('npm run test:smart-contracts:coverage', { stdio: 'inherit' });

        const contractCoveragePath = path.join(
          process.cwd(),
          'coverage',
          'contracts',
          'coverage-summary.json'
        );
        if (fs.existsSync(contractCoveragePath)) {
          const coverage = JSON.parse(
            fs.readFileSync(contractCoveragePath, 'utf8')
          );
          this.metrics.contracts.coverage =
            coverage.total?.statements?.pct || 0;
          console.log(
            `  Contract coverage: ${this.metrics.contracts.coverage}%`
          );
        }
      } catch (error) {
        console.log('  Contract coverage not available');
      }
    } catch (error) {
      console.error('Error collecting contract metrics:', error.message);
    }
  }

  /**
   * Collect Security metrics
   */
  async collectSecurityMetrics() {
    console.log('🔒 Collecting Security metrics...');

    try {
      // Run npm audit
      try {
        const auditOutput = execSync('npm audit --json 2>/dev/null', {
          encoding: 'utf8',
        });
        const audit = JSON.parse(auditOutput);

        this.metrics.security.vulnerabilities = Object.values(
          audit.metadata?.vulnerabilities || {}
        ).reduce((sum, count) => sum + count, 0);

        console.log(
          `  Found ${this.metrics.security.vulnerabilities} npm vulnerabilities`
        );
      } catch (error) {
        console.log('  npm audit check failed');
      }

      // Additional security checks could be added here
      // - Slither results
      // - Other security scanners
    } catch (error) {
      console.error('Error collecting security metrics:', error.message);
    }
  }

  /**
   * Calculate overall quality score
   */
  calculateOverallScore() {
    console.log('🧮 Calculating overall quality score...');

    // Scoring algorithm (0-100):
    // - Coverage: 40% weight (JS: 20%, Rust: 10%, Contracts: 10%)
    // - Issues penalty: 30% weight
    // - Test success: 30% weight

    let score = 0;

    // Coverage component (40 points max)
    const jsCoverage = Math.min(this.metrics.javascript.coverage, 100) * 0.2;
    const rustCoverage = Math.min(this.metrics.rust.coverage, 100) * 0.1;
    const contractCoverage =
      Math.min(this.metrics.contracts.coverage, 100) * 0.1;
    score += jsCoverage + rustCoverage + contractCoverage;

    // Issues penalty (30 points max, deducted based on issues)
    const totalIssues =
      this.metrics.javascript.lint_issues +
      this.metrics.rust.clippy_warnings +
      this.metrics.contracts.solhint_issues +
      this.metrics.security.vulnerabilities;

    const issuesScore = Math.max(30 - totalIssues * 0.5, 0);
    score += issuesScore;

    // Test success component (30 points max)
    let testScore = 30;
    if (this.metrics.rust.test_results?.failed > 0) {
      testScore -= this.metrics.rust.test_results.failed * 2;
    }
    score += Math.max(testScore, 0);

    this.metrics.overall_score = Math.round(Math.min(score, 100));

    console.log(`  Overall Quality Score: ${this.metrics.overall_score}/100`);
  }

  /**
   * Generate and save report
   */
  async generateReport() {
    const reportDir = path.join(process.cwd(), 'reports');
    if (!fs.existsSync(reportDir)) {
      fs.mkdirSync(reportDir, { recursive: true });
    }

    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    const reportPath = path.join(
      reportDir,
      `quality-metrics-${timestamp}.json`
    );

    fs.writeFileSync(reportPath, JSON.stringify(this.metrics, null, 2));
    console.log(`\n📄 Report saved to: ${reportPath}`);

    // Also save as latest
    const latestPath = path.join(reportDir, 'quality-metrics-latest.json');
    fs.writeFileSync(latestPath, JSON.stringify(this.metrics, null, 2));

    return reportPath;
  }

  /**
   * Print summary to console
   */
  printSummary() {
    console.log('\n' + '='.repeat(50));
    console.log('📊 QUALITY METRICS SUMMARY');
    console.log('='.repeat(50));
    console.log(`Overall Score: ${this.metrics.overall_score}/100`);
    console.log(`\nJavaScript/TypeScript:`);
    console.log(`  ├─ Lint Issues: ${this.metrics.javascript.lint_issues}`);
    console.log(`  └─ Coverage: ${this.metrics.javascript.coverage}%`);
    console.log(`\nRust:`);
    console.log(`  ├─ Clippy Warnings: ${this.metrics.rust.clippy_warnings}`);
    console.log(`  └─ Coverage: ${this.metrics.rust.coverage}%`);
    console.log(`\nSmart Contracts:`);
    console.log(
      `  ├─ Solhint Issues: ${this.metrics.contracts.solhint_issues}`
    );
    console.log(`  └─ Coverage: ${this.metrics.contracts.coverage}%`);
    console.log(`\nSecurity:`);
    console.log(
      `  └─ Vulnerabilities: ${this.metrics.security.vulnerabilities}`
    );

    // Quality assessment
    if (this.metrics.overall_score >= 90) {
      console.log(`\n🎉 Excellent code quality!`);
    } else if (this.metrics.overall_score >= 80) {
      console.log(`\n✅ Good code quality`);
    } else if (this.metrics.overall_score >= 70) {
      console.log(`\n⚠️  Code quality needs improvement`);
    } else {
      console.log(`\n❌ Poor code quality - immediate attention required`);
    }

    console.log('='.repeat(50));
  }

  /**
   * Run complete metrics collection
   */
  async run() {
    console.log('🚀 Starting WRFCoin Quality Metrics Collection\n');

    await this.collectJavaScriptMetrics();
    await this.collectRustMetrics();
    await this.collectContractMetrics();
    await this.collectSecurityMetrics();

    this.calculateOverallScore();

    const reportPath = await this.generateReport();
    this.printSummary();

    return {
      metrics: this.metrics,
      reportPath,
    };
  }
}

// CLI execution
if (require.main === module) {
  const reporter = new QualityMetricsReporter();

  reporter
    .run()
    .then(({ metrics }) => {
      // Exit with appropriate code based on quality score
      if (metrics.overall_score < 70) {
        console.log('\n❌ Quality gates failed');
        process.exit(1);
      } else {
        console.log('\n✅ Quality gates passed');
        process.exit(0);
      }
    })
    .catch(error => {
      console.error('Error running quality metrics:', error);
      process.exit(1);
    });
}

module.exports = QualityMetricsReporter;
