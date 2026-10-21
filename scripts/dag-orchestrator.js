/**
 * DAG-Based Workflow Orchestrator for Wrfcoin
 * Implements dependency-aware startup, health monitoring, and cascading restarts
 */

const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const {
  GracefulShutdown,
  ShutdownPriority,
} = require('../backend/shared/graceful-shutdown/index.js');

class DAGOrchestrator {
  constructor() {
    this.workflows = new Map();
    this.dependencies = new Map();
    this.runningProcesses = new Map();
    this.healthChecks = new Map();
    this.startupOrder = [];
    this.retryAttempts = new Map();
    this.maxRetries = 3;
    this.healthCheckInterval = 15000; // 15 seconds

    this.loadWorkflowDefinitions();
    this.calculateStartupOrder();
  }

  loadWorkflowDefinitions() {
    // Define workflow dependencies based on your current architecture
    const workflowDefs = {
      // Foundation Layer - Database and Core Infrastructure
      database_setup: {
        command: 'node scripts/wrf-db-tool.js status',
        port: null,
        dependencies: [],
        category: 'foundation',
        healthCheck: 'database',
        critical: true,
      },

      // Core Protocol Layer
      websocket_server: {
        command: 'node backend/server/websocket.js',
        port: 8080,
        dependencies: ['database_setup'],
        category: 'protocol',
        healthCheck: 'http://localhost:8080/health',
      },

      cross_chain_protocol: {
        command: 'node backend/server/cross_chain_protocol_server.js',
        port: 3000,
        dependencies: ['database_setup'],
        category: 'protocol',
        healthCheck: 'http://localhost:3000/health',
      },

      compute_networks: {
        command: 'node backend/server/compute_networks_server.js',
        port: 6000,
        dependencies: ['database_setup'],
        category: 'protocol',
        healthCheck: 'http://localhost:6000/health',
      },

      iot_sensor_networks: {
        command: 'node backend/server/iot_sensor_networks_server_fixed.js',
        port: 6003,
        dependencies: ['database_setup'],
        category: 'protocol',
        healthCheck: 'http://localhost:3002/health',
      },

      // API and Service Layer
      cross_chain_websocket: {
        command: 'node backend/server/cross_chain_websocket_server.js',
        port: 8000,
        dependencies: ['cross_chain_protocol', 'websocket_server'],
        category: 'api',
        healthCheck: 'ws://localhost:5001',
      },

      unified_api_server: {
        command: 'node backend/server/unified_api_server.js',
        port: 3001,
        dependencies: ['cross_chain_protocol'],
        category: 'api',
        healthCheck: 'http://localhost:3001/health',
      },

      enhanced_weather_rewards: {
        command: 'node backend/server/enhanced_weather_rewards.js',
        port: 6004,
        dependencies: ['iot_sensor_networks', 'database_setup'],
        category: 'api',
        healthCheck: 'http://localhost:8001/health',
      },

      weather_earnings_transfer: {
        command: 'node backend/server/weather_earnings_transfer.js',
        port: 6005,
        dependencies: ['enhanced_weather_rewards'],
        category: 'api',
        healthCheck: 'http://localhost:3003/health',
      },

      ai_ml_networks: {
        command: 'node backend/server/ai_ml_networks_server.js',
        port: 6001,
        dependencies: ['compute_networks'],
        category: 'api',
        healthCheck: 'http://localhost:6001/health',
      },

      contract_integration: {
        command: 'node contracts/integrations/contract-integration-server.js',
        port: 9000,
        dependencies: ['cross_chain_protocol'],
        category: 'api',
        healthCheck: 'http://localhost:9000/health',
      },

      node_discovery: {
        command: 'node backend/server/easy_node_discovery.js',
        port: 9001,
        dependencies: ['unified_api_server'],
        category: 'api',
        healthCheck: 'http://localhost:9001/health',
      },

      // Application Layer
      acurite_collector: {
        command: 'node acurite-working-collector.js',
        port: null,
        dependencies: ['weather_earnings_transfer'],
        category: 'application',
        healthCheck: 'process',
      },

      frontend_application: {
        command: 'cd frontend && npm run dev -- --host 0.0.0.0 --port 5000',
        port: 5000,
        dependencies: ['unified_api_server', 'cross_chain_websocket'],
        category: 'application',
        healthCheck: 'http://localhost:5000',
      },

      // Management Layer
      service_control_panel: {
        command: 'node scripts/service-control-panel.js',
        port: 2001,
        dependencies: ['unified_api_server'],
        category: 'management',
        healthCheck: 'http://localhost:2001/health',
      },

      memory_optimized_server: {
        command: 'node backend/server/memory_optimized_server.js',
        port: null,
        dependencies: [],
        category: 'management',
        healthCheck: 'process',
      },
    };

    // Load workflows and dependencies
    for (const [name, config] of Object.entries(workflowDefs)) {
      this.workflows.set(name, config);
      this.dependencies.set(name, config.dependencies || []);
      this.retryAttempts.set(name, 0);
    }
  }

  calculateStartupOrder() {
    // Implement Kahn's algorithm for topological sorting
    const inDegree = new Map();
    const queue = [];

    // Initialize in-degree for all nodes
    for (const workflow of this.workflows.keys()) {
      inDegree.set(workflow, 0);
    }

    // Calculate in-degrees
    for (const [workflow, deps] of this.dependencies) {
      for (const dep of deps) {
        inDegree.set(workflow, (inDegree.get(workflow) || 0) + 1);
      }
    }

    // Find nodes with no dependencies
    for (const [workflow, degree] of inDegree) {
      if (degree === 0) {
        queue.push(workflow);
      }
    }

    // Process queue
    while (queue.length > 0) {
      const current = queue.shift();
      this.startupOrder.push(current);

      // Reduce in-degree for dependent workflows
      for (const [workflow, deps] of this.dependencies) {
        if (deps.includes(current)) {
          const newDegree = inDegree.get(workflow) - 1;
          inDegree.set(workflow, newDegree);
          if (newDegree === 0) {
            queue.push(workflow);
          }
        }
      }
    }

    // Check for cycles
    if (this.startupOrder.length !== this.workflows.size) {
      throw new Error('Circular dependency detected in workflow DAG!');
    }

    console.log('📋 Calculated DAG startup order:');
    this.printStartupOrder();
  }

  printStartupOrder() {
    const categories = [
      'foundation',
      'protocol',
      'api',
      'application',
      'management',
    ];

    for (const category of categories) {
      const workflows = this.startupOrder.filter(
        name => this.workflows.get(name).category === category
      );

      if (workflows.length > 0) {
        console.log(`\n🏗️  ${category.toUpperCase()} Layer:`);
        workflows.forEach((workflow, index) => {
          const config = this.workflows.get(workflow);
          const portInfo = config.port ? ` (port ${config.port})` : '';
          console.log(`   ${index + 1}. ${workflow}${portInfo}`);
        });
      }
    }
  }

  sanitizeCommand(command) {
    // Security: Validate command against allowed patterns
    if (!command || typeof command !== 'string') {
      throw new Error('Invalid command: must be a non-empty string');
    }

    // Define allowed command patterns for this workflow orchestrator
    const allowedPatterns = [
      /^node\s+[\w\-\.\/]+\.js(\s+.*)?$/, // Node.js scripts
      /^cd\s+[\w\-\.\/]+\s+&&\s+npm\s+run\s+dev\s+.*$/, // Frontend dev server
      /^npm\s+(start|run\s+[\w\-]+)(\s+.*)?$/, // NPM commands
      /^cargo\s+run(\s+.*)?$/, // Rust commands (for WVM)
    ];

    // Check if command matches any allowed pattern
    const isAllowed = allowedPatterns.some(pattern =>
      pattern.test(command.trim())
    );

    if (!isAllowed) {
      throw new Error(`Command not allowed: ${command}`);
    }

    // Additional validation: block dangerous characters and sequences
    const dangerousPatterns = [
      /[;&|`$(){}]/, // Shell metacharacters
      /\.\./, // Directory traversal
      /rm\s+-rf/, // Dangerous rm commands
      />/, // Output redirection
      /</, // Input redirection
      /\|\|/, // OR operator
      /&&.*rm/, // Chained dangerous commands
    ];

    const isDangerous = dangerousPatterns.some(pattern =>
      pattern.test(command)
    );

    if (isDangerous) {
      throw new Error(`Command contains dangerous patterns: ${command}`);
    }

    return command.trim();
  }

  async checkPortConflicts() {
    const usedPorts = new Set();
    const conflicts = [];

    for (const [name, config] of this.workflows) {
      if (config.port) {
        if (usedPorts.has(config.port)) {
          conflicts.push(`Port ${config.port} conflict: ${name}`);
        } else {
          usedPorts.add(config.port);
        }
      }
    }

    if (conflicts.length > 0) {
      console.log('⚠️  Port conflicts detected:');
      conflicts.forEach(conflict => console.log(`   ${conflict}`));
      return false;
    }

    console.log('✅ No port conflicts detected');
    return true;
  }

  async startWorkflow(name) {
    const config = this.workflows.get(name);
    if (!config) {
      throw new Error(`Workflow ${name} not found`);
    }

    console.log(`🚀 Starting ${name}...`);

    try {
      // Security: Validate and sanitize command before execution
      const sanitizedCommand = this.sanitizeCommand(config.command);
      const process = spawn('bash', ['-c', sanitizedCommand], {
        stdio: ['ignore', 'pipe', 'pipe'],
        detached: false,
      });

      this.runningProcesses.set(name, process);

      // Setup process monitoring
      process.stdout.on('data', data => {
        console.log(`[${name}] ${data.toString().trim()}`);
      });

      process.stderr.on('data', data => {
        console.error(`[${name}] ERROR: ${data.toString().trim()}`);
      });

      process.on('exit', code => {
        console.log(`[${name}] Exited with code ${code}`);
        this.runningProcesses.delete(name);

        if (code !== 0) {
          this.handleWorkflowFailure(name);
        }
      });

      // Wait for service to be ready
      await this.waitForHealth(name);
      console.log(`✅ ${name} started successfully`);
    } catch (error) {
      console.error(`❌ Failed to start ${name}:`, error.message);
      throw error;
    }
  }

  async waitForHealth(name, timeout = 30000) {
    const config = this.workflows.get(name);
    const startTime = Date.now();

    while (Date.now() - startTime < timeout) {
      try {
        const healthy = await this.checkHealth(name);
        if (healthy) {
          return true;
        }
      } catch (error) {
        // Health check failed, continue waiting
      }

      await new Promise(resolve => setTimeout(resolve, 2000));
    }

    throw new Error(`Health check timeout for ${name}`);
  }

  async checkHealth(name) {
    const config = this.workflows.get(name);
    const healthCheck = config.healthCheck;

    if (!healthCheck) return true;

    try {
      if (healthCheck === 'database') {
        // Check database connectivity
        return await this.checkDatabaseHealth();
      } else if (healthCheck === 'process') {
        // Check if process is running
        return this.runningProcesses.has(name);
      } else if (healthCheck.startsWith('http')) {
        // HTTP health check
        const response = await fetch(healthCheck);
        return response.ok;
      } else if (healthCheck.startsWith('ws')) {
        // WebSocket health check
        return await this.checkWebSocketHealth(healthCheck);
      }
    } catch (error) {
      return false;
    }

    return false;
  }

  async checkDatabaseHealth() {
    try {
      // Simple database connection test
      const { Pool } = require('pg');
      const pool = new Pool({ connectionString: process.env.DATABASE_URL });
      const result = await pool.query('SELECT 1');
      await pool.end();
      return result.rows.length > 0;
    } catch (error) {
      return false;
    }
  }

  async checkWebSocketHealth(wsUrl) {
    return new Promise(resolve => {
      try {
        const WebSocket = require('ws');
        const ws = new WebSocket(wsUrl);

        ws.on('open', () => {
          ws.close();
          resolve(true);
        });

        ws.on('error', () => {
          resolve(false);
        });

        setTimeout(() => {
          ws.close();
          resolve(false);
        }, 5000);
      } catch (error) {
        resolve(false);
      }
    });
  }

  async handleWorkflowFailure(name) {
    const retries = this.retryAttempts.get(name) || 0;

    if (retries < this.maxRetries) {
      console.log(
        `🔄 Retrying ${name} (attempt ${retries + 1}/${this.maxRetries})`
      );
      this.retryAttempts.set(name, retries + 1);

      // Wait before retry
      await new Promise(resolve => setTimeout(resolve, 5000));

      try {
        await this.startWorkflow(name);
      } catch (error) {
        console.error(`❌ Retry failed for ${name}`);
      }
    } else {
      console.error(`💥 ${name} failed after ${this.maxRetries} attempts`);

      // Check if this affects downstream services
      await this.handleCascadingFailure(name);
    }
  }

  async handleCascadingFailure(failedWorkflow) {
    const affected = [];

    // Find downstream workflows
    for (const [workflow, deps] of this.dependencies) {
      if (deps.includes(failedWorkflow)) {
        affected.push(workflow);
      }
    }

    if (affected.length > 0) {
      console.log(
        `⚠️  Cascading failure detected. Affected workflows: ${affected.join(', ')}`
      );

      // Stop affected services gracefully
      for (const workflow of affected) {
        await this.stopWorkflow(workflow);
      }
    }
  }

  async stopWorkflow(name) {
    const process = this.runningProcesses.get(name);
    if (process) {
      console.log(`🛑 Stopping ${name}...`);
      process.kill('SIGTERM');

      // Wait for graceful shutdown
      await new Promise(resolve => setTimeout(resolve, 3000));

      if (this.runningProcesses.has(name)) {
        console.log(`💀 Force killing ${name}...`);
        process.kill('SIGKILL');
      }
    }
  }

  async startAll() {
    console.log('🎯 Starting DAG-orchestrated workflow deployment...\n');

    // Check for port conflicts first
    const noConflicts = await this.checkPortConflicts();
    if (!noConflicts) {
      throw new Error('Port conflicts must be resolved before starting');
    }

    // Start workflows in dependency order
    for (const workflowName of this.startupOrder) {
      try {
        await this.startWorkflow(workflowName);

        // Brief pause between startups
        await new Promise(resolve => setTimeout(resolve, 2000));
      } catch (error) {
        console.error(`💥 Failed to start ${workflowName}:`, error.message);

        // Check if this is a critical service
        const config = this.workflows.get(workflowName);
        if (config.critical) {
          console.error('❌ Critical service failed. Aborting startup.');
          throw error;
        }

        console.log('⚠️  Non-critical service failed. Continuing...');
      }
    }

    console.log('\n🎉 DAG orchestration complete!');
    this.startHealthMonitoring();
  }

  startHealthMonitoring() {
    console.log('🏥 Starting continuous health monitoring...');

    this.healthMonitorInterval = setInterval(async () => {
      for (const [name, config] of this.workflows) {
        if (this.runningProcesses.has(name)) {
          const healthy = await this.checkHealth(name);
          if (!healthy) {
            console.log(`⚠️  Health check failed for ${name}`);
            await this.handleWorkflowFailure(name);
          }
        }
      }
    }, this.healthCheckInterval);
  }

  /**
   * Stop all running workflows and cleanup
   */
  async stopAll() {
    console.log('🛑 Stopping all workflows...');

    // Stop health monitoring
    if (this.healthMonitorInterval) {
      clearInterval(this.healthMonitorInterval);
      this.healthMonitorInterval = null;
    }

    // Stop all running processes in reverse order
    const reverseOrder = [...this.startupOrder].reverse();
    for (const name of reverseOrder) {
      if (this.runningProcesses.has(name)) {
        await this.stopWorkflow(name);
      }
    }

    console.log('🛑 All workflows stopped');
  }

  getStatus() {
    const status = {
      running: [],
      stopped: [],
      healthy: [],
      unhealthy: [],
    };

    for (const name of this.workflows.keys()) {
      if (this.runningProcesses.has(name)) {
        status.running.push(name);
      } else {
        status.stopped.push(name);
      }
    }

    return status;
  }

  printStatus() {
    const status = this.getStatus();

    console.log('\n📊 Workflow Status:');
    console.log(`✅ Running: ${status.running.length}`);
    console.log(`❌ Stopped: ${status.stopped.length}`);

    if (status.running.length > 0) {
      console.log('\n🟢 Running workflows:');
      status.running.forEach(name => {
        const config = this.workflows.get(name);
        const portInfo = config.port ? ` (port ${config.port})` : '';
        console.log(`   • ${name}${portInfo}`);
      });
    }

    if (status.stopped.length > 0) {
      console.log('\n🔴 Stopped workflows:');
      status.stopped.forEach(name => console.log(`   • ${name}`));
    }
  }
}

// CLI Interface
async function main() {
  const orchestrator = new DAGOrchestrator();
  const command = process.argv[2] || 'start';

  try {
    switch (command) {
      case 'start':
        // Setup graceful shutdown for the orchestrator
        const shutdown = GracefulShutdown.getInstance({
          globalTimeout: 60000, // 60s timeout for stopping all services
        });

        shutdown.registerHandler({
          name: 'dag-orchestrator',
          priority: ShutdownPriority.STOP_BACKGROUND_JOBS,
          handler: () => orchestrator.stopAll(),
        });

        shutdown.setupSignalHandlers();

        await orchestrator.startAll();
        break;

      case 'status':
        orchestrator.printStatus();
        break;

      case 'order':
        orchestrator.printStartupOrder();
        break;

      case 'conflicts':
        await orchestrator.checkPortConflicts();
        break;

      default:
        console.log(
          'Usage: node dag-orchestrator.js [start|status|order|conflicts]'
        );
    }
  } catch (error) {
    console.error('💥 Orchestrator error:', error.message);
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}

module.exports = DAGOrchestrator;
