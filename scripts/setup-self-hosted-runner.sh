#!/usr/bin/env bash
# Setup GitHub Actions self-hosted runner on N5 Pro (or any Debian/Ubuntu host)
#
# Usage:
#   GITHUB_TOKEN=<pat-with-admin:org-or-repo-scope> \
#   REPO=wrfcoin/infra \
#   ./setup-self-hosted-runner.sh
#
# Environment variables:
#   GITHUB_TOKEN   - PAT with repo/admin scope, or a registration token
#                    (obtain from: Settings → Actions → Runners → New self-hosted runner)
#   REPO           - GitHub repo slug, e.g. "wrfcoin/infra" or "wrfcoin/core4"
#   RUNNER_VERSION - Optional: pin a specific actions-runner release (default: latest)
#   RUNNER_DIR     - Optional: installation directory (default: /opt/gh-runner)
#   RUNNER_USER    - Optional: OS user to run the service (default: gh-runner)
#   RUNNER_LABELS  - Optional: comma-separated extra labels (always includes base set)
#   RUNNER_NAME    - Optional: display name in GitHub UI (default: hostname)
#   EPHEMERAL      - Optional, DEFAULT "false" (persistent). Owner decision
#                    2026-07-22: core4 is private with a single collaborator,
#                    so the fork-PR threat --ephemeral defends against does not
#                    exist here, and the JIT alternative would have required a
#                    token-minting credential living on the testnet host — a
#                    concrete risk traded for a theoretical one.
#                    "true" selects ephemeral (SINGLE-JOB) mode. An
#                    ephemeral runner deregisters itself after one job. It is
#                    the safer posture for running PR code, but it does NOT
#                    survive under systemd — see INSTALL_SERVICE.
#   INSTALL_SERVICE- Optional: "true" (default) installs+starts the systemd
#                    service. Refused together with EPHEMERAL=true unless
#                    EPHEMERAL_SINGLE_JOB_ACK=true, because that combination
#                    yields a runner that works exactly once.
#   SEED_PYTHON    - Optional: Python X.Y to seed into the runner tool cache
#                    (e.g. "3.12"). REQUIRED for any workflow using
#                    actions/setup-python — see "Tool cache" below. Empty to
#                    skip.
#   EPHEMERAL_SINGLE_JOB_ACK
#                  - Optional: "true" to accept a deliberately single-use
#                    ephemeral+systemd install (useful for a one-shot smoke
#                    test). The script says so loudly rather than pretending
#                    the result is durable.
#
# Security notes:
#   - Runs as an unprivileged user (gh-runner), NOT root
#   - Ephemeral mode (EPHEMERAL=true) gives each job a clean environment
#   - Docker socket is bind-mounted to allow container-based CI steps
#   - Firewall: outbound HTTPS to github.com only; no inbound ports required
#
# Acceptance criteria (issue #115):
#   - Runner appears "online" in GitHub → Settings → Actions → Runners
#   - `cargo check --workspace` completes <3 min on warm cache
#   - Runner restarts automatically after host reboot (systemd) — persistent mode
#     only; see the EPHEMERAL note below, ephemeral runners are single-use.
#
# NOT done by this script, listed because issue #115 states it as a criterion:
#   - Prometheus metrics on :9100/metrics (node_exporter). This script does not
#     install node_exporter and never has. Install it separately; do not read
#     this script's success as that criterion being met.
set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf '\e[32m[INFO]\e[0m  %s\n' "$*"; }
warn()  { printf '\e[33m[WARN]\e[0m  %s\n' "$*" >&2; }
die()   { printf '\e[31m[ERROR]\e[0m %s\n' "$*" >&2; exit 1; }
need()  { command -v "$1" &>/dev/null || die "Required command not found: $1"; }

runner_service_unit_name() {
  local unit="actions.runner.${1}.${2}.service"
  printf '%s\n' "${unit//\//-}"
}

resolve_runner_service_unit() {
  local unit_dir="$1"
  local unit
  unit="$(runner_service_unit_name "$2" "$3")"
  [[ -f "${unit_dir}/${unit}" ]] || return 1
  printf '%s\n' "$unit"
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
: "${GITHUB_TOKEN:?Set GITHUB_TOKEN to a PAT or registration token}"
: "${REPO:?Set REPO to org/repo, e.g. wrfcoin/infra}"

RUNNER_DIR="${RUNNER_DIR:-/opt/gh-runner}"
RUNNER_USER="${RUNNER_USER:-gh-runner}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname -s)}"
EPHEMERAL="${EPHEMERAL:-false}"
INSTALL_SERVICE="${INSTALL_SERVICE:-true}"
EPHEMERAL_SINGLE_JOB_ACK="${EPHEMERAL_SINGLE_JOB_ACK:-false}"
SEED_PYTHON="${SEED_PYTHON:-}"

# Detect architecture
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) RUNNER_ARCH="arm64" ;;
  x86_64)        RUNNER_ARCH="x64"   ;;
  *)             die "Unsupported architecture: $ARCH" ;;
esac

# Base labels always applied; caller may append extras
BASE_LABELS="self-hosted,linux,${RUNNER_ARCH},n5pro,wrfcoin"
EXTRA_LABELS="${RUNNER_LABELS:-}"
if [[ -n "$EXTRA_LABELS" ]]; then
  ALL_LABELS="${BASE_LABELS},${EXTRA_LABELS}"
else
  ALL_LABELS="$BASE_LABELS"
fi

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
need curl
need tar
need systemctl

if [[ "$(id -u)" -ne 0 ]]; then
  die "Run this script as root (sudo) — it installs a systemd service."
fi

# ---------------------------------------------------------------------------
# EPHEMERAL + systemd is a trap. Refuse it before creating anything.
#
# An ephemeral runner deregisters itself when its job finishes — that is the
# point of it. systemd then restarts the service into a configuration that no
# longer exists, and the runner dies with:
#
#     An error occurred: Not configured. Run config.(sh/cmd) to configure the runner.
#
# Observed exactly once in the wild, on 2026-07-22: the runner accepted a job,
# completed it successfully, removed .credentials and .runner, and the service
# was dead from then on. `gh api .../runners` reported total_count 0 immediately
# after a SUCCESSFUL job, which reads precisely like a registration failure.
#
# So this combination is refused rather than silently produced. The choice of
# posture is deliberately left to the caller — this script does not pick one:
#
#   EPHEMERAL=true  INSTALL_SERVICE=false  -> safest for untrusted PR code;
#                                             run ./run.sh under a supervisor
#                                             that re-registers per job (JIT).
#   EPHEMERAL=false INSTALL_SERVICE=true   -> durable; survives reboot. Job
#                                             residue persists between jobs.
#   EPHEMERAL=true  INSTALL_SERVICE=true   -> single-use. Requires
#                                             EPHEMERAL_SINGLE_JOB_ACK=true.
# ---------------------------------------------------------------------------
if [[ "$EPHEMERAL" == "true" && "$INSTALL_SERVICE" == "true" ]]; then
  if [[ "$EPHEMERAL_SINGLE_JOB_ACK" != "true" ]]; then
    die "REFUSING: EPHEMERAL=true with INSTALL_SERVICE=true produces a runner that
       works for exactly ONE job and then fails permanently with 'Not configured'.

       An ephemeral runner deregisters itself after its job; systemd then restarts
       it into a config that no longer exists. Worse, the runners API reports
       total_count 0 afterwards, so it looks like registration failed when the job
       actually succeeded.

       Pick one, explicitly:
         EPHEMERAL=true  INSTALL_SERVICE=false   # clean per-job env, needs a
                                                 # supervisor to re-register (JIT)
         EPHEMERAL=false INSTALL_SERVICE=true    # durable service, residue persists
         EPHEMERAL=true  INSTALL_SERVICE=true  EPHEMERAL_SINGLE_JOB_ACK=true
                                                 # deliberately single-use (smoke test)

       This script does not choose your security posture for you."
  fi
  warn "EPHEMERAL=true with a systemd service: this runner is SINGLE-USE."
  warn "It will accept one job, succeed, deregister, and the service will then"
  warn "fail with 'Not configured'. That is expected, not a fault. The runners"
  warn "API will report total_count 0 afterwards even though the job passed."
fi

# ---------------------------------------------------------------------------
# Resolve latest runner version if not pinned
# ---------------------------------------------------------------------------
if [[ -z "${RUNNER_VERSION:-}" ]]; then
  info "Resolving latest actions-runner release..."
  RUNNER_VERSION=$(curl -sSfL \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/actions/runner/releases/latest" \
    | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')
  [[ -n "$RUNNER_VERSION" ]] || die "Could not resolve latest runner version"
fi
info "Runner version: ${RUNNER_VERSION}"

TARBALL="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}"

# ---------------------------------------------------------------------------
# Create unprivileged runner user
# ---------------------------------------------------------------------------
if ! id "$RUNNER_USER" &>/dev/null; then
  info "Creating user: ${RUNNER_USER}"
  useradd --system --shell /bin/bash --create-home --home-dir "${RUNNER_DIR}" "$RUNNER_USER"
else
  info "User ${RUNNER_USER} already exists"
fi

# ---------------------------------------------------------------------------
# Download and extract
# ---------------------------------------------------------------------------
mkdir -p "${RUNNER_DIR}"
chown "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_DIR}"

TARBALL_PATH="/tmp/${TARBALL}"
if [[ ! -f "$TARBALL_PATH" ]]; then
  info "Downloading ${DOWNLOAD_URL}..."
  curl -sSfL -o "$TARBALL_PATH" "$DOWNLOAD_URL"
else
  info "Tarball already cached at ${TARBALL_PATH}"
fi

info "Extracting to ${RUNNER_DIR}..."
tar -xzf "$TARBALL_PATH" -C "${RUNNER_DIR}"
chown -R "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_DIR}"

# ---------------------------------------------------------------------------
# Obtain a registration token from the PAT (if GITHUB_TOKEN looks like a PAT)
# ---------------------------------------------------------------------------
# The old test was `ghp_* || github_pat_*`, with everything else ASSUMED to be a
# registration token. That silently misroutes any other credential form — an
# OAuth/app token (`gho_`, `ghs_`, `ghu_`, which is what `gh auth token` can
# return) was handed to config.sh as if it were a registration token and failed
# with an opaque error. The old comment also claimed registration tokens start
# with "ATVB", which is not a documented or reliable property.
#
# Route on the ACCESS TOKEN prefixes that GitHub does document, and treat
# anything else as a registration token — but say which branch was taken, so a
# misrouted credential is diagnosable from the log instead of mysterious.
case "$GITHUB_TOKEN" in
  ghp_*|github_pat_*|gho_*|ghs_*|ghu_*)
    info "Access token detected (prefix: ${GITHUB_TOKEN%%_*}_) — exchanging for a registration token..."
    # infra#1073: the token reaches curl on stdin (-H @-) from the builtin
    # printf, never through argv (ps, /proc/<pid>/cmdline, sudo logs).
    REG_RESPONSE=$(printf 'Authorization: Bearer %s\n' "${GITHUB_TOKEN}" | curl -sSL \
      -X POST \
      -H "Accept: application/vnd.github+json" \
      -H @- \
      "https://api.github.com/repos/${REPO}/actions/runners/registration-token") \
      || die "Registration-token request failed (network or TLS error)"

    if command -v jq &>/dev/null; then
      REG_TOKEN=$(printf '%s' "$REG_RESPONSE" | jq -r '.token // empty')
      API_MESSAGE=$(printf '%s' "$REG_RESPONSE" | jq -r '.message // empty')
    else
      REG_TOKEN=$(printf '%s' "$REG_RESPONSE" | grep -o '"token" *: *"[^"]*"' | head -1 | sed 's/.*: *"//; s/"$//')
      API_MESSAGE=$(printf '%s' "$REG_RESPONSE" | grep -o '"message" *: *"[^"]*"' | head -1 | sed 's/.*: *"//; s/"$//')
    fi

    if [[ -z "$REG_TOKEN" ]]; then
      # Report GitHub's own reason. The previous version died with a generic
      # message and discarded the API's explanation.
      die "Failed to obtain a registration token for ${REPO}.
       GitHub said: ${API_MESSAGE:-<no message in response>}
       The token needs admin rights on the repository (classic: 'repo';
       fine-grained: Administration read+write)."
    fi
    ;;
  *)
    info "Treating GITHUB_TOKEN as a pre-minted registration token (no recognised access-token prefix)."
    info "These expire ONE HOUR after minting — mint it immediately before running this script."
    REG_TOKEN="$GITHUB_TOKEN"
    ;;
esac

# ---------------------------------------------------------------------------
# Configure the runner
# ---------------------------------------------------------------------------
EPHEMERAL_FLAG=""
[[ "$EPHEMERAL" == "true" ]] && EPHEMERAL_FLAG="--ephemeral"

# `--replace` replaces the runner on GITHUB's side; it does not clear a local
# config. If .runner exists, config.sh refuses with "Cannot configure the runner
# because it is already configured" and the script dies mid-way with the user
# left guessing. Found reconfiguring ephemeral -> persistent on 2026-07-22.
if [[ -f "${RUNNER_DIR}/.runner" ]]; then
  die "A runner is already configured in ${RUNNER_DIR}.
       '--replace' replaces it on GitHub's side but cannot clear the local config.
       Remove it first, with a REMOVAL token (not a registration token):

         gh api -X POST repos/${REPO}/actions/runners/remove-token --jq .token
         sudo -u ${RUNNER_USER} bash -c 'cd ${RUNNER_DIR} && ./config.sh remove --token <TOKEN>'

       If the service is running, stop it first:
         systemctl stop 'actions.runner.*' && (cd ${RUNNER_DIR} && ./svc.sh uninstall)"
fi

info "Configuring runner '${RUNNER_NAME}' for https://github.com/${REPO}..."
# The token is passed through the environment so the longer-lived sudo/bash
# argv contains only the literal text "$REG_TOKEN", not the credential. This
# narrows the exposure but cannot eliminate it: config.sh accepts the token only
# as `--token VALUE`, so its OWN argv contains the plaintext token after the
# child expands the environment variable. `/proc/<config-pid>/cmdline` may
# therefore expose it for the duration of config.sh. The runner provides no
# environment/file alternative; do not claim this interface can hide that
# residual.
configure_runner() {
  export REG_TOKEN
  sudo -u "$RUNNER_USER" --preserve-env=REG_TOKEN bash -c '
    set -euo pipefail
    cd "$1"
    ./config.sh \
      --url "https://github.com/$2" \
      --token "$REG_TOKEN" \
      --name "$3" \
      --labels "$4" \
      --work "_work" \
      $5 \
      --unattended \
      --replace
  ' _ "${RUNNER_DIR}" "${REPO}" "${RUNNER_NAME}" "${ALL_LABELS}" "${EPHEMERAL_FLAG}"
  unset REG_TOKEN
}
configure_runner

# ---------------------------------------------------------------------------
# Install as systemd service
# ---------------------------------------------------------------------------
SERVICE_UNIT=""
if [[ "$INSTALL_SERVICE" != "true" ]]; then
  info "INSTALL_SERVICE=false — runner configured but no systemd service installed."
  info "Start it in the foreground with:  sudo -u ${RUNNER_USER} ${RUNNER_DIR}/run.sh"
else
  # svc.sh install writes to /etc/systemd/system and runs systemctl, so it
  # REQUIRES root. The previous version tried it as the unprivileged runner user
  # first, with the guaranteed failure hidden by 2>/dev/null, then fell through
  # to the root call via `||`. That made a normal path look like an error path
  # and buried any real failure. Run it as root, once.
  info "Installing systemd service..."
  pushd "${RUNNER_DIR}" > /dev/null
  ./svc.sh install "$RUNNER_USER"

  info "Starting service..."
  ./svc.sh start
  popd > /dev/null

  # svc.sh start returned 0 while leaving the service inactive (observed
  # 2026-07-22). Trust systemd, not the wrapper's exit code: a runner that is
  # registered but not listening is exactly the state that looks fine and picks
  # up no jobs.
  if ! SERVICE_UNIT="$(
    resolve_runner_service_unit "/etc/systemd/system" "$REPO" "$RUNNER_NAME"
  )"; then
    EXPECTED_SERVICE_UNIT="$(runner_service_unit_name "$REPO" "$RUNNER_NAME")"
    die "systemd unit ${EXPECTED_SERVICE_UNIT} for repo ${REPO} and runner
       ${RUNNER_NAME} was not created — refusing to verify a different runner's
       service."
  fi

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    systemctl is-active --quiet "$SERVICE_UNIT" && break
    sleep 1
  done

  if systemctl is-active --quiet "$SERVICE_UNIT"; then
    info "Service ${SERVICE_UNIT} is active."
  else
    warn "Service ${SERVICE_UNIT} is NOT active after install. Recent log:"
    journalctl -u "$SERVICE_UNIT" -n 20 --no-pager >&2 || true
    if [[ "$EPHEMERAL" == "true" ]]; then
      die "Ephemeral runner's service is inactive. If it already ran a job this is
       expected (see the EPHEMERAL warning above); if it has not, the install failed."
    fi
    die "Runner service failed to start — the runner is registered but will pick up no jobs."
  fi
fi

# ---------------------------------------------------------------------------
# Optional: Rust toolchain + sccache pre-seeding (for core4 CI speed)
# ---------------------------------------------------------------------------
if command -v rustup &>/dev/null; then
  info "rustup found — ensuring stable toolchain is current..."
  sudo -u "$RUNNER_USER" bash -c "rustup update stable" || true
else
  warn "rustup not installed. For fast Rust CI, install rustup as ${RUNNER_USER}:"
  warn "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sudo -u ${RUNNER_USER} sh -s -- -y"
fi

if command -v sccache &>/dev/null; then
  info "sccache found — runner will use it automatically if RUSTC_WRAPPER=sccache is set in workflows."
else
  warn "sccache not installed. For Rust compile caching:"
  warn "  cargo install sccache   (or install via apt/pkg manager)"
fi

# ---------------------------------------------------------------------------
# Docker socket access (for integration tests that spin containers)
# ---------------------------------------------------------------------------
if [[ -S /var/run/docker.sock ]]; then
  DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
  if ! id -nG "$RUNNER_USER" | grep -qw docker; then
    # The old fallback was `groupmod -a -U` — those are Solaris/illumos flags and
    # do not exist in Linux shadow-utils, so it could never succeed. Removed
    # rather than left as decorative error handling. If the group is not named
    # `docker`, resolve it from the socket's gid.
    DOCKER_GROUP="$(getent group "$DOCKER_GID" | cut -d: -f1)"
    if usermod -aG "${DOCKER_GROUP:-docker}" "$RUNNER_USER" 2>/dev/null; then
      info "Added ${RUNNER_USER} to group '${DOCKER_GROUP:-docker}' — restart the service for effect."
    else
      warn "Could not add ${RUNNER_USER} to the docker group (gid ${DOCKER_GID}); do it manually:"
      warn "  usermod -aG ${DOCKER_GROUP:-docker} ${RUNNER_USER} && systemctl restart actions.runner.*"
    fi
  fi
else
  warn "/var/run/docker.sock not found — Docker-in-runner tests will not work."
fi

# ---------------------------------------------------------------------------
# Tool cache — actions/setup-python and friends
#
# THIS IS NOT OPTIONAL POLISH. Discovered the hard way on 2026-07-22: the first
# real workflow moved to the N5 runner (input-panic-lint) failed at
# actions/setup-python@v5 with
#
#     The version '3.12' with architecture 'x64' was not found
#
# Three things combine, none of them obvious:
#
#   1. Self-hosted runners have NO pre-seeded tool cache. GitHub's hosted images
#      ship /opt/hostedtoolcache already populated; a bare runner does not.
#   2. A self-hosted runner's tool cache defaults to <RUNNER_DIR>/_work/_tool,
#      NOT /opt/hostedtoolcache. Seeding the latter looks right and does nothing.
#   3. actions/python-versions publishes builds for Ubuntu only. On a DEBIAN
#      host there is no matching build to download, so setup-python cannot
#      self-heal — it just fails. The Ubuntu 22.04 build does run on Debian 12
#      (glibc 2.35 vs 2.36), which is what makes seeding viable at all.
#
# This was previously a hand-run sequence recorded in a PR body, which is
# exactly how it becomes folklore and gets rediscovered painfully. It is a
# script step now.
# ---------------------------------------------------------------------------
if [[ -n "$SEED_PYTHON" ]]; then
  TOOL_CACHE="${RUNNER_DIR}/_work/_tool"
  info "Seeding Python ${SEED_PYTHON} into the runner tool cache (${TOOL_CACHE})..."

  MANIFEST=$(curl -sSfL https://raw.githubusercontent.com/actions/python-versions/main/versions-manifest.json) \
    || die "Could not fetch the python-versions manifest"

  read -r PY_VERSION PY_URL <<<"$(printf '%s' "$MANIFEST" | python3 -c "
import json,sys
want = sys.argv[1]
for rel in json.load(sys.stdin):
    if rel['version'].startswith(want + '.'):
        for f in rel['files']:
            # Ubuntu-only upstream; 22.04 is the most portable of the builds.
            if f['platform'] == 'linux' and f['arch'] == 'x64' and f.get('platform_version') == '22.04':
                print(rel['version'], f['download_url']); sys.exit()
" "$SEED_PYTHON")"

  [[ -n "${PY_URL:-}" ]] || die "No Ubuntu 22.04 x64 build of Python ${SEED_PYTHON} in the manifest."

  if [[ -x "${TOOL_CACHE}/Python/${PY_VERSION}/x64/bin/python3" ]]; then
    info "Python ${PY_VERSION} already in the tool cache — skipping."
  else
    SEED_TMP=$(mktemp -d)
    info "Downloading Python ${PY_VERSION}..."
    curl -sSfL -o "${SEED_TMP}/py.tar.gz" "$PY_URL" || die "Download failed: $PY_URL"
    tar -xzf "${SEED_TMP}/py.tar.gz" -C "$SEED_TMP"

    mkdir -p "${TOOL_CACHE}/Python/${PY_VERSION}/x64"
    # The tarball unpacks as tool/ (newer releases) or directly as bin/lib/include.
    if [[ -d "${SEED_TMP}/tool" ]]; then
      cp -r "${SEED_TMP}/tool/." "${TOOL_CACHE}/Python/${PY_VERSION}/x64/"
    else
      cp -r "${SEED_TMP}/bin" "${SEED_TMP}/lib" "${SEED_TMP}/include" \
        "${TOOL_CACHE}/Python/${PY_VERSION}/x64/" 2>/dev/null || true
    fi
    # setup-python treats a version as usable only if this marker exists.
    touch "${TOOL_CACHE}/Python/${PY_VERSION}/x64.complete"
    chown -R "${RUNNER_USER}:${RUNNER_USER}" "${TOOL_CACHE}"
    rm -rf "$SEED_TMP"
  fi

  # Verify the seeded interpreter reports the version we intended, not merely
  # that SOMETHING runs. These portable builds are dynamically linked, and if
  # the host happens to carry its own libpython of the same minor version the
  # seeded binary can bind to THAT instead — it starts fine and reports the
  # host's patch version. Caught exactly that while testing this block: the
  # cache directory said 3.12.13 while the interpreter reported 3.12.3, because
  # ldd resolved libpython3.12.so.1.0 to /lib/x86_64-linux-gnu.
  #
  # A tool cache that silently serves a different interpreter than CI asked for
  # is worse than an empty one: the job goes green against the wrong Python.
  SEEDED_REPORT=$("${TOOL_CACHE}/Python/${PY_VERSION}/x64/bin/python3" --version 2>&1 || true)
  SEEDED_VERSION=$(printf '%s' "$SEEDED_REPORT" | awk '{print $2}')

  if [[ -z "$SEEDED_VERSION" ]]; then
    die "Seeded Python ${PY_VERSION} is not runnable (got: ${SEEDED_REPORT:-<no output>}).
       The build does not match this OS."
  fi

  if [[ "$SEEDED_VERSION" != "$PY_VERSION" ]]; then
    warn "Seeded Python reports ${SEEDED_VERSION} but the tool cache entry is ${PY_VERSION}."
    warn "The interpreter is probably binding to a host libpython rather than the"
    warn "one it shipped with:"
    ldd "${TOOL_CACHE}/Python/${PY_VERSION}/x64/bin/python3.${SEED_PYTHON#*.}" 2>/dev/null \
      | grep -i libpython | sed 's/^/         /' >&2 || true
    die "Refusing a tool cache that serves a different interpreter than it advertises.
       A job would run green against the wrong Python. Either remove the host's
       libpython${SEED_PYTHON}, or seed on a host that does not carry one."
  fi

  info "Tool cache: Python ${SEEDED_VERSION} ready (verified, matches the cache entry)."
else
  warn "SEED_PYTHON not set. Any workflow using actions/setup-python WILL FAIL on"
  warn "this runner with \"The version 'X.Y' with architecture 'x64' was not found\"."
  warn "Re-run with SEED_PYTHON=3.12 (or the version your workflows request)."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
SERVICE_NAME="${SERVICE_UNIT:-$(runner_service_unit_name "$REPO" "$RUNNER_NAME")}"
info "==================================================================="
info "Runner installed successfully!"
info ""
info "  Name   : ${RUNNER_NAME}"
info "  Labels : ${ALL_LABELS}"
info "  Dir    : ${RUNNER_DIR}"
info "  User   : ${RUNNER_USER}"
info "  Svc    : ${SERVICE_NAME:-actions.runner.<org>.<repo>.<name>.service}"
info "  Ephem  : ${EPHEMERAL}"
info "  Service: ${INSTALL_SERVICE}"
info ""
info "Verification steps:"
info "  1. Check service status:"
info "     systemctl status '${SERVICE_NAME:-actions.runner.*}'"
info ""
info "  2. Confirm the runner appears online:"
info "     https://github.com/${REPO}/settings/actions/runners"
info ""
info "  3. Test with a dispatch workflow:"
info "     gh workflow run ci-self-hosted.yml --repo ${REPO}"
info ""
info "  4. Check runner logs if needed:"
info "     journalctl -u '${SERVICE_NAME:-actions.runner.*}' -f"
info "==================================================================="
