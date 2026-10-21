import { afterEach, describe, it } from 'node:test';
import * as assert from 'node:assert/strict';
import { HealthReporter } from './health.js';

describe('HealthReporter', () => {
  const reporters: HealthReporter[] = [];

  afterEach(async () => {
    while (reporters.length > 0) {
      await reporters.pop()?.stopHealthServer();
    }
  });

  it('serves health JSON and Prometheus metrics', async () => {
    const reporter = new HealthReporter('compute-test');
    reporters.push(reporter);

    const port = await reporter.startHealthServer(0);
    reporter.recordHeartbeat(true);
    reporter.setRunning('task-123');
    reporter.setTaskProgress(42);

    const healthResponse = await fetch(`http://127.0.0.1:${port}/health`);
    assert.equal(healthResponse.status, 200);
    const healthPayload = (await healthResponse.json()) as {
      nodeId: string;
      status: string;
      currentTaskId?: string;
    };
    assert.equal(healthPayload.nodeId, 'compute-test');
    assert.equal(healthPayload.status, 'running');
    assert.equal(healthPayload.currentTaskId, 'task-123');

    let metrics = await fetch(`http://127.0.0.1:${port}/metrics`).then((response) =>
      response.text(),
    );
    assert.match(
      metrics,
      /wrf_compute_agent_status\{node_id="compute-test",status="running"\} 1/,
    );
    assert.match(
      metrics,
      /wrf_compute_agent_task_progress_percent\{node_id="compute-test"\} 42/,
    );

    reporter.recordCompleted(12.5);
    reporter.setIdle();
    metrics = await fetch(`http://127.0.0.1:${port}/metrics`).then((response) =>
      response.text(),
    );
    assert.match(
      metrics,
      /wrf_compute_agent_task_executions_total\{node_id="compute-test",outcome="completed"\} 1/,
    );
    assert.match(
      metrics,
      /wrf_compute_agent_task_execution_duration_seconds_total\{node_id="compute-test",outcome="completed"\} 12\.500/,
    );
    assert.match(
      metrics,
      /wrf_compute_agent_last_heartbeat_success_timestamp_seconds\{node_id="compute-test"\} \d+/,
    );
  });
});
