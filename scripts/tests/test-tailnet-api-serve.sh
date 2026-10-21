#!/usr/bin/env bash
# Tests for testnet/edge/tailnet-api-serve.sh (mobile#44 tailnet-only API route).
#
# Offline: `tailscale` and `curl` are stubs selected through TAILSCALE_BIN and
# CURL_BIN. The tailscale stub keeps serve state as JSON in a file shaped like
# `tailscale serve status --json` (ipn.ServeConfig), logs every invocation, and
# exits 99 on any `funnel` or `reset`, so the script can never be caught
# publishing or wiping serve config. No host, tailnet, or daemon is touched.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/testnet/edge/tailnet-api-serve.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tailnet-api-serve-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

HOST=wrfcoin-testnet.taila1c049.ts.net
export FAKE_TS_STATE="$TMP/state.json" FAKE_TS_LOG="$TMP/ts.log" FAKE_TS_HOST="$HOST"
export FAKE_CURL_CODES="$TMP/curl-codes" TAILNET_API_EVIDENCE_DIR="$TMP/evidence" TAILNET_API_LOCK="$TMP/serve.lock"

cat > "$TMP/tailscale" <<'STUB'
#!/usr/bin/env bash
# Minimal stateful stand-in for the tailscale CLI's serve surface.
printf '%s\n' "$*" >> "$FAKE_TS_LOG"
case " $* " in
  *" funnel "*|*" reset"*) echo "stub: forbidden invocation: $*" >&2; exit 99 ;;
esac
[ "${FAKE_TS_STATUS_FAIL:-0}" = 1 ] && [ "$1 $2" = "serve status" ] && { echo "stub: daemon down" >&2; exit 1; }
exec python3 - "$@" <<'PY'
import json, os, sys
state_path, host = os.environ["FAKE_TS_STATE"], os.environ["FAKE_TS_HOST"]
state = json.load(open(state_path)) if os.path.exists(state_path) else {}
args = sys.argv[1:]
written = state_path + ".written"
def save():
    global state
    state = {k: v for k, v in state.items() if v}
    json.dump(state, open(state_path, "w"))
    open(written, "w").close()
def flag(name):
    return next((a.split("=", 1)[1] for a in args if a.startswith(f"--{name}=")), None)
def countdown(var):
    """True for the first N calls after a write, where N = $var (per fixture)."""
    counter = state_path + "." + var
    n = int(os.environ.get(var, "0") or 0)
    used = int(open(counter).read()) if os.path.exists(counter) else 0
    if os.path.exists(written) and used < n:
        open(counter, "w").write(str(used + 1))
        return True
    return False
if args[:3] == ["serve", "status", "--json"]:
    if os.path.exists(written):
        reads_path = state_path + ".reads"
        reads = (int(open(reads_path).read()) if os.path.exists(reads_path) else 0) + 1
        open(reads_path, "w").write(str(reads))
        # A concurrent writer (not this script) changes 8080 just before this read.
        if str(reads) == os.environ.get("FAKE_TS_CONCURRENT_AT_READ"):
            state.setdefault("TCP", {})["8080"] = {"TCPForward": "127.0.0.1:9999"}
            json.dump(state, open(state_path, "w"))
    if countdown("FAKE_TS_STRUCT_READS_AFTER_WRITE"):
        print('{"TCP": ["bad"]}'); sys.exit(0)
    if countdown("FAKE_TS_FAIL_READS_AFTER_WRITE"):
        print("stub: status failed after write", file=sys.stderr); sys.exit(1)
    if countdown("FAKE_TS_MALFORMED_READS_AFTER_WRITE"):
        print("{not json"); sys.exit(0)
    print(json.dumps(state) if state else "{}")
elif args[0] == "serve" and args[-1] == "off":
    if os.environ.get("FAKE_TS_OFF_FAIL") == "1" and flag("https") == "9444":
        print("stub: off failed", file=sys.stderr); sys.exit(1)
    for kind in ("https", "http", "tcp", "tls-terminated-tcp"):
        port = flag(kind)
        if port:
            break
    (state.get("TCP") or {}).pop(port, None)
    for key in ("Web", "AllowFunnel"):
        for k in [k for k in (state.get(key) or {}) if k.endswith(":" + port)]:
            del state[key][k]
    if os.environ.get("FAKE_TS_EXTERNAL_AFTER_OFF") == port:              # another writer, right after our off
        state.setdefault("TCP", {})[port] = {"TCPForward": "127.0.0.1:9999"}
    if os.environ.get("FAKE_TS_CLOBBER_ON_OFF") == "1" and port == "9444":
        os.environ.pop("FAKE_TS_CLOBBER_ON_OFF")
        marker = state_path + ".clobbered"
        if not os.path.exists(marker):                    # an `off` that also drops 8080, once
            open(marker, "w").close()
            (state.get("TCP") or {}).pop("8080", None)
    save()
elif args[0] == "serve" and (flag("tcp") or flag("tls-terminated-tcp")):
    port = flag("tcp") or flag("tls-terminated-tcp")
    entry = {"TCPForward": args[-1].split("://", 1)[1]}
    if flag("tls-terminated-tcp"):
        entry["TerminateTLS"] = host
    state.setdefault("TCP", {})[port] = entry
    save()
elif args[0] == "serve":
    port = flag("https")
    mount = flag("set-path")
    state.setdefault("TCP", {})[port] = {"HTTPS": True}
    state.setdefault("Web", {}).setdefault(f"{host}:{port}", {"Handlers": {}})["Handlers"][mount] = {"Proxy": args[-1]}
    if os.environ.get("FAKE_TS_FUNNEL_ON_SERVE") == "1" and port == "9444":   # a CLI that also funnels
        state.setdefault("AllowFunnel", {})[f"{host}:{port}"] = True
    if os.environ.get("FAKE_TS_CLOBBER") == "1" and port == "9444":           # a CLI that rewrites others
        state["TCP"].pop("8080", None)
    if os.environ.get("FAKE_TS_CLOBBER_MODIFY") == "1" and port == "9444":    # ... or modifies one
        state["TCP"]["8080"] = {"TCPForward": "127.0.0.1:8081", "TerminateTLS": host}
    if os.environ.get("FAKE_TS_BREAK_EVIDENCE") == "1" and port == "9444":    # evidence becomes unwritable
        root = os.environ["TAILNET_API_EVIDENCE_DIR"]
        newest = sorted(os.listdir(root))[-1]
        for name in ("restore.log", "after-write.json", "after-off.json", "final.json"):
            os.makedirs(os.path.join(root, newest, name), exist_ok=True)
    save()
else:
    print(f"stub: unsupported: {args}", file=sys.stderr)
    sys.exit(2)
PY
STUB
cat > "$TMP/curl" <<'STUB'
#!/usr/bin/env bash
# Answers with the code configured for the URL (last arg) in FAKE_CURL_CODES.
url="${*: -1}"
code="$(awk -v u="$url" '$1 == u {c = $2} END {print c}' "$FAKE_CURL_CODES" 2>/dev/null)"
printf '%s' "${code:-000}"
[ "${code:-000}" != 000 ]
STUB
chmod +x "$TMP/tailscale" "$TMP/curl"
export TAILSCALE_BIN="$TMP/tailscale" CURL_BIN="$TMP/curl"

# The approved faucet TCP serve (#604) that every operation must leave alone.
FAUCET_STATE='{"TCP": {"8080": {"TCPForward": "127.0.0.1:8080", "TerminateTLS": "'"$HOST"'"}}}'
EXPECTED_WEB="{\"$HOST:9444\": {\"Handlers\": {\"/api\": {\"Proxy\": \"http://127.0.0.1:5000/api\"}}}}"

FAILED=()
fail() { FAILED+=("$1"); echo "  FAIL: $1: $2" >&2; }
reset_fixture() { # STATE-JSON
  printf '%s\n' "$1" > "$FAKE_TS_STATE"
  rm -f "$FAKE_TS_STATE".*
  : > "$FAKE_TS_LOG"
  printf '%s\n' 'http://127.0.0.1:5000/api/build 200' > "$FAKE_CURL_CODES"
  unset FAKE_TS_FUNNEL_ON_SERVE FAKE_TS_CLOBBER FAKE_TS_STATUS_FAIL FAKE_TS_OFF_FAIL \
    FAKE_TS_CLOBBER_ON_OFF FAKE_TS_FAIL_READS_AFTER_WRITE FAKE_TS_MALFORMED_READS_AFTER_WRITE \
    FAKE_TS_STRUCT_READS_AFTER_WRITE FAKE_TS_CONCURRENT_AT_READ FAKE_TS_BREAK_EVIDENCE \
    FAKE_TS_CLOBBER_MODIFY FAKE_TS_EXTERNAL_AFTER_OFF
}
run() { # NAME ARGS... -> rc in $RC, output in $TMP/NAME.out
  local name="$1"; shift
  bash "$SCRIPT" "$@" > "$TMP/$name.out" 2>&1
  RC=$?
}
expect_rc() { # NAME WANT
  [ "$RC" -eq "$2" ] || { sed 's/^/    /' "$TMP/$1.out" >&2; fail "$1" "exit $RC, expected $2"; }
}
out_has() { grep -Fq -- "$2" "$TMP/$1.out" || { sed 's/^/    /' "$TMP/$1.out" >&2; fail "$1" "output lacks: $2"; }; }
state_is() { # NAME PYTHON-EXPR over s (state) — explicit status, not a pipe
  python3 - "$FAKE_TS_STATE" "$2" "$EXPECTED_WEB" "$HOST" <<'PY' || fail "$1" "state check failed: $2"
import json, sys
s = json.load(open(sys.argv[1])); expected_web = json.loads(sys.argv[3]); host = sys.argv[4]
assert eval(sys.argv[2]), s
PY
}
serve_calls() { grep -c '^serve --bg' "$FAKE_TS_LOG"; }

echo enable_from_faucet_only_state
reset_fixture "$FAUCET_STATE"
run enable enable
expect_rc enable 0
out_has enable 'TAILNET_API_ROUTE=ENABLED :9444/api -> http://127.0.0.1:5000/api (serve only, no Funnel)'
state_is enable 's["TCP"]["9444"] == {"HTTPS": True} and s["Web"] == expected_web'
state_is enable 's["TCP"]["8080"] == {"TCPForward": "127.0.0.1:8080", "TerminateTLS": host}'
state_is enable '"AllowFunnel" not in s'
grep -Fxq 'serve --bg --https=9444 --set-path=/api http://127.0.0.1:5000/api' "$FAKE_TS_LOG" \
  || fail enable "exact serve command not issued"

echo enable_again_is_a_noop
: > "$FAKE_TS_LOG"
run enable_again enable
expect_rc enable_again 0
out_has enable_again 'TAILNET_API_ROUTE=UNCHANGED already enabled on :9444'
[ "$(serve_calls)" -eq 0 ] || fail enable_again "a second enable wrote serve config"

echo verify_exact_route
run verify verify
expect_rc verify 0
out_has verify 'TAILNET_API_ROUTE=VERIFIED'

echo verify_probe_green
printf '%s\n' "https://$HOST:9444/api/build 200" "https://$HOST:9444/ 404" >> "$FAKE_CURL_CODES"
run verify_probe verify --probe-url "https://$HOST:9444"
expect_rc verify_probe 0
out_has verify_probe "ok https://$HOST:9444/ -> 404 (only /api mounted)"

echo verify_probe_red_when_spa_is_served
printf '%s\n' "https://$HOST:9444/ 200" >> "$FAKE_CURL_CODES"
run verify_probe_spa verify --probe-url "https://$HOST:9444"
expect_rc verify_probe_spa 1
out_has verify_probe_spa 'answered 200, expected 404 (only /api is mounted)'

echo verify_probe_refuses_non_tailnet_url
run verify_probe_host verify --probe-url "https://api.example.org:9444"
expect_rc verify_probe_host 1
out_has verify_probe_host 'must be https://<node>.ts.net:9444'

echo disable_restores_faucet_only_state
run disable disable
expect_rc disable 0
out_has disable 'TAILNET_API_ROUTE=DISABLED :9444'
state_is disable "s == json.loads('''$FAUCET_STATE''')"

echo disable_again_is_a_noop
: > "$FAKE_TS_LOG"
run disable_again disable
expect_rc disable_again 0
out_has disable_again 'already absent'
grep -q ' off$' "$FAKE_TS_LOG" && fail disable_again "a second disable wrote serve config"

echo funnel_on_9444_fails_status_and_verify
reset_fixture "{\"TCP\": {\"9444\": {\"HTTPS\": true}}, \"Web\": $EXPECTED_WEB, \"AllowFunnel\": {\"$HOST:9444\": true}}"
run funnel_status status
expect_rc funnel_status 1
out_has funnel_status "TAILNET_API_ROUTE_STATE=funnel: AllowFunnel is set for ['$HOST:9444']"
run funnel_verify verify
expect_rc funnel_verify 1
run funnel_enable enable
expect_rc funnel_enable 1
out_has funnel_enable 'refusing to overwrite :9444 (funnel:'

echo conflicting_9444_config_is_not_overwritten
reset_fixture "{\"TCP\": {\"9444\": {\"HTTPS\": true}}, \"Web\": {\"$HOST:9444\": {\"Handlers\": {\"/\": {\"Proxy\": \"http://127.0.0.1:4001\"}}}}}"
cp "$FAKE_TS_STATE" "$TMP/conflict-before.json"
run conflict enable
expect_rc conflict 1
out_has conflict 'refusing to overwrite :9444 (conflict: handlers are'
cmp -s "$FAKE_TS_STATE" "$TMP/conflict-before.json" || fail conflict "a refused enable changed serve state"
[ "$(serve_calls)" -eq 0 ] || fail conflict "a refused enable issued serve"

echo enable_that_also_funnels_is_rolled_back
reset_fixture "$FAUCET_STATE"
export FAKE_TS_FUNNEL_ON_SERVE=1
run rollback_funnel enable
expect_rc rollback_funnel 1
out_has rollback_funnel "after enable the state is 'funnel:"
out_has rollback_funnel 'TAILNET_API_ROUTE=ROLLED_BACK :9444 removed and the serve config equals the pre-write snapshot'
state_is rollback_funnel "s == json.loads('''$FAUCET_STATE''')"

echo enable_that_touches_other_entries_is_rolled_back
reset_fixture "$FAUCET_STATE"
export FAKE_TS_CLOBBER=1
run rollback_clobber enable
expect_rc rollback_clobber 1
out_has rollback_clobber 'enable changed a serve entry other than :9444'
out_has rollback_clobber 'TAILNET_API_ROUTE=ROLLED_BACK :9444 removed and the serve config equals the pre-write snapshot; restored 1 serve command(s)'
# Codex round 7 [P1]: drift is RESTORED, not just detected. 8080 is byte-identical.
state_is rollback_clobber "s == json.loads('''$FAUCET_STATE''')"
grep -Fxq "serve --bg --tls-terminated-tcp=8080 tcp://127.0.0.1:8080" "$FAKE_TS_LOG" \
  || fail rollback_clobber "8080 was not restored with a scoped serve command"
ls "$TAILNET_API_EVIDENCE_DIR"/*-enable/before.json > /dev/null 2>&1 \
  || fail rollback_clobber "no pre-write evidence (before.json) was kept"

echo disable_that_touches_other_entries_restores_them
reset_fixture "{\"TCP\": {\"8080\": {\"TCPForward\": \"127.0.0.1:8080\", \"TerminateTLS\": \"$HOST\"}, \"9444\": {\"HTTPS\": true}}, \"Web\": $EXPECTED_WEB}"
export FAKE_TS_CLOBBER_ON_OFF=1
run disable_clobber disable
expect_rc disable_clobber 1
out_has disable_clobber 'TAILNET_API_ROUTE=ROLLED_BACK :9444 removed and the serve config equals the pre-write snapshot'
state_is disable_clobber "s == json.loads('''$FAUCET_STATE''')"

echo post_write_status_failure_is_rolled_back
reset_fixture "$FAUCET_STATE"
export FAKE_TS_FAIL_READS_AFTER_WRITE=1
run post_status enable
expect_rc post_status 1
out_has post_status "after enable: cannot read 'tailscale serve status --json'"
out_has post_status 'TAILNET_API_ROUTE=ROLLED_BACK'
state_is post_status "s == json.loads('''$FAUCET_STATE''')"

echo post_write_malformed_json_is_rolled_back
reset_fixture "$FAUCET_STATE"
export FAKE_TS_MALFORMED_READS_AFTER_WRITE=1
run post_json enable
expect_rc post_json 1
out_has post_json "after enable: 'tailscale serve status --json' returned malformed JSON"
out_has post_json 'TAILNET_API_ROUTE=ROLLED_BACK'
state_is post_json "s == json.loads('''$FAUCET_STATE''')"

echo rollback_command_failure_is_never_called_removed
reset_fixture "$FAUCET_STATE"
export FAKE_TS_FUNNEL_ON_SERVE=1 FAKE_TS_OFF_FAIL=1
run off_fails enable
expect_rc off_fails 1
# shellcheck disable=SC2016 # literal backticks in the expected message
out_has off_fails 'TAILNET_API_ROUTE=ROLLBACK_INCOMPLETE `serve --https=9444 off` failed (exit 1); :9444 was NOT removed'
out_has off_fails 'before.json is the config to restore by hand; never serve reset'
if grep -Eq 'ROLLED_BACK|9444 removed' "$TMP/off_fails.out"; then
  fail off_fails "claimed a removal although off failed"
fi

echo funnel_to_the_upstream_fails_verify
reset_fixture "{\"TCP\": {\"9444\": {\"HTTPS\": true}, \"443\": {\"HTTPS\": true}}, \"Web\": {\"$HOST:9444\": {\"Handlers\": {\"/api\": {\"Proxy\": \"http://127.0.0.1:5000/api\"}}}, \"$HOST:443\": {\"Handlers\": {\"/\": {\"Proxy\": \"http://127.0.0.1:5000\"}}}}, \"AllowFunnel\": {\"$HOST:443\": true}}"
run funnel_upstream verify
expect_rc funnel_upstream 1
out_has funnel_upstream "a Funnel-enabled handler reaches the frontend upstream: ['$HOST:443/ -> http://127.0.0.1:5000']"
run funnel_upstream_status status
expect_rc funnel_upstream_status 1

echo enable_refuses_when_upstream_is_down
reset_fixture "$FAUCET_STATE"
printf '%s\n' 'http://127.0.0.1:5000/api/build 502' > "$FAKE_CURL_CODES"
run upstream_down enable
expect_rc upstream_down 1
out_has upstream_down 'upstream http://127.0.0.1:5000/api/build answered 502'
[ "$(serve_calls)" -eq 0 ] || fail upstream_down "serve issued with the upstream down"

echo unreadable_serve_status_fails_closed
reset_fixture "$FAUCET_STATE"
export FAKE_TS_STATUS_FAIL=1
run status_down enable
expect_rc status_down 1
out_has status_down "cannot read 'tailscale serve status --json'"
[ "$(serve_calls)" -eq 0 ] || fail status_down "serve issued without reading state"

echo usage_errors_exit_2
unset FAKE_TS_STATUS_FAIL
run usage_none
expect_rc usage_none 2
run usage_bad bogus
expect_rc usage_bad 2

# --- codex round 9 ----------------------------------------------------------
echo concurrent_writer_entry_survives_recovery
# Our write drops 8080 (clobber). Another writer then sets 8080 to its own value
# before recovery reads (post-write read 2) and before the pre-restore re-read
# (read 3). Neither may be overwritten with before.json's value.
for at in 2 3; do
  reset_fixture "$FAUCET_STATE"
  export FAKE_TS_CLOBBER=1 FAKE_TS_CONCURRENT_AT_READ=$at
  run "concurrent_$at" enable
  expect_rc "concurrent_$at" 1
  out_has "concurrent_$at" 'TAILNET_API_ROUTE=ROLLBACK_INCOMPLETE'
  out_has "concurrent_$at" 'TCP[8080]'
  out_has "concurrent_$at" '(conflict)'
  state_is "concurrent_$at" 's["TCP"]["8080"] == {"TCPForward": "127.0.0.1:9999"} and "9444" not in s["TCP"]'
  if grep -q 'ROLLED_BACK' "$TMP/concurrent_$at.out"; then fail "concurrent_$at" "claimed ROLLED_BACK over a concurrent edit"; fi
  if grep -Fq 'serve --bg --tls-terminated-tcp=8080' "$FAKE_TS_LOG"; then fail "concurrent_$at" "restored 8080 over the concurrent writer"; fi
done

echo modified_entry_is_restored_off_then_readd
reset_fixture "$FAUCET_STATE"
export FAKE_TS_CLOBBER_MODIFY=1
run modify enable
expect_rc modify 1
out_has modify 'TAILNET_API_ROUTE=ROLLED_BACK'
state_is modify "s == json.loads('''$FAUCET_STATE''')"
grep -Fxq 'serve --tls-terminated-tcp=8080 off' "$FAKE_TS_LOG" || fail modify "the modified entry was not turned off first"

echo external_edit_between_off_and_readd_survives
# Codex round 14: our write modifies 8080, so recovery runs `off` then a re-add.
# Another writer installs :9999 on 8080 between the two. The re-add must NOT
# run, :9999 must survive, and the result must not be ROLLED_BACK.
reset_fixture "$FAUCET_STATE"
export FAKE_TS_CLOBBER_MODIFY=1 FAKE_TS_EXTERNAL_AFTER_OFF=8080
run between enable
expect_rc between 1
out_has between 'TAILNET_API_ROUTE=ROLLBACK_INCOMPLETE'
# shellcheck disable=SC2016 # literal backticks in the expected message
out_has between 'TCP[8080] changed by another writer during recovery (before `serve --bg --tls-terminated-tcp=8080 tcp://127.0.0.1:8080`)'
state_is between 's["TCP"]["8080"] == {"TCPForward": "127.0.0.1:9999"} and "9444" not in s["TCP"]'
if grep -Fq 'serve --bg --tls-terminated-tcp=8080' "$FAKE_TS_LOG"; then fail between "re-added 8080 over the external edit"; fi
if grep -q 'ROLLED_BACK' "$TMP/between.out"; then fail between "claimed ROLLED_BACK over an external edit"; fi

echo test_fault_seam_refused_against_the_real_cli
reset_fixture "$FAUCET_STATE"
mkdir -p "$TMP/realbin"
printf '#!/bin/sh\ntouch "%s/real-cli-called"; exit 97\n' "$TMP" > "$TMP/realbin/tailscale"
chmod +x "$TMP/realbin/tailscale"
env -u TAILSCALE_BIN PATH="$TMP/realbin:$PATH" TAILNET_API_TEST_FAULT=after-write \
  bash "$SCRIPT" enable > "$TMP/seam.out" 2>&1
RC=$?
expect_rc seam 1
out_has seam 'TAILNET_API_TEST_FAULT is set, but it is a test-only fault seam and must stay unset against the real tailscale CLI'
[ ! -e "$TMP/real-cli-called" ] || fail seam "the real tailscale CLI was invoked with the test seam set"

echo second_run_is_locked_out
reset_fixture "$FAUCET_STATE"
python3 -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600); fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close(); time.sleep(30)' "$TAILNET_API_LOCK" "$TMP/locked" &
holder=$!
for _ in $(seq 50); do [ -e "$TMP/locked" ] && break; sleep 0.1; done
run locked enable
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
rm -f "$TMP/locked"
expect_rc locked 1
out_has locked "another tailnet-api-serve run holds $TAILNET_API_LOCK; nothing written"
[ "$(serve_calls)" -eq 0 ] || fail locked "a locked-out run wrote serve config"

echo malformed_structure_after_write_is_rolled_back
reset_fixture "$FAUCET_STATE"
export FAKE_TS_STRUCT_READS_AFTER_WRITE=1
run struct_once enable
expect_rc struct_once 1
out_has struct_once "'tailscale serve status --json' is malformed: TCP is not an object"
out_has struct_once 'TAILNET_API_ROUTE=ROLLED_BACK'
state_is struct_once "s == json.loads('''$FAUCET_STATE''')"
if grep -q 'Traceback' "$TMP/struct_once.out"; then fail struct_once "crashed with a traceback"; fi

echo malformed_structure_throughout_recovery_is_reported_incomplete
reset_fixture "$FAUCET_STATE"
export FAKE_TS_STRUCT_READS_AFTER_WRITE=99
run struct_always enable
expect_rc struct_always 1
out_has struct_always 'TAILNET_API_ROUTE=ROLLBACK_INCOMPLETE recovery could not verify the result'
state_is struct_always '"9444" not in s["TCP"]'   # the scoped off still ran
if grep -Eq 'ROLLED_BACK|Traceback' "$TMP/struct_always.out"; then fail struct_always "claimed success or crashed"; fi

echo evidence_write_failure_never_blocks_the_rollback
reset_fixture "$FAUCET_STATE"
export FAKE_TS_FUNNEL_ON_SERVE=1 FAKE_TS_BREAK_EVIDENCE=1
# infra#1125: the stub breaks "the newest" evidence dir, picked by sorting NAMES,
# which are wall-clock stamps. In the shared root an earlier case's dir can sort
# after this run's (a backwards clock step, e.g. on WSL2), so the wrong dir was
# broken and the case failed only in-suite. A root of its own holds exactly one
# dir at serve time, so there is nothing to mis-pick.
mkdir -p "$TMP/evidence-broken"
TAILNET_API_EVIDENCE_DIR="$TMP/evidence-broken" run evidence_broken enable
expect_rc evidence_broken 1
out_has evidence_broken 'TAILNET_API_ROUTE=ROLLED_BACK'
out_has evidence_broken 'evidence writes FAILED: '
out_has evidence_broken 'restore.log (IsADirectoryError)'
state_is evidence_broken "s == json.loads('''$FAUCET_STATE''')"
if grep -q 'Traceback' "$TMP/evidence_broken.out"; then fail evidence_broken "crashed with a traceback"; fi

echo unexpected_exception_after_write_is_recovered
reset_fixture "$FAUCET_STATE"
TAILNET_API_TEST_FAULT=after-write run fault enable
expect_rc fault 1
out_has fault 'after enable: RuntimeError: injected fault after the serve write'
out_has fault 'TAILNET_API_ROUTE=ROLLED_BACK'
state_is fault "s == json.loads('''$FAUCET_STATE''')"
if grep -q 'Traceback' "$TMP/fault.out"; then fail fault "crashed with a traceback"; fi

echo funnel_to_loopback_5000_in_any_spelling_fails_verify
for target in 'http://localhost.:5000' 'http://LOCALHOST:5000' 'http://[::1]:5000' 'http://[::ffff:127.0.0.1]:5000' \
    'http://127.1:5000' 'http://0x7f.0.0.1:5000' 'http://0.0.0.0:5000' 'http://127.0.0.1:5000/api' '5000' 'localhost:5000' \
    'http://a.localhost:5000' 'http://[0:0:0:0:0:0:0:1]:5000'; do
  reset_fixture "{\"TCP\": {\"9444\": {\"HTTPS\": true}, \"443\": {\"HTTPS\": true}}, \"Web\": {\"$HOST:9444\": {\"Handlers\": {\"/api\": {\"Proxy\": \"http://127.0.0.1:5000/api\"}}}, \"$HOST:443\": {\"Handlers\": {\"/x\": {\"Proxy\": \"$target\"}}}}, \"AllowFunnel\": {\"$HOST:443\": true}}"
  run funnel_spelling verify
  if [ "$RC" -ne 1 ] || ! grep -Fq "a Funnel-enabled handler reaches the frontend upstream: ['$HOST:443/x -> $target']" "$TMP/funnel_spelling.out"; then
    sed 's/^/    /' "$TMP/funnel_spelling.out" >&2; fail funnel_spelling "Funnel to '$target' passed verify"
  fi
done
for target in 'http://127.0.0.1:8444' 'http://example.org:5000' 'http://10.251.0.10:5000'; do
  reset_fixture "{\"TCP\": {\"9444\": {\"HTTPS\": true}, \"443\": {\"HTTPS\": true}}, \"Web\": {\"$HOST:9444\": {\"Handlers\": {\"/api\": {\"Proxy\": \"http://127.0.0.1:5000/api\"}}}, \"$HOST:443\": {\"Handlers\": {\"/\": {\"Proxy\": \"$target\"}}}}, \"AllowFunnel\": {\"$HOST:443\": true}}"
  run funnel_ok verify
  [ "$RC" -eq 0 ] || { sed 's/^/    /' "$TMP/funnel_ok.out" >&2; fail funnel_ok "a Funnel to '$target' (not this host's :5000) was flagged"; }
done

echo static_tailnet_only_guarantees
# The script's Python body is the only place that talks to tailscale.
port="$(sed -n 's/^PORT, MOUNT = "\([0-9]*\)", .*/\1/p' "$SCRIPT")"
[ -n "$port" ] || fail static "could not read PORT from the script"
# It must never invoke funnel or reset: every tailscale call goes through ts(...).
if grep -nE 'ts\([^)]*"(funnel|reset)"' "$SCRIPT"; then
  fail static "script invokes tailscale funnel/reset"
fi
calls="$(grep -c 'subprocess.run(\[TS,' "$SCRIPT")"
[ "$calls" -eq 1 ] || fail static "expected exactly one raw tailscale call site (inside ts()), found $calls"
# The out-of-tailnet probe must grade this port as closed.
grep -Eq "^FORBIDDEN_PORTS=\"[^\"]*\\b${port}\\b" "$ROOT/testnet/edge/probe_public_exposure_external.sh" \
  || fail static "probe_public_exposure_external.sh does not forbid :$port"
# The route ledger must record the route so it is an explicit exposure decision.
grep -Fq "tailnet_serve: \":${port}/api" "$ROOT/testnet/edge/route-ledger.yml" \
  || fail static "route-ledger.yml does not record the :$port tailnet route"

if [ ${#FAILED[@]} -gt 0 ]; then
  echo "TAILNET_API_SERVE_TESTS=FAIL cases: ${FAILED[*]}" >&2
  exit 1
fi
echo TAILNET_API_SERVE_TESTS=PASS
