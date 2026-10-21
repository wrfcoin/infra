#!/bin/sh
# Bundle backend entry points with esbuild, auto-externalizing native modules.
#
# Usage:
#   sh esbuild-backend.sh                            # build all services (default)
#   sh esbuild-backend.sh <entry> <outfile>          # build one specific service
#   SERVICES="compute storage" sh esbuild-backend.sh # build a named subset
#
# Each entry point is compiled via /tmp/build.mjs (esbuild JS API + cjsInline
# plugin) which resolves imports ending in .cjs to their .js/.ts source and
# bundles them inline, producing a self-contained CJS bundle with no runtime
# shim files needed.
#
# Produces one CJS bundle per service under dist/ and writes dist/externals.txt
# listing every package that could not be bundled (needed in the runtime image).
set -e

# Full list of all backend service entry points.
# Format: <source_path>:<output_path>
ALL_ENTRIES="
server/enhanced_unified_api_optimized.ts:dist/server.cjs
server/governance_server.js:dist/governance_server.cjs
server/iot_sensor_networks_server.js:dist/iot_sensor.cjs
server/enhanced_weather_rewards.ts:dist/weather_earnings.cjs
server/cross_chain_protocol_server.js:dist/cross_chain_protocol_server.cjs
server/compute_networks_server.ts:dist/compute_networks_server.cjs
server/ai_ml_networks_server_impl.js:dist/ai_ml_networks_server.cjs
server/weather-ipfs-archive-worker.ts:dist/weather_ipfs_archive.cjs
server/easy_node_discovery.js:dist/easy_node_discovery.cjs
"

# --------------------------------------------------------------------------
# Select which entries to build (three modes, in priority order):
#
#  1. Positional args: sh esbuild-backend.sh <entry> <outfile>
#     Builds exactly that one pair — useful for CI or per-service rebuilds.
#
#  2. SERVICES env var: SERVICES="compute storage" sh esbuild-backend.sh
#     Space-separated list of output basenames (without .cjs) drawn from
#     ALL_ENTRIES above.  Example: SERVICES="wallet governance iot"
#
#  3. No args, no SERVICES: builds every entry in ALL_ENTRIES (default).
# --------------------------------------------------------------------------
if [ -n "$1" ] && [ -n "$2" ]; then
  ENTRIES="${1}:${2}"
elif [ -n "$SERVICES" ]; then
  ENTRIES=""
  for svc in $SERVICES; do
    match=$(printf '%s\n' $ALL_ENTRIES | grep ":dist/${svc}\.cjs$" | head -1)
    if [ -n "$match" ]; then
      ENTRIES="$ENTRIES $match"
    else
      echo "WARNING: no ALL_ENTRIES match for service '$svc' — skipping" >&2
    fi
  done
  if [ -z "$ENTRIES" ]; then
    echo "ERROR: SERVICES='$SERVICES' matched no known entries" >&2
    exit 1
  fi
else
  ENTRIES="$ALL_ENTRIES"
fi

BASE_EXTERNALS="--external:jsdom --external:canvas --external:dompurify --external:isomorphic-dompurify --external:onnxruntime-node"
ALL_EXTERNALS="$BASE_EXTERNALS"
MAX_ATTEMPTS=10

mkdir -p dist

for entry_pair in $ENTRIES; do
  INFILE="${entry_pair%%:*}"
  OUTFILE="${entry_pair##*:}"
  [ -z "$INFILE" ] && continue

  echo "=== Bundling $INFILE => $OUTFILE ==="
  EXTERNALS="$ALL_EXTERNALS"
  # One resolution order for every entry. (The old .js-first branch named
  # server/ai_ml_networks_server.js, an entry ALL_ENTRIES no longer has: ai_ml
  # bundles server/ai_ml_networks_server_impl.js, so the branch never ran.)
  RESOLVE_EXTENSIONS=".ts,.js,.json"

  SUCCESS=false
  for i in $(seq 1 $MAX_ATTEMPTS); do
    if node /tmp/build.mjs "$INFILE" "$OUTFILE" \
      --resolve-extensions="$RESOLVE_EXTENSIONS" \
      $EXTERNALS 2>/tmp/esbuild.log; then
      echo "  $OUTFILE succeeded (attempt $i)"
      cat /tmp/esbuild.log
      SUCCESS=true
      break
    fi

    MISSING=$(grep 'Could not resolve' /tmp/esbuild.log | sed 's/.*Could not resolve "\([^"]*\)".*/\1/' | sort -u)
    if [ -z "$MISSING" ]; then
      echo "  ERROR: build failed without resolvable externals"
      cat /tmp/esbuild.log
      exit 1
    fi

    for pkg in $MISSING; do
      case "$pkg" in
        ./*|../*|/*)
          echo "  ERROR: refusing to externalize unresolved relative/absolute import: $pkg"
          cat /tmp/esbuild.log
          exit 1
          ;;
      esac
    done

    for pkg in $MISSING; do
      echo "  Adding external: $pkg"
      EXTERNALS="$EXTERNALS --external:$pkg"
      ALL_EXTERNALS="$ALL_EXTERNALS --external:$pkg"
    done
  done

  if [ "$SUCCESS" = false ]; then
    echo "FATAL: $INFILE failed after $MAX_ATTEMPTS attempts"
    exit 1
  fi

  # ------------------------------------------------------------------------
  # Fail-loud guard (per bundle): a self-contained CJS bundle must contain
  # ZERO runtime require() of a *.cjs file. If any survive, the cjsInline
  # plugin failed to inline a source (missing .js/.ts/.cjs peer in this build
  # tree) and the runtime image would crash on boot with
  #   Error: Cannot find module '../../server/utils/strict-cors-config.cjs'
  # Catch it HERE, at build time, instead of shipping a crashing image.
  # ------------------------------------------------------------------------
  LEAKED=$(grep -oE "require\([^)]*\.cjs[^)]*\)" "$OUTFILE" | sort -u || true)
  if [ -n "$LEAKED" ]; then
    echo "FATAL: $OUTFILE contains unbundled runtime .cjs require()s — the"
    echo "cjsInline plugin could not inline these source files, so the image"
    echo "would crash on boot. Offending requires:"
    echo "$LEAKED"
    exit 1
  fi
  echo "  $OUTFILE guard OK (0 runtime .cjs requires)"
done

# Write deduplicated externals list for the Dockerfile pruner stage.
# Strip the well-known base externals so only discovered externals appear.
echo "$ALL_EXTERNALS" | tr ' ' '\n' | sed 's/--external://' | grep . | sort -u > dist/externals.txt
echo "=== Externalized packages ==="
cat dist/externals.txt
echo "=== All bundles built ==="
ls -lh dist/*.cjs
