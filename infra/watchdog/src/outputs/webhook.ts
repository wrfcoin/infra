export interface WebhookPayload {
  task: string;
  severity: string;
  timestamp: string;
  summary: string;
  details: unknown;
}

export class WebhookOutput {
  private url: string | null;

  constructor(url: string | null) {
    this.url = url;
  }

  isConfigured(): boolean {
    return Boolean(this.url);
  }

  async send(payload: WebhookPayload): Promise<void> {
    if (!this.url) {
      return;
    }

    const res = await fetch(this.url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(10_000),
    });

    if (!res.ok) {
      const text = await res.text().catch(() => '');
      throw new Error(`Webhook failed: ${res.status} ${text}`);
    }

    console.log(`[webhook] Sent: ${payload.task} (${payload.severity})`);
  }
}
