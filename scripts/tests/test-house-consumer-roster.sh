#!/usr/bin/env bash
# scripts/house-consumer-roster.sh against a mock node + mailbox (python3) and a
# stub CLI. Synthetic data only; nothing reaches a real host.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/house-consumer-roster.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-house-consumer.XXXXXX")
cleanup() { [[ -n "${MOCK_PID:-}" ]] && kill "$MOCK_PID" 2>/dev/null; rm -rf -- "$WORK"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

READ_TOKEN=synthetic-read-token-0123456789abcdef      # secret-leak-ok: synthetic test bearer
WRITE_TOKEN=synthetic-write-token-0123456789abcdef    # secret-leak-ok: synthetic test bearer
RECEIVER_TOKEN=synthetic-receiver-token-0123456789ab  # secret-leak-ok: synthetic test bearer
for name in read write receiver; do
  var="$(tr '[:lower:]' '[:upper:]' <<<"$name")_TOKEN"
  ( umask 077; printf '%s\n' "${!var}" >"$WORK/$name.token" )
done

cat >"$WORK/mock.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
work, read_token, write_token = sys.argv[1], sys.argv[2], sys.argv[3]
A, B, C, HOUSE, D, E = '0a' * 32, '0b' * 32, '0c' * 32, '0d' * 32, '0e' * 32, '0f' * 32
KA, KB, KC, KD, KE = 'a1' * 32, 'b1' * 32, 'c1' * 32, 'e1' * 32, 'f1' * 32
PEER = '12D3KooWJWoaqZhDaoEFshF7Rh1bpY9ohihFhzcW6d69Lr2NASuq'
bonds = {A: KA, B: KB, C: KC, HOUSE: 'd1' * 32, D: KD, E: KE}
records = {
    KA: {'deployment_id': A, 'server_key': KA, 'epoch': '41', 'multiaddrs': [
        f'/ip4/198.51.99.7/tcp/9000/p2p/{PEER}', f'/ip4/198.51.99.8/tcp/9000/p2p/{PEER}']},
    KB: {'deployment_id': B, 'server_key': KB, 'epoch': '37', 'multiaddrs': [f'/ip4/198.51.99.9/tcp/9000/p2p/{PEER}']},
    # Only a private address: the CLI stub calls it valid; the script's own check refuses it.
    KD: {'deployment_id': D, 'server_key': KD, 'epoch': '41', 'multiaddrs': [f'/ip4/10.0.0.5/tcp/9000/p2p/{PEER}']},
    # A record the CLI's signature check refuses (the stub looks for this marker).
    KE: {'deployment_id': E, 'server_key': KE, 'epoch': '41', 'signature': 'BADSIG', 'multiaddrs': [f'/ip4/198.51.99.10/tcp/9000/p2p/{PEER}']},
}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code); self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        p = self.path
        if p.startswith('/node/bonds?'):
            if 'after=' not in p:
                return self.reply(200, {'epoch': '41', 'bonds': [{'deployment_id': i, 'status': 'REGISTERED', 'jailed': False} for i in (A, B)], 'next_after': B})
            return self.reply(200, {'epoch': '41', 'bonds': [{'deployment_id': i, 'status': 'REGISTERED', 'jailed': False} for i in (C, HOUSE, D, E)]
                + [{'deployment_id': 'ee' * 32, 'status': 'REGISTERED', 'jailed': True}], 'next_after': None})
        if p.startswith('/node/bonds/'):
            i = p.rsplit('/', 1)[1]
            return self.reply(200, {'status': 'REGISTERED', 'registration': {'binding': {'server_key': list(bytes.fromhex(bonds[i]))}}})
        if p.startswith('/addresses/'):
            if self.headers.get('authorization') != f'Bearer {read_token}':
                return self.reply(401, {'ok': False})
            k = p.rsplit('/', 1)[1]
            return self.reply(200, {'ok': True, 'data': records[k]}) if k in records else self.reply(404, {'ok': False})
        self.reply(404, {})
    def do_PUT(self):
        if self.headers.get('authorization') != f'Bearer {write_token}':
            return self.reply(401, {'ok': False})
        body = self.rfile.read(int(self.headers['content-length']))
        with open(f'{work}/puts.jsonl', 'a') as f:
            f.write(json.dumps({'path': self.path, 'body': json.loads(body)}) + '\n')
        self.reply(200, {'ok': True})
srv = HTTPServer(('127.0.0.1', 0), H)
open(f'{work}/port', 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$WORK/mock.py" "$WORK" "$READ_TOKEN" "$WRITE_TOKEN" &
MOCK_PID=$!
for _ in $(seq 1 50); do [[ -s "$WORK/port" ]] && break; sleep 0.1; done
PORT=$(cat "$WORK/port")

# Stub CLI. `node address verify`: refuses the BADSIG record, checks the pinned args.
# `snapshot fetch`: the first address of bond A fails, the second answers; it records
# argv and stdin, and checks that no file of the pass holds an address mid-run.
cat >"$WORK/wrfcoin" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2 $3" == "node address verify" ]]; then
  printf '%s\n' "$*" >>"$STUB_VERIFY_LOG"
  record=$(cat)
  [[ "$record" == *BADSIG* ]] && exit 1
  [[ "$*" == *"--chain-id 888 --network-id testnet --genesis-hash $(printf 'ab%.0s' $(seq 32))"* ]] || exit 1
  exit 0
fi
printf '%s\n' "$*" >>"$STUB_LOG"
cat >>"$STUB_STDIN"
from="" archive=""
while [[ $# -gt 0 ]]; do case "$1" in --from) from="$2"; shift 2 ;; --receipt-archive) archive="$2"; shift 2 ;; *) shift ;; esac; done
if grep -rqs '198\.51\.99\|10\.0\.0\.5' "$(dirname "$archive")"; then echo LEAK >>"$STUB_LOG"; fi
[[ "$from" == /ip4/198.51.99.7/* ]] && exit 1
printf '{"claim_hex":"0aff","receipt_id":"%s"}' "$(printf '42%.0s' $(seq 32))" >"$archive/bonded-x.json"
SH
chmod +x "$WORK/wrfcoin"

export HOUSE_NODE_URL="http://127.0.0.1:$PORT" ADDRESS_MAILBOX_URL="http://127.0.0.1:$PORT"
HOUSE_DEPLOYMENT_IDS=$(printf '0d%.0s' $(seq 32))
export ADDRESS_READ_TOKEN_FILE="$WORK/read.token" HOUSE_DEPLOYMENT_IDS
export HOUSE_RECEIVER_URL="http://127.0.0.1:1" HOUSE_RECEIVER_TOKEN_FILE="$WORK/receiver.token"
export CLAIM_MAILBOX_WRITE_TOKEN_FILE="$WORK/write.token" WRFCOIN_CLI="$WORK/wrfcoin"
export STUB_LOG="$WORK/stub.log" STUB_STDIN="$WORK/stub.stdin" STUB_VERIFY_LOG="$WORK/verify.log" TMPDIR="$WORK"
GENESIS_HASH=$(printf 'ab%.0s' $(seq 32))
export CHAIN_ID=888 NETWORK_ID=testnet GENESIS_HASH

# plan: one line per bond, no address, nothing fetched or written.
plan=$(bash "$SCRIPT" plan)
grep -q 'mode=plan epoch=41 bonds=6' <<<"$plan" || fail "roster paging: $plan"
grep -q 'bond=0e0e0e0e key=e1e1e1e1 status=NO_PUBLIC_ADDRESS' <<<"$plan" || fail "private-only record: $plan"
grep -q 'bond=0f0f0f0f key=f1f1f1f1 status=RECORD_INVALID' <<<"$plan" || fail "invalid record: $plan"
grep -q -- "--deployment-id $(printf '0a%.0s' $(seq 32)) --server-key $(printf 'a1%.0s' $(seq 32))" "$WORK/verify.log" || fail "verify not pinned to bond and K"
grep -q 'bond=0a0a0a0a key=a1a1a1a1 status=READY addresses=2 record_epoch=41' <<<"$plan" || fail "ready line: $plan"
grep -q 'bond=0b0b0b0b key=b1b1b1b1 status=STALE_RECORD record_epoch=37' <<<"$plan" || fail "stale line: $plan"
grep -q 'bond=0c0c0c0c key=c1c1c1c1 status=NO_RECORD' <<<"$plan" || fail "missing line: $plan"
grep -q '0d0d0d0d' <<<"$plan" && fail "the house's own bond was considered"
grep -q '198.51.99' <<<"$plan" && fail "plan printed an address"
grep -q '10.0.0.5' <<<"$plan" && fail "plan printed an address"
grep -q 'ready=1 no_record=1 stale=1 stored=0 failed=2' <<<"$plan" || fail "plan summary: $plan"
[[ ! -e "$STUB_LOG" && ! -e "$WORK/puts.jsonl" ]] || fail "plan fetched or wrote"

# run: tries the record's addresses in order, then PUTs the claim for bond A, epoch 41.
run=$(bash "$SCRIPT" run)
grep -q 'bond=0a0a0a0a key=a1a1a1a1 status=CLAIMS_STORED count=1 address=2/2' <<<"$run" || fail "run line: $run"
grep -q '198.51.99' <<<"$run" && fail "run printed an address"
grep -q LEAK "$STUB_LOG" && fail "an address reached a file during the pass"
[[ $(wc -l <"$STUB_LOG") == 2 ]] || fail "expected two dial attempts (none to the private-only or invalid record)"
grep -q -- "--trusted-signers $(printf 'a1%.0s' $(seq 32))" "$STUB_LOG" || fail "snapshot not pinned to K"
for token in "$READ_TOKEN" "$WRITE_TOKEN" "$RECEIVER_TOKEN"; do
  grep -qF "$token" "$STUB_LOG" && fail "a token reached the CLI argv"
done
grep -qF "\"receiver_operator\":\"$RECEIVER_TOKEN\"" "$STUB_STDIN" || fail "receiver token not on stdin"
put=$(cat "$WORK/puts.jsonl")
jq -e --arg p "/claims/$(printf '0a%.0s' $(seq 32))/41" '.path == $p and (.body.claims | length) == 1 and .body.claims[0].claim_hex == "0aff"' <<<"$put" >/dev/null || fail "claim PUT: $put"
# Nothing of the pass is left on disk.
[[ -z "$(find "$WORK" -maxdepth 1 -name 'house-consumer.*')" ]] || fail "private folder left behind"

# Refusals: loose token file, missing mailbox URL.
chmod 644 "$WORK/read.token"
bash "$SCRIPT" plan >/dev/null 2>&1 && fail "accepted a group-readable token file"
chmod 600 "$WORK/read.token"
ADDRESS_MAILBOX_URL="" bash "$SCRIPT" plan >/dev/null 2>&1 && fail "ran without a mailbox URL"
bash "$SCRIPT" bogus >/dev/null 2>&1 && fail "accepted an unknown mode"
GENESIS_HASH="" bash "$SCRIPT" plan >/dev/null 2>&1 && fail "ran without a pinned genesis"
echo "PASS house-consumer-roster: plan, run (local record verify, public-address check, address fallback, K-pinned fetch, claim PUT), no addresses printed or written, no token in argv"
