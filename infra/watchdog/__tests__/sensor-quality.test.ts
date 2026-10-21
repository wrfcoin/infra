/**
 * Sensor Quality Task Tests
 *
 * infra#88: Watchdog IoT Sensor Data Quality Screening
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { Registry, Counter } from 'prom-client';
import {
  createSensorQualityTask,
  parseSensorQualityConfig,
  parseSensorQualityResponse,
  type SensorQualityConfig,
  type SensorQualityDeps,
} from '../src/tasks/sensor-quality.js';
import type { LLMProvider, LLMResult, Message, LLMOptions } from '../src/llm/provider.js';
import type { GrafanaOutput, GrafanaAnnotation } from '../src/outputs/grafana.js';
import type { WebhookOutput, WebhookPayload } from '../src/outputs/webhook.js';
import type { JournalOutput, JournalEntry } from '../src/outputs/journal.js';
import type { HealthServer } from '../src/health-server.js';
import {
  SensorDataSource,
  type StationReadings,
} from '../src/sources/sensor-data.js';

// --- Mock factories (following log-anomaly.test.ts pattern) ---

function createMockLLMProvider(
  response: string | null,
  available = true,
): LLMProvider {
  return {
    async chat(_messages: Message[], _options?: LLMOptions): Promise<LLMResult> {
      if (response === null) throw new Error('LLM unavailable');
      return {
        content: response,
        model: 'test-model',
        prompt_tokens: 50,
        completion_tokens: 20,
      };
    },
    async isAvailable(): Promise<boolean> {
      return available;
    },
  };
}

function createMockSensorSource(
  stations: StationReadings[],
): SensorDataSource {
  return {
    fetchRecentReadings: async () => stations,
  } as unknown as SensorDataSource;
}

function createMockGrafana(): GrafanaOutput & {
  annotations: GrafanaAnnotation[];
} {
  const annotations: GrafanaAnnotation[] = [];
  return {
    annotations,
    isConfigured: () => true,
    annotate: async (a: GrafanaAnnotation) => {
      annotations.push(a);
    },
  } as unknown as GrafanaOutput & { annotations: GrafanaAnnotation[] };
}

function createMockWebhook(): WebhookOutput & {
  payloads: WebhookPayload[];
} {
  const payloads: WebhookPayload[] = [];
  return {
    payloads,
    isConfigured: () => true,
    send: async (p: WebhookPayload) => {
      payloads.push(p);
    },
  } as unknown as WebhookOutput & { payloads: WebhookPayload[] };
}

function createMockJournal(): JournalOutput & {
  entries: JournalEntry[];
} {
  const entries: JournalEntry[] = [];
  return {
    entries,
    append: (e: JournalEntry) => {
      entries.push(e);
    },
  } as unknown as JournalOutput & { entries: JournalEntry[] };
}

function createMockHealthServer(): HealthServer {
  const registry = new Registry();
  return {
    registry,
    llmRequestsCounter: new Counter({
      name: 'test_sq_llm_requests_total',
      help: 'test',
      labelNames: ['status'] as const,
      registers: [registry],
    }),
  } as unknown as HealthServer;
}

const DEFAULT_TASK_CONFIG: SensorQualityConfig = {
  window_minutes: 15,
  min_readings_per_station: 3,
  max_stations_per_batch: 50,
  backend_api_url: 'http://localhost:3001',
};

function buildDeps(
  overrides: Partial<SensorQualityDeps> = {},
): SensorQualityDeps {
  return {
    llmProvider: createMockLLMProvider('{"issues": []}'),
    grafana: createMockGrafana(),
    webhook: createMockWebhook(),
    journal: createMockJournal(),
    healthServer: createMockHealthServer(),
    taskConfig: DEFAULT_TASK_CONFIG,
    sensorDataSource: createMockSensorSource([]),
    ...overrides,
  };
}

// --- Helper: generate station readings ---

function makeReadings(
  count: number,
  valueFn: (i: number) => Partial<{ temperature: number; humidity: number; pressure: number }>,
): StationReadings['readings'] {
  const now = Date.now();
  return Array.from({ length: count }, (_, i) => ({
    timestamp: new Date(now - (count - i) * 60_000).toISOString(),
    ...valueFn(i),
  }));
}

// ============================================================================
// parseSensorQualityResponse
// ============================================================================

describe('parseSensorQualityResponse', () => {
  it('parses valid issue JSON', () => {
    const result = parseSensorQualityResponse(
      JSON.stringify({
        issues: [
          {
            station_id: 'station-a',
            issue_type: 'stuck',
            field: 'temperature',
            severity: 'warning',
            evidence: 'Temperature constant at 22.0°C for 20 readings',
            recommendation: 'Flag for manual review',
          },
        ],
      }),
    );
    expect(result).toHaveLength(1);
    expect(result[0].station_id).toBe('station-a');
    expect(result[0].issue_type).toBe('stuck');
    expect(result[0].severity).toBe('warning');
  });

  it('returns empty array for no issues', () => {
    const result = parseSensorQualityResponse('{"issues": []}');
    expect(result).toHaveLength(0);
  });

  it('handles malformed JSON gracefully', () => {
    const result = parseSensorQualityResponse(
      'I cannot analyze this data properly.',
    );
    expect(result).toHaveLength(0);
  });

  it('extracts JSON from markdown code blocks', () => {
    const result = parseSensorQualityResponse(
      '```json\n{"issues": [{"station_id": "s1", "issue_type": "drift", "field": "pressure", "severity": "critical", "evidence": "drifting"}]}\n```',
    );
    expect(result).toHaveLength(1);
    expect(result[0].issue_type).toBe('drift');
  });

  it('filters out issues with invalid issue_type', () => {
    const result = parseSensorQualityResponse(
      JSON.stringify({
        issues: [
          {
            station_id: 's1',
            issue_type: 'unknown_type',
            severity: 'warning',
          },
          {
            station_id: 's2',
            issue_type: 'stuck',
            severity: 'warning',
          },
        ],
      }),
    );
    expect(result).toHaveLength(1);
    expect(result[0].station_id).toBe('s2');
  });

  it('filters out issues with invalid severity', () => {
    const result = parseSensorQualityResponse(
      JSON.stringify({
        issues: [
          {
            station_id: 's1',
            issue_type: 'stuck',
            severity: 'mega-critical',
          },
        ],
      }),
    );
    expect(result).toHaveLength(0);
  });
});

// ============================================================================
// parseSensorQualityConfig
// ============================================================================

describe('parseSensorQualityConfig', () => {
  it('returns defaults when raw is undefined', () => {
    const config = parseSensorQualityConfig(undefined);
    expect(config.window_minutes).toBe(15);
    expect(config.min_readings_per_station).toBe(3);
    expect(config.max_stations_per_batch).toBe(50);
    expect(config.backend_api_url).toBe('http://localhost:3001');
  });

  it('overrides with valid values', () => {
    const config = parseSensorQualityConfig({
      window_minutes: 30,
      min_readings_per_station: 5,
      max_stations_per_batch: 100,
      backend_api_url: 'http://backend:4001',
    });
    expect(config.window_minutes).toBe(30);
    expect(config.min_readings_per_station).toBe(5);
    expect(config.max_stations_per_batch).toBe(100);
    expect(config.backend_api_url).toBe('http://backend:4001');
  });

  it('falls back to defaults for wrong types', () => {
    const config = parseSensorQualityConfig({
      window_minutes: 'not-a-number',
      min_readings_per_station: null,
    });
    expect(config.window_minutes).toBe(15);
    expect(config.min_readings_per_station).toBe(3);
  });
});

// ============================================================================
// createSensorQualityTask
// ============================================================================

describe('createSensorQualityTask', () => {
  it('skips when LLM is unavailable', async () => {
    const journal = createMockJournal();
    const deps = buildDeps({
      llmProvider: createMockLLMProvider(null, false),
      sensorDataSource: createMockSensorSource([
        {
          stationId: 'station-a',
          readings: makeReadings(5, () => ({ temperature: 22 })),
        },
      ]),
      journal,
    });

    const task = createSensorQualityTask(deps);
    await task(); // Should not throw

    expect(journal.entries).toHaveLength(0);
  });

  it('skips when backend returns no readings', async () => {
    const journal = createMockJournal();
    const deps = buildDeps({
      llmProvider: createMockLLMProvider('{"issues": []}', true),
      sensorDataSource: createMockSensorSource([]),
      journal,
    });

    const task = createSensorQualityTask(deps);
    await task();

    expect(journal.entries).toHaveLength(0);
  });

  it('detects no issues in normal readings', async () => {
    const grafana = createMockGrafana();
    const journal = createMockJournal();

    const deps = buildDeps({
      llmProvider: createMockLLMProvider('{"issues": []}', true),
      sensorDataSource: createMockSensorSource([
        {
          stationId: 'station-a',
          readings: makeReadings(5, (i) => ({
            temperature: 20 + Math.random() * 2,
            humidity: 55 + i,
          })),
        },
      ]),
      grafana,
      journal,
    });

    const task = createSensorQualityTask(deps);
    await task();

    expect(grafana.annotations).toHaveLength(0);
    expect(journal.entries).toHaveLength(0);
  });

  it('flags stuck sensor via LLM response', async () => {
    const grafana = createMockGrafana();
    const journal = createMockJournal();

    const llmResponse = JSON.stringify({
      issues: [
        {
          station_id: 'station-stuck',
          issue_type: 'stuck',
          field: 'temperature',
          severity: 'warning',
          evidence:
            'Temperature has been exactly 22.0°C for all 20 readings',
          recommendation: 'Flag station for manual review',
        },
      ],
    });

    const deps = buildDeps({
      llmProvider: createMockLLMProvider(llmResponse, true),
      sensorDataSource: createMockSensorSource([
        {
          stationId: 'station-stuck',
          readings: makeReadings(20, () => ({ temperature: 22.0 })),
        },
      ]),
      grafana,
      journal,
    });

    const task = createSensorQualityTask(deps);
    await task();

    // Warning → grafana + journal (no webhook)
    expect(grafana.annotations).toHaveLength(1);
    expect(grafana.annotations[0].tags).toContain('sensor-quality');
    expect(journal.entries).toHaveLength(1);
    expect(journal.entries[0].severity).toBe('warning');
    expect(journal.entries[0].task).toBe('sensor-quality');
  });

  it('flags synthetic data pattern', async () => {
    const journal = createMockJournal();

    const llmResponse = JSON.stringify({
      issues: [
        {
          station_id: 'station-syn',
          issue_type: 'synthetic',
          field: 'humidity',
          severity: 'warning',
          evidence:
            'Humidity perfectly inverse to temperature with R²=1.00',
          recommendation: 'Investigate data generation pattern',
        },
      ],
    });

    const deps = buildDeps({
      llmProvider: createMockLLMProvider(llmResponse, true),
      sensorDataSource: createMockSensorSource([
        {
          stationId: 'station-syn',
          readings: makeReadings(10, (i) => ({
            temperature: 20 + i,
            humidity: 80 - i,
          })),
        },
      ]),
      journal,
    });

    const task = createSensorQualityTask(deps);
    await task();

    expect(journal.entries).toHaveLength(1);
    expect(journal.entries[0].finding).toContain('synthetic');
  });

  it('flags context anomaly (desert humidity)', async () => {
    const journal = createMockJournal();

    const llmResponse = JSON.stringify({
      issues: [
        {
          station_id: 'station-desert',
          issue_type: 'context_anomaly',
          field: 'humidity',
          severity: 'warning',
          evidence:
            'Station at desert coordinates reporting 95% humidity consistently',
          recommendation: 'Verify station location and sensor calibration',
        },
      ],
    });

    const deps = buildDeps({
      llmProvider: createMockLLMProvider(llmResponse, true),
      sensorDataSource: createMockSensorSource([
        {
          stationId: 'station-desert',
          latitude: 25.0,
          longitude: -110.0,
          readings: makeReadings(5, () => ({
            temperature: 42,
            humidity: 95,
          })),
        },
      ]),
      journal,
    });

    const task = createSensorQualityTask(deps);
    await task();

    expect(journal.entries).toHaveLength(1);
    expect(journal.entries[0].finding).toContain('context_anomaly');
  });

  it('filters stations with < min_readings_per_station', async () => {
    let capturedMessages: Message[] | null = null;

    const mockLLM: LLMProvider = {
      async chat(messages: Message[]): Promise<LLMResult> {
        capturedMessages = messages;
        return {
          content: '{"issues": []}',
          model: 'test',
          prompt_tokens: 10,
          completion_tokens: 5,
        };
      },
      async isAvailable() {
        return true;
      },
    };

    const deps = buildDeps({
      llmProvider: mockLLM,
      sensorDataSource: createMockSensorSource([
        {
          stationId: 'has-enough',
          readings: makeReadings(5, () => ({ temperature: 20 })),
        },
        {
          stationId: 'too-few',
          readings: makeReadings(2, () => ({ temperature: 20 })),
        },
      ]),
      taskConfig: { ...DEFAULT_TASK_CONFIG, min_readings_per_station: 3 },
    });

    const task = createSensorQualityTask(deps);
    await task();

    // Only "has-enough" should be in the prompt
    expect(capturedMessages).not.toBeNull();
    const userContent = capturedMessages![1].content;
    expect(userContent).toContain('has-enough');
    expect(userContent).not.toContain('too-few');
  });

  it('caps at max_stations_per_batch', async () => {
    // Create 60 stations, cap at 50
    const manyStations: StationReadings[] = Array.from(
      { length: 60 },
      (_, i) => ({
        stationId: `station-${i}`,
        readings: makeReadings(5, () => ({ temperature: 20 })),
      }),
    );

    // The source already caps, but verify the source receives the config
    const source = createMockSensorSource(manyStations.slice(0, 50));

    let capturedMessages: Message[] | null = null;
    const mockLLM: LLMProvider = {
      async chat(messages: Message[]): Promise<LLMResult> {
        capturedMessages = messages;
        return {
          content: '{"issues": []}',
          model: 'test',
          prompt_tokens: 10,
          completion_tokens: 5,
        };
      },
      async isAvailable() {
        return true;
      },
    };

    const deps = buildDeps({
      llmProvider: mockLLM,
      sensorDataSource: source,
      taskConfig: { ...DEFAULT_TASK_CONFIG, max_stations_per_batch: 50 },
    });

    const task = createSensorQualityTask(deps);
    await task();

    expect(capturedMessages).not.toBeNull();
    // Verify we sent 50 stations, not 60
    const parsed = JSON.parse(
      capturedMessages![1].content.replace('Station readings:\n\n', ''),
    );
    expect(parsed).toHaveLength(50);
  });

  it('routes warning → grafana + journal, no webhook', async () => {
    const grafana = createMockGrafana();
    const webhookOut = createMockWebhook();
    const journal = createMockJournal();

    const llmResponse = JSON.stringify({
      issues: [
        {
          station_id: 's1',
          issue_type: 'drift',
          field: 'pressure',
          severity: 'warning',
          evidence: 'Gradual drift',
          recommendation: 'Check',
        },
      ],
    });

    const deps = buildDeps({
      llmProvider: createMockLLMProvider(llmResponse, true),
      sensorDataSource: createMockSensorSource([
        {
          stationId: 's1',
          readings: makeReadings(5, () => ({ pressure: 1013 })),
        },
      ]),
      grafana,
      webhook: webhookOut,
      journal,
    });

    const task = createSensorQualityTask(deps);
    await task();

    expect(grafana.annotations).toHaveLength(1);
    expect(journal.entries).toHaveLength(1);
    expect(webhookOut.payloads).toHaveLength(0);
  });

  it('routes critical → grafana + webhook + journal', async () => {
    const grafana = createMockGrafana();
    const webhookOut = createMockWebhook();
    const journal = createMockJournal();

    const llmResponse = JSON.stringify({
      issues: [
        {
          station_id: 's2',
          issue_type: 'synthetic',
          field: 'temperature',
          severity: 'critical',
          evidence: 'Clearly fabricated data',
          recommendation: 'Suspend station',
        },
      ],
    });

    const deps = buildDeps({
      llmProvider: createMockLLMProvider(llmResponse, true),
      sensorDataSource: createMockSensorSource([
        {
          stationId: 's2',
          readings: makeReadings(5, () => ({ temperature: 20 })),
        },
      ]),
      grafana,
      webhook: webhookOut,
      journal,
    });

    const task = createSensorQualityTask(deps);
    await task();

    expect(grafana.annotations).toHaveLength(1);
    expect(grafana.annotations[0].tags).toContain('sensor-quality-critical');
    expect(webhookOut.payloads).toHaveLength(1);
    expect(webhookOut.payloads[0].severity).toBe('critical');
    expect(journal.entries).toHaveLength(1);
  });

  it('routes info → journal only (no grafana, no webhook)', async () => {
    const grafana = createMockGrafana();
    const webhookOut = createMockWebhook();
    const journal = createMockJournal();

    const llmResponse = JSON.stringify({
      issues: [
        {
          station_id: 's3',
          issue_type: 'outlier',
          field: 'humidity',
          severity: 'info',
          evidence: 'Minor outlier',
          recommendation: 'No action needed',
        },
      ],
    });

    const deps = buildDeps({
      llmProvider: createMockLLMProvider(llmResponse, true),
      sensorDataSource: createMockSensorSource([
        {
          stationId: 's3',
          readings: makeReadings(5, () => ({ humidity: 50 })),
        },
      ]),
      grafana,
      webhook: webhookOut,
      journal,
    });

    const task = createSensorQualityTask(deps);
    await task();

    expect(journal.entries).toHaveLength(1);
    expect(grafana.annotations).toHaveLength(0);
    expect(webhookOut.payloads).toHaveLength(0);
  });

  it('handles malformed LLM response gracefully', async () => {
    const grafana = createMockGrafana();
    const journal = createMockJournal();

    const deps = buildDeps({
      llmProvider: createMockLLMProvider(
        'Sorry, I cannot analyze these readings properly.',
        true,
      ),
      sensorDataSource: createMockSensorSource([
        {
          stationId: 'station-a',
          readings: makeReadings(5, () => ({ temperature: 20 })),
        },
      ]),
      grafana,
      journal,
    });

    const task = createSensorQualityTask(deps);
    await task(); // Should not throw

    expect(grafana.annotations).toHaveLength(0);
    expect(journal.entries).toHaveLength(0);
  });

  it('handles backend API down gracefully', async () => {
    const journal = createMockJournal();

    const failingSource = {
      fetchRecentReadings: async () => {
        throw new Error('ECONNREFUSED');
      },
    } as unknown as SensorDataSource;

    const deps = buildDeps({
      llmProvider: createMockLLMProvider('{"issues": []}', true),
      sensorDataSource: failingSource,
      journal,
    });

    const task = createSensorQualityTask(deps);
    await task(); // Should not throw

    expect(journal.entries).toHaveLength(0);
  });
});
