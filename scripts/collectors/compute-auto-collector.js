/**
 * Compute Auto-Collector
 * One-click computational power contribution to earn WRF tokens
 * "Set it and forget it" system following the proven weather station model
 */

const os = require('os');
const axios = require('axios');
const crypto = require('crypto');
const {
  GracefulShutdown,
  ShutdownPriority,
} = require('../../backend/shared/graceful-shutdown/index.js');

// Configuration
const config = {
  serverUrl: 'http://localhost:6002',
  walletAddress:
    process.env.WALLET_ADDRESS || 'wrf717d72395303fcb2aed4df368f32f1078d18e9cc',
  preferences: {
    maxCPUUsage: 75, // Max CPU usage percentage
    maxRAMUsage: 65, // Max RAM usage percentage
    allowGPU: false, // Enable GPU compute tasks
    onlyWhenIdle: true, // Only run when system is idle
    autoStart: true, // Auto-start recommended tasks
    preferredTasks: [], // Empty = accept all suitable tasks
  },
  checkInterval: 30000, // Check for new tasks every 30 seconds
  maxConcurrentTasks: 1, // Max simultaneous tasks
};

// Global state
let nodeId = null;
let currentTask = null;
let totalEarnings = 0;
let tasksCompleted = 0;
let isRunning = false;

/**
 * Initialize and register the compute node
 */
async function initializeComputeNode() {
  try {
    console.log('🖥️ Initializing Wrfcoin Compute Contributor...');
    console.log('💻 Detecting system capabilities...');

    const capabilities = {
      cpuCount: os.cpus().length,
      cpuModel: os.cpus()[0]?.model || 'Unknown',
      totalRAM: Math.round(os.totalmem() / (1024 * 1024 * 1024)),
      platform: os.platform(),
      architecture: os.arch(),
    };

    console.log(`   📊 ${capabilities.cpuCount} CPU cores`);
    console.log(`   🧠 ${capabilities.totalRAM}GB RAM`);
    console.log(`   💾 ${capabilities.platform} ${capabilities.architecture}`);

    const response = await axios.post(
      `${config.serverUrl}/api/compute/register`,
      {
        walletAddress: config.walletAddress,
        preferences: config.preferences,
      }
    );

    if (response.data.success) {
      nodeId = response.data.nodeId;
      console.log(`✅ Compute node registered: ${nodeId}`);
      console.log(`🏦 Wallet: ${config.walletAddress}`);

      if (response.data.recommendedTasks.length > 0) {
        console.log(
          `🎯 Recommended tasks: ${response.data.recommendedTasks.length}`
        );
        response.data.recommendedTasks.slice(0, 3).forEach(task => {
          console.log(
            `   • ${task.name}: ${task.baseReward} WRF (${task.estimatedTime})`
          );
        });
      }

      if (response.data.estimatedEarnings) {
        console.log(
          `💰 Estimated earnings: ${response.data.estimatedEarnings.daily} WRF/day`
        );
      }

      return true;
    } else {
      console.error('❌ Failed to register compute node:', response.data.error);
      return false;
    }
  } catch (error) {
    console.error('❌ Initialization error:', error.message);
    return false;
  }
}

/**
 * Check system load and determine if ready for new tasks
 */
function isSystemReady() {
  const load = os.loadavg()[0];
  const cpuCount = os.cpus().length;
  const currentCPU = Math.round((load / cpuCount) * 100);

  const totalRAM = os.totalmem();
  const freeRAM = os.freemem();
  const currentRAM = Math.round(((totalRAM - freeRAM) / totalRAM) * 100);

  const cpuOk = currentCPU < config.preferences.maxCPUUsage;
  const ramOk = currentRAM < config.preferences.maxRAMUsage;
  const idleOk = !config.preferences.onlyWhenIdle || currentCPU < 20;

  return {
    ready: cpuOk && ramOk && idleOk,
    currentCPU,
    currentRAM,
    load,
    reasons: {
      cpu: cpuOk ? 'OK' : `High CPU: ${currentCPU}%`,
      ram: ramOk ? 'OK' : `High RAM: ${currentRAM}%`,
      idle: idleOk ? 'OK' : 'System not idle',
    },
  };
}

/**
 * Get available compute tasks
 */
async function getAvailableTasks() {
  try {
    const response = await axios.get(
      `${config.serverUrl}/api/compute/tasks/available/${nodeId}`
    );

    if (response.data.success) {
      return response.data.availableTasks;
    } else {
      console.error('❌ Failed to get available tasks:', response.data.error);
      return [];
    }
  } catch (error) {
    console.error('❌ Task retrieval error:', error.message);
    return [];
  }
}

/**
 * Start a compute task
 */
async function startComputeTask(taskType) {
  try {
    console.log(`🚀 Starting compute task: ${taskType}`);

    const response = await axios.post(
      `${config.serverUrl}/api/compute/tasks/start`,
      {
        nodeId,
        taskType,
      }
    );

    if (response.data.success) {
      currentTask = response.data.task;
      console.log(`✅ Task started: ${currentTask.taskId}`);
      console.log(`💰 Expected reward: ${currentTask.baseReward} WRF`);
      console.log(`⏱️ Estimated time: ${currentTask.estimatedTime}`);

      // Monitor task progress
      monitorTaskProgress(currentTask.taskId);
      return true;
    } else {
      console.error('❌ Failed to start task:', response.data.error);
      return false;
    }
  } catch (error) {
    console.error('❌ Task start error:', error.message);
    return false;
  }
}

/**
 * Monitor task progress and completion
 */
async function monitorTaskProgress(taskId) {
  const progressInterval = setInterval(async () => {
    try {
      const response = await axios.get(
        `${config.serverUrl}/api/compute/tasks/${taskId}/status`
      );

      if (response.data.success) {
        const task = response.data;

        if (task.status === 'completed') {
          clearInterval(progressInterval);
          await handleTaskCompletion(task);
        } else if (task.status === 'running') {
          console.log(
            `🔄 Task progress: ${Math.round(task.progress)}% (CPU: ${Math.round(task.resourceUsage?.cpu || 0)}%)`
          );
        } else if (task.status === 'failed') {
          clearInterval(progressInterval);
          console.error(`❌ Task failed: ${taskId}`);
          currentTask = null;
        }
      }
    } catch (error) {
      console.error('❌ Progress monitoring error:', error.message);
    }
  }, 10000); // Check every 10 seconds
}

/**
 * Handle task completion and rewards
 */
async function handleTaskCompletion(task) {
  try {
    console.log(`✅ Task completed: ${task.taskId}`);
    console.log(`💰 Reward earned: ${task.reward} WRF`);

    totalEarnings += task.reward || 0;
    tasksCompleted++;
    currentTask = null;

    // Update earnings
    await updateEarnings();

    console.log(
      `📈 Total stats: ${tasksCompleted} tasks | ${totalEarnings.toFixed(2)} WRF earned`
    );
  } catch (error) {
    console.error('❌ Task completion error:', error.message);
  }
}

/**
 * Update earnings statistics
 */
async function updateEarnings() {
  try {
    const response = await axios.get(
      `${config.serverUrl}/api/compute/earnings`,
      {
        params: { nodeId },
      }
    );

    if (response.data.success) {
      totalEarnings = response.data.earnings.total;
      tasksCompleted = response.data.statistics.tasksCompleted;
    }
  } catch (error) {
    console.error('❌ Earnings update error:', error.message);
  }
}

/**
 * Send heartbeat to maintain connection
 */
async function sendHeartbeat() {
  try {
    const systemStatus = isSystemReady();

    const response = await axios.post(
      `${config.serverUrl}/api/compute/heartbeat`,
      {
        nodeId,
        status: {
          cpuUsage: systemStatus.currentCPU,
          ramUsage: systemStatus.currentRAM,
          load: systemStatus.load,
        },
      }
    );

    if (
      response.data.success &&
      response.data.availableTasks?.length > 0 &&
      !currentTask
    ) {
      // Auto-start task if system is ready and no current task
      if (systemStatus.ready && config.preferences.autoStart) {
        const bestTask = response.data.availableTasks[0];
        await startComputeTask(bestTask.taskId);
      }
    }
  } catch (error) {
    console.error('❌ Heartbeat error:', error.message);
  }
}

/**
 * Display current statistics
 */
function displayStats() {
  const systemStatus = isSystemReady();

  console.log('\n🖥️ Wrfcoin Compute Contributor Status');
  console.log('=====================================');
  console.log(`📍 Node ID: ${nodeId || 'Not registered'}`);
  console.log(`💰 Total Earnings: ${totalEarnings.toFixed(2)} WRF`);
  console.log(`📊 Tasks Completed: ${tasksCompleted}`);
  console.log(
    `🔄 Current Task: ${currentTask ? currentTask.taskType : 'None'}`
  );
  console.log(`💻 CPU Usage: ${systemStatus.currentCPU}%`);
  console.log(`🧠 RAM Usage: ${systemStatus.currentRAM}%`);
  console.log(`⚡ System Ready: ${systemStatus.ready ? 'Yes' : 'No'}`);
  if (!systemStatus.ready) {
    Object.entries(systemStatus.reasons).forEach(([key, reason]) => {
      if (reason !== 'OK') console.log(`   ⚠️ ${key}: ${reason}`);
    });
  }
  console.log('=====================================\n');
}

/**
 * Main collection loop
 */
async function startAutoCollection() {
  console.log('🎯 Starting Wrfcoin Compute Auto-Collector');
  console.log('⚡ "Set it and forget it" compute contribution');
  console.log('=====================================');

  // Initialize
  const initialized = await initializeComputeNode();
  if (!initialized) {
    console.error('❌ Failed to initialize. Exiting...');
    return;
  }

  isRunning = true;
  console.log('🚀 Auto-collection started!');

  // Setup graceful shutdown
  const shutdown = GracefulShutdown.getInstance();

  // Register cleanup handler
  shutdown.registerHandler({
    name: 'compute-collector-cleanup',
    priority: ShutdownPriority.STOP_BACKGROUND_JOBS,
    timeout: 5000,
    handler: () => {
      console.log('\n🛑 Shutting down compute auto-collector...');
      isRunning = false;

      if (currentTask) {
        console.log('⏸️ Current task will continue running');
      }

      displayStats();
      console.log('✅ Compute auto-collector stopped');
    },
  });

  shutdown.setupSignalHandlers();

  // Main loop
  while (isRunning) {
    try {
      // Send heartbeat
      await sendHeartbeat();

      // Check for new tasks if none running
      if (!currentTask && config.preferences.autoStart) {
        const systemStatus = isSystemReady();

        if (systemStatus.ready) {
          const availableTasks = await getAvailableTasks();

          if (availableTasks.length > 0) {
            // Start the best suitable task
            const bestTask = availableTasks[0];
            await startComputeTask(bestTask.taskId);
          }
        }
      }

      // Display stats every 5 minutes
      if (tasksCompleted % 10 === 0 && tasksCompleted > 0) {
        displayStats();
      }

      // Wait before next check
      await new Promise(resolve => setTimeout(resolve, config.checkInterval));
    } catch (error) {
      console.error('❌ Collection loop error:', error.message);
      await new Promise(resolve => setTimeout(resolve, 60000)); // Wait 1 minute on error
    }
  }
}

// Start the auto-collector
if (require.main === module) {
  startAutoCollection().catch(error => {
    console.error('❌ Failed to start auto-collector:', error.message);
    process.exit(1);
  });
}

module.exports = {
  startAutoCollection,
  initializeComputeNode,
  isSystemReady,
  displayStats,
};
