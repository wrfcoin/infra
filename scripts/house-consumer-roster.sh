#!/usr/bin/env bash
# House consumer roster (epic 6 self-serve bonding, node address records).
#
# For an owner kit, not a cron by itself. One pass per epoch:
#   1. read the bond roster from the house node (public chain data);
#   2. for each other bonded node, read its server key K from GET /node/bonds/<id>;
#   3. read the node's own signed address record for K from the address mailbox
#      (testnet/services/claim-mailbox/NODE_ADDRESSES.md; house read bearer) and
#      verify it locally before using it: `wrfcoin node address verify` (both
#      signatures, strict Ed25519, pinned chain/bond/K) plus this script's own
#      public-address check;
#   4. plan: print one line per bond (no address). run: fetch a bonded snapshot
#      from the node over P2P (`wrfcoin snapshot fetch --bonded`), trying each
#      address in its record, then PUT the claims it produced into the claim
#      mailbox for that bond and epoch, where the owner's `receipt auto` reads them.
#
# Addresses come only from the nodes' own records. They are held in shell
# variables for this pass and never written to disk or printed: HTTP bodies are
# read into variables, records reach the CLI on stdin, and the fetch's stderr
# is discarded. The receipt archive (public claims only) and the curl header
# files live in a private temporary folder removed at exit. Credentials come from owner-only files and travel in curl header files
# or on the CLI's stdin, never on a command line.
#
# Usage: house-consumer-roster.sh [plan|run]       (default: plan)
#
# Environment (the kit sets these; nothing has a live default):
#   HOUSE_NODE_URL                 house node API for roster reads   (default http://127.0.0.1:8556)
#   HOUSE_NODE_READER_TOKEN_FILE   Reader bearer for HOUSE_NODE_URL (/node/bonds needs one)
#   ADDRESS_MAILBOX_URL            mailbox base, e.g. http://wrfcoin-testnet-claim-mailbox:8095
#   ADDRESS_READ_TOKEN_FILE        house read bearer for GET /addresses/<K>
#   HOUSE_DEPLOYMENT_IDS           comma list of the house's own bond ids (never fetched from)
#   CHAIN_ID, NETWORK_ID, GENESIS_HASH  the chain every record must name (888 / testnet / 64 hex)
#   WRFCOIN_CLI                    CLI binary with `node address verify` (default: wrfcoin)
#   run only:
#   HOUSE_RECEIVER_URL             the receiver node API that ingests the snapshot (fresh receiver)
#   HOUSE_RECEIVER_TOKEN_FILE      the receiver's Operator bearer
#   CLAIM_MAILBOX_WRITE_TOKEN_FILE the claim mailbox write bearer (PUT /claims/...)
#   FETCH_TIMEOUT_SECS             per fetch (default 900)
#
# Exit: 0 pass finished (some bonds may have had no record), 1 config or roster error.
set -euo pipefail

MODE="${1:-plan}"
case "$MODE" in plan|run) ;; *) echo "usage: $0 [plan|run]" >&2; exit 1 ;; esac

HOUSE_NODE_URL="${HOUSE_NODE_URL:-http://127.0.0.1:8556}"
ADDRESS_MAILBOX_URL="${ADDRESS_MAILBOX_URL:-}"
WRFCOIN_CLI="${WRFCOIN_CLI:-wrfcoin}"
FETCH_TIMEOUT_SECS="${FETCH_TIMEOUT_SECS:-900}"
HEX64='^[0-9a-f]{64}$'
GENESIS_HASH="${GENESIS_HASH:-}"

die() { echo "house-consumer: $*" >&2; exit 1; }

# An owner-only regular file (not a symlink), read once; never echoed.
read_secret() {
  local path="$1" what="$2" mode
  [[ -n "$path" && -f "$path" && ! -L "$path" ]] || die "$what file missing"
  mode=$(stat -c '%a' "$path")
  [[ "$mode" == 600 || "$mode" == 400 ]] || die "$what file must be mode 600 or 400"
  local value
  value=$(head -c 4096 "$path" | tr -d '\r\n')
  [[ ${#value} -ge 16 ]] || die "$what file is empty or too short"
  printf '%s' "$value"
}

[[ -n "$ADDRESS_MAILBOX_URL" ]] || die "ADDRESS_MAILBOX_URL is required"
CHAIN_ID="${CHAIN_ID:-}" NETWORK_ID="${NETWORK_ID:-}" GENESIS_HASH="${GENESIS_HASH#0x}"
[[ "$CHAIN_ID" =~ ^[0-9A-Za-z_-]{1,32}$ && "$NETWORK_ID" =~ ^[0-9A-Za-z_-]{1,32}$ ]] || die "CHAIN_ID and NETWORK_ID are required"
[[ "$GENESIS_HASH" =~ $HEX64 ]] || die "GENESIS_HASH (64 lowercase hex) is required"
command -v "$WRFCOIN_CLI" >/dev/null || die "CLI not found"
for url in "$HOUSE_NODE_URL" "$ADDRESS_MAILBOX_URL"; do
  [[ "$url" =~ ^https?://[A-Za-z0-9.:-]+(/[A-Za-z0-9._/-]*)?$ ]] || die "invalid URL in config"
done
ADDRESS_MAILBOX_URL="${ADDRESS_MAILBOX_URL%/}"
HOUSE_NODE_URL="${HOUSE_NODE_URL%/}"

PRIVATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/house-consumer.XXXXXX")
chmod 700 "$PRIVATE_DIR"
trap 'rm -rf -- "$PRIVATE_DIR"' EXIT

# curl header files: a bearer never appears in argv.
header_file() {
  local name="$1" token="$2"
  local file="$PRIVATE_DIR/$name.headers"
  ( umask 077; printf 'Authorization: Bearer %s\n' "$token" >"$file" )
  printf '%s' "$file"
}

# Each secret is read into a variable first: a failed read inside an argument would not stop set -e.
token=$(read_secret "${ADDRESS_READ_TOKEN_FILE:-}" "address read token")
READ_HEADERS=$(header_file address-read "$token")
NODE_HEADERS=/dev/null
if [[ -n "${HOUSE_NODE_READER_TOKEN_FILE:-}" ]]; then
  token=$(read_secret "$HOUSE_NODE_READER_TOKEN_FILE" "node reader token")
  NODE_HEADERS=$(header_file node-read "$token")
fi
if [[ "$MODE" == run ]]; then
  [[ "${HOUSE_RECEIVER_URL:-}" =~ ^https?://[A-Za-z0-9.:-]+/?$ ]] || die "HOUSE_RECEIVER_URL is required for run"
  RECEIVER_TOKEN=$(read_secret "${HOUSE_RECEIVER_TOKEN_FILE:-}" "receiver token")
  # It is written into the CLI's stdin JSON: plain token characters only.
  [[ "$RECEIVER_TOKEN" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || die "receiver token has unexpected characters"
  token=$(read_secret "${CLAIM_MAILBOX_WRITE_TOKEN_FILE:-}" "claim mailbox write token")
  WRITE_HEADERS=$(header_file claim-write "$token")
fi
unset token

# GET with a bounded body, kept in memory (never a file: a record body holds
# addresses); prints the body (data envelope unwrapped), or fails.
get_json() {
  local url="$1" headers="$2" reply code body
  reply=$(curl -sS --max-time 15 --max-filesize 1048576 -w '\n%{http_code}' -H @"$headers" "$url" 2>/dev/null) || return 2
  code="${reply##*$'\n'}"
  body="${reply%$'\n'*}"
  [[ "$code" == 200 ]] || return 3
  [[ ${#body} -le 1048576 ]] || return 2
  jq -c '.data // .' <<<"$body"
}

# A dialable public address in the record's own shape (defence in depth on top
# of the CLI's check): no private, loopback, link-local, CGNAT, ULA or mapped.
public_multiaddr() {
  local addr="$1" host a b
  if [[ "$addr" =~ ^/ip4/([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/tcp/[1-9][0-9]{0,4}/p2p/[1-9A-HJ-NP-Za-km-z]{40,60}$ ]]; then
    a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]}
    (( a == 0 || a == 10 || a == 127 || a >= 224 )) && return 1
    (( a == 169 && b == 254 )) && return 1
    (( a == 172 && b >= 16 && b <= 31 )) && return 1
    (( a == 192 && b == 168 )) && return 1
    (( a == 100 && b >= 64 && b <= 127 )) && return 1
    return 0
  fi
  if [[ "$addr" =~ ^/ip6/([0-9a-f:]+)/tcp/[1-9][0-9]{0,4}/p2p/[1-9A-HJ-NP-Za-km-z]{40,60}$ ]]; then
    host=${BASH_REMATCH[1]}
    # Global unicast 2000::/3 only (refuses ::1, ::ffff:..., fc00::/7, fe80::/10, ff00::/8).
    [[ "$host" =~ ^[23][0-9a-f]{0,3}: ]] && return 0
  fi
  return 1
}

is_house() {
  local id="$1" own own_id
  IFS=',' read -r -a own <<<"${HOUSE_DEPLOYMENT_IDS:-}"
  for own_id in "${own[@]}"; do [[ "$own_id" == "$id" ]] && return 0; done
  return 1
}

# 1. Roster: every registered bond, keyset-paged.
BONDS=()
after=""
for _ in $(seq 1 50); do
  page=$(get_json "$HOUSE_NODE_URL/node/bonds?limit=200${after:+&after=$after}" "$NODE_HEADERS") || die "roster read failed"
  # One epoch for the whole pass: the first page's; a page from another epoch aborts.
  page_epoch=$(jq -r '.epoch // empty' <<<"$page")
  if [[ -z "${EPOCH:-}" ]]; then EPOCH="$page_epoch"; elif [[ "$page_epoch" != "$EPOCH" ]]; then die "epoch changed while reading the roster; run again"; fi
  while IFS= read -r id; do BONDS+=("$id"); done < <(jq -r '.bonds[] | select(.status == "REGISTERED" and .jailed != true) | .deployment_id' <<<"$page")
  after=$(jq -r '.next_after // empty' <<<"$page")
  [[ -z "$after" ]] && break
  [[ "$after" =~ $HEX64 ]] || die "roster cursor invalid"
done
[[ "${EPOCH:-}" =~ ^[0-9]{1,15}$ ]] || die "node did not report the epoch"

ready=0 missing=0 stale=0 fetched=0 failed=0
echo "house-consumer: mode=$MODE epoch=$EPOCH bonds=${#BONDS[@]}"
for id in "${BONDS[@]}"; do
  [[ "$id" =~ $HEX64 ]] || continue
  if is_house "$id"; then continue; fi
  # 2. The bond's registered server key K (a 32-number array, or hex).
  bond=$(get_json "$HOUSE_NODE_URL/node/bonds/$id" "$NODE_HEADERS") || { echo "bond=${id:0:8} status=BOND_READ_FAILED"; failed=$((failed + 1)); continue; }
  key=$(jq -r '.registration.binding.server_key | if type == "array" then (map(. as $b | "0123456789abcdef"[($b / 16 | floor):($b / 16 | floor) + 1] + "0123456789abcdef"[($b % 16):($b % 16) + 1]) | join("")) else ltrimstr("0x") end' <<<"$bond")
  [[ "$key" =~ $HEX64 ]] || { echo "bond=${id:0:8} status=NO_SERVER_KEY"; failed=$((failed + 1)); continue; }
  # 3. The node's own record for K. The mailbox verified both signatures and the bond on write.
  if ! record=$(get_json "$ADDRESS_MAILBOX_URL/addresses/$key" "$READ_HEADERS"); then
    echo "bond=${id:0:8} key=${key:0:8} status=NO_RECORD"
    missing=$((missing + 1))
    continue
  fi
  rec_id=$(jq -r '.deployment_id' <<<"$record")
  rec_key=$(jq -r '.server_key' <<<"$record")
  rec_epoch=$(jq -r '.epoch' <<<"$record")
  if [[ "$rec_id" != "$id" || "$rec_key" != "$key" || ! "$rec_epoch" =~ ^[0-9]{1,15}$ ]]; then
    echo "bond=${id:0:8} key=${key:0:8} status=RECORD_MISMATCH"
    failed=$((failed + 1))
    continue
  fi
  # A record older than two epochs is expiring; the node has stopped publishing.
  if (( rec_epoch + 2 < EPOCH )); then
    echo "bond=${id:0:8} key=${key:0:8} status=STALE_RECORD record_epoch=$rec_epoch"
    stale=$((stale + 1))
    continue
  fi
  # Verify locally: both signatures (strict), the pinned chain, this bond and this K.
  if ! jq -c . <<<"$record" | "$WRFCOIN_CLI" node address verify --record - --chain-id "$CHAIN_ID" \
      --network-id "$NETWORK_ID" --genesis-hash "$GENESIS_HASH" --deployment-id "$id" --server-key "$key" >/dev/null 2>&1; then
    echo "bond=${id:0:8} key=${key:0:8} status=RECORD_INVALID"
    failed=$((failed + 1))
    continue
  fi
  addrs=()
  while IFS= read -r addr; do
    if public_multiaddr "$addr"; then addrs+=("$addr"); fi
  done < <(jq -r '.multiaddrs[]' <<<"$record")
  if [[ ${#addrs[@]} == 0 ]]; then
    echo "bond=${id:0:8} key=${key:0:8} status=NO_PUBLIC_ADDRESS"
    failed=$((failed + 1))
    continue
  fi
  ready=$((ready + 1))
  if [[ "$MODE" == plan ]]; then
    echo "bond=${id:0:8} key=${key:0:8} status=READY addresses=${#addrs[@]} record_epoch=$rec_epoch"
    continue
  fi

  # 4. Fetch over P2P from the first address that answers; the snapshot must be signed by K.
  archive="$PRIVATE_DIR/archive-$id"
  mkdir -m 700 "$archive"
  done_fetch=""
  for i in "${!addrs[@]}"; do
    addr="${addrs[$i]}"
    # stderr may name the address it dialled: discarded, never kept.
    if printf '{"server_reader":"","receiver_operator":"%s"}' "$RECEIVER_TOKEN" | \
      timeout "$FETCH_TIMEOUT_SECS" "$WRFCOIN_CLI" snapshot fetch --from "$addr" --to "$HOUSE_RECEIVER_URL" \
        --bonded --auth-stdin --trusted-signers "$key" --receipt-archive "$archive" >/dev/null 2>&1; then
      done_fetch=$i
      break
    fi
  done
  if [[ -z "$done_fetch" ]]; then
    echo "bond=${id:0:8} key=${key:0:8} status=FETCH_FAILED tried=${#addrs[@]}"
    failed=$((failed + 1))
    continue
  fi
  # 5. Claims to the claim mailbox for this bond and epoch.
  claims=$(find "$archive" -maxdepth 1 -type f -name 'bonded-*.json' -print0 | xargs -0 -r cat | \
    jq -cs '[.[] | select((.claim_hex | type) == "string" and (.receipt_id | type) == "string") | {claim_hex, receipt_id}] | unique_by(.receipt_id) | .[:8]')
  count=$(jq 'length' <<<"$claims")
  if [[ "$count" == 0 ]]; then
    echo "bond=${id:0:8} key=${key:0:8} status=NO_CLAIM_PRODUCED"
    failed=$((failed + 1))
    continue
  fi
  code=$(jq -c '{claims: .}' <<<"$claims" | curl -sS --max-time 15 -o /dev/null -w '%{http_code}' -X PUT \
    -H @"$WRITE_HEADERS" -H 'Content-Type: application/json' --data-binary @- \
    "$ADDRESS_MAILBOX_URL/claims/$id/$EPOCH") || code=000
  if [[ "$code" == 200 ]]; then
    echo "bond=${id:0:8} key=${key:0:8} status=CLAIMS_STORED count=$count address=$((done_fetch + 1))/${#addrs[@]}"
    fetched=$((fetched + 1))
  else
    echo "bond=${id:0:8} key=${key:0:8} status=CLAIM_PUT_FAILED http=$code"
    failed=$((failed + 1))
  fi
done
echo "house-consumer: ready=$ready no_record=$missing stale=$stale stored=$fetched failed=$failed"
