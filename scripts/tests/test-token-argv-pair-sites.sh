#!/usr/bin/env bash
# infra#1066 (codex round 24): bearer tokens must never be passed to curl in
# argv (visible in ps and /proc). This pins the two sites in the
# backend#1234 pair's path; the remaining pre-existing sites are infra#1073.
#   1. infra/docker/wal-replay-healthcheck.sh  (WRFCOIN_READER_TOKEN)
#   2. scripts/relaunch-testnet-stack.sh IoT smoke (WRFCOIN_OPERATOR_TOKEN)
# Each real code path runs against a curl stand-in that records argv and only
# answers when the bearer arrives on stdin (-H @-).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "  ok    $*"; }
TOKEN="argv-regression-token-1066"

# Stand-in curl: log argv; read an `-H @-` header from stdin; succeed only if
# the expected bearer arrived. /readyz needs no auth.
cat > "$TMP/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ARGV_LOG:?}"
header=''
url=''
while (( $# > 0 )); do
  case "$1" in
    -H) if [[ "$2" == "@-" ]]; then IFS= read -r header || true; fi; shift 2 ;;
    --max-time|-X|-d|-o|-w) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  */readyz) printf '{"status":"ready"}\n'; exit 0 ;;
esac
[[ "$header" == "Authorization: Bearer ${EXPECT_TOKEN:?}" ]] || exit 22
case "$url" in
  */metrics) printf 'wrfcoin_wal_replay_status 1\nwrfcoin_state_divergence_total 0\n' ;;
  *) printf '{"ok":true}\n' ;;
esac
SH
chmod +x "$TMP/curl"
export ARGV_LOG="$TMP/argv.log" EXPECT_TOKEN="$TOKEN"

echo "== 1. wal-replay-healthcheck.sh: reader token on stdin =="
: > "$ARGV_LOG"
env WRFCOIN_READER_TOKEN="$TOKEN" CURL_BIN="$TMP/curl" \
  NODE_READYZ_URL=http://node/readyz NODE_METRICS_URL=http://node/metrics \
  bash "$REPO/infra/docker/wal-replay-healthcheck.sh" > "$TMP/wal.out" 2>&1 ||
  { cat "$TMP/wal.out" >&2; fail "healthcheck failed with the reader token"; }
grep -q 'wrfcoin_state_divergence_total=0' "$TMP/wal.out" || fail "metrics were not fetched with the bearer"
grep -q '/metrics' "$ARGV_LOG" || fail "curl stand-in was not used for /metrics"
! grep -qF "$TOKEN" "$ARGV_LOG" || fail "reader token visible in curl argv"
ok "healthcheck passes with the bearer delivered on stdin; token not in argv"

echo "== 2. relaunch-testnet-stack.sh IoT smoke: operator token on stdin =="
SCRIPT="$REPO/scripts/relaunch-testnet-stack.sh"
# Execute the real helper and the real IoT smoke block, extracted verbatim.
python3 - "$SCRIPT" "$TMP/iot-smoke.sh" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
helper = re.search(r"^curl_with_operator_bearer\(\) \{.*?^\}\n", src, re.S | re.M)
# The smoke block is the SKIPPED reset immediately followed by the RUN_SMOKE gate
# (an earlier SKIPPED line initialises the summary variables).
block = re.search(r'^IOT_SMOKE_STATUS="SKIPPED"\nif \[ "\$RUN_SMOKE" = "1" \].*?^fi\n', src, re.S | re.M)
assert helper and block, "helper or IoT smoke block not found"
with open(sys.argv[2], "w", encoding="utf-8") as out:
    out.write('run_smoke_command() { shift; "$@"; }\n')
    out.write(helper.group(0))
    out.write(block.group(0))
    out.write('printf "IOT_SMOKE_STATUS=%s\\n" "$IOT_SMOKE_STATUS"\n')
PY
: > "$ARGV_LOG"
env PATH="$TMP:$PATH" RUN_SMOKE=1 WRFCOIN_OPERATOR_TOKEN="$TOKEN" bash "$TMP/iot-smoke.sh" > "$TMP/iot.out" 2>&1 ||
  { cat "$TMP/iot.out" >&2; fail "IoT smoke block errored"; }
grep -q 'IOT_SMOKE_STATUS=PASS' "$TMP/iot.out" || { cat "$TMP/iot.out" >&2; fail "IoT smoke did not authenticate via stdin"; }
grep -q '/api/iot/readings' "$ARGV_LOG" || fail "curl stand-in was not used for the IoT smoke"
! grep -qF "$TOKEN" "$ARGV_LOG" || fail "operator token visible in curl argv"
ok "IoT smoke PASS with the bearer delivered on stdin; token not in argv"

echo "PASS: pair-scoped token argv sites"
