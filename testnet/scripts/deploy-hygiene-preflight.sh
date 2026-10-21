#!/usr/bin/env bash
# Preflight source check for local-build testnet deploys.
set -euo pipefail

ROOT="${WRFCOIN_ROOT:-${WRFCOIN_DEPLOY_ROOT:-/path/to/wrfcoin-deploy}}"
BRANCH="${DEPLOY_BRANCH:-main}"
REPOS=(infra backend core4 frontend)

usage() {
  cat <<USAGE
Usage: WRFCOIN_ROOT=/path/to/wrfcoin-deploy DEPLOY_BRANCH=main $0

Checks each critical repo before a local-build deploy:
  - repo exists
  - HEAD is attached
  - current branch matches DEPLOY_BRANCH
  - no tracked or untracked working tree changes
  - upstream is configured
  - local branch is not ahead or behind upstream

The script does not fetch or mutate repos. Run git fetch explicitly first when
you want a fresh upstream comparison.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

failures=0

check_repo() {
  local name="$1"
  local path="${ROOT}/${name}"
  local branch upstream counts ahead behind sha

  if [[ ! -d "${path}/.git" ]]; then
    echo "FAIL ${name}: missing git repo at ${path}"
    failures=$((failures + 1))
    return
  fi

  if ! branch="$(git -C "$path" symbolic-ref --quiet --short HEAD)"; then
    sha="$(git -C "$path" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "FAIL ${name}: detached HEAD at ${sha}"
    failures=$((failures + 1))
    return
  fi

  if [[ "$branch" != "$BRANCH" ]]; then
    echo "FAIL ${name}: on branch ${branch}, expected ${BRANCH}"
    failures=$((failures + 1))
  fi

  if [[ -n "$(git -C "$path" status --porcelain)" ]]; then
    echo "FAIL ${name}: working tree has local changes"
    failures=$((failures + 1))
  fi

  if ! upstream="$(git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
    echo "FAIL ${name}: no upstream configured for ${branch}"
    failures=$((failures + 1))
    return
  fi

  counts="$(git -C "$path" rev-list --left-right --count HEAD..."$upstream")"
  ahead="${counts%%[[:space:]]*}"
  behind="${counts##*[[:space:]]}"
  if [[ "$ahead" != "0" || "$behind" != "0" ]]; then
    echo "FAIL ${name}: ${branch} diverges from ${upstream} (ahead=${ahead}, behind=${behind})"
    failures=$((failures + 1))
  fi

  sha="$(git -C "$path" rev-parse --short HEAD)"
  echo "OK ${name}: ${branch} ${sha} matches ${upstream}"
}

echo "Deploy hygiene preflight root: ${ROOT}"
echo "Expected branch: ${BRANCH}"
for repo in "${REPOS[@]}"; do
  check_repo "$repo"
done

if [[ "$failures" -ne 0 ]]; then
  echo "Deploy hygiene preflight FAILED (${failures} issue(s))"
  exit 1
fi

echo "Deploy hygiene preflight passed"
