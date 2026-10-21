import * as http from 'node:http';

export interface AlertManagerAlert {
  status: 'firing' | 'resolved';
  labels: Record<string, string>;
  annotations: Record<string, string>;
  startsAt: string;
  endsAt: string;
  fingerprint: string;
}

export interface AlertManagerPayload {
  status: string;
  alerts: AlertManagerAlert[];
  groupLabels: Record<string, string>;
  commonLabels: Record<string, string>;
  externalURL: string;
}

export type AlertCallback = (alerts: AlertManagerAlert[]) => void;

export class AlertReceiver {
  private server: http.Server | null = null;
  private onAlerts: AlertCallback;

  constructor(onAlerts: AlertCallback) {
    this.onAlerts = onAlerts;
  }

  async start(port: number = 8090): Promise<number> {
    this.server = http.createServer(async (req, res) => {
      if (req.url === '/alerts' && req.method === 'POST') {
        await this.handleAlerts(req, res);
        return;
      }

      if (req.url === '/health' && req.method === 'GET') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'ok' }));
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
          reject(new Error('Alert receiver did not bind to a TCP port'));
          return;
        }
        console.log(`[alert-receiver] Listening on port ${address.port}`);
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

  private async handleAlerts(
    req: http.IncomingMessage,
    res: http.ServerResponse,
  ): Promise<void> {
    const chunks: Buffer[] = [];
    for await (const chunk of req) {
      chunks.push(chunk as Buffer);
    }

    let payload: AlertManagerPayload;
    try {
      const body = Buffer.concat(chunks).toString('utf-8');
      payload = JSON.parse(body) as AlertManagerPayload;
    } catch {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Invalid JSON payload' }));
      return;
    }

    if (!Array.isArray(payload.alerts)) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Missing alerts array' }));
      return;
    }

    // Return 200 immediately — processing is async
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'accepted', count: payload.alerts.length }));

    if (payload.alerts.length > 0) {
      this.onAlerts(payload.alerts);
    }
  }
}
