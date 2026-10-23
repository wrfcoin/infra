#!/usr/bin/env bash
# Decide the docs-sync gate's mode from the three PRODUCTION_* repository variables
# (.github/workflows/docs-sync-production-gateway-gate.yml; infra#27 review).
#
#   none set  -> "docs-sync" (the gateway probe has nothing to call; skipped loudly)
#   all set   -> "all"       (docs-sync and the production gateway probe)
#   some set  -> exit 2      (a partial configuration is a misconfiguration: the probe
#                             would silently not run although an operator set it up)
#
# The mode is the only thing on stdout; annotations go to stderr so a caller can
# capture the mode with $(...). Values are never printed. An unset repository
# variable reaches the job as an empty string, so empty and unset are the same here.
set -euo pipefail

names=(MAIN_API_BASE_URL MAIN_API_WS_URL COMPUTE_API_BASE_URL)
set_names=()
missing_names=()
for name in "${names[@]}"; do
  if [ -n "${!name:-}" ]; then set_names+=("$name"); else missing_names+=("$name"); fi
done

if [ "${#set_names[@]}" -eq 0 ]; then
  echo "::notice::PRODUCTION_* variables are not set; running docs-sync only, gateway check skipped" >&2
  echo "docs-sync"
elif [ "${#missing_names[@]}" -eq 0 ]; then
  echo "all"
else
  echo "::error title=Partial production gateway configuration::set: ${set_names[*]}; empty or unset: ${missing_names[*]}. Set all three PRODUCTION_* repository variables (PRODUCTION_MAIN_API_BASE_URL, PRODUCTION_MAIN_API_WS_URL, PRODUCTION_COMPUTE_API_BASE_URL) to run the gateway check, or none of them to skip it." >&2
  exit 2
fi
