#!/usr/bin/env bash
# CI runs every scripts/tests/test-*.sh bare, so test-esbuild-entries-exist.sh's
# --self-test mutations (missing entry, orphan dist command, dangling backend
# source in any tracked compose file, a shell-string command, compose merge
# tags) would otherwise never execute. This suite runs them.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "${ROOT}/scripts/tests/test-esbuild-entries-exist.sh" --self-test
