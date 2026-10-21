import { describe, it, expect, beforeEach } from 'vitest';
import { Scheduler } from '../src/scheduler.js';

describe('Scheduler', () => {
  let scheduler: Scheduler;

  beforeEach(() => {
    scheduler = new Scheduler();
  });

  it('registers a task', () => {
    scheduler.registerTask('test-task', async () => {}, '*/5 * * * *');
    const status = scheduler.getTaskStatus();
    expect(status['test-task']).toBeDefined();
    expect(status['test-task'].schedule).toBe('*/5 * * * *');
    expect(status['test-task'].runCount).toBe(0);
  });

  it('registers an on-alert task', () => {
    scheduler.registerTask('alert-task', async () => {}, 'on-alert');
    const status = scheduler.getTaskStatus();
    expect(status['alert-task']).toBeDefined();
    expect(status['alert-task'].schedule).toBe('on-alert');
  });

  it('executes task via triggerOnAlert', async () => {
    let executed = false;
    scheduler.registerTask(
      'alert-task',
      async () => {
        executed = true;
      },
      'on-alert',
    );

    await scheduler.triggerOnAlert();
    expect(executed).toBe(true);

    const status = scheduler.getTaskStatus();
    expect(status['alert-task'].runCount).toBe(1);
    expect(status['alert-task'].lastRunAt).not.toBeNull();
  });

  it('executes named task via triggerOnAlert', async () => {
    let task1Executed = false;
    let task2Executed = false;

    scheduler.registerTask(
      'task1',
      async () => {
        task1Executed = true;
      },
      'on-alert',
    );
    scheduler.registerTask(
      'task2',
      async () => {
        task2Executed = true;
      },
      'on-alert',
    );

    await scheduler.triggerOnAlert('task1');
    expect(task1Executed).toBe(true);
    expect(task2Executed).toBe(false);
  });

  it('tracks error count on task failure', async () => {
    scheduler.registerTask(
      'failing-task',
      async () => {
        throw new Error('intentional failure');
      },
      'on-alert',
    );

    await scheduler.triggerOnAlert('failing-task');

    const status = scheduler.getTaskStatus();
    expect(status['failing-task'].runCount).toBe(1);
    expect(status['failing-task'].errorCount).toBe(1);
  });

  it('starts and stops cron tasks', () => {
    scheduler.registerTask('cron-task', async () => {}, '*/1 * * * *');
    scheduler.start();

    const status = scheduler.getTaskStatus();
    expect(status['cron-task']).toBeDefined();

    // Stop should not throw
    scheduler.stop();
  });

  it('handles invalid cron expression gracefully', () => {
    scheduler.registerTask('bad-cron', async () => {}, 'not-a-cron');
    // Should not throw
    scheduler.start();
    scheduler.stop();
  });

  it('replaces existing task with same name', () => {
    let version = 0;
    scheduler.registerTask(
      'dup',
      async () => {
        version = 1;
      },
      'on-alert',
    );
    scheduler.registerTask(
      'dup',
      async () => {
        version = 2;
      },
      'on-alert',
    );

    // Should only have one task
    const status = scheduler.getTaskStatus();
    expect(Object.keys(status)).toHaveLength(1);
  });

  it('gracefully skips when LLM is unavailable', async () => {
    let skipped = false;
    scheduler.registerTask(
      'llm-task',
      async () => {
        // Simulate checking LLM availability
        const llmAvailable = false;
        if (!llmAvailable) {
          skipped = true;
          return;
        }
      },
      'on-alert',
    );

    await scheduler.triggerOnAlert('llm-task');
    expect(skipped).toBe(true);

    const status = scheduler.getTaskStatus();
    expect(status['llm-task'].runCount).toBe(1);
    expect(status['llm-task'].errorCount).toBe(0);
  });
});
