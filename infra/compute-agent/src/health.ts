import * as os from 'node:os';
import * as http from 'node:http';

type AgentState = 'idle' | 'running' | 'error';
type TaskOutcome = 'completed' | 'failed';

export interface NodeStatus {
  nodeId: string;
  status: AgentState;
  currentTaskId?: string;
  cpuUsage?: number;
  memoryUsageMb?: number;
  diskUsageGb?: number;
  uptime: number;
  tasksCompleted: number;
  tasksFailed: number;
}

export class HealthReporter {
  private nodeId: string;
  private startTime: number;
  private _status: AgentState = 'idle';
  private _currentTaskId?: string;
  private _tasksCompleted: number = 0;
  private _tasksFailed: number = 0;
  private _taskProgressPercent: number = 0;
  private _heartbeatFailures: number = 0;
  private _lastHeartbeatSuccessTimestampSeconds: number = 0;
  private _taskExecutions: Record<TaskOutcome, number> = {
    completed: 0,
    failed: 0,
  };
  private _taskDurationSecondsTotal: Record<TaskOutcome, number> = {
    completed: 0,
    failed: 0,
  };
  private _lastTaskDurationSeconds: number = 0;
  private server: http.Server | null = null;

  constructor(nodeId: string) {
    this.nodeId = nodeId;
    this.startTime = Date.now();
  }

  setRunning(taskId: string): void {
    this._status = 'running';
    this._currentTaskId = taskId;
    this._taskProgressPercent = 0;
  }

  setIdle(): void {
    this._status = 'idle';
    this._currentTaskId = undefined;
    this._taskProgressPercent = 0;
  }

  setError(): void {
    this._status = 'error';
  }

  setTaskProgress(progressPercent: number): void {
    this._taskProgressPercent = Math.max(0, Math.min(100, progressPercent));
  }

  recordHeartbeat(success: boolean): void {
    if (success) {
      this._lastHeartbeatSuccessTimestampSeconds = Math.floor(Date.now() / 1000);
      return;
    }

    this._heartbeatFailures++;
  }

  recordCompleted(durationSeconds: number = 0): void {
    this._tasksCompleted++;
    this._recordTaskOutcome('completed', durationSeconds);
  }

  recordFailed(durationSeconds: number = 0): void {
    this._tasksFailed++;
    this._recordTaskOutcome('failed', durationSeconds);
  }

  private _recordTaskOutcome(
    outcome: TaskOutcome,
    durationSeconds: number,
  ): void {
    const normalizedDuration = Math.max(0, durationSeconds);
    this._taskExecutions[outcome]++;
    this._taskDurationSecondsTotal[outcome] += normalizedDuration;
    this._lastTaskDurationSeconds = normalizedDuration;
  }

  getStatus(): NodeStatus {
    const totalMem = os.totalmem();
    const freeMem = os.freemem();
    const usedMemMb = Math.round((totalMem - freeMem) / (1024 * 1024));

    // CPU usage: average load over 1 minute, normalized to number of CPUs
    const cpus = os.cpus().length;
    const load1 = os.loadavg()[0];
    const cpuUsage = Math.round((load1 / cpus) * 100);

    return {
      nodeId: this.nodeId,
      status: this._status,
      currentTaskId: this._currentTaskId,
      cpuUsage,
      memoryUsageMb: usedMemMb,
      uptime: Math.round((Date.now() - this.startTime) / 1000),
      tasksCompleted: this._tasksCompleted,
      tasksFailed: this._tasksFailed,
    };
  }

  getMetrics(): string {
    const status = this.getStatus();
    const baseLabels = { node_id: status.nodeId };
    const lines: string[] = [];

    appendMetric(
      lines,
      'wrf_compute_agent_up',
      'gauge',
      'Whether the compute agent is healthy enough to accept work.',
      [
        {
          labels: baseLabels,
          value: status.status === 'error' ? 0 : 1,
        },
      ],
    );
    appendMetric(
      lines,
      'wrf_compute_agent_status',
      'gauge',
      'Current compute agent state as one-hot status labels.',
      [
        {
          labels: { ...baseLabels, status: 'idle' },
          value: status.status === 'idle' ? 1 : 0,
        },
        {
          labels: { ...baseLabels, status: 'running' },
          value: status.status === 'running' ? 1 : 0,
        },
        {
          labels: { ...baseLabels, status: 'error' },
          value: status.status === 'error' ? 1 : 0,
        },
      ],
    );
    appendMetric(
      lines,
      'wrf_compute_agent_running',
      'gauge',
      'Whether the compute agent is currently running a task.',
      [
        {
          labels: baseLabels,
          value: status.status === 'running' ? 1 : 0,
        },
      ],
    );
    appendMetric(
      lines,
      'wrf_compute_agent_cpu_usage_percent',
      'gauge',
      'Approximate compute agent CPU usage percent based on normalized load average.',
      [
        {
          labels: baseLabels,
          value: status.cpuUsage ?? 0,
        },
      ],
    );
    appendMetric(
      lines,
      'wrf_compute_agent_memory_usage_megabytes',
      'gauge',
      'Approximate compute agent memory usage in megabytes.',
      [
        {
          labels: baseLabels,
          value: status.memoryUsageMb ?? 0,
        },
      ],
    );
    appendMetric(
      lines,
      'wrf_compute_agent_uptime_seconds',
      'gauge',
      'Compute agent uptime in seconds.',
      [
        {
          labels: baseLabels,
          value: status.uptime,
        },
      ],
    );
    appendMetric(
      lines,
      'wrf_compute_agent_tasks_completed_total',
      'counter',
      'Total number of tasks completed by the compute agent.',
      [
        {
          labels: baseLabels,
          value: status.tasksCompleted,
        },
      ],
    );
    appendMetric(
      lines,
      'wrf_compute_agent_tasks_failed_total',
      'counter',
      'Total number of tasks failed by the compute agent.',
      [
        {
          labels: baseLabels,
          value: status.tasksFailed,
        },
      ],
    );
    appendMetric(
      lines,
      'wrf_compute_agent_task_executions_total',
      'counter',
      'Task execution outcomes emitted by the compute agent.',
      [
        {
          labels: { ...baseLabels, outcome: 'completed' },
          value: this._taskExecutions.completed,
        },
        {
          labels: { ...baseLabels, outcome: 'failed' },
          value: this._taskExecutions.failed,
        },
      ],
    );
    appendMetric(
      lines,
      'wrf_compute_agent_task_execution_duration_seconds_total',
      'counter',
      'Cumulative task execution duration by outcome.',
      [
        {
          labels: { ...baseLabels, outcome: 'completed' },
          value: this._taskDurationSecondsTotal.completed,
        },
        {
          labels: { ...baseLabels, outcome: 'failed' },
          value: this._taskDurationSecondsTotal.failed,
        },
      ],
    );
    appendMetric(
      lines,
      'wrf_compute_agent_last_task_duration_seconds',
      'gauge',
      'Duration in seconds of the last finished task.',
      [
        {
          labels: baseLabels,
          value: this._lastTaskDurationSeconds,
        },
      ],
    );
    appendMetric(
      lines,
      'wrf_compute_agent_task_progress_percent',
      'gauge',
      'Progress percentage for the current task, or zero when idle.',
      [
        {
          labels: baseLabels,
          value: this._taskProgressPercent,
        },
      ],
    );
    appendMetric(
      lines,
      'wrf_compute_agent_heartbeat_failures_total',
      'counter',
      'Total number of heartbeat failures observed by the compute agent.',
      [
        {
          labels: baseLabels,
          value: this._heartbeatFailures,
        },
      ],
    );
    appendMetric(
      lines,
      'wrf_compute_agent_last_heartbeat_success_timestamp_seconds',
      'gauge',
      'Unix timestamp of the most recent successful heartbeat.',
      [
        {
          labels: baseLabels,
          value: this._lastHeartbeatSuccessTimestampSeconds,
        },
      ],
    );

    return `${lines.join('\n')}\n`;
  }

  /**
   * Start health and Prometheus endpoints on the given port.
   * Returns the actual listening port, which is useful for tests when `port=0`.
   */
  async startHealthServer(port: number = 3333): Promise<number> {
    this.server = http.createServer((req, res) => {
      if (req.url === '/health' && req.method === 'GET') {
        const status = this.getStatus();
        const httpStatus = status.status === 'error' ? 503 : 200;
        res.writeHead(httpStatus, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(status));
        return;
      }

      if (req.url === '/metrics' && req.method === 'GET') {
        res.writeHead(200, {
          'Content-Type': 'text/plain; version=0.0.4; charset=utf-8',
        });
        res.end(this.getMetrics());
        return;
      }

      res.writeHead(404);
      res.end('Not Found');
    });

    return await new Promise<number>((resolve, reject) => {
      this.server?.once('error', reject);
      this.server?.listen(port, () => {
        const address = this.server?.address();
        if (!address || typeof address === 'string') {
          reject(new Error('Health endpoint did not expose a TCP port'));
          return;
        }

        console.log(`[health] Health endpoint listening on port ${address.port}`);
        resolve(address.port);
      });
    });
  }

  async stopHealthServer(): Promise<void> {
    if (!this.server) {
      return;
    }

    const server = this.server;
    this.server = null;

    await new Promise<void>((resolve, reject) => {
      server.close((error) => {
        if (error) {
          reject(error);
          return;
        }

        resolve();
      });
    });
  }
}

interface MetricSample {
  labels: Record<string, string>;
  value: number;
}

function appendMetric(
  lines: string[],
  name: string,
  type: 'counter' | 'gauge',
  help: string,
  samples: MetricSample[],
): void {
  lines.push(`# HELP ${name} ${help}`);
  lines.push(`# TYPE ${name} ${type}`);
  for (const sample of samples) {
    lines.push(`${name}${formatLabels(sample.labels)} ${formatValue(sample.value)}`);
  }
}

function formatLabels(labels: Record<string, string>): string {
  const entries = Object.entries(labels);
  if (entries.length === 0) {
    return '';
  }

  const formatted = entries
    .map(([key, value]) => `${key}="${escapeLabelValue(value)}"`)
    .join(',');
  return `{${formatted}}`;
}

function escapeLabelValue(value: string): string {
  return value.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');
}

function formatValue(value: number): string {
  if (!Number.isFinite(value)) {
    return '0';
  }

  return Number.isInteger(value) ? value.toString() : value.toFixed(3);
}
