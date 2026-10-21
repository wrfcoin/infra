#!/usr/bin/env bash
# lint-all-dockerfiles.sh — lint every Dockerfile in the repo, by discovery. (infra#741)
#
# WHY THIS EXISTS
# ---------------
# The `Lint Dockerfiles` job in testnet-docker-validate.yml hard-coded three
# paths:
#     infra/docker/Dockerfile.backend
#     infra/docker/Dockerfile.core
#     testnet/Dockerfile.frontend
# On #737 it reported GREEN having read **0 of the 1 file that PR changed**.
# A check named "Lint Dockerfiles" that lints 3 of 35 is worse than no check:
# it produces a green that a reviewer reasonably reads as full coverage.
#
# THE DISCOVERY GLOB IS WIDER THAN THE OBVIOUS ONE — ON PURPOSE
# --------------------------------------------------------------
# build-boot-gate.yml discovers with:
#     (^|/)(Dockerfile[^/]*|[^/]*\.[Dd]ockerfile)$
# which requires the basename to START with "Dockerfile" or END with
# ".dockerfile". That misses `infra/docker/docker-k6-distributed-Dockerfile`,
# whose basename does neither — and the same blind spot exists in that
# workflow's `paths:` filter (`**/Dockerfile`, `**/Dockerfile.*`,
# `**/*.dockerfile`), so changing that file triggers no gate at all.
#
# That was not hypothetical. The historical file did not parse:
#     legacy builder : dockerfile parse error on line 779: unknown instruction: EOF
#     BuildKit       : dockerfile parse error line 53: unknown instruction: IMPORT
# It was a live instance of the #708 defect class, invisible to the gate that
# was built to catch #708 because of how the file was named. It was deleted in
# #752; the wider end-anchored form is retained deliberately for future files
# with this naming shape, rather than relying on today's inventory.
#
# So this discovers on basename *containing* Dockerfile/dockerfile.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

HADOLINT="${HADOLINT_IMAGE:-hadolint/hadolint@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d}"

# --------------------------------------------------------------------------
# QUARANTINE — files allowed to fail hadolint's PARSER, with a reason each.
#
# This is not a way to silence findings. A quarantined file that starts
# parsing FAILS this script, so the entry cannot outlive the defect: whoever
# fixes the file is told to delete its exemption in the same change. A stale
# exemption is worse than no exemption, so it is built to expire.
#
# A quarantined file is still linted; a real rule violation (DL/SC code) in one
# is still an error. Only the parser failure is tolerated.
# --------------------------------------------------------------------------
declare -A QUARANTINE=()

RC=0
ERRORS=0
WARNINGS=0

# Does Docker's OWN parser accept this file?
#
# build-boot-gate.yml downgrades a hadolint parser failure to a warning on the
# grounds that "step 1 already proved Docker parses it". That is sound there
# and unsound in general — it is an assumption, and for
# docker-k6-distributed-Dockerfile it is false. So prove it per file instead.
#
# `--target` names a stage that cannot exist. Docker must parse the entire file
# to discover the stage is missing, so "target stage ... could not be found"
# is positive evidence that parsing succeeded. The context is an empty
# directory, so nothing is uploaded and nothing is built.
#
# BuildKit FIRST: it is the parser real builds use (Compose v2, build-boot-gate).
# The classic builder on Docker 20.10, which is CT102's daemon default, has no
# heredoc support. It rejects valid files such as Dockerfile.soil-model
# (`RUN cat > f << 'PYEOF'`) with `unknown instruction: """Soil`, a permanent
# false RED; build-boot-gate.yml documents the same trap. Fall back to the
# daemon default ONLY when this client cannot use BuildKit at all (Docker >= 23
# without the buildx plugin), and record that. The fixture self-test below
# proves whichever parser is in use can still fail.
PARSER="BuildKit"
docker_parses() {
  local f="$1" empty out
  empty="$(mktemp -d)"
  out="$(DOCKER_BUILDKIT=1 docker build -f "$f" --target r124_parse_probe_nonexistent "$empty" 2>&1)"
  if grep -q 'buildx component is missing' <<<"$out"; then
    PARSER="daemon default (BuildKit unavailable on this client: no buildx)"
    out="$(docker build -f "$f" --target r124_parse_probe_nonexistent "$empty" 2>&1)"
  fi
  rmdir "$empty" 2>/dev/null
  grep -q 'could not be found' <<<"$out"
}

# Self-test: the probe must reject the #708 fixture and accept its fixed twin
# (the same pair build-boot-gate.yml uses). A probe that accepts everything
# would turn every "DOES NOT PARSE" check below into a silent pass.
if docker_parses .github/gate-fixtures/708-red.dockerfile.fixture; then
  echo "::error::parser probe is blind: it accepted the #708 red fixture (parser: $PARSER)"
  exit 1
fi
if ! docker_parses .github/gate-fixtures/708-green.dockerfile.fixture; then
  echo "::error::parser probe rejects the #708 green fixture (parser: $PARSER); it cannot tell valid from invalid"
  exit 1
fi
echo "parser probe self-test: rejects 708-red, accepts 708-green (parser: $PARSER)"

# The basename must START with "Dockerfile" (Dockerfile, Dockerfile.ml) or END
# with it (docker-k6-distributed-Dockerfile, foo.dockerfile). Matching merely
# "contains" is too wide and caught this very script — `lint-all-dockerfiles.sh`
# contains "dockerfile" — which then failed to parse as a Dockerfile. That is
# why the pattern is anchored at both ends rather than loose.
mapfile -t FILES < <(git ls-files \
  | grep -E '(^|/)([Dd]ockerfile[^/]*|[^/]*[Dd]ockerfile)$' \
  | grep -v '^\.github/gate-fixtures/' | sort)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "::error::0 Dockerfiles discovered — the discovery glob is broken"
  exit 1
fi

echo "discovered ${#FILES[@]} Dockerfile(s) by content-independent name match"
echo

for f in "${FILES[@]}"; do
  out="$(docker run --rm -i "$HADOLINT" \
          hadolint --no-color --failure-threshold error - < "$f" 2>&1)"
  rc=$?

  quarantined=0
  [ -n "${QUARANTINE[$f]+x}" ] && quarantined=1

  if [ "$rc" -eq 0 ]; then
    if [ "$quarantined" -eq 1 ]; then
      # The exemption outlived the defect. Fail, so it gets removed.
      echo "::error file=$f::this file is in QUARANTINE but now lints clean — delete its entry from scripts/lint-all-dockerfiles.sh"
      ERRORS=$((ERRORS + 1)); RC=1
    else
      echo "  ok        $f"
    fi
    continue
  fi

  if grep -qE '(DL[0-9]{4}|SC[0-9]{4})' <<<"$out"; then
    # A real rule violation. An error whether or not the file is quarantined.
    echo "::error file=$f::hadolint rule violation"
    sed "s|^-|$f|;s|^/dev/stdin|$f|" <<<"$out"
    ERRORS=$((ERRORS + 1)); RC=1
  elif docker_parses "$f"; then
    # hadolint's parser refused it but Docker's accepts it. A hadolint
    # limitation, not a defect in the file. Proven per file, not assumed.
    echo "::warning file=$f::hadolint cannot parse this file; Docker's own parser accepts it (probed)"
    WARNINGS=$((WARNINGS + 1))
  elif [ "$quarantined" -eq 1 ]; then
    # Docker cannot parse it either — a real #708-class defect, held under a
    # stated, self-retiring exemption.
    echo "::warning file=$f::DOES NOT PARSE (Docker's own parser) — QUARANTINED: ${QUARANTINE[$f]}"
    WARNINGS=$((WARNINGS + 1))
  else
    echo "::error file=$f::DOES NOT PARSE — Docker's own parser rejects this file (#708 class)"
    sed "s|^-|$f|;s|^/dev/stdin|$f|" <<<"$out"
    ERRORS=$((ERRORS + 1)); RC=1
  fi
done

# A quarantine entry for a file that no longer exists is stale config. Fail so
# it is removed with the deletion, not left to rot.
for q in "${!QUARANTINE[@]}"; do
  [ -f "$q" ] || { echo "::error::QUARANTINE lists '$q', which is not in the tree — delete the stale entry"; ERRORS=$((ERRORS + 1)); RC=1; }
done

echo
echo "linted ${#FILES[@]} file(s): $ERRORS error(s), $WARNINGS quarantined-parse-warning(s)"
echo
echo "NOTE: threshold is 'error'. A survey at --failure-threshold info across"
echo "this same set reports 118 further findings (87 warning, 31 info) and"
echo "ZERO at error level. Those are tracked separately, not silently ignored;"
echo "raising the threshold is a deliberate follow-up, not a side effect."

exit $RC
