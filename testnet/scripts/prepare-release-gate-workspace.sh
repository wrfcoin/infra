#!/usr/bin/env bash
# Build a git gate workspace for render-release-manifest.sh on a host whose
# deployed trees are not git checkouts (infra#1047).
#
# CT101 deploys core4 and infra as plain `git archive` extractions
# (core4.releases/<sha>, infra.releases/<sha>), so `git rev-parse HEAD` fails
# there and the renderer's --workspace cannot point at them. This script makes a
# separate workspace of real checkouts, each at its pin and each with an
# origin/main ref, from explicit sources: a git bundle file (the host has no git
# credentials) or a local repository (CT101's backend/frontend checkouts).
#
#   prepare-release-gate-workspace.sh --out DIR --infra-commit SHA \
#     --source core4=/root/core4-rc.bundle --source infra=/root/infra-rc.bundle \
#     --source backend=<deploy-root>/backend \
#     --source frontend=<deploy-root>/frontend
#
# Infra is checked out at --infra-commit (the release-pins file cannot name its
# own commit); core4/backend/frontend are checked out at the pins that commit's
# testnet/release-pins.env names. Nothing is guessed: every checkout must be the
# exact pin, clean, and contained in the source's main branch, or the script
# fails and the workspace must be discarded.
#
# Why not `git clone <bundle>`: a bundle made with
# `git bundle create X origin/main` carries refs/remotes/origin/main only, and
# cloning it yields an EMPTY repository with no origin/main at all. This script
# fetches the bundle's main ref into refs/remotes/origin/main explicitly.
#
# To bind the deployed non-git trees to these checkouts, pass them to the
# renderer: --release-tree core4=<core4.releases/sha> --release-tree infra=<...>.
set -euo pipefail

OUT=""
INFRA_COMMIT=""
declare -A SOURCES=()
REPOS=(core4 backend frontend infra)

usage() { sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; }
fail() { echo "GATE_WORKSPACE=FAIL $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --infra-commit) INFRA_COMMIT="$2"; shift 2 ;;
    --source)
      name="${2%%=*}"; src="${2#*=}"
      [[ "$2" == *=* && -n "$src" ]] || fail "--source must be NAME=PATH: $2"
      case " ${REPOS[*]} " in *" $name "*) ;; *) fail "--source: unknown repository $name" ;; esac
      [[ -z "${SOURCES[$name]:-}" ]] || fail "--source $name given twice"
      SOURCES[$name]="$(realpath -m -- "$src")"
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done

[[ -n "$OUT" ]] || fail "--out is required"
[[ "$INFRA_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "--infra-commit must be a full lowercase 40-hex SHA"
for repo in "${REPOS[@]}"; do
  [[ -n "${SOURCES[$repo]:-}" ]] || fail "--source $repo=PATH is required"
  [[ -e "${SOURCES[$repo]}" ]] || fail "source for $repo does not exist: ${SOURCES[$repo]}"
done
if [[ -e "$OUT" ]] && [[ -n "$(ls -A -- "$OUT")" ]]; then
  fail "$OUT exists and is not empty; use a new directory"
fi
mkdir -p "$OUT"
OUT="$(realpath -- "$OUT")"

# main_ref SOURCE -> the single main ref the source offers.
main_ref() {
  local src="$1" refs
  if [[ -f "$src" ]]; then
    refs="$(git bundle list-heads "$src" 2>/dev/null | awk '{ print $2 }')" \
      || fail "$src is not a readable git bundle"
  elif git -C "$src" rev-parse --git-dir >/dev/null 2>&1; then
    refs="$(git -C "$src" for-each-ref --format='%(refname)' refs/remotes/origin/main refs/heads/main)"
  else
    fail "$src is neither a git bundle nor a git repository"
  fi
  if grep -qx 'refs/remotes/origin/main' <<<"$refs"; then
    echo refs/remotes/origin/main
  elif grep -qx 'refs/heads/main' <<<"$refs"; then
    echo refs/heads/main
  else
    fail "$src offers neither refs/remotes/origin/main nor refs/heads/main"
  fi
}

for repo in "${REPOS[@]}"; do
  src="${SOURCES[$repo]}"
  ref="$(main_ref "$src")"
  git init -q "$OUT/$repo"
  git -C "$OUT/$repo" fetch -q --no-tags "$src" "+${ref}:refs/remotes/origin/main" \
    || fail "cannot fetch $ref from $src into $repo"
done

git -C "$OUT/infra" checkout -q --detach "$INFRA_COMMIT" 2>/dev/null \
  || fail "infra commit $INFRA_COMMIT is not in the infra source's main branch"
PINS="$OUT/infra/testnet/release-pins.env"
[[ -f "$PINS" && -f "$OUT/infra/testnet/cut-pins.env" ]] \
  || fail "infra $INFRA_COMMIT has no testnet/release-pins.env and cut-pins.env"

pin_of() {
  local key="$1" value
  value="$(sed -n "s/^${key}=//p" "$PINS")"
  [[ "$(grep -c "^${key}=" "$PINS")" == 1 && "$value" =~ ^[0-9a-f]{40}$ ]] \
    || fail "$PINS must name exactly one full 40-hex $key"
  printf '%s' "$value"
}
# Separate assignments: a failing $(pin_of ...) inside `declare -A (...)` would
# not stop the script.
core4_pin="$(pin_of WRFCOIN_RC_CORE4_COMMIT)"
backend_pin="$(pin_of WRFCOIN_RC_BACKEND_COMMIT)"
frontend_pin="$(pin_of WRFCOIN_RC_FRONTEND_COMMIT)"
declare -A WANT=([core4]="$core4_pin" [backend]="$backend_pin" [frontend]="$frontend_pin" [infra]="$INFRA_COMMIT")

summary=()
for repo in "${REPOS[@]}"; do
  want="${WANT[$repo]}"
  if [[ "$repo" != infra ]]; then
    git -C "$OUT/$repo" checkout -q --detach "$want" 2>/dev/null \
      || fail "$repo pin $want is not in the $repo source's main branch"
  fi
  head="$(git -C "$OUT/$repo" rev-parse HEAD)"
  [[ "$head" == "$want" ]] || fail "$repo HEAD $head != $want"
  git -C "$OUT/$repo" merge-base --is-ancestor "$want" refs/remotes/origin/main \
    || fail "$repo $want is not contained in origin/main"
  [[ -z "$(git -C "$OUT/$repo" status --porcelain)" ]] || fail "$repo checkout is not clean"
  summary+=("$repo=$head")
done

# The workspace root is the compose build context (infra#1077). BuildKit reads
# <context>/.dockerignore; install the canonical one from the pinned infra.
install -m 0644 "$OUT/infra/testnet/workspace.dockerignore" "$OUT/.dockerignore" \
  || fail "cannot install $OUT/.dockerignore"

echo "GATE_WORKSPACE=READY dir=$OUT ${summary[*]}"
echo "  render with: bash $OUT/infra/testnet/scripts/render-release-manifest.sh --workspace $OUT --pins $PINS ..."
echo "  build with:  export WRFCOIN_ROOT=$OUT; source $OUT/infra/testnet/scripts/export-build-provenance.sh; bash $OUT/infra/testnet/scripts/check-build-root.sh --service ... -- <compose args>"
