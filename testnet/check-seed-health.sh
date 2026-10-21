#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

PASS_COUNT=0
FAIL_COUNT=0
# shellcheck disable=SC2034  # Reserved for future CLI behavior.
PROBE_MODE=0
FIX_MODE=0
POSITIONAL_PEERS=()

status_line() {
  local level="$1"
  shift
  printf '%-5s %s\n' "$level" "$*"
}

mark_pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  status_line "PASS" "$*"
}

mark_fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  status_line "FAIL" "$*"
}

usage() {
  cat <<'EOF'
Usage: check-seed-health.sh [--probe] [--fix] [-- MULTIADDR ...]

Probes configured BOOTSTRAP_PEERS for TCP reachability on P2P ports.
Reads BOOTSTRAP_PEERS from .env if it exists, or accepts explicit multiaddrs
after a `--` separator for ad-hoc checks.

Options:
  --probe    (reserved for future libp2p identify probe)
  --fix      (reserved for future auto-fix suggestions)
  --         Treat the remaining arguments as literal multiaddrs
EOF
}

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

parse_args() {
  POSITIONAL_PEERS=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --probe)
        PROBE_MODE=1
        shift
        ;;
      --fix)
        FIX_MODE=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --)
        shift
        POSITIONAL_PEERS=("$@")
        return 0
        ;;
      /*)
        echo "ERROR: pass explicit multiaddrs after -- so they are not confused with flags." >&2
        usage
        exit 1
        ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

lookup_dnsaddr_records() {
  local dnsaddr_host="$1"
  local query_name="_dnsaddr.${dnsaddr_host}"

  if command -v dig >/dev/null 2>&1; then
    dig +short TXT "$query_name" 2>/dev/null | tr -d '"'
    return 0
  fi

  if command -v host >/dev/null 2>&1; then
    host -t TXT "$query_name" 2>/dev/null | sed -n 's/.*descriptive text "\(.*\)"/\1/p'
    return 0
  fi

  if command -v nslookup >/dev/null 2>&1; then
    nslookup -type=TXT "$query_name" 2>/dev/null | sed -n 's/.*text = "\(.*\)"/\1/p'
    return 0
  fi

  return 1
}

extract_endpoint() {
  local multiaddr="$1"
  local depth="${2:-0}"
  local family host port dnsaddr_host endpoint txt_record

  if [ "$depth" -gt 5 ]; then
    return 1
  fi

  if [[ "$multiaddr" =~ ^/(ip4|ip6|dns|dns4|dns6)/([^/]+).*/tcp/([0-9]+)(/.*)?$ ]]; then
    family="${BASH_REMATCH[1]}"
    host="${BASH_REMATCH[2]}"
    port="${BASH_REMATCH[3]}"
    printf '%s\t%s\t%s\n' "$family" "$host" "$port"
    return 0
  fi

  if [[ "$multiaddr" =~ ^/dnsaddr/([^/]+)(/.*)?$ ]]; then
    dnsaddr_host="${BASH_REMATCH[1]}"

    while IFS= read -r txt_record; do
      txt_record="$(trim_whitespace "$txt_record")"
      txt_record="${txt_record#dnsaddr=}"
      [ -z "$txt_record" ] && continue

      if endpoint=$(extract_endpoint "$txt_record" $((depth + 1))); then
        printf '%s\n' "$endpoint"
        return 0
      fi
    done < <(lookup_dnsaddr_records "$dnsaddr_host" || true)
  fi

  return 1
}

extract_host_port() {
  local endpoint family host port

  endpoint=$(extract_endpoint "$1" "${2:-0}") || return 1
  IFS=$'\t' read -r family host port <<<"$endpoint"
  printf '%s\t%s\n' "$host" "$port"
}

format_host_port() {
  local family="$1"
  local host="$2"
  local port="$3"

  if [ "$family" = "ip6" ]; then
    printf '[%s]:%s' "$host" "$port"
    return 0
  fi

  printf '%s:%s' "$host" "$port"
}

probe_tcp() {
  local host="$1"
  local port="$2"
  local family="${3:-}"
  local timeout_secs=3

  if [ -z "$host" ] || [ -z "$port" ]; then
    return 1
  fi

  if command -v nc >/dev/null 2>&1; then
    if [ "$family" = "ip6" ]; then
      nc -6 -z -w "$timeout_secs" "$host" "$port" >/dev/null 2>&1
      return $?
    fi

    nc -z -w "$timeout_secs" "$host" "$port" >/dev/null 2>&1
    return $?
  fi

  if [ "$family" = "ip6" ]; then
    return 1
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_secs" bash -c "</dev/tcp/${host}/${port}" 2>/dev/null
    return $?
  fi

  exec 3<>/dev/tcp/"$host"/"$port" 2>/dev/null && exec 3>&- && return 0
  return 1
}

load_peers_from_env() {
  local bootstrap_peers multiaddr

  if [ ! -f "$ENV_FILE" ]; then
    mark_fail ".env not found at $ENV_FILE; cannot determine BOOTSTRAP_PEERS"
    return 1
  fi

  bootstrap_peers=$(grep '^BOOTSTRAP_PEERS=' "$ENV_FILE" | cut -d= -f2- || true)
  if [ -z "$bootstrap_peers" ]; then
    mark_fail "BOOTSTRAP_PEERS not set in $ENV_FILE"
    return 1
  fi

  IFS=',' read -r -a POSITIONAL_PEERS <<<"$bootstrap_peers"
  for multiaddr in "${!POSITIONAL_PEERS[@]}"; do
    POSITIONAL_PEERS[$multiaddr]="$(trim_whitespace "${POSITIONAL_PEERS[$multiaddr]#\"}")"
    POSITIONAL_PEERS[$multiaddr]="${POSITIONAL_PEERS[$multiaddr]%\"}"
  done
}

main() {
  local multiaddr endpoint family host port display_host_port

  parse_args "$@"

  # Reserved flags are parsed now so future probe/fix modes stay CLI-compatible.
  if [ "$PROBE_MODE" -eq 1 ] || [ "$FIX_MODE" -eq 1 ]; then
    :
  fi

  if [ "${#POSITIONAL_PEERS[@]}" -eq 0 ]; then
    load_peers_from_env || exit 1
  fi

  echo "Checking seed reachability..."
  echo

  for multiaddr in "${POSITIONAL_PEERS[@]}"; do
    multiaddr="$(trim_whitespace "$multiaddr")"
    [ -z "$multiaddr" ] && continue

    endpoint=$(extract_endpoint "$multiaddr" || true)
    if [ -z "$endpoint" ]; then
      mark_fail "Could not parse multiaddr: $multiaddr"
      continue
    fi

    IFS=$'\t' read -r family host port <<<"$endpoint"
    display_host_port=$(format_host_port "$family" "$host" "$port")

    if probe_tcp "$host" "$port" "$family"; then
      mark_pass "$display_host_port reachable"
    else
      mark_fail "$display_host_port unreachable (TCP $port not open)"
    fi
  done

  echo
  status_line "=====" "Seed Reachability Report"
  status_line "PASS" "$PASS_COUNT of $((PASS_COUNT + FAIL_COUNT)) seeds reachable"

  if [ "$FAIL_COUNT" -gt 0 ]; then
    status_line "WARN" "$FAIL_COUNT seed(s) unreachable or unparseable"
    echo
    echo "Troubleshooting:"
    echo "  - Verify BOOTSTRAP_PEERS is correctly formatted in .env"
    echo "  - Confirm seed node addresses are correct and currently online"
    echo "  - Check that the expected TCP port is reachable from your network"
    echo "  - For dnsaddr seeds, verify DNS TXT lookups work on this host"
    echo
    exit 1
  fi

  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
