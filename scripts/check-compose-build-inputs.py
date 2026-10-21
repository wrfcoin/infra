#!/usr/bin/env python3
"""Static gate (infra#982): every tracked compose file's build inputs must exist.

For each service with `build:` in each git-tracked compose file, the resolved
`build.context` directory and `build.dockerfile` must exist, unless the compose
file is under an `attic/` directory or the (file, service) pair is declared in
scripts/tests/fixtures/compose-build-exceptions.json with a reason. An exception whose
service no longer offends is STALE and fails the gate.

Context is relative to the compose file's directory; dockerfile is relative to
the context. `${VAR:-default}` is resolved to its default; a variable with no
default makes the input UNRESOLVED, which is reported and fails the gate
(declare it as an exception instead). Remote contexts (URLs, git@) are skipped.

Usage: check-compose-build-inputs.py [--root DIR] [--files F ...]
Exit 0 clean; 1 on any offender, YAML parse failure, non-mapping YAML, stale exception or
zero compose files scanned, or an exception entry without a reason; 2 on argparse usage errors.
"""
import argparse, json, os, re, subprocess, sys
import yaml

VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::?-([^${}]*))?\}")
COMPOSE = re.compile(r"(^|/)(docker-)?compose[^/]*\.ya?ml$|monitoring-compose\.yml$")


class _Loader(yaml.SafeLoader):
    """Compose merge tags (!reset, !override) are not build-input relevant."""


def _any_tag(loader, suffix, node):
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    v = loader.construct_scalar(node)
    return yaml.safe_load(v) if v in ("null", "~", "") else v


_Loader.add_multi_constructor("!", _any_tag)


def resolve(s):
    # Reduce innermost defaults first. Every replacement removes a variable
    # wrapper, so iteration terminates without consulting the runner's env.
    while True:
        expanded = VAR.sub(lambda m: m.group(2) if m.group(2) is not None else m.group(0), s)
        if expanded == s:
            return s, [m.group(1) for m in VAR.finditer(s) if m.group(2) is None]
        s = expanded


def tracked_compose(root):
    out = subprocess.run(["git", "-C", root, "ls-files"], capture_output=True, text=True, check=True).stdout
    return sorted(f for f in out.splitlines() if COMPOSE.search(f))


def load_exceptions(root):
    """Returns (valid {(file, service)}, invalid [message]). An entry without a non-blank
    file, service and reason is INVALID and fails the gate; it never silently covers
    (or fails to cover) anything."""
    p = os.path.join(root, "scripts/tests/fixtures/compose-build-exceptions.json")
    if not os.path.exists(p):
        return set(), []
    try:
        with open(p) as f:
            entries = json.load(f)["exceptions"]
        if not isinstance(entries, list):
            raise ValueError("`exceptions` is not a list")
    except Exception as e:
        return set(), [f"exceptions file unreadable: {type(e).__name__}"]
    valid, invalid = set(), []
    for i, e in enumerate(entries):
        fields = [e.get(k) if isinstance(e, dict) else None for k in ("file", "service", "reason")]
        missing = [k for k, v in zip(("file", "service", "reason"), fields) if not (isinstance(v, str) and v.strip())]
        if missing:
            invalid.append(f"entry #{i} is missing {', '.join(missing)}")
        else:
            valid.add((fields[0], fields[1]))
    return valid, invalid


def check(root, files, external=None):
    """external, if given, collects (file, service, context) for contexts that
    resolve outside the repo (workspace-sibling checkouts); they are not
    verifiable from a single-repo CI checkout and are reported, not failed."""
    bad = []
    real_root = os.path.realpath(root)
    for rel in files:
        if "/attic/" in "/" + rel:
            continue
        path = os.path.join(root, rel)
        try:
            with open(path) as fh:
                doc = yaml.load(fh, Loader=_Loader)
        except Exception as e:
            bad.append((rel, "-", f"YAML parse error: {str(e).splitlines()[0] if str(e) else type(e).__name__}"))
            continue
        if doc is None:
            doc = {}
        if not isinstance(doc, dict):
            bad.append((rel, "-", f"top-level YAML is a {type(doc).__name__}, not a mapping"))
            continue
        if not isinstance(doc.get("services") or {}, dict):
            bad.append((rel, "-", "`services` is not a mapping"))
            continue
        base = os.path.dirname(path)
        for name, svc in (doc.get("services") or {}).items():
            b = (svc or {}).get("build")
            if b is None:
                continue
            if isinstance(b, str):
                b = {"context": b}
            ctx_raw = str(b.get("context", "."))
            if re.match(r"^(https?://|git@|git://|github\.com/)", ctx_raw):
                continue
            ctx_r, u1 = resolve(ctx_raw)
            if u1:
                bad.append((rel, name, f"UNRESOLVED context variable(s) {u1}: {ctx_raw}"))
                continue
            ctx = os.path.normpath(os.path.join(base, ctx_r))
            if os.path.commonpath([real_root, os.path.realpath(ctx)]) != real_root:
                if external is not None:
                    external.append((rel, name, ctx_raw))
                continue
            if not os.path.isdir(ctx):
                bad.append((rel, name, f"build.context missing: {ctx_raw} -> {os.path.relpath(ctx, root)}"))
                continue
            if "dockerfile_inline" in b:
                continue
            df_raw = str(b.get("dockerfile", "Dockerfile"))
            df_r, u2 = resolve(df_raw)
            if u2:
                bad.append((rel, name, f"UNRESOLVED dockerfile variable(s) {u2}: {df_raw}"))
                continue
            df = os.path.normpath(os.path.join(ctx, df_r))
            if not os.path.isfile(df):
                bad.append((rel, name, f"build.dockerfile missing: {df_raw} -> {os.path.relpath(df, root)}"))
    return bad


def apply_exceptions(bad, exceptions, files):
    """Split raw offenders into (remaining, stale). An exception is STALE when its
    file was scanned (or no longer exists in the scanned set's tracked list) and the
    service no longer offends, so a fixed service forces its entry to be deleted."""
    offending = {(f, svc) for f, svc, _ in bad}
    remaining = [b for b in bad if (b[0], b[1]) not in exceptions]
    scanned = set(files)
    stale = sorted(e for e in exceptions if e not in offending and e[0] in scanned)
    return remaining, stale


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.normpath(os.path.join(os.path.dirname(__file__), "..")))
    ap.add_argument("--files", nargs="*")
    a = ap.parse_args()
    files = a.files if a.files is not None else tracked_compose(a.root)
    if not files:
        print("compose build-input gate: FAIL, zero compose files found to scan (a gate that scans nothing proves nothing)")
        return 1
    exceptions, invalid = load_exceptions(a.root)
    ext = []
    bad, stale = apply_exceptions(check(a.root, files, ext), exceptions, files)
    if a.files is None:  # full scan: an exception for a file that is no longer tracked is also stale
        stale = sorted(set(stale) | {e for e in exceptions if e[0] not in set(files)})
    print(f"compose build-input gate: scanned {len(files)} compose file(s), {len(bad)} offender(s), {len(stale)} stale exception(s), {len(invalid)} invalid exception(s), {len(ext)} external-context service(s) skipped")
    for rel, svc, c in ext:
        print(f"  external {rel} [{svc}]: context {c} is outside this repo")
    for rel, svc, why in bad:
        print(f"  OFFENDER {rel} [{svc}]: {why}")
    for rel, svc in stale:
        print(f"  STALE exception {rel} [{svc}]: no longer an offender (or file gone); delete it from compose-build-exceptions.json")
    for msg in invalid:
        print(f"  INVALID exception: {msg}; every entry needs file, service and a non-empty reason")
    return 1 if (bad or stale or invalid) else 0


if __name__ == "__main__":
    sys.exit(main())
