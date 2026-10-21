#!/usr/bin/env node

/**
 * Test Environment Setup Script
 *
 * Sets up the complete testing environment including:
 * - Database initialization
 * - Contract deployment
 * - Test data seeding
 * - Service startup
 */

const { spawn, exec } = require('child_process');
const fs = require('fs');
const path = require('path');

class TestEnvironmentSetup {
  constructor() {
    this.processes = [];
    this.cleanup = this.cleanup.bind(this);

    // Handle cleanup on exit
    process.on('SIGINT', this.cleanup);
    process.on('SIGTERM', this.cleanup);
    process.on('exit', this.cleanup);
  }

  async setup() {
    console.log('🚀 Setting up test environment...');

    try {
      await this.setupDatabase();
      await this.startBlockchain();
      await this.deployContracts();
      await this.startServices();
      await this.seedTestData();

      console.log('✅ Test environment ready!');
      return true;
    } catch (error) {
      console.error('❌ Test setup failed:', error);
      await this.cleanup();
      return false;
    }
  }

  async setupDatabase() {
    console.log('📊 Setting up test database...');

    return new Promise((resolve, reject) => {
      const dbSetup = spawn('npm', ['run', 'db:setup:test'], {
        cwd: path.join(__dirname, '../backend/graphql'),
        stdio: 'inherit',
      });

      dbSetup.on('close', code => {
        if (code === 0) {
          console.log('✅ Database setup complete');
          resolve();
        } else {
          reject(new Error(`Database setup failed with code ${code}`));
        }
      });
    });
  }

  async startBlockchain() {
    console.log('⛓️  Starting local blockchain...');

    return new Promise((resolve, reject) => {
      const hardhatNode = spawn('npx', ['hardhat', 'node', '--detach'], {
        stdio: 'pipe',
      });

      this.processes.push(hardhatNode);

      setTimeout(() => {
        console.log('✅ Local blockchain started');
        resolve();
      }, 10000); // Wait 10 seconds for blockchain to start
    });
  }

  async deployContracts() {
    console.log('📝 Deploying test contracts...');

    return new Promise((resolve, reject) => {
      const deploy = spawn(
        'npx',
        ['hardhat', 'run', 'scripts/deploy.js', '--network', 'localhost'],
        {
          stdio: 'inherit',
        }
      );

      deploy.on('close', code => {
        if (code === 0) {
          console.log('✅ Contracts deployed');
          resolve();
        } else {
          reject(new Error(`Contract deployment failed with code ${code}`));
        }
      });
    });
  }

  async startServices() {
    console.log('🔧 Starting backend services...');

    // Start GraphQL API
    const apiProcess = spawn('npm', ['run', 'start:test'], {
      cwd: path.join(__dirname, '../backend/graphql'),
      stdio: 'pipe',
      env: {
        ...process.env,
        NODE_ENV: 'test',
        DATABASE_URL:
          process.env.TEST_DATABASE_URL ||
          'postgresql://postgres:testpass@localhost:5432/wrfcoin_test',
        REDIS_URL: process.env.TEST_REDIS_URL || 'redis://localhost:6379',
      },
    });

    this.processes.push(apiProcess);

    // Start frontend in test mode
    if (process.env.START_FRONTEND !== 'false') {
      const frontendProcess = spawn('npm', ['run', 'dev:test'], {
        stdio: 'pipe',
        env: {
          ...process.env,
          NODE_ENV: 'test',
          NEXT_PUBLIC_API_URL: 'http://localhost:4000/graphql',
          NEXT_PUBLIC_CHAIN_ID: '31337',
        },
      });

      this.processes.push(frontendProcess);
    }

    // Wait for services to start
    await new Promise(resolve => setTimeout(resolve, 15000));
    console.log('✅ Services started');
  }

  async seedTestData() {
    console.log('🌱 Seeding test data...');

    const seedScript = path.join(__dirname, 'seed-test-data-retired.js');
    if (fs.existsSync(seedScript)) {
      return new Promise((resolve, reject) => {
        const seed = spawn('node', [seedScript], {
          stdio: 'inherit',
        });

        seed.on('close', code => {
          if (code === 0) {
            console.log('✅ Test data seeded');
            resolve();
          } else {
            reject(new Error(`Test data seeding failed with code ${code}`));
          }
        });
      });
    } else {
      console.log('⚠️  No seed script found, skipping test data seeding');
    }
  }

  async cleanup() {
    console.log('🧹 Cleaning up test environment...');

    // Kill all spawned processes
    for (const process of this.processes) {
      try {
        process.kill('SIGTERM');
      } catch (error) {
        // Process might already be dead
      }
    }

    // Stop hardhat node if running
    try {
      exec('pkill -f "hardhat node"');
    } catch (error) {
      // Process might not be running
    }

    console.log('✅ Cleanup complete');
  }

  // Health check method
  async healthCheck() {
    console.log('🔍 Performing health check...');

    const checks = [
      this.checkBlockchain(),
      this.checkAPI(),
      this.checkDatabase(),
    ];

    const results = await Promise.allSettled(checks);
    const failures = results.filter(result => result.status === 'rejected');

    if (failures.length > 0) {
      console.error('❌ Health check failed:', failures);
      return false;
    }

    console.log('✅ All services healthy');
    return true;
  }

  async checkBlockchain() {
    return new Promise((resolve, reject) => {
      const check = spawn(
        'npx',
        ['hardhat', 'console', '--network', 'localhost'],
        {
          stdio: 'pipe',
        }
      );

      check.stdin.write('await ethers.provider.getBlockNumber()\n');
      check.stdin.write('.exit\n');

      check.on('close', code => {
        if (code === 0) {
          resolve('Blockchain OK');
        } else {
          reject(new Error('Blockchain check failed'));
        }
      });
    });
  }

  async checkAPI() {
    const fetch = require('node-fetch');

    try {
      const response = await fetch('http://localhost:4000/health');
      if (response.ok) {
        return 'API OK';
      } else {
        throw new Error('API health check failed');
      }
    } catch (error) {
      throw new Error('API unreachable');
    }
  }

  async checkDatabase() {
    return new Promise((resolve, reject) => {
      const check = spawn('npm', ['run', 'db:check'], {
        cwd: path.join(__dirname, '../backend/graphql'),
        stdio: 'pipe',
      });

      check.on('close', code => {
        if (code === 0) {
          resolve('Database OK');
        } else {
          reject(new Error('Database check failed'));
        }
      });
    });
  }
}

// CLI interface
if (require.main === module) {
  const command = process.argv[2];
  const setup = new TestEnvironmentSetup();

  switch (command) {
    case 'setup':
      setup.setup().then(success => {
        process.exit(success ? 0 : 1);
      });
      break;

    case 'cleanup':
      setup.cleanup().then(() => {
        process.exit(0);
      });
      break;

    case 'health':
      setup.healthCheck().then(healthy => {
        process.exit(healthy ? 0 : 1);
      });
      break;

    default:
      console.log('Usage: node test-setup.js [setup|cleanup|health]');
      process.exit(1);
  }
}

module.exports = TestEnvironmentSetup;
