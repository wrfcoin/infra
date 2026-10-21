import { loadConfig } from './config.js';
import { createProvider, type LLMProvider } from './llm/provider.js';
import { Scheduler } from './scheduler.js';
import { HealthServer } from './health-server.js';
import { DockerLogSource } from './sources/docker.js';
import { GrafanaOutput } from './outputs/grafana.js';
import { WebhookOutput } from './outputs/webhook.js';
import { JournalOutput } from './outputs/journal.js';
import {
  createLogAnomalyTask,
  parseLogAnomalyConfig,
} from './tasks/log-anomaly.js';
import {
  createAlertSummaryTask,
  parseAlertSummaryConfig,
  type AlertSummaryTask,
} from './tasks/alert-summary.js';
import { AlertReceiver } from './alert-receiver.js';
import {
  createSensorQualityTask,
  parseSensorQualityConfig,
} from './tasks/sensor-quality.js';

const HEALTH_PORT = parseInt(process.env.HEALTH_PORT ?? '3334', 10);

async function main(): Promise<void> {
  console.log('[watchdog] Starting WRFCoin Watchdog Service');

  // Load configuration
  const config = loadConfig();

  // Initialize LLM provider (may be unavailable — that's OK)
  const llmProvider = createProvider(config.llm);
  const llmAvailable = await llmProvider.isAvailable();
  if (llmAvailable) {
    console.log(
      `[watchdog] LLM provider available: ${config.llm.primary.endpoint} (${config.llm.primary.model})`,
    );
  } else {
    console.warn(
      '[watchdog] LLM provider unavailable — running in health-check-only mode',
    );
  }

  // Initialize shared dependencies
  const dockerSource = new DockerLogSource(
    config.sources.docker.socket,
    config.sources.docker.container_prefix,
    config.sources.docker.log_window_minutes,
  );
  const grafana = new GrafanaOutput(
    config.outputs.grafana.url,
    config.outputs.grafana.api_key,
  );
  const webhookOutput = new WebhookOutput(config.outputs.webhook.url);
  const journalOutput = new JournalOutput(config.outputs.journal.dir);

  // Initialize scheduler
  const scheduler = new Scheduler();

  // Start health server (needed before task registration for metrics)
  const healthServer = new HealthServer(
    scheduler,
    () => scheduler.triggerOnAlert(),
  );
  await healthServer.start(HEALTH_PORT);

  // Register configured tasks
  let alertSummary: AlertSummaryTask | null = null;
  let alertReceiver: AlertReceiver | null = null;

  for (const [name, taskConfig] of Object.entries(config.tasks)) {
    if (!taskConfig.enabled) {
      console.log(`[watchdog] Task '${name}' is disabled, skipping`);
      continue;
    }

    if (name === 'alert-summary') {
      const summaryConfig = parseAlertSummaryConfig(taskConfig.config);
      alertSummary = createAlertSummaryTask({
        llmProvider,
        grafana,
        webhook: webhookOutput,
        journal: journalOutput,
        healthServer,
        taskConfig: summaryConfig,
      });
      scheduler.registerTask(name, alertSummary.handler, taskConfig.schedule);

      // Start alert receiver on configured port
      alertReceiver = new AlertReceiver(
        (alerts) => alertSummary!.receiveAlerts(alerts),
      );
      await alertReceiver.start(summaryConfig.alert_receiver_port);
      continue;
    }

    const handler = createTaskHandler(name, {
      llmProvider,
      dockerSource,
      grafana,
      webhook: webhookOutput,
      journal: journalOutput,
      healthServer,
      taskConfig,
    });

    scheduler.registerTask(name, handler, taskConfig.schedule);
  }

  // Start cron scheduler
  scheduler.start();

  // Graceful shutdown
  const shutdown = async (signal: string): Promise<void> => {
    console.log(`[watchdog] Received ${signal}, shutting down`);
    alertSummary?.shutdown();
    scheduler.stop();
    await alertReceiver?.stop();
    await healthServer.stop();
    console.log('[watchdog] Shutdown complete');
    process.exit(0);
  };

  process.on('SIGTERM', () => void shutdown('SIGTERM'));
  process.on('SIGINT', () => void shutdown('SIGINT'));

  console.log('[watchdog] Service started successfully');
}

interface TaskDeps {
  llmProvider: LLMProvider;
  dockerSource: DockerLogSource;
  grafana: GrafanaOutput;
  webhook: WebhookOutput;
  journal: JournalOutput;
  healthServer: HealthServer;
  taskConfig: { config?: Record<string, unknown> };
}

function createTaskHandler(
  taskName: string,
  deps: TaskDeps,
): () => Promise<void> {
  switch (taskName) {
    case 'log-anomaly':
      return createLogAnomalyTask({
        llmProvider: deps.llmProvider,
        dockerSource: deps.dockerSource,
        grafana: deps.grafana,
        webhook: deps.webhook,
        journal: deps.journal,
        healthServer: deps.healthServer,
        taskConfig: parseLogAnomalyConfig(deps.taskConfig.config),
      });
    case 'sensor-quality':
      return createSensorQualityTask({
        llmProvider: deps.llmProvider,
        grafana: deps.grafana,
        webhook: deps.webhook,
        journal: deps.journal,
        healthServer: deps.healthServer,
        taskConfig: parseSensorQualityConfig(deps.taskConfig.config),
      });
    default:
      // Placeholder for tasks not yet implemented (#88-#93)
      return async () => {
        const available = await deps.llmProvider.isAvailable();
        if (!available) {
          console.log(`[${taskName}] Skipping — LLM provider unavailable`);
          return;
        }
        console.log(
          `[${taskName}] Placeholder handler — implement in task-specific issue`,
        );
      };
  }
}

main().catch((err) => {
  console.error(`[watchdog] Fatal error: ${(err as Error).message}`);
  process.exit(1);
});
