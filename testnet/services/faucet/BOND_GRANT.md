# Faucet bond grant (design note)

Refs infra#1332, core4#3592. Owner ruling 2026-10-19 20:12Z: on chain 888 the
node bond stays 250.36 WRF, and newcomers get a one-time faucet bond grant.

## What it pays

One transfer of `FAUCET_BOND_GRANT_AMOUNT`, default **250.36 WRF**
(25036000000 base units), to the node's **bond owner account**. The amount is
the 250 WRF bond (core4 `NODE_BOND_WRF`) plus 0.36 WRF of lifecycle fee
headroom. That matches what each 777 bond owner was funded with.

A bond Deposit locks the owner account's existing balance, and core4 has no
"pay into escrow" path. So the grant goes to the owner account that the node
names. The request binds that owner to the node's bond server key, so the
balance is earmarked for that key's Deposit. The faucet cannot force the
Deposit to happen. Each paid grant is recorded with its server key, peer id,
owner and transaction hash, so an operator can compare grants against bond
registrations later.

## Request

`POST /faucet/bond-grant` with JSON:

| Field | Meaning |
|---|---|
| `ownerAddress` | Bond owner account, `0x` or `wrf` + 40 hex. Receives the grant. |
| `serverKey` | The node's bond **server key**, 32-byte ed25519 public key, hex. It is the key that signs `NodeBondPossession` with role Server in the Deposit. |
| `peerId` | The node's libp2p peer id. |
| `height`, `blockHash` | A block the node holds, near the tip. |
| `signature` | ed25519 signature by the server key over the message below. |

The signed message is:

```
"wrfcoin_faucet_bond_grant_v1"
  || str(chain_id) || str(network_id)
  || str(ownerAddress)   (normalized 0x lowercase)
  || str(serverKey)      (lowercase hex)
  || str(peerId)
  || u64LE(height)
  || str(blockHash)      (lowercase hex, no 0x)
str(s) = u32LE(byte length) || UTF-8 bytes
```

It uses the same length-prefixed encoding as the faucet's transfer
authorization. Binding the chain id and network id means a 777 signature never
verifies on 888. Binding a recent block makes an old signature expire on its
own.

`bond-grant-request.js` builds this request for an operator. It has no
dependencies. It reads the node's own peer id and a block two under its tip
from the node API, and signs with a 32-byte seed file. It prints the JSON and
never prints the key.

## Checks, in order

1. **Feature on.** `FAUCET_BOND_GRANT_ENABLED=true`, otherwise 404.
2. **Caller.** The backend proxy's operator bearer, or a captcha on the public
   path, exactly as for the drip.
3. **Shape and signature.** Malformed fields give 400. A signature that does not
   verify gives 400. Nothing has been reserved yet.
4. **Synced and visible, on the faucet's own node.**
   - The signed height is at most the tip and at most
     `FAUCET_BOND_GRANT_MAX_LAG_BLOCKS` (default 20) behind it.
   - The node's block at that height has the signed hash.
   - The peer id is in `GET /network/peers/sync`, is not banned, advertises a
     height within the lag window, and its advertisement is at most
     `FAUCET_BOND_GRANT_MAX_ADVERT_AGE_SECONDS` (default 300) old.

   A failed check gives 409 `NODE_NOT_VISIBLE` or `NODE_NOT_SYNCED`. A failed
   chain read gives 503. Neither reserves anything.
5. **Abuse controls, in one Redis Lua call.** The call refuses when the server
   key, the peer id or the owner wallet already has a grant or a pending one.
   It also refuses when today's grant **count** has reached
   `FAUCET_BOND_GRANT_DAILY_COUNT_CAP` (default 4). Otherwise it marks all
   three and counts the grant. The three marks never expire. The daily count
   expires at the end of the UTC day.
6. **Transfer.** The grant uses the same nonce fence, in-flight guard, balance
   floor and outcome rules as the drip:
   - A definitive node rejection releases the marks and the count.
   - An unknown outcome keeps them, records a `bond_grant` pending claim, and
     answers `CLAIM_PENDING`.
   - Success rewrites the marks with the transaction hash.

The drip's per-wallet, per-device and global WRF caps are not charged. The
bond grant has its own count cap. A grantee can still use the normal drip for
fees.

## What this does not stop

- One operator with several machines can claim once per machine. Each one
  needs a distinct server key, a distinct peer id that the faucet node sees
  syncing, and a distinct wallet. The daily count cap bounds the total.
- A grantee who never bonds keeps 250.36 WRF of testnet value. The audit trail
  is the record; there is no clawback.

## Configuration

| Variable | Default |
|---|---|
| `FAUCET_BOND_GRANT_ENABLED` | `false` |
| `FAUCET_BOND_GRANT_AMOUNT` | `250.36` |
| `FAUCET_BOND_GRANT_DAILY_COUNT_CAP` | `4` |
| `FAUCET_BOND_GRANT_MAX_LAG_BLOCKS` | `20` |
| `FAUCET_BOND_GRANT_MAX_ADVERT_AGE_SECONDS` | `300` |
| `FAUCET_READER_TOKEN` | falls back to `FAUCET_API_TOKEN` |
| `FAUCET_TIP_PATH`, `FAUCET_BLOCK_PATH`, `FAUCET_SYNC_PEERS_PATH` | `/network/info`, `/chain/block/{height}`, `/network/peers/sync` |
| `FAUCET_BOND_GRANT_PREFIX` | `faucet:bond-grant:` |

The faucet must run with `WRFCOIN_CHAIN_ID` and `WRFCOIN_NETWORK_ID` set to the
live chain. The sync-peer route exists only on a node built with P2P.

## Not in this change

The faucet has no public host. Public drip claims reach it through the
backend onboarding proxy and the edge allowlist. A public bond grant needs the
same two pieces: a backend route that forwards to `/faucet/bond-grant` with
the operator bearer, and its edge allowlist entry. Until then, the grant works
for calls that carry the operator token.
