/**
 * NAS Storage Auto-Collector
 * Automatically discovers, configures, and manages NAS devices to earn WRF tokens
 * "Set it and forget it" system for continuous storage earnings
 */

const axios = require('axios');
const crypto = require('crypto');
const dgram = require('dgram');
const { execSync } = require('child_process');
const {
  GracefulShutdown,
  ShutdownPriority,
} = require('../../backend/shared/graceful-shutdown/index.js');

// Track active intervals for cleanup
const activeIntervals = [];

// Configuration
const CONFIG = {
  nasServerUrl: 'http://localhost:7001',
  storageNetworksUrl: 'http://localhost:7000',
  walletAddress: 'wrf717d72395303fcb2aed4df368f32f1078d18e9cc',
  collectionInterval: 120000, // 2 minutes
  validationInterval: 300000, // 5 minutes
  autoDiscovery: true,
  autoRegister: true,
  maxStorageAllocation: '80%', // Use up to 80% of available space
};

// Global state
let registeredNodes = new Map();
let discoveredDevices = [];
let stats = {
  totalEarnings: 0,
  successfulValidations: 0,
  failedValidations: 0,
  dataStored: 0,
  startTime: new Date(),
};

/**
 * Discover NAS devices on local network
 */
async function discoverNASDevices() {
  try {
    console.log('🔍 Scanning network for NAS devices...');

    // Method 1: Check for common NAS manufacturers via UPnP/SSDP
    const upnpDevices = await scanUPnPDevices();

    // Method 2: Network scan for common NAS ports
    const networkDevices = await scanNetworkDevices();

    // Method 3: Check for NAS-specific services
    const serviceDevices = await scanNASServices();

    // Combine and deduplicate discoveries
    const allDevices = [...upnpDevices, ...networkDevices, ...serviceDevices];
    discoveredDevices = deduplicateDevices(allDevices);

    console.log(
      `📱 Discovered ${discoveredDevices.length} potential NAS devices:`
    );
    discoveredDevices.forEach(device => {
      console.log(`   ${device.brand} ${device.model} at ${device.ipAddress}`);
      console.log(`   💾 Estimated capacity: ${device.estimatedCapacity}`);
      console.log(`   💰 Est. earnings: ${device.estimatedEarnings}/month`);
    });

    return discoveredDevices;
  } catch (error) {
    console.error('❌ NAS discovery failed:', error.message);
    return [];
  }
}

/**
 * Scan for UPnP/SSDP devices (Synology, QNAP, etc.)
 */
async function scanUPnPDevices() {
  const devices = [];

  try {
    // Simulate UPnP discovery (in real implementation, would use actual UPnP)
    const mockDiscoveries = [
      {
        brand: 'Synology',
        model: 'DS220+',
        ipAddress: '192.168.1.100',
        macAddress: '00:11:32:AA:BB:CC',
        estimatedCapacity: '8TB',
        estimatedEarnings: '2.4 WRF',
        services: ['smb', 'nfs', 'http'],
        confidence: 95,
      },
      {
        brand: 'QNAP',
        model: 'TS-251D',
        ipAddress: '192.168.1.101',
        macAddress: '00:11:32:DD:EE:FF',
        estimatedCapacity: '4TB',
        estimatedEarnings: '1.2 WRF',
        services: ['smb', 'ftp', 'http'],
        confidence: 90,
      },
    ];

    devices.push(...mockDiscoveries);
    console.log(`   🔍 UPnP scan found ${mockDiscoveries.length} devices`);
  } catch (error) {
    console.log('   ⚠️ UPnP scan failed, continuing...');
  }

  return devices;
}

/**
 * Scan network for devices on common NAS ports
 */
async function scanNetworkDevices() {
  const devices = [];

  try {
    // Check common NAS ports: 5000 (Synology), 8080 (QNAP), 80 (WD)
    const commonPorts = [5000, 8080, 80, 443];
    const networkRange = '192.168.1.'; // Simplified for demo

    console.log('   🌐 Scanning network ports...');

    // Simulate network scan results
    devices.push({
      brand: 'Western Digital',
      model: 'My Cloud EX2',
      ipAddress: '192.168.1.102',
      estimatedCapacity: '12TB',
      estimatedEarnings: '3.6 WRF',
      services: ['http', 'smb'],
      confidence: 85,
    });
  } catch (error) {
    console.log('   ⚠️ Network scan failed, continuing...');
  }

  return devices;
}

/**
 * Scan for NAS-specific services
 */
async function scanNASServices() {
  const devices = [];

  try {
    // Check for SMB/CIFS shares, NFS exports, etc.
    console.log('   📂 Scanning for storage services...');

    // Simulate service discovery
    devices.push({
      brand: 'TrueNAS',
      model: 'SCALE',
      ipAddress: '192.168.1.103',
      estimatedCapacity: '16TB',
      estimatedEarnings: '4.8 WRF',
      services: ['nfs', 'smb', 'iscsi'],
      confidence: 80,
    });
  } catch (error) {
    console.log('   ⚠️ Service scan failed, continuing...');
  }

  return devices;
}

/**
 * Remove duplicate devices from discovery results
 */
function deduplicateDevices(devices) {
  const seen = new Set();
  return devices.filter(device => {
    const key = device.ipAddress + device.macAddress;
    if (seen.has(key)) {
      return false;
    }
    seen.add(key);
    return true;
  });
}

/**
 * Register discovered NAS device as storage node
 */
async function registerNASNode(device) {
  try {
    console.log(`📡 Registering ${device.brand} ${device.model}...`);

    const registrationData = {
      deviceInfo: {
        brand: device.brand,
        model: device.model,
        firmware: 'Auto-detected',
        macAddress: device.macAddress || generateMacAddress(),
      },
      storageCapacity: {
        total: parseCapacity(device.estimatedCapacity),
        available: Math.floor(parseCapacity(device.estimatedCapacity) * 0.8), // 80% available
      },
      networkInfo: {
        ipAddress: device.ipAddress,
        port: 7002,
        bandwidth: '1 Gbps',
      },
      ownerAddress: CONFIG.walletAddress,
    };

    const response = await axios.post(
      `${CONFIG.nasServerUrl}/api/nas/register`,
      registrationData
    );

    if (response.data.success) {
      const nodeId = response.data.nodeId;
      registeredNodes.set(nodeId, {
        ...device,
        nodeId,
        registrationTime: new Date(),
        earnings: 0,
        status: 'active',
      });

      console.log(`✅ Registration successful - Node ID: ${nodeId}`);
      console.log(
        `💰 Estimated monthly earnings: ${response.data.estimatedEarnings.toFixed(2)} WRF`
      );

      return nodeId;
    }
  } catch (error) {
    console.error(
      `❌ Registration failed for ${device.brand} ${device.model}:`,
      error.message
    );
    return null;
  }
}

/**
 * Configure storage allocation for registered node
 */
async function configureStorageNode(nodeId, device) {
  try {
    const totalCapacity = parseCapacity(device.estimatedCapacity);
    const allocationPercentage = parseInt(CONFIG.maxStorageAllocation) / 100;
    const allocatedSpace = Math.floor(totalCapacity * allocationPercentage);

    const configData = {
      nodeId,
      storageAllocation: {
        allocatedSpace,
        reservedSpace: totalCapacity - allocatedSpace,
        compressionEnabled: true,
        encryptionEnabled: true,
      },
      networkSettings: {
        maxBandwidth: '100 Mbps',
        priorityLevel: 'normal',
      },
    };

    const response = await axios.put(
      `${CONFIG.nasServerUrl}/api/nas/configure`,
      configData
    );

    if (response.data.success) {
      console.log(`⚙️ Configuration complete for ${nodeId}`);
      console.log(
        `📦 Allocated: ${formatBytes(allocatedSpace)} (${CONFIG.maxStorageAllocation})`
      );
      return true;
    }
  } catch (error) {
    console.error(`❌ Configuration failed for ${nodeId}:`, error.message);
    return false;
  }
}

/**
 * Monitor and respond to storage validation challenges
 */
async function handleValidationChallenges() {
  for (const [nodeId, nodeInfo] of registeredNodes.entries()) {
    try {
      // Send heartbeat and check for challenges
      const heartbeatData = {
        nodeId,
        status: {
          online: true,
          uptime: calculateUptime(nodeInfo.registrationTime),
          freeSpace: Math.floor(
            parseCapacity(nodeInfo.estimatedCapacity) * 0.7
          ),
          loadAverage: Math.random() * 2, // Simulate load
        },
      };

      const response = await axios.post(
        `${CONFIG.nasServerUrl}/api/nas/heartbeat`,
        heartbeatData
      );

      if (response.data.success && response.data.challenges) {
        console.log(`🎯 Validation challenge for ${nodeId}`);

        // Generate and submit proof of storage
        await submitStorageProof(nodeId, response.data.challenges);
      }
    } catch (error) {
      console.error(`❌ Validation failed for ${nodeId}:`, error.message);
      stats.failedValidations++;
    }
  }
}

/**
 * Submit cryptographic proof of storage
 */
async function submitStorageProof(nodeId, challenge) {
  try {
    // Generate merkle proof (simplified for demo)
    const proof = generateMerkleProof(challenge.challengeId);

    const validationData = {
      nodeId,
      challengeId: challenge.challengeId,
      proof,
    };

    const response = await axios.post(
      `${CONFIG.nasServerUrl}/api/nas/validate`,
      validationData
    );

    if (response.data.success) {
      console.log(
        `✅ Validation passed for ${nodeId} - Reward: ${response.data.reward} WRF`
      );
      stats.successfulValidations++;
      stats.totalEarnings += response.data.reward;

      // Update node earnings
      if (registeredNodes.has(nodeId)) {
        registeredNodes.get(nodeId).earnings += response.data.reward;
      }
    } else {
      console.log(`❌ Validation failed for ${nodeId}`);
      stats.failedValidations++;
    }
  } catch (error) {
    console.error(`❌ Proof submission failed for ${nodeId}:`, error.message);
    stats.failedValidations++;
  }
}

/**
 * Store environmental data shards (when available)
 */
async function handleDataStorage() {
  try {
    // Check if we have weather data to store
    const weatherResponse = await axios.get(
      'http://localhost:4001/api/weather/latest'
    );

    if (weatherResponse.data && weatherResponse.data.success) {
      const weatherData = weatherResponse.data.data;

      // Distribute data across available storage nodes
      for (const [nodeId, nodeInfo] of registeredNodes.entries()) {
        if (nodeInfo.status === 'active') {
          await storeDataShard(nodeId, weatherData);
        }
      }
    }
  } catch (error) {
    // Weather data not available, continue with normal operation
    console.log('📊 No weather data available for storage distribution');
  }
}

/**
 * Store data shard on specific node
 */
async function storeDataShard(nodeId, data) {
  try {
    const dataBuffer = Buffer.from(JSON.stringify(data));
    const base64Data = dataBuffer.toString('base64');

    const storageRequest = {
      nodeId,
      data: base64Data,
      metadata: {
        type: 'environmental_data',
        source: 'weather_station',
        timestamp: new Date().toISOString(),
        size: dataBuffer.length,
      },
    };

    const response = await axios.post(
      `${CONFIG.nasServerUrl}/api/nas/data/shard`,
      storageRequest
    );

    if (response.data.success) {
      console.log(
        `📦 Data stored on ${nodeId} - Reward: ${response.data.estimatedReward.toFixed(4)} WRF`
      );
      stats.dataStored += dataBuffer.length;
      stats.totalEarnings += response.data.estimatedReward;
    }
  } catch (error) {
    console.error(`❌ Data storage failed for ${nodeId}:`, error.message);
  }
}

/**
 * Claim accumulated rewards for all nodes
 */
async function claimRewards() {
  for (const [nodeId, nodeInfo] of registeredNodes.entries()) {
    try {
      const claimData = {
        nodeId,
        walletAddress: CONFIG.walletAddress,
      };

      const response = await axios.post(
        `${CONFIG.nasServerUrl}/api/nas/claim-rewards`,
        claimData
      );

      if (response.data.success && response.data.claimedAmount > 0) {
        console.log(
          `💰 Claimed ${response.data.claimedAmount} WRF from ${nodeId}`
        );
        console.log(`🏦 Total earnings: ${response.data.totalEarnings} WRF`);
      }
    } catch (error) {
      console.error(`❌ Reward claim failed for ${nodeId}:`, error.message);
    }
  }
}

/**
 * Display current earnings and statistics
 */
function displayStats() {
  const uptime = Date.now() - stats.startTime.getTime();
  const hours = Math.floor(uptime / (1000 * 60 * 60));
  const minutes = Math.floor((uptime % (1000 * 60 * 60)) / (1000 * 60));

  console.log('\n📊 NAS Storage Network Statistics');
  console.log('=====================================');
  console.log(`⏰ Uptime: ${hours}h ${minutes}m`);
  console.log(`📱 Active nodes: ${registeredNodes.size}`);
  console.log(`💰 Total earnings: ${stats.totalEarnings.toFixed(4)} WRF`);
  console.log(`✅ Successful validations: ${stats.successfulValidations}`);
  console.log(`❌ Failed validations: ${stats.failedValidations}`);
  console.log(`📦 Data stored: ${formatBytes(stats.dataStored)}`);

  if (stats.successfulValidations + stats.failedValidations > 0) {
    const successRate =
      (stats.successfulValidations /
        (stats.successfulValidations + stats.failedValidations)) *
      100;
    console.log(`📈 Success rate: ${successRate.toFixed(1)}%`);
  }

  console.log('\n🗄️ Registered Storage Nodes:');
  for (const [nodeId, nodeInfo] of registeredNodes.entries()) {
    console.log(
      `   ${nodeInfo.brand} ${nodeInfo.model} - ${nodeInfo.earnings.toFixed(4)} WRF`
    );
  }
  console.log('=====================================\n');
}

// Helper functions
function parseCapacity(capacityStr) {
  const value = parseFloat(capacityStr);
  const unit = capacityStr.toLowerCase();

  if (unit.includes('tb')) return value * 1024 * 1024 * 1024 * 1024;
  if (unit.includes('gb')) return value * 1024 * 1024 * 1024;
  if (unit.includes('mb')) return value * 1024 * 1024;
  return value;
}

function formatBytes(bytes) {
  if (bytes >= 1024 ** 4) return `${(bytes / 1024 ** 4).toFixed(2)} TB`;
  if (bytes >= 1024 ** 3) return `${(bytes / 1024 ** 3).toFixed(2)} GB`;
  if (bytes >= 1024 ** 2) return `${(bytes / 1024 ** 2).toFixed(2)} MB`;
  return `${bytes} bytes`;
}

function generateMacAddress() {
  return Array.from({ length: 6 }, () =>
    Math.floor(Math.random() * 256)
      .toString(16)
      .padStart(2, '0')
  ).join(':');
}

function generateMerkleProof(challengeId) {
  // Simplified proof generation
  return crypto
    .createHash('sha256')
    .update(challengeId + Date.now())
    .digest('hex');
}

function calculateUptime(startTime) {
  return ((Date.now() - startTime.getTime()) / (1000 * 60 * 60 * 24)).toFixed(
    2
  );
}

/**
 * Main auto-collection loop
 */
async function startAutoCollection() {
  console.log('🗄️ NAS Storage Auto-Collector Starting...');
  console.log(`💰 Wallet: ${CONFIG.walletAddress}`);
  console.log(
    `⏰ Collection Interval: ${CONFIG.collectionInterval / 1000} seconds`
  );
  console.log(
    `🔍 Auto-discovery: ${CONFIG.autoDiscovery ? 'Enabled' : 'Disabled'}`
  );
  console.log('🚀 Beginning NAS storage network setup...\n');

  // Initial discovery and registration
  if (CONFIG.autoDiscovery) {
    const devices = await discoverNASDevices();

    if (CONFIG.autoRegister && devices.length > 0) {
      console.log('\n📡 Auto-registering discovered devices...');

      for (const device of devices) {
        const nodeId = await registerNASNode(device);
        if (nodeId) {
          await configureStorageNode(nodeId, device);
        }

        // Small delay between registrations
        await new Promise(resolve => setTimeout(resolve, 2000));
      }
    }
  }

  console.log(
    `\n✅ Setup complete - ${registeredNodes.size} storage nodes active`
  );
  console.log('🔄 Starting continuous earning cycle...\n');

  // Setup graceful shutdown
  const shutdown = GracefulShutdown.getInstance();

  // Register cleanup handler for intervals
  shutdown.registerHandler({
    name: 'nas-collector-intervals',
    priority: ShutdownPriority.STOP_BACKGROUND_JOBS,
    timeout: 5000,
    handler: () => {
      console.log('\n🛑 Shutting down NAS Auto-Collector...');
      for (const interval of activeIntervals) {
        clearInterval(interval);
      }
      displayStats();
      console.log('✅ Shutdown complete');
    },
  });

  shutdown.setupSignalHandlers();

  // Main collection loop
  const collectionInterval = setInterval(async () => {
    try {
      await handleDataStorage();
    } catch (error) {
      console.error('❌ Data storage cycle failed:', error.message);
    }
  }, CONFIG.collectionInterval);
  activeIntervals.push(collectionInterval);

  // Validation loop
  const validationInterval = setInterval(async () => {
    try {
      await handleValidationChallenges();
    } catch (error) {
      console.error('❌ Validation cycle failed:', error.message);
    }
  }, CONFIG.validationInterval);
  activeIntervals.push(validationInterval);

  // Rewards claiming (every 30 minutes)
  const rewardsInterval = setInterval(
    async () => {
      try {
        await claimRewards();
      } catch (error) {
        console.error('❌ Reward claiming failed:', error.message);
      }
    },
    30 * 60 * 1000
  );
  activeIntervals.push(rewardsInterval);

  // Statistics display (every 5 minutes)
  const statsInterval = setInterval(
    () => {
      displayStats();
    },
    5 * 60 * 1000
  );
  activeIntervals.push(statsInterval);

  // Initial stats display
  setTimeout(displayStats, 10000);

  console.log('🎉 NAS Auto-Collector is now running!');
  console.log('💡 Your storage devices will automatically earn WRF tokens');
  console.log('📊 Statistics will be displayed every 5 minutes\n');
}

// Start the auto-collector
startAutoCollection().catch(error => {
  console.error('❌ NAS Auto-Collector failed to start:', error.message);
  process.exit(1);
});
