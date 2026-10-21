#!/usr/bin/env bash
# OWNER ONLY: install helpers on workstation, or scheduler files on Proxmox.
set -euo pipefail
trap 'printf "STOP: standby observer installation failed\n" >&2' ERR
step_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$step_dir/../../.." && pwd)"
if [ "$(id -u)" != 0 ]; then
  printf 'STOP: run the owner install step as root\n' >&2; exit 1
fi
case "${1:-}" in
  workstation)
    install -d -m 0755 /opt/wrfcoin-standby
    install -m 0755 "$repo/scripts/check-standby-usb.py" "$repo/scripts/check-standby-external.py" /opt/wrfcoin-standby/
    printf 'PASS: workstation probe helpers installed; no job enabled\n'
    ;;
  proxmox)
    if [ ! -d /etc/pve ] || [ "$#" -ne 2 ]; then
      printf 'STOP: Proxmox host and private owner configuration path required\n' >&2; exit 1
    fi
    python3 "$repo/scripts/check-standby-external.py" --config "$2" --validate-config
    install -d -m 0755 /opt/wrfcoin-standby
    install -d -m 0700 /etc/wrfcoin-standby
    install -m 0755 "$repo/scripts/check-standby-external.py" /opt/wrfcoin-standby/
    install -m 0600 "$2" /etc/wrfcoin-standby/config.json
    install -m 0644 "$step_dir/wrfcoin-standby-observer.service" "$step_dir/wrfcoin-standby-observer.timer" /etc/systemd/system/
    printf 'PASS: Proxmox observer staged; timer still disabled\n'
    ;;
  *) printf 'STOP: choose workstation or proxmox role\n' >&2; exit 1 ;;
esac
