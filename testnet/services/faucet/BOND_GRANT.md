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
| `peerSignature` | ed25519 proof of possession of the peer identity key over the peer message below. |

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
2. **Caller.** The operator bearer is required by default. Direct captcha
   callers are accepted only with `FAUCET_BOND_GRANT_PUBLIC=true`; an invalid
   supplied bearer is always refused.
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
   `FAUCET_BOND_GRANT_DAILY_COUNT_CAP` (default 2). Otherwise it marks all
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
| `FAUCET_BOND_GRANT_DAILY_COUNT_CAP` | `2` (1–100) |
| `FAUCET_BOND_GRANT_PUBLIC` | `false` |
| `FAUCET_BOND_GRANT_MIN_PEER_AGE_SECONDS` | `86400` (1–2592000) |
| `FAUCET_BOND_GRANT_MIN_INTERVAL_SECONDS` | `21600` (1–604800) |
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

## Self-serve pacing (owner-approved spec 2026-10-23)

A peer must have numeric `connection_age_secs` of at least 86400 (24 h).
Missing, invalid or young ages fail closed with 409 `NODE_TOO_NEW` and
`retryAfterSeconds`, before any Redis reservation. Existing sync checks remain.
The identity/daily Lua reservation also atomically reserves a global gap of
21600 seconds (6 h). A paid or pending grant keeps the gap; definitive
non-admission releases only its own gap. Spacing refusal is 429
`BOND_GRANT_SPACING` with `Retry-After`. Two grants per UTC day is the default.
One grant ever per server key, peer id and owner wallet remains unchanged.
Numeric settings accept whole integers within the documented bounds; invalid
values fall back to defaults. Maximum lag accepts 1–1000, advert age 1–86400.

`GET /faucet/bond-grants` requires `FAUCET_READER_TOKEN` unless
`FAUCET_BOND_GRANT_PUBLIC=true`. It returns `{ "grants": [...] }`, newest
first, at most 100 successful grants. Each row contains exactly
`ownerAddress`, `peerId`, `serverKey`, `txHash`, `time` (ISO UTC), `bonded`.
No IPs, bodies, reservation tokens, or upstream error details are exposed.
This bounded history starts with this version; lifetime identity marks remain.

**Bond status: not yet available.** Per LEAD addendum 1, every row currently
has `bonded: null`. Core4 `GET /node/bonds/{id}` needs a deployment id, which
is a separate input in CLI `node_deposit.rs` and absent from grant records.
`node_bond_registry.rs::node_bond_escrow_address` derives an escrow from an id;
it does not derive the id from grant fields. A follow-up needs a sourced
mapping before true/false resolution and its 60-second cache can be enabled.
No Core4 route is added here.

No deploy: the owner enables it after the first payout. Both switches default
OFF. No host `.env` change is part of this work.

## Peer possession amendment (LEAD addendum 2, 2026-10-23)

The requester must control both the bond server key and the libp2p identity
behind `peerId`. The faucet verifies **both signatures**, including requests
with an operator bearer. Missing/invalid peer proof, malformed ids, hashed
(non-identity) multihashes and non-ed25519 keys return 400
`INVALID_BOND_GRANT_REQUEST` before any chain read or Redis reservation.
Merely naming a long-connected peer does not satisfy probation.

With `FAUCET_BOND_GRANT_PUBLIC=false`, the former captcha-only public path
from public main is removed. This is intentionally stricter than main.

### Final byte layout (for the Core4 CLI)

`signature = Ed25519.sign(server_private_key, M)` where:

```text
M = UTF8("wrfcoin_faucet_bond_grant_v1")
    || str(chain_id) || str(network_id)
    || str(ownerAddress) || str(serverKey) || str(peerId)
    || u64LE(height) || str(blockHash)
str(s) = u32LE(UTF8(s).length) || UTF8(s)
```

`peerSignature = Ed25519.sign(peer_private_key, P)` where:

```text
P = UTF8("wrfcoin_faucet_bond_grant_peer_v1") || M
```

Both domain strings are raw UTF-8 bytes, with **no length prefix or NUL**.
Neither message is hashed before Ed25519 signing. `M` is exactly the same
byte array for both signers. `peerSignature` and `signature` themselves are
not fields of `M`. Chain/network ids are strings; wallet is lowercase `0x`
plus 40 hex; server key is lowercase 64 hex; peer id is the canonical,
unprefixed base58btc string; height is eight unsigned little-endian bytes;
block hash is lowercase 64 hex without `0x`. Signatures are 128 lowercase hex.

The accepted peer id decodes to these 38 bytes:
`00 24 08 01 12 20 || peer_ed25519_public_key[32]`.
`00` is the identity multihash code, `24` its 36-byte digest length, and
`08 01 12 20` is protobuf PublicKey Type=Ed25519 (1), Data length=32.
Reject every other layout; do not treat a hash as an embedded public key.

### Node identity file / request builder

Core4 `p2p/src/identity.rs::load_or_generate_keypair` writes
`Keypair::to_protobuf_encoding()` to `<node-data-dir>/peer_identity.key`.
The launch API chooses that path in `native-chain/src/bin/launch_api/main.rs`.
For ed25519, the 68-byte file is protobuf PrivateKey:
`08 01 12 40 || seed[32] || public_key[32]`. It is binary, not hex text.
The builder checks its owner-only file permissions on Unix, exact encoding,
seed/public-key consistency, and that the key matches the node's peer id.
It never prints either private key. Do not copy this file into a web client.

```sh
node bond-grant-request.js --owner 0x<BOND_OWNER> \
  --server-key-file <server-seed-hex-file> \
  --peer-key-file <node-data-dir>/peer_identity.key \
  --chain-id 888 --network-id testnet --node http://127.0.0.1:8556
```

The request contains both signatures. The backend's one-use captcha proof
(`challengeId`, `answer`) is appended separately and is not signed.

### Frozen reference vector

`bond-grant-peer-vector.json` is the machine-readable copy; tests compare
both preimages and both signatures byte-for-byte. All seeds in that fixture
are deterministic public test data, never operator credentials. The libp2p
reference generated the peer id, protobuf private key and peer signature:

Node v24.15.0; `@libp2p/crypto` 5.2.0; `@libp2p/peer-id` 6.0.18.

Reference calls: `generateKeyPairFromSeed('Ed25519', Uint8Array(32).fill(2))`,
`peerIdFromPrivateKey(peerKey).toString()`, `privateKeyToProtobuf(peerKey)`,
and `peerKey.sign(P)`. The server test seed is `Uint8Array(32).fill(1)`.
The helper's peer signature equals the independently signed libp2p result.
The packages are used only to generate the reference, not at faucet runtime.

```json
{
  "chainId": "888",
  "networkId": "testnet",
  "peerPublicKeyHex": "8139770ea87d175f56a35466c34c7ecccb8d8a91b4ee37a25df60f5b8fc9b394",
  "request": {
    "ownerAddress": "0x3333333333333333333333333333333333333333",
    "serverKey": "8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c",
    "peerId": "12D3KooWJWoaqZhDaoEFshF7Rh1bpY9ohihFhzcW6d69Lr2NASuq",
    "height": 42,
    "blockHash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "signature": "dcca8a3707f2d8004f826330002b44ae8bf6dab50084c7bfce8b6336c15d8c45b8babf67f1a5ae8a6a8085f88822fad257a14cebc473c5f5769ac9d7a1957a0f",
    "peerSignature": "3735d36b70f2033a99bd369d9c3cbd33ec1dcf339efb8bb7edcc25dc53a35a18cea79cf9d641304a99e82a6339f21afb783972495bcf0aa7698463d83a95d800"
  },
  "serverMessageHex": "777266636f696e5f6661756365745f626f6e645f6772616e745f76310300000038383807000000746573746e65742a000000307833333333333333333333333333333333333333333333333333333333333333333333333333333333400000003861383865336464373430396631393566643532646232643363626135643732636136373039626631643934313231626633373438383031623430663666356334000000313244334b6f6f574a576f61715a6844616f454673684637526831627059396f68696846687a6357366436394c72324e415375712a000000000000004000000061616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161",
  "peerMessageHex": "777266636f696e5f6661756365745f626f6e645f6772616e745f706565725f7631777266636f696e5f6661756365745f626f6e645f6772616e745f76310300000038383807000000746573746e65742a000000307833333333333333333333333333333333333333333333333333333333333333333333333333333333400000003861383865336464373430396631393566643532646232643363626135643732636136373039626631643934313231626633373438383031623430663666356334000000313244334b6f6f574a576f61715a6844616f454673684637526831627059396f68696846687a6357366436394c72324e415375712a000000000000004000000061616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161"
}
```
