#!/usr/bin/env bash
# bootstrap.sh — First-time setup for WRFCoin testnet development
#
# Works on: Linux (Ubuntu/Debian), macOS, and Windows (Git Bash / MSYS2)
# Idempotent: safe to re-run at any time.
#
# Usage:
#   bash infra/scripts/bootstrap.sh          # from wrfcoin/ root
#   bash scripts/bootstrap.sh               # from infra/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$INFRA_DIR/.." && pwd)"
CORE4_DIR="$ROOT/core4"
BACKEND_DIR="$ROOT/backend"

# ── colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLU}[bootstrap]${NC} $*"; }
ok()    { echo -e "${GRN}[bootstrap]${NC} $*"; }
warn()  { echo -e "${YLW}[bootstrap]${NC} $*"; }
error() { echo -e "${RED}[bootstrap]${NC} $*" >&2; }

# ── platform detection ─────────────────────────────────────────────────────────
detect_platform() {
  case "$(uname -s 2>/dev/null)" in
    Darwin*)           PLATFORM="macos" ;;
    Linux*)            PLATFORM="linux" ;;
    MINGW*|CYGWIN*|MSYS*) PLATFORM="windows" ;;
    *)                 PLATFORM="unknown" ;;
  esac
}

install_hint() {
  local tool="$1"
  case "$tool" in
    docker)
      case "$PLATFORM" in
        linux)   echo "  sudo apt-get install -y docker.io && sudo systemctl start docker" ;;
        macos)   echo "  brew install --cask docker   # then launch Docker Desktop" ;;
        windows) echo "  Download Docker Desktop from https://www.docker.com/products/docker-desktop/" ;;
      esac ;;
    docker-compose)
      case "$PLATFORM" in
        linux)   echo "  sudo apt-get install -y docker-compose-plugin  OR  pip install docker-compose" ;;
        macos)   echo "  Included with Docker Desktop" ;;
        windows) echo "  Included with Docker Desktop" ;;
      esac ;;
    node|npm)
      case "$PLATFORM" in
        linux)   echo "  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt-get install -y nodejs" ;;
        macos)   echo "  brew install node@20" ;;
        windows) echo "  Download from https://nodejs.org/  (LTS, 20+)" ;;
      esac ;;
    cargo)
      echo "  curl https://sh.rustup.rs -sSf | sh   # all platforms" ;;
    jq)
      case "$PLATFORM" in
        linux)   echo "  sudo apt-get install -y jq" ;;
        macos)   echo "  brew install jq" ;;
        windows) echo "  winget install jqlang.jq   (run in admin PowerShell)" ;;
      esac ;;
  esac
}

# ── dependency checks ──────────────────────────────────────────────────────────
check_deps() {
  local missing=()

  for tool in docker node npm cargo jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing+=("$tool")
    fi
  done

  # docker-compose: accept either standalone or the compose plugin
  if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
    missing+=("docker-compose")
  fi

  # docker daemon running?
  if command -v docker >/dev/null 2>&1 && ! docker info >/dev/null 2>&1; then
    warn "Docker is installed but the daemon isn't running."
    case "$PLATFORM" in
      linux)   warn "  Start it: sudo systemctl start docker" ;;
      macos|windows) warn "  Launch Docker Desktop first." ;;
    esac
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    error "Missing required tools:"
    for tool in "${missing[@]}"; do
      error "  • $tool"
      error "$(install_hint "$tool")"
    done
    error ""
    error "Install the above tools then re-run: bash infra/scripts/bootstrap.sh"
    exit 1
  fi

  ok "All required tools found."
}

# ── secret generation ──────────────────────────────────────────────────────────
gen_hex() {
  # Generates N random bytes as lowercase hex (default 32 bytes = 64 hex chars)
  local bytes="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    node -e "process.stdout.write(require('crypto').randomBytes(${bytes}).toString('hex'))"
  fi
}

gen_b64() {
  # Generates N random bytes as base64 (default 32 bytes)
  local bytes="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 "$bytes" | tr -d '\n'
  else
    node -e "process.stdout.write(require('crypto').randomBytes(${bytes}).toString('base64'))"
  fi
}

# ── env file generation ────────────────────────────────────────────────────────
generate_envs() {
  if [ -f "$CORE4_DIR/.env" ] && [ -f "$BACKEND_DIR/.env" ]; then
    ok "core4/.env and backend/.env already exist — skipping generation."
    return 0
  fi

  info "Generating dev secrets..."
  local op_token redis_pass postgres_pass jwt_secret session_secret
  op_token="$(gen_hex 32)"         # 64 hex chars — WRFCOIN_OPERATOR_TOKEN
  redis_pass="$(gen_hex 16)"       # 32 hex chars
  postgres_pass="$(gen_hex 16)"    # 32 hex chars
  jwt_secret="$(gen_b64 32)"
  session_secret="$(gen_b64 32)"

  # ── core4/.env ────────────────────────────────────────────────────────────
  if [ ! -f "$CORE4_DIR/.env" ]; then
    info "Writing core4/.env ..."
    cat > "$CORE4_DIR/.env" <<EOF
# WRFCoin core4 dev environment — generated by bootstrap.sh
# Fill in the API keys below, then run ./start-testnet.sh
NODE_ENV=development
LOG_LEVEL=debug

# ── API Keys (fill these in) ──────────────────────────────────────────────────
ANTHROPIC_API_KEY=FILL_IN_sk-ant-...
PERPLEXITY_API_KEY=FILL_IN_pplx-...     # optional
OPENAI_API_KEY=FILL_IN_sk-proj-...      # optional

# ── Auth (auto-generated) ─────────────────────────────────────────────────────
WRFCOIN_OPERATOR_TOKEN=${op_token}
JWT_SECRET=${jwt_secret}
SESSION_SECRET=${session_secret}
MFA_MASTER_KEY=dev-mfa-key-not-for-production

# ── Database ──────────────────────────────────────────────────────────────────
POSTGRES_DEV_PASSWORD=${postgres_pass}
DATABASE_URL=postgresql://wrfcoin:${postgres_pass}@127.0.0.1:5432/wrfcoin
DATABASE_SSL=false
DB_POOL_SIZE=5

# ── Redis ─────────────────────────────────────────────────────────────────────
REDIS_PASSWORD=${redis_pass}
ORACLE_REDIS_PASSWORD=${redis_pass}
REDIS_URL=redis://:${redis_pass}@127.0.0.1:6379

# ── HSM (dev mock) ────────────────────────────────────────────────────────────
HSM_MOCK_MODE=true
PKCS11_LIB=/usr/lib/libykcs11.so
HSM_SLOT=0

# ── Blockchain ────────────────────────────────────────────────────────────────
BLOCKCHAIN_NODE_URL=http://localhost:8080
NETWORK_ID=testnet

# ── CORS ──────────────────────────────────────────────────────────────────────
CORS_ORIGIN=${CORS_ORIGIN:-http://localhost:3001}
ALLOWED_HOSTS=localhost,127.0.0.1

# ── Monitoring (dev defaults) ─────────────────────────────────────────────────
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=dev-grafana-pass
PROMETHEUS_ADMIN_USER=prometheus
PROMETHEUS_ADMIN_PASSWORD=dev-prometheus-pass
EOF
    ok "core4/.env created."
  else
    ok "core4/.env already exists — skipping."
  fi

  # ── backend/.env ──────────────────────────────────────────────────────────
  if [ ! -f "$BACKEND_DIR/.env" ]; then
    info "Writing backend/.env ..."
    cat > "$BACKEND_DIR/.env" <<EOF
# WRFCoin backend dev environment — generated by bootstrap.sh
NODE_ENV=development
LOG_LEVEL=debug

# ── Auth ──────────────────────────────────────────────────────────────────────
JWT_SECRET=${jwt_secret}
SESSION_SECRET=${session_secret}

# ── Database ──────────────────────────────────────────────────────────────────
DATABASE_URL=postgresql://wrfcoin:${postgres_pass}@127.0.0.1:5432/wrfcoin
DATABASE_SSL=false

# ── Redis ─────────────────────────────────────────────────────────────────────
REDIS_PASSWORD=${redis_pass}
REDIS_URL=redis://:${redis_pass}@127.0.0.1:6379

# ── HSM (dev mock) ────────────────────────────────────────────────────────────
HSM_MOCK_MODE=true

# ── Blockchain ────────────────────────────────────────────────────────────────
BLOCKCHAIN_NODE_URL=http://localhost:8080
NETWORK_ID=testnet

# ── CORS ──────────────────────────────────────────────────────────────────────
CORS_ORIGIN=${CORS_ORIGIN:-http://localhost:3001}
EOF
    ok "backend/.env created."
  else
    ok "backend/.env already exists — skipping."
  fi
}

# ── docker-compose.dev.yml at root ────────────────────────────────────────────
ensure_compose_file() {
  local src="$INFRA_DIR/docker-compose.dev.yml"
  local dst="$ROOT/docker-compose.dev.yml"

  if [ ! -f "$src" ]; then
    warn "infra/docker-compose.dev.yml not found — skipping root copy."
    return 0
  fi

  if [ -f "$dst" ]; then
    ok "docker-compose.dev.yml already at root — skipping."
    return 0
  fi

  cp "$src" "$dst"
  ok "Copied docker-compose.dev.yml to wrfcoin/ root."
}

# ── start-testnet.sh wrapper at root ──────────────────────────────────────────
ensure_start_script() {
  local dst="$ROOT/start-testnet.sh"

  if [ -f "$dst" ]; then
    ok "start-testnet.sh already exists at root — skipping."
    return 0
  fi

  info "Creating start-testnet.sh at root ..."
  cat > "$dst" <<'STARTSCRIPT'
#!/usr/bin/env bash
# start-testnet.sh — Launch the WRFCoin testnet (created by bootstrap.sh)
#
# Usage:
#   ./start-testnet.sh               # standard launch
#   ./start-testnet.sh --fast        # skip long readiness timeouts
#   ./start-testnet.sh --clean       # wipe docker volumes first
#   ./start-testnet.sh --skip-smoke  # skip CLI smoke checks
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH_SCRIPT="$ROOT/infra/scripts/relaunch-testnet-stack.sh"

if [ ! -f "$LAUNCH_SCRIPT" ]; then
  echo "ERROR: $LAUNCH_SCRIPT not found."
  echo "Is the infra/ repo present? Run: bash pull-all.sh"
  exit 1
fi

# Source env files so REDIS_PASSWORD / POSTGRES_DEV_PASSWORD are exported
# to docker-compose without requiring manual `export` before each launch.
# Variables already in the shell environment take precedence.
if [ -z "${REDIS_PASSWORD:-}" ]; then
  for _env in "$ROOT/core4/.env" "$ROOT/backend/.env"; do
    if [ -f "$_env" ]; then
      set -a
      # shellcheck disable=SC1090
      source "$_env"
      set +a
      break
    fi
  done
  unset _env
fi

exec "$LAUNCH_SCRIPT" "$@"
STARTSCRIPT

  chmod +x "$dst"
  ok "start-testnet.sh created."
}

# ── final instructions ─────────────────────────────────────────────────────────
print_next_steps() {
  echo ""
  echo -e "${GRN}════════════════════════════════════════════════════════════${NC}"
  echo -e "${GRN} Bootstrap complete!${NC}"
  echo -e "${GRN}════════════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${YLW}Manual steps required:${NC}"
  echo ""
  echo "  1. Fill in your API keys in core4/.env:"
  echo "       ANTHROPIC_API_KEY=sk-ant-...    (required for AI features)"
  echo "       PERPLEXITY_API_KEY=pplx-...     (optional)"
  echo ""
  echo "  2. Start the testnet:"
  echo "       ./start-testnet.sh              (standard)"
  echo "       ./start-testnet.sh --fast       (skip long timeouts)"
  echo "       ./start-testnet.sh --clean      (wipe Docker volumes first)"
  echo ""
  echo "  3. First-time database setup (after the testnet starts):"
  echo "       cd core4 && npm run db:setup"
  echo ""
  echo -e "${GRN}════════════════════════════════════════════════════════════${NC}"
  echo ""
}

# ── main ───────────────────────────────────────────────────────────────────────
main() {
  echo ""
  info "WRFCoin testnet bootstrap"
  info "Root: $ROOT"
  info "Platform: detecting..."

  detect_platform
  info "Platform: $PLATFORM"
  echo ""

  check_deps
  generate_envs
  ensure_compose_file
  ensure_start_script
  print_next_steps
}

main "$@"
