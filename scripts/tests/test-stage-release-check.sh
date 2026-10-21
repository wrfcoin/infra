#!/usr/bin/env bash
# shellcheck disable=SC2015
# Fixture-repo tests for testnet/scripts/stage-release-check.sh (infra#1135).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/testnet/scripts/stage-release-check.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e
pass=0; fail=0
t_ok() { pass=$((pass+1)); echo "PASS $1"; }
t_no() { fail=$((fail+1)); echo "FAIL $1" >&2; }

# mk_ws DIR MIGRATION_IN_COMPOSE [newest migration at backend]
mk_ws() {
  local ws="$1" pinmig="$2" newest="${3:-0026_b}"
  mkdir -p "$ws/backend/drizzle/migrations" "$ws/infra/testnet"
  git -C "$ws/backend" init -q -b main
  touch "$ws/backend/drizzle/migrations/0001_a.sql" "$ws/backend/drizzle/migrations/${newest}.sql"
  git -C "$ws/backend" add -A; git -C "$ws/backend" commit -qm b
  git -C "$ws/infra" init -q -b main
  printf 'services:\n  db-migrate:\n    environment:\n      WRFCOIN_EXPECTED_DB_MIGRATION: "%s"\n' "$pinmig" > "$ws/infra/testnet/docker-compose.testnet.yml"
  git -C "$ws/infra" add -A; git -C "$ws/infra" commit -qm i
  for r in backend infra; do git -C "$ws/$r" update-ref refs/remotes/origin/main HEAD; done
  BP="$(git -C "$ws/backend" rev-parse HEAD)"; IP="$(git -C "$ws/infra" rev-parse HEAD)"
}
run() { bash "$CHECK" --backend-pin "$1" --infra-pin "$2" --workspace "$3" >"$T/out" 2>&1; echo $?; }

mk_ws "$T/w1" 0026_b
[[ "$(run "$BP" "$IP" "$T/w1")" == 0 ]] && t_ok "all pins equal, migration matches -> 0" || t_no "happy path"

# wrong pin
[[ "$(run "$(printf '0%.0s' {1..40})" "$IP" "$T/w1")" == 1 ]] && grep -q "^FAIL backend HEAD" "$T/out" && t_ok "backend pin mismatch fails" || t_no "backend pin mismatch"

# origin/main behind HEAD (HEAD equals pin but origin/main does not)
mk_ws "$T/w2" 0026_b
echo x > "$T/w2/backend/x"; git -C "$T/w2/backend" add -A; git -C "$T/w2/backend" commit -qm c
NB="$(git -C "$T/w2/backend" rev-parse HEAD)"
[[ "$(run "$NB" "$IP" "$T/w2")" == 1 ]] && grep -q "^FAIL backend origin/main" "$T/out" && ! grep -q "^FAIL backend HEAD" "$T/out" && t_ok "origin/main != pin fails (HEAD ok)" || t_no "origin/main behind"

# origin/main ref missing
mk_ws "$T/w3" 0026_b
git -C "$T/w3/infra" update-ref -d refs/remotes/origin/main
[[ "$(run "$BP" "$IP" "$T/w3")" == 1 ]] && grep -q "infra origin/main <none>" "$T/out" && t_ok "missing origin/main fails" || t_no "missing origin/main"

# migration pin stale
mk_ws "$T/w4" 0025_old
[[ "$(run "$BP" "$IP" "$T/w4")" == 1 ]] && grep -q "0025_old != newest migration at backend pin 0026_b" "$T/out" && t_ok "stale expected migration fails" || t_no "stale migration"

# working tree dirty compose does not fool it (reads the pinned tree)
mk_ws "$T/w5" 0025_old
sed -i 's/0025_old/0026_b/' "$T/w5/infra/testnet/docker-compose.testnet.yml"
[[ "$(run "$BP" "$IP" "$T/w5")" == 1 ]] && t_ok "reads pinned tree, not working tree" || t_no "working-tree spoof"

# bad args
[[ "$(bash "$CHECK" --backend-pin abc --infra-pin "$IP" --workspace "$T/w1" >/dev/null 2>&1; echo $?)" == 2 ]] && t_ok "short pin rejected" || t_no "short pin"
[[ "$(bash "$CHECK" --backend-pin "$BP" --infra-pin "$IP" >/dev/null 2>&1; echo $?)" == 2 ]] && t_ok "missing workspace rejected" || t_no "missing workspace"

# read-only: no new files/refs in the workspace
mk_ws "$T/w6" 0026_b
before="$(cd "$T/w6" && find . -path '*/.git' -prune -o -type f -print | sort | md5sum; git -C backend for-each-ref | md5sum)"
run "$BP" "$IP" "$T/w6" >/dev/null
after="$(cd "$T/w6" && find . -path '*/.git' -prune -o -type f -print | sort | md5sum; git -C backend for-each-ref | md5sum)"
[[ "$before" == "$after" ]] && t_ok "workspace untouched" || t_no "workspace modified"

echo "stage-release-check tests: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
