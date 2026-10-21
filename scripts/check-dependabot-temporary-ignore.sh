#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${DEPENDABOT_CONFIG:-${ROOT}/.github/dependabot.yml}"
LEDGER="${DEPENDABOT_TEMPORARY_IGNORES:-${ROOT}/.github/dependabot-temporary-ignores.yml}"
TODAY="${DEPENDABOT_TODAY:-$(date -u +%F)}"

python3 - "${CONFIG}" "${LEDGER}" "${TODAY}" <<'PY'
import datetime as dt
import pathlib
import re
import sys

import yaml


def load_yaml(path, label):
    try:
        return yaml.safe_load(pathlib.Path(path).read_text())
    except FileNotFoundError:
        raise SystemExit(f"FAIL: missing {label}: {path}")
    except yaml.YAMLError as error:
        raise SystemExit(f"FAIL: invalid {label}: {error}")


def fail(message):
    raise SystemExit(f"FAIL: {message}")


def parse_date(value, label):
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        fail(f"{label} must be an ISO date YYYY-MM-DD")
    try:
        return dt.date.fromisoformat(value)
    except ValueError:
        fail(f"{label} is not a valid calendar date")


config_path, ledger_path, today_text = sys.argv[1:]
config = load_yaml(config_path, "Dependabot config")
ledger = load_yaml(ledger_path, "ignore ledger")
today = parse_date(today_text, "DEPENDABOT_TODAY")

if not isinstance(config, dict) or config.get("version") != 2:
    fail("Dependabot config must declare version: 2")
updates = config.get("updates")
if not isinstance(updates, list):
    fail("Dependabot config must contain updates")

if not isinstance(ledger, dict) or ledger.get("version") != 2:
    fail("ignore ledger must declare version: 2")

# --- Policy ignores: standing owner policy, no expiry, guard-pinned scope.
# Exactly two, in order: the node LTS policy (#745) and the ubuntu
# release-line freeze (#760). ---
policy_records = ledger.get("policy_ignores")
if not isinstance(policy_records, list) or len(policy_records) != 3:
    fail(
        "policy-ignore ledger must contain exactly three entries "
        "(node #745, ubuntu #760, python #873)"
    )


def check_policy(record, label, expected_issue, expected_reviewed, required_keys, expected_scope):
    if not isinstance(record, dict):
        fail(f"{label} policy ledger entry must be a mapping")
    if set(record) != required_keys:
        missing = sorted(required_keys - set(record))
        extra = sorted(set(record) - required_keys)
        fail(f"{label} policy ledger fields mismatch; missing={missing} extra={extra}")
    if record["issue"] != expected_issue:
        fail(f"{label} policy ledger issue must be {expected_issue}, got {record['issue']!r}")
    reviewed = parse_date(record["reviewed-on"], f"{label} policy reviewed-on")
    if reviewed != expected_reviewed:
        fail(
            f"{label} policy ledger boundary must remain reviewed-on "
            f"{expected_reviewed.isoformat()}; changing the policy rewrites this "
            "guard deliberately"
        )
    if today < reviewed:
        fail(f"DEPENDABOT_TODAY precedes {label} policy reviewed-on")
    for field, expected in expected_scope.items():
        if record[field] != expected:
            fail(f"{label} policy ledger {field} must remain {expected!r}, got {record[field]!r}")


check_policy(
    policy_records[0],
    "node",
    expected_issue=745,
    expected_reviewed=dt.date(2026, 8, 29),
    required_keys={
        "issue",
        "package-ecosystem",
        "dependency-name",
        "update-types",
        "applies-to-directories",
        "reviewed-on",
    },
    expected_scope={
        "package-ecosystem": "docker",
        "dependency-name": "node",
        "update-types": ["version-update:semver-major"],
        "applies-to-directories": "all-docker-entries",
    },
)

check_policy(
    policy_records[1],
    "ubuntu",
    expected_issue=760,
    expected_reviewed=dt.date(2026, 8, 30),
    required_keys={
        "issue",
        "package-ecosystem",
        "directory",
        "dependency-name",
        "update-types",
        "reviewed-on",
    },
    expected_scope={
        "package-ecosystem": "docker",
        "directory": "/infra/docker",
        "dependency-name": "ubuntu",
        # BOTH levels: ubuntu release lines live in the semver minor (#760).
        # A major-only ignore is the inverted #713 shape that let 24.10
        # through (#739) — the test suite carries a RED control for exactly
        # that regression.
        "update-types": [
            "version-update:semver-major",
            "version-update:semver-minor",
        ],
    },
)

check_policy(
    policy_records[2],
    "python",
    expected_issue=873,
    expected_reviewed=dt.date(2026, 8, 30),
    required_keys={
        "issue",
        "package-ecosystem",
        "directory",
        "dependency-name",
        "update-types",
        "reviewed-on",
    },
    expected_scope={
        "package-ecosystem": "docker",
        "directory": "/infra/docker",
        "dependency-name": "python",
        # BOTH levels: python release lines also live in the semver minor
        # (3.11 -> 3.14, the #872 REAL-RED). Scoped to /infra/docker only —
        # /infra/monitoring runs 3.14 green and stays unfrozen.
        "update-types": [
            "version-update:semver-major",
            "version-update:semver-minor",
        ],
    },
)

# --- Temporary ignores: none. The #713 ubuntu exception graduated to the
# #760 policy. A new time-boxed exception is added together with a guard
# update that restores the expiry machinery for it. ---
records = ledger.get("temporary_ignores")
if records != []:
    fail(
        "temporary-ignore ledger must be an empty list (the #713 exception "
        f"graduated to the #760 policy); got {records!r}"
    )

# --- Actual config ignores must exactly match the ledger: every docker entry
# carries the node semver-major policy ignore; /infra/docker additionally
# carries the ubuntu and python major+minor freezes (ubuntu first, node,
# then python — the config order). Non-docker entries carry no ignore at
# all. ---
NODE_IGNORE = {
    "dependency-name": "node",
    "update-types": ["version-update:semver-major"],
}
UBUNTU_IGNORE = {
    "dependency-name": "ubuntu",
    "update-types": [
        "version-update:semver-major",
        "version-update:semver-minor",
    ],
}
PYTHON_IGNORE = {
    "dependency-name": "python",
    "update-types": [
        "version-update:semver-major",
        "version-update:semver-minor",
    ],
}

docker_entry_count = 0
for entry in updates:
    if not isinstance(entry, dict):
        fail("malformed Dependabot update entry")
    ecosystem = entry.get("package-ecosystem")
    directory = entry.get("directory")
    ignores = entry.get("ignore", [])
    if ignores is None:
        ignores = []
    if not isinstance(ignores, list):
        fail("Dependabot ignore must be a list")
    for ignore in ignores:
        if not isinstance(ignore, dict):
            fail("malformed Dependabot ignore entry")
    normalized = [
        {
            "dependency-name": ignore.get("dependency-name"),
            "update-types": ignore.get("update-types"),
        }
        for ignore in ignores
    ]
    if ecosystem == "docker":
        docker_entry_count += 1
        expected = (
            [UBUNTU_IGNORE, NODE_IGNORE, PYTHON_IGNORE]
            if directory == "/infra/docker"
            else [NODE_IGNORE]
        )
        if normalized != expected:
            fail(
                f"docker entry {directory!r} ignores do not match the ledger: "
                f"expected={expected!r} actual={normalized!r}"
            )
    else:
        if normalized:
            fail(
                f"non-docker entry {directory!r} carries ignores with no "
                f"ledger record: {normalized!r}"
            )

if docker_entry_count == 0:
    fail("no docker entries found; the ignore policies have nothing to bind")

print(
    "PASS: ignore ledger matches config; node LTS policy (#745) on "
    f"{docker_entry_count} docker entries; ubuntu (#760) and python (#873) "
    f"release-line freezes on /infra/docker; no temporary ignores; "
    f"today={today.isoformat()}"
)
PY
