#!/usr/bin/env python3
"""Ratchet: no GitHub cache restore on a self-hosted job (infra#1113).

CT102's runners sit behind a metered home link (1.2 TB/month; the cap was used up
on 2026-09-27, ~100 GB/day of it GitHub cache restores). ~/.npm, CARGO_HOME,
RUSTUP_HOME, CARGO_TARGET_DIR and the tool cache already persist on the runner
host, so a GitHub cache restore re-downloads bytes that are already on local disk.
Byte budget: a self-hosted job should download no cache payload at all; the
measured cost of one npm cache restore was ~532 MB per job.

A job counts as possibly self-hosted unless every label of its `runs-on` is a known
GitHub-hosted image name from an explicit list (HOSTED_LABEL: ubuntu-latest, ubuntu-24.04, windows-2022, macos-14, ...; not a prefix match), after expanding literal
`strategy.matrix` values and include entries behind `runs-on: ${{ matrix.X }}`.
Anything else fails closed: `self-hosted`, any custom label, a `group:` selector (even
with labels: GitHub routes by group AND labels, and a runner can lack the default
`self-hosted` label), and runner expressions that cannot be resolved to literals. It
fails this check when any step of such a job:
  - uses actions/cache (or actions/cache/restore);
  - passes `cache:` to a setup-node/python/go/java/ruby/dotnet/... action;
  - uses Swatinem/rust-cache (save-if:false still restores), Ruby bundler-cache,
    Flutter SDK/pub-cache, Trivy cache or setup-buildx's binary cache;
  - passes buildx `cache-from`/`cache-to` with ANY entry that is not `type=local`
    or `type=inline` (each entry is judged on its own; a registry reference or an
    expression counts as remote). Prints a per-workflow count of cache
steps (hosted vs self-hosted) and exits 1 on any self-hosted one.

Usage: check-selfhosted-cache.py [WORKFLOW_DIR ...]   (default .github/workflows)
"""
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


MATRIX_REF = re.compile(r"^\s*\$\{\{\s*matrix\.([A-Za-z0-9_-]+)\s*\}\}\s*$")


def _matrix_values(job, key):
    """Literal values the matrix key can take (each a label string or a list of labels),
    or None when they cannot be resolved to literals."""
    matrix = (job.get("strategy") or {}).get("matrix")
    if not isinstance(matrix, dict):
        return None
    values = []
    if key in matrix:
        raw = matrix[key]
        if not isinstance(raw, list):
            return None  # e.g. an expression string
        values.extend(raw)
    for entry in matrix.get("include") or []:
        if isinstance(entry, dict) and key in entry:
            values.append(entry[key])
    if not values:
        return None
    for value in values:
        items = value if isinstance(value, list) else [value]
        if any((not isinstance(item, str)) or "${{" in item for item in items):
            return None
    return values


# GitHub-hosted runner image labels, an explicit maintained list (not a prefix match:
# `ubuntu-ct102` would satisfy a prefix and can be a custom label on a self-hosted
# runner). Anything not listed, including custom-named larger runners, is treated as
# possibly self-hosted. Extend this list when GitHub adds an image.
HOSTED_LABEL = re.compile(
    r"^(?:"
    r"ubuntu-(?:latest|slim|20\.04|22\.04|24\.04|22\.04-arm|24\.04-arm)"
    r"|windows-(?:latest|2019|2022|2025|11-arm)"
    r"|macos-(?:latest|12|13|14|15|26)(?:-(?:large|xlarge|intel))?"
    r")$"
)


def runner_may_be_self_hosted(job):
    """(may_be_self_hosted, reason). Only a runner proven to be a GitHub-hosted image is
    hosted. Fail closed on: a `group:` selector (even with labels), any label that is
    not a known hosted image name, unresolved expressions, and matrix values behind
    `${{ matrix.X }}` that are any of those."""
    runs_on = job.get("runs-on")
    if isinstance(runs_on, dict):
        return True, "runs-on group selector (a runner group is not proof of a hosted runner)"
    elements = runs_on if isinstance(runs_on, list) else [runs_on]

    def label_problem(label):
        if not isinstance(label, str) or "${{" in label:
            return "runs-on is not a literal label"
        if "self-hosted" in label:
            return "self-hosted"
        if not HOSTED_LABEL.match(label):
            return f"runner label '{label}' is not a known GitHub-hosted image (may route to a self-hosted runner)"
        return None

    for element in elements:
        if isinstance(element, str) and "${{" in element:
            match = MATRIX_REF.match(element)
            values = _matrix_values(job, match.group(1)) if match else None
            if values is None:
                return True, f"runs-on expression '{element.strip()}' cannot be resolved to literal labels"
            for value in values:
                items = value if isinstance(value, list) else [value]
                for item in items:
                    problem = label_problem(item)
                    if problem:
                        return True, "a matrix runner value: " + problem
        else:
            problem = label_problem(element)
            if problem:
                return True, problem
    return False, ""


def cache_input_enabled(inputs, key, default=False):
    """Only a literal false proves disabled. Empty inputs use action defaults;
    unresolved expressions/other values remain possibly enabled."""
    value = inputs.get(key)
    if value is None or value == "":
        return default
    return value is not False and str(value).strip() != "false"


def cache_reason(step: dict):
    # Admit only the exact runtime predicate; an arbitrary expression containing
    # this text (e.g. "|| true") can still restore on a self-hosted runner.
    guard = str(step.get("if", "")).strip()
    if guard.startswith("${{") and guard.endswith("}}"):
        guard = guard[3:-2].strip()
    if re.fullmatch(r"runner\.environment\s*!=\s*(['\"])self-hosted\1", guard):
        return None
    uses = str(step.get("uses", ""))
    with_ = step.get("with") or {}
    action = uses.split("@")[0].lower()
    if action == "swatinem/rust-cache":
        # save-if controls upload, cache-targets:false still caches Cargo.
        # Keep lookup-only/provider overrides conservative as for actions/cache.
        return "Swatinem/rust-cache (restore enabled by default)"
    if action == "ruby/setup-ruby" and cache_input_enabled(with_, "bundler-cache"):
        return "ruby/setup-ruby bundler-cache"
    if action == "subosito/flutter-action":
        sdk = cache_input_enabled(with_, "cache")
        if sdk or cache_input_enabled(with_, "pub-cache", default=sdk):
            return "subosito/flutter-action SDK/pub cache"
    if action == "aquasecurity/trivy-action" and cache_input_enabled(with_, "cache", default=True):
        return "aquasecurity/trivy-action cache (default true)"
    if action == "docker/setup-buildx-action" and cache_input_enabled(with_, "cache-binary", default=True):
        return "docker/setup-buildx-action binary cache (default true)"
    if uses.startswith("actions/cache"):
        return "actions/cache"
    if uses.startswith("actions/setup-") and with_.get("cache"):
        cache = str(with_["cache"]).strip()
        # setup-node documents empty cache as disabled. Recognize only its
        # exact npm/empty expression; other setup actions have other semantics.
        guarded_node = uses.startswith("actions/setup-node@") and re.fullmatch(
            r"\$\{\{\s*runner\.environment\s*!=\s*(['\"])self-hosted\1\s*"
            r"&&\s*(['\"])npm\2\s*\|\|\s*(['\"])\3\s*\}\}", cache)
        if not guarded_node:
            return f"{uses.split('@')[0]} cache: {with_['cache']}"
    for key in ("cache-from", "cache-to"):
        value = str(with_.get(key, ""))
        if not value.strip():
            continue
        # Every entry is judged on its own: one `type=local` must not exempt a
        # `type=gha` or registry entry next to it. Only local/inline are allowed;
        # an entry with no `type=` is a registry reference; an expression is unverifiable.
        for line in value.splitlines():
            line = line.strip()
            if not line:
                continue
            types = re.findall(r"type=([A-Za-z0-9_-]+)", line)
            if "${{" in line or not types or any(t not in {"local", "inline"} for t in types):
                return f"{key}: {line}"
    return None


def scan(directory: Path):
    findings, counts = [], {}
    for path in sorted(directory.glob("*.y*ml")):
        try:
            doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError as error:
            findings.append(f"{path.name}: unparseable ({error.__class__.__name__})")
            continue
        hosted = selfhosted = 0
        for job_name, job in (doc.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            sh, why = runner_may_be_self_hosted(job)
            for step in job.get("steps") or []:
                reason = cache_reason(step) if isinstance(step, dict) else None
                if reason is None:
                    continue
                if sh:
                    selfhosted += 1
                    findings.append(f"{path.name}: job '{job_name}' ({why}) restores a GitHub cache: {reason}")
                else:
                    hosted += 1
        counts[path.name] = (hosted, selfhosted)
    return findings, counts


def main() -> int:
    dirs = [Path(arg) for arg in sys.argv[1:]] or [ROOT / ".github/workflows"]
    findings, counts = [], {}
    for directory in dirs:
        f, c = scan(directory)
        findings += f
        counts.update(c)
    print("workflow cache steps (hosted / self-hosted):")
    for name, (hosted, selfhosted) in counts.items():
        if hosted or selfhosted:
            print(f"  {name}: {hosted} / {selfhosted}")
    if findings:
        print("selfhosted-cache ratchet: FAIL", file=sys.stderr)
        for item in findings:
            print(f"- {item}", file=sys.stderr)
        return 1
    print(f"selfhosted-cache ratchet: PASS ({sum(c[0] for c in counts.values())} hosted cache steps, 0 self-hosted)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
