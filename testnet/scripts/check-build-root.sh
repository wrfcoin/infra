#!/usr/bin/env bash
# Pre-build guard for a testnet release build (infra#1077). Run it (do not
# source it) in the shell that sourced export-build-provenance.sh, right before
# `docker compose ... build`, with the SAME compose global arguments:
#
#   check-build-root.sh --service wrfcoin-backend --service db-migrate \
#     --service wrfcoin-frontend -- -p testnet --env-file .../.env -f ... -f ...
#
# It refuses (exit 1, BUILD_ROOT=FAIL) unless:
#   1. WRFCOIN_BUILD_ROOT is set: provenance was exported in this shell;
#   2. WRFCOIN_ROOT is EXPORTED and resolves to WRFCOIN_BUILD_ROOT. This process
#      only sees exported variables, exactly like `docker compose`, so a root
#      that is set but not exported is caught here;
#   3. <root>/.dockerignore is the canonical infra/testnet/workspace.dockerignore;
#   4. every named service renders a build.context that resolves to the root or
#      a directory inside it, per `docker compose <args> config --format json`,
#      the same resolution the build will use.
# The render contains interpolated secrets, so it is written to a private
# temporary file, never printed, and deleted on exit. Compose's error output can
# contain them too, so a failed render prints only a fixed class of failure,
# and a checked service is reported only by name and a fixed inside/outside/
# missing status, never by its rendered or resolved context.
#
# --render FILE checks an existing `config --format json` render instead of
# running compose (used by the tests; the file is not deleted).
set -euo pipefail

fail() { echo "BUILD_ROOT=FAIL $*" >&2; exit 1; }
usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

services=()
render=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) [[ -n "${2:-}" ]] || fail "--service needs a name"; services+=("$2"); shift 2 ;;
    --render) [[ -n "${2:-}" ]] || fail "--render needs a file"; render="$2"; shift 2 ;;
    --) shift; break ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1 (compose arguments go after --)" ;;
  esac
done
compose_args=("$@")

[[ ${#services[@]} -gt 0 ]] || fail "name at least one --service that this build will build"
[[ -n "$render" || ${#compose_args[@]} -gt 0 ]] \
  || fail "pass the build's compose global arguments after -- (the -f set and --env-file), or --render FILE"

[[ -n "${WRFCOIN_BUILD_ROOT:-}" ]] \
  || fail "WRFCOIN_BUILD_ROOT is not set: source export-build-provenance.sh in this shell first"
root="$(realpath -e -- "$WRFCOIN_BUILD_ROOT" 2>/dev/null)" \
  || fail "WRFCOIN_BUILD_ROOT $WRFCOIN_BUILD_ROOT does not exist"

exported="$(printenv WRFCOIN_ROOT || true)"
[[ -n "$exported" ]] \
  || fail "WRFCOIN_ROOT is not exported, so compose would build from its default context, not $root: export WRFCOIN_ROOT=$root"
[[ "$(realpath -m -- "$exported")" == "$root" ]] \
  || fail "exported WRFCOIN_ROOT=$exported is not the labelled build root $root"

template="$root/infra/testnet/workspace.dockerignore"
[[ -f "$template" ]] || fail "$template is missing"
cmp -s -- "$template" "$root/.dockerignore" \
  || fail "$root/.dockerignore is missing or differs from infra/testnet/workspace.dockerignore"

if [[ -z "$render" ]]; then
  tmpdir="$(mktemp -d)"
  trap 'rm -rf -- "$tmpdir"' EXIT
  chmod 700 "$tmpdir"
  render="$tmpdir/render.json"
  if ! docker compose "${compose_args[@]}" config --format json >"$render" 2>"$tmpdir/render.err"; then
    # NEVER echo compose's stderr: its messages interpolate values (for example
    # `invalid containerPort: <value>`), which can be secrets from --env-file.
    # Print only a fixed, allowlisted class; the operator reproduces the detail
    # privately if needed.
    class="unclassified"
    if grep -q 'required variable' "$tmpdir/render.err"; then class="a required variable is unset"
    elif grep -qiE 'no such file|not found' "$tmpdir/render.err"; then class="a compose or env file was not found"
    elif grep -qiE 'yaml|mapping|unmarshal' "$tmpdir/render.err"; then class="a compose file does not parse"
    elif grep -qiE 'invalid|validating' "$tmpdir/render.err"; then class="a rendered value is invalid"
    fi
    fail "docker compose config failed for the given arguments ($class; compose's own message is withheld because it can contain secret values)"
  fi
fi

python3 - "$root" "$render" "${services[@]}" <<'PY'
import json, os, sys
root, render, names = sys.argv[1], sys.argv[2], sys.argv[3:]
try:
    services = json.load(open(render, encoding="utf-8")).get("services") or {}
except (OSError, ValueError) as exc:
    print(f"BUILD_ROOT=FAIL cannot read the compose render: {exc.__class__.__name__}", file=sys.stderr)
    sys.exit(1)
# Only the service name (from --service) and a fixed status are ever printed.
# The rendered context, and its resolved path, can carry interpolated values
# (`context: ${WRFCOIN_ROOT}/${SECRET}`, `https://user:${TOKEN}@host/repo.git`),
# so they are compared but never echoed.
bad = 0
for name in names:
    build = (services.get(name) or {}).get("build")
    context = build.get("context") if isinstance(build, dict) else None
    if not context:
        print(f"  {name}: STOP (not rendered with a build context)", file=sys.stderr)
        bad = 1
        continue
    resolved = os.path.realpath(context)
    inside = resolved == root or resolved.startswith(root + os.sep)
    print(f"  {name}: {'OK (context inside the labelled root)' if inside else 'STOP (context outside the labelled root)'}",
          file=sys.stderr)
    bad |= not inside
if bad:
    print(f"BUILD_ROOT=FAIL a build context is not inside the labelled root {root}", file=sys.stderr)
    sys.exit(1)
print(f"BUILD_ROOT=OK root={root} services={','.join(names)}", file=sys.stderr)
PY
