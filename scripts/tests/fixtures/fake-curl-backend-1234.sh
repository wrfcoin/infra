#!/usr/bin/env bash
# Stub curl for the preflight smoke (backend#1234): answers /health with the
# real captured backend bodies, the detailed one only for the expected bearer.
# Records its argv to FAKE_CURL_ARGV_LOG (infra#1066 round 13: the token must
# never be in argv), and reads `-H @-` headers from stdin like real curl.
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_CURL_ARGV_LOG:?}"
out='' header=''
while (( $# > 0 )); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|-m) shift 2 ;;
    -H)
      if [ "$2" = "@-" ]; then IFS= read -r header || true; header="${header%$'\r'}"; else header="$2"; fi
      shift 2 ;;
    *) shift ;;
  esac
done
fx="${FAKE_BACKEND_FIXTURES:?}"
if [ "${header}" = "Authorization: Bearer ${FAKE_BACKEND_TOKEN:?}" ]; then
  cp "${fx}/backend-authenticated-503.json" "${out}"
else
  cp "${fx}/backend-anonymous-503.json" "${out}"
fi
printf '503'
