#!/usr/bin/env python3
"""Read-only source preflight; never a substitute for an activation-crossing replay.

Consumes an operator-captured complete /network/upgrade response in an envelope:
{captured_at: UTC ISO8601, chain_id: "888", network_id: "testnet", upgrade: {...}}.
No API credentials, network requests, checkout changes or live writes.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import sys

SHA = re.compile(r"[0-9a-f]{40}")
FEATURE = re.compile(r"[a-z0-9_]{1,64}")
REGISTRY = "shared-protocol/src/crypto/protocol_support.rs"


def integer(value):
    return type(value) is int and 0 <= value <= 2**53 - 1


def schedule_features(document, now, max_age_hours):
    if document.get("chain_id") != "888" or document.get("network_id") != "testnet":
        raise ValueError("schedule identity must be chain 888/testnet")
    try:
        captured = datetime.fromisoformat(document["captured_at"].replace("Z", "+00:00"))
        age = (now - captured).total_seconds()
    except (KeyError, TypeError, AttributeError, ValueError):
        raise ValueError("schedule capture time must have a timezone") from None
    if not 0 <= age <= max_age_hours * 3600:
        raise ValueError("schedule capture is stale or in the future; capture it again")
    upgrade = document.get("upgrade")
    if not isinstance(upgrade, dict) or not integer(upgrade.get("tip_height")):
        raise ValueError("schedule has no valid tip height")
    scheduled = upgrade.get("scheduled")
    if not isinstance(scheduled, dict) or scheduled.get("truncated") is not False or scheduled.get("base_provisional") is not False:
        raise ValueError("schedule must be complete and non-provisional")
    entries = scheduled.get("entries")
    if not isinstance(entries, list) or not entries or len(entries) > 256 or scheduled.get("total_entries") != len(entries):
        raise ValueError("schedule entries are empty, oversized or incomplete")
    features = set()
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("feature"), str) or not FEATURE.fullmatch(entry["feature"]) or not integer(entry.get("activation_height")):
            raise ValueError("invalid scheduled feature or activation height")
        if entry["feature"] in features:
            raise ValueError("duplicate scheduled feature")
        features.add(entry["feature"])
    return features


def known_features(source):
    # Only the actual literal registry, never comments or tests that happen to name a feature.
    source = re.sub(r"/\*.*?\*/|//[^\n]*", "", source, flags=re.S)
    match = re.search(r"pub\s+const\s+KNOWN_FEATURES\s*:\s*&\s*\[\s*&str\s*\]\s*=\s*&\s*\[(.*?)\]\s*;", source, re.S)
    if not match:
        raise ValueError("literal KNOWN_FEATURES registry not found; review source format")
    body = match[1]
    values = re.findall(r'"([a-z0-9_]{1,64})"', body)
    if not values or re.sub(r'"[a-z0-9_]{1,64}"|[\s,]', '', body) or len(values) != len(set(values)):
        raise ValueError("unsupported or duplicate KNOWN_FEATURES registry")
    return set(values)


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True, stderr=subprocess.DEVNULL, timeout=30).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core4-repo', type=Path, required=True)
    parser.add_argument('--schedule', type=Path, required=True)
    parser.add_argument('--pins', type=Path, default=Path(__file__).resolve().parents[1] / 'testnet/cut-pins.env')
    parser.add_argument('--candidate', help='Full commit for a Windows or other release; otherwise uses join pin')
    parser.add_argument('--downloads-manifest', type=Path)
    parser.add_argument('--required-commit', action='append', default=[], help='Reviewed hardening commit that must be an ancestor; repeat as needed')
    parser.add_argument('--max-age-hours', type=int, default=24)
    args = parser.parse_args()
    try:
        if not 1 <= args.max_age_hours <= 24:
            raise ValueError('capture age limit must be 1..24 hours')
        if args.candidate:
            candidate = args.candidate
        else:
            matches = re.findall(r'^WRFCOIN_CUT_CORE4_COMMIT=([0-9a-f]{40})$', args.pins.read_text(), re.M)
            if len(matches) != 1:
                raise ValueError('pins must contain exactly one full core4 commit')
            candidate = matches[0]
        if not SHA.fullmatch(candidate):
            raise ValueError('candidate must be a full commit, not a branch or tag')
        if git(args.core4_repo, 'rev-parse', candidate + '^{commit}') != candidate:
            raise ValueError('candidate does not resolve exactly')
        wanted = schedule_features(json.loads(args.schedule.read_text()), datetime.now(timezone.utc), args.max_age_hours)
        known = known_features(git(args.core4_repo, 'show', candidate + ':' + REGISTRY))
        missing = sorted(wanted - known)
        if missing:
            raise ValueError('candidate lacks scheduled features: ' + ', '.join(missing))
        for required in args.required_commit:
            if not SHA.fullmatch(required):
                raise ValueError('required hardening commit must be a full commit')
            git(args.core4_repo, 'merge-base', '--is-ancestor', required, candidate)
        if args.downloads_manifest:
            artifacts = json.loads(args.downloads_manifest.read_text()).get('artifacts', [])
            for name in ['node-source', 'cli-source']:
                rows = [row for row in artifacts if row.get('id') == name]
                if len(rows) != 1 or rows[0].get('commit') != candidate or rows[0].get('published') is not True or rows[0].get('repo') != 'wrfcoin/core4':
                    raise ValueError('downloads source entries must match the candidate and be published')
        print(json.dumps({'status': 'PASS', 'evidence': 'source-preflight-only', 'candidate': candidate,
                          'scheduledFeaturesChecked': len(wanted), 'requiredCommitsChecked': len(args.required_commit),
                          'hardeningReview': 'explicit-ancestry-only' if args.required_commit else 'not-requested',
                          'runtimeReplay': 'not-run'}))
        return 0
    except (ValueError, OSError, subprocess.SubprocessError, TypeError, AttributeError) as error:
        # Do not echo file contents, credentials, git stderr, or internal paths.
        reason = str(error) if isinstance(error, ValueError) and not isinstance(error, json.JSONDecodeError) else type(error).__name__
        print(json.dumps({'status': 'FAIL', 'reason': reason}), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
