#!/usr/bin/env python3
"""Print the Docker volume (or bind-mount host path) mounted at a container dir.

Used by testnet/backup.sh to find the chain-data volume (infra#1115).

    resolve-node-volume.py mounts  DATA_DIR  < `docker inspect --format '{{json .Mounts}}' C`
    resolve-node-volume.py compose SERVICE DATA_DIR < `docker compose config --format json`

`mounts` reads the running container, which carries the real, project-prefixed
volume name. `compose` is the fallback when the container is not running. It
accepts both service-volume shapes: the object form current Compose emits
({"type","source","target"}) and the legacy "src:dst[:mode]" string. A named
volume is mapped through the top-level `volumes` block, where Compose has
already resolved the real name (e.g. node-data -> testnet_node-data).

Exits nonzero with a reason on stderr when nothing is mounted at DATA_DIR.
"""
import json
import sys


def die(msg):
    print(f"resolve-node-volume: {msg}", file=sys.stderr)
    sys.exit(1)


def from_mounts(data_dir):
    mounts = json.load(sys.stdin) or []
    for m in mounts:
        if m.get("Destination") != data_dir:
            continue
        if m.get("Type") == "volume" and m.get("Name"):
            return m["Name"]
        if m.get("Type") == "bind" and m.get("Source"):
            return m["Source"]
        die(f"unsupported mount type {m.get('Type')!r} at {data_dir}")
    die(f"running container has no mount at {data_dir}")


def from_compose(service, data_dir):
    cfg = json.load(sys.stdin)
    try:
        entries = cfg["services"][service].get("volumes") or []
    except KeyError:
        die(f"service {service!r} not in compose config")
    top = cfg.get("volumes") or {}
    for v in entries:
        if isinstance(v, dict):
            kind, source, target = v.get("type", "volume"), v.get("source"), v.get("target")
        elif isinstance(v, str):
            parts = v.split(":")
            if len(parts) < 2:
                continue  # anonymous volume: nothing to name
            source, target = parts[0], parts[1]
            kind = "bind" if source.startswith(("/", ".", "~")) else "volume"
        else:
            die(f"unrecognised volume entry: {v!r}")
        if target != data_dir or not source:
            continue
        if kind == "volume":
            return (top.get(source) or {}).get("name") or source
        if kind == "bind":
            return source
        die(f"unsupported volume type {kind!r} at {data_dir}")
    die(f"service {service!r} has no volume at {data_dir}")


def main(argv):
    if len(argv) == 3 and argv[1] == "mounts":
        print(from_mounts(argv[2]))
    elif len(argv) == 4 and argv[1] == "compose":
        print(from_compose(argv[2], argv[3]))
    else:
        die("usage: mounts DATA_DIR | compose SERVICE DATA_DIR")


if __name__ == "__main__":
    main(sys.argv)
