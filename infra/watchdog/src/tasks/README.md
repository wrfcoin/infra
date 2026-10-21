# Watchdog Tasks

Individual watchdog tasks are registered via the `Scheduler.registerTask()` API in `src/index.ts`.

## Adding a new task

1. Create a file under `src/tasks/` (e.g., `src/tasks/log-anomaly.ts`)
2. Export a factory function that accepts dependencies (LLM provider, data sources, outputs)
3. Register it in `src/index.ts` using `scheduler.registerTask(name, handler, schedule)`

## Task interface

```typescript
// The handler is a simple async function
type TaskHandler = () => Promise<void>;

// Register with a cron expression or "on-alert" for webhook-triggered
scheduler.registerTask('my-task', handler, '*/5 * * * *');
scheduler.registerTask('alert-task', handler, 'on-alert');
```

## Planned tasks (see GitHub issues)

| Task | Issue | Schedule | Description |
|------|-------|----------|-------------|
| log-anomaly | #86 | `*/5 * * * *` | Scan container logs for anomalies via LLM |
| alert-summary | #87 | `on-alert` | Correlate and summarize active alerts |
| health-digest | #88 | `0 * * * *` | Hourly health digest |
| resource-forecast | #89 | `0 */6 * * *` | Predict resource exhaustion |
| deploy-monitor | #90 | `on-alert` | Monitor deployment rollouts |
| config-drift | #91 | `0 0 * * *` | Detect configuration drift |
| cost-analysis | #92 | `0 6 * * 1` | Weekly infrastructure cost report |
| security-scan | #93 | `0 0 * * *` | Daily security posture check |
