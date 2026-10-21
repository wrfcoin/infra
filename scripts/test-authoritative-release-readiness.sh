#!/usr/bin/env bash
set -euo pipefail

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/authoritative-release.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$REPO_ROOT/scripts/testnet-launch-readiness.sh"
mkdir -p "$ROOT/bin"

RUNTIME_IMAGE_ID=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
cat >"$ROOT/bin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${RUNTIME_IMAGE_ID:?}"
SH

cat >"$ROOT/bin/secrets.sh" <<'SH'
#!/usr/bin/env bash
[[ "${FAIL_SECRETS:-false}" != true ]]
SH
cat >"$ROOT/bin/validator.js" <<'JS'
process.exit(process.env.FAIL_REPORT === 'true' ? 1 : 0);
JS
cat >"$ROOT/bin/contracts.js" <<'JS'
process.exit(process.env.FAIL_CONTRACTS === 'true' ? 1 : 0);
JS
cat >"$ROOT/bin/pair.sh" <<'SH'
#!/usr/bin/env bash
[[ "${FAIL_PAIR:-false}" != true ]] || exit 1
out=''
while [[ $# -gt 0 ]]; do
  [[ "$1" == --json-out ]] && { out="$2"; shift 2; continue; }
  shift
done
case "${PAIR_MODE:-complete}" in
  complete) production='{"synthetic_collector":"disabled","real_contributions_observed":2}'; alerts='{"n5":{"outbound_forwarding":"succeeded"},"desktop":{"outbound_forwarding":"succeeded"}}' ;;
  missing-synthetic) production='{}'; alerts='{"n5":{"outbound_forwarding":"succeeded"},"desktop":{"outbound_forwarding":"succeeded"}}' ;;
  missing-alert) production='{"synthetic_collector":"disabled","real_contributions_observed":2}'; alerts='{}' ;;
  synthetic-enabled) production='{"synthetic_collector":"enabled","real_contributions_observed":2}'; alerts='{"n5":{"outbound_forwarding":"succeeded"},"desktop":{"outbound_forwarding":"succeeded"}}' ;;
  zero-real) production='{"synthetic_collector":"disabled","real_contributions_observed":0}'; alerts='{"n5":{"outbound_forwarding":"succeeded"},"desktop":{"outbound_forwarding":"succeeded"}}' ;;
  failed-alert) production='{"synthetic_collector":"disabled","real_contributions_observed":2}'; alerts='{"n5":{"outbound_forwarding":"failed"},"desktop":{"outbound_forwarding":"succeeded"}}' ;;
esac
printf '{"overall":"pass","production_evidence":%s,"alert_delivery":%s}\n' "$production" "$alerts" >"$out"
SH
cat >"$ROOT/bin/full.py" <<'PY'
import os,sys
service=sys.argv[sys.argv.index('--service')+1]
if os.environ.get('FAIL_FULL') == service: raise SystemExit(1)
print('FUNCTIONAL live_dependency_probe')
PY
chmod +x "$ROOT/bin/secrets.sh" "$ROOT/bin/pair.sh" "$ROOT/bin/full.py"
chmod +x "$ROOT/bin/docker"

cat >"$ROOT/metrics" <<'EOF'
wrfcoin_chain_height 42
wrfcoin_state_divergence_total 0
EOF
printf '{}\n' >"$ROOT/n5.json"
printf '{}\n' >"$ROOT/desktop.json"
printf '{}\n' >"$ROOT/readiness.json"

run_gate() {
  local label="$1"; shift
  WRFCOIN_SECRETS_GATE="$ROOT/bin/secrets.sh" \
  WRFCOIN_READINESS_VALIDATOR="$ROOT/bin/validator.js" \
  WRFCOIN_CONTRACT_GATE="$ROOT/bin/contracts.js" \
  WRFCOIN_PAIR_GATE="$ROOT/bin/pair.sh" \
  WRFCOIN_FULL_PROFILE_PROBE="$ROOT/bin/full.py" \
  WRFCOIN_LAST_HEIGHT_FILE="$ROOT/$label.height" \
  WRFCOIN_TESTNET_RUNTIME_IMAGE="$RUNTIME_IMAGE_ID" \
  RUNTIME_IMAGE_ID="$RUNTIME_IMAGE_ID" \
  PATH="$ROOT/bin:$PATH" \
    "$@" bash "$GATE" \
      --n5 "$ROOT/n5.json" --desktop "$ROOT/desktop.json" \
      --readiness-report "$ROOT/readiness.json" \
      --metrics-url "file://$ROOT/metrics" \
      --profile developer \
      --json-out "$ROOT/$label.json" --markdown-out "$ROOT/$label.md" \
      >"$ROOT/$label.out" 2>&1
}

run_gate green env
python3 - "$ROOT/green.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1],encoding='utf-8'))
assert r['overall']=='pass' and r['proof_class']=='NON_RELEASE'
PY
grep -q 'Overall: \*\*PASS\*\*' "$ROOT/green.md"

for case in secrets report contracts pair full synthetic alert synthetic-enabled zero-real failed-alert; do
  args=(env)
  case "$case" in
    secrets) args+=(FAIL_SECRETS=true) ;;
    report) args+=(FAIL_REPORT=true) ;;
    contracts) args+=(FAIL_CONTRACTS=true) ;;
    pair) args+=(FAIL_PAIR=true) ;;
    full) args+=(FAIL_FULL=compute) ;;
    synthetic) args+=(PAIR_MODE=missing-synthetic) ;;
    alert) args+=(PAIR_MODE=missing-alert) ;;
    synthetic-enabled) args+=(PAIR_MODE=synthetic-enabled) ;;
    zero-real) args+=(PAIR_MODE=zero-real) ;;
    failed-alert) args+=(PAIR_MODE=failed-alert) ;;
  esac
  if run_gate "$case" "${args[@]}"; then
    echo "FAIL: subordinate mutation '$case' produced top-level PASS" >&2
    exit 1
  fi
  python3 - "$ROOT/$case.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1],encoding='utf-8'))['overall']=='fail'
PY
done

mkdir -p "$ROOT/repo/scripts" "$ROOT/repo/testnet/scripts"
cp "$GATE" "$ROOT/repo/scripts/testnet-launch-readiness.sh"
cp "$REPO_ROOT/testnet/scripts/validate-runtime-image.sh" "$ROOT/repo/testnet/scripts/validate-runtime-image.sh"
cp "$ROOT/bin/secrets.sh" "$ROOT/repo/scripts/check-testnet-secrets.sh"
cp "$ROOT/bin/validator.js" "$ROOT/repo/scripts/validate-readiness-report.js"
cp "$ROOT/bin/contracts.js" "$ROOT/repo/scripts/launch-critical-contract-gate.cjs"
cp "$ROOT/bin/pair.sh" "$ROOT/repo/testnet/scripts/launch-readiness-gate.sh"
cp "$ROOT/bin/full.py" "$ROOT/repo/testnet/scripts/full-profile-functional-probe.py"
chmod +x "$ROOT/repo/scripts/check-testnet-secrets.sh" \
  "$ROOT/repo/testnet/scripts/launch-readiness-gate.sh" \
  "$ROOT/repo/testnet/scripts/full-profile-functional-probe.py"
WRFCOIN_LAST_HEIGHT_FILE="$ROOT/public.height" \
  WRFCOIN_TESTNET_RUNTIME_IMAGE="$RUNTIME_IMAGE_ID" RUNTIME_IMAGE_ID="$RUNTIME_IMAGE_ID" PATH="$ROOT/bin:$PATH" \
  bash "$ROOT/repo/scripts/testnet-launch-readiness.sh" \
    --n5 "$ROOT/n5.json" --desktop "$ROOT/desktop.json" \
    --readiness-report "$ROOT/readiness.json" \
    --metrics-url "file://$ROOT/metrics" \
    --json-out "$ROOT/public.json" --markdown-out "$ROOT/public.md" \
    >"$ROOT/public.out" 2>&1
python3 - "$ROOT/public.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1],encoding='utf-8'))
assert r['overall']=='pass' and r['proof_class']=='PUBLIC_RELEASE'
assert not any(c['status']=='non_release' for c in r['checks'])
PY

for override in \
  WRFCOIN_SECRETS_GATE \
  WRFCOIN_READINESS_VALIDATOR \
  WRFCOIN_CONTRACT_GATE \
  WRFCOIN_PAIR_GATE \
  WRFCOIN_FULL_PROFILE_PROBE; do
  if env "$override=$ROOT/bin/secrets.sh" bash "$GATE" >"$ROOT/$override.out" 2>&1; then
    echo "FAIL: public-release accepted $override" >&2
    exit 1
  fi
  grep -q "Public-release mode refuses gate override: $override" "$ROOT/$override.out"
done

if bash "$GATE" --profile public-release --skip-report >/dev/null 2>&1; then
  echo 'FAIL: public-release accepted a skip flag' >&2
  exit 1
fi

if WRFCOIN_LAST_HEIGHT_FILE="$ROOT/missing.height" \
  bash "$ROOT/repo/scripts/testnet-launch-readiness.sh" --metrics-url "file://$ROOT/metrics" \
    --json-out "$ROOT/missing.json" --markdown-out "$ROOT/missing.md" \
    >"$ROOT/missing.out" 2>&1; then
  echo 'FAIL: public-release accepted missing report and pair snapshots' >&2
  exit 1
fi
grep -q 'readiness-report.json is required' "$ROOT/missing.out"
grep -q 'both --n5 and --desktop snapshots are required' "$ROOT/missing.out"

mv "$ROOT/repo/testnet/scripts/full-profile-functional-probe.py" \
  "$ROOT/repo/testnet/scripts/full-profile-functional-probe.py.off"
if WRFCOIN_LAST_HEIGHT_FILE="$ROOT/missing-full.height" \
  bash "$ROOT/repo/scripts/testnet-launch-readiness.sh" --n5 "$ROOT/n5.json" --desktop "$ROOT/desktop.json" \
    --readiness-report "$ROOT/readiness.json" --metrics-url "file://$ROOT/metrics" \
    --json-out "$ROOT/missing-full.json" --markdown-out "$ROOT/missing-full.md" \
    >"$ROOT/missing-full.out" 2>&1; then
  echo 'FAIL: public-release accepted missing full-profile evidence generator' >&2
  exit 1
fi
grep -q 'full-profile functional probe missing' "$ROOT/missing-full.out"
mv "$ROOT/repo/testnet/scripts/full-profile-functional-probe.py.off" \
  "$ROOT/repo/testnet/scripts/full-profile-functional-probe.py"

WRFCOIN_LAST_HEIGHT_FILE="$ROOT/dev.height" \
  WRFCOIN_TESTNET_RUNTIME_IMAGE=wrfcoin/native-chain:testnet-local \
  bash "$GATE" --profile developer --skip-secrets --skip-runtime-image --skip-report --skip-contracts --skip-full-profile \
    --metrics-url "file://$ROOT/metrics" --json-out "$ROOT/dev.json" --markdown-out "$ROOT/dev.md" \
    >/dev/null
grep -q '"proof_class": "NON_RELEASE"' "$ROOT/dev.json"
grep -q '"status": "non_release"' "$ROOT/dev.json"

echo 'PASS: authoritative release command aggregates every gate and labels developer skips NON_RELEASE'
