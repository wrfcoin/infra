#!/usr/bin/env bash
# Guard the infra#474 coverage ledger; Dependabot itself parses this on GitHub.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${DEPENDABOT_CONFIG:-${ROOT}/.github/dependabot.yml}"

python3 - "${CONFIG}" "${ROOT}" <<'PY'
import pathlib
import sys
import yaml

try:
    document = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
except yaml.YAMLError as error:
    raise SystemExit(f"FAIL: invalid Dependabot YAML: {error}")
if not isinstance(document, dict) or document.get("version") != 2:
    raise SystemExit("FAIL: Dependabot config must declare version: 2")
entries = document.get("updates")
if not isinstance(entries, list):
    raise SystemExit("FAIL: Dependabot config must contain updates")
seen = set()
for entry in entries:
    if not isinstance(entry, dict):
        raise SystemExit("FAIL: malformed Dependabot entry")
    ecosystem, directory = entry.get("package-ecosystem"), entry.get("directory")
    if not isinstance(ecosystem, str) or not isinstance(directory, str):
        raise SystemExit("FAIL: Dependabot entry lacks ecosystem or directory")
    if entry.get("schedule", {}).get("interval") != "weekly":
        raise SystemExit(f"FAIL: Dependabot entry is not weekly: {ecosystem} {directory}")
    groups = entry.get("groups")
    if not isinstance(groups, dict) or len(groups) != 1:
        raise SystemExit(f"FAIL: Dependabot entry must have one group: {ecosystem} {directory}")
    group = next(iter(groups.values()))
    if not isinstance(group, dict) or group.get("patterns") != ["*"]:
        raise SystemExit(f"FAIL: group does not cover all dependencies: {ecosystem} {directory}")
    if group.get("exclude-patterns") or group.get("update-types"):
        raise SystemExit(f"FAIL: group can silently exclude update classes: {ecosystem} {directory}")
    seen.add((ecosystem, directory))

# The required set is DERIVED from the tree, not typed from memory: a manifest
# added next month must fail this gate until it gets a grouped weekly entry,
# because "someone remembered to extend a literal set" is exactly how
# /infra/terraform/compute-agent's provider pins went unscanned. Dependabot's
# `directory:` is not recursive, so every manifest-bearing directory is its own
# surface.
import os

root = pathlib.Path(sys.argv[2])
SKIP_DIRS = {".git", "node_modules", ".terraform", "__pycache__", ".venv", "dist", "build"}
MANIFESTS = (
    ("npm", lambda name: name == "package.json"),
    ("docker", lambda name: name == "Dockerfile" or name.startswith("Dockerfile.")),
    ("terraform", lambda name: name.endswith(".tf")),
    ("pip", lambda name: name == "pyproject.toml"
        or (name.startswith("requirements") and name.endswith(".txt"))),
)

required = set()
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not (d.startswith(".") and d != ".github")]
    rel = "/" + str(pathlib.Path(dirpath).relative_to(root)).replace("\\", "/")
    rel = "/" if rel == "/." else rel
    for ecosystem, matches in MANIFESTS:
        if any(matches(name) for name in filenames):
            required.add((ecosystem, rel))
if (root / ".github" / "workflows").is_dir():
    required.add(("github-actions", "/"))

missing = required - seen
if missing:
    raise SystemExit(f"FAIL: manifest-bearing surfaces with no grouped Dependabot entry: {sorted(missing)}")
stale = seen - required
if stale:
    raise SystemExit(f"FAIL: Dependabot entries with no manifest on disk (stale): {sorted(stale)}")
print(f"PASS: {len(required)} derived infra Dependabot update surfaces are grouped weekly")
PY
