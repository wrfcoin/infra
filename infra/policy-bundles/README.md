# Actor-Governance Policy Bundles

This directory contains versioned policy bundles used to roll out actor-governance sanction logic with deterministic validation and rollback metadata.

## Layout
- `schema/actor-governance-policy-bundle.v1.schema.json`: canonical schema contract.
- `bundles/actor-governance-policy-bundle.v1.0.0.json`: sample policy bundle version.
- `runbooks/rollback-actor-governance-policy.md`: rollback procedure.
- `releases/<environment>/<version>/...`: generated deployment artifacts.

## Validation Gate
Run pre-deploy checks locally:

```bash
node scripts/validate-policy-bundle.cjs \
  --bundle infra/policy-bundles/bundles/actor-governance-policy-bundle.v1.0.0.json
```

Validator guarantees:
- Bundle schema/version metadata is present.
- Actor classes (`human`, `ai_agent`, `robot`) are defined.
- Equal-liability matrix maps each offense level to the same sanction profile across actor classes.
- Rollback metadata exists and references a real runbook path.
- Stable SHA-256 digest is produced from canonical JSON.

## Reproducible Rollout
Dry-run bundle deployment and create auditable artifacts:

```bash
node scripts/deploy-policy-bundle.cjs \
  --bundle infra/policy-bundles/bundles/actor-governance-policy-bundle.v1.0.0.json \
  --environment staging \
  --output-dir /tmp/policy-bundle-rollout \
  --dry-run
```

Generated artifacts include:
- `bundle.json`
- `bundle.canonical.json`
- `deployment-record.json`
- `rollback.json`
- `current.json` pointer per environment

## Rollback
Follow:
- `infra/policy-bundles/runbooks/rollback-actor-governance-policy.md`
