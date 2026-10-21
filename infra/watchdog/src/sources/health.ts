import type { HealthService } from '../config.js';

export interface HealthCheckResult {
  name: string;
  url: string;
  healthy: boolean;
  status: number | null;
  responseTimeMs: number;
  error: string | null;
  body: unknown;
}

export class HealthPoller {
  private services: HealthService[];
  private timeoutMs: number;

  constructor(services: HealthService[], timeoutMs = 5000) {
    this.services = services;
    this.timeoutMs = timeoutMs;
  }

  async checkAll(): Promise<HealthCheckResult[]> {
    return Promise.all(this.services.map((svc) => this.check(svc)));
  }

  private async check(service: HealthService): Promise<HealthCheckResult> {
    const start = performance.now();

    try {
      const res = await fetch(service.url, {
        signal: AbortSignal.timeout(this.timeoutMs),
      });

      const elapsed = performance.now() - start;
      let body: unknown = null;

      const contentType = res.headers.get('content-type') ?? '';
      if (contentType.includes('application/json')) {
        body = await res.json().catch(() => null);
      }

      return {
        name: service.name,
        url: service.url,
        healthy: res.ok,
        status: res.status,
        responseTimeMs: Math.round(elapsed),
        error: res.ok ? null : `HTTP ${res.status}`,
        body,
      };
    } catch (err) {
      const elapsed = performance.now() - start;
      return {
        name: service.name,
        url: service.url,
        healthy: false,
        status: null,
        responseTimeMs: Math.round(elapsed),
        error: (err as Error).message,
        body: null,
      };
    }
  }
}
