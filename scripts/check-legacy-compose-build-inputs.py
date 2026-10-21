#!/usr/bin/env python3
"""Check build inputs of retained infra/docker variants without rendering env.

Scope is deliberately the legacy directory, not testnet overlays whose effective
project directories and overrides require a separate compose-chain inventory.
Contexts outside this checkout or requiring interpolation are EXTERNAL.
"""
import argparse
from pathlib import Path
import subprocess

import yaml


class ComposeLoader(yaml.SafeLoader):
    pass


def compose_tag(loader, node):
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    return loader.construct_scalar(node)


for tag in ("!reset", "!override"):
    ComposeLoader.add_constructor(tag, compose_tag)


def inside(path, root):
    return path.is_relative_to(root)


def inspect(root, files):
    rows = []
    for file in files:
        label = file.relative_to(root).as_posix()
        try:
            document = yaml.load(file.read_text(), Loader=ComposeLoader)
            if not isinstance(document, dict) or not isinstance(document.get("services"), dict):
                raise ValueError("services must be a mapping")
            for name, service in document["services"].items():
                if not isinstance(service, dict):
                    raise ValueError(f"{name}: service must be a mapping")
                if "build" not in service:
                    continue
                build = service["build"]
                if isinstance(build, str):
                    build = {"context": build}
                if not isinstance(build, dict):
                    raise ValueError(f"{name}: build must be a mapping or string")
                context = build.get("context", ".")
                dockerfile = build.get("dockerfile", "Dockerfile")
                if not isinstance(context, str) or not isinstance(dockerfile, str):
                    raise ValueError(f"{name}: context/dockerfile must be strings")
                prefix = f"{label}:{name}"
                # Never inspect sibling checkouts or expand environment values.
                if "$" in context or "://" in context or context.startswith("git@"):
                    rows.append(("EXTERNAL", prefix, "dynamic or remote context"))
                    continue
                base = (file.parent / context).resolve()
                if not inside(base, root):
                    rows.append(("EXTERNAL", prefix, "context outside checkout"))
                    continue
                if not base.is_dir():
                    rows.append(("MISSING", prefix, f"context {base.relative_to(root)}"))
                    continue
                if "dockerfile_inline" in build:
                    rows.append(("ERROR", prefix, "inline Dockerfile requires separate validation"))
                    continue
                if "$" in dockerfile:
                    rows.append(("EXTERNAL", prefix, "dynamic Dockerfile"))
                    continue
                target = (base / dockerfile).resolve()
                if not inside(target, root):
                    rows.append(("EXTERNAL", prefix, "Dockerfile outside checkout"))
                elif not target.is_file():
                    rows.append(("MISSING", prefix, f"Dockerfile {target.relative_to(root)}"))
                else:
                    rows.append(("LOCAL", prefix, f"Dockerfile {target.relative_to(root)}"))
        except (OSError, ValueError, yaml.YAMLError) as error:
            rows.append(("ERROR", label, str(error)))
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root.resolve()
    # Include new untracked variants too, so a local negative control needs no
    # index mutation. CI's clean checkout yields tracked files only.
    listing = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        capture_output=True, check=True,
    ).stdout.decode().split("\0")
    files = sorted({root / name for name in listing if name and
                    Path(name).parent == Path("infra/docker") and
                    "compose" in Path(name).name and Path(name).suffix in (".yml", ".yaml")})
    if not files:
        print("VOID: no active legacy Compose variants discovered")
        return 2
    rows = inspect(root, files)
    for status, label, detail in rows:
        print(f"{status}: {label}: {detail}")
    counts = {kind: sum(row[0] == kind for row in rows)
              for kind in ("LOCAL", "EXTERNAL", "MISSING", "ERROR")}
    print(f"files={len(files)} local={counts['LOCAL']} external={counts['EXTERNAL']} "
          f"missing={counts['MISSING']} errors={counts['ERROR']}")
    return int(bool(counts["MISSING"] or counts["ERROR"]))


if __name__ == "__main__":
    raise SystemExit(main())
