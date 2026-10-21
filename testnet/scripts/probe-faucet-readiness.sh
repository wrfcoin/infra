#!/usr/bin/env bash
set -euo pipefail

URL=""
JSON=false
PUBLIC_RELEASE=false
PROXY_VERIFIED=false

usage() {
  echo "Usage: $0 --url URL [--json] [--public-release] [--onboarding-proxy-verified]" >&2
}

while (($#)); do
  case "$1" in
    --url) URL="${2:-}"; shift 2 ;;
    --json) JSON=true; shift ;;
    --public-release) PUBLIC_RELEASE=true; shift ;;
    --onboarding-proxy-verified) PROXY_VERIFIED=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if [[ -z "$URL" ]]; then
  usage
  exit 2
fi

HEALTH_URL="${URL%/}/health"
BODY="$(mktemp "${TMPDIR:-/tmp}/faucet-readiness.XXXXXX.json")"
trap 'rm -f "$BODY"' EXIT

if ! curl --fail --silent --show-error --max-time 10 "$HEALTH_URL" -o "$BODY"; then
  if $JSON; then
    printf '{"classification":"UNREACHABLE","passing":false}\n'
  else
    echo "UNREACHABLE"
  fi
  exit 2
fi

CLASSIFICATION="$(python3 - "$BODY" <<'PY'
import json
import sys

try:
    payload = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    print("UNREACHABLE")
    raise SystemExit

mode = payload.get("dispenseMode")
direct = payload.get("directClaimsEnabled") is True
wallet = payload.get("walletConfigured") is True
token = payload.get("apiTokenConfigured") is True
captcha = payload.get("captchaReady") is True

if direct and mode == "direct" and wallet and token and captcha:
    print("DIRECT_READY")
elif not direct and mode == "proxy-only" and wallet and token and not captcha:
    print("PROXY_ONLY")
elif not direct and mode == "unconfigured":
    print("UNCONFIGURED")
else:
    print("UNREACHABLE")
PY
)"

PASSING=false
if [[ "$CLASSIFICATION" == "DIRECT_READY" ]]; then
  PASSING=true
elif [[ "$CLASSIFICATION" == "PROXY_ONLY" ]] && $PROXY_VERIFIED; then
  PASSING=true
fi

if $JSON; then
  printf '{"classification":"%s","passing":%s}\n' "$CLASSIFICATION" "$PASSING"
else
  echo "$CLASSIFICATION"
fi

if [[ "$CLASSIFICATION" == "UNREACHABLE" ]]; then
  exit 2
fi
if $PUBLIC_RELEASE && ! $PASSING; then
  exit 1
fi

