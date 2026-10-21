# WRFCoin Testnet Getting Started

Use this page if you just cloned `wrfcoin/infra` and want the shortest path to a working testnet node.
For deeper reference, keep [`core4/docs/TESTNET_OPERATOR_GUIDE_v3.md`](https://github.com/wrfcoin/core4/blob/main/docs/TESTNET_OPERATOR_GUIDE_v3.md)
open nearby — that is the current operator guide.

If you are onboarding a household weather contributor rather than a full peer operator, skip to
[`GATEWAY_ONBOARDING.md`](GATEWAY_ONBOARDING.md). This page assumes you are bringing up the node
stack yourself.

If you plan to add Zigbee sensor coverage later, wait until the 3-peer network is stable and read
[`ZIGBEE_GATEWAY.md`](ZIGBEE_GATEWAY.md) before you plug in any coordinator hardware.

## 0. Before you start

Minimum recommended hardware:

- 4 CPU cores
- 16 GB RAM
- 100 GB SSD
- stable broadband plus a way to forward TCP `9000`

You also need:

- Docker Engine 24+
- Docker Compose v2
- `openssl`
- either `htpasswd` or `python3` with `bcrypt` so Prometheus auth can be generated cleanly

## 1. Clone and enter the testnet directory

```bash
git clone https://github.com/wrfcoin/infra.git
cd infra/testnet
```

## 2. Generate local secrets and config

```bash
bash setup-env.sh
```

That creates these files in `testnet/`:

- `.env`
- `prometheus-web.yml`
- `prometheus-bearer-token`
- `alertmanager.rendered.yml`

Save the printed credentials somewhere safe. If `.env` already exists, the script stops instead of overwriting it.
If you change `ALERTMANAGER_WEBHOOK_URL` or the operator email list later, update `.env`
and rerun `bash render-alertmanager-config.sh` so `alertmanager.rendered.yml` stays in sync.

## 3. Set bootstrap peers

```bash
bash check-seeds.sh --print
```

Copy the printed `BOOTSTRAP_PEERS=...` value into `.env`. The expected format is:

```bash
BOOTSTRAP_PEERS=/ip4/<IP>/tcp/<PORT>/p2p/<PEER_ID>,/dns4/<HOSTNAME>/tcp/<PORT>/p2p/<PEER_ID>
```

Use the exact multiaddrs published in `seeds.txt`. Dedicated seed nodes may publish on `9001`
even though regular operator nodes listen on `9000`.

If you are bringing up peer `#313` or `#317`, keep `BOOTSTRAP_PEERS` pointed at the stable
reference/seed nodes and set `WRFCOIN_P2P_EXTERNAL_ADDR` to the machine's own reachable public
multiaddr once TCP `9000` is forwarded.

## 4. Start the stack

Always include `docker-compose.override.yml` — the project is stealth (no public
image registry), so the base compose file alone cannot pull images. The override
redirects every service to a local build, including the maintained faucet under
`services/faucet/`. The obsolete root-level faucet Dockerfile was removed so the
documented and deployed build path cannot drift apart.

```bash
docker compose -f docker-compose.testnet.yml -f docker-compose.override.yml up -d --build
```

Optional profiles:

- `docker compose -f docker-compose.testnet.yml -f docker-compose.override.yml --profile seed up -d --build`
  adds the faucet UI on `http://localhost:8080/faucet`
- `docker compose -f docker-compose.testnet.yml -f docker-compose.override.yml --profile full up -d --build`
  adds the cross-chain, compute, AI/ML, storage, and node-discovery services

On the node host node container path, keep the full profile local-build-only with the
override files and leave state on the named Docker volumes already defined in
the compose stack. After it comes up, run `bash scripts/smoke-full.sh` to probe
the optional full-profile services before treating that surface as healthy.

The main operator-facing ports are:

- `8556` node API
- `4001` backend API
- `4000` wallet
- `8000` governance
- `3002` IoT
- `8001` weather earnings
- `5000` frontend
- `8080` faucet UI
- `9090` Prometheus
- `3100` Grafana
- `9093` Alertmanager
- `9000` P2P listener

AlertManager notifications are rendered from `.env` into
`alertmanager.rendered.yml`. Critical alerts post to `ALERTMANAGER_WEBHOOK_URL`
(default: `http://host.docker.internal:19093/alerts`) and can also email the
operator list in `ALERTMANAGER_OPERATOR_EMAILS`. Warning and info alerts stay
log-only. For a local receiver on the testnet host, run
`python3 alertmanager-webhook-receiver.py --host 0.0.0.0 --port 19093`.

Grafana is prewired on first boot:

- Prometheus and Loki datasources are provisioned automatically
- The home page opens on `Wrfcoin Blockchain Overview`
- The `node-overview`, `infrastructure`, `logs`, and `weather-data` dashboards are mounted read-only

## 5. Quick verification

```bash
bash check-health.sh
```

If you started the optional full profile on node container with the local-build
overrides, follow with:

```bash
bash scripts/smoke-full.sh
```

If you want a manual check, use:

```bash
curl -sf http://localhost:8556/readyz
curl -sf http://localhost:8556/network/info
curl -sf http://localhost:4001/health
docker compose -f docker-compose.testnet.yml ps
```

The node is not really ready until `8556` is healthy and `network/info` shows peers.
When Grafana comes up, open `http://localhost:3100` and confirm you land on the blockchain overview instead of a blank home screen.

## 6. Connect your weather station

Once the node is healthy, submit weather data with the Ambient Weather collector from your core4 checkout:

```bash
AMBIENT_WEATHER_APP_KEY=<key> AMBIENT_WEATHER_API_KEY=<key> \
  WRFCOIN_API_HOST=127.0.0.1 WRFCOIN_API_PORT=8556 \
  node tests/security/fetch-ambient-weather.cjs
```

If you are using a different station type, keep the same node API target and follow the matching collector flow in `core4/docs/TESTNET_OPERATOR_GUIDE_v3.md`.

If you are exploring the experimental radio-weather path instead of a normal station bridge, see
[`SDR_INGEST.md`](SDR_INGEST.md). That path keeps SDR observations separate from peer identity
and stays experimental until the testnet is stable.

If you are helping a household weather contributor, stop here and use
[`GATEWAY_ONBOARDING.md`](GATEWAY_ONBOARDING.md) instead. That path keeps the contributor behind a
gateway/API onboarding flow instead of turning the device into a node operator.

Zigbee sensor gateways are a follow-on path, not part of the initial bootstrap. After the peer
rollout is stable, use [`ZIGBEE_GATEWAY.md`](ZIGBEE_GATEWAY.md) to keep the coordinator host out of
the blockchain peer role.

## 7. Watch the first rewards path

Open Grafana at `http://localhost:3100` and watch:

- `Wrfcoin Blockchain Overview` for block height, peer count, and mempool health
- `WRFCoin Weather Data` for active stations, data quality, and validator participation
- `WRFCoin Infrastructure` for node, backend, and weather-earnings resource health

Those are the quickest signals that your node is alive, your station is contributing, and the reward path is working.

## 8. What next

If the stack is up, move to the operator guide for day-1 tasks like peer management, monitoring, and routine operations.
If anything fails, jump to the [troubleshooting section](https://github.com/wrfcoin/core4/blob/main/docs/TESTNET_OPERATOR_GUIDE_v3.md#troubleshooting)
in `core4/docs/TESTNET_OPERATOR_GUIDE_v3.md` before restarting services.
