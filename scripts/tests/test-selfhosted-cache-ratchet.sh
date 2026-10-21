#!/usr/bin/env bash
# infra#1113: no GitHub cache restore on a self-hosted (CT102) job. Real workflows
# must pass; each synthetic leak shape must fail; hosted/local caches must pass.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/scripts/check-selfhosted-cache.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "SELFHOSTED_CACHE=FAIL $*" >&2; exit 1; }

python3 "$CHECK" >"$T/real.out" 2>&1 || { cat "$T/real.out" >&2; fail "real workflows leak a cache onto a self-hosted job"; }
echo "ok real workflows clean"

wf() { # NAME RUNS-ON STEP-YAML
  mkdir -p "$T/$1"; printf 'on: push\njobs:\n  j:\n    runs-on: %s\n    steps:\n%s\n' "$2" "$3" > "$T/$1/w.yml"; }
leak() { wf "$1" "$2" "$3"; python3 "$CHECK" "$T/$1" >/dev/null 2>&1 && fail "$1: leak accepted"; echo "ok RED $1"; }
clean() { wf "$1" "$2" "$3"; python3 "$CHECK" "$T/$1" >/dev/null 2>&1 || fail "$1: clean case rejected"; echo "ok GREEN $1"; }

SH='[self-hosted, n5pro]'
CACHE='      - uses: actions/cache@v6
        with: {path: x, key: k}'
# raw YAML job fragment: NAME "STRATEGY+RUNS-ON LINES" STEPS
wfm() { mkdir -p "$T/$1"; printf 'on: push\njobs:\n  j:\n%s\n    steps:\n%s\n' "$2" "$3" > "$T/$1/w.yml"; }
leakm() { wfm "$1" "$2" "$3"; python3 -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" "$T/$1/w.yml" || fail "$1: fixture is not valid YAML (RED would be vacuous)"; python3 "$CHECK" "$T/$1" >/dev/null 2>&1 && fail "$1: leak accepted"; echo "ok RED $1"; }
cleanm() { wfm "$1" "$2" "$3"; python3 "$CHECK" "$T/$1" >/dev/null 2>&1 || fail "$1: clean case rejected"; echo "ok GREEN $1"; }
leak actions-cache "$SH" '      - uses: actions/cache@v6
        with: {path: x, key: k}'
leak actions-cache-restore "$SH" '      - uses: actions/cache/restore@v6
        with: {path: x, key: k}'
leak setup-node-cache "$SH" '      - uses: actions/setup-node@v7
        with: {node-version: 22, cache: npm}'
leak setup-python-cache "$SH" '      - uses: actions/setup-python@v6
        with: {python-version: "3.12", cache: pip}'
leak buildx-gha "$SH" '      - uses: docker/build-push-action@v6
        with: {cache-from: "type=gha", cache-to: "type=gha,mode=max"}'
leak selfhosted-string "self-hosted" '      - uses: actions/cache@v6
        with: {path: x, key: k}'
clean hosted-cache ubuntu-latest '      - uses: actions/cache@v6
        with: {path: x, key: k}'
clean selfhosted-setup-node-no-cache "$SH" '      - uses: actions/setup-node@v7
        with: {node-version: 22}'
clean selfhosted-local-buildx "$SH" '      - uses: docker/build-push-action@v6
        with: {cache-from: "type=local,src=/tmp/c", cache-to: "type=local,dest=/tmp/c2"}'
# infra#1142 review: matrix / unresolved runners and per-entry buildx cache judgement
leakm matrix-self-hosted '    strategy: {matrix: {runner: [ubuntu-latest, self-hosted]}}
    runs-on: ${{ matrix.runner }}' "$CACHE"
leakm matrix-include-self-hosted '    strategy: {matrix: {include: [{runner: ubuntu-latest}, {runner: [self-hosted, n5pro]}]}}
    runs-on: ${{ matrix.runner }}' "$CACHE"
leakm matrix-label-array '    strategy: {matrix: {runner: [ubuntu-latest, [self-hosted, linux]]}}
    runs-on: ${{ matrix.runner }}' "$CACHE"
leakm unresolved-expression '    runs-on: ${{ inputs.runner }}' "$CACHE"
leakm unresolved-matrix-expression '    strategy: {matrix: {runner: "${{ fromJSON(vars.RUNNERS) }}"}}
    runs-on: ${{ matrix.runner }}' "$CACHE"
leakm group-only '    runs-on: {group: ci-pool}' "$CACHE"
leakm buildx-mixed-local-then-gha "    runs-on: [self-hosted, linux]" '      - uses: docker/build-push-action@v6
        with:
          cache-from: |
            type=local,src=/tmp/c
            type=gha'
leakm buildx-mixed-local-then-registry "    runs-on: [self-hosted, linux]" '      - uses: docker/build-push-action@v6
        with:
          cache-to: |
            type=local,dest=/tmp/c
            ghcr.io/o/r:buildcache'
leakm buildx-registry-ref-only "    runs-on: [self-hosted, linux]" '      - uses: docker/build-push-action@v6
        with: {cache-from: "ghcr.io/o/r:buildcache"}'
cleanm matrix-hosted-only '    strategy: {matrix: {runner: [ubuntu-latest, ubuntu-24.04]}}
    runs-on: ${{ matrix.runner }}' "$CACHE"
cleanm matrix-include-hosted-only '    strategy: {matrix: {include: [{runner: ubuntu-latest}, {runner: macos-14}]}}
    runs-on: ${{ matrix.runner }}' "$CACHE"
cleanm buildx-all-local-multiline "    runs-on: [self-hosted, linux]" '      - uses: docker/build-push-action@v6
        with:
          cache-from: |
            type=local,src=/tmp/a
            type=local,src=/tmp/b
          cache-to: type=inline'
# infra#1142 review 2: literal labels are not proof of a hosted runner
leakm group-with-labels '    runs-on: {group: ci-pool, labels: linux}' "$CACHE"
leakm group-with-hosted-label '    runs-on: {group: ci-pool, labels: ubuntu-latest}' "$CACHE"
leakm custom-label-only '    runs-on: [linux, x64, n5pro]' "$CACHE"
leakm custom-label-string '    runs-on: n5pro' "$CACHE"
leakm matrix-custom-label '    strategy: {matrix: {runner: [ubuntu-latest, n5pro]}}
    runs-on: ${{ matrix.runner }}' "$CACHE"
leakm matrix-label-array-custom '    strategy: {matrix: {runner: [ubuntu-latest, [linux, x64]]}}
    runs-on: ${{ matrix.runner }}' "$CACHE"
# infra#1142 review 3: a hosted-looking prefix is not proof (custom label on a self-hosted runner)
leakm prefixed-custom-ubuntu '    runs-on: ubuntu-ct102' "$CACHE"
leakm prefixed-custom-windows '    runs-on: [windows-metered]' "$CACHE"
leakm prefixed-custom-macos '    runs-on: macos-local' "$CACHE"
leakm prefixed-custom-larger-runner '    runs-on: ubuntu-latest-8-cores' "$CACHE"
leakm matrix-prefixed-custom '    strategy: {matrix: {runner: [ubuntu-24.04, ubuntu-ct102]}}
    runs-on: ${{ matrix.runner }}' "$CACHE"
leakm matrix-include-prefixed-custom '    strategy: {matrix: {include: [{runner: macos-14}, {runner: windows-metered}]}}
    runs-on: ${{ matrix.runner }}' "$CACHE"
cleanm hosted-label-array '    runs-on: [ubuntu-24.04]' "$CACHE"
cleanm hosted-arm-and-windows-matrix '    strategy: {matrix: {runner: [ubuntu-24.04-arm, windows-2022, macos-14]}}
    runs-on: ${{ matrix.runner }}' "$CACHE"
cleanm custom-label-without-cache '    runs-on: [linux, x64, n5pro]' '      - run: echo hi'
cleanm unresolved-runner-without-cache '    runs-on: ${{ inputs.runner }}' '      - run: echo hi'
# Exact runtime guards disable the step/cache on every self-hosted runner;
# a substring, OR, reversed condition or nonempty fallback does not prove that.
clean guarded-step "$SH" "      - uses: actions/cache@v6
        if: runner.environment != 'self-hosted'
        with: {path: x, key: k}"
clean guarded-node "$SH" '      - uses: actions/setup-node@v4
        with:
          cache: ${{ runner.environment != '\''self-hosted'\'' && '\''npm'\'' || '\'''\'' }}'
clean wrapped-step "$SH" '      - uses: actions/cache/restore@v6
        if: ${{ runner.environment != '\''self-hosted'\'' }}
        with: {path: x, key: k}'
leak guard-or-true "$SH" "      - uses: actions/cache@v6
        if: runner.environment != 'self-hosted' || true
        with: {path: x, key: k}"
leak guard-reversed "$SH" "      - uses: actions/cache@v6
        if: runner.environment == 'self-hosted'
        with: {path: x, key: k}"
leak guard-comment "$SH" "      - uses: actions/cache@v6
        name: runner.environment != 'self-hosted'
        with: {path: x, key: k}"
leak node-nonempty-fallback "$SH" '      - uses: actions/setup-node@v4
        with:
          cache: ${{ runner.environment != '\''self-hosted'\'' && '\''npm'\'' || '\''npm'\'' }}'
leak non-node-expression "$SH" '      - uses: actions/setup-python@v6
        with:
          cache: ${{ runner.environment != '\''self-hosted'\'' && '\''npm'\'' || '\'''\'' }}'
# infra#1237: cache-restoring families found in the org's workflow inventory.
# The action defaults matter; save-if and cache-targets do not disable restore.
leakm rust-cache-default "    runs-on: $SH" '      - uses: Swatinem/rust-cache@v2'
leakm rust-cache-save-disabled "    runs-on: $SH" '      - uses: Swatinem/rust-cache@v2
        with: {save-if: false}'
leakm rust-cache-targets-disabled "    runs-on: $SH" '      - uses: Swatinem/rust-cache@v2
        with: {cache-targets: false}'
# Conservatively flag lookup-only/provider changes, as direct actions/cache is.
leakm rust-cache-lookup-only "    runs-on: $SH" '      - uses: Swatinem/rust-cache@v2
        with: {lookup-only: true}'
leakm rust-cache-other-provider "    runs-on: $SH" '      - uses: Swatinem/rust-cache@v2
        with: {cache-provider: warpbuild}'
leakm ruby-bundler-cache "    runs-on: $SH" '      - uses: ruby/setup-ruby@v1
        with: {bundler-cache: true}'
cleanm ruby-default "    runs-on: $SH" '      - uses: ruby/setup-ruby@v1'
cleanm ruby-disabled "    runs-on: $SH" '      - uses: ruby/setup-ruby@v1
        with: {bundler-cache: "false"}'
leakm flutter-sdk "    runs-on: $SH" '      - uses: subosito/flutter-action@v2
        with: {cache: true}'
leakm flutter-pub-only "    runs-on: $SH" '      - uses: subosito/flutter-action@v2
        with: {cache: false, pub-cache: true}'
cleanm flutter-default "    runs-on: $SH" '      - uses: subosito/flutter-action@v2'
cleanm flutter-disabled "    runs-on: $SH" '      - uses: subosito/flutter-action@v2
        with: {cache: "false", pub-cache: false}'
leakm trivy-default "    runs-on: $SH" '      - uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25'
leakm trivy-explicit "    runs-on: $SH" '      - uses: aquasecurity/trivy-action@v0.36.0
        with: {cache: true}'
cleanm trivy-disabled "    runs-on: $SH" '      - uses: aquasecurity/trivy-action@v0.36.0
        with: {cache: false}'
leakm buildx-binary-default "    runs-on: $SH" '      - uses: docker/setup-buildx-action@v4'
leakm buildx-binary-explicit "    runs-on: $SH" '      - uses: docker/setup-buildx-action@v4
        with: {cache-binary: true}'
cleanm buildx-binary-disabled "    runs-on: $SH" '      - uses: docker/setup-buildx-action@v4
        with: {cache-binary: "false"}'
# Use real workflow YAML, not cache_reason directly: classification and CLI both run.
for family in rust ruby flutter trivy buildx; do
  case "$family" in
    rust) action=Swatinem/rust-cache@v2; inputs='{}' ;;
    ruby) action=ruby/setup-ruby@v1; inputs='{bundler-cache: true}' ;;
    flutter) action=subosito/flutter-action@v2; inputs='{cache: true}' ;;
    trivy) action=aquasecurity/trivy-action@v0.36.0; inputs='{}' ;;
    buildx) action=docker/setup-buildx-action@v4; inputs='{}' ;;
  esac
  step="      - uses: $action
        with: $inputs"
  cleanm "$family-hosted" '    runs-on: ubuntu-latest' "$step"
  cleanm "$family-exact-guard" "    runs-on: $SH" "$step
        if: runner.environment != 'self-hosted'"
  cleanm "$family-wrapped-guard" "    runs-on: $SH" "$step
        if: \${{ runner.environment != 'self-hosted' }}"
  leakm "$family-or-true" "    runs-on: $SH" "$step
        if: runner.environment != 'self-hosted' || true"
  leakm "$family-custom-label" '    runs-on: ubuntu-ct102' "$step"
done
leakm ruby-cache-expression "    runs-on: $SH" '      - uses: ruby/setup-ruby@v1
        with: {bundler-cache: "${{ inputs.cache }}"}'
leakm flutter-pub-expression "    runs-on: $SH" '      - uses: subosito/flutter-action@v2
        with: {cache: false, pub-cache: "${{ inputs.cache }}"}'
leakm trivy-cache-expression "    runs-on: $SH" '      - uses: aquasecurity/trivy-action@v0.36.0
        with: {cache: "${{ inputs.cache }}"}'
leakm buildx-binary-expression "    runs-on: $SH" '      - uses: docker/setup-buildx-action@v4
        with: {cache-binary: "${{ inputs.cache }}"}'
cleanm local-tool-cache "    runs-on: $SH" '      - uses: jwlawson/actions-setup-cmake@v2'
echo "SELFHOSTED_CACHE=PASS"
