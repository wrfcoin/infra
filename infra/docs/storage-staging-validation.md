# Storage Stack Staging Validation

This document defines the pre-deployment checklist, validation steps, sign-off criteria,
and rollback procedure for deploying the storage provider stack to staging and production.

---

## Pre-Deployment Checklist

- [ ] All Kubernetes manifests pass `kubectl apply --dry-run=client -f infra/k8s/storage/`
- [ ] Terraform plan shows expected resources: `terraform plan -var-file=staging.tfvars`
- [ ] Container images are pinned to specific versions (no `:latest` tags in production)
- [ ] Secrets template (`secrets.yml`) has been populated with staging credentials
- [ ] Storage class `gp3` (or equivalent) exists in the target cluster
- [ ] Namespace `storage` does not conflict with existing workloads
- [ ] Network policies allow traffic between the backend namespace and `storage` namespace
- [ ] Prometheus is configured to scrape the `storage` namespace (annotation-based discovery)
- [ ] Grafana dashboard JSON (`storage-providers.json`) imports without errors
- [ ] Alert rules (`storage-providers.yml`) load without Prometheus config errors
- [ ] PVC sizes are appropriate for the staging environment (may be smaller than production)
- [ ] Resource requests/limits are appropriate for the staging cluster capacity

---

## Validation Steps

### Step 1: Deploy Namespace and Secrets

```bash
kubectl apply -f infra/k8s/storage/namespace.yml
kubectl apply -f infra/k8s/storage/secrets.yml
```

Verify:
```bash
kubectl get namespace storage
kubectl -n storage get secrets
```

### Step 2: Deploy IPFS

```bash
kubectl apply -f infra/k8s/storage/ipfs-statefulset.yml
kubectl apply -f infra/k8s/storage/ipfs-service.yml
```

Verify:
```bash
# Wait for pods to be ready
kubectl -n storage rollout status statefulset/ipfs --timeout=120s

# Smoke test: check IPFS node identity
kubectl -n storage exec ipfs-0 -- ipfs id

# Smoke test: add and retrieve data
kubectl -n storage exec ipfs-0 -- sh -c 'echo "wrfcoin-staging-test" | ipfs add -q'
# Note the CID, then:
kubectl -n storage exec ipfs-0 -- ipfs cat <CID>
```

### Step 3: Deploy Filecoin Lotus

```bash
kubectl apply -f infra/k8s/storage/filecoin-statefulset.yml
kubectl apply -f infra/k8s/storage/filecoin-service.yml
```

Verify:
```bash
# Wait for pod readiness (may take several minutes for initial sync)
kubectl -n storage rollout status statefulset/filecoin-lotus --timeout=300s

# Check sync status
kubectl -n storage exec filecoin-lotus-0 -- lotus sync status

# Check API availability
kubectl -n storage exec filecoin-lotus-0 -- lotus net id
```

### Step 4: Deploy Arweave Gateway

```bash
kubectl apply -f infra/k8s/storage/arweave-deployment.yml
kubectl apply -f infra/k8s/storage/arweave-service.yml
```

Verify:
```bash
kubectl -n storage rollout status deployment/arweave-gateway --timeout=120s

# Smoke test: check gateway info
kubectl -n storage exec deploy/arweave-gateway -- curl -s http://localhost:1984/info
```

### Step 5: Verify Metrics and Monitoring

```bash
# Check that Prometheus is scraping storage pods
curl -s http://prometheus:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.namespace=="storage")'

# Verify Grafana dashboard loads
# Navigate to Grafana -> Dashboards -> "WRFCoin Storage Providers"

# Verify alert rules are loaded
curl -s http://prometheus:9090/api/v1/rules | jq '.data.groups[] | select(.name=="storage-providers")'
```

### Step 6: End-to-End Integration Test

Run the storage provider integration tests from the backend:

```bash
# From the backend repo
npm run test:integration -- --grep "storage"
```

Or run the storage-providers crate tests (if the storage-providers repo is available):

```bash
cd <repo-root>/storage-providers
cargo test
```

---

## Sign-Off Criteria

All of the following must be true before promoting to production:

| Criterion | Verified |
|-----------|----------|
| All IPFS pods are Ready (3/3) | [ ] |
| IPFS add/cat round-trip succeeds | [ ] |
| Filecoin Lotus pod is Ready and syncing | [ ] |
| Filecoin API responds to JSON-RPC requests | [ ] |
| Arweave gateway pod is Ready | [ ] |
| Arweave /info endpoint returns valid JSON | [ ] |
| Prometheus scrapes all storage pods | [ ] |
| Grafana dashboard renders all 7 panels | [ ] |
| No critical alerts firing in staging | [ ] |
| End-to-end integration tests pass | [ ] |
| Staging has been stable for >= 1 hour | [ ] |

**Sign-off:**

- SRE: __________________ Date: __________
- Backend Lead: __________________ Date: __________

---

## Rollback Procedure

If the deployment fails or causes issues in staging/production:

### Quick Rollback (< 5 minutes)

```bash
# Delete all storage workloads (data on PVCs is preserved)
kubectl delete -f infra/k8s/storage/arweave-deployment.yml
kubectl delete -f infra/k8s/storage/arweave-service.yml
kubectl delete -f infra/k8s/storage/filecoin-statefulset.yml
kubectl delete -f infra/k8s/storage/filecoin-service.yml
kubectl delete -f infra/k8s/storage/ipfs-statefulset.yml
kubectl delete -f infra/k8s/storage/ipfs-service.yml
```

The backend storage router will detect unhealthy providers and stop routing to them. Existing
data remains accessible via any previously cached copies.

### Full Rollback (remove all resources)

```bash
kubectl delete -f infra/k8s/storage/
# Or via Terraform:
terraform destroy -target=kubernetes_namespace.storage
```

**Warning:** Deleting PVCs will destroy stored data. Only delete PVCs if you are certain the
data is recoverable from the network or from database-tracked CIDs.

### Post-Rollback Steps

1. Verify backend services are not returning 5xx errors related to storage.
2. Check that the storage router has marked all providers as unavailable.
3. Investigate root cause before re-deploying.
4. Update this document with any lessons learned.
