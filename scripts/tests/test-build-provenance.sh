#!/usr/bin/env bash
# Release build provenance (infra#991, infra#1077): the export helper stamps
# exact checkout heads and exports the root it labelled as the build root
# (check-build-root.sh refuses a build context elsewhere), the release
# Dockerfiles label them, and the compose files that build the gated images
# pass them through. The gate that consumes the labels is covered by
# test-render-release-manifest.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPORT="${EXPORT_UNDER_TEST:-${ROOT}/testnet/scripts/export-build-provenance.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

GUARD="${GUARD_UNDER_TEST:-${ROOT}/testnet/scripts/check-build-root.sh}"
TMP="$(realpath "$TMP")"
for repo in core4 backend frontend infra; do
  mkdir -p "$TMP/$repo"
  git -C "$TMP/$repo" init -q
  printf '%s\n' "$repo" > "$TMP/$repo/source.txt"
  git -C "$TMP/$repo" add source.txt
  if [[ $repo == infra ]]; then
    mkdir -p "$TMP/infra/testnet"
    cp "$ROOT/testnet/workspace.dockerignore" "$TMP/infra/testnet/workspace.dockerignore"
    git -C "$TMP/infra" add testnet/workspace.dockerignore
  fi
  git -C "$TMP/$repo" -c user.name=fixture -c user.email=fixture@invalid commit -q -m fixture
done

echo exact_checkout_heads_exported
WRFCOIN_ROOT="$TMP" bash -c '
  source "$1" 2>/dev/null
  test "$WRFCOIN_CORE4_BUILD_REVISION" = "$(git -C "$WRFCOIN_ROOT/core4" rev-parse HEAD)"
  test "$WRFCOIN_BACKEND_BUILD_REVISION" = "$(git -C "$WRFCOIN_ROOT/backend" rev-parse HEAD)"
  test "$WRFCOIN_FRONTEND_BUILD_REVISION" = "$(git -C "$WRFCOIN_ROOT/frontend" rev-parse HEAD)"
  test "$WRFCOIN_INFRA_BUILD_REVISION" = "$(git -C "$WRFCOIN_ROOT/infra" rev-parse HEAD)"
  [[ "$WRFCOIN_BUILD_CREATED" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]
' _ "$EXPORT" || fail "exact checkout heads were not exported"

echo sourcing_does_not_change_caller_shell_options
# An owner sources this into an interactive shell; a leaked `set -e` would close
# that shell on the next failing command.
opts="$(WRFCOIN_ROOT="$TMP" bash -c 'set +euo pipefail; source "$1" 2>/dev/null; printf "%s|%s\n" "$-" "$(set -o | awk "/^pipefail/{print \$2}")"' _ "$EXPORT")"
flags="${opts%%|*}"
[[ "$flags" != *e* && "$flags" != *u* && "${opts##*|}" == off ]] \
  || fail "sourcing changed caller shell options: $opts"

echo missing_checkout_exports_nothing
mv "$TMP/backend" "$TMP/backend-away"
set +e
WRFCOIN_ROOT="$TMP" bash -c '
  source "$1" 2>"$2"
  rc=$?
  [[ -z "${WRFCOIN_CORE4_BUILD_REVISION:-}${WRFCOIN_BUILD_CREATED:-}" ]] || exit 99
  exit "$rc"
' _ "$EXPORT" "$TMP/missing.err"
rc=$?
set -e
mv "$TMP/backend-away" "$TMP/backend"
[[ $rc -eq 1 ]] || fail "missing checkout returned $rc, expected 1 with nothing exported"
grep -Fq 'BUILD_PROVENANCE=FAIL' "$TMP/missing.err" || fail "missing checkout not reported"

echo dirty_tracked_checkout_refused
# The image would be labelled with HEAD while baking uncommitted changes.
printf '%s\n' local-edit >> "$TMP/backend/source.txt"
set +e
WRFCOIN_ROOT="$TMP" bash -c '
  source "$1" 2>"$2"
  rc=$?
  [[ -z "${WRFCOIN_BACKEND_BUILD_REVISION:-}${WRFCOIN_CORE4_BUILD_REVISION:-}${WRFCOIN_BUILD_CREATED:-}" ]] || exit 99
  exit "$rc"
' _ "$EXPORT" "$TMP/dirty.err"
rc=$?
set -e
git -C "$TMP/backend" checkout -q -- source.txt
[[ $rc -eq 1 ]] || fail "dirty tracked checkout returned $rc, expected 1 with nothing exported"
grep -Fq 'backend has uncommitted tracked changes' "$TMP/dirty.err" || fail "dirty checkout not named"

echo untracked_files_do_not_block
# Gitignored/untracked files (.env, build output) are not part of the commit.
printf 'SECRET=fixture\n' > "$TMP/backend/.env"
WRFCOIN_ROOT="$TMP" bash -c 'source "$1" 2>/dev/null && [[ -n "$WRFCOIN_BACKEND_BUILD_REVISION" ]]' _ "$EXPORT" \
  || fail "an untracked file blocked provenance export"
rm "$TMP/backend/.env"

echo executing_instead_of_sourcing_refused
set +e
WRFCOIN_ROOT="$TMP" bash "$EXPORT" 2>"$TMP/exec.err"
rc=$?
set -e
[[ $rc -eq 2 ]] || fail "executing the helper returned $rc, expected 2"

# ---- infra#1077: the labelled root must be the build context -------------
# The r11 runbook form `WRFCOIN_ROOT=$G source helper` set WRFCOIN_ROOT only
# while `source` ran. compose then resolved `context: ${WRFCOIN_ROOT:-default}`
# to the LIVE checkouts while the images carried $G's revisions.
LIVE="$TMP-live"   # stands in for the compose default (the live checkouts)
mkdir -p "$LIVE"
trap 'rm -rf "$TMP" "$LIVE"' EXIT
# The fixture uses the override's own context expression, with its default
# pointed at $LIVE, so it cannot drift from what the release build resolves.
context_expr="$(python3 - "$ROOT" <<'PY'
import re, sys
text = open(f"{sys.argv[1]}/testnet/docker-compose.override.yml", encoding="utf-8").read()
found = set()
for service in ("wrfcoin-node", "wrfcoin-backend", "db-migrate", "wrfcoin-frontend"):
    m = re.search(rf"^  {re.escape(service)}:\n(?:    .*\n|\s*\n)*?      context: *(\S+)\n", text, re.M)
    assert m, f"{service}: no build context in the override"
    found.add(m.group(1))
assert found == {"${WRFCOIN_ROOT:-${WRFCOIN_DEPLOY_ROOT:-/path/to/wrfcoin-deploy}}"}, found
print(found.pop())
PY
)" || fail "gated build contexts in the override are not \${WRFCOIN_ROOT:-${WRFCOIN_DEPLOY_ROOT:-/path/to/wrfcoin-deploy}}"
cat > "$TMP-compose.yml" <<YAML
services:
  wrfcoin-backend:
    image: fixture/backend
    build:
      context: ${context_expr/\/home\/tony\/wrfcoin-deploy/$LIVE}
  wrfcoin-faucet:
    image: fixture/faucet
    build:
      context: ${context_expr/\/home\/tony\/wrfcoin-deploy/$LIVE}/infra
YAML
trap 'rm -rf "$TMP" "$LIVE" "$TMP-compose.yml"' EXIT
HAVE_COMPOSE=0
docker compose version >/dev/null 2>&1 && HAVE_COMPOSE=1

echo prefix_form_leaves_root_exported
# RED against the pre-#1077 helper: it only READ WRFCOIN_ROOT.
env -u WRFCOIN_ROOT -u WRFCOIN_BUILD_ROOT bash -c '
  WRFCOIN_ROOT="$2" source "$1" 2>/dev/null
  [[ "$(printenv WRFCOIN_ROOT)" == "$2" && "$(printenv WRFCOIN_BUILD_ROOT)" == "$2" ]]
' _ "$EXPORT" "$TMP" || fail "prefix form left WRFCOIN_ROOT/WRFCOIN_BUILD_ROOT unexported: compose would build the default context"

echo explicit_export_form_still_works
env -u WRFCOIN_ROOT -u WRFCOIN_BUILD_ROOT bash -c '
  export WRFCOIN_ROOT="$2"; source "$1" 2>/dev/null
  [[ "$(printenv WRFCOIN_ROOT)" == "$2" && "$(printenv WRFCOIN_BUILD_ROOT)" == "$2" ]]
' _ "$EXPORT" "$TMP" || fail "export form did not export the build root"

if [[ $HAVE_COMPOSE == 1 ]]; then
  echo prefix_form_compose_builds_the_labelled_root
  got="$(env -u WRFCOIN_ROOT -u WRFCOIN_BUILD_ROOT FIXTURE_ROOT="$TMP" bash -c '
    WRFCOIN_ROOT="$FIXTURE_ROOT" source "$1" 2>/dev/null
    docker compose -p fixture -f "$2" config --format json \
      | python3 -c "import json,sys; print(json.load(sys.stdin)[\"services\"][\"wrfcoin-backend\"][\"build\"][\"context\"])"
  ' _ "$EXPORT" "$TMP-compose.yml")"
  [[ "$got" == "$TMP" ]] || fail "prefix form: compose resolved the build context to '$got', not the labelled root $TMP"
else
  echo "prefix_form_compose_builds_the_labelled_root: docker compose unavailable, render cases use --render fixtures"
fi

echo guard_accepts_labelled_root
guard_ok() { # extra env... ; runs the guard after sourcing, prefix form
  env -u WRFCOIN_ROOT -u WRFCOIN_BUILD_ROOT FIXTURE_ROOT="$TMP" HAVE_COMPOSE="$HAVE_COMPOSE" bash -c '
    WRFCOIN_ROOT="$FIXTURE_ROOT" source "$1" 2>/dev/null || exit 90
    if [[ $HAVE_COMPOSE == 1 ]]; then
      bash "$2" --service wrfcoin-backend --service wrfcoin-faucet -- -p fixture -f "$3"
    else
      printf "{\"services\":{\"wrfcoin-backend\":{\"build\":{\"context\":\"%s\"}},\"wrfcoin-faucet\":{\"build\":{\"context\":\"%s/infra\"}}}}" \
        "$WRFCOIN_ROOT" "$WRFCOIN_ROOT" > "$FIXTURE_ROOT-render.json"
      bash "$2" --service wrfcoin-backend --service wrfcoin-faucet --render "$FIXTURE_ROOT-render.json"
    fi
  ' _ "$EXPORT" "$GUARD" "$TMP-compose.yml"
}
guard_ok 2>"$TMP-guard.err" || { cat "$TMP-guard.err" >&2; fail "guard refused a correctly exported build root"; }
grep -Fq "BUILD_ROOT=OK root=$TMP services=wrfcoin-backend,wrfcoin-faucet" "$TMP-guard.err" \
  || { cat "$TMP-guard.err" >&2; fail "guard did not report OK"; }
rm -f "$TMP-guard.err" "$TMP-render.json"

guard_refuses() { # NAME WANT-TEXT SHELL-SETUP GUARD-ARGS...
  local name="$1" want="$2" setup="$3" rc
  shift 3
  set +e
  env -u WRFCOIN_ROOT -u WRFCOIN_BUILD_ROOT FIXTURE_ROOT="$TMP" bash -c "$setup"'
    shift 0; bash "$GUARD_PATH" "$@"
  ' _ "$@" >"$TMP-$name.err" 2>&1
  rc=$?
  set -e
  if [[ $rc -ne 1 ]] || ! grep -Fq 'BUILD_ROOT=FAIL' "$TMP-$name.err" || ! grep -Fq -- "$want" "$TMP-$name.err"; then
    sed 's/^/    /' "$TMP-$name.err" >&2
    fail "$name: guard returned $rc, expected 1 with: $want"
  fi
  rm -f "$TMP-$name.err"
}
export GUARD_PATH="$GUARD" EXPORT_PATH="$EXPORT"
printf '{"services":{"wrfcoin-backend":{"build":{"context":"%s"}}}}' "$LIVE" > "$TMP-live-render.json"
printf '{"services":{"wrfcoin-backend":{"build":{"context":"%s"}}}}' "$TMP" > "$TMP-good-render.json"
trap 'rm -rf "$TMP" "$LIVE" "$TMP-compose.yml" "$TMP-live-render.json" "$TMP-good-render.json"' EXIT

echo guard_refuses_without_provenance
guard_refuses no_provenance 'source export-build-provenance.sh' 'export WRFCOIN_ROOT="$FIXTURE_ROOT";' \
  --service wrfcoin-backend --render "$TMP-good-render.json"

echo guard_refuses_unexported_root
# The pre-#1077 state after the prefix form: stamps exported, root not.
guard_refuses unexported 'WRFCOIN_ROOT is not exported' \
  'WRFCOIN_ROOT="$FIXTURE_ROOT" source "$EXPORT_PATH" 2>/dev/null; export -n WRFCOIN_ROOT;' \
  --service wrfcoin-backend --render "$TMP-good-render.json"

echo guard_refuses_root_other_than_labelled
guard_refuses other_root 'is not the labelled build root' \
  'export WRFCOIN_ROOT="$FIXTURE_ROOT"; source "$EXPORT_PATH" 2>/dev/null; export WRFCOIN_ROOT=/;' \
  --service wrfcoin-backend --render "$TMP-good-render.json"

echo guard_refuses_context_outside_root
guard_refuses outside 'outside' \
  'export WRFCOIN_ROOT="$FIXTURE_ROOT"; source "$EXPORT_PATH" 2>/dev/null;' \
  --service wrfcoin-backend --render "$TMP-live-render.json"

echo guard_refuses_unrendered_service
guard_refuses unrendered 'not rendered with a build context' \
  'export WRFCOIN_ROOT="$FIXTURE_ROOT"; source "$EXPORT_PATH" 2>/dev/null;' \
  --service wrfcoin-frontend --render "$TMP-good-render.json"

echo guard_refuses_without_service
guard_refuses no_service 'name at least one --service' \
  'export WRFCOIN_ROOT="$FIXTURE_ROOT"; source "$EXPORT_PATH" 2>/dev/null;' \
  --render "$TMP-good-render.json"

if [[ $HAVE_COMPOSE == 1 ]]; then
  echo guard_refuses_live_default_context_via_compose
  # A root exported for the helper but a compose file whose context ignores it.
  sed "s|context: .*|context: $LIVE|" "$TMP-compose.yml" > "$TMP-pinned-compose.yml"
  guard_refuses compose_outside 'outside' \
    'export WRFCOIN_ROOT="$FIXTURE_ROOT"; source "$EXPORT_PATH" 2>/dev/null;' \
    --service wrfcoin-backend -- -p fixture -f "$TMP-pinned-compose.yml"
  rm -f "$TMP-pinned-compose.yml"
fi

if [[ $HAVE_COMPOSE == 1 ]]; then
  echo guard_failed_render_does_not_leak_interpolated_values
  # Compose error messages interpolate values (e.g. `invalid containerPort:
  # <value>`), so the guard must never echo compose's stderr. A synthetic secret
  # in a port spec makes compose fail with that value in its message.
  secret="fixture-secret-$RANDOM$RANDOM-do-not-print"
  cat > "$TMP-leak-compose.yml" <<'YAML'
services:
  wrfcoin-backend:
    image: fixture/backend
    build:
      context: ${WRFCOIN_ROOT}
    ports: ["${FIXTURE_SECRET}"]
YAML
  # Precondition, so the case cannot pass vacuously: compose itself does print it.
  FIXTURE_SECRET="$secret" bash "${ROOT}/testnet/tests/render-testnet-compose.sh" -p fixture -f "$TMP-leak-compose.yml" config --format json \
    >/dev/null 2>"$TMP-leak-raw.err" && fail "leak fixture: compose unexpectedly rendered"
  grep -Fq "$secret" "$TMP-leak-raw.err" || fail "leak fixture: compose stderr no longer contains the value; the case would be vacuous"
  mkdir -p "$TMP-leak-tmpdir"
  set +e
  env -u WRFCOIN_ROOT -u WRFCOIN_BUILD_ROOT FIXTURE_ROOT="$TMP" FIXTURE_SECRET="$secret" TMPDIR="$TMP-leak-tmpdir" bash -c '
    export WRFCOIN_ROOT="$FIXTURE_ROOT"; source "$1" 2>/dev/null || exit 90
    bash "$2" --service wrfcoin-backend -- -p fixture -f "$3"
  ' _ "$EXPORT" "$GUARD" "$TMP-leak-compose.yml" >"$TMP-leak.out" 2>"$TMP-leak.err"
  rc=$?
  set -e
  [[ $rc -eq 1 ]] || { cat "$TMP-leak.err" >&2; fail "failed render returned $rc, expected 1"; }
  grep -Fq 'BUILD_ROOT=FAIL docker compose config failed' "$TMP-leak.err" \
    || { cat "$TMP-leak.err" >&2; fail "failed render not reported"; }
  if grep -Fq "$secret" "$TMP-leak.out" "$TMP-leak.err"; then
    fail "guard printed an interpolated value from compose's error output"
  fi
  [[ -z "$(ls -A "$TMP-leak-tmpdir")" ]] || fail "guard left its render directory behind: $(ls -A "$TMP-leak-tmpdir")"
  rm -rf "$TMP-leak-compose.yml" "$TMP-leak-raw.err" "$TMP-leak.out" "$TMP-leak.err" "$TMP-leak-tmpdir"
fi

if [[ $HAVE_COMPOSE == 1 ]]; then
  # codex round 51: the guard must never print a rendered or resolved build
  # context, which can carry an interpolated secret. Two real renders are
  # checked: one context the guard ACCEPTS (a secret-named subdirectory inside
  # the root) and one it REFUSES (a credentialed git URL).
  ctx_secret="ctx-secret-$RANDOM$RANDOM-do-not-print"
  mkdir -p "$TMP/$ctx_secret"
  context_leak_case() { # NAME WANT-RC WANT-TEXT CONTEXT-EXPR
    local name="$1" want_rc="$2" want="$3" expr="$4" rc
    printf 'services:\n  wrfcoin-backend:\n    image: fixture/backend\n    build:\n      context: %s\n' "$expr" \
      > "$TMP-$name-compose.yml"
    # Precondition: compose's render really carries the marker (non-vacuous).
    env FIXTURE_SECRET="$ctx_secret" WRFCOIN_ROOT="$TMP" bash "${ROOT}/testnet/tests/render-testnet-compose.sh" -p fixture -f "$TMP-$name-compose.yml" \
      config --format json 2>/dev/null | grep -Fq "$ctx_secret" \
      || fail "$name: the render does not contain the marker; the case would be vacuous"
    mkdir -p "$TMP-$name-tmpdir"
    set +e
    env -u WRFCOIN_ROOT -u WRFCOIN_BUILD_ROOT FIXTURE_ROOT="$TMP" FIXTURE_SECRET="$ctx_secret" \
      TMPDIR="$TMP-$name-tmpdir" bash -c '
        export WRFCOIN_ROOT="$FIXTURE_ROOT"; source "$1" 2>/dev/null || exit 90
        bash "$2" --service wrfcoin-backend -- -p fixture -f "$3"
      ' _ "$EXPORT" "$GUARD" "$TMP-$name-compose.yml" >"$TMP-$name.out" 2>"$TMP-$name.err"
    rc=$?
    set -e
    [[ $rc -eq $want_rc ]] || { sed "s/$ctx_secret/<marker>/g" "$TMP-$name.err" >&2; fail "$name: guard returned $rc, expected $want_rc"; }
    grep -Fq -- "$want" "$TMP-$name.err" || { sed "s/$ctx_secret/<marker>/g" "$TMP-$name.err" >&2; fail "$name: missing '$want'"; }
    if grep -Fq "$ctx_secret" "$TMP-$name.out" "$TMP-$name.err"; then
      fail "$name: guard printed the rendered build context (it carries an interpolated value)"
    fi
    [[ -z "$(ls -A "$TMP-$name-tmpdir")" ]] || fail "$name: guard left its render directory behind"
    rm -rf "$TMP-$name-compose.yml" "$TMP-$name.out" "$TMP-$name.err" "$TMP-$name-tmpdir"
  }
  echo guard_accepted_context_is_not_printed
  context_leak_case ctx_accepted 0 'BUILD_ROOT=OK' '${WRFCOIN_ROOT}/${FIXTURE_SECRET}'
  echo guard_refused_context_is_not_printed
  context_leak_case ctx_refused 1 'BUILD_ROOT=FAIL' 'https://user:${FIXTURE_SECRET}@example.invalid/repo.git'
  rmdir "$TMP/$ctx_secret"
fi

echo dockerignore_installed_when_missing
rm -f "$TMP/.dockerignore"
env -u WRFCOIN_ROOT bash -c 'export WRFCOIN_ROOT="$2"; source "$1" 2>/dev/null' _ "$EXPORT" "$TMP" \
  || fail "helper failed on a root without .dockerignore"
cmp -s "$TMP/.dockerignore" "$ROOT/testnet/workspace.dockerignore" \
  || fail "helper did not install the canonical workspace .dockerignore"

echo differing_dockerignore_refused
printf '*\n' > "$TMP/.dockerignore"
set +e
env -u WRFCOIN_ROOT -u WRFCOIN_BUILD_ROOT bash -c '
  export WRFCOIN_ROOT="$2"; source "$1" 2>"$3"
  rc=$?
  [[ -z "${WRFCOIN_BACKEND_BUILD_REVISION:-}${WRFCOIN_BUILD_ROOT:-}" ]] || exit 99
  exit "$rc"
' _ "$EXPORT" "$TMP" "$TMP-di.err"
rc=$?
set -e
[[ $rc -eq 1 ]] && grep -Fq 'differs from infra/testnet/workspace.dockerignore' "$TMP-di.err" \
  || { cat "$TMP-di.err" >&2; fail "a differing .dockerignore returned $rc, expected 1 with nothing exported"; }
rm -f "$TMP-di.err"
guard_refuses dockerignore 'dockerignore is missing or differs' \
  'export WRFCOIN_ROOT="$FIXTURE_ROOT" WRFCOIN_BUILD_ROOT="$FIXTURE_ROOT";' \
  --service wrfcoin-backend --render "$TMP-good-render.json"
cp "$ROOT/testnet/workspace.dockerignore" "$TMP/.dockerignore"

echo failed_run_clears_stale_stamps
# A second, failing run in the same shell must not leave the first run's
# stamps and build root behind for the build to use.
set +e
env -u WRFCOIN_ROOT -u WRFCOIN_BUILD_ROOT bash -c '
  export WRFCOIN_ROOT="$2"; source "$1" 2>/dev/null || exit 98
  mv "$2/backend" "$2/backend-away"
  source "$1" 2>/dev/null; rc=$?
  mv "$2/backend-away" "$2/backend"
  [[ $rc -eq 1 ]] || exit 97
  [[ -z "${WRFCOIN_CORE4_BUILD_REVISION:-}${WRFCOIN_BUILD_CREATED:-}${WRFCOIN_BUILD_ROOT:-}" ]] || exit 99
' _ "$EXPORT" "$TMP"
rc=$?
set -e
[[ $rc -eq 0 ]] || fail "failed_run_clears_stale_stamps: got $rc (98 first run failed, 97 second did not fail, 99 stale stamps left)"

echo release_dockerfiles_label_stamps_without_build_guard
for dockerfile in \
  infra/docker/Dockerfile.core \
  infra/docker/Dockerfile.backend \
  infra/docker/Dockerfile.backend-api \
  infra/docker/Dockerfile.storage \
  testnet/Dockerfile.frontend \
  testnet/edge/Dockerfile.caddy \
  testnet/services/faucet/Dockerfile; do
  grep -Fq 'org.opencontainers.image.revision="$WRFCOIN_BUILD_REVISION"' "$ROOT/$dockerfile" \
    || fail "$dockerfile does not label the revision"
  grep -Fq 'org.opencontainers.image.created="$WRFCOIN_BUILD_CREATED"' "$ROOT/$dockerfile" \
    || fail "$dockerfile does not label the creation time"
  # A build-time guard breaks every builder that passes no args: the join script
  # (`up --build wrfcoin-node`), the oracle-attester compose, the funnel edge and
  # the CI Caddy builds. Fail-closed belongs in the gate: empty labels classify
  # UNAVAILABLE there.
  if grep -Eq '^RUN test -n "\$WRFCOIN_BUILD_(REVISION|CREATED)"' "$ROOT/$dockerfile"; then
    fail "$dockerfile refuses to build without provenance args"
  fi
done
grep -Fq 'ENV WRFCOIN_BUILD_REVISION=' "$ROOT/infra/docker/Dockerfile.backend-api" \
  || fail "backend-api image does not expose WRFCOIN_BUILD_REVISION to /api/build"

echo gated_image_builds_pass_provenance_args
python3 - "$ROOT" <<'PY' || fail "a gated image build does not pass provenance args"
import re, sys
root = sys.argv[1]
def block(path, service):
    text = open(f"{root}/{path}", encoding="utf-8").read()
    match = re.search(rf"^  {re.escape(service)}:\n((?:    .*\n|\s*\n)+)", text, re.M)
    assert match, f"{path}: service {service} not found"
    return text, match.group(1)
cases = [
    ("testnet/docker-compose.override.yml", "wrfcoin-node", "*core-build-args", "WRFCOIN_CORE4_BUILD_REVISION"),
    ("testnet/docker-compose.override.yml", "wrfcoin-backend", "*backend-build-args", "WRFCOIN_BACKEND_BUILD_REVISION"),
    ("testnet/docker-compose.override.yml", "wrfcoin-frontend", "*frontend-build-args", "WRFCOIN_FRONTEND_BUILD_REVISION"),
    ("testnet/docker-compose.edge.yml", "edge", "*edge-build-args", "WRFCOIN_INFRA_BUILD_REVISION"),
    ("testnet/docker-compose.funnel-edge.yml", "funnel-edge", "WRFCOIN_INFRA_BUILD_REVISION", "WRFCOIN_INFRA_BUILD_REVISION"),
    # infra#1121: the faucet image is gated too; it is built from infra.
    ("testnet/docker-compose.testnet.yml", "wrfcoin-faucet", "*infra-build-args", "WRFCOIN_INFRA_BUILD_REVISION"),
    ("testnet/docker-compose.override.yml", "wrfcoin-faucet", "*infra-build-args", "WRFCOIN_INFRA_BUILD_REVISION"),
]
for path, service, reference, variable in cases:
    text, body = block(path, service)
    assert reference in body, f"{path}: {service} build does not use {reference}"
    assert variable in text, f"{path}: {variable} is never referenced"
    print(f"  {path} {service}: {reference}")
PY

if [[ $HAVE_COMPOSE == 1 ]]; then
  echo deployed_faucet_render_passes_infra_revision
  # The CT101 file set, merged: the faucet build must receive the infra stamps.
  COMPOSE_PROFILES=faucet WRFCOIN_FUNNEL_ORIGIN=https://fixture.invalid \
    WRFCOIN_INFRA_BUILD_REVISION=1111111111111111111111111111111111111111 WRFCOIN_BUILD_CREATED=2026-09-28T00:00:00Z \
    bash "$ROOT/testnet/tests/render-testnet-compose.sh" --env-file "$ROOT/testnet/.env.testnet.example" \
    -f "$ROOT/testnet/docker-compose.testnet.yml" -f "$ROOT/testnet/docker-compose.override.yml" \
    -f "$ROOT/testnet/docker-compose.local-paths.yml" -f "$ROOT/testnet/docker-compose.funnel-edge.yml" \
    config --format json 2>/dev/null | python3 -c '
import json, sys
args = json.load(sys.stdin)["services"]["wrfcoin-faucet"]["build"].get("args") or {}
assert args.get("WRFCOIN_BUILD_REVISION") == "1" * 40, args
assert args.get("WRFCOIN_BUILD_CREATED") == "2026-09-28T00:00:00Z", args
' || fail "the deployed render does not pass the infra stamps to the faucet build"
fi

echo foreign_repo_images_not_labelled_as_infra
# oracle-reference is built from the separate oracle-reference repository; an
# infra SHA on it would be false provenance.
python3 - "$ROOT" <<'PY' || fail "a non-infra build context carries infra provenance labels"
import re, sys
text = open(f"{sys.argv[1]}/testnet/docker-compose.testnet.yml", encoding="utf-8").read()
checked = 0
for match in re.finditer(r"^  ([A-Za-z0-9_.-]+):\n((?:    .*\n|\s*\n)+)", text, re.M):
    service, body = match.group(1), match.group(2)
    context = re.search(r"^      context: *(\S+)", body, re.M)
    if context and "oracle-reference" in context.group(1):
        assert "infra-build-labels" not in body, f"{service} ({context.group(1)}) carries infra labels"
        print(f"  {service}: context {context.group(1)} has no infra labels")
        checked += 1
assert checked, "no oracle-reference build found: this check would be vacuous"
PY

echo storage_providers_stamped_only_when_checked_out
# infra#944: opt-in. Absent (every release so far): nothing exported for it, nothing refused.
WRFCOIN_ROOT="$TMP" bash -c '
  source "$1" 2>/dev/null || exit 1
  [[ -z "${WRFCOIN_STORAGE_PROVIDERS_BUILD_REVISION:-}" ]]
' _ "$EXPORT" || fail "storage-providers revision exported although it is not checked out"
mkdir -p "$TMP/storage-providers"
git -C "$TMP/storage-providers" init -q
printf '%s\n' storage-providers > "$TMP/storage-providers/source.txt"
git -C "$TMP/storage-providers" add source.txt
git -C "$TMP/storage-providers" -c user.name=fixture -c user.email=fixture@invalid commit -q -m fixture
WRFCOIN_ROOT="$TMP" bash -c '
  source "$1" 2>/dev/null || exit 1
  test "$WRFCOIN_STORAGE_PROVIDERS_BUILD_REVISION" = "$(git -C "$WRFCOIN_ROOT/storage-providers" rev-parse HEAD)"
' _ "$EXPORT" || fail "storage-providers head was not exported"
printf '%s\n' local-edit >> "$TMP/storage-providers/source.txt"
set +e
WRFCOIN_ROOT="$TMP" bash -c '
  source "$1" 2>"$2"
  rc=$?
  [[ -z "${WRFCOIN_STORAGE_PROVIDERS_BUILD_REVISION:-}${WRFCOIN_CORE4_BUILD_REVISION:-}${WRFCOIN_BUILD_CREATED:-}" ]] || exit 99
  exit "$rc"
' _ "$EXPORT" "$TMP/sp-dirty.err"
rc=$?
set -e
[[ $rc -eq 1 ]] && grep -Fq 'storage-providers has uncommitted tracked changes' "$TMP/sp-dirty.err" \
  || fail "a dirty storage-providers checkout returned $rc, expected 1 with nothing exported"
git -C "$TMP/storage-providers" checkout -q -- source.txt

echo workspace_dockerignore_allows_storage_providers_only
python3 - "$ROOT/testnet/workspace.dockerignore" <<'PY'
import sys
lines = [l.strip() for l in open(sys.argv[1]) if l.strip() and not l.startswith("#")]
assert "!/storage-providers" in lines and "!/storage-providers/**" in lines, "storage-providers not allowed"
tops = sorted({l[2:].split("/")[0] for l in lines if l.startswith("!/")} - {".env.example", ".env.testnet.example"})
assert tops == [".dockerignore", ".gitignore", "backend", "core4", "frontend", "infra", "package-lock.json", "package.json", "prometheus.yml", "storage-providers", "testnet"], tops
PY

echo BUILD_PROVENANCE_TESTS=PASS
