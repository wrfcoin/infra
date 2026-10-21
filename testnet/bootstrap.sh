#!/usr/bin/env bash
# =============================================================================
# WRFCoin Testnet — One-Click Bootstrap
#
# Takes a prepared host (Docker installed, repos cloned) from zero to a running,
# peered WRFCoin testnet node. Intended as the entry point for new operators.
#
# What this script does:
#   1. Preflight checks (Docker, RAM, disk, port 9000)
#   2. Generates secrets via setup-env.sh (skips if .env already exists)
#   3. Generates Prometheus auth plus AlertManager rendered config if missing
#   4. Fetches current seed peers from seeds.txt
#   5. Builds Docker images locally (no registry push)
#   6. Starts the testnet stack with docker compose
#   7. Polls /readyz and /network/peers until healthy
#   8. Prints a success banner with peer ID and shareable multiaddress
#
# Usage:
#   bash testnet/bootstrap.sh                   # full flow (default)
#   bash testnet/bootstrap.sh --quick           # guided happy-path for new operators
#   bash testnet/bootstrap.sh --dry-run         # print what would happen, change nothing
#
# Options:
#   --quick              Guided 3-prompt flow: operator label, bootstrap peers,
#                        external multiaddr. Generates a secret-backed .env via
#                        setup-env.sh if .env is missing. Ideal for a new operator's
#                        first run.
#   --non-interactive    Skip all interactive prompts; read values from existing .env
#   --skip-build         Use existing Docker images (do not rebuild)
#   --skip-preflight     Skip hardware/port prereq checks
#   --skip-prereq-check  Alias for --skip-preflight
#   --dry-run            Print planned actions without executing them
#   --help               Show this message
#
# Environment variables consumed in --non-interactive mode:
#   WRFCOIN_OPERATOR_LABEL       Display name for this operator (optional)
#   BOOTSTRAP_PEERS              Comma-separated multiaddrs (else seeds.txt is used)
#   WRFCOIN_P2P_EXTERNAL_ADDR    Operator-supplied reachable multiaddr (required)
#
# Prerequisites (run on the N5 Pro inside CT 101 — verify IP with: ask the operator for the node host address):
#   - Docker 24+ and docker compose plugin installed
#   - Repos cloned to <src-root>/{infra,backend,core4,frontend}
#   - Run as root or a user in the docker group
#
# Related docs (printed in the success banner):
#   - docs/operator/nat-traversal.md           NAT / CGNAT / relay traversal guide
#   - docs/operator/fork-recovery-runbook.md   What to do when a fork alert fires
#
# Deployment constraint: images are built locally — NEVER pushed to a registry.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Compose file paths (relative to this script)
COMPOSE_BASE="${SCRIPT_DIR}/docker-compose.testnet.yml"
COMPOSE_OVERRIDE="${SCRIPT_DIR}/docker-compose.override.yml"

# Defaults
NON_INTERACTIVE=false
SKIP_BUILD=false
SKIP_PREFLIGHT=false
QUICK_MODE=false
DRY_RUN=false

# Thresholds for preflight
MIN_RAM_MB=14336     # 14 GB (16 GB recommended; leave 2 GB headroom)
MIN_DISK_GB=40       # 40 GB free on Docker data root
P2P_PORT=9000
API_PORT=8556
BACKEND_PORT=4001
HEALTH_TIMEOUT=180   # seconds to wait for all services

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
info()  { echo -e "${CYAN}[>]${NC} $*"; }
header(){ echo -e "${BOLD}${CYAN}${*}${NC}"; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --quick)             QUICK_MODE=true; shift ;;
      --non-interactive)   NON_INTERACTIVE=true; shift ;;
      --skip-build)        SKIP_BUILD=true; shift ;;
      --skip-preflight)    SKIP_PREFLIGHT=true; shift ;;
      --skip-prereq-check) SKIP_PREFLIGHT=true; shift ;;
      --dry-run)           DRY_RUN=true; shift ;;
      --help|-h)
        awk '/^# =========/{ if (++n == 2) { print; exit } } n >= 1 { print }' "$0" \
          | sed 's/^# \?//'
        exit 0 ;;
      *)
        err "Unknown argument: $1"; exit 1 ;;
    esac
  done

  if [ "$QUICK_MODE" = true ] && [ "$NON_INTERACTIVE" = true ]; then
    err "--quick and --non-interactive are mutually exclusive."
    err "  --quick assumes an interactive user; --non-interactive reads .env as-is."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Dry-run helper — wrap state-changing commands
# ---------------------------------------------------------------------------
run() {
  if [ "$DRY_RUN" = true ]; then
    info "[dry-run] would run: $*"
    return 0
  fi
  "$@"
}

# ---------------------------------------------------------------------------
# CGNAT / private-range detection helper
#
# Returns 0 if the detected public IP falls in a CGNAT or private range
# (100.64/10 per RFC 6598, plus 10/8, 172.16/12, 192.168/16, 169.254/16).
# Returns 1 otherwise. Prints the detected IP on stdout either way.
# ---------------------------------------------------------------------------
detect_external_ip() {
  local ip=""
  for svc in "https://api.ipify.org" "https://ifconfig.me" "https://checkip.amazonaws.com"; do
    ip=$(curl -fsS --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]' || true)
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    ip=""
  done
  [ -z "$ip" ] && return 2
  printf '%s' "$ip"

  # Classify — return code tells caller
  local o1 o2
  o1=$(echo "$ip" | cut -d. -f1)
  o2=$(echo "$ip" | cut -d. -f2)
  if [ "$o1" = "10" ] \
     || [ "$o1" = "127" ] \
     || { [ "$o1" = "100" ] && [ "$o2" -ge 64 ] && [ "$o2" -le 127 ]; } \
     || { [ "$o1" = "172" ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]; } \
     || { [ "$o1" = "192" ] && [ "$o2" = "168" ]; } \
     || { [ "$o1" = "169" ] && [ "$o2" = "254" ]; }; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Step 0 (--quick only): guided operator prompts
#
# Ensures .env exists with generated secrets, then prompts for the three values
# a new operator typically needs to set: operator label, bootstrap peers,
# external multiaddr. Auto-detects external IP and CGNAT, suggests the relay
# fallback (see docs/operator/nat-traversal.md) when behind CGNAT.
# ---------------------------------------------------------------------------
quick_mode_prompts() {
  header "=== Step 0 (--quick): Guided setup ==="

  local env_file="${SCRIPT_DIR}/.env"

  if [ ! -f "$env_file" ]; then
    info ".env missing — generating secrets via setup-env.sh before guided prompts."
    run bash "${SCRIPT_DIR}/setup-env.sh"
  else
    info ".env already exists — will patch values but keep secrets."
  fi

  # --- Prompt 1: operator label ---
  local current_label default_label=""
  if [ -f "$env_file" ]; then
    current_label=$(grep '^WRFCOIN_OPERATOR_LABEL=' "$env_file" 2>/dev/null | cut -d= -f2- || true)
    default_label="${current_label:-}"
  fi
  echo ""
  read -r -p "Operator display name [${default_label:-anonymous}]: " WRFCOIN_OPERATOR_LABEL
  WRFCOIN_OPERATOR_LABEL="${WRFCOIN_OPERATOR_LABEL:-${default_label:-anonymous}}"

  # --- Prompt 2: bootstrap peers ---
  local default_peers=""
  if [ -f "${SCRIPT_DIR}/seeds.txt" ]; then
    default_peers=$(grep -v '^#' "${SCRIPT_DIR}/seeds.txt" | grep -v '^[[:space:]]*$' | tr '\n' ',' | sed 's/,$//' || true)
  fi
  echo ""
  if [ -n "$default_peers" ]; then
    info "Default bootstrap peers (from seeds.txt):"
    echo "$default_peers" | tr ',' '\n' | sed 's/^/    /'
  fi
  read -r -p "BOOTSTRAP_PEERS [ENTER for default]: " BOOTSTRAP_PEERS
  BOOTSTRAP_PEERS="${BOOTSTRAP_PEERS:-$default_peers}"

  # --- Prompt 3: external multiaddr ---
  local detected_ip="" cgnat=false
  echo ""
  info "Auto-detecting your public IP..."
  if detected_ip=$(detect_external_ip); then
    cgnat=true
  elif [ $? -eq 1 ]; then
    cgnat=false
  else
    detected_ip=""
    warn "Could not reach any IP detection service. Continuing without auto-detection."
  fi

  if [ -n "$detected_ip" ]; then
    log "Detected IP: ${detected_ip}"
    if [ "$cgnat" = true ]; then
      warn "This IP is in a CGNAT / private range. Inbound P2P on port ${P2P_PORT}"
      warn "likely will NOT be reachable from the internet."
      warn "See docs/operator/nat-traversal.md for the relay / Tier-3 fallback."
    fi
  fi

  local default_multiaddr=""
  if [ -n "$detected_ip" ] && [ "$cgnat" = false ]; then
    default_multiaddr="/ip4/${detected_ip}/tcp/${P2P_PORT}"
  fi

  read -r -p "WRFCOIN_P2P_EXTERNAL_ADDR [${default_multiaddr:-leave blank}]: " WRFCOIN_P2P_EXTERNAL_ADDR
  WRFCOIN_P2P_EXTERNAL_ADDR="${WRFCOIN_P2P_EXTERNAL_ADDR:-$default_multiaddr}"

  # --- Write back into .env ---
  if [ "$DRY_RUN" = false ]; then
    _patch_env_kv "$env_file" "WRFCOIN_OPERATOR_LABEL" "$WRFCOIN_OPERATOR_LABEL"
    _patch_env_kv "$env_file" "BOOTSTRAP_PEERS"        "$BOOTSTRAP_PEERS"
    _patch_env_kv "$env_file" "WRFCOIN_P2P_EXTERNAL_ADDR" "$WRFCOIN_P2P_EXTERNAL_ADDR"
    log "Wrote operator label, bootstrap peers, and external multiaddr to .env"
  else
    info "[dry-run] would write WRFCOIN_OPERATOR_LABEL=${WRFCOIN_OPERATOR_LABEL}"
    info "[dry-run] would write BOOTSTRAP_PEERS=${BOOTSTRAP_PEERS}"
    info "[dry-run] would write WRFCOIN_P2P_EXTERNAL_ADDR=${WRFCOIN_P2P_EXTERNAL_ADDR}"
  fi
}

# Helper: idempotently upsert KEY=VALUE in an env file.
_patch_env_kv() {
  local file="$1" key="$2" val="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    # Escape | for sed replacement
    local esc
    esc=$(printf '%s\n' "$val" | sed 's/[|&]/\\&/g')
    sed -i "s|^${key}=.*|${key}=${esc}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

# ---------------------------------------------------------------------------
# Step 1: Preflight checks
# ---------------------------------------------------------------------------
preflight() {
  header "=== Step 1: Preflight checks ==="

  local preflight_ok=true

  # Docker
  if command -v docker &>/dev/null; then
    local docker_ver
    docker_ver=$(docker --version 2>&1 | grep -oP '\d+\.\d+' | head -1)
    local docker_major
    docker_major=$(echo "$docker_ver" | cut -d. -f1)
    if [ "${docker_major:-0}" -ge 24 ]; then
      log "Docker:  $(docker --version)"
    else
      err "Docker version ${docker_ver} is too old. Requires 24+."
      err "Run: bash scripts/operator-install.sh --skip-build"
      preflight_ok=false
    fi
  else
    err "Docker not found. Install it first:"
    err "  bash scripts/operator-install.sh --skip-build"
    preflight_ok=false
  fi

  # Docker Compose plugin
  if docker compose version &>/dev/null 2>&1; then
    log "Compose: $(docker compose version)"
  else
    err "docker compose plugin not found."
    err "Install: apt-get install docker-compose-plugin"
    preflight_ok=false
  fi

  # RAM
  local ram_mb
  ram_mb=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo)
  if [ "${ram_mb:-0}" -ge $MIN_RAM_MB ]; then
    log "RAM:     ${ram_mb} MB (>= ${MIN_RAM_MB} MB required)"
  else
    err "Insufficient RAM: ${ram_mb} MB (need at least ${MIN_RAM_MB} MB / ~14 GB)"
    preflight_ok=false
  fi

  # Disk
  local disk_root
  disk_root=$(df -BG / 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4}' || echo 0)
  local docker_root
  docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")
  local disk_docker
  disk_docker=$(df -BG "$docker_root" 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4}' || echo 0)
  local disk_gb
  disk_gb=$((disk_docker > disk_root ? disk_docker : disk_root))

  if [ "${disk_gb:-0}" -ge $MIN_DISK_GB ]; then
    log "Disk:    ${disk_gb} GB free on Docker root (>= ${MIN_DISK_GB} GB required)"
  else
    warn "Low disk space: ${disk_gb} GB free on Docker root (recommend >= ${MIN_DISK_GB} GB)"
    warn "  Large images and blockchain data may exceed this. Continue? (y/N)"
    if [ "$NON_INTERACTIVE" = false ]; then
      read -r -t 30 confirm || confirm="n"
      [ "${confirm,,}" = "y" ] || { err "Aborted."; exit 1; }
    fi
  fi

  # Port 9000 (P2P) — check if bound already
  if command -v ss &>/dev/null; then
    if ss -tlnp 2>/dev/null | grep -q ":${P2P_PORT}"; then
      warn "Port ${P2P_PORT} is already in use. The P2P listener may conflict."
      warn "  Check: ss -tlnp | grep ${P2P_PORT}"
    else
      log "Port:    ${P2P_PORT} available"
    fi
  fi

  # openssl (needed by setup-env.sh)
  if command -v openssl &>/dev/null; then
    log "openssl: $(openssl version)"
  else
    err "openssl not found. Install: apt-get install openssl"
    preflight_ok=false
  fi

  # python3 (needed by setup-env.sh to render AlertManager config)
  if command -v python3 &>/dev/null; then
    log "python3: $(python3 --version 2>&1)"
  else
    err "python3 not found. Install Python 3 before running setup-env.sh."
    preflight_ok=false
  fi

  # Compose files
  if [ ! -f "$COMPOSE_BASE" ]; then
    err "Missing compose file: ${COMPOSE_BASE}"
    err "Ensure the infra repo is cloned and you are in the correct directory."
    preflight_ok=false
  fi
  if [ ! -f "$COMPOSE_OVERRIDE" ]; then
    err "Missing override file: ${COMPOSE_OVERRIDE}"
    preflight_ok=false
  fi

  if [ "$preflight_ok" = false ]; then
    err "Preflight failed. Fix the errors above and rerun."
    exit 1
  fi

  log "All preflight checks passed."
}

# ---------------------------------------------------------------------------
# Step 2: Generate secrets
# ---------------------------------------------------------------------------
generate_secrets() {
  header "=== Step 2: Secret generation ==="

  local env_file="${SCRIPT_DIR}/.env"

  if [ -f "$env_file" ]; then
    info ".env already exists — skipping generation."
    info "  To regenerate: rm ${env_file} && bash setup-env.sh"
    return
  fi

  log "Generating secrets via setup-env.sh..."

  if [ "$NON_INTERACTIVE" = true ]; then
    run bash "${SCRIPT_DIR}/setup-env.sh"
  else
    echo ""
    warn "About to generate testnet secrets (.env, prometheus-web.yml, bearer token, alertmanager.rendered.yml)."
    warn "The secrets will be printed once — save them in a password manager."
    warn "Proceed? (Y/n)"
    read -r -t 30 confirm || confirm="y"
    if [[ "${confirm,,}" == "n" ]]; then
      err "Aborted. Rerun when ready."
      exit 1
    fi
    run bash "${SCRIPT_DIR}/setup-env.sh"
  fi

  log "Secrets generated. Save the credentials printed above."
}

# ---------------------------------------------------------------------------
# Seed reachability check — uses scripts/testnet/check-seeds.sh to validate
# that seeds.txt entries parse. In --quick mode this is a fail-fast guard:
# an operator with a broken seeds.txt should hear about it before docker builds.
# ---------------------------------------------------------------------------
check_seed_reachability() {
  header "=== Seed reachability preflight ==="

  local checker="${SCRIPT_DIR}/check-seeds.sh"
  if [ ! -x "$checker" ]; then
    warn "check-seeds.sh not executable; skipping seed reachability preflight."
    return
  fi

  if run bash "$checker" >/dev/null 2>&1; then
    log "seeds.txt validated."
  else
    err "seeds.txt failed validation — run ${checker} to see errors."
    if [ "$QUICK_MODE" = true ]; then
      err "In --quick mode, aborting on seed validation failure."
      exit 1
    fi
    warn "Continuing despite seed failure (not --quick)."
  fi
}

# ---------------------------------------------------------------------------
# P2P advertised-address guard — fail closed before a node mutation.
# The value is operator-supplied and must accept a bounded TCP reachability
# proof; syntax-only validation is reserved for explicitly marked tests.
# ---------------------------------------------------------------------------
validate_p2p_external_addr() {
  header "=== P2P advertised-address preflight ==="

  run_p2p_config_validation
  log "P2P advertised address passed bounded reachability validation."
}

run_p2p_config_validation() {
  local checker="${SCRIPT_DIR}/check-p2p-external-addr.sh"
  local env_file="${SCRIPT_DIR}/.env"

  [ -f "$checker" ] || {
    err "Missing P2P advertised-address checker: ${checker}"
    exit 1
  }
  if [ -n "${WRFCOIN_P2P_EXTERNAL_ADDR:-}" ]; then
    bash "$checker" --require "$WRFCOIN_P2P_EXTERNAL_ADDR"
  else
    bash "$checker" --env-file "$env_file" --require
  fi
}

# ---------------------------------------------------------------------------
# Post-start P2P validation repeats the bounded proof after the node starts.
# ---------------------------------------------------------------------------
post_start_p2p_validation() {
  header "=== Post-start P2P advertised-address validation ==="
  run_p2p_config_validation
  info "Post-start reachability validation passed."
}

# ---------------------------------------------------------------------------
# Step 3: Ensure Prometheus config exists
# ---------------------------------------------------------------------------
ensure_prometheus_config() {
  header "=== Step 3: Prometheus config ==="

  local prom_web="${SCRIPT_DIR}/prometheus-web.yml"

  if [ -f "$prom_web" ]; then
    info "prometheus-web.yml already exists."
    return
  fi

  local example="${SCRIPT_DIR}/prometheus-web.yml.example"
  if [ -f "$example" ]; then
    info "Copying prometheus-web.yml from example..."
    run cp "$example" "$prom_web"
    # prom/prometheus runs as uid/gid 65534, so this bind-mounted file must
    # be readable by the non-root container user.
    run chmod 644 "$prom_web"
    warn "prometheus-web.yml copied from example — run setup-env.sh to generate"
    warn "a real bcrypt hash before exposing Prometheus to external hosts."
  else
    warn "No prometheus-web.yml found and no example available."
    warn "Creating a minimal placeholder — replace before production use."
    if [ "$DRY_RUN" = true ]; then
      info "[dry-run] would write placeholder prometheus-web.yml to ${prom_web}"
    else
      cat > "$prom_web" << 'EOF'
# Placeholder — generated by bootstrap.sh
# Replace with a real bcrypt hash via: setup-env.sh
basic_auth_users:
  admin: $2y$10$PLACEHOLDER_REPLACE_ME_WITH_REAL_BCRYPT_HASH
EOF
      chmod 644 "$prom_web"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Step 4: Fetch seed peers
# ---------------------------------------------------------------------------
fetch_seed_peers() {
  header "=== Step 4: Seed peers ==="

  local seeds_file="${SCRIPT_DIR}/seeds.txt"
  local env_file="${SCRIPT_DIR}/.env"

  # Read active (non-comment, non-empty) seeds
  local active_seeds=""
  if [ -f "$seeds_file" ]; then
    active_seeds=$(grep -v '^#' "$seeds_file" | grep -v '^[[:space:]]*$' | tr '\n' ',' | sed 's/,$//')
  fi

  if [ -z "$active_seeds" ]; then
    info "No seed peers in seeds.txt yet — BOOTSTRAP_PEERS will be empty."
    info "  Coordinate with other operators on Discord to get peer addresses."
    return
  fi

  log "Found seed peers:"
  echo "$active_seeds" | tr ',' '\n' | while read -r peer; do
    info "  $peer"
  done

  # Update BOOTSTRAP_PEERS in .env if it is still blank
  if [ -f "$env_file" ]; then
    local current_peers
    current_peers=$(grep '^BOOTSTRAP_PEERS=' "$env_file" | cut -d= -f2-)
    if [ -z "$current_peers" ]; then
      if [ "$DRY_RUN" = true ]; then
        info "[dry-run] would set BOOTSTRAP_PEERS=${active_seeds} in .env"
      else
        sed -i "s|^BOOTSTRAP_PEERS=.*|BOOTSTRAP_PEERS=${active_seeds}|" "$env_file"
        log "BOOTSTRAP_PEERS updated in .env."
      fi
    else
      info "BOOTSTRAP_PEERS already set — not overwriting."
    fi
  fi
}

# ---------------------------------------------------------------------------
# Step 5: Build Docker images
# ---------------------------------------------------------------------------
build_images() {
  header "=== Step 5: Docker image build ==="

  if [ "$SKIP_BUILD" = true ]; then
    info "--skip-build set — using existing images."
    return
  fi

  ensure_workspace_dockerignore
  run bash "${SCRIPT_DIR}/scripts/render-cut-overlay.sh"

  log "Building images from local source (this takes 5–15 minutes first time)..."
  log "  No image registry — all builds are local."

  run docker compose \
    -f "$COMPOSE_BASE" \
    -f "$COMPOSE_OVERRIDE" \
    build \
    --parallel

  log "Images built."
}

ensure_workspace_dockerignore() {
  local template="${SCRIPT_DIR}/workspace.dockerignore"
  local env_file="${SCRIPT_DIR}/.env"
  local workspace_root="${WRFCOIN_ROOT:-}"
  local target

  if [ -z "$workspace_root" ] && [ -f "$env_file" ]; then
    workspace_root=$(awk -F= '
      /^[[:space:]]*WRFCOIN_ROOT[[:space:]]*=/ {
        value=$0
        sub(/^[^=]*=/, "", value)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        gsub(/^["\047]|["\047]$/, "", value)
        print value
        exit
      }
    ' "$env_file")
  fi
  # Only parse path assignments, never source the operator's complete env file.
  local src_root="${WRFCOIN_SRC_ROOT:-}"
  local deploy_root="${WRFCOIN_DEPLOY_ROOT:-}"
  if [ -f "$env_file" ]; then
    [ -n "$src_root" ] || src_root=$(awk -F= '$1 ~ /^[[:space:]]*WRFCOIN_SRC_ROOT[[:space:]]*$/ {sub(/^[^=]*=/, ""); gsub(/^[[:space:]\042\047]+|[[:space:]\042\047]+$/, ""); print; exit}' "$env_file")
    [ -n "$deploy_root" ] || deploy_root=$(awk -F= '$1 ~ /^[[:space:]]*WRFCOIN_DEPLOY_ROOT[[:space:]]*$/ {sub(/^[^=]*=/, ""); gsub(/^[[:space:]\042\047]+|[[:space:]\042\047]+$/, ""); print; exit}' "$env_file")
  fi
  case "$workspace_root" in
    '${WRFCOIN_DEPLOY_ROOT}'|'${WRFCOIN_DEPLOY_ROOT:-/path/to/wrfcoin-deploy}') workspace_root="$deploy_root" ;;
  esac
  workspace_root="${workspace_root:-${src_root:-/path/to/wrfcoin-src}}"
  target="${workspace_root}/.dockerignore"

  [ -f "$template" ] || {
    err "Missing canonical workspace ignore template: ${template}"
    exit 1
  }

  if [ ! -d "$workspace_root" ]; then
    err "WRFCOIN_ROOT does not exist: ${workspace_root}"
    err "Set WRFCOIN_ROOT to the directory containing infra, backend, core4, and frontend."
    exit 1
  fi

  if [ -f "$target" ]; then
    if cmp -s "$template" "$target"; then
      log "Workspace Docker ignore is current: ${target}"
      return
    fi
    err "Workspace Docker ignore differs from the canonical template: ${target}"
    err "Review the diff, then replace it with ${template} before building."
    exit 1
  fi

  if [ "$DRY_RUN" = true ]; then
    info "[dry-run] would install ${template} as ${target}"
    return
  fi

  install -m 0644 "$template" "$target"
  log "Installed workspace Docker ignore: ${target}"
}

# ---------------------------------------------------------------------------
# Step 6: Start the testnet stack
# ---------------------------------------------------------------------------
start_stack() {
  header "=== Step 6: Start testnet stack ==="

  run docker compose \
    -f "$COMPOSE_BASE" \
    -f "$COMPOSE_OVERRIDE" \
    up -d

  log "Stack started."
}

# ---------------------------------------------------------------------------
# Post-start peer poll — briefly watch /network/info so the operator sees
# peer_count and chain_height moving in real time. Used by --quick mode.
# ---------------------------------------------------------------------------
poll_peer_progress() {
  local deadline=$((SECONDS + 60))
  local prev_peers=-1 prev_height=-1

  if [ "$DRY_RUN" = true ]; then
    info "[dry-run] would poll http://localhost:${API_PORT}/network/info for 60s"
    return 0
  fi

  info "Polling /network/info for 60s to show live peer and height activity..."
  while [ $SECONDS -lt $deadline ]; do
    local info_json peers height
    info_json=$(curl -sf "http://localhost:${API_PORT}/network/info" 2>/dev/null || echo "{}")
    peers=$(echo "$info_json"  | jq -r '.peer_count   // 0' 2>/dev/null || echo 0)
    height=$(echo "$info_json" | jq -r '.chain_height // 0' 2>/dev/null || echo 0)

    if [ "$peers" != "$prev_peers" ] || [ "$height" != "$prev_height" ]; then
      printf "\r${CYAN}[>]${NC}  peers=%-4s height=%-10s    " "$peers" "$height"
      prev_peers="$peers"
      prev_height="$height"
    fi
    sleep 2
  done
  echo ""

  if [ "$prev_peers" -gt 0 ] 2>/dev/null; then
    log "Peer connection established (final peer_count=${prev_peers}, height=${prev_height})."
  else
    warn "No peers seen after 60s."
    warn "  Possible causes:"
    warn "    - Port ${P2P_PORT} not reachable from seed peer (see docs/operator/nat-traversal.md)"
    warn "    - BOOTSTRAP_PEERS empty or stale (bash ${SCRIPT_DIR}/check-seeds.sh)"
    warn "    - Seed peer offline"
  fi
}

# ---------------------------------------------------------------------------
# Step 7: Health polling
# ---------------------------------------------------------------------------
wait_for_health() {
  header "=== Step 7: Waiting for services to become healthy ==="

  if [ "$DRY_RUN" = true ]; then
    info "[dry-run] would poll http://localhost:${API_PORT}/readyz and http://localhost:${BACKEND_PORT}/health (up to ${HEALTH_TIMEOUT}s)"
    return 0
  fi

  local elapsed=0
  local interval=5
  local node_ok=false
  local backend_ok=false

  info "Polling /readyz and /health (timeout: ${HEALTH_TIMEOUT}s)..."

  while [ $elapsed -lt $HEALTH_TIMEOUT ]; do
    if curl -sf "http://localhost:${API_PORT}/readyz" >/dev/null 2>&1; then
      node_ok=true
    fi
    if curl -sf "http://localhost:${BACKEND_PORT}/health" >/dev/null 2>&1; then
      backend_ok=true
    fi

    if [ "$node_ok" = true ] && [ "$backend_ok" = true ]; then
      log "Services healthy after ${elapsed}s."
      return 0
    fi

    # Progress indicator
    local waiting=""
    [ "$node_ok" = false ]    && waiting+=" node"
    [ "$backend_ok" = false ] && waiting+=" backend"
    printf "\r${CYAN}[>]${NC}  %3ds — waiting for:%s   " "$elapsed" "$waiting"
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo ""
  err "Services did not become healthy within ${HEALTH_TIMEOUT}s."
  err "Troubleshoot:"
  err "  docker compose -f ${COMPOSE_BASE} logs --tail=50"
  err "  docker compose -f ${COMPOSE_BASE} ps"
  return 1
}

# ---------------------------------------------------------------------------
# Step 8: Install backup cron (idempotent)
# ---------------------------------------------------------------------------
install_backup_cron() {
  header "=== Step 8: Backup cron ==="

  local cron_entry="0 3 * * * cd ${SCRIPT_DIR} && bash backup.sh >> /var/log/wrfcoin-backup.log 2>&1"

  if crontab -l 2>/dev/null | grep -qF "backup.sh"; then
    info "Backup cron already installed — skipping."
    return
  fi

  if [ "$DRY_RUN" = true ]; then
    info "[dry-run] would install crontab entry: ${cron_entry}"
    return
  fi

  # Append to existing crontab (or create from scratch if none exists)
  ( crontab -l 2>/dev/null; echo "$cron_entry" ) | crontab -
  log "Backup cron installed: daily at 03:00, logs → /var/log/wrfcoin-backup.log"
}

# ---------------------------------------------------------------------------
# Step 9: Print success banner
# ---------------------------------------------------------------------------
print_banner() {
  echo ""

  # Fetch peer info from the running node
  local node_info peer_id block_height local_ip p2p_multiaddr
  node_info=$(curl -sf "http://localhost:${API_PORT}/node/info" 2>/dev/null || echo "{}")
  peer_id=$(echo "$node_info" | jq -r '.peer_id // "pending"' 2>/dev/null || echo "pending")
  block_height=$(echo "$node_info" | jq -r '.block_height // 0' 2>/dev/null || echo "0")
  local_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")

  if [ -n "$peer_id" ] && [ "$peer_id" != "pending" ]; then
    p2p_multiaddr="/ip4/${local_ip}/tcp/${P2P_PORT}/p2p/${peer_id}"
  else
    p2p_multiaddr="(peer ID not yet available — try again in 30s)"
  fi

  echo -e "${GREEN}${BOLD}"
  cat << 'BANNER'
  __        ______  _____ ____      _
  \ \      / /  _ \|  ___/ ___|___ (_)_ __
   \ \ /\ / /| |_) | |_ | |   / _ \| | '_ \
    \ V  V / |  _ <|  _|| |__| (_) | | | | |
     \_/\_/  |_| \_\_|   \____\___/|_|_| |_|

  Testnet Node — Online
BANNER
  echo -e "${NC}"

  printf "%-20s %s\n" "Peer ID:"    "$peer_id"
  printf "%-20s %s\n" "Block height:" "$block_height"
  printf "%-20s %s\n" "API:"        "http://localhost:${API_PORT}"
  printf "%-20s %s\n" "Backend:"    "http://localhost:${BACKEND_PORT}"
  printf "%-20s %s\n" "P2P port:"   "${P2P_PORT} (open inbound in your firewall/router)"
  printf "%-20s %s\n" "Grafana:"    "http://localhost:3100"
  echo ""
  printf "%-20s %s\n" "Multiaddr:" "$p2p_multiaddr"
  echo ""
  echo "  Share with other operators:"
  echo "  ${p2p_multiaddr}"
  echo ""
  echo "  Next-steps docs:"
  echo "    docs/operator/nat-traversal.md          — if peer_count stays at 0"
  echo "    docs/operator/fork-recovery-runbook.md  — if a ChainForkActive alert fires"
  echo "    testnet/TESTNET_OPERATOR_GUIDE.md       — full operator reference"
  echo ""
  echo "  Useful commands:"
  echo "    # Live logs"
  echo "    docker compose -f ${COMPOSE_BASE} -f ${COMPOSE_OVERRIDE} logs -f"
  echo ""
  echo "    # Stop node"
  echo "    docker compose -f ${COMPOSE_BASE} -f ${COMPOSE_OVERRIDE} down"
  echo ""
  echo "    # Redeploy after code update"
  echo "    bash ${SCRIPT_DIR}/bootstrap.sh --skip-preflight"
  echo ""
  echo "    # Re-run guided setup (rewrites operator label / peers / multiaddr)"
  echo "    bash ${SCRIPT_DIR}/bootstrap.sh --quick --skip-build"
  echo ""
  echo "    # Troubleshoot: reachability, peers, fork state"
  echo "    curl -s http://localhost:${API_PORT}/network/info | jq"
  echo "    curl -s http://localhost:${API_PORT}/chain/info   | jq"
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  echo ""
  echo -e "${BOLD}WRFCoin Testnet Bootstrap${NC}"
  echo -e "  Script dir: ${SCRIPT_DIR}"
  [ "$QUICK_MODE" = true ] && echo -e "  Mode:       ${BOLD}--quick${NC} (guided)"
  [ "$DRY_RUN"    = true ] && echo -e "  Mode:       ${BOLD}--dry-run${NC} (no state changes)"
  echo ""

  if [ "$SKIP_PREFLIGHT" = false ]; then
    preflight
  else
    warn "--skip-preflight: skipping hardware/port checks."
  fi

  if [ "$QUICK_MODE" = true ]; then
    quick_mode_prompts
  fi

  generate_secrets
  ensure_prometheus_config
  fetch_seed_peers
  check_seed_reachability
  validate_p2p_external_addr
  build_images
  start_stack
  wait_for_health
  post_start_p2p_validation
  install_backup_cron

  if [ "$QUICK_MODE" = true ]; then
    poll_peer_progress
  fi

  print_banner
}

main "$@"
