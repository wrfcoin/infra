#!/usr/bin/env python3
"""Post-cut gate: block 1 must carry the intended activation schedule (infra#1018).

The 2026-09-13 cut never stamped its activation schedule: block 1 had no
`protocol_activation_schedule` and `protocol_version: v1`, and nothing in the cut
runbook checked for it. A genesis cut FAILS unless all of these hold:

  0. the response is block 1 itself: an envelope says ok:true and the block has the
     numeric height 1 (a later block with matching metadata must not pass);
  1. block 1's metadata has `protocol_activation_schedule` EQUAL to --expected-schedule;
  2. block 1's metadata has `protocol_version` EQUAL to --expected-version
     (default v1 for chain 888, otherwise legacy v2; --chain-id or exported
     WRFCOIN_CHAIN_ID overrides the block metadata's chain_id);
  3. for every --node-log FILE, the LAST `Signing protocol <v> active` line says
     the expected version (and at least one such line exists).

Block 1 comes from `GET /chain/block/1` saved to a file (--block-json) or fetched
(--url BASE; a reader bearer is read from $WRFCOIN_READER_TOKEN and sent as a
header, never on argv). The response envelope `{"ok":true,"data":{"metadata":{..}}}`
and a bare `{"metadata":{..}}` are both accepted. Nothing is printed of the
schedule beyond OK/FAIL reasons naming which check failed.

Exit 0 = every check passed; 1 = a check failed; 2 = bad usage/input.
"""
import argparse
import json
import os
import re
import sys
import urllib.request

ACTIVE = re.compile(r"Signing protocol (v[0-9]+) active")


def load_block(args):
    if args.block_json:
        with open(args.block_json, encoding="utf-8") as handle:
            return json.load(handle)
    url = args.url.rstrip("/") + "/chain/block/1"
    request = urllib.request.Request(url)
    token = os.environ.get("WRFCOIN_READER_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=15) as response:  # noqa: S310 (operator-supplied URL)
        return json.load(response)


def block_body(block):
    """(body, problems): the block object out of an envelope or a bare block.
    An envelope (any dict with a `data` key) must say ok:true; the block must
    carry the numeric height 1 (not a bool, string or another height), so a later
    block's matching metadata can never satisfy the genesis-block gate."""
    problems = []
    body = block
    if isinstance(block, dict) and "data" in block:
        if block.get("ok") is not True:
            problems.append("block 1 response is an envelope without ok:true")
        body = block["data"]
    if not isinstance(body, dict):
        return None, problems + ["block 1 response has no block object"]
    height = body.get("height")
    if isinstance(height, bool) or not isinstance(height, int):
        problems.append("block has no numeric height (this gate needs height exactly 1)")
    elif height != 1:
        problems.append(f"block height is {height}, not 1")
    return body, problems


def metadata_of(body):
    metadata = body.get("metadata") if isinstance(body, dict) else None
    return metadata if isinstance(metadata, dict) else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--block-json")
    source.add_argument("--url")
    parser.add_argument("--expected-schedule", required=True)
    parser.add_argument("--chain-id", default=os.environ.get('WRFCOIN_CHAIN_ID'), choices=['777', '888'])
    parser.add_argument("--expected-version", help='default: v1 at chain 888, v2 at chain 777')
    parser.add_argument("--node-log", action="append", default=[], required=True)
    args = parser.parse_args()
    if not args.expected_schedule.strip():
        print("CUT_BLOCK1=FAIL --expected-schedule is empty", file=sys.stderr)
        return 2
    try:
        block = load_block(args)
    except (OSError, ValueError) as error:
        print(f"CUT_BLOCK1=FAIL cannot read block 1: {error.__class__.__name__}", file=sys.stderr)
        return 2

    failures = []
    body, problems = block_body(block)
    failures.extend(problems)
    metadata = metadata_of(body)
    if metadata is None:
        failures.append("block 1 has no metadata object")
        metadata = {}
    if args.expected_version is None:
        chain = args.chain_id or str(metadata.get('chain_id', '777'))
        args.expected_version = 'v1' if chain == '888' else 'v2'
    schedule = metadata.get("protocol_activation_schedule")
    if schedule is None:
        failures.append("block 1 metadata lacks protocol_activation_schedule (the 09-13 cut failure)")
    elif schedule != args.expected_schedule:
        failures.append("block 1 protocol_activation_schedule differs from the intended schedule")
    version = metadata.get("protocol_version")
    if version != args.expected_version:
        failures.append(f"block 1 protocol_version is {version!r}, expected {args.expected_version!r}")
    for path in args.node_log:
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                seen = ACTIVE.findall(handle.read())
        except OSError as error:
            failures.append(f"cannot read node log {path}: {error.__class__.__name__}")
            continue
        if not seen:
            failures.append(f"{path}: no 'Signing protocol <v> active' line")
        elif seen[-1] != args.expected_version:
            failures.append(f"{path}: last 'Signing protocol' line says {seen[-1]}, expected {args.expected_version}")

    if failures:
        print("CUT_BLOCK1=FAIL", file=sys.stderr)
        for item in failures:
            print(f"- {item}", file=sys.stderr)
        return 1
    print(f"CUT_BLOCK1=PASS version={args.expected_version} node_logs={len(args.node_log)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
