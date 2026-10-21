#!/usr/bin/env python3
"""Stage pinned public source and existing crates.io cache; never fetch dependencies."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tomllib

REVISION = "b71a90b1322d83b8368ebc9fe2376768e2d4e7ac"
ROOT = Path(__file__).resolve().parents[1]


def index_key(name):
    name = name.lower()
    if len(name) < 3:
        return f"{len(name)}/{name}"
    if len(name) == 3:
        return f"3/{name[0]}/{name}"
    return f"{name[:2]}/{name[2:4]}/{name}"


def stage(source, registry, output, revision=REVISION):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("revision must be a full immutable commit")
    actual = subprocess.check_output(["git", "-C", str(source), "rev-parse", f"{revision}^{{commit}}"], text=True).strip()
    if actual != revision:
        raise ValueError("source revision mismatch")
    if output.exists():
        raise ValueError("output already exists; use a fresh staging directory")
    files = subprocess.check_output(["git", "-C", str(source), "ls-tree", "-r", "--name-only", revision], text=True).splitlines()
    selected = [name for name in files if name in {"Cargo.toml", "Cargo.lock", "crates/defi-node/fixtures/pools.toml"}
                or re.fullmatch(r"crates/[a-z-]+/Cargo.toml", name)
                or re.fullmatch(r"crates/[a-z-]+/src/(?:[a-zA-Z0-9_/-]+/)*[a-zA-Z0-9_-]+\.rs", name)]
    output.mkdir(parents=True)
    source_out = output / "source"
    for name in selected:
        destination = source_out / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(subprocess.check_output(["git", "-C", str(source), "show", f"{revision}:{name}"]))
    (source_out / ".revision").write_text(revision + "\n")
    packages = tomllib.loads((source_out / "Cargo.lock").read_text())["package"]
    indexes = list((registry / "index").glob("index.crates.io-*"))
    if len(indexes) != 1:
        raise ValueError("one existing public crates.io sparse index is required")
    index = indexes[0]
    index_out = output / "registry/index" / index.name
    index_out.mkdir(parents=True)
    shutil.copyfile(index / "config.json", index_out / "config.json")
    missing = []
    for package in packages:
        source_kind = package.get("source")
        if source_kind is None:
            continue
        if source_kind != "registry+https://github.com/rust-lang/crates.io-index":
            raise ValueError("only public crates.io dependencies may be staged")
        name, version = package["name"], package["version"]
        metadata = index / ".cache" / index_key(name)
        if not metadata.is_file():
            raise ValueError(f"cached index metadata absent for {name}; no network fallback")
        destination = index_out / ".cache" / index_key(name)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(metadata, destination)
        archive = registry / "cache" / index.name / f"{name}-{version}.crate"
        if not archive.is_file():
            missing.append(f"{name}-{version}")
            continue  # optional/dev targets may not use it; the offline build must prove this
        if hashlib.sha256(archive.read_bytes()).hexdigest() != package["checksum"]:
            raise ValueError(f"cached archive checksum mismatch: {name}-{version}")
        destination = output / "registry/cache" / index.name / archive.name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(archive, destination)
    staged = [p for p in output.rglob("*") if p.is_file()]
    manifest = {"revision": revision, "source_files": len(selected), "bytes": sum(p.stat().st_size for p in staged),
                "missing_archives": missing, "sha256": {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest() for p in staged}}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT.parent / "defi-protocols")
    parser.add_argument("--registry", type=Path, default=Path.home() / ".cargo/registry")
    parser.add_argument("--output", type=Path, default=ROOT / "testnet/services/defi/.cache")
    args = parser.parse_args()
    try:
        manifest = stage(args.source, args.registry, args.output)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"STOP: {error}\n")
    print(f"PASS: staged {manifest['source_files']} pinned source files, {manifest['bytes']} local bytes; "
          f"{len(manifest['missing_archives'])} archives absent; offline image build is still required")


if __name__ == "__main__":
    main()
