# Testnet Alertmanager notification rotation and legacy SMTP cleanup

Use this runbook to rotate the critical webhook or reconcile an older live
Alertmanager configuration with the current webhook-only source. Perform
runtime changes only in an owner-approved operations window. A source PR does
not deploy or reload Alertmanager.

## Current delivery model

[`testnet/alertmanager.yml`](../../testnet/alertmanager.yml) routes critical
alerts to `critical-notifications`, with one webhook integration to the
alert-receiver service. The receiver forwards to the operator's configured
ntfy or Telegram destination. Warning alerts route to `log-only`, which has
no notification integrations. Keep notification destinations, topics and
credentials private; do not dump rendered configuration or receiver logs.

[`testnet/render-alertmanager-config.sh`](../../testnet/render-alertmanager-config.sh)
renders the template to `testnet/alertmanager.rendered.yml` using
`ALERTMANAGER_WEBHOOK_URL`; its default is the alert-receiver container on the
testnet network. Forward delivery uses the receiver's `ALERT_FORWARD_*`
settings. Rendered configuration and real `.env` values must not be committed.

## Email is retired, not an alternate working channel

Infra PR #631 removed SMTP and `email_configs` from the template and renderer
because the testnet container had no local MTA. The renderer does not apply the
retired `ALERTMANAGER_OPERATOR_EMAILS` or `ALERTMANAGER_SMTP_*` settings.
Changing those variables will not configure email delivery in the current
template. Earlier versions of this runbook incorrectly advised doing so.

A legacy live configuration may still have a local port-25 smarthost and an
email integration alongside the working webhook. A refused SMTP connection
means no accepting relay was reached; it is not evidence of a TLS or password
failure. Webhook delivery can succeed while this separate integration retries.
Treat the failed email path as configuration drift, not human reachability.

The minimal remediation is to reconcile the mounted and loaded configuration
with the existing webhook-only template, preserving the privately configured
webhook and receiver-forwarding destinations. Do not provision an MTA or add
SMTP credentials merely to eliminate an obsolete integration. Any future
email channel requires a separately reviewed template/renderer change plus a
reachable relay, sender/recipient policy, authentication/TLS policy and an
owner-observed delivery test. No email support is implemented by this runbook.

## Owner-window rotation or reconciliation

1. Privately confirm the current webhook/forwarding settings and owner
   subscription. Record only routing names and integration counts in evidence.
2. For endpoint rotation, update `ALERTMANAGER_WEBHOOK_URL` in the runtime
   `.env`. For legacy SMTP cleanup, use the current webhook-only template and
   preserve the existing destination. Render with
   `bash testnet/render-alertmanager-config.sh` from the infra checkout.
3. Validate the rendered configuration privately using the matching
   Alertmanager version. Confirm `critical-notifications` has one webhook and
   zero email integrations, and `log-only` has no integrations. Keep secret
   configuration out of validation output and retained artifacts.
4. In the owner-approved operations window, have the operator load the
   reviewed configuration using the Alertmanager restart step in
   the operator-approved paging procedure (supplied separately).
   Use only that section's `restart alertmanager` command with the verified
   live Compose chain. Do not run its `up -d --build alert-receiver` command;
   notification rotation or reconciliation needs no receiver rebuild. This
   runbook's webhook-only settings supersede its legacy email guidance. Neither
   rendering nor merging a PR proves that the running process loaded it.
5. Read `/api/v2/status` through loopback using Python urllib, keeping the
   returned configuration private. Check the loaded routing/integration counts
   as well as the mounted file. Raw hashes can differ due to serialization;
   compare the relevant settings rather than inferring a reload from hashes.
6. Receiver liveness and a dry-run payload are not proof of human delivery.
   A firing/resolved notification test requires its own owner-approved window
   and an owner receipt. Avoid the receiver self-test, which can expose the
   forwarding destination. Do not send a notification during read-only triage.

## ValidatorParticipationZero on the current V1/PoP runtime

The rule in
[`testnet/alert-rules-blockchain-health.yml`](../../testnet/alert-rules-blockchain-health.yml)
tests `wrfcoin_consensus_validator_participation_rate == 0` for 10 minutes.
It is a warning with component `consensus-observability`, routed log-only.
The rule already explains that the participation source is unwired on the
current PoP testnet. A default zero is an instrumentation gap, not measured
validator inactivity or evidence of healthy participation.

At Core4 revision `620902bf7b01cf09b11b2bb0ff5a22571e7cb694`,
`native-chain/src/monitoring/mod.rs` builds `CoreMetricSnapshot` without
setting `validator_participation_rate`, using `..Default::default()`;
`shared-protocol/src/monitoring/mod.rs` exports that default value.
**Re-verify at the deployed revision** before applying this V1 instrumentation
note or proposing a silence; the pinned source observation is not proof of
the current runtime's participation wiring. Keep the warning visible until
runtime wiring supplies meaningful measurements.
Do not relax the threshold, replace zero with a synthetic healthy value, or
silence other consensus/finality/block-production alerts.

If an owner needs temporary noise suppression during a documented V1 window,
the proposal is a **single-target, time-limited silence**, not a rule removal:

- Exact matchers: `alertname=ValidatorParticipationZero`, `severity=warning`,
  `component=consensus-observability`, and the actual observed target's `job`
  and `instance`. Supply target values privately; no regex or wildcard matches.
- Maximum duration: 24 hours from approval, with a named owner and review time.
- Reason: verified default-zero instrumentation at the deployed V1 revision;
  participation remains UNKNOWN, not healthy.
- Remove/review it before any runtime wiring, consensus activation or node
  revision change. Do not renew it automatically. Leave every critical alert
  and the existing independently scoped BFT silence unchanged.

This is a proposal only. No silence or live rule change is created by this
runbook. Once participation wiring is enabled, sustained measured zero must
be investigated as a real signal rather than classified using this V1 note.
