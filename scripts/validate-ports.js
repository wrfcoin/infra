#!/usr/bin/env node
/**
 * WRFCoin Port Validation Script
 *
 * Validates port allocations across the platform to ensure:
 * - No duplicate port allocations
 * - Ports are within expected ranges
 * - All registered services have valid configurations
 *
 * Usage: node scripts/validate-ports.js [--check-availability]
 */

import fs from 'fs';
import path from 'path';
import net from 'net';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Configuration
const CONFIG = {
  portRegistryPath: path.join(__dirname, '../backend/config/port-registry.json'),
  microservicesPath: path.join(__dirname, '../backend/config/microservices.json'),
  portRanges: {
    api: { min: 3000, max: 3999, name: 'API Services' },
    application: { min: 4000, max: 4999, name: 'Application Services' },
    frontend: { min: 5000, max: 5999, name: 'Frontend Services' },
    database: { min: 5432, max: 6379, name: 'Database Services', flexible: true },
    compute: { min: 6000, max: 6999, name: 'Compute Services' },
    storage: { min: 7000, max: 7999, name: 'Storage Services' },
    websocket: { min: 8000, max: 8999, name: 'WebSocket/Governance Services' },
    integration: { min: 9000, max: 9999, name: 'Integration Services' },
  },
  reservedPorts: [80, 443, 22, 8080, 9090, 3306, 27017],
};

// ANSI color codes
const colors = {
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  reset: '\x1b[0m',
};

function log(message, color = 'reset') {
  console.log(`${colors[color]}${message}${colors.reset}`);
}

function loadJSON(filePath) {
  try {
    const content = fs.readFileSync(filePath, 'utf8');
    return JSON.parse(content);
  } catch (error) {
    log(`Error loading ${filePath}: ${error.message}`, 'red');
    return null;
  }
}

function validatePortRegistry(registry) {
  const errors = [];
  const warnings = [];
  const portMap = new Map();

  log('\n=== Validating Port Registry ===\n', 'blue');

  if (!registry || !registry.services) {
    errors.push('Port registry is empty or invalid');
    return { errors, warnings, portMap };
  }

  for (const [serviceName, config] of Object.entries(registry.services)) {
    const port = config.port;

    // Check for duplicate ports
    if (portMap.has(port)) {
      errors.push(
        `Duplicate port ${port}: "${serviceName}" conflicts with "${portMap.get(port)}"`
      );
    } else {
      portMap.set(port, serviceName);
    }

    // Check if port is in valid range
    let validRange = false;
    for (const [rangeKey, range] of Object.entries(CONFIG.portRanges)) {
      if (port >= range.min && port <= range.max) {
        validRange = true;
        break;
      }
    }

    if (!validRange && port !== 5432 && port !== 6379) {
      warnings.push(
        `Port ${port} for "${serviceName}" is outside standard ranges`
      );
    }

    // Check for reserved ports
    if (CONFIG.reservedPorts.includes(port)) {
      errors.push(
        `Port ${port} for "${serviceName}" is a reserved system port`
      );
    }

    // Validate port number
    if (port < 1 || port > 65535) {
      errors.push(`Invalid port number ${port} for "${serviceName}"`);
    }
  }

  return { errors, warnings, portMap };
}

function validateMicroservices(microservices, portMap) {
  const errors = [];
  const warnings = [];

  log('\n=== Validating Microservices Configuration ===\n', 'blue');

  if (!microservices || !microservices.services) {
    warnings.push('Microservices configuration not found or invalid');
    return { errors, warnings };
  }

  // Flatten all services from categories
  const allServices = [];
  for (const [category, services] of Object.entries(microservices.services)) {
    for (const [serviceKey, service] of Object.entries(services)) {
      allServices.push({ key: serviceKey, ...service, category });
    }
  }

  for (const service of allServices) {
    const port = service.port;

    // Check if port is registered
    if (!portMap.has(port)) {
      warnings.push(
        `Port ${port} for "${service.name}" is not in port registry`
      );
    }

    // Check for valid health endpoint
    if (!service.health_endpoint) {
      warnings.push(`Service "${service.name}" missing health endpoint`);
    }
  }

  return { errors, warnings };
}

function checkPortAvailability(port) {
  return new Promise((resolve) => {
    const server = net.createServer();

    server.once('error', (err) => {
      if (err.code === 'EADDRINUSE') {
        resolve({ port, available: false, error: 'Port in use' });
      } else {
        resolve({ port, available: false, error: err.message });
      }
    });

    server.once('listening', () => {
      server.close();
      resolve({ port, available: true });
    });

    server.listen(port, '127.0.0.1');
  });
}

async function checkAllPortsAvailability(portMap) {
  log('\n=== Checking Port Availability ===\n', 'blue');

  const results = [];
  const ports = Array.from(portMap.keys());

  for (const port of ports) {
    const result = await checkPortAvailability(port);
    results.push({
      ...result,
      service: portMap.get(port),
    });
  }

  return results;
}

function generateReport(registryValidation, microservicesValidation, availabilityResults) {
  log('\n=== Validation Report ===\n', 'blue');

  const totalErrors =
    registryValidation.errors.length + microservicesValidation.errors.length;
  const totalWarnings =
    registryValidation.warnings.length + microservicesValidation.warnings.length;

  // Errors
  if (totalErrors > 0) {
    log(`\nERRORS (${totalErrors}):`, 'red');
    for (const error of registryValidation.errors) {
      log(`  - ${error}`, 'red');
    }
    for (const error of microservicesValidation.errors) {
      log(`  - ${error}`, 'red');
    }
  }

  // Warnings
  if (totalWarnings > 0) {
    log(`\nWARNINGS (${totalWarnings}):`, 'yellow');
    for (const warning of registryValidation.warnings) {
      log(`  - ${warning}`, 'yellow');
    }
    for (const warning of microservicesValidation.warnings) {
      log(`  - ${warning}`, 'yellow');
    }
  }

  // Availability
  if (availabilityResults) {
    const unavailable = availabilityResults.filter((r) => !r.available);
    const available = availabilityResults.filter((r) => r.available);

    log(`\nPORT AVAILABILITY:`, 'blue');
    log(`  Available: ${available.length}`, 'green');
    log(`  In use: ${unavailable.length}`, unavailable.length > 0 ? 'yellow' : 'green');

    if (unavailable.length > 0) {
      log('\n  Ports in use:', 'yellow');
      for (const result of unavailable) {
        log(`    - Port ${result.port} (${result.service}): ${result.error}`, 'yellow');
      }
    }
  }

  // Port distribution
  log('\nPORT DISTRIBUTION:', 'blue');
  const distribution = {};
  for (const [port, service] of registryValidation.portMap) {
    for (const [rangeKey, range] of Object.entries(CONFIG.portRanges)) {
      if (port >= range.min && port <= range.max) {
        distribution[range.name] = (distribution[range.name] || 0) + 1;
        break;
      }
    }
  }
  for (const [category, count] of Object.entries(distribution)) {
    log(`  ${category}: ${count} services`, 'reset');
  }

  // Summary
  log('\n=== Summary ===\n', 'blue');
  log(`Total services registered: ${registryValidation.portMap.size}`, 'reset');
  log(`Errors: ${totalErrors}`, totalErrors > 0 ? 'red' : 'green');
  log(`Warnings: ${totalWarnings}`, totalWarnings > 0 ? 'yellow' : 'green');

  if (totalErrors === 0) {
    log('\n✅ Port validation passed!', 'green');
    return true;
  } else {
    log('\n❌ Port validation failed!', 'red');
    return false;
  }
}

async function main() {
  const args = process.argv.slice(2);
  const checkAvailability = args.includes('--check-availability');

  log('WRFCoin Port Validation Script', 'blue');
  log('================================\n', 'blue');

  // Load configurations
  const portRegistry = loadJSON(CONFIG.portRegistryPath);
  const microservices = loadJSON(CONFIG.microservicesPath);

  if (!portRegistry) {
    log('Failed to load port registry', 'red');
    process.exit(1);
  }

  // Validate port registry
  const registryValidation = validatePortRegistry(portRegistry);

  // Validate microservices
  const microservicesValidation = validateMicroservices(
    microservices,
    registryValidation.portMap
  );

  // Check port availability if requested
  let availabilityResults = null;
  if (checkAvailability) {
    availabilityResults = await checkAllPortsAvailability(
      registryValidation.portMap
    );
  }

  // Generate report
  const passed = generateReport(
    registryValidation,
    microservicesValidation,
    availabilityResults
  );

  process.exit(passed ? 0 : 1);
}

main().catch((error) => {
  log(`Unexpected error: ${error.message}`, 'red');
  process.exit(1);
});
