#!/usr/bin/env bash
# OWNER ONLY: one outside probe; no scheduler change.
set -euo pipefail
trap 'printf "STOP: standby preflight failed; inspect sanitized codes\n" >&2' ERR
if [ ! -d /etc/pve ]; then printf 'STOP: run on Proxmox\n' >&2; exit 1; fi
install -d -m 0700 /var/lib/wrfcoin-standby
python3 /opt/wrfcoin-standby/check-standby-external.py --config /etc/wrfcoin-standby/config.json --test-notification
python3 /opt/wrfcoin-standby/check-standby-external.py --config /etc/wrfcoin-standby/config.json
printf 'PASS: outside node and attester/USB probe\n'
