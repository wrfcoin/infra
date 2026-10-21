#!/bin/sh
# Generic fail-closed HSM service launcher (infra#819).
#
# Unlike hsm-entrypoint.sh this script never provisions a key and does not
# assume the node binary. It prepares the selected PKCS#11 transport, then
# drops privileges and execs the service command supplied by the image.

set -eu

# The attester's capped physics-only mode is selected by leaving this variable
# unset. Compose needs an explicit operator choice, so it carries a sentinel
# which is removed here before the process starts.
if [ "${WRFCOIN_ATTESTER_NWS_STATION:-}" = "PHYSICS_ONLY" ]; then
  unset WRFCOIN_ATTESTER_NWS_STATION
fi

MODULE="${WRFCOIN_HSM_MODULE_PATH:?WRFCOIN_HSM_MODULE_PATH must be set}"

case "$MODULE" in
  */softhsm*)
    export SOFTHSM2_CONF="${SOFTHSM2_CONF:-/app/data/hsm/softhsm2.conf}"
    if [ ! -r "$SOFTHSM2_CONF" ]; then
      echo "FATAL: SoftHSM config is absent; complete the attended oracle-key ceremony before starting the attester" >&2
      exit 1
    fi
    ;;
  *)
    # Desktop/WSL passes the USB device and starts pcscd in-container. CT101
    # bind-mounts the host socket, in which case no daemon is started here.
    if [ ! -S /run/pcscd/pcscd.comm ]; then
      if [ "$(id -u)" != "0" ]; then
        echo "FATAL: no pcscd socket is mounted and the service is not root, so pcscd cannot be started" >&2
        exit 1
      fi
      mkdir -p /run/pcscd
      pcscd --foreground --auto-exit --disable-polkit &
      sleep 1
      [ -S /run/pcscd/pcscd.comm ] || {
        echo "FATAL: pcscd did not create its socket" >&2
        exit 1
      }
    fi
    ;;
esac

if [ "$#" -eq 0 ]; then
  echo "FATAL: hsm-service-entrypoint requires a service command" >&2
  exit 1
fi

if [ "$(id -u)" = "0" ]; then
  exec gosu wrfcoin "$@"
fi

exec "$@"
