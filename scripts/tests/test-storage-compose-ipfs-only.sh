#!/usr/bin/env bash
# The storage stack ships the REAL storage-node daemon, IPFS-only, with a
# self-hosted kubo and no paid providers in the default render
# (storage-providers#65/#69, infra#944; owner ruling 2026-10-01).
#
# Render-only: `docker compose config` with dummy values. It never builds,
# pulls or starts anything. Each property also has a RED control that mutates a
# copy and must fail, so a check that goes blind is caught.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKERFILE="${ROOT}/infra/docker/Dockerfile.storage"
STORAGE_COMPOSE="${ROOT}/infra/docker/docker-compose.storage.yml"
DEV_COMPOSE="${ROOT}/infra/docker/docker-compose.yml"

fail() {
  printf 'STORAGE_IPFS_ONLY=FAIL %s\n' "$*" >&2
  exit 1
}

if ! docker compose version >/dev/null 2>&1; then
  printf '%s\n' 'STORAGE_IPFS_ONLY=VOID docker compose is not available; nothing was rendered' >&2
  exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
dummy_env="${tmp}/dummy.env"
# Placeholders only: the dev compose refuses to render without these names.
printf '%s\n' REDIS_PASSWORD=dummy DATABASE_URL=dummy REDIS_URL=dummy JWT_SECRET=dummy \
  > "$dummy_env"

render() { # render <compose> [profile] -> JSON on stdout
  local file="$1" profile="${2:-}"
  if [[ -n "$profile" ]]; then
    docker compose --env-file "$dummy_env" -f "$file" --profile "$profile" config --format json
  else
    docker compose --env-file "$dummy_env" -f "$file" config --format json
  fi
}

check_dockerfile() { # check_dockerfile <path>
  local file="$1"
  grep -Eq '^RUN cargo build --release --locked -p wrfcoin-storage-node$' "$file" ||
    { echo "does not build wrfcoin-storage-node"; return 1; }
  grep -Eq '^COPY storage-providers/crates ' "$file" ||
    { echo "does not build from the storage-providers checkout"; return 1; }
  grep -Eq '^ENTRYPOINT \["/app/storage-node"\]$' "$file" ||
    { echo "does not run storage-node"; return 1; }
  grep -Eq '^ENV STORAGE_NODE_PROFILE=testnet ' "$file" ||
    { echo "does not default to the testnet profile"; return 1; }
  if grep -Ev '^[[:space:]]*#' "$file" | grep -Eq 'storage_networks_server|node backend/|backend/server'; then
    echo "still packages the backend storage mock"; return 1
  fi
  if grep -E '^FROM ' "$file" | grep -Ev '@sha256:[0-9a-f]{64}( |$)' | grep -q .; then
    echo "a FROM line is not digest-pinned"; return 1
  fi
}

check_storage_compose() { # check_storage_compose <path>
  local file="$1" default paid
  default="$(render "$file")" || { echo "default render failed"; return 1; }
  paid="$(render "$file" paid-providers)" || { echo "paid-providers render failed"; return 1; }
  python3 - "$default" "$paid" <<'PY'
import json, re, sys

default, paid = (json.loads(arg)["services"] for arg in sys.argv[1:3])
problems = []
if sorted(default) != ["ipfs", "storage-provider"]:
    problems.append(f"default services are {sorted(default)}, expected only ipfs and storage-provider")
if not str(default.get("ipfs", {}).get("image", "")).startswith("ipfs/kubo:"):
    problems.append("ipfs is not a self-hosted kubo")
sp = default.get("storage-provider", {})
if (sp.get("build") or {}).get("dockerfile") != "infra/infra/docker/Dockerfile.storage":
    problems.append("storage-provider does not build Dockerfile.storage")
if not any(int(p.get("target", 0)) == 7001 for p in sp.get("ports", [])):
    problems.append("storage-provider does not publish the daemon port 7001")
env = sp.get("environment") or {}
if env.get("STORAGE_NODE_PROFILE") != "testnet":
    problems.append("storage-provider is not in the testnet profile")
paid_env = [k for k in env if re.search(r"PINATA|WEB3_STORAGE|NFT_STORAGE|REMOTE_PIN|FILECOIN|ARWEAVE|LOTUS", k)]
if paid_env:
    problems.append(f"storage-provider carries paid-provider env {paid_env}")
for name in ("filecoin-lite", "arweave-gateway"):
    if name not in paid:
        problems.append(f"{name} vanished from the paid-providers profile")

# infra#1159 review: in EVERY profile, the kubo API port is never published
# (loopback included), and every image is digest-pinned or a full x.y.z tag.
PINNED = re.compile(r"@sha256:[0-9a-f]{64}$|:v?\d+\.\d+\.\d+(?:[-+][\w.]+)?$")
for label, services in (("default", default), ("paid-providers", paid)):
    for port in (services.get("ipfs") or {}).get("ports") or []:
        if int(port.get("target", 0)) == 5001:
            problems.append(f"{label}: ipfs publishes the Kubo API port 5001 ({port.get('host_ip') or 'all interfaces'}:{port.get('published')})")
    for name, svc in sorted(services.items()):
        image = svc.get("image")
        if image and not PINNED.search(str(image)):
            problems.append(f"{label}: {name} image {image} is not pinned to a digest or a full version")
if problems:
    print("; ".join(problems))
    sys.exit(1)
PY
}

check_dev_compose() { # check_dev_compose <path>
  local file="$1" rendered
  rendered="$(render "$file" full)" || { echo "dev render failed"; return 1; }
  python3 - "$rendered" <<'PY'
import json, sys
svc = json.loads(sys.argv[1])["services"].get("wrfcoin-storage")
if not svc:
    print("wrfcoin-storage missing"); sys.exit(1)
if (svc.get("build") or {}).get("dockerfile") != "infra/infra/docker/Dockerfile.storage":
    print("wrfcoin-storage does not build Dockerfile.storage"); sys.exit(1)
if not any(int(p.get("target", 0)) == 7001 for p in svc.get("ports", [])):
    print("wrfcoin-storage does not target the daemon port 7001"); sys.exit(1)
PY
}

expect_pass() { # expect_pass <label> <check> <path>
  local out
  out="$("$2" "$3" 2>&1)" || fail "$1: ${out}"
  printf 'ok   %s\n' "$1"
}

expect_red() { # expect_red <label> <check> <path> <must-say>
  local out
  if out="$("$2" "$3" 2>&1)"; then
    fail "RED control passed (the check is blind): $1"
  fi
  grep -Fq -- "$4" <<<"$out" || fail "RED control $1 failed for the wrong reason: ${out}"
  printf 'red  %s\n' "$1"
}

expect_pass 'Dockerfile.storage builds the real storage-node' check_dockerfile "$DOCKERFILE"
expect_pass 'storage compose renders IPFS-only by default' check_storage_compose "$STORAGE_COMPOSE"
expect_pass 'dev compose wrfcoin-storage runs the real daemon' check_dev_compose "$DEV_COMPOSE"

# RED controls on mutated copies (siblings, so relative paths still resolve).
mock="${tmp}/Dockerfile.mock"
cp "$DOCKERFILE" "$mock"
printf '%s\n' 'CMD ["node", "backend/server/storage_networks_server.js"]' >> "$mock"
expect_red 'the mock CMD reintroduced' check_dockerfile "$mock" 'backend storage mock'

unpinned="${tmp}/Dockerfile.unpinned"
sed 's|^FROM rust:1.88-bookworm@sha256:[0-9a-f]*|FROM rust:1.88-bookworm|' "$DOCKERFILE" > "$unpinned"
expect_red 'an unpinned FROM' check_dockerfile "$unpinned" 'not digest-pinned'

ungated="${ROOT}/infra/docker/.test-storage-ungated.$$.yml"
paidenv="${ROOT}/infra/docker/.test-storage-paidenv.$$.yml"
trap 'rm -rf "$tmp" "$ungated" "$paidenv"' EXIT
sed "/^  filecoin-lite:/{n;/profiles:/d}" "$STORAGE_COMPOSE" > "$ungated"
expect_red 'lotus back in the default render' check_storage_compose "$ungated" 'default services are'
sed 's|^      - STORAGE_NODE_PROFILE=testnet$|      - STORAGE_NODE_PROFILE=testnet\n      - PINATA_JWT=dummy|' "$STORAGE_COMPOSE" > "$paidenv"
expect_red 'a paid pinning credential' check_storage_compose "$paidenv" 'paid-provider env'

# infra#1159 review controls: the Kubo API published (loopback, then all
# interfaces), and an unpinned image in the paid-providers profile.
apiloop="${ROOT}/infra/docker/.test-storage-apiloop.$$.yml"
apiall="${ROOT}/infra/docker/.test-storage-apiall.$$.yml"
unpinnedimg="${ROOT}/infra/docker/.test-storage-unpinned.$$.yml"
trap 'rm -rf "$tmp" "$ungated" "$paidenv" "$apiloop" "$apiall" "$unpinnedimg"' EXIT
sed "s|^      - '127.0.0.1:8080:8080' # Gateway (localhost only)$|      - '127.0.0.1:5001:5001'\n&|" "$STORAGE_COMPOSE" > "$apiloop"
expect_red 'the Kubo API published on loopback' check_storage_compose "$apiloop" 'publishes the Kubo API port 5001 (127.0.0.1:5001)'
sed "s|^      - '127.0.0.1:8080:8080' # Gateway (localhost only)$|      - '5001:5001'\n&|" "$STORAGE_COMPOSE" > "$apiall"
expect_red 'the Kubo API published on all interfaces' check_storage_compose "$apiall" 'publishes the Kubo API port 5001'
sed 's|^    image: node:20-alpine@sha256:[0-9a-f]*$|    image: node:20-alpine|' "$STORAGE_COMPOSE" > "$unpinnedimg"
expect_red 'an unpinned image in the paid-providers profile' check_storage_compose "$unpinnedimg" 'paid-providers: arweave-gateway image node:20-alpine is not pinned'

printf '%s\n' 'STORAGE_IPFS_ONLY=PASS'
