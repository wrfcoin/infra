/**
 * Self-Healing Architecture Module
 * Automatically recovers from failures and attacks
 */
const { exec } = require('child_process');
const fs = require('fs').promises;

class SelfHealingSystem {
  constructor() {
    this.services = new Map();
    this.healthChecks = new Map();
    this.recoveryStrategies = new Map();
    this.failureHistory = [];
  }

  /**
   * Register service for monitoring
   */
  registerService(name, config) {
    this.services.set(name, {
      ...config,
      status: 'unknown',
      lastCheck: 0,
      failureCount: 0,
    });

    console.log(`🔧 Registered service for monitoring: ${name}`);
  }

  /**
   * Perform health check on service
   */
  async checkServiceHealth(serviceName) {
    const service = this.services.get(serviceName);
    if (!service) return false;

    try {
      let isHealthy = false;

      switch (service.type) {
        case 'http':
          const response = await fetch(service.healthUrl, { timeout: 5000 });
          isHealthy = response.ok;
          break;

        case 'process':
          const { stdout } = await this.execAsync(
            `pgrep -f "${service.processName}"`
          );
          isHealthy = stdout.trim().length > 0;
          break;

        case 'port':
          isHealthy = await this.checkPort(service.port);
          break;
      }

      service.status = isHealthy ? 'healthy' : 'unhealthy';
      service.lastCheck = Date.now();

      if (!isHealthy) {
        service.failureCount++;
        this.handleServiceFailure(serviceName, service);
      } else if (service.failureCount > 0) {
        console.log(`✅ Service ${serviceName} recovered`);
        service.failureCount = 0;
      }

      return isHealthy;
    } catch (error) {
      service.status = 'error';
      service.failureCount++;
      console.error(
        `❌ Health check failed for ${serviceName}: ${error.message}`
      );
      return false;
    }
  }

  /**
   * Handle service failure
   */
  async handleServiceFailure(serviceName, service) {
    console.log(
      `🚨 Service failure detected: ${serviceName} (failures: ${service.failureCount})`
    );

    this.failureHistory.push({
      service: serviceName,
      timestamp: Date.now(),
      failureCount: service.failureCount,
    });

    // Apply recovery strategy based on failure count
    if (service.failureCount === 1) {
      await this.restartService(serviceName);
    } else if (service.failureCount === 2) {
      await this.killAndRestartService(serviceName);
    } else if (service.failureCount >= 3) {
      await this.fullRecovery(serviceName);
    }
  }

  /**
   * Restart service gracefully
   */
  async restartService(serviceName) {
    console.log(`🔄 Attempting graceful restart of ${serviceName}`);
    const service = this.services.get(serviceName);

    if (service.restartCommand) {
      try {
        await this.execAsync(service.restartCommand);
        console.log(`✅ Restarted ${serviceName}`);
      } catch (error) {
        console.error(`❌ Failed to restart ${serviceName}: ${error.message}`);
      }
    }
  }

  /**
   * Force kill and restart service
   */
  async killAndRestartService(serviceName) {
    console.log(`💀 Force killing and restarting ${serviceName}`);
    const service = this.services.get(serviceName);

    try {
      // Kill process
      if (service.processName) {
        await this.execAsync(`pkill -f "${service.processName}"`);
      }

      // Wait a moment
      await new Promise(resolve => setTimeout(resolve, 2000));

      // Restart
      if (service.startCommand) {
        await this.execAsync(service.startCommand);
        console.log(`✅ Force restarted ${serviceName}`);
      }
    } catch (error) {
      console.error(
        `❌ Failed to force restart ${serviceName}: ${error.message}`
      );
    }
  }

  /**
   * Full recovery including cleanup
   */
  async fullRecovery(serviceName) {
    console.log(`🔧 Performing full recovery for ${serviceName}`);
    const service = this.services.get(serviceName);

    try {
      // Cleanup corrupted state
      if (service.cleanupCommand) {
        await this.execAsync(service.cleanupCommand);
      }

      // Reset configuration
      if (service.configReset) {
        await this.execAsync(service.configReset);
      }

      // Full restart
      await this.killAndRestartService(serviceName);

      console.log(`✅ Full recovery completed for ${serviceName}`);
    } catch (error) {
      console.error(
        `❌ Full recovery failed for ${serviceName}: ${error.message}`
      );
    }
  }

  /**
   * Start monitoring all services
   */
  startMonitoring() {
    console.log('🔧 Starting self-healing monitoring system');

    // Register core Wrfcoin services
    this.registerService('frontend', {
      type: 'http',
      healthUrl: 'http://localhost:5000',
      restartCommand: 'npm run dev --prefix frontend',
      processName: 'vite',
    });

    this.registerService('websocket', {
      type: 'port',
      port: 4002,
      restartCommand: 'node backend/server/websocket.js',
      processName: 'websocket.js',
    });

    this.registerService('cross-chain', {
      type: 'http',
      healthUrl: 'http://localhost:3000/health',
      restartCommand: 'node backend/server/cross_chain_protocol_server.js',
      processName: 'cross_chain_protocol_server.js',
    });

    // Start monitoring loop
    setInterval(async () => {
      for (const serviceName of this.services.keys()) {
        await this.checkServiceHealth(serviceName);
      }
    }, 30000); // Check every 30 seconds

    console.log('✅ Self-healing system active');
  }

  /**
   * Helper methods
   */
  sanitizeInput(input) {
    if (typeof input !== 'string') {
      throw new Error('Input must be a string');
    }
    // Remove dangerous characters and shell metacharacters
    return input.replace(/[;&|`$(){}[\]<>'"\\]/g, '');
  }

  async execAsync(command) {
    return new Promise((resolve, reject) => {
      // Sanitize the command to prevent injection
      const sanitizedCommand = this.sanitizeInput(command);

      // Additional validation - reject if command looks suspicious
      if (sanitizedCommand !== command) {
        reject(new Error('Command contains potentially dangerous characters'));
        return;
      }

      exec(sanitizedCommand, (error, stdout, stderr) => {
        if (error) reject(error);
        else resolve({ stdout, stderr });
      });
    });
  }

  async checkPort(port) {
    try {
      const { stdout } = await this.execAsync(`netstat -tuln | grep :${port}`);
      return stdout.includes(`:${port}`);
    } catch {
      return false;
    }
  }
}

module.exports = SelfHealingSystem;
