# Compute Agent Deployment Guide

## Overview

The current WRFCoin compute agent is a lightweight Node.js worker that:

1. registers with the compute contribution API
2. sends heartbeat updates for the registered node
3. polls for available tasks
4. starts one task at a time
5. tracks task status until the task reaches a terminal state
6. exposes a local `/health` endpoint for liveness and readiness checks

The implementation in `infra/compute-agent/src/index.ts` is suitable for a
conservative Kubernetes autoscaling policy, provided the cluster can supply
standard HPA resource metrics.

## Runtime inputs

| Variable | Default | Description |
|----------|---------|-------------|
| `WALLET_ADDRESS` | none | Required wallet address sent to `POST /api/compute/register` |
| `TASK_API_URL` | `http://127.0.0.1:6003` | Compute contribution API base URL |
| `POLL_INTERVAL_MS` | `10000` | Task polling and task status polling interval |
| `HEARTBEAT_INTERVAL_MS` | `30000` | Heartbeat interval |
| `HEALTH_PORT` | `3333` | Health endpoint port |

The agent exits immediately if `WALLET_ADDRESS` is not set or registration
fails.

## Kubernetes autoscaling package

The repo-managed Kubernetes deployment lives under:

```bash
infra/k8s/compute-agent/
```

Apply it separately from the base platform manifests:

```bash
kubectl apply -k infra/k8s/compute-agent/
```

The package includes:

- a dedicated namespace
- a compute-agent deployment
- a health service
- a PodDisruptionBudget
- a HorizontalPodAutoscaler

The base package is intentionally schedulable on general worker capacity. It
does not hard-require a dedicated compute-agent node group.

### Scaling policy

- minimum replicas: `1`
- maximum replicas: `5`
- scale-up signals: CPU `70%` or memory `80%`
- scale-down behavior: 15 minute stabilization, at most 1 pod removed every 5 minutes

This keeps one warm agent online and avoids aggressive scale-down while tasks
may still be active.

### Metrics and cluster dependencies

- The optional Terraform node group for compute agents is controlled by
  `enable_compute_agent_node_group`, `compute_agent_instance_types`,
  `compute_agent_min_size`, `compute_agent_desired_size`, and
  `compute_agent_max_size`.
- The base package does not pin pods to that optional node group. Operators who
  want dedicated placement should add their own selector/affinity overlay once
  the target labels and taints exist in their cluster.
- HPA requires Kubernetes resource metrics, typically from `metrics-server`.
- The repo does not currently install `cluster-autoscaler`; if the deployment
  needs more pods than the existing node pool can fit, cluster capacity must be
  managed separately.
- The repo does not yet expose task backlog or busy/idle state through an
  HPA-consumable custom metrics pipeline, so CPU and memory are the current
  conservative fallback signals.

### Required secret

Create `wrfcoin-compute-agent-secrets` in the `wrfcoin-compute-agent` namespace
with:

- `wallet-address`

Override `TASK_API_URL` from the included `ConfigMap` if the compute
contribution API is not available at the default in-cluster address.

## Validation

Use the repo-native commands that validate the autoscaling assets directly:

```bash
terraform -chdir=infra/terraform fmt -check
terraform -chdir=infra/terraform validate
kubectl kustomize infra/k8s/compute-agent
kubectl apply --dry-run=client -k infra/k8s/compute-agent
```

## Troubleshooting

**Agent exits with "WALLET_ADDRESS is required"**
The Kubernetes secret or container environment is missing `WALLET_ADDRESS`.

**Agent logs "Task API unavailable"**
`TASK_API_URL` does not point at a reachable compute contribution server.

**HPA does not react**
The cluster is likely missing resource metrics collection. Verify
`metrics-server` or the equivalent metrics API is installed and healthy.

**Pods stay Pending during scale-up**
The compute-agent deployment can only grow within existing node capacity unless
cluster-autoscaler is installed and the dedicated compute-agent node group is
enabled.
