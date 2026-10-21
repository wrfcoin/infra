#!/usr/bin/env bash
# Source this before a testnet release compose build (infra#991, infra#1077):
#   export WRFCOIN_ROOT=<deploy-root>   # or the gate workspace $G
#   source "$WRFCOIN_ROOT/infra/testnet/scripts/export-build-provenance.sh"
#   bash "$WRFCOIN_ROOT/infra/testnet/scripts/check-build-root.sh" \
#     --service wrfcoin-backend ... -- <the compose global args of the build>
#   docker compose <the same compose global args> build ...
# It derives the OCI revision/created stamps from the build host's exact
# checkouts; callers must not hand-type release provenance. It is sourced into
# the caller's shell, so it deliberately does not change shell options
# (no `set -e`), and it exports nothing unless every checkout resolves to a
# full SHA with no uncommitted tracked changes. Stale values from an earlier
# run are cleared first, so a failed run cannot leave old stamps behind.
#
# The labelled root and the build context must be the same tree (infra#1077).
# compose builds from `context: ${WRFCOIN_ROOT:-<deploy-root>}`, so
# on success this helper EXPORTS WRFCOIN_ROOT as the root it labelled and
# records it as WRFCOIN_BUILD_ROOT for check-build-root.sh. The old prefix form
# `WRFCOIN_ROOT=$G source ...` left WRFCOIN_ROOT unexported, and compose then
# built the live checkouts under $G's labels. The helper now makes the prefix
# form safe too, but prefer the explicit `export`, and always run
# check-build-root.sh: an executed process sees only what is really exported.
#
# It also makes sure the root has the canonical workspace .dockerignore
# (infra/testnet/workspace.dockerignore): installed when missing, refused when a
# different one is present. prepare-release-gate-workspace.sh installs it at
# creation.

_wrfcoin_provenance() {
  local root="${WRFCOIN_ROOT:-${WRFCOIN_DEPLOY_ROOT:-/path/to/wrfcoin-deploy}}" repo sha created
  local -a names=(CORE4 BACKEND FRONTEND INFRA) repos=(core4 backend frontend infra) shas=()
  unset WRFCOIN_CORE4_BUILD_REVISION WRFCOIN_BACKEND_BUILD_REVISION \
    WRFCOIN_FRONTEND_BUILD_REVISION WRFCOIN_INFRA_BUILD_REVISION \
    WRFCOIN_STORAGE_PROVIDERS_BUILD_REVISION WRFCOIN_BUILD_CREATED WRFCOIN_BUILD_ROOT
  local given="$root"
  if ! root="$(realpath -e -- "$given" 2>/dev/null)" || [[ ! -d "$root" ]]; then
    echo "BUILD_PROVENANCE=FAIL WRFCOIN_ROOT $given is not a directory" >&2
    return 1
  fi
  # storage-providers (infra#944, the opt-in r20 storage-node build) is stamped only when it is
  # checked out under the root, so every other release is unaffected; once present it is held to the
  # same exact-head, no-uncommitted-changes standard as the rest.
  if [[ -e "$root/storage-providers" ]]; then
    names+=(STORAGE_PROVIDERS)
    repos+=(storage-providers)
  fi
  for repo in "${repos[@]}"; do
    sha="$(git -C "$root/$repo" rev-parse HEAD 2>/dev/null)"
    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "BUILD_PROVENANCE=FAIL $root/$repo did not resolve to a full lowercase SHA" >&2
      return 1
    fi
    # A modified tracked file means the build is not the commit it would be
    # labelled with. Untracked files (gitignored .env, build output) are fine.
    if [[ -n "$(git -C "$root/$repo" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
      echo "BUILD_PROVENANCE=FAIL $root/$repo has uncommitted tracked changes; its HEAD is not what would be built" >&2
      return 1
    fi
    shas+=("$sha")
  done

  # BuildKit reads <context>/.dockerignore. Without it the whole workspace
  # (other repos' target/, node_modules, .env files) enters the build context.
  local template="$root/infra/testnet/workspace.dockerignore" target="$root/.dockerignore"
  if [[ ! -f "$template" ]]; then
    echo "BUILD_PROVENANCE=FAIL $template is missing" >&2
    return 1
  fi
  if [[ -e "$target" || -L "$target" ]]; then
    if ! cmp -s -- "$template" "$target"; then
      echo "BUILD_PROVENANCE=FAIL $target differs from infra/testnet/workspace.dockerignore; replace it: install -m 0644 $template $target" >&2
      return 1
    fi
  elif ! install -m 0644 -- "$template" "$target"; then
    echo "BUILD_PROVENANCE=FAIL cannot install $target" >&2
    return 1
  fi

  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  local i
  for i in "${!names[@]}"; do
    export "WRFCOIN_${names[$i]}_BUILD_REVISION=${shas[$i]}"
  done
  export WRFCOIN_BUILD_CREATED="$created"
  # Under the prefix form WRFCOIN_ROOT lives in a temporary scope that bash
  # discards when `source` returns. Unsetting it from this function removes that
  # scope's copy (bash dynamic scoping), so the export below lands in the
  # caller's global scope and survives. check-build-root.sh verifies the result.
  unset WRFCOIN_ROOT
  export WRFCOIN_ROOT="$root"
  export WRFCOIN_BUILD_ROOT="$root"
  echo "BUILD_PROVENANCE=READY root=${root} created=${created} (WRFCOIN_ROOT exported; run check-build-root.sh before building)" >&2
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo 'BUILD_PROVENANCE=FAIL source this file; executing it cannot export into your shell' >&2
  exit 2
fi
_wrfcoin_provenance
