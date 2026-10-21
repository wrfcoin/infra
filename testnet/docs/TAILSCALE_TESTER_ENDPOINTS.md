# WRFCoin Testnet — Tailscale Tester Endpoints

> Canonical reachability doc for the June 17 testnet (issues #552 and #557).
> Testers reach the testnet **over Tailscale** — not the public internet, not the home LAN.

## How testers connect

1. **Join the tailnet.** Install Tailscale and run `tailscale up`, then accept the invite the
   operator sent you. Until you are on the tailnet, none of the URLs below resolve.
2. **Use the endpoints below.** Replace `<CT101_TAILNET_IP>` with `<CT101 tailnet IPv4 — run
   tailscale ip -4 inside the testnet container>`. Do not use the Proxmox host's address.
   The generated source-of-truth table is [PUBLIC_ENDPOINTS.md](../PUBLIC_ENDPOINTS.md).

## Endpoints

| Service | URL | What it's for |
|---------|-----|---------------|
| **Block explorer** | not exposed directly; use the internal tailnet gateway route if the operator enables it | Browse blocks, txs, and chain state |
| **Frontend dashboard** | not published | Operator-only via SSH tunnel |
| **Faucet** | `http://<CT101_TAILNET_IP>:8080` once the operator sets `FAUCET_TAILNET_BIND_ADDR` (#588); not published by default | Claim test WRF — see JOIN_TESTNET.md "Getting test WRF" |
| **Backend REST API** | not published | Operator-only via SSH tunnel |
| **Node API (RPC)** | not published | Operator-only via SSH tunnel |

The P2P bootstrap multiaddr (port 9000) is published separately by the operator and is the only
publicly reachable port; it is not part of the tailnet-only HTTP surface above.

Operator/metrics dashboards (Prometheus :9090, Grafana :3100, Alertmanager :9093, exporters) are
**not** exposed over the tailnet — they stay on loopback and require an SSH tunnel
(`testnet/tunnel.sh`).

Do not use `docker-compose.lan.yml` or `expose-lan.sh` to publish node/backend services for
the tailnet launch. The LAN overlay is explorer-only.

## Operator setup (N5 / CT 101)

The tailnet bind is opt-in via a single env var. On the host, inside CT 101:

```bash
tailscale ip -4                 # run inside CT101; use the returned IPv4
cd /path/to/infra/testnet
echo 'TESTNET_TAILNET_BIND_ADDR=<CT101_TAILNET_IP>' >> .env

# Redeploy with the 3-file stack (LOCAL build only — never push images):
docker compose -f docker-compose.testnet.yml \
  -f docker-compose.override.yml \
  -f docker-compose.local-paths.yml up -d
```

- Default (`TESTNET_TAILNET_BIND_ADDR` unset or `127.0.0.1`): all HTTP services stay loopback.
- The explorer direct port is not part of the current tester surface; use the generated endpoint table.
- **Faucet is a separate opt-in**: set `FAUCET_TAILNET_BIND_ADDR` to the tailnet IP and
  recreate the faucet container (seed profile) to let testers claim test WRF (#588). Exposing the
  explorer never implicitly exposes the faucet, and vice versa (smoke checks C4/C4b).
- Never set either var to `0.0.0.0` — that would expose the services to every interface,
  including any public one.
- `WRFCOIN_BACKEND_BIND_ADDR` (#546) is a per-service operator override for the backend only;
  it is not part of the tester launch path.

Verify the bindings after redeploy:

```bash
docker compose -f docker-compose.testnet.yml ps --format '{{.Service}}\t{{.Ports}}'
# Expect 0.0.0.0:9000; node/backend/frontend/monitoring on 127.0.0.1.
# Faucet: 127.0.0.1:8080 by default, 100.x.y.z:8080 once FAUCET_TAILNET_BIND_ADDR is set.
```

See `core4/docs/TESTNET_OPERATOR_GUIDE_v3.md` → "Tailscale reachability for testers" for the full
operator reference (canonical; `testnet/TESTNET_OPERATOR_GUIDE.md` in this repo is retired).
