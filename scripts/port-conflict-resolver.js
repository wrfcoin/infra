/**
 * Enhanced Port Conflict Resolver for Wrfcoin DAG Architecture
 * Integrates with DAG orchestrator to prevent and resolve port conflicts
 */

const fs = require('fs');
const { exec } = require('child_process');
const util = require('util');
const execAsync = util.promisify(exec);

class PortConflictResolver {
  constructor() {
    this.portMap = new Map();
    this.reservedPorts = new Set([22, 80, 443, 5432, 5000]); // System + frontend
    this.portRanges = {
      frontend: [5000, 5099],
      api: [3000, 3999],
      websocket: [8000, 8999],
      database: [5432, 5499],
      services: [6000, 6999],
      management: [2000, 2999],
      integration: [9000, 9999],
    };

    this.loadDAGConfiguration();
  }

  loadDAGConfiguration() {
    // Load port assignments from DAG orchestrator
    this.dagPorts = {
      // Foundation Layer
      database_setup: null,

      // Protocol Layer
      websocket_server: 8080,
      cross_chain_protocol: 3000,
      storage_networks: 7000,
      compute_networks: 6000,
      iot_sensor_networks: 3002,

      // API Layer
      cross_chain_websocket: 5001,
      unified_api_server: 3001,
      enhanced_weather_rewards: 8001,
      weather_earnings_transfer: 3003,
      ai_ml_networks: 6001,
      contract_integration: 9000,
      node_discovery: 9001,

      // Application Layer
      acurite_collector: null,
      frontend_application: 5000,

      // Management Layer
      service_control_panel: 2001,
      memory_optimized_server: null,
    };

    // Build port map for conflict detection
    for (const [service, port] of Object.entries(this.dagPorts)) {
      if (port) {
        this.portMap.set(port, service);
      }
    }
  }

  async scanActiveConnections() {
    try {
      const { stdout } = await execAsync(
        'netstat -tulpn 2>/dev/null | grep LISTEN || ss -tulpn | grep LISTEN'
      );
      const activeConnections = new Map();

      const lines = stdout.split('\n').filter(line => line.trim());

      for (const line of lines) {
        const match = line.match(/:(\d+)\s/);
        if (match) {
          const port = parseInt(match[1]);
          if (port > 1024) {
            // Skip system ports
            const processMatch = line.match(/(\d+)\/(\w+)/);
            const process = processMatch ? processMatch[2] : 'unknown';
            activeConnections.set(port, process);
          }
        }
      }

      return activeConnections;
    } catch (error) {
      console.log(
        '⚠️  Could not scan active connections, proceeding with conflict detection...'
      );
      return new Map();
    }
  }

  async detectConflicts() {
    const conflicts = [];
    const suggestions = [];
    const activeConnections = await this.scanActiveConnections();

    console.log('🔍 Scanning for port conflicts in DAG configuration...\n');

    // Check for duplicates in DAG configuration
    const portCounts = new Map();
    for (const [service, port] of Object.entries(this.dagPorts)) {
      if (port) {
        if (!portCounts.has(port)) {
          portCounts.set(port, []);
        }
        portCounts.get(port).push(service);
      }
    }

    // Find internal conflicts
    for (const [port, services] of portCounts) {
      if (services.length > 1) {
        conflicts.push({
          type: 'internal_duplicate',
          port: port,
          services: services,
          severity: 'critical',
        });
      }
    }

    // Check against active connections
    for (const [port, service] of Object.entries(this.dagPorts)) {
      if (port && activeConnections.has(port)) {
        const runningProcess = activeConnections.get(port);
        conflicts.push({
          type: 'external_conflict',
          port: port,
          service: service,
          runningProcess: runningProcess,
          severity: 'high',
        });
      }
    }

    // Check port range violations
    for (const [service, port] of Object.entries(this.dagPorts)) {
      if (port) {
        const category = this.categorizeService(service);
        const range = this.portRanges[category];

        if (range && (port < range[0] || port > range[1])) {
          suggestions.push({
            type: 'range_violation',
            service: service,
            currentPort: port,
            recommendedRange: range,
            severity: 'medium',
          });
        }
      }
    }

    return { conflicts, suggestions };
  }

  categorizeService(serviceName) {
    if (serviceName.includes('frontend')) return 'frontend';
    if (serviceName.includes('websocket')) return 'websocket';
    if (serviceName.includes('api') || serviceName.includes('protocol'))
      return 'api';
    if (serviceName.includes('database') || serviceName.includes('db'))
      return 'database';
    if (serviceName.includes('control') || serviceName.includes('memory'))
      return 'management';
    if (
      serviceName.includes('integration') ||
      serviceName.includes('discovery')
    )
      return 'integration';
    return 'services';
  }

  async generateSolutions(conflicts, suggestions) {
    const solutions = [];
    const availablePorts = await this.findAvailablePorts();

    // Solve internal duplicates
    for (const conflict of conflicts.filter(
      c => c.type === 'internal_duplicate'
    )) {
      const keepOriginal = conflict.services[0];
      const needReassignment = conflict.services.slice(1);

      for (const service of needReassignment) {
        const category = this.categorizeService(service);
        const newPort = this.findPortInRange(category, availablePorts);

        if (newPort) {
          solutions.push({
            type: 'reassign_port',
            service: service,
            oldPort: conflict.port,
            newPort: newPort,
            reason: `Duplicate port conflict with ${keepOriginal}`,
          });
          availablePorts.delete(newPort);
        }
      }
    }

    // Solve external conflicts
    for (const conflict of conflicts.filter(
      c => c.type === 'external_conflict'
    )) {
      const category = this.categorizeService(conflict.service);
      const newPort = this.findPortInRange(category, availablePorts);

      if (newPort) {
        solutions.push({
          type: 'reassign_port',
          service: conflict.service,
          oldPort: conflict.port,
          newPort: newPort,
          reason: `External conflict with ${conflict.runningProcess}`,
        });
        availablePorts.delete(newPort);
      }
    }

    // Optimize port ranges
    for (const suggestion of suggestions.filter(
      s => s.type === 'range_violation'
    )) {
      const newPort = this.findPortInRange(
        this.categorizeService(suggestion.service),
        availablePorts
      );

      if (newPort) {
        solutions.push({
          type: 'optimize_range',
          service: suggestion.service,
          oldPort: suggestion.currentPort,
          newPort: newPort,
          reason: `Move to recommended ${this.categorizeService(suggestion.service)} range`,
        });
        availablePorts.delete(newPort);
      }
    }

    return solutions;
  }

  async findAvailablePorts() {
    const activeConnections = await this.scanActiveConnections();
    const availablePorts = new Set();

    // Scan common port ranges for available ports
    for (const [category, [start, end]] of Object.entries(this.portRanges)) {
      for (let port = start; port <= end; port++) {
        if (
          !activeConnections.has(port) &&
          !this.portMap.has(port) &&
          !this.reservedPorts.has(port)
        ) {
          availablePorts.add(port);
        }
      }
    }

    return availablePorts;
  }

  findPortInRange(category, availablePorts) {
    const range = this.portRanges[category];
    if (!range) return null;

    for (const port of availablePorts) {
      if (port >= range[0] && port <= range[1]) {
        return port;
      }
    }

    return null;
  }

  async applySolutions(solutions) {
    console.log('🔧 Applying port conflict solutions...\n');

    const dagOrchestratorPath = './scripts/dag-orchestrator.js';
    let dagContent = fs.readFileSync(dagOrchestratorPath, 'utf8');

    for (const solution of solutions) {
      console.log(
        `🔄 ${solution.service}: ${solution.oldPort} → ${solution.newPort}`
      );
      console.log(`   Reason: ${solution.reason}\n`);

      // Update DAG orchestrator configuration
      const oldPortRegex = new RegExp(
        `('${solution.service}':[\\s\\S]*?port:\\s*)${solution.oldPort}`,
        'g'
      );
      dagContent = dagContent.replace(oldPortRegex, `$1${solution.newPort}`);

      // Update port map
      this.portMap.delete(solution.oldPort);
      this.portMap.set(solution.newPort, solution.service);
      this.dagPorts[solution.service] = solution.newPort;
    }

    // Write updated DAG orchestrator
    fs.writeFileSync(dagOrchestratorPath, dagContent);

    // Generate port architecture documentation
    await this.updatePortDocumentation(solutions);

    console.log('✅ Port conflict resolution completed!');
    return solutions.length;
  }

  async updatePortDocumentation(solutions) {
    const portDoc = this.generatePortArchitectureDoc();

    // Update port architecture documentation
    const portDocPath = './docs/infrastructure/wrfcoin-port-architecture.md';
    fs.writeFileSync(portDocPath, portDoc);

    // Update workflow architecture with conflict resolution info
    const workflowDoc = this.generateWorkflowArchitectureUpdate(solutions);
    const workflowDocPath = './docs/architecture/workflow-architecture.md';

    if (fs.existsSync(workflowDocPath)) {
      let existingContent = fs.readFileSync(workflowDocPath, 'utf8');
      existingContent += '\n\n' + workflowDoc;
      fs.writeFileSync(workflowDocPath, existingContent);
    } else {
      fs.writeFileSync(workflowDocPath, workflowDoc);
    }
  }

  generatePortArchitectureDoc() {
    const timestamp = new Date().toISOString();

    return `# Wrfcoin Port Architecture
*Generated: ${timestamp}*

## Port Allocation Strategy

### Foundation Layer
- Database Setup: No specific port (uses DATABASE_URL)

### Protocol Layer (3000-3999, 6000-7999)
- Cross-Chain Protocol Server: ${this.dagPorts.cross_chain_protocol}
- Storage Networks Server: ${this.dagPorts.storage_networks}
- Compute Networks Server: ${this.dagPorts.compute_networks}
- IoT Sensor Networks: ${this.dagPorts.iot_sensor_networks}

### API Layer (3000-3999, 8000-8999)
- Unified API Server: ${this.dagPorts.unified_api_server}
- Weather Earnings Transfer: ${this.dagPorts.weather_earnings_transfer}
- Enhanced Weather Rewards: ${this.dagPorts.enhanced_weather_rewards}
- AI/ML Networks: ${this.dagPorts.ai_ml_networks}

### WebSocket Layer (8000-8999, 5000-5999)
- Main WebSocket Server: ${this.dagPorts.websocket_server}
- Cross-Chain WebSocket: ${this.dagPorts.cross_chain_websocket}

### Integration Layer (9000-9999)
- Contract Integration Server: ${this.dagPorts.contract_integration}
- Node Discovery Server: ${this.dagPorts.node_discovery}

### Application Layer (5000-5999)
- Frontend Application: ${this.dagPorts.frontend_application}
- AcuRite Collector: Process-based (no port)

### Management Layer (2000-2999)
- Service Control Panel: ${this.dagPorts.service_control_panel}
- Memory Optimized Server: Process-based (no port)

## Port Range Guidelines

| Category | Range | Purpose |
|----------|-------|---------|
| Management | 2000-2999 | Service control, monitoring |
| API Services | 3000-3999 | REST APIs, protocol servers |
| Applications | 5000-5999 | Frontend, user interfaces |
| Compute Services | 6000-6999 | AI/ML, compute networks |
| Storage/Data | 7000-7999 | Storage networks, data services |
| WebSockets | 8000-8999 | Real-time communication |
| Integrations | 9000-9999 | External integrations, discovery |

## Conflict Resolution

This architecture ensures:
- No port conflicts between services
- Logical grouping by functionality
- Clear separation of concerns
- Easy identification of service types by port range

## Health Check Endpoints

All HTTP services expose \`/health\` endpoints for monitoring and DAG orchestration.
`;
  }

  generateWorkflowArchitectureUpdate(solutions) {
    const timestamp = new Date().toISOString();

    return `
## DAG-Based Port Conflict Resolution
*Updated: ${timestamp}*

### Automatic Conflict Resolution Applied

The DAG orchestrator has resolved the following port conflicts:

${
  solutions.length > 0
    ? solutions
        .map(
          s =>
            `- **${s.service}**: Moved from port ${s.oldPort} to ${s.newPort}\n  *Reason: ${s.reason}*`
        )
        .join('\n')
    : 'No conflicts detected - all ports optimally assigned.'
}

### Port Management Strategy

1. **Conflict Detection**: Scans for duplicate assignments and external conflicts
2. **Range Optimization**: Ensures services use appropriate port ranges
3. **DAG Integration**: Updates orchestrator configuration automatically
4. **Documentation Sync**: Keeps architecture docs current

### Benefits

- ✅ Eliminates startup failures due to port conflicts
- ✅ Optimizes port usage by service category
- ✅ Maintains service isolation
- ✅ Enables predictable DAG startup ordering
`;
  }

  printReport() {
    console.log('\n📊 Port Allocation Report\n');
    console.log('Current Port Assignments:');

    const categories = [
      'foundation',
      'protocol',
      'api',
      'websocket',
      'application',
      'management',
      'integration',
    ];

    for (const category of categories) {
      const services = Object.entries(this.dagPorts)
        .filter(([service, port]) => {
          const serviceCategory = this.categorizeService(service);
          return (
            serviceCategory === category ||
            (category === 'websocket' && service.includes('websocket'))
          );
        })
        .filter(([service, port]) => port !== null);

      if (services.length > 0) {
        console.log(`\n🏗️  ${category.toUpperCase()}:`);
        services.forEach(([service, port]) => {
          console.log(`   ${service}: ${port}`);
        });
      }
    }

    console.log('\n🔒 Reserved System Ports:');
    Array.from(this.reservedPorts)
      .sort((a, b) => a - b)
      .forEach(port => {
        console.log(`   ${port}`);
      });
  }

  async run() {
    console.log('🚀 DAG-Enhanced Port Conflict Resolver\n');

    const { conflicts, suggestions } = await this.detectConflicts();

    if (conflicts.length === 0 && suggestions.length === 0) {
      console.log('✅ No port conflicts detected!');
      this.printReport();
      return 0;
    }

    // Display conflicts
    if (conflicts.length > 0) {
      console.log('❌ Port Conflicts Detected:\n');

      for (const conflict of conflicts) {
        if (conflict.type === 'internal_duplicate') {
          console.log(`🔴 Port ${conflict.port} used by multiple services:`);
          conflict.services.forEach(service => console.log(`   - ${service}`));
        } else if (conflict.type === 'external_conflict') {
          console.log(`🔴 Port ${conflict.port} conflict:`);
          console.log(`   Service: ${conflict.service}`);
          console.log(`   External process: ${conflict.runningProcess}`);
        }
        console.log();
      }
    }

    // Display suggestions
    if (suggestions.length > 0) {
      console.log('💡 Optimization Suggestions:\n');

      for (const suggestion of suggestions) {
        console.log(
          `🟡 ${suggestion.service} (port ${suggestion.currentPort}):`
        );
        console.log(
          `   Consider moving to range ${suggestion.recommendedRange[0]}-${suggestion.recommendedRange[1]}`
        );
        console.log();
      }
    }

    // Generate and apply solutions
    const solutions = await this.generateSolutions(conflicts, suggestions);

    if (solutions.length > 0) {
      const resolved = await this.applySolutions(solutions);
      console.log(`\n🎉 Resolved ${resolved} port issues!`);
    }

    this.printReport();
    return solutions.length;
  }
}

// CLI Interface
async function main() {
  const resolver = new PortConflictResolver();

  try {
    await resolver.run();
  } catch (error) {
    console.error('💥 Port resolver error:', error.message);
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}

module.exports = PortConflictResolver;
