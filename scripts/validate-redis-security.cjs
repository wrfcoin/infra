#!/usr/bin/env node

/**
 * WRFCoin Redis Security Validation Script
 * Validates Redis security configuration across all services and environments
 */

const Redis = require('ioredis');
const fs = require('fs').promises;
const path = require('path');
const {
  createSecureRedisConnection,
  testRedisConnection,
} = require('../backend/server/utils/redis-connection');

// ANSI color codes for terminal output
const colors = {
  reset: '\x1b[0m',
  bright: '\x1b[1m',
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  magenta: '\x1b[35m',
  cyan: '\x1b[36m',
};

const log = {
  info: msg => console.log(`${colors.blue}ℹ${colors.reset} ${msg}`),
  success: msg => console.log(`${colors.green}✓${colors.reset} ${msg}`),
  warning: msg => console.log(`${colors.yellow}⚠${colors.reset} ${msg}`),
  error: msg => console.log(`${colors.red}✗${colors.reset} ${msg}`),
  header: msg =>
    console.log(`\n${colors.bright}${colors.cyan}${msg}${colors.reset}\n`),
};

class RedisSecurityValidator {
  constructor() {
    this.results = {
      tests: [],
      summary: {
        total: 0,
        passed: 0,
        failed: 0,
        warnings: 0,
      },
    };
  }

  /**
   * Add test result
   */
  addResult(test, status, message, details = null) {
    const result = {
      test,
      status, // 'pass', 'fail', 'warning'
      message,
      details,
      timestamp: new Date().toISOString(),
    };

    this.results.tests.push(result);
    this.results.summary.total++;

    if (status === 'pass') {
      this.results.summary.passed++;
      log.success(`${test}: ${message}`);
    } else if (status === 'fail') {
      this.results.summary.failed++;
      log.error(`${test}: ${message}`);
    } else if (status === 'warning') {
      this.results.summary.warnings++;
      log.warning(`${test}: ${message}`);
    }

    if (details) {
      console.log(
        `   ${colors.cyan}Details:${colors.reset} ${JSON.stringify(details, null, 2)}`
      );
    }
  }

  /**
   * Test Redis connection security
   */
  async testRedisConnection(name, config) {
    try {
      const client = createSecureRedisConnection(config);
      const testResult = await testRedisConnection(client);

      if (testResult.success) {
        this.addResult(
          `Redis Connection (${name})`,
          'pass',
          'Connection established successfully with authentication',
          {
            host: config.host,
            port: config.port,
            passwordConfigured: !!config.password,
            pingTime: testResult.pingTime,
            version: testResult.version,
          }
        );
      } else {
        this.addResult(
          `Redis Connection (${name})`,
          'fail',
          'Connection failed',
          testResult
        );
      }

      await client.quit();
    } catch (error) {
      this.addResult(
        `Redis Connection (${name})`,
        'fail',
        `Connection error: ${error.message}`,
        { error: error.code }
      );
    }
  }

  /**
   * Test unauthenticated access
   */
  async testUnauthenticatedAccess(name, config) {
    try {
      // Try to connect without password
      const unauthConfig = { ...config, password: '' };
      const client = new Redis(unauthConfig);

      try {
        await client.ping();

        this.addResult(
          `Unauthenticated Access Test (${name})`,
          'fail',
          'Redis allows unauthenticated access - SECURITY VULNERABILITY',
          { host: config.host, port: config.port }
        );

        await client.quit();
      } catch (authError) {
        this.addResult(
          `Unauthenticated Access Test (${name})`,
          'pass',
          'Redis properly rejects unauthenticated access',
          { authError: authError.message }
        );
      }
    } catch (error) {
      this.addResult(
        `Unauthenticated Access Test (${name})`,
        'warning',
        `Could not test unauthenticated access: ${error.message}`
      );
    }
  }

  /**
   * Test dangerous commands
   */
  async testDangerousCommands(name, config) {
    try {
      const client = createSecureRedisConnection(config);
      const dangerousCommands = [
        'FLUSHDB',
        'FLUSHALL',
        'KEYS',
        'CONFIG',
        'DEBUG',
        'EVAL',
        'SCRIPT',
      ];

      for (const command of dangerousCommands) {
        try {
          // Try to execute the dangerous command
          if (command === 'KEYS') {
            await client.keys('*');
          } else if (command === 'CONFIG') {
            await client.config('GET', '*');
          } else {
            await client.call(command.toLowerCase());
          }

          this.addResult(
            `Dangerous Command Test (${name})`,
            'fail',
            `Dangerous command '${command}' is available - SECURITY RISK`,
            { command, host: config.host }
          );
        } catch (cmdError) {
          if (
            cmdError.message.includes('unknown command') ||
            cmdError.message.includes('renamed')
          ) {
            this.addResult(
              `Dangerous Command Test (${name})`,
              'pass',
              `Dangerous command '${command}' is properly disabled/renamed`,
              { command }
            );
          } else {
            this.addResult(
              `Dangerous Command Test (${name})`,
              'warning',
              `Command '${command}' test inconclusive: ${cmdError.message}`,
              { command, error: cmdError.message }
            );
          }
        }
      }

      await client.quit();
    } catch (error) {
      this.addResult(
        `Dangerous Command Test (${name})`,
        'warning',
        `Could not test dangerous commands: ${error.message}`
      );
    }
  }

  /**
   * Validate environment variables
   */
  validateEnvironmentVariables() {
    const requiredVars = ['REDIS_PASSWORD'];
    const recommendedVars = ['ORACLE_REDIS_PASSWORD', 'REDIS_TLS'];

    for (const varName of requiredVars) {
      if (process.env[varName]) {
        if (process.env[varName].length < 16) {
          this.addResult(
            'Environment Variables',
            'warning',
            `${varName} is too short (< 16 characters)`,
            { variable: varName, length: process.env[varName].length }
          );
        } else {
          this.addResult(
            'Environment Variables',
            'pass',
            `${varName} is properly configured`,
            { variable: varName, length: process.env[varName].length }
          );
        }
      } else {
        this.addResult(
          'Environment Variables',
          'fail',
          `${varName} is not set`,
          { variable: varName }
        );
      }
    }

    for (const varName of recommendedVars) {
      if (process.env[varName]) {
        this.addResult(
          'Environment Variables',
          'pass',
          `${varName} is configured`,
          { variable: varName }
        );
      } else {
        this.addResult(
          'Environment Variables',
          'warning',
          `${varName} is not set (recommended for enhanced security)`,
          { variable: varName }
        );
      }
    }
  }

  /**
   * Check Docker Compose configurations
   */
  async validateDockerComposeConfigs() {
    const dockerComposeFiles = [
      'docker-compose.yml',
      'infra/docker/docker-compose.yml',
      'docker/docker-compose.oracle.yml',
      'infra/monitoring/docker-compose.monitoring-complete.yml',
    ];

    for (const file of dockerComposeFiles) {
      try {
        const content = await fs.readFile(
          path.join(process.cwd(), file),
          'utf8'
        );

        // Check for exposed Redis ports
        if (content.includes('6379:6379') && !content.includes('# ports:')) {
          this.addResult(
            'Docker Configuration',
            'fail',
            `${file} exposes Redis port 6379 publicly - SECURITY RISK`,
            { file, issue: 'public_port_exposure' }
          );
        } else {
          this.addResult(
            'Docker Configuration',
            'pass',
            `${file} does not expose Redis ports publicly`,
            { file }
          );
        }

        // Check for password configuration
        if (
          content.includes('--requirepass') ||
          content.includes('REDIS_PASSWORD')
        ) {
          this.addResult(
            'Docker Configuration',
            'pass',
            `${file} includes Redis password configuration`,
            { file }
          );
        } else {
          this.addResult(
            'Docker Configuration',
            'warning',
            `${file} may not include Redis password configuration`,
            { file }
          );
        }
      } catch (error) {
        this.addResult(
          'Docker Configuration',
          'warning',
          `Could not read ${file}: ${error.message}`,
          { file, error: error.message }
        );
      }
    }
  }

  /**
   * Run all security tests
   */
  async runAllTests() {
    log.header('🔒 WRFCoin Redis Security Validation');

    // Test 1: Environment Variables
    log.info('Testing environment variables...');
    this.validateEnvironmentVariables();

    // Test 2: Docker Compose Configurations
    log.info('Validating Docker Compose configurations...');
    await this.validateDockerComposeConfigs();

    // Test 3: Redis Connections
    log.info('Testing Redis connections...');

    // Define test configurations
    const testConfigs = [
      {
        name: 'Main Redis',
        config: {
          host: process.env.REDIS_HOST || 'redis-cache',
          port: parseInt(process.env.REDIS_PORT) || 6379,
          password: process.env.REDIS_PASSWORD || '',
        },
      },
      {
        name: 'Oracle Redis',
        config: {
          host: 'oracle-redis',
          port: 6379,
          password: process.env.ORACLE_REDIS_PASSWORD || '',
        },
      },
    ];

    for (const { name, config } of testConfigs) {
      if (config.password) {
        await this.testRedisConnection(name, config);
        await this.testUnauthenticatedAccess(name, config);
        await this.testDangerousCommands(name, config);
      } else {
        this.addResult(
          `Redis Tests (${name})`,
          'warning',
          'Skipping connection tests - no password configured',
          { host: config.host, port: config.port }
        );
      }
    }

    // Generate summary
    this.generateSummary();
  }

  /**
   * Generate validation summary
   */
  generateSummary() {
    log.header('📊 Validation Summary');

    const { total, passed, failed, warnings } = this.results.summary;

    console.log(`${colors.bright}Total Tests:${colors.reset} ${total}`);
    console.log(`${colors.green}Passed:${colors.reset} ${passed}`);
    console.log(`${colors.red}Failed:${colors.reset} ${failed}`);
    console.log(`${colors.yellow}Warnings:${colors.reset} ${warnings}`);

    const successRate = total > 0 ? ((passed / total) * 100).toFixed(1) : 0;
    console.log(`${colors.bright}Success Rate:${colors.reset} ${successRate}%`);

    // Security recommendations
    if (failed > 0 || warnings > 0) {
      log.header('🛡️  Security Recommendations');

      if (failed > 0) {
        log.error(
          'CRITICAL: Fix all failed tests before deploying to production'
        );
      }

      log.info('Review warnings and implement recommended security measures');
      log.info('Regularly rotate Redis passwords');
      log.info('Monitor Redis access logs for suspicious activity');
      log.info('Use TLS encryption for Redis connections in production');
    }

    // Exit with appropriate code
    if (failed > 0) {
      process.exit(1);
    } else if (warnings > 0) {
      process.exit(2);
    } else {
      log.success('All Redis security tests passed!');
      process.exit(0);
    }
  }

  /**
   * Save results to file
   */
  async saveResults(filename = 'redis-security-validation.json') {
    try {
      await fs.writeFile(
        path.join(process.cwd(), filename),
        JSON.stringify(this.results, null, 2)
      );
      log.info(`Results saved to ${filename}`);
    } catch (error) {
      log.error(`Failed to save results: ${error.message}`);
    }
  }
}

// Main execution
async function main() {
  try {
    const validator = new RedisSecurityValidator();
    await validator.runAllTests();
    await validator.saveResults();
  } catch (error) {
    log.error(`Validation failed: ${error.message}`);
    console.error(error);
    process.exit(1);
  }
}

// Run if called directly
if (require.main === module) {
  main().catch(console.error);
}

module.exports = { RedisSecurityValidator };
