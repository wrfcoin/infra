# Node address records (testnet, default OFF)

A bond on chain names its server key K but no address, so the house consumer can't find a newcomer's
node from the roster alone. Each bonded node publishes its own signed record "server key K is at these
addresses" once an epoch, and the consumer reads it. Nobody keeps any other list of node addresses.

```
bonded node: wrfcoin node address publish ── POST /addresses (public, signed) ──► claim mailbox
                                                                                    │ checks K against
house consumer: scripts/house-consumer-roster.sh ◄── GET /addresses/<K> (bearer) ──┘ GET /node/bonds/<id>
```

## Record

```json
{"version":1,"chain_id":"888","network_id":"testnet","genesis_hash":"<64 hex>",
 "deployment_id":"<64 hex bond id>","server_key":"<64 hex K>","peer_id":"12D3Koo...",
 "epoch":"41","height":"27300","multiaddrs":["/ip4/<public address>/tcp/9000/p2p/12D3Koo..."],
 "signature":"<128 hex>","peer_signature":"<128 hex>"}
```

Exactly these fields. 1 to 4 addresses, each `/ip4|ip6/<address>/tcp/<port>/p2p/<peer_id>`, at most 200 bytes, IPv6 in canonical
(RFC 5952) form as core4 writes it, public only: no private, CGNAT, loopback, link-local, documentation
(incl. `3fff::/20`), benchmarking (`2001:2::/48`), ORCHID (`2001:10::/28`, `2001:20::/28`), 6to4 (incl. the
`192.88.99.0/24` relay), Teredo or mapped ranges.

Signing preimage (`address-record.js`; core4 `tools/cli/WrfcoinCLI/src/commands/node_address.rs` freezes the
same bytes with a test vector that `address.test.js` repeats):

```
str(s) = u32LE(UTF-8 length) || UTF-8 bytes
M = "wrfcoin_node_address_record_v1"
    || str(chain_id) || str(network_id) || str(genesis_hash) || str(deployment_id) || str(server_key) || str(peer_id)
    || u64LE(epoch) || u64LE(height) || u32LE(n) || str(multiaddr_1) .. str(multiaddr_n)
signature      = Ed25519(server key K, M)
peer_signature = Ed25519(peer identity key, "wrfcoin_node_address_record_peer_v1" || M)
```

## What `POST /addresses` checks, in order

1. Enabled and configured (chain id, network id and genesis hash pinned); JSON body at most 4 KiB; shape.
2. `chain_id`, `network_id`, `genesis_hash` equal the pinned ones (`400 WRONG_CHAIN`).
3. Both signatures, strict Ed25519 as in core4 (`verify_strict`): small-order or non-canonical public keys
   and R, and S >= L, are refused before `crypto.verify` (`403 BAD_SIGNATURE`). No node read happens for
   anything that fails 1 to 3.
4. A record equal to the stored one answers `UNCHANGED`; an older one `409 STALE_RECORD`. Neither reads
   the node or spends K's budget, so replaying a node's record does nothing.
5. The bond must be in a cached roster of bonded server keys (REGISTERED, not exiting, not jailed), and K
   must be its server key (`403 NOT_BONDED` / `SERVER_KEY_MISMATCH`). The roster is refreshed at most once a
   minute (`NODE_ADDRESS_ROSTER_TTL_SECONDS`): one `/node/bonds` list plus a bond read only for new or changed
   bonds, at most 256 bonds. So a freshly made key that signs a valid record costs no node read.
6. At most 6 new records an hour per K (`429 RATE_LIMITED`), and a node-read budget (2 in flight,
   60 a minute, else `429 BUSY`).
7. `GET /node/bonds/<deployment_id>`: `REGISTERED`, not jailed, no exit pending, binding in effect for the
   record's epoch (`403 NOT_BONDED`); its server key is K
   (`403 SERVER_KEY_MISMATCH`); the record's epoch is the current one (`409 STALE_EPOCH` / `FUTURE_EPOCH`);
   its height is at most 10 blocks past the node's (`409 FUTURE_HEIGHT`). Node unreachable: `503 NODE_UNAVAILABLE`.
8. Stored only if `(epoch, height)` is newer than what is kept for K (atomic in Redis).

`GET /addresses/<K>` and `GET /addresses` (all live records, at most 256) need
`Authorization: Bearer <NODE_ADDRESS_READ_TOKEN>`, held only by the house consumer. They never go through the edge.

## Expiry, storage and privacy

- One Redis hash per K plus an index; every write resets the expiry to `NODE_ADDRESS_TTL_SECONDS`
  (default 118,272 s: 3 epochs of 512 blocks at ~77 s). A node that stops publishing drops out by itself.
- The only addresses stored are the ones nodes publish about themselves, for at most ~33 h after their
  last record. No client IP is read or stored (the service sits behind the backend proxy).
- Expiry removes a record from the live Redis only. Redis RDB/AOF files and any backup of them keep a copy
  until they are rewritten (next RDB save, AOF rewrite) or the backup ages out. Count that in "how long".
- Logs: one line per decision, `address decision=<CODE> key=<first 8 hex of K> epoch=<E>`. Never an address.
  Reads are not logged.

## Switches

| Variable | Default | Meaning |
|---|---|---|
| `NODE_ADDRESS_ENABLED` | `false` | Off: every `/addresses` route answers 404 (claims are unaffected) |
| `WRFCOIN_CHAIN_ID`, `WRFCOIN_NETWORK_ID`, `WRFCOIN_GENESIS_HASH` | compose / `testnet` / empty | Pinned chain identity; incomplete = `503 NOT_CONFIGURED` |
| `NODE_ADDRESS_NODE_URL` | `http://127.0.0.1:8556` (compose: `http://wrfcoin-node:8556`) | Node API for bond reads |
| `NODE_ADDRESS_NODE_READER_TOKEN` | empty | Optional reader bearer for that node |
| `NODE_ADDRESS_READ_TOKEN` | empty | House consumer read bearer; under 32 characters = reads refused (503) |
| `NODE_ADDRESS_TTL_SECONDS` | `118272` | 1 h to 14 days |
| `NODE_ADDRESS_WRITES_PER_HOUR` | `6` | New records per K per hour |
| `NODE_ADDRESS_NODE_READS_IN_FLIGHT` / `_PER_MINUTE` | `2` / `60` | Node-read budget |
| `NODE_ADDRESS_MAX_HEIGHT_AHEAD` | `10` | Blocks a record may be ahead of the mailbox's node |

## Public path

**The real off switches are the service flags:** `NODE_ADDRESS_ENABLED=false` on the mailbox (every
`/addresses` route 404) and `NODE_ADDRESS_PROXY_ENABLED=false` on the backend. `PUBLIC_READONLY_API` is
likely already `on` for the other public routes, so it does not keep this one closed by itself.

The service needs `WRFCOIN_CHAIN_ID=888` (the compose default is 777), the 888 genesis hash, and a node
Reader bearer (`NODE_ADDRESS_NODE_READER_TOKEN`, falls back to `WRFCOIN_READER_TOKEN`): `/node/bonds`
answers 401 without one.

Edge rule `@public_node_address_publish` (`POST /api/node-addresses`, JSON, 4 KiB, no query, zone
`node_address_write` 4 a minute per client) is gated by `PUBLIC_READONLY_API=on`, and the backend proxy
answers 404 until `NODE_ADDRESS_PROXY_ENABLED=true`. Turning it on is an owner web round: a fresh read token
in the CT101 testnet `.env` and the consumer's token file, the genesis hash, `NODE_ADDRESS_ENABLED=true`,
recreate only this container, then the proxy flag.
