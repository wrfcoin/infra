#!/usr/bin/env python3
"""Record and check local canonical cut-overlay custody; no host access."""
import argparse
import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WRITER = "testnet/scripts/render-cut-overlay.sh"


def read_regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("custody input must be a regular file, without a symlink")
    return path.read_bytes()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate custody record field")
        result[key] = value
    return result


def custody(pins, overlay, expected, check):
    overlay_bytes = read_regular(overlay)
    if overlay_bytes != read_regular(expected):
        raise ValueError("overlay bytes differ from the canonical pinned wrfcoin-node render")
    record = {
        "schema": 1,
        "writer": WRITER,
        "writer_sha256": sha256(read_regular(ROOT / WRITER)),
        "checker_sha256": sha256(read_regular(Path(__file__))),
        "pins_sha256": sha256(read_regular(pins)),
        "overlay_sha256": sha256(overlay_bytes),
    }
    target = Path(str(overlay) + ".custody.json")
    if check:
        if target.is_symlink() or not target.is_file() or target.stat().st_size > 4096:
            raise ValueError("custody record missing, indirect, or oversized; owner must render the pair")
        observed = json.loads(read_regular(target), object_pairs_hook=unique_object)
        if (not isinstance(observed, dict) or type(observed.get("schema")) is not int
                or observed != record):
            raise ValueError("custody record differs from writer, checker, pins or overlay checksums")
        return
    if target.is_symlink() or (target.exists() and not target.is_file()):
        raise ValueError("custody record destination must be a regular file")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=target.parent,
                                         prefix=".cut-custody-", delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(record, stream, sort_keys=True, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pins", type=Path, required=True)
    parser.add_argument("--overlay", type=Path, required=True)
    parser.add_argument("--expected", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        custody(args.pins, args.overlay, args.expected, args.check)
    except (OSError, ValueError) as error:
        print(f"CUT_OVERLAY=FAIL {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
