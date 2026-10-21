#!/usr/bin/env bash
# Refs infra#1113: persistent npm tarballs, with no dependency lifecycle downloads.
# Node service probes currently have no packages with install scripts. A service
# needing one must add an explicit, reviewed build step rather than enable every
# dependency's postinstall on the metered runner.
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 || ! -f "$1/package-lock.json" ]]; then
  echo 'CI_NODE_INSTALL=FAIL expected a locked directory and optional --omit=dev' >&2
  exit 2
fi
args=()
if [[ $# -eq 2 ]]; then
  if [[ "$2" != --omit=dev ]]; then
    echo 'CI_NODE_INSTALL=FAIL only --omit=dev is accepted' >&2
    exit 2
  fi
  args+=(--omit=dev)
fi
cache="${WRFCOIN_CI_NPM_CACHE:-${HOME:?}/.npm}"
if [[ "$cache" != /* ]]; then
  echo 'CI_NODE_INSTALL=FAIL npm cache must be an absolute persistent path' >&2
  exit 2
fi
cd -- "$1"
exec npm ci --cache "$cache" --prefer-offline --ignore-scripts --no-audit --no-fund "${args[@]}"
