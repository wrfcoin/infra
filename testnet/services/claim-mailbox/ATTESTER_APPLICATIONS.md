# Attester applications (testnet, default OFF)

A bonded node operator who wants to run an oracle attester asks for a seat with a signed **application**.
The owner reviews the open applications and seats approved ones in one governance-signed batch. A seated
attester leaves the same way, with a signed **step-down**. The mailbox only collects and checks the
records; it never changes the oracle set.

```
bonded node (CLI / dashboard) ── POST /attester-applications (public, signed) ──► claim mailbox
                                                                                    │ checks K against the
owner review tool (ws) ◄── GET /attester-applications (owner bearer) ──────────────┘ bond on chain and the
                                                                                      seated oracle set
```

## Record

```json
{"version":1,"kind":"apply","chain_id":"888","network_id":"testnet","genesis_hash":"<64 hex>",
 "bond_id":"<64 hex bond (deployment) id>","server_key":"<64 hex K>","oracle_pubkey":"<64 hex>",
 "epoch":"55","height":"28100","settings_version":"1","client_version":"0.9.0-preview9",
 "signature":"<128 hex>","oracle_signature":"<128 hex>"}
```

Exactly these fields, all hex lowercase:

| Field | Rule |
|---|---|
| `version` | the JSON number `1` |
| `kind` | `"apply"` or `"step_down"` |
| `chain_id`, `network_id` | `[0-9A-Za-z_-]{1,32}`, must equal the pinned ones |
| `genesis_hash` | 64 hex, must equal the pinned one |
| `bond_id` | 64 hex: the bond's deployment id |
| `server_key` | 64 hex: K, the bond's registered server public key |
| `oracle_pubkey` | 64 hex: the Ed25519 public key to be seated (or stepping down); never equal to K |
| `epoch`, `height` | decimal text below 2^53, no leading zeros: the node's current epoch and height |
| `settings_version` | decimal text 1..999999999: the `WRFCOIN_ATTESTER_SETTINGS_VERSION` the attester runs (`testnet/attester/`) |
| `client_version` | `[0-9A-Za-z._+-]{1,40}`: the signing client's version |
| `signature`, `oracle_signature` | 128 hex Ed25519 signatures, below |

No payout address, IP address, name or email is in the record.

## Signing preimage (byte for byte)

`attester-application.js` builds it; `attester-application.test.js` freezes a test vector. A CLI that signs
applications must reproduce the vector exactly.

```
str(s) = u32LE(UTF-8 byte length of s) || UTF-8 bytes of s
M = UTF8("wrfcoin_attester_application_v1")          (31 bytes, no length prefix)
    || str(kind) || str(chain_id) || str(network_id) || str(genesis_hash)
    || str(bond_id) || str(server_key) || str(oracle_pubkey)
    || u64LE(epoch) || u64LE(height) || u32LE(settings_version) || str(client_version)
signature        = Ed25519(K, M)
oracle_signature = Ed25519(oracle key, UTF8("wrfcoin_attester_application_oracle_v1") || M)
```

- Hex fields are signed as their 64-character lowercase **text** (as in the node address record), not as
  raw bytes.
- `epoch`, `height` and `settings_version` are signed as integers (the JSON carries them as text).
- Both signatures are verified strictly (as ed25519-dalek `verify_strict`): small-order or non-canonical
  public keys and R, and S >= L, are refused.
- Domain separation: `M` starts with its own domain string, so it can't be confused with an address
  record (`wrfcoin_node_address_record_v1`) or any other signed message. The oracle key signs a second
  domain prefix in front of `M`, so its signature can't be lifted onto a K-signed message or the other way
  round.
- Binding: chain id, network id and genesis hash bind it to one chain; epoch and height bind it in time
  (the mailbox takes only the current epoch); bond id and K bind it to one bond.

### Test vector

Seeds (32 identical bytes each, as Ed25519 private seeds): K = `[11; 32]`, oracle key = `[7; 32]`.

```
K             = 66be7e332c7a453332bd9d0a7f7db055f5c5ef1a06ada66d98b39fb6810c473a
oracle_pubkey = ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c
fields        = kind "apply", chain_id "888", network_id "testnet", genesis_hash "ab" x 32,
                bond_id "01" x 32, epoch 55, height 28100, settings_version 1, client_version "0.9.0-preview9"
len(M)        = 368
sha256(M)     = daad9c1093ed7de1b819c4badb3d54ed8bc50c6d4d750f4a45990976b4f76d6e
signature     = 8bbbf8a9436afb51dfd2fd1a8270a531866dd53bd2bfa7d395f6aa8bf4c7e105ad9fab30ee98fc6a19ceec340292a5aebbdd7985af52543b6418b08da4c22900
oracle_sig    = f6e28039f00c61485ac398eb91a294977bb977005cdbcfaf08d8e7f4dd65b25156637faa7b1a8a493db0a941c4296fbbddb1547acd93f72b80d95e36a828930c

kind "step_down", otherwise the same:
sha256(M)     = fd0ab3306948aa491192143857759f97b139cfc8b7c13ed9d183099db82af192
signature     = 2ce98586689359a54c977576f62cefa16a994485c82c7c5efb57d07d0bea665951939ede38f7c43da56c1ce8ea0f0e23667fb72837cd4b12ccc6187e6c79fb08
oracle_sig    = a6ac52e6856c76d812d28385f0d533d46dc5daeb32af31b27e87f2c5015a44681aa542da9283e2ede337bea318561ae92f952c55b53b27c14f8f2908abe65d01
```

The full hex of `M` is spelled out field by field in the test `the signing preimage and both signatures
are frozen`. The vector was also reproduced with an independent Ed25519 implementation (Python
`cryptography`).

## What `POST /attester-applications` checks, in order

1. Enabled and configured (chain id, network id and genesis hash pinned); JSON body at most 4 KiB; shape;
   `oracle_pubkey` != K (`403 KEY_REUSE`).
2. `chain_id`, `network_id`, `genesis_hash` equal the pinned ones (`400 WRONG_CHAIN`).
3. Both signatures, strict Ed25519 (`403 BAD_SIGNATURE`).
4. `oracle_pubkey` is not a forbidden role key (`ATTESTER_APPLICATION_FORBIDDEN_KEYS`: governance,
   producers, snapshot signers; `403 FORBIDDEN_KEY`). No node read happens for anything that fails 1 to 4.
5. A record equal to the stored one for this bond answers `UNCHANGED`; an older one `409 STALE_RECORD`.
   Neither reads the node or spends K's budget.
6. The bond is in the cached roster of bonded server keys (REGISTERED, not exiting, not jailed) and K is
   its server key (`403 NOT_BONDED` / `SERVER_KEY_MISMATCH`). This is the same roster, refreshed at most
   once a minute, that node address records use: a fresh key costs no per-request node read.
7. At most 6 accepted applications an hour per K (`429 RATE_LIMITED`); the node-read budget is shared with
   address records (2 in flight, 60 a minute, else `429 BUSY`).
8. `GET /node/bonds/<bond_id>`: as for address records: registered, not jailed, no exit pending, binding in
   effect, server key K, the record's epoch is the current one (`409 STALE_EPOCH` / `FUTURE_EPOCH`), height
   at most 10 blocks ahead (`409 FUTURE_HEIGHT`).
9. `GET /transactions/oracle/config` (cached for the roster TTL): K is not a seated oracle key
   (`403 FORBIDDEN_KEY`); for `apply` the oracle key is not already seated (`409 ALREADY_SEATED`); for
   `step_down` it is seated (`409 NOT_SEATED`).
10. Stored only if `(epoch, height)` is newer than what is kept for the bond, and no other bond holds a live
    application for the same oracle key (`409 ORACLE_KEY_IN_USE`). Atomic in Redis. A newer record that
    names a different oracle key releases the old one.

So each bond has at most one live record (apply or step-down; the newest wins), and each oracle key at
most one bond.

## Reads

| Route | Who | Answer |
|---|---|---|
| `GET /attester-applications` | `Authorization: Bearer <ATTESTER_APPLICATION_OWNER_TOKEN>` | all live records (at most 256) |
| `GET /attester-applications/<bond_id>` | owner bearer | one record, or `404 NO_RECORD` |
| `GET /attester-applications/counts` | anyone | `{"apply": n, "step_down": m}` only |

The owner bearer is its own token, not the house consumer's address-read token. Reads are not logged.

## Expiry, storage and privacy

- Records expire after `ATTESTER_APPLICATION_TTL_SECONDS` (default 236,544 s: 6 epochs of 512 blocks at
  ~77 s, about 2.7 days, so an application outlives a weekend). A node that still wants a seat re-signs
  for the current epoch.
- Redis keys: one hash per bond, one string per oracle key naming its bond, an index sorted by expiry, a
  per-K hourly counter. Every key expires. Redis RDB/AOF files and their backups keep a copy until they
  are rewritten.
- The record holds only public keys and chain facts. No client IP is read or stored.
- Logs: one line per decision,
  `attester decision=<CODE> kind=<kind> bond=<first 8 hex> oracle=<first 8 hex> epoch=<E>`.

## Switches

| Variable | Default | Meaning |
|---|---|---|
| `ATTESTER_APPLICATIONS_ENABLED` | `false` | Off: every `/attester-applications` route answers 404 |
| `ATTESTER_APPLICATION_OWNER_TOKEN` | empty | Owner read bearer; under 32 characters = reads refused (503) |
| `ATTESTER_APPLICATION_TTL_SECONDS` | `236544` | 1 h to 28 days |
| `ATTESTER_APPLICATION_WRITES_PER_HOUR` | `6` | Accepted applications per K per hour |
| `ATTESTER_APPLICATION_FORBIDDEN_KEYS` | empty | Comma-separated 64-hex public keys that may never be an oracle key |
| shared with address records | | `WRFCOIN_CHAIN_ID`, `WRFCOIN_NETWORK_ID`, `WRFCOIN_GENESIS_HASH`, `NODE_ADDRESS_NODE_URL`, `NODE_ADDRESS_NODE_READER_TOKEN`, roster TTL, node-read budget, max height ahead |

## Public path

Not wired yet. Like `POST /api/node-addresses`, the public `POST /api/attester-applications` would be an
edge rule to the backend plus a backend proxy to this route, each behind its own switch. Neither is in
this change; until both land (and `ATTESTER_APPLICATIONS_ENABLED=true`), applications can't reach the
mailbox from outside. Turning it on is an owner web round: the genesis hash, a fresh owner token in the
CT101 testnet `.env` and the owner's own token file on ws, the forbidden-key list, the flag, recreate
only this container.

## Not in this change

- An applicant reading its own record's status (seated / declined) with a K-signed challenge.
- Owner-marked outcomes and re-apply cooldowns stored in the mailbox.
