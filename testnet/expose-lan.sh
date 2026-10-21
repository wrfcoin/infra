#!/usr/bin/env bash
# Launches the testnet stack with only the block explorer exposed on all
# interfaces (0.0.0.0) instead of localhost only, using the
# docker-compose.lan.yml explorer-only override file.
#
# Node API (:8556), backend (:4001), monitoring, and exporters remain
# loopback-bound. For the June 17 tailnet launch, prefer Tailscale Serve in
# front of http://127.0.0.1:8081 or TESTNET_TAILNET_BIND_ADDR for explorer only.
#
# Usage:
#   bash expose-lan.sh              # start with explorer-only LAN exposure
#   bash expose-lan.sh --build      # same, but rebuild local images
#   bash expose-lan.sh down         # tear down the explorer-only LAN stack
set -euo pipefail

# CT 101 IP is DHCP-assigned. Override if it has changed:
#   N5_LAN_IP=192.168.0.X bash testnet/expose-lan.sh
# Discover current IP: ask the operator for the node host address
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P2P_GUARD="${DIR}/check-p2p-external-addr.sh"
BASE=(-f "$DIR/docker-compose.testnet.yml")
LAN=(-f "$DIR/docker-compose.lan.yml")

# Include the local-build override when the file exists.
OVERRIDE=()
if [ -f "$DIR/docker-compose.override.yml" ]; then
  OVERRIDE=(-f "$DIR/docker-compose.override.yml")
fi

case "${1:-up}" in
  down)
    "${P2P_GUARD}" --env-file "${DIR}/.env" --require
    docker compose "${BASE[@]}" "${OVERRIDE[@]}" "${LAN[@]}" down "${@:2}"
    ;;
  up|--build)
    : "${N5_LAN_IP:?Set N5_LAN_IP to the currently verified CT101 LAN address}"
    BUILD_FLAG=()
    for arg in "$@"; do
      [ "$arg" = "--build" ] && BUILD_FLAG=(--build)
    done
    "${P2P_GUARD}" --env-file "${DIR}/.env" --require
    docker compose "${BASE[@]}" "${OVERRIDE[@]}" "${LAN[@]}" up -d "${BUILD_FLAG[@]}"
    echo ""
    echo "Explorer-only LAN port on ${N5_LAN_IP} (0.0.0.0):"
    echo "  Block Explorer http://${N5_LAN_IP}:8081"
    echo ""
    echo "Node API :8556, backend :4001, frontend :5000, and monitoring ports remain loopback-bound."
    echo ""
    echo "To stop: bash expose-lan.sh down"
    ;;
  *)
    echo "Usage: bash expose-lan.sh [up|down|--build]" >&2
    exit 1
    ;;
esac
