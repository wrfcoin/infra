import * as http from 'node:http';
import * as os from 'node:os';
import * as path from 'node:path';
import * as fs from 'node:fs';
import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import { Registry } from 'prom-client';
import {
  createLogAnomalyTask,
  parseLLMResponse,
  type LogAnomalyConfig,
  type LogAnomalyDeps,
} from '../src/tasks/log-anomaly.js';
import type { LLMProvider, LLMResult, Message, LLMOptions } from '../src/llm/provider.js';
import type { DockerLogSource, PrioritizedLogResult } from '../src/sources/docker.js';
import type { GrafanaOutput, GrafanaAnnotation } from '../src/outputs/grafana.js';
import type { WebhookOutput, WebhookPayload } from '../src/outputs/webhook.js';
import type { JournalOutput, JournalEntry } from '../src/outputs/journal.js';
import type { HealthServer } from '../src/health-server.js';
import { Counter } from 'prom-client';

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
        prompt_tokens: 50,
        completion_tokens: 20,
      };
    },
    async isAvailable(): Promise<boolean> {
      return available;
    },
  };
}

function createMockDockerSource(
  logs: PrioritizedLogResult[],
): DockerLogSource {
  return {
    collectLogsWithBudget: async () => logs,
    collectLogs: async () => logs,
  } as unknown as DockerLogSource;
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
      name: 'test_llm_requests_total',
      help: 'test',
      labelNames: ['status'] as const,
      registers: [registry],
    }),
  } as unknown as HealthServer;
}

const DEFAULT_TASK_CONFIG: LogAnomalyConfig = {
  window_minutes: 5,
  containers: ['*'],
  min_severity: 'warning',
  max_log_lines: 500,
  noise_filters: [],
};

function buildDeps(overrides: Partial<LogAnomalyDeps> = {}): LogAnomalyDeps {
  return {
    llmProvider: createMockLLMProvider('{"anomalies": []}'),
    dockerSource: createMockDockerSource([]),
    grafana: createMockGrafana(),
    webhook: createMockWebhook(),
    journal: createMockJournal(),
    healthServer: createMockHealthServer(),
    taskConfig: DEFAULT_TASK_CONFIG,
    ...overrides,
  };
}

// --- Tests ---

describe('parseLLMResponse', () => {
  it('parses valid anomaly JSON', () => {
    const result = parseLLMResponse(
      '{"anomalies": [{"severity": "warning", "service": "api", "summary": "High latency", "evidence": "p99 > 2s"}]}',
      'warning',
    );
    expect(result).toHaveLength(1);
    expect(result[0].severity).toBe('warning');
    expect(result[0].service).toBe('api');
  });

  it('returns empty array for no anomalies', () => {
    const result = parseLLMResponse('{"anomalies": []}', 'warning');
    expect(result).toHaveLength(0);
  });

  it('handles malformed JSON gracefully', () => {
    const result = parseLLMResponse('not valid json at all', 'warning');
    expect(result).toHaveLength(0);
  });

  it('extracts JSON from markdown code blocks', () => {
    const result = parseLLMResponse(
      '```json\n{"anomalies": [{"severity": "critical", "service": "db", "summary": "OOM"}]}\n```',
      'warning',
    );
    expect(result).toHaveLength(1);
    expect(result[0].severity).toBe('critical');
  });

  it('filters by min_severity', () => {
    const result = parseLLMResponse(
      '{"anomalies": [{"severity": "info", "service": "x", "summary": "debug noise"}]}',
      'warning',
    );
    expect(result).toHaveLength(0);
  });
});

describe('createLogAnomalyTask', () => {
  it('skips when LLM is unavailable', async () => {
    const deps = buildDeps({
      llmProvider: createMockLLMProvider(null, false),
      dockerSource: createMockDockerSource([
        {
          containerId: 'abc123',
          containerName: 'wrfcoin-api',
          logs: 'some logs',
          lineCount: 1,
          errorLines: 0,
          warnLines: 0,
        },
      ]),
    });

    const task = createLogAnomalyTask(deps);
    await task(); // Should not throw
  });

  it('skips when no logs collected', async () => {
    const deps = buildDeps({
      llmProvider: createMockLLMProvider('{"anomalies": []}', true),
      dockerSource: createMockDockerSource([]),
    });

    const task = createLogAnomalyTask(deps);
    await task(); // Should not throw
  });

  it('detects no anomalies in normal logs', async () => {
    const grafana = createMockGrafana();
    const journal = createMockJournal();

    const deps = buildDeps({
      llmProvider: createMockLLMProvider('{"anomalies": []}', true),
      dockerSource: createMockDockerSource([
        {
          containerId: 'abc123',
          containerName: 'wrfcoin-api',
          logs: '2026-03-15T01:00:00Z INFO Request processed successfully',
          lineCount: 1,
          errorLines: 0,
          warnLines: 0,
        },
      ]),
      grafana,
      journal,
    });

    const task = createLogAnomalyTask(deps);
    await task();

    expect(grafana.annotations).toHaveLength(0);
    expect(journal.entries).toHaveLength(0);
  });

  it('routes warning anomaly to grafana + journal', async () => {
    const grafana = createMockGrafana();
    const journal = createMockJournal();
    const webhookOut = createMockWebhook();

    const llmResponse = JSON.stringify({
      anomalies: [
        {
          severity: 'warning',
          service: 'wrfcoin-wallet',
          summary: 'Connection pool shrinking: active connections dropped from 50 to 12',
          evidence: 'pool_size=12 prev_pool_size=50',
        },
      ],
    });

    const deps = buildDeps({
      llmProvider: createMockLLMProvider(llmResponse, true),
      dockerSource: createMockDockerSource([
        {
          containerId: 'def456',
          containerName: 'wrfcoin-wallet',
          logs: 'WARN Connection pool shrinking: pool_size=12 prev_pool_size=50',
          lineCount: 1,
          errorLines: 0,
          warnLines: 1,
        },
      ]),
      grafana,
      webhook: webhookOut,
      journal,
    });

    const task = createLogAnomalyTask(deps);
    await task();

    // Warning → Grafana + journal (no webhook)
    expect(grafana.annotations).toHaveLength(1);
    expect(grafana.annotations[0].tags).toContain('anomaly');
    expect(grafana.annotations[0].tags).not.toContain('anomaly-critical');

    expect(journal.entries).toHaveLength(1);
    expect(journal.entries[0].severity).toBe('warning');

    expect(webhookOut.payloads).toHaveLength(0);
  });

  it('routes critical anomaly to grafana + webhook + journal', async () => {
    const grafana = createMockGrafana();
    const journal = createMockJournal();
    const webhookOut = createMockWebhook();

    const llmResponse = JSON.stringify({
      anomalies: [
        {
          severity: 'critical',
          service: 'wrfcoin-api',
          summary: 'OOM killer terminated process, service crash-looping',
          evidence: 'Out of memory: Killed process 1234',
        },
        {
          severity: 'critical',
          service: 'wrfcoin-wallet',
          summary: 'Connection refused after OOM in dependent service',
          evidence: 'ECONNREFUSED 127.0.0.1:4001',
        },
      ],
    });

    const deps = buildDeps({
      llmProvider: createMockLLMProvider(llmResponse, true),
      dockerSource: createMockDockerSource([
        {
          containerId: 'aaa111',
          containerName: 'wrfcoin-api',
          logs: 'ERROR Out of memory: Killed process 1234\nFATAL Service shutting down',
          lineCount: 2,
          errorLines: 2,
          warnLines: 0,
        },
        {
          containerId: 'bbb222',
          containerName: 'wrfcoin-wallet',
          logs: 'ERROR ECONNREFUSED 127.0.0.1:4001',
          lineCount: 1,
          errorLines: 1,
          warnLines: 0,
        },
      ]),
      grafana,
      webhook: webhookOut,
      journal,
    });

    const task = createLogAnomalyTask(deps);
    await task();

    // 2 critical anomalies → 2 grafana + 2 webhook + 2 journal
    expect(grafana.annotations).toHaveLength(2);
    expect(grafana.annotations[0].tags).toContain('anomaly-critical');

    expect(webhookOut.payloads).toHaveLength(2);
    expect(webhookOut.payloads[0].severity).toBe('critical');

    expect(journal.entries).toHaveLength(2);
  });

  it('handles malformed LLM response gracefully', async () => {
    const grafana = createMockGrafana();
    const journal = createMockJournal();

    const deps = buildDeps({
      llmProvider: createMockLLMProvider(
        'Sorry, I cannot analyze these logs properly.',
        true,
      ),
      dockerSource: createMockDockerSource([
        {
          containerId: 'abc123',
          containerName: 'wrfcoin-api',
          logs: 'ERROR something',
          lineCount: 1,
          errorLines: 1,
          warnLines: 0,
        },
      ]),
      grafana,
      journal,
    });

    const task = createLogAnomalyTask(deps);
    await task(); // Should not throw

    expect(grafana.annotations).toHaveLength(0);
    expect(journal.entries).toHaveLength(0);
  });
});

describe('noise filtering and token budget', () => {
  it('noise filters are passed to docker source', async () => {
    let capturedOptions: unknown;

    const mockDocker = {
      collectLogsWithBudget: async (opts: unknown) => {
        capturedOptions = opts;
        return [];
      },
      collectLogs: async () => [],
    } as unknown as DockerLogSource;

    const deps = buildDeps({
      llmProvider: createMockLLMProvider('{"anomalies": []}', true),
      dockerSource: mockDocker,
      taskConfig: {
        ...DEFAULT_TASK_CONFIG,
        noise_filters: ['GET /health 200', 'GET /metrics 200'],
        max_log_lines: 200,
      },
    });

    const task = createLogAnomalyTask(deps);
    await task();

    const opts = capturedOptions as {
      noiseFilters: string[];
      maxLogLines: number;
    };
    expect(opts.noiseFilters).toEqual([
      'GET /health 200',
      'GET /metrics 200',
    ]);
    expect(opts.maxLogLines).toBe(200);
  });

  it('token budget limits log lines', async () => {
    // This tests the DockerLogSource.collectLogsWithBudget indirectly
    // by verifying the task passes max_log_lines to the source
    let capturedOptions: unknown;

    const mockDocker = {
      collectLogsWithBudget: async (opts: unknown) => {
        capturedOptions = opts;
        return [];
      },
      collectLogs: async () => [],
    } as unknown as DockerLogSource;

    const deps = buildDeps({
      llmProvider: createMockLLMProvider('{"anomalies": []}', true),
      dockerSource: mockDocker,
      taskConfig: {
        ...DEFAULT_TASK_CONFIG,
        max_log_lines: 100,
      },
    });

    const task = createLogAnomalyTask(deps);
    await task();

    expect((capturedOptions as { maxLogLines: number }).maxLogLines).toBe(
      100,
    );
  });
});
