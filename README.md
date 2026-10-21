# WRFCoin Infrastructure

This repository contains the deployment configuration, node-joining tools and monitoring assets for the WRFCoin testnet.

**Running a node? Start with the [node join guide](testnet/JOIN_TESTNET.md).**
It explains the current prerequisites and how to check chain identity, peers and sync progress. Joining as a sync node does not grant a producer or oracle role.

## Public testnet

Public launch target: **Thursday, 2026-10-22, around 19:00 UTC**.

This is a test network. It may be reset without notice. Balances and tokens have no monetary value. No migration to mainnet is promised or implied. Please attach no production bridges, exchange listings or irreplaceable assets.

[Website](https://wrfcoin.com) ·
[Quickstart](https://github.com/wrfcoin/docs/blob/main/testnet/quickstart.md) ·
[Testnet support](https://github.com/wrfcoin/testnet-support) ·
[Security policy](SECURITY.md)

## What works today

- Sync-node join tooling and checks for chain identity and sync progress.
- Compose configuration and [public overlay examples](testnet/PUBLIC_DEPLOYMENT_EXAMPLES.md) for operators supplying their own installation settings.
- A documented [public endpoint allowlist](testnet/PUBLIC_ENDPOINTS.md), with route authentication and explicit default-off controls.
- Monitoring configuration and a node-operator dashboard in the monitoring tree.

These are source capabilities. A rendered Compose file or passing local test does not prove a deployed node, successful join, hardware signer, reward payout or delivered alert.

## Planned and current limitations

Public internet peering without an invite is targeted for launch. The join guide on current main still documents the invite-based path; use only a bootstrap address published by the operators and check the latest guide before joining. Public peering is not claimed operational here.

Signed downloadable binaries are not yet published. Public deployment examples require operator configuration and do not provision signing keys or authorize a producer. Kubernetes and Terraform assets elsewhere in the tree are reference material, not the active testnet deployment path.

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
