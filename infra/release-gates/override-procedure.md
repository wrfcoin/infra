# Alignment-95 Release Gate Override Procedure

Emergency override path for `infra#6` production promotion gate.

## Preconditions

Override is allowed only when all are true:

1. A critical production fix is time-sensitive.
2. KPI gate failure is understood and risk-assessed.
3. A remediation issue is created before promotion.

## Required Inputs

When running the release gate workflow with override, all fields are mandatory:

- `override_ticket` (incident or issue ID)
- `override_reason` (plain-language justification)
- `override_approver` (named accountable approver)

## Audit Record

Every run emits an audit artifact (`alignment-release-gate-audit`) containing:

- decision (`pass`, `blocked`, or `override-pass`)
- thresholds version
- metric pass/fail details
- override metadata (ticket, reason, approver)
- run context (`github_sha`, `github_ref`, `github_actor`, `github_run_id`)

Override runs must be linked back to follow-up remediation and closure evidence.
