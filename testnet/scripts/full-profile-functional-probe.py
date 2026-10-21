#!/usr/bin/env python3
"""Fail-closed, non-mutating functional probes for full-profile services."""

from __future__ import annotations

import argparse
import datetime
import json
import secrets
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


SERVICE_CONTRACTS = {
    "cross-chain": {
        "capability": "crosschain.bridge_status",
        "dependency_kind": "bridge_client",
        "path": "/api/crosschain/bridge-status",
    },
    "compute": {
        "capability": "compute.flux.status",
        "dependency_kind": "compute_provider_client",
        "path": "/api/flux/status",
    },
    "ml": {
        "capability": "ml.provider_status",
        "dependency_kind": "model_runtime_client",
        "path": "/api/aiml/networks/status",
    },
    "node-discovery": {
        "capability": "node_discovery.peer_registry",
        "dependency_kind": "peer_registry",
        "path": "/network",
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--service", choices=sorted(SERVICE_CONTRACTS), required=True)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--max-age-seconds", type=float, default=120.0)
    return parser.parse_args()


def request_json(url: str, timeout: float) -> tuple[int, Any]:
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status = response.status
            raw = response.read(65536)
    except urllib.error.HTTPError as error:
        status = error.code
        raw = error.read(65536)
    try:
        return status, json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(
            f"domain endpoint returned non-JSON HTTP {status}: {error}"
        ) from error


def parse_timestamp(value: Any) -> datetime.datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(datetime.timezone.utc)


def unavailable_reason(payload: Any, capability: str) -> str | None:
    if not isinstance(payload, dict):
        return None
    error = payload.get("error")
    if not isinstance(error, dict):
        return None
    if (
        payload.get("unavailable") is True
        and error.get("code") == "NOT_IMPLEMENTED"
        and error.get("capability") == capability
        and isinstance(payload.get("reason"), str)
        and payload["reason"].strip()
    ):
        return payload["reason"].strip()
    return None


def validate_functional(
    payload: Any,
    contract: dict[str, str],
    nonce: str,
    max_age_seconds: float,
) -> tuple[bool, str]:
    if not isinstance(payload, dict):
        return False, "domain response is not a JSON object"
    evidence = payload.get("readiness")
    if not isinstance(evidence, dict):
        return False, "missing readiness evidence object (health-only/canned response)"
    if payload.get("success") is not True:
        return False, "domain response does not assert success=true"
    if payload.get("capability") != contract["capability"]:
        return False, f"capability must be {contract['capability']}"
    if evidence.get("evidence_class") != "FUNCTIONAL":
        return False, "readiness evidence_class must be FUNCTIONAL"
    if evidence.get("source") != "live_dependency_probe":
        return False, "readiness source must be live_dependency_probe"
    if evidence.get("nonce") != nonce:
        return (
            False,
            "readiness nonce does not match this probe (constant/cached payload)",
        )
    observed_at = parse_timestamp(evidence.get("observed_at"))
    if observed_at is None:
        return False, "readiness observed_at is missing or not timezone-aware"
    age = abs(
        (datetime.datetime.now(datetime.timezone.utc) - observed_at).total_seconds()
    )
    if age > max_age_seconds:
        return (
            False,
            f"readiness evidence is stale ({age:.1f}s > {max_age_seconds:.1f}s)",
        )
    dependency = evidence.get("dependency")
    if not isinstance(dependency, dict):
        return False, "missing dependency evidence"
    if dependency.get("kind") != contract["dependency_kind"]:
        return False, f"dependency kind must be {contract['dependency_kind']}"
    if dependency.get("connected") is not True:
        return False, "dependency is not connected"
    target = dependency.get("target")
    if not isinstance(target, str) or not target.strip():
        return False, "dependency target is missing"
    return True, f"live {dependency['kind']} boundary target={target}"


def main() -> int:
    args = parse_args()
    contract = SERVICE_CONTRACTS[args.service]
    nonce = secrets.token_hex(16)
    base = args.base_url.rstrip("/")
    query = urllib.parse.urlencode({"readiness_nonce": nonce})
    url = f"{base}{contract['path']}?{query}"
    try:
        status, payload = request_json(url, args.timeout)
    except (OSError, ValueError) as error:
        print(f"probe error: {error}")
        return 1

    if status == 501:
        reason = unavailable_reason(payload, contract["capability"])
        if reason:
            print(f"UNAVAILABLE (honest, not release-green): {reason}")
        else:
            print("HTTP 501 did not match the canonical unavailable schema")
        return 1
    if status != 200:
        print(f"domain endpoint returned HTTP {status}")
        return 1

    valid, detail = validate_functional(payload, contract, nonce, args.max_age_seconds)
    print(detail if valid else f"UNAVAILABLE (unproven, not release-green): {detail}")
    return 0 if valid else 1


if __name__ == "__main__":
    raise SystemExit(main())
