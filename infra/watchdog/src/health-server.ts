import * as http from 'node:http';
import { Registry, Gauge, Counter, Histogram, collectDefaultMetrics } from 'prom-client';
import type { Scheduler } from './scheduler.js';

export class HealthServer {
  private server: http.Server | null = null;
  private scheduler: Scheduler;
  private startTime: number;
  private onAlertCallback: (() => Promise<void>) | null;

  // Prometheus metrics
  readonly registry: Registry;
  readonly upGauge: Gauge;
  readonly taskRunsCounter: Counter;
  readonly taskDurationHistogram: Histogram;
  readonly llmRequestsCounter: Counter;
  readonly llmLatencyHistogram: Histogram;

  constructor(
    scheduler: Scheduler,
    onAlertCallback: (() => Promise<void>) | null = null,
  ) {
    this.scheduler = scheduler;
    this.startTime = Date.now();
    this.onAlertCallback = onAlertCallback;

    this.registry = new Registry();
    collectDefaultMetrics({ register: this.registry });

    this.upGauge = new Gauge({
      name: 'wrfcoin_watchdog_up',
      help: 'Whether the watchdog service is running',
      registers: [this.registry],
    });
    this.upGauge.set(1);

    this.taskRunsCounter = new Counter({
      name: 'wrfcoin_watchdog_task_runs_total',
      help: 'Total number of task executions',
      labelNames: ['task', 'status'] as const,
      registers: [this.registry],
    });

    this.taskDurationHistogram = new Histogram({
      name: 'wrfcoin_watchdog_task_duration_seconds',
      help: 'Task execution duration in seconds',
      labelNames: ['task'] as const,
      buckets: [0.1, 0.5, 1, 5, 10, 30, 60],
      registers: [this.registry],
    });

    this.llmRequestsCounter = new Counter({
      name: 'wrfcoin_watchdog_llm_requests_total',
      help: 'Total LLM API requests',
      labelNames: ['status'] as const,
      registers: [this.registry],
    });

    this.llmLatencyHistogram = new Histogram({
      name: 'wrfcoin_watchdog_llm_latency_seconds',
      help: 'LLM request latency in seconds',
      buckets: [0.5, 1, 2, 5, 10, 30],
      registers: [this.registry],
    });
  }

  async start(port: number = 3334): Promise<number> {
    this.server = http.createServer(async (req, res) => {
      if (req.url === '/health' && req.method === 'GET') {
        this.handleHealth(res);
        return;
      }

      if (req.url === '/metrics' && req.method === 'GET') {
        await this.handleMetrics(res);
        return;
      }

      if (
        req.url === '/webhook/alertmanager' &&
        req.method === 'POST'
      ) {
        await this.handleAlertWebhook(req, res);
        return;
      }

      res.writeHead(404);
      res.end('Not Found');
    });

    return new Promise<number>((resolve, reject) => {
      this.server?.once('error', reject);
      this.server?.listen(port, () => {
        const address = this.server?.address();
        if (!address || typeof address === 'string') {
          reject(new Error('Health server did not bind to a TCP port'));
          return;
        }
        console.log(`[health] Listening on port ${address.port}`);
        resolve(address.port);
      });
    });
  }

  async stop(): Promise<void> {
    if (!this.server) return;
    const server = this.server;
    this.server = null;
    await new Promise<void>((resolve, reject) => {
      server.close((err) => (err ? reject(err) : resolve()));
    });
  }

  private handleHealth(res: http.ServerResponse): void {
    const status = {
      status: 'ok',
      uptime: Math.round((Date.now() - this.startTime) / 1000),
      tasks: this.scheduler.getTaskStatus(),
    };
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(status));
  }

  private async handleMetrics(res: http.ServerResponse): Promise<void> {
    try {
      const metrics = await this.registry.metrics();
      res.writeHead(200, {
        'Content-Type': this.registry.contentType,
      });
      res.end(metrics);
    } catch (err) {
      res.writeHead(500);
      res.end(`Error collecting metrics: ${(err as Error).message}`);
    }
  }

  private async handleAlertWebhook(
    req: http.IncomingMessage,
    res: http.ServerResponse,
  ): Promise<void> {
    const chunks: Buffer[] = [];
    for await (const chunk of req) {
      chunks.push(chunk as Buffer);
    }

    console.log('[health] Received alertmanager webhook');

    if (this.onAlertCallback) {
      // Fire and forget — don't block the webhook response
      this.onAlertCallback().catch((err) => {
        console.error(`[health] on-alert callback failed: ${(err as Error).message}`);
      });
    }

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'accepted' }));
  }
}
