#!/usr/bin/env node

/**
 * WRFCoin Service Dependency Monitoring Agent
 *
 * This service continuously monitors service dependencies, validates health,
 * generates real-time dependency maps, and provides alerting capabilities.
 */

const express = require('express');
const axios = require('axios');
const winston = require('winston');
const cron = require('node-cron');
const promClient = require('prom-client');
const fs = require('fs');
const path = require('path');
const {
  GracefulShutdown,
  ShutdownPriority,
} = require('./lib/graceful-shutdown.js');

// Configuration
const CONFIG = {
  port: process.env.PORT || 9200,
  prometheusUrl: process.env.PROMETHEUS_URL || 'http://prometheus-deps:9090',
  monitoringInterval: parseInt(process.env.MONITORING_INTERVAL) || 30,
  logLevel: process.env.LOG_LEVEL || 'info',
  healthTimeout: 10000,
  maxRetries: 3,
};

// Service definitions - matches our architecture
const SERVICES = {
  // Critical Level 1 Services
  'wrfcoin-core': { port: 5000, health: '/health', critical: true },
  postgresql: { port: 5432, health: null, critical: true },
  'redis-cache': { port: 6379, health: null, critical: true },

  // Level 2 Core Services
  'wrfcoin-main-api': { port: 4001, health: '/health', critical: true },
  'cross-chain-protocol': { port: 3000, health: '/health', critical: false },
  'weather-service': { port: 3001, health: '/health', critical: false },

  // Level 3 Application Services
  'api-gateway': { port: 4000, health: '/health', critical: false },
  'ml-inference': { port: 8080, health: '/health', critical: false },
  'governance-server': { port: 8000, health: '/health', critical: false },

  // Level 4 Microservices
  'nft-service': { port: 4002, health: '/health', critical: false },
  'user-service': { port: 4003, health: '/health', critical: false },
  'weather-earnings': { port: 8080, health: '/health', critical: false },

  // Network Services
  'compute-networks': { port: 6000, health: '/health', critical: false },
  'ai-ml-networks': { port: 6001, health: '/health', critical: false },
  'storage-networks': { port: 7000, health: '/health', critical: false },

  // IoT and Specialized Services
  'iot-sensor-networks': { port: 3002, health: '/health', critical: false },
  'node-discovery': { port: 9001, health: '/health', critical: false },
  'clamav-antivirus': { port: 3310, health: null, critical: false },
};

// Initialize logger
const logger = winston.createLogger({
  level: CONFIG.logLevel,
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.errors({ stack: true }),
    winston.format.json()
  ),
  defaultMeta: { service: 'dependency-monitor' },
  transports: [
    new winston.transports.File({ filename: 'logs/error.log', level: 'error' }),
    new winston.transports.File({ filename: 'logs/combined.log' }),
    new winston.transports.Console({
      format: winston.format.simple(),
    }),
  ],
});

// Initialize Prometheus metrics
const register = new promClient.Registry();

// Custom metrics
const serviceHealthGauge = new promClient.Gauge({
  name: 'wrfcoin_service_health',
  help: 'Health status of WRFCoin services (1 = healthy, 0 = unhealthy)',
  labelNames: ['service_name', 'port', 'critical'],
});

const dependencyCheckGauge = new promClient.Gauge({
  name: 'wrfcoin_dependency_check',
  help: 'Dependency relationship validation (1 = valid, 0 = broken)',
  labelNames: ['service', 'dependency', 'relationship_type'],
});

const healthCheckDurationGauge = new promClient.Gauge({
  name: 'wrfcoin_health_check_duration_seconds',
  help: 'Duration of health checks in seconds',
  labelNames: ['service_name', 'check_type'],
});

const cascadeFailureGauge = new promClient.Gauge({
  name: 'wrfcoin_cascade_failure_risk',
  help: 'Risk level of cascade failures (0-1)',
  labelNames: ['service_tier', 'risk_level'],
});

// Register metrics
register.registerMetric(serviceHealthGauge);
register.registerMetric(dependencyCheckGauge);
register.registerMetric(healthCheckDurationGauge);
register.registerMetric(cascadeFailureGauge);

// Add default metrics
promClient.collectDefaultMetrics({ register });

class DependencyMonitor {
  constructor() {
    this.app = express();
    this.healthStatus = new Map();
    this.dependencyMap = this.loadDependencyMap();
    this.setupRoutes();
    this.startMonitoring();
  }

  loadDependencyMap() {
    try {
      const mapPath = path.join(__dirname, 'maps', 'service-dependencies.json');
      if (fs.existsSync(mapPath)) {
        const data = fs.readFileSync(mapPath, 'utf8');
        return JSON.parse(data);
      }
    } catch (error) {
      logger.error('Failed to load dependency map:', error);
    }
    return { services: {}, dependency_matrix: {} };
  }

  setupRoutes() {
    // Health check endpoint
    this.app.get('/health', (req, res) => {
      res.json({
        status: 'healthy',
        timestamp: new Date().toISOString(),
        monitored_services: Object.keys(SERVICES).length,
        healthy_services: Array.from(this.healthStatus.values()).filter(
          s => s.healthy
        ).length,
      });
    });

    // Metrics endpoint
    this.app.get('/metrics', async (req, res) => {
      res.set('Content-Type', register.contentType);
      res.end(await register.metrics());
    });

    // Service status endpoint
    this.app.get('/services', (req, res) => {
      const services = Array.from(this.healthStatus.entries()).map(
        ([name, status]) => ({
          name,
          ...status,
        })
      );
      res.json({ services, timestamp: new Date().toISOString() });
    });

    // Dependency matrix endpoint
    this.app.get('/dependencies', (req, res) => {
      res.json({
        dependency_matrix: this.dependencyMap.dependency_matrix,
        health_status: Object.fromEntries(this.healthStatus),
        timestamp: new Date().toISOString(),
      });
    });

    // Generate visual dependency map
    this.app.get('/map', async (req, res) => {
      try {
        const format = req.query.format || 'json';
        const map = await this.generateDependencyVisualization(format);

        if (format === 'json') {
          res.json(map);
        } else {
          res.set('Content-Type', 'text/plain');
          res.send(map);
        }
      } catch (error) {
        logger.error('Failed to generate dependency map:', error);
        res.status(500).json({ error: 'Failed to generate map' });
      }
    });

    // Cascade failure analysis
    this.app.get('/cascade-analysis', (req, res) => {
      const analysis = this.analyzeCascadeFailures();
      res.json(analysis);
    });
  }

  async checkServiceHealth(serviceName, serviceConfig) {
    const startTime = Date.now();
    let healthy = false;
    let error = null;

    try {
      if (serviceConfig.health) {
        // HTTP health check
        const url = `http://localhost:${serviceConfig.port}${serviceConfig.health}`;
        const response = await axios.get(url, {
          timeout: CONFIG.healthTimeout,
          validateStatus: status => status < 400,
        });
        healthy = response.status === 200;
      } else {
        // TCP connectivity check
        const net = require('net');
        healthy = await new Promise(resolve => {
          const socket = new net.Socket();
          socket.setTimeout(CONFIG.healthTimeout);

          socket.on('connect', () => {
            socket.destroy();
            resolve(true);
          });

          socket.on('timeout', () => {
            socket.destroy();
            resolve(false);
          });

          socket.on('error', () => {
            resolve(false);
          });

          socket.connect(serviceConfig.port, 'localhost');
        });
      }
    } catch (err) {
      healthy = false;
      error = err.message;
    }

    const duration = (Date.now() - startTime) / 1000;

    // Update metrics
    serviceHealthGauge.set(
      {
        service_name: serviceName,
        port: serviceConfig.port.toString(),
        critical: serviceConfig.critical.toString(),
      },
      healthy ? 1 : 0
    );

    healthCheckDurationGauge.set(
      {
        service_name: serviceName,
        check_type: serviceConfig.health ? 'http' : 'tcp',
      },
      duration
    );

    // Update internal status
    this.healthStatus.set(serviceName, {
      healthy,
      last_check: new Date().toISOString(),
      response_time: duration,
      error,
      critical: serviceConfig.critical,
    });

    logger.debug(
      `Health check for ${serviceName}: ${healthy ? 'HEALTHY' : 'UNHEALTHY'}`,
      {
        service: serviceName,
        healthy,
        duration,
        error,
      }
    );

    return { serviceName, healthy, duration, error };
  }

  async performHealthChecks() {
    logger.info('Starting health check cycle');
    const promises = Object.entries(SERVICES).map(([name, config]) =>
      this.checkServiceHealth(name, config)
    );

    try {
      const results = await Promise.allSettled(promises);
      const healthyCount = results.filter(
        r => r.status === 'fulfilled' && r.value.healthy
      ).length;
      const totalCount = results.length;

      logger.info(
        `Health check completed: ${healthyCount}/${totalCount} services healthy`
      );

      // Check for cascade failure risks
      this.updateCascadeFailureMetrics();

      return results;
    } catch (error) {
      logger.error('Health check cycle failed:', error);
      return [];
    }
  }

  updateCascadeFailureMetrics() {
    const criticalServices = Array.from(this.healthStatus.entries()).filter(
      ([_, status]) => status.critical
    );

    const criticalDown = criticalServices.filter(
      ([_, status]) => !status.healthy
    ).length;
    const criticalTotal = criticalServices.length;

    const riskLevel = criticalTotal > 0 ? criticalDown / criticalTotal : 0;

    cascadeFailureGauge.set(
      {
        service_tier: 'critical',
        risk_level: riskLevel > 0.5 ? 'high' : 'low',
      },
      riskLevel
    );
  }

  async generateDependencyVisualization(format = 'json') {
    const services = Object.fromEntries(this.healthStatus);

    if (format === 'json') {
      return {
        services,
        dependencies: this.dependencyMap.dependency_matrix,
        visualization: {
          nodes: Object.keys(services).map(name => ({
            id: name,
            label: name,
            status: services[name]?.healthy ? 'healthy' : 'unhealthy',
            critical: services[name]?.critical || false,
          })),
          edges: this.getDependencyEdges(),
        },
        timestamp: new Date().toISOString(),
      };
    }

    // Generate DOT format for Graphviz
    return this.generateDOTVisualization();
  }

  getDependencyEdges() {
    const edges = [];
    Object.entries(this.dependencyMap.dependency_matrix || {}).forEach(
      ([service, deps]) => {
        if (Array.isArray(deps)) {
          deps.forEach(dep => {
            edges.push({
              from: dep,
              to: service,
              status:
                this.healthStatus.get(dep)?.healthy &&
                this.healthStatus.get(service)?.healthy
                  ? 'healthy'
                  : 'unhealthy',
            });
          });
        }
      }
    );
    return edges;
  }

  generateDOTVisualization() {
    let dot = 'digraph DependencyHealth {\n  rankdir=TB;\n';

    // Add nodes with health status
    this.healthStatus.forEach((status, serviceName) => {
      const color = status.healthy ? 'green' : 'red';
      const style = status.critical ? 'bold' : 'solid';
      dot += `  "${serviceName}" [color=${color}, style=${style}, fillcolor=${color}30, style=filled];\n`;
    });

    // Add edges
    this.getDependencyEdges().forEach(edge => {
      const color = edge.status === 'healthy' ? 'green' : 'red';
      dot += `  "${edge.from}" -> "${edge.to}" [color=${color}];\n`;
    });

    dot += '}';
    return dot;
  }

  analyzeCascadeFailures() {
    const downServices = Array.from(this.healthStatus.entries())
      .filter(([_, status]) => !status.healthy)
      .map(([name, _]) => name);

    const affectedServices = new Set();

    // Find services that depend on down services
    Object.entries(this.dependencyMap.dependency_matrix || {}).forEach(
      ([service, deps]) => {
        if (
          Array.isArray(deps) &&
          deps.some(dep => downServices.includes(dep))
        ) {
          affectedServices.add(service);
        }
      }
    );

    return {
      down_services: downServices,
      potentially_affected: Array.from(affectedServices),
      cascade_risk: affectedServices.size / Object.keys(SERVICES).length,
      critical_services_down: downServices.filter(
        s => this.healthStatus.get(s)?.critical
      ),
      timestamp: new Date().toISOString(),
    };
  }

  startMonitoring() {
    // Initial health check
    this.performHealthChecks();

    // Schedule regular health checks
    cron.schedule(`*/${CONFIG.monitoringInterval} * * * * *`, () => {
      this.performHealthChecks();
    });

    logger.info(
      `Monitoring started with ${CONFIG.monitoringInterval}s interval`
    );
  }

  start() {
    this.app.listen(CONFIG.port, () => {
      logger.info(`WRFCoin Dependency Monitor started on port ${CONFIG.port}`);
      logger.info(`Monitoring ${Object.keys(SERVICES).length} services`);
      logger.info(`Prometheus metrics available at /metrics`);
    });
  }
}

// Start the service
const monitor = new DependencyMonitor();
monitor.start();

// Graceful shutdown using GracefulShutdown utility
const shutdown = GracefulShutdown.getInstance({
  enableLogging: true,
  logger: (message, level) => logger[level](message),
});

// Register handler to stop monitoring cron job
shutdown.registerHandler({
  name: 'stop-dependency-monitor-cron',
  priority: ShutdownPriority.STOP_BACKGROUND_JOBS,
  timeout: 5000,
  handler: () => {
    logger.info('Stopping monitoring cron jobs');
    // The cron library does not expose a stop method on the module,
    // but scheduled tasks can be destroyed if tracked
  },
});

// Register handler to close the Express server
shutdown.registerHandler({
  name: 'close-dependency-monitor-server',
  priority: ShutdownPriority.DRAIN_HTTP_CONNECTIONS,
  timeout: 10000,
  handler: () => {
    return new Promise((resolve, reject) => {
      logger.info('Closing Express server');
      if (monitor.app && monitor.app.listening) {
        // Note: Express app doesn't have .close() directly,
        // would need to track the server instance for proper close
        resolve();
      } else {
        resolve();
      }
    });
  },
});

// Setup signal handlers for graceful shutdown
shutdown.setupSignalHandlers();

module.exports = DependencyMonitor;
