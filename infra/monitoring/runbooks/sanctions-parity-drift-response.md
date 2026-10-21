# Sanctions Parity Drift Response Runbook

Runbook for `infra#5` sanctions fairness-phase2 observability alerts.

## Scope

This runbook enforces equal-liability treatment across actor classes (`human`, `ai`, `robot`) for equivalent offense severity.

- sanction-rate parity by actor class
- sanction-rate parity by offense severity
- sanction outcome mix parity
- telemetry completeness and remediation latency

## Alert Thresholds

| Alert | Trigger |
|---|---|
| `AlignmentSanctionParityActorClassDriftCritical` | actor-class spread `> 0.08` for 20m |
| `AlignmentSanctionParitySeverityDriftCritical` | offense-severity spread `> 0.10` for 20m |
| `AlignmentSanctionParityOutcomeBiasWarning` | outcome bias score `> 0.12` for 30m |
| `AlignmentSanctionParityTelemetryCoverageDrop` | label coverage ratio `< 0.98` for 15m |
| `AlignmentSanctionParityRemediationLatencyHigh` | remediation latency p95 `> 14400s` for 30m |

## Actor-Class Parity Drift

1. Validate drift in dashboard panel `Sanction Rate by Actor Class and Severity`.
2. Confirm the same offense-severity cohort is being compared across all actor classes.
3. Correlate drift start-time with policy bundle revisions and sanctions service deploys.
4. If one actor class is over-penalized, trigger emergency parity rollback and open incident issue.

## Offense-Severity Parity Drift

1. Validate severity taxonomy integrity (`low`, `medium`, `high`) from backend telemetry.
2. Compare sanction outcomes for equivalent severity across actor classes.
3. If severity classification drift is present, freeze automated sanction escalations.
4. File remediation task that includes expected parity score delta and owner.

## Outcome Bias Detected

1. Inspect outcome mix panel grouped by actor class and severity.
2. Confirm no hidden actor-specific policy branch or classifier threshold exists.
3. Force manual review mode for high-severity actions until bias score recovers.
4. Attach evidence bundle to incident with pre/post correction parity snapshots.

## Telemetry Coverage Drop

1. Check ingestion path for missing `actor_class` or `offense_severity` labels.
2. Block parity SLO sign-off while telemetry completeness is below threshold.
3. Backfill missing dimensions if logs are recoverable.
4. Open follow-up hardening task to prevent unlabeled sanction writes.

## Remediation Latency Breach

1. Verify active parity incidents and linked remediation tasks.
2. Escalate to on-call governance owner if p95 latency exceeds 4 hours.
3. Track every parity incident to closure with root cause + rollback notes.
4. Confirm post-fix parity score remains within SLO for two consecutive windows.
