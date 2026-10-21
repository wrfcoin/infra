#!/usr/bin/env python3
"""Fail-closed semantic health contracts for public-release checks."""
import argparse
import json
import sys

GOOD = {"healthy", "ok", "up", "ready", "connected", "operational"}
BAD = {"degraded", "down", "unhealthy", "failed", "failure", "error", "offline"}


def fail(message: str) -> None:
    print(f"SEMANTIC_HEALTH_FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def walk(value, path="root") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{key}"
            if key == "status" and isinstance(child, str) and child.lower() in BAD:
                fail(f"{child_path}={child}")
            if key in {"connected", "healthy", "ready"} and child is False:
                fail(f"{child_path}=false")
            walk(child, child_path)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            walk(child, f"{path}[{index}]")


parser = argparse.ArgumentParser()
parser.add_argument("--contract", required=True, choices=("backend", "governance", "generic"))
parser.add_argument("payload")
args = parser.parse_args()

try:
    with open(args.payload, encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, UnicodeError, json.JSONDecodeError) as error:
    fail(f"malformed-json contract={args.contract} reason={error}")

if not isinstance(payload, dict):
    fail(f"contract={args.contract} payload-must-be-object")

if args.contract == "backend":
    if payload.get("success") is not True:
        fail("contract=backend root.success must be true")
    health = payload.get("data")
    if not isinstance(health, dict):
        fail("contract=backend root.data is missing")
    status = health.get("status")
    if not isinstance(status, str) or status.lower() not in GOOD:
        fail(f"contract=backend root.data.status={status!r}")
    walk(health, "root.data")
    dependencies = health.get("dependencies")
    database = dependencies.get("database") if isinstance(dependencies, dict) else None
    if not isinstance(database, dict):
        fail("contract=backend root.data.dependencies.database is missing")
    db_status = database.get("status")
    if not isinstance(db_status, str) or db_status.lower() not in GOOD:
        fail(f"contract=backend database.status={db_status!r}")
elif args.contract == "governance":
    status = payload.get("status")
    if not isinstance(status, str) or status.lower() not in GOOD:
        fail(f"contract=governance root.status={status!r}")
    walk(payload)
    dependencies = payload.get("dependencies")
    database = dependencies.get("database") if isinstance(dependencies, dict) else None
    if not isinstance(database, dict):
        fail("contract=governance root.dependencies.database is missing")
    db_status = database.get("status")
    if not isinstance(db_status, str) or db_status.lower() not in GOOD:
        fail(f"contract=governance database.status={db_status!r}")
    if database.get("mode") != "connected":
        fail(f"contract=governance database.mode={database.get('mode')!r}")
else:
    status = payload.get("status")
    if not isinstance(status, str) or status.lower() not in GOOD:
        fail(f"contract=generic root.status={status!r}")
    walk(payload)

print(f"SEMANTIC_HEALTH_PASS: contract={args.contract} status={status}")
