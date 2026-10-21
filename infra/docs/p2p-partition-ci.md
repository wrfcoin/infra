# P2P Partition CI Gate

This gate adds a small deterministic network-partition regression check for infra CI. It is designed to catch transport-level partition regressions without requiring a full multi-repo chaos stack or manual operator cleanup.

## Entry Point

Run locally:

```bash
bash scripts/run-p2p-partition-ci.sh
```

Run a dry-run that writes the expected reports without touching Docker:

```bash
bash scripts/run-p2p-partition-ci.sh --dry-run
```

CI runs the same wrapper through `.github/workflows/p2p-partition-gate.yml`.

## What The Gate Verifies

The wrapper starts three lightweight peer containers on an isolated Docker network and checks:

1. Baseline connectivity across all peers.
2. Partition enforcement by disconnecting `peer-c` from the network.
3. Recovery by reconnecting `peer-c` and waiting for connectivity to return within a fixed timeout.

The run fails if:

- baseline connectivity never becomes healthy
- the isolated peer is still reachable during the partition window
- recovery does not complete before the timeout
- required logs and summaries cannot be written

## Artifacts

Artifacts are written under `artifacts/p2p-partition/` by default:

- `command-output.txt`: full wrapper stdout/stderr
- `workflow-output.txt`: workflow-level tee log in GitHub Actions
- `preflight.log`: environment and Docker version details
- `docker-ps.log`: final container state snapshot
- `network-inspect.log`: final Docker network inspection
- `cleanup.log`: cleanup actions performed
- `summary.md`: human-readable result summary for local use and `GITHUB_STEP_SUMMARY`
- `summary.json`: machine-readable phase/result output
- per-probe `*.log` files for baseline, partition, and recovery checks

## Dependencies And Assumptions

- Linux host with Docker Engine available to the current user
- ability to pull the configured container image (default `busybox:1.36.1`)
- no host-level `iptables`, `tc`, or privileged network mutation required
- GitHub-hosted runner compatibility through Docker network connect/disconnect only

## Current Limitations

- This is a deterministic transport-partition gate, not a production-faithful libp2p or consensus correctness test.
- The gate validates infra-owned orchestration, failure signaling, and recovery timing around a partition event.
- Full protocol behavior under partition still belongs in deeper cross-repo or protocol-level test suites.
