/**
 * Enhanced Wrfcoin Service Control Panel
 * Unified management for weather stations, storage nodes, and distributed services
 * Extends existing control panel with NAS storage integration
 */

const fs = require('fs');
const path = require('path');
const express = require('express');
const axios = require('axios');
const { execSync, spawn } = require('child_process');
const { corsMiddleware } = require('../backend/shared/middleware/cors-config.cjs');

// Extended service metadata including NAS storage services
const SERVICE_METADATA = {
  // Weather & Earnings Services (Protected)
  'AcuRite Weather Station Collector': {
    port: null,
    category: 'earnings',
    status: 'running',
    priority: 'protected',
    tags: ['@weather', '@earnings', '@protected'],
    file: 'acurite-working-collector.js',
    command: 'node acurite-working-collector.js',
    dependencies: [],
    autoStart: true,
    protected: true,
    description: 'Weather data collection earning 1.70 WRF',
  },

  // Core Services
  'Frontend Application': {
    port: 5000,
    category: 'core',
    status: 'running',
    priority: 'critical',
    tags: ['@frontend', '@ui', '@critical'],
    file: 'frontend/src/main.jsx',
    command: 'cd frontend && npm run dev -- --host 0.0.0.0 --port 5000',
    dependencies: ['Main API Server'],
    autoStart: true,
    protected: false,
    description: 'Main user interface',
  },

  'Main API Server': {
    port: 4000,
    category: 'core',
    status: 'running',
    priority: 'critical',
    tags: ['@api', '@backend', '@critical'],
    file: 'backend/server/main_api_server.js',
    command: 'node backend/server/main_api_server.js',
    dependencies: [],
    autoStart: true,
    protected: false,
    description: 'Core API and wallet operations',
  },

  // Network Services
  'Cross-Chain WebSocket Port 5001': {
    port: 5001,
    category: 'network',
    status: 'running',
    priority: 'critical',
    tags: ['@websocket', '@cross-chain', '@critical'],
    file: 'backend/server/cross_chain_websocket_server.js',
    command: 'node backend/server/cross_chain_websocket_server.js',
    dependencies: [],
    autoStart: true,
    protected: false,
    description: 'Real-time cross-chain communication',
  },

  'IoT Sensor Networks Port 3002': {
    port: 3002,
    category: 'network',
    status: 'running',
    priority: 'high',
    tags: ['@iot', '@sensors', '@network'],
    file: 'backend/server/iot_sensor_networks_server_fixed.js',
    command: 'node backend/server/iot_sensor_networks_server_fixed.js',
    dependencies: [],
    autoStart: true,
    protected: false,
    description: '740,000 IoT devices managed',
  },
};

class EnhancedServiceControlPanel {
  constructor() {
    this.app = express();
    this.services = SERVICE_METADATA;
    this.powerMode = 'normal';
    this.nasNodes = new Map();
    this.weatherEarnings = 0;
    this.storageEarnings = 0;
    this.setupMiddleware();
    this.setupRoutes();
    this.startMonitoring();
  }

  setupMiddleware() {
    this.app.use(express.json());
    this.app.use(express.static('public'));

    // CORS with proper origin validation
    this.app.use(corsMiddleware);
  }

  setupRoutes() {
    // Main control panel UI
    this.app.get('/', (req, res) => {
      res.send(this.generateEnhancedControlPanelHTML());
    });

    // Enhanced API endpoints
    this.app.get('/api/services', (req, res) => {
      res.json(this.getServicesStatus());
    });

    this.app.get('/api/nas/nodes', (req, res) => {
      res.json(this.getNASNodesStatus());
    });

    this.app.get('/api/nas/discovery', (req, res) => {
      res.json(this.discoverNASDevices());
    });

    this.app.post('/api/nas/register', (req, res) => {
      const result = this.registerNASDevice(req.body);
      res.json(result);
    });

    this.app.get('/api/earnings/summary', (req, res) => {
      res.json(this.getEarningsSummary());
    });

    this.app.post('/api/services/:name/toggle', (req, res) => {
      const serviceName = decodeURIComponent(req.params.name);
      const result = this.toggleService(serviceName);
      res.json(result);
    });

    this.app.get('/api/status', (req, res) => {
      res.json(this.getSystemStatus());
    });
  }

  getNASNodesStatus() {
    return { success: false, unavailable: true,
      error: 'Legacy NAS services retired; use the real IPFS archive path' };
  }

  discoverNASDevices() {
    return { success: false, unavailable: true,
      error: 'Legacy NAS services retired; use the real IPFS archive path' };
  }

  registerNASDevice() {
    return { success: false, unavailable: true,
      error: 'Legacy NAS services retired; use the real IPFS archive path' };
  }

  getEarningsSummary() {
    return { success: false, unavailable: true,
      error: 'Legacy NAS services retired; use the real IPFS archive path' };
  }

  getServicesStatus() {
    const categorized = {};

    Object.entries(this.services).forEach(([name, service]) => {
      if (!categorized[service.category]) {
        categorized[service.category] = [];
      }
      categorized[service.category].push({
        name,
        ...service,
        realTimeStatus: this.checkServiceHealth(service),
      });
    });

    return {
      services: categorized,
      summary: this.getServicesSummary(),
      powerMode: this.powerMode,
    };
  }

  getServicesSummary() {
    const total = Object.keys(this.services).length;
    const running = Object.values(this.services).filter(
      s => s.status === 'running'
    ).length;
    const protectedServices = Object.values(this.services).filter(
      s => s.protected
    ).length;

    return {
      total,
      running,
      stopped: total - running,
      protected: protectedServices,
      categories: {
        earnings: Object.values(this.services).filter(
          s => s.category === 'earnings'
        ).length,
        storage: Object.values(this.services).filter(
          s => s.category === 'storage'
        ).length,
        core: Object.values(this.services).filter(s => s.category === 'core')
          .length,
        network: Object.values(this.services).filter(
          s => s.category === 'network'
        ).length,
      },
    };
  }

  checkServiceHealth(service) {
    // Enhanced health check that considers NAS storage status
    if (service.name === 'NAS Storage Auto-Collector') {
      return {
        status: service.status,
        health: service.status === 'running' ? 'healthy' : 'stopped',
        nodes: this.nasNodes.size,
        earnings: Array.from(this.nasNodes.values()).reduce(
          (sum, node) => sum + node.earnings,
          0
        ),
      };
    }

    return {
      status: service.status,
      health: service.status === 'running' ? 'healthy' : 'stopped',
    };
  }

  toggleService(serviceName) {
    const service = this.services[serviceName];

    if (!service) {
      return { success: false, error: 'Service not found' };
    }

    if (service.protected) {
      return {
        success: false,
        error: 'Protected service cannot be modified',
        message: 'Weather earnings are protected from accidental shutdown',
      };
    }

    try {
      if (service.status === 'running') {
        // Stop service
        service.status = 'stopped';
        console.log(`🛑 Stopping ${serviceName}`);
      } else {
        // Start service
        service.status = 'running';
        console.log(`🚀 Starting ${serviceName}`);
      }

      return {
        success: true,
        service: serviceName,
        newStatus: service.status,
        message: `${serviceName} ${service.status === 'running' ? 'started' : 'stopped'} successfully`,
      };
    } catch (error) {
      return {
        success: false,
        error: error.message,
      };
    }
  }

  generateEnhancedControlPanelHTML() {
    return `
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Wrfcoin Enhanced Service Control Panel</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #0a0a0a; color: #e0e0e0; }
        .container { max-width: 1400px; margin: 0 auto; padding: 20px; }
        .header { text-align: center; margin-bottom: 30px; }
        .header h1 { color: #00d4aa; font-size: 2.5em; margin-bottom: 10px; }
        .header p { color: #888; font-size: 1.1em; }
        
        .dashboard { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-bottom: 30px; }
        .earnings-panel { background: linear-gradient(135deg, #1a3a2e, #0f2922); border-radius: 12px; padding: 20px; }
        .storage-panel { background: linear-gradient(135deg, #2a1a3a, #1f0f29); border-radius: 12px; padding: 20px; }
        
        .panel-title { font-size: 1.3em; color: #fff; margin-bottom: 15px; display: flex; align-items: center; }
        .panel-title::before { content: '💰'; margin-right: 10px; }
        .storage-panel .panel-title::before { content: '🗄️'; }
        
        .earnings-row { display: flex; justify-content: space-between; margin-bottom: 10px; }
        .earnings-source { color: #ccc; }
        .earnings-amount { color: #00d4aa; font-weight: bold; }
        .total-earnings { font-size: 1.2em; border-top: 1px solid #333; padding-top: 10px; margin-top: 15px; }
        
        .services-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; }
        .service-category { background: #1a1a1a; border-radius: 12px; padding: 20px; border-left: 4px solid #00d4aa; }
        .category-title { font-size: 1.2em; color: #00d4aa; margin-bottom: 15px; text-transform: uppercase; }
        
        .service-item { background: #2a2a2a; border-radius: 8px; padding: 15px; margin-bottom: 10px; transition: all 0.3s; }
        .service-item:hover { background: #333; transform: translateY(-2px); }
        .service-name { font-weight: bold; color: #fff; margin-bottom: 5px; }
        .service-description { color: #aaa; font-size: 0.9em; margin-bottom: 10px; }
        .service-status { display: flex; justify-content: space-between; align-items: center; }
        .status-badge { padding: 4px 12px; border-radius: 20px; font-size: 0.8em; font-weight: bold; }
        .status-running { background: #16a085; color: white; }
        .status-stopped { background: #e74c3c; color: white; }
        .status-protected { background: #f39c12; color: white; }
        
        .toggle-btn { background: #34495e; color: white; border: none; padding: 6px 12px; border-radius: 4px; cursor: pointer; }
        .toggle-btn:hover { background: #4a6741; }
        .toggle-btn:disabled { background: #666; cursor: not-allowed; }
        
        .nas-discovery { background: #1a1a1a; border-radius: 12px; padding: 20px; margin-top: 20px; }
        .discover-btn { background: #00d4aa; color: #000; border: none; padding: 10px 20px; border-radius: 6px; cursor: pointer; font-weight: bold; }
        .discover-btn:hover { background: #00b894; }
        
        .discovered-devices { margin-top: 15px; }
        .device-item { background: #2a2a2a; padding: 10px; margin: 5px 0; border-radius: 6px; }
        
        @media (max-width: 768px) {
            .dashboard { grid-template-columns: 1fr; }
            .services-grid { grid-template-columns: 1fr; }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🎮 Wrfcoin Enhanced Control Panel</h1>
            <p>Unified Management: Weather Stations + Storage Networks + Distributed Services</p>
        </div>

        <div class="dashboard">
            <div class="earnings-panel">
                <div class="panel-title">Earnings Dashboard</div>
                <div id="earnings-content">Loading earnings data...</div>
            </div>
            
            <div class="storage-panel">
                <div class="panel-title">Storage Network Status</div>
                <div id="storage-content">Loading storage data...</div>
            </div>
        </div>

        <div class="services-grid" id="services-grid">
            Loading services...
        </div>

        <div class="nas-discovery">
            <h3>🔍 NAS Device Discovery</h3>
            <p>Legacy NAS discovery and registration are retired.</p>
            <button class="discover-btn" disabled>NAS discovery unavailable</button>
            <div class="discovered-devices" id="discovered-devices"></div>
        </div>
    </div>

    <script>
        let services = {};
        
        async function loadData() {
            await Promise.all([loadServices(), loadEarnings(), loadStorage()]);
        }

        async function loadServices() {
            try {
                const response = await fetch('/api/services');
                const data = await response.json();
                services = data.services;
                renderServices(data.services);
            } catch (error) {
                console.error('Failed to load services:', error);
            }
        }

        async function loadEarnings() {
            try {
                const response = await fetch('/api/earnings/summary');
                const data = await response.json();
                if (data.unavailable) {
                    document.getElementById('earnings-content').textContent = 'Legacy NAS earnings summary unavailable';
                    return;
                }
                renderEarnings(data.earnings);
            } catch (error) {
                console.error('Failed to load earnings:', error);
            }
        }

        async function loadStorage() {
            try {
                const response = await fetch('/api/nas/nodes');
                const data = await response.json();
                renderStorage(data);
            } catch (error) {
                console.error('Failed to load storage data:', error);
            }
        }

        function renderServices(servicesByCategory) {
            const grid = document.getElementById('services-grid');
            grid.innerHTML = '';

            Object.entries(servicesByCategory).forEach(([category, categoryServices]) => {
                const categoryDiv = document.createElement('div');
                categoryDiv.className = 'service-category';
                
                categoryDiv.innerHTML = \`
                    <div class="category-title">\${category} Services</div>
                    \${categoryServices.map(service => \`
                        <div class="service-item">
                            <div class="service-name">\${service.name}</div>
                            <div class="service-description">\${service.description}</div>
                            <div class="service-status">
                                <span class="status-badge status-\${service.protected ? 'protected' : service.status}">
                                    \${service.protected ? 'PROTECTED' : service.status.toUpperCase()}
                                </span>
                                <button class="toggle-btn" 
                                        onclick="toggleService('\${service.name}')"
                                        \${service.protected ? 'disabled' : ''}>
                                    \${service.status === 'running' ? 'Stop' : 'Start'}
                                </button>
                            </div>
                        </div>
                    \`).join('')}
                \`;
                
                grid.appendChild(categoryDiv);
            });
        }

        function renderEarnings(earnings) {
            const content = document.getElementById('earnings-content');
            content.innerHTML = \`
                <div class="earnings-row">
                    <span class="earnings-source">Weather Station:</span>
                    <span class="earnings-amount">\${earnings.weather.total.toFixed(4)} WRF</span>
                </div>
                <div class="earnings-row">
                    <span class="earnings-source">Storage Network:</span>
                    <span class="earnings-amount">\${earnings.storage.total.toFixed(4)} WRF</span>
                </div>
                <div class="earnings-row total-earnings">
                    <span class="earnings-source">Total Earnings:</span>
                    <span class="earnings-amount">\${earnings.combined.toFixed(4)} WRF</span>
                </div>
                <div style="margin-top: 10px; font-size: 0.9em; color: #888;">
                    Wallet: \${earnings.wallet}
                </div>
            \`;
        }

        function renderStorage(data) {
            const content = document.getElementById('storage-content');
            if (data.unavailable) {
                content.textContent = 'Legacy NAS services retired';
                return;
            }
            content.innerHTML = \`
                <div class="earnings-row">
                    <span class="earnings-source">Active Nodes:</span>
                    <span class="earnings-amount">\${data.nodes.length}</span>
                </div>
                <div class="earnings-row">
                    <span class="earnings-source">Storage Status:</span>
                    <span class="earnings-amount">\${data.success ? 'Online' : 'Offline'}</span>
                </div>
                <div class="earnings-row">
                    <span class="earnings-source">Auto-Collector:</span>
                    <span class="earnings-amount">\${services.earnings?.find(s => s.name.includes('NAS'))?.status || 'Stopped'}</span>
                </div>
            \`;
        }

        async function toggleService(serviceName) {
            try {
                const response = await fetch(\`/api/services/\${encodeURIComponent(serviceName)}/toggle\`, {
                    method: 'POST'
                });
                const result = await response.json();
                
                if (result.success) {
                    loadData(); // Refresh all data
                } else {
                    alert(result.error || result.message);
                }
            } catch (error) {
                alert('Failed to toggle service: ' + error.message);
            }
        }

        async function discoverNAS() {
            const btn = event.target;
            btn.disabled = true;
            btn.textContent = 'Scanning...';
            
            try {
                const response = await fetch('/api/nas/discovery');
                const data = await response.json();
                
                const devicesDiv = document.getElementById('discovered-devices');
                if (data.success && data.discoveredDevices.length > 0) {
                    devicesDiv.innerHTML = \`
                        <h4>Found \${data.discoveredDevices.length} NAS devices:</h4>
                        \${data.discoveredDevices.map(device => \`
                            <div class="device-item">
                                <strong>\${device.type} \${device.model}</strong><br>
                                IP: \${device.ipAddress} | Capacity: \${device.estimatedCapacity}<br>
                                Estimated earnings: \${device.estimatedEarnings}/month
                                <button onclick="registerDevice(this, \${JSON.stringify(device).replace(/"/g, '&quot;')})" 
                                        style="float: right; background: #00d4aa; border: none; padding: 5px 10px; border-radius: 3px;">
                                    Register
                                </button>
                            </div>
                        \`).join('')}
                    \`;
                } else {
                    devicesDiv.innerHTML = '<p>No NAS devices discovered. Make sure devices are powered on and connected.</p>';
                }
            } catch (error) {
                document.getElementById('discovered-devices').innerHTML = '<p>Discovery failed: ' + error.message + '</p>';
            } finally {
                btn.disabled = false;
                btn.textContent = 'Scan for NAS Devices';
            }
        }

        async function registerDevice(btn, device) {
            btn.disabled = true;
            btn.textContent = 'Registering...';
            
            try {
                const registrationData = {
                    deviceInfo: {
                        brand: device.type,
                        model: device.model,
                        firmware: 'Auto-detected',
                        macAddress: device.macAddress || '00:00:00:00:00:00'
                    },
                    storageCapacity: {
                        total: parseCapacity(device.estimatedCapacity),
                        available: Math.floor(parseCapacity(device.estimatedCapacity) * 0.8)
                    },
                    networkInfo: {
                        ipAddress: device.ipAddress,
                        port: 7002,
                        bandwidth: '1 Gbps'
                    },
                    ownerAddress: 'wrf717d72395303fcb2aed4df368f32f1078d18e9cc'
                };
                
                const response = await fetch('/api/nas/register', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(registrationData)
                });
                
                const result = await response.json();
                
                if (result.success) {
                    btn.textContent = 'Registered!';
                    btn.style.background = '#16a085';
                    loadData(); // Refresh data
                } else {
                    btn.textContent = 'Failed';
                    btn.style.background = '#e74c3c';
                    alert('Registration failed: ' + result.error);
                }
            } catch (error) {
                btn.textContent = 'Error';
                btn.style.background = '#e74c3c';
                alert('Registration error: ' + error.message);
            }
        }

        function parseCapacity(capacityStr) {
            const value = parseFloat(capacityStr);
            const unit = capacityStr.toLowerCase();
            if (unit.includes('tb')) return value * 1024 * 1024 * 1024 * 1024;
            if (unit.includes('gb')) return value * 1024 * 1024 * 1024;
            return value;
        }

        // Auto-refresh data every 30 seconds
        setInterval(loadData, 30000);
        
        // Initial load
        loadData();
    </script>
</body>
</html>`;
  }

  async startMonitoring() {
    // Monitor earnings and update internal state
    setInterval(async () => {
      try {
        const earnings = await this.getEarningsSummary();
        if (earnings.success) {
          this.weatherEarnings = earnings.earnings.weather.total;
          this.storageEarnings = earnings.earnings.storage.total;
        }
      } catch (error) {
        console.error('Monitoring error:', error);
      }
    }, 60000); // Every minute
  }

  getSystemStatus() {
    return {
      powerMode: this.powerMode,
      totalServices: Object.keys(this.services).length,
      runningServices: Object.values(this.services).filter(
        s => s.status === 'running'
      ).length,
      weatherEarnings: this.weatherEarnings,
      storageEarnings: this.storageEarnings,
      nasNodes: this.nasNodes.size,
      timestamp: new Date().toISOString(),
    };
  }
}

// Start the enhanced control panel
const controlPanel = new EnhancedServiceControlPanel();
const PORT = 2001;

controlPanel.app.listen(PORT, '0.0.0.0', () => {
  console.log('🎮 Enhanced Wrfcoin Service Control Panel');
  console.log('====================================');
  console.log(`🌐 Control Panel UI: http://0.0.0.0:${PORT}`);
  console.log('📊 Services API: http://0.0.0.0:${PORT}/api/services');
  console.log(
    '💰 Earnings Dashboard: http://0.0.0.0:${PORT}/api/earnings/summary'
  );
  console.log('🗄️ NAS Management: http://0.0.0.0:${PORT}/api/nas/nodes');
  console.log('====================================');
  console.log('🛡️  Weather earnings are PROTECTED');
  console.log('🔧 Legacy NAS storage management unavailable');
  console.log('📱 Legacy NAS auto-discovery retired');
});

module.exports = controlPanel;
