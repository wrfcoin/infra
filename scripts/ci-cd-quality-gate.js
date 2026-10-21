#!/usr/bin/env node

/**
 * CI/CD Quality Gate Script
 * Orchestrates comprehensive testing pipeline with parallel execution and quality enforcement
 */

const { spawn, execSync } = require('child_process');
const path = require('path');
const fs = require('fs').promises;

class CICDQualityGate {
  constructor(options = {}) {
    this.options = {
      skipCoverage: options.skipCoverage || false,
      skipPerformance: options.skipPerformance || false,
      skipSecurity: options.skipSecurity || false,
      parallel: options.parallel !== false, // Default to true
      verbose: options.verbose || process.env.VERBOSE === 'true',
      ...options,
    };

    this.startTime = Date.now();
    this.results = {};
    this.exitCode = 0;
  }

  /**
   * Main pipeline execution
   */
  async run() {
    console.log('🚀 Starting CI/CD Quality Gate Pipeline');
    console.log('=' * 50);

    try {
      // Phase 1: Pre-flight checks
      await this.preflightChecks();

      // Phase 2: Parallel test execution
      if (this.options.parallel) {
        await this.runParallelTests();
      } else {
        await this.runSequentialTests();
      }

      // Phase 3: Coverage analysis and enforcement
      if (!this.options.skipCoverage) {
        await this.enforceCoverage();
      }

      // Phase 4: Performance regression detection
      if (!this.options.skipPerformance) {
        await this.detectPerformanceRegressions();
      }

      // Phase 5: Security validation
      if (!this.options.skipSecurity) {
        await this.validateSecurity();
      }

      // Phase 6: Generate comprehensive report
      await this.generateFinalReport();

      // Phase 7: Quality gate decision
      this.makeQualityGateDecision();
    } catch (error) {
      console.error('💥 Pipeline failed:', error.message);
      this.exitCode = 1;
    } finally {
      await this.cleanup();
      this.printFinalSummary();
      process.exit(this.exitCode);
    }
  }

  /**
   * Pre-flight environment and dependency checks
   */
  async preflightChecks() {
    console.log('🔍 Running pre-flight checks...');

    const checks = [
      () => this.checkNodeVersion(),
      () => this.checkDependencies(),
      () => this.checkEnvironmentVariables(),
      () => this.prepareTestEnvironment(),
    ];

    for (const check of checks) {
      await check();
    }

    console.log('✅ Pre-flight checks completed');
  }

  /**
   * Check Node.js version compatibility
   */
  async checkNodeVersion() {
    const version = process.version;
    const majorVersion = parseInt(version.split('.')[0].substring(1), 10);

    if (majorVersion < 18) {
      throw new Error(`Node.js 18+ required, found ${version}`);
    }

    console.log(`  ✅ Node.js version: ${version}`);
  }

  /**
   * Check required dependencies
   */
  async checkDependencies() {
    const requiredPackages = ['jest', 'playwright', '@lhci/cli'];

    for (const pkg of requiredPackages) {
      try {
        require.resolve(pkg);
        console.log(`  ✅ ${pkg} available`);
      } catch (error) {
        throw new Error(`Required package missing: ${pkg}`);
      }
    }
  }

  /**
   * Check environment variables
   */
  async checkEnvironmentVariables() {
    const requiredEnvVars = ['NODE_ENV'];
    const optionalEnvVars = ['WEBPAGETEST_API_KEY', 'LIGHTHOUSE_CI_TOKEN'];

    for (const envVar of requiredEnvVars) {
      if (!process.env[envVar]) {
        throw new Error(`Required environment variable missing: ${envVar}`);
      }
      console.log(`  ✅ ${envVar} set`);
    }

    for (const envVar of optionalEnvVars) {
      if (process.env[envVar]) {
        console.log(`  ✅ ${envVar} available`);
      } else {
        console.log(`  ⚠️  ${envVar} not set (optional)`);
      }
    }
  }

  /**
   * Prepare test environment
   */
  async prepareTestEnvironment() {
    // Ensure test results directory exists
    const resultsDir = path.join(process.cwd(), 'tests/results');
    await fs.mkdir(resultsDir, { recursive: true });

    // Clean previous results
    const cleanCommand = 'npm run coverage:clean';
    try {
      execSync(cleanCommand, {
        stdio: this.options.verbose ? 'inherit' : 'pipe',
      });
      console.log('  ✅ Test environment prepared');
    } catch (error) {
      console.warn('  ⚠️  Could not clean previous results:', error.message);
    }
  }

  /**
   * Run tests in parallel for optimal performance
   */
  async runParallelTests() {
    console.log('🏃 Running parallel test execution...');

    const testSuites = [
      {
        name: 'Unit Tests',
        command: 'npm run test:unit',
        timeout: 300000, // 5 minutes
        critical: true,
      },
      {
        name: 'Integration Tests',
        command: 'npm run test:integration',
        timeout: 600000, // 10 minutes
        critical: true,
      },
      {
        name: 'Frontend Tests',
        command: 'npm run test:frontend',
        timeout: 300000, // 5 minutes
        critical: false,
      },
      {
        name: 'Smart Contract Tests',
        command: 'npm run test:smart-contracts',
        timeout: 480000, // 8 minutes
        critical: true,
      },
    ];

    const promises = testSuites.map(suite => this.runTestSuite(suite));
    const results = await Promise.allSettled(promises);

    // Analyze results
    results.forEach((result, index) => {
      const suite = testSuites[index];
      if (result.status === 'fulfilled') {
        this.results[suite.name] = { passed: true, ...result.value };
        console.log(`  ✅ ${suite.name} completed`);
      } else {
        this.results[suite.name] = {
          passed: false,
          error: result.reason.message,
        };
        console.log(`  ❌ ${suite.name} failed: ${result.reason.message}`);

        if (suite.critical) {
          this.exitCode = 1;
        }
      }
    });
  }

  /**
   * Run tests sequentially (fallback)
   */
  async runSequentialTests() {
    console.log('🔄 Running sequential test execution...');

    const testCommands = [
      'npm run test:unit',
      'npm run test:integration',
      'npm run test:smart-contracts',
    ];

    for (const command of testCommands) {
      try {
        await this.runCommand(command);
        console.log(`  ✅ ${command} completed`);
      } catch (error) {
        console.log(`  ❌ ${command} failed: ${error.message}`);
        this.exitCode = 1;
      }
    }
  }

  /**
   * Run individual test suite
   */
  async runTestSuite(suite) {
    return new Promise((resolve, reject) => {
      const startTime = Date.now();

      const process = spawn('npm', ['run', suite.command.split(' ')[2]], {
        stdio: this.options.verbose ? 'inherit' : 'pipe',
        env: {
          ...process.env,
          COVERAGE: 'false', // Coverage will be run separately
          CI: 'true',
        },
      });

      const timeout = setTimeout(() => {
        process.kill('SIGKILL');
        reject(new Error(`Timeout after ${suite.timeout}ms`));
      }, suite.timeout);

      process.on('close', code => {
        clearTimeout(timeout);
        const duration = Date.now() - startTime;

        if (code === 0) {
          resolve({ duration, exitCode: code });
        } else {
          reject(new Error(`Process exited with code ${code}`));
        }
      });

      process.on('error', error => {
        clearTimeout(timeout);
        reject(error);
      });
    });
  }

  /**
   * Enforce code coverage requirements
   */
  async enforceCoverage() {
    console.log('📊 Enforcing code coverage requirements...');

    try {
      // Run coverage analysis
      await this.runCommand('npm run test:coverage');

      // Run coverage enforcement
      const coverageEnforcer = require('../tests/utils/coverage-helpers.js');
      const { CoverageEnforcer } = coverageEnforcer;

      const enforcer = new CoverageEnforcer();
      const report = await enforcer.enforceCoverage();

      this.results.coverage = {
        passed: report.passed,
        coverage: report.coverage,
        thresholds: report.thresholds,
        violations: report.thresholdCheck.failures,
      };

      if (!report.passed) {
        console.log('❌ Coverage requirements not met');
        this.exitCode = 1;
      } else {
        console.log('✅ Coverage requirements satisfied');
      }
    } catch (error) {
      console.error('❌ Coverage enforcement failed:', error.message);
      this.results.coverage = { passed: false, error: error.message };
      this.exitCode = 1;
    }
  }

  /**
   * Detect performance regressions
   */
  async detectPerformanceRegressions() {
    console.log('⚡ Detecting performance regressions...');

    try {
      // Start the frontend for testing
      const serverProcess = await this.startTestServer();

      try {
        // Run Lighthouse CI
        await this.runLighthouseCI();

        // Run WebPageTest if API key available
        if (process.env.WEBPAGETEST_API_KEY) {
          await this.runWebPageTest();
        }

        this.results.performance = { passed: true };
        console.log('✅ Performance regression detection completed');
      } finally {
        // Stop the test server
        if (serverProcess) {
          serverProcess.kill('SIGTERM');
        }
      }
    } catch (error) {
      console.error(
        '❌ Performance regression detection failed:',
        error.message
      );
      this.results.performance = { passed: false, error: error.message };
      this.exitCode = 1;
    }
  }

  /**
   * Start test server for performance testing
   */
  async startTestServer() {
    return new Promise((resolve, reject) => {
      const server = spawn('npm', ['run', 'start:frontend'], {
        stdio: this.options.verbose ? 'inherit' : 'pipe',
        env: {
          ...process.env,
          NODE_ENV: 'test',
          PORT: '3000',
        },
      });

      // Wait for server to be ready
      setTimeout(() => {
        resolve(server);
      }, 10000); // 10 seconds

      server.on('error', reject);
    });
  }

  /**
   * Run Lighthouse CI
   */
  async runLighthouseCI() {
    const command = 'npx lhci autorun';
    await this.runCommand(command);
    console.log('  ✅ Lighthouse CI completed');
  }

  /**
   * Run WebPageTest
   */
  async runWebPageTest() {
    const WebPageTestRunner = require('../tests/performance/webpagetest-config.js');
    const { WRFWebPageTestRunner } = WebPageTestRunner;

    const runner = new WRFWebPageTestRunner();
    await runner.runFullSuite();
    console.log('  ✅ WebPageTest completed');
  }

  /**
   * Validate security requirements
   */
  async validateSecurity() {
    console.log('🔒 Validating security requirements...');

    try {
      // Run security test suite
      await this.runCommand('npm run test:security');

      // Run additional security tools if available
      try {
        await this.runCommand('npm run security:comprehensive');
      } catch (error) {
        console.warn(
          '  ⚠️  Additional security tools not available:',
          error.message
        );
      }

      this.results.security = { passed: true };
      console.log('✅ Security validation completed');
    } catch (error) {
      console.error('❌ Security validation failed:', error.message);
      this.results.security = { passed: false, error: error.message };
      this.exitCode = 1;
    }
  }

  /**
   * Generate comprehensive test report
   */
  async generateFinalReport() {
    console.log('📝 Generating comprehensive report...');

    try {
      const TestResultsProcessor = require('../tests/utils/test-results-processor.js');
      const { TestResultsProcessor: Processor } = TestResultsProcessor;

      const processor = new Processor();
      const report = await processor.generateReport();

      this.results.finalReport = report;

      if (!report.summary.overallPassed.passed) {
        console.log('❌ Quality gate analysis indicates failure');
        this.exitCode = 1;
      } else {
        console.log('✅ Quality gate analysis indicates success');
      }
    } catch (error) {
      console.error('❌ Report generation failed:', error.message);
      this.results.finalReport = { error: error.message };
    }
  }

  /**
   * Make final quality gate decision
   */
  makeQualityGateDecision() {
    const criticalFailures = [];

    // Check test results
    Object.entries(this.results).forEach(([name, result]) => {
      if (result && !result.passed && result.error) {
        criticalFailures.push(`${name}: ${result.error}`);
      }
    });

    // Check final report
    if (
      this.results.finalReport &&
      !this.results.finalReport.summary?.overallPassed?.passed
    ) {
      const blockingFactors =
        this.results.finalReport.summary.overallPassed.blockingFactors || [];
      criticalFailures.push(...blockingFactors);
    }

    if (criticalFailures.length > 0) {
      console.log('\n❌ QUALITY GATE FAILED');
      console.log('Blocking issues:');
      criticalFailures.forEach(failure => {
        console.log(`  • ${failure}`);
      });
      this.exitCode = 1;
    } else {
      console.log('\n✅ QUALITY GATE PASSED');
      console.log('All quality checks satisfied');
    }
  }

  /**
   * Cleanup resources
   */
  async cleanup() {
    // Cleanup operations
    console.log('🧹 Cleaning up...');

    try {
      // Kill any remaining processes
      execSync('pkill -f "npm run start" || true', { stdio: 'pipe' });
    } catch (error) {
      // Ignore cleanup errors
    }
  }

  /**
   * Print final pipeline summary
   */
  printFinalSummary() {
    const duration = Date.now() - this.startTime;

    console.log('\n🎯 CI/CD Pipeline Summary');
    console.log('=' * 40);
    console.log(`Duration: ${Math.round(duration / 1000)}s`);
    console.log(`Exit Code: ${this.exitCode}`);
    console.log(`Status: ${this.exitCode === 0 ? '✅ SUCCESS' : '❌ FAILED'}`);

    // Print component results
    Object.entries(this.results).forEach(([name, result]) => {
      if (result && typeof result.passed === 'boolean') {
        console.log(`${name}: ${result.passed ? '✅ PASSED' : '❌ FAILED'}`);
      }
    });
  }

  /**
   * Utility to run shell commands
   */
  async runCommand(command) {
    return new Promise((resolve, reject) => {
      const process = spawn('sh', ['-c', command], {
        stdio: this.options.verbose ? 'inherit' : 'pipe',
      });

      process.on('close', code => {
        if (code === 0) {
          resolve();
        } else {
          reject(
            new Error(`Command failed with exit code ${code}: ${command}`)
          );
        }
      });

      process.on('error', reject);
    });
  }
}

// CLI execution
if (require.main === module) {
  const args = process.argv.slice(2);
  const options = {};

  // Parse command line arguments
  args.forEach(arg => {
    if (arg === '--skip-coverage') options.skipCoverage = true;
    if (arg === '--skip-performance') options.skipPerformance = true;
    if (arg === '--skip-security') options.skipSecurity = true;
    if (arg === '--no-parallel') options.parallel = false;
    if (arg === '--verbose') options.verbose = true;
  });

  const pipeline = new CICDQualityGate(options);
  pipeline.run().catch(error => {
    console.error('Pipeline execution failed:', error);
    process.exit(1);
  });
}

module.exports = { CICDQualityGate };
