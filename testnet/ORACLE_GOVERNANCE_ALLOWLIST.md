# Oracle governance allowlist — deployment and verification (O2b)

`WRFCOIN_ORACLE_GOVERNANCE_PUBKEYS` names the ed25519 public key(s) authorized to sign on-chain
oracle-registration transactions (#2055 Option A, oracle gate #724). This document is the deployment
path and the operator's verification step for it.

**Value for this chain — the O1 ceremony governance key, public half:**

```
e7bec166ad446314d26fb7526bfa8cec1b363b438440262fb001f7b04b20bf00
```

It is a **public** key. It is committed in `docker-compose.testnet.yml` exactly like
`WRFCOIN_CHAIN_ID`, and deliberately not `.env`-substituted — see "Why it is hardcoded" below.

---

## 1. It is per HOST, not per identity

Every node that will ever **validate** this chain needs it — the producer, the seed, and every
syncing peer. `oracle_governance_pubkeys()` resolves it from that node's own process environment, so
a node that was not told who may authorize registrations accepts none.

| Host | Service / container | Covered by |
|---|---|---|
| N5 CT 101 | `wrfcoin-node` / `wrfcoin-testnet-node` | base compose |
| N5 CT 101 | `wrfcoin-seed` / `wrfcoin-testnet-seed` (profile `seed`) | base compose |
| Workstation (desktop peer #2) | `wrfcoin-node` / `wrfcoin-testnet-node` | **same base compose** |

The workstation brings up the same `docker-compose.testnet.yml` with `docker-compose.desktop.yml`
layered on top, and that overlay does not touch this key — so **one change in the base compose
deploys both hosts**. The workstation carries two oracle identities; that is irrelevant here. The
allowlist authorizes the *governance signer*, not the oracles, so one deployment per host is both
necessary and sufficient.

Late joiners count. Mango and the Surface Pro need it **before** they rejoin, not after.

---

## 2. Fail-closed is correct — do not "fix" it

Unset or empty means an **empty allowlist**, and every oracle registration then fails
authorization. That is the intended posture and it must stay.

It is the opposite of the deleted `GENESIS_ORACLE_SET_ENV` (#2496, removed by #2523), where unset
reached a branch that **validated nothing and said nothing**. Here, unset means *refuse everything* —
loud, not silent.

**Measured, 2026-08-04**, two nodes built from `core4` `67d07852`, one with the variable and one
without, both on `chain_id "777"` / `network_id testnet`:

```text
A (allowlist set):   height=1  oracle_set n=3  quorum=2
B (allowlist unset): height=0  oracle_set n=0  quorum=2   <- never stored block 1

B's log:
  WARN proof_of_publishing: Block at height 1 rejected: oracle registration without valid
       governance authorization (forgery rejected, #2055)
  WARN p2p_events: Rejecting P2P block at height 1: failed consensus validation
  WARN p2p_events: FORK DETECTED: peer ... is at height 1 (local=0) with different tip
```

The gate is `shared-protocol/src/consensus/proof_of_publishing.rs:6081` (§0d of
`classify_block_transaction`), reached from the sync verifier's per-transaction loop.
`TX_SIGNATURE_VERIFICATION_ACTIVATION_HEIGHT = 0`, so it is live at height 1.

So an unprepared peer **stalls loudly rather than forking silently**. Recoverable — see §6 — but
still a peer that cannot follow the chain.

---

## 3. Why it is hardcoded rather than `${VAR}`-substituted

A `${WRFCOIN_ORACLE_GOVERNANCE_PUBKEYS:-}` form fails in the worst direction: a missing or
misspelled `.env` entry renders as **empty**, which is a silently empty allowlist and a node that
refuses every registration. That is the "one forgotten export on cut day" failure #2523 was written
to eliminate, reintroduced through `.env`.

There is also nothing to protect: this is a public key. Rotation is a compose edit and a PR, which
leaves an auditable trail — better than an untracked `.env` line on two hosts.

---

## 4. Activation — container RECREATION, not a reload

`environment:` entries are baked into container config. `oracle_governance_pubkeys()` reads the
variable **from the process environment on every call**, so:

- A node started before this change **passes a rendered-config read and still refuses every
  registration.** Never verify this from `docker compose config`.
- The change takes effect only on `docker compose up -d` for those services (container recreation).

**That is a deploy action and therefore the owner's.** This PR does not deploy it.

Both live nodes are also missing `WRFCOIN_REQUIRE_PRODUCER_AUTH` (verified 2026-08-04, read-only
`docker inspect` on both hosts) because they predate that compose entry too. Recreation applies
both. Expect that, and check it in the same window.

---

## 5. Verification — run this on each host after recreation

The checker reads `/proc/<resolved-pid>/environ` as NUL-delimited records and succeeds only when
there is **exactly one** `WRFCOIN_ORACLE_GOVERNANCE_PUBKEYS` record whose value is **exactly equal**
to the expected key. It fails closed on unreadable, missing, duplicate, or mismatched process state.

### N5 CT 101

```bash
# Run INSIDE CT 101 — Docker must resolve the container PID in that CT's PID namespace.
cd <repo-root>/core4
bash scripts/verify-oracle-governance-allowlist.sh \
  --container wrfcoin-testnet-node \
  --expected-pubkey e7bec166ad446314d26fb7526bfa8cec1b363b438440262fb001f7b04b20bf00

# If the seed profile is running, it is a separate process and needs its own check:
bash scripts/verify-oracle-governance-allowlist.sh \
  --container wrfcoin-testnet-seed \
  --expected-pubkey e7bec166ad446314d26fb7526bfa8cec1b363b438440262fb001f7b04b20bf00
```

> **Path trap, measured 2026-08-04.** Use `<repo-root>/core4`, **not**
> `<repo-root>/core4`. The deploy checkout is pinned at `581a9a123` (#1694) and does
> **not contain this script at all**. Confirm you have the right copy before trusting a run:
>
> ```bash
> sha256sum scripts/verify-oracle-governance-allowlist.sh
> # 61dc91256e991ca74c9bd49ac7b99b5cc5438bf580b00720b293e2d62909dbac
> ```

### Workstation

```bash
cd <repo-root>/core4
bash scripts/verify-oracle-governance-allowlist.sh \
  --container wrfcoin-testnet-node \
  --expected-pubkey e7bec166ad446314d26fb7526bfa8cec1b363b438440262fb001f7b04b20bf00
```

For any non-container deployment use `--pid <node-pid>` instead of `--container`.

### The PASS line

```text
PASS: process <pid> has exactly WRFCOIN_ORACLE_GOVERNANCE_PUBKEYS=e7bec166ad446314d26fb7526bfa8cec1b363b438440262fb001f7b04b20bf00
```

Anything else is a FAIL, and the command exits nonzero. **A line reporting a count other than 1, or
reporting "contains" rather than exact equality, is not this PASS** —
`check_oracle_governance_ceremony_doc.py` guards exactly that, with a mutation control that flips
`exactly equal` to `contains` and must fail.

### Expected BEFORE recreation (the RED control)

Verified read-only on both hosts, 2026-08-04 — this is what the checker is being run against, so it
should currently fail:

```bash
docker inspect wrfcoin-testnet-node --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed 's/=.*//' | grep -c '^WRFCOIN_ORACLE_GOVERNANCE_PUBKEYS$'
# 0   on CT 101 and on the workstation
```

This prints variable **names only**. Do not dump values.

> `jq` is **not installed inside CT 101** — a `docker inspect | jq` pipeline there produces an empty
> result and a misleading `0` that means "jq is missing", not "the variable is absent". Use the
> `--format` template above, which needs no `jq`.

---

## 6. If a peer was started without it

It will sit at height 0 with `oracle_set` empty and log the block-1 rejection above. To recover:

1. Deploy this compose change to that host.
2. Recreate the container (`docker compose up -d` for the node service).
3. **Wait for the next block.** A lagging peer back-fills only when a *new* block reaches it on
   gossip — measured: it then logs `P2P block height N is ahead of local tip 0 — buffering as orphan
   and kicking sync`, fetches block 1, and converges on the producer's `state_root`. No genesis
   re-cut, no data-dir wipe; a peer that had already rejected block 1 twice recovered this way.

**The four-hour trap.** `initial_block_time_secs = 14400`, so a correctly configured peer can sit at
height 0, connected and healthy-looking, for a full block interval before it catches up.

**Check the log line, not the height.** A peer that is merely *waiting* logs nothing about block 1.
A peer that is *rejecting* logs
`Block at height 1 rejected: oracle registration without valid governance authorization`.

---

## 7. Which repo this lives in, and why

The variable is **consumed by `core4` code** but **supplied by `infra`'s compose**, and it is
deployment configuration, not consensus content — deliberately not in `state_root`. `core4` is
frozen at `deb5a3c5` for the genesis cut and takes no non-draft changes; `infra` is not frozen. So
the mechanism belongs here, and only the *checker* (`scripts/verify-oracle-governance-allowlist.sh`,
already merged) lives in `core4`.
