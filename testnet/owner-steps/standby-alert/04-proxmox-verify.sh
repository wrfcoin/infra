#!/usr/bin/env bash
# OWNER ONLY: require a successful real run as well as an active timer.
set -euo pipefail
trap 'printf "STOP: standby observer runtime verification failed\n" >&2' ERR
if [ ! -d /etc/pve ]; then printf 'STOP: run on Proxmox\n' >&2; exit 1; fi
systemctl is-active --quiet wrfcoin-standby-observer.timer
systemctl start wrfcoin-standby-observer.service
result="$(systemctl show --property=ExecMainStatus --value wrfcoin-standby-observer.service)"
if [ "$result" != 0 ]; then printf 'STOP: observer reported unavailable\n' >&2; exit 1; fi
printf 'PASS: timer active and actual observer run succeeded\n'
