#!/usr/bin/env bash
# OWNER ONLY, run on the workstation. Reads the producers this host can reach, dry-runs on
# the governance key host, then runs the real activation there, which asks for your YES.
# Hosts are inputs: nothing here names one. Runbook: docs/MOBILE_STATION_ACTIVATION.md.
#
#   activate-mobile-stations-888.sh \
#     --key-host '<command that runs a program on the key host, with a terminal>' \
#     --tool-dir <infra checkout's testnet/scripts on the key host> \
#     --key-host-producer <name>=<container> \
#     --reader <name>='<docker command for that producer>' (twice) \
#     --cli <CLI path on the key host> --cli-sha <digest from the build receipt> [--limit N]
set +x
set -euo pipefail

key_host='' tool_dir='' direct='' cli='' cli_sha='' limit=21 container=wrfcoin-testnet-node
readers=()
stop() { echo "ACTIVATION STOP: $1"; exit 1; }
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || stop 'invalid arguments'
  case "$1" in
    --key-host) key_host=$2 ;;
    --tool-dir) tool_dir=$2 ;;
    --key-host-producer) direct=$2 ;;
    --reader) readers+=("$2") ;;
    --cli) cli=$2 ;;
    --cli-sha) cli_sha=$2 ;;
    --limit) limit=$2 ;;
    --reader-container) container=$2 ;;
    *) stop 'invalid arguments' ;;
  esac
  shift 2
done
[ -n "$key_host" ] && [ -n "$tool_dir" ] && [ -n "$direct" ] && [ -n "$cli" ] && [ -n "$cli_sha" ] || stop 'invalid arguments'
[ "${#readers[@]}" -eq 2 ] || stop 'exactly two --reader inputs are required'
# These cross a remote shell, so only plain values are accepted.
plain='^[A-Za-z0-9._/=:@+-]+$'
for value in "$tool_dir" "$direct" "$cli" "$cli_sha" "$limit"; do
  [[ "$value" =~ $plain ]] || stop 'invalid arguments'
done

take_readings() {
  local entry name read_command revision
  readings=()
  for entry in "${readers[@]}"; do
    name=${entry%%=*}
    read_command=${entry#*=}
    [[ "$name" =~ ^[A-Za-z0-9._-]{1,64}$ ]] && [ "$read_command" != "$entry" ] || stop 'invalid --reader'
    revision=$(bash -c "$read_command inspect --format '{{index .Config.Labels \"org.opencontainers.image.revision\"}}' $container" 2>/dev/null </dev/null) \
      || stop "producer $name revision read failed; nothing signed"
    [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || stop "producer $name has no revision; nothing signed"
    readings+=(--producer-reading "$name=$revision@$(date +%s)")
  done
}

run_on_key_host() {
  # $key_host is the owner's own command, split into words on purpose.
  # shellcheck disable=SC2086
  $key_host python3 "$tool_dir/activate-mobile-stations.py" --cli "$cli" --cli-sha "$cli_sha" \
    --limit "$limit" --producer "$direct" "${readings[@]}" "$@"
}

take_readings
run_on_key_host --dry-run
take_readings   # the dry run takes time, and the fence wants a recent reading
run_on_key_host
