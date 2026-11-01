# WRFCoin Infrastructure

This repository contains the deployment configuration, node-joining tools and monitoring assets for the WRFCoin testnet.

**Running a node? Start with the [node join guide](testnet/JOIN_TESTNET.md).**
It explains the current prerequisites and how to check chain identity, peers and sync progress. Joining as a sync node does not grant a producer or oracle role.

## Public testnet

The public testnet opened on **2026-10-22**.

This is a test network. It may be reset without notice. Balances and tokens have no monetary value. No migration to mainnet is promised or implied. Please attach no production bridges, exchange listings or irreplaceable assets.

[Website](https://wrfcoin.com) ·
[Quickstart](https://github.com/wrfcoin/docs/blob/main/testnet/quickstart.md) ·
[Testnet support](https://github.com/wrfcoin/testnet-support) ·
[Security policy](SECURITY.md)

## Try it

1. Open the [WRFCoin website](https://wrfcoin.com) to watch the chain: block height, the weather map and the block explorer.
2. Follow the [quickstart](https://github.com/wrfcoin/docs/blob/main/testnet/quickstart.md) to set up a wallet and claim testnet WRF from the faucet.
3. Read the [facts page](https://github.com/wrfcoin/docs/blob/main/testnet/facts.md) for what the testnet does and does not offer.
4. To run a sync node, follow the [node join guide](testnet/JOIN_TESTNET.md).
5. Ask for help or report bugs at [testnet-support](https://github.com/wrfcoin/testnet-support); report vulnerabilities privately through the [security policy](SECURITY.md).

## What works today

- Sync-node join tooling and checks for chain identity and sync progress.
- Compose configuration and [public overlay examples](testnet/PUBLIC_DEPLOYMENT_EXAMPLES.md) for operators supplying their own installation settings.
- A documented [public endpoint allowlist](testnet/PUBLIC_ENDPOINTS.md), with route authentication and explicit default-off controls.
- Monitoring configuration and a node-operator dashboard in the monitoring tree.

These are source capabilities. A rendered Compose file or passing local test does not prove a deployed node, successful join, hardware signer, reward payout or delivered alert.

## Planned and current limitations

The join guide needs no invite: a sync-only node dials the public seed pinned in `testnet/cut-pins.env` and needs only outbound connections. The Docker join covers Linux and macOS. On Windows, use the native [Windows node preview 4 installer](https://github.com/wrfcoin/core4/releases/tag/v888-windows-preview-4) (v0.4.0) instead of WSL or Docker; it is an unsigned testnet preview, so Windows SmartScreen warns, and Windows is not yet a validated join platform. A node built from current core4 serves its own dashboard at `http://127.0.0.1:8556/dashboard`; the Windows installer includes it. A passing local test does not prove that any particular join succeeded.

Signed downloadable binaries are not yet published (the Windows installer above is unsigned). Public deployment examples require operator configuration and do not provision signing keys or authorize a producer. Kubernetes and Terraform assets elsewhere in the tree are reference material, not the active testnet deployment path.

## Build and run

Follow the [node join guide](testnet/JOIN_TESTNET.md) for Docker prerequisites, source builds and the supported join procedure. For a deployment configuration review, use the [public overlay examples](testnet/PUBLIC_DEPLOYMENT_EXAMPLES.md); a successful configuration render alone is not permission to deploy.

See [CONTRIBUTING.md](CONTRIBUTING.md) for local validation commands. Use isolated local resources for development.

## Repository map

| Path | Start here for |
| --- | --- |
| [testnet/JOIN_TESTNET.md](testnet/JOIN_TESTNET.md) | Joining and checking a sync node |
| [testnet/PUBLIC_DEPLOYMENT_EXAMPLES.md](testnet/PUBLIC_DEPLOYMENT_EXAMPLES.md) | Portable operator configuration examples |
| [testnet/PUBLIC_ENDPOINTS.md](testnet/PUBLIC_ENDPOINTS.md) | Public edge route contract |
| `testnet/` | Node/service Compose configuration, edge routing and monitoring |
| `scripts/` | Configuration validation and operational tooling; read each tool's prerequisites |
| `infra/monitoring/` | Monitoring and alerting assets |
| `infra/k8s/`, `infra/terraform/` | Reference configurations for other environments |

Contributions follow the [Code of Conduct](CODE_OF_CONDUCT.md). Send vulnerability reports privately using the security policy above.

## License

Licensed under either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.

---

_Note: issue and pull-request numbers mentioned in this repository refer to a private archive that predates this public repository; they are not links into this repo._
