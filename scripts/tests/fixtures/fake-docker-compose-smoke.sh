#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG:?}"
mode="${FAKE_DOCKER_MODE:-healthy}"

if [ "${1:-}" = "ps" ]; then
  if [[ " $* " == *" -aq "* ]]; then
    [ "${mode}" = "collision" ] && printf '%s\n' existing-container
  elif [[ " $* " == *" --format "* ]]; then
    if [ "${mode}" = "unexpected-service" ]; then
      printf '%s\n' postgres redis wrfcoin-backend wrfcoin-node
    else
      printf '%s\n' ${FAKE_SERVICES:-postgres redis wrfcoin-backend}
    fi
  fi
  exit 0
fi

if [ "${1:-}" = "volume" ] || [ "${1:-}" = "network" ]; then
  exit 0
fi

if [ "${1:-}" = "inspect" ]; then
  if [[ "$*" == *"State.Status"* ]]; then
    printf '%s\n' running
  else
    printf '%s\n' none
  fi
  exit 0
fi

if [ "${1:-}" = "logs" ]; then
  exit 0
fi

if [ "${1:-}" = "exec" ]; then
  case "${mode}" in
    real-exec)
      # backend#1234: run the smoke's REAL in-container probe script
      # (`exec <cid> sh -c <script>`) with a stub curl that serves the captured
      # post-#1234 backend bodies: detail only for the expected bearer.
      shift 2
      exec env PATH="${FAKE_CURL_DIR:?}:${PATH}" "$@"
      ;;
    startup-race)
      state="${FAKE_DOCKER_STATE:?}"
      if [ ! -e "${state}" ]; then
        : > "${state}"
        printf '%s\n' 000
        # Model the original bug exactly: curl failed, but the final cleanup
        # command masked its status, so docker exec reported success with 000.
        exit 0
      fi
      printf '%s\n%s\n' 503 '{"success":false,"data":{"status":"unhealthy","dependencies":{"core4":{"status":"down"}}}}'
      ;;
    bad-503)
      printf '%s\n%s\n' 503 '{"status":"degraded"}'
      ;;
    healthy)
      printf '%s\n%s\n' 200 '{"success":true,"data":{"status":"healthy"}}'
      ;;
    *)
      printf '%s\n%s\n' 503 '{"success":false,"data":{"status":"unhealthy","dependencies":{"core4":{"status":"down"}}}}'
      ;;
  esac
  exit 0
fi

if [ "${1:-}" = "compose" ]; then
  case " $* " in
    *" ps -q "*) printf '%s\n' smoke-container ;;
    *" up "*) ;;
    *" down "*) ;;
  esac
  exit 0
fi

exit 0
