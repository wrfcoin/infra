/**
 * Wrfcoin Restart Groups Manager
 * Implements intelligent service restart ordering based on dependencies and categories
 * Protects revenue-critical services during system operations
 */

const { SERVICE_METADATA } = require('./service-control-panel.js');

class RestartGroupsManager {
  constructor() {
    this.services = SERVICE_METADATA;
    this.groups = this.generateRestartGroups();
    this.dependencyGraph = this.buildDependencyGraph();
  }

  // Generate restart groups based on priority and category
  generateRestartGroups() {
    const groups = {
      // Group 1: Critical infrastructure (start first)
      critical: {
        order: 1,
        description: 'Critical infrastructure services - start first',
        services: [],
        parallel: false, // Start sequentially for stability
        waitTime: 5000, // Wait 5s between services
      },

      // Group 2: Revenue protection (earnings services)
      revenue: {
        order: 2,
        description: 'Revenue-generating services - protected from shutdown',
        services: [],
        parallel: false,
        waitTime: 3000,
        protected: true, // Cannot be stopped during group operations
      },

      // Group 3: Network layer
      network: {
        order: 3,
        description: 'Network and cross-chain services',
        services: [],
        parallel: true, // Can start in parallel
        waitTime: 2000,
      },

      // Group 4: Core application services
      application: {
        order: 4,
        description: 'Core application and API services',
        services: [],
        parallel: true,
        waitTime: 3000,
      },

      // Group 5: Compute and AI services
      compute: {
        order: 5,
        description: 'Compute, AI, and ML services',
        services: [],
        parallel: true,
        waitTime: 1000,
      },

      // Group 6: Storage and data services
      storage: {
        order: 6,
        description: 'Storage and data management services',
        services: [],
        parallel: true,
        waitTime: 1000,
      },

      // Group 7: Supporting infrastructure
      infrastructure: {
        order: 7,
        description: 'Supporting infrastructure and utilities',
        services: [],
        parallel: true,
        waitTime: 500,
      },
    };

    // Categorize services into groups
    Object.entries(this.services).forEach(([name, service]) => {
      if (service.priority === 'critical') {
        groups.critical.services.push(name);
      } else if (service.priority === 'revenue-critical' || service.protected) {
        groups.revenue.services.push(name);
      } else if (
        service.category === 'network' ||
        service.category === 'blockchain'
      ) {
        groups.network.services.push(name);
      } else if (service.category === 'core' || service.category === 'api') {
        groups.application.services.push(name);
      } else if (['ai', 'compute'].includes(service.category)) {
        groups.compute.services.push(name);
      } else if (['storage', 'iot'].includes(service.category)) {
        groups.storage.services.push(name);
      } else {
        groups.infrastructure.services.push(name);
      }
    });

    return groups;
  }

  // Build dependency graph for ordering within groups
  buildDependencyGraph() {
    const graph = {};
    const inDegree = {};

    // Initialize
    Object.keys(this.services).forEach(name => {
      graph[name] = [];
      inDegree[name] = 0;
    });

    // Build edges and calculate in-degrees
    Object.entries(this.services).forEach(([name, service]) => {
      if (service.dependencies && service.dependencies.length > 0) {
        service.dependencies.forEach(dep => {
          if (graph[dep]) {
            graph[dep].push(name);
            inDegree[name]++;
          }
        });
      }
    });

    return { graph, inDegree };
  }

  // Get topological ordering for services within a group
  getTopologicalOrder(serviceNames) {
    const subGraph = {};
    const subInDegree = {};
    const queue = [];
    const result = [];

    // Initialize subgraph with only services in this group
    serviceNames.forEach(name => {
      subGraph[name] = this.dependencyGraph.graph[name].filter(dep =>
        serviceNames.includes(dep)
      );
      subInDegree[name] =
        this.services[name].dependencies?.filter(dep =>
          serviceNames.includes(dep)
        ).length || 0;

      if (subInDegree[name] === 0) {
        queue.push(name);
      }
    });

    // Kahn's algorithm for topological sorting
    while (queue.length > 0) {
      const current = queue.shift();
      result.push(current);

      subGraph[current].forEach(neighbor => {
        subInDegree[neighbor]--;
        if (subInDegree[neighbor] === 0) {
          queue.push(neighbor);
        }
      });
    }

    return result;
  }

  // Generate complete startup sequence
  generateStartupSequence() {
    const sequence = [];

    // Sort groups by order
    const sortedGroups = Object.entries(this.groups).sort(
      ([, a], [, b]) => a.order - b.order
    );

    sortedGroups.forEach(([groupName, group]) => {
      if (group.services.length > 0) {
        const orderedServices = this.getTopologicalOrder(group.services);

        sequence.push({
          groupName,
          description: group.description,
          services: orderedServices,
          parallel: group.parallel,
          waitTime: group.waitTime,
          protected: group.protected || false,
        });
      }
    });

    return sequence;
  }

  // Generate shutdown sequence (reverse of startup)
  generateShutdownSequence() {
    const startupSequence = this.generateStartupSequence();

    return startupSequence
      .slice()
      .reverse()
      .map(group => ({
        ...group,
        services: group.services.slice().reverse(),
        description: group.description.replace('start', 'stop'),
      }));
  }

  // Execute restart group operation
  async executeRestartGroup(groupName, operation = 'restart') {
    const group = this.groups[groupName];
    if (!group) {
      throw new Error(`Group '${groupName}' not found`);
    }

    if (group.protected && operation !== 'start') {
      throw new Error(
        `Group '${groupName}' is protected - contains revenue-critical services`
      );
    }

    console.log(`🔄 ${operation.toUpperCase()} group: ${groupName}`);
    console.log(`📋 Description: ${group.description}`);
    console.log(`🔧 Services: ${group.services.join(', ')}`);

    const orderedServices = this.getTopologicalOrder(group.services);
    const results = [];

    if (group.parallel) {
      // Execute in parallel
      const promises = orderedServices.map(async serviceName => {
        return this.executeServiceOperation(serviceName, operation);
      });

      const parallelResults = await Promise.allSettled(promises);
      results.push(
        ...parallelResults.map((result, index) => ({
          service: orderedServices[index],
          success: result.status === 'fulfilled',
          result: result.status === 'fulfilled' ? result.value : result.reason,
        }))
      );
    } else {
      // Execute sequentially
      for (const serviceName of orderedServices) {
        try {
          const result = await this.executeServiceOperation(
            serviceName,
            operation
          );
          results.push({ service: serviceName, success: true, result });

          // Wait between services if specified
          if (group.waitTime > 0) {
            await new Promise(resolve => setTimeout(resolve, group.waitTime));
          }
        } catch (error) {
          results.push({
            service: serviceName,
            success: false,
            result: error.message,
          });
          console.error(
            `❌ Failed to ${operation} ${serviceName}:`,
            error.message
          );
        }
      }
    }

    return {
      groupName,
      operation,
      totalServices: orderedServices.length,
      successful: results.filter(r => r.success).length,
      failed: results.filter(r => !r.success).length,
      results,
    };
  }

  // Mock service operation (would integrate with actual service management)
  async executeServiceOperation(serviceName, operation) {
    const service = this.services[serviceName];

    if (service.protected && operation !== 'start') {
      throw new Error(
        `Service ${serviceName} is protected - earnings critical`
      );
    }

    console.log(
      `  ${operation === 'start' ? '🟢' : operation === 'stop' ? '🔴' : '🔄'} ${operation.toUpperCase()}: ${serviceName}`
    );

    // Simulate operation time
    await new Promise(resolve =>
      setTimeout(resolve, Math.random() * 1000 + 500)
    );

    return `${serviceName} ${operation} completed successfully`;
  }

  // Get restart recommendations
  getRestartRecommendations() {
    const recommendations = [];

    // Check for services that should be restarted together
    Object.entries(this.groups).forEach(([groupName, group]) => {
      if (group.services.length > 1) {
        recommendations.push({
          type: 'group',
          groupName,
          reason: `${group.services.length} related services can be managed together`,
          services: group.services,
          impact: group.protected ? 'high' : 'medium',
        });
      }
    });

    // Check for dependency-based recommendations
    Object.entries(this.services).forEach(([name, service]) => {
      if (service.dependencies && service.dependencies.length > 0) {
        recommendations.push({
          type: 'dependency',
          service: name,
          reason: `Depends on ${service.dependencies.length} other services`,
          dependencies: service.dependencies,
          impact: service.protected ? 'high' : 'low',
        });
      }
    });

    return recommendations;
  }

  // CLI interface
  static async runCLI() {
    const manager = new RestartGroupsManager();
    const args = process.argv.slice(2);
    const command = args[0];

    switch (command) {
      case 'groups':
        console.log('🔄 Restart Groups:');
        Object.entries(manager.groups).forEach(([name, group]) => {
          console.log(`\n📋 ${name} (Order: ${group.order})`);
          console.log(`   Description: ${group.description}`);
          console.log(`   Services: ${group.services.join(', ')}`);
          console.log(`   Parallel: ${group.parallel ? 'Yes' : 'No'}`);
          console.log(`   Wait Time: ${group.waitTime}ms`);
          if (group.protected) console.log(`   🛡️  PROTECTED`);
        });
        break;

      case 'startup':
        const startupSequence = manager.generateStartupSequence();
        console.log('🚀 Startup Sequence:');
        startupSequence.forEach((group, index) => {
          console.log(
            `\n${index + 1}. ${group.groupName} - ${group.description}`
          );
          console.log(`   Services: ${group.services.join(' → ')}`);
          console.log(`   Mode: ${group.parallel ? 'Parallel' : 'Sequential'}`);
          if (group.protected) console.log(`   🛡️  PROTECTED`);
        });
        break;

      case 'shutdown':
        const shutdownSequence = manager.generateShutdownSequence();
        console.log('🛑 Shutdown Sequence:');
        shutdownSequence.forEach((group, index) => {
          console.log(
            `\n${index + 1}. ${group.groupName} - ${group.description}`
          );
          console.log(`   Services: ${group.services.join(' → ')}`);
          if (group.protected)
            console.log(`   🛡️  PROTECTED - Cannot shutdown`);
        });
        break;

      case 'execute':
        const groupName = args[1];
        const operation = args[2] || 'restart';
        if (!groupName) {
          console.error('❌ Please specify group name');
          break;
        }

        try {
          const result = await manager.executeRestartGroup(
            groupName,
            operation
          );
          console.log(`\n✅ Group ${operation} completed:`);
          console.log(`   Total: ${result.totalServices}`);
          console.log(`   Successful: ${result.successful}`);
          console.log(`   Failed: ${result.failed}`);
        } catch (error) {
          console.error(
            `❌ Failed to execute group ${operation}:`,
            error.message
          );
        }
        break;

      case 'recommendations':
        const recommendations = manager.getRestartRecommendations();
        console.log('💡 Restart Recommendations:');
        recommendations.forEach(rec => {
          console.log(`\n${rec.type === 'group' ? '📋' : '🔗'} ${rec.reason}`);
          if (rec.services)
            console.log(`   Services: ${rec.services.join(', ')}`);
          if (rec.dependencies)
            console.log(`   Dependencies: ${rec.dependencies.join(', ')}`);
          console.log(`   Impact: ${rec.impact}`);
        });
        break;

      default:
        console.log('🔄 Wrfcoin Restart Groups Manager');
        console.log(
          'Usage: node restart-groups-manager.js <command> [options]'
        );
        console.log('');
        console.log('Commands:');
        console.log('  groups                    Show all restart groups');
        console.log('  startup                   Show startup sequence');
        console.log('  shutdown                  Show shutdown sequence');
        console.log(
          '  execute <group> [op]      Execute group operation (start|stop|restart)'
        );
        console.log('  recommendations           Show restart recommendations');
        console.log('');
        console.log('Examples:');
        console.log('  node restart-groups-manager.js groups');
        console.log('  node restart-groups-manager.js execute critical start');
    }
  }
}

// CLI execution
if (require.main === module) {
  RestartGroupsManager.runCLI().catch(console.error);
}

module.exports = { RestartGroupsManager };
