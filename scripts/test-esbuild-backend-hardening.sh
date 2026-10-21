#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/infra/docker/esbuild-backend.sh"
TMP_ROOT="${TMPDIR:-/tmp}/esbuild-backend-test-$$"
MOCK_BIN="$TMP_ROOT/bin"
mkdir -p "$MOCK_BIN"

# esbuild-backend.sh invokes the esbuild JS API via `node /tmp/build.mjs
# <infile> <outfile> --resolve-extensions=... --external:<pkg> ...` and
# redirects that process's stderr to /tmp/esbuild.log, then greps it for
# `Could not resolve "<pkg>"` lines. Mock `node` (not `npx`) to match the
# current build path; emit exactly that stderr shape on the failure scenarios.
cat > "$MOCK_BIN/node" <<'MOCK_NODE'
#!/bin/sh
set -eu

MODE="${MOCK_ESBUILD_MODE:-}"

# Drop the build.mjs script path ($1); remaining positionals are
# <infile> <outfile> followed by --flags.
[ "$#" -gt 0 ] && shift
INFILE="${1:-}"
OUTFILE="${2:-}"

write_bundle() {
  if [ -n "$OUTFILE" ]; then
    mkdir -p "$(dirname -- "$OUTFILE")"
    printf '%s\n' '// mock bundle' > "$OUTFILE"
  fi
}

case "$MODE" in
  package)
    case " $* " in
      *" --external:optional-native "*)
        write_bundle
        exit 0
        ;;
    esac
    echo 'Could not resolve "optional-native"' >&2
    exit 1
    ;;
  relative)
    echo 'Could not resolve "../server/utils/error-response.js"' >&2
    exit 1
    ;;
  absolute)
    echo 'Could not resolve "/app/backend/server/utils/error-response.js"' >&2
    exit 1
    ;;
  *)
    echo "unknown MOCK_ESBUILD_MODE: $MODE" >&2
    exit 2
    ;;
esac
MOCK_NODE
chmod +x "$MOCK_BIN/node"

assert_contains() {
  file="$1"
  text="$2"
  if ! grep -Fq "$text" "$file"; then
    echo "expected '$file' to contain: $text" >&2
    echo "--- $file ---" >&2
    cat "$file" >&2
    exit 1
  fi
}

assert_not_contains() {
  file="$1"
  text="$2"
  if grep -Fq "$text" "$file"; then
    echo "expected '$file' not to contain: $text" >&2
    echo "--- $file ---" >&2
    cat "$file" >&2
    exit 1
  fi
}

run_case() {
  name="$1"
  mode="$2"
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/server"
  printf '%s\n' 'console.log("fixture");' > "$case_dir/server/app.js"
  (
    cd "$case_dir"
    PATH="$MOCK_BIN:$PATH" MOCK_ESBUILD_MODE="$mode" \
      sh "$SCRIPT" server/app.js dist/app.cjs
  ) > "$case_dir/output.log" 2>&1
}

run_case package package
assert_contains "$TMP_ROOT/package/output.log" "Adding external: optional-native"
assert_contains "$TMP_ROOT/package/dist/externals.txt" "optional-native"

relative_dir="$TMP_ROOT/relative"
mkdir -p "$relative_dir/server"
printf '%s\n' 'console.log("fixture");' > "$relative_dir/server/app.js"
if (
  cd "$relative_dir"
  PATH="$MOCK_BIN:$PATH" MOCK_ESBUILD_MODE="relative" \
    sh "$SCRIPT" server/app.js dist/app.cjs
) > "$relative_dir/output.log" 2>&1; then
  echo "expected unresolved relative import to fail" >&2
  cat "$relative_dir/output.log" >&2
  exit 1
fi

assert_contains "$relative_dir/output.log" "refusing to externalize unresolved relative/absolute import: ../server/utils/error-response.js"
assert_not_contains "$relative_dir/output.log" "Adding external: ../server/utils/error-response.js"

absolute_dir="$TMP_ROOT/absolute"
mkdir -p "$absolute_dir/server"
printf '%s\n' 'console.log("fixture");' > "$absolute_dir/server/app.js"
if (
  cd "$absolute_dir"
  PATH="$MOCK_BIN:$PATH" MOCK_ESBUILD_MODE="absolute" \
    sh "$SCRIPT" server/app.js dist/app.cjs
) > "$absolute_dir/output.log" 2>&1; then
  echo "expected unresolved absolute import to fail" >&2
  cat "$absolute_dir/output.log" >&2
  exit 1
fi

assert_contains "$absolute_dir/output.log" "refusing to externalize unresolved relative/absolute import: /app/backend/server/utils/error-response.js"
assert_not_contains "$absolute_dir/output.log" "Adding external: /app/backend/server/utils/error-response.js"

echo "esbuild backend hardening tests passed"
