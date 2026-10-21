#!/usr/bin/env python3
"""Reject direct npm lifecycle installs and browser downloads on metered jobs.

Refs infra#1113. Complements the cache guard in infra#1142. Known hosted runner
labels are exempt; unknown/group/expression/matrix selectors are conservative.
Scope: direct commands in workflow run blocks. A helper invocation is allowed
only for the reviewed ci-node-install.sh boundary. Arbitrary action internals,
shell helpers and Dockerfiles need their own review; this is not a network meter.
"""
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
HOSTED = {
    "ubuntu-latest", "ubuntu-22.04", "ubuntu-24.04", "ubuntu-24.04-arm",
    "windows-latest", "windows-2022", "windows-2025",
    "macos-latest", "macos-14", "macos-15", "macos-15-intel",
}
INSTALL = re.compile(r"(?<![\w-])npm\b[^\n;&|)]*")
LIFECYCLE = re.compile(r"(?:^|\s)(?:ci|install|i|rebuild)(?:\s|$)")
BROWSER = re.compile(r"(?<![\w/-])(?:npx\s+)?(?:playwright|puppeteer|cypress)\s+(?:install|browsers\s+install)\b")


def findings(directory):
    failures = []
    paths = sorted(directory.glob("*.yml")) + sorted(directory.glob("*.yaml"))
    if not paths:
        return [f"{directory}: no workflow files"]
    for path in paths:
        try:
            doc = yaml.safe_load(path.read_text()) or {}
        except yaml.YAMLError:
            failures.append(f"{path.name}: invalid YAML")
            continue
        for name, job in doc.get("jobs", {}).items():
            labels = job.get("runs-on")
            labels = labels if isinstance(labels, list) else [labels]
            if labels and all(isinstance(label, str) and label in HOSTED for label in labels):
                continue
            for step in job.get("steps", []):
                run = step.get("run", "")
                # Comments are not commands; quoted data can cause conservative
                # findings and must be moved to fixtures, rather than exempting
                # a whole job containing a real install.
                run = "\n".join(line for line in run.splitlines() if not line.lstrip().startswith("#"))
                run = run.replace("\\\n", " ")
                if BROWSER.search(run):
                    failures.append(f"{path.name}/{name}: direct browser download")
                for command in INSTALL.findall(run):
                    if not LIFECYCLE.search(command):
                        continue
                    # Only the bare CLI flag guarantees suppression. A later
                    # --ignore-scripts=false would win, so assignments are refused.
                    if (not re.search(r"(?:^|\s)--ignore-scripts(?:\s|$)", command)
                            or "--ignore-scripts=" in command
                            or "--no-ignore-scripts" in command
                            or re.search(r"--ignore-scripts\s+false\b", command)):
                        failures.append(f"{path.name}/{name}: npm lifecycle scripts enabled")
    return failures


def main():
    failures = []
    for directory in [Path(arg) for arg in sys.argv[1:]] or [ROOT / ".github/workflows"]:
        failures.extend(findings(directory))
    for failure in failures:
        print(f"POSTINSTALL_BUDGET=FAIL {failure}", file=sys.stderr)
    if not failures:
        print("POSTINSTALL_BUDGET=PASS direct workflow commands")
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
