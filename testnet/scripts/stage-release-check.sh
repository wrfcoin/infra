#!/usr/bin/env bash
# Read-only pre-stage check for a release (infra#1135, Refs infra#1104).
#
#   stage-release-check.sh --backend-pin SHA --infra-pin SHA --workspace DIR
#
# DIR is a gate workspace holding git checkouts DIR/backend and DIR/infra.
# Verifies, without writing anything or touching the network:
#   1. HEAD and refs/remotes/origin/main of BOTH gate repos equal their pin;
#   2. WRFCOIN_EXPECTED_DB_MIGRATION in testnet/docker-compose.testnet.yml at the
#      infra pin equals the newest drizzle/migrations/*.sql at the backend pin.
# Exit 0 only when every check passes; every failure is reported, then exit 1.
set -euo pipefail

BACKEND_PIN=""; INFRA_PIN=""; WORKSPACE=""
usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "STAGE_RELEASE_CHECK=FAIL $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend-pin) [[ $# -ge 2 ]] || die "--backend-pin needs a value"; BACKEND_PIN="$2"; shift 2 ;;
    --infra-pin) [[ $# -ge 2 ]] || die "--infra-pin needs a value"; INFRA_PIN="$2"; shift 2 ;;
    --workspace) [[ $# -ge 2 ]] || die "--workspace needs a value"; WORKSPACE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
sha_re='^[0-9a-f]{40}$'
[[ "$BACKEND_PIN" =~ $sha_re ]] || die "--backend-pin must be a full lowercase 40-hex SHA"
[[ "$INFRA_PIN" =~ $sha_re ]] || die "--infra-pin must be a full lowercase 40-hex SHA"
[[ -n "$WORKSPACE" && -d "$WORKSPACE" ]] || die "--workspace must be an existing directory"

failures=0
bad() { echo "FAIL $*" >&2; failures=$((failures + 1)); }
good() { echo "ok   $*"; }

check_repo() {
  local name="$1" pin="$2" dir="$WORKSPACE/$1" head main
  if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    bad "$name: $dir is not a git checkout"; return
  fi
  head="$(git -C "$dir" rev-parse --verify -q 'HEAD^{commit}' || true)"
  main="$(git -C "$dir" rev-parse --verify -q 'refs/remotes/origin/main^{commit}' || true)"
  if [[ "$head" == "$pin" ]]; then good "$name HEAD == pin"; else bad "$name HEAD ${head:-<none>} != pin $pin"; fi
  if [[ "$main" == "$pin" ]]; then good "$name origin/main == pin"; else bad "$name origin/main ${main:-<none>} != pin $pin"; fi
}
check_repo backend "$BACKEND_PIN"
check_repo infra "$INFRA_PIN"

# Migration pin: read from the pinned commits' trees, not the working trees.
expected="$(git -C "$WORKSPACE/infra" show "${INFRA_PIN}:testnet/docker-compose.testnet.yml" 2>/dev/null \
  | sed -n 's/^[[:space:]]*WRFCOIN_EXPECTED_DB_MIGRATION:[[:space:]]*"\{0,1\}\([A-Za-z0-9_]*\)"\{0,1\}[[:space:]]*$/\1/p' | sort -u || true)"
newest="$(git -C "$WORKSPACE/backend" ls-tree --name-only "${BACKEND_PIN}" drizzle/migrations/ 2>/dev/null \
  | sed -n 's#^drizzle/migrations/\(.*\)\.sql$#\1#p' | LC_ALL=C sort | tail -n 1 || true)"
if [[ -z "$expected" ]]; then
  bad "WRFCOIN_EXPECTED_DB_MIGRATION not found (exactly one value required) in compose at infra pin"
elif [[ "$(wc -l <<<"$expected")" -ne 1 ]]; then
  bad "WRFCOIN_EXPECTED_DB_MIGRATION has several distinct values at infra pin: $(tr '\n' ' ' <<<"$expected")"
elif [[ -z "$newest" ]]; then
  bad "no drizzle/migrations/*.sql at backend pin"
elif [[ "$expected" == "$newest" ]]; then
  good "WRFCOIN_EXPECTED_DB_MIGRATION == newest migration ($newest)"
else
  bad "WRFCOIN_EXPECTED_DB_MIGRATION $expected != newest migration at backend pin $newest"
fi

if [[ "$failures" -ne 0 ]]; then
  echo "STAGE_RELEASE_CHECK=FAIL ($failures problem(s))" >&2; exit 1
fi
echo "STAGE_RELEASE_CHECK=OK"
