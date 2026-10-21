#!/usr/bin/env node

/**
 * WRFCoin Service Dependency Map Generator
 *
 * This script generates a comprehensive service dependency map for the WRFCoin platform.
 * It creates visual representations in multiple formats (DOT, JSON, Mermaid) and
 * provides real-time dependency health monitoring capabilities.
 */

const fs = require('fs');
const path = require('path');

// WRFCoin Platform Service Architecture Definition
const SERVICE_ARCHITECTURE = {
  // Level 0 - Monitoring Infrastructure
  level0: {
    prometheus: {
      port: 9090,
      tier: 'monitoring',
      dependencies: [],
      description: 'Metrics collection and alerting',
      criticalness: 'high',
      healthEndpoint: '/metrics',
    },
  },

  // Level 1 - Foundation Infrastructure
  level1: {
    'wrfcoin-core': {
      port: 5000,
      tier: 'core',
      dependencies: [],
      description: 'Core blockchain service with WVM',
      criticalness: 'critical',
      healthEndpoint: '/health',
    },
    postgresql: {
      port: 5432,
      tier: 'database',
      dependencies: [],
      description: 'Primary database (21-table schema)',
      criticalness: 'critical',
      healthEndpoint: null,
    },
    'redis-cache': {
      port: 6379,
      tier: 'cache',
      dependencies: [],
      description: 'Primary caching layer',
      criticalness: 'high',
      healthEndpoint: null,
    },
    'iot-sensor-networks': {
      port: 3002,
      tier: 'iot',
      dependencies: [],
      description: '20+ IoT platform integrations',
      criticalness: 'medium',
      healthEndpoint: '/health',
    },
    'node-discovery': {
      port: 9001,
      tier: 'discovery',
      dependencies: [],
      description: 'P2P network node discovery',
      criticalness: 'medium',
      healthEndpoint: '/health',
    },
    'clamav-antivirus': {
      port: 3310,
      tier: 'security',
      dependencies: [],
      description: 'Antivirus scanning service',
      criticalness: 'low',
      healthEndpoint: null,
    },
  },

  // Level 2 - Core Services
  level2: {
    'wrfcoin-main-api': {
      port: 4001,
      tier: 'api',
      dependencies: ['wrfcoin-core', 'postgresql', 'redis-cache'],
      description: 'Main API server with GraphQL',
      criticalness: 'critical',
      healthEndpoint: '/health',
    },
    'cross-chain-protocol': {
      port: 3000,
      tier: 'bridge',
      dependencies: ['wrfcoin-core'],
      description: '13+ cross-chain bridges',
      criticalness: 'high',
      healthEndpoint: '/health',
    },
    'weather-service': {
      port: 3001,
      tier: 'data',
      dependencies: ['wrfcoin-core', 'iot-sensor-networks'],
      description: 'Weather data collection and validation',
      criticalness: 'medium',
      healthEndpoint: '/health',
    },
    'compute-networks': {
      port: 6000,
      tier: 'network',
      dependencies: ['wrfcoin-core'],
      description: 'Distributed computing coordination',
      criticalness: 'medium',
      healthEndpoint: '/health',
    },
    'ai-ml-networks': {
      port: 6001,
      tier: 'network',
      dependencies: ['wrfcoin-core'],
      description: 'AI/ML model deployment network',
      criticalness: 'medium',
      healthEndpoint: '/health',
    },
    'storage-networks': {
      port: 7000,
      tier: 'storage',
      dependencies: ['wrfcoin-core'],
      description: 'IPFS/Filecoin/Arweave integration',
      criticalness: 'medium',
      healthEndpoint: '/health',
    },
  },

  // Level 3 - Application Services
  level3: {
    'api-gateway': {
      port: 4000,
      tier: 'gateway',
      dependencies: ['nft-service', 'user-service', 'wrfcoin-main-api'],
      description: 'API Gateway with routing',
      criticalness: 'high',
      healthEndpoint: '/health',
    },
    'ml-inference': {
      port: 8080,
      tier: 'compute',
      dependencies: ['wrfcoin-core', 'ai-ml-networks'],
      description: 'ML inference with GPU support',
      criticalness: 'medium',
      healthEndpoint: '/health',
    },
    'etl-pipeline': {
      port: 5000,
      tier: 'data',
      dependencies: ['wrfcoin-core', 'weather-service', 'postgresql'],
      description: 'Data transformation pipeline',
      criticalness: 'medium',
      healthEndpoint: '/health',
    },
    'governance-server': {
      port: 8000,
      tier: 'governance',
      dependencies: ['wrfcoin-main-api'],
      description: 'DAO proposals and voting',
      criticalness: 'medium',
      healthEndpoint: '/health',
    },
    'nas-storage': {
      port: 7001,
      tier: 'storage',
      dependencies: ['storage-networks'],
      description: 'NAS storage node management',
      criticalness: 'low',
      healthEndpoint: '/health',
    },
  },

  // Level 4 - Microservices
  level4: {
    'nft-service': {
      port: 4002,
      tier: 'microservice',
      dependencies: ['wrfcoin-main-api'],
      description: 'NFT marketplace service',
      criticalness: 'medium',
      healthEndpoint: '/health',
    },
    'user-service': {
      port: 4003,
      tier: 'microservice',
      dependencies: ['wrfcoin-main-api'],
      description: 'User management service',
      criticalness: 'high',
      healthEndpoint: '/health',
    },
    'weather-earnings': {
      port: 8080,
      tier: 'rewards',
      dependencies: ['weather-service', 'wrfcoin-main-api'],
      description: 'Weather station reward distribution',
      criticalness: 'medium',
      healthEndpoint: '/health',
    },
  },
};

// Service tier definitions and characteristics
const SERVICE_TIERS = {
  monitoring: {
    color: '#FF6B6B',
    priority: 0,
    description: 'Monitoring Infrastructure',
  },
  core: { color: '#4ECDC4', priority: 1, description: 'Blockchain Core' },
  database: { color: '#45B7D1', priority: 1, description: 'Data Storage' },
  cache: { color: '#96CEB4', priority: 1, description: 'Caching Layer' },
  api: { color: '#FFEAA7', priority: 2, description: 'API Services' },
  gateway: { color: '#DDA0DD', priority: 3, description: 'API Gateway' },
  bridge: { color: '#FFB347', priority: 2, description: 'Cross-Chain Bridges' },
  data: { color: '#87CEEB', priority: 2, description: 'Data Processing' },
  network: { color: '#F0E68C', priority: 2, description: 'Network Services' },
  storage: { color: '#DEB887', priority: 2, description: 'Storage Services' },
  compute: { color: '#FFA07A', priority: 3, description: 'Compute Services' },
  microservice: { color: '#B19CD9', priority: 4, description: 'Microservices' },
  iot: { color: '#FFD700', priority: 1, description: 'IoT Networks' },
  discovery: {
    color: '#98FB98',
    priority: 1,
    description: 'Service Discovery',
  },
  security: { color: '#F08080', priority: 1, description: 'Security Services' },
  governance: { color: '#20B2AA', priority: 3, description: 'Governance' },
  rewards: { color: '#FF69B4', priority: 4, description: 'Reward Systems' },
  runtime: { color: '#DAA520', priority: 5, description: 'Runtime Metrics' },
};

class ServiceDependencyMapper {
  constructor() {
    this.services = this.flattenServices();
    this.outputDir = path.join(__dirname, 'dependency-maps');
    this.ensureOutputDir();
  }

  flattenServices() {
    const flattened = {};
    Object.keys(SERVICE_ARCHITECTURE).forEach(level => {
      Object.keys(SERVICE_ARCHITECTURE[level]).forEach(serviceName => {
        const service = SERVICE_ARCHITECTURE[level][serviceName];
        flattened[serviceName] = {
          ...service,
          level: level,
          levelNumber: parseInt(level.replace('level', '')),
        };
      });
    });
    return flattened;
  }

  ensureOutputDir() {
    if (!fs.existsSync(this.outputDir)) {
      fs.mkdirSync(this.outputDir, { recursive: true });
    }
  }

  generateDOTGraph() {
    let dot = `digraph WRFCoinServiceDependencies {
  rankdir=TB;
  node [fontname="Arial", fontsize=10, shape=box, style=filled];
  edge [fontname="Arial", fontsize=8];
  
  // Service tier subgraphs for better organization
`;

    // Group services by tier
    const tierGroups = {};
    Object.keys(this.services).forEach(serviceName => {
      const service = this.services[serviceName];
      if (!tierGroups[service.tier]) {
        tierGroups[service.tier] = [];
      }
      tierGroups[service.tier].push(serviceName);
    });

    // Create subgraphs for each tier
    Object.keys(tierGroups).forEach(tier => {
      const tierInfo = SERVICE_TIERS[tier];
      dot += `
  subgraph cluster_${tier} {
    label="${tierInfo.description}";
    style=filled;
    color="${tierInfo.color}30";
    fontsize=12;
    fontweight=bold;
`;

      tierGroups[tier].forEach(serviceName => {
        const service = this.services[serviceName];
        const criticalityStyle = this.getCriticalityStyle(service.criticalness);
        dot += `    "${serviceName}" [label="${serviceName}\\nPort: ${service.port}\\n${service.description}", fillcolor="${tierInfo.color}", ${criticalityStyle}];\n`;
      });

      dot += '  }\n';
    });

    // Add dependencies
    dot += '\n  // Dependencies\n';
    Object.keys(this.services).forEach(serviceName => {
      const service = this.services[serviceName];
      service.dependencies.forEach(depName => {
        const depService = this.services[depName];
        const edgeStyle = this.getEdgeStyle(
          service.criticalness,
          depService?.criticalness
        );
        dot += `  "${depName}" -> "${serviceName}" [${edgeStyle}];\n`;
      });
    });

    // Add legend
    dot += `
  // Legend
  subgraph cluster_legend {
    label="Service Criticality Legend";
    style=filled;
    color="#F0F0F0";
    fontsize=10;
    
    legend_critical [label="Critical Service", fillcolor="#FF4444", shape=box];
    legend_high [label="High Priority", fillcolor="#FFA500", shape=box];
    legend_medium [label="Medium Priority", fillcolor="#FFFF00", shape=box];
    legend_low [label="Low Priority", fillcolor="#90EE90", shape=box];
    
    legend_critical -> legend_high -> legend_medium -> legend_low [style=invis];
  }

}`;

    return dot;
  }

  getCriticalityStyle(criticality) {
    const styles = {
      critical: 'penwidth=3, color="#FF0000"',
      high: 'penwidth=2, color="#FFA500"',
      medium: 'penwidth=1, color="#FFFF00"',
      low: 'penwidth=1, color="#90EE90"',
    };
    return styles[criticality] || styles['medium'];
  }

  getEdgeStyle(fromCriticality, toCriticality) {
    if (fromCriticality === 'critical' || toCriticality === 'critical') {
      return 'penwidth=3, color="#FF0000"';
    }
    if (fromCriticality === 'high' || toCriticality === 'high') {
      return 'penwidth=2, color="#FFA500"';
    }
    return 'penwidth=1, color="#666666"';
  }

  generateMermaidDiagram() {
    let mermaid = `graph TD
    %% WRFCoin Service Dependency Map
    %% Generated automatically - DO NOT EDIT MANUALLY
    
`;

    // Define nodes with styling
    Object.keys(this.services).forEach(serviceName => {
      const service = this.services[serviceName];
      const tierInfo = SERVICE_TIERS[service.tier];
      const nodeId = serviceName.replace(/-/g, '_');
      mermaid += `    ${nodeId}["${serviceName}<br/>Port: ${service.port}<br/>${service.description}"]\n`;
    });

    mermaid += '\n    %% Dependencies\n';

    // Add dependencies
    Object.keys(this.services).forEach(serviceName => {
      const service = this.services[serviceName];
      const nodeId = serviceName.replace(/-/g, '_');
      service.dependencies.forEach(depName => {
        const depNodeId = depName.replace(/-/g, '_');
        mermaid += `    ${depNodeId} --> ${nodeId}\n`;
      });
    });

    // Add styling
    mermaid += '\n    %% Styling by service tier\n';
    Object.keys(SERVICE_TIERS).forEach(tier => {
      const tierInfo = SERVICE_TIERS[tier];
      const servicesInTier = Object.keys(this.services).filter(
        s => this.services[s].tier === tier
      );
      if (servicesInTier.length > 0) {
        const nodeIds = servicesInTier.map(s => s.replace(/-/g, '_')).join(',');
        mermaid += `    classDef ${tier}Class fill:${tierInfo.color},stroke:#333,stroke-width:2px\n`;
        mermaid += `    class ${nodeIds} ${tier}Class\n`;
      }
    });

    return mermaid;
  }

  generateJSONStructure() {
    const structure = {
      metadata: {
        generated: new Date().toISOString(),
        platform: 'WRFCoin',
        total_services: Object.keys(this.services).length,
        dependency_levels: Object.keys(SERVICE_ARCHITECTURE).length,
        tiers: Object.keys(SERVICE_TIERS),
      },
      services: {},
      tiers: SERVICE_TIERS,
      dependency_matrix: {},
      health_endpoints: {},
      critical_path_analysis: this.analyzeCriticalPaths(),
    };

    // Add services with full details
    Object.keys(this.services).forEach(serviceName => {
      structure.services[serviceName] = this.services[serviceName];
    });

    // Create dependency matrix
    Object.keys(this.services).forEach(serviceName => {
      structure.dependency_matrix[serviceName] =
        this.services[serviceName].dependencies;
    });

    // Create health endpoints map
    Object.keys(this.services).forEach(serviceName => {
      const service = this.services[serviceName];
      if (service.healthEndpoint) {
        structure.health_endpoints[serviceName] =
          `http://localhost:${service.port}${service.healthEndpoint}`;
      }
    });

    return structure;
  }

  analyzeCriticalPaths() {
    const criticalPaths = [];
    const criticalServices = Object.keys(this.services).filter(
      name => this.services[name].criticalness === 'critical'
    );

    criticalServices.forEach(serviceName => {
      const path = this.buildDependencyPath(serviceName);
      criticalPaths.push({
        service: serviceName,
        path: path,
        risk_level: this.calculateRiskLevel(path),
      });
    });

    return criticalPaths;
  }

  buildDependencyPath(serviceName, visited = new Set()) {
    if (visited.has(serviceName)) {
      return []; // Avoid circular dependencies
    }

    visited.add(serviceName);
    const service = this.services[serviceName];
    const path = [serviceName];

    service.dependencies.forEach(depName => {
      const depPath = this.buildDependencyPath(depName, new Set(visited));
      path.push(...depPath);
    });

    return path;
  }

  calculateRiskLevel(path) {
    const criticalCount = path.filter(
      service => this.services[service]?.criticalness === 'critical'
    ).length;

    if (criticalCount >= 3) return 'high';
    if (criticalCount >= 2) return 'medium';
    return 'low';
  }

  generatePrometheusConfig() {
    const config = {
      scrape_configs: [],
    };

    Object.keys(this.services).forEach(serviceName => {
      const service = this.services[serviceName];
      if (service.healthEndpoint) {
        config.scrape_configs.push({
          job_name: serviceName,
          static_configs: [
            {
              targets: [`localhost:${service.port}`],
            },
          ],
          metrics_path:
            service.healthEndpoint === '/health'
              ? '/metrics'
              : service.healthEndpoint,
          scrape_interval: this.getScrapeInterval(service.criticalness),
          relabel_configs: [
            {
              source_labels: ['__address__'],
              target_label: 'service_tier',
              replacement: service.tier,
            },
            {
              source_labels: ['__address__'],
              target_label: 'dependency_level',
              replacement: service.levelNumber.toString(),
            },
            {
              source_labels: ['__address__'],
              target_label: 'criticality',
              replacement: service.criticalness,
            },
          ],
        });
      }
    });

    return config;
  }

  getScrapeInterval(criticality) {
    const intervals = {
      critical: '10s',
      high: '15s',
      medium: '30s',
      low: '60s',
    };
    return intervals[criticality] || '30s';
  }

  generateAll() {
    console.log('🚀 Generating WRFCoin Service Dependency Maps...\n');

    // Generate DOT graph
    const dotGraph = this.generateDOTGraph();
    fs.writeFileSync(
      path.join(this.outputDir, 'service-dependencies.dot'),
      dotGraph
    );
    console.log('✅ Generated Graphviz DOT file: service-dependencies.dot');

    // Generate Mermaid diagram
    const mermaidDiagram = this.generateMermaidDiagram();
    fs.writeFileSync(
      path.join(this.outputDir, 'service-dependencies.mmd'),
      mermaidDiagram
    );
    console.log('✅ Generated Mermaid diagram: service-dependencies.mmd');

    // Generate JSON structure
    const jsonStructure = this.generateJSONStructure();
    fs.writeFileSync(
      path.join(this.outputDir, 'service-dependencies.json'),
      JSON.stringify(jsonStructure, null, 2)
    );
    console.log('✅ Generated JSON structure: service-dependencies.json');

    // Generate Prometheus config snippet
    const prometheusConfig = this.generatePrometheusConfig();
    fs.writeFileSync(
      path.join(this.outputDir, 'prometheus-services.yml'),
      `# WRFCoin Service Dependencies Prometheus Configuration\n# Generated automatically\n\n${JSON.stringify(prometheusConfig, null, 2)}`
    );
    console.log('✅ Generated Prometheus config: prometheus-services.yml');

    // Generate README
    this.generateREADME();
    console.log('✅ Generated README: README.md');

    console.log(`\n🎉 Service dependency mapping complete!`);
    console.log(`📁 Files generated in: ${this.outputDir}`);
    console.log(
      `📊 Total services mapped: ${Object.keys(this.services).length}`
    );
    console.log(
      `🔗 Total dependencies: ${Object.values(this.services).reduce((acc, s) => acc + s.dependencies.length, 0)}`
    );
    console.log(`🏷️  Service tiers: ${Object.keys(SERVICE_TIERS).length}`);
  }

  generateREADME() {
    const readme = `# WRFCoin Service Dependency Map

Generated on: ${new Date().toISOString()}

## Overview

This directory contains comprehensive service dependency mapping for the WRFCoin platform, including ${Object.keys(this.services).length} services across ${Object.keys(SERVICE_TIERS).length} tiers.

## Files

- **service-dependencies.dot**: Graphviz DOT format for visual graph generation
- **service-dependencies.mmd**: Mermaid diagram format for documentation
- **service-dependencies.json**: Complete JSON structure with metadata
- **prometheus-services.yml**: Prometheus configuration for monitoring

## Service Tiers

${Object.keys(SERVICE_TIERS)
  .map(tier => {
    const tierInfo = SERVICE_TIERS[tier];
    const servicesInTier = Object.keys(this.services).filter(
      s => this.services[s].tier === tier
    );
    return `### ${tierInfo.description}
- **Services**: ${servicesInTier.join(', ')}
- **Count**: ${servicesInTier.length}
- **Priority**: ${tierInfo.priority}`;
  })
  .join('\n\n')}

## Critical Services

${Object.keys(this.services)
  .filter(name => this.services[name].criticalness === 'critical')
  .map(name => `- **${name}**: ${this.services[name].description}`)
  .join('\n')}

## Generating Visuals

### Using Graphviz
\`\`\`bash
dot -Tpng service-dependencies.dot -o service-dependencies.png
dot -Tsvg service-dependencies.dot -o service-dependencies.svg
\`\`\`

### Using Mermaid CLI
\`\`\`bash
mmdc -i service-dependencies.mmd -o service-dependencies.png
\`\`\`

## Monitoring Integration

The generated Prometheus configuration can be integrated into your existing Prometheus setup:

\`\`\`yaml
# Add to your prometheus.yml
include:
  - "prometheus-services.yml"
\`\`\`

## Health Endpoints

${Object.keys(this.services)
  .filter(name => this.services[name].healthEndpoint)
  .map(name => {
    const service = this.services[name];
    return `- **${name}**: http://localhost:${service.port}${service.healthEndpoint}`;
  })
  .join('\n')}
`;

    fs.writeFileSync(path.join(this.outputDir, 'README.md'), readme);
  }
}

// Run the generator
if (require.main === module) {
  const mapper = new ServiceDependencyMapper();
  mapper.generateAll();
}

module.exports = ServiceDependencyMapper;
