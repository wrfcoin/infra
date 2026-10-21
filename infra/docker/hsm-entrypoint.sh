#!/bin/sh
# SoftHSM2 init + exec for wrfcoin-node.
# On first start (empty data volume), initialises a SoftHSM2 token and
# generates an Ed25519 signing keypair inside it.  On restarts the slot
# already exists and this script is a near-no-op.
#
# For YubiKey: set WRFCOIN_HSM_MODULE_PATH=libykcs11.so and skip SoftHSM2
# provisioning — the physical token is provisioned out-of-band.

set -e

# Runs before any HSM access or node exec, including sync-only startup.
validate_genesis_bootstrap() {
  bootstrap_cutter="${WRFCOIN_CUTTER_PREGENESIS:-0}"
  case "$bootstrap_cutter" in
    0|1) ;;
    *) echo 'FATAL: invalid pre-genesis cutter mode.' >&2; return 1 ;;
  esac
  if [ "${WRFCOIN_CHAIN_ID:-777}" != 888 ]; then
    [ "$bootstrap_cutter" = 0 ] && return 0
    echo 'FATAL: pre-genesis cutter mode requires chain 888.' >&2; return 1
  fi
  bootstrap_zero=0000000000000000000000000000000000000000000000000000000000000000
  bootstrap_hash="${WRFCOIN_GENESIS_HASH:-}"
  bootstrap_hash="${bootstrap_hash#0x}"
  if [ "$bootstrap_cutter" = 1 ]; then
    if [ "${WRFCOIN_NETWORK_ID:-}" != testnet ] || [ "${WRFCOIN_SYNC_ONLY:-0}" != 0 ]; then
      echo 'FATAL: pre-genesis cutter requires a producing 888/testnet node.' >&2; return 1
    fi
    if [ -e "${WRFCOIN_DATA_DIR:-./data}/wrfcoin.redb" ] || [ -L "${WRFCOIN_DATA_DIR:-./data}/wrfcoin.redb" ]; then
      echo 'FATAL: cutter database exists; pin the real genesis and remove the pre-genesis overlay.' >&2; return 1
    fi
    if [ -n "$bootstrap_hash" ] && [ "$bootstrap_hash" != "$bootstrap_zero" ]; then
      echo 'FATAL: pre-genesis cutter cannot use a recorded genesis hash; use normal startup.' >&2; return 1
    fi
    # Explicit zero means no expectation. An absent hash would use compiled 777 pins.
    export WRFCOIN_GENESIS_HASH="$bootstrap_zero"
    return 0
  fi
  if [ "${#bootstrap_hash}" != 64 ] || [ "$bootstrap_hash" = "$bootstrap_zero" ]; then
    echo 'FATAL: chain 888 normal startup requires a nonzero recorded genesis hash.' >&2; return 1
  fi
  case "$bootstrap_hash" in
    *[!0-9a-f]*) echo 'FATAL: invalid chain 888 genesis hash.' >&2; return 1 ;;
  esac
}
validate_genesis_bootstrap

HSM_DIR="/app/data/hsm"
SOFTHSM2_CONF="${HSM_DIR}/softhsm2.conf"
TOKEN_LABEL="${WRFCOIN_HSM_TOKEN_LABEL:-wrfcoin-validator}"
KEY_LABEL="${WRFCOIN_HSM_KEY_LABEL:-wrfcoin-signing-key}"
PIN_ENV="${WRFCOIN_HSM_PIN_ENV:-WRFCOIN_HSM_PIN}"
MODULE="${WRFCOIN_HSM_MODULE_PATH:-/usr/lib/softhsm/libsofthsm2.so}"

run_as_wrfcoin() {
  if [ "$(id -u)" = "0" ] && command -v gosu >/dev/null 2>&1; then
    gosu wrfcoin "$@"
  else
    "$@"
  fi
}

exec_wrfcoin_node() {
  if [ "$(id -u)" = "0" ] && command -v gosu >/dev/null 2>&1; then
    exec gosu wrfcoin /usr/local/bin/wrfcoin-node "$@"
  fi

  exec /usr/local/bin/wrfcoin-node "$@"
}

# A sync-only node validates and relays blocks but never produces one. Requiring it to
# initialise a signing token defeats that role boundary and makes the documented clean-machine
# join impossible. Keep this explicit and default-off; all validator/seed starts continue into
# the fail-closed HSM path below. Use the normal exec helper so root is still dropped.
if [ "${WRFCOIN_SYNC_ONLY:-0}" = "1" ]; then
  echo "[hsm-init] Sync-only mode: starting without a block-signing token."
  exec_wrfcoin_node "$@"
fi

# Only run SoftHSM2 init when using the softhsm2 module (skip for YubiKey).
case "$MODULE" in
  */softhsm*)
    export SOFTHSM2_CONF

    # Create config on first launch.
    if [ ! -f "$SOFTHSM2_CONF" ]; then
      mkdir -p "${HSM_DIR}/tokens"
      printf 'directories.tokendir = %s/tokens\nobjectstore.backend = file\nlog.level = INFO\n' \
        "$HSM_DIR" > "$SOFTHSM2_CONF"
      chown -R wrfcoin:wrfcoin "$HSM_DIR"
    fi

    # Resolve the PIN from the indirection env var.
    #
    # FAIL CLOSED. This previously defaulted to the literal PIN `1234`, which
    # silently protected a real Ed25519 signing key with a value committed to a
    # public repository (infra #784 — found live on CT 101, where every stored
    # .env candidate was rejected because the token had never used one).
    #
    # `:-` fires on EMPTY as well as unset, and docker-compose.testnet.yml passes
    # `WRFCOIN_HSM_PIN: ${WRFCOIN_HSM_PIN:-}` — an empty string. So the compose
    # guard that refuses an unconfigured PIN was bypassed by the time this ran.
    eval "PIN=\${${PIN_ENV}:-}"
    if [ -z "$PIN" ]; then
      echo "FATAL: $PIN_ENV is unset or empty — refusing to initialise a SoftHSM token with a default PIN" >&2
      exit 1
    fi

    # Init token + key only if the token label is not yet present.
    # Note: softhsm2-util --show-slots outputs the label without quotes;
    # grep for the bare label string, NOT "label" (no surrounding quotes).
    if ! run_as_wrfcoin softhsm2-util --show-slots 2>/dev/null | grep -qF "${TOKEN_LABEL}"; then
      echo "[hsm-init] Initialising SoftHSM2 token: ${TOKEN_LABEL}"
      run_as_wrfcoin softhsm2-util --init-token --free \
        --label "${TOKEN_LABEL}" \
        --pin  "${PIN}" \
        --so-pin "${WRFCOIN_HSM_SO_PIN:?FATAL: WRFCOIN_HSM_SO_PIN is unset or empty — refusing the default SO-PIN 0000}"

      echo "[hsm-init] Generating Ed25519 keypair: ${KEY_LABEL}"
      run_as_wrfcoin pkcs11-tool --module "${MODULE}" \
        --login --pin "${PIN}" \
        --token-label "${TOKEN_LABEL}" \
        --keypairgen --key-type EC:edwards25519 \
        --label "${KEY_LABEL}" --id 01

      echo "[hsm-init] Token ready."
    fi
    ;;
  *)
    if [ "$(id -u)" = "0" ] && command -v pcscd >/dev/null 2>&1 && [ ! -S /run/pcscd/pcscd.comm ]; then
      echo "[hsm-init] Starting container-local pcscd for PKCS#11 token access."
      mkdir -p /run/pcscd
      pcscd --foreground --auto-exit --disable-polkit &
      sleep 1
    fi
    ;;
esac

exec_wrfcoin_node "$@"
