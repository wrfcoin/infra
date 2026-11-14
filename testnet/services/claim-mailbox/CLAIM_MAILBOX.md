# Claim mailbox (testnet, default OFF)

A bonded node is paid for an epoch only if its **owner** submits a receipt batch
before the epoch closes. The batch holds claims that **another** bonded node
(the consumer) made by fetching a snapshot from it. The consumer ends up with
the claims; the owner needs them. This service carries them across.

```
house consumer ── PUT /claims/<bond id>/<epoch> (bearer) ──► claim mailbox
                                                                 │
bond owner's timer: wrfcoin node receipt auto ◄── GET (public) ──┘
   └── signs once with the owner key, posts to its own node, re-posts until included
```

## Wire format

`GET /claims/<deployment_id>/<epoch>` (public, no credential):

```json
{"deployment_id":"<64 hex>","epoch":"40","claims":[{"claim_hex":"<wire hex>","receipt_id":"<64 hex>"}]}
```

- `404 NO_CLAIM`: nothing for this bond and epoch yet. Claims are sorted by `receipt_id`.
- This is exactly what `wrfcoin node receipt auto --mailbox-url <base>/claims` reads (core4 #173).

`PUT /claims/<deployment_id>/<epoch>` with `Authorization: Bearer <CLAIM_MAILBOX_WRITE_TOKEN>`,
body `{"claims":[{"claim_hex":"…","receipt_id":"…"}]}`:

- Merges by `receipt_id` (a retry or a newer copy replaces, it does not take a slot).
- At most 8 claims per bond and epoch (core4 `MAX_NODE_CLAIMS`); a write that would exceed it is
  refused whole (`409 TOO_MANY_CLAIMS`).
- Each claim at most 1,536 bytes (3,072 hex); body at most 64 KiB.
- Every key expires `CLAIM_MAILBOX_TTL_SECONDS` after its last write (default 36 h, about three epochs).

## What it checks, and what it doesn't

It checks the shape only: lowercase hex, sizes, counts, the bearer. It does **not** check signatures or
that `receipt_id` is the claim's hash. That is on purpose: the owner's CLI re-checks every claim against
the chain (chain, epoch, server key, consumer key, manifest and contract signatures, receipt id) before it
signs anything, so a bad claim in the mailbox can make an owner's pass fail but never makes it sign
something wrong. Only the house consumer holds the write token, so a stranger can't fill a bond's 8 slots.

## Privacy

Claims are public chain data once included. No address, IP or account is stored. Logs: one line per write
(`decision`, first 8 hex of the bond id, epoch, count). Reads are not logged.

## Switches

| Variable | Default | Meaning |
|---|---|---|
| `CLAIM_MAILBOX_ENABLED` | `false` | Off: every `/claims` route answers 404 |
| `CLAIM_MAILBOX_WRITE_TOKEN` | empty | Under 32 characters = writes refused (503); reads still work |
| `CLAIM_MAILBOX_TTL_SECONDS` | `129600` | 1 h to 14 days |
| `REDIS_URL` | — | Required when enabled |

## Deploy (owner-run; nothing here touches a live container)

Compose service `wrfcoin-claim-mailbox`, profile `claim-mailbox`, so no existing `up` starts it. No host
port: once the follow-up backend proxy and edge rule land, only the backend reaches it (route ledger:
`exposure: never`). The deploy goes in a web-round kit that Tony runs and types YES for:

1. Put a fresh random write token (`openssl rand -hex 32`) in the CT101 testnet `.env` as
   `CLAIM_MAILBOX_WRITE_TOKEN`, and the same value in the house consumer's own token file on its host.
   Never print it.
2. `docker compose -f testnet/docker-compose.testnet.yml --profile claim-mailbox build wrfcoin-claim-mailbox`
   on the build host, then `up -d wrfcoin-claim-mailbox` on CT101 from the kit. It starts **off**.
3. After the backend proxy and edge rule are live: `CLAIM_MAILBOX_ENABLED=true`, recreate only this
   container, and check `GET /health` says `enabled:true, writable:true`.

Off switch: `CLAIM_MAILBOX_ENABLED=false` and recreate the container. Owners then simply find no claim
(`NO_CLAIM`, exit 0); nothing on chain changes.
