# Incident Response Runbook

## Severity Levels

| Level | Name | Definition | Response Time | Examples |
|-------|------|-----------|---------------|----------|
| SEV1 | Critical | Complete platform outage or data loss risk | 15 min | All nodes down, DB corruption, security breach |
| SEV2 | Major | Significant feature degradation | 30 min | Consensus stalled, API gateway down, bridge halted |
| SEV3 | Minor | Degraded performance or partial outage | 2 hours | High latency, single node down, cache failure |
| SEV4 | Low | Cosmetic or non-urgent issues | Next business day | Dashboard glitch, log noise, non-critical alert |

---

## Incident Workflow

```
    ┌──────────────┐
    │  Alert Fires │
    └──────┬───────┘
           │
    ┌──────▼───────┐
    │  1. Triage   │  Assess severity, assign incident commander
    └──────┬───────┘
           │
    ┌──────▼───────┐
    │  2. Mitigate │  Stop the bleeding (failover, scale, restart)
    └──────┬───────┘
           │
    ┌──────▼───────┐
    │  3. Diagnose │  Root cause analysis
    └──────┬───────┘
           │
    ┌──────▼───────┐
    │  4. Fix      │  Deploy fix or rollback
    └──────┬───────┘
           │
    ┌──────▼───────┐
    │  5. Verify   │  Confirm resolution, close alert
    └──────┬───────┘
           │
    ┌──────▼───────┐
    │ 6. Postmortem│  Document, action items, prevent recurrence
    └──────────────┘
```

---

## Step 1: Triage

### Who responds?

| Severity | Primary | Escalation |
|----------|---------|------------|
| SEV1 | On-call SRE + Tech Lead | VP Engineering (15 min) |
| SEV2 | On-call SRE | Tech Lead (30 min) |
| SEV3 | On-call SRE | Team lead (next standup) |
| SEV4 | Whoever sees it | None |

### Triage Checklist

1. **What is broken?** Check the alert details and affected component.
2. **How many users are affected?** Check traffic metrics and error rates.
3. **Is data at risk?** Check for data corruption, unauthorized access.
4. **What changed recently?** Check recent deployments, config changes, and PRs merged.

```bash
# Quick triage commands
kubectl get pods --all-namespaces | grep -v Running
kubectl get events --all-namespaces --sort-by=.lastTimestamp | tail -30
kubectl top nodes
```

### Communication

- **SEV1/SEV2:** Post in `#incidents` Slack channel immediately with:
  ```
  INCIDENT: [SEV level] [Brief description]
  Status: Investigating
  Impact: [What's broken for users]
  Commander: [Your name]
  ```
- **SEV3/SEV4:** Note in `#ops` channel.

---

## Step 2: Mitigate

The goal is to restore service, not to find the root cause. Speed matters.

### Common Mitigation Actions

| Symptom | Immediate Action |
|---------|-----------------|
| Service crash-looping | `kubectl rollout undo deployment/<name>` |
| High CPU/memory | `kubectl scale deployment/<name> --replicas=+2` |
| Database overloaded | Kill long-running queries, restart connection pool |
| Network partition | Check NetworkPolicies, restart affected pods |
| Bad deployment | Roll back: `kubectl rollout undo deployment/<name>` |
| Config error | Revert ConfigMap: `kubectl rollout undo deployment/<name>` |
| DDoS / rate limiting | Enable rate limiting at ingress, block IPs |

### Rollback a Deployment

```bash
# Check deployment history
kubectl rollout history deployment/<name>

# Roll back to previous version
kubectl rollout undo deployment/<name>

# Roll back to a specific revision
kubectl rollout undo deployment/<name> --to-revision=<N>

# Verify rollback
kubectl rollout status deployment/<name>
```

### Emergency: Halt Bridge Operations

If the cross-chain bridge is compromised:

```bash
# Pause the bridge service
kubectl scale deployment/cross-chain-bridge --replicas=0

# Verify no bridge transactions are in flight
kubectl logs -l app=cross-chain-bridge --tail=100 | grep -i "pending\|inflight"
```

Notify the security team immediately for SEV1 bridge incidents.

---

## Step 3: Diagnose

### Diagnostic Toolkit

```bash
# Cluster-wide health
kubectl get nodes
kubectl top nodes
kubectl get pods --all-namespaces | grep -v Running

# Recent changes (last 2 hours)
kubectl get events --all-namespaces --sort-by=.lastTimestamp | \
  awk '$1 > "'$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)'"'

# Check Prometheus for error spikes
curl -s "http://prometheus:9090/api/v1/query?query=rate(http_requests_total{status=~'5..'}[5m])" | jq .

# Check recent deployments
kubectl get replicasets -l tier=backend --sort-by=.metadata.creationTimestamp | tail -10
```

### Per-Component Diagnostics

See the specific runbook for each component:

| Component | Runbook |
|-----------|---------|
| Blockchain nodes | [blockchain-node-runbook.md](blockchain-node-runbook.md) |
| Backend services | [backend-services-runbook.md](backend-services-runbook.md) |
| Storage providers | [storage-runtime-runbook.md](storage-runtime-runbook.md) |
| Compute agents | [compute-agent-deployment.md](compute-agent-deployment.md) |

---

## Step 4: Fix

### Deploy a Hotfix

```bash
# Build and push the fix image
docker build -t wrfcoin/<service>:<tag> .
docker push wrfcoin/<service>:<tag>

# Update the deployment
kubectl set image deployment/<service> <container>=wrfcoin/<service>:<tag>

# Monitor rollout
kubectl rollout status deployment/<service>
```

### Apply a Database Fix

```bash
# Always backup first
pg_dump "$DATABASE_URL" --format=custom > pre-fix-backup.dump

# Apply the fix
psql "$DATABASE_URL" -f fix.sql

# Verify
psql "$DATABASE_URL" -c "SELECT count(*) FROM <affected_table>;"
```

---

## Step 5: Verify

### Verification Checklist

- [ ] Alert has cleared (check AlertManager)
- [ ] Health endpoints return 200 OK
- [ ] Error rate is back to baseline
- [ ] Latency is back to baseline
- [ ] No new error patterns in logs
- [ ] Affected users can confirm resolution (if applicable)

```bash
# Quick verification
for port in 4001 3000 4000 8080 8000; do
  echo "Port $port: $(curl -s -o /dev/null -w '%{http_code}' http://localhost:$port/health)"
done

# Check error rate trend
curl -s "http://prometheus:9090/api/v1/query?query=rate(http_requests_total{status=~'5..'}[5m])" | jq '.data.result[].value[1]'
```

### Close the Incident

Update `#incidents` channel:
```
INCIDENT RESOLVED: [SEV level] [Brief description]
Duration: [start → end]
Root cause: [one line]
Fix: [what was done]
Postmortem: [link or "to follow"]
```

---

## Step 6: Postmortem

Required for all SEV1 and SEV2 incidents. Optional for SEV3.

### Postmortem Template

```markdown
# Incident Postmortem: [Title]

**Date:** YYYY-MM-DD
**Duration:** HH:MM → HH:MM (X hours Y minutes)
**Severity:** SEV[N]
**Commander:** [Name]

## Summary
[2-3 sentences describing what happened and the impact.]

## Timeline
- HH:MM — Alert fired: [alert name]
- HH:MM — Incident commander assigned
- HH:MM — [Mitigation action taken]
- HH:MM — Root cause identified
- HH:MM — Fix deployed
- HH:MM — Incident resolved

## Root Cause
[Technical description of what went wrong and why.]

## Impact
- Users affected: [count or percentage]
- Data loss: [yes/no, details]
- Revenue impact: [if applicable]

## What Went Well
- [Item]

## What Went Poorly
- [Item]

## Action Items
| Action | Owner | Due Date | Status |
|--------|-------|----------|--------|
| [Action] | [Name] | YYYY-MM-DD | Open |

## Lessons Learned
[Key takeaways for the team.]
```

### Postmortem Review

- Schedule within 3 business days of SEV1/SEV2 resolution.
- Invite: incident commander, on-call SRE, affected service owners.
- Focus on systemic improvements, not blame.
- Track action items in GitHub issues with the `postmortem` label.

---

## On-Call Reference

### Useful Aliases

```bash
alias k='kubectl'
alias kgp='kubectl get pods --all-namespaces'
alias kge='kubectl get events --all-namespaces --sort-by=.lastTimestamp | tail -20'
alias ktp='kubectl top pods --all-namespaces'
alias ktn='kubectl top nodes'
```

### Key URLs

| Resource | URL |
|----------|-----|
| Grafana | `https://grafana.wrfcoin.internal` |
| Prometheus | `https://prometheus.wrfcoin.internal` |
| AlertManager | `https://alertmanager.wrfcoin.internal` |
| GitHub Actions | `https://github.com/wrfcoin/infra/actions` |

### Escalation Contacts

| Role | Contact |
|------|---------|
| On-call SRE | PagerDuty rotation |
| Tech Lead | PagerDuty escalation (15 min) |
| Security Team | `#security` Slack + PagerDuty |
| VP Engineering | PagerDuty escalation (30 min, SEV1 only) |
