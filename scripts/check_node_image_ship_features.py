#!/usr/bin/env python3
"""Refuse a node-image build file that names a ship-forbidden core4 feature (infra#1034).

core4#3229 added the test-only `panic-drill` cargo feature: a `launch_api` built with it
panics its inbound P2P consumer when a trigger file appears. core4's
`scripts/check_release_endpoints.py --profile-file` refuses a build file whose
`--features` list names it -- but only when the name is written on that line. This
passes it:

    ARG FEATURES="full-mining,p2p,hsm,panic-drill"
    RUN cargo build --release --features "${FEATURES}"

because the `--features` line carries `${FEATURES}`, not the feature name. This guard
closes that hole for infra's own files with a blunter rule: a ship-forbidden feature
name may not appear as a token on ANY non-comment line of the files it is given
(Dockerfile ARG/ENV defaults, `--features` lists, compose `build.args`, ...). It is a
cheap pre-build check. It is not the proof: a value supplied from outside these files
(e.g. `docker build --build-arg FEATURES=...` typed by hand) is invisible to any file
scan. The proof is `check_release_endpoints.py --binary` on the `launch_api` taken out
of the built image, which the Node Image Ship-Feature Guard workflow runs on CT102.

The forbidden names default to core4's list at the time of writing. `--checker PATH`
loads core4's checker and adds its `SHIP_FORBIDDEN_FEATURES`, so a feature core4 adds
later is picked up without editing this file. The list can only grow, never shrink.

    python3 scripts/check_node_image_ship_features.py infra/docker/Dockerfile.core
    python3 scripts/check_node_image_ship_features.py --checker core4/scripts/check_release_endpoints.py FILE...

Exit 0: no forbidden name in any file. Exit 1: a finding, or a file that could not be read.
"""

from __future__ import annotations

import argparse
import importlib.util
import re
import sys
from pathlib import Path

# core4 scripts/check_release_endpoints.py SHIP_FORBIDDEN_FEATURES at 24237c2d6 (#3229).
DEFAULT_FORBIDDEN = ("dev-endpoints", "panic-drill")


def forbidden_features(checker: Path | None) -> tuple[str, ...]:
    names = list(DEFAULT_FORBIDDEN)
    if checker is not None:
        spec = importlib.util.spec_from_file_location("core4_check_release_endpoints", checker)
        if spec is None or spec.loader is None:
            raise ValueError(f"{checker}: cannot load as a Python module")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        loaded = getattr(module, "SHIP_FORBIDDEN_FEATURES", None)
        if not loaded:
            raise ValueError(f"{checker}: has no SHIP_FORBIDDEN_FEATURES; refusing to guess the list")
        names.extend(name for name in loaded if name not in names)
    return tuple(names)


def scan(path: Path, features: tuple[str, ...]) -> list[str]:
    findings: list[str] = []
    patterns = {
        feature: re.compile(rf"(?<![\w-]){re.escape(feature)}(?![\w-])") for feature in features
    }
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        # A whole-line comment is prose, not configuration. A trailing `# ...` is NOT
        # stripped: in a Dockerfile it is part of the instruction, not a comment.
        if line.lstrip().startswith("#"):
            continue
        for feature, pattern in patterns.items():
            if pattern.search(line):
                findings.append(
                    f"{path}:{number}: names ship-forbidden core4 feature `{feature}`: {line.strip()}"
                )
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("files", nargs="+", type=Path, help="build files to scan")
    parser.add_argument(
        "--checker",
        type=Path,
        help="core4 scripts/check_release_endpoints.py; its SHIP_FORBIDDEN_FEATURES are added",
    )
    args = parser.parse_args(argv)
    try:
        features = forbidden_features(args.checker)
    except (OSError, ValueError, SyntaxError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    errors: list[str] = []
    for file in args.files:
        if not file.is_file():
            errors.append(f"{file}: does not exist (a missing file cannot be certified)")
            continue
        errors.extend(scan(file, features))
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    if errors:
        return 1
    print(
        f"check_node_image_ship_features OK: {len(args.files)} file(s) name none of "
        f"{', '.join(features)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
