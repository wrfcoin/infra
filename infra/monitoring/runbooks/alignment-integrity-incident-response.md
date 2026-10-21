# Alignment Integrity Incident Response Runbook

Runbook for `infra#2` integrity observability alerts.

## Scope

- participation integrity anomalies
- sanction efficacy and parity drift
- appeal overturn trend regressions
- forecast breadth integrity regressions

## Alert Thresholds

| Alert | Trigger |
|---|---|
| `AlignmentIntegrityAbuseSpike` | high-risk abuse events `> 20` in 15m |
| `AlignmentSybilCoverageDrop` | sybil detection coverage ratio `< 0.85` for 15m |
| `AlignmentSanctionParityDrift` | sanction parity spread `> 0.35` for 20m |
| `AlignmentAppealOverturnRateHigh` | appeal overturn rate `> 0.20` for 20m |
| `AlignmentParticipationAccessibilityDegraded` | participation accessibility score `< 0.95` for 10m |
| `AlignmentForecastCoverageRegression` | env phase2 coverage `< 0.75` for 30m |

## Abuse Spike Response

1. Validate spike in dashboard panel `Abuse + Sybil Signal Rate`.
2. Verify backend abuse-risk and sybil endpoints are responding and fresh.
3. Check if spike is domain-localized by region/provider; isolate ingestion sources if needed.
4. If false-positive pressure rises, adjust alert noise handling and open incident.

## Sybil Coverage Drop

1. Validate detector telemetry ingestion path from backend integrity endpoints.
2. Compare detector coverage with adversarial simulation baselines.
3. Trigger security-testing suite for bot-farm and sanction-evasion regression.
4. Escalate to SEV1 if coverage remains below threshold >30m.

## Sanction Parity Drift

1. Review actor-class sanction distribution on dashboard.
2. Cross-check parity with recent policy/version deployment timeline.
3. Verify no class-specific policy branch was introduced.
4. Open corrective policy ticket and mark parity drift incident.

## Appeal Overturn Rate

1. Inspect top offense codes driving overturned decisions.
2. Compare threshold changes to appeal outcomes over last 24h.
3. If overturn rate remains elevated, force manual review mode for high-risk actions.
4. Capture remediation notes and required threshold rollback.

## Participation Accessibility Drop

1. Check geoblocking signal counters and relay availability.
2. Confirm no region-based filtering policy was rolled out inadvertently.
3. Mitigate by rerouting relay paths and disabling blocking rules.
4. Verify accessibility score returns above `0.95`.

## Forecast Coverage Regression

1. Review phase2 domain coverage (`soil`, `ocean`, `hydrology`) from backend summary.
2. Identify provider and pipeline ingest gaps.
3. Restore missing domain ingestion jobs and validate canonical outputs.
4. Track post-fix coverage recovery for 2 consecutive windows.
