#!/usr/bin/env bash
# GET-only public release freshness and viewer-route probe.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORIGIN=""
PINS="${ROOT}/testnet/release-pins.env"
JSON=0
TIMEOUT=8

usage() {
  echo 'usage: probe_public_build_freshness.sh --origin URL [--pins FILE] [--json]'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --origin) ORIGIN="${2%/}"; shift 2 ;;
    --pins) PINS="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "PUBLIC_BUILD_FRESHNESS=UNREACHABLE unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$ORIGIN" == http://* || "$ORIGIN" == https://* ]] || {
  echo 'PUBLIC_BUILD_FRESHNESS=UNREACHABLE --origin must be http(s)' >&2
  exit 2
}
[[ -r "$PINS" ]] || { echo "PUBLIC_BUILD_FRESHNESS=UNREACHABLE pins missing: $PINS" >&2; exit 2; }
MIN_DATE="$(sed -n 's/^WRFCOIN_RC_MIN_PUBLIC_BUILD_DATE=//p' "$PINS" | tail -n 1)"
[[ "$MIN_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || {
  echo 'PUBLIC_BUILD_FRESHNESS=UNREACHABLE minimum date is missing or malformed' >&2
  exit 2
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FINDINGS="$TMP/findings.txt"
: > "$FINDINGS"
CLASS=FRESH
ROOT_LAST_MODIFIED=""
ASSET_PATH=""
ASSET_LAST_MODIFIED=""
BACKEND_REVISION=""
BACKEND_CREATED=""

mark_stale() { [[ "$CLASS" == UNREACHABLE ]] || CLASS=STALE; printf '%s\n' "$*" >> "$FINDINGS"; }
mark_unreachable() { CLASS=UNREACHABLE; printf '%s\n' "$*" >> "$FINDINGS"; }

request() {
  local label="$1" path="$2"
  local headers="$TMP/${label}.headers" body="$TMP/${label}.body" code_file="$TMP/${label}.code"
  if ! curl -sS -m "$TIMEOUT" -D "$headers" -o "$body" -w '%{http_code}' \
      "${ORIGIN}${path}" > "$code_file"; then
    mark_unreachable "${path}: request failed"
    return 1
  fi
  return 0
}

header_value() {
  local file="$1" name="$2"
  awk -v key="$name" 'BEGIN{IGNORECASE=1} $0 ~ "^" key ":" {sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0} END{print value}' "$file"
}

date_is_fresh() {
  python3 - "$1" "$MIN_DATE" <<'PY'
import datetime
import email.utils
import sys
try:
    observed = email.utils.parsedate_to_datetime(sys.argv[1])
    if observed.tzinfo is None:
        observed = observed.replace(tzinfo=datetime.timezone.utc)
    minimum = datetime.datetime.fromisoformat(sys.argv[2]).replace(tzinfo=datetime.timezone.utc)
except (TypeError, ValueError):
    raise SystemExit(1)
raise SystemExit(0 if observed >= minimum else 1)
PY
}

if request root /; then
  ROOT_LAST_MODIFIED="$(header_value "$TMP/root.headers" Last-Modified)"
  [[ "$(cat "$TMP/root.code")" == 200 ]] || mark_stale "/: HTTP $(cat "$TMP/root.code")"
  if [[ -z "$ROOT_LAST_MODIFIED" ]] || ! date_is_fresh "$ROOT_LAST_MODIFIED"; then
    mark_stale "/: Last-Modified '${ROOT_LAST_MODIFIED:-missing}' predates ${MIN_DATE}"
  fi
  ASSET_PATH="$(grep -oE '/assets/index-[A-Za-z0-9._-]+\.js' "$TMP/root.body" | head -n 1 || true)"
  if [[ -z "$ASSET_PATH" ]]; then
    mark_stale '/: no /assets/index-*.js reference found'
  elif request asset "$ASSET_PATH"; then
    ASSET_LAST_MODIFIED="$(header_value "$TMP/asset.headers" Last-Modified)"
    [[ "$(cat "$TMP/asset.code")" == 200 ]] || mark_stale "${ASSET_PATH}: HTTP $(cat "$TMP/asset.code")"
    if [[ -z "$ASSET_LAST_MODIFIED" ]] || ! date_is_fresh "$ASSET_LAST_MODIFIED"; then
      mark_stale "${ASSET_PATH}: Last-Modified '${ASSET_LAST_MODIFIED:-missing}' predates ${MIN_DATE}"
    fi
  fi
fi

mapfile -t VIEWER_PATHS < <(
  awk '
    /^[[:space:]]*path \/api\/blockchain\/status/ { print "/api/blockchain/status" }
    /^[[:space:]]*path \/api\/blockchain\/blocks/ { print "/api/blockchain/blocks?limit=3" }
    /^[[:space:]]*path \/api\/weather\/coverage-zones/ { print "/api/weather/coverage-zones" }
  ' "${ROOT}/testnet/edge/public_onboarding.caddy" | sort -u
)
[[ ${#VIEWER_PATHS[@]} -eq 3 ]] || mark_stale "viewer route inventory expected 3, found ${#VIEWER_PATHS[@]}"
index=0
for path in "${VIEWER_PATHS[@]}"; do
  index=$((index + 1))
  if request "viewer-${index}" "$path"; then
    code="$(cat "$TMP/viewer-${index}.code")"
    body="$(tr -d '\r\n' < "$TMP/viewer-${index}.body")"
    if [[ "$code" == 404 && "$body" == 'Not found' ]]; then
      mark_stale "${path}: edge 404 Not found"
    elif [[ ! "$code" =~ ^2 ]]; then
      mark_stale "${path}: HTTP ${code}"
    fi
  fi
done

if request capabilities /api/capabilities; then
  code="$(cat "$TMP/capabilities.code")"
  [[ "$code" =~ ^2 ]] || mark_stale "/api/capabilities: HTTP ${code}"
fi

if request backend-build /api/build; then
  code="$(cat "$TMP/backend-build.code")"
  if [[ ! "$code" =~ ^2 ]]; then
    mark_stale "/api/build: HTTP ${code}"
  else
    build_result="$(python3 - "$TMP/backend-build.body" "$PINS" "$MIN_DATE" <<'PY'
import datetime, json, re, sys
try:
    body = json.load(open(sys.argv[1], encoding="utf-8"))
    pins = dict(line.strip().split("=", 1) for line in open(sys.argv[2], encoding="utf-8") if "=" in line and not line.lstrip().startswith("#"))
    revision = body["revision"]
    created = body["created"]
    observed = datetime.datetime.fromisoformat(created.replace("Z", "+00:00"))
    minimum = datetime.datetime.fromisoformat(sys.argv[3]).replace(tzinfo=datetime.timezone.utc)
    if not body.get("available") or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("invalid build response")
    if revision != pins["WRFCOIN_RC_BACKEND_COMMIT"]:
        print(f"STALE|{revision}|{created}|revision does not match release pin")
    elif observed < minimum:
        print(f"STALE|{revision}|{created}|creation timestamp predates minimum")
    else:
        print(f"FRESH|{revision}|{created}|")
except Exception as error:
    print(f"INVALID|||{error}")
PY
)"
    IFS='|' read -r build_class BACKEND_REVISION BACKEND_CREATED build_detail <<< "$build_result"
    [[ "$build_class" == FRESH ]] || mark_stale "/api/build: ${build_detail:-invalid build metadata}"
  fi
fi

if grep -Fq '/join/manifest.json' "${ROOT}/testnet/edge/public_onboarding.caddy"; then
  if request join /join/manifest.json; then
    join_code="$(cat "$TMP/join.code")"
    join_type="$(header_value "$TMP/join.headers" Content-Type)"
    [[ "$join_code" == 200 ]] || mark_stale "/join/manifest.json: HTTP ${join_code}"
    [[ "$join_type" == application/json* ]] || mark_stale "/join/manifest.json: Content-Type ${join_type:-missing}"
  fi
fi

if [[ $JSON -eq 1 ]]; then
  CLASS="$CLASS" ORIGIN="$ORIGIN" MIN_DATE="$MIN_DATE" ROOT_LM="$ROOT_LAST_MODIFIED" \
    ASSET_PATH="$ASSET_PATH" ASSET_LM="$ASSET_LAST_MODIFIED" BACKEND_REVISION="$BACKEND_REVISION" \
    BACKEND_CREATED="$BACKEND_CREATED" FINDINGS="$FINDINGS" python3 - <<'PY'
import json
import os
print(json.dumps({
    "classification": os.environ["CLASS"],
    "origin": os.environ["ORIGIN"],
    "minimum_build_date": os.environ["MIN_DATE"],
    "root_last_modified": os.environ["ROOT_LM"] or None,
    "asset_path": os.environ["ASSET_PATH"] or None,
    "asset_last_modified": os.environ["ASSET_LM"] or None,
    "backend_revision": os.environ["BACKEND_REVISION"] or None,
    "backend_created": os.environ["BACKEND_CREATED"] or None,
    "findings": [line.rstrip("\n") for line in open(os.environ["FINDINGS"], encoding="utf-8")],
}, sort_keys=True))
PY
else
  echo "PUBLIC_BUILD_FRESHNESS=${CLASS} origin=${ORIGIN} minimum=${MIN_DATE}"
  sed 's/^/  - /' "$FINDINGS"
fi

case "$CLASS" in
  FRESH) exit 0 ;;
  STALE) exit 1 ;;
  UNREACHABLE) exit 2 ;;
esac
