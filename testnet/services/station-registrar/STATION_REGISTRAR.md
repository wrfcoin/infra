# Station registrar service

Default **off**. It lets a phone owner get their station registered on chain
without the genesis governance key, once the chain feature
`station_registrar_key` is pinned and scheduled.

## Why it exists

A phone station only earns once a registration signed by an authorized key
is on chain. Today that key is the genesis governance key, which also
schedules chain features and signs upgrade notices. That key never goes
behind an automatic signer, so today every phone waits for the owner's batch
(`testnet/docs/MOBILE_STATION_ACTIVATION.md`).

`station_registrar_key` (core4, unscheduled) lets a registration be signed by
a key pinned in the node binary instead, but only for a **new phone-class
station**: `phone-barometer`, tier `unverified`, provenance `real`, the owner's
slot-0 `mob-` id, v2 with `expected_nonce` 0, coordinates exactly on the 0.1
degree grid, no elevation, at most one per block, and under a compiled
ceiling of 128 phone stations. The key can sign nothing else. This service
holds the online key's file and decides who gets a signature.

The chain's limits are what bound a stolen key. The limits below are what
stop a bad day before it is on chain.

## Flow

1. The phone (through the backend or the public edge) sends `POST
   /station-registrar/requests` with the owner-signed row it already builds
   for the owner's batch: `station_id`, `owner_address`, `owner_pubkey`,
   `owner_signature`, `latitude`, `longitude`, `hardware_model`,
   `provenance_class`, `data_quality_tier`. Nothing else.
2. The service checks it (below). If it passes, the answer is `202` with
   `status: held` and `releaseAt`, 24 h later.
3. After the hold, the release loop re-checks the chain, has the CLI sign
   with the online key, and submits it to the node's station route. One at a
   time: the next is signed only after the previous one shows in the
   registry and the chain has moved on a block.
4. `GET /station-registrar/requests/<station id>` answers `held`,
   `submitted`, `registered`, `refused` or `needs_review`. No address, no
   coordinates.

## Checks on a request, in order

| # | Check | Refusal |
|---|---|---|
| 1 | `STATION_REGISTRAR_ENABLED=true` and no stop file | 503 `REGISTRAR_STOPPED` |
| 2 | Chain id, network `testnet`, genesis hash, key file path, state file, node token, address salt ≥ 16 chars | 503 `REGISTRAR_UNAVAILABLE` |
| 3 | The visitor's address is known (from the edge's `X-Forwarded-For` only when the connection comes from a listed proxy) | 400 `CLIENT_ADDRESS_UNKNOWN` |
| 4 | Shape: exactly the nine fields; the chain's registrar limits (phone, unverified, real, slot-0 `mob-` id, on the grid, no elevation) | 422 `REGISTRATION_REFUSED` |
| 5 | The node is on this chain; `station_registrar_key` is active; `station_coordinates_fixed_point` is not (this service doesn't build integer coordinates yet) | 503 `REGISTRAR_WRONG_CHAIN` / `REGISTRAR_NOT_ACTIVE` / `REGISTRAR_FORMAT_UNSUPPORTED` |
| 6 | The station is not in the registry and its owner-ledger nonce is 0 | 409 `STATION_ALREADY_REGISTERED` / `STATION_NOT_NEW` |
| 7 | Active phone stations in the registry < soft ceiling (default 128, never above it) | 409 `REGISTRAR_CEILING` |
| 8 | `wrfcoin station registrar-sign --check` (no key): the owner proof verifies and is bound to the address, and the row is inside the registrar limits, exactly as the chain checks it | 422 `REGISTRATION_REFUSED` |
| 9 | Limits, in one serialized step (below) | 409 / 429 |

Before signing, the release loop repeats 5 to 7. A station registered some
other way during the hold is marked `refused` and never signed.

## Limits

Approved by the owner 2026-11-07. Off chain: they change without a release.

- **One request per station, ever.** The station id is derived from the
  wallet, so this is one per wallet.
- **20 a day in total**, over any trailing 24 h.
- **3 a day per public address.** IPv6 counts per /64. Only an HMAC of the
  address (`STATION_REGISTRAR_IP_SALT`) is kept, for 30 days.
- **3 a day per 0.1 degree cell.**
- **24 h hold** between acceptance and signing, so a bad day can be stopped
  before anything is on chain.
- **Stop switch:** `STATION_REGISTRAR_ENABLED=false`, or create the file named
  by `STATION_REGISTRAR_STOP_FILE` (no restart). Both stop acceptance and
  signing. Stations already on chain stay.
- **At most one in flight.** One registrar registration per block is a chain
  rule (a second one in the same block is mined as nothing), so the service
  never sends two at once.
- **Never resent.** A submission whose answer was lost (`SUBMIT_UNKNOWN`) or a
  signer failure (`SIGN_FAILED`) pauses all releases until a person reads it
  back. One that isn't in the registry 6 blocks later goes to `needs_review`.

Left out: email, accounts, Play Integrity or App Attest.

## What is stored

One JSON file (`STATION_REGISTRAR_STATE_FILE`), mode 0600, rewritten
atomically. Per request: station id, the address HMAC, the cell (integer
tenths), times and status. While held it also keeps the owner-signed row (its
coordinates are on the 0.1 degree grid and become public on chain anyway).
The row is dropped once the request is submitted or refused. Finished records
are deleted after 30 days.

## Keys

- The service **never generates, copies or prints a key**. The operator
  provisions the online registrar key file (`STATION_REGISTRAR_KEY_FILE`,
  mode 0600, read-only mount). The cold spare never comes near this host.
- The CLI reads the file only on the final sign call, after every rule
  passed. The CLI child gets only `PATH` and `HOME`, never this service's
  token or salt.
- The registrar key must never be added to `WRFCOIN_ORACLE_GOVERNANCE_PUBKEYS`
  or any other env list: that list also trusts upgrade notices.
- What a stolen online key costs: up to 128 fake phone stations at most one a
  block (about 2.7 h to fill), phone class only, no effect on existing
  stations. The owner deactivates each with the governance key. Retiring the
  key takes a release; the pinned cold spare carries on.

## The CLI contract this service calls

`wrfcoin --json station registrar-sign --row-file <file> --chain-id <id>
--network-id testnet --genesis-hash <block-1 hash> --expected-nonce 0`, then:

- with `--check`: no key read. Answers `{ok: true, data: {station_id,
  owner_proof: "valid"}}` or `{ok: false, error: {message}}`.
- with `--submitted-at <unix> --key-file <file> --out <file>`: signs one v2
  registration as the registrar key, refuses unless that key is pinned for the
  genesis, writes `{chain_id, network_id, transactions: [one]}` and answers
  `{ok: true, data: {signed: true}}`.

**This command is not in core4 yet** (`station build-registration` refuses a
key that is not in the governance allowlist). It is a core4 CLI change that
must land before this service can sign; until then every `--check` fails and
the service accepts nothing (fail closed).

## Configuration

| Variable | Default |
|---|---|
| `STATION_REGISTRAR_ENABLED` | `false` |
| `STATION_REGISTRAR_STOP_FILE` | unset (a path; while that file exists, nothing is accepted or signed) |
| `WRFCOIN_CHAIN_ID`, `WRFCOIN_NETWORK_ID` | required; network must be `testnet` |
| `STATION_REGISTRAR_GENESIS_HASH` | required, the chain's block-1 hash |
| `STATION_REGISTRAR_KEY_FILE` | required (path only) |
| `STATION_REGISTRAR_STATE_FILE` | required when enabled |
| `STATION_REGISTRAR_NODE_URL` | `http://127.0.0.1:8556` |
| `STATION_REGISTRAR_NODE_TOKEN` | Operator bearer: the station list and the station POST |
| `STATION_REGISTRAR_IP_SALT` | required, ≥ 16 chars |
| `STATION_REGISTRAR_TRUSTED_PROXIES` | comma list of the edge's addresses; unset trusts none |
| `STATION_REGISTRAR_CLI` | `wrfcoin` |
| `STATION_REGISTRAR_DAILY_TOTAL` | `20` (1–100) |
| `STATION_REGISTRAR_DAILY_PER_IP` | `3` (1–100) |
| `STATION_REGISTRAR_DAILY_PER_CELL` | `3` (1–100) |
| `STATION_REGISTRAR_HOLD_SECONDS` | `86400` (3600–604800) |
| `STATION_REGISTRAR_SOFT_CEILING` | `128` (1–128) |
| `STATION_REGISTRAR_CONFIRM_BLOCKS` | `6` |
| `STATION_REGISTRAR_TICK_SECONDS` | `30` |
| `STATION_REGISTRAR_RETENTION_SECONDS` | `2592000` (30 days) |
| `PORT` | `8095` |

## Not in this change

- No Dockerfile, compose entry, backend proxy or edge route. The service
  needs the core4 CLI built with the pinned keys, so its image comes with the
  release that pins them.
- Nothing is enabled. The chain refuses every registrar registration until
  `station_registrar_key` is pinned for this chain and scheduled.

## Tests

`npm test` (or `bash scripts/tests/test-station-registrar-service.sh`). No
dependencies. The CLI and the node are stand-ins and no key is read or
written; core4 tests the signature and the chain rules. The station id is
checked against the vector frozen in core4.
