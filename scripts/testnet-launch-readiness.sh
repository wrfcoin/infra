#!/usr/bin/env bash
# testnet-launch-readiness.sh — pre-launch readiness wrapper (infra#472)
#
# Chains all local readiness sub-checks in order:
#   1. check-testnet-secrets.sh    — guard configs/testnet/ from accidental commits
#   2. immutable runtime image and configured-versus-running identity
#   3. validate-readiness-report.js — validate CI-generated readiness-report.json
#   4. launch-critical-contract-gate.cjs — contract-suite gating checks
#   5. Tier 3 chain-liveness probe — fails closed on missing/stalled chain height
#   6. Tier 4 divergence gate      — fails closed on missing/nonzero divergence metric
#
# This is the one authoritative public-release verdict. It also emits JSON and
# Markdown evidence. Public-release mode has no silent skips; developer mode
# keeps iteration easy but labels every omission NON_RELEASE.
#
# Usage:
#   bash scripts/testnet-launch-readiness.sh --n5 FILE --desktop FILE --readiness-report FILE
#
# Flags:
#   --node-url     URL    Base URL of the node API  (default: http://localhost:8556)
#   --metrics-url  URL    URL of the /metrics endpoint (default: ${node-url}/metrics)
#   --skip-secrets        Skip the secrets check (e.g. in fresh worktrees — expected to fail)
#   --skip-runtime-image  Skip runtime-image proof (offline unit tests only)
#   --skip-report         Skip validate-readiness-report.js even if JSON is present
#   --skip-contracts      Skip launch-critical-contract-gate.cjs
#   --skip-full-profile   Developer-only skip for live functional probes
#   --profile MODE        public-release (default) or developer
#   --n5 FILE             N5 deploy-status snapshot
#   --desktop FILE        desktop deploy-status snapshot
#   --readiness-report FILE  CI readiness report (required in public-release)
#   --json-out FILE       final machine verdict (default: public-release-readiness.json)
#   --markdown-out FILE   final human verdict (default: public-release-readiness.md)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

NODE_URL="http://localhost:8556"
METRICS_URL=""
SKIP_SECRETS=false
SKIP_RUNTIME_IMAGE=false
SKIP_REPORT=false
SKIP_CONTRACTS=false
SKIP_FULL_PROFILE=false
PROFILE="public-release"
N5_SNAPSHOT=""
DESKTOP_SNAPSHOT=""
REPORT_JSON=""
JSON_OUT="public-release-readiness.json"
MARKDOWN_OUT="public-release-readiness.md"
LAST_HEIGHT_FILE="${WRFCOIN_LAST_HEIGHT_FILE:-/tmp/wrfcoin_last_height}"

require_flag_arg() {
  local flag_name="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    echo "Missing value for ${flag_name}" >&2
    echo "Run with --help for usage." >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node-url)
      require_flag_arg "--node-url" "${2:-}"
      NODE_URL="$2"
      shift 2
      ;;
    --metrics-url)
      require_flag_arg "--metrics-url" "${2:-}"
      METRICS_URL="$2"
      shift 2
      ;;
    --skip-secrets)  SKIP_SECRETS=true; shift ;;
    --skip-runtime-image) SKIP_RUNTIME_IMAGE=true; shift ;;
    --skip-report)   SKIP_REPORT=true; shift ;;
    --skip-contracts) SKIP_CONTRACTS=true; shift ;;
    --skip-full-profile) SKIP_FULL_PROFILE=true; shift ;;
    --profile)
      require_flag_arg "--profile" "${2:-}"
      PROFILE="$2"; shift 2 ;;
    --n5)
      require_flag_arg "--n5" "${2:-}"
      N5_SNAPSHOT="$2"; shift 2 ;;
    --desktop)
      require_flag_arg "--desktop" "${2:-}"
      DESKTOP_SNAPSHOT="$2"; shift 2 ;;
    --readiness-report)
      require_flag_arg "--readiness-report" "${2:-}"
      REPORT_JSON="$2"; shift 2 ;;
    --json-out)
      require_flag_arg "--json-out" "${2:-}"
      JSON_OUT="$2"; shift 2 ;;
    --markdown-out)
      require_flag_arg "--markdown-out" "${2:-}"
      MARKDOWN_OUT="$2"; shift 2 ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$METRICS_URL" ]] && METRICS_URL="${NODE_URL}/metrics"
case "$PROFILE" in
  public-release|developer) ;;
  *) echo "Invalid --profile: $PROFILE" >&2; exit 2 ;;
esac
if [[ "$PROFILE" == public-release ]] && { $SKIP_SECRETS || $SKIP_RUNTIME_IMAGE || $SKIP_REPORT || $SKIP_CONTRACTS || $SKIP_FULL_PROFILE; }; then
  echo "Public-release mode refuses --skip-* flags" >&2
  exit 2
fi
if [[ "$PROFILE" == public-release ]]; then
  for override in \
    WRFCOIN_SECRETS_GATE \
    WRFCOIN_READINESS_VALIDATOR \
    WRFCOIN_CONTRACT_GATE \
    WRFCOIN_PAIR_GATE \
    WRFCOIN_FULL_PROFILE_PROBE; do
    if [[ -v "$override" ]]; then
      echo "Public-release mode refuses gate override: $override" >&2
      exit 2
    fi
  done
fi

PASS=0
FAIL=0
WARN=0
FAILURES=()
RESULT_LOG="$(mktemp "${TMPDIR:-/tmp}/wrfcoin-release-results.XXXXXX")"
PAIR_REPORT="$(mktemp "${TMPDIR:-/tmp}/wrfcoin-pair-report.XXXXXX")"
trap 'rm -f "$RESULT_LOG" "$PAIR_REPORT"' EXIT

record() { printf '%s\t%s\n' "$1" "$2" >>"$RESULT_LOG"; }
pass()  { echo "[PASS] $1"; PASS=$((PASS+1)); record pass "$1"; }
fail()  { echo "[FAIL] $1"; FAIL=$((FAIL+1)); FAILURES+=("$1"); record fail "$1"; }
warn()  { echo "[WARN] $1"; WARN=$((WARN+1)); record warn "$1"; }
skip()  { echo "[SKIP] NON_RELEASE $1"; record non_release "$1"; }
header(){ echo; echo "=== $1 ==="; }

metric_value() {
  local payload="$1"
  local metric="$2"
  awk -v metric="$metric" '
    $1 == metric || index($1, metric "{") == 1 { print $2; exit }
  ' <<<"$payload"
}

# ---------------------------------------------------------------------------
# 1. Secrets check
# ---------------------------------------------------------------------------
header "1. Testnet secrets guard (infra#472)"
if $SKIP_SECRETS; then
  skip "secrets check (--skip-secrets)"
elif [[ ! -f "${WRFCOIN_SECRETS_GATE:-$SCRIPT_DIR/check-testnet-secrets.sh}" ]]; then
  fail "check-testnet-secrets.sh not found at $SCRIPT_DIR"
else
  if bash "${WRFCOIN_SECRETS_GATE:-$SCRIPT_DIR/check-testnet-secrets.sh}"; then
    pass "check-testnet-secrets.sh"
  else
    fail "check-testnet-secrets.sh — configs/testnet/ may contain secrets; check before deploy"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Immutable runtime image and running identity
# ---------------------------------------------------------------------------
header "2. Immutable runtime image"
RUNTIME_IMAGE_GATE="$REPO_ROOT/testnet/scripts/validate-runtime-image.sh"
RUNTIME_IMAGE="${WRFCOIN_TESTNET_RUNTIME_IMAGE:-}"
if [[ -z "$RUNTIME_IMAGE" && -f "$REPO_ROOT/testnet/.env" ]]; then
  RUNTIME_IMAGE="$(awk -F= '$1 == "WRFCOIN_TESTNET_RUNTIME_IMAGE" { sub(/^[^=]*=/, ""); print; exit }' "$REPO_ROOT/testnet/.env")"
fi
if $SKIP_RUNTIME_IMAGE; then
  skip "runtime-image proof (--skip-runtime-image)"
elif [[ ! -x "$RUNTIME_IMAGE_GATE" ]]; then
  fail "runtime-image validator missing or not executable at $RUNTIME_IMAGE_GATE"
elif "$RUNTIME_IMAGE_GATE" --profile public-release \
  --image "$RUNTIME_IMAGE" --check-running; then
  pass "immutable configured image matches all validator/seed/HSM-init containers"
else
  fail "runtime image is not immutable or configured/running identities differ"
fi

# ---------------------------------------------------------------------------
# 3. Readiness report validation
# ---------------------------------------------------------------------------
header "3. CI readiness report (infra#472)"
if $SKIP_REPORT; then
  skip "validate-readiness-report.js (--skip-report)"
elif [[ ! -f "${WRFCOIN_READINESS_VALIDATOR:-$SCRIPT_DIR/validate-readiness-report.js}" ]]; then
  fail "validate-readiness-report.js not found at $SCRIPT_DIR"
else
  if [[ -z "$REPORT_JSON" ]]; then
    if [[ "$PROFILE" == public-release ]]; then
      fail "readiness-report.json is required in public-release mode"
    else
      skip "readiness-report.json missing"
    fi
  elif [[ ! -f "$REPORT_JSON" ]]; then
    fail "readiness report not found: $REPORT_JSON"
  else
    if node "${WRFCOIN_READINESS_VALIDATOR:-$SCRIPT_DIR/validate-readiness-report.js}" "$REPORT_JSON"; then
      pass "validate-readiness-report.js ($REPORT_JSON)"
    else
      fail "validate-readiness-report.js — report validation failed for $REPORT_JSON"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4. Contract gate
# ---------------------------------------------------------------------------
header "4. Critical contract gate (infra#472)"
if $SKIP_CONTRACTS; then
  skip "launch-critical-contract-gate.cjs (--skip-contracts)"
elif [[ ! -f "${WRFCOIN_CONTRACT_GATE:-$SCRIPT_DIR/launch-critical-contract-gate.cjs}" ]]; then
  fail "launch-critical-contract-gate.cjs not found at $SCRIPT_DIR"
else
  if node "${WRFCOIN_CONTRACT_GATE:-$SCRIPT_DIR/launch-critical-contract-gate.cjs}" 2>&1; then
    pass "launch-critical-contract-gate.cjs"
  else
    EXIT=$?
    if [[ $EXIT -eq 2 ]]; then
      if [[ "$PROFILE" == public-release ]]; then
        fail "launch-critical-contract-gate.cjs — testnet stack unavailable in public-release mode"
      else
        skip "launch-critical-contract-gate.cjs — testnet stack not running"
      fi
    else
      fail "launch-critical-contract-gate.cjs — contract gate failed (exit $EXIT)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4. Paired-node, synthetic-policy, and outbound-alert evidence
# ---------------------------------------------------------------------------
header "4. Paired-node production evidence"
PAIR_GATE="${WRFCOIN_PAIR_GATE:-$REPO_ROOT/testnet/scripts/launch-readiness-gate.sh}"
if [[ -z "$N5_SNAPSHOT" || -z "$DESKTOP_SNAPSHOT" ]]; then
  if [[ "$PROFILE" == public-release ]]; then
    fail "both --n5 and --desktop snapshots are required in public-release mode"
  else
    skip "paired-node snapshots missing"
  fi
elif [[ ! -f "$N5_SNAPSHOT" || ! -f "$DESKTOP_SNAPSHOT" ]]; then
  fail "paired-node snapshot path is missing"
elif [[ ! -f "$PAIR_GATE" ]]; then
  fail "paired-node readiness gate missing: $PAIR_GATE"
elif bash "$PAIR_GATE" --n5 "$N5_SNAPSHOT" --desktop "$DESKTOP_SNAPSHOT" \
  --json-out "$PAIR_REPORT" >/dev/null; then
  if python3 - "$PAIR_REPORT" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
assert report.get("overall") == "pass"
production = report.get("production_evidence")
assert isinstance(production, dict)
assert production.get("synthetic_collector") == "disabled"
assert isinstance(production.get("real_contributions_observed"), int)
assert production["real_contributions_observed"] > 0
alerts = report.get("alert_delivery")
assert isinstance(alerts, dict) and alerts
for node in ("n5", "desktop"):
    evidence = alerts.get(node)
    assert isinstance(evidence, dict)
    assert evidence.get("outbound_forwarding") == "succeeded"
PY
  then
    pass "paired snapshots, real production, synthetic policy, and alert delivery"
  else
    fail "paired gate passed without complete synthetic/real/alert release evidence"
  fi
else
  fail "paired-node launch-readiness gate failed"
fi

# ---------------------------------------------------------------------------
# 5. Full-profile functional dependency evidence
# ---------------------------------------------------------------------------
header "5. Full-profile functional evidence"
FULL_PROBE="${WRFCOIN_FULL_PROFILE_PROBE:-$REPO_ROOT/testnet/scripts/full-profile-functional-probe.py}"
if [[ "$PROFILE" == developer && "$SKIP_FULL_PROFILE" == true ]]; then
  skip "full-profile functional evidence skipped by developer profile"
elif [[ ! -f "$FULL_PROBE" ]]; then
  fail "full-profile functional probe missing: $FULL_PROBE"
else
  FULL_FAILURES=0
  while IFS='|' read -r service base_url; do
    if output="$(python3 "$FULL_PROBE" --service "$service" --base-url "$base_url" 2>&1)"; then
      pass "full-profile ${service}: ${output}"
    else
      fail "full-profile ${service}: ${output}"
      FULL_FAILURES=$((FULL_FAILURES + 1))
    fi
  done <<'EOF'
cross-chain|http://127.0.0.1:3000
compute|http://127.0.0.1:6000
ml|http://127.0.0.1:6001
node-discovery|http://127.0.0.1:9005
EOF
fi

# ---------------------------------------------------------------------------
# 6. Tier 3 — Chain liveness probe
#    core4#1620 exports wrfcoin_chain_height. Treat missing metrics as a
#    fail-closed launch blocker rather than a warning.
# ---------------------------------------------------------------------------
header "6. Tier 3 — Chain liveness probe"
METRICS_PAYLOAD="$(curl -sf "$METRICS_URL" 2>/dev/null || true)"
if [[ -z "$METRICS_PAYLOAD" ]]; then
  fail "unable to fetch metrics from $METRICS_URL — cannot verify Tier 3 chain liveness"
else
  LAST_HEIGHT="$(metric_value "$METRICS_PAYLOAD" "wrfcoin_chain_height")"
  if [[ -z "$LAST_HEIGHT" ]]; then
    fail "wrfcoin_chain_height missing from metrics — cannot verify Tier 3 chain liveness"
  elif ! [[ "$LAST_HEIGHT" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    fail "Tier 3 chain-liveness metric is non-numeric: wrfcoin_chain_height=$LAST_HEIGHT"
  else
    PREV_HEIGHT="$(cat "$LAST_HEIGHT_FILE" 2>/dev/null || echo 0)"
    if ! [[ "$PREV_HEIGHT" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      PREV_HEIGHT=0
    fi
    printf '%s\n' "$LAST_HEIGHT" > "$LAST_HEIGHT_FILE"
    if awk -v curr="$LAST_HEIGHT" -v prev="$PREV_HEIGHT" 'BEGIN { exit !(curr > prev) }'; then
      pass "Tier 3 chain height advanced (${PREV_HEIGHT} -> ${LAST_HEIGHT})"
    else
      fail "Tier 3 chain stalled at h=${LAST_HEIGHT} (previous ${PREV_HEIGHT})"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 7. Tier 4 — Divergence gate
#    core4#1620 exports wrfcoin_state_divergence_total. Missing or nonzero
#    divergence is a fail-closed launch blocker.
# ---------------------------------------------------------------------------
header "7. Tier 4 — Divergence gate"
DIVERGENCE_TOTAL=""
if [[ -z "$METRICS_PAYLOAD" ]]; then
  fail "unable to fetch metrics from $METRICS_URL — cannot verify Tier 4 divergence"
else
  DIVERGENCE_TOTAL="$(metric_value "$METRICS_PAYLOAD" "wrfcoin_state_divergence_total")"
  if [[ -z "$DIVERGENCE_TOTAL" ]]; then
    fail "wrfcoin_state_divergence_total missing from metrics — cannot verify Tier 4 divergence"
  elif ! [[ "$DIVERGENCE_TOTAL" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    fail "Tier 4 divergence metric is non-numeric: wrfcoin_state_divergence_total=$DIVERGENCE_TOTAL"
  elif awk -v value="$DIVERGENCE_TOTAL" 'BEGIN { exit !(value == 0) }'; then
    pass "Tier 4 divergence metric clean (wrfcoin_state_divergence_total=0)"
  else
    fail "Tier 4 divergence detected: wrfcoin_state_divergence_total=${DIVERGENCE_TOTAL}"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
FINAL_CLASS="PUBLIC_RELEASE"
[[ "$PROFILE" == developer ]] && FINAL_CLASS="NON_RELEASE"
FINAL_RESULT="pass"
[[ $FAIL -gt 0 ]] && FINAL_RESULT="fail"
python3 - "$RESULT_LOG" "$JSON_OUT" "$MARKDOWN_OUT" "$PROFILE" "$FINAL_CLASS" "$FINAL_RESULT" <<'PY'
import datetime, json, pathlib, sys
log_path, json_path, markdown_path, profile, proof_class, overall = sys.argv[1:]
checks=[]
with open(log_path, encoding="utf-8") as handle:
    for line in handle:
        status, details = line.rstrip("\n").split("\t", 1)
        checks.append({"status": status, "details": details})
report={
    "schema":"wrfcoin.public_release_readiness.v1",
    "generated_at":datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "profile":profile,
    "proof_class":proof_class,
    "overall":overall,
    "checks":checks,
}
pathlib.Path(json_path).write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
lines=["# WRFCoin public-release readiness", "", f"Overall: **{overall.upper()}**", f"Profile: **{profile}**", f"Proof class: **{proof_class}**", "", "| Status | Evidence |", "|---|---|"]
for item in checks:
    details=item["details"].replace("|", "\\|")
    lines.append(f'| {item["status"]} | {details} |')
pathlib.Path(markdown_path).write_text("\n".join(lines)+"\n", encoding="utf-8")
PY

echo
echo "========================================"
echo "  Testnet launch-readiness summary"
echo "========================================"
echo "  PASS:  $PASS"
echo "  WARN:  $WARN  (WARN checks do NOT block launch)"
echo "  FAIL:  $FAIL"
echo "  PROFILE: $PROFILE ($FINAL_CLASS)"
echo "  JSON: $JSON_OUT"
echo "  MARKDOWN: $MARKDOWN_OUT"
if [[ $FAIL -gt 0 ]]; then
  echo
  echo "Failing checks:"
  for msg in "${FAILURES[@]}"; do
    echo "  • $msg"
  done
  echo
  echo "RESULT: NOT READY — fix the above before promoting testnet."
  exit 1
else
  echo
  echo "RESULT: PASS — all runnable checks passed. Review WARN items."
  exit 0
fi
