#!/usr/bin/env bash
# OWNER ONLY: enable the Proxmox timer after successful preflight.
set -euo pipefail
trap 'printf "STOP: standby timer enablement failed\n" >&2' ERR
if [ ! -d /etc/pve ]; then printf 'STOP: run on Proxmox\n' >&2; exit 1; fi
python3 /opt/wrfcoin-standby/check-standby-external.py --config /etc/wrfcoin-standby/config.json --validate-config
systemctl daemon-reload
systemctl enable --now wrfcoin-standby-observer.timer
systemctl is-active --quiet wrfcoin-standby-observer.timer
printf 'PASS: Proxmox timer enabled\n'
