#!/usr/bin/env bash
# infra#1073: credentials must never be expanded into curl argv, where ps,
# /proc/<pid>/cmdline and sudo/audit logs can read them.
#
#   1. Checker controls: scripts/check-credential-argv.py flags every known
#      leaking shape (including attached short-option arguments, flag
#      clusters and backslash-newline continuations) and none of the
#      stdin/header-file fix shapes, so the ratchet cannot pass by being
#      blind. 1b proves with real curl against a localhost-only server that
#      the flagged shapes really authenticate with the secret in argv.
#   2. Ratchet: the tracked tree has zero credential-in-argv sites.
#   3. Argv capture: each executable site is run for real, extracted verbatim
#      from its source, against an argv-recording curl that authenticates
#      only a header read from stdin or a header file. Each must succeed, and
#      the credential must appear nowhere in any recorded argv.
#
# Sites covered elsewhere with the same method:
#   post-reboot-verify.sh        -> scripts/tests/test-post-reboot-seed-parity.sh
#   verify-two-node-convergence  -> scripts/tests/test-verify-two-node-convergence.sh
#   relaunch IoT smoke, wal-replay healthcheck -> test-token-argv-pair-sites.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${REPO}/scripts/check-credential-argv.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CHECKS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { CHECKS=$((CHECKS + 1)); echo "  ok    $*"; }

TOKEN="argv-ratchet-token-1073"
PASSWORD="argv-ratchet-password-1073"
BASIC="$(printf 'admin:%s' "$PASSWORD" | base64 | tr -d '\n')"

echo "== 1. checker controls =="
mkdir -p "$TMP/corpus"
# unmask: the leak shapes are stored with their credential flags masked
# (@H@, @u@, --@header@, --@user@; @@ breaks a word split across lines) and
# unmasked at runtime, so this tracked
# file never contains a real leaking shape and the repo ratchet below needs no
# exemption for it.
unmask() { sed -e 's/@@//g' -e 's/--@header@/--header/g' -e 's/--@user@/--user/g' -e 's/@H@/H/g' -e 's/@u@/u/g'; }
# One entry per shell LOGICAL line; backslash-newline continues an entry.
unmask > "$TMP/corpus/leaks.sh" <<'EOF'
curl -@H@ "Authorization: Bearer $TOKEN" http://x
curl -sf --max-time 5 -@H@ "Authorization: Bearer ${WRFCOIN_READER_TOKEN}" http://x
  - 'curl -sf -@H@ "Authorization: Bearer $${WRFCOIN_READER_TOKEN}" http://x'
auth_args=(-@H@ "Authorization: Bearer ${token}")
local cmd=(curl -s -@H@ "Authorization: Bearer $OPERATOR_TOKEN" "http://x")
${token:+-@H@ "Authorization: Bearer ${token}"}
sh -c 'curl -s -@H@ \"Authorization: Bearer \$${READER_TOKEN_VAR}\" \"http://x\"'
curl --@header@ "Authorization: Bearer $T" http://x
wget --@header@="Authorization: Bearer $T" http://x
curl -@H@ "X-API-Key: ${API_KEY}" http://x
curl -@H@ 'authorization: token $GH' http://x
curl_body "$url" -@H@ "$auth_header"
curl -@H@ "${AUTH_HEADER}" http://x
curl -@u@ "admin:${GRAFANA_ADMIN_PASSWORD}" http://x
curl --@user@ "${grafana_user}:${grafana_password}" http://x
curl -@H@"Authorization: Bearer $TOKEN" http://x
curl -@H@"$auth_header" http://x
curl -s@H@ "Authorization: Bearer $TOKEN" http://x
curl -@u@"admin:$PASSWORD" http://x
curl -@H@ 'Authorization: Bearer '"$TOKEN" http://x
curl -sf \
  -@H@ \
  "Authorization: Bearer $TOKEN" http://x
curl -sf --@header@ \
  "X-API-Key: ${API_KEY}" http://x
curl -sf -@u@ \
  "admin:${PASSWORD}" http://x
curl -sf -@H@ $'Authorization: Bearer '"$TOKEN" http://x
curl -@H@ "Authorization: Bearer "$TOKEN http://x
curl -@H@ "${nowhere_headers[@]}" http://x
curl -@u@ "$grafana_creds" http://x
curl -sf -@H@ 'Authorization'": Bearer $TOKEN" http://x
curl -@H@ "Authorization: Bea"'rer '"$TOKEN" http://x
curl -@H@ Auth"oriz"'ation: Bearer '$TOKEN http://x
curl -@H@ 'Author'"ization: "$'Bearer '"$TOKEN" http://x
curl -@H@ $'\x41uthorization: Bearer '"$TOKEN" http://x
result="$(curl -sf -@H@ "Authorization: Bearer $TOKEN" http://x)"
curl -sf -@H@ "Author\
ization: Bearer $TOKEN" http://x
curl -sf --hea@@\
der "Authorization: Bearer $TOKEN" http://x
curl -sf -@H@ Auth\
orization:\ Bearer\ $TOKEN http://x
sh -c 'curl -sf -@H@ "Author''ization: Bearer $TOKEN" http://x'
sh -c $'curl -sf -@H@ "Authorization: Bearer $TOKEN" http://x'
bash -c "curl -sf -@H@ 'Author'\"ization: Bearer \$TOKEN\" http://x"
curl -sf -@H@ $'Author\0ignored'"ization: Bearer $TOKEN" http://x
curl -sf -@H@ $'Author\x00zzz'"ization: Bearer $TOKEN" http://x
curl -sf -@H@ "$h_from_env" http://x
curl -sf -@H@ "$1" http://x
EOF
# Credentials carried in a same-file variable/array: the assignment lines are
# not findings; the -H use lines (2 ... 14, 17, 19) are. infra#1076: a
# multiline initialiser is collected whole (23); an array or scalar whose
# value this file cannot inspect (mapfile, read, a positional) is rejected
# conservatively (25, 27, 28). The assignment value is
# dequoted as one shell word, whatever its quoting.
unmask > "$TMP/corpus/leaks-context.sh" <<'EOF'
headers=("Authorization: Bearer $TOKEN")
curl -sf -@H@ "${headers[@]}" http://x
auth_line="Authorization: Bearer $TOKEN"
curl -sf -@H@ "$auth_line" http://x
h='Authorization: Bearer '"$TOKEN"
curl -sf -@H@ "$h" http://x
g=$'Authorization: Bearer '"$TOKEN"
curl -sf -@H@ "$g" http://x
k=Authorization:\ Bearer\ $TOKEN
curl -sf -@H@ "$k" http://x
hq='Authorization'": Bearer $TOKEN"
curl -sf -@H@ "$hq" http://x
hm='Auth'"orization: "$'Bearer '"$TOKEN"
curl -sf -@H@ "$hm" http://x
hc="Author\
ization: Bearer $TOKEN"
curl -sf -@H@ "$hc" http://x
hn=$'Author\0ignored'"ization: Bearer $TOKEN"
curl -sf -@H@ "$hn" http://x
declare -a mheaders=(
  "Authorization: Bearer $TOKEN"
)
curl -sf -@H@ "${mheaders[@]}" http://x
mapfile -t file_headers < headers.txt
curl -sf -@H@ "${file_headers[@]}" http://x
IFS= read -r read_hdr < header.txt
curl -sf -@H@ "$read_hdr" http://x
send_with() { local hdr="$1"; curl -sf -@H@ "$hdr" http://x; }
EOF
cat > "$TMP/corpus/clean.sh" <<'EOF'
printf 'Authorization: Bearer %s\n' "$TOKEN" | curl -H @- http://x
printf "Authorization: Bearer %s\n" "$${WRFCOIN_READER_TOKEN}" | curl -sf -H @- http://x
curl -H @<(printf 'Authorization: Bearer %s\n' "$JWT") http://x
curl -H @"$HEADER_FILE" http://x
curl -H@- http://x
curl -sH @- http://x
printf 'Authorization: Bearer %s\n' "$TOKEN" | curl -sf \
  -H @- \
  http://x
curl -H "Content-Type: application/json" -H "Accept: $ACCEPT" http://x
curl -H "X-GitHub-Api-Version: 2022-11-28" http://x
curl -X GET "http://x/report" \
  -H "X-API-Key: <admin_api_key>" \
  -o "reports/r-$(date +%Y%m%d).json"
[[ "$header" == "Authorization: Bearer ${EXPECT_TOKEN:?}" ]] || exit 22
headers: { Authorization: `Bearer ${TOKEN}` },
curl -u "$(id -u)" http://x
docker run -u "$(id -u):$(id -g)" image
accept_headers=("Accept: application/json")
printf 'Authorization: Bearer %s\n' "$TOKEN" | curl -sf -H @- -H "${accept_headers[@]}" http://x
curl -H $'Accept: application/json' http://x
ACCEPT_HEADER="Accept: text/plain"
curl -H "$ACCEPT_HEADER" http://x
h_accept="Accept: application/json"
curl -H "$h_accept" http://x
accept_multi=(
  "Accept: application/json"
  # a comment inside the initialiser
  "X-Trace: $TRACE_ID"
)
curl -H "${accept_multi[@]}" http://x
accept_line='Accept: '"$ACCEPT_VALUE"
curl -H "$accept_line" http://x
curl -H 'Accept'": application/json" http://x
accept_split='Acc'"ept: $ACCEPT_VALUE"
curl -H "$accept_split" http://x
echo "don't pass tokens with -H; see the runbook"
note='-H Authorization\
: Bearer $TOKEN is literal text here'
# a comment ending in a backslash does not continue \
curl -sf -H @- http://x
curl -sf -H $'Accept: \0ignored'"$ACCEPT_VALUE" http://x
sh -c 'printf "Authorization: Bearer %s\n" "$TOKEN" | curl -sf -H @- "$URL"'
EOF
logical_entries() { grep -vc '\\$' "$1"; }
leaks_expected="$(logical_entries "$TMP/corpus/leaks.sh")"
set +e
leak_out="$(python3 "$CHECKER" --root "$TMP/corpus" leaks.sh 2>/dev/null)"
leak_rc=$?
clean_out="$(python3 "$CHECKER" --root "$TMP/corpus" clean.sh 2>&1)"
clean_rc=$?
set -e
[[ "$leak_rc" -eq 1 ]] || fail "checker exit ${leak_rc} on the leak corpus (want 1)"
leaks_found="$(grep -c '^leaks.sh:' <<<"$leak_out")"
[[ "$leaks_found" -eq "$leaks_expected" ]] || {
  printf '%s\n' "$leak_out" >&2
  fail "checker flagged ${leaks_found}/${leaks_expected} leak shapes"
}
ok "checker flags all ${leaks_expected} leaking shapes (incl. attached -H\"…\"/-u\"…\", flag clusters, continuations, any quote splits, \$'…', unresolved arrays)"
set +e
ctx_out="$(python3 "$CHECKER" --root "$TMP/corpus" leaks-context.sh 2>/dev/null)"
set -e
[[ "$(grep -o '^leaks-context.sh:[0-9]*' <<<"$ctx_out" | cut -d: -f2 | tr '\n' ' ')" == "2 4 6 8 10 12 14 17 19 23 25 27 28 " ]] \
  || { printf '%s\n' "$ctx_out" >&2; fail "same-file credential array/variable uses not flagged at lines 2 4 6 8 10 12 14 17 19 23 25 27 28"; }
ok "credential header carried in a same-file array or variable (any quoting) is flagged at its -H use"
# A continued entry is reported at the physical line of its flag.
split_line="$(grep -n '^  -H \\$' "$TMP/corpus/leaks.sh" | cut -d: -f1)"
grep -q "^leaks.sh:${split_line}: \[header-literal\]" <<<"$leak_out" \
  || { printf '%s\n' "$leak_out" >&2; fail "continued -H not reported at its physical line ${split_line}"; }
ok "continued -H diagnostic keeps its physical line number (${split_line})"
[[ "$clean_rc" -eq 0 ]] || { printf '%s\n' "$clean_out" >&2; fail "checker flagged a fix-pattern/benign shape"; }
ok "checker passes the $(logical_entries "$TMP/corpus/clean.sh") stdin/header-file/benign shapes"

echo "== 1b. real-curl argv control =="
# Proves the attached and continued shapes are real exposures, not just regex
# matches: real curl authenticates with them against a localhost-only server
# while an argv recorder sees the credential; the stdin fix authenticates with
# clean argv. The same bytes are executed and scanned.
REAL_CURL="$(command -v curl)"
mkdir -p "$TMP/real"
cat > "$TMP/real/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${REAL_ARGV_LOG:?}"
exec "${REAL_CURL:?}" "$@"
SH
chmod +x "$TMP/real/curl"
python3 - "$TMP/real/port" "$TOKEN" "$BASIC" > /dev/null 2>&1 <<'PY' &
import http.server, sys
port_file, token, basic = sys.argv[1:4]
ok = {f"Bearer {token}", f"Basic {basic}"}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.headers.get("Authorization") in ok else 401)
        self.end_headers()
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do [[ -s "$TMP/real/port" ]] && break; sleep 0.1; done
[[ -s "$TMP/real/port" ]] || fail "localhost control server did not start"
URL="http://127.0.0.1:$(cat "$TMP/real/port")/"
# real_control <name> <want: leak|clean>: body on stdin (masked), run + scan.
real_control() {
  local name="$1" want="$2" src="$TMP/real/$1.sh"
  shift 2  # any remaining NAME=value args are extra environment
  unmask > "$src"
  : > "$TMP/real/argv.log"
  env PATH="$TMP/real:$PATH" REAL_CURL="$REAL_CURL" REAL_ARGV_LOG="$TMP/real/argv.log" \
    T="$TOKEN" PASSWORD="$PASSWORD" URL="$URL" "$@" bash "$src" \
    || fail "real-curl control ${name}: real curl did not authenticate"
  local leaked=clean flagged rc
  grep -qF -e "$TOKEN" -e "$PASSWORD" "$TMP/real/argv.log" && leaked=leak
  # A detected leak is exit 1 WITH a finding for this file; clean is exit 0.
  # Anything else (a crash, a traceback) is a failure, never a detection.
  set +e
  python3 "$CHECKER" --root "$TMP/real" "$name.sh" > "$TMP/real/check.out" 2> "$TMP/real/check.err"
  rc=$?
  set -e
  ! grep -q 'Traceback' "$TMP/real/check.err" || fail "real-curl control ${name}: checker crashed"
  if [[ "$rc" -eq 1 ]] && grep -q "^${name}.sh:[0-9]*: \[" "$TMP/real/check.out"; then
    flagged=leak
  elif [[ "$rc" -eq 0 ]]; then
    flagged=clean
  else
    fail "real-curl control ${name}: checker exit ${rc} without a finding"
  fi
  [[ "$leaked" == "$want" && "$flagged" == "$want" ]] \
    || fail "real-curl control ${name}: argv=${leaked} checker=${flagged} (want ${want})"
  ok "real curl: ${name} authenticates; argv ${want}, checker ${want}"
}
real_control attached-header leak <<'EOF'
curl -sf -@H@"Authorization: Bearer $T" "$URL"
EOF
real_control continued-header leak <<'EOF'
curl -sf \
  -@H@ \
  "Authorization: Bearer $T" "$URL"
EOF
real_control attached-user leak <<'EOF'
curl -sf -@u@"admin:$PASSWORD" "$URL"
EOF
real_control ansi-c-header leak <<'EOF'
curl -sf -@H@ $'Authorization: Bearer '"$T" "$URL"
EOF
real_control header-array leak <<'EOF'
headers=("Authorization: Bearer $T")
curl -sf -@H@ "${headers[@]}" "$URL"
EOF
real_control concat-scalar leak <<'EOF'
h='Authorization: Bearer '"$T"
curl -sf -@H@ "$h" "$URL"
EOF
real_control ansi-c-scalar leak <<'EOF'
h=$'Authorization: Bearer '"$T"
curl -sf -@H@ "$h" "$URL"
EOF
real_control split-name-scalar leak <<'EOF'
h='Authorization'": Bearer $T"
curl -sf -@H@ "$h" "$URL"
EOF
real_control split-name-direct leak <<'EOF'
curl -sf -@H@ 'Authorization'": Bearer $T" "$URL"
EOF
real_control mixed-quoting leak <<'EOF'
curl -sf -@H@ 'Auth'"orization: Bea"$'rer '"$T" "$URL"
EOF
real_control continued-in-quotes leak <<'EOF'
curl -sf -@H@ "Author\
ization: Bearer $T" "$URL"
EOF
real_control continued-option-name leak <<'EOF'
curl -sf --hea@@\
der "Authorization: Bearer $T" "$URL"
EOF
real_control continued-scalar leak <<'EOF'
h="Author\
ization: Bearer $T"
curl -sf -@H@ "$h" "$URL"
EOF
real_control sh-c-split-quotes leak <<'EOF'
sh -c 'curl -sf -@H@ "Author''ization: Bearer $T" "$URL"'
EOF
real_control sh-c-ansi-c leak <<'EOF'
sh -c $'curl -sf -@H@ "Authorization: Bearer $T" "$URL"'
EOF
real_control ansi-c-nul-direct leak <<'EOF'
curl -sf -@H@ $'Author\0ignored'"ization: Bearer $T" "$URL"
EOF
real_control ansi-c-nul-scalar leak <<'EOF'
h=$'Author\0ignored'"ization: Bearer $T"
curl -sf -@H@ "$h" "$URL"
EOF
real_control env-scalar leak "h=Authorization: Bearer $TOKEN" <<'EOF'
curl -sf -@H@ "$h" "$URL"
EOF
real_control multiline-array leak <<'EOF'
declare -a headers=(
  "Authorization: Bearer $T"
)
curl -sf -@H@ "${headers[@]}" "$URL"
EOF
real_control benign-array clean <<'EOF'
accept_headers=("Accept: application/json")
printf 'Authorization: Bearer %s\n' "$T" | curl -sf -H @- -H "${accept_headers[@]}" "$URL"
EOF
real_control stdin-fix clean <<'EOF'
printf 'Authorization: Bearer %s\n' "$T" | curl -sf \
  -H @- \
  "$URL"
EOF
kill "$SERVER_PID" 2>/dev/null || true

echo "== 1c. pathological input =="
# The checker must finish every odd input with exit 0 or 1 and no traceback,
# and a numeric-escape oddity must not hide the rest of the line or file.
mkdir -p "$TMP/odd"
# odd_case <name> <want rc> [<want finding line>]: body on stdin (masked).
odd_case() {
  local name="$1" want="$2" line="${3:-}" rc
  unmask > "$TMP/odd/$name.sh"
  set +e
  LC_ALL=C python3 "$CHECKER" --root "$TMP/odd" "$name.sh" > "$TMP/odd/out" 2> "$TMP/odd/err"
  rc=$?
  set -e
  ! grep -q 'Traceback' "$TMP/odd/err" || { cat "$TMP/odd/err" >&2; fail "pathological ${name}: traceback"; }
  [[ "$rc" -eq "$want" ]] || { cat "$TMP/odd/out" "$TMP/odd/err" >&2; fail "pathological ${name}: exit ${rc} (want ${want})"; }
  [[ -z "$line" ]] || grep -q "^${name}.sh:${line}: \[" "$TMP/odd/out" \
    || { cat "$TMP/odd/out" >&2; fail "pathological ${name}: no finding at line ${line}"; }
}
odd_case ansi-c-above-max 0 <<'EOF'
printf '%s' $'\U00110000'
EOF
odd_case ansi-c-overflow 0 <<'EOF'
printf '%s' $'\UFFFFFFFF'
EOF
odd_case ansi-c-surrogate 0 <<'EOF'
printf '%s' $'\uD800' $'\777'
EOF
odd_case rest-of-line-inspected 1 1 <<'EOF'
x=$'\UFFFFFFFF'; curl -sf -@H@ "Authorization: Bearer $TOKEN" http://x
EOF
odd_case rest-of-file-inspected 1 2 <<'EOF'
printf '%s' $'\UFFFFFFFF' $'\U00110000'
curl -sf -@H@ "Authorization: Bearer $TOKEN" http://x
EOF
odd_case unterminated-quotes 1 1 <<'EOF'
curl -sf -@H@ "Authorization: Bearer $TOKEN
EOF
odd_case unbalanced-substitutions 0 <<'EOF'
echo $(((((( ${ `unterminated $'\x
EOF
printf 'echo %s x%s\n' "$(printf '$(%.0s' $(seq 1 300))" "$(printf ')%.0s' $(seq 1 300))" | odd_case deep-nesting 0
printf 'curl \\' | odd_case trailing-backslash-eof 0
printf '\xff\xfe\x00 curl -H x\r\n\xc3\x28 echo ok\r\n' | odd_case invalid-bytes 0
ok "pathological inputs (bad \\U escapes, surrogates, unterminated, deep nesting, invalid bytes) exit 0/1 without a traceback; findings after them are kept"

echo "== 2. repo ratchet =="
python3 "$CHECKER" --root "$REPO" || fail "credential-in-argv sites in the tracked tree (see above)"
ok "tracked tree has zero credential-in-argv sites"

echo "== 3. argv capture on executable sites =="
mkdir -p "$TMP/bin"
# Recording curl: logs argv; takes the Authorization header only from stdin
# (-H @-) or a header file (-H @path); 401/exit 22 unless it matches.
cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ARGV_LOG:?}"
header='' url='' out='' wfmt=''
while (( $# > 0 )); do
  case "$1" in
    -H|--header)
      case "$2" in
        @-) IFS= read -r header || true ;;
        @*) IFS= read -r header < "${2#@}" || true ;;
      esac
      shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -w) wfmt="$2"; shift 2 ;;
    -X|-d|--data|--max-time|--connect-timeout|--retry|--retry-delay|-u|--user) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
code=200 rc=0
case "$url" in
  */readyz|*/health) body='{"status":"ready"}' ;;
  *)
    if [[ "$header" != "${EXPECT_HEADER:?}" ]]; then
      code=401 rc=22 body='{"error":"unauthorized"}'
    else
      case "$url" in
        */metrics) body='wrfcoin_state_divergence_total 0' ;;
        */jobs*) body='{"jobs":[{"id":1},{"id":2}]}' ;;
        */registration-token) body='{"token":"stub-registration"}' ;;
        */api/dashboards/*) body='{"dashboard":{"title":"stub"}}' ;;
        */api/snapshots) body='{"url":"http://grafana.stub/s/1"}' ;;
        *) body='{"ok":true}' ;;
      esac
    fi ;;
esac
if [[ -n "$out" ]]; then printf '%s\n' "$body" > "$out"; else printf '%s\n' "$body"; fi
[[ -z "$wfmt" ]] || printf '%s' "$code"
exit "$rc"
SH
chmod +x "$TMP/bin/curl"
export ARGV_LOG="$TMP/argv.log"
BEARER="Authorization: Bearer ${TOKEN}"

# assert_no_leak <label> <secret>: the site ran curl, and never with the secret.
assert_no_leak() {
  [[ -s "$ARGV_LOG" ]] || fail "$1: curl was never invoked"
  ! grep -qF "$2" "$ARGV_LOG" || fail "$1: credential visible in curl argv"
  ! grep -q 'Authorization' "$ARGV_LOG" || fail "$1: an Authorization header travelled in argv"
}
# extract_fn <name> <file>: the function's source, verbatim. Heredoc bodies
# are skipped when looking for the closing column-0 brace, because several
# functions embed Python whose dict literals close in column 0.
extract_fn() {
  python3 - "$1" "$2" <<'EXTRACT'
import re, sys
name, path = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().split("\n")
out, inside, heredoc = [], False, None
for i, line in enumerate(lines):
    if not inside:
        if not line.startswith(name + "() {"):
            continue
        inside = True
    out.append(line)
    if heredoc is not None:
        if line.strip() == heredoc:
            heredoc = None
        continue
    m = re.search(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", line)
    if m:
        heredoc = m.group(1)
        continue
    # A column-0 brace closes the function only where shell code resumes
    # (blank line, comment, next definition, EOF) -- not inside a multi-line
    # `python3 -c "..."` string, where the next line is still that string.
    nxt = lines[i + 1] if i + 1 < len(lines) else ""
    if line == "}" and len(out) > 1 and (
        nxt.strip() == "" or nxt.startswith("#") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*\(\) \{", nxt)
    ):
        break
if not out or out[-1] != "}":
    sys.exit(f"extract_fn: {name} not found or unterminated in {path}")
print("\n".join(out))
EXTRACT
}

# 3a. Dockerfile.core HEALTHCHECK, run under /bin/sh exactly as Docker does.
: > "$ARGV_LOG"
hc="$(python3 - "$REPO/infra/docker/Dockerfile.core" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read().replace("\\\n", " ")
m = re.search(r"^HEALTHCHECK .*? CMD (.*)$", src, re.M)
assert m, "HEALTHCHECK CMD not found"
print(m.group(1).strip())
PY
)"
env PATH="$TMP/bin:$PATH" EXPECT_HEADER="$BEARER" WRFCOIN_READER_TOKEN="$TOKEN" sh -c "$hc" \
  || fail "Dockerfile.core healthcheck failed with the Reader token"
assert_no_leak "Dockerfile.core healthcheck" "$TOKEN"
ok "Dockerfile.core HEALTHCHECK authenticates /metrics via stdin"

# 3b. testnet/docker-compose.override.yml node healthcheck (compose $$ -> $).
: > "$ARGV_LOG"
hc="$(python3 - "$REPO/testnet/docker-compose.override.yml" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^\s*- '(curl [^\n]*wrfcoin_state_divergence_total)'\s*$", src, re.M)
assert m, "node healthcheck not found"
print(m.group(1).replace("''", "'").replace("$$", "$"))
PY
)"
env PATH="$TMP/bin:$PATH" EXPECT_HEADER="$BEARER" WRFCOIN_READER_TOKEN="$TOKEN" sh -c "$hc" \
  || fail "compose override node healthcheck failed with the Reader token"
assert_no_leak "compose override healthcheck" "$TOKEN"
ok "compose override node healthcheck authenticates /metrics via stdin"

# 3c. run-p2p-partition-ci.sh api_call: host docker argv and container curl argv.
: > "$ARGV_LOG"
cat > "$TMP/bin/docker" <<'SH'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${ARGV_LOG:?}"
[[ "$1" == exec ]] || exit 2
shift
[[ "$1" == -i ]] && shift
shift # container name
exec "$@"
SH
chmod +x "$TMP/bin/docker"
out="$(env PATH="$TMP/bin:$PATH" EXPECT_HEADER="$BEARER" OPERATOR_TOKEN="$TOKEN" CONTAINER_PREFIX=p2p \
  bash -c "$(extract_fn api_call "$REPO/scripts/run-p2p-partition-ci.sh")"$'\n''api_call node-a POST /mine "{\"n\":1}"')" \
  || fail "run-p2p-partition-ci api_call failed"
[[ "$out" == '{"ok":true}' ]] || fail "p2p api_call did not authenticate (got: $out)"
grep -q '^docker exec -i p2p-node-a curl' "$ARGV_LOG" || fail "p2p api_call did not use docker exec -i"
assert_no_leak "p2p api_call" "$TOKEN"
ok "run-p2p-partition-ci api_call pipes the bearer through docker exec -i"

# 3d. setup-self-hosted-runner.sh registration-token exchange (the statement).
: > "$ARGV_LOG"
stmt="$(python3 - "$REPO/scripts/setup-self-hosted-runner.sh" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^\s*REG_RESPONSE=\$\(.*?registration-token\"\)", src, re.S | re.M)
assert m, "registration-token request not found"
print(m.group(0))
PY
)"
out="$(env PATH="$TMP/bin:$PATH" EXPECT_HEADER="Authorization: Bearer ghp_${TOKEN}" \
  GITHUB_TOKEN="ghp_${TOKEN}" REPO=wrfcoin/infra bash -c "$stmt"$'\n''printf "%s" "$REG_RESPONSE"')" \
  || fail "runner registration-token request failed"
[[ "$out" == *stub-registration* ]] || fail "runner token exchange did not authenticate (got: $out)"
assert_no_leak "setup-self-hosted-runner" "$TOKEN"
ok "setup-self-hosted-runner exchanges the GitHub token via stdin"

# 3e. public-exposure-edge-gate.yml "Fetch this run attempt's job records" step.
: > "$ARGV_LOG"
step="$(python3 - "$REPO/.github/workflows/public-exposure-edge-gate.yml" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for job in wf["jobs"].values():
    for st in job.get("steps", []):
        if st.get("name", "").startswith("Fetch this run attempt"):
            print(st["run"])
            sys.exit(0)
sys.exit("job-records step not found")
PY
)"
out="$(cd "$TMP" && env PATH="$TMP/bin:$PATH" EXPECT_HEADER="$BEARER" GH_TOKEN="$TOKEN" \
  GITHUB_API_URL=http://api.stub GITHUB_REPOSITORY=wrfcoin/infra GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 \
  bash -c "$step")" || fail "edge-gate job-records step failed"
[[ "$out" == 'retrieved 2 job record(s)' ]] || fail "edge-gate step did not authenticate (got: $out)"
assert_no_leak "public-exposure-edge-gate step" "$TOKEN"
ok "public-exposure-edge-gate job-records step sends GH_TOKEN via stdin"

# 3f. sustained-test-preflight.sh check_test_submission (commit + reveal).
: > "$ARGV_LOG"
PRE="$REPO/testnet/scripts/sustained-test-preflight.sh"
out="$(env PATH="$TMP/bin:$PATH" EXPECT_HEADER="$BEARER" bash -c "
PERFORM_TEST_SUBMISSION=1 NODE_API=http://node.stub CONTRIBUTOR=0xb02 STATION_ID=s1
get_auth_token() { printf '%s' '$TOKEN'; }
build_test_payload() { printf '{}'; }
build_commit_hash() { printf 'deadbeef'; }
pass() { printf 'PASS %s\n' \"\$*\"; }
fail() { printf 'FAIL %s\n' \"\$*\"; }
warn() { printf 'WARN %s\n' \"\$*\"; }
$(extract_fn curl_with_bearer "$PRE")
$(extract_fn check_test_submission "$PRE")
check_test_submission")" || fail "preflight check_test_submission errored"
[[ "$out" == *"commit=200 reveal=200"* ]] || fail "preflight commit/reveal did not authenticate (got: $out)"
[[ "$(grep -c '/transactions/contribution/' "$ARGV_LOG")" -eq 2 ]] || fail "preflight did not issue commit and reveal"
assert_no_leak "sustained-test-preflight" "$TOKEN"
ok "sustained-test-preflight commit/reveal authenticate via stdin"

# 3g. sustained-operation-test.sh: the load generator's helper (both token
# states) and export_grafana_snapshot's Basic credentials.
OPS="$REPO/testnet/scripts/sustained-operation-test.sh"
: > "$ARGV_LOG"
code="$(env PATH="$TMP/bin:$PATH" EXPECT_HEADER="$BEARER" bash -c "
$(extract_fn curl_with_bearer "$OPS")
curl_with_bearer '$TOKEN' -s -o /dev/null -w '%{http_code}' -X POST http://node.stub/transactions/contribution/commit")" \
  || fail "sustained-operation curl_with_bearer failed"
[[ "$code" == 200 ]] || fail "sustained-operation bearer not delivered (HTTP $code)"
assert_no_leak "sustained-operation load generator" "$TOKEN"
# Empty token => no Authorization header at all (the previous ${token:+...}).
code="$(env PATH="$TMP/bin:$PATH" EXPECT_HEADER="$BEARER" bash -c "
$(extract_fn curl_with_bearer "$OPS")
curl_with_bearer '' -s -o /dev/null -w '%{http_code}' http://node.stub/x" || true)"
[[ "$code" == 401 ]] || fail "empty token must send no Authorization header (HTTP $code)"
routed="$(extract_fn spawn_load_generator "$OPS" | grep -cF 'curl_with_bearer "${token}"' || true)"
[[ "$routed" -eq 2 ]] || fail "load generator commit/reveal no longer route through curl_with_bearer (${routed}/2)"
ok "sustained-operation load generator bearer via stdin; empty token sends no header"

: > "$ARGV_LOG"
out="$(cd "$TMP" && env PATH="$TMP/bin:$PATH" EXPECT_HEADER="Authorization: Basic ${BASIC}" bash -c "
GRAFANA_ADMIN_USER=admin GRAFANA_ADMIN_PASSWORD='$PASSWORD' GRAFANA_URL=http://grafana.stub
GRAFANA_DASHBOARD_UID=u GRAFANA_SNAPSHOT_TIMEOUT_SECS=5 SCRIPT_START_ISO=2026-01-01T00:00:00Z
SNAPSHOT_DASHBOARD_FILE=$TMP/dash.json SNAPSHOT_REQUEST_FILE=$TMP/req.json SNAPSHOT_RESPONSE_FILE=$TMP/resp.json
TESTNET_ENV_FILE=/nonexistent
log() { :; }; err() { printf 'ERR %s\n' \"\$*\"; }
write_snapshot_metadata() { printf 'META %s %s\n' \"\$1\" \"\$2\"; }
$(extract_fn env_file_value "$OPS")
$(extract_fn curl_with_basic_auth "$OPS")
$(extract_fn export_grafana_snapshot "$OPS")
export_grafana_snapshot")" || fail "export_grafana_snapshot errored: $out"
[[ "$out" == "META exported "* ]] || fail "Grafana snapshot did not authenticate (got: $out)"
[[ "$(grep -c 'grafana.stub' "$ARGV_LOG")" -eq 2 ]] || fail "Grafana lookup + snapshot were not both issued"
assert_no_leak "export_grafana_snapshot" "$PASSWORD"
! grep -qF "$BASIC" "$ARGV_LOG" || fail "export_grafana_snapshot: encoded Basic credential in argv"
ok "sustained-operation Grafana snapshot sends Basic credentials via stdin"

echo "PASS: ${CHECKS} credential-argv ratchet checks"
