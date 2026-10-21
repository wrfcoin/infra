import * as http from 'node:http';

export interface ContainerInfo {
  Id: string;
  Names: string[];
  State: string;
}

export interface DockerLogResult {
  containerId: string;
  containerName: string;
  logs: string;
}

export interface PrioritizedLogResult extends DockerLogResult {
  lineCount: number;
  errorLines: number;
  warnLines: number;
}

export interface LogCollectionOptions {
  windowMinutes?: number;
  maxLogLines?: number;
  noiseFilters?: string[];
  containers?: string[];
}

export class DockerLogSource {
  private socketPath: string;
  private containerPrefix: string;
  private logWindowMinutes: number;

  constructor(
    socketPath: string,
    containerPrefix: string,
    logWindowMinutes: number,
  ) {
    this.socketPath = socketPath;
    this.containerPrefix = containerPrefix;
    this.logWindowMinutes = logWindowMinutes;
  }

  async collectLogsWithBudget(
    options: LogCollectionOptions = {},
  ): Promise<PrioritizedLogResult[]> {
    const windowMinutes = options.windowMinutes ?? this.logWindowMinutes;
    const maxLogLines = options.maxLogLines ?? 500;
    const noiseFilters = (options.noiseFilters ?? []).map(
      (pattern) => new RegExp(pattern, 'i'),
    );
    const containerFilter = options.containers ?? ['*'];

    const containers = await this.listContainers();
    const filtered = containerFilter.includes('*')
      ? containers
      : containers.filter((c) =>
          c.Names.some((n) =>
            containerFilter.some((f) => n.replace(/^\//, '').includes(f)),
          ),
        );

    const results: PrioritizedLogResult[] = [];
    let totalLines = 0;

    for (const container of filtered) {
      if (totalLines >= maxLogLines) break;

      try {
        const since = Math.floor(Date.now() / 1000) - windowMinutes * 60;
        const path = `/containers/${container.Id}/logs?stdout=true&stderr=true&since=${since}&timestamps=true`;
        const rawLogs = await this.dockerRequest<string>(path, true);

        const lines = rawLogs.split('\n').filter((l) => l.trim());

        // Apply noise filters
        const cleaned = lines.filter(
          (line) => !noiseFilters.some((re) => re.test(line)),
        );

        // Separate by priority
        const errorLines: string[] = [];
        const warnLines: string[] = [];
        const infoLines: string[] = [];

        for (const line of cleaned) {
          const lower = line.toLowerCase();
          if (
            lower.includes('error') ||
            lower.includes('fatal') ||
            lower.includes('panic') ||
            lower.includes('oom') ||
            lower.includes('crash')
          ) {
            errorLines.push(line);
          } else if (
            lower.includes('warn') ||
            lower.includes('timeout') ||
            lower.includes('retry')
          ) {
            warnLines.push(line);
          } else {
            infoLines.push(line);
          }
        }

        // Budget: error first, then warn, then info
        const budget = maxLogLines - totalLines;
        const prioritized: string[] = [];
        for (const bucket of [errorLines, warnLines, infoLines]) {
          const remaining = budget - prioritized.length;
          if (remaining <= 0) break;
          prioritized.push(...bucket.slice(0, remaining));
        }

        if (prioritized.length > 0) {
          const containerName =
            container.Names[0]?.replace(/^\//, '') ??
            container.Id.slice(0, 12);

          results.push({
            containerId: container.Id.slice(0, 12),
            containerName,
            logs: prioritized.join('\n'),
            lineCount: prioritized.length,
            errorLines: Math.min(errorLines.length, budget),
            warnLines: Math.min(
              warnLines.length,
              Math.max(0, budget - errorLines.length),
            ),
          });

          totalLines += prioritized.length;
        }
      } catch (err) {
        console.warn(
          `[docker] Failed to read logs from ${container.Id.slice(0, 12)}: ${(err as Error).message}`,
        );
      }
    }

    return results;
  }

  async collectLogs(): Promise<DockerLogResult[]> {
    const containers = await this.listContainers();
    const results: DockerLogResult[] = [];

    for (const container of containers) {
      try {
        const logs = await this.getContainerLogs(container.Id);
        const filtered = this.filterHealthCheckNoise(logs);
        if (filtered.trim()) {
          results.push({
            containerId: container.Id.slice(0, 12),
            containerName: container.Names[0]?.replace(/^\//, '') ?? container.Id.slice(0, 12),
            logs: filtered,
          });
        }
      } catch (err) {
        console.warn(
          `[docker] Failed to read logs from ${container.Id.slice(0, 12)}: ${(err as Error).message}`,
        );
      }
    }

    return results;
  }

  private async listContainers(): Promise<ContainerInfo[]> {
    const data = await this.dockerRequest<ContainerInfo[]>(
      '/containers/json?all=false',
    );
    return data.filter((c) =>
      c.Names.some((n) => n.replace(/^\//, '').startsWith(this.containerPrefix)),
    );
  }

  private async getContainerLogs(containerId: string): Promise<string> {
    const since = Math.floor(Date.now() / 1000) - this.logWindowMinutes * 60;
    const path = `/containers/${containerId}/logs?stdout=true&stderr=true&since=${since}&timestamps=true`;
    return this.dockerRequest<string>(path, true);
  }

  private filterHealthCheckNoise(logs: string): string {
    return logs
      .split('\n')
      .filter((line) => {
        const lower = line.toLowerCase();
        return (
          !lower.includes('health') ||
          lower.includes('error') ||
          lower.includes('fail') ||
          lower.includes('unhealthy')
        );
      })
      .join('\n');
  }

  private dockerRequest<T>(path: string, raw?: boolean): Promise<T> {
    return new Promise((resolve, reject) => {
      const req = http.request(
        {
          socketPath: this.socketPath,
          path,
          method: 'GET',
          headers: { 'Content-Type': 'application/json' },
        },
        (res) => {
          const chunks: Buffer[] = [];
          res.on('data', (chunk: Buffer) => chunks.push(chunk));
          res.on('end', () => {
            const body = Buffer.concat(chunks).toString('utf-8');
            if (res.statusCode && res.statusCode >= 400) {
              reject(new Error(`Docker API ${res.statusCode}: ${body.slice(0, 200)}`));
              return;
            }
            if (raw) {
              resolve(body as unknown as T);
            } else {
              try {
                resolve(JSON.parse(body) as T);
              } catch {
                reject(new Error(`Invalid JSON from Docker API: ${body.slice(0, 200)}`));
              }
            }
          });
        },
      );

      req.on('error', reject);
      req.setTimeout(10_000, () => {
        req.destroy(new Error('Docker API request timed out'));
      });
      req.end();
    });
  }
}
