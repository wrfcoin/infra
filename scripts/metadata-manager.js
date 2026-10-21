/**
 * Wrfcoin Service Metadata Manager
 * Validates, queries, and manages service metadata using the standardized schema
 */

const fs = require('fs');
const path = require('path');
const Ajv = require('ajv');
const addFormats = require('ajv-formats');

class MetadataManager {
  constructor() {
    this.ajv = new Ajv({ allErrors: true });
    addFormats(this.ajv);
    this.loadSchema();
  }

  loadSchema() {
    try {
      const schemaPath = path.join(
        __dirname,
        '../docs/architecture/service-metadata-schema.json'
      );
      this.schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
      this.validate = this.ajv.compile(this.schema);
      console.log('✅ Service metadata schema loaded successfully');
    } catch (error) {
      console.error('❌ Failed to load metadata schema:', error.message);
      process.exit(1);
    }
  }

  // Validate service metadata against schema
  validateServiceMetadata(serviceData) {
    const valid = this.validate(serviceData);
    if (!valid) {
      return {
        valid: false,
        errors: this.validate.errors.map(err => ({
          field: err.instancePath || err.schemaPath,
          message: err.message,
          data: err.data,
        })),
      };
    }
    return { valid: true, errors: [] };
  }

  // Query services by various filters
  queryServices(services, filters = {}) {
    let results = Object.entries(services);

    // Filter by category
    if (filters.category) {
      results = results.filter(
        ([name, service]) => service.category === filters.category
      );
    }

    // Filter by status
    if (filters.status) {
      results = results.filter(
        ([name, service]) => service.status === filters.status
      );
    }

    // Filter by priority
    if (filters.priority) {
      results = results.filter(
        ([name, service]) => service.priority === filters.priority
      );
    }

    // Filter by tags
    if (filters.tags && filters.tags.length > 0) {
      results = results.filter(([name, service]) => {
        return filters.tags.some(
          tag => service.tags && service.tags.includes(tag)
        );
      });
    }

    // Filter by port range
    if (filters.portRange) {
      const [min, max] = filters.portRange;
      results = results.filter(([name, service]) => {
        return service.port && service.port >= min && service.port <= max;
      });
    }

    // Filter by autoStart
    if (filters.autoStart !== undefined) {
      results = results.filter(
        ([name, service]) => service.autoStart === filters.autoStart
      );
    }

    // Filter by protected status
    if (filters.protected !== undefined) {
      results = results.filter(
        ([name, service]) => service.protected === filters.protected
      );
    }

    // Search in name and description
    if (filters.search) {
      const searchTerm = filters.search.toLowerCase();
      results = results.filter(([name, service]) => {
        return (
          name.toLowerCase().includes(searchTerm) ||
          (service.description &&
            service.description.toLowerCase().includes(searchTerm))
        );
      });
    }

    return Object.fromEntries(results);
  }

  // Generate restart groups based on dependencies and categories
  generateRestartGroups(services) {
    const groups = {
      critical: [],
      revenue: [],
      network: [],
      compute: [],
      storage: [],
      infrastructure: [],
    };

    Object.entries(services).forEach(([name, service]) => {
      if (service.priority === 'critical') {
        groups.critical.push(name);
      } else if (service.priority === 'revenue-critical' || service.protected) {
        groups.revenue.push(name);
      } else if (service.category === 'network') {
        groups.network.push(name);
      } else if (['ai', 'compute'].includes(service.category)) {
        groups.compute.push(name);
      } else if (['storage', 'iot'].includes(service.category)) {
        groups.storage.push(name);
      } else {
        groups.infrastructure.push(name);
      }
    });

    return groups;
  }

  // Generate dependency graph
  generateDependencyGraph(services) {
    const graph = {};
    const dependents = {};

    // Initialize graph
    Object.keys(services).forEach(name => {
      graph[name] = [];
      dependents[name] = [];
    });

    // Build dependency relationships
    Object.entries(services).forEach(([name, service]) => {
      if (service.dependencies && service.dependencies.length > 0) {
        service.dependencies.forEach(dep => {
          if (graph[dep]) {
            graph[dep].push(name);
            dependents[name].push(dep);
          }
        });
      }
    });

    return { graph, dependents };
  }

  // Get service startup order based on dependencies
  getStartupOrder(services) {
    const { dependents } = this.generateDependencyGraph(services);
    const visited = new Set();
    const order = [];

    const visit = serviceName => {
      if (visited.has(serviceName)) return;
      visited.add(serviceName);

      // Visit dependencies first
      const service = services[serviceName];
      if (service && service.dependencies) {
        service.dependencies.forEach(dep => {
          if (services[dep]) {
            visit(dep);
          }
        });
      }

      order.push(serviceName);
    };

    // Sort by priority first, then visit
    const priorityOrder = [
      'critical',
      'revenue-critical',
      'high',
      'medium',
      'low',
    ];
    const sortedServices = Object.entries(services).sort(([, a], [, b]) => {
      const aPriority = priorityOrder.indexOf(a.priority);
      const bPriority = priorityOrder.indexOf(b.priority);
      return aPriority - bPriority;
    });

    sortedServices.forEach(([name]) => visit(name));

    return order;
  }

  // Generate port conflict report
  generatePortConflictReport(services) {
    const portMap = {};
    const conflicts = [];

    Object.entries(services).forEach(([name, service]) => {
      if (service.port) {
        if (portMap[service.port]) {
          conflicts.push({
            port: service.port,
            services: [portMap[service.port], name],
          });
        } else {
          portMap[service.port] = name;
        }
      }
    });

    return {
      totalPorts: Object.keys(portMap).length,
      conflicts,
      portMap,
    };
  }

  // Generate resource usage summary
  generateResourceSummary(services) {
    const summary = {
      cpu: { low: 0, medium: 0, high: 0 },
      memory: { low: 0, medium: 0, high: 0 },
      totalServices: Object.keys(services).length,
      runningServices: 0,
      autoStartServices: 0,
      protectedServices: 0,
    };

    Object.values(services).forEach(service => {
      if (service.status === 'running') summary.runningServices++;
      if (service.autoStart) summary.autoStartServices++;
      if (service.protected) summary.protectedServices++;

      if (service.resources) {
        if (service.resources.cpu) {
          summary.cpu[service.resources.cpu] =
            (summary.cpu[service.resources.cpu] || 0) + 1;
        }
        if (service.resources.memory) {
          summary.memory[service.resources.memory] =
            (summary.memory[service.resources.memory] || 0) + 1;
        }
      }
    });

    return summary;
  }

  // Export services metadata to different formats
  exportMetadata(services, format = 'json') {
    const timestamp = new Date().toISOString();
    const metadata = {
      version: this.schema.version,
      timestamp,
      services,
      summary: this.generateResourceSummary(services),
      portConflicts: this.generatePortConflictReport(services),
      restartGroups: this.generateRestartGroups(services),
      startupOrder: this.getStartupOrder(services),
    };

    switch (format.toLowerCase()) {
      case 'json':
        return JSON.stringify(metadata, null, 2);

      case 'yaml':
        // Would need yaml library for full implementation
        return this.toYAML(metadata);

      case 'csv':
        return this.toCSV(services);

      default:
        throw new Error(`Unsupported export format: ${format}`);
    }
  }

  toCSV(services) {
    const headers = [
      'Name',
      'Port',
      'Category',
      'Status',
      'Priority',
      'Protected',
      'AutoStart',
      'Description',
    ];
    const rows = [headers.join(',')];

    Object.entries(services).forEach(([name, service]) => {
      const row = [
        `"${name}"`,
        service.port || '',
        service.category,
        service.status,
        service.priority,
        service.protected || false,
        service.autoStart || false,
        `"${service.description || ''}"`,
      ];
      rows.push(row.join(','));
    });

    return rows.join('\n');
  }

  toYAML(obj) {
    // Simplified YAML conversion for basic structure
    return Object.entries(obj)
      .map(([key, value]) => {
        if (typeof value === 'object') {
          return `${key}:\n  ${JSON.stringify(value, null, 2).split('\n').join('\n  ')}`;
        }
        return `${key}: ${value}`;
      })
      .join('\n');
  }

  // CLI interface
  static async runCLI() {
    const manager = new MetadataManager();
    const args = process.argv.slice(2);
    const command = args[0];

    // Load services from control panel
    const { SERVICE_METADATA } = require('./service-control-panel.js');

    switch (command) {
      case 'validate':
        console.log('🔍 Validating service metadata...');
        let allValid = true;
        Object.entries(SERVICE_METADATA).forEach(([name, service]) => {
          const result = manager.validateServiceMetadata(service);
          if (!result.valid) {
            console.log(`❌ ${name}:`);
            result.errors.forEach(err => {
              console.log(`   ${err.field}: ${err.message}`);
            });
            allValid = false;
          }
        });
        if (allValid) {
          console.log('✅ All service metadata is valid!');
        }
        break;

      case 'query':
        const filter = args[1];
        const value = args[2];
        const filters = {};
        if (filter && value) filters[filter] = value;

        const results = manager.queryServices(SERVICE_METADATA, filters);
        console.log(`📊 Found ${Object.keys(results).length} services:`);
        Object.keys(results).forEach(name => console.log(`  - ${name}`));
        break;

      case 'groups':
        const groups = manager.generateRestartGroups(SERVICE_METADATA);
        console.log('📋 Restart Groups:');
        Object.entries(groups).forEach(([group, services]) => {
          console.log(`  ${group}: ${services.join(', ')}`);
        });
        break;

      case 'order':
        const order = manager.getStartupOrder(SERVICE_METADATA);
        console.log('🚀 Startup Order:');
        order.forEach((service, index) => {
          console.log(`  ${index + 1}. ${service}`);
        });
        break;

      case 'ports':
        const portReport = manager.generatePortConflictReport(SERVICE_METADATA);
        console.log('🔌 Port Analysis:');
        console.log(`  Total ports used: ${portReport.totalPorts}`);
        if (portReport.conflicts.length > 0) {
          console.log('  ⚠️  Conflicts:');
          portReport.conflicts.forEach(conflict => {
            console.log(
              `    Port ${conflict.port}: ${conflict.services.join(', ')}`
            );
          });
        } else {
          console.log('  ✅ No port conflicts detected');
        }
        break;

      case 'export':
        const format = args[1] || 'json';
        const output = manager.exportMetadata(SERVICE_METADATA, format);
        console.log(output);
        break;

      case 'summary':
        const summary = manager.generateResourceSummary(SERVICE_METADATA);
        console.log('📈 Resource Summary:');
        console.log(`  Total Services: ${summary.totalServices}`);
        console.log(`  Running: ${summary.runningServices}`);
        console.log(`  Auto-Start: ${summary.autoStartServices}`);
        console.log(`  Protected: ${summary.protectedServices}`);
        console.log(
          `  CPU Usage: Low(${summary.cpu.low}) Medium(${summary.cpu.medium}) High(${summary.cpu.high})`
        );
        break;

      default:
        console.log('🛠️  Wrfcoin Metadata Manager');
        console.log('Usage: node metadata-manager.js <command> [options]');
        console.log('');
        console.log('Commands:');
        console.log('  validate              Validate all service metadata');
        console.log('  query <field> <value> Query services by field');
        console.log('  groups                Show restart groups');
        console.log('  order                 Show startup order');
        console.log('  ports                 Show port usage and conflicts');
        console.log('  summary               Show resource summary');
        console.log(
          '  export [format]       Export metadata (json, yaml, csv)'
        );
        console.log('');
        console.log('Examples:');
        console.log('  node metadata-manager.js query category weather');
        console.log('  node metadata-manager.js export json > services.json');
    }
  }
}

// CLI execution
if (require.main === module) {
  MetadataManager.runCLI().catch(console.error);
}

module.exports = { MetadataManager };
