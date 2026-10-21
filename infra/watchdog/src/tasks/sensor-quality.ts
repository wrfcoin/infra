/**
 * Sensor Quality Task
 *
 * LLM-based detection of stuck sensors, drift, synthetic data, and context
 * anomalies in weather station submissions. Runs every 15 minutes as an
 * advisory layer on top of core4's hard physics bounds.
 *
 * ADVISORY ONLY — flags for human review, never auto-slashes.
 *
 * infra#88: Watchdog IoT Sensor Data Quality Screening
 */

import { Counter } from 'prom-client';
import type { LLMProvider } from '../llm/provider.js';
import { sensorQualityPrompt } from '../llm/prompts.js';
import {
  SensorDataSource,
  type SensorDataConfig,
  type StationReadings,
} from '../sources/sensor-data.js';
import type { GrafanaOutput } from '../outputs/grafana.js';
import type { WebhookOutput } from '../outputs/webhook.js';
import type { JournalOutput } from '../outputs/journal.js';
import type { HealthServer } from '../health-server.js';

// ============================================================================
// Types
// ============================================================================

export interface SensorQualityConfig {
  window_minutes: number;
  min_readings_per_station: number;
  max_stations_per_batch: number;
  backend_api_url: string;
}

export interface SensorQualityIssue {
  station_id: string;
  issue_type: 'stuck' | 'drift' | 'synthetic' | 'context_anomaly' | 'outlier';
  field: string;
  severity: 'info' | 'warning' | 'critical';
  evidence: string;
  recommendation: string;
}

export interface SensorQualityDeps {
  llmProvider: LLMProvider;
  grafana: GrafanaOutput;
  webhook: WebhookOutput;
  journal: JournalOutput;
  healthServer: HealthServer;
  taskConfig: SensorQualityConfig;
  /** Optional override for testing — if not provided, creates from config */
  sensorDataSource?: SensorDataSource;
}

// ============================================================================
// Config parsing
// ============================================================================

const DEFAULT_CONFIG: SensorQualityConfig = {
  window_minutes: 15,
  min_readings_per_station: 3,
  max_stations_per_batch: 50,
  backend_api_url: 'http://localhost:3001',
};

export function parseSensorQualityConfig(
  raw: Record<string, unknown> | undefined,
): SensorQualityConfig {
  if (!raw) return { ...DEFAULT_CONFIG };
  return {
    window_minutes:
      typeof raw.window_minutes === 'number'
        ? raw.window_minutes
        : DEFAULT_CONFIG.window_minutes,
    min_readings_per_station:
      typeof raw.min_readings_per_station === 'number'
        ? raw.min_readings_per_station
        : DEFAULT_CONFIG.min_readings_per_station,
    max_stations_per_batch:
      typeof raw.max_stations_per_batch === 'number'
        ? raw.max_stations_per_batch
        : DEFAULT_CONFIG.max_stations_per_batch,
    backend_api_url:
      typeof raw.backend_api_url === 'string'
        ? raw.backend_api_url
        : DEFAULT_CONFIG.backend_api_url,
  };
}

// ============================================================================
// LLM response parsing
// ============================================================================

export function parseSensorQualityResponse(
  content: string,
): SensorQualityIssue[] {
  try {
    let jsonStr = content.trim();
    const jsonMatch = jsonStr.match(/```(?:json)?\s*([\s\S]*?)```/);
    if (jsonMatch) {
      jsonStr = jsonMatch[1].trim();
    }

    const parsed = JSON.parse(jsonStr) as {
      issues?: Array<{
        station_id?: string;
        issue_type?: string;
        field?: string;
        severity?: string;
        evidence?: string;
        recommendation?: string;
      }>;
    };

    if (!Array.isArray(parsed.issues)) return [];

    const validTypes = new Set([
      'stuck',
      'drift',
      'synthetic',
      'context_anomaly',
      'outlier',
    ]);
    const validSeverities = new Set(['info', 'warning', 'critical']);

    return parsed.issues
      .filter(
        (i) =>
          i.station_id &&
          i.issue_type &&
          validTypes.has(i.issue_type) &&
          validSeverities.has(i.severity ?? ''),
      )
      .map((i) => ({
        station_id: i.station_id!,
        issue_type: i.issue_type as SensorQualityIssue['issue_type'],
        field: i.field ?? 'unknown',
        severity: i.severity as SensorQualityIssue['severity'],
        evidence: i.evidence ?? '',
        recommendation: i.recommendation ?? 'Flag for manual review',
      }));
  } catch (err) {
    console.error(
      `[sensor-quality] Failed to parse LLM response: ${(err as Error).message}`,
    );
    console.error(
      `[sensor-quality] Raw response: ${content.slice(0, 500)}`,
    );
    return [];
  }
}

// ============================================================================
// Task factory
// ============================================================================

export function createSensorQualityTask(
  deps: SensorQualityDeps,
): () => Promise<void> {
  const {
    llmProvider,
    grafana,
    webhook,
    journal,
    healthServer,
    taskConfig,
  } = deps;

  // Create sensor data source (or use injected one for tests)
  const sensorSource =
    deps.sensorDataSource ??
    new SensorDataSource({
      backend_api_url: taskConfig.backend_api_url,
      window_minutes: taskConfig.window_minutes,
      max_stations_per_batch: taskConfig.max_stations_per_batch,
    });

  // Register task-specific metrics
  const issuesCounter = new Counter({
    name: 'wrfcoin_watchdog_sensor_quality_issues_total',
    help: 'Total data quality issues detected by the sensor-quality task',
    labelNames: ['issue_type', 'severity'] as const,
    registers: [healthServer.registry],
  });

  const stationsScreenedCounter = new Counter({
    name: 'wrfcoin_watchdog_sensor_quality_stations_screened',
    help: 'Total stations screened by the sensor-quality task',
    registers: [healthServer.registry],
  });

  const llmTokensCounter = new Counter({
    name: 'wrfcoin_watchdog_sensor_quality_llm_tokens_total',
    help: 'LLM tokens used by the sensor-quality task',
    labelNames: ['type'] as const,
    registers: [healthServer.registry],
  });

  return async (): Promise<void> => {
    // 1. Check LLM availability
    const available = await llmProvider.isAvailable();
    if (!available) {
      console.log('[sensor-quality] Skipping — LLM provider unavailable');
      return;
    }

    // 2. Fetch recent readings from backend
    let stations: StationReadings[];
    try {
      stations = await sensorSource.fetchRecentReadings();
    } catch (err) {
      console.error(
        `[sensor-quality] Failed to fetch sensor data: ${(err as Error).message}`,
      );
      return;
    }

    if (stations.length === 0) {
      console.log('[sensor-quality] No station readings collected, skipping');
      return;
    }

    // 3. Filter: need min_readings_per_station for pattern detection
    const eligible = stations.filter(
      (s) => s.readings.length >= taskConfig.min_readings_per_station,
    );

    if (eligible.length === 0) {
      console.log(
        `[sensor-quality] No stations with >= ${taskConfig.min_readings_per_station} readings, skipping`,
      );
      return;
    }

    stationsScreenedCounter.inc(eligible.length);

    // 4. Build prompt
    const readingsJson = JSON.stringify(
      eligible.map((s) => ({
        station_id: s.stationId,
        latitude: s.latitude,
        longitude: s.longitude,
        readings: s.readings,
      })),
      null,
      2,
    );

    const messages = sensorQualityPrompt(
      readingsJson,
      taskConfig.window_minutes,
    );

    // 5. Call LLM
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
        `[sensor-quality] LLM request failed: ${(err as Error).message}`,
      );
      healthServer.llmRequestsCounter.inc({ status: 'error' });
      return;
    }

    // 6. Parse response
    const issues = parseSensorQualityResponse(llmContent);

    if (issues.length === 0) {
      console.log(
        `[sensor-quality] No issues detected across ${eligible.length} stations`,
      );
      return;
    }

    console.log(
      `[sensor-quality] Detected ${issues.length} issue(s) across ${eligible.length} stations`,
    );

    // 7. Route alerts by severity
    for (const issue of issues) {
      issuesCounter.inc({
        issue_type: issue.issue_type,
        severity: issue.severity,
      });

      const timestamp = new Date().toISOString();
      const finding = `[${issue.station_id}] ${issue.issue_type}: ${issue.evidence}`;

      // Journal entry for ALL severities (info, warning, critical)
      journal.append({
        timestamp,
        task: 'sensor-quality',
        severity: issue.severity,
        llm_model: llmModel,
        prompt_tokens: promptTokens,
        completion_tokens: completionTokens,
        finding,
      });

      // Grafana annotation for warning + critical
      if (issue.severity === 'warning' || issue.severity === 'critical') {
        const tag =
          issue.severity === 'critical'
            ? 'sensor-quality-critical'
            : 'sensor-quality';

        try {
          await grafana.annotate({
            text: `[${issue.station_id}] ${issue.issue_type} (${issue.field})\n\n${issue.evidence}\n\nRecommendation: ${issue.recommendation}`,
            tags: [tag, 'sensor-quality', issue.station_id],
          });
        } catch (err) {
          console.warn(
            `[sensor-quality] Grafana annotation failed: ${(err as Error).message}`,
          );
        }
      }

      // Webhook for critical only
      if (issue.severity === 'critical') {
        try {
          await webhook.send({
            task: 'sensor-quality',
            severity: 'critical',
            timestamp,
            summary: finding,
            details: {
              station_id: issue.station_id,
              issue_type: issue.issue_type,
              field: issue.field,
              evidence: issue.evidence,
              recommendation: issue.recommendation,
            },
          });
        } catch (err) {
          console.warn(
            `[sensor-quality] Webhook failed: ${(err as Error).message}`,
          );
        }
      }
    }
  };
}
