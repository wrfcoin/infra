# Compute-Agent Kubernetes Autoscaling

This package is the repo-managed Kubernetes path for scaling the current
`infra/compute-agent` service.

The base package is intentionally schedulable on general worker capacity. It
does not hard-require a dedicated compute-agent node group.

Apply it separately from `infra/k8s/base/`:

```bash
kubectl apply -k infra/k8s/compute-agent/
```

## Runtime inputs

Create a secret named `wrfcoin-compute-agent-secrets` in the
`wrfcoin-compute-agent` namespace with:

- `wallet-address`

The included `ConfigMap` sets:

- `TASK_API_URL=http://wrfcoin-compute-contribution.default.svc.cluster.local:6003`
- `POLL_INTERVAL_MS=10000`
- `HEARTBEAT_INTERVAL_MS=30000`
- `HEALTH_PORT=3333`

Override `TASK_API_URL` if the compute contribution server lives elsewhere.

## Scaling policy

- `minReplicas: 1`
- `maxReplicas: 5`
- scale up when CPU stays above `70%` or memory stays above `80%`
- scale down no faster than 1 pod every 5 minutes, with a 15 minute
  stabilization window

The pod template is annotated with
`cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` so future
cluster-autoscaler deployments do not aggressively drain agents.

## Dependencies and gaps

- The optional Terraform node group for this workload is controlled by
  `enable_compute_agent_node_group`, `compute_agent_instance_types`,
  `compute_agent_min_size`, `compute_agent_desired_size`, and
  `compute_agent_max_size`.
- The base package does not pin pods to that optional node group. Operators who
  want dedicated placement should add their own selector/affinity overlay once
  the target labels and taints exist in their cluster.
- The cluster must expose Kubernetes resource metrics for HPA
  (typically via `metrics-server`).
- The repo does not currently install `cluster-autoscaler`, so pod growth above
  existing node capacity still requires separate cluster setup.
- The repo does not yet provide an HPA-consumable task backlog or busy/idle
  metric. The HPA therefore uses CPU and memory as the conservative fallback.

## Validation

```bash
kubectl kustomize infra/k8s/compute-agent
kubectl apply --dry-run=client -k infra/k8s/compute-agent
```
