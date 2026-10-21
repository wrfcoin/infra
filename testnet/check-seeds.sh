#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEEDS_FILE="${SEEDS_FILE:-${SCRIPT_DIR}/seeds.txt}"
CUT_PINS_FILE="${CUT_PINS_FILE:-${SCRIPT_DIR}/cut-pins.env}"
PRINT_ONLY=0
ALLOW_LAN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --print) PRINT_ONLY=1 ;;
    --allow-lan) ALLOW_LAN=1 ;;
    *)
      echo "Usage: $(basename "$0") [--print] [--allow-lan]" >&2
      exit 1
      ;;
  esac
  shift
done

if [ ! -f "$SEEDS_FILE" ]; then
  echo "ERROR: missing seeds file: $SEEDS_FILE" >&2
  exit 1
fi

if [ ! -f "$CUT_PINS_FILE" ]; then
  echo "ERROR: missing cut pins file: $CUT_PINS_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CUT_PINS_FILE"
if [ -z "${WRFCOIN_CUT_BOOTSTRAP:-}" ]; then
  echo "ERROR: WRFCOIN_CUT_BOOTSTRAP is unset in ${CUT_PINS_FILE}" >&2
  exit 1
fi

seed_lines=()
line_no=0

while IFS= read -r raw_line || [ -n "$raw_line" ]; do
  line_no=$((line_no + 1))

  line="${raw_line#"${raw_line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"

  case "$line" in
    ""|\#*)
      continue
      ;;
  esac

  case "$line" in
    /ip4/*|/ip6/*|/dns4/*|/dns6/*|/dnsaddr/*)
      ;;
    *)
      echo "ERROR: ${SEEDS_FILE}:${line_no} is not a supported multiaddr: ${line}" >&2
      exit 1
      ;;
  esac

  if ! printf '%s' "$line" | grep -Eq '/p2p/[^[:space:]]+$'; then
    echo "ERROR: ${SEEDS_FILE}:${line_no} is missing a /p2p/<PEER_ID> suffix: ${line}" >&2
    exit 1
  fi

  if printf '%s' "$line" | grep -Eq '/tcp/'; then
    if ! printf '%s' "$line" | grep -Eq '/tcp/[0-9]+(/|$)'; then
      echo "ERROR: ${SEEDS_FILE}:${line_no} uses a non-numeric tcp port: ${line}" >&2
      exit 1
    fi
  fi

  if [ "$ALLOW_LAN" -ne 1 ] && printf '%s' "$line" | grep -Eq \
    '/ip4/(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'; then
    echo "ERROR: ${SEEDS_FILE}:${line_no} contains an RFC1918 address; use --allow-lan only for an intentional local deployment: ${line}" >&2
    exit 1
  fi

  seed_lines+=("$line")
done < "$SEEDS_FILE"

if [ "${#seed_lines[@]}" -eq 0 ]; then
  echo "WARNING: no seed entries found in ${SEEDS_FILE}." >&2
  echo "Add peer multiaddrs there or set BOOTSTRAP_PEERS manually in .env." >&2
  if [ "$PRINT_ONLY" -eq 1 ]; then
    exit 1
  fi
  exit 0
fi

pinned_bootstrap_listed=0
for seed in "${seed_lines[@]}"; do
  if [ "$seed" = "$WRFCOIN_CUT_BOOTSTRAP" ]; then
    pinned_bootstrap_listed=1
    break
  fi
done
if [ "$pinned_bootstrap_listed" -ne 1 ]; then
  echo "ERROR: pinned WRFCOIN_CUT_BOOTSTRAP from ${CUT_PINS_FILE} is not listed in ${SEEDS_FILE}: ${WRFCOIN_CUT_BOOTSTRAP}" >&2
  exit 1
fi

unique_count=$(printf '%s\n' "${seed_lines[@]}" | sort -u | wc -l | tr -d ' ')
if [ "$unique_count" -ne "${#seed_lines[@]}" ]; then
  echo "ERROR: duplicate bootstrap peer entries found in ${SEEDS_FILE}." >&2
  printf '%s\n' "${seed_lines[@]}" | sort | uniq -d >&2
  exit 1
fi

bootstrap_peers=$(IFS=,; printf '%s' "${seed_lines[*]}")

if [ "$PRINT_ONLY" -eq 1 ]; then
  printf 'BOOTSTRAP_PEERS=%s\n' "$bootstrap_peers"
  exit 0
fi

echo "OK: ${#seed_lines[@]} seed entries validated in ${SEEDS_FILE}."
echo "Copy this into .env if you want to bootstrap from them:"
echo "BOOTSTRAP_PEERS=${bootstrap_peers}"
