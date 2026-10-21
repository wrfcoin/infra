#!/usr/bin/env bash
# infra#1047: a git gate workspace for render-release-manifest.sh on a host
# whose deployed trees are non-git `git archive` extractions (CT101).
#
# Sources are synthetic: core4 and infra arrive as git bundles made exactly the
# way the rc0926 runbook makes them (`git bundle create X origin/main`), backend
# and frontend as local checkouts with an origin/main ref (CT101's shape). The
# renderer is then run against the prepared workspace, and its repository gates
# (HEAD == pin, clean, pin on origin/main, frontend #363, infra pins) must pass.
#
# PREPARE_UNDER_TEST / RENDERER_UNDER_TEST may point at other copies.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREPARE="${PREPARE_UNDER_TEST:-${ROOT}/testnet/scripts/prepare-release-gate-workspace.sh}"
SOURCE_RENDERER="${RENDERER_UNDER_TEST:-${ROOT}/testnet/scripts/render-release-manifest.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SRC="$TMP/src"
mkdir -p "$SRC"
commit() { git -C "$1" -c user.name=fixture -c user.email=fixture@invalid commit -q -m "$2"; }
FAILED=()
check() { # NAME COMMAND...
  local name="$1"; shift
  echo "$name"
  if ! "$@"; then FAILED+=("$name"); echo "  CASE FAILED: $name" >&2; fi
}

# ---- fixture sources
for repo in core4 backend frontend; do
  git init -q "$SRC/$repo"
  printf '%s v1\n' "$repo" > "$SRC/$repo/source.txt"
  git -C "$SRC/$repo" add source.txt && commit "$SRC/$repo" v1
  printf '%s v2\n' "$repo" >> "$SRC/$repo/source.txt"
  git -C "$SRC/$repo" add source.txt && commit "$SRC/$repo" v2
  git -C "$SRC/$repo" update-ref refs/remotes/origin/main HEAD
done
CORE4_PIN=$(git -C "$SRC/core4" rev-parse HEAD)
CORE4_V1=$(git -C "$SRC/core4" rev-parse HEAD~1)
BACKEND_PIN=$(git -C "$SRC/backend" rev-parse HEAD)
FRONTEND_PIN=$(git -C "$SRC/frontend" rev-parse HEAD)
# core4 work that is NOT on main: a pin there must be refused.
git -C "$SRC/core4" checkout -q -b side
printf 'side\n' >> "$SRC/core4/source.txt"; git -C "$SRC/core4" add source.txt && commit "$SRC/core4" side
CORE4_SIDE=$(git -C "$SRC/core4" rev-parse HEAD)
git -C "$SRC/core4" checkout -q --detach "$CORE4_PIN"

write_infra_commit() { # CORE4-PIN -> commits infra with those pins, prints the SHA
  mkdir -p "$SRC/infra/testnet/scripts"
  cp "$SOURCE_RENDERER" "$SRC/infra/testnet/scripts/render-release-manifest.sh"
  cp "${ROOT}/testnet/scripts/cors_origin_policy.py" "$SRC/infra/testnet/scripts/cors_origin_policy.py"
  cp "${ROOT}/testnet/workspace.dockerignore" "$SRC/infra/testnet/workspace.dockerignore"
  cat > "$SRC/infra/testnet/release-pins.env" <<PINS
WRFCOIN_RC_CORE4_COMMIT=$1
WRFCOIN_RC_BACKEND_COMMIT=$BACKEND_PIN
WRFCOIN_RC_FRONTEND_COMMIT=$FRONTEND_PIN
WRFCOIN_RC_MIN_PUBLIC_BUILD_DATE=2026-09-18
PINS
  printf 'WRFCOIN_CUT_CORE4_COMMIT=%s\n' "$1" > "$SRC/infra/testnet/cut-pins.env"
  git -C "$SRC/infra" add testnet && commit "$SRC/infra" "pins $1"
  git -C "$SRC/infra" rev-parse HEAD
}
git init -q "$SRC/infra"
printf 'readme\n' > "$SRC/infra/README"; git -C "$SRC/infra" add README && commit "$SRC/infra" init
INFRA_NO_PINS=$(git -C "$SRC/infra" rev-parse HEAD)
INFRA_SIDE_PIN=$(write_infra_commit "$CORE4_SIDE")
INFRA_OLD_PIN=$(write_infra_commit "$CORE4_V1")
INFRA_PIN=$(write_infra_commit "$CORE4_PIN")
git -C "$SRC/infra" update-ref refs/remotes/origin/main HEAD
# Bundles exactly as the runbook makes them (ref: refs/remotes/origin/main).
git -C "$SRC/core4" bundle create "$TMP/core4.bundle" origin/main 2>/dev/null
git -C "$SRC/infra" bundle create "$TMP/infra.bundle" origin/main 2>/dev/null
export WRFCOIN_RC_REQUIRED_FRONTEND_COMMIT="$FRONTEND_PIN"
EMPTY_COMPOSE="$TMP/compose.json"
printf '{"name": "testnet", "services": {}}\n' > "$EMPTY_COMPOSE"

prepare() { # OUT INFRA-COMMIT [overrides...]
  bash "$PREPARE" --out "$1" --infra-commit "$2" \
    --source "core4=$TMP/core4.bundle" --source "infra=$TMP/infra.bundle" \
    --source "backend=$SRC/backend" --source "frontend=$SRC/frontend" "${@:3}"
}
refused() { # NAME WANT-TEXT OUT INFRA [overrides...]
  local out="$TMP/$1.out" rc
  prepare "${@:3}" >"$out" 2>&1
  rc=$?
  if [[ $rc -ne 1 ]] || ! grep -Fq -- "GATE_WORKSPACE=FAIL" "$out" || ! grep -Fq -- "$2" "$out"; then
    sed 's/^/    /' "$out" >&2; echo "    $1 returned $rc, expected 1 with: $2" >&2; return 1
  fi
}

# ---- the documented procedure this replaces: RED by construction.
runbook_bundle_clone_has_no_origin_main() {
  git clone -q "$TMP/core4.bundle" "$TMP/runbook-clone" 2>/dev/null
  if git -C "$TMP/runbook-clone" rev-parse -q --verify 'origin/main^{commit}' >/dev/null 2>&1; then
    echo "    a clone of the runbook's bundle unexpectedly has origin/main" >&2; return 1
  fi
}

workspace_ready_and_renderer_repo_gates_pass() {
  local ws="$TMP/gate" rc
  prepare "$ws" "$INFRA_PIN" > "$TMP/ready.out" 2>&1 || { cat "$TMP/ready.out" >&2; return 1; }
  grep -Fq "GATE_WORKSPACE=READY dir=$ws core4=$CORE4_PIN backend=$BACKEND_PIN frontend=$FRONTEND_PIN infra=$INFRA_PIN" "$TMP/ready.out" \
    || { cat "$TMP/ready.out" >&2; return 1; }
  # infra#1077: the workspace root is the build context; BuildKit reads its
  # .dockerignore, which must be the pinned infra's canonical one.
  cmp -s "$ws/.dockerignore" "$ws/infra/testnet/workspace.dockerignore" \
    || { echo "    $ws/.dockerignore is missing or not the canonical workspace.dockerignore" >&2; return 1; }
  # The renderer's repository gates all pass on this workspace. The empty
  # compose render makes the images UNAVAILABLE (exit 2), which is expected
  # here; what matters is that it got past every repository check.
  bash "$ws/infra/testnet/scripts/render-release-manifest.sh" --workspace "$ws" \
    --pins "$ws/infra/testnet/release-pins.env" --compose-config "$EMPTY_COMPOSE" \
    --out "$TMP/gate-manifest.json" > "$TMP/render.out" 2>&1
  rc=$?
  [[ $rc -eq 2 ]] && grep -Fq 'RELEASE_MANIFEST=UNAVAILABLE' "$TMP/render.out" \
    || { cat "$TMP/render.out" >&2; echo "    renderer returned $rc" >&2; return 1; }
  python3 - "$TMP/gate-manifest.json" "$CORE4_PIN" "$INFRA_PIN" <<'PY' || return 1
import json, sys
m = json.load(open(sys.argv[1]))
r = m["repos"]
assert r["core4"]["head"] == r["core4"]["pinned"] == sys.argv[2], r["core4"]
assert all(r[n]["head"] == r[n]["pinned"] and r[n]["clean"] for n in ("core4", "backend", "frontend")), r
assert r["infra"]["head"] == sys.argv[3] and r["infra"]["clean"], r["infra"]
PY
}

# The workspace is bound to the deployed non-git trees by the renderer.
release_trees_bind_to_prepared_workspace() {
  local ws="$TMP/gate" tree="$TMP/core4.releases/$CORE4_PIN" rc
  mkdir -p "$tree"
  git -C "$SRC/core4" archive "$CORE4_PIN" | tar -x -C "$tree"
  bash "$ws/infra/testnet/scripts/render-release-manifest.sh" --workspace "$ws" \
    --pins "$ws/infra/testnet/release-pins.env" --compose-config "$EMPTY_COMPOSE" \
    --release-tree "core4=$tree" --out "$TMP/tree-manifest.json" > "$TMP/tree.out" 2>&1
  rc=$?
  [[ $rc -eq 2 ]] || { cat "$TMP/tree.out" >&2; echo "    renderer returned $rc" >&2; return 1; }
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["repos"]["core4"]["release_tree"]["verified_against"] == sys.argv[2]' \
    "$TMP/tree-manifest.json" "$CORE4_PIN" || return 1
  # The deployed tree of an older commit is refused.
  rm -rf "$tree" && mkdir -p "$tree" && git -C "$SRC/core4" archive "$CORE4_V1" | tar -x -C "$tree"
  bash "$ws/infra/testnet/scripts/render-release-manifest.sh" --workspace "$ws" \
    --pins "$ws/infra/testnet/release-pins.env" --compose-config "$EMPTY_COMPOSE" \
    --release-tree "core4=$tree" --out "$TMP/tree-old.json" > "$TMP/tree-old.out" 2>&1
  rc=$?
  [[ $rc -eq 1 ]] && grep -Fq 'source.txt: content differs' "$TMP/tree-old.out" \
    || { cat "$TMP/tree-old.out" >&2; echo "    old tree returned $rc" >&2; return 1; }
}

refusals() {
  local rc=0
  mkdir -p "$TMP/nonempty" && touch "$TMP/nonempty/x"
  refused out_not_empty 'is not empty' "$TMP/nonempty" "$INFRA_PIN" || rc=1
  refused pin_not_on_main "core4 pin $CORE4_SIDE is not in the core4 source's main branch" "$TMP/side" "$INFRA_SIDE_PIN" || rc=1
  refused infra_without_pins 'has no testnet/release-pins.env' "$TMP/nopins" "$INFRA_NO_PINS" || rc=1
  refused infra_not_on_main 'is not in the infra source' "$TMP/badinfra" "$(printf '%040d' 7)" || rc=1
  refused short_infra_sha 'full lowercase 40-hex' "$TMP/short" "${INFRA_PIN:0:12}" || rc=1
  printf 'not a bundle\n' > "$TMP/junk.bundle"
  bash "$PREPARE" --out "$TMP/junk" --infra-commit "$INFRA_PIN" --source "core4=$TMP/junk.bundle" \
    --source "infra=$TMP/infra.bundle" --source "backend=$SRC/backend" --source "frontend=$SRC/frontend" \
    > "$TMP/junk.out" 2>&1
  [[ $? -eq 1 ]] && grep -Fq 'is not a readable git bundle' "$TMP/junk.out" || { cat "$TMP/junk.out" >&2; rc=1; }
  refused duplicate_source 'given twice' "$TMP/dup" "$INFRA_PIN" --source "core4=$TMP/core4.bundle" || rc=1
  git init -q "$TMP/nomain" && printf 'x\n' > "$TMP/nomain/x" && git -C "$TMP/nomain" add x && commit "$TMP/nomain" x \
    && git -C "$TMP/nomain" branch -q -m trunk
  bash "$PREPARE" --out "$TMP/nm" --infra-commit "$INFRA_PIN" --source "core4=$TMP/core4.bundle" \
    --source "infra=$TMP/infra.bundle" --source "backend=$TMP/nomain" --source "frontend=$SRC/frontend" \
    > "$TMP/nomain.out" 2>&1
  [[ $? -eq 1 ]] && grep -Fq 'offers neither refs/remotes/origin/main nor refs/heads/main' "$TMP/nomain.out" \
    || { cat "$TMP/nomain.out" >&2; rc=1; }
  bash "$PREPARE" --out "$TMP/missing" --infra-commit "$INFRA_PIN" --source "core4=$TMP/core4.bundle" \
    > "$TMP/missing.out" 2>&1
  [[ $? -eq 1 ]] && grep -Fq -- '--source backend=PATH is required' "$TMP/missing.out" || { cat "$TMP/missing.out" >&2; rc=1; }
  # An older pin is fine for the script (it is on main); the renderer's
  # image checks, not this script, decide whether that release is current.
  prepare "$TMP/old" "$INFRA_OLD_PIN" > "$TMP/old.out" 2>&1 && grep -Fq "core4=$CORE4_V1" "$TMP/old.out" \
    || { cat "$TMP/old.out" >&2; rc=1; }
  return $rc
}

[[ -f "$PREPARE" ]] || { echo "FAIL: $PREPARE is missing" >&2; exit 1; }
check runbook_bundle_clone_has_no_origin_main runbook_bundle_clone_has_no_origin_main
check workspace_ready_and_renderer_repo_gates_pass workspace_ready_and_renderer_repo_gates_pass
check release_trees_bind_to_prepared_workspace release_trees_bind_to_prepared_workspace
check refusals refusals

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "GATE_WORKSPACE_TESTS=FAIL cases: ${FAILED[*]}" >&2
  exit 1
fi
echo GATE_WORKSPACE_TESTS=PASS
