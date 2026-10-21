# WRFCoin Testnet Launch Readiness Checklist

This is the manager-facing final checklist for the infra launch path. Complete
it before promoting a local-build testnet deploy to external traffic.

## 1. Source And PR State

- [ ] `wrfcoin/infra` has no open launch-blocking PRs waiting on review.
- [ ] `infra#490`, `infra#491`, `infra#486`, and `infra#487` have either landed
  evidence or an explicit manager deferral.
- [ ] The CT checkout is on the intended branch and clean:
      ```bash
      cd <repo-root>/infra
      bash testnet/scripts/deploy-hygiene-preflight.sh
      ```
- [ ] CI failures caused by GitHub Actions billing are recorded separately from
  code quality.

## 2. Env And Secret Hygiene

- [ ] `.env` exists only on the operator host and is never committed.
- [ ] `.env` is not group- or world-readable:
      ```bash
      find testnet -maxdepth 1 -name '.env*' ! -name '.env.testnet.example' ! -perm 600 -print
      ```
- [ ] No deploy-blocking backup files remain:
      ```bash
      find testnet -maxdepth 1 -name '.env.bak*' -print
      ```
- [ ] If `.env.bak*` files existed on a host, delete them only after operator
  approval and rotate every secret that appeared in a readable backup.
- [ ] Required generated values are present. See
  [public deployment prerequisites](PUBLIC_DEPLOYMENT_EXAMPLES.md) and the operator-supplied secret configuration.
- [ ] HSM/YubiKey PIN state is current and was not exposed in transcripts.

## 3. Local Readiness Wrapper

Run from the infra repo root:

```bash
bash scripts/testnet-launch-readiness.sh \
  --n5 deploy-status-n5-pro.json \
  --desktop deploy-status-desktop.json \
  --readiness-report readiness-report.json
```

Required result:

- [ ] Final JSON and Markdown both report `PUBLIC_RELEASE` and `PASS`.
- [ ] Secrets, readiness report, contract, paired-node, synthetic/real-production,
      outbound-alert, and full-profile functional gates all pass without skips.
- [ ] Tier 3 chain-liveness passes with `wrfcoin_chain_height` increasing.
- [ ] Tier 4 divergence passes with `wrfcoin_state_divergence_total=0`.
- [ ] TODO `infra#978`: run `testnet/scripts/probe-faucet-readiness.sh`;
      public release requires `DIRECT_READY`, or `PROXY_ONLY` only after the
      onboarding proxy has separate functional evidence.

## 4. Post-Deploy Snapshot

On each node, send the explicit labelled delivery canary and immediately collect
the read-only snapshot. By default the gate rejects delivery evidence older than
five minutes (`ALERT_DELIVERY_MAX_AGE_SECONDS` can narrow that bound).

```bash
cd <repo-root>/infra
bash testnet/scripts/alert-delivery-canary.sh
NODE_NAME=n5-pro WRFCOIN_ROOT=<repo-root> bash testnet/scripts/deploy-status-snapshot.sh > deploy-status-n5-pro.json
bash testnet/scripts/alert-delivery-canary.sh
NODE_NAME=desktop WRFCOIN_ROOT=<repo-root> bash testnet/scripts/deploy-status-snapshot.sh > deploy-status-desktop.json
```

Then evaluate the pair:

```bash
bash testnet/scripts/launch-readiness-gate.sh \
  --n5 deploy-status-n5-pro.json \
  --desktop deploy-status-desktop.json \
  --json-out launch-readiness-report.json \
  --markdown-out launch-readiness-report.md
```

Required result:

- [ ] N5 is healthy and advancing.
- [ ] Desktop is healthy and converging with N5.
- [ ] Backend health is green or intentionally out of scope.
- [ ] Targeted node log scan has no unresolved fork, reorg, validation, sync,
  panic, or error blocker.
- [ ] Pair gate exits 0 before deploy promotion.

## 5. Cross-Repo Blockers

- [ ] No open `testnet-blocker` issue in `core4`, `backend`, or another runtime
  repo remains unassigned or unexplained.
- [ ] Human-gate items are scheduled before public exposure: oracle trust
  bootstrap, key ceremony, and real operator-token rotation.
- [ ] Any partial fix is recorded as partial; do not close a parent launch issue
  from an infra docs slice alone.

## Decision

Overall readiness: `PASS` / `FAIL`

If `FAIL`, stop deploy promotion and update the first blocking GitHub issue with
the exact command output, redacted as needed. If `PASS`, attach the snapshot
JSON files and launch-readiness report to the manager note.
