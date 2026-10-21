#!/usr/bin/env bash
# Public frontend builds fail closed on VITE_ENABLE_* (infra#974, frontend#348,
# frontend#381).
#
# 1. testnet/frontend-build-flags-guard.sh, the guard Dockerfile.frontend runs
#    before `npm run build`, run directly against env and .env-file fixtures:
#    a public build with any VITE_ENABLE_* non-empty is refused (pattern-based:
#    a flag invented here is refused too); staging is allowed; an unknown
#    variant is refused.
# 2. Dockerfile.frontend wiring: the guard runs in the build stage after the
#    frontend source is copied and before `npm run build`, every VITE_ENABLE_*
#    ARG is passed by compose and recorded as a label.
# 3. A real `docker compose config` render (no daemon): the default render
#    passes variant=public and empty flags; a staging render passes them through.
#
# 4. VITE_PUBLIC_READONLY_PATHS (infra#983, frontend#360), the Stage 1.5
#    read-only stage: default empty (off); exactly `true` is accepted in the
#    public variant; any other value, and any .env-file value, is refused.
#
# 5. VITE_FAUCET_OPEN (frontend#437 W28, owner ruling 2026-10-02 #14): the
#    onboarding faucet claim step. Same contract as 4: default empty (the step
#    says the faucet is not funded yet), exactly `true` opens the claim, any
#    other value and any .env-file value is refused, compose passes it with an
#    empty default and the image records it outside org.wrfcoin.frontend.*.
#
# The release-manifest side (a staging or flagged image is never FRESH) is in
# test-render-release-manifest.sh (frontend_internal_surface_images_never_fresh).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$ROOT/testnet/frontend-build-flags-guard.sh"
DOCKERFILE="$ROOT/testnet/Dockerfile.frontend"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILED=()
fail() { echo "  FAIL: $*" >&2; FAILED+=("$1"); }

# guard_case NAME WANT-RC [ENV=VALUE ...] -- runs the guard in a clean env
# (only PATH, plus the given assignments) against $TMP/app.
guard_case() {
  local name="$1" want="$2" rc
  shift 2
  # "$@" carries only VAR=value assignments from the callers in this file.
    # dynamic-payload-reviewed: frontend-flags-guard-env-assignments
  env -i PATH="$PATH" "$@" sh "$GUARD" "$TMP/app" > "$TMP/$name.out" 2>&1
  rc=$?
  if [[ $rc -ne $want ]]; then
    sed 's/^/    /' "$TMP/$name.out" >&2
    fail "$name" "returned $rc, expected $want"
    return 1
  fi
  echo "  ok    $name (rc=$rc)"
}
out_has() { grep -Fq -- "$2" "$TMP/$1.out" || { sed 's/^/    /' "$TMP/$1.out" >&2; fail "$1" "output lacks: $2"; }; }
fresh_app() { rm -rf "$TMP/app"; mkdir -p "$TMP/app"; }

echo "guard: environment"
fresh_app
guard_case defaults_empty_pass 0
out_has defaults_empty_pass 'FRONTEND_FLAGS=OK variant=public'
guard_case explicit_public_empty_flags_pass 0 WRFCOIN_FRONTEND_BUILD_VARIANT=public \
  VITE_ENABLE_FULL_STUDIO= VITE_ENABLE_DEMO_SURFACES= VITE_ENABLE_OPERATOR_PREVIEW=
guard_case operator_preview_on_public_red 1 VITE_ENABLE_OPERATOR_PREVIEW=true
out_has operator_preview_on_public_red 'VITE_ENABLE_OPERATOR_PREVIEW'
guard_case full_studio_on_public_red 1 VITE_ENABLE_FULL_STUDIO=true
guard_case demo_surfaces_on_public_red 1 WRFCOIN_FRONTEND_BUILD_VARIANT=public VITE_ENABLE_DEMO_SURFACES=true
# Any non-empty value, not just the frontend's exact `true`.
guard_case operator_preview_false_string_red 1 VITE_ENABLE_OPERATOR_PREVIEW=false
guard_case operator_preview_space_red 1 "VITE_ENABLE_OPERATOR_PREVIEW= "
# Pattern-based: a flag this guard has never heard of is refused.
guard_case unknown_future_flag_red 1 VITE_ENABLE_SOMETHING_NEW=1
out_has unknown_future_flag_red 'VITE_ENABLE_SOMETHING_NEW'
guard_case staging_allows_flags 0 WRFCOIN_FRONTEND_BUILD_VARIANT=staging \
  VITE_ENABLE_FULL_STUDIO=true VITE_ENABLE_OPERATOR_PREVIEW=true
out_has staging_allows_flags 'variant=staging (NOT a release image)'
guard_case unknown_variant_red 1 WRFCOIN_FRONTEND_BUILD_VARIANT=release
guard_case empty_variant_red 1 WRFCOIN_FRONTEND_BUILD_VARIANT=
guard_case unrelated_vite_vars_pass 0 VITE_API_URL=https://x.invalid VITE_WRFCOIN_CHAIN_ID=777

echo "guard: VITE_PUBLIC_READONLY_PATHS (Stage 1.5, infra#983)"
fresh_app
guard_case readonly_default_empty_off 0
out_has readonly_default_empty_off 'FRONTEND_PUBLIC_READONLY=off'
guard_case readonly_explicit_empty_off 0 VITE_PUBLIC_READONLY_PATHS=
out_has readonly_explicit_empty_off 'FRONTEND_PUBLIC_READONLY=off'
# Allowed in the PUBLIC variant: it is not a VITE_ENABLE_* surface.
guard_case readonly_true_public_pass 0 WRFCOIN_FRONTEND_BUILD_VARIANT=public VITE_PUBLIC_READONLY_PATHS=true
out_has readonly_true_public_pass 'FRONTEND_PUBLIC_READONLY=on'
out_has readonly_true_public_pass 'FRONTEND_FLAGS=OK variant=public'
guard_case readonly_true_default_variant_pass 0 VITE_PUBLIC_READONLY_PATHS=true
guard_case readonly_true_staging_pass 0 WRFCOIN_FRONTEND_BUILD_VARIANT=staging VITE_PUBLIC_READONLY_PATHS=true
# The frontend honors only the exact string `true`; everything else is refused
# rather than silently building the stage off.
for bad in TRUE True 1 on yes false off " true" "true " '"true"'; do
  case_name="readonly_value_$(printf '%s' "$bad" | tr -c 'A-Za-z0-9' '_')_red"
  guard_case "$case_name" 1 "VITE_PUBLIC_READONLY_PATHS=$bad"
  out_has "$case_name" 'FRONTEND_FLAGS=REFUSED VITE_PUBLIC_READONLY_PATHS'
done
guard_case readonly_bad_value_on_staging_red 1 WRFCOIN_FRONTEND_BUILD_VARIANT=staging VITE_PUBLIC_READONLY_PATHS=1
# It does not open the VITE_ENABLE_* gate: a public build with both is refused.
guard_case readonly_true_with_enable_flag_red 1 VITE_PUBLIC_READONLY_PATHS=true VITE_ENABLE_OPERATOR_PREVIEW=true
out_has readonly_true_with_enable_flag_red 'VITE_ENABLE_OPERATOR_PREVIEW'
# The build arg is the one switch: an .env file may not set it.
for file in .env .env.production .env.local; do
  fresh_app
  printf 'VITE_PUBLIC_READONLY_PATHS=true\n' > "$TMP/app/$file"
  guard_case "readonly_file_${file//[.-]/_}_red" 1
  out_has "readonly_file_${file//[.-]/_}_red" "set in $TMP/app env files: $file"
done
fresh_app
printf 'export VITE_PUBLIC_READONLY_PATHS: "true"\n' > "$TMP/app/.env.production"
guard_case readonly_file_export_colon_red 1
fresh_app
printf 'VITE_PUBLIC_READONLY_PATHS=\nVITE_PUBLIC_READONLY_PATHS=""  # off\n' > "$TMP/app/.env.production"
guard_case readonly_file_empty_pass 0
fresh_app
printf 'VITE_PUBLIC_READONLY_PATHS=true\n' > "$TMP/app/.env.example"
guard_case readonly_file_example_ignored 0

echo "guard: VITE_FAUCET_OPEN (faucet claim step, frontend#437)"
fresh_app
guard_case faucet_default_empty_off 0
out_has faucet_default_empty_off 'FRONTEND_FAUCET_OPEN=off'
guard_case faucet_explicit_empty_off 0 VITE_FAUCET_OPEN=
out_has faucet_explicit_empty_off 'FRONTEND_FAUCET_OPEN=off'
# Allowed in the PUBLIC variant: it is not a VITE_ENABLE_* surface.
guard_case faucet_true_public_pass 0 WRFCOIN_FRONTEND_BUILD_VARIANT=public VITE_FAUCET_OPEN=true
out_has faucet_true_public_pass 'FRONTEND_FAUCET_OPEN=on'
out_has faucet_true_public_pass 'FRONTEND_FLAGS=OK variant=public'
guard_case faucet_true_staging_pass 0 WRFCOIN_FRONTEND_BUILD_VARIANT=staging VITE_FAUCET_OPEN=true
# OnboardingPage.tsx isFaucetOpen() honors only the exact string `true`.
for bad in TRUE True 1 on yes false off " true" "true " '"true"'; do
  case_name="faucet_value_$(printf '%s' "$bad" | tr -c 'A-Za-z0-9' '_')_red"
  guard_case "$case_name" 1 "VITE_FAUCET_OPEN=$bad"
  out_has "$case_name" 'FRONTEND_FLAGS=REFUSED VITE_FAUCET_OPEN'
done
# Independent of the Stage 1.5 switch: each is judged on its own value.
guard_case faucet_true_readonly_off_pass 0 VITE_FAUCET_OPEN=true VITE_PUBLIC_READONLY_PATHS=
out_has faucet_true_readonly_off_pass 'FRONTEND_PUBLIC_READONLY=off'
guard_case faucet_bad_readonly_true_red 1 VITE_FAUCET_OPEN=1 VITE_PUBLIC_READONLY_PATHS=true
# It does not open the VITE_ENABLE_* gate.
guard_case faucet_true_with_enable_flag_red 1 VITE_FAUCET_OPEN=true VITE_ENABLE_FULL_STUDIO=true
out_has faucet_true_with_enable_flag_red 'VITE_ENABLE_FULL_STUDIO'
# The build arg is the one switch: an .env file may not set it.
for file in .env .env.production .env.local; do
  fresh_app
  printf 'VITE_FAUCET_OPEN=true\n' > "$TMP/app/$file"
  guard_case "faucet_file_${file//[.-]/_}_red" 1
  out_has "faucet_file_${file//[.-]/_}_red" "VITE_FAUCET_OPEN is set in $TMP/app env files: $file"
done
fresh_app
printf 'export VITE_FAUCET_OPEN: "true"\n' > "$TMP/app/.env.production"
guard_case faucet_file_export_colon_red 1
fresh_app
printf 'VITE_FAUCET_OPEN=\nVITE_FAUCET_OPEN=""  # off\n' > "$TMP/app/.env.production"
guard_case faucet_file_empty_pass 0
fresh_app
printf 'VITE_FAUCET_OPEN=true\n' > "$TMP/app/.env.example"
guard_case faucet_file_example_ignored 0

echo "guard: every .env file vite could load (any mode)"
# Review of #1048, non-blocking 2: every .env and .env.<mode>[.local] is
# scanned, not only the production-mode files; only *.example is exempt.
for file in .env .env.local .env.production .env.production.local \
    .env.staging .env.staging.local .env.development .env.development.local .env.test .env.custom-mode; do
  fresh_app
  printf '# comment\nVITE_API_URL=\nVITE_ENABLE_OPERATOR_PREVIEW=true\n' > "$TMP/app/$file"
  guard_case "file_${file//[.-]/_}_red" 1
  out_has "file_${file//[.-]/_}_red" "$file: VITE_ENABLE_OPERATOR_PREVIEW"
done
fresh_app
printf 'export VITE_ENABLE_FULL_STUDIO=true\n' > "$TMP/app/.env"
guard_case file_export_form_red 1
# Review of #1048, non-blocking 1: dotenv (Vite 7 loadEnv) also accepts
# `KEY: value`, which yields VITE_ENABLE_FULL_STUDIO=true.
fresh_app
printf 'VITE_ENABLE_FULL_STUDIO: true\n' > "$TMP/app/.env"
guard_case file_colon_form_red 1
out_has file_colon_form_red '.env: VITE_ENABLE_FULL_STUDIO'
fresh_app
printf 'export VITE_ENABLE_OPERATOR_PREVIEW : "true"\n' > "$TMP/app/.env.production"
guard_case file_export_colon_form_red 1
fresh_app
printf '  VITE_ENABLE_FUTURE_THING = yes # later flag\n' > "$TMP/app/.env.production"
guard_case file_unknown_future_flag_red 1
fresh_app
printf 'VITE_ENABLE_FULL_STUDIO=\nVITE_ENABLE_DEMO_SURFACES=""\nVITE_ENABLE_OPERATOR_PREVIEW=%s # off\nVITE_ENABLE_X:\nVITE_ENABLE_Y: ""\n' "''" > "$TMP/app/.env.production"
guard_case file_empty_values_pass 0
fresh_app
# Documentation only: *.example is never loaded by vite.
printf 'VITE_ENABLE_OPERATOR_PREVIEW=true\n' > "$TMP/app/.env.example"
printf 'VITE_ENABLE_OPERATOR_PREVIEW=true\n' > "$TMP/app/.env.production.example"
guard_case file_example_ignored 0
fresh_app
printf 'VITE_ENABLE_OPERATOR_PREVIEW=true\n' > "$TMP/app/.env.production"
guard_case file_on_staging_refused 1 WRFCOIN_FRONTEND_BUILD_VARIANT=staging
# Review of #1048, non-blocking 3: frontend's .env.example sets
# VITE_ENABLE_CONTRACT_SURFACES=false; a copy of it as .env is refused, and the
# refusal says why.
fresh_app
printf 'VITE_API_URL=\nVITE_ENABLE_CONTRACT_SURFACES=false\n' > "$TMP/app/.env"
guard_case file_copied_example_red 1
out_has file_copied_example_red 'copied from .env.example'
out_has file_copied_example_red 'Any non-empty value, including false, is refused'

echo "Dockerfile.frontend wiring"
python3 - "$DOCKERFILE" "$ROOT/testnet/docker-compose.override.yml" <<'PY' || fail dockerfile_wiring "see above"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
compose = open(sys.argv[2], encoding="utf-8").read()
stages = re.split(r"^FROM ", text, flags=re.M)
assert len(stages) == 3, f"expected two stages, got {len(stages) - 1}"
build, serve = stages[1], stages[2]
lines = build.splitlines()
def index(pattern):
    hits = [i for i, line in enumerate(lines) if re.search(pattern, line)]
    assert hits, f"build stage lacks {pattern!r}"
    return hits[0]
copy_src = index(r"^COPY frontend/ \.")
guard = index(r"frontend-build-flags-guard /app")
npm_build = index(r"^RUN npm run build")
assert copy_src < guard < npm_build, (copy_src, guard, npm_build)
# Every VITE_ENABLE_* ARG after the guard would bypass it.
flag_args = [i for i, line in enumerate(lines) if re.match(r"^ARG VITE_ENABLE_", line)]
assert flag_args and max(flag_args) < guard, "a VITE_ENABLE_* ARG is declared after the guard"
names = sorted(re.findall(r"^ARG (VITE_ENABLE_[A-Z0-9_]+)=$", build, re.M))
assert names == ["VITE_ENABLE_CONTRACT_SURFACES", "VITE_ENABLE_DEMO_SURFACES", "VITE_ENABLE_FULL_STUDIO", "VITE_ENABLE_OPERATOR_PREVIEW"], names
assert re.search(r"^ARG WRFCOIN_FRONTEND_BUILD_VARIANT=public$", build, re.M)
for name in names:
    label = "org.wrfcoin.frontend." + name[len("VITE_ENABLE_"):].lower().replace("_", "-")
    assert f'{label}="${name}"' in serve, f"serve stage does not label {label}"
    assert f"{name}: ${{{name}:-}}" in compose, f"compose does not pass {name} with an empty default"
assert 'org.wrfcoin.frontend.variant="$WRFCOIN_FRONTEND_BUILD_VARIANT"' in serve
assert "WRFCOIN_FRONTEND_BUILD_VARIANT: ${WRFCOIN_FRONTEND_BUILD_VARIANT:-public}" in compose
assert not re.search(r"^ENV VITE_ENABLE_", serve, re.M), "serve stage sets a VITE_ENABLE_* ENV"
# infra#983: VITE_PUBLIC_READONLY_PATHS defaults EMPTY, is declared before the
# guard, reaches the build as ENV, is passed by compose with an empty default,
# and is labelled OUTSIDE org.wrfcoin.frontend.* (any non-empty label there
# makes render-release-manifest.sh call the image STALE).
ro = [i for i, line in enumerate(lines) if re.match(r"^ARG VITE_PUBLIC_READONLY_PATHS", line)]
assert len(ro) == 1 and lines[ro[0]] == "ARG VITE_PUBLIC_READONLY_PATHS=", "build stage must declare ARG VITE_PUBLIC_READONLY_PATHS= (empty default) once"
assert ro[0] < guard, "VITE_PUBLIC_READONLY_PATHS is declared after the guard"
assert re.search(r"^ENV VITE_PUBLIC_READONLY_PATHS=\$VITE_PUBLIC_READONLY_PATHS$", build, re.M)
assert "VITE_PUBLIC_READONLY_PATHS: ${VITE_PUBLIC_READONLY_PATHS:-}" in compose, "compose does not pass VITE_PUBLIC_READONLY_PATHS with an empty default"
assert re.search(r"^ARG VITE_PUBLIC_READONLY_PATHS=$", serve, re.M)
assert 'LABEL org.wrfcoin.stage.public-readonly="$VITE_PUBLIC_READONLY_PATHS"' in serve
assert "org.wrfcoin.frontend.public-readonly" not in serve
assert not re.search(r"^ENV VITE_PUBLIC_READONLY_PATHS", serve, re.M)
# W28: VITE_FAUCET_OPEN follows the same contract, labelled org.wrfcoin.stage.faucet-open.
fo = [i for i, line in enumerate(lines) if re.match(r"^ARG VITE_FAUCET_OPEN", line)]
assert len(fo) == 1 and lines[fo[0]] == "ARG VITE_FAUCET_OPEN=", "build stage must declare ARG VITE_FAUCET_OPEN= (empty default) once"
assert fo[0] < guard, "VITE_FAUCET_OPEN is declared after the guard"
assert re.search(r"^ENV VITE_FAUCET_OPEN=\$VITE_FAUCET_OPEN$", build, re.M)
assert "VITE_FAUCET_OPEN: ${VITE_FAUCET_OPEN:-}" in compose, "compose does not pass VITE_FAUCET_OPEN with an empty default"
assert re.search(r"^ARG VITE_FAUCET_OPEN=$", serve, re.M)
assert 'LABEL org.wrfcoin.stage.faucet-open="$VITE_FAUCET_OPEN"' in serve
assert "org.wrfcoin.frontend.faucet" not in serve
assert not re.search(r"^ENV VITE_FAUCET_OPEN", serve, re.M)
print("  ok    guard after COPY frontend/ and before npm run build; ARGs, compose args and labels agree")
PY

echo "compose render (docker compose config, no daemon)"
if ! docker compose version >/dev/null 2>&1; then
  fail compose_render "docker compose v2 is required for the render cases"
else
  export WRFCOIN_FUNNEL_ORIGIN=https://fixture.invalid
  export WRFCOIN_P2P_EXTERNAL_ADDR=/ip4/198.51.100.7/tcp/9000
  export WRFCOIN_SEED_P2P_EXTERNAL_ADDR=/ip4/203.0.113.9/tcp/9000
  render() { # OUT [ENV=VALUE ...]
    local out="$1"; shift
    # "$@" carries only VAR=value assignments from the callers in this file.
        # dynamic-payload-reviewed: frontend-flags-render-env-assignments
    env "$@" bash "$ROOT/testnet/tests/render-testnet-compose.sh" --env-file "$ROOT/testnet/.env.testnet.example" \
      -f "$ROOT/testnet/docker-compose.testnet.yml" -f "$ROOT/testnet/docker-compose.override.yml" \
      config --format json > "$out" 2> "$out.err"
  }
  args_are() { # NAME JSON PYTHON-DICT
    python3 - "$2" "$3" <<'PY' || fail "$1" "rendered frontend build args differ"
import ast, json, sys
args = json.load(open(sys.argv[1]))["services"]["wrfcoin-frontend"]["build"]["args"]
want = ast.literal_eval(sys.argv[2])
got = {k: args.get(k) for k in want}
assert got == want, got
PY
    [[ " ${FAILED[*]-} " == *" $1 "* ]] || echo "  ok    $1"
  }
  if render "$TMP/default.json" -u VITE_ENABLE_OPERATOR_PREVIEW -u VITE_ENABLE_FULL_STUDIO \
      -u VITE_ENABLE_DEMO_SURFACES -u WRFCOIN_FRONTEND_BUILD_VARIANT -u VITE_PUBLIC_READONLY_PATHS -u VITE_FAUCET_OPEN; then
    args_are render_default_public_empty "$TMP/default.json" \
      "{'WRFCOIN_FRONTEND_BUILD_VARIANT': 'public', 'VITE_ENABLE_FULL_STUDIO': '', 'VITE_ENABLE_DEMO_SURFACES': '', 'VITE_ENABLE_OPERATOR_PREVIEW': '', 'VITE_PUBLIC_READONLY_PATHS': '', 'VITE_FAUCET_OPEN': ''}"
  else
    cat "$TMP/default.json.err" >&2; fail render_default_public_empty "compose render failed"
  fi
  if render "$TMP/staging.json" WRFCOIN_FRONTEND_BUILD_VARIANT=staging \
      VITE_ENABLE_FULL_STUDIO=true VITE_ENABLE_OPERATOR_PREVIEW=true; then
    args_are render_staging_passes_flags "$TMP/staging.json" \
      "{'WRFCOIN_FRONTEND_BUILD_VARIANT': 'staging', 'VITE_ENABLE_FULL_STUDIO': 'true', 'VITE_ENABLE_OPERATOR_PREVIEW': 'true'}"
  else
    cat "$TMP/staging.json.err" >&2; fail render_staging_passes_flags "compose render failed"
  fi
  if render "$TMP/readonly.json" -u WRFCOIN_FRONTEND_BUILD_VARIANT VITE_PUBLIC_READONLY_PATHS=true; then
    args_are render_public_readonly_true "$TMP/readonly.json" \
      "{'WRFCOIN_FRONTEND_BUILD_VARIANT': 'public', 'VITE_PUBLIC_READONLY_PATHS': 'true'}"
  else
    cat "$TMP/readonly.json.err" >&2; fail render_public_readonly_true "compose render failed"
  fi
  if render "$TMP/faucet.json" -u WRFCOIN_FRONTEND_BUILD_VARIANT VITE_FAUCET_OPEN=true; then
    args_are render_public_faucet_open_true "$TMP/faucet.json" \
      "{'WRFCOIN_FRONTEND_BUILD_VARIANT': 'public', 'VITE_FAUCET_OPEN': 'true'}"
  else
    cat "$TMP/faucet.json.err" >&2; fail render_public_faucet_open_true "compose render failed"
  fi
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "FRONTEND_BUILD_FLAGS_TESTS=FAIL cases: ${FAILED[*]}" >&2
  exit 1
fi
echo FRONTEND_BUILD_FLAGS_TESTS=PASS
