// node-cron v4 exports ScheduledTask as a named type; the v3 `cron.ScheduledTask`
// namespace form no longer exists. See infra#751.
import cron, { type ScheduledTask } from 'node-cron';

export type TaskHandler = () => Promise<void>;

interface RegisteredTask {
  name: string;
  schedule: string;
  handler: TaskHandler;
  cronJob: ScheduledTask | null;
  lastRunAt: Date | null;
  lastDurationMs: number;
  runCount: number;
  errorCount: number;
}

export class Scheduler {
  private tasks = new Map<string, RegisteredTask>();
  private running = false;

  registerTask(name: string, handler: TaskHandler, schedule: string): void {
    if (this.tasks.has(name)) {
      console.warn(`[scheduler] Task '${name}' already registered, replacing`);
      this.tasks.get(name)?.cronJob?.stop();
    }

    this.tasks.set(name, {
      name,
      schedule,
      handler,
      cronJob: null,
      lastRunAt: null,
      lastDurationMs: 0,
      runCount: 0,
      errorCount: 0,
    });

    console.log(`[scheduler] Registered task '${name}' (schedule: ${schedule})`);
  }

  start(): void {
    if (this.running) return;
    this.running = true;

    for (const [name, task] of this.tasks) {
      if (task.schedule === 'on-alert') {
        console.log(`[scheduler] Task '${name}' is webhook-triggered (on-alert)`);
        continue;
      }

      if (!cron.validate(task.schedule)) {
        console.error(
          `[scheduler] Invalid cron expression for '${name}': ${task.schedule}`,
        );
        continue;
      }

      task.cronJob = cron.schedule(task.schedule, () => {
        void this.executeTask(name);
      });

      console.log(`[scheduler] Started cron for '${name}': ${task.schedule}`);
    }
  }

  stop(): void {
    this.running = false;
    for (const task of this.tasks.values()) {
      task.cronJob?.stop();
      task.cronJob = null;
    }
    console.log('[scheduler] All tasks stopped');
  }

  async triggerOnAlert(taskName?: string): Promise<void> {
    const targets = taskName
      ? [this.tasks.get(taskName)].filter(Boolean)
      : [...this.tasks.values()].filter((t) => t.schedule === 'on-alert');

    for (const task of targets) {
      if (task) {
        await this.executeTask(task.name);
      }
    }
  }

  getTaskStatus(): Record<
    string,
    {
      schedule: string;
      lastRunAt: string | null;
      lastDurationMs: number;
      runCount: number;
      errorCount: number;
    }
  > {
    const status: Record<string, {
      schedule: string;
      lastRunAt: string | null;
      lastDurationMs: number;
      runCount: number;
      errorCount: number;
    }> = {};

    for (const [name, task] of this.tasks) {
      status[name] = {
        schedule: task.schedule,
        lastRunAt: task.lastRunAt?.toISOString() ?? null,
        lastDurationMs: task.lastDurationMs,
        runCount: task.runCount,
        errorCount: task.errorCount,
      };
    }

    return status;
  }

  private async executeTask(name: string): Promise<void> {
    const task = this.tasks.get(name);
    if (!task) return;

    const start = performance.now();
    console.log(`[scheduler] Executing task '${name}'`);

    try {
      await task.handler();
      task.runCount++;
      task.lastRunAt = new Date();
      task.lastDurationMs = Math.round(performance.now() - start);
      console.log(
        `[scheduler] Task '${name}' completed in ${task.lastDurationMs}ms`,
      );
    } catch (err) {
      task.errorCount++;
      task.runCount++;
      task.lastRunAt = new Date();
      task.lastDurationMs = Math.round(performance.now() - start);
      console.error(
        `[scheduler] Task '${name}' failed: ${(err as Error).message}`,
      );
    }
  }
}
