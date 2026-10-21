#!/usr/bin/env bash
# Release-candidate manifest gate (infra#968, infra#991).
#
# Repositories are synthetic fixture checkouts. The gated image tags come from a
# REAL `docker compose config` render of this repository's compose files, and
# `docker image inspect` / `docker container inspect` are served by a stub
# `docker` from scripts/tests/fixtures/release-manifest/:
#   inspect-fresh.json                  FRESH when __REVISION__ is the pinned SHA
#   inspect-stale.json                  STALE: created 2026-08-17
#   inspect-old-docker-fresh-label.json STALE: Docker Created 2026-08-01, label claims 09-24
#   inspect-wrong-revision.json         STALE: revision is not the pinned SHA
#   inspect-label-missing.json          UNAVAILABLE: no labels
#   inspect-label-empty.json            UNAVAILABLE: built without provenance args
#   inspect-labels-list.json            UNAVAILABLE: malformed (Labels is a list)
#   inspect-not-object.json             UNAVAILABLE: malformed (not an object)
#   inspect-truncated.json              UNAVAILABLE: malformed (not JSON)
#   inspect-no-id.json                  UNAVAILABLE: no image Id
#   inspect-identity-owner-aacut.json   CT101's aacut identity-owner image (infra#1047):
#                                       its real Id/labels, created 2026-09-13 (< min date)
#   inspect-faucet-july.json            the faucet CT101 ran until infra#1121: created
#                                       2026-07-02T23:38Z, no revision label
# `docker compose` is passed through to the real docker; nothing touches a daemon.
#
# RENDERER_UNDER_TEST may point at another copy of the renderer (mutation runs).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_RENDERER="${RENDERER_UNDER_TEST:-${ROOT}/testnet/scripts/render-release-manifest.sh}"
TMP="$(mktemp -d)"
WORKSPACE="$TMP/workspace"
PINS="$WORKSPACE/infra/testnet/release-pins.env"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$WORKSPACE" "$TMP/bin"
KUBO_DIGEST=sha256:$(printf 'ab%.0s' $(seq 32))
commit() { git -C "$1" -c user.name=fixture -c user.email=fixture@invalid commit -q -m "$2"; }

REAL_DOCKER="$(command -v docker || true)"
[[ -n "$REAL_DOCKER" ]] && "$REAL_DOCKER" compose version >/dev/null 2>&1 || {
  echo 'FAIL: docker compose is required to render the real compose files (no daemon is used)' >&2
  exit 1
}
export REAL_DOCKER
export FIXTURE_DIR="${ROOT}/scripts/tests/fixtures/release-manifest"
export FIXTURE_MAP="$TMP/fixture-map" CONTAINER_MAP="$TMP/container-map"
export FIXTURE_WORKSPACE="$WORKSPACE"
cat > "$TMP/bin/docker" <<'SH'
#!/bin/sh
# Stub docker. FIXTURE_MAP lines: "<image> <fixture> <revspec>", where revspec is
# a workspace repo name (its HEAD) or rev:<sha>. CONTAINER_MAP lines:
# "<container> <image-id> <running> <exit-code>". Unlisted names behave like
# missing ones.
case "$1 $2" in
  "compose "*) exec "$REAL_DOCKER" "$@" ;;
  "image inspect")
    line=$(awk -v name="$3" '$1 == name { print; exit }' "$FIXTURE_MAP")
    [ -n "$line" ] || { echo "Error: No such image: $3" >&2; exit 1; }
    fixture=$(echo "$line" | awk '{ print $2 }'); spec=$(echo "$line" | awk '{ print $3 }')
    case "$spec" in
      rev:*) revision="${spec#rev:}" ;;
      *) revision=$(git -C "$FIXTURE_WORKSPACE/$spec" rev-parse HEAD) || exit 1 ;;
    esac
    sed -e "s#__IMAGE__#$3#" -e "s#__REVISION__#$revision#" "$FIXTURE_DIR/$fixture.json" ;;
  "container inspect")
    line=$(awk -v name="$3" '$1 == name { print; exit }' "$CONTAINER_MAP")
    [ -n "$line" ] || { echo "Error: No such container: $3" >&2; exit 1; }
    printf '[{"Name":"/%s","Image":"%s","State":{"Running":%s,"ExitCode":%s}}]\n' \
      "$3" "$(echo "$line" | awk '{ print $2 }')" "$(echo "$line" | awk '{ print $3 }')" \
      "$(echo "$line" | awk '{ print $4 }')" ;;
  "container ls")
    # infra#1047: positive absence check. STUB_LS_FAIL=1 simulates a daemon error.
    [ "${STUB_LS_FAIL:-0}" = 1 ] && { echo "Error: daemon unavailable" >&2; exit 1; }
    awk '{ print $1 }' "$CONTAINER_MAP" ;;
  *) echo "stub docker: unsupported: $*" >&2; exit 64 ;;
esac
SH
chmod +x "$TMP/bin/docker"

# ------------------------------------------------------------------ fixtures
for repo in core4 backend frontend storage-providers; do
  mkdir "$WORKSPACE/$repo"
  git -C "$WORKSPACE/$repo" init -q
  printf '%s\n' "$repo" > "$WORKSPACE/$repo/source.txt"
  git -C "$WORKSPACE/$repo" add source.txt
  commit "$WORKSPACE/$repo" fixture
done
# core4 gets a second commit so an older, ancestor core4 build exists (infra#1047).
CORE4_OLD=$(git -C "$WORKSPACE/core4" rev-parse HEAD)
printf '%s\n' 'core4 v2' >> "$WORKSPACE/core4/source.txt"
git -C "$WORKSPACE/core4" add source.txt
commit "$WORKSPACE/core4" 'fixture core4 v2'
FRONTEND_PRE_363=$(git -C "$WORKSPACE/frontend" rev-parse HEAD)
printf '%s\n' '#363' >> "$WORKSPACE/frontend/source.txt"
git -C "$WORKSPACE/frontend" add source.txt
commit "$WORKSPACE/frontend" 'fixture frontend #363'
FRONTEND_363=$(git -C "$WORKSPACE/frontend" rev-parse HEAD)
export WRFCOIN_RC_REQUIRED_FRONTEND_COMMIT="$FRONTEND_363"
for repo in core4 backend frontend storage-providers; do
  git -C "$WORKSPACE/$repo" update-ref refs/remotes/origin/main HEAD
done

mkdir -p "$WORKSPACE/infra/testnet/scripts" "$WORKSPACE/infra/testnet/edge" "$WORKSPACE/infra/testnet/services/faucet"
cp "$SOURCE_RENDERER" "$WORKSPACE/infra/testnet/scripts/render-release-manifest.sh"
cp "${ROOT}/testnet/scripts/cors_origin_policy.py" "$WORKSPACE/infra/testnet/scripts/cors_origin_policy.py"
cat > "$PINS" <<PINS
WRFCOIN_RC_CORE4_COMMIT=$(git -C "$WORKSPACE/core4" rev-parse HEAD)
WRFCOIN_RC_BACKEND_COMMIT=$(git -C "$WORKSPACE/backend" rev-parse HEAD)
WRFCOIN_RC_FRONTEND_COMMIT=$(git -C "$WORKSPACE/frontend" rev-parse HEAD)
WRFCOIN_RC_MIN_PUBLIC_BUILD_DATE=2026-09-18
# Optional storage pins (opt-in --storage group): ignored unless a case passes --storage.
WRFCOIN_RC_STORAGE_PROVIDERS_COMMIT=$(git -C "$WORKSPACE/storage-providers" rev-parse HEAD)
WRFCOIN_RC_IPFS_KUBO_DIGEST=$KUBO_DIGEST
PINS
cat > "$WORKSPACE/infra/testnet/cut-pins.env" <<PINS
WRFCOIN_CUT_CORE4_COMMIT=$(git -C "$WORKSPACE/core4" rev-parse HEAD)
WRFCOIN_CUT_GENESIS_HASH=6ad436386cfc6c746146f6ef2f9d32ddb7a93f18efd3635606abd27c9ca17db8
PINS
# Infra history: EDGE_V1 (old edge build context) -> EDGE_V2 (Caddy bump in the
# edge context) -> FAUCET_V2 (faucet source change only) -> HEAD (change outside
# both contexts; edge identical to EDGE_V2, faucet identical to FAUCET_V2).
printf 'FROM caddy:2.11.3-alpine\n' > "$WORKSPACE/infra/testnet/edge/Dockerfile.caddy"
printf '// faucet v1 (July)\n' > "$WORKSPACE/infra/testnet/services/faucet/server.js"
git -C "$WORKSPACE/infra" init -q
git -C "$WORKSPACE/infra" add testnet
commit "$WORKSPACE/infra" 'fixture: edge v1'
EDGE_V1=$(git -C "$WORKSPACE/infra" rev-parse HEAD)
printf 'FROM caddy:2.11.4-alpine\n' > "$WORKSPACE/infra/testnet/edge/Dockerfile.caddy"
git -C "$WORKSPACE/infra" add testnet
commit "$WORKSPACE/infra" 'fixture: caddy bump in the edge build context'
EDGE_V2=$(git -C "$WORKSPACE/infra" rev-parse HEAD)
printf '// faucet v2\n' > "$WORKSPACE/infra/testnet/services/faucet/server.js"
git -C "$WORKSPACE/infra" add testnet
commit "$WORKSPACE/infra" 'fixture: faucet source change'
FAUCET_V2=$(git -C "$WORKSPACE/infra" rev-parse HEAD)
printf 'unrelated\n' > "$WORKSPACE/infra/README.fixture"
git -C "$WORKSPACE/infra" add README.fixture
commit "$WORKSPACE/infra" 'fixture: non-edge change'
RENDERER="$WORKSPACE/infra/testnet/scripts/render-release-manifest.sh"

# The deployed compose file set, rendered for real (config only).
export WRFCOIN_FUNNEL_ORIGIN=https://fixture.invalid
export WRFCOIN_P2P_EXTERNAL_ADDR=/ip4/198.51.100.7/tcp/9000
export WRFCOIN_SEED_P2P_EXTERNAL_ADDR=/ip4/203.0.113.9/tcp/9000
# The faucet runs under the "faucet" profile (infra#1057). A deployed render
# includes it through the host .env's COMPOSE_PROFILES; the gate requires it
# (infra#1121), so every render here has the profile unless a case removes it.
export COMPOSE_PROFILES=faucet
COMPOSE_ARGS=(
  --env-file "${ROOT}/testnet/.env.testnet.example"
  -f "${ROOT}/testnet/docker-compose.testnet.yml"
  -f "${ROOT}/testnet/docker-compose.override.yml"
  -f "${ROOT}/testnet/docker-compose.funnel-edge.yml"
)
COMPOSE_JSON="$TMP/compose.json"
# Through the canonical render helper (check-compose-render-inventory.py): it
# runs `docker compose` from PATH, which is still the REAL docker here. The
# PATH stub is installed on the next line, after this render.
bash "${ROOT}/testnet/tests/render-testnet-compose.sh" "${COMPOSE_ARGS[@]}" config --format json > "$COMPOSE_JSON"
# The same set with the opt-in storage and weather-archive profiles (infra#944): ipfs-kubo,
# storage-node and weather-ipfs-archive. Rendered here, before the stub docker is on PATH.
STORAGE_JSON="$TMP/compose-storage.json"
COMPOSE_PROFILES=faucet,ipfs-storage,weather-archive bash "${ROOT}/testnet/tests/render-testnet-compose.sh" \
  "${COMPOSE_ARGS[@]}" -f "${ROOT}/testnet/docker-compose.weather-archive.yml" config --format json > "$STORAGE_JSON"
export PATH="$TMP/bin:$PATH"

NODE_TAG=wrfcoin/native-chain:testnet-local
BACKEND_TAG=wrfcoin/backend-api:testnet-local
BACKEND_SERVICES_TAG=wrfcoin/backend:testnet-local
FRONTEND_TAG=wrfcoin/frontend:testnet-local
EDGE_TAG=wrfcoin/edge-caddy:testnet-local
FAUCET_TAG=wrfcoin/faucet:testnet-local
STORAGE_TAG=wrfcoin/storage-node:testnet-local
KUBO_TAG=ipfs/kubo:v0.24.0
KUBO_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["Id"])' "$FIXTURE_DIR/inspect-kubo.json")"
FRESH_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["Id"])' "$FIXTURE_DIR/inspect-fresh.json")"

# write_fixture_map [SERVICE FIXTURE [REVSPEC]]: every image FRESH except
# SERVICE, served from FIXTURE ("absent" leaves the tag out entirely).
write_fixture_map() {
  local override_service="${1:-}" override_fixture="${2:-}" override_spec="${3:-}"
  local service image spec fixture
  : > "$FIXTURE_MAP"
  while read -r service image spec; do
    fixture=inspect-fresh
    if [[ "$service" == "$override_service" ]]; then
      fixture="$override_fixture"
      [[ -n "$override_spec" ]] && spec="$override_spec"
    fi
    [[ "$fixture" == absent ]] && continue
    printf '%s %s %s\n' "$image" "$fixture" "$spec" >> "$FIXTURE_MAP"
  done <<MAP
core4 $NODE_TAG core4
backend $BACKEND_TAG backend
backend-services $BACKEND_SERVICES_TAG backend
frontend $FRONTEND_TAG frontend
edge $EDGE_TAG infra
faucet $FAUCET_TAG infra
storage $STORAGE_TAG storage-providers
MAP
  # Upstream, never built here: served from the digest-pinned fixture (unused without --storage).
  printf '%s %s %s\n' "$KUBO_TAG" inspect-kubo rev:none >> "$FIXTURE_MAP"
}
# write_container_map [CONTAINER IMAGE-ID RUNNING EXIT|absent ...]: every
# container of a rendered gated service runs its tag's image (one-shot services
# exited 0), except the named ones. The container set comes from the render.
python3 - "$COMPOSE_JSON" > "$TMP/gated-containers" <<'PY'
import json, os, sys
services = json.load(open(sys.argv[1], encoding="utf-8"))["services"]
oneshot = {dep for spec in services.values() for dep, cond in (spec.get("depends_on") or {}).items()
           if isinstance(cond, dict) and cond.get("condition") == "service_completed_successfully"}
gated = {"Dockerfile.core", "Dockerfile.backend-api", "Dockerfile.backend", "Dockerfile.frontend", "Dockerfile.caddy"}
for name, spec in sorted(services.items()):
    dockerfile = (spec.get("build") or {}).get("dockerfile", "")
    if os.path.basename(dockerfile) in gated or dockerfile.endswith("testnet/services/faucet/Dockerfile"):
        print(spec.get("container_name") or f"testnet-{name}-1", "false 0" if name in oneshot else "true 0")
PY
write_container_map() {
  local name running exit_code i
  : > "$CONTAINER_MAP"
  while read -r name running exit_code; do
    local line="$name $FRESH_ID $running $exit_code"
    for ((i = 1; i <= $#; i += 4)); do
      if [[ "${!i}" == "$name" ]]; then
        local j=$((i + 1)) k=$((i + 2)) l=$((i + 3))
        line="$name ${!j} ${!k} ${!l}"
        [[ "${!j}" == absent ]] && line=""
      fi
    done
    [[ -n "$line" ]] && printf '%s\n' "$line" >> "$CONTAINER_MAP"
  done < "$TMP/gated-containers"
  return 0
}
write_fixture_map
write_container_map

render() {
  bash "$RENDERER" --workspace "$WORKSPACE" --pins "$PINS" "$@"
}

# expect NAME RC CLASS SERVICE|- [render args...]: run the renderer, require exit
# RC and classification CLASS; for a named SERVICE also require the summary to
# name it and every other image to stay FRESH. Explicit checks throughout:
# case functions run in a keep-going runner where errexit is not in effect.
expect() {
  local name="$1" want_rc="$2" want_class="$3" service="$4" rc field=stale
  shift 4
  render "$@" --out "$TMP/$name.json" >"$TMP/$name.out" 2>&1
  rc=$?
  if [[ $rc -ne $want_rc ]]; then
    sed 's/^/    /' "$TMP/$name.out" >&2
    echo "    $name returned $rc, expected $want_rc" >&2
    return 1
  fi
  [[ "$want_class" == UNAVAILABLE ]] && field=unavailable
  if [[ "$service" != - && "$want_class" != FRESH ]] && ! grep -Eq "RELEASE_MANIFEST=${want_class} .* ${field}=${service}( |$)" "$TMP/$name.out"; then
    sed 's/^/    /' "$TMP/$name.out" >&2
    echo "    $name: summary does not name ${field}=${service}" >&2
    return 1
  fi
  python3 - "$TMP/$name.json" "$service" "$want_class" <<'CHECK' || return 1
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
service, want = sys.argv[2], sys.argv[3]
assert payload["classification"] == want, payload["classification"]
if service != "-":
    assert payload["images"][service]["freshness"] == want, payload["images"][service]
    others = [name for name in payload["images"] if name != service]
    assert all(payload["images"][name]["freshness"] == "FRESH" for name in others), payload["images"]
CHECK
}
expect_image() { # NAME SERVICE FIXTURE RC CLASS [REVSPEC]
  local rc=0
  write_fixture_map "$2" "$3" "${6:-}"
  expect "$1" "$4" "$5" "$2" --compose-config "$COMPOSE_JSON" || rc=1
  write_fixture_map
  return $rc
}
out_has() { grep -Fq -- "$2" "$TMP/$1.out" || { sed 's/^/    /' "$TMP/$1.out" >&2; echo "    $1: output lacks: $2" >&2; return 1; }; }
json_is() { # NAME PYTHON-EXPR
  python3 - "$TMP/$1.json" "$2" <<'CHECK' || { echo "    $1: JSON check failed: $2" >&2; return 1; }
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert eval(sys.argv[2], {"m": payload}), sys.argv[2]
CHECK
}

FAILED=()
run_case() {
  local name="$1"
  echo "$name"
  if ! ( "$@" ); then
    FAILED+=("$name")
    echo "  CASE FAILED: $name" >&2
  fi
}

# ------------------------------------------------------------------ cases
exact_clean_heads_pass() {
  expect exact_clean_heads_pass 0 FRESH - --compose-config "$COMPOSE_JSON" || return 1
  json_is exact_clean_heads_pass 'set(m["repos"]) == {"core4", "backend", "frontend", "infra"}' || return 1
  # The real compose set builds explorer/alert-receiver from infra/testnet/: not release builds.
  json_is exact_clean_heads_pass 'm["membership_problems"] == []' || return 1
  json_is exact_clean_heads_pass 'm["config_problems"] == []' || return 1
  json_is exact_clean_heads_pass 'all(m["repos"][n]["head"] == m["repos"][n]["pinned"] == m["repos"][n]["origin_main"] for n in ("core4", "backend", "frontend"))' || return 1
  json_is exact_clean_heads_pass 'm["repos"]["frontend"]["contains_frontend_363"] == m["repos"]["frontend"]["pinned"]' || return 1
  json_is exact_clean_heads_pass 'm["repos"]["infra"]["source"] == "renderer_checkout" and "pinned" not in m["repos"]["infra"]' || return 1
  json_is exact_clean_heads_pass 'all(t["evidence"] == "LOCAL_INSPECT" and t["freshness"] == "FRESH" for g in m["images"].values() for t in g["tags"].values())' || return 1
  json_is exact_clean_heads_pass 'set(m["images"]) == {"core4", "backend", "backend-services", "frontend", "edge", "faucet"}' || return 1
}

stale_wrong_revision_and_unlabelled_images() {
  local service rc=0
  for service in core4 backend; do
    expect_image "stale_${service}_red" "$service" inspect-stale 1 STALE || rc=1
    expect_image "wrong_revision_${service}_red" "$service" inspect-wrong-revision 1 STALE || rc=1
    expect_image "label_missing_${service}_unavailable" "$service" inspect-label-missing 2 UNAVAILABLE || rc=1
    expect_image "label_empty_${service}_unavailable" "$service" inspect-label-empty 2 UNAVAILABLE || rc=1
    expect_image "image_absent_${service}_unavailable" "$service" absent 2 UNAVAILABLE || rc=1
  done
  expect_image wrong_revision_frontend_red frontend inspect-wrong-revision 1 STALE || rc=1
  expect_image foreign_revision_edge_red edge inspect-wrong-revision 1 STALE || rc=1
  out_has wrong_revision_backend_red 'revision 2222222222222222222222222222222222222222 is not the pinned' || rc=1
  return $rc
}

# Fix 1: an ancestor revision is fresh only if the edge build context is unchanged.
edge_old_ancestor_with_changed_context_stale() {
  expect_image edge_ancestor_changed_context_red edge inspect-fresh 1 STALE "rev:$EDGE_V1" || return 1
  out_has edge_ancestor_changed_context_red "testnet/edge/ changed between revision $EDGE_V1" || return 1
}
edge_older_commit_with_identical_context_fresh() {
  expect_image edge_older_same_context_fresh edge inspect-fresh 0 FRESH "rev:$EDGE_V2"
}

# Fix 3: Docker's Created bounds the age; the build-env label cannot rejuvenate it.
old_docker_created_with_fresh_label_stale() {
  local rc=0
  expect_image old_docker_fresh_label_core4_red core4 inspect-old-docker-fresh-label 1 STALE || rc=1
  expect_image old_docker_fresh_label_backend_red backend inspect-old-docker-fresh-label 1 STALE || rc=1
  return $rc
}

# Fix 4: malformed inspect output is UNAVAILABLE (exit 2), never a traceback.
malformed_inspect_output_unavailable() {
  local fixture rc=0
  for fixture in inspect-not-object inspect-labels-list inspect-truncated; do
    expect_image "malformed_${fixture#inspect-}_unavailable" backend "$fixture" 2 UNAVAILABLE || rc=1
    ! grep -q Traceback "$TMP/malformed_${fixture#inspect-}_unavailable.out" || { echo "    traceback for $fixture" >&2; rc=1; }
  done
  return $rc
}
# Fix 4: no manifest from an earlier run survives a run that fails early.
earlier_manifest_never_survives() {
  printf '{"classification": "FRESH"}\n' > "$TMP/survivor.json"
  mv "$WORKSPACE/frontend" "$TMP/frontend-away"
  local rc
  render --compose-config "$COMPOSE_JSON" --out "$TMP/survivor.json" >"$TMP/survivor.out" 2>&1
  rc=$?
  mv "$TMP/frontend-away" "$WORKSPACE/frontend"
  [[ $rc -eq 2 ]] || { echo "    missing repo returned $rc, expected 2" >&2; return 1; }
  [[ ! -e "$TMP/survivor.json" ]] || { echo "    earlier FRESH manifest survived a VOID run" >&2; return 1; }
}

# Fix 5: the gated tags are the ones the deployed compose set renders.
compose_render_derives_gated_tags() {
  expect compose_files_fresh 0 FRESH - "${COMPOSE_ARGS[@]}" || return 1
  json_is compose_files_fresh "list(m['images']['core4']['tags']) == ['$NODE_TAG'] and m['images']['core4']['compose_services'] == ['softhsm-init', 'wrfcoin-node']" || return 1
  json_is compose_files_fresh "list(m['images']['backend']['tags']) == ['$BACKEND_TAG'] and m['images']['backend']['compose_services'] == ['wrfcoin-backend']" || return 1
  json_is compose_files_fresh "list(m['images']['edge']['tags']) == ['$EDGE_TAG'] and m['images']['edge']['compose_services'] == ['funnel-edge']" || return 1
}
host_override_tag_is_followed() {
  printf 'services:\n  wrfcoin-node:\n    image: wrfcoin/native-chain:testnet-aacut-fixture\n' > "$TMP/custody-override.yml"
  expect override_tag_absent_unavailable 2 UNAVAILABLE core4 "${COMPOSE_ARGS[@]}" -f "$TMP/custody-override.yml" || return 1
  json_is override_tag_absent_unavailable "m['images']['core4']['tags']['wrfcoin/native-chain:testnet-aacut-fixture']['services'] == ['wrfcoin-node']" || return 1
  json_is override_tag_absent_unavailable "m['images']['core4']['tags']['wrfcoin/native-chain:testnet-aacut-fixture']['freshness'] == 'UNAVAILABLE'" || return 1
  printf '%s\n' 'wrfcoin/native-chain:testnet-aacut-fixture inspect-fresh core4' >> "$FIXTURE_MAP"
  local rc=0
  expect override_tag_fresh 0 FRESH - "${COMPOSE_ARGS[@]}" -f "$TMP/custody-override.yml" || rc=1
  write_fixture_map
  return $rc
}
no_compose_input_is_void() {
  local rc
  render --out "$TMP/no-compose.json" >"$TMP/no-compose.out" 2>&1
  rc=$?
  [[ $rc -eq 2 ]] || { echo "    no compose input returned $rc, expected 2" >&2; return 1; }
  out_has no-compose 'RELEASE_MANIFEST=VOID no compose file set' || return 1
  [[ ! -e "$TMP/no-compose.json" ]] || { echo "    VOID run wrote a manifest" >&2; return 1; }
}
compose_render_failure_unavailable() {
  printf 'services: [not, a, mapping\n' > "$TMP/broken-compose.yml"
  expect compose_render_failure 2 UNAVAILABLE - -f "$TMP/broken-compose.yml" || return 1
  out_has compose_render_failure 'docker compose config failed' || return 1
}

# infra#1056: CT101 ran every backend service with CORS_ORIGIN=http://localhost:5000
# because compose defaulted it. Unset now renders empty (not `:?`: the #762 join
# trap), and an empty, loopback, or wildcard value must never classify FRESH;
# --verify refuses such a manifest.
cors_origin_unset_is_unavailable() {
  local rc=0
  grep -v '^CORS_ORIGIN=' "${ROOT}/testnet/.env.testnet.example" > "$TMP/no-cors.env"
  expect cors_unset_unavailable 2 UNAVAILABLE - --env-file "$TMP/no-cors.env" \
    -f "${ROOT}/testnet/docker-compose.testnet.yml" \
    -f "${ROOT}/testnet/docker-compose.override.yml" \
    -f "${ROOT}/testnet/docker-compose.funnel-edge.yml" || return 1
  grep -Eq 'RELEASE_MANIFEST=UNAVAILABLE .* unavailable=config( |$)' "$TMP/cors_unset_unavailable.out" \
    || { echo "    summary does not name unavailable=config" >&2; rc=1; }
  # The funnel overlay sets the gateway's own value; every other reader is empty.
  json_is cors_unset_unavailable '"wrfcoin-backend" not in {p["service"] for p in m["config_problems"]}' || rc=1
  out_has cors_unset_unavailable 'RELEASE_MANIFEST_FINDING config: UNAVAILABLE: wrfcoin-iot: CORS_ORIGIN is empty (no default since infra#1056)' || rc=1
  return $rc
}
cors_origin_loopback_is_unavailable() {
  local rc=0
  python3 - "$COMPOSE_JSON" "$TMP/cors-localhost.json" <<'CORS'
import json, sys
rendered = json.load(open(sys.argv[1], encoding="utf-8"))
for spec in rendered["services"].values():
    env = spec.get("environment") or {}
    if "CORS_ORIGIN" in env:
        env["CORS_ORIGIN"] = "https://wrfcoin-testnet.taila1c049.ts.net, http://localhost:5000"
rendered["services"]["wrfcoin-iot"]["environment"]["CORS_ORIGIN"] = "*"
rendered["services"]["wrfcoin-weather-earnings"]["environment"]["CORS_ORIGIN"] = "https://[0:0:0:0:0:0:0:1]:5000"
rendered["services"]["wrfcoin-backend"]["environment"]["CORS_ORIGIN"] = "https://*.example.org"
json.dump(rendered, open(sys.argv[2], "w", encoding="utf-8"))
CORS
  # "-": `config` is not an image group, so name it through the summary line.
  expect cors_localhost_unavailable 2 UNAVAILABLE - --compose-config "$TMP/cors-localhost.json" || rc=1
  grep -Eq 'RELEASE_MANIFEST=UNAVAILABLE .* unavailable=config( |$)' "$TMP/cors_localhost_unavailable.out" \
    || { echo "    summary does not name unavailable=config" >&2; rc=1; }
  json_is cors_localhost_unavailable 'all(g["freshness"] == "FRESH" for g in m["images"].values())' || rc=1
  json_is cors_localhost_unavailable '{p["service"] for p in m["config_problems"]} >= {"wrfcoin-backend", "wrfcoin-governance", "wrfcoin-iot"}' || rc=1
  json_is cors_localhost_unavailable 'all("loopback" in p["reason"] for p in m["config_problems"] if p["service"] not in ("wrfcoin-iot", "wrfcoin-backend"))' || rc=1
  json_is cors_localhost_unavailable '[p["reason"].startswith("CORS_ORIGIN entry %r is not a scheme://host[:port] origin" % "*") for p in m["config_problems"] if p["service"] == "wrfcoin-iot"] == [True]' || rc=1
  out_has cors_localhost_unavailable "RELEASE_MANIFEST_FINDING config: UNAVAILABLE: wrfcoin-governance: CORS_ORIGIN entry 'http://localhost:5000' is a loopback origin" || rc=1
  # Codex round 5: parsed, not string-matched (shared cors_origin_policy.py).
  out_has cors_localhost_unavailable "wrfcoin-weather-earnings: CORS_ORIGIN entry 'https://[0:0:0:0:0:0:0:1]:5000' is a loopback origin" || rc=1
  out_has cors_localhost_unavailable "wrfcoin-backend: CORS_ORIGIN entry 'https://*.example.org' is not a scheme://host[:port] origin" || rc=1
  return $rc
}
cors_policy_module_missing_fails_closed() {
  local rc
  # A committed removal, so the clean-tree gate passes and the renderer reaches
  # the policy load. The fixture infra repo is this test's own; it is reset.
  git -C "$WORKSPACE/infra" rm -q testnet/scripts/cors_origin_policy.py
  commit "$WORKSPACE/infra" 'fixture: drop the CORS policy module'
  render --compose-config "$COMPOSE_JSON" --out "$TMP/no-policy.json" > "$TMP/no-policy.out" 2>&1
  rc=$?
  git -C "$WORKSPACE/infra" reset -q --hard HEAD~1
  [[ $rc -ne 0 ]] || { echo "    renderer passed without its CORS policy module" >&2; return 1; }
  out_has no-policy 'RELEASE_MANIFEST=FAIL CORS policy module missing' || return 1
}
cors_origin_problems_fail_verify() {
  local vrc
  write_container_map
  expect cors_verify_base 0 FRESH - --compose-config "$COMPOSE_JSON" --check-running || return 1
  python3 - "$TMP/cors_verify_base.json" "$TMP/cors-verify-tampered.json" <<'CORS'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
manifest["config_problems"] = [{"service": "wrfcoin-iot", "reason": "CORS_ORIGIN entry 'http://localhost:5000' is a loopback origin"}]
json.dump(manifest, open(sys.argv[2], "w", encoding="utf-8"))
CORS
  bash "$RENDERER" --verify "$TMP/cors-verify-tampered.json" > "$TMP/cors-verify.out" 2>&1
  vrc=$?
  [[ $vrc -eq 1 ]] || { cat "$TMP/cors-verify.out" >&2; echo "    --verify returned $vrc, expected 1" >&2; return 1; }
  out_has cors-verify 'config_problems is' || return 1
}

# Fix 6: post-deploy, each running container must use exactly the tag's image.
OLD_ID="sha256:$(printf 'old' | sha256sum | cut -c1-64)"
running_containers_checked() {
  local rc=0
  write_container_map
  expect running_match_fresh 0 FRESH - --compose-config "$COMPOSE_JSON" --check-running || rc=1
  write_container_map wrfcoin-testnet-backend "$OLD_ID" true 0
  expect running_old_image_red 1 STALE backend --compose-config "$COMPOSE_JSON" --check-running || rc=1
  out_has running_old_image_red 'container wrfcoin-testnet-backend running an old image' || rc=1
  write_container_map wrfcoin-testnet-node absent x x
  expect running_absent_unavailable 2 UNAVAILABLE core4 --compose-config "$COMPOSE_JSON" --check-running || rc=1
  write_container_map wrfcoin-testnet-funnel-edge "$FRESH_ID" false 0
  expect running_stopped_unavailable 2 UNAVAILABLE edge --compose-config "$COMPOSE_JSON" --check-running || rc=1
  write_container_map wrfcoin-testnet-backend "$OLD_ID" true 0
  expect running_not_checked_by_default 0 FRESH - --compose-config "$COMPOSE_JSON" || rc=1
  write_container_map
  return $rc
}

# R1: the manifest and summary record which pass produced them, so a
# pre-deploy FRESH can never stand in for the post-deploy --check-running one.
mode_is_recorded_and_distinguishes_passes() {
  local rc=0
  write_container_map
  expect mode_pre 0 FRESH - --compose-config "$COMPOSE_JSON" || rc=1
  expect mode_post 0 FRESH - --compose-config "$COMPOSE_JSON" --check-running || rc=1
  out_has mode_pre 'RELEASE_MANIFEST=FRESH mode=pre_deploy ' || rc=1
  out_has mode_post 'RELEASE_MANIFEST=FRESH mode=check_running ' || rc=1
  json_is mode_pre 'm["mode"] == "pre_deploy" and m["check_running"] is False' || rc=1
  json_is mode_pre 'all(t["containers"] is None for g in m["images"].values() for t in g["tags"].values())' || rc=1
  json_is mode_post 'm["mode"] == "check_running" and m["check_running"] is True' || rc=1
  # Every service of every gated tag has its container and image ID recorded.
  json_is mode_post 'all(sorted(c["service"] for c in t["containers"]) == sorted(t["services"]) and all(c["container"] and c["container_image_id"] for c in t["containers"]) for g in m["images"].values() for t in g["tags"].values())' || rc=1
  json_is mode_post 'any(c["service"] == "db-migrate" and c["one_shot"] and c["exit_code"] == 0 for c in m["images"]["backend-services"]["tags"]["'"$BACKEND_SERVICES_TAG"'"]["containers"])' || rc=1
  return $rc
}

# R2: the second backend image (wrfcoin/backend:testnet-local) is gated on the
# backend pin, over the service set the render derives.
second_backend_image_gated() {
  local rc=0
  json_is compose_files_fresh "list(m['images']['backend-services']['tags']) == ['$BACKEND_SERVICES_TAG']" || rc=1
  json_is compose_files_fresh "m['images']['backend-services']['compose_services'] == ['db-migrate', 'wrfcoin-governance', 'wrfcoin-iot', 'wrfcoin-weather-earnings']" || rc=1
  expect_image stale_backend_services_red backend-services inspect-stale 1 STALE || rc=1
  expect_image wrong_revision_backend_services_red backend-services inspect-wrong-revision 1 STALE || rc=1
  expect_image label_missing_backend_services_unavailable backend-services inspect-label-missing 2 UNAVAILABLE || rc=1
  return $rc
}
# A stale image on a single backend-image service (its own tag via a host
# override) fails the gate for that service.
stale_weather_earnings_and_db_migrate_images_red() {
  local service tag rc=0
  for service in wrfcoin-weather-earnings db-migrate; do
    tag="wrfcoin/backend:${service}-old"
    printf 'services:\n  %s:\n    image: %s\n' "$service" "$tag" > "$TMP/override-$service.yml"
    write_fixture_map
    printf '%s inspect-stale backend\n' "$tag" >> "$FIXTURE_MAP"
    expect "stale_${service}_red" 1 STALE backend-services "${COMPOSE_ARGS[@]}" -f "$TMP/override-$service.yml" || rc=1
    json_is "stale_${service}_red" "m['images']['backend-services']['tags']['$tag']['services'] == ['$service'] and m['images']['backend-services']['tags']['$tag']['freshness'] == 'STALE'" || rc=1
    json_is "stale_${service}_red" "m['images']['backend-services']['tags']['$BACKEND_SERVICES_TAG']['freshness'] == 'FRESH'" || rc=1
  done
  write_fixture_map
  return $rc
}
# db-migrate is one-shot: its exited container must have run the tag's image
# and exited 0.
db_migrate_one_shot_checked() {
  local rc=0
  write_container_map wrfcoin-testnet-db-migrate "$OLD_ID" false 0
  expect db_migrate_old_image_red 1 STALE backend-services --compose-config "$COMPOSE_JSON" --check-running || rc=1
  out_has db_migrate_old_image_red 'container wrfcoin-testnet-db-migrate running an old image' || rc=1
  write_container_map wrfcoin-testnet-db-migrate "$FRESH_ID" false 1
  expect db_migrate_failed_red 1 STALE backend-services --compose-config "$COMPOSE_JSON" --check-running || rc=1
  out_has db_migrate_failed_red 'one-shot wrfcoin-testnet-db-migrate exited 1' || rc=1
  write_container_map wrfcoin-testnet-db-migrate "$FRESH_ID" true 0
  expect db_migrate_still_running_unavailable 2 UNAVAILABLE backend-services --compose-config "$COMPOSE_JSON" --check-running || rc=1
  write_container_map wrfcoin-testnet-db-migrate absent x x
  expect db_migrate_absent_unavailable 2 UNAVAILABLE backend-services --compose-config "$COMPOSE_JSON" --check-running || rc=1
  write_container_map wrfcoin-testnet-weather-earnings "$OLD_ID" true 0
  expect weather_earnings_old_container_red 1 STALE backend-services --compose-config "$COMPOSE_JSON" --check-running || rc=1
  write_container_map
  return $rc
}
inspect_without_image_id_unavailable() {
  expect_image no_id_backend_unavailable backend inspect-no-id 2 UNAVAILABLE
}
# infra#974 (frontend#348/#381): the frontend image must be a public build with
# every org.wrfcoin.frontend.* flag label empty. A staging image, an image with
# internal-surface flags set (including a flag added later), or an image built
# before the variant label existed is never FRESH.
frontend_internal_surface_images_never_fresh() {
  local rc=0
  expect_image frontend_operator_preview_stale frontend inspect-frontend-operator-preview 1 STALE || rc=1
  out_has frontend_operator_preview_stale 'org.wrfcoin.frontend.operator-preview=true' || rc=1
  expect_image frontend_staging_stale frontend inspect-frontend-staging 1 STALE || rc=1
  out_has frontend_staging_stale "variant 'staging'" || rc=1
  expect_image frontend_future_flag_stale frontend inspect-frontend-future-flag 1 STALE || rc=1
  out_has frontend_future_flag_stale 'org.wrfcoin.frontend.some-new-flag=1' || rc=1
  expect_image frontend_no_variant_unavailable frontend inspect-frontend-no-variant 2 UNAVAILABLE || rc=1
  out_has frontend_no_variant_unavailable 'org.wrfcoin.frontend.variant label missing' || rc=1
  return $rc
}

# ---- R3: membership is fail-closed (round 3). Host overrides from the review.
override() { # NAME YAML-BODY -> path of an override file under $TMP
  printf 'services:\n%s\n' "$2" > "$TMP/override-$1.yml"
  printf '%s' "$TMP/override-$1.yml"
}
NODE_PREBUILT=wrfcoin/native-chain:testnet-aacut-x
node_prebuilt_tag_with_build_reset_is_gated() {
  local rc=0 file
  file="$(override node-prebuilt "  wrfcoin-node:
    image: $NODE_PREBUILT
    build: !reset null")"
  # Tag absent locally: the node is gated, so core4 cannot be FRESH.
  expect node_prebuilt_absent_unavailable 2 UNAVAILABLE core4 "${COMPOSE_ARGS[@]}" -f "$file" || rc=1
  json_is node_prebuilt_absent_unavailable "m['images']['core4']['tags']['$NODE_PREBUILT']['services'] == ['wrfcoin-node']" || rc=1
  # Present but built from another commit: STALE.
  printf '%s inspect-wrong-revision core4\n' "$NODE_PREBUILT" >> "$FIXTURE_MAP"
  expect node_prebuilt_wrong_revision_red 1 STALE core4 "${COMPOSE_ARGS[@]}" -f "$file" || rc=1
  # Present with the pinned revision: FRESH pre-deploy...
  write_fixture_map
  printf '%s inspect-fresh core4\n' "$NODE_PREBUILT" >> "$FIXTURE_MAP"
  expect node_prebuilt_fresh 0 FRESH - "${COMPOSE_ARGS[@]}" -f "$file" || rc=1
  # ...but post-deploy the node container on an unrelated image is STALE.
  write_container_map wrfcoin-testnet-node "$OLD_ID" true 0
  expect node_prebuilt_container_old_red 1 STALE core4 "${COMPOSE_ARGS[@]}" -f "$file" --check-running || rc=1
  write_container_map
  write_fixture_map
  return $rc
}
# A baseline service is gated by name even on an image outside the release
# repositories (only the name rule can catch this one).
baseline_service_on_foreign_image_is_gated() {
  local file
  file="$(override node-foreign "  wrfcoin-node:
    image: ghcr.io/example/node:1
    build: !reset null")"
  expect node_foreign_image_unavailable 2 UNAVAILABLE core4 "${COMPOSE_ARGS[@]}" -f "$file" || return 1
  json_is node_foreign_image_unavailable "m['images']['core4']['tags']['ghcr.io/example/node:1']['services'] == ['wrfcoin-node']" || return 1
}
iot_retagged_or_registry_image_is_gated() {
  local rc=0 file image
  for image in wrfcoin/backend:iot-hotfix ghcr.io/wrfcoin/backend:latest; do
    file="$(override "iot-${image//[\/:]/-}" "  wrfcoin-iot:
    image: $image
    build: !reset null")"
    expect "iot_${image//[\/:.]/_}_unavailable" 2 UNAVAILABLE backend-services "${COMPOSE_ARGS[@]}" -f "$file" || rc=1
    json_is "iot_${image//[\/:.]/_}_unavailable" "m['images']['backend-services']['tags']['$image']['services'] == ['wrfcoin-iot']" || rc=1
  done
  return $rc
}
unmapped_release_build_is_unavailable() {
  local rc=0 file
  file="$(override iot-unmapped "  wrfcoin-iot:
    build:
      dockerfile: infra/infra/docker/Dockerfile.backend-worker")"
  expect iot_unmapped_dockerfile_unavailable 2 UNAVAILABLE backend-services "${COMPOSE_ARGS[@]}" -f "$file" || rc=1
  out_has iot_unmapped_dockerfile_unavailable 'wrfcoin-iot: built from Dockerfile.backend-worker, not Dockerfile.backend' || rc=1
  # An unlisted service built inside a pinned repository's tree is not ignored.
  file="$(override stray-core4-build "  stray-tool:
    image: wrfcoin/stray-tool:local
    build:
      context: $WORKSPACE/core4
      dockerfile: tools/Dockerfile.stray")"
  expect stray_core4_build_unavailable 2 UNAVAILABLE core4 "${COMPOSE_ARGS[@]}" -f "$file" || rc=1
  out_has stray_core4_build_unavailable 'stray-tool: unmapped release build' || rc=1
  return $rc
}
required_service_missing_is_unavailable() {
  python3 - "$COMPOSE_JSON" "$TMP/no-iot.json" <<'PY' || return 1
import json, sys
config = json.load(open(sys.argv[1], encoding="utf-8"))
del config["services"]["wrfcoin-iot"]
json.dump(config, open(sys.argv[2], "w", encoding="utf-8"))
PY
  expect required_iot_missing_unavailable 2 UNAVAILABLE backend-services --compose-config "$TMP/no-iot.json" || return 1
  out_has required_iot_missing_unavailable 'wrfcoin-iot: required service is not rendered' || return 1
}
unlisted_service_on_release_repo_is_gated() {
  local file
  file="$(override extra-worker "  extra-worker:
    image: wrfcoin/backend:worker-x")"
  expect extra_worker_unavailable 2 UNAVAILABLE backend-services "${COMPOSE_ARGS[@]}" -f "$file" || return 1
  json_is extra_worker_unavailable "m['images']['backend-services']['tags']['wrfcoin/backend:worker-x']['services'] == ['extra-worker']" || return 1
}
# N1: a restart: "no" service is one-shot even when no consumer waits on it.
restart_no_service_is_one_shot() {
  python3 - "$COMPOSE_JSON" "$TMP/no-depends.json" <<'PY' || return 1
import json, sys
config = json.load(open(sys.argv[1], encoding="utf-8"))
for spec in config["services"].values():
    spec.pop("depends_on", None)
assert config["services"]["db-migrate"]["restart"] == "no"
json.dump(config, open(sys.argv[2], "w", encoding="utf-8"))
PY
  write_container_map
  expect restart_no_one_shot_fresh 0 FRESH - --compose-config "$TMP/no-depends.json" --check-running
}
# N2: --verify accepts only a consistent post-deploy manifest.
verify_accepts_only_consistent_post_deploy_manifests() {
  local rc=0 name
  write_container_map
  expect verify_pre 0 FRESH - --compose-config "$COMPOSE_JSON" || rc=1
  expect verify_post 0 FRESH - --compose-config "$COMPOSE_JSON" --check-running || rc=1
  bash "$RENDERER" --verify "$TMP/verify_post.json" > "$TMP/verify-ok.out" 2>&1 \
    || { cat "$TMP/verify-ok.out" >&2; echo "    genuine post-deploy manifest did not verify" >&2; rc=1; }
  grep -Fq 'RELEASE_MANIFEST_VERIFY=PASS' "$TMP/verify-ok.out" || rc=1
  python3 - "$TMP" <<'PY' || rc=1
import json, sys
tmp = sys.argv[1]
pre = json.load(open(f"{tmp}/verify_pre.json"))
post = json.load(open(f"{tmp}/verify_post.json"))
flipped = dict(pre, mode="check_running", check_running=True)          # hand-edited mode
json.dump(flipped, open(f"{tmp}/tamper-mode.json", "w"))
swapped = json.loads(json.dumps(post))                                   # container on other image
tag = next(iter(swapped["images"]["core4"]["tags"].values()))
tag["containers"][0]["container_image_id"] = "sha256:" + "0" * 64
json.dump(swapped, open(f"{tmp}/tamper-image.json", "w"))
dropped = json.loads(json.dumps(post))                                   # a service's container missing
tag = dropped["images"]["backend-services"]["tags"]["wrfcoin/backend:testnet-local"]
tag["containers"] = [c for c in tag["containers"] if c["service"] != "wrfcoin-iot"]
json.dump(dropped, open(f"{tmp}/tamper-dropped.json", "w"))
stale = json.loads(json.dumps(post)); stale["classification"] = "STALE"  # not FRESH
json.dump(stale, open(f"{tmp}/tamper-class.json", "w"))
PY
  for name in verify_pre tamper-mode tamper-image tamper-dropped tamper-class; do
    local file="$TMP/$name.json"
    bash "$RENDERER" --verify "$file" > "$TMP/verify-$name.out" 2>&1
    local vrc=$?
    if [[ $vrc -ne 1 ]] || ! grep -Fq 'RELEASE_MANIFEST_VERIFY=FAIL' "$TMP/verify-$name.out"; then
      cat "$TMP/verify-$name.out" >&2
      echo "    --verify $name returned $vrc, expected 1 with FAIL" >&2
      rc=1
    fi
  done
  return $rc
}
# infra#1039: --verify binds the manifest to the current release. Each case is a
# genuine post-deploy manifest with one thing changed (or a genuine manifest
# checked against other pins); every one must FAIL with exit 1 and a FAIL line,
# never a traceback.
verify_rc() { # NAME EXPECTED-RC MANIFEST [verify args...]
  local name="$1" want="$2" file="$3" vrc
  shift 3
  bash "$RENDERER" --verify "$file" "$@" > "$TMP/verify-$name.out" 2>&1
  vrc=$?
  if [[ $vrc -ne $want ]] || grep -q 'Traceback' "$TMP/verify-$name.out"; then
    sed 's/^/    /' "$TMP/verify-$name.out" >&2
    echo "    --verify $name returned $vrc, expected $want (no traceback)" >&2
    return 1
  fi
  if [[ $want -eq 1 ]] && ! grep -Fq 'RELEASE_MANIFEST_VERIFY=FAIL' "$TMP/verify-$name.out"; then
    sed 's/^/    /' "$TMP/verify-$name.out" >&2
    echo "    --verify $name: no RELEASE_MANIFEST_VERIFY=FAIL line" >&2
    return 1
  fi
  return 0
}
verify_binds_manifest_to_current_release() {
  local rc=0 name
  write_container_map
  expect verify_bind_post 0 FRESH - --compose-config "$COMPOSE_JSON" --check-running || return 1
  verify_rc genuine 0 "$TMP/verify_bind_post.json" || rc=1
  grep -Fq 'RELEASE_MANIFEST_VERIFY=PASS' "$TMP/verify-genuine.out" || rc=1
  python3 - "$TMP" <<'PY' || return 1
import datetime, json, sys
tmp = sys.argv[1]
post = json.load(open(f"{tmp}/verify_bind_post.json"))
def copy():
    return json.loads(json.dumps(post))
def dump(name, manifest):
    json.dump(manifest, open(f"{tmp}/bind-{name}.json", "w"))
now = datetime.datetime.now(datetime.timezone.utc)
old = "a" * 40

# Replay of an earlier release candidate: every pin and revision is another SHA.
replay = copy()
for repo in ("core4", "backend", "frontend"):
    for field in ("pinned", "head", "resolved_pin"):
        replay["repos"][repo][field] = old
for group in ("core4", "backend", "backend-services", "frontend"):
    replay["images"][group]["expected_revision"] = old
    for record in replay["images"][group]["tags"].values():
        record["revision"] = old
dump("replayed-release", replay)
# Same replay, also backdated (the reviewer's exact case).
replay["generated_at"] = "2025-01-01T00:00:00+00:00"
dump("replayed-backdated", replay)

# Only one tag's revision differs from the pin; freshness still says FRESH.
one = copy()
next(iter(one["images"]["frontend"]["tags"].values()))["revision"] = old
dump("tag-revision", one)
# The edge revision is not a commit of this infra checkout.
edge = copy()
next(iter(edge["images"]["edge"]["tags"].values()))["revision"] = old
dump("edge-revision", edge)
# The manifest was rendered under another minimum build date.
floor = copy(); floor["minimum_public_build_date"] = "2026-01-01"
dump("min-date", floor)

# generated_at: too old, in the future, missing, naive, garbage.
aged = copy(); aged["generated_at"] = (now - datetime.timedelta(hours=25)).isoformat()
dump("too-old", aged)
two_hours = copy(); two_hours["generated_at"] = (now - datetime.timedelta(hours=2)).isoformat()
dump("two-hours-old", two_hours)
future = copy(); future["generated_at"] = (now + datetime.timedelta(hours=1)).isoformat()
dump("future", future)
missing = copy(); del missing["generated_at"]
dump("no-generated-at", missing)
naive = copy(); naive["generated_at"] = now.replace(tzinfo=None).isoformat()
dump("naive-generated-at", naive)
garbage = copy(); garbage["generated_at"] = "yesterday"
dump("garbage-generated-at", garbage)

# A tag with no services and no containers.
empty = copy()
template = next(iter(empty["images"]["core4"]["tags"].values()))
empty["images"]["core4"]["tags"]["wrfcoin/native-chain:empty"] = dict(template, services=[], containers=[])
dump("empty-tag", empty)

# Malformed shapes: each must be a FAIL line, not a traceback.
for label, mutate in {
    "containers-str": lambda t: t.__setitem__("containers", ["x"]),
    "containers-dict": lambda t: t.__setitem__("containers", {"x": 1}),
    "services-str": lambda t: t.__setitem__("services", "wrfcoin-node"),
    "services-unhashable": lambda t: t.__setitem__("services", [["wrfcoin-node"]]),
}.items():
    shaped = copy()
    mutate(next(iter(shaped["images"]["core4"]["tags"].values())))
    dump(label, shaped)
record_list = copy()
tags = record_list["images"]["core4"]["tags"]
tags[next(iter(tags))] = ["x"]
dump("record-not-object", record_list)
repos_list = copy(); repos_list["repos"] = ["core4"]
dump("repos-not-object", repos_list)
PY
  for name in replayed-release replayed-backdated tag-revision edge-revision min-date \
      too-old future no-generated-at naive-generated-at garbage-generated-at empty-tag \
      containers-str containers-dict services-str services-unhashable record-not-object repos-not-object; do
    verify_rc "$name" 1 "$TMP/bind-$name.json" || rc=1
  done
  # The age window is configurable: two hours passes the 24h default, not 1h.
  verify_rc two-hours-default 0 "$TMP/bind-two-hours-old.json" || rc=1
  verify_rc two-hours-1h 1 "$TMP/bind-two-hours-old.json" --max-age-hours 1 || rc=1
  verify_rc bad-max-age 2 "$TMP/verify_bind_post.json" --max-age-hours nope || rc=1
  # A genuine manifest from the previous release fails once the checkout's own
  # pins move to the next release.
  cp "$PINS" "$TMP/pins.saved"
  sed -i "s/^WRFCOIN_RC_BACKEND_COMMIT=.*/WRFCOIN_RC_BACKEND_COMMIT=$(printf 'b%.0s' {1..40})/" "$PINS"
  verify_rc next-release-pins 1 "$TMP/verify_bind_post.json" || rc=1
  cp "$TMP/pins.saved" "$PINS"
  grep -Fq 'repos.backend.pinned' "$TMP/verify-next-release-pins.out" || rc=1
  verify_rc same-pins-explicit 0 "$TMP/verify_bind_post.json" --pins "$PINS" || rc=1
  return $rc
}
# Review of #1045, non-blocking 1: --verify, like the renderer, uses only the
# verifying checkout's own pins files, so a stale copy of an old release's pins
# cannot vouch for an old manifest; and the age window is capped at 72h.
verify_refuses_external_pins_and_unbounded_age() {
  local rc=0
  write_container_map
  expect verify_ext_post 0 FRESH - --compose-config "$COMPOSE_JSON" --check-running || return 1
  cp "$PINS" "$TMP/external-pins.env"
  verify_rc external-pins 1 "$TMP/verify_ext_post.json" --pins "$TMP/external-pins.env" || rc=1
  grep -Fq 'must be this checkout' "$TMP/verify-external-pins.out" || rc=1
  cp "$WORKSPACE/infra/testnet/cut-pins.env" "$TMP/external-cut-pins.env"
  verify_rc external-cut-pins 1 "$TMP/verify_ext_post.json" --cut-pins "$TMP/external-cut-pins.env" || rc=1
  grep -Fq 'must be this checkout' "$TMP/verify-external-cut-pins.out" || rc=1
  # A copy inside the checkout's testnet/ directory is still not the pins file.
  cp "$PINS" "$WORKSPACE/infra/testnet/old-release-pins.env"
  verify_rc in-tree-copy-pins 1 "$TMP/verify_ext_post.json" --pins "$WORKSPACE/infra/testnet/old-release-pins.env" || rc=1
  rm -f "$WORKSPACE/infra/testnet/old-release-pins.env"
  verify_rc missing-own-pins 2 "$TMP/verify_ext_post.json" --pins "$TMP/no-such-pins.env" || rc=1
  verify_rc max-age-72 0 "$TMP/verify_ext_post.json" --max-age-hours 72 || rc=1
  verify_rc max-age-73 2 "$TMP/verify_ext_post.json" --max-age-hours 73 || rc=1
  verify_rc max-age-huge 2 "$TMP/verify_ext_post.json" --max-age-hours 100000 || rc=1
  verify_rc max-age-inf 2 "$TMP/verify_ext_post.json" --max-age-hours inf || rc=1
  verify_rc max-age-nan 2 "$TMP/verify_ext_post.json" --max-age-hours nan || rc=1
  return $rc
}
# Review of #1045, non-blocking 2: a repo recorded as not clean never verifies.
verify_rechecks_clean_repos() {
  local rc=0 repo
  write_container_map
  expect verify_clean_post 0 FRESH - --compose-config "$COMPOSE_JSON" --check-running || return 1
  for repo in core4 backend frontend infra; do
    python3 - "$TMP/verify_clean_post.json" "$TMP/unclean-$repo.json" "$repo" <<'PY' || return 1
import json, sys
manifest = json.load(open(sys.argv[1]))
manifest["repos"][sys.argv[3]]["clean"] = False
json.dump(manifest, open(sys.argv[2], "w"))
PY
    verify_rc "unclean-$repo" 1 "$TMP/unclean-$repo.json" || rc=1
    grep -Fq "repos.$repo.clean" "$TMP/verify-unclean-$repo.out" || rc=1
  done
  python3 - "$TMP/verify_clean_post.json" "$TMP/unclean-missing.json" <<'PY' || return 1
import json, sys
manifest = json.load(open(sys.argv[1]))
del manifest["repos"]["backend"]["clean"]
json.dump(manifest, open(sys.argv[2], "w"))
PY
  verify_rc unclean-missing 1 "$TMP/unclean-missing.json" || rc=1
  return $rc
}
# Review of #1045, non-blocking 3: a Dockerfile in a subdirectory of
# infra/docker/ is a release build too.
unmapped_infra_docker_subdir_build_is_unavailable() {
  local rc=0 file
  file="$(override infra-docker-subdir "  wrfcoin-newsvc:
    image: wrfcoin/newsvc:testnet-local
    build:
      context: $WORKSPACE
      dockerfile: infra/infra/docker/workers/Dockerfile.x")"
  expect infra_docker_subdir_unavailable 2 UNAVAILABLE - "${COMPOSE_ARGS[@]}" -f "$file" || rc=1
  out_has infra_docker_subdir_unavailable 'wrfcoin-newsvc: unmapped release build (Dockerfile.x)' || rc=1
  file="$(override infra-docker-subdir-context "  wrfcoin-newsvc:
    image: wrfcoin/newsvc:testnet-local
    build:
      context: $WORKSPACE/infra/infra/docker/workers
      dockerfile: Dockerfile.x")"
  expect infra_docker_subdir_context_unavailable 2 UNAVAILABLE - "${COMPOSE_ARGS[@]}" -f "$file" || rc=1
  out_has infra_docker_subdir_context_unavailable 'wrfcoin-newsvc: unmapped release build (Dockerfile.x)' || rc=1
  return $rc
}
# infra#1039 item 3: the release Dockerfiles live in infra/docker/ and build from
# the workspace root, so a new service built from a new Dockerfile there is an
# unmapped release build, whatever its image.
unmapped_infra_docker_build_is_unavailable() {
  local rc=0 file
  file="$(override infra-docker-new "  wrfcoin-newsvc:
    image: wrfcoin/newsvc:testnet-local
    build:
      context: $WORKSPACE
      dockerfile: infra/infra/docker/Dockerfile.newsvc")"
  expect infra_docker_unmapped_unavailable 2 UNAVAILABLE - "${COMPOSE_ARGS[@]}" -f "$file" || rc=1
  out_has infra_docker_unmapped_unavailable 'wrfcoin-newsvc: unmapped release build (Dockerfile.newsvc)' || rc=1
  # The same Dockerfile directory reached with the infra checkout as context.
  file="$(override infra-docker-infra-context "  wrfcoin-newsvc:
    image: wrfcoin/newsvc:testnet-local
    build:
      context: $WORKSPACE/infra
      dockerfile: infra/docker/Dockerfile.newsvc")"
  expect infra_docker_infra_context_unavailable 2 UNAVAILABLE - "${COMPOSE_ARGS[@]}" -f "$file" || rc=1
  out_has infra_docker_infra_context_unavailable 'wrfcoin-newsvc: unmapped release build (Dockerfile.newsvc)' || rc=1
  return $rc
}

# ---- infra#1047: CT101 keeps its identity owners (softhsm-init,
# softhsm-seed-init, wrfcoin-seed) on the older aacut core4 image, because
# boot-heal forbids recreating them. Without an exemption core4 can never be
# FRESH; with a reviewed exemption bound to the exact image it can, and the
# owners are recorded as EXEMPT, never FRESH.
AACUT_TAG=wrfcoin/native-chain:testnet-aacut-fixture-amd64
AACUT_ID=sha256:3c3660a417ae300bb887f91a7d2e1fdf72b7f9d212e61ab95e3ff280a1c7d67c
CT101_OVERRIDE="$TMP/ct101-release-override.yml"
cat > "$CT101_OVERRIDE" <<YAML
services:
  softhsm-init:
    image: $AACUT_TAG
  softhsm-seed-init:
    image: $AACUT_TAG
  wrfcoin-seed:
    image: $AACUT_TAG
YAML
ct101_fixtures() { # [REVSPEC for the aacut tag]
  write_fixture_map
  printf '%s inspect-identity-owner-aacut %s\n' "$AACUT_TAG" "${1:-rev:$CORE4_OLD}" >> "$FIXTURE_MAP"
}
ct101_containers() { # [CONTAINER IMAGE-ID RUNNING EXIT|absent ...] overrides for the owners
  write_container_map
  # The default map already lists softhsm-init on the node's image; the stub
  # serves the first match, so the owners' lines replace any existing ones.
  sed -i -E '/^wrfcoin-testnet-(softhsm-init|seed-softhsm-init|seed) /d' "$CONTAINER_MAP"
  local owners=(
    "wrfcoin-testnet-softhsm-init $AACUT_ID true 0"
    "wrfcoin-testnet-seed-softhsm-init $AACUT_ID true 0"
    "wrfcoin-testnet-seed $AACUT_ID false 1"
  ) line i
  for line in "${owners[@]}"; do
    for ((i = 1; i <= $#; i += 4)); do
      if [[ "${line%% *}" == "${!i}" ]]; then
        local j=$((i + 1)) k=$((i + 2)) l=$((i + 3))
        line="${!i} ${!j} ${!k} ${!l}"
        [[ "${!j}" == absent ]] && line=""
      fi
    done
    [[ -n "$line" ]] && printf '%s\n' "$line" >> "$CONTAINER_MAP"
  done
  return 0
}
exemptions_file() { # NAME LINE... -> path
  printf '%s\n' "# fixture exemption file" "${@:2}" > "$TMP/exempt-$1.txt"
  printf '%s' "$TMP/exempt-$1.txt"
}
CT101_EXEMPT="$(exemptions_file ct101 \
  "softhsm-init $AACUT_ID $CORE4_OLD" \
  "softhsm-seed-init $AACUT_ID $CORE4_OLD   # identity owner, boot-heal custody" \
  "wrfcoin-seed $AACUT_ID $CORE4_OLD")"

# The problem as filed: the owners' old image keeps core4 from ever being FRESH.
identity_owners_on_old_core4_image_block_fresh() {
  export COMPOSE_PROFILES=seed
  ct101_fixtures
  expect ct101_no_exemption_red 1 STALE core4 "${COMPOSE_ARGS[@]}" -f "$CT101_OVERRIDE" || return 1
  json_is ct101_no_exemption_red "sorted(m['images']['core4']['tags']['$AACUT_TAG']['services']) == ['softhsm-init', 'softhsm-seed-init', 'wrfcoin-seed']" || return 1
  out_has ct101_no_exemption_red 'predates minimum public build date' || return 1
}

identity_owner_exemption_reaches_fresh() {
  local rc=0
  export COMPOSE_PROFILES=seed
  ct101_fixtures
  expect ct101_exempt_pre 0 FRESH - "${COMPOSE_ARGS[@]}" -f "$CT101_OVERRIDE" --exempt "$CT101_EXEMPT" || rc=1
  out_has ct101_exempt_pre 'RELEASE_MANIFEST=FRESH mode=pre_deploy ' || rc=1
  out_has ct101_exempt_pre ' exempt=softhsm-init,softhsm-seed-init,wrfcoin-seed' || rc=1
  json_is ct101_exempt_pre "list(m['images']['core4']['tags']) == ['$NODE_TAG'] and m['images']['core4']['tags']['$NODE_TAG']['services'] == ['wrfcoin-node']" || rc=1
  json_is ct101_exempt_pre "m['images']['core4']['exempt']['$AACUT_TAG']['freshness'] == 'EXEMPT' and m['images']['core4']['exempt']['$AACUT_TAG']['image_id'] == '$AACUT_ID'" || rc=1
  json_is ct101_exempt_pre "m['exemptions']['services'] == ['softhsm-init', 'softhsm-seed-init', 'wrfcoin-seed'] and len(m['exemptions']['sha256']) == 64" || rc=1
  json_is ct101_exempt_pre "all(t['freshness'] == 'FRESH' for g in m['images'].values() for t in g['tags'].values())" || rc=1
  ct101_containers
  expect ct101_exempt_post 0 FRESH - "${COMPOSE_ARGS[@]}" -f "$CT101_OVERRIDE" --exempt "$CT101_EXEMPT" --check-running || rc=1
  json_is ct101_exempt_post "sorted(c['service'] for c in m['images']['core4']['exempt']['$AACUT_TAG']['containers']) == ['softhsm-init', 'softhsm-seed-init', 'wrfcoin-seed']" || rc=1
  bash "$RENDERER" --verify "$TMP/ct101_exempt_post.json" --exempt "$CT101_EXEMPT" > "$TMP/ct101-verify.out" 2>&1 \
    || { cat "$TMP/ct101-verify.out" >&2; echo "    exempt post-deploy manifest did not verify" >&2; rc=1; }
  grep -Fq 'RELEASE_MANIFEST_VERIFY=PASS' "$TMP/ct101-verify.out" && grep -Fq 'exempt=softhsm-init,softhsm-seed-init,wrfcoin-seed' "$TMP/ct101-verify.out" || rc=1
  # The exemption covers the owners only: a stale node is still STALE.
  ct101_fixtures
  sed -i "s#^$NODE_TAG inspect-fresh#$NODE_TAG inspect-stale#" "$FIXTURE_MAP"
  expect ct101_exempt_stale_node_red 1 STALE core4 "${COMPOSE_ARGS[@]}" -f "$CT101_OVERRIDE" --exempt "$CT101_EXEMPT" || rc=1
  ct101_fixtures; write_container_map
  return $rc
}

exemption_is_bound_to_exact_image_and_container() {
  local rc=0 file
  export COMPOSE_PROFILES=seed
  ct101_fixtures
  file="$(exemptions_file wrong-id "softhsm-init sha256:$(printf '%064d' 0) $CORE4_OLD" "softhsm-seed-init $AACUT_ID $CORE4_OLD" "wrfcoin-seed $AACUT_ID $CORE4_OLD")"
  expect exempt_wrong_id_red 1 STALE core4 "${COMPOSE_ARGS[@]}" -f "$CT101_OVERRIDE" --exempt "$file" || rc=1
  out_has exempt_wrong_id_red 'not the exempted sha256:0000' || rc=1
  file="$(exemptions_file wrong-rev "softhsm-init $AACUT_ID $(printf '%040d' 1)" "softhsm-seed-init $AACUT_ID $CORE4_OLD" "wrfcoin-seed $AACUT_ID $CORE4_OLD")"
  expect exempt_wrong_revision_red 1 STALE core4 "${COMPOSE_ARGS[@]}" -f "$CT101_OVERRIDE" --exempt "$file" || rc=1
  out_has exempt_wrong_revision_red 'is not the exempted 0000000000000000000000000000000000000001' || rc=1
  # Declared and labelled alike, but not an ancestor of the core4 pin.
  ct101_fixtures rev:2222222222222222222222222222222222222222
  file="$(exemptions_file foreign "softhsm-init $AACUT_ID 2222222222222222222222222222222222222222" "softhsm-seed-init $AACUT_ID 2222222222222222222222222222222222222222" "wrfcoin-seed $AACUT_ID 2222222222222222222222222222222222222222")"
  expect exempt_not_ancestor_red 1 STALE core4 "${COMPOSE_ARGS[@]}" -f "$CT101_OVERRIDE" --exempt "$file" || rc=1
  out_has exempt_not_ancestor_red 'is not an ancestor of the core4 pin' || rc=1
  # The exempted tag absent locally: nothing to bind to.
  write_fixture_map
  expect exempt_image_absent_unavailable 2 UNAVAILABLE core4 "${COMPOSE_ARGS[@]}" -f "$CT101_OVERRIDE" --exempt "$CT101_EXEMPT" || rc=1
  # Post-deploy the owners' containers must run exactly the exempted image.
  ct101_fixtures
  ct101_containers wrfcoin-testnet-seed-softhsm-init "$OLD_ID" true 0
  expect exempt_container_other_image_red 1 STALE core4 "${COMPOSE_ARGS[@]}" -f "$CT101_OVERRIDE" --exempt "$CT101_EXEMPT" --check-running || rc=1
  out_has exempt_container_other_image_red 'exempt container wrfcoin-testnet-seed-softhsm-init runs' || rc=1
  ct101_containers wrfcoin-testnet-softhsm-init absent x x
  expect exempt_container_absent_unavailable 2 UNAVAILABLE core4 "${COMPOSE_ARGS[@]}" -f "$CT101_OVERRIDE" --exempt "$CT101_EXEMPT" --check-running || rc=1
  write_container_map
  return $rc
}

exemption_file_refusals() {
  local rc=0
  export COMPOSE_PROFILES=seed
  ct101_fixtures
  refuse() { # NAME FILE WANT-TEXT
    local out="$TMP/$1.out" vrc
    render "${COMPOSE_ARGS[@]}" -f "$CT101_OVERRIDE" --exempt "$2" --out "$TMP/$1.json" >"$out" 2>&1
    vrc=$?
    if [[ $vrc -ne 1 ]] || ! grep -Fq -- "$3" "$out" || [[ -e "$TMP/$1.json" ]]; then
      sed 's/^/    /' "$out" >&2; echo "    $1 returned $vrc, expected 1 with: $3 and no manifest" >&2; return 1
    fi
  }
  refuse exempt_node_refused "$(exemptions_file node "wrfcoin-node $FRESH_ID $CORE4_OLD")" 'exemption for wrfcoin-node refused: only the identity owners' || rc=1
  refuse exempt_attester_refused "$(exemptions_file attester "oracle-attester $FRESH_ID $CORE4_OLD")" 'exemption for oracle-attester refused' || rc=1
  refuse exempt_malformed_refused "$(exemptions_file malformed "softhsm-init $AACUT_ID")" 'exemption line 2 is not' || rc=1
  refuse exempt_short_id_refused "$(exemptions_file short "softhsm-init sha256:3c3660a4 $CORE4_OLD")" 'exemption line 2 is not' || rc=1
  refuse exempt_duplicate_refused "$(exemptions_file dup "softhsm-init $AACUT_ID $CORE4_OLD" "softhsm-init $AACUT_ID $CORE4_OLD")" 'listed twice' || rc=1
  refuse exempt_empty_refused "$(exemptions_file empty)" 'lists no service' || rc=1
  refuse exempt_missing_file_refused "$TMP/does-not-exist.txt" 'cannot read exemption file' || rc=1
  # A stale exemption (seed profile not rendered) is refused, not ignored.
  export COMPOSE_PROFILES=
  refuse exempt_unrendered_refused "$CT101_EXEMPT" 'exemption for softhsm-seed-init, wrfcoin-seed names no rendered gated service' || rc=1
  return $rc
}

exemption_refused_when_tag_shared_with_gated_service() {
  # Default render: softhsm-init runs the node's own tag. An exemption there
  # would ride on the node's gate, so it is refused and the tag stays gated.
  local file
  write_fixture_map
  file="$(exemptions_file shared "softhsm-init $FRESH_ID $CORE4_OLD")"
  expect exempt_shared_tag_unavailable 2 UNAVAILABLE core4 "${COMPOSE_ARGS[@]}" --exempt "$file" || return 1
  out_has exempt_shared_tag_unavailable "softhsm-init: exemption refused: tag $NODE_TAG also serves gated service(s) ['wrfcoin-node']" || return 1
  json_is exempt_shared_tag_unavailable "m['images']['core4']['tags']['$NODE_TAG']['services'] == ['softhsm-init', 'wrfcoin-node']" || return 1
}

verify_rejects_tampered_exemptions() {
  local rc=0 name
  export COMPOSE_PROFILES=seed
  ct101_fixtures; ct101_containers
  expect ct101_verify_src 0 FRESH - "${COMPOSE_ARGS[@]}" -f "$CT101_OVERRIDE" --exempt "$CT101_EXEMPT" --check-running || return 1
  python3 - "$TMP" "$AACUT_TAG" "$NODE_TAG" <<'PY' || return 1
import json, sys
tmp, aacut, node = sys.argv[1:]
src = json.load(open(f"{tmp}/ct101_verify_src.json"))
def variant(name, mutate):
    m = json.loads(json.dumps(src)); mutate(m); json.dump(m, open(f"{tmp}/{name}.json", "w"))
def not_exempt(m): m["images"]["core4"]["exempt"][aacut]["freshness"] = "STALE"
def other_image(m): m["images"]["core4"]["exempt"][aacut]["containers"][0]["container_image_id"] = "sha256:" + "0" * 64
def drop_container(m): m["images"]["core4"]["exempt"][aacut]["containers"].pop()
def list_node(m): m["exemptions"]["services"].append("wrfcoin-node")
def unlisted_record(m): m["exemptions"]["services"].remove("wrfcoin-seed")
def node_into_exempt(m):
    rec = m["images"]["core4"]["tags"].pop(node)
    rec.update(freshness="EXEMPT", declared={"wrfcoin-node": {"image_id": rec["image_id"]}})
    m["images"]["core4"]["exempt"][node] = rec
    m["exemptions"]["services"].append("wrfcoin-node")
def declared_mismatch(m): m["images"]["core4"]["exempt"][aacut]["declared"]["wrfcoin-seed"]["image_id"] = "sha256:" + "1" * 64
def seed_running(m):
    for c in m["images"]["core4"]["exempt"][aacut]["containers"]:
        if c["service"] == "wrfcoin-seed":
            c.update(running=True, exit_code=0)
def not_ancestor(m):
    rec = m["images"]["core4"]["exempt"][aacut]
    rec["revision"] = "2" * 40
    for d in rec["declared"].values():
        d["revision"] = "2" * 40
def revision_mismatch(m): m["images"]["core4"]["exempt"][aacut]["declared"]["softhsm-init"]["revision"] = "3" * 40
for name, fn in [("tamper-not-exempt", not_exempt), ("tamper-exempt-image", other_image),
                 ("tamper-exempt-dropped", drop_container), ("tamper-list-node", list_node),
                 ("tamper-unlisted", unlisted_record), ("tamper-node-exempt", node_into_exempt),
                 ("tamper-declared", declared_mismatch), ("tamper-seed-running", seed_running),
                 ("tamper-not-ancestor", not_ancestor), ("tamper-revision", revision_mismatch)]:
    variant(name, fn)
PY
  for name in tamper-not-exempt tamper-exempt-image tamper-exempt-dropped tamper-list-node tamper-unlisted tamper-node-exempt tamper-declared tamper-seed-running tamper-not-ancestor tamper-revision; do
    bash "$RENDERER" --verify "$TMP/$name.json" --exempt "$CT101_EXEMPT" > "$TMP/verify-$name.out" 2>&1
    local vrc=$?
    if [[ $vrc -ne 1 ]] || ! grep -Fq 'RELEASE_MANIFEST_VERIFY=FAIL' "$TMP/verify-$name.out"; then
      cat "$TMP/verify-$name.out" >&2
      echo "    --verify $name returned $vrc, expected 1 with FAIL" >&2
      rc=1
    fi
  done
  write_container_map
  return $rc
}

# ---- infra#1047: a non-git release tree (CT101's core4.releases/<sha>, an
# extracted `git archive`) is bound to the pinned workspace checkout.
release_tree_must_equal_git_archive_of_pin() {
  local rc=0 tree="$TMP/core4.releases/pin" infra_tree="$TMP/infra.releases/head"
  mkdir -p "$tree" "$infra_tree"
  git -C "$WORKSPACE/core4" archive HEAD | tar -x -C "$tree"
  git -C "$WORKSPACE/infra" archive HEAD | tar -x -C "$infra_tree"
  printf 'SECRET=fixture\n' > "$infra_tree/testnet/.env"          # operator files are untracked
  expect release_tree_fresh 0 FRESH - --compose-config "$COMPOSE_JSON" \
    --release-tree "core4=$tree" --release-tree "infra=$infra_tree" || rc=1
  json_is release_tree_fresh "m['repos']['core4']['release_tree']['verified_against'] == m['repos']['core4']['pinned'] and m['repos']['core4']['release_tree']['untracked_extra_count'] == 0" || rc=1
  json_is release_tree_fresh "m['repos']['infra']['release_tree']['verified_against'] == m['repos']['infra']['head'] and m['repos']['infra']['release_tree']['untracked_extra'] == ['testnet/.env']" || rc=1
  tree_refused() { # NAME WANT [--release-tree ...]
    local vrc
    render --compose-config "$COMPOSE_JSON" "${@:3}" --out "$TMP/$1.json" >"$TMP/$1.out" 2>&1
    vrc=$?
    if [[ $vrc -ne 1 ]] || ! grep -Fq -- "$2" "$TMP/$1.out" || [[ -e "$TMP/$1.json" ]]; then
      sed 's/^/    /' "$TMP/$1.out" >&2; echo "    $1 returned $vrc, expected 1 with: $2" >&2; return 1
    fi
  }
  tree_refused release_tree_twice 'given twice' --release-tree "core4=$tree" --release-tree "core4=$tree" || rc=1
  printf 'edited\n' >> "$tree/source.txt"
  tree_refused release_tree_edited 'source.txt: content differs' --release-tree "core4=$tree" || rc=1
  git -C "$WORKSPACE/core4" show HEAD:source.txt > "$tree/source.txt"
  chmod +x "$tree/source.txt"
  tree_refused release_tree_mode 'source.txt: executable bit differs' --release-tree "core4=$tree" || rc=1
  chmod -x "$tree/source.txt"
  rm "$infra_tree/testnet/cut-pins.env"
  tree_refused release_tree_missing 'testnet/cut-pins.env: missing' --release-tree "infra=$infra_tree" || rc=1
  # A tree extracted from the older core4 commit is not the pin.
  rm -rf "$tree" && mkdir -p "$tree"
  git -C "$WORKSPACE/core4" archive "$CORE4_OLD" | tar -x -C "$tree"
  tree_refused release_tree_old_commit 'source.txt: content differs' --release-tree "core4=$tree" || rc=1
  tree_refused release_tree_is_checkout 'is the workspace checkout itself' --release-tree "core4=$WORKSPACE/core4" || rc=1
  tree_refused release_tree_bad_name '--release-tree must be NAME=DIR' --release-tree "edge=$tree" || rc=1
  return $rc
}

# ---- review of #1054 (item 1): the seed is a full core4 node. Exempt only
# while it is NOT running: exited from the exempt image, or confirmed absent.
exempt_seed_must_not_run() {
  local rc=0
  export COMPOSE_PROFILES=seed
  ct101_fixtures
  ct101_containers wrfcoin-testnet-seed "$AACUT_ID" true 0
  expect exempt_seed_running_red 1 STALE core4 "${COMPOSE_ARGS[@]}" -f "$CT101_OVERRIDE" --exempt "$CT101_EXEMPT" --check-running || rc=1
  out_has exempt_seed_running_red 'exempt wrfcoin-seed container wrfcoin-testnet-seed is running' || rc=1
  # Running on some other image is just as red.
  ct101_containers wrfcoin-testnet-seed "$OLD_ID" true 0
  expect exempt_seed_running_other_red 1 STALE core4 "${COMPOSE_ARGS[@]}" -f "$CT101_OVERRIDE" --exempt "$CT101_EXEMPT" --check-running || rc=1
  # Exited from another image: not the exempted one.
  ct101_containers wrfcoin-testnet-seed "$OLD_ID" false 0
  expect exempt_seed_exited_other_red 1 STALE core4 "${COMPOSE_ARGS[@]}" -f "$CT101_OVERRIDE" --exempt "$CT101_EXEMPT" --check-running || rc=1
  # Absent (positively listed as not there): FRESH, recorded present=false, and it verifies.
  ct101_containers wrfcoin-testnet-seed absent x x
  expect exempt_seed_absent_fresh 0 FRESH - "${COMPOSE_ARGS[@]}" -f "$CT101_OVERRIDE" --exempt "$CT101_EXEMPT" --check-running || rc=1
  json_is exempt_seed_absent_fresh "[c for c in m['images']['core4']['exempt']['$AACUT_TAG']['containers'] if c['service'] == 'wrfcoin-seed'] == [{'service': 'wrfcoin-seed', 'container': 'wrfcoin-testnet-seed', 'container_image_id': None, 'running': False, 'exit_code': None, 'present': False, 'required_state': 'not_running'}]" || rc=1
  bash "$RENDERER" --verify "$TMP/exempt_seed_absent_fresh.json" --exempt "$CT101_EXEMPT" > "$TMP/seed-absent-verify.out" 2>&1 \
    || { cat "$TMP/seed-absent-verify.out" >&2; echo "    absent-seed manifest did not verify" >&2; rc=1; }
  # An inspect failure is never taken for absence: the listing must succeed.
  STUB_LS_FAIL=1 expect exempt_seed_listing_failed_unavailable 2 UNAVAILABLE core4 "${COMPOSE_ARGS[@]}" -f "$CT101_OVERRIDE" --exempt "$CT101_EXEMPT" --check-running || rc=1
  # The HSM init owners are not relaxed: absent is still UNAVAILABLE.
  ct101_containers wrfcoin-testnet-seed-softhsm-init absent x x
  expect exempt_init_absent_unavailable 2 UNAVAILABLE core4 "${COMPOSE_ARGS[@]}" -f "$CT101_OVERRIDE" --exempt "$CT101_EXEMPT" --check-running || rc=1
  write_container_map
  return $rc
}

# Review item 4: --verify re-reads the exemption file the manifest names.
verify_requires_the_same_exemption_file() {
  local rc=0 vrc other
  export COMPOSE_PROFILES=seed
  ct101_fixtures; ct101_containers
  expect ct101_file_src 0 FRESH - "${COMPOSE_ARGS[@]}" -f "$CT101_OVERRIDE" --exempt "$CT101_EXEMPT" --check-running || return 1
  vfail() { # NAME WANT [verify args...]
    bash "$RENDERER" --verify "$TMP/ct101_file_src.json" "${@:3}" > "$TMP/$1.out" 2>&1
    vrc=$?
    if [[ $vrc -ne 1 ]] || ! grep -Fq -- "$2" "$TMP/$1.out"; then
      cat "$TMP/$1.out" >&2; echo "    $1 returned $vrc, expected 1 with: $2" >&2; return 1
    fi
  }
  vfail verify_without_exempt_file 'pass the same --exempt FILE to --verify' || rc=1
  other="$(exemptions_file edited "softhsm-init $AACUT_ID $CORE4_OLD" "softhsm-seed-init $AACUT_ID $CORE4_OLD" "wrfcoin-seed $AACUT_ID $CORE4_OLD")"
  vfail verify_other_exempt_file 'sha256' --exempt "$other" || rc=1
  other="$(exemptions_file fewer "softhsm-init $AACUT_ID $CORE4_OLD")"
  vfail verify_fewer_entries '--exempt entries' --exempt "$other" || rc=1
  write_container_map
  return $rc
}

# Review item 4: the manifest records --release-tree use; --verify can require it.
release_tree_use_is_recorded_and_can_be_required() {
  local rc=0 vrc tree="$TMP/core4.releases/verify"
  mkdir -p "$tree"
  git -C "$WORKSPACE/core4" archive HEAD | tar -x -C "$tree"
  write_container_map
  expect tree_post 0 FRESH - --compose-config "$COMPOSE_JSON" --check-running --release-tree "core4=$tree" || rc=1
  json_is tree_post "m['release_trees'] == ['core4']" || rc=1
  expect no_tree_post 0 FRESH - --compose-config "$COMPOSE_JSON" --check-running || rc=1
  json_is no_tree_post "m['release_trees'] == []" || rc=1
  bash "$RENDERER" --verify "$TMP/tree_post.json" --require-release-tree core4 > "$TMP/tree-verify.out" 2>&1 \
    || { cat "$TMP/tree-verify.out" >&2; rc=1; }
  for args in "tree_post.json infra" "no_tree_post.json core4"; do
    set -- $args
    bash "$RENDERER" --verify "$TMP/$1" --require-release-tree "$2" > "$TMP/tree-verify-$2.out" 2>&1
    vrc=$?
    if [[ $vrc -ne 1 ]] || ! grep -Fq "release tree $2: required" "$TMP/tree-verify-$2.out"; then
      cat "$TMP/tree-verify-$2.out" >&2; echo "    --require-release-tree $2 on $1 returned $vrc" >&2; rc=1
    fi
  done
  return $rc
}

# ------------------------------------------------------------------ faucet (infra#1121)
# CT101 ran wrfcoin/faucet:testnet-local built 2026-07-02 with no revision label
# (July server.js) while --check-running said FRESH: the faucet was not gated.
faucet_is_gated_from_the_render() {
  local rc=0
  expect faucet_compose_fresh 0 FRESH - "${COMPOSE_ARGS[@]}" || return 1
  json_is faucet_compose_fresh "list(m['images']['faucet']['tags']) == ['$FAUCET_TAG'] and m['images']['faucet']['compose_services'] == ['wrfcoin-faucet']" || rc=1
  json_is faucet_compose_fresh "m['images']['faucet']['tags']['$FAUCET_TAG']['revision'] == '$(git -C "$WORKSPACE/infra" rev-parse HEAD)'" || rc=1
  json_is faucet_compose_fresh "'testnet/services/faucet/' in m['images']['faucet']['expected_revision']" || rc=1
  return $rc
}
faucet_july_image_is_stale() {
  local rc=0
  # The exact live state: created 2026-07-02, no labels at all.
  expect_image faucet_july_red faucet inspect-faucet-july 1 STALE || rc=1
  out_has faucet_july_red 'predates minimum public build date' || rc=1
  expect_image faucet_stale_red faucet inspect-stale 1 STALE || rc=1
  return $rc
}
faucet_unlabelled_image_is_never_fresh() {
  local rc=0
  expect_image faucet_label_missing_unavailable faucet inspect-label-missing 2 UNAVAILABLE || rc=1
  expect_image faucet_label_empty_unavailable faucet inspect-label-empty 2 UNAVAILABLE || rc=1
  out_has faucet_label_empty_unavailable 'org.opencontainers.image.revision label missing or not a full SHA' || rc=1
  expect_image faucet_image_absent_unavailable faucet absent 2 UNAVAILABLE || rc=1
  return $rc
}
faucet_revision_must_bake_current_faucet_source() {
  local rc=0
  # A recent build from an infra commit whose faucet source differs from HEAD.
  expect_image faucet_old_source_red faucet inspect-fresh 1 STALE "rev:$EDGE_V2" || rc=1
  out_has faucet_old_source_red "testnet/services/faucet/ changed between revision $EDGE_V2" || rc=1
  expect_image faucet_foreign_revision_red faucet inspect-wrong-revision 1 STALE || rc=1
  # An older commit with an identical faucet source is the same image.
  expect_image faucet_same_source_fresh faucet inspect-fresh 0 FRESH "rev:$FAUCET_V2" || rc=1
  # The edge's own context is judged separately: FAUCET_V2's edge is EDGE_V2's.
  expect_image edge_unaffected_by_faucet_change edge inspect-fresh 0 FRESH "rev:$FAUCET_V2" || rc=1
  return $rc
}
faucet_running_container_checked() {
  local rc=0
  write_container_map
  expect faucet_running_fresh 0 FRESH - --compose-config "$COMPOSE_JSON" --check-running || rc=1
  json_is faucet_running_fresh "[c['container'] for c in m['images']['faucet']['tags']['$FAUCET_TAG']['containers']] == ['wrfcoin-testnet-faucet']" || rc=1
  # Rebuilt tag, container never recreated: the r12 section 6.4 failure mode.
  write_container_map wrfcoin-testnet-faucet "$OLD_ID" true 0
  expect faucet_running_old_red 1 STALE faucet --compose-config "$COMPOSE_JSON" --check-running || rc=1
  out_has faucet_running_old_red 'container wrfcoin-testnet-faucet running an old image' || rc=1
  write_container_map wrfcoin-testnet-faucet absent x x
  expect faucet_running_absent_unavailable 2 UNAVAILABLE faucet --compose-config "$COMPOSE_JSON" --check-running || rc=1
  write_container_map
  return $rc
}
faucet_missing_from_render_is_unavailable() {
  local rc=0
  # A render without the faucet profile cannot vouch for a running faucet.
  COMPOSE_PROFILES= expect faucet_unrendered_unavailable 2 UNAVAILABLE faucet "${COMPOSE_ARGS[@]}" || rc=1
  out_has faucet_unrendered_unavailable 'wrfcoin-faucet: required service is not rendered' || rc=1
  return $rc
}
faucet_on_another_tag_or_dockerfile_is_gated() {
  local rc=0
  python3 - "$COMPOSE_JSON" "$TMP" <<'PY' || return 1
import json, sys
src, tmp = sys.argv[1], sys.argv[2]
def variant(name, mutate):
    config = json.load(open(src, encoding="utf-8"))
    mutate(config["services"])
    json.dump(config, open(f"{tmp}/{name}.json", "w", encoding="utf-8"))
# A host override points the faucet at a prebuilt tag and drops its build.
variant("faucet-prebuilt", lambda s: (s["wrfcoin-faucet"].pop("build"),
                                      s["wrfcoin-faucet"].__setitem__("image", "wrfcoin/faucet:july")))
# The faucet built from some other Dockerfile.
variant("faucet-other-dockerfile",
        lambda s: s["wrfcoin-faucet"]["build"].__setitem__("dockerfile", "testnet/services/faucet/Dockerfile.dev"))
# Another service running the faucet repository.
variant("faucet-second-service",
        lambda s: s.__setitem__("faucet-b", {"image": "ghcr.io/wrfcoin/faucet:old", "container_name": "faucet-b"}))
PY
  expect faucet_prebuilt_unavailable 2 UNAVAILABLE faucet --compose-config "$TMP/faucet-prebuilt.json" || rc=1
  json_is faucet_prebuilt_unavailable "m['images']['faucet']['tags']['wrfcoin/faucet:july']['services'] == ['wrfcoin-faucet']" || rc=1
  expect faucet_other_dockerfile_unavailable 2 UNAVAILABLE faucet --compose-config "$TMP/faucet-other-dockerfile.json" || rc=1
  out_has faucet_other_dockerfile_unavailable 'wrfcoin-faucet: built from Dockerfile.dev, not testnet/services/faucet/Dockerfile' || rc=1
  expect faucet_second_service_unavailable 2 UNAVAILABLE faucet --compose-config "$TMP/faucet-second-service.json" || rc=1
  json_is faucet_second_service_unavailable "m['images']['faucet']['tags']['ghcr.io/wrfcoin/faucet:old']['services'] == ['faucet-b']" || rc=1
  return $rc
}
verify_requires_a_fresh_faucet() {
  local rc=0 name
  write_container_map
  expect verify_faucet_post 0 FRESH - --compose-config "$COMPOSE_JSON" --check-running || return 1
  verify_rc faucet-genuine 0 "$TMP/verify_faucet_post.json" || rc=1
  python3 - "$TMP" "$EDGE_V2" <<'PY' || return 1
import json, sys
tmp, edge_v2 = sys.argv[1], sys.argv[2]
post = json.load(open(f"{tmp}/verify_faucet_post.json"))
def dump(name, mutate):
    manifest = json.loads(json.dumps(post))
    mutate(manifest)
    json.dump(manifest, open(f"{tmp}/faucet-{name}.json", "w"))
def tag(m):
    return next(iter(m["images"]["faucet"]["tags"].values()))
# A manifest from a renderer that never gated the faucet (pre-#1121).
dump("group-missing", lambda m: m["images"].pop("faucet"))
# The faucet revision is a real infra commit whose faucet source has since changed.
dump("old-source", lambda m: tag(m).__setitem__("revision", edge_v2))
dump("foreign-revision", lambda m: tag(m).__setitem__("revision", "a" * 40))
PY
  for name in group-missing old-source foreign-revision; do
    verify_rc "faucet-$name" 1 "$TMP/faucet-$name.json" || rc=1
  done
  grep -Fq 'faucet: missing' "$TMP/verify-faucet-group-missing.out" \
    || { echo "    group-missing: no 'faucet: missing'" >&2; rc=1; }
  grep -Fq "testnet/services/faucet/ differs between revision $EDGE_V2" "$TMP/verify-faucet-old-source.out" \
    || { sed 's/^/    /' "$TMP/verify-faucet-old-source.out" >&2; echo "    old-source: faucet context not checked" >&2; rc=1; }
  return $rc
}

run_case exact_clean_heads_pass
run_case stale_wrong_revision_and_unlabelled_images
run_case edge_old_ancestor_with_changed_context_stale
run_case edge_older_commit_with_identical_context_fresh
run_case old_docker_created_with_fresh_label_stale
run_case malformed_inspect_output_unavailable
run_case earlier_manifest_never_survives
run_case compose_render_derives_gated_tags
run_case host_override_tag_is_followed
run_case no_compose_input_is_void
run_case compose_render_failure_unavailable
run_case cors_origin_unset_is_unavailable
run_case cors_origin_loopback_is_unavailable
run_case cors_origin_problems_fail_verify
run_case cors_policy_module_missing_fails_closed
run_case running_containers_checked
run_case mode_is_recorded_and_distinguishes_passes
run_case second_backend_image_gated
run_case stale_weather_earnings_and_db_migrate_images_red
run_case db_migrate_one_shot_checked
run_case inspect_without_image_id_unavailable
run_case frontend_internal_surface_images_never_fresh
run_case node_prebuilt_tag_with_build_reset_is_gated
run_case baseline_service_on_foreign_image_is_gated
run_case iot_retagged_or_registry_image_is_gated
run_case unmapped_release_build_is_unavailable
run_case required_service_missing_is_unavailable
run_case unlisted_service_on_release_repo_is_gated
run_case restart_no_service_is_one_shot
run_case verify_accepts_only_consistent_post_deploy_manifests
run_case verify_binds_manifest_to_current_release
run_case unmapped_infra_docker_build_is_unavailable
run_case verify_refuses_external_pins_and_unbounded_age
run_case verify_rechecks_clean_repos
run_case unmapped_infra_docker_subdir_build_is_unavailable
run_case identity_owners_on_old_core4_image_block_fresh
run_case identity_owner_exemption_reaches_fresh
run_case exemption_is_bound_to_exact_image_and_container
run_case exemption_file_refusals
run_case exemption_refused_when_tag_shared_with_gated_service
run_case verify_rejects_tampered_exemptions
run_case release_tree_must_equal_git_archive_of_pin
run_case exempt_seed_must_not_run
run_case verify_requires_the_same_exemption_file
run_case release_tree_use_is_recorded_and_can_be_required
run_case faucet_is_gated_from_the_render
run_case faucet_july_image_is_stale
run_case faucet_unlabelled_image_is_never_fresh
run_case faucet_revision_must_bake_current_faucet_source
run_case faucet_running_container_checked
run_case faucet_missing_from_render_is_unavailable
run_case faucet_on_another_tag_or_dockerfile_is_gated
run_case verify_requires_a_fresh_faucet

# ---------------------------------------------------------------- storage group (infra#944, #1242)
# The storage group is OPT-IN (--storage). Without it the renderer behaves exactly as before the
# group existed, whatever the render contains: the r19.1 deployed manifest must not change.
STORAGE_ARGS=(--compose-config "$STORAGE_JSON" --storage)
storage_container_map() { # [CONTAINER IMAGE-ID RUNNING EXIT|absent ...] over the storage render
  write_container_map
  local c
  for c in testnet-storage-node-1 testnet-weather-ipfs-archive-1; do
    printf '%s %s true 0\n' "$c" "$FRESH_ID" >> "$CONTAINER_MAP"
  done
  printf '%s %s true 0\n' testnet-ipfs-kubo-1 "$KUBO_ID" >> "$CONTAINER_MAP"
}
storage_fixture_map() { # [kubo-fixture]: every image FRESH, kubo served from the given fixture
  write_fixture_map
  if [[ -n "${1:-}" ]]; then
    grep -v "^$KUBO_TAG " "$FIXTURE_MAP" > "$FIXTURE_MAP.tmp" || true
    printf '%s %s rev:none\n' "$KUBO_TAG" "$1" >> "$FIXTURE_MAP.tmp"
    mv "$FIXTURE_MAP.tmp" "$FIXTURE_MAP"
  fi
}
normalise_manifest() { # FILE: drop only the wall-clock field
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); m.pop("generated_at"); print(json.dumps(m, indent=2, sort_keys=True))' "$1"
}

storage_group_is_opt_in_and_changes_nothing_without_it() {
  local rc=0 json
  write_fixture_map; write_container_map
  for json in "$COMPOSE_JSON" "$STORAGE_JSON"; do
    render --compose-config "$json" --out "$TMP/optin.json" >"$TMP/optin.out" 2>&1 || true
    python3 - "$TMP/optin.json" <<'PY' || rc=1
import json, sys
m = json.load(open(sys.argv[1]))
assert set(m["images"]) == {"core4", "backend", "backend-services", "frontend", "edge", "faucet"}, sorted(m["images"])
assert set(m["repos"]) == {"core4", "backend", "frontend", "infra"}, sorted(m["repos"])
assert "storage-providers" not in json.dumps(m), "storage leaked into a manifest rendered without --storage"
PY
    # Optional byte-for-byte comparison with another renderer (the pre-storage one from main):
    #   BASELINE_RENDERER=<path> scripts/tests/test-render-release-manifest.sh
    if [[ -n "${BASELINE_RENDERER:-}" ]]; then
      mkdir -p "$TMP/baseline/testnet/scripts"
      cp "$BASELINE_RENDERER" "$TMP/baseline/testnet/scripts/render-release-manifest.sh"
      cp "${ROOT}/testnet/scripts/cors_origin_policy.py" "$TMP/baseline/testnet/scripts/"
      cp "$WORKSPACE/infra/testnet/cut-pins.env" "$TMP/baseline/testnet/cut-pins.env"
      local rc_new rc_old
      render --compose-config "$json" --out "$TMP/new.json" >"$TMP/new.out" 2>&1; rc_new=$?
      bash "$TMP/baseline/testnet/scripts/render-release-manifest.sh" --workspace "$WORKSPACE" --pins "$PINS" \
        --compose-config "$json" --out "$TMP/old.json" >"$TMP/old.out" 2>&1; rc_old=$?
      [[ $rc_new -eq $rc_old ]] || { sed 's/^/    old: /' "$TMP/old.out" >&2; sed 's/^/    new: /' "$TMP/new.out" >&2; echo "    baseline rc $rc_old != new rc $rc_new" >&2; rc=1; }
      cmp -s <(normalise_manifest "$TMP/old.json") <(normalise_manifest "$TMP/new.json") \
        || { echo "    manifest differs from the baseline renderer's for $json" >&2; rc=1; }
      cmp -s <(sed -e 's#output=[^ ]*##' "$TMP/old.out") <(sed -e 's#output=[^ ]*##' "$TMP/new.out") \
        || { echo "    console output differs from the baseline renderer's for $json" >&2; rc=1; }
    fi
  done
  # Storage services in the render but no --storage: unchanged behaviour, Dockerfile.storage unmapped.
  render --compose-config "$STORAGE_JSON" --out "$TMP/optin.json" >"$TMP/optin.out" 2>&1 || true
  json_is optin "any(p['service'] == 'storage-node' for p in m['membership_problems'])" || rc=1
  return $rc
}

storage_group_gates_kubo_and_storage_node() {
  local rc=0
  storage_fixture_map inspect-kubo
  expect storage_fresh 0 FRESH - "${STORAGE_ARGS[@]}" || return 1
  json_is storage_fresh 'set(m["images"]) == {"core4", "backend", "backend-services", "frontend", "edge", "faucet", "storage"}' || rc=1
  json_is storage_fresh "sorted(m['images']['storage']['tags']) == ['$KUBO_TAG', '$STORAGE_TAG']" || rc=1
  json_is storage_fresh "m['images']['storage']['compose_services'] == ['ipfs-kubo', 'storage-node']" || rc=1
  json_is storage_fresh "m['images']['storage']['expected_revision'] == m['repos']['storage-providers']['pinned']" || rc=1
  json_is storage_fresh "m['images']['storage']['tags']['$STORAGE_TAG']['revision'] == m['repos']['storage-providers']['head']" || rc=1
  json_is storage_fresh "m['images']['storage']['tags']['$KUBO_TAG']['upstream'] is True and m['images']['storage']['tags']['$KUBO_TAG']['pinned_digest'] == '$KUBO_DIGEST'" || rc=1
  json_is storage_fresh "m['repos']['storage-providers']['head'] == m['repos']['storage-providers']['pinned'] == m['repos']['storage-providers']['origin_main'] and m['repos']['storage-providers']['clean']" || rc=1
  # The worker runs the backend image: it is gated with the backend, not as storage.
  json_is storage_fresh "'weather-ipfs-archive' in m['images']['backend-services']['tags']['$BACKEND_SERVICES_TAG']['services'] and 'weather-ipfs-archive' not in m['images']['storage']['compose_services']" || rc=1
  json_is storage_fresh 'm["membership_problems"] == []' || rc=1
  return $rc
}

storage_group_refuses_wrong_revision_digest_and_missing_services() {
  local rc=0
  # storage-node built from some other storage-providers commit
  write_fixture_map storage inspect-wrong-revision
  expect storage_wrong_rev 1 STALE storage "${STORAGE_ARGS[@]}" || rc=1
  out_has storage_wrong_rev 'is not the pinned' || rc=1
  # storage-node without the revision label (built outside the #1259 overlay)
  write_fixture_map storage inspect-label-empty
  expect storage_no_label 2 UNAVAILABLE storage "${STORAGE_ARGS[@]}" || rc=1
  # kubo not the pinned digest (a tag-only pull, or a different image under the tag)
  storage_fixture_map inspect-fresh
  expect storage_kubo_digest 1 STALE storage "${STORAGE_ARGS[@]}" || rc=1
  out_has storage_kubo_digest "$KUBO_DIGEST" || rc=1
  # kubo image missing locally
  storage_fixture_map nonexistent-fixture
  grep -v "^$KUBO_TAG " "$FIXTURE_MAP" > "$FIXTURE_MAP.tmp"; mv "$FIXTURE_MAP.tmp" "$FIXTURE_MAP"
  expect storage_kubo_absent 2 UNAVAILABLE storage "${STORAGE_ARGS[@]}" || rc=1
  # --storage over a render without the storage profile: required services missing
  storage_fixture_map inspect-kubo
  expect storage_not_rendered 2 UNAVAILABLE storage --compose-config "$COMPOSE_JSON" --storage || rc=1
  out_has storage_not_rendered 'required service is not rendered' || rc=1
  # an unpinned checkout is refused like core4/backend/frontend
  printf '%s\n' dirty >> "$WORKSPACE/storage-providers/source.txt"
  render "${STORAGE_ARGS[@]}" --out "$TMP/sp-dirty.json" >"$TMP/sp-dirty.out" 2>&1
  [[ $? -eq 1 ]] && grep -Fq 'storage-providers worktree is dirty' "$TMP/sp-dirty.out" \
    || { sed 's/^/    /' "$TMP/sp-dirty.out" >&2; echo "    dirty storage-providers not refused" >&2; rc=1; }
  git -C "$WORKSPACE/storage-providers" checkout -q -- source.txt
  write_fixture_map
  return $rc
}

storage_group_running_containers_checked_and_verified() {
  local rc=0
  storage_fixture_map inspect-kubo
  storage_container_map
  expect storage_post 0 FRESH - "${STORAGE_ARGS[@]}" --check-running || return 1
  json_is storage_post "all(c['container_image_id'] == t['image_id'] for t in m['images']['storage']['tags'].values() for c in t['containers'])" || rc=1
  verify_rc storage-genuine 0 "$TMP/storage_post.json" --storage || rc=1
  verify_rc storage-genuine-noflag 0 "$TMP/storage_post.json" || rc=1
  # a storage-node container still running the previous image
  storage_container_map
  sed -i "s#^testnet-storage-node-1 .*#testnet-storage-node-1 sha256:$(printf 'c%.0s' $(seq 64)) true 0#" "$CONTAINER_MAP"
  expect storage_old_container 1 STALE storage "${STORAGE_ARGS[@]}" --check-running || rc=1
  # verify: a manifest rendered without storage cannot satisfy --storage; tampered storage evidence fails
  write_container_map
  expect verify_nostorage 0 FRESH - --compose-config "$COMPOSE_JSON" --check-running || rc=1
  verify_rc storage-required-but-absent 1 "$TMP/verify_nostorage.json" --storage || rc=1
  grep -Fq 'storage: missing' "$TMP/verify-storage-required-but-absent.out" || { echo "    no 'storage: missing'" >&2; rc=1; }
  python3 - "$TMP" "$KUBO_TAG" "$STORAGE_TAG" <<'PY' || return 1
import json, sys
tmp, kubo, node = sys.argv[1:]
post = json.load(open(f"{tmp}/storage_post.json"))
def dump(name, mutate):
    m = json.loads(json.dumps(post)); mutate(m)
    json.dump(m, open(f"{tmp}/storage-{name}.json", "w"))
dump("node-revision", lambda m: m["images"]["storage"]["tags"][node].__setitem__("revision", "a" * 40))
dump("kubo-digest", lambda m: m["images"]["storage"]["tags"][kubo].__setitem__("pinned_digest", "sha256:" + "d" * 64))
dump("kubo-observed", lambda m: m["images"]["storage"]["tags"][kubo].__setitem__("repo_digests", []))
dump("kubo-claims-node", lambda m: m["images"]["storage"]["tags"][node].__setitem__("upstream", True))
dump("repo-pin", lambda m: m["repos"]["storage-providers"].__setitem__("pinned", "b" * 40))
dump("group-expected", lambda m: m["images"]["storage"].__setitem__("expected_revision", "b" * 40))
PY
  local name
  for name in node-revision kubo-digest kubo-observed kubo-claims-node repo-pin group-expected; do
    verify_rc "storage-$name" 1 "$TMP/storage-$name.json" || rc=1
  done
  write_fixture_map; write_container_map
  return $rc
}
run_case storage_group_is_opt_in_and_changes_nothing_without_it
run_case storage_group_gates_kubo_and_storage_node
run_case storage_group_refuses_wrong_revision_digest_and_missing_services
run_case storage_group_running_containers_checked_and_verified

# ------------------------------------------------ repository checks (fail-fast)
if [[ ${#FAILED[@]} -eq 0 ]]; then
  echo sha_mismatch_red
  sed 's/^WRFCOIN_RC_CORE4_COMMIT=.*/WRFCOIN_RC_CORE4_COMMIT=0000000000000000000000000000000000000000/' "$PINS" > "$TMP/bad-pins.env"
  set +e
  bash "$RENDERER" --workspace "$WORKSPACE" --pins "$TMP/bad-pins.env" --compose-config "$COMPOSE_JSON" --out "$TMP/bad.json" >"$TMP/mismatch.out" 2>&1
  rc=$?
  set -e
  [[ $rc -eq 1 ]] || { echo "SHA mismatch returned $rc, expected 1" >&2; exit 1; }
  grep -Fq 'WRFCOIN_CUT_CORE4_COMMIT' "$TMP/mismatch.out"

  echo frontend_without_363_red
  sed "s/^WRFCOIN_RC_FRONTEND_COMMIT=.*/WRFCOIN_RC_FRONTEND_COMMIT=$FRONTEND_PRE_363/" "$PINS" > "$TMP/pre-363-pins.env"
  git -C "$WORKSPACE/frontend" checkout -q --detach "$FRONTEND_PRE_363"
  set +e
  bash "$RENDERER" --workspace "$WORKSPACE" --pins "$TMP/pre-363-pins.env" --compose-config "$COMPOSE_JSON" --out "$TMP/pre-363.json" >"$TMP/pre-363.out" 2>&1
  rc=$?
  set -e
  git -C "$WORKSPACE/frontend" checkout -q --detach "$FRONTEND_363"
  [[ $rc -eq 1 ]] || { echo "frontend without #363 returned $rc, expected 1" >&2; exit 1; }
  grep -Fq 'selected frontend pin does not contain #363' "$TMP/pre-363.out"

  echo dirty_tree_red
  printf '%s\n' dirty >> "$WORKSPACE/backend/source.txt"
  set +e
  render --compose-config "$COMPOSE_JSON" --out "$TMP/dirty.json" >"$TMP/dirty.out" 2>&1
  rc=$?
  set -e
  [[ $rc -eq 1 ]] || { echo "dirty tree returned $rc, expected 1" >&2; exit 1; }
  grep -Fq 'worktree is dirty' "$TMP/dirty.out"
  git -C "$WORKSPACE/backend" restore source.txt

  echo dirty_renderer_checkout_red
  printf '%s\n' dirty > "$WORKSPACE/infra/uncommitted.txt"
  set +e
  render --compose-config "$COMPOSE_JSON" --out "$TMP/dirty-infra.json" >"$TMP/dirty-infra.out" 2>&1
  rc=$?
  set -e
  [[ $rc -eq 1 ]] || { echo "dirty infra returned $rc, expected 1" >&2; exit 1; }
  grep -Fq 'infra worktree is dirty' "$TMP/dirty-infra.out"
  rm "$WORKSPACE/infra/uncommitted.txt"

  echo missing_repo_void
  mv "$WORKSPACE/frontend" "$TMP/frontend-away"
  set +e
  render --compose-config "$COMPOSE_JSON" --out "$TMP/missing.json" >"$TMP/missing.out" 2>&1
  rc=$?
  set -e
  mv "$TMP/frontend-away" "$WORKSPACE/frontend"
  [[ $rc -eq 2 ]] || { echo "missing repo returned $rc, expected 2" >&2; exit 1; }
  grep -Fq 'RELEASE_MANIFEST=VOID repository missing' "$TMP/missing.out"

  echo external_pins_refused
  cp "$PINS" "$TMP/external-pins.env"
  set +e
  bash "$RENDERER" --workspace "$WORKSPACE" --pins "$TMP/external-pins.env" --compose-config "$COMPOSE_JSON" --out "$TMP/external.json" >"$TMP/external.out" 2>&1
  rc=$?
  set -e
  [[ $rc -eq 1 ]] || { echo "external pins returned $rc, expected 1" >&2; exit 1; }
  grep -Fq 'must contain and use testnet/release-pins.env' "$TMP/external.out"

  echo exact_clean_heads_restored
  render --compose-config "$COMPOSE_JSON" --out "$TMP/restored.json"
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "RELEASE_MANIFEST_TESTS=FAIL cases: ${FAILED[*]}" >&2
  exit 1
fi
echo RELEASE_MANIFEST_TESTS=PASS
