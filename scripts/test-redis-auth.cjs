#!/usr/bin/env node

/**
 * Quick Redis Authentication Test Script
 * Tests Redis authentication when services are running
 */

const Redis = require('ioredis');

const colors = {
  reset: '\x1b[0m',
  bright: '\x1b[1m',
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
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

async function testRedisAuth() {
  log.header('🔒 Quick Redis Authentication Test');

  // Test configuration
  const configs = [
    {
      name: 'Main Redis (localhost)',
      host: 'localhost',
      port: 6379,
      password: process.env.REDIS_PASSWORD || '',
    },
    {
      name: 'Main Redis (container)',
      host: 'redis-cache',
      port: 6379,
      password: process.env.REDIS_PASSWORD || '',
    },
  ];

  for (const config of configs) {
    log.info(`Testing ${config.name}...`);

    if (!config.password) {
      log.warning('No password configured - skipping test');
      continue;
    }

    try {
      // Test with authentication
      const client = new Redis({
        host: config.host,
        port: config.port,
        password: config.password,
        connectTimeout: 3000,
        lazyConnect: true,
        maxRetriesPerRequest: 1,
      });

      const start = Date.now();
      await client.ping();
      const pingTime = Date.now() - start;

      log.success(`Authenticated connection successful (${pingTime}ms)`);

      // Test unauthenticated access
      try {
        const unauthClient = new Redis({
          host: config.host,
          port: config.port,
          password: '',
          connectTimeout: 2000,
          lazyConnect: true,
          maxRetriesPerRequest: 1,
        });

        await unauthClient.ping();
        log.error('SECURITY ISSUE: Unauthenticated access allowed!');
        await unauthClient.quit();
      } catch (authError) {
        log.success('Unauthenticated access properly rejected');
      }

      await client.quit();
    } catch (error) {
      if (
        error.code === 'ECONNREFUSED' ||
        error.code === 'ENOTFOUND' ||
        error.code === 'ETIMEDOUT'
      ) {
        log.warning(`Service not available: ${error.message}`);
      } else {
        log.error(`Connection failed: ${error.message}`);
      }
    }
  }

  log.header('Test completed');
}

// Run test
testRedisAuth().catch(console.error);
