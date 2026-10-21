export interface PrometheusResult {
  status: string;
  data: {
    resultType: string;
    result: Array<{
      metric: Record<string, string>;
      value?: [number, string];
      values?: Array<[number, string]>;
    }>;
  };
}

export class PrometheusClient {
  private baseUrl: string;

  constructor(baseUrl: string) {
    this.baseUrl = baseUrl.replace(/\/$/, '');
  }

  async query(expr: string): Promise<PrometheusResult> {
    const url = `${this.baseUrl}/api/v1/query?query=${encodeURIComponent(expr)}`;
    return this.request(url);
  }

  async queryRange(
    expr: string,
    start: number,
    end: number,
    step: string,
  ): Promise<PrometheusResult> {
    const params = new URLSearchParams({
      query: expr,
      start: start.toString(),
      end: end.toString(),
      step,
    });
    const url = `${this.baseUrl}/api/v1/query_range?${params}`;
    return this.request(url);
  }

  async isReachable(): Promise<boolean> {
    try {
      const res = await fetch(`${this.baseUrl}/-/ready`, {
        signal: AbortSignal.timeout(5000),
      });
      return res.ok;
    } catch {
      return false;
    }
  }

  private async request(url: string): Promise<PrometheusResult> {
    const res = await fetch(url, {
      signal: AbortSignal.timeout(10_000),
    });

    if (!res.ok) {
      const text = await res.text().catch(() => '');
      throw new Error(`Prometheus query failed: ${res.status} ${text}`);
    }

    return (await res.json()) as PrometheusResult;
  }
}
