import * as http from 'node:http';
import {
  describe,
  it,
  expect,
  beforeEach,
  afterEach,
  vi,
} from 'vitest';
import { Registry, Counter } from 'prom-client';
import {
  createAlertSummaryTask,
  parseCorrelationResponse,
  type AlertSummaryConfig,
  type AlertSummaryDeps,
  type AlertSummaryTask,
} from '../src/tasks/alert-summary.js';
import { AlertReceiver, type AlertManagerAlert } from '../src/alert-receiver.js';
import type { LLMProvider, LLMResult, Message, LLMOptions } from '../src/llm/provider.js';
import type { GrafanaOutput, GrafanaAnnotation } from '../src/outputs/grafana.js';
import type { WebhookOutput, WebhookPayload } from '../src/outputs/webhook.js';
import type { JournalOutput, JournalEntry } from '../src/outputs/journal.js';
import type { HealthServer } from '../src/health-server.js';

// --- Mock factories ---

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
        prompt_tokens: 80,
        completion_tokens: 40,
      };
    },
    async isAvailable(): Promise<boolean> {
      return available;
    },
  };
}

function createMockGrafana(): GrafanaOutput & { annotations: GrafanaAnnotation[] } {
  const annotations: GrafanaAnnotation[] = [];
  return {
    annotations,
    isConfigured: () => true,
    annotate: async (a: GrafanaAnnotation) => { annotations.push(a); },
  } as unknown as GrafanaOutput & { annotations: GrafanaAnnotation[] };
}

function createMockWebhook(): WebhookOutput & { payloads: WebhookPayload[] } {
  const payloads: WebhookPayload[] = [];
  return {
    payloads,
    isConfigured: () => true,
    send: async (p: WebhookPayload) => { payloads.push(p); },
  } as unknown as WebhookOutput & { payloads: WebhookPayload[] };
}

function createMockJournal(): JournalOutput & { entries: JournalEntry[] } {
  const entries: JournalEntry[] = [];
  return {
    entries,
    append: (e: JournalEntry) => { entries.push(e); },
  } as unknown as JournalOutput & { entries: JournalEntry[] };
}

function createMockHealthServer(): HealthServer {
  const registry = new Registry();
  return {
    registry,
    llmRequestsCounter: new Counter({
      name: 'test_alert_llm_requests_total',
      help: 'test',
      labelNames: ['status'] as const,
      registers: [registry],
    }),
  } as unknown as HealthServer;
}

const DEFAULT_CONFIG: AlertSummaryConfig = {
  batch_window_seconds: 60,
  min_alerts_for_correlation: 2,
  include_resolved: true,
  alert_receiver_port: 0, // random port for tests
};

function buildDeps(overrides: Partial<AlertSummaryDeps> = {}): AlertSummaryDeps {
  return {
    llmProvider: createMockLLMProvider('{"root_cause":"test","cascade":[],"investigation":[],"severity":"degraded","affected_services":[]}'),
    grafana: createMockGrafana(),
    webhook: createMockWebhook(),
    journal: createMockJournal(),
    healthServer: createMockHealthServer(),
    taskConfig: DEFAULT_CONFIG,
    ...overrides,
  };
}

function makeAlert(overrides: Partial<AlertManagerAlert> = {}): AlertManagerAlert {
  return {
    status: 'firing',
    labels: { alertname: 'HighCPU', severity: 'warning', service: 'main-api' },
    annotations: { summary: 'CPU > 80%', description: 'High CPU usage detected' },
    startsAt: '2026-03-15T12:00:00Z',
    endsAt: '0001-01-01T00:00:00Z',
    fingerprint: 'abc123',
    ...overrides,
  };
}

// --- Tests ---

describe('parseCorrelationResponse', () => {
  it('parses valid correlation JSON', () => {
    const result = parseCorrelationResponse(JSON.stringify({
      root_cause: 'Database connection pool exhausted',
      cascade: ['DB pool full → API timeouts → health check failures'],
      investigation: ['Check pg_stat_activity', 'Review connection limits'],
      severity: 'partial_outage',
      affected_services: ['main-api', 'wallet'],
    }));

    expect(result.root_cause).toBe('Database connection pool exhausted');
    expect(result.severity).toBe('partial_outage');
    expect(result.cascade).toHaveLength(1);
    expect(result.affected_services).toContain('main-api');
  });

  it('handles malformed JSON gracefully', () => {
    const result = parseCorrelationResponse('not json');
    expect(result.severity).toBe('degraded');
    expect(result.root_cause).toContain('Unable to parse');
  });

  it('defaults unknown severity to degraded', () => {
    const result = parseCorrelationResponse(
      '{"root_cause":"x","severity":"banana","cascade":[],"investigation":[],"affected_services":[]}',
    );
    expect(result.severity).toBe('degraded');
  });

  it('extracts JSON from markdown code blocks', () => {
    const result = parseCorrelationResponse(
      '```json\n{"root_cause":"OOM","cascade":[],"investigation":[],"severity":"full_outage","affected_services":["api"]}\n```',
    );
    expect(result.severity).toBe('full_outage');
    expect(result.root_cause).toBe('OOM');
  });
});

describe('AlertReceiver', () => {
  let receiver: AlertReceiver;
  let receivedAlerts: AlertManagerAlert[];
  let port: number;

  beforeEach(async () => {
    receivedAlerts = [];
    receiver = new AlertReceiver((alerts) => {
      receivedAlerts.push(...alerts);
    });
    port = await receiver.start(0);
  });

  afterEach(async () => {
    await receiver.stop();
  });

  it('accepts valid AlertManager payload and returns 200', async () => {
    const payload = {
      status: 'firing',
      alerts: [makeAlert()],
      groupLabels: {},
      commonLabels: {},
      externalURL: 'http://alertmanager:9093',
    };

    const res = await fetch(`http://localhost:${port}/alerts`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });

    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.status).toBe('accepted');
    expect(body.count).toBe(1);
    expect(receivedAlerts).toHaveLength(1);
  });

  it('returns 400 for malformed JSON', async () => {
    const res = await fetch(`http://localhost:${port}/alerts`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: 'not json',
    });

    expect(res.status).toBe(400);
  });

  it('returns 400 for missing alerts array', async () => {
    const res = await fetch(`http://localhost:${port}/alerts`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ status: 'firing' }),
    });

    expect(res.status).toBe(400);
  });

  it('returns 200 for empty alerts array (no-op)', async () => {
    const res = await fetch(`http://localhost:${port}/alerts`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ status: 'firing', alerts: [], groupLabels: {}, commonLabels: {}, externalURL: '' }),
    });

    expect(res.status).toBe(200);
    expect(receivedAlerts).toHaveLength(0);
  });
});

describe('Alert batching', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('batches alerts within window and processes after timeout', async () => {
    const journal = createMockJournal();
    const grafana = createMockGrafana();

    const llmResponse = JSON.stringify({
      root_cause: 'High CPU across cluster',
      cascade: [],
      investigation: ['Check process list'],
      severity: 'degraded',
      affected_services: ['main-api'],
    });

    const deps = buildDeps({
      llmProvider: createMockLLMProvider(llmResponse, true),
      grafana,
      journal,
      taskConfig: { ...DEFAULT_CONFIG, batch_window_seconds: 5 },
    });

    const task = createAlertSummaryTask(deps);

    // Send 1 alert
    task.receiveAlerts([makeAlert()]);

    // Advance timer past batch window
    vi.advanceTimersByTime(5_000);

    // Let async processing complete
    await vi.advanceTimersByTimeAsync(100);

    expect(journal.entries).toHaveLength(1);
    expect(journal.entries[0].task).toBe('alert-summary');
    expect(grafana.annotations).toHaveLength(1);

    task.shutdown();
  });

  it('deduplicates alerts by fingerprint within window', async () => {
    const journal = createMockJournal();

    const llmResponse = JSON.stringify({
      root_cause: 'test',
      cascade: [],
      investigation: [],
      severity: 'degraded',
      affected_services: [],
    });

    const deps = buildDeps({
      llmProvider: createMockLLMProvider(llmResponse, true),
      journal,
      taskConfig: { ...DEFAULT_CONFIG, batch_window_seconds: 5 },
    });

    const task = createAlertSummaryTask(deps);

    // Send same alert 3 times (same fingerprint)
    task.receiveAlerts([makeAlert({ fingerprint: 'dup1' })]);
    task.receiveAlerts([makeAlert({ fingerprint: 'dup1' })]);
    task.receiveAlerts([makeAlert({ fingerprint: 'dup1' })]);

    vi.advanceTimersByTime(5_000);
    await vi.advanceTimersByTimeAsync(100);

    // Should process only 1 unique alert
    expect(journal.entries).toHaveLength(1);

    task.shutdown();
  });

  it('collects multiple distinct alerts into one batch', async () => {
    let capturedMessages: Message[] = [];

    const mockLLM: LLMProvider = {
      async chat(messages: Message[]): Promise<LLMResult> {
        capturedMessages = messages;
        return {
          content: JSON.stringify({
            root_cause: 'Cascading failure',
            cascade: ['DB → API → Frontend'],
            investigation: ['Check DB'],
            severity: 'partial_outage',
            affected_services: ['db', 'api'],
          }),
          model: 'test',
          prompt_tokens: 100,
          completion_tokens: 50,
        };
      },
      async isAvailable() { return true; },
    };

    const webhookOut = createMockWebhook();
    const deps = buildDeps({
      llmProvider: mockLLM,
      webhook: webhookOut,
      taskConfig: { ...DEFAULT_CONFIG, batch_window_seconds: 5 },
    });

    const task = createAlertSummaryTask(deps);

    task.receiveAlerts([
      makeAlert({ fingerprint: 'a1', labels: { alertname: 'HighCPU', severity: 'warning', service: 'api' } }),
      makeAlert({ fingerprint: 'a2', labels: { alertname: 'DBConnExhausted', severity: 'critical', service: 'db' } }),
    ]);
    task.receiveAlerts([
      makeAlert({ fingerprint: 'a3', labels: { alertname: 'HealthCheckFailed', severity: 'critical', service: 'frontend' } }),
    ]);

    vi.advanceTimersByTime(5_000);
    await vi.advanceTimersByTimeAsync(100);

    // 3 alerts in one batch
    const userMessage = capturedMessages.find((m) => m.role === 'user');
    expect(userMessage?.content).toContain('HighCPU');
    expect(userMessage?.content).toContain('DBConnExhausted');
    expect(userMessage?.content).toContain('HealthCheckFailed');

    // partial_outage → webhook fires
    expect(webhookOut.payloads).toHaveLength(1);
    expect(webhookOut.payloads[0].severity).toBe('partial_outage');

    task.shutdown();
  });

  it('starts new batch after window closes', async () => {
    const journal = createMockJournal();

    const llmResponse = JSON.stringify({
      root_cause: 'test',
      cascade: [],
      investigation: [],
      severity: 'degraded',
      affected_services: [],
    });

    const deps = buildDeps({
      llmProvider: createMockLLMProvider(llmResponse, true),
      journal,
      taskConfig: { ...DEFAULT_CONFIG, batch_window_seconds: 5 },
    });

    const task = createAlertSummaryTask(deps);

    // First batch
    task.receiveAlerts([makeAlert({ fingerprint: 'batch1' })]);
    vi.advanceTimersByTime(5_000);
    await vi.advanceTimersByTimeAsync(100);

    // Second batch (new alert after window closed)
    task.receiveAlerts([makeAlert({ fingerprint: 'batch2' })]);
    vi.advanceTimersByTime(5_000);
    await vi.advanceTimersByTimeAsync(100);

    expect(journal.entries).toHaveLength(2);

    task.shutdown();
  });
});

describe('Severity routing', () => {
  beforeEach(() => { vi.useFakeTimers(); });
  afterEach(() => { vi.useRealTimers(); });

  it('degraded → Grafana + journal (no webhook)', async () => {
    const grafana = createMockGrafana();
    const webhookOut = createMockWebhook();
    const journal = createMockJournal();

    const deps = buildDeps({
      llmProvider: createMockLLMProvider(JSON.stringify({
        root_cause: 'Minor latency spike',
        cascade: [],
        investigation: [],
        severity: 'degraded',
        affected_services: ['api'],
      }), true),
      grafana,
      webhook: webhookOut,
      journal,
      taskConfig: { ...DEFAULT_CONFIG, batch_window_seconds: 1 },
    });

    const task = createAlertSummaryTask(deps);
    task.receiveAlerts([makeAlert()]);
    vi.advanceTimersByTime(1_000);
    await vi.advanceTimersByTimeAsync(100);

    expect(grafana.annotations).toHaveLength(1);
    expect(grafana.annotations[0].tags).toContain('alert-degraded');
    expect(journal.entries).toHaveLength(1);
    expect(webhookOut.payloads).toHaveLength(0);

    task.shutdown();
  });

  it('full_outage → Grafana + webhook + journal', async () => {
    const grafana = createMockGrafana();
    const webhookOut = createMockWebhook();
    const journal = createMockJournal();

    const deps = buildDeps({
      llmProvider: createMockLLMProvider(JSON.stringify({
        root_cause: 'Database down',
        cascade: ['DB → all services'],
        investigation: ['Check RDS'],
        severity: 'full_outage',
        affected_services: ['db', 'api', 'wallet'],
      }), true),
      grafana,
      webhook: webhookOut,
      journal,
      taskConfig: { ...DEFAULT_CONFIG, batch_window_seconds: 1 },
    });

    const task = createAlertSummaryTask(deps);
    task.receiveAlerts([makeAlert()]);
    vi.advanceTimersByTime(1_000);
    await vi.advanceTimersByTimeAsync(100);

    expect(grafana.annotations).toHaveLength(1);
    expect(grafana.annotations[0].tags).toContain('alert-full-outage');
    expect(webhookOut.payloads).toHaveLength(1);
    expect(journal.entries).toHaveLength(1);

    task.shutdown();
  });
});

describe('Resolved alerts', () => {
  beforeEach(() => { vi.useFakeTimers(); });
  afterEach(() => { vi.useRealTimers(); });

  it('tracks firing → resolved with duration', async () => {
    const grafana = createMockGrafana();
    const journal = createMockJournal();

    const deps = buildDeps({
      grafana,
      journal,
      taskConfig: { ...DEFAULT_CONFIG, batch_window_seconds: 1 },
    });

    const task = createAlertSummaryTask(deps);

    // First: firing alert
    task.receiveAlerts([makeAlert({
      status: 'firing',
      fingerprint: 'incident1',
      labels: { alertname: 'HighCPU', severity: 'warning', service: 'api' },
      startsAt: '2026-03-15T12:00:00Z',
    })]);

    vi.advanceTimersByTime(1_000);
    await vi.advanceTimersByTimeAsync(100);

    // Then: resolved
    task.receiveAlerts([makeAlert({
      status: 'resolved',
      fingerprint: 'incident1',
      labels: { alertname: 'HighCPU', severity: 'warning', service: 'api' },
      startsAt: '2026-03-15T12:00:00Z',
      endsAt: '2026-03-15T12:05:00Z',
    })]);

    // Resolved alerts are processed immediately (no batch window)
    await vi.advanceTimersByTimeAsync(100);

    // Journal should have: 1 from batch + 1 resolved
    const resolvedEntry = journal.entries.find(
      (e) => e.finding.includes('resolved'),
    );
    expect(resolvedEntry).toBeDefined();
    expect(resolvedEntry!.finding).toContain('Duration: 5m');

    task.shutdown();
  });
});

describe('Graceful degradation', () => {
  beforeEach(() => { vi.useFakeTimers(); });
  afterEach(() => { vi.useRealTimers(); });

  it('logs to journal without analysis when LLM unavailable', async () => {
    const journal = createMockJournal();

    const deps = buildDeps({
      llmProvider: createMockLLMProvider(null, false),
      journal,
      taskConfig: { ...DEFAULT_CONFIG, batch_window_seconds: 1 },
    });

    const task = createAlertSummaryTask(deps);
    task.receiveAlerts([
      makeAlert({ labels: { alertname: 'HighCPU', severity: 'warning', service: 'api' } }),
    ]);

    vi.advanceTimersByTime(1_000);
    await vi.advanceTimersByTimeAsync(100);

    // Alert logged to journal without LLM analysis
    expect(journal.entries).toHaveLength(1);
    expect(journal.entries[0].finding).toContain('[unanalyzed]');
    expect(journal.entries[0].llm_model).toBeNull();

    task.shutdown();
  });
});
