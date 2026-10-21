# Post33000 observation (Refs infra#1235)

Off by default: standalone testnet/docker-compose.post33000-monitor.yml requires profile post33000-monitor.
No node/attester dependency or exporter is added; existing native height and faucet balance metrics are reused.
Owner alone stages a cached Prometheus image, mode0600 Reader token file outside the repo and reviewed config.
The four example loopback ports are placeholders, not live defaults. Map them to already approved owner tunnels.
Keep the metric jobs' exact ws/mango/n5/faucet labels; distinct node targets are mandatory. Confirm the same credential
is accepted by all four /metrics endpoints, or stage a separately reviewed per-job credential adaptation.
Never print credentials, token files, headers or env. The observer has no Docker socket or remote-shell access.

Enable only after the approved activation-check-0410 returns ACTIVATION_OK and the owner verifies E0f binding/ACTIVE.
Height alone does not prove ACTIVE. Stop this observer during activation, W27, owner acceptance or bulk audits to
avoid competing node reads. Scrapes are spaced90s (three node /metrics reads and one faucet metric read per cycle).
No block scan or additional /addresses polling is added; the existing faucet service owns its balance refresh.

FaucetNetFundingStalled observes a30-minute window, all three nodes beyond33000 at its start and each net tip advance
>=N=20. It fires on nonpositive net faucet balance change and requires four healthy scrapes plus successful balance
refresh through the window. It deliberately compares NET balance: claims may offset emissions and trigger an alert.
Investigate claim outflow versus funding before asserting a minting failure. It cannot prove every intra-window
increment or detect a stall shorter than30min; sparse/stale samples and reorgs require owner investigation.
The existing balance gauge uses floating-point Prometheus representation; it is not an exact base-unit receipt.
ThreeNodeTipsDiverged fires at spread>20 (20 is allowed) only when exactly3 node gauges and3 healthy scrapes exist.
Unavailable/missing targets get a separate observation alert rather than a false convergence claim.

The independent Prometheus UI binds only127.0.0.1:9097. Its example Alertmanager target127.0.0.1:9093 is owner-reviewed
routing input, not proof of a listening receiver. Verify actual receiver delivery and its heartbeat before relying
on pages. No runtime monitor, tunnel, receiver, token or host operation was executed by this lane.
No automatic boot wiring is added. Dropping a profile does not stop an existing observer; owner stops it separately.
Tests evaluate the real PromQL with promtool and synthetic series; no mock evaluator substitutes for Prometheus.

"No alert" is never evidence of health: a dead Prometheus cannot evaluate or send its own alert. The independent
external host-job heartbeat/receiver is the only detector of observer failure; verify that path before relying on pages.
