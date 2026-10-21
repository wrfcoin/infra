#!/usr/bin/env python3
"""B2 admission proof using real Caddy, loopback ports and no live upstream.

502 proves dispatch to the deliberately absent backend; 404 proves edge refusal.
Response privacy is the merged backend#1481 contract, not inferred from a 502.
Also called by the existing runtime edge CI gate, without changing its admission.
"""
from __future__ import annotations

import itertools
import re
import shutil
import subprocess
import tempfile
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

from verify_public_exposure_runtime import EDGE, IMAGE, run, status

BOARD = "/api/earnings/leaderboard"
PROFILE = "/api/operators/c_0123456789abcdef01234567/profile"
QUERY = "role=producer&period=all&limit=30"
GOOD = f"{BOARD}?{QUERY}"
GATE_OFF = (None, "off", "ON", "true", "1", " on")
NON_GET = ("POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD")
DENIED = (
    BOARD, f"{BOARD}?", f"{BOARD}?role=producer", f"{BOARD}?role=producer&period=all",
    # Every alternate ordering; only role, period, limit is accepted.
    *(f"{BOARD}?{'&'.join(parts)}" for parts in itertools.permutations(QUERY.split('&'))
      if '&'.join(parts) != QUERY),
    *(f"{GOOD}&{param}" for param in (
        "role=attester", "period=7d", "limit=1", "x=1", "country=US",
        "region=Europe", "near=40,-100", "radius_km=500", "lat=40", "lng=-100",
    )),
    f"{GOOD}&", f"{BOARD}?x=1&{QUERY}",
    *(f"{BOARD}?role={role}&period=all&limit=30" for role in ("unknown", "faucet", "Producer", "")),
    f"{BOARD}?role=producer&period=1y&limit=30",
    *(f"{BOARD}?role=producer&period=all&limit={limit}" for limit in ("0", "31", "100", "030", "-1", "3a", "")),
    f"{BOARD}?role=%70roducer&period=all&limit=30", f"{BOARD}?ROLE=producer&period=all&limit=30",
    f"{BOARD}?role=producer%26period=all&limit=30",
    f"{BOARD}/?{QUERY}", f"{BOARD}/x?{QUERY}", f"{BOARD}x?{QUERY}",
    f"/api/earnings/Leaderboard?{QUERY}", "/api/earnings", "/api/earnings/identities",
    PROFILE + "?x=1", PROFILE + "?role=producer", PROFILE + "/", PROFILE + "/x",
    PROFILE.replace("profile", "og-meta"), PROFILE.replace("profile", "card.png"),
    PROFILE.replace("c_0123456789abcdef01234567", "0x" + "a" * 40),
    PROFILE.replace("c_0123456789abcdef01234567", "c_" + "a" * 23),
    PROFILE.replace("c_0123456789abcdef01234567", "c_" + "a" * 25),
    PROFILE.replace("c_0123456789abcdef01234567", "c_" + "A" * 24),
    "/api/operators", "/api/operators/identities", "/api/operators/c_0123456789abcdef01234567",
    "/api/blockchain/blocks/1", "/api/chain/block/1",
    "/api/node-control/identities", "/api/producer-set", "/api/attesters",
)
NONCANONICAL = (
    f"/api/node-control/../earnings/leaderboard?{QUERY}",
    f"/api/earnings//leaderboard?{QUERY}", f"/api/earnings%2fleaderboard?{QUERY}",
    PROFILE.replace("/c_", "/./c_"), PROFILE.replace("/profile", "%2fprofile"),
)


@contextmanager
def edge(config: str, port: str, snippet: str, gate: str | None):
    name = f"sol4-earnings-{uuid.uuid4().hex[:10]}"
    with tempfile.TemporaryDirectory() as directory:
        target = Path(directory)
        shutil.copy(EDGE / "downloads.caddy", target / "downloads.caddy")
        (target / "Caddyfile").write_text(config)
        (target / "public_onboarding.caddy").write_text(snippet)
        options = ["-e", "ACME_EMAIL=local@example.invalid"]
        if gate is not None:
            options += ["-e", f"PUBLIC_READONLY_API={gate}"]
        mount = ["-v", f"{target}:/etc/caddy:ro"]
        # Validate the real config, including rate_limit, before serving it.
        run("docker", "run", "--rm", *options, *mount, IMAGE,
            "caddy", "validate", "--config", "/etc/caddy/Caddyfile")
        try:
            run("docker", "run", "--rm", "-d", "--name", name, "--network", "bridge",
                "--add-host", "wrfcoin-testnet-backend:127.0.0.1",
                "--add-host", "wrfcoin-testnet-frontend:127.0.0.1",
                "-p", f"127.0.0.1::{port}", *options, *mount, IMAGE,
                "caddy", "run", "--config", "/etc/caddy/Caddyfile")
            for _ in range(30):
                mapped = run("docker", "port", name, f"{port}/tcp", check=False)
                if mapped:
                    try:
                        if status(mapped, "/api/not-allowed") == 404:
                            yield mapped
                            return
                    except (subprocess.CalledProcessError, ValueError):
                        pass
                time.sleep(0.2)
            raise AssertionError("scratch Caddy did not start")
        finally:
            subprocess.run(("docker", "rm", "-f", name), check=True, capture_output=True)


def expect(mapped: str, path: str, code: int, method: str = "GET"):
    observed = status(mapped, path, method)
    assert observed == code, f"{method} {path}: expected {code}, got {observed}"


def prove_cases(config: str, port: str, snippet: str, cases, code: int):
    # Every request consumes a bucket, including refusals. Keep each fresh
    # container below 30; no 429 can masquerade as grammar admission/refusal.
    for offset in range(0, len(cases), 24):
        with edge(config, port, snippet, "on") as mapped:
            for path in cases[offset:offset + 24]:
                expect(mapped, path, code)


def prove_rate(config: str, port: str, snippet: str):
    with edge(config, port, snippet, "on") as mapped:
        # Both new routes share the existing weather public_read bucket.
        paths = (GOOD, PROFILE, "/api/weather/leaderboard?metric=earnings&period=7d&limit=30")
        for count in range(30):
            expect(mapped, paths[count % 3], 502)
        for path in paths:
            expect(mapped, path, 429)


def prove_red(config: str, port: str, original: str):
    query_line = next(line for line in original.splitlines(True) if "^role=" in line)
    gate_line = "\t\tvars {env.PUBLIC_READONLY_API} on\n"
    mutations = {
        "query removed": (original.replace(query_line, ""), BOARD, "GET", "on", 404),
        "query unanchored": (original.replace("'^role=", "'role="), f"{BOARD}?x=1&{QUERY}", "GET", "on", 404),
        "extra geo": (original.replace("&period=(all|7d|30d)&limit=([1-9]|[12][0-9]|30)$",
                        "&period=(all|7d|30d)&limit=([1-9]|[12][0-9]|30)(&country=US)?$"),
                      GOOD + "&country=US", "GET", "on", 404),
        "reordered": (original.replace("^role=(contribution|attester|producer|node|forecast)&period=(all|7d|30d)",
                       "^period=(all|7d|30d)&role=(contribution|attester|producer|node|forecast)"),
                      f"{BOARD}?period=all&role=producer&limit=30", "GET", "on", 404),
        "limit widened": (original.replace(query_line, query_line.replace("|30)$", "|30|100)$")),
                          f"{BOARD}?role=producer&period=all&limit=100", "GET", "on", 404),
        "profile raw address": (original.replace("^/api/operators/c_[0-9a-f]{24}/profile$", "^/api/operators/[^/]+/profile$"),
                                PROFILE.replace("c_0123456789abcdef01234567", "0x" + "a" * 40), "GET", "on", 404),
        "profile query removed": (original.replace("^/api/operators/c_[0-9a-f]{24}/profile$\n" + gate_line +
                                 '\t\texpression `{query} == ""`\n',
                                 "^/api/operators/c_[0-9a-f]{24}/profile$\n" + gate_line), PROFILE + "?x=1", "GET", "on", 404),
    }
    for route, path in (("earnings_leaderboard", GOOD), ("operator_profile", PROFILE)):
        prefix = f"@public_readonly_{route} {{\n\t\tmethod GET"
        mutations[f"{route} POST"] = (original.replace(prefix, prefix + " POST"), path, "POST", "on", 404)
        matcher = "^/api/earnings/leaderboard$" if route == "earnings_leaderboard" else "^/api/operators/c_[0-9a-f]{24}/profile$"
        mutations[f"{route} gate removed"] = (
            original.replace("path_regexp " + matcher + "\n" + gate_line, "path_regexp " + matcher + "\n"),
            path, "GET", None, 404,
        )
    for label, (mutated, path, method, gate, code) in mutations.items():
        assert mutated != original, f"RED mutation did not change config: {label}"
        with edge(config, port, mutated, gate) as mapped:
            try:
                expect(mapped, path, code, method)
            except AssertionError as error:
                print(f"PASS [RED B2] {label}: {error}")
            else:
                raise AssertionError(f"RED mutation survived: {label}")
    for rate_path in (" /api/earnings/leaderboard", " /api/operators/c_*/profile"):
        # Remove only the zone path, leaving the admission matcher intact.
        mutated = original.replace(rate_path, "")
        assert mutated != original
        try:
            prove_rate(config, port, mutated)
        except AssertionError as error:
            print(f"PASS [RED B2] limiter removal {rate_path.strip()}: {error}")
        else:
            raise AssertionError(f"RED limiter mutation survived: {rate_path}")


def main():
    original = (EDGE / "public_onboarding.caddy").read_text()
    direct = (EDGE / "Caddyfile").read_text()
    direct = re.sub(r"(?m)^\{\$WRFCOIN_PUBLIC_DOMAIN\}\s*\{", ":8080 {", direct)
    direct = re.sub(r"(?m)^api\.\{\$WRFCOIN_PUBLIC_DOMAIN\}\s*\{", ":8081 {", direct)
    funnel = (EDGE / "Caddyfile.funnel").read_text()
    accepted = tuple(f"{BOARD}?role={role}&period={period}&limit={limit}" for role, period, limit in
                     itertools.product(("contribution", "attester", "producer", "node", "forecast"),
                                       ("all", "7d", "30d"), (1, 9, 10, 19, 20, 29, 30))) + (PROFILE,)
    for label, config, port in (("direct", direct, "8080"), ("funnel", funnel, "8444")):
        for gate in GATE_OFF:
            with edge(config, port, original, gate) as mapped:
                expect(mapped, GOOD, 404)
                expect(mapped, PROFILE, 404)
        prove_cases(config, port, original, accepted, 502)
        prove_cases(config, port, original, DENIED, 404)
        prove_cases(config, port, original, NONCANONICAL, 400)
        with edge(config, port, original, "on") as mapped:
            for path in (GOOD, PROFILE):
                for method in NON_GET:
                    expect(mapped, path, 404, method)
        prove_rate(config, port, original)
        print(f"PASS [B2 {label}] validate; {len(accepted)} admitted; {len(DENIED)} refused; "
              f"all gate-OFF values, non-GET, traversal and shared 30/min limiter")
    prove_red(funnel, "8444", original)


if __name__ == "__main__":
    main()
