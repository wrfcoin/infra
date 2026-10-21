#!/usr/bin/env bash
# Open SSH tunnels to the WRFCoin testnet services on CT 101.
# Access Grafana at http://localhost:3100, API at http://localhost:4001, etc.
#
# CT 101 IP is DHCP-assigned. Override if it has changed:
#   N5_LAN_IP=192.168.0.X bash testnet/tunnel.sh
# Discover current IP: ask the operator for the node host address
# Or run: bash scripts/verify-n5-ip.sh
: "${N5_LAN_IP:?Set N5_LAN_IP to the currently verified CT101 LAN address}"

echo "Tunneling to CT 101 (${N5_LAN_IP}): Grafana :3100 | API :4001 | Node :8556 | Prometheus :9090"
echo "Press Ctrl+C to close tunnels."
ssh -N \
  -L 3100:127.0.0.1:3100 \
  -L 4001:127.0.0.1:4001 \
  -L 8556:127.0.0.1:8556 \
  -L 9090:127.0.0.1:9090 \
  "root@${N5_LAN_IP}"
