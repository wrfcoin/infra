#!/usr/bin/env bash
# Compare a host's .env against every variable the compose chain REQUIRES.
#
# WHY THIS EXISTS
# ---------------
# On 2026-08-05, walking the genesis cut card's rehearsal steps produced thirteen
# findings. FIVE of them were the same failure wearing different clothes:
#
#   upstream tightens a requirement  ->  a long-lived host's .env predates it
#                                    ->  nothing compares the two
#                                    ->  it surfaces as a startup crash, mid-ceremony
#
#   WRFCOIN_P2P_EXTERNAL_ADDR        compose refused to render at all
#   WRFCOIN_HSM_PIN / _SO_PIN        softhsm-init unhealthy, node never started
#   ALLOW_UNENCRYPTED_STORAGE        node exited at boot
#   N8N_WEBHOOK_SECRET               compose refused to render (CT 101 only)
#   WRFCOIN_SEED_P2P_EXTERNAL_ADDR   seed refused to start
#
# Compose reports only the FIRST interpolation failure, so discovering these one
# at a time costs one full up/build cycle each. This reports all of them at once.
#
# USAGE
#   ./check-env-completeness.sh                          # auto-detect the running chain
#   ./check-env-completeness.sh -f a.yml -f b.yml        # explicit chain
#   ./check-env-completeness.sh --env /path/to/.env
#   ./check-env-completeness.sh --cut-pins /path/to/cut-pins.env   # default: ./cut-pins.env
#                                                                   # (or $CUT_PINS_FILE)
#   ./check-env-completeness.sh --cut      # ONLY on the host that cuts block 1:
#                                          # also enforce the cut-only genesis inputs
#                                          # (core4#3361 genesis faucet address)
#
# Exit 0 = nothing missing. Exit 1 = at least one required variable absent/empty.
set -uo pipefail

ENV_FILE=""
CUT_PINS="${CUT_PINS_FILE:-}"
CUT_MODE=0
FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    -f) FILES+=("$2"); shift 2 ;;
    --env) ENV_FILE="$2"; shift 2 ;;
    --cut-pins) CUT_PINS="$2"; shift 2 ;;
    --cut) CUT_MODE=1; shift ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
ENV_FILE="${ENV_FILE:-$PWD/.env}"
CUT_PINS="${CUT_PINS:-$PWD/cut-pins.env}"

# Derive the chain from the RUNNING container when not given one. The chain
# differs per host (CT 101 uses local-paths + yubikey overlays where the
# workstation uses desktop), so a hardcoded list checks the wrong thing.
if [ ${#FILES[@]} -eq 0 ]; then
  if labels=$(docker inspect wrfcoin-testnet-node \
        --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null) \
     && [ -n "$labels" ]; then
    # The label holds the absolute paths compose used. Keep a path that exists
    # here (an out-of-tree operator override stays in the chain); otherwise fall
    # back to the same-named file in this directory. Anything still missing is
    # refused below, never silently dropped.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ -f "$f" ]; then FILES+=("$f"); else FILES+=("$(basename "$f")"); fi
    done < <(printf '%s' "$labels" | tr ',' '\n')
    echo "chain (from the running container): ${FILES[*]}"
  else
    FILES=(docker-compose.testnet.yml docker-compose.override.yml)
    echo "chain (fallback, no running container): ${FILES[*]}"
  fi
fi
[ -f "$ENV_FILE" ] || { echo "FAIL: no .env at $ENV_FILE" >&2; exit 1; }
echo "env file: $ENV_FILE"
echo

# Every requested file must exist. Compose itself exits 1 on a missing -f, so
# dropping one here would check a DIFFERENT chain than the `up` runs, and
# could pass while the deploy fails (codex review of #1060). The full ordered
# list is what every check below reads and renders.
present=()
missing_files=()
for f in "${FILES[@]}"; do
  if [ -f "$f" ]; then present+=("$f"); else missing_files+=("$f"); fi
done
if [ ${#missing_files[@]} -gt 0 ]; then
  printf 'FAIL: requested compose file does not exist: %s\n' "${missing_files[@]}" >&2
  exit 1
fi
[ ${#present[@]} -gt 0 ] || { echo "FAIL: no compose files named" >&2; exit 1; }

# 1. compose-enforced:  ${VAR:?message}. This deliberately includes
#    WRFCOIN_ATTESTER_NWS_STATION whenever the attester overlay is in the chain.
compose_req=$(grep -hoE '\$\{[A-Z_][A-Z0-9_]*:\?' "${present[@]}" 2>/dev/null \
              | sed 's/^..//; s/:?$//' | sort -u)

# 2. runtime-enforced: an entrypoint guard that aborts on an unset variable.
#    These are INVISIBLE to a `:?` scan -- that is exactly how
#    WRFCOIN_SEED_P2P_EXTERNAL_ADDR reached a live host. See infra#762 for why
#    such guards deliberately cannot be `:?`.
runtime_req=$(grep -hoE 'FATAL: [A-Z_][A-Z0-9_]* is (unset|not set|empty)' "${present[@]}" 2>/dev/null \
              | awk '{print $2}' | sort -u)

required=$(printf '%s\n%s\n' "$compose_req" "$runtime_req" | grep -v '^$' | sort -u)
echo "required variables found: $(printf '%s\n' "$required" | grep -c .)"
echo "  compose-enforced (:?)  : $(printf '%s\n' "$compose_req" | grep -c .)"
echo "  runtime-enforced guards: $(printf '%s\n' "$runtime_req" | grep -c .)"
echo

missing=0
while IFS= read -r v; do
  [ -z "$v" ] && continue
  if ! grep -qE "^${v}=.+" "$ENV_FILE"; then
    echo "  MISSING or EMPTY: $v"
    missing=$((missing + 1))
  fi
done <<< "$required"

# Known-bad defaults worth failing on even when the variable IS set.
if grep -qE '^WRFCOIN_HSM_SO_PIN=0000$' "$ENV_FILE"; then
  echo "  UNSAFE DEFAULT:   WRFCOIN_HSM_SO_PIN is 0000 (found live on CT 101, 2026-08-05)"
  missing=$((missing + 1))
fi

# infra#1056: CT101 ran every backend service with CORS_ORIGIN=http://localhost:5000
# because compose defaulted it and .env never set it. Compose now has no default
# but, deliberately, no `:?` either (the #762 trap: it would break the join
# command, which starts no backend service), so the `:?` scan above cannot see
# it. Check the EFFECTIVE value instead of the literal .env line: render this
# exact ordered file set with this env file AND this process environment (an
# exported CORS_ORIGIN wins over .env; overlays and interpolation apply), then
# validate CORS_ORIGIN in every rendered service that reads it, with the ONE
# shared policy (scripts/cors_origin_policy.py, which the release manifest also
# uses): https://host[:port] only, and no loopback, unspecified or wildcard host
# in any spelling a browser accepts. Config only: nothing is built or started.
if grep -qE '^[[:space:]]+CORS_ORIGIN:' "${present[@]}" 2>/dev/null; then
  cors_render="$(mktemp "${TMPDIR:-/tmp}/cors-render.XXXXXX")"
  cors_args=(--env-file "$ENV_FILE")
  for f in "${present[@]}"; do cors_args+=(-f "$f"); done
  if ! docker compose "${cors_args[@]}" config --format json > "$cors_render" 2> "$cors_render.err"; then
    echo "  UNVERIFIED CORS_ORIGIN: effective compose render failed: $(tail -n 1 "$cors_render.err")"
    missing=$((missing + 1))
  elif ! cors_report="$(python3 "$PWD/scripts/cors_origin_policy.py" --env-gate "$cors_render")"; then
    printf '%s\n' "$cors_report"
    missing=$((missing + 1))
  else
    printf '%s\n' "$cors_report"
  fi
  rm -f "$cors_render" "$cors_render.err"
fi

# Snapshot-ingest trusted signers (infra#979, owner ruling infra#1080 2026-09-27).
#
# core4 fails closed on its own: an empty allow-list makes
# POST /network/snapshot-sync/ingest refuse every payload (core4
# routes/snapshot.rs:282). So this gate's job is DRIFT, not absence:
#   - no signer pinned in cut-pins.env (WRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS):
#       host list empty      -> WARN (snapshot-ingest UNAVAILABLE), not a failure
#       host list set        -> each entry must be 64-hex, else ERROR
#   - a signer IS pinned:
#       pin malformed        -> ERROR
#       host list empty      -> ERROR (absent)
#       host set != pin set  -> ERROR (mismatch; compared case-insensitively,
#                               order- and duplicate-insensitive)
# A malformed host entry is always an ERROR.
#
# Parsing (both host and pin positions): the value is split on EVERY comma; each
# entry may carry whitespace only at its boundaries (core4 trims entries, main.rs
# parse_snapshot_trusted_signers) and must then be exactly 64 hex digits. Internal
# whitespace, an empty entry (",,", a leading/trailing comma) or any non-hex entry
# makes the whole list malformed -- validation happens BEFORE canonicalisation.
# Only case, order and duplicates are ignored when comparing. A value that is
# empty after trimming is "no signers".
#
# The pins file must be read successfully: a missing or unreadable file is an
# ERROR, never a silent "no pin". WARN is reserved for a file that was read and
# simply pins no signer.
strip_quotes() {
  local v="$1"
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}
trim_ws() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}
# Prints the canonical (lowercase, sorted, unique, comma-joined) list.
# Returns 1 if the list is malformed; prints nothing for an empty value.
canonical_signers() {
  local raw entry rest out=()
  raw="$(trim_ws "$1")"
  [ -n "$raw" ] || return 0
  rest="$raw,"
  while [ -n "$rest" ]; do
    entry="${rest%%,*}"
    rest="${rest#*,}"
    entry="$(trim_ws "$entry")"
    [[ "$entry" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    out+=("$(printf '%s' "$entry" | tr 'A-F' 'a-f')")
  done
  printf '%s\n' "${out[@]}" | sort -u | paste -sd, -
}

snapshot_signers="$(strip_quotes "$(sed -n 's/^WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=//p' "$ENV_FILE" | tail -1)")"
pins_ok=1
pinned_signers=""
if [ ! -e "$CUT_PINS" ]; then
  echo "  ERROR cut pins file not found: $CUT_PINS (pass --cut-pins or set CUT_PINS_FILE)"
  missing=$((missing + 1)); pins_ok=0
elif ! pins_content="$(cat -- "$CUT_PINS" 2>/dev/null)"; then
  echo "  ERROR cut pins file unreadable: $CUT_PINS"
  missing=$((missing + 1)); pins_ok=0
else
  pinned_signers="$(strip_quotes "$(printf '%s\n' "$pins_content" | sed -n 's/^WRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS=//p' | tail -1)")"
fi

# Runs on every preflight, including steady-state hosts after a cut.
if [ "$pins_ok" -eq 1 ]; then
  if ! python3 "$PWD/scripts/chain-identity.py" --pins "$CUT_PINS" --env "$ENV_FILE"; then
    missing=$((missing + 1))
  fi
fi

host_norm=""
host_bad=0
host_norm="$(canonical_signers "$snapshot_signers")" || host_bad=1
if [ "$host_bad" -ne 0 ]; then
  echo "  ERROR WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS: every signer must be a 64-hex ed25519 public key (no empty entries, no internal whitespace)"
  missing=$((missing + 1))
elif [ "$pins_ok" -eq 0 ]; then
  : # already reported: the pin cannot be compared against
elif [ -z "$(trim_ws "$pinned_signers")" ]; then
  if [ -z "$host_norm" ]; then
    echo "  WARN  WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS: snapshot-ingest UNAVAILABLE (no trusted signers; none pinned in $(basename "$CUT_PINS"))"
  else
    n=$(printf '%s' "$host_norm" | tr ',' '\n' | grep -c .)
    echo "  snapshot-ingest: trusted signer list valid (${n} key(s)); no cut pin to compare against"
  fi
else
  if ! pin_norm="$(canonical_signers "$pinned_signers")"; then
    echo "  ERROR WRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS in $CUT_PINS: every pinned signer must be a 64-hex ed25519 public key (no empty entries, no internal whitespace)"
    missing=$((missing + 1))
  elif [ -z "$host_norm" ]; then
    echo "  ERROR WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS: absent, but $(basename "$CUT_PINS") pins a trusted snapshot signer"
    missing=$((missing + 1))
  elif [ "$host_norm" != "$pin_norm" ]; then
    echo "  ERROR WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS: does not match the signer(s) pinned in $(basename "$CUT_PINS")"
    missing=$((missing + 1))
  else
    n=$(printf '%s' "$host_norm" | tr ',' '\n' | grep -c .)
    echo "  snapshot-ingest: trusted signer list valid (${n} key(s)) and matches the cut pin"
  fi
fi

# Faucet bucket high-water mark (infra#1121). The faucet exits at startup unless
# FAUCET_HIGH_WATER_MARK is a positive whole-WRF amount (server.js
# validateHighWaterConfig), and compose deliberately gives it no default, so an
# older host .env crash-loops a rebuilt faucet. Required when the chain defines
# wrfcoin-faucet and an active profile starts it (faucet, seed, or *). Profiles
# follow compose: an exported COMPOSE_PROFILES wins over the .env line. The
# value is operator configuration: only its class is ever printed.
if grep -qE '^  wrfcoin-faucet:' "${present[@]}" 2>/dev/null; then
  if [ -n "${COMPOSE_PROFILES+x}" ]; then
    profiles="$COMPOSE_PROFILES"
  else
    profiles="$(strip_quotes "$(sed -n 's/^COMPOSE_PROFILES=//p' "$ENV_FILE" | tail -1)")"
  fi
  faucet_active=0
  read -r -a profile_list <<< "${profiles//,/ }"   # no word glob: `*` stays literal
  for profile in "${profile_list[@]}"; do
    case "$profile" in faucet|seed|'*') faucet_active=1 ;; esac
  done
  if [ "$faucet_active" -eq 1 ]; then
    high_water="$(trim_ws "$(strip_quotes "$(sed -n 's/^FAUCET_HIGH_WATER_MARK=//p' "$ENV_FILE" | tail -1)")")"
    high_water_ok=0
    # Same rules as server.js toBaseUnits/parseRequiredBaseUnits: a decimal with
    # at most 8 fractional digits, > 0, and within the safe JSON integer range
    # once in base units (10^8 per WRF).
    if [[ "$high_water" =~ ^([0-9]+)(\.([0-9]{1,8}))?$ ]]; then
      hw_int="${BASH_REMATCH[1]}" hw_frac="${BASH_REMATCH[3]}"
      hw_int="${hw_int#"${hw_int%%[!0]*}"}"
      hw_frac="$(printf '%-8s' "$hw_frac" | tr ' ' 0)"
      if [ "${#hw_int}" -le 9 ]; then
        hw_base=$(( 10#${hw_int:-0} * 100000000 + 10#$hw_frac ))
        [ "$hw_base" -gt 0 ] && [ "$hw_base" -le 9007199254740991 ] && high_water_ok=1
      fi
    fi
    if [ -z "$high_water" ]; then
      echo "  ERROR FAUCET_HIGH_WATER_MARK: unset or empty, but the faucet profile is active (the faucet exits at startup without it)"
      missing=$((missing + 1))
    elif [ "$high_water_ok" -ne 1 ]; then
      echo "  ERROR FAUCET_HIGH_WATER_MARK: malformed (a positive whole-WRF amount, at most 8 decimals, at most 90071992.54740991; value not shown)"
      missing=$((missing + 1))
    else
      echo "  faucet: FAUCET_HIGH_WATER_MARK set (positive, well-formed)"
    fi
  fi
fi

# Genesis faucet address (core4#3361 option B, owner ruling 2026-09-28).
#
# WRFCOIN_GENESIS_FAUCET_ADDRESS is a CUT-ONLY input: the node that cuts block 1
# writes it into block 1, and every node reads it back from there forever
# (core4 launch_api main.rs, "Optional cut input"). The live chain 777 was cut
# on 2026-09-13 without it, so its faucet slice never mints (core4#3361).
#
# Which chains need one is decided by the GENESIS chain id pinned here
# (WRFCOIN_CUT_NETWORK_ID=testnet). Legacy pins without a network use
# WRFCOIN_CHAIN_ID (default unchanged); new testnet cuts require a faucet.
#
# Steady state (no --cut) never ERRORs: followers never read the variable, and
# chain 777 already exists without one. Only the cutting host, run with --cut,
# is refused:
#   --cut, faucet chain:  pin empty or malformed                     -> ERROR
#                         the value wrfcoin-node would RECEIVE is
#                         absent, malformed or != pin                -> ERROR
#   no --cut:             empty pin on a faucet chain                -> WARN
#                         malformed pin                              -> WARN
#                         host .env set and != pin                   -> WARN
# "What the node receives" is read from the EFFECTIVE compose render of this
# exact file set with this env file and this process environment (the same
# render the CORS check uses), as services.wrfcoin-node.environment. A .env line
# is not evidence: compose may never forward it, may forward it to another
# service, or a literal (render-cut-overlay.sh writes one into
# docker-compose.cut.yml) or an exported shell value may override it.
# Addresses are 0x + 40 hex, compared case-insensitively; the zero address is
# malformed (it would mint the faucet slice to nobody). No value is ever printed.
FAUCET_CHAIN_IDS="${WRFCOIN_CHAIN_ID:-777}"
canonical_address() {
  local v
  v="$(trim_ws "$1")"
  [[ "$v" =~ ^0x[0-9a-fA-F]{40}$ ]] || return 1
  v="$(printf '%s' "$v" | tr 'A-F' 'a-f')"
  [ "$v" != "0x0000000000000000000000000000000000000000" ] || return 1
  printf '%s' "$v"
}
# Prints one word for the faucet address wrfcoin-node receives after the render:
# NOSERVICE | ABSENT | MALFORMED | MATCH | MISMATCH. Never the value itself.
rendered_node_faucet() {
  local render args=(--env-file "$ENV_FILE") f verdict
  for f in "${present[@]}"; do args+=(-f "$f"); done
  render="$(mktemp "${TMPDIR:-/tmp}/faucet-render.XXXXXX")"
  if ! docker compose "${args[@]}" config --format json > "$render" 2> "$render.err"; then
    echo "RENDERFAIL"
    rm -f "$render" "$render.err"
    return 0
  fi
  verdict="$(PIN="$1" python3 - "$render" <<'PY'
import json, re, os, sys
cfg = json.load(open(sys.argv[1]))
svc = (cfg.get("services") or {}).get("wrfcoin-node")
if svc is None:
    print("NOSERVICE"); sys.exit()
env = svc.get("environment") or {}
if isinstance(env, list):
    env = dict(e.split("=", 1) if "=" in e else (e, None) for e in env)
if "WRFCOIN_GENESIS_FAUCET_ADDRESS" not in env or not (env["WRFCOIN_GENESIS_FAUCET_ADDRESS"] or "").strip():
    print("ABSENT"); sys.exit()
v = env["WRFCOIN_GENESIS_FAUCET_ADDRESS"].strip().lower()
if not re.fullmatch(r"0x[0-9a-f]{40}", v) or v == "0x" + "0" * 40:
    print("MALFORMED"); sys.exit()
print("MATCH" if v == os.environ["PIN"] else "MISMATCH")
PY
)" || verdict="RENDERFAIL"
  rm -f "$render" "$render.err"
  printf '%s' "$verdict"
}
if [ "$pins_ok" -eq 1 ]; then
  cut_chain_id="$(trim_ws "$(strip_quotes "$(printf '%s\n' "$pins_content" | sed -n 's/^WRFCOIN_CUT_CHAIN_ID=//p' | tail -1)")")"
  pinned_faucet="$(trim_ws "$(strip_quotes "$(printf '%s\n' "$pins_content" | sed -n 's/^WRFCOIN_CUT_GENESIS_FAUCET_ADDRESS=//p' | tail -1)")")"
  host_faucet="$(trim_ws "$(strip_quotes "$(sed -n 's/^WRFCOIN_GENESIS_FAUCET_ADDRESS=//p' "$ENV_FILE" | tail -1)")")"
  cut_network_id="$(trim_ws "$(strip_quotes "$(printf '%s\n' "$pins_content" | sed -n 's/^WRFCOIN_CUT_NETWORK_ID=//p' | tail -1)")")"
  faucet_chain=0
  [ "$cut_network_id" = testnet ] && faucet_chain=1
  for id in $FAUCET_CHAIN_IDS; do [ "$cut_chain_id" = "$id" ] && faucet_chain=1; done
  if [ "$faucet_chain" -eq 0 ]; then
    [ "$CUT_MODE" -eq 1 ] && echo "  genesis faucet: not required (chain id '${cut_chain_id}' has no faucet slice)"
  elif [ "$CUT_MODE" -eq 1 ]; then
    if [ -z "$pinned_faucet" ]; then
      echo "  ERROR WRFCOIN_CUT_GENESIS_FAUCET_ADDRESS: chain ${cut_chain_id} funds a faucet slice, but $(basename "$CUT_PINS") pins no genesis faucet address (core4#3361)"
      missing=$((missing + 1))
    elif ! pin_faucet="$(canonical_address "$pinned_faucet")"; then
      echo "  ERROR WRFCOIN_CUT_GENESIS_FAUCET_ADDRESS in $CUT_PINS: must be 0x + 40 hex and not the zero address"
      missing=$((missing + 1))
    else
      case "$(rendered_node_faucet "$pin_faucet")" in
        MATCH)
          echo "  genesis faucet: wrfcoin-node receives a valid address equal to the cut pin" ;;
        ABSENT)
          echo "  ERROR WRFCOIN_GENESIS_FAUCET_ADDRESS: wrfcoin-node does not receive it in the rendered compose chain (render testnet/scripts/render-cut-overlay.sh into docker-compose.cut.yml)"
          missing=$((missing + 1)) ;;
        MALFORMED)
          echo "  ERROR WRFCOIN_GENESIS_FAUCET_ADDRESS: the value wrfcoin-node receives must be 0x + 40 hex and not the zero address"
          missing=$((missing + 1)) ;;
        MISMATCH)
          echo "  ERROR WRFCOIN_GENESIS_FAUCET_ADDRESS: the value wrfcoin-node receives does not match the genesis faucet address pinned in $(basename "$CUT_PINS")"
          missing=$((missing + 1)) ;;
        NOSERVICE)
          echo "  ERROR WRFCOIN_GENESIS_FAUCET_ADDRESS: no wrfcoin-node service in the rendered compose chain, so nothing would cut block 1 with it"
          missing=$((missing + 1)) ;;
        *)
          echo "  UNVERIFIED WRFCOIN_GENESIS_FAUCET_ADDRESS: effective compose render failed"
          missing=$((missing + 1)) ;;
      esac
    fi
  elif [ -z "$pinned_faucet" ]; then
    echo "  WARN  WRFCOIN_CUT_GENESIS_FAUCET_ADDRESS: chain predates #3361; faucet unbound until option A"
  elif ! canonical_address "$pinned_faucet" >/dev/null; then
    echo "  WARN  WRFCOIN_CUT_GENESIS_FAUCET_ADDRESS in $(basename "$CUT_PINS"): malformed (0x + 40 hex, not zero); a --cut would refuse it"
  elif [ -n "$host_faucet" ] && [ "$(canonical_address "$host_faucet" || true)" != "$(canonical_address "$pinned_faucet" || true)" ]; then
    echo "  WARN  WRFCOIN_GENESIS_FAUCET_ADDRESS: set on this host but does not match the cut pin (read only at a cut; fix before cutting)"
  fi
fi

# Invitee-onboarding variables (backend origin/main; infra#1146 + the r17 pin). None of
# these is compose-required (`:?` would break the join command, the #762 trap), so
# the scan above cannot see them, yet each one silently disables a step an invitee
# sees. WARN, never a failure: they are legitimately empty on a host that does not
# serve invitees. Only checked when the chain's compose passes the variable through.
# The .env line is read, not an exported value (compose prefers an exported one).
# Values are never printed, only their class.
env_val() { strip_quotes "$(sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1)"; }
chain_passes() { grep -qE "^[[:space:]]+$1:" "${present[@]}" 2>/dev/null; }
if chain_passes STATION_CHAIN_SYNC_ENABLED && [ "$(env_val STATION_CHAIN_SYNC_ENABLED)" != "true" ]; then
  echo "  WARN  STATION_CHAIN_SYNC_ENABLED: not 'true'; no registered phone is ever marked on_chain, so every invitee stays 'awaiting activation' and cannot upload readings"
fi
if chain_passes WRFCOIN_READER_TOKEN && [ -z "$(env_val WRFCOIN_READER_TOKEN)" ]; then
  echo "  WARN  WRFCOIN_READER_TOKEN: empty; reading uploads and the wallet balance read answer 503 CORE4_READER_CREDENTIAL_UNCONFIGURED, so invitees cannot upload or see a balance"
fi
if chain_passes EXPLORER_FAUCET_ADDRESS && [ -z "$(env_val EXPLORER_FAUCET_ADDRESS)" ]; then
  echo "  WARN  EXPLORER_FAUCET_ADDRESS: empty; the mobile explorer summary reports faucetFunded as unknown (null)"
fi
for gv in WRFCOIN_GOVERNANCE_CHAIN_ID WRFCOIN_GOVERNANCE_NETWORK_ID WRFCOIN_GOVERNANCE_SIGNING_VERSION; do
  if chain_passes "$gv" && [ -z "$(env_val "$gv")" ]; then
    echo "  WARN  $gv: empty; governance voting answers 503 (needs signing version, chain id and network id), so invitees cannot vote"
  fi
done
if chain_passes WRFCOIN_GOVERNANCE_SIGNING_VERSION; then
  gsv="$(env_val WRFCOIN_GOVERNANCE_SIGNING_VERSION)"
  if [ -n "$gsv" ] && [ "$gsv" != "1" ] && [ "$gsv" != "2" ]; then
    echo "  WARN  WRFCOIN_GOVERNANCE_SIGNING_VERSION: not 1 or 2; governance voting answers 503 (the live chain 777 verifies version 1 until the signing-v2 schedule extension)"
  fi
fi

operator_token=$(sed -n 's/^WRFCOIN_OPERATOR_TOKEN=//p' "$ENV_FILE" | tail -n 1)
contributor_token=$(sed -n 's/^WRFCOIN_CONTRIBUTOR_TOKEN=//p' "$ENV_FILE" | tail -n 1)
if [ -n "$operator_token" ] && [ "$operator_token" = "$contributor_token" ]; then
  echo "  UNSAFE AUTHORITY: WRFCOIN_CONTRIBUTOR_TOKEN must differ from WRFCOIN_OPERATOR_TOKEN"
  missing=$((missing + 1))
fi

echo
if [ "$missing" -eq 0 ]; then
  echo "PASS: every required variable is present and non-empty."
else
  echo "FAIL: $missing problem(s). Fix before \`docker compose up\` -- compose reports only the first."
fi

# Say plainly what this cannot see, so a PASS is not mistaken for completeness.
cat <<'NOTE'

NOT CHECKED, and a PASS does not cover it:
  - guards inside the node BINARY rather than compose (e.g. the storage-encryption
    exit, and #2713's chain-identity refusal). Those need a real start.
  - whether a value is CORRECT, only that it is non-empty. An operator-verified
    reachable multiaddr and a plausible-looking one are indistinguishable here.
    (CORS_ORIGIN is the exception: its EFFECTIVE rendered value is validated,
    so run this in the same shell, with the same -f list, as the `up`.)
  - variables an overlay introduces that is not in the detected chain.
  - whether a trusted snapshot signer belongs to the intended ceremony. This
    check validates syntax, and equality with a cut-pins.env pin when one exists.
  - an EXPORTED FAUCET_HIGH_WATER_MARK: compose would prefer it over the .env
    line, but only the .env line is checked.
  - whether a genesis faucet address is the INTENDED faucet wallet. --cut checks
    that the value wrfcoin-node receives equals the pin; read it back out
    of block 1 after the cut (core4 GENESIS_CUT_RUNBOOK step 6b-faucet).
NOTE

if [ "$missing" -eq 0 ]; then exit 0; else exit 1; fi
