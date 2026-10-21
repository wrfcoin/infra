/**
 * Centralized Port Registry System for Wrfcoin Infrastructure
 * Prevents conflicts, manages assignments, and maintains current documentation
 */

const fs = require('fs');
const path = require('path');

class PortRegistry {
  constructor() {
    this.registryFile = './config/port-registry.json';
    this.configDir = './config';
    this.registry = this.loadRegistry();
    this.portRanges = {
      system: [1, 1999],
      management: [2000, 2999],
      api: [3000, 3999],
      application: [4000, 4999],
      frontend: [5000, 5999],
      compute: [6000, 6999],
      storage: [7000, 7999],
      websocket: [8000, 8999],
      integration: [9000, 9999],
    };
  }

  loadRegistry() {
    try {
      if (!fs.existsSync(this.configDir)) {
        fs.mkdirSync(this.configDir, { recursive: true });
      }

      if (fs.existsSync(this.registryFile)) {
        const data = fs.readFileSync(this.registryFile, 'utf8');
        return JSON.parse(data);
      }
    } catch (error) {
      console.log('Creating new port registry...');
    }

    return {
      metadata: {
        created: new Date().toISOString(),
        lastUpdated: new Date().toISOString(),
        version: '1.0.0',
      },
      services: {},
      reservedPorts: [5000], // Frontend is always reserved
    };
  }

  saveRegistry() {
    this.registry.metadata.lastUpdated = new Date().toISOString();
    fs.writeFileSync(this.registryFile, JSON.stringify(this.registry, null, 2));
  }

  categorizeService(serviceName) {
    const name = serviceName.toLowerCase();

    if (name.includes('frontend') || name.includes('ui')) return 'frontend';
    if (name.includes('websocket') || name.includes('ws')) return 'websocket';
    if (
      name.includes('api') ||
      name.includes('protocol') ||
      name.includes('server')
    )
      return 'api';
    if (
      name.includes('wallet') ||
      name.includes('testnet') ||
      name.includes('dashboard')
    )
      return 'application';
    if (
      name.includes('compute') ||
      name.includes('ai') ||
      name.includes('ml') ||
      name.includes('networks')
    )
      return 'compute';
    if (
      name.includes('storage') ||
      name.includes('data') ||
      name.includes('db')
    )
      return 'storage';
    if (
      name.includes('contract') ||
      name.includes('integration') ||
      name.includes('discovery')
    )
      return 'integration';
    if (
      name.includes('control') ||
      name.includes('management') ||
      name.includes('monitor')
    )
      return 'management';

    return 'api'; // Default to API layer
  }

  findAvailablePort(category, preferredPort = null) {
    const range = this.portRanges[category];
    if (!range) {
      throw new Error(`Unknown category: ${category}`);
    }

    const [start, end] = range;
    const usedPorts = new Set([
      ...Object.values(this.registry.services).map(s => s.port),
      ...this.registry.reservedPorts,
    ]);

    // Try preferred port first if specified
    if (
      preferredPort &&
      preferredPort >= start &&
      preferredPort <= end &&
      !usedPorts.has(preferredPort)
    ) {
      return preferredPort;
    }

    // Find first available port in range
    for (let port = start; port <= end; port++) {
      if (!usedPorts.has(port)) {
        return port;
      }
    }

    throw new Error(
      `No available ports in ${category} range (${start}-${end})`
    );
  }

  registerService(serviceName, category = null, preferredPort = null) {
    // Auto-detect category if not provided
    if (!category) {
      category = this.categorizeService(serviceName);
    }

    // Check if service already exists
    if (this.registry.services[serviceName]) {
      console.log(
        `Service ${serviceName} already registered on port ${this.registry.services[serviceName].port}`
      );
      return this.registry.services[serviceName].port;
    }

    // Find available port
    const port = this.findAvailablePort(category, preferredPort);

    // Register the service
    this.registry.services[serviceName] = {
      port: port,
      category: category,
      registeredAt: new Date().toISOString(),
      status: 'registered',
    };

    this.saveRegistry();
    console.log(`✅ Registered ${serviceName} on port ${port} (${category})`);
    return port;
  }

  unregisterService(serviceName) {
    if (this.registry.services[serviceName]) {
      const port = this.registry.services[serviceName].port;
      delete this.registry.services[serviceName];
      this.saveRegistry();
      console.log(`❌ Unregistered ${serviceName} from port ${port}`);
      return true;
    }
    console.log(`Service ${serviceName} not found in registry`);
    return false;
  }

  updateServiceStatus(serviceName, status) {
    if (this.registry.services[serviceName]) {
      this.registry.services[serviceName].status = status;
      this.registry.services[serviceName].lastStatusUpdate =
        new Date().toISOString();
      this.saveRegistry();
      return true;
    }
    return false;
  }

  getServicePort(serviceName) {
    return this.registry.services[serviceName]?.port || null;
  }

  listServices(category = null) {
    const services = Object.entries(this.registry.services);

    if (category) {
      return services.filter(([name, info]) => info.category === category);
    }

    return services;
  }

  validateConfiguration() {
    const conflicts = [];
    const portCounts = new Map();

    // Count port usage
    for (const [serviceName, info] of Object.entries(this.registry.services)) {
      if (!portCounts.has(info.port)) {
        portCounts.set(info.port, []);
      }
      portCounts.get(info.port).push(serviceName);
    }

    // Find conflicts
    for (const [port, services] of portCounts) {
      if (services.length > 1) {
        conflicts.push({ port, services });
      }
    }

    return conflicts;
  }

  resolveConflicts() {
    const conflicts = this.validateConfiguration();
    const resolutions = [];

    for (const conflict of conflicts) {
      console.log(`\n🚨 Resolving conflict on port ${conflict.port}`);
      console.log(`   Services: ${conflict.services.join(', ')}`);

      // Keep the first service, reassign others
      const [keepService, ...reassignServices] = conflict.services;
      console.log(`   Keeping: ${keepService}`);

      for (const serviceName of reassignServices) {
        const serviceInfo = this.registry.services[serviceName];
        const oldPort = serviceInfo.port;

        try {
          // Remove service temporarily to find new port
          delete this.registry.services[serviceName];
          const newPort = this.findAvailablePort(serviceInfo.category);

          // Re-register with new port
          this.registry.services[serviceName] = {
            ...serviceInfo,
            port: newPort,
            resolvedAt: new Date().toISOString(),
            previousPort: oldPort,
          };

          resolutions.push({
            service: serviceName,
            oldPort: oldPort,
            newPort: newPort,
            reason: `Resolved conflict with ${keepService}`,
          });

          console.log(`   Moved ${serviceName}: ${oldPort} → ${newPort}`);
        } catch (error) {
          console.error(
            `   Failed to reassign ${serviceName}: ${error.message}`
          );
        }
      }
    }

    if (resolutions.length > 0) {
      this.saveRegistry();
    }

    return resolutions;
  }

  generateCurrentArchitectureDoc() {
    const timestamp = new Date().toISOString();
    const conflicts = this.validateConfiguration();

    let doc = `# Wrfcoin Port Architecture (Centralized Registry)
*Generated: ${timestamp}*
*Registry Version: ${this.registry.metadata.version}*
*Status: ${conflicts.length === 0 ? 'No conflicts' : `${conflicts.length} conflicts detected`}*

## Current Port Assignments

`;

    // Group services by category
    const categories = {};
    for (const [serviceName, info] of Object.entries(this.registry.services)) {
      if (!categories[info.category]) {
        categories[info.category] = [];
      }
      categories[info.category].push([serviceName, info]);
    }

    // Generate sections for each category
    for (const [category, services] of Object.entries(categories)) {
      const categoryName = category.charAt(0).toUpperCase() + category.slice(1);
      const range = this.portRanges[category];
      doc += `### ${categoryName} Layer (${range[0]}-${range[1]})\n`;

      services.sort((a, b) => a[1].port - b[1].port);
      for (const [serviceName, info] of services) {
        const statusIcon =
          info.status === 'running'
            ? '🟢'
            : info.status === 'registered'
              ? '🔵'
              : '🔴';
        doc += `- ${serviceName}: ${info.port} ${statusIcon}\n`;
      }
      doc += '\n';
    }

    if (conflicts.length > 0) {
      doc += '## Detected Conflicts\n\n';
      for (const conflict of conflicts) {
        doc += `- Port ${conflict.port}: ${conflict.services.join(', ')}\n`;
      }
      doc += '\n';
    }

    doc += `## Port Range Utilization

| Category | Range | Used | Available |
|----------|-------|------|-----------|
`;

    for (const [category, range] of Object.entries(this.portRanges)) {
      if (category === 'system') continue;

      const servicesInRange = Object.values(this.registry.services).filter(
        s => s.port >= range[0] && s.port <= range[1]
      ).length;
      const totalPorts = range[1] - range[0] + 1;
      const available = totalPorts - servicesInRange;

      doc += `| ${category} | ${range[0]}-${range[1]} | ${servicesInRange} | ${available} |\n`;
    }

    doc += `

## Registry Management

Services are automatically assigned ports within appropriate ranges:
- **Management**: System control and monitoring services
- **API**: REST APIs and protocol servers  
- **Application**: Business logic and specialized services
- **Frontend**: User interfaces (port 5000 reserved)
- **Compute**: AI/ML and computational services
- **Storage**: Data storage and management
- **WebSocket**: Real-time communication
- **Integration**: External integrations and discovery

Use the port registry system to register new services and prevent conflicts.
`;

    return doc;
  }

  importExistingServices() {
    console.log('🔄 Importing existing service configurations...');

    const knownServices = {
      'Frontend Application': { category: 'frontend', port: 5000 },
      'Cross-Chain Protocol Server': { category: 'api', port: 3000 },
      'Missing Endpoints Server': { category: 'api', port: 3001 },
      'Wallet Server': { category: 'application', port: 4000 },
      'Testnet API Server': { category: 'application', port: 4001 },
      'Performance Dashboard API': { category: 'application', port: 4002 },
      'Cross-Chain WebSocket': { category: 'websocket', port: 5001 },
      'Compute Networks Server': { category: 'compute', port: 6000 },
      'AI ML Networks': { category: 'compute', port: 6001 },
      'IoT Sensor Networks': { category: 'compute', port: 3002 },
      'Storage Networks': { category: 'storage', port: 7000 },
      'Enhanced Cross-Chain Server': { category: 'websocket', port: 8002 },
      'Memory Optimized Server': { category: 'websocket', port: 8003 },
      'Contract Integration Server': { category: 'integration', port: 9000 },
      'Node Discovery Server': { category: 'integration', port: 9001 },
    };

    let imported = 0;
    for (const [serviceName, config] of Object.entries(knownServices)) {
      if (!this.registry.services[serviceName]) {
        this.registry.services[serviceName] = {
          port: config.port,
          category: config.category,
          registeredAt: new Date().toISOString(),
          status: 'imported',
          source: 'existing_configuration',
        };
        imported++;
      }
    }

    if (imported > 0) {
      this.saveRegistry();
      console.log(`✅ Imported ${imported} existing services`);
    }

    return imported;
  }

  printStatus() {
    console.log('\n📊 PORT REGISTRY STATUS\n');
    console.log('='.repeat(50));

    const conflicts = this.validateConfiguration();
    console.log(`Registry Version: ${this.registry.metadata.version}`);
    console.log(`Last Updated: ${this.registry.metadata.lastUpdated}`);
    console.log(
      `Total Services: ${Object.keys(this.registry.services).length}`
    );
    console.log(`Conflicts: ${conflicts.length}`);

    if (conflicts.length > 0) {
      console.log('\n🚨 CONFLICTS:');
      for (const conflict of conflicts) {
        console.log(
          `   Port ${conflict.port}: ${conflict.services.join(', ')}`
        );
      }
    }

    console.log('\n📋 SERVICES BY CATEGORY:');
    const categories = {};
    for (const [serviceName, info] of Object.entries(this.registry.services)) {
      if (!categories[info.category]) {
        categories[info.category] = [];
      }
      categories[info.category].push(`${serviceName}:${info.port}`);
    }

    for (const [category, services] of Object.entries(categories)) {
      console.log(`\n🏗️  ${category.toUpperCase()}:`);
      services.forEach(service => console.log(`   ${service}`));
    }
  }
}

module.exports = PortRegistry;

// CLI Interface
if (require.main === module) {
  const registry = new PortRegistry();
  const command = process.argv[2];
  const serviceName = process.argv[3];
  const category = process.argv[4];
  const port = process.argv[5] ? parseInt(process.argv[5]) : null;

  switch (command) {
    case 'register':
      if (!serviceName) {
        console.error(
          'Usage: node port-registry.js register <service-name> [category] [preferred-port]'
        );
        process.exit(1);
      }
      registry.registerService(serviceName, category, port);
      break;

    case 'unregister':
      if (!serviceName) {
        console.error('Usage: node port-registry.js unregister <service-name>');
        process.exit(1);
      }
      registry.unregisterService(serviceName);
      break;

    case 'status':
      registry.printStatus();
      break;

    case 'resolve':
      const resolutions = registry.resolveConflicts();
      console.log(`\n✅ Resolved ${resolutions.length} conflicts`);
      break;

    case 'import':
      registry.importExistingServices();
      registry.printStatus();
      break;

    case 'docs':
      const doc = registry.generateCurrentArchitectureDoc();
      const docPath =
        './docs/infrastructure/wrfcoin-port-architecture-current.md';
      fs.writeFileSync(docPath, doc);
      console.log(`📝 Documentation updated: ${docPath}`);
      break;

    case 'get':
      if (!serviceName) {
        console.error('Usage: node port-registry.js get <service-name>');
        process.exit(1);
      }
      const servicePort = registry.getServicePort(serviceName);
      if (servicePort) {
        console.log(servicePort);
      } else {
        console.error(`Service ${serviceName} not found`);
        process.exit(1);
      }
      break;

    default:
      console.log(`
Wrfcoin Port Registry CLI

Commands:
  register <service> [category] [port]  - Register a new service
  unregister <service>                  - Remove a service
  get <service>                         - Get port for service
  status                                - Show registry status
  resolve                               - Resolve port conflicts
  import                                - Import existing services
  docs                                  - Generate current documentation

Examples:
  node port-registry.js register "New API Server" api 3005
  node port-registry.js get "Frontend Application"
  node port-registry.js resolve
  node port-registry.js docs
`);
  }
}
