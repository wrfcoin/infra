#!/usr/bin/env python3
"""Local, outside-container proof for the public onboarding Caddy boundary.

Requires the deliberately local-only ``wrfcoin/edge-caddy:testnet-local`` image.
It binds ephemeral ports on 127.0.0.1, never contacts N5, and never pushes an image.

Two phases, one per public edge (both import public_onboarding.caddy):
  1. Caddyfile          — direct 443 edge, hostnames rewritten to local ports
  2. Caddyfile.funnel   — the loopback :8444 edge run EXACTLY as shipped
Each phase proves: non-allowlisted API path 404s, /ws 404s, an allowlisted
route is admitted past the edge (upstream 502, never the edge 404), and the
sixth faucet claim rate-limits. Phase 2b (infra#983) proves the Stage 1.5
station reads stay 404 unless the edge env is exactly PUBLIC_READONLY_API=on.
"""

from __future__ import annotations

import http.server
import json
import re
import threading
import shutil
import subprocess
import tempfile
import time
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EDGE = ROOT / "testnet" / "edge"
IMAGE = "wrfcoin/edge-caddy:testnet-local"
NGINX_FRONTEND_CONF = ROOT / "testnet" / "nginx-frontend.conf"
PUBLIC_READS = (
    "/api/blockchain/transactions",
    f"/api/blockchain/transactions/{'a' * 64}",
    "/api/blockchain/validators",
    "/api/blockchain/stats",
    # infra#968: exact paths for the public build-freshness probe.
    "/api/build",
    "/api/capabilities",
)
DENIED_PUBLIC_READS = (
    "/api/blockchain/mempool",
    "/api/blockchain/blocks/1",
    "/api/weather/stations",
    # Siblings of the infra#968 exact matches: no prefix or suffix widening.
    "/api/builds",
    "/api/build/x",
    "/api/build/",
    "/api/capabilities/x",
    "/api/capabilitiesx",
    # infra#983: gated Stage 1.5 station reads are OFF in every default run.
    "/api/stations/abc/observations",
    "/api/stations/abc/quality",
    "/api/stations/abc/submissions",
    "/api/stations/abc/earnings",
)
# infra#983 — Stage 1.5 station reads behind PUBLIC_READONLY_API. Admitted
# (upstream 502) ONLY when the edge container's env is exactly `on`; 404 when
# unset or any other value. The siblings stay 404 even with the gate on.
READONLY_GATED_READS = (
    "/api/weather/stations",
    "/api/stations/abc/observations",
    "/api/stations/KMAWELLE-12_x/quality",
    f"/api/stations/{'s' * 64}/submissions",
    # The exact query the Stage 1.5 station page sends for its observations poll.
    "/api/stations/abc/observations?limit=1",
)
# Query lock (stage15 readiness): with the gate ON these still 404. `lat`/`lng`
# (and the `lat[]` form Express also reads) switch the station list to the
# outbound NOAA nearby lookup; `limit`/`after` page it; a detail read takes
# only an empty query or exactly `limit=1`.
READONLY_QUERY_DENIED = (
    "/api/weather/stations?lat=40&lng=-100",
    "/api/weather/stations?lat%5B%5D=40&lng%5B%5D=-100",
    "/api/weather/stations?lng=-100",
    "/api/weather/stations?limit=500",
    "/api/weather/stations?after=x",
    "/api/weather/stations?source=noaa",
    "/api/stations/abc/submissions?limit=100",
    "/api/stations/abc/submissions?limit=1&offset=5",
    "/api/stations/abc/observations?limit=100",
    "/api/stations/abc/observations?limit=1&after=1",
    "/api/stations/abc/observations?LIMIT=1",
    "/api/stations/abc/quality?x=1",
)
# backend#1232 / frontend#534 — the per-station earnings read, gated exactly like the reads
# above but proved in its OWN edge container: the public_read zone allows 30 requests/min per
# client for /api/stations/*, and the earnings proof added to the main one would exceed it.
READONLY_EARNINGS_READS = (
    "/api/stations/abc/earnings",
    "/api/stations/KMAWELLE-12_x/earnings",
    f"/api/stations/{'s' * 64}/earnings",
)
# The frontend calls it with NO query string; `?limit=` sizes the per-commit core4
# reward-evidence fan-out, so even the `limit=1` its siblings admit is refused.
READONLY_EARNINGS_QUERY_DENIED = (
    "/api/stations/abc/earnings?limit=1",
    "/api/stations/abc/earnings?limit=100",
    "/api/stations/abc/earnings?x=1",
    "/api/stations/abc/earnings?limit",
)
# Every method but GET must 404 on the earnings route (HEAD included: Caddy would
# otherwise answer HEAD from a GET matcher only if the matcher were widened).
READONLY_EARNINGS_NON_GET_METHODS = ("POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD")
READONLY_EARNINGS_SIBLINGS_DENIED = (
    "/api/stations/abc/earnings/x",
    "/api/stations/abc/earnings/",
    "/api/stations/abc/earningsx",
    "/api/stations/abc/Earnings",
    f"/api/stations/{'s' * 65}/earnings",
    "/api/stations/a.b/earnings",
)
# backend#1456 / frontend#535 (owner ruling 2026-10-06) — the weather leaderboard, same gate, its own
# containers (public_read is 30 requests/min per client). The ONE admitted grammar, in this order:
#   metric=<earnings|submissions|quality_score|streak>&period=<7d|30d|all>&limit=<1..30>
LEADERBOARD = "/api/weather/leaderboard"
READONLY_LEADERBOARD_READS = (
    f"{LEADERBOARD}?metric=earnings&period=30d&limit=30",  # exactly what GlobalLeaderboard sends
    f"{LEADERBOARD}?metric=earnings&period=7d&limit=25",
    f"{LEADERBOARD}?metric=submissions&period=all&limit=1",
    f"{LEADERBOARD}?metric=quality_score&period=7d&limit=9",
    f"{LEADERBOARD}?metric=streak&period=30d&limit=10",
    f"{LEADERBOARD}?metric=streak&period=all&limit=29",
)
READONLY_LEADERBOARD_QUERY_DENIED = (
    LEADERBOARD,
    f"{LEADERBOARD}?",
    f"{LEADERBOARD}?metric=earnings",
    f"{LEADERBOARD}?metric=earnings&period=30d",
    # Geo params are refused outright, earnings or not (backend#1457 400s earnings+geo).
    f"{LEADERBOARD}?metric=earnings&period=30d&limit=30&country=US",
    f"{LEADERBOARD}?metric=earnings&period=30d&limit=30&region=Europe",
    f"{LEADERBOARD}?metric=earnings&period=30d&limit=30&near=40,-100",
    f"{LEADERBOARD}?metric=submissions&period=7d&limit=30&country=US",
    f"{LEADERBOARD}?metric=streak&period=7d&limit=30&near=40,-100&radius_km=500",
    f"{LEADERBOARD}?metric=bogus&period=7d&limit=30",
    f"{LEADERBOARD}?metric=earnings&period=1y&limit=30",
    f"{LEADERBOARD}?metric=earnings&period=30d&limit=31",
    f"{LEADERBOARD}?metric=earnings&period=30d&limit=100",
    f"{LEADERBOARD}?metric=earnings&period=30d&limit=0",
    f"{LEADERBOARD}?metric=earnings&period=30d&limit=030",
    f"{LEADERBOARD}?metric=earnings&period=30d&limit=3a",
    f"{LEADERBOARD}?metric=earnings&period=30d&limit=-1",
    f"{LEADERBOARD}?metric=earnings&period=30d&limit=",
    f"{LEADERBOARD}?period=30d&metric=earnings&limit=30",  # reordered
    f"{LEADERBOARD}?metric=earnings&limit=30&period=30d",  # reordered
    f"{LEADERBOARD}?metric=earnings&period=30d&limit=30&x=1",
    f"{LEADERBOARD}?metric=earnings&metric=streak&period=30d&limit=30",
    f"{LEADERBOARD}?metric=earnings&period=30d&limit=30&",
    f"{LEADERBOARD}?METRIC=earnings&period=30d&limit=30",
    f"{LEADERBOARD}?metric=%65arnings&period=30d&limit=30",
    f"{LEADERBOARD}?x=1&metric=earnings&period=30d&limit=30",  # prefix junk (unanchored regex)
)
# One representative per refusal class, for the RED controls (each mutant must fail on at least one).
READONLY_LEADERBOARD_RED_PROBES = (
    LEADERBOARD,
    f"{LEADERBOARD}?metric=earnings&period=30d&limit=30&country=US",
    f"{LEADERBOARD}?metric=earnings&period=30d&limit=100",
    f"{LEADERBOARD}?x=1&metric=earnings&period=30d&limit=30",
)
READONLY_LEADERBOARD_SIBLINGS_DENIED = (
    f"{LEADERBOARD}/?metric=earnings&period=30d&limit=30",
    f"{LEADERBOARD}/x?metric=earnings&period=30d&limit=30",
    f"{LEADERBOARD}x?metric=earnings&period=30d&limit=30",
    "/api/weather/Leaderboard?metric=earnings&period=30d&limit=30",
    "/api/weather/leaderboards?metric=earnings&period=30d&limit=30",
)
READONLY_LEADERBOARD_NON_GET_METHODS = ("POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD")
# infra#1095 — station theft protection. Two exact alias-only routes (st_ + 12 lowercase hex):
#   POST /api/stations/<alias>/owner-actions   the signed owner-tx relay (UNGATED, 8 KiB body cap, own rate zone)
#   GET  /api/stations/<alias>/ownership       the ownership state read (gated by PUBLIC_READONLY_API=on)
OWNER_ALIAS = "st_0123456789ab"
OWNER_RELAY = f"/api/stations/{OWNER_ALIAS}/owner-actions"
OWNERSHIP_READ = f"/api/stations/{OWNER_ALIAS}/ownership"
OWNER_RELAY_BODY_CAP = 8192
# Paths that must NOT reach the backend for any method on the relay (404).
OWNER_RELAY_DENIED_PATHS = (
    "/api/stations/abc/owner-actions",                    # raw station id, not an alias
    "/api/stations/PWS-DULUTH-X/owner-actions",
    "/api/stations/ST_0123456789AB/owner-actions",         # alias must be lowercase hex
    "/api/stations/st_0123456789a/owner-actions",          # 11 hex
    "/api/stations/st_0123456789abc/owner-actions",        # 13 hex
    "/api/stations/st_0123456789ab/owner-actions/",
    "/api/stations/st_0123456789ab/owner-actions/x",
    "/api/stations/st_0123456789ab/owner-actionsx",
    f"{OWNER_RELAY}?x=1",                                  # NO query string (a bare `?` is an empty query and is admitted, as for every other locked read)
)
OWNER_RELAY_NON_POST_METHODS = ("GET", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD")
OWNERSHIP_DENIED_PATHS = (
    "/api/stations/abc/ownership",
    "/api/stations/ST_0123456789AB/ownership",
    "/api/stations/st_0123456789a/ownership",
    "/api/stations/st_0123456789abc/ownership",
    "/api/stations/st_0123456789ab/ownership/",
    "/api/stations/st_0123456789ab/ownership/x",
    "/api/stations/st_0123456789ab/ownershipx",
    f"{OWNERSHIP_READ}?x=1",
    f"{OWNERSHIP_READ}?limit=1",
)
OWNERSHIP_NON_GET_METHODS = ("POST", "PUT", "DELETE", "PATCH")
OWNER_RELAY_RATE_EVENTS = 10  # zone station_owner_actions: events 10 per 10m per client
READONLY_GATE_OFF_VALUES = (None, "off", "ON", "true", "1", " on")
READONLY_SIBLINGS_DENIED = (
    "/api/stations/abc/observations/x",
    "/api/stations/abc/observationsx",
    "/api/stations/abc",
    "/api/stations/",
    f"/api/stations/{'s' * 65}/quality",
    "/api/stations/a.b/quality",
    "/api/weather/stations/abc",
    "/api/weather/stationsx",
)
# infra#1051: Caddy matches a CLEANED path but reverse_proxy forwards the RAW
# URI, and Express 4 resolves neither dot segments nor encoded separators. Each
# of these CLEANS to an allowlisted read (or other edge route) while its raw
# form routes somewhere else in the backend, so each must be refused at the
# edge with the guard's 400 — never admitted (502 here), never a quiet 404
# from some later handler that a future edit could turn into an admit.
# Sent with curl --path-as-is so curl itself does not normalize them away.
NONCANONICAL_PATHS = (
    "/api/node-control/x/../../weather/coverage-zones",
    "/api/node-control/x/../../blockchain/stats",
    "/api/node-os/x/../../blockchain/status",
    "/api/node-control/../weather/coverage-zones",
    "/api/node-control/%2e%2e/weather/coverage-zones",
    "/api/node-control/x/%2E%2E/%2e%2E/weather/coverage-zones",
    "/api/node-control/x/..%2f..%2fweather/coverage-zones",
    "/api/node-control/x/..%2F..%2Fweather/coverage-zones",
    "/api/node-control/x/%2e%2e%2f%2e%2e%2fweather/coverage-zones",
    "/api/node-control/x/%252e%252e/%252e%252e/weather/coverage-zones",
    "/api/node-control/x/%25252e%25252e/weather/coverage-zones",
    "/api/node-control/x/..%5c..%5cweather/coverage-zones",
    "/api/node-control/x/..%5C..%5Cweather/coverage-zones",
    "/api/node-control/x/..\\..\\weather/coverage-zones",
    "/api/./weather/coverage-zones",
    "/api/weather/./coverage-zones",
    "/api/weather/coverage-zones/.",
    "/api/weather/coverage-zones/..",
    "/api//weather/coverage-zones",
    "//api/weather/coverage-zones",
    "/api/weather/coverage-zones%00",
    "/api/node-control/x/../../auth/nonce/0x0000000000000000000000000000000000000000",
    "/earn/../api/weather/coverage-zones",
    "/x/../status.json",
    "/x/../join/manifest.json",
)
# Raw request targets sent verbatim with curl --request-target. Absolute-form
# targets are not origin-form and are refused outright; `#` targets follow.
NONCANONICAL_TARGETS = (
    "http://wrfcoin.invalid/api/node-control/x/../../weather/coverage-zones",
    "http://wrfcoin.invalid/api/weather/coverage-zones",
    # Literal `#` in the raw target (review of #1052 at 9084b02). curl strips
    # fragments from URLs, so these must go through --request-target. Go keeps
    # `#` as a path character; Caddy cleans past it and forwards `%23` with the
    # dot segments raw, which Express then dispatches by the raw prefix.
    "/api/node-control/foo#/../../weather/coverage-zones",
    "/api/node-control/foo/x#/../../../weather/coverage-zones",
    "/api/wallet-auth/x#/../../weather/coverage-zones",
    "/api/x#/../weather/coverage-zones",
    "/api/weather/coverage-zones#/../../node-control",
    "/api/weather/coverage-zones#",
    "/api/governance/proposals/x#%2F..",
)
# Canonical controls: the guard must not over-reach. Dots inside a segment and
# dot-segments in the QUERY string are canonical and keep their old outcome.
CANONICAL_ADMITTED = (
    "/api/weather/coverage-zones?next=../../x",
    "/api/blockchain/stats?q=%2e%2e%2f",
)


def run(*args: str, check: bool = True) -> str:
    return subprocess.run(args, check=check, text=True, capture_output=True).stdout.strip()


def status(
    port: str,
    path: str,
    method: str = "GET",
    headers: tuple[str, ...] = (),
    request_target: str | None = None,
) -> int:
    # `-X HEAD` makes curl wait for a body that never comes; HEAD must use -I.
    method_args = ["-I"] if method == "HEAD" else ["-X", method]
    header_args = [arg for header in headers for arg in ("-H", header)]
    target_args = ["--request-target", request_target] if request_target is not None else []
    # --path-as-is: without it curl collapses ../ and ./ before sending, and
    # the infra#1051 cases would silently test the canonical path instead.
    return int(run(
        "curl", "--path-as-is", "--max-time", "3", *method_args, "-sS", "-o", "/dev/null",
        "-w", "%{http_code}", *header_args, *target_args, f"http://{port}{path}",
    ))


def prove_edge(label: str, config_text: str, container_port: str, snippet_text: str | None = None) -> None:
    name = f"wrf-edge-proof-{uuid.uuid4().hex[:10]}"
    with tempfile.TemporaryDirectory() as directory:
        caddy_dir = Path(directory)
        shutil.copy(EDGE / "downloads.caddy", caddy_dir / "downloads.caddy")
        (caddy_dir / "Caddyfile").write_text(config_text, encoding="utf-8")
        # The Caddyfile imports the shared allowlist — an unmounted import is
        # a boot failure, which is exactly what this phase would catch.
        if snippet_text is None:
            shutil.copy(EDGE / "public_onboarding.caddy", caddy_dir / "public_onboarding.caddy")
        else:
            (caddy_dir / "public_onboarding.caddy").write_text(snippet_text, encoding="utf-8")
        try:
            run(
                "docker", "run", "--rm", "-d", "--name", name, "--network", "bridge",
                "--add-host", "wrfcoin-testnet-backend:127.0.0.1",
                "--add-host", "wrfcoin-testnet-frontend:127.0.0.1",
                "-p", f"127.0.0.1::{container_port}", "-e", "ACME_EMAIL=local@example.invalid",
                "-v", f"{caddy_dir}:/etc/caddy:ro", IMAGE,
                "caddy", "run", "--config", "/etc/caddy/Caddyfile",
            )
            for _ in range(30):
                mapped = run("docker", "port", name, f"{container_port}/tcp", check=False)
                if mapped:
                    try:
                        if status(mapped, "/api/not-allowed") == 404:
                            break
                    except (subprocess.CalledProcessError, ValueError):
                        pass
                time.sleep(0.2)
            else:
                logs = run("docker", "logs", name, check=False)
                raise AssertionError(f"[{label}] edge did not return the terminal 404: {logs}")

            if status(mapped, "/api/not-allowed") != 404:
                raise AssertionError(f"[{label}] unsupported API path was not rejected at the edge")
            if status(mapped, "/ws") != 404:
                raise AssertionError(f"[{label}] /ws was not rejected at the edge")
            # Allowlist admission control: upstreams intentionally do not
            # exist, so an admitted route surfaces as a 502 from the proxy —
            # the edge 404 here would mean the allowlist is dead.
            nonce = status(mapped, "/api/auth/nonce/0x0000000000000000000000000000000000000000")
            if nonce == 404:
                raise AssertionError(f"[{label}] allowlisted nonce route was rejected — allowlist not wired")
            for path in PUBLIC_READS:
                if status(mapped, path) == 404:
                    raise AssertionError(f"[{label}] approved public read was rejected: {path}")
                if status(mapped, path, "POST") != 404:
                    raise AssertionError(f"[{label}] non-GET public read was admitted: {path}")
            for path in DENIED_PUBLIC_READS:
                if status(mapped, path) != 404:
                    raise AssertionError(f"[{label}] excluded public read was admitted: {path}")
            # infra#1051 over-reach control, run BEFORE the traversal cases so a
            # public_read 429 cannot masquerade as an admit: canonical reads
            # with dots only in the query string are admitted (upstream 502).
            for path in CANONICAL_ADMITTED:
                code = status(mapped, path)
                if code != 502:
                    raise AssertionError(f"[{label}] canonical read was not admitted (got {code}): {path}")
            claims = [status(mapped, "/api/onboarding/faucet/claim", "POST") for _ in range(6)]
            if claims[-1] != 429:
                raise AssertionError(f"[{label}] sixth faucet claim was not rate-limited: {claims}")
            print(
                f"PASS [{label}] denied API=404; /ws=404; nonce admitted ({nonce}); "
                f"faucet claims={claims}"
            )
        finally:
            subprocess.run(("docker", "rm", "-f", name), capture_output=True)


NONCANONICAL_CHUNK = 20


def prove_noncanonical_refused(label: str, config_text: str, container_port: str, snippet_text: str | None = None) -> None:
    """infra#1051: every non-canonical raw request is refused with the guard's 400.

    The guard runs AFTER rate_limit (unchanged by #1051), and most cases clean
    to a public_read path, so one container would exhaust that zone's 30/min
    and a 429 would hide whether the guard fired. Each chunk therefore runs in
    a fresh edge with fresh buckets, and the check still demands exactly 400:
    a 429, a 502 (admitted) and a 404 (a later handler) are all failures.
    """
    cases = [(path, None) for path in NONCANONICAL_PATHS] + [("/", target) for target in NONCANONICAL_TARGETS]
    for start in range(0, len(cases), NONCANONICAL_CHUNK):
        chunk = cases[start : start + NONCANONICAL_CHUNK]
        name = f"wrf-edge-dots-{uuid.uuid4().hex[:10]}"
        with tempfile.TemporaryDirectory() as directory:
            caddy_dir = Path(directory)
            shutil.copy(EDGE / "downloads.caddy", caddy_dir / "downloads.caddy")
            (caddy_dir / "Caddyfile").write_text(config_text, encoding="utf-8")
            if snippet_text is None:
                shutil.copy(EDGE / "public_onboarding.caddy", caddy_dir / "public_onboarding.caddy")
            else:
                (caddy_dir / "public_onboarding.caddy").write_text(snippet_text, encoding="utf-8")
            try:
                run(
                    "docker", "run", "--rm", "-d", "--name", name, "--network", "bridge",
                    "--add-host", "wrfcoin-testnet-backend:127.0.0.1",
                    "--add-host", "wrfcoin-testnet-frontend:127.0.0.1",
                    "-p", f"127.0.0.1::{container_port}", "-e", "ACME_EMAIL=local@example.invalid",
                    "-v", f"{caddy_dir}:/etc/caddy:ro", IMAGE,
                    "caddy", "run", "--config", "/etc/caddy/Caddyfile",
                )
                for _ in range(30):
                    mapped = run("docker", "port", name, f"{container_port}/tcp", check=False)
                    if mapped:
                        try:
                            if status(mapped, "/api/not-allowed") == 404:
                                break
                        except (subprocess.CalledProcessError, ValueError):
                            pass
                    time.sleep(0.2)
                else:
                    logs = run("docker", "logs", name, check=False)
                    raise AssertionError(f"[{label}] edge did not come up: {logs}")
                for path, target in chunk:
                    code = status(mapped, path, request_target=target)
                    if code != 400:
                        shown = target if target is not None else path
                        raise AssertionError(
                            f"[{label}] non-canonical request was not refused with 400 (got {code}): {shown}"
                        )
            finally:
                subprocess.run(("docker", "rm", "-f", name), capture_output=True)
    print(f"PASS [{label}] {len(cases)} non-canonical requests (dot segments, encoded, `#`, absolute-form) = 400")


def prove_xff_cannot_reset_the_limit(
    label: str, config_text: str, container_port: str, header_for=None
) -> None:
    """infra#657: the faucet_claim limit must key on something the CLIENT cannot choose.

    `trusted_proxies static private_ranges` alone takes the LEFTMOST
    X-Forwarded-For entry, so a client that sends a different value on every
    request lands in a different rate-limit bucket every time and the limit
    never engages. Measured on this image: rotating the header returned 8x200
    where a fixed header returned 5x200 then 429.

    WHAT THIS MODELS, and its one limitation, stated so nobody over-reads a
    green run: each request carries a rotating spoofed entry FOLLOWED BY a
    fixed public address, which is the header shape produced when the hop in
    front APPENDS the real client IP. Under strict the bucket follows the
    appended value, so the limit engages; under `private_ranges` alone it
    follows the rotating spoof and never does.

    It does NOT cover the case where the hop passes the client's header through
    untouched. Measured on this image, `trusted_proxies_strict` does NOT close
    that case: a rotating spoof with nothing appended defeats the limit with or
    without it. Whether tailscale funnel appends or passes through is an open
    question tracked separately; if it passes through, this edge must stop
    honoring client X-Forwarded-For altogether and this phase changes with it.

    FAILS on `private_ranges` alone, PASSES with `trusted_proxies_strict`.
    Do not "fix" a failure here by relaxing the assertion.

    Scope: only Caddyfile.funnel sets trusted_proxies, so only that edge honors
    X-Forwarded-For and only that edge can be spoofed this way.
    """
    name = f"wrf-edge-xff-{uuid.uuid4().hex[:10]}"
    with tempfile.TemporaryDirectory() as directory:
        caddy_dir = Path(directory)
        shutil.copy(EDGE / "downloads.caddy", caddy_dir / "downloads.caddy")
        (caddy_dir / "Caddyfile").write_text(config_text, encoding="utf-8")
        shutil.copy(EDGE / "public_onboarding.caddy", caddy_dir / "public_onboarding.caddy")
        try:
            run(
                "docker", "run", "--rm", "-d", "--name", name, "--network", "bridge",
                "--add-host", "wrfcoin-testnet-backend:127.0.0.1",
                "--add-host", "wrfcoin-testnet-frontend:127.0.0.1",
                "-p", f"127.0.0.1::{container_port}", "-e", "ACME_EMAIL=local@example.invalid",
                "-v", f"{caddy_dir}:/etc/caddy:ro", IMAGE,
                "caddy", "run", "--config", "/etc/caddy/Caddyfile",
            )
            for _ in range(30):
                mapped = run("docker", "port", name, f"{container_port}/tcp", check=False)
                if mapped:
                    try:
                        if status(mapped, "/api/not-allowed") == 404:
                            break
                    except (subprocess.CalledProcessError, ValueError):
                        pass
                time.sleep(0.2)
            else:
                logs = run("docker", "logs", name, check=False)
                raise AssertionError(f"[{label}] edge did not come up: {logs}")

            # Each request carries a DIFFERENT spoofed entry, then a FIXED
            # address standing in for the one an appending hop would add. If
            # the key follows the client-chosen leftmost entry, every request
            # is a fresh bucket and none is ever refused; if it follows the
            # appended value, all eight share one bucket and the sixth is.
            # `header_for` decides which world the attacker is assumed to be
            # in. Default models an APPENDING hop: a rotating spoofed entry
            # followed by a fixed address. infra#884 also runs the
            # PASS-THROUGH shape -- a rotating spoof with nothing appended --
            # which is the case trusted_proxies_strict did NOT close.
            if header_for is None:
                header_for = lambda n: f"X-Forwarded-For: 203.0.113.{n}, 198.51.100.7"
            rotated = [
                status(mapped, "/api/onboarding/faucet/claim", "POST", (header_for(n),))
                for n in range(1, 9)
            ]
            if 429 not in rotated:
                raise AssertionError(
                    f"[{label}] rotating X-Forwarded-For defeated the faucet_claim limit: {rotated}. "
                    "The rate-limit key follows a client-controlled header. "
                    "Add `trusted_proxies_strict` to the funnel edge's global options."
                )
            print(f"PASS [{label}] rotating X-Forwarded-For did NOT reset the faucet limit: {rotated}")
        finally:
            subprocess.run(("docker", "rm", "-f", name), capture_output=True)


def prove_inbound_xff_is_logged_and_client_ip_is_the_peer(config_text: str, container_port: str) -> None:
    """infra#884: the instrumentation works, and the cost of the hardening is real.

    Two facts, measured together because they come from the same log line:

    1. The INBOUND X-Forwarded-For is recorded as received. That is what makes
       #884 answerable from the deployed edge's own logs without anyone
       probing it: two or more entries ending in a public address means the
       funnel APPENDS; exactly what a client sent means PASS-THROUGH.

    2. From a peer that is NOT the pinned wrfcoin-ingress gateway (here the
       harness's default-bridge gateway), {client_ip} is the connection peer
       even when the header carries a plausible appended client address: only
       the one trusted hop can set it (backend#1229; see phase 7 for that hop).
    """
    label = "funnel-edge-xff-logging"
    name = f"wrf-edge-log-{uuid.uuid4().hex[:10]}"
    appended_chain = "203.0.113.44, 198.51.100.9"
    with tempfile.TemporaryDirectory() as directory:
        caddy_dir = Path(directory)
        shutil.copy(EDGE / "downloads.caddy", caddy_dir / "downloads.caddy")
        (caddy_dir / "Caddyfile").write_text(config_text, encoding="utf-8")
        shutil.copy(EDGE / "public_onboarding.caddy", caddy_dir / "public_onboarding.caddy")
        try:
            run(
                "docker", "run", "--rm", "-d", "--name", name, "--network", "bridge",
                "--add-host", "wrfcoin-testnet-backend:127.0.0.1",
                "--add-host", "wrfcoin-testnet-frontend:127.0.0.1",
                "-p", f"127.0.0.1::{container_port}", "-e", "ACME_EMAIL=local@example.invalid",
                "-v", f"{caddy_dir}:/etc/caddy:ro", IMAGE,
                "caddy", "run", "--config", "/etc/caddy/Caddyfile",
            )
            for _ in range(30):
                mapped = run("docker", "port", name, f"{container_port}/tcp", check=False)
                if mapped:
                    try:
                        if status(mapped, "/api/not-allowed") == 404:
                            break
                    except (subprocess.CalledProcessError, ValueError):
                        pass
                time.sleep(0.2)
            else:
                raise AssertionError(f"[{label}] edge did not come up")

            status(mapped, "/api/not-allowed", "GET", (f"X-Forwarded-For: {appended_chain}",))
            time.sleep(0.5)
            # Caddy writes the access log to STDERR, and run() returns stdout
            # only -- reading it with run() silently yields nothing and the
            # phase fails as though the instrumentation were missing.
            log_streams = subprocess.run(
                ("docker", "logs", name), capture_output=True, text=True
            )
            logged = None
            for line in (log_streams.stdout + log_streams.stderr).splitlines():
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if entry.get("inbound_x_forwarded_for") == appended_chain:
                    logged = entry
                    break
            if logged is None:
                raise AssertionError(
                    f"[{label}] the inbound X-Forwarded-For was not recorded. The #884 "
                    "instrumentation is the only way that question gets answered from "
                    "the deployed edge; without it this change is half-done."
                )

            resolved = logged.get("request", {}).get("client_ip")
            if resolved in (None, ""):
                raise AssertionError(f"[{label}] access log carried no client_ip to check")
            if resolved in appended_chain.split(", "):
                raise AssertionError(
                    f"[{label}] {{client_ip}} resolved to {resolved}, an address the CLIENT "
                    "supplied. The hardening is not in effect."
                )
            if "headers" in logged.get("request", {}):
                raise AssertionError(
                    f"[{label}] request headers are being logged; the #884 log was meant to "
                    "be narrow and this is a public edge."
                )
            print(
                f"PASS [{label}] inbound XFF recorded as {appended_chain!r}; "
                f"{{client_ip}} = {resolved} (the peer, NOT a client-supplied value) — "
                "an untrusted peer cannot choose its bucket"
            )
        finally:
            subprocess.run(("docker", "rm", "-f", name), capture_output=True)


def prove_readonly_gate(
    label: str,
    config_text: str,
    container_port: str,
    gate_value: str | None,
    snippet_text: str | None = None,
    reads: tuple[str, ...] | None = None,
    siblings: tuple[str, ...] | None = None,
    query_denied: tuple[str, ...] = (),
    non_get_from: int = 1,
    non_get_methods: tuple[str, ...] = ("POST", "PUT", "DELETE"),
    non_get_paths: int | None = None,
) -> None:
    """infra#983: the Stage 1.5 station reads obey PUBLIC_READONLY_API exactly.

    gate_value None runs the container with the variable UNSET. Only `on`
    admits; every other value must leave the edge exactly as it is today
    (404). With the gate on, the admitted reads are GET-only and anchored:
    the siblings and non-GET methods still 404. (POST /api/weather/stations is
    the separately approved station_register route, so it is not a sibling.)
    """
    reads = READONLY_GATED_READS if reads is None else reads
    siblings = READONLY_SIBLINGS_DENIED if siblings is None else siblings
    name = f"wrf-edge-ro-{uuid.uuid4().hex[:10]}"
    env_args = [] if gate_value is None else ["-e", f"PUBLIC_READONLY_API={gate_value}"]
    with tempfile.TemporaryDirectory() as directory:
        caddy_dir = Path(directory)
        shutil.copy(EDGE / "downloads.caddy", caddy_dir / "downloads.caddy")
        (caddy_dir / "Caddyfile").write_text(config_text, encoding="utf-8")
        if snippet_text is None:
            shutil.copy(EDGE / "public_onboarding.caddy", caddy_dir / "public_onboarding.caddy")
        else:
            (caddy_dir / "public_onboarding.caddy").write_text(snippet_text, encoding="utf-8")
        try:
            run(
                "docker", "run", "--rm", "-d", "--name", name, "--network", "bridge",
                "--add-host", "wrfcoin-testnet-backend:127.0.0.1",
                "--add-host", "wrfcoin-testnet-frontend:127.0.0.1",
                "-p", f"127.0.0.1::{container_port}", "-e", "ACME_EMAIL=local@example.invalid",
                *env_args,
                "-v", f"{caddy_dir}:/etc/caddy:ro", IMAGE,
                "caddy", "run", "--config", "/etc/caddy/Caddyfile",
            )
            for _ in range(30):
                mapped = run("docker", "port", name, f"{container_port}/tcp", check=False)
                if mapped:
                    try:
                        if status(mapped, "/api/not-allowed") == 404:
                            break
                    except (subprocess.CalledProcessError, ValueError):
                        pass
                time.sleep(0.2)
            else:
                logs = run("docker", "logs", name, check=False)
                raise AssertionError(f"[{label}] edge did not come up: {logs}")
            shown = "unset" if gate_value is None else repr(gate_value)
            if gate_value != "on":
                for path in reads:
                    code = status(mapped, path)
                    if code != 404:
                        raise AssertionError(
                            f"[{label}] PUBLIC_READONLY_API={shown} admitted a gated read (got {code}): {path}"
                        )
                print(f"PASS [{label}] PUBLIC_READONLY_API={shown}: {len(reads)} gated reads = 404")
                return
            for path in reads:
                code = status(mapped, path)
                if code != 502:
                    raise AssertionError(f"[{label}] PUBLIC_READONLY_API=on did not admit (got {code}): {path}")
            # non_get_paths caps how many paths get every method: the public_read zone is
            # 30 requests/min per client, so the earnings proof tries all six methods on its
            # first path only (the matcher is one `method GET` line shared by every id).
            for path in reads[non_get_from:][:non_get_paths]:
                for method in non_get_methods:
                    if status(mapped, path, method) != 404:
                        raise AssertionError(f"[{label}] gated read admitted {method}: {path}")
            for method in ("PUT", "DELETE", "PATCH"):
                if status(mapped, "/api/weather/stations", method) != 404:
                    raise AssertionError(f"[{label}] gated station list admitted {method}")
            for path in siblings:
                code = status(mapped, path)
                if code != 404:
                    raise AssertionError(f"[{label}] sibling of a gated read was admitted (got {code}): {path}")
            for path in query_denied:
                code = status(mapped, path)
                if code != 404:
                    raise AssertionError(f"[{label}] query-locked read was admitted (got {code}): {path}")
            # #1051 still runs first with the gate on.
            for path in ("/api/stations/abc/../abc/quality", "/api/stations/abc/%2e%2e/x/quality"):
                code = status(mapped, path)
                if code != 400:
                    raise AssertionError(f"[{label}] non-canonical gated path was not refused with 400 (got {code}): {path}")
            print(
                f"PASS [{label}] PUBLIC_READONLY_API='on': {len(reads)} gated reads admitted (502), "
                f"non-GET and {len(siblings)} siblings = 404, dot segments = 400"
            )
        finally:
            subprocess.run(("docker", "rm", "-f", name), capture_output=True)


def prove_readonly_query_lock(
    label: str, config_text: str, container_port: str, snippet_text: str | None = None
) -> None:
    """stage15 readiness: with PUBLIC_READONLY_API=on the gated reads admit
    only the exact query strings the Stage 1.5 build sends.

    Own container, so these requests never share a rate-limit window with
    prove_readonly_gate's (both zones allow 30/min per client).
    """
    name = f"wrf-edge-rq-{uuid.uuid4().hex[:10]}"
    with tempfile.TemporaryDirectory() as directory:
        caddy_dir = Path(directory)
        shutil.copy(EDGE / "downloads.caddy", caddy_dir / "downloads.caddy")
        (caddy_dir / "Caddyfile").write_text(config_text, encoding="utf-8")
        if snippet_text is None:
            shutil.copy(EDGE / "public_onboarding.caddy", caddy_dir / "public_onboarding.caddy")
        else:
            (caddy_dir / "public_onboarding.caddy").write_text(snippet_text, encoding="utf-8")
        try:
            run(
                "docker", "run", "--rm", "-d", "--name", name, "--network", "bridge",
                "--add-host", "wrfcoin-testnet-backend:127.0.0.1",
                "--add-host", "wrfcoin-testnet-frontend:127.0.0.1",
                "-p", f"127.0.0.1::{container_port}", "-e", "ACME_EMAIL=local@example.invalid",
                "-e", "PUBLIC_READONLY_API=on",
                "-v", f"{caddy_dir}:/etc/caddy:ro", IMAGE,
                "caddy", "run", "--config", "/etc/caddy/Caddyfile",
            )
            for _ in range(30):
                mapped = run("docker", "port", name, f"{container_port}/tcp", check=False)
                if mapped:
                    try:
                        if status(mapped, "/api/not-allowed") == 404:
                            break
                    except (subprocess.CalledProcessError, ValueError):
                        pass
                time.sleep(0.2)
            else:
                logs = run("docker", "logs", name, check=False)
                raise AssertionError(f"[{label}] edge did not come up: {logs}")
            for path in READONLY_QUERY_DENIED:
                code = status(mapped, path)
                if code != 404:
                    raise AssertionError(f"[{label}] gated read admitted an unlocked query (got {code}): {path}")
            for path in ("/api/weather/stations", "/api/weather/stations?", "/api/stations/abc/observations?limit=1"):
                code = status(mapped, path)
                if code != 502:
                    raise AssertionError(f"[{label}] exact Stage 1.5 query was not admitted (got {code}): {path}")
            print(
                f"PASS [{label}] PUBLIC_READONLY_API='on': {len(READONLY_QUERY_DENIED)} unlocked queries = 404, "
                "the Stage 1.5 build's exact queries admitted (502)"
            )
        finally:
            subprocess.run(("docker", "rm", "-f", name), capture_output=True)


class _ReadingUpstream:
    """A throwaway backend that READS the request body and answers 200.

    Caddy's request_body cap is enforced as the proxy reads the body, so a missing upstream (502) can never
    show a 413. This one lets the proof see the cap. It binds ONLY the docker bridge gateway address (reachable from
    the edge container, not from the LAN or the loopback), on an ephemeral port, and is torn down after use.
    """

    def __init__(self) -> None:
        self.host = run("docker", "network", "inspect", "bridge", "-f", "{{(index .IPAM.Config 0).Gateway}}")
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self) -> None:  # noqa: N802
                try:
                    remaining = int(self.headers.get("Content-Length") or 0)
                    while remaining > 0:
                        chunk = self.rfile.read(min(65536, remaining))
                        if not chunk:
                            break
                        remaining -= len(chunk)
                except OSError:
                    return
                self.send_response(200)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"ok")

            def log_message(self, *_args: object) -> None:
                pass

        self.server = http.server.ThreadingHTTPServer((self.host, 0), Handler)
        self.server.handle_error = lambda *_args: None  # a refused oversize body breaks the pipe by design
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


def post_status(port: str, path: str, body_bytes: int = 2) -> int:
    """POST a JSON-looking body of exactly `body_bytes` bytes and return the HTTP status."""
    payload = "{" + "x" * max(0, body_bytes - 2) + "}" if body_bytes >= 2 else ""
    result = subprocess.run(
        ["curl", "--path-as-is", "--max-time", "8", "-X", "POST", "-sS", "-o", "/dev/null", "-w", "%{http_code}",
         "-H", "Content-Type: application/json", "--data-binary", "@-", f"http://{port}{path}"],
        input=payload, check=True, text=True, capture_output=True,
    )
    return int(result.stdout.strip())


def prove_station_owner_routes(
    label: str,
    config_text: str,
    container_port: str,
    gate_value: str | None,
    phase: str,
    snippet_text: str | None = None,
) -> None:
    """infra#1095: the owner-action relay and the ownership read, exactly as approved.

    phases "read" and "relay" (gate on, separate containers): the route is admitted (upstream 502), every
    raw-id/odd-alias/query/sibling/method variant is 404, and the relay's 8 KiB cap answers 413
    just above the cap and admits exactly at it. phase "gate": with the gate unset/off the
    READ is 404 while the relay (UNGATED) is still admitted. phase "rate": the relay's own
    zone answers 429 after OWNER_RELAY_RATE_EVENTS requests (own container, own budget).
    Upstreams do not exist, so "admitted" surfaces as the proxy's 502.
    """
    name = f"wrf-edge-so-{uuid.uuid4().hex[:10]}"
    env_args = [] if gate_value is None else ["-e", f"PUBLIC_READONLY_API={gate_value}"]
    upstream_server = _ReadingUpstream() if phase == "relay" else None
    admitted = 200 if upstream_server else 502  # "admitted" = the proxy reached an upstream (200) or tried (502)
    with tempfile.TemporaryDirectory() as directory:
        caddy_dir = Path(directory)
        shutil.copy(EDGE / "downloads.caddy", caddy_dir / "downloads.caddy")
        (caddy_dir / "Caddyfile").write_text(config_text, encoding="utf-8")
        snippet = (EDGE / "public_onboarding.caddy").read_text(encoding="utf-8") if snippet_text is None else snippet_text
        if upstream_server:
            snippet = snippet.replace("wrfcoin-testnet-backend:4001", f"wrfcoin-testnet-backend:{upstream_server.port}")
        (caddy_dir / "public_onboarding.caddy").write_text(snippet, encoding="utf-8")
        try:
            run(
                "docker", "run", "--rm", "-d", "--name", name, "--network", "bridge",
                "--add-host", "wrfcoin-testnet-backend:" + (upstream_server.host if upstream_server else "127.0.0.1"),
                "--add-host", "wrfcoin-testnet-frontend:127.0.0.1",
                "-p", f"127.0.0.1::{container_port}", "-e", "ACME_EMAIL=local@example.invalid",
                *env_args,
                "-v", f"{caddy_dir}:/etc/caddy:ro", IMAGE,
                "caddy", "run", "--config", "/etc/caddy/Caddyfile",
            )
            for _ in range(30):
                mapped = run("docker", "port", name, f"{container_port}/tcp", check=False)
                if mapped:
                    try:
                        if status(mapped, "/api/not-allowed") == 404:
                            break
                    except (subprocess.CalledProcessError, ValueError):
                        pass
                time.sleep(0.2)
            else:
                raise AssertionError(f"[{label}] edge did not come up: {run('docker', 'logs', name, check=False)}")

            if phase == "rate":
                codes = [post_status(mapped, OWNER_RELAY) for _ in range(OWNER_RELAY_RATE_EVENTS + 1)]
                if codes[:OWNER_RELAY_RATE_EVENTS] != [502] * OWNER_RELAY_RATE_EVENTS or codes[-1] != 429:
                    raise AssertionError(
                        f"[{label}] relay rate zone must admit {OWNER_RELAY_RATE_EVENTS} then 429, got {codes}"
                    )
                print(f"PASS [{label}] relay admits {OWNER_RELAY_RATE_EVENTS} POSTs then 429s: {codes}")
                return
            if phase == "gate":
                shown = "unset" if gate_value is None else repr(gate_value)
                code = status(mapped, OWNERSHIP_READ)
                if code != 404:
                    raise AssertionError(f"[{label}] PUBLIC_READONLY_API={shown} admitted the ownership read (got {code})")
                code = post_status(mapped, OWNER_RELAY)
                if code != 502:
                    raise AssertionError(f"[{label}] the UNGATED relay must be admitted regardless of the gate (got {code})")
                print(f"PASS [{label}] PUBLIC_READONLY_API={shown}: ownership read = 404, relay still admitted (502)")
                return

            # The onboarding zone counts /api/weather/stations* at 30/min per client, so the read and the relay
            # are proven in separate containers.
            if phase == "read":
                code = status(mapped, OWNERSHIP_READ)
                if code != 502:
                    raise AssertionError(f"[{label}] PUBLIC_READONLY_API=on did not admit the ownership read (got {code})")
                for method in OWNERSHIP_NON_GET_METHODS:
                    if status(mapped, OWNERSHIP_READ, method) != 404:
                        raise AssertionError(f"[{label}] the ownership read admitted {method}")
                for path in OWNERSHIP_DENIED_PATHS:
                    code = status(mapped, path)
                    if code != 404:
                        raise AssertionError(f"[{label}] ownership read variant was admitted (got {code}): {path}")
                # #1051 still runs first.
                for path in (f"/api/stations/{OWNER_ALIAS}/../abc/ownership", f"/api/stations/{OWNER_ALIAS}/%2e%2e/x/ownership"):
                    code = status(mapped, path)
                    if code != 400:
                        raise AssertionError(f"[{label}] non-canonical path was not refused with 400 (got {code}): {path}")
                print(
                    f"PASS [{label}] ownership read admitted (502); {len(OWNERSHIP_DENIED_PATHS)} variants and "
                    f"{len(OWNERSHIP_NON_GET_METHODS)} wrong methods = 404; dot segments = 400"
                )
                return
            if phase != "relay":
                raise AssertionError(f"unknown phase {phase}")
            code = post_status(mapped, OWNER_RELAY)
            if code != admitted:
                raise AssertionError(f"[{label}] the owner-action relay was not admitted (got {code})")
            for method in OWNER_RELAY_NON_POST_METHODS:
                if status(mapped, OWNER_RELAY, method) != 404:
                    raise AssertionError(f"[{label}] the owner-action relay admitted {method}")
            for path in OWNER_RELAY_DENIED_PATHS:
                code = post_status(mapped, path)
                if code != 404:
                    raise AssertionError(f"[{label}] owner-action relay variant was admitted (got {code}): {path}")
            code = post_status(mapped, OWNER_RELAY, OWNER_RELAY_BODY_CAP)
            if code != admitted:
                raise AssertionError(f"[{label}] a body of exactly the cap must be admitted (got {code})")
            code = post_status(mapped, OWNER_RELAY, OWNER_RELAY_BODY_CAP + 1)
            if code != 413:
                raise AssertionError(f"[{label}] a body one byte over the 8 KiB cap must be 413 at the edge (got {code})")
            code = post_status(mapped, OWNER_RELAY, 1_000_000)
            if code != 413:
                raise AssertionError(f"[{label}] a 1 MB body must be 413 at the edge (got {code})")
            print(
                f"PASS [{label}] relay admitted ({admitted}); {len(OWNER_RELAY_DENIED_PATHS)} variants and "
                f"{len(OWNER_RELAY_NON_POST_METHODS)} wrong methods = 404; body cap {OWNER_RELAY_BODY_CAP}: "
                "at cap admitted, +1 and 1 MB = 413"
            )
        finally:
            subprocess.run(("docker", "rm", "-f", name), capture_output=True)
            if upstream_server:
                upstream_server.close()


def frontend_nginx_image() -> str:
    """The serve-stage base of testnet/Dockerfile.frontend, digest-pinned."""
    text = (ROOT / "testnet" / "Dockerfile.frontend").read_text(encoding="utf-8")
    match = re.search(r"(?m)^FROM (nginx:[^\s]+@sha256:[0-9a-f]{64})\s*$", text)
    if match is None:
        raise AssertionError("Dockerfile.frontend has no digest-pinned nginx serve stage")
    return match.group(1)


def prove_frontend_csp_served(label: str, conf_text: str) -> None:
    """Owner ruling 2026-09-27: the SPA is SERVED with exactly the approved CSP
    (img-src adds only https://tile.openstreetmap.org) on BOTH the document and
    a static asset (the add_header copy in the asset location), one header each.

    Runs the Dockerfile's own pinned nginx with the real config; the backend
    upstream only has to resolve at startup, never answer.
    """
    from verify_public_exposure_boundary import FRONTEND_CSP

    name = f"wrf-fe-csp-{uuid.uuid4().hex[:10]}"
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "html" / "assets").mkdir(parents=True)
        (root / "html" / "index.html").write_text("<!doctype html><title>csp</title>\n", encoding="utf-8")
        (root / "html" / "assets" / "app.js").write_text("void 0;\n", encoding="utf-8")
        (root / "default.conf").write_text(conf_text, encoding="utf-8")
        for path in (root, root / "html", root / "html" / "assets"):
            path.chmod(0o755)
        for path in (root / "default.conf", root / "html" / "index.html", root / "html" / "assets" / "app.js"):
            path.chmod(0o644)
        try:
            run(
                "docker", "run", "--rm", "-d", "--name", name, "--network", "bridge",
                "--add-host", "wrfcoin-backend:127.0.0.1",
                "-p", "127.0.0.1::5000",
                "-v", f"{root / 'default.conf'}:/etc/nginx/conf.d/default.conf:ro",
                "-v", f"{root / 'html'}:/usr/share/nginx/html:ro",
                frontend_nginx_image(),
            )
            for _ in range(50):
                mapped = run("docker", "port", name, "5000/tcp", check=False)
                if mapped:
                    try:
                        if status(mapped, "/") == 200:
                            break
                    except (subprocess.CalledProcessError, ValueError):
                        pass
                time.sleep(0.2)
            else:
                logs = run("docker", "logs", name, check=False)
                raise AssertionError(f"[{label}] frontend nginx did not come up: {logs}")
            for path in ("/", "/assets/app.js", "/map"):
                headers = run("curl", "-sS", "-D", "-", "-o", "/dev/null", "--max-time", "3", f"http://{mapped}{path}")
                values = [line.split(":", 1)[1].strip() for line in headers.splitlines()
                          if line.lower().startswith("content-security-policy:")]
                if values != [FRONTEND_CSP]:
                    raise AssertionError(f"[{label}] {path} served CSP {values!r}, want exactly one approved header")
            print(f"PASS [{label}] frontend nginx serves exactly the approved CSP on /, /map and a static asset")
        finally:
            subprocess.run(("docker", "rm", "-f", name), capture_output=True)


def prove_ingress_gateway_gives_per_client_buckets(config_text: str, container_port: str) -> None:
    """backend#1229: the one trusted hop yields per-visitor buckets.

    Runs the edge on a scratch network pinned to the production wrfcoin-ingress
    subnet (10.251.0.0/24), published on 127.0.0.1 exactly as in compose, so the
    connection peer really is the 10.251.0.1 gateway that docker-proxy uses.
    Each request carries the single X-Forwarded-For entry tailscaled writes.
    Visitor A exhausts faucet_claim; visitor B must still be admitted, and A
    must be refused -- one shared bucket (the pre-#1229 shape) fails the first
    assertion, and an edge that ignored the header would fail it too.
    """
    label = "funnel-edge-ingress-gateway"
    suffix = uuid.uuid4().hex[:10]
    name = f"wrf-edge-gw-{suffix}"
    network = f"wrf-ingress-{suffix}"
    with tempfile.TemporaryDirectory() as directory:
        caddy_dir = Path(directory)
        shutil.copy(EDGE / "downloads.caddy", caddy_dir / "downloads.caddy")
        (caddy_dir / "Caddyfile").write_text(config_text, encoding="utf-8")
        shutil.copy(EDGE / "public_onboarding.caddy", caddy_dir / "public_onboarding.caddy")
        try:
            created = subprocess.run(
                ("docker", "network", "create", "--driver", "bridge",
                 "--subnet", "10.251.0.0/24", "--gateway", "10.251.0.1", network),
                capture_output=True, text=True,
            )
            if created.returncode:
                raise AssertionError(
                    f"[{label}] could not create the pinned 10.251.0.0/24 scratch network "
                    f"(is a wrfcoin-ingress network already up on this host?): {created.stderr.strip()}"
                )
            run(
                "docker", "run", "--rm", "-d", "--name", name, "--network", network,
                "--ip", "10.251.0.12",
                "--add-host", "wrfcoin-testnet-backend:127.0.0.1",
                "--add-host", "wrfcoin-testnet-frontend:127.0.0.1",
                "-p", f"127.0.0.1::{container_port}", "-e", "ACME_EMAIL=local@example.invalid",
                "-v", f"{caddy_dir}:/etc/caddy:ro", IMAGE,
                "caddy", "run", "--config", "/etc/caddy/Caddyfile",
            )
            for _ in range(30):
                mapped = run("docker", "port", name, f"{container_port}/tcp", check=False)
                if mapped:
                    try:
                        if status(mapped, "/api/not-allowed") == 404:
                            break
                    except (subprocess.CalledProcessError, ValueError):
                        pass
                time.sleep(0.2)
            else:
                logs = run("docker", "logs", name, check=False)
                raise AssertionError(f"[{label}] edge did not come up: {logs}")

            claim = lambda visitor: status(
                mapped, "/api/onboarding/faucet/claim", "POST", (f"X-Forwarded-For: {visitor}",)
            )
            visitor_a = [claim("203.0.113.5") for _ in range(8)]
            if 429 not in visitor_a:
                raise AssertionError(f"[{label}] visitor A was never limited: {visitor_a}")
            visitor_b = claim("198.51.100.9")
            if visitor_b == 429:
                raise AssertionError(
                    f"[{label}] visitor B was refused after visitor A exhausted the limit "
                    f"(A: {visitor_a}); the gateway hop's X-Forwarded-For is not keying buckets"
                )
            print(
                f"PASS [{label}] from the pinned 10.251.0.1 gateway, visitor A {visitor_a} "
                f"is limited while visitor B gets {visitor_b}: independent buckets"
            )
        finally:
            subprocess.run(("docker", "rm", "-f", name), capture_output=True)
            subprocess.run(("docker", "network", "rm", network), capture_output=True)


# S1 + S2 website-parity reads (own wallet with Bearer, governance, weather). Each case is
# (method, path, extra curl headers, expected status): 502 = admitted past the edge (no upstream here),
# 404 = the edge allowlist refused it, 400 = the #1051 non-canonical guard.
PARITY_ADDR = "0x" + "a1" * 20
PARITY_BEARER = ("Authorization: Bearer test-session",)
_W = f"/api/wallet/{PARITY_ADDR}"
_T = f"{_W}/transactions"
PARITY_WALLET_CASES = (
    ("GET", _W, PARITY_BEARER, 502),
    ("GET", f"/api/wallet/0x{'A1' * 20}", PARITY_BEARER, 502),
    ("GET", f"{_T}?limit=20&offset=0", PARITY_BEARER, 502),  # exactly what the mobile app sends
    ("GET", f"{_T}?limit=1&offset=0", PARITY_BEARER, 502),
    ("GET", f"{_T}?limit=50&offset=999999", PARITY_BEARER, 502),
    # Missing / wrong credential: never proxied.
    ("GET", _W, (), 404),
    ("GET", _T + "?limit=20&offset=0", (), 404),
    ("GET", _W, ("Authorization: Basic dGVzdDp0ZXN0",), 404),
    ("GET", _W, ("Authorization: bearer lower",), 404),
    ("GET", _W, ("Authorization: Bearer",), 404),
    # Query lock.
    ("GET", _W + "?x=1", PARITY_BEARER, 404),
    ("GET", _T, PARITY_BEARER, 404),
    ("GET", f"{_T}?limit=51&offset=0", PARITY_BEARER, 404),
    ("GET", f"{_T}?limit=100&offset=0", PARITY_BEARER, 404),
    ("GET", f"{_T}?limit=0&offset=0", PARITY_BEARER, 404),
    ("GET", f"{_T}?limit=020&offset=0", PARITY_BEARER, 404),
    ("GET", f"{_T}?limit=20", PARITY_BEARER, 404),
    ("GET", f"{_T}?limit=20&offset=", PARITY_BEARER, 404),
    ("GET", f"{_T}?limit=20&offset=1234567", PARITY_BEARER, 404),
    ("GET", f"{_T}?offset=0&limit=20", PARITY_BEARER, 404),
    ("GET", f"{_T}?limit=20&offset=0&creditLimit=100", PARITY_BEARER, 404),
    ("GET", f"{_T}?limit=20&offset=0&page=2", PARITY_BEARER, 404),
    ("GET", f"{_T}?x=1&limit=20&offset=0", PARITY_BEARER, 404),
    # Address shape, siblings, methods.
    ("GET", f"/api/wallet/0x{'a1' * 19}a", PARITY_BEARER, 404),  # 39 hex
    ("GET", f"/api/wallet/0x{'a1' * 20}b", PARITY_BEARER, 404),  # 41 hex
    ("GET", f"/api/wallet/{'a1' * 20}", PARITY_BEARER, 404),  # no 0x
    ("GET", _W + "/", PARITY_BEARER, 404),
    ("GET", _T + "/", PARITY_BEARER, 404),
    ("GET", _T + "x?limit=20&offset=0", PARITY_BEARER, 404),
    ("GET", _W + "/nonce", PARITY_BEARER, 502),
    ("GET", _W + "/nfts", PARITY_BEARER, 404),
    ("GET", _W + "/data", PARITY_BEARER, 404),
    ("GET", "/api/wallet/send", PARITY_BEARER, 404),
    ("GET", "/api/wallet/mnemonic/generate", PARITY_BEARER, 404),
    ("POST", "/api/wallet/send", PARITY_BEARER, 404),
    ("POST", "/api/wallet/send-private", PARITY_BEARER, 404),
    ("POST", "/api/wallet/estimate-gas", PARITY_BEARER, 404),
    ("POST", "/api/wallet/mnemonic/generate", PARITY_BEARER, 404),
    ("POST", _W, PARITY_BEARER, 404),
    ("POST", _T + "?limit=20&offset=0", PARITY_BEARER, 404),
    ("PUT", _W, PARITY_BEARER, 404),
    ("DELETE", _W, PARITY_BEARER, 404),
    ("GET", f"/api/wallet/x/../{PARITY_ADDR[2:]}", PARITY_BEARER, 400),
    ("GET", f"{_W}/%2e%2e/{PARITY_ADDR}", PARITY_BEARER, 400),
)
_P = "/api/governance/proposals"
PARITY_GOVERNANCE_CASES = (
    ("GET", _P, (), 502),
    ("GET", _P + "?limit=100&offset=0", (), 502),
    ("GET", _P + "?limit=1&offset=999999", (), 502),
    ("GET", _P + "/prop-002", (), 502),
    ("GET", _P + "/Abc_DEF-123", (), 502),
    ("GET", _P + "/" + "a" * 128, (), 502),
    ("GET", "/api/governance/treasury", (), 502),
    ("GET", _P + "?limit=101&offset=0", (), 404),
    ("GET", _P + "?limit=0&offset=0", (), 404),
    ("GET", _P + "?limit=100", (), 404),
    ("GET", _P + "?offset=0&limit=10", (), 404),
    ("GET", _P + "?page=2", (), 404),
    ("GET", _P + "?limit=10&offset=0&x=1", (), 404),
    ("GET", _P + "?x=1", (), 404),
    ("GET", _P + "/", (), 404),
    ("GET", _P + "x", (), 404),
    ("GET", _P + "/" + "a" * 129, (), 404),
    ("GET", _P + "/a.b", (), 404),
    ("GET", _P + "/prop-002?x=1", (), 404),
    ("GET", _P + "/prop-002/votes", (), 404),
    ("GET", _P + "/prop-002/vote", (), 404),
    ("GET", _P + "/prop-002/activate", (), 404),
    ("GET", "/api/governance/treasury?x=1", (), 404),
    ("GET", "/api/governance/treasury/", (), 404),
    ("GET", "/api/governance/treasury/transactions", (), 404),
    ("GET", "/api/governance/delegations", (), 404),
    ("GET", "/api/governance/delegate", (), 404),
    ("GET", "/api/governance/status", (), 404),
    ("GET", "/api/governance/analytics", (), 404),
    ("POST", _P, (), 404),
    ("POST", _P + "/prop-002", (), 404),
    ("POST", _P + "/prop-002/vote", (), 404),
    ("PUT", _P + "/prop-002/activate", (), 404),
    ("POST", "/api/governance/treasury", (), 404),
    ("DELETE", _P + "/prop-002", (), 404),
    ("GET", "/api/governance/x/../proposals", (), 400),
)
_C = "/api/weather/current"
_F = "/api/weather/forecast"
PARITY_WEATHER_CASES = (
    ("GET", f"{_C}/47.6,-122.3", (), 502),
    ("GET", f"{_C}/-33.9,151.2", (), 502),
    ("GET", f"{_C}/0.0,-0.0", (), 502),
    ("GET", f"{_C}/47.6%2C-122.3", (), 502),  # encoded comma decodes to the same cell
    ("GET", f"{_F}/47.6,-122.3?type=hourly&days=1", (), 502),
    ("GET", f"{_F}/47.6,-122.3?days=14", (), 502),
    ("GET", f"{_C}/47.65,-122.3", (), 404),  # two decimals
    ("GET", f"{_C}/47.6,-122.35", (), 404),
    ("GET", f"{_C}/47,-122.3", (), 404),  # no decimal
    ("GET", f"{_C}/47.6,-122", (), 404),
    ("GET", f"{_C}/147.6,-122.3", (), 404),  # 3-digit latitude
    ("GET", f"{_C}/47.6,-1222.3", (), 404),
    ("GET", f"{_C}/+47.6,-122.3", (), 404),
    ("GET", f"{_C}/47.6e0,-122.3", (), 404),
    ("GET", f"{_C}/47.6,-122.3/", (), 404),
    ("GET", f"{_C}/47.6,-122.3/x", (), 404),
    ("GET", f"{_C}/abc", (), 404),
    ("GET", _C, (), 404),
    ("GET", f"{_C}/47.6,-122.3?lat=1.0&lng=2.0", (), 404),  # query coordinates would override the path
    ("GET", f"{_C}/47.6,-122.3?x=1", (), 404),
    ("GET", f"{_F}/47.6,-122.3", (), 404),
    ("GET", f"{_F}/47.6,-122.3?days=7", (), 404),
    ("GET", f"{_F}/47.6,-122.3?days=014", (), 404),
    ("GET", f"{_F}/47.6,-122.3?type=hourly&days=2", (), 404),
    ("GET", f"{_F}/47.6,-122.3?days=14&type=hourly", (), 404),
    ("GET", f"{_F}/47.6,-122.3?days=14&unit=days", (), 404),
    ("GET", f"{_F}/47.6,-122.3?type=daily&days=14", (), 404),
    ("GET", f"{_F}/47.65,-122.3?days=14", (), 404),
    ("GET", f"{_F}/47.6,-122.3?lat=1.0&lng=2.0&days=14", (), 404),
    ("POST", f"{_C}/47.6,-122.3", (), 404),
    ("POST", f"{_F}/47.6,-122.3?days=14", (), 404),
    ("GET", "/api/weather/data/47.6,-122.3", (), 404),
    ("GET", "/api/weather/historical/47.6,-122.3", (), 404),
    ("GET", "/api/weather/providers", (), 404),
    ("GET", "/api/weather/alerts/47.6,-122.3", (), 404),
    ("GET", "/api/weather/x/../current/47.6,-122.3", (), 400),
)

# Public forecaster pages (frontend forecastersPath/forecasterPath) and the mobile explorer summary.
_FC = "/api/forecasters"
_FK = "c_0123456789abcdef01234567"
_XS = "/api/explorer/summary"
FORECASTER_EXPLORER_CASES = (
    ("GET", _FC + "?period=7d&limit=25", (), 502),  # exactly what PublicForecastersPage sends
    ("GET", _FC + "?period=30d&limit=100", (), 502),
    ("GET", _FC + "?period=all&limit=1", (), 502),
    ("GET", f"{_FC}/{_FK}", (), 502),
    ("GET", _XS, (), 502),  # exactly what the mobile explorer sends
    ("GET", _FC, (), 404),
    ("GET", _FC + "?period=7d", (), 404),
    ("GET", _FC + "?limit=25&period=7d", (), 404),
    ("GET", _FC + "?period=7d&limit=0", (), 404),
    ("GET", _FC + "?period=7d&limit=101", (), 404),
    ("GET", _FC + "?period=7d&limit=025", (), 404),
    ("GET", _FC + "?period=1y&limit=25", (), 404),
    ("GET", _FC + "?period=7d&limit=25&x=1", (), 404),
    ("GET", _FC + "/", (), 404),
    ("GET", f"{_FC}/0x{'a' * 40}", (), 404),  # raw address lookups never reach the backend
    ("GET", f"{_FC}/c_{'A' * 24}", (), 404),
    ("GET", f"{_FC}/c_{'a' * 23}", (), 404),
    ("GET", f"{_FC}/{_FK}?x=1", (), 404),
    ("GET", f"{_FC}/{_FK}/x", (), 404),
    ("GET", _XS + "?x=1", (), 404),
    ("GET", _XS + "/", (), 404),
    ("GET", "/api/explorer", (), 404),
    ("GET", "/api/explorer/blocks", (), 404),
    ("POST", _FC + "?period=7d&limit=25", (), 404),
    ("POST", _XS, (), 404),
    ("DELETE", f"{_FC}/{_FK}", (), 404),
    ("GET", f"{_FC}/x/../{_FK}", (), 400),
)

# Proof card for one station reading (backend#229; frontend proofCardPath).
_PC = "/api/proofs"
_PK = "c0" * 32
PROOF_CARD_CASES = (
    ("GET", f"{_PC}/{_PK}", (), 502),  # what the station page link sends without a height
    ("GET", f"{_PC}/{_PK}?h=4890", (), 502),  # what a share link sends
    ("GET", f"{_PC}/{_PK}?h=1", (), 502),
    ("GET", f"{_PC}/{_PK}?h=999999999999", (), 502),
    ("GET", f"{_PC}/{_PK}?h=0", (), 404),
    ("GET", f"{_PC}/{_PK}?h=04890", (), 404),
    ("GET", f"{_PC}/{_PK}?h=1234567890123", (), 404),
    ("GET", f"{_PC}/{_PK}?h=", (), 404),
    ("GET", f"{_PC}/{_PK}?h=1&x=1", (), 404),
    ("GET", f"{_PC}/{_PK}?x=1", (), 404),
    ("GET", f"{_PC}/{_PK.upper()}", (), 404),
    ("GET", f"{_PC}/0x{_PK}", (), 404),
    ("GET", f"{_PC}/{_PK[:-1]}", (), 404),
    ("GET", f"{_PC}/{_PK}/badge.svg", (), 404),
    ("GET", f"{_PC}/{_PK}/", (), 404),
    ("GET", _PC, (), 404),
    ("GET", _PC + "/", (), 404),
    ("POST", f"{_PC}/{_PK}", (), 404),
    ("DELETE", f"{_PC}/{_PK}", (), 404),
    ("GET", f"{_PC}/x/../{_PK}", (), 400),
)

# Producers and bonded nodes page (frontend NETWORK_NODES_PATH).
_NN = "/api/network/nodes"
NETWORK_NODES_CASES = (
    ("GET", _NN, (), 502),  # exactly what the /nodes page sends
    ("GET", _NN + "?x=1", (), 404),
    ("GET", _NN + "/", (), 404),
    ("GET", _NN + "/extra", (), 404),
    ("GET", "/api/network", (), 404),
    ("GET", "/api/network/info", (), 404),
    ("GET", "/api/network/peers", (), 404),
    ("POST", _NN, (), 404),
    ("DELETE", _NN, (), 404),
    ("GET", "/api/network/x/../nodes", (), 400),
)

# Owner ruling 2026-11-01: bring-your-own-key Wolfram reading check. POST + application/json only,
# exact path, no query (the caller's AppID rides in the body, never in a logged URL).
_WR = "/api/integrations/wolfram/reading-check"
_JSON = ("Content-Type: application/json",)
WOLFRAM_READING_CHECK_CASES = (
    ("POST", _WR, _JSON, 502),  # exactly what the station page sends
    ("POST", _WR, (), 404),
    ("POST", _WR, ("Content-Type: text/plain",), 404),
    ("POST", _WR + "?appid=x", _JSON, 404),
    ("POST", _WR + "/", _JSON, 404),
    ("POST", "/api/integrations/wolfram/query", _JSON, 404),
    ("POST", "/api/integrations/wolfram/execute", _JSON, 404),
    ("GET", "/api/integrations/wolfram/settings", (), 404),
    ("GET", _WR, (), 404),
    ("PUT", _WR, _JSON, 404),
    ("POST", "/api/integrations/x/../wolfram/reading-check", _JSON, 400),
)
# Station calibration certificate status (core4#388/#435; frontend CalibrationService). Alias only,
# no query; the signed submit/revoke POSTs never pass the edge.
_CC = "/api/calibration-certificates"
_CA = "st_7d29a4c1e0b8"
CALIBRATION_CASES = (
    ("GET", f"{_CC}/station/{_CA}", (), 502),  # what the station page sends
    ("GET", f"{_CC}/station/st_000000000000", (), 502),
    ("GET", f"{_CC}/station/{_CA}?x=1", (), 404),
    ("GET", f"{_CC}/station/{_CA.upper()}", (), 404),
    ("GET", f"{_CC}/station/{_CA}0", (), 404),
    ("GET", f"{_CC}/station/{_CA[:-1]}", (), 404),
    ("GET", f"{_CC}/station/PWS-DULUTH-JANEDOE-01", (), 404),  # a raw station id never matches
    ("GET", f"{_CC}/station/{_CA}/", (), 404),
    ("GET", f"{_CC}/station/{_CA}/history", (), 404),
    ("GET", f"{_CC}/station", (), 404),
    ("GET", _CC, (), 404),
    ("POST", _CC, (), 404),  # submit stays on the operator network
    ("POST", f"{_CC}/revocations", (), 404),
    ("POST", f"{_CC}/station/{_CA}", (), 404),
    ("DELETE", f"{_CC}/station/{_CA}", (), 404),
    ("GET", f"{_CC}/x/../station/{_CA}", (), 400),
)


# Weekly forecast competition (backend#251; frontend COMPETITIONS_PATH / competitionWeekPath).
_CP = "/api/competitions"
COMPETITION_CASES = (
    ("GET", _CP, (), 502),
    ("GET", f"{_CP}/current", (), 502),
    ("GET", f"{_CP}/2026-W45", (), 502),
    ("GET", f"{_CP}/2026-W01", (), 502),
    ("GET", f"{_CP}/2026-W53", (), 502),
    ("GET", f"{_CP}/2026-W54", (), 404),
    ("GET", f"{_CP}/2026-W00", (), 404),
    ("GET", f"{_CP}/2026-w45", (), 404),
    ("GET", f"{_CP}/2026-W5", (), 404),
    ("GET", f"{_CP}/", (), 404),
    ("GET", f"{_CP}/current/", (), 404),
    ("GET", f"{_CP}/abc/leaderboard", (), 404),
    ("GET", f"{_CP}?limit=5", (), 404),
    ("GET", f"{_CP}/current?limit=5", (), 404),
    ("POST", _CP, (), 404),
    ("DELETE", f"{_CP}/2026-W45", (), 404),
    ("GET", f"{_CP}/x/../current", (), 400),
)

# Payout notifications (backend#389): config public; Bearer for subscription routes; JSON for bodies.
_N = "/api/notifications"
_NID = "0b0b0b0b-1c1c-4d4d-8e8e-9f9f9f9f9f9f"
_NADDR = "0x" + "a1" * 20
_BJ = PARITY_BEARER + _JSON
NOTIFICATION_CASES = (
    ("GET", f"{_N}/config", (), 502),
    ("POST", f"{_N}/subscriptions", _BJ, 502),
    ("GET", f"{_N}/subscriptions/{_NADDR}", PARITY_BEARER, 502),
    ("DELETE", f"{_N}/subscriptions/{_NID}", PARITY_BEARER, 502),
    ("POST", f"{_N}/subscriptions/{_NID}/test", PARITY_BEARER, 502),
    ("POST", f"{_N}/unsubscribe", _JSON, 502),
    # Bearer missing: never proxied.
    ("POST", f"{_N}/subscriptions", _JSON, 404),
    ("GET", f"{_N}/subscriptions/{_NADDR}", (), 404),
    ("DELETE", f"{_N}/subscriptions/{_NID}", (), 404),
    ("POST", f"{_N}/subscriptions/{_NID}/test", (), 404),
    # Wrong content type, method, shape or query.
    ("POST", f"{_N}/subscriptions", PARITY_BEARER + ("Content-Type: text/plain",), 404),
    ("POST", f"{_N}/unsubscribe", (), 404),
    ("GET", f"{_N}/config?x=1", (), 404),
    ("POST", f"{_N}/config", _JSON, 404),
    ("GET", f"{_N}/subscriptions", PARITY_BEARER, 404),
    ("GET", f"{_N}/subscriptions/{_NADDR[:-1]}", PARITY_BEARER, 404),
    ("DELETE", f"{_N}/subscriptions/{_NID.upper()}", PARITY_BEARER, 404),
    ("DELETE", f"{_N}/subscriptions/{_NADDR}", PARITY_BEARER, 404),
    ("GET", f"{_N}/subscriptions/{_NID}/test", PARITY_BEARER, 404),
    ("POST", f"{_N}/subscriptions?x=1", _BJ, 404),
    ("POST", f"{_N}/webhooks", _BJ, 404),
    ("GET", f"{_N}/x/../config", (), 400),
)

# Demo items 7, 8 and 10 (forecast check, friend challenges, free-play duels): exactly what the
# frontend publicReadonlyApi.ts / walletApi.ts and the phone's ApiConstants send.
_FV = "/api/forecast-verification"
_CK = "c0" * 32
FORECAST_CHECK_CASES = (
    ("GET", f"{_FV}/summary", (), 502),
    ("GET", f"{_FV}/forecasts/{_CK}", (), 502),
    ("POST", f"{_FV}/forecasts", _JSON, 502),  # no bearer: the record proves itself
    ("GET", f"{_FV}/summary?x=1", (), 404),
    ("GET", f"{_FV}/forecasts/{_CK.upper()}", (), 404),
    ("GET", f"{_FV}/forecasts/{_CK[:-1]}", (), 404),
    ("GET", f"{_FV}/forecasts", (), 404),
    ("POST", f"{_FV}/forecasts", (), 404),  # JSON only
    ("POST", f"{_FV}/forecasts?x=1", _JSON, 404),
    ("POST", f"{_FV}/forecasts/{_CK}", _JSON, 404),
    ("POST", f"{_FV}/compute/forecast/verify", _JSON, 404),  # the gridded bearer POST stays off the edge
    ("PUT", f"{_FV}/forecasts", _JSON, 404),
    ("GET", f"{_FV}/x/../summary", (), 400),
)
_CH = "/api/challenges"
CHALLENGE_CASES = (
    ("GET", f"{_CH}/code/RAIN-7K2Q", (), 502),
    ("GET", _CH, PARITY_BEARER, 502),
    ("POST", _CH, _BJ, 502),
    ("POST", f"{_CH}/join", _BJ, 502),
    ("POST", f"{_CH}/sync", _BJ, 502),
    ("GET", _CH, (), 404),  # the caller's list needs the wallet bearer
    ("POST", _CH, _JSON, 404),
    ("POST", f"{_CH}/join", PARITY_BEARER, 404),  # JSON only
    ("GET", f"{_CH}/code/rain-7k2q", (), 404),
    ("GET", f"{_CH}/code/RAIN7K2Q", (), 404),
    ("GET", f"{_CH}/code/RAIN-7K2Q?x=1", (), 404),
    ("GET", f"{_CH}/active", (), 404),  # the 2026-04 routes stay unreachable
    ("POST", f"{_CH}/x/claim", _BJ, 404),
    ("POST", f"{_CH}/leave", _BJ, 404),
    ("DELETE", _CH, PARITY_BEARER, 404),
    ("GET", f"{_CH}/x/../code/RAIN-7K2Q", (), 400),
)
_DU = "/api/duels"
_DID = "6f1d2c4e-8a8b-4c1e-9d6a-1f2e3d4c5b6a"
DUEL_CASES = (
    ("GET", _DU, (), 502),
    ("GET", f"{_DU}/{_DID}", (), 502),
    ("GET", f"{_DU}/mine", PARITY_BEARER, 502),
    ("POST", _DU, _BJ, 502),
    ("POST", f"{_DU}/{_DID}/accept", _BJ, 502),
    ("POST", f"{_DU}/{_DID}/forecast", _BJ, 502),
    ("POST", f"{_DU}/{_DID}/record", _JSON, 502),  # no bearer: the record proves itself
    ("GET", f"{_DU}/mine", (), 404),
    ("POST", f"{_DU}/{_DID}/accept", _JSON, 404),
    ("POST", _DU, PARITY_BEARER, 404),
    ("GET", f"{_DU}/{_DID.upper()}", (), 404),
    ("GET", f"{_DU}/not-a-uuid", (), 404),
    ("GET", f"{_DU}?x=1", (), 404),
    ("POST", f"{_DU}/create", _BJ, 404),  # the 2026-04 stake routes stay unreachable
    ("POST", f"{_DU}/{_DID}/join", _BJ, 404),
    ("GET", f"{_DU}/{_DID}/result", (), 404),
    ("POST", f"{_DU}/{_DID}/resolve", _BJ, 404),
    ("GET", f"{_DU}/x/../{_DID}", (), 400),
)

# Passkey-wallet payout notifications (backend feat/passkey-payout-subscribe): no JWT, so no Bearer; the
# body carries a WebAuthn assertion over a single-use nonce. JSON only, exact paths, no query.
_NP = f"{_N}/passkey"
PASSKEY_NOTIFICATION_CASES = (
    ("POST", f"{_NP}/challenge", _JSON, 502),
    ("POST", f"{_NP}/subscriptions", _JSON, 502),
    ("POST", f"{_NP}/unsubscribe", _JSON, 502),
    # A stray Bearer header neither helps nor hurts.
    ("POST", f"{_NP}/subscriptions", _BJ, 502),
    # Content-Type missing or wrong: never proxied.
    ("POST", f"{_NP}/challenge", (), 404),
    ("POST", f"{_NP}/subscriptions", (), 404),
    ("POST", f"{_NP}/unsubscribe", ("Content-Type: text/plain",), 404),
    # Wrong method, shape or query.
    ("GET", f"{_NP}/challenge", (), 404),
    ("GET", f"{_NP}/subscriptions", (), 404),
    ("DELETE", f"{_NP}/subscriptions", _JSON, 404),
    ("POST", f"{_NP}/challenge?address=0x00", _JSON, 404),
    ("POST", f"{_NP}/subscriptions?x=1", _JSON, 404),
    ("POST", f"{_NP}/subscriptions/{_NID}", _JSON, 404),
    ("POST", f"{_NP}/challenge/", _JSON, 404),
    ("POST", f"{_NP}", _JSON, 404),
    ("POST", f"{_NP}/test", _JSON, 404),
    ("POST", f"{_NP}/x/../challenge", _JSON, 400),
)


def prove_parity_reads(
    label: str, config_text: str, container_port: str, gate_value: str | None, cases: tuple, budget: int,
    snippet_text: str | None = None,
) -> None:
    """S1 + S2: every case answers exactly its expected status, in as many throwaway edges as the
    per-client rate budget needs (rate-limit matching counts refused requests too). With the gate
    unset or not exactly `on`, every admitted case must be a 404 instead."""
    chunks = [cases[i:i + budget] for i in range(0, len(cases), budget)]
    for index, chunk in enumerate(chunks):
        name = f"wrf-edge-parity-{uuid.uuid4().hex[:10]}"
        env_args = [] if gate_value is None else ["-e", f"PUBLIC_READONLY_API={gate_value}"]
        with tempfile.TemporaryDirectory() as directory:
            caddy_dir = Path(directory)
            shutil.copy(EDGE / "downloads.caddy", caddy_dir / "downloads.caddy")
            (caddy_dir / "Caddyfile").write_text(config_text, encoding="utf-8")
            if snippet_text is None:
                shutil.copy(EDGE / "public_onboarding.caddy", caddy_dir / "public_onboarding.caddy")
            else:
                (caddy_dir / "public_onboarding.caddy").write_text(snippet_text, encoding="utf-8")
            try:
                run(
                    "docker", "run", "--rm", "-d", "--name", name, "--network", "bridge",
                    "--add-host", "wrfcoin-testnet-backend:127.0.0.1",
                    "--add-host", "wrfcoin-testnet-frontend:127.0.0.1",
                    "-p", f"127.0.0.1::{container_port}", "-e", "ACME_EMAIL=local@example.invalid",
                    *env_args,
                    "-v", f"{caddy_dir}:/etc/caddy:ro", IMAGE,
                    "caddy", "run", "--config", "/etc/caddy/Caddyfile",
                )
                for _ in range(30):
                    mapped = run("docker", "port", name, f"{container_port}/tcp", check=False)
                    if mapped:
                        try:
                            # /api/not-allowed is in no rate zone, so probing does not spend the budget.
                            if status(mapped, "/api/not-allowed") == 404:
                                break
                        except (subprocess.CalledProcessError, ValueError):
                            pass
                    time.sleep(0.2)
                else:
                    raise AssertionError(f"[{label}] edge did not come up: {run('docker', 'logs', name, check=False)}")
                for method, path, headers, expected in chunk:
                    want = expected if gate_value == "on" or expected != 502 else 404
                    got = status(mapped, path, method, headers)
                    if got != want:
                        raise AssertionError(
                            f"[{label}] PUBLIC_READONLY_API={gate_value!r}: {method} {path} "
                            f"headers={list(headers)} expected {want}, got {got}"
                        )
            finally:
                subprocess.run(("docker", "rm", "-f", name), capture_output=True)
    print(f"PASS [{label}] PUBLIC_READONLY_API={gate_value!r}: {len(cases)} cases in {len(chunks)} edge(s)")


def prove_weather_noaa_zone(label: str, config_text: str, container_port: str) -> None:
    """S2b: the weather_noaa zone admits 10 reads per client per minute and then 429s, and spends
    none of public_read's budget (a wallet read still answers afterwards)."""
    name = f"wrf-edge-wz-{uuid.uuid4().hex[:10]}"
    with tempfile.TemporaryDirectory() as directory:
        caddy_dir = Path(directory)
        shutil.copy(EDGE / "downloads.caddy", caddy_dir / "downloads.caddy")
        (caddy_dir / "Caddyfile").write_text(config_text, encoding="utf-8")
        shutil.copy(EDGE / "public_onboarding.caddy", caddy_dir / "public_onboarding.caddy")
        try:
            run(
                "docker", "run", "--rm", "-d", "--name", name, "--network", "bridge",
                "--add-host", "wrfcoin-testnet-backend:127.0.0.1",
                "--add-host", "wrfcoin-testnet-frontend:127.0.0.1",
                "-p", f"127.0.0.1::{container_port}", "-e", "ACME_EMAIL=local@example.invalid",
                "-e", "PUBLIC_READONLY_API=on",
                "-v", f"{caddy_dir}:/etc/caddy:ro", IMAGE,
                "caddy", "run", "--config", "/etc/caddy/Caddyfile",
            )
            for _ in range(30):
                mapped = run("docker", "port", name, f"{container_port}/tcp", check=False)
                if mapped:
                    try:
                        if status(mapped, "/api/not-allowed") == 404:
                            break
                    except (subprocess.CalledProcessError, ValueError):
                        pass
                time.sleep(0.2)
            else:
                raise AssertionError(f"[{label}] edge did not come up")
            codes = [status(mapped, f"{_C}/47.6,-122.3") for _ in range(11)]
            if codes[:10] != [502] * 10 or codes[10] != 429:
                raise AssertionError(f"[{label}] weather_noaa must admit 10 then 429, got {codes}")
            forecast = status(mapped, f"{_F}/47.6,-122.3?days=14")
            if forecast != 429:
                raise AssertionError(f"[{label}] current and forecast must share one budget, forecast got {forecast}")
            other = status(mapped, "/api/governance/treasury")
            if other != 502:
                raise AssertionError(f"[{label}] weather_noaa must not spend public_read budget, got {other}")
            print(f"PASS [{label}] weather_noaa admits 10 per minute then 429s: {codes}")
        finally:
            subprocess.run(("docker", "rm", "-f", name), capture_output=True)



def main() -> None:
    if subprocess.run(("docker", "image", "inspect", IMAGE), capture_output=True).returncode:
        raise SystemExit(f"missing {IMAGE}; build it locally first (never push it)")

    # backend#1481: run the new exact earnings/profile admission proof in the
    # existing CI consumer, including real validate/request/limiter RED controls.
    from verify_earnings_edge_runtime import main as prove_earnings
    prove_earnings()

    # Phase 1: the direct edge, with both public hostnames turned into
    # unencrypted local-only listeners.
    config = (EDGE / "Caddyfile").read_text(encoding="utf-8")
    config = re.sub(r"(?m)^\{\$WRFCOIN_PUBLIC_DOMAIN\}\s*\{", ":8080 {", config)
    config = re.sub(r"(?m)^api\.\{\$WRFCOIN_PUBLIC_DOMAIN\}\s*\{", ":8081 {", config)
    prove_edge("direct-edge", config, "8080")
    prove_noncanonical_refused("direct-edge", config, "8080")

    # Phase 2: the funnel edge, byte-identical to what ships — it already
    # listens on plain :8444 with auto_https off.
    prove_edge("funnel-edge", (EDGE / "Caddyfile.funnel").read_text(encoding="utf-8"), "8444")
    prove_noncanonical_refused("funnel-edge", (EDGE / "Caddyfile.funnel").read_text(encoding="utf-8"), "8444")

    # Phase 2b (infra#983): the Stage 1.5 station reads are inert unless the
    # edge env is exactly `on` — on both edges, the funnel one as shipped.
    funnel_text = (EDGE / "Caddyfile.funnel").read_text(encoding="utf-8")
    for value in READONLY_GATE_OFF_VALUES:
        prove_readonly_gate("funnel-edge-readonly", funnel_text, "8444", value)
    prove_readonly_gate("funnel-edge-readonly", funnel_text, "8444", "on")
    prove_readonly_gate("direct-edge-readonly", config, "8080", None)
    prove_readonly_gate("direct-edge-readonly", config, "8080", "on")
    # backend#1232: the earnings read, same gate, in its own container (own rate-limit budget).
    for value in READONLY_GATE_OFF_VALUES:
        prove_readonly_gate("funnel-edge-earnings", funnel_text, "8444", value, reads=READONLY_EARNINGS_READS)
    for label, text, port in (("funnel-edge-earnings", funnel_text, "8444"), ("direct-edge-earnings", config, "8080")):
        prove_readonly_gate(
            label, text, port, "on", reads=READONLY_EARNINGS_READS,
            siblings=READONLY_EARNINGS_SIBLINGS_DENIED, query_denied=READONLY_EARNINGS_QUERY_DENIED, non_get_from=0,
            non_get_methods=READONLY_EARNINGS_NON_GET_METHODS, non_get_paths=1,
        )
    prove_readonly_gate("direct-edge-earnings", config, "8080", None, reads=READONLY_EARNINGS_READS)
    # backend#1456: the leaderboard. Container 1 proves toggle-off, admitted shapes, non-GET and siblings;
    # container 2 (own rate-limit budget) proves the query lock refuses every denied shape.
    for value in READONLY_GATE_OFF_VALUES:
        prove_readonly_gate("funnel-edge-leaderboard", funnel_text, "8444", value, reads=READONLY_LEADERBOARD_READS)
    for label, text, port in (("funnel-edge-leaderboard", funnel_text, "8444"), ("direct-edge-leaderboard", config, "8080")):
        prove_readonly_gate(
            label, text, port, "on", reads=READONLY_LEADERBOARD_READS,
            siblings=READONLY_LEADERBOARD_SIBLINGS_DENIED, non_get_from=0,
            non_get_methods=READONLY_LEADERBOARD_NON_GET_METHODS, non_get_paths=1,
        )
        half = len(READONLY_LEADERBOARD_QUERY_DENIED) // 2  # 30/min/client budget: two containers
        for part, denied in enumerate((READONLY_LEADERBOARD_QUERY_DENIED[:half], READONLY_LEADERBOARD_QUERY_DENIED[half:])):
            prove_readonly_gate(
                f"{label}-query-lock-{part}", text, port, "on", reads=READONLY_LEADERBOARD_READS[:1],
                query_denied=denied, non_get_from=0, non_get_methods=(), non_get_paths=0,
            )
    prove_readonly_gate("direct-edge-leaderboard", config, "8080", None, reads=READONLY_LEADERBOARD_READS)
    prove_readonly_query_lock("funnel-edge-query-lock", funnel_text, "8444")
    prove_readonly_query_lock("direct-edge-query-lock", config, "8080")

    # S1 + S2 (website parity): own-wallet (Bearer) + governance + weather reads. Gate-off proof on both
    # edges, then the full positive/negative matrix with the gate on.
    for label, text, port in (("funnel-edge-parity", funnel_text, "8444"), ("direct-edge-parity", config, "8080")):
        for value in (None, "off", "ON", "true"):
            prove_parity_reads(
                f"{label}-wallet-gate", text, port, value, PARITY_WALLET_CASES[:5] + PARITY_GOVERNANCE_CASES[:7], 24
            )
        prove_parity_reads(f"{label}-wallet", text, port, "on", PARITY_WALLET_CASES, 24)
        prove_parity_reads(f"{label}-governance", text, port, "on", PARITY_GOVERNANCE_CASES, 24)
        prove_parity_reads(f"{label}-weather-gate", text, port, None, PARITY_WEATHER_CASES[:6], 8)
        prove_parity_reads(f"{label}-weather", text, port, "on", PARITY_WEATHER_CASES, 8)
        prove_weather_noaa_zone(f"{label}-weather-zone", text, port)
        prove_parity_reads(f"{label}-forecasters-gate", text, port, None, FORECASTER_EXPLORER_CASES[:5], 24)
        prove_parity_reads(f"{label}-forecasters", text, port, "on", FORECASTER_EXPLORER_CASES, 24)
        prove_parity_reads(f"{label}-proof-card-gate", text, port, None, PROOF_CARD_CASES[:4], 16)
        prove_parity_reads(f"{label}-proof-card", text, port, "on", PROOF_CARD_CASES, 16)
        prove_parity_reads(f"{label}-network-nodes-gate", text, port, None, NETWORK_NODES_CASES[:1], 12)
        prove_parity_reads(f"{label}-network-nodes", text, port, "on", NETWORK_NODES_CASES, 12)
        prove_parity_reads(f"{label}-wolfram-gate", text, port, None, WOLFRAM_READING_CHECK_CASES[:1], 6)
        prove_parity_reads(f"{label}-wolfram", text, port, "on", WOLFRAM_READING_CHECK_CASES, 6)
        prove_parity_reads(f"{label}-competitions-gate", text, port, None, COMPETITION_CASES[:5], 16)
        prove_parity_reads(f"{label}-competitions", text, port, "on", COMPETITION_CASES, 16)
        # notify_write counts every request on the subscription paths (10/min): small chunks.
        prove_parity_reads(f"{label}-notifications-gate", text, port, None, NOTIFICATION_CASES[:6], 8)
        prove_parity_reads(f"{label}-notifications", text, port, "on", NOTIFICATION_CASES, 8)
        prove_parity_reads(f"{label}-passkey-notifications-gate", text, port, None, PASSKEY_NOTIFICATION_CASES[:4], 8)
        prove_parity_reads(f"{label}-passkey-notifications", text, port, "on", PASSKEY_NOTIFICATION_CASES, 8)
        prove_parity_reads(f"{label}-calibration-gate", text, port, None, CALIBRATION_CASES[:2], 16)
        prove_parity_reads(f"{label}-calibration", text, port, "on", CALIBRATION_CASES, 16)
        prove_parity_reads(f"{label}-forecast-check-gate", text, port, None, FORECAST_CHECK_CASES[:3], 12)
        prove_parity_reads(f"{label}-forecast-check", text, port, "on", FORECAST_CHECK_CASES, 16)
        prove_parity_reads(f"{label}-challenges-gate", text, port, None, CHALLENGE_CASES[:5], 12)
        prove_parity_reads(f"{label}-challenges", text, port, "on", CHALLENGE_CASES, 16)
        prove_parity_reads(f"{label}-duels-gate", text, port, None, DUEL_CASES[:7], 12)
        prove_parity_reads(f"{label}-duels", text, port, "on", DUEL_CASES, 16)

    # S1 + S2 RED controls: each loosening MUST fail the parity proof; if it passes, the cases are vacuous.
    caddy_src = (EDGE / "public_onboarding.caddy").read_text(encoding="utf-8")
    parity_mutants = {
        "bearer requirement removed": (
            caddy_src.replace('\t\theader Authorization "Bearer *"\n', ""), PARITY_WALLET_CASES,
        ),
        "wallet transactions query lock removed": (
            re.sub(r"(?m)^\t\texpression `\{query\}\.matches\('\^limit=\(\[1-9\]\|\[1-4\]\[0-9\]\|50\)[^\n]*`\n", "", caddy_src),
            PARITY_WALLET_CASES,
        ),
        "forecast query lock removed": (
            caddy_src.replace(' || {query} == "days=14"`', ' || {query} == "days=14" || {query} != "zz"`'),
            PARITY_WEATHER_CASES,
        ),
        "weather coordinates widened to two decimals": (
            caddy_src.replace("current/-?[0-9]{1,2}\\.[0-9],", "current/-?[0-9]{1,2}\\.[0-9]+,"), PARITY_WEATHER_CASES,
        ),
        "wolfram reading check widened to the integrations prefix": (
            caddy_src.replace("path /api/integrations/wolfram/reading-check\n\t\tvars", "path /api/integrations/*\n\t\tvars"),
            WOLFRAM_READING_CHECK_CASES,
        ),
        "forecaster profile widened to any segment": (
            caddy_src.replace("^/api/forecasters/c_[0-9a-f]{24}$", "^/api/forecasters/[^/]+$"), FORECASTER_EXPLORER_CASES,
        ),
        "network nodes widened to the network prefix": (
            caddy_src.replace("path /api/network/nodes\n", "path /api/network/*\n"), NETWORK_NODES_CASES,
        ),
        "challenge board widened to any segment": (
            caddy_src.replace("^/api/challenges/code/[A-Z0-9]{4}-[A-Z0-9]{4}$", "^/api/challenges/code/[^/]+$"), CHALLENGE_CASES,
        ),
        "duel writes widened to any action": (
            caddy_src.replace("/(accept|forecast))?$", "/[a-z]+)?$"), DUEL_CASES,
        ),
        "forecast check hand-in admitted without JSON": (
            caddy_src.replace("path /api/forecast-verification/forecasts\n\t\tvars {env.PUBLIC_READONLY_API} on\n\t\texpression `{query} == \"\"`\n\t\theader Content-Type application/json\n",
                              "path /api/forecast-verification/forecasts\n\t\tvars {env.PUBLIC_READONLY_API} on\n\t\texpression `{query} == \"\"`\n"),
            FORECAST_CHECK_CASES,
        ),
        "proof card widened to any segment": (
            caddy_src.replace("^/api/proofs/[0-9a-f]{64}$", "^/api/proofs/[^/]+$"), PROOF_CARD_CASES,
        ),
        "competition week widened to any segment": (
            caddy_src.replace("(current|[0-9]{4}-W(0[1-9]|[1-4][0-9]|5[0-3]))", "[^/]+"), COMPETITION_CASES,
        ),
        "notification subscribe Bearer removed": (
            caddy_src.replace(
                'path /api/notifications/subscriptions\n\t\tvars {env.PUBLIC_READONLY_API} on\n\t\texpression `{query} == ""`\n\t\theader Authorization "Bearer *"\n',
                'path /api/notifications/subscriptions\n\t\tvars {env.PUBLIC_READONLY_API} on\n\t\texpression `{query} == ""`\n',
            ), NOTIFICATION_CASES,
        ),
        "passkey notification challenge content type removed": (
            caddy_src.replace(
                'path /api/notifications/passkey/challenge\n\t\tvars {env.PUBLIC_READONLY_API} on\n\t\texpression `{query} == ""`\n\t\theader Content-Type application/json\n',
                'path /api/notifications/passkey/challenge\n\t\tvars {env.PUBLIC_READONLY_API} on\n\t\texpression `{query} == ""`\n',
            ), PASSKEY_NOTIFICATION_CASES,
        ),
        "passkey notification routes widened to the passkey prefix": (
            caddy_src.replace("path /api/notifications/passkey/subscriptions\n", "path /api/notifications/passkey/*\n"),
            PASSKEY_NOTIFICATION_CASES,
        ),
        "calibration certificate widened to any segment": (
            caddy_src.replace("^/api/calibration-certificates/station/st_[0-9a-f]{12}$", "^/api/calibration-certificates/station/[^/]+$"),
            CALIBRATION_CASES,
        ),
        "calibration certificate query unlocked": (
            caddy_src.replace(
                "station/st_[0-9a-f]{12}$\n\t\tvars {env.PUBLIC_READONLY_API} on\n\t\texpression `{query} == \"\"`",
                "station/st_[0-9a-f]{12}$\n\t\tvars {env.PUBLIC_READONLY_API} on",
            ),
            CALIBRATION_CASES,
        ),
        "proof card height hint loosened": (
            caddy_src.replace("'^h=[1-9][0-9]{0,11}$'", "'^h=[0-9]+'"), PROOF_CARD_CASES,
        ),
        "forecasters list query lock loosened": (
            caddy_src.replace("&limit=([1-9]|[1-9][0-9]|100)$')`", "&limit=[0-9]+$')`"), FORECASTER_EXPLORER_CASES,
        ),
        "governance proposal id widened to any segment": (
            caddy_src.replace("proposals/[A-Za-z0-9_-]{1,128}$", "proposals/[^/]+$"), PARITY_GOVERNANCE_CASES,
        ),
    }
    for mutant, (mutated, cases) in parity_mutants.items():
        if mutated == caddy_src:
            raise AssertionError(f"RED control could not be built: parity mutant {mutant!r} changed nothing")
        try:
            prove_parity_reads(f"RED-parity-{mutant}", funnel_text, "8444", "on", cases, 8, snippet_text=mutated)
        except AssertionError as error:
            print(f"PASS [RED control] parity mutant {mutant!r} correctly FAILS its proof: {error}")
        else:
            raise AssertionError(f"RED control failed: parity mutant {mutant!r} passed its proof")

    # Phase 2c (infra#983 RED control): with the gate line removed the reads
    # are admitted with the variable unset, so the default-off proof MUST fail.
    # If it passes, phase 2b's off cases are vacuous.
    ungated = (EDGE / "public_onboarding.caddy").read_text(encoding="utf-8").replace(
        "\t\tvars {env.PUBLIC_READONLY_API} on\n", ""
    )
    if "PUBLIC_READONLY_API} on" in ungated or ungated == (EDGE / "public_onboarding.caddy").read_text(encoding="utf-8"):
        raise AssertionError("RED control could not be built: no PUBLIC_READONLY_API gate to remove")
    try:
        prove_readonly_gate("RED-ungated-readonly", funnel_text, "8444", None, snippet_text=ungated)
    except AssertionError as error:
        print(f"PASS [RED control] ungated Stage 1.5 reads correctly FAIL the default-off proof: {error}")
    else:
        raise AssertionError("RED control failed: ungated Stage 1.5 reads passed the default-off proof")

    # Phase 2d (stage15 query-lock RED control): with both query locks removed
    # the query-lock proof MUST fail on the NOAA-branch query. If it passes, the
    # READONLY_QUERY_DENIED cases above are vacuous.
    unlocked = re.sub(r"(?m)^\t\texpression `\{query\}.*`\n", "", (EDGE / "public_onboarding.caddy").read_text(encoding="utf-8"))
    if "expression `{query}" in unlocked:
        raise AssertionError("RED control could not be built: query lock still present")
    if unlocked == (EDGE / "public_onboarding.caddy").read_text(encoding="utf-8"):
        raise AssertionError("RED control could not be built: no query lock to remove")
    try:
        prove_readonly_query_lock("RED-unlocked-query", funnel_text, "8444", snippet_text=unlocked)
    except AssertionError as error:
        print(f"PASS [RED control] query-unlocked Stage 1.5 reads correctly FAIL the query-lock proof: {error}")
    else:
        raise AssertionError("RED control failed: query-unlocked Stage 1.5 reads passed the query-lock proof")

    # Phase 2d' (backend#1232 RED control): with the EARNINGS query lock removed the
    # earnings proof MUST fail on `?limit=100`. If it passes, READONLY_EARNINGS_QUERY_DENIED
    # is vacuous.
    earnings_unlocked = (EDGE / "public_onboarding.caddy").read_text(encoding="utf-8").replace(
        "earnings$\n\t\tvars {env.PUBLIC_READONLY_API} on\n\t\texpression `{query} == \"\"`\n",
        "earnings$\n\t\tvars {env.PUBLIC_READONLY_API} on\n",
    )
    if earnings_unlocked == (EDGE / "public_onboarding.caddy").read_text(encoding="utf-8"):
        raise AssertionError("RED control could not be built: no earnings query lock to remove")
    try:
        prove_readonly_gate(
            "RED-unlocked-earnings", funnel_text, "8444", "on", snippet_text=earnings_unlocked,
            reads=READONLY_EARNINGS_READS, siblings=READONLY_EARNINGS_SIBLINGS_DENIED,
            query_denied=READONLY_EARNINGS_QUERY_DENIED, non_get_from=0,
        )
    except AssertionError as error:
        print(f"PASS [RED control] query-unlocked earnings correctly FAIL the earnings proof: {error}")
    else:
        raise AssertionError("RED control failed: query-unlocked earnings passed the earnings proof")

    # Phase 2d-lb (backend#1456 RED controls): each loosening of the leaderboard matcher MUST fail its proof.
    caddy_text = (EDGE / "public_onboarding.caddy").read_text(encoding="utf-8")
    lb_lock = re.search(r"(?m)^\t\texpression `\{query\}\.matches\('[^\n]*\)`\n", caddy_text)
    if lb_lock is None:
        raise AssertionError("RED control could not be built: no leaderboard query lock to remove")
    lb_mutants = {
        "unlocked": caddy_text.replace(lb_lock.group(0), ""),
        "limit-100": caddy_text.replace("[12][0-9]|30)$", "[12][0-9]|30|100)$"),
        "geo-country": caddy_text.replace("|30)$", "|30)(&country=[A-Z]{2})?$"),
        "unanchored": caddy_text.replace("'^metric=", "'metric="),
        "post": caddy_text.replace(
            "@public_readonly_weather_leaderboard {\n\t\tmethod GET\n",
            "@public_readonly_weather_leaderboard {\n\t\tmethod GET POST\n",
        ),
        "ungated": caddy_text.replace(
            "path_regexp ^/api/weather/leaderboard$\n\t\tvars {env.PUBLIC_READONLY_API} on\n", "path_regexp ^/api/weather/leaderboard$\n"
        ),
    }
    for mutant, mutated in lb_mutants.items():
        if mutated == caddy_text:
            raise AssertionError(f"RED control could not be built: leaderboard mutant {mutant} changed nothing")
        try:
            if mutant == "ungated":
                prove_readonly_gate(
                    f"RED-leaderboard-{mutant}", funnel_text, "8444", None, snippet_text=mutated,
                    reads=READONLY_LEADERBOARD_READS,
                )
            else:
                prove_readonly_gate(
                    f"RED-leaderboard-{mutant}", funnel_text, "8444", "on", snippet_text=mutated,
                    reads=READONLY_LEADERBOARD_READS[:1], query_denied=READONLY_LEADERBOARD_RED_PROBES,
                    siblings=READONLY_LEADERBOARD_SIBLINGS_DENIED, non_get_from=0,
                    non_get_methods=READONLY_LEADERBOARD_NON_GET_METHODS, non_get_paths=1,
                )
        except AssertionError as error:
            print(f"PASS [RED control] leaderboard mutant {mutant} correctly FAILS its proof: {error}")
        else:
            raise AssertionError(f"RED control failed: leaderboard mutant {mutant} passed its proof")

    # Phase 2d'' (backend#1232 RED control): with the earnings matcher widened to HEAD/OPTIONS/
    # PATCH the earnings proof MUST fail. If it passes, READONLY_EARNINGS_NON_GET_METHODS is vacuous.
    for extra in ("HEAD", "OPTIONS", "PATCH"):
        widened_methods = (EDGE / "public_onboarding.caddy").read_text(encoding="utf-8").replace(
            "@public_readonly_station_earnings {\n\t\tmethod GET\n",
            f"@public_readonly_station_earnings {{\n\t\tmethod GET {extra}\n",
        )
        if widened_methods == (EDGE / "public_onboarding.caddy").read_text(encoding="utf-8"):
            raise AssertionError("RED control could not be built: no earnings method line to widen")
        try:
            prove_readonly_gate(
                f"RED-earnings-{extra}", funnel_text, "8444", "on", snippet_text=widened_methods,
                reads=READONLY_EARNINGS_READS, siblings=READONLY_EARNINGS_SIBLINGS_DENIED,
                query_denied=READONLY_EARNINGS_QUERY_DENIED, non_get_from=0,
                non_get_methods=READONLY_EARNINGS_NON_GET_METHODS, non_get_paths=1,
            )
        except AssertionError as error:
            print(f"PASS [RED control] earnings widened to {extra} correctly FAILS the earnings proof: {error}")
        else:
            raise AssertionError(f"RED control failed: earnings widened to {extra} passed the earnings proof")

    # Phase 2d-so (infra#1095): the station owner-action relay and the ownership read.
    for value in READONLY_GATE_OFF_VALUES:
        prove_station_owner_routes("funnel-edge-owner-gate", funnel_text, "8444", value, "gate")
    prove_station_owner_routes("direct-edge-owner-gate", config, "8080", None, "gate")
    for label, text, port in (("funnel-edge-owner", funnel_text, "8444"), ("direct-edge-owner", config, "8080")):
        prove_station_owner_routes(f"{label}-read", text, port, "on", "read")
        prove_station_owner_routes(f"{label}-relay", text, port, "on", "relay")
        prove_station_owner_routes(f"{label}-rate", text, port, "on", "rate")

    # Phase 2d-so RED controls: each loosening of the relay or the read MUST fail its proof.
    so_text = (EDGE / "public_onboarding.caddy").read_text(encoding="utf-8")
    so_mutants = {
        "cap-removed": ("relay", "on", so_text.replace("\t\trequest_body {\n\t\t\tmax_size 8KiB\n\t\t}\n", "")),
        "cap-widened": ("relay", "on", so_text.replace("max_size 8KiB", "max_size 2MB")),
        "relay-get": ("relay", "on", so_text.replace("@station_owner_actions {\n\t\tmethod POST", "@station_owner_actions {\n\t\tmethod POST GET")),
        "relay-raw-ids": ("relay", "on", so_text.replace("st_[0-9a-f]{12}/owner-actions$\n\t\texpression", "[A-Za-z0-9_-]{1,64}/owner-actions$\n\t\texpression")),
        "relay-query": ("relay", "on", re.sub(r"(owner-actions\$\n)\t\texpression `\{query\} == \"\"`\n", r"\1", so_text, count=1)),
        "zone-loosened": ("rate", "on", so_text.replace("events 10\n\t\t\twindow 10m", "events 1000\n\t\t\twindow 10m")),
        "read-ungated": ("gate", None, so_text.replace("/ownership$\n\t\tvars {env.PUBLIC_READONLY_API} on\n", "/ownership$\n")),
        "read-query": ("read", "on", so_text.replace("/ownership$\n\t\tvars {env.PUBLIC_READONLY_API} on\n\t\texpression `{query} == \"\"`\n", "/ownership$\n\t\tvars {env.PUBLIC_READONLY_API} on\n")),
        "read-post": ("read", "on", so_text.replace("@public_readonly_station_ownership {\n\t\tmethod GET", "@public_readonly_station_ownership {\n\t\tmethod GET POST")),
    }
    for mutant, (so_phase, so_gate, mutated) in so_mutants.items():
        if mutated == so_text:
            raise AssertionError(f"RED control could not be built: station-owner mutant {mutant} changed nothing")
        try:
            prove_station_owner_routes(f"RED-owner-{mutant}", funnel_text, "8444", so_gate, so_phase, snippet_text=mutated)
        except AssertionError as error:
            print(f"PASS [RED control] station-owner mutant {mutant} correctly FAILS its proof: {error}")
        else:
            raise AssertionError(f"RED control failed: station-owner mutant {mutant} passed its proof")

    # Phase 2e (owner ruling 2026-09-27): the frontend CSP as actually served,
    # plus a RED control — a config whose asset-location copy is widened must
    # fail, or the static-asset check above is vacuous.
    conf = NGINX_FRONTEND_CONF.read_text(encoding="utf-8")
    prove_frontend_csp_served("frontend-csp", conf)
    last = conf.rindex("add_header Content-Security-Policy")
    widened = conf[:last] + conf[last:].replace("https://tile.openstreetmap.org;", "https:;", 1)
    if widened == conf:
        raise AssertionError("RED control could not be built: no tile origin in the asset-location CSP")
    try:
        prove_frontend_csp_served("RED-widened-asset-csp", widened)
    except AssertionError as error:
        print(f"PASS [RED control] a widened asset-location CSP correctly FAILS the served-CSP proof: {error}")
    else:
        raise AssertionError("RED control failed: a widened asset-location CSP passed the served-CSP proof")

    # Phase 3 (RED control): the raw-frontend funnel shape — exactly what the
    # pre-revision runbook would have published — must FAIL this proof. If it
    # ever passes, the proof itself has gone vacuous.
    raw_frontend = "{\n\tauto_https off\n}\n:8444 {\n\treverse_proxy wrfcoin-testnet-frontend:5000\n}\n"
    try:
        prove_edge("RED-raw-frontend", raw_frontend, "8444")
    except AssertionError:
        print("PASS [RED control] raw-frontend funnel shape correctly FAILS the boundary proof")
    else:
        raise AssertionError("RED control failed: a raw-frontend funnel passed the boundary proof")

    # Phase 3b (infra#1051 RED control): the shipped funnel edge with the
    # non-canonical-path guard removed — the exact pre-fix shape on main
    # 410228b — must FAIL. If it passes, the traversal cases above are vacuous.
    snippet = (EDGE / "public_onboarding.caddy").read_text(encoding="utf-8")
    unguarded = re.sub(
        r"\t@noncanonical_uri \{.*?\n\t\}\n\thandle @noncanonical_uri \{.*?\n\t\}\n",
        "",
        snippet,
        count=1,
        flags=re.S,
    )
    if unguarded == snippet:
        raise AssertionError("RED control could not be built: no @noncanonical_uri guard to remove")
    try:
        prove_noncanonical_refused(
            "RED-unguarded-dot-segments",
            (EDGE / "Caddyfile.funnel").read_text(encoding="utf-8"),
            "8444",
            snippet_text=unguarded,
        )
    except AssertionError as error:
        print(f"PASS [RED control] pre-#1051 edge correctly FAILS the traversal proof: {error}")
    else:
        raise AssertionError("RED control failed: an edge without the #1051 guard passed the traversal proof")

    # Phase 3c (RED control, review of #1052 at 9084b02): the guard as first
    # shipped scanned `[^?#]*`, so a literal `#` ended the inspection while
    # Caddy cleaned past it and forwarded `%23/../..` raw. That exact regex must
    # FAIL the proof; if it passes, the `#` targets have gone vacuous.
    hash_blind = snippet.replace(
        "[^?]*(?:#|/\\.\\.?(?:[/?]|$)", "[^?#]*(?:/\\.\\.?(?:[/?#]|$)"
    )
    if hash_blind == snippet:
        raise AssertionError("RED control could not be built: guard regex not in its expected form")
    try:
        prove_noncanonical_refused(
            "RED-hash-blind-guard",
            (EDGE / "Caddyfile.funnel").read_text(encoding="utf-8"),
            "8444",
            snippet_text=hash_blind,
        )
    except AssertionError as error:
        print(f"PASS [RED control] 9084b02 `[^?#]` guard correctly FAILS the `#` proof: {error}")
    else:
        raise AssertionError("RED control failed: a guard blind to literal `#` passed the traversal proof")

    # Phase 4 (infra#657, #884, backend#1229): from any peer other than the
    # pinned wrfcoin-ingress gateway -- here the harness's default-bridge
    # gateway -- the shipped funnel edge must not let a client choose its own
    # rate-limit bucket via X-Forwarded-For, in EITHER header shape. The
    # pass-through shape below -- a rotating spoof with nothing appended -- is
    # the one #885's `private_ranges` + strict did not close.
    funnel_config = (EDGE / "Caddyfile.funnel").read_text(encoding="utf-8")
    prove_xff_cannot_reset_the_limit(
        "funnel-edge-xff-appended", funnel_config, "8444"
    )
    prove_xff_cannot_reset_the_limit(
        "funnel-edge-xff-passthrough",
        funnel_config,
        "8444",
        header_for=lambda n: f"X-Forwarded-For: 203.0.113.{n}",
    )

    # Phase 5 (RED control for phase 4): widen the shipped single-hop trust to
    # #885's `private_ranges` and the pass-through bypass MUST succeed (the
    # harness peer is a private address). Without this control phase 4 could
    # pass for an unrelated reason -- a limiter that refused everything, say --
    # and would keep passing if someone widened the trusted set.
    # Comments in Caddyfile.funnel discuss trusted_proxies at length, so this
    # must look for ACTIVE directives -- non-comment lines -- not mentions.
    active_trust = [
        line.strip() for line in funnel_config.splitlines()
        if line.strip().startswith("trusted_proxies") and not line.strip().startswith("trusted_proxies_strict")
    ]
    if active_trust != ["trusted_proxies static 10.251.0.1/32"]:
        raise AssertionError(
            "RED control could not be built: Caddyfile.funnel must trust exactly "
            f"`trusted_proxies static 10.251.0.1/32` (backend#1229), found {active_trust}; "
            "phase 4 would be testing a different configuration than it claims."
        )
    retrusted = funnel_config.replace(
        "trusted_proxies static 10.251.0.1/32", "trusted_proxies static private_ranges", 1
    )
    try:
        prove_xff_cannot_reset_the_limit(
            "RED-retrusted",
            retrusted,
            "8444",
            header_for=lambda n: f"X-Forwarded-For: 203.0.113.{n}",
        )
    except AssertionError:
        print("PASS [RED control] widening trust to private_ranges re-opens the pass-through bypass, as measured")
    else:
        raise AssertionError(
            "RED control failed: the pass-through spoof was refused even WITH "
            "private_ranges trusted, so phase 4 is not testing what it claims"
        )

    # Phase 6 (infra#884): from an UNTRUSTED peer, {client_ip} is the peer even
    # when the header carries a plausible chain. This reads {client_ip} out of
    # the edge's own access log, which also proves the #884 instrumentation
    # records the inbound header as received.
    prove_inbound_xff_is_logged_and_client_ip_is_the_peer(funnel_config, "8444")

    # Phase 7 (backend#1229): from the pinned wrfcoin-ingress gateway -- the
    # only peer tailscaled's funnel traffic can arrive from -- the header
    # tailscaled wrote IS honoured, so two visitors get independent buckets and
    # the backend receives "<client>, <gateway>".
    prove_ingress_gateway_gives_per_client_buckets(funnel_config, "8444")


if __name__ == "__main__":
    main()
