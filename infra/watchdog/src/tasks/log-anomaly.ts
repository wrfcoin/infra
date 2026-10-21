import { Counter } from 'prom-client';
import type { LLMProvider } from '../llm/provider.js';
import { logAnomalyDetectionPrompt } from '../llm/prompts.js';
import type { DockerLogSource, PrioritizedLogResult } from '../sources/docker.js';
import type { GrafanaOutput } from '../outputs/grafana.js';
import type { WebhookOutput } from '../outputs/webhook.js';
import type { JournalOutput } from '../outputs/journal.js';
import type { HealthServer } from '../health-server.js';

export interface LogAnomalyConfig {
  window_minutes: number;
  containers: string[];
  min_severity: string;
  max_log_lines: number;
  noise_filters: string[];
}

export interface Anomaly {
  severity: 'warning' | 'critical';
  service: string;
  summary: string;
  evidence: string;
}

export interface LogAnomalyDeps {
  llmProvider: LLMProvider;
  dockerSource: DockerLogSource;
  grafana: GrafanaOutput;
  webhook: WebhookOutput;
  journal: JournalOutput;
  healthServer: HealthServer;
  taskConfig: LogAnomalyConfig;
}

const DEFAULT_CONFIG: LogAnomalyConfig = {
  window_minutes: 5,
  containers: ['*'],
  min_severity: 'warning',
  max_log_lines: 500,
  noise_filters: [],
};

export function parseLogAnomalyConfig(
  raw: Record<string, unknown> | undefined,
): LogAnomalyConfig {
  if (!raw) return { ...DEFAULT_CONFIG };
  return {
    window_minutes:
      typeof raw.window_minutes === 'number'
        ? raw.window_minutes
        : DEFAULT_CONFIG.window_minutes,
    containers: Array.isArray(raw.containers)
      ? raw.containers
      : DEFAULT_CONFIG.containers,
    min_severity:
      typeof raw.min_severity === 'string'
        ? raw.min_severity
        : DEFAULT_CONFIG.min_severity,
    max_log_lines:
      typeof raw.max_log_lines === 'number'
        ? raw.max_log_lines
        : DEFAULT_CONFIG.max_log_lines,
    noise_filters: Array.isArray(raw.noise_filters)
      ? raw.noise_filters
      : DEFAULT_CONFIG.noise_filters,
  };
}

export function createLogAnomalyTask(deps: LogAnomalyDeps): () => Promise<void> {
  const {
    llmProvider,
    dockerSource,
    grafana,
    webhook,
    journal,
    healthServer,
    taskConfig,
  } = deps;

  // Register task-specific metrics
  const anomaliesCounter = new Counter({
    name: 'wrfcoin_watchdog_anomalies_detected_total',
    help: 'Total anomalies detected by the log-anomaly task',
    labelNames: ['severity', 'service'] as const,
    registers: [healthServer.registry],
  });

  const llmTokensCounter = new Counter({
    name: 'wrfcoin_watchdog_log_anomaly_llm_tokens_total',
    help: 'LLM tokens used by the log-anomaly task',
    labelNames: ['type'] as const,
    registers: [healthServer.registry],
  });

  return async (): Promise<void> => {
    // Check LLM availability
    const available = await llmProvider.isAvailable();
    if (!available) {
      console.log('[log-anomaly] Skipping — LLM provider unavailable');
      return;
    }

    // Collect logs with budget and noise filtering
    let logResults: PrioritizedLogResult[];
    try {
      logResults = await dockerSource.collectLogsWithBudget({
        windowMinutes: taskConfig.window_minutes,
        maxLogLines: taskConfig.max_log_lines,
        noiseFilters: taskConfig.noise_filters,
        containers: taskConfig.containers,
      });
    } catch (err) {
      console.error(
        `[log-anomaly] Failed to collect Docker logs: ${(err as Error).message}`,
      );
      return;
    }

    if (logResults.length === 0) {
      console.log('[log-anomaly] No container logs collected, skipping');
      return;
    }

    // Build formatted log text for LLM
    const formattedLogs = logResults
      .map(
        (r) =>
          `=== ${r.containerName} (${r.lineCount} lines, ${r.errorLines} errors, ${r.warnLines} warnings) ===\n${r.logs}`,
      )
      .join('\n\n');

    // Build prompt and call LLM
    const messages = logAnomalyDetectionPrompt(
      formattedLogs,
      taskConfig.window_minutes,
    );

    let llmContent: string;
    let llmModel: string | null = null;
    let promptTokens = 0;
    let completionTokens = 0;

    try {
      const result = await llmProvider.chat(messages);
      llmContent = result.content;
      llmModel = result.model;
      promptTokens = result.prompt_tokens;
      completionTokens = result.completion_tokens;

      llmTokensCounter.inc({ type: 'prompt' }, promptTokens);
      llmTokensCounter.inc({ type: 'completion' }, completionTokens);
      healthServer.llmRequestsCounter.inc({ status: 'success' });
    } catch (err) {
      console.error(
        `[log-anomaly] LLM request failed: ${(err as Error).message}`,
      );
      healthServer.llmRequestsCounter.inc({ status: 'error' });
      return;
    }

    // Parse LLM response
    const anomalies = parseLLMResponse(llmContent, taskConfig.min_severity);

    if (anomalies.length === 0) {
      console.log('[log-anomaly] No anomalies detected');
      return;
    }

    console.log(
      `[log-anomaly] Detected ${anomalies.length} anomalie(s)`,
    );

    // Route alerts by severity
    for (const anomaly of anomalies) {
      anomaliesCounter.inc({
        severity: anomaly.severity,
        service: anomaly.service,
      });

      const timestamp = new Date().toISOString();

      // Journal entry for all anomalies
      journal.append({
        timestamp,
        task: 'log-anomaly',
        severity: anomaly.severity,
        llm_model: llmModel,
        prompt_tokens: promptTokens,
        completion_tokens: completionTokens,
        finding: `[${anomaly.service}] ${anomaly.summary}`,
      });

      // Grafana annotation for all anomalies
      const tag =
        anomaly.severity === 'critical'
          ? 'anomaly-critical'
          : 'anomaly';

      try {
        await grafana.annotate({
          text: `[${anomaly.service}] ${anomaly.summary}\n\nEvidence: ${anomaly.evidence}`,
          tags: [tag, 'log-anomaly', anomaly.service],
        });
      } catch (err) {
        console.warn(
          `[log-anomaly] Grafana annotation failed: ${(err as Error).message}`,
        );
      }

      // Webhook for critical only
      if (anomaly.severity === 'critical') {
        try {
          await webhook.send({
            task: 'log-anomaly',
            severity: 'critical',
            timestamp,
            summary: `[${anomaly.service}] ${anomaly.summary}`,
            details: { evidence: anomaly.evidence },
          });
        } catch (err) {
          console.warn(
            `[log-anomaly] Webhook failed: ${(err as Error).message}`,
          );
        }
      }
    }
  };
}

export function parseLLMResponse(
  content: string,
  minSeverity: string,
): Anomaly[] {
  try {
    // Extract JSON from response (handle markdown code blocks)
    let jsonStr = content.trim();
    const jsonMatch = jsonStr.match(/```(?:json)?\s*([\s\S]*?)```/);
    if (jsonMatch) {
      jsonStr = jsonMatch[1].trim();
    }

    const parsed = JSON.parse(jsonStr) as {
      anomalies?: Array<{
        severity?: string;
        service?: string;
        summary?: string;
        evidence?: string;
      }>;
    };

    if (!Array.isArray(parsed.anomalies)) {
      return [];
    }

    const severityOrder: Record<string, number> = {
      info: 0,
      warning: 1,
      critical: 2,
    };
    const minLevel = severityOrder[minSeverity] ?? 1;

    return parsed.anomalies
      .filter((a) => {
        const level = severityOrder[a.severity ?? ''] ?? 0;
        return level >= minLevel;
      })
      .map((a) => ({
        severity: (a.severity === 'critical' ? 'critical' : 'warning') as
          | 'warning'
          | 'critical',
        service: a.service ?? 'unknown',
        summary: a.summary ?? 'No summary provided',
        evidence: a.evidence ?? '',
      }));
  } catch (err) {
    console.error(
      `[log-anomaly] Failed to parse LLM response: ${(err as Error).message}`,
    );
    console.error(`[log-anomaly] Raw response: ${content.slice(0, 500)}`);
    return [];
  }
}
