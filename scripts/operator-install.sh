#!/usr/bin/env bash
# =============================================================================
# WRFCoin Operator Node Install Script
#
# Automates the full setup of a WRFCoin operator node on Ubuntu 22.04+ or
# Debian 12+ (amd64/arm64). Designed to run inside CT 101 (<NODE_LAN_IP>) on
# the N5 Pro, but works on any compatible host.
#
# What this script does:
#   1. Checks OS and architecture compatibility
#   2. Installs system dependencies (curl, git, openssl, etc.)
#   3. Installs Docker CE + Compose plugin (idempotent)
#   4. Clones WRFCoin repos to INSTALL_DIR
#   5. Detects ZFS mounts (N5 Pro) and optional hardware (SDR, Zigbee)
#   6. Generates secrets via testnet/setup-env.sh (skips if .env exists)
#   7. Builds Docker images from local source (no registry)
#   8. Starts the testnet stack and verifies health
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/wrfcoin/infra/main/scripts/operator-install.sh | bash
#   # or
#   bash scripts/operator-install.sh [--install-dir DIR] [--skip-build] [--dry-run]
#
# Options:
#   --install-dir DIR   Directory to clone repos into (default: <src-root>)
#   --skip-build        Skip Docker image build (use existing images)
#   --dry-run           Print actions without executing
#   --help              Show this message
#
# Deployment constraint: images are built locally — NEVER pushed to ghcr.io.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
INSTALL_DIR="${INSTALL_DIR:-${WRFCOIN_SRC_ROOT:-/path/to/wrfcoin-src}}"
GITHUB_ORG="wrfcoin"
REPOS=(infra backend core4 frontend)
TESTNET_DIR=""         # set after clone
DRY_RUN=false
SKIP_BUILD=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
info() { echo -e "${CYAN}[>]${NC} $*"; }
run()  {
  if [ "$DRY_RUN" = true ]; then
    echo -e "${CYAN}[DRY-RUN]${NC} $*"
  else
    # Forwards its own argv; no caller passes it a Compose render (grepped, infra#1107).
    # dynamic-payload-reviewed: operator-install-run-forwards-argv
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir)
        INSTALL_DIR="$2"; shift 2 ;;
      --skip-build)
        SKIP_BUILD=true; shift ;;
      --dry-run)
        DRY_RUN=true; shift ;;
      --help|-h)
        grep '^#' "$0" | sed 's/^# \?//' | head -30
        exit 0 ;;
      *)
        err "Unknown argument: $1"; exit 1 ;;
    esac
  done
  TESTNET_DIR="${INSTALL_DIR}/infra/testnet"
}

# ---------------------------------------------------------------------------
# Step 1: OS and architecture check
# ---------------------------------------------------------------------------
check_os() {
  log "=== Step 1: OS and architecture check ==="

  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64|aarch64) info "Architecture: $arch" ;;
    *) err "Unsupported architecture: $arch (requires x86_64 or aarch64)"; exit 1 ;;
  esac

  if [ ! -f /etc/os-release ]; then
    err "/etc/os-release not found — cannot detect OS."
    exit 1
  fi
  # shellcheck source=/dev/null
  . /etc/os-release

  info "OS: $PRETTY_NAME"

  case "$ID" in
    ubuntu)
      local ver_major
      ver_major=$(echo "$VERSION_ID" | cut -d. -f1)
      if [ "$ver_major" -lt 22 ]; then
        err "Ubuntu $VERSION_ID not supported. Requires Ubuntu 22.04 or later."
        exit 1
      fi
      ;;
    debian)
      if [ "${VERSION_ID:-0}" -lt 12 ]; then
        err "Debian $VERSION_ID not supported. Requires Debian 12 or later."
        exit 1
      fi
      ;;
    *)
      warn "Untested OS: $ID — proceeding anyway. Ubuntu/Debian recommended."
      ;;
  esac

  # Check we are not root on a non-CT host (warn only)
  if [ "$(id -u)" -ne 0 ]; then
    err "This script must run as root (or with sudo)."
    exit 1
  fi

  log "OS check passed."
}

# ---------------------------------------------------------------------------
# Step 2: System dependencies
# ---------------------------------------------------------------------------
install_deps() {
  log "=== Step 2: System dependencies ==="

  run apt-get update -qq
  run apt-get install -y --no-install-recommends \
    curl \
    git \
    openssl \
    ca-certificates \
    gnupg \
    htop \
    rsync \
    jq \
    lsb-release \
    apt-transport-https

  log "System dependencies installed."
}

# ---------------------------------------------------------------------------
# Step 3: Docker CE + Compose plugin
# ---------------------------------------------------------------------------
install_docker() {
  log "=== Step 3: Docker CE ==="

  if command -v docker &>/dev/null; then
    local docker_ver
    docker_ver=$(docker --version 2>&1 | grep -oP '\d+\.\d+' | head -1)
    local docker_major
    docker_major=$(echo "$docker_ver" | cut -d. -f1)
    if [ "${docker_major:-0}" -ge 24 ]; then
      info "Docker already installed: $(docker --version)"
      info "Docker Compose: $(docker compose version)"
      return
    fi
    warn "Docker version $docker_ver is older than 24. Reinstalling..."
    run apt-get remove -y docker docker-engine docker.io containerd runc || true
  fi

  info "Installing Docker CE from upstream repository..."
  run install -m 0755 -d /etc/apt/keyrings

  # shellcheck source=/dev/null
  . /etc/os-release
  local distro_codename
  distro_codename=$(lsb_release -cs 2>/dev/null || echo "$VERSION_CODENAME")

  run curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
    -o /etc/apt/keyrings/docker.asc
  run chmod a+r /etc/apt/keyrings/docker.asc

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/${ID} ${distro_codename} stable" \
    | run tee /etc/apt/sources.list.d/docker.list > /dev/null

  run apt-get update -qq
  run apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  # Configure Docker daemon for overlay2 and log rotation
  run mkdir -p /etc/docker
  if [ ! -f /etc/docker/daemon.json ]; then
    cat > /etc/docker/daemon.json << 'DEOF'
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  }
}
DEOF
    log "Docker daemon.json written."
  else
    info "Docker daemon.json already exists — not overwriting."
  fi

  run systemctl enable --now docker

  log "Docker installed: $(docker --version)"
  log "Docker Compose: $(docker compose version)"

  # Smoke test
  if run docker run --rm hello-world > /dev/null 2>&1; then
    log "Docker smoke test: OK"
  else
    warn "Docker smoke test failed — check daemon logs with: journalctl -u docker"
  fi
}

# ---------------------------------------------------------------------------
# Step 4: Clone repos
# ---------------------------------------------------------------------------
clone_repos() {
  log "=== Step 4: Clone WRFCoin repos ==="

  run mkdir -p "$INSTALL_DIR"

  for repo in "${REPOS[@]}"; do
    local dest="${INSTALL_DIR}/${repo}"
    if [ -d "${dest}/.git" ]; then
      info "${repo}: already cloned — pulling latest main..."
      run git -C "$dest" fetch origin
      run git -C "$dest" checkout main
      run git -C "$dest" pull --ff-only origin main || \
        warn "${repo}: fast-forward failed — local changes may exist. Skipping pull."
    else
      info "Cloning ${GITHUB_ORG}/${repo}..."
      run git clone \
        "https://github.com/${GITHUB_ORG}/${repo}.git" \
        "$dest"
    fi
  done

  log "All repos ready in ${INSTALL_DIR}."
}

# ---------------------------------------------------------------------------
# Step 5: Detect optional hardware
# ---------------------------------------------------------------------------
detect_hardware() {
  log "=== Step 5: Hardware detection ==="

  # ZFS mounts (N5 Pro has tank/postgres, tank/redis, tank/blockchain)
  if command -v zfs &>/dev/null; then
    local zfs_pools
    zfs_pools=$(zpool list -H -o name 2>/dev/null || true)
    if echo "$zfs_pools" | grep -q "^tank$"; then
      log "ZFS pool 'tank' detected — ZFS-backed volumes will be used."
      info "  Datasets: $(zfs list -H -o name -r tank | tr '\n' ' ')"
      export ZFS_AVAILABLE=true
    else
      info "ZFS not configured — using Docker default volumes."
      export ZFS_AVAILABLE=false
    fi
  else
    info "ZFS not installed — using Docker default volumes."
    export ZFS_AVAILABLE=false
  fi

  # SDR dongle detection (optional — for radio weather collection)
  if command -v lsusb &>/dev/null; then
    local sdr_count
    sdr_count=$(lsusb 2>/dev/null | grep -icE "RTL2838|RTL2832|0bda:2838|0bda:2832" || true)
    if [ "${sdr_count:-0}" -gt 0 ]; then
      log "RTL-SDR dongle detected — radio weather collection available."
      export SDR_AVAILABLE=true
    else
      info "No RTL-SDR dongle detected — radio weather collection disabled."
      export SDR_AVAILABLE=false
    fi
  else
    info "lsusb not available — skipping SDR detection."
    export SDR_AVAILABLE=false
  fi

  # Zigbee USB dongle detection (optional)
  if command -v lsusb &>/dev/null; then
    local zigbee_count
    zigbee_count=$(lsusb 2>/dev/null | grep -icE "Silicon Labs CP210|0403:6001|10c4:ea60|EFR32" || true)
    if [ "${zigbee_count:-0}" -gt 0 ]; then
      log "Zigbee dongle detected — sensor mesh integration can be staged after the 3-peer rollout is stable."
      export ZIGBEE_AVAILABLE=true
    else
      info "No Zigbee dongle detected — sensor mesh disabled."
      export ZIGBEE_AVAILABLE=false
    fi
  else
    export ZIGBEE_AVAILABLE=false
  fi

  # Rust toolchain (needed for local builds)
  if command -v cargo &>/dev/null; then
    info "Rust toolchain: $(rustc --version)"
    export RUST_AVAILABLE=true
  else
    warn "Rust toolchain not found — will be installed for local Docker builds."
    warn "  (The Dockerfile installs Rust inside the build container — host Rust is optional.)"
    export RUST_AVAILABLE=false
  fi
}

# ---------------------------------------------------------------------------
# Step 6: Generate secrets
# ---------------------------------------------------------------------------
generate_secrets() {
  log "=== Step 6: Secret generation ==="

  local env_file="${TESTNET_DIR}/.env"

  if [ -f "$env_file" ]; then
    info ".env already exists at ${env_file} — skipping secret generation."
    info "  To regenerate: rm ${env_file} && bash ${TESTNET_DIR}/setup-env.sh"
    return
  fi

  info "Running setup-env.sh to generate secrets..."
  run bash "${TESTNET_DIR}/setup-env.sh"

  log "Secrets generated. Save the output above in a password manager."
}

# ---------------------------------------------------------------------------
# Testnet validation floor (also for an existing .env)
# ---------------------------------------------------------------------------
configure_node_validation() {
  local env_file="${TESTNET_DIR}/.env"
  # Export as well as persist: inherited shell values override Compose .env.
  export WRFCOIN_MIN_WORK_FACTOR=0
  if [ "$DRY_RUN" = true ]; then
    info "[DRY-RUN] Set WRFCOIN_MIN_WORK_FACTOR=0 in ${env_file} and the startup environment."
    return
  fi
  if grep -q '^WRFCOIN_MIN_WORK_FACTOR=' "$env_file"; then
    sed -i.bak 's|^WRFCOIN_MIN_WORK_FACTOR=.*|WRFCOIN_MIN_WORK_FACTOR=0|' "$env_file"
    rm -f "${env_file}.bak"
  else
    printf '\nWRFCOIN_MIN_WORK_FACTOR=0\n' >> "$env_file"
  fi
}

# ---------------------------------------------------------------------------
# Public chain-888 bootstrap inputs (also for an existing .env)
# ---------------------------------------------------------------------------
configure_node_bootstrap() {
  local pins="${CUT_PINS_FILE:-${TESTNET_DIR}/cut-pins.env}" bootstrap key value
  if [ "$DRY_RUN" = true ]; then
    info "[DRY-RUN] Validate and load public node bootstrap inputs from ${pins}."
    return
  fi
  bootstrap="$(python3 "${TESTNET_DIR}/scripts/chain-identity.py" --pins "$pins" --bootstrap-env "${TESTNET_DIR}/.env")" || return 1
  if [ -n "$bootstrap" ]; then
    while IFS='=' read -r key value; do export "$key=$value"; done <<< "$bootstrap"
  fi
}

# ---------------------------------------------------------------------------
# Step 7: Build Docker images
# ---------------------------------------------------------------------------
build_images() {
  log "=== Step 7: Docker image build ==="

  if [ "$SKIP_BUILD" = true ]; then
    info "--skip-build set — skipping Docker build."
    return
  fi

  info "Building all images locally (this takes 5–15 minutes on first run)..."
  info "  Images: wrfcoin/native-chain, wrfcoin/backend, wrfcoin/frontend"
  info "  No image registry push — local builds only."

  run docker compose \
    -f "${TESTNET_DIR}/docker-compose.testnet.yml" \
    -f "${TESTNET_DIR}/docker-compose.override.yml" \
    build \
    --parallel

  log "Docker images built."
}

# ---------------------------------------------------------------------------
# Step 8: Start testnet stack
# ---------------------------------------------------------------------------
start_testnet() {
  log "=== Step 8: Start testnet stack ==="

  run docker compose \
    -f "${TESTNET_DIR}/docker-compose.testnet.yml" \
    -f "${TESTNET_DIR}/docker-compose.override.yml" \
    up -d

  log "Testnet stack started."
}

# ---------------------------------------------------------------------------
# Step 9: Health verification
# ---------------------------------------------------------------------------
verify_health() {
  log "=== Step 9: Health verification ==="

  local max_wait=120
  local elapsed=0
  local interval=5

  info "Waiting up to ${max_wait}s for services to become healthy..."

  while [ $elapsed -lt $max_wait ]; do
    local node_ok=false
    local backend_ok=false

    if curl -sf http://localhost:8556/readyz >/dev/null 2>&1; then
      node_ok=true
    fi
    if curl -sf http://localhost:4001/health >/dev/null 2>&1; then
      backend_ok=true
    fi

    if [ "$node_ok" = true ] && [ "$backend_ok" = true ]; then
      log "All services healthy."
      break
    fi

    local status=""
    [ "$node_ok" = false ] && status+=" node(waiting)"
    [ "$backend_ok" = false ] && status+=" backend(waiting)"
    info "  ${elapsed}s:${status} — retrying in ${interval}s..."
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  if [ $elapsed -ge $max_wait ]; then
    warn "Health check timed out after ${max_wait}s."
    warn "Check logs: docker compose -f ${TESTNET_DIR}/docker-compose.testnet.yml logs --tail=50"
    return 1
  fi

  # Print service summary
  echo ""
  log "=== Service Status ==="
  docker compose \
    -f "${TESTNET_DIR}/docker-compose.testnet.yml" \
    -f "${TESTNET_DIR}/docker-compose.override.yml" \
    ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || \
    docker compose \
      -f "${TESTNET_DIR}/docker-compose.testnet.yml" \
      -f "${TESTNET_DIR}/docker-compose.override.yml" \
      ps

  # Node info
  local node_info
  node_info=$(curl -sf http://localhost:8556/node/info 2>/dev/null || echo "{}")
  local peer_id
  peer_id=$(echo "$node_info" | jq -r '.peer_id // "unknown"' 2>/dev/null || echo "unknown")

  echo ""
  echo "============================================================"
  echo "  WRFCoin Operator Node — Ready"
  echo "============================================================"
  echo "  Peer ID:    ${peer_id}"
  echo "  API:        http://localhost:8556"
  echo "  P2P port:   9000 (ensure this is reachable from peers)"
  echo "  Grafana:    http://localhost:3100"
  echo "  Backend:    http://localhost:4001"
  echo ""
  if [ -n "$peer_id" ] && [ "$peer_id" != "unknown" ]; then
    echo "  Share with other operators:"
    echo "  /ip4/$(hostname -I | awk '{print $1}')/tcp/9000/p2p/${peer_id}"
  fi
  echo "============================================================"
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  echo ""
  echo "============================================================"
  echo "  WRFCoin Operator Node Install"
  echo "  Install dir: ${INSTALL_DIR}"
  if [ "$DRY_RUN" = true ]; then
    echo "  Mode: DRY-RUN (no changes will be made)"
  fi
  echo "============================================================"
  echo ""

  check_os
  install_deps
  install_docker
  clone_repos
  detect_hardware
  generate_secrets
  configure_node_validation
  configure_node_bootstrap
  build_images
  start_testnet
  verify_health

  log "=== Install complete ==="
  log "Logs: docker compose -f ${TESTNET_DIR}/docker-compose.testnet.yml logs -f"
  log "Stop: docker compose -f ${TESTNET_DIR}/docker-compose.testnet.yml down"
}

main "$@"
