# Bond admission service

Default **off**. It lets a node operator get the bond co-sign without the
genesis governance key, once the chain feature `bond_admission_key` is
scheduled and active.

## Why it exists

A node bond Deposit or Update needs a co-sign. Before `bond_admission_key`
the only accepted co-signer is the genesis governance key, which also
schedules chain features. That key never goes behind an automatic signer.

`bond_admission_key` (core4, unscheduled) lets a Deposit or Update be
co-signed by a key pinned in the node binary instead. That key can co-sign
only those two actions. This service holds the pinned key's file and decides
who gets the co-sign.

The 32-bond chain limit is the thing to protect: slots only come back when a
bond owner exits. The rules below keep one person from filling them.

## Flow

On the operator's machine (core4 CLI):

```sh
# 1. Keyless Deposit plan, naming the admission key as co-signer.
#    Use the generated alias node-<first 8 hex of the server key>.
wrfcoin node bond deposit ... --governance-key <admission public key> --admission-cosign \
  --service-alias node-<8 hex> --dry-run --out plan.json
# 2. Server and consumer approvals.
wrfcoin node bond sign --transaction-file plan.json --role server   --key-file server.key   ... --out s.json
wrfcoin node bond sign --transaction-file s.json    --role consumer --key-file consumer.key ... --out sc.json
# 3. Bind the node's public P2P address to the packet (peer identity key).
wrfcoin node bond admission-request --transaction-file sc.json \
  --multiaddr /ip4/<public ip>/tcp/9000/p2p/<peer id> --chain-id 888 --network-id testnet --out request.json
```

`POST /bond-admission` with `request.json`. On success the answer carries the
co-signed packet. The operator then adds the payout approval and submits with
`wrfcoin node bond deposit --approvals-file … --key-file owner.key`, inside the
same epoch. The service submits nothing.

## Checks, in order

| # | Check | Refusal |
|---|---|---|
| 1 | `BOND_ADMISSION_ENABLED=true` | 404 `ADMISSION_DISABLED` |
| 2 | Chain id set, network `testnet`, key file path set, address salt ≥ 16 chars | 503 `ADMISSION_UNAVAILABLE` |
| 3 | Shape. Address is `/ip4` or `/ip6`, public (no private, CGNAT, loopback, link-local, documentation or IPv4-mapped), ends in `peerId` | 400 / 422 `ADDRESS_NOT_PUBLIC` |
| 4 | `wrfcoin node bond admit` (no key): Deposit or Update only, co-signer is a pinned admission key for the packet's genesis, no co-sign yet, valid server and consumer signatures | 422 `ADMISSION_PACKET_REFUSED` |
| 5 | Peer signature over this packet's authorization hash and this address | 400 `INVALID_PEER_SIGNATURE` |
| 6 | Deposit: alias is `node-<first 8 hex of server key>` (aliases are public forever) | 422 `ALIAS_NOT_GENERATED` |
| 7 | The node is a sync peer of the network node, connected ≥ 24 h, advertising a recent height, not banned | 409 `NODE_NOT_VISIBLE` / `NODE_TOO_NEW` / `NODE_NOT_SYNCED` |
| 8 | Deposit: bonds on chain < soft ceiling (default 16) | 409 `ADMISSION_CEILING` |
| 9 | `wrfcoin node bond probe`: the service dials the address; that peer id answers the keyless `Info` for this chain and genesis | 409 `NODE_NOT_REACHABLE` / `NODE_WRONG_CHAIN` |
| 10 | Limits, in one atomic Redis step (below) | 409 / 429 |
| 11 | `wrfcoin node bond admit --key-file … --out …`: the co-sign, checked before it is returned | 503 `ADMISSION_SIGN_FAILED` (releases step 10) |

## Limits

Deposit:

- One admission per **server key**, ever. Exception, a **renewal**: the same deployment
  asks again from the same address for a later effective epoch, because its first packet
  missed the epoch. A renewal is not counted against the limits.
- One admission per **public address** for 30 days. Only an HMAC of the address (with
  `BOND_ADMISSION_IP_SALT`) is stored, and it expires.
  For IPv6 the address counted is the network prefix (`BOND_ADMISSION_IPV6_PREFIX_BITS`,
  default the /64), so every address of one home connection is the same address here,
  however it is written. Tunnel ranges over one IPv4 address (6to4, Teredo) are refused
  like CGNAT.
  Only global unicast IPv6 (`2000::/3`) is accepted. An IPv4 address written as IPv6
  (IPv4-mapped or IPv4-translated, in any spelling), NAT64 and local ranges are refused as
  not public. A mark written before prefix counting (a hash of the address
  text) still counts, and a renewal that matches it is rewritten to the prefix mark, unless
  another node already holds that prefix mark.
- At least **6 h** between admissions, across everyone.
- At most **2 a day** (UTC).

Update: one per deployment per effective epoch. Updates take no slot.

`GET /bond-admissions`: the last 100 admissions (action, deployment, server key, alias,
effective epoch, time). No addresses. Everything in it is public on chain anyway.

## Keys

- The service **never generates, copies or prints a key**. The operator provisions the
  admission seed file (`BOND_ADMISSION_KEY_FILE`, mode 0600, read-only mount).
- The CLI reads the file only on the final sign call, after every rule passed. The CLI
  child process gets only `PATH` and `HOME`, never this service's tokens or salt.
- `wrfcoin node bond admit` accepts a software key file on `testnet` only. Anywhere else
  the co-sign needs the dedicated HSM signer (`node bond sign --role admission`).
- What a stolen admission key costs: bonds admitted outside these rules. Each one still
  costs 250 WRF and a slot. It cannot schedule features, sign upgrade notices or touch
  Exit/Withdraw. The binary pins a cold spare, so a lost key needs no new feature.

## Log

One line per request: `decision=ADMITTED action=… deployment=<first 8 hex> epoch=…`, or
`decision=<refusal code>` (including `ADMISSION_BUSY`). No address, peer id or key is ever logged.

## Configuration

| Variable | Default |
|---|---|
| `BOND_ADMISSION_ENABLED` | `false` (the stop switch) |
| `WRFCOIN_CHAIN_ID`, `WRFCOIN_NETWORK_ID` | required; network must be `testnet` |
| `BOND_ADMISSION_KEY_FILE` | required (path only) |
| `BOND_ADMISSION_IP_SALT` | required, ≥ 16 chars |
| `BOND_ADMISSION_CLI` | `wrfcoin` |
| `BOND_ADMISSION_NODE_URL` | `http://127.0.0.1:8556` |
| `BOND_ADMISSION_READER_TOKEN` | Reader bearer for `/network/peers/sync` and `/node/bonds` |
| `REDIS_URL` | required when enabled |
| `BOND_ADMISSION_SOFT_CEILING` | `16` (1–32) |
| `BOND_ADMISSION_DAILY_CAP` | `2` (1–100) |
| `BOND_ADMISSION_MIN_INTERVAL_SECONDS` | `21600` |
| `BOND_ADMISSION_IP_TTL_SECONDS` | `2592000` (30 days) |
| `BOND_ADMISSION_IPV6_PREFIX_BITS` | `64` (an integer from `48` to `64`; any other value is ignored, named once in the startup log, and `64` is used) |
| `BOND_ADMISSION_MIN_PEER_AGE_SECONDS` | `86400` |
| `BOND_ADMISSION_MAX_LAG_BLOCKS` | `20` |
| `BOND_ADMISSION_MAX_ADVERT_AGE_SECONDS` | `300` |
| `BOND_ADMISSION_MAX_IN_FLIGHT` | `2` (more get 429 `ADMISSION_BUSY`) |
| `PORT` | `8094` |

## Image (compose profile `bond-admission`)

`docker compose --profile bond-admission` starts `wrfcoin-bond-admission`. It has no host port; only the backend
proxy reaches it (`BOND_ADMISSION_URL=http://wrfcoin-bond-admission:8094` on the backend).

1. Build the release CLI on CT102 inside the same base as the node image (Debian bookworm, glibc), from the core4
   revision that pins the admission keys. Copy it to `testnet/services/bond-admission/bin/wrfcoin`; that directory
   is git-ignored.
2. Build with `BOND_ADMISSION_CLI_SHA256=<sha256 of that file>`. The build refuses a missing or different hash and
   checks that the binary starts.
3. Key: the online seed file, owned by uid 1001, mode 0600, in a host directory named by `BOND_ADMISSION_KEY_DIR`,
   mounted read-only at `/run/bond-admission`. A missing directory or file means every co-sign is refused (503).
4. Set `BOND_ADMISSION_IP_SALT` (16+ chars) in the host env file. `BOND_ADMISSION_ENABLED` stays `false` until the
   owner switches it on.

The container runs read-only, no capabilities, `/tmp` tmpfs only.

## Tests

`npm test`. The CLI and the network node are stand-ins; core4 tests the packet rules
(`node_bond_admit.rs`). The peer-signature layout is checked against a vector frozen in
core4. Set `BOND_ADMISSION_TEST_REDIS_URL` to a throwaway local Redis to run the limits
through the real Lua.
