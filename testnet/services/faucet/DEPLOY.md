# WRFCoin Testnet Faucet — Deploy & Funding (N5 Pro)

The faucet dispenses test WRF to onboard external testers. It is gated behind the
`seed` compose profile, so the standard testnet bringup does **not** start it. This
doc covers the one-time deploy + wallet funding. All steps run on the N5 Pro
(`<NODE_LAN_IP>`, CT 101) per the local-build deployment constraint — no images are
pushed to any registry.

> **Constraint:** Local builds only. Never `docker push`. The node API is loopback-only
> on the N5; reach it via `<node-shell> 'curl ...'`.

## How the faucet sends WRF (contract)

The faucet calls the node's REST `launch_api`:

```
POST {FAUCET_NODE_URL}/transactions/submit
Authorization: Bearer <FAUCET_API_TOKEN>
Content-Type: application/json

{ "from": "<FAUCET_WALLET_ADDRESS>", "to": "<claimant>", "amount": <base units>, "transparent_opt_out": true }
```

- `amount` is in **base units** (1 WRF = 10^8). The faucet converts `FAUCET_AMOUNT`
  (whole WRF) automatically.
- `transparent_opt_out: true` makes a transparent `Transfer` so testers immediately
  see and spend the funds (the node default is a confidential transfer).
- The route requires the **Contributor** role; the node's operator token satisfies it,
  so `FAUCET_API_TOKEN` defaults to `WRFCOIN_OPERATOR_TOKEN` when unset.
- There is **no** JSON-RPC `wrf_transfer` method — that was the bug fixed in infra #551.
- The `auth_signature` is computed over a **v2** preimage that folds the deployment's
  `(chain_id, network_id)` in right after the domain tag (core4 #2034 / PR #2064,
  infra #626). `WRFCOIN_CHAIN_ID`/`WRFCOIN_NETWORK_ID` are hardcoded to `777`/`testnet`
  in `docker-compose.testnet.yml` for both `wrfcoin-node` and `wrfcoin-faucet` — they
  **must** match exactly, or the node's fail-closed auth check rejects every dispense.
  If you ever run the faucet outside this compose file, set both env vars to the same
  values the node resolves (`shared-protocol/src/crypto/domain_signing.rs` in core4).

## 1. Configure faucet env

In the deploy `.env` on CT 101 (inside `wrfcoin-deploy`), set:

```bash
# Required
FAUCET_WALLET_PRIVKEY=<hex privkey of the faucet wallet>
FAUCET_WALLET_ADDRESS=0x<40-hex faucet address>
FAUCET_HIGH_WATER_MARK=<absolute whole-WRF bucket mark; required, no default>
# FAUCET_API_TOKEN is optional — defaults to WRFCOIN_OPERATOR_TOKEN (already set).

# Optional tuning
FAUCET_AMOUNT=10                  # whole WRF per claim
FAUCET_RATE_LIMIT_SECONDS=86400   # cooldown per device (tailnet user, else peer IP)
FAUCET_TRUST_PROXY=false          # or a fixed hop count such as 1 behind one trusted proxy
FAUCET_WALLET_DAILY_CAP=10        # whole WRF per wallet per UTC day
FAUCET_DEVICE_DAILY_CAP=10        # whole WRF per device per UTC day (default: FAUCET_AMOUNT)
FAUCET_GLOBAL_DAILY_CAP=1000      # whole WRF globally per UTC day
FAUCET_WALLET_BALANCE_FLOOR=10    # refuse claims that would leave less than this
FAUCET_REFILL_SOURCE=manual       # manual, emission, or treasury; owner decision required before changing
FAUCET_WALLET_BALANCE_PATH=/addresses/{address}
FAUCET_CAPTCHA_PROVIDER=hcaptcha  # hcaptcha or recaptcha-v3; off fails closed once wallet is configured
FAUCET_HCAPTCHA_SITEKEY=<sitekey>
FAUCET_HCAPTCHA_SECRET=<secret>
```

`REDIS_PASSWORD` and `WRFCOIN_OPERATOR_TOKEN` are already required by the base stack.

### Claim limits

A claim must pass all four limits. They are independent:

| Limit | Keyed on | Env (default) | Refusal (HTTP 429, with `Retry-After`) |
|---|---|---|---|
| Cooldown | device | `FAUCET_RATE_LIMIT_SECONDS` (86400) | `RATE_LIMITED` |
| Device daily cap | device, per UTC day | `FAUCET_DEVICE_DAILY_CAP` (= `FAUCET_AMOUNT`, one claim) | `DAILY_LIMIT_REACHED` |
| Wallet daily cap | wallet address, per UTC day | `FAUCET_WALLET_DAILY_CAP` (= `FAUCET_AMOUNT`) | `DAILY_LIMIT_REACHED` |
| Global daily cap | everything, per UTC day | `FAUCET_GLOBAL_DAILY_CAP` (1000) | `GLOBAL_DAILY_LIMIT_EXCEEDED` |

- A **device** is the authenticated tailnet user behind `tailscale serve`, otherwise the peer IP, or the
  trusted proxy's `x-client-ip` on operator-token requests. Redis stores only its sha256 fingerprint.
- The device and wallet caps return **one uniform message**, so a caller cannot tell which cap refused it.
  A refused claim keeps the device's cooldown spent. Submitting someone else's address therefore
  reveals nothing about that address and costs the prober a claim slot.
- The counters live in Redis (`faucet:device-daily:`, `faucet:wallet-daily:`, `faucet:global-daily:`,
  plus the cooldown keys) with TTLs. They survive a faucet restart, and they survive a Redis restart
  because the stack's Redis runs with `--appendonly yes`.
- **Unknown transfer outcomes keep the claim spent.** Once the transfer request has left the faucet,
  only a **definitive** non-admission releases the cooldown and the daily reservations:
  - nothing was sent: signing failed, or the single hop failed to connect (`ECONNREFUSED`,
    `ENOTFOUND`, `EAI_AGAIN`). The submit never follows redirects;
  - or the node answered a direct 4xx whose body is exactly core4's error envelope
    (`{ok:false, data:null, error:{code, message}, meta:{request_id, timestamp, api_version:"v1"}}`)
    with no acceptance evidence (`accepted:true`, a tx id or hash) and a code other than
    `REPLAY_REJECTED`.

  Everything else may mean the node already accepted the transfer, and is **unknown**: a reset, a
  timeout, any 3xx, a 5xx, an unrecognised or contradictory 4xx body, or a 2xx without a usable
  transaction id. The faucet then keeps the cooldown and every daily reservation, and answers HTTP 409
  `CLAIM_PENDING` ("do not retry"). It records the claim (nonce, wallet, amount, reason) under
  `faucet:pending:<nonce>` (`FAUCET_PENDING_PREFIX`, kept 7 days) and logs `claim outcome unknown`.
  There is no automatic reconciler yet (infra#1158): an operator checks the wallet's balance or the
  nonce on-chain.
- **Retry-After** on a daily-limit refusal and on `CLAIM_PENDING` is the calendar wait to the next
  00:00:00Z (at least 1 second). If the device's retained cooldown lasts longer, it is the larger of
  the two. The daily Redis keys live 60 seconds past their day; that margin is never sent to a client.
- `docker-compose.testnet.yml` does not pass `FAUCET_DEVICE_DAILY_CAP` yet, so the code default
  (one claim per device per day) applies. To override it, add the variable to the faucet service's
  `environment` and to the env file.

The faucet no longer trusts client-supplied `X-Forwarded-For` by default. If it is
published behind a reverse proxy, set `FAUCET_TRUST_PROXY` to the exact number of
trusted proxy hops and make sure the proxy overwrites forwarding headers.

## 2. Fund the faucet wallet on-chain

The faucet wallet must hold WRF before it can dispense. (An unfunded faucet is safe
to bring up — claims fail closed with `FAUCET_EMPTY` — so it is fine to do §3 first
and fund afterwards; the transfer path below actually requires the container.)

> ⚠️ **Do NOT fund via `POST /debug/seed-account`.** Earlier revisions of this doc
> used it; that guidance caused a real incident:
>
> - **It forks state on any network with peers attached.** The route pokes balance
>   state outside block application, so the seeding node's state root immediately
>   diverges from every same-height peer (this split the N5 from the desktop peer on
>   2026-07-02 — `/readyz` flipped `not_ready`, `wrfcoin_state_divergence_total`
>   fired). Recovery required mirror-seeding every peer by hand.
> - **It is disabled by default** since core4#1811 — the route 404s unless the node
>   was explicitly started with it enabled.
> - **Balances it creates are not reliably spendable** — see wrfcoin/core4#2056
>   (transparent transfer from a seeded account accepted by the API but silently
>   dropped between mempool and block application).
>
> It is a single-node debugging tool, not a funding mechanism.

### Supported funding paths

**(a) Signed transparent transfer from an already-funded account** — the only
fork-safe path on a running network. Same node contract the faucet itself uses
(§ "How the faucet sends WRF"): transparent transfers must carry a from-account
ed25519 authorization (#1727/#1848). The faucet image ships the signing helpers, so
sign + submit from inside the owner-authorized faucet container. You need a funded source
account and its 32-byte hex ed25519 seed; `amount` is in **base units**
(10,000 WRF = `1000000000000`):

The owner supplies `SRC`, `DEST`, `AMOUNT_BASE` and `SRC_KEY` through an approved
local credential channel; do not put a seed or bearer in command arguments or
logs. Save this script beside `/app/server.js` and run it there with Node after
the r19 rebuild. Its account read uses the source address and the configured
Reader account path. Stop other senders for that source account during funding.
An uncertain submission requires owner reconciliation before another attempt.

```javascript
const f = require("./server.js");
const fundingAttempt = (async () => {
  const from = f.normalizeWalletAddress(process.env.SRC);
  const to = f.normalizeWalletAddress(process.env.DEST);
  const amount = Number(process.env.AMOUNT_BASE);
  if (!f.isSupportedWalletAddress(from) || !f.isSupportedWalletAddress(to) ||
      !Number.isSafeInteger(amount) || amount <= 0) throw new Error("Invalid funding inputs");
  const { nonce } = await f.getFaucetAccount(from);
  const auth = f.signTransferAuthorization({
    from, to, amountBaseUnits: process.env.AMOUNT_BASE, nonce,
    privkeyHex: process.env.SRC_KEY,
  });
  const response = await fetch(process.env.FAUCET_NODE_URL.replace(/\/$/, "") +
    (process.env.FAUCET_SUBMIT_PATH || "/transactions/submit"), {
    method: "POST", redirect: "manual", signal: AbortSignal.timeout(10000),
    headers: { "Content-Type": "application/json",
               Authorization: "Bearer " + (process.env.FAUCET_API_TOKEN || process.env.WRFCOIN_OPERATOR_TOKEN || "") },
    body: JSON.stringify({
      from, to, amount, transparent_opt_out: true,
      transparent_opt_out_reason: "faucet-funding", nonce, ...auth,
    }),
  });
  const payload = await f.readBoundedNodeJson(response);
  const { txHash } = f.parseReceipt(payload.data, to);
  if (!response.ok || payload.ok === false || payload.error || payload.data?.accepted !== true ||
      typeof txHash !== "string" || !/^(0x)?[0-9a-f]{64}$/i.test(txHash)) {
    throw new Error("Funding admission is unverified");
  }
  console.log("Funding admission receipt", txHash, "requires settlement verification");
})();
fundingAttempt.catch(() => { console.error("Funding attempt needs owner review; do not retry blindly"); process.exitCode = 1; });
```

**(b) Genesis allocation (fresh network bringup only).** A brand-new network can
allocate the faucet balance at genesis. This is a network-wide operator decision —
the running testnet's genesis is pinned, so this path does **not** apply to an
already-running chain; it exists so re-genesis planning doesn't reinvent (a).

### Confirm the balance

```bash
<node-shell> 'curl -s http://localhost:8556/addresses/0x<FAUCET_WALLET_ADDRESS>'
```

## 3. Bring up the faucet (seed profile)

From the deploy stack directory inside CT 101, start ONLY the faucet without touching
the running node/peer:

```bash
<node-shell> 'bash -lc "cd <repo-root>/infra/testnet && \
  docker compose --env-file .env -f docker-compose.testnet.yml --profile seed \
  up -d --build --no-deps wrfcoin-faucet"'
```

(Build is local; no registry push. `--no-deps` leaves redis/node/peer untouched.)

## 4. Verify

```bash
# Health (expect walletConfigured:true, apiTokenConfigured:true, captchaReady:true, redisHealthy:true)
<node-shell> 'curl -s http://localhost:8080/health'

# End-to-end claim test (replace with a real test address)
<node-shell> 'curl -s -X POST http://localhost:8080/faucet/request \
  -H "Content-Type: application/json" \
  -d "{\"walletAddress\":\"0x<test address>\"}"'
# -> { ok: true, receipt: { txHash: "<tx_id>", ... } }

# Confirm the recipient received funds on-chain
<node-shell> 'curl -s http://localhost:8556/addresses/0x<test address>'
```

## 5. Public exposure (separate blocker)

The faucet binds `127.0.0.1:8080`. External testers need an exposure path
(reverse proxy / Tailscale / SSH tunnel) — tracked under the public-reachability
blocker, out of scope for #551.

## Rollback

```bash
<node-shell> 'bash -lc "cd <repo-root>/infra/testnet && \
  docker compose -f docker-compose.testnet.yml --profile seed stop wrfcoin-faucet"'
```


## Account nonce submission (r19)

The deployed service source is `testnet/services/faucet/server.js`, copied by
`testnet/services/faucet/Dockerfile`. The tracked release/local Compose definitions
use that Dockerfile; they do not select the legacy `testnet/faucet/server.js` copy.
This is repository wiring evidence, rather than a live container inspection.

Each payout reads its own canonical account through the existing Reader-gated
`/addresses/{address}` route by default, honoring `FAUCET_WALLET_BALANCE_PATH`,
with the faucet API bearer. That credential must
permit both Reader and transfer submission; an Operator credential covers both.
The returned decimal nonce is signed exactly. Account reads are limited to five
seconds and 64 KiB, with no redirect or retry; transfer submits have a ten-second
request deadline and no redirect or retry.

Only one payout submission runs at a time in a service process. A durable Redis
nonce fence, scoped by the global-cap prefix and faucet account, also prevents
another process or restart from reusing the same account nonce. It remains until
the authoritative account nonce advances, or a definitive non-admission removes
it by compare-and-delete using a unique reservation ownership token. A receipt indicates admission; another claim waits
for account advancement rather than guessing the next nonce. Busy claims return
503 and release their own reservations. Never run multiple independently
configured global-cap prefixes for one signing account.
Expect at most one accepted payout per account nonce advancement (roughly one
per block, about 80 seconds on this testnet); intervening claims receive 503.

A direct, well-formed node `TRANSACTION_REJECTED` nonce-conflict response is a
definitive non-admission: reservations and the matching fence are returned, and
there is no automatic retry. Ambiguous replies, missing receipts and transport
failures retain the fence and pending-claim reservations. If the account does not
advance, the faucet remains unavailable until an owner-authorized reconciliation
establishes non-admission; calendar expiry or a restart cannot erase this fence.
The canonical transaction-status reconciliation remains tracked separately in
infra#1158/core4#3418. Keep the Redis data durable across service restarts and do
not expire or manually clear nonce-fence keys on an uncertain outcome.

After definitive non-admission, fence cleanup retries up to three idempotent
compare-and-delete operations, each with a one-second response deadline. A lost
response cannot erase another claimant's token at the same nonce. Persistent
failure returns `503 FAUCET_NONCE_CLEANUP_PENDING`; the process retains one
pending deletion and retries it before the next payout. Daily-cap refunds and
transfer POSTs are never retried by this mechanism. The pending deletion is
process-local: restarting while cleanup remains pending preserves the Redis
fence but needs owner recovery if the account nonce has not advanced.

Before an authorized chain reset or rollback, stop faucet senders and retain
the account identity, fence and claim records with the owner evidence. A lower
post-reset account nonce cannot advance past the old fence. The owner must
establish that no earlier uncertain transfer can be admitted on the selected
chain before removing only that account's retained fence, then check the
Reader account nonce and resume. Do not automate deletion from a lower nonce,
elapsed time or service restart. Verify the deployed bearer has both roles
before enabling the rebuilt service.

This change needs a faucet image rebuild for r19. No new environment input,
SQL migration, live account read, on-chain transfer or deployment is performed
by the implementation tests.

## New chain cut (genesis 888): owner Redis steps

Refs infra#1332, core4#3592. Owner-run at the 888 cut. The faucet itself
performs none of these steps.

On a new genesis the faucet account starts again at nonce 0. The retained
nonce fence still holds the last 777 nonce, so every 888 claim would wait
forever with `FAUCET_TRANSFER_BUSY`. The rule above applies: clear only that
account's fence, and only after non-admission is established. Here the chain
change itself establishes it. Transfer authorizations are v2 and bind the chain
id and network id, so a transfer signed for 777 cannot verify on 888.

With the default prefixes, the keys are:

| Key | What it is |
|---|---|
| `faucet:global-daily:nonce:<faucet address, 0x lowercase>` | The nonce fence. |
| `faucet:pending:*` | Claims whose 777 outcome was unknown. |
| `faucet:wallet-daily:*`, `faucet:device-daily:*`, `faucet:global-daily:<day>`, `faucet:ip:*`, `faucet:tsuser:*` | Daily caps and cooldowns. They expire within a day. Clearing them is optional. |
| `faucet:bond-grant:*` | Bond grant marks (BOND_GRANT.md). None exist unless grants were on before the cut. |

Steps:

1. Stop the faucet before the cut.
2. In `<node-shell>`, use `redis-cli` against the testnet Redis. Pass the
   password through `REDISCLI_AUTH`, never on the command line.
3. Keep the evidence: `GET` the fence key and each `faucet:pending:*` record,
   and save the output with the cut records.
4. `DEL` the fence key and the `faucet:pending:*` keys. Use `--scan --pattern`
   to list them; never use `FLUSHALL` or `FLUSHDB`, because the same Redis
   serves other services.
5. Set the faucet's `WRFCOIN_CHAIN_ID` to 888. If the 888 genesis names a new
   faucet address, set `FAUCET_WALLET_ADDRESS` and `FAUCET_WALLET_PRIVKEY` to
   it. The fence key follows the address, so a new address starts with no
   fence. Still delete the old one.
6. Start the faucet. Check `/health`, then read the faucet account through the
   Reader route: its nonce should be `0` before the first claim.
7. To turn the bond grant on, set `FAUCET_BOND_GRANT_ENABLED=true` and restart.
   The faucet wallet must hold the grants on top of its drip budget.

`<node-shell>` means the operator-provided shell inside the node deployment.
Replace it with your own access method; no host/container layout is assumed.
