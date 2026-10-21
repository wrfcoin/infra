#!/usr/bin/env bash
# Fixture test for test_oracle.sh's authed read (infra#1036). Offline: docker
# and curl are PATH stubs, and test_oracle.sh runs its in-CT snippet locally via
# ORACLE_TEST_LOCAL_EXEC=1. Nothing here contacts a live host.
#
# Covers: 200 with data (set size/quorum READ from the body), 401 and 403
# (UNAVAILABLE, exit 77), no token (UNAVAILABLE, curl never called), a 500, an
# unreachable quorum, a wedged reveal path, a pinned-expectation mismatch, and
# that the token never appears in any argv or in the suite's output.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/test_oracle.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TOKEN="fixture-reader-$$-$RANDOM"
failures=0
cases=0

mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX_ARGV_LOG"
if [[ "$1" == "exec" && "$3" == "printenv" && "$4" == "WRFCOIN_READER_TOKEN" && -n "${FIX_TOKEN:-}" ]]; then
  printf '%s\n' "$FIX_TOKEN"
  exit 0
fi
exit 1
STUB
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX_ARGV_LOG"
echo call >> "$FIX_CURL_CALLS"
n=$(wc -l < "$FIX_CURL_CALLS")
config="$(cat)"
# The header must arrive on stdin, carrying exactly the token the node accepts
# (FIX_NODE_TOKEN; defaults to the container's token).
if [[ "$config" != "header = \"Authorization: Bearer ${FIX_NODE_TOKEN:-$FIX_TOKEN}\"" ]]; then
  printf '{"error":"unauthorized"}\n401'
  exit 0
fi
case "$FIX_MODE" in
  ok)        pending=$(( n == 1 ? 3 : 1 )); q=2; n_set=4 ;;
  wedged)    pending=$(( n * 5 )); q=2; n_set=4 ;;
  badquorum) pending=0; q=5; n_set=4 ;;
  401)       printf '{"ok":false,"error":{"code":"UNAUTHORIZED"}}\n401'; exit 0 ;;
  403)       printf '{"ok":false,"error":{"code":"FORBIDDEN"}}\n403'; exit 0 ;;
  500)       printf 'boom\n500'; exit 0 ;;
esac
set_json=$(for (( k = 1; k <= n_set; k++ )); do printf '"oracle-%d"' "$k"; (( k < n_set )) && printf ','; done)
printf '{"oracle_set":[%s],"oracle_quorum":%d,"tracked_commit_count":%d,"commits_with_quorum":0,"commits_pending_quorum":%d}\n200' \
  "$set_json" "$q" "$pending" "$pending"
STUB
chmod +x "$TMP/bin/docker" "$TMP/bin/curl"

# run_case <name> <expected-exit> <mode> <token|-> <must-match-regex> [env...]
run_case() {
  local name=$1 want=$2 mode=$3 tok=$4 pattern=$5
  shift 5
  cases=$((cases + 1))
  local dir="$TMP/case-$cases"
  mkdir -p "$dir"
  : > "$dir/argv"; : > "$dir/calls"
  local rc=0
  [[ "$tok" == "-" ]] && tok=""
  env PATH="$TMP/bin:$PATH" FIX_ARGV_LOG="$dir/argv" FIX_CURL_CALLS="$dir/calls" \
      FIX_MODE="$mode" FIX_TOKEN="$tok" ORACLE_TEST_LOCAL_EXEC=1 \
      SAMPLES=2 INTERVAL_SECS=0 CURL_SPACING=0 "$@" \
      bash "$SUT" > "$dir/out" 2>&1
  rc=$?
  local ok=1
  if [[ "$rc" != "$want" ]]; then
    echo "FAIL [$name]: exit $rc, want $want"; ok=0
  fi
  if ! grep -Eq "$pattern" "$dir/out"; then
    echo "FAIL [$name]: output does not match /$pattern/"; ok=0
  fi
  if grep -Fq "$TOKEN" "$dir/argv" "$dir/out"; then
    echo "FAIL [$name]: token leaked into an argv or the suite output"; ok=0
  fi
  if (( ok == 0 )); then
    sed 's/^/    | /' "$dir/out"
    failures=$((failures + 1))
  else
    echo "PASS [$name] (exit $rc)"
  fi
  CASE_DIR="$dir"
}

run_case "200 with data, n=4 q=2 read from body" 0 ok "$TOKEN" \
  'oracle quorum reachable: q=2 of n=4' \
  EXPECT_ORACLE_SET_SIZE=4 EXPECT_ORACLE_QUORUM=2

run_case "401 is UNAVAILABLE, not a data failure" 77 401 "$TOKEN" \
  'UNAVAILABLE.*HTTP 401'
if grep -q 'FAIL' "$CASE_DIR/out"; then
  echo "FAIL [401]: reported a data FAIL alongside UNAVAILABLE"; failures=$((failures + 1))
fi

run_case "403 is UNAVAILABLE" 77 403 "$TOKEN" 'UNAVAILABLE.*HTTP 403'

run_case "no token is UNAVAILABLE and never calls the node" 77 ok - \
  'UNAVAILABLE.*WRFCOIN_READER_TOKEN is not set'
if [[ -s "$CASE_DIR/calls" ]]; then
  echo "FAIL [no token]: curl was called without a token"; failures=$((failures + 1))
fi

run_case "stale container token refused by the node (401) is UNAVAILABLE" 77 ok "$TOKEN" \
  'UNAVAILABLE.*HTTP 401' FIX_NODE_TOKEN=rotated-token

run_case "500 is a FAIL, not UNAVAILABLE" 1 500 "$TOKEN" 'FAIL.*HTTP 500'

run_case "quorum above set size is a data FAIL" 1 badquorum "$TOKEN" \
  'FAIL.*oracle_quorum=5 is unreachable for oracle_set_size=4'

run_case "strictly rising pending count is a FAIL" 1 wedged "$TOKEN" \
  'FAIL.*strictly rose'

run_case "pinned expectation mismatch is a FAIL (size is read, not hardcoded)" 1 ok "$TOKEN" \
  'FAIL.*oracle_set_size=4 but EXPECT_ORACLE_SET_SIZE=3' EXPECT_ORACLE_SET_SIZE=3

# The header must travel on stdin, never in curl's argv.
if grep -q 'Authorization' "$TMP"/case-*/argv; then
  echo "FAIL: an Authorization header appeared in an argv"; failures=$((failures + 1))
fi

echo "ORACLE_AUTH_FIXTURE cases=${cases} failures=${failures}"
if (( failures > 0 )); then
  exit 1
fi
echo "ORACLE_AUTH_FIXTURE=PASS"
