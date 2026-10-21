import {
  HttpTaskClient,
  type ForecastTask,
  type StartedTask,
  type TaskStatusResult,
} from './task-client.js';
import { HealthReporter } from './health.js';

const config = {
  taskApiUrl: process.env.TASK_API_URL || 'http://127.0.0.1:6003',
  walletAddress: process.env.WALLET_ADDRESS || '',
  pollIntervalMs: parseInt(process.env.POLL_INTERVAL_MS || '10000', 10),
  heartbeatIntervalMs: parseInt(
    process.env.HEARTBEAT_INTERVAL_MS || '30000',
    10,
  ),
  healthPort: parseInt(process.env.HEALTH_PORT || '3333', 10),
  registrationPreferences: {
    maxCPUUsage: 80,
    maxRAMUsage: 70,
    allowGPU: false,
    preferredTasks: [] as string[],
    autoStart: true,
    onlyWhenIdle: true,
  },
};

const taskClient = new HttpTaskClient(
  config.taskApiUrl,
  process.env.WRFCOIN_OPERATOR_TOKEN,
);

let running = true;
let registeredNodeId: string | null = null;
let health: HealthReporter | null = null;
let currentTask: StartedTask | null = null;
let currentTaskStartedAtMs: number | null = null;
let heartbeatTimer: ReturnType<typeof setInterval> | null = null;

async function main(): Promise<void> {
  console.log('[agent] WRFCoin Compute Agent starting');
  console.log(`[agent] Task API: ${config.taskApiUrl}`);
  console.log(`[agent] Poll interval: ${config.pollIntervalMs}ms`);
  console.log(`[agent] Heartbeat interval: ${config.heartbeatIntervalMs}ms`);

  if (!config.walletAddress) {
    console.error('[agent] Fatal: WALLET_ADDRESS is required');
    process.exit(1);
  }

  const registration = await taskClient.register(
    config.walletAddress,
    config.registrationPreferences,
  );
  if (!registration) {
    console.error('[agent] Fatal: failed to register compute node');
    process.exit(1);
  }

  registeredNodeId = registration.nodeId;
  health = new HealthReporter(registeredNodeId);
  await health.startHealthServer(config.healthPort);

  console.log(`[agent] Registered node ID: ${registeredNodeId}`);
  console.log(
    `[agent] Recommended tasks: ${registration.recommendedTasks.map((task) => task.taskId).join(', ') || 'none'}`,
  );

  await sendHeartbeat();
  startHeartbeatLoop();

  while (running) {
    try {
      await pollAndExecute();
    } catch (err) {
      console.error(`[agent] Poll loop error: ${(err as Error).message}`);
      health?.setError();
    }

    if (running) {
      await sleep(config.pollIntervalMs);
    }
  }

  console.log('[agent] Main loop exited');
}

function startHeartbeatLoop(): void {
  heartbeatTimer = setInterval(() => {
    void sendHeartbeat();
  }, config.heartbeatIntervalMs);
}

async function sendHeartbeat(): Promise<void> {
  if (!registeredNodeId || !health) {
    return;
  }

  const heartbeat = await taskClient.heartbeat(
    registeredNodeId,
    health.getStatus(),
  );

  if (!heartbeat?.success) {
    console.warn('[agent] Heartbeat request failed');
    health.recordHeartbeat(false);
    return;
  }

  health.recordHeartbeat(true);

  if (!currentTask && heartbeat.availableTasks.length > 0) {
    console.log(
      `[agent] Heartbeat recommendations: ${heartbeat.availableTasks.map((task) => task.taskId).join(', ')}`,
    );
  }
}

async function pollAndExecute(): Promise<void> {
  if (!registeredNodeId || currentTask) {
    return;
  }

  const tasks = await taskClient.pollAvailableTasks(registeredNodeId);
  if (tasks.length === 0) {
    return;
  }

  const selectedTask = selectTask(tasks);
  console.log(
    `[agent] Starting task candidate ${selectedTask.taskId} (${selectedTask.name})`,
  );

  const started = await taskClient.startTask(registeredNodeId, selectedTask.taskId);
  if (!started?.success) {
    console.warn(`[agent] Failed to start task type ${selectedTask.taskId}`);
    return;
  }

  currentTask = started.task;
  currentTaskStartedAtMs = Date.now();
  health?.setRunning(started.taskId);
  health?.setTaskProgress(0);

  console.log(
    `[agent] Task started: ${started.taskId} (${started.task.taskType})`,
  );

  await monitorTask(started.taskId);
}

export function selectTask(tasks: ForecastTask[]): ForecastTask {
  return [...tasks].sort((left, right) => right.suitability - left.suitability)[0];
}

async function monitorTask(taskId: string): Promise<void> {
  while (running && currentTask?.taskId === taskId) {
    const status = await taskClient.getTaskStatus(taskId);
    if (!status?.success) {
      console.warn(`[agent] Status polling failed for task ${taskId}`);
      await sleep(config.pollIntervalMs);
      continue;
    }

    logTaskStatus(status);
    health?.setTaskProgress(status.progress);

    if (status.status === 'completed') {
      health?.recordCompleted(calculateTaskDurationSeconds());
      health?.setIdle();
      currentTask = null;
      currentTaskStartedAtMs = null;
      return;
    }

    if (isTerminalFailure(status.status)) {
      health?.recordFailed(calculateTaskDurationSeconds());
      health?.setIdle();
      currentTask = null;
      currentTaskStartedAtMs = null;
      return;
    }

    await sleep(config.pollIntervalMs);
  }
}

function logTaskStatus(status: TaskStatusResult): void {
  if (status.status === 'running') {
    console.log(
      `[agent] Task ${status.taskId} running: ${Math.round(status.progress)}%`,
    );
    return;
  }

  if (status.status === 'completed') {
    console.log(
      `[agent] Task ${status.taskId} completed with reward ${status.reward ?? 0}`,
    );
    return;
  }

  console.warn(`[agent] Task ${status.taskId} ended with status ${status.status}`);
}

function isTerminalFailure(status: string): boolean {
  return status === 'failed' || status === 'cancelled' || status === 'abandoned';
}

async function shutdown(signal: string): Promise<void> {
  console.log(`[agent] Received ${signal}, shutting down gracefully...`);
  running = false;

  if (heartbeatTimer) {
    clearInterval(heartbeatTimer);
    heartbeatTimer = null;
  }

  if (currentTask) {
    console.log(
      `[agent] Leaving task ${currentTask.taskId} to backend-managed execution`,
    );
  }

  await health?.stopHealthServer();
  console.log('[agent] Shutdown complete');
  process.exit(0);
}

process.on('SIGTERM', () => {
  void shutdown('SIGTERM');
});
process.on('SIGINT', () => {
  void shutdown('SIGINT');
});

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function calculateTaskDurationSeconds(): number {
  if (!currentTaskStartedAtMs) {
    return 0;
  }

  return (Date.now() - currentTaskStartedAtMs) / 1000;
}

main().catch((err) => {
  console.error(`[agent] Fatal error: ${(err as Error).message}`);
  process.exit(1);
});
