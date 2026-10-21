# WRFCoin Compute Agent

Registers a local compute node with the compute contribution server, sends
heartbeats, polls for available work, starts one compute task at a time, and
tracks task progress through the backend status endpoint.

## Contract

The agent is aligned to `backend/server/compute_contribution_server.js` on
port `6003` and uses these endpoints:

- `POST /api/compute/register`
- `POST /api/compute/heartbeat`
- `GET /api/compute/tasks/available/:nodeId`
- `POST /api/compute/tasks/start`
- `GET /api/compute/tasks/:taskId/status`

The backend assigns the authoritative `nodeId` during registration. The agent
reuses that `nodeId` for heartbeat, task polling, task start, and status
tracking.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WALLET_ADDRESS` | none | Required wallet address sent to `POST /api/compute/register` |
| `TASK_API_URL` | `http://127.0.0.1:6003` | Compute contribution API base URL |
| `POLL_INTERVAL_MS` | `10000` | Task polling and status polling interval |
| `HEARTBEAT_INTERVAL_MS` | `30000` | Heartbeat interval |
| `HEALTH_PORT` | `3333` | Health endpoint port |

## Run

```bash
WALLET_ADDRESS=wrf717d72395303fcb2aed4df368f32f1078d18e9cc npm run dev
```

The agent exits immediately if `WALLET_ADDRESS` is not set or registration
fails.

## Lifecycle

1. Register once with `POST /api/compute/register`.
2. Start the local `/health` endpoint.
3. Send periodic heartbeats to `POST /api/compute/heartbeat`.
4. Poll `GET /api/compute/tasks/available/:nodeId`.
5. Start the best available task through `POST /api/compute/tasks/start`.
6. Poll `GET /api/compute/tasks/:taskId/status` until the task reaches a
   terminal status.

Task completion is backend-managed by the compute contribution server. The
agent no longer uses the legacy claim, complete, fail, or abandon endpoints.

## Validation

Build and run the package checks:

```bash
npm run build
node --import tsx --test src/*.test.ts
```

To verify against a local backend, start `compute_contribution_server.js` on
`127.0.0.1:6003`, run the agent with `WALLET_ADDRESS` set, and confirm:

- registration succeeds and logs a backend-issued `nodeId`
- heartbeat requests do not return `404`
- available-task polling does not return `404`
- one task is started through `/api/compute/tasks/start`
- the started task is observed through `/api/compute/tasks/:taskId/status`
