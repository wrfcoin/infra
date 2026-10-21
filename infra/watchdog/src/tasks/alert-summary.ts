import { Counter, Histogram } from 'prom-client';
import type { LLMProvider } from '../llm/provider.js';
import { alertCorrelationPrompt } from '../llm/prompts.js';
import type { AlertManagerAlert } from '../alert-receiver.js';
import type { GrafanaOutput } from '../outputs/grafana.js';
import type { WebhookOutput } from '../outputs/webhook.js';
import type { JournalOutput } from '../outputs/journal.js';
import type { HealthServer } from '../health-server.js';

export interface AlertSummaryConfig {
  batch_window_seconds: number;
  min_alerts_for_correlation: number;
  include_resolved: boolean;
  alert_receiver_port: number;
}

export interface CorrelationResult {
  root_cause: string;
  cascade: string[];
  investigation: string[];
  severity: 'degraded' | 'partial_outage' | 'full_outage';
  affected_services: string[];
}

export interface AlertSummaryDeps {
  llmProvider: LLMProvider;
  grafana: GrafanaOutput;
  webhook: WebhookOutput;
  journal: JournalOutput;
  healthServer: HealthServer;
  taskConfig: AlertSummaryConfig;
}

export interface AlertSummaryTask {
  handler: () => Promise<void>;
  receiveAlerts: (alerts: AlertManagerAlert[]) => void;
  shutdown: () => void;
}

const DEFAULT_CONFIG: AlertSummaryConfig = {
  batch_window_seconds: 60,
  min_alerts_for_correlation: 2,
  include_resolved: true,
  alert_receiver_port: 8090,
};

export function parseAlertSummaryConfig(
  raw: Record<string, unknown> | undefined,
): AlertSummaryConfig {
  if (!raw) return { ...DEFAULT_CONFIG };
  return {
    batch_window_seconds:
      typeof raw.batch_window_seconds === 'number'
        ? raw.batch_window_seconds
        : DEFAULT_CONFIG.batch_window_seconds,
    min_alerts_for_correlation:
      typeof raw.min_alerts_for_correlation === 'number'
        ? raw.min_alerts_for_correlation
        : DEFAULT_CONFIG.min_alerts_for_correlation,
    include_resolved:
      typeof raw.include_resolved === 'boolean'
        ? raw.include_resolved
        : DEFAULT_CONFIG.include_resolved,
    alert_receiver_port:
      typeof raw.alert_receiver_port === 'number'
        ? raw.alert_receiver_port
        : DEFAULT_CONFIG.alert_receiver_port,
  };
}

export function createAlertSummaryTask(
  deps: AlertSummaryDeps,
): AlertSummaryTask {
  const {
    llmProvider,
    grafana,
    webhook,
    journal,
    healthServer,
    taskConfig,
  } = deps;

  // Metrics
  const batchesCounter = new Counter({
    name: 'wrfcoin_watchdog_alert_correlation_batches_total',
    help: 'Total alert correlation batches processed',
    registers: [healthServer.registry],
  });

  const alertsPerBatchHistogram = new Histogram({
    name: 'wrfcoin_watchdog_alert_correlation_alerts_per_batch',
    help: 'Number of alerts per correlation batch',
    buckets: [1, 2, 5, 10, 20, 50],
    registers: [healthServer.registry],
  });

  const taskDurationHistogram = new Histogram({
    name: 'wrfcoin_watchdog_alert_correlation_task_duration_seconds',
    help: 'Alert correlation task duration in seconds',
    buckets: [0.5, 1, 2, 5, 10, 30],
    registers: [healthServer.registry],
  });

  const resolvedCounter = new Counter({
    name: 'wrfcoin_watchdog_alert_correlation_incidents_resolved_total',
    help: 'Total incidents resolved',
    registers: [healthServer.registry],
  });

  // Batcher state
  const buffer = new Map<string, AlertManagerAlert>();
  let batchTimer: ReturnType<typeof setTimeout> | null = null;
  const activeIncidents = new Map<string, AlertManagerAlert>();

  function receiveAlerts(alerts: AlertManagerAlert[]): void {
    for (const alert of alerts) {
      if (alert.status === 'resolved' && taskConfig.include_resolved) {
        handleResolved(alert);
        continue;
      }

      if (alert.status === 'firing') {
        // Dedup by fingerprint within batch window
        if (!buffer.has(alert.fingerprint)) {
          buffer.set(alert.fingerprint, alert);
        }

        // Track as active incident
        activeIncidents.set(alert.fingerprint, alert);
      }
    }

    // Start batch window on first firing alert
    if (buffer.size > 0 && batchTimer === null) {
      console.log(
        `[alert-summary] Batch window started (${taskConfig.batch_window_seconds}s)`,
      );
      batchTimer = setTimeout(() => {
        void flushBatch();
      }, taskConfig.batch_window_seconds * 1000);
    }
  }

  function handleResolved(alert: AlertManagerAlert): void {
    const incident = activeIncidents.get(alert.fingerprint);
    activeIncidents.delete(alert.fingerprint);

    const startsAt = incident
      ? new Date(incident.startsAt)
      : new Date(alert.startsAt);
    const endsAt = new Date(alert.endsAt);
    const durationMinutes = Math.round(
      (endsAt.getTime() - startsAt.getTime()) / 60_000,
    );

    const alertName =
      alert.labels.alertname ?? alert.fingerprint;
    const service = alert.labels.service ?? 'unknown';

    console.log(
      `[alert-summary] Incident resolved: ${alertName} (duration: ${durationMinutes}m)`,
    );

    resolvedCounter.inc();

    const timestamp = new Date().toISOString();

    journal.append({
      timestamp,
      task: 'alert-summary',
      severity: 'info',
      llm_model: null,
      prompt_tokens: 0,
      completion_tokens: 0,
      finding: `Incident resolved: ${alertName} on ${service}. Duration: ${durationMinutes}m`,
    });

    grafana
      .annotate({
        text: `Incident resolved: ${alertName} on ${service}. Duration: ${durationMinutes}m`,
        tags: ['alert-resolved', service],
      })
      .catch((err) => {
        console.warn(
          `[alert-summary] Grafana annotation failed: ${(err as Error).message}`,
        );
      });
  }

  async function flushBatch(): Promise<void> {
    batchTimer = null;
    const batch = [...buffer.values()];
    buffer.clear();

    if (batch.length === 0) return;

    const start = performance.now();
    batchesCounter.inc();
    alertsPerBatchHistogram.observe(batch.length);

    console.log(
      `[alert-summary] Processing batch of ${batch.length} alert(s)`,
    );

    const available = await llmProvider.isAvailable();
    if (!available) {
      console.warn(
        '[alert-summary] LLM unavailable — logging batch to journal without analysis',
      );
      const timestamp = new Date().toISOString();
      for (const alert of batch) {
        journal.append({
          timestamp,
          task: 'alert-summary',
          severity: alert.labels.severity ?? 'unknown',
          llm_model: null,
          prompt_tokens: 0,
          completion_tokens: 0,
          finding: `[unanalyzed] ${alert.labels.alertname}: ${alert.annotations.summary ?? ''}`,
        });
      }
      return;
    }

    // Build prompt
    const alertsJson = JSON.stringify(
      batch.map((a) => ({
        alertname: a.labels.alertname,
        severity: a.labels.severity,
        service: a.labels.service,
        summary: a.annotations.summary,
        description: a.annotations.description,
        startsAt: a.startsAt,
      })),
      null,
      2,
    );

    const skipCascade = batch.length < taskConfig.min_alerts_for_correlation;
    const messages = alertCorrelationPrompt(alertsJson, batch.length, skipCascade);

    let result: CorrelationResult;
    let llmModel: string | null = null;
    let promptTokens = 0;
    let completionTokens = 0;

    try {
      const llmResult = await llmProvider.chat(messages);
      llmModel = llmResult.model;
      promptTokens = llmResult.prompt_tokens;
      completionTokens = llmResult.completion_tokens;
      healthServer.llmRequestsCounter.inc({ status: 'success' });

      result = parseCorrelationResponse(llmResult.content);
    } catch (err) {
      console.error(
        `[alert-summary] LLM request failed: ${(err as Error).message}`,
      );
      healthServer.llmRequestsCounter.inc({ status: 'error' });
      return;
    }

    const elapsed = (performance.now() - start) / 1000;
    taskDurationHistogram.observe(elapsed);

    await routeCorrelation(
      result,
      batch,
      llmModel,
      promptTokens,
      completionTokens,
    );
  }

  async function routeCorrelation(
    result: CorrelationResult,
    batch: AlertManagerAlert[],
    llmModel: string | null,
    promptTokens: number,
    completionTokens: number,
  ): Promise<void> {
    const timestamp = new Date().toISOString();
    const services = result.affected_services.join(', ');
    const summary = `Root cause: ${result.root_cause}. Affected: ${services}`;

    // Journal — always
    journal.append({
      timestamp,
      task: 'alert-summary',
      severity: result.severity,
      llm_model: llmModel,
      prompt_tokens: promptTokens,
      completion_tokens: completionTokens,
      finding: summary,
    });

    // Grafana annotation — always
    const tagMap: Record<string, string> = {
      degraded: 'alert-degraded',
      partial_outage: 'alert-partial-outage',
      full_outage: 'alert-full-outage',
    };
    const tag = tagMap[result.severity] ?? 'alert-correlation';

    try {
      const text = [
        summary,
        '',
        `Cascade: ${result.cascade.join(' → ')}`,
        `Investigation: ${result.investigation.join('; ')}`,
        `Alerts in batch: ${batch.length}`,
      ].join('\n');

      await grafana.annotate({
        text,
        tags: [tag, 'alert-summary', ...result.affected_services],
      });
    } catch (err) {
      console.warn(
        `[alert-summary] Grafana annotation failed: ${(err as Error).message}`,
      );
    }

    // Webhook — partial_outage and full_outage
    if (
      result.severity === 'partial_outage' ||
      result.severity === 'full_outage'
    ) {
      try {
        await webhook.send({
          task: 'alert-summary',
          severity: result.severity,
          timestamp,
          summary,
          details: {
            root_cause: result.root_cause,
            cascade: result.cascade,
            investigation: result.investigation,
            affected_services: result.affected_services,
            alert_count: batch.length,
          },
        });
      } catch (err) {
        console.warn(
          `[alert-summary] Webhook failed: ${(err as Error).message}`,
        );
      }
    }
  }

  // Manual trigger handler (for scheduler's on-alert)
  async function handler(): Promise<void> {
    if (buffer.size > 0) {
      if (batchTimer !== null) {
        clearTimeout(batchTimer);
      }
      await flushBatch();
    }
  }

  function shutdown(): void {
    if (batchTimer !== null) {
      clearTimeout(batchTimer);
      batchTimer = null;
    }
    buffer.clear();
  }

  return { handler, receiveAlerts, shutdown };
}

export function parseCorrelationResponse(content: string): CorrelationResult {
  try {
    let jsonStr = content.trim();
    const jsonMatch = jsonStr.match(/```(?:json)?\s*([\s\S]*?)```/);
    if (jsonMatch) {
      jsonStr = jsonMatch[1].trim();
    }

    const parsed = JSON.parse(jsonStr) as Partial<CorrelationResult>;

    const validSeverities = ['degraded', 'partial_outage', 'full_outage'];
    const severity = validSeverities.includes(parsed.severity ?? '')
      ? (parsed.severity as CorrelationResult['severity'])
      : 'degraded';

    return {
      root_cause: parsed.root_cause ?? 'Unable to determine root cause',
      cascade: Array.isArray(parsed.cascade) ? parsed.cascade : [],
      investigation: Array.isArray(parsed.investigation)
        ? parsed.investigation
        : [],
      severity,
      affected_services: Array.isArray(parsed.affected_services)
        ? parsed.affected_services
        : [],
    };
  } catch (err) {
    console.error(
      `[alert-summary] Failed to parse LLM response: ${(err as Error).message}`,
    );
    console.error(`[alert-summary] Raw response: ${content.slice(0, 500)}`);
    return {
      root_cause: 'Unable to parse LLM response',
      cascade: [],
      investigation: [],
      severity: 'degraded',
      affected_services: [],
    };
  }
}
