#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="${ROOT}/scripts/check-dependabot-temporary-ignore.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

config="${tmpdir}/dependabot.yml"
ledger="${tmpdir}/ledger.yml"
cp "${ROOT}/.github/dependabot.yml" "${config}"
cp "${ROOT}/.github/dependabot-temporary-ignores.yml" "${ledger}"

# Green control date: on/after both policy reviews (node 2026-08-29, ubuntu
# 2026-08-30). Every RED control below runs at the same date so it can only
# fail for its own injected reason.
GREEN_DATE=2026-08-30

run_guard() {
    local cfg="$1" ledger_path="$2" today="$3"
    DEPENDABOT_CONFIG="${cfg}" \
    DEPENDABOT_TEMPORARY_IGNORES="${ledger_path}" \
    DEPENDABOT_TODAY="${today}" \
    "${GUARD}"
}

expect_fail() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'FAIL: expected RED control: %s\n' "${label}" >&2
        exit 1
    fi
    printf 'RED control caught: %s\n' "${label}"
}

run_guard "${config}" "${ledger}" "${GREEN_DATE}"

sed 's/^  - issue: 745$/  - issue: 746/' "${ledger}" > "${tmpdir}/wrong-node-issue.yml"
expect_fail "mismatched node policy issue linkage" \
    run_guard "${config}" "${tmpdir}/wrong-node-issue.yml" "${GREEN_DATE}"

sed 's/^  - issue: 760$/  - issue: 761/' "${ledger}" > "${tmpdir}/wrong-ubuntu-issue.yml"
expect_fail "mismatched ubuntu policy issue linkage" \
    run_guard "${config}" "${tmpdir}/wrong-ubuntu-issue.yml" "${GREEN_DATE}"

sed 's/^  - issue: 873$/  - issue: 874/' "${ledger}" > "${tmpdir}/wrong-python-issue.yml"
expect_fail "mismatched python policy issue linkage" \
    run_guard "${config}" "${tmpdir}/wrong-python-issue.yml" "${GREEN_DATE}"

# Python variant of the inversion regression (#872/#873): drop semver-minor
# from ONLY the python ignore line — a major-only python freeze would let the
# 3.11 -> 3.14 class straight back through.
sed '/dependency-name: "python"/{n;s/, "version-update:semver-minor"//}' \
    "${config}" > "${tmpdir}/inverted-python.yml"
expect_fail "python ignore reverted to major-only (the #872 class)" \
    run_guard "${tmpdir}/inverted-python.yml" "${ledger}" "${GREEN_DATE}"

# THE #713 INVERSION REGRESSION (#739/#760): an ubuntu ignore that names only
# semver-major permits 24.04 -> 24.10. The guard must refuse that shape.
sed 's/\["version-update:semver-major", "version-update:semver-minor"\]/["version-update:semver-major"]/' \
    "${config}" > "${tmpdir}/inverted-ubuntu.yml"
expect_fail "ubuntu ignore reverted to major-only (the #713 inversion)" \
    run_guard "${tmpdir}/inverted-ubuntu.yml" "${ledger}" "${GREEN_DATE}"

sed '/^      - version-update:semver-minor$/d' "${ledger}" > "${tmpdir}/ledger-minor-dropped.yml"
expect_fail "ubuntu policy ledger record loses semver-minor" \
    run_guard "${config}" "${tmpdir}/ledger-minor-dropped.yml" "${GREEN_DATE}"

sed 's/dependency-name: "ubuntu"/dependency-name: "node"/' "${config}" > "${tmpdir}/scope-drift.yml"
expect_fail "actual ignore scope drift" \
    run_guard "${tmpdir}/scope-drift.yml" "${ledger}" "${GREEN_DATE}"

sed '0,/dependency-name: "node"/s//dependency-name: "nodejs"/' "${config}" > "${tmpdir}/node-policy-drift.yml"
expect_fail "node policy ignore renamed on one docker entry" \
    run_guard "${tmpdir}/node-policy-drift.yml" "${ledger}" "${GREEN_DATE}"

sed 's|directory: /infra/docker|directory: /infra/other|' "${config}" > "${tmpdir}/directory-drift.yml"
expect_fail "actual directory scope drift" \
    run_guard "${tmpdir}/directory-drift.yml" "${ledger}" "${GREEN_DATE}"

sed 's/version-update:semver-major/version-update:semver-minor/' "${config}" > "${tmpdir}/update-type-drift.yml"
expect_fail "actual update-type scope drift" \
    run_guard "${tmpdir}/update-type-drift.yml" "${ledger}" "${GREEN_DATE}"

sed 's/^temporary_ignores: \[\]$/temporary_ignores:\n  - issue: 999/' "${ledger}" > "${tmpdir}/temporary-reintroduced.yml"
expect_fail "temporary ignore reintroduced without a guard update" \
    run_guard "${config}" "${tmpdir}/temporary-reintroduced.yml" "${GREEN_DATE}"

sed 's/reviewed-on: "2026-08-29"/reviewed-on: "2026-08-15"/' "${ledger}" > "${tmpdir}/node-date-drift.yml"
expect_fail "node policy review date drift" \
    run_guard "${config}" "${tmpdir}/node-date-drift.yml" "${GREEN_DATE}"

sed 's/reviewed-on: "2026-08-30"/reviewed-on: "2026-08-15"/' "${ledger}" > "${tmpdir}/ubuntu-date-drift.yml"
expect_fail "ubuntu policy review date drift" \
    run_guard "${config}" "${tmpdir}/ubuntu-date-drift.yml" "${GREEN_DATE}"

expect_fail "injected date before ubuntu policy review" \
    run_guard "${config}" "${ledger}" 2026-08-29

printf 'PASS: policy-ignore RED controls and GREEN control\n'
