# backend#1234 health response fixtures

Captured on 2026-09-26 from **real backend code**. The source was the
`wrfcoin/backend` PR #1234 head `fd1cc6fd` (branch `tony/1224-operator-gated-probes`).
No values are hand-written.

| file | how it was produced |
|---|---|
| `governance-authenticated.json` | `createHealthMiddleware('governance-server', {database: {critical: false, check: () => ({status: 'up', mode: 'connected'})}})`. This is the governance server's own dependency shape. `healthHandler` was called with `Authorization: Bearer <WRFCOIN_READER_TOKEN>`. |
| `governance-anonymous.json` | Same middleware, no Authorization header. |
| `backend-authenticated-503.json` | Real `server/enhanced_unified_api_optimized.ts` booted with `node --import tsx`, with Postgres, Redis and core4 on dead ports. `GET /health` was sent with `Authorization: Bearer <WRFCOIN_READER_TOKEN>`. |
| `backend-anonymous-503.json` | Same boot, `GET /health` with no Authorization header. |

After backend#1234, anonymous callers receive only `{status, timestamp}`, plus
`success` on the backend's `/health`. Authenticated callers (operator or reader
bearer) receive the unchanged detailed contract that `validate-health-payload.py`,
the governance container healthcheck and `preflight-compose-smoke.sh` check.
