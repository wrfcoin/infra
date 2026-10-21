export interface GrafanaAnnotation {
  text: string;
  tags: string[];
  time?: number;
  timeEnd?: number;
}

export class GrafanaOutput {
  private url: string;
  private apiKey: string;

  constructor(url: string, apiKey: string) {
    this.url = url.replace(/\/$/, '');
    this.apiKey = apiKey;
  }

  isConfigured(): boolean {
    return Boolean(this.url && this.apiKey);
  }

  async annotate(annotation: GrafanaAnnotation): Promise<void> {
    if (!this.isConfigured()) {
      console.warn('[grafana] Not configured, skipping annotation');
      return;
    }

    const body = {
      text: annotation.text,
      tags: annotation.tags,
      time: annotation.time ?? Date.now(),
      timeEnd: annotation.timeEnd,
    };

    const res = await fetch(`${this.url}/api/annotations`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${this.apiKey}`,
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(10_000),
    });

    if (!res.ok) {
      const text = await res.text().catch(() => '');
      throw new Error(`Grafana annotation failed: ${res.status} ${text}`);
    }

    console.log(`[grafana] Annotation created: ${annotation.tags.join(', ')}`);
  }
}
