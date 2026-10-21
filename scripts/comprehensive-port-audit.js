/**
 * Comprehensive Port Audit for Wrfcoin Infrastructure
 * Scans all workflow configurations and active processes to create accurate port documentation
 */

const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');
const util = require('util');
const execAsync = util.promisify(exec);

class ComprehensivePortAudit {
  constructor() {
    this.workflowPorts = new Map();
    this.activePorts = new Map();
    this.portConflicts = [];
    this.undocumentedServices = [];

    // Known workflow to port mappings from actual configuration
    this.knownWorkflows = {
      'Frontend Application': 5000,
      'Cross-Chain Protocol Server': 3000,
      'Cross-Chain WebSocket Port 5001': 5001,
      'Missing Endpoints Server': 3001,
      'Unified API Server': 3001,
      'Unified API Server Port 3001': 3001,
      'Performance Dashboard API': 4002,
      'Wallet Server Port 4000': 4000,
      'Testnet API Server': 4001,
      'Testnet API Server Port 4001': 4001,
      'WebSocket Server Fixed': 4002,
      'Compute Networks Server': 6000,
      'AI ML Networks Port 6001': 6001,
      'IoT Sensor Networks Port 3002': 3002,
      'Storage Networks Port 7000': 7000,
      'Contract Integration Port 9000': 9000,
      'Node Discovery Port 9001': 9001,
      'Enhanced Cross-Chain Server Port 8002': 8002,
      'Memory Optimized Server': 8003,
    };
  }

  async scanActiveProcesses() {
    try {
      console.log('🔍 Scanning active network processes...');

      // Try multiple methods to get port information
      let output = '';
      try {
        const { stdout } = await execAsync(
          'ss -tulpn 2>/dev/null | grep LISTEN'
        );
        output = stdout;
      } catch (e) {
        try {
          const { stdout } = await execAsync(
            'netstat -tulpn 2>/dev/null | grep LISTEN'
          );
          output = stdout;
        } catch (e2) {
          console.log('⚠️  Could not scan active ports via ss or netstat');
          return;
        }
      }

      const lines = output.split('\n').filter(line => line.trim());

      for (const line of lines) {
        const portMatch = line.match(/:(\d+)\s/);
        if (portMatch) {
          const port = parseInt(portMatch[1]);
          if (port >= 2000 && port <= 9999) {
            // Focus on our port ranges
            const processMatch = line.match(/(\d+)\/(\w+)/);
            const process = processMatch ? processMatch[2] : 'unknown';
            this.activePorts.set(port, {
              process: process,
              line: line.trim(),
            });
          }
        }
      }

      console.log(
        `✅ Found ${this.activePorts.size} active ports in our ranges`
      );
    } catch (error) {
      console.log('⚠️  Port scanning failed:', error.message);
    }
  }

  scanWorkflowConfigurations() {
    console.log('📋 Analyzing workflow configurations...');

    // Add known workflows
    for (const [workflow, port] of Object.entries(this.knownWorkflows)) {
      this.workflowPorts.set(workflow, port);
    }

    // Scan for any server files to find additional ports
    try {
      this.scanServerFiles();
    } catch (error) {
      console.log('⚠️  Could not scan server files:', error.message);
    }

    console.log(`✅ Found ${this.workflowPorts.size} configured workflows`);
  }

  scanServerFiles() {
    const serverDirs = ['backend/server', 'server', 'contracts/integrations'];

    for (const dir of serverDirs) {
      if (fs.existsSync(dir)) {
        const files = fs.readdirSync(dir).filter(f => f.endsWith('.js'));

        for (const file of files) {
          try {
            const content = fs.readFileSync(path.join(dir, file), 'utf8');
            const portMatches = content.match(/(?:port|PORT).*?(\d{4,5})/g);

            if (portMatches) {
              for (const match of portMatches) {
                const portNum = match.match(/(\d{4,5})/);
                if (portNum) {
                  const port = parseInt(portNum[1]);
                  if (port >= 2000 && port <= 9999) {
                    const serviceName = file
                      .replace('.js', '')
                      .replace(/_/g, ' ');
                    if (
                      !Array.from(this.workflowPorts.values()).includes(port)
                    ) {
                      this.undocumentedServices.push({
                        file: path.join(dir, file),
                        service: serviceName,
                        port: port,
                      });
                    }
                  }
                }
              }
            }
          } catch (error) {
            // Skip files we can't read
          }
        }
      }
    }
  }

  detectConflicts() {
    console.log('🔎 Detecting port conflicts...');

    const portUsage = new Map();

    // Count workflow port usage
    for (const [workflow, port] of this.workflowPorts) {
      if (!portUsage.has(port)) {
        portUsage.set(port, []);
      }
      portUsage.get(port).push({ type: 'workflow', name: workflow });
    }

    // Add undocumented services
    for (const service of this.undocumentedServices) {
      if (!portUsage.has(service.port)) {
        portUsage.set(service.port, []);
      }
      portUsage.get(service.port).push({
        type: 'undocumented',
        name: service.service,
        file: service.file,
      });
    }

    // Find conflicts
    for (const [port, users] of portUsage) {
      if (users.length > 1) {
        this.portConflicts.push({
          port: port,
          conflicts: users,
        });
      }
    }

    console.log(`⚠️  Found ${this.portConflicts.length} port conflicts`);
  }

  generateComprehensiveReport() {
    console.log('\n📊 COMPREHENSIVE PORT AUDIT REPORT\n');
    console.log('='.repeat(60));

    // Active Ports Section
    console.log('\n🟢 ACTIVE PORTS:');
    const sortedActivePorts = Array.from(this.activePorts.entries()).sort(
      (a, b) => a[0] - b[0]
    );
    for (const [port, info] of sortedActivePorts) {
      console.log(`   ${port}: ${info.process}`);
    }

    // Configured Workflows Section
    console.log('\n📋 CONFIGURED WORKFLOWS:');
    const sortedWorkflows = Array.from(this.workflowPorts.entries()).sort(
      (a, b) => a[1] - b[1]
    );
    for (const [workflow, port] of sortedWorkflows) {
      const isActive = this.activePorts.has(port) ? '🟢' : '🔴';
      console.log(`   ${isActive} ${workflow}: ${port}`);
    }

    // Undocumented Services Section
    if (this.undocumentedServices.length > 0) {
      console.log('\n⚠️  UNDOCUMENTED SERVICES:');
      for (const service of this.undocumentedServices) {
        console.log(`   ${service.service}: ${service.port} (${service.file})`);
      }
    }

    // Port Conflicts Section
    if (this.portConflicts.length > 0) {
      console.log('\n🚨 PORT CONFLICTS:');
      for (const conflict of this.portConflicts) {
        console.log(`   Port ${conflict.port}:`);
        for (const user of conflict.conflicts) {
          console.log(
            `     - ${user.type}: ${user.name}${user.file ? ` (${user.file})` : ''}`
          );
        }
      }
    }

    // Port Range Analysis
    console.log('\n📈 PORT RANGE ANALYSIS:');
    const ranges = {
      'Management (2000-2999)': [2000, 2999],
      'API Services (3000-3999)': [3000, 3999],
      'Applications (4000-4999)': [4000, 4999],
      'Frontend (5000-5999)': [5000, 5999],
      'Compute (6000-6999)': [6000, 6999],
      'Storage (7000-7999)': [7000, 7999],
      'WebSocket (8000-8999)': [8000, 8999],
      'Integration (9000-9999)': [9000, 9999],
    };

    for (const [rangeName, [start, end]] of Object.entries(ranges)) {
      const portsInRange = Array.from(this.workflowPorts.values()).filter(
        port => port >= start && port <= end
      ).length;
      console.log(`   ${rangeName}: ${portsInRange} services`);
    }
  }

  generateOptimizedPortArchitecture() {
    const timestamp = new Date().toISOString();

    // Create optimized port assignments
    const optimizedPorts = new Map();
    const portRanges = {
      management: [2000, 2999],
      api: [3000, 3999],
      application: [4000, 4999],
      frontend: [5000, 5999],
      compute: [6000, 6999],
      storage: [7000, 7999],
      websocket: [8000, 8999],
      integration: [9000, 9999],
    };

    // Frontend stays at 5000
    optimizedPorts.set('Frontend Application', 5000);

    // API services in 3000 range
    optimizedPorts.set('Cross-Chain Protocol Server', 3000);
    optimizedPorts.set('Missing Endpoints Server', 3001);
    optimizedPorts.set('Unified API Server', 3001); // Same as Missing Endpoints

    // Application services in 4000 range
    optimizedPorts.set('Wallet Server Port 4000', 4000);
    optimizedPorts.set('Testnet API Server Port 4001', 4001);
    optimizedPorts.set('Performance Dashboard API', 4002);

    // WebSocket in 5000 range (Cross-Chain WebSocket)
    optimizedPorts.set('Cross-Chain WebSocket Port 5001', 5001);

    // Compute services in 6000 range
    optimizedPorts.set('Compute Networks Server', 6000);
    optimizedPorts.set('AI ML Networks Port 6001', 6001);

    // Storage in 7000 range
    optimizedPorts.set('Storage Networks Port 7000', 7000);

    // WebSocket services in 8000 range
    optimizedPorts.set('WebSocket Server Fixed', 8000);
    optimizedPorts.set('Enhanced Cross-Chain Server Port 8002', 8002);
    optimizedPorts.set('Memory Optimized Server', 8003);

    // Integration services in 9000 range
    optimizedPorts.set('Contract Integration Port 9000', 9000);
    optimizedPorts.set('Node Discovery Port 9001', 9001);

    return `# Wrfcoin Port Architecture (Comprehensive Audit)
*Generated: ${timestamp}*
*Status: ${this.portConflicts.length} conflicts detected, ${this.undocumentedServices.length} undocumented services*

## Current Port Assignments

### API Layer (3000-3999)
- Cross-Chain Protocol Server: 3000
- Missing Endpoints Server / Unified API Server: 3001

### Application Layer (4000-4999)
- Wallet Server: 4000
- Testnet API Server: 4001
- Performance Dashboard API: 4002
- WebSocket Server Fixed: 4002 ⚠️ CONFLICT

### Frontend Layer (5000-5999)
- Frontend Application: 5000
- Cross-Chain WebSocket: 5001

### Compute Layer (6000-6999)
- Compute Networks Server: 6000
- AI/ML Networks: 6001

### Storage Layer (7000-7999)
- Storage Networks: 7000

### WebSocket Layer (8000-8999)
- Enhanced Cross-Chain Server: 8002
- Memory Optimized Server: 8003

### Integration Layer (9000-9999)
- Contract Integration Server: 9000
- Node Discovery Server: 9001

## Detected Issues

${
  this.portConflicts.length > 0
    ? '### Port Conflicts\n' +
      this.portConflicts
        .map(
          c => `- Port ${c.port}: ${c.conflicts.map(u => u.name).join(', ')}`
        )
        .join('\n')
    : '### No Port Conflicts Detected'
}

${
  this.undocumentedServices.length > 0
    ? '\n### Undocumented Services\n' +
      this.undocumentedServices
        .map(s => `- ${s.service}: ${s.port} (${s.file})`)
        .join('\n')
    : ''
}

## Recommendations

1. **Resolve Port 4002 Conflict**: Performance Dashboard API and WebSocket Server Fixed both use port 4002
2. **Update Documentation**: Add all active services to port architecture docs
3. **Standardize Naming**: Ensure workflow names match service purposes
4. **Range Compliance**: Move services to appropriate port ranges

## Health Check Endpoints

All HTTP services should expose \`/health\` endpoints for monitoring.
`;
  }

  async run() {
    console.log('🚀 Starting Comprehensive Port Audit\n');

    await this.scanActiveProcesses();
    this.scanWorkflowConfigurations();
    this.detectConflicts();
    this.generateComprehensiveReport();

    // Generate updated documentation
    const newDoc = this.generateOptimizedPortArchitecture();
    const docPath = './docs/infrastructure/wrfcoin-port-architecture-audit.md';
    fs.writeFileSync(docPath, newDoc);

    console.log(`\n📝 Updated documentation saved to: ${docPath}`);
    console.log('\n🎯 Next Steps:');
    console.log('1. Review and resolve port conflicts');
    console.log('2. Update workflow configurations');
    console.log('3. Restart services with correct port assignments');

    return {
      conflicts: this.portConflicts.length,
      undocumented: this.undocumentedServices.length,
      total_services: this.workflowPorts.size,
    };
  }
}

// Run the audit
const audit = new ComprehensivePortAudit();
audit
  .run()
  .then(results => {
    console.log(
      `\n✅ Audit complete: ${results.conflicts} conflicts, ${results.undocumented} undocumented, ${results.total_services} total services`
    );
  })
  .catch(error => {
    console.error('❌ Audit failed:', error);
  });
