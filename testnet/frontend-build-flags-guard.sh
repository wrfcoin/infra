#!/bin/sh
# Fail-closed guard for the frontend image's VITE_ENABLE_* flags (infra#974,
# frontend#348, frontend#381).
#
# The frontend's VITE_ENABLE_FULL_STUDIO, VITE_ENABLE_DEMO_SURFACES and
# VITE_ENABLE_OPERATOR_PREVIEW expose internal studio, demo and operator-preview
# routes. They may be set only for a staging build. testnet/Dockerfile.frontend
# runs this before `npm run build`:
#
#   WRFCOIN_FRONTEND_BUILD_VARIANT=public  (the default) every VITE_ENABLE_*
#       value must be empty: in the build environment AND in every .env file
#       in APP_DIR that vite could load under any --mode (.env, .env.local,
#       .env.<mode>, .env.<mode>.local); only *.example is exempt. Both the
#       KEY=value and the dotenv KEY: value forms count. The check is
#       pattern-based, so a flag added to the frontend later is covered without
#       editing this file.
#   WRFCOIN_FRONTEND_BUILD_VARIANT=staging  only empty or exactly `true` build
#       values are allowed. Non-empty frontend .env values are refused too:
#       explicit Docker build args are the only switches, as for the faucet.
#   anything else                           refused.
#
# Any non-empty value fails, not just `true`: the frontend's own parsing is not
# this gate's contract.
#
# VITE_PUBLIC_READONLY_PATHS (infra#983, frontend#360) is NOT a VITE_ENABLE_*
# surface: it is the Stage 1.5 public read-only stage (/explore, /explorer,
# /map, /search, station detail), so it is allowed in the public variant. It
# is checked in every variant:
#   - the build value must be empty (off, the default) or exactly `true`. The
#     frontend honors only the exact string `true`, so `TRUE`, `1` or `on`
#     would silently build the stage OFF; refusing makes a typo loud;
#   - no .env file may set it non-empty: the Dockerfile ARG is the one switch.
#
# VITE_FAUCET_OPEN (frontend#437 W28, owner ruling 2026-10-02 #14) is the
# onboarding faucet claim step (OnboardingPage.tsx isFaucetOpen). Same rules as
# VITE_PUBLIC_READONLY_PATHS: empty (the step says the faucet is not funded yet,
# the default) or exactly `true`, never from a .env file. Turning it on is the
# owner's call once the faucet is funded.
#
# VITE_DISABLE_WALLET_SEND (frontend#552 S9, infra#1329) is the web Send kill
# switch: the exact string `true` hides Send entirely. Web Send is ON for the
# public build (owner ruling 2026-10-15), so the PUBLIC variant refuses `true`
# rather than ship with Send silently hidden. Staging may set it. The guard
# always prints FRONTEND_DISABLE_WALLET_SEND=on (Send hidden) or =off (Send
# visible), so the build log and the deploy receipt record Send's state. Same
# value rules as the switches above: empty or exactly `true`, never from a
# .env file.
#
# Exit 0 = allowed, 1 = refused.
#
# usage: frontend-build-flags-guard.sh [APP_DIR]   (default: .)
set -u

app_dir="${1:-.}"
variant="${WRFCOIN_FRONTEND_BUILD_VARIANT-public}"

all_flags=$(env | sed -n -E 's/^(VITE_ENABLE_[A-Za-z0-9_]*)=.*/\1/p' | sort -u)
set_flags=""
for name in $all_flags; do
  # Read the actual value, including newlines; env's line rendering alone
  # misses a value whose first character is a newline. Names match above.
  eval "value=\"\${${name}-}\""
  [ -n "$value" ] && set_flags="$set_flags$name "
done
file_flags=""
for file in "$app_dir"/.env "$app_dir"/.env.*; do
  [ -f "$file" ] || continue
  name=${file##*/}
  case "$name" in *.example) continue ;; esac
  # KEY=value or KEY: value (dotenv accepts both), optionally after `export`;
  # a value of "" or '' is empty.
  found=$(sed -n -E \
    -e "s/^[[:space:]]*(export[[:space:]]+)?(VITE_ENABLE_[A-Za-z0-9_]*)[[:space:]]*[:=][[:space:]]*(\"\"|'')?[[:space:]]*(#.*)?\$/EMPTY/" \
    -e "/^EMPTY\$/d" \
    -e "s/^[[:space:]]*(export[[:space:]]+)?(VITE_ENABLE_[A-Za-z0-9_]*)[[:space:]]*[:=].*/\\2/p" "$file" | sort -u | tr '\n' ' ')
  [ -n "$found" ] && file_flags="$file_flags$name: $found"
done

# exact_true_switch NAME WHAT ON-LINE OFF-LINE: an explicit build-arg switch.
# Its build value must be empty (off) or exactly `true`,
# and no .env file may set it non-empty. Prints ON-LINE or OFF-LINE; exits 1
# on a refusal.
exact_true_switch() {
  name="$1"; what="$2"; on_line="$3"; off_line="$4"
  value=""
  eval "value=\"\${${name}-}\""
  case "$value" in
    ""|true) ;;
    *)
      echo "FRONTEND_FLAGS=REFUSED $name='$value': only empty ($what off, the default) or exactly 'true' (on)." >&2
      echo "  The frontend honors only the exact string 'true'; any other value would silently build the $what off." >&2
      exit 1
      ;;
  esac
  switch_files=""
  for file in "$app_dir"/.env "$app_dir"/.env.*; do
    [ -f "$file" ] || continue
    base=${file##*/}
    case "$base" in *.example) continue ;; esac
    found=$(sed -n -E \
      -e "s/^[[:space:]]*(export[[:space:]]+)?${name}[[:space:]]*[:=][[:space:]]*(\"\"|'')?[[:space:]]*(#.*)?\$/EMPTY/" \
      -e "/^EMPTY\$/d" \
      -e "s/^[[:space:]]*(export[[:space:]]+)?${name}[[:space:]]*[:=].*/set/p" "$file")
    [ -n "$found" ] && switch_files="$switch_files$base "
  done
  if [ -n "$switch_files" ]; then
    echo "FRONTEND_FLAGS=REFUSED $name is set in $app_dir env files: $switch_files" >&2
    echo "  The build arg $name is the only $what switch; empty the value or delete the line." >&2
    exit 1
  fi
  if [ "$value" = true ]; then echo "$on_line"; else echo "$off_line"; fi
}

exact_true_switch VITE_PUBLIC_READONLY_PATHS "Stage 1.5" \
  "FRONTEND_PUBLIC_READONLY=on (Stage 1.5 read-only stage built in)" "FRONTEND_PUBLIC_READONLY=off"
exact_true_switch VITE_FAUCET_OPEN "faucet claim" \
  "FRONTEND_FAUCET_OPEN=on (onboarding offers the faucet claim)" "FRONTEND_FAUCET_OPEN=off"

# The public variant must not hide Send. Judged before the switch prints, so a
# refused build never logs a state line.
if [ "$variant" = public ] && [ "${VITE_DISABLE_WALLET_SEND-}" = true ]; then
  echo "FRONTEND_FLAGS=REFUSED variant=public: VITE_DISABLE_WALLET_SEND=true would build the public image with web Send hidden." >&2
  echo "  Web Send is ON for the public build (owner ruling 2026-10-15). Empty the build arg, or use" >&2
  echo "  WRFCOIN_FRONTEND_BUILD_VARIANT=staging for an image that hides Send." >&2
  exit 1
fi
exact_true_switch VITE_DISABLE_WALLET_SEND "web Send kill switch" \
  "FRONTEND_DISABLE_WALLET_SEND=on (web Send HIDDEN)" "FRONTEND_DISABLE_WALLET_SEND=off (web Send visible)"

case "$variant" in
  public)
    if [ -n "$set_flags" ] || [ -n "$file_flags" ]; then
      echo "FRONTEND_FLAGS=REFUSED variant=public: VITE_ENABLE_* must be empty for a public build." >&2
      [ -n "$set_flags" ] && echo "  set in the build environment: $set_flags" >&2
      [ -n "$file_flags" ] && echo "  set in $app_dir env files: $file_flags" >&2
      echo "  Any non-empty value, including false, is refused. A .env copied from .env.example" >&2
      echo "  (frontend's sets VITE_ENABLE_CONTRACT_SURFACES=false) trips this: empty the value or" >&2
      echo "  delete the line." >&2
      echo "  These flags expose internal routes (frontend#348/#381). Build with" >&2
      echo "  WRFCOIN_FRONTEND_BUILD_VARIANT=staging for a staging image, never for release." >&2
      exit 1
    fi
    echo "FRONTEND_FLAGS=OK variant=public (no VITE_ENABLE_* set)"
    ;;
  staging)
    if [ -n "$file_flags" ]; then
      echo "FRONTEND_FLAGS=REFUSED variant=staging: VITE_ENABLE_* set in $app_dir env files: $file_flags" >&2
      echo "  Empty the frontend file values; use explicit build args instead." >&2
      exit 1
    fi
    # Validate even future environment switches by pattern. All declared
    # Docker ARGs are exported as ENV before this guard, including empties.
    for flag in $all_flags; do
      exact_true_switch "$flag" "staging surface" \
        "FRONTEND_STAGING_FLAG=$flag:on" "FRONTEND_STAGING_FLAG=$flag:off"
    done
    echo "FRONTEND_FLAGS=OK variant=staging (NOT a release image) set: ${set_flags:-none} ${file_flags}"
    ;;
  *)
    echo "FRONTEND_FLAGS=REFUSED unknown WRFCOIN_FRONTEND_BUILD_VARIANT '$variant' (public or staging)" >&2
    exit 1
    ;;
esac
