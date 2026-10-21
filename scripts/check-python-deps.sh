#!/usr/bin/env bash
# check-python-deps.sh — resolve every Python dependency manifest in this repo
# against the SAME base image its consumer Dockerfile uses. (infra#746)
#
# WHY THIS EXISTS
# ---------------
# `infra/tools/requirements-ml.txt` matches none of the Build/Boot Gate's 18
# `paths:` patterns, and no other workflow covers Python at all. So a Python
# dependency bump in this repo was unfalsifiable by CI. #738 was admitted on a
# local CT102 resolver run that nothing in CI would ever reproduce.
#
# This does not build an image. It installs the resolved wheel artifacts inside
# a disposable container with `pip install --only-binary=:all: --report`, so
# resolver success and wheel availability are both path-relevant evidence.
#
# WHAT IT CANNOT CATCH — read this before trusting a green.
#   * A package that resolves but fails at import or runtime. Resolution is not
#     execution. Dockerfile.ml's own build is the check for that, and it needs
#     the deploy-root context (see #747 / #753).
#   * A version that resolves today and stops resolving tomorrow when an index
#     yanks a release. This is a point-in-time check, like every resolver check.
#   * Anything in `Dockerfile.soil-model`, which pip-installs inline with no
#     manifest file. Listed as a known gap below rather than silently skipped.
#
# Run locally exactly as CI does:
#   scripts/check-python-deps.sh
#   scripts/check-python-deps.sh --self-test-only

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --------------------------------------------------------------------------
# The map: manifest -> the Dockerfile that consumes it.
#
# The BASE IMAGE is deliberately NOT hard-coded here. It is read from the
# consumer Dockerfile's first FROM at run time, so a base-image bump moves this
# check with it automatically. Hard-coding the image is how `Lint Dockerfiles`
# ended up green on files it never opened (#741).
# --------------------------------------------------------------------------
MAP="
infra/tools/requirements-ml.txt|infra/docker/Dockerfile.ml
infra/monitoring/requirements-webhook.txt|infra/monitoring/Dockerfile.webhook-handler
"

# Hash-pinned lockfiles, installed with --require-hashes by their consumer.
LOCKMAP="
infra/monitoring/requirements-webhook.lock|infra/monitoring/Dockerfile.webhook-handler
"

# Manifests with NO container consumer. Each needs a stated reason; the
# coverage assertion below fails on anything not listed in one of the three.
declare -A EXCLUDED=(
  ["testnet/scripts/requirements-registration888.txt"]="owner-run CLI, no container consumer; registration888-kit.yml installs and exercises this manifest"
  ["infra/tools/pyproject.toml"]="uv project scaffold (name: repl-nix-workspace); no Dockerfile installs it"
  ["infra/tools/uv.lock"]="lockfile for the above scaffold; no Dockerfile installs it"
)

RC=0
note() { echo "$*"; }
fail() { echo "::error::$*"; RC=1; }

# --------------------------------------------------------------------------
# 0. COVERAGE ASSERTION — the anti-rot step.
#
# Every Python manifest in the tree must be mapped, locked, or explicitly
# excluded. A new requirements file added tomorrow fails this until someone
# decides which it is. This is the step that keeps the list from going stale
# the way #741's hard-coded trio did.
# --------------------------------------------------------------------------
coverage_check() {
  local discovered known f miss=0
  mapfile -t discovered < <(git ls-files \
    | grep -EI '(^|/)(requirements[^/]*\.(txt|lock)|constraints[^/]*\.txt|pyproject\.toml|uv\.lock|Pipfile)$' \
    | grep -v '^\.github/gate-fixtures/' | sort)

  [ "${#discovered[@]}" -gt 0 ] || { fail "0 Python manifests discovered — the discovery glob is broken"; return; }
  note "discovered ${#discovered[@]} Python manifest(s)"

  known="$(printf '%s\n%s\n' "$MAP" "$LOCKMAP" | awk -F'|' 'NF{print $1}')"
  for f in "${discovered[@]}"; do
    if grep -qxF "$f" <<<"$known"; then
      note "  covered   $f"
    elif [ -n "${EXCLUDED[$f]+x}" ]; then
      note "  excluded  $f — ${EXCLUDED[$f]}"
    else
      fail "unmapped Python manifest: $f — add it to MAP/LOCKMAP or to EXCLUDED with a reason"
      miss=1
    fi
  done
  [ "$miss" -eq 0 ] && note "coverage: OK"
}

# Read the first FROM of a Dockerfile, digest and all.
base_image_of() {
  local df="$1"
  grep -m1 -E '^[[:space:]]*FROM[[:space:]]' "$df" | awk '{print $2}'
}

# The probe. Returns pip's exit status verbatim.
# `rc` is captured immediately; nothing runs between the command and the read.
resolve_in() {
  local image="$1" reqfile="$2" extra="${3:-}" out rc
  # NO `-i`, and stdin closed: this runs inside a `while read` loop, and an
  # interactive container consumes the loop's stdin and silently eats the
  # remaining manifests. That bug skipped requirements-webhook.txt during
  # development while still reporting rc=0 — the exact false-green this gate
  # exists to prevent.
  out="$(docker run --rm \
          -v "$REPO_ROOT/$(dirname "$reqfile")":/req:ro \
          "$image" \
          pip install --no-cache-dir --only-binary=:all: --quiet --report /tmp/report.json \
            $extra -r "/req/$(basename "$reqfile")" 2>&1 < /dev/null)"
  rc=$?
  printf '%s\n' "$out" | tail -20
  return $rc
}

# --------------------------------------------------------------------------
# 1. RED CONTROL — proves the probe can fail, on every single run.
#
# A gate never observed failing is indistinguishable from a gate that cannot
# fail. Two controls, because they exercise different resolver paths:
#   (a) a package that does not exist  -> index lookup failure
#   (b) a genuinely unsatisfiable pin  -> dependency resolution failure
# If either RED control comes back green, the probe is broken and this script
# fails without even looking at the real manifests.
# --------------------------------------------------------------------------
red_control() {
  local image="$1" tmp rc ok=1
  tmp="$(mktemp -d)"

  printf 'wrfcoin-package-that-does-not-exist-r124==999.999.999\n' > "$tmp/requirements-red-a.txt"
  docker run --rm -v "$tmp":/req:ro "$image" \
    pip install --no-cache-dir --only-binary=:all: --quiet -r /req/requirements-red-a.txt >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "RED CONTROL (a) PASSED — a nonexistent package resolved. The probe cannot fail; treat every green from it as VOID."
    ok=0
  else
    note "RED control (a) nonexistent package  -> rc=$rc  (correctly RED)"
  fi

  printf 'urllib3<2\nurllib3>=2.7.0\n' > "$tmp/requirements-red-b.txt"
  docker run --rm -v "$tmp":/req:ro "$image" \
    pip install --no-cache-dir --only-binary=:all: --quiet -r /req/requirements-red-b.txt >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "RED CONTROL (b) PASSED — mutually exclusive pins resolved. The probe cannot fail; treat every green from it as VOID."
    ok=0
  else
    note "RED control (b) unsatisfiable pins   -> rc=$rc  (correctly RED)"
  fi

  rm -rf "$tmp"
  [ "$ok" -eq 1 ]
}

# --------------------------------------------------------------------------
main() {
  echo "=== 0. coverage ==="
  coverage_check

  # The RED control runs in the first mapped manifest's base image, so it is
  # exercising the same interpreter the real checks use.
  local first_df first_img
  first_df="$(awk -F'|' 'NF{print $2; exit}' <<<"$MAP")"
  first_img="$(base_image_of "$first_df")"

  echo
  echo "=== 1. RED control (base: $first_img) ==="
  if ! red_control "$first_img"; then
    echo "::error::RED control failed — not reporting any result from this run."
    return 1
  fi

  if [ "${1:-}" = "--self-test-only" ]; then
    echo "self-test only; stopping before the real manifests."
    return $RC
  fi

  echo
  echo "=== 2. resolve each mapped manifest ==="
  # Counted, not just iterated. If anything ever eats this loop's stdin again,
  # the tally below fails the run instead of quietly reporting a partial pass.
  local req df img rc
  local want_map got_map=0
  want_map="$(awk 'NF' <<<"$MAP" | wc -l)"
  while IFS='|' read -r req df; do
    got_map=$((got_map + 1))
    [ -n "$req" ] || continue
    [ -f "$req" ] || { fail "mapped manifest missing from the tree: $req"; continue; }
    [ -f "$df" ]  || { fail "consumer Dockerfile missing: $df (mapped from $req)"; continue; }
    img="$(base_image_of "$df")"
    [ -n "$img" ] || { fail "no FROM found in $df"; continue; }
    echo "--- $req  (base from $df: $img)"
    resolve_in "$img" "$req"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      note "    rc=0  RESOLVES"
    else
      fail "$req does NOT resolve against $img (rc=$rc)"
    fi
  done <<< "$(awk 'NF' <<<"$MAP")"
  [ "$got_map" -eq "$want_map" ] \
    || fail "resolved $got_map of $want_map mapped manifests — the loop was cut short, treat this run as VOID"

  echo
  echo "=== 3. hash-pinned lockfiles (--require-hashes) ==="
  local want_lock got_lock=0
  want_lock="$(awk 'NF' <<<"$LOCKMAP" | wc -l)"
  while IFS='|' read -r req df; do
    got_lock=$((got_lock + 1))
    [ -n "$req" ] || continue
    [ -f "$req" ] || { fail "mapped lockfile missing from the tree: $req"; continue; }
    img="$(base_image_of "$df")"
    echo "--- $req  (base from $df: $img)"
    resolve_in "$img" "$req" "--require-hashes"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      note "    rc=0  RESOLVES (hashes verified)"
    else
      fail "$req does NOT resolve with --require-hashes against $img (rc=$rc)"
    fi
  done <<< "$(awk 'NF' <<<"$LOCKMAP")"
  [ "$got_lock" -eq "$want_lock" ] \
    || fail "resolved $got_lock of $want_lock lockfiles — the loop was cut short, treat this run as VOID"

  echo
  echo "=== known gap ==="
  echo "infra/docker/Dockerfile.soil-model pip-installs inline with no manifest file;"
  echo "this gate does not cover it. Stated rather than silently skipped."

  return $RC
}

main "$@"
