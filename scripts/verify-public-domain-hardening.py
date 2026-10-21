#!/usr/bin/env python3
"""Fail-closed public-domain verification for wrfcoin.com.

The live check is deliberately read-only. It observes both redirect hosts,
DNSSEC, CAA, and the deployed RFC 9116 security.txt. The pure verifier is kept
separate from network collection so its failure boundaries can be mutation
tested without trusting the public network or a mocked command-line tool.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener, urlopen


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_POLICY = ROOT / "testnet" / "edge" / "public-domain-hardening.json"


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        return None


def fetch_once(url: str, timeout: float) -> dict[str, Any]:
    request = Request(url, headers={"User-Agent": "wrfcoin-domain-gate/1"})
    try:
        response = build_opener(NoRedirect()).open(request, timeout=timeout)
    except HTTPError as error:
        response = error
    body = response.read(1_000_000).decode("utf-8", errors="replace")
    return {
        "status": response.status,
        "headers": {key.lower(): value for key, value in response.headers.items()},
        "body": body,
    }


def query_dns(name: str, record_type: str, timeout: float) -> dict[str, Any]:
    query = urlencode({"name": name, "type": record_type, "do": "true"})
    request = Request(
        f"https://cloudflare-dns.com/dns-query?{query}",
        headers={"Accept": "application/dns-json", "User-Agent": "wrfcoin-domain-gate/1"},
    )
    with urlopen(request, timeout=timeout) as response:
        return json.loads(response.read(1_000_000))


def retry(operation, attempts: int):  # noqa: ANN001, ANN201
    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            return operation()
        except (OSError, ValueError) as error:
            last_error = error
            if attempt < attempts:
                time.sleep(0.5 * attempt)
    assert last_error is not None
    raise last_error


def observe(operation, attempts: int) -> dict[str, Any]:  # noqa: ANN001
    try:
        return retry(operation, attempts)
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def collect_live(policy: dict[str, Any], timeout: float, attempts: int) -> dict[str, Any]:
    domain = policy["domain"]
    return {
        "collected_at": datetime.now(timezone.utc).isoformat(),
        "http": {
            domain: observe(lambda: fetch_once(f"https://{domain}/", timeout), attempts),
            policy["www_domain"]: observe(
                lambda: fetch_once(f"https://{policy['www_domain']}/", timeout), attempts
            ),
            "security_txt": observe(lambda: fetch_once(policy["security_txt_url"], timeout), attempts),
        },
        # Read-only GETs through the same no-follow handler; one per host+probe.
        "http_paths": {
            host: {
                probe: observe(lambda h=host, p=probe: fetch_once(f"https://{h}{p}", timeout), attempts)
                for probe in policy.get("redirect_path_probes", [])
            }
            for host in (domain, policy["www_domain"])
        },
        "dns": {
            "CAA": observe(lambda: query_dns(domain, "CAA", timeout), attempts),
            "DS": observe(lambda: query_dns(domain, "DS", timeout), attempts),
            "DNSKEY": observe(lambda: query_dns(domain, "DNSKEY", timeout), attempts),
        },
    }


def hsts_max_age(value: str) -> int | None:
    match = re.search(r"(?:^|;)\s*max-age\s*=\s*(\d+)\s*(?:;|$)", value, re.IGNORECASE)
    return int(match.group(1)) if match else None


def caa_entries(answer: list[dict[str, Any]]) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    pattern = re.compile(r'^\s*\d+\s+(issue|issuewild)\s+"([^"]*)"\s*$', re.IGNORECASE)
    for item in answer:
        if item.get("type") != 257:
            continue
        match = pattern.match(str(item.get("data", "")))
        if match:
            # RFC 8659 §4.2: an issue/issuewild value is an issuer domain
            # optionally followed by "; parameters" (Cloudflare emits e.g.
            # `pki.goog; cansignhttpexchanges=yes`). Authorization is decided by
            # the issuer domain alone; the parameters are not part of it.
            issuer = match.group(2).split(";", 1)[0].strip().lower().rstrip(".")
            entries.append((match.group(1).lower(), issuer))
    return entries


def security_txt_fields(body: str) -> dict[str, list[str]]:
    fields: dict[str, list[str]] = {}
    for raw_line in body.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, value = line.split(":", 1)
        fields.setdefault(key.strip().lower(), []).append(value.strip())
    return fields


def path_preservation_failures(policy: dict[str, Any], evidence: dict[str, Any]) -> list[str]:
    """Each probe must redirect to the funnel origin with the identical path and query.

    Components are compared as raw strings (no percent-decoding) so an encoded
    character that is decoded, double-encoded, or dropped is a failure.
    """
    failures: list[str] = []
    probes = policy.get("redirect_path_probes", [])
    if not probes:
        return ["redirect path probes: policy defines none"]
    origin = urlsplit(policy["expected_redirect_url"])
    for host in (policy["domain"], policy["www_domain"]):
        for probe in probes:
            label = f"{host}{probe}"
            result = evidence.get("http_paths", {}).get(host, {}).get(probe, {})
            if result.get("status") not in policy["redirect_statuses"]:
                failures.append(f"{label}: expected an HTTPS redirect status")
                continue
            location = result.get("headers", {}).get("location")
            if not isinstance(location, str):
                failures.append(f"{label}: redirect has no Location")
                continue
            want = urlsplit(probe)
            got = urlsplit(location)
            for part, expected, actual in (
                ("scheme", origin.scheme, got.scheme),
                ("host", origin.netloc, got.netloc),
                ("path", want.path, got.path),
                ("query", want.query, got.query),
                ("fragment", "", got.fragment),
            ):
                if expected != actual:
                    failures.append(f"{label}: redirect {part} {actual!r} != expected {expected!r}")
    return failures


def verify(policy: dict[str, Any], evidence: dict[str, Any], now: datetime | None = None) -> list[str]:
    failures: list[str] = []
    now = now or datetime.now(timezone.utc)

    for host in (policy["domain"], policy["www_domain"]):
        result = evidence.get("http", {}).get(host, {})
        if result.get("status") not in policy["redirect_statuses"]:
            failures.append(f"{host}: expected an HTTPS redirect status")
        if result.get("headers", {}).get("location") != policy["expected_redirect_url"]:
            failures.append(f"{host}: redirect target is not exact")
        hsts = result.get("headers", {}).get("strict-transport-security", "")
        max_age = hsts_max_age(hsts)
        if max_age is None or max_age < policy["minimum_hsts_max_age_seconds"]:
            failures.append(f"{host}: HSTS max-age is missing or below policy")
        if not policy["allow_hsts_preload"] and re.search(r"(?:^|;)\s*preload\s*(?:;|$)", hsts, re.I):
            failures.append(f"{host}: HSTS preload is not approved during the initial soak")

    failures.extend(path_preservation_failures(policy, evidence))

    caa = evidence.get("dns", {}).get("CAA", {})
    entries = caa_entries(caa.get("Answer", [])) if caa.get("Status") == 0 else []
    authorized = [(tag, value) for tag, value in entries if value and value != ";"]
    approved = {value.lower().rstrip(".") for value in policy["approved_caa_issuers"]}
    if not authorized:
        failures.append("CAA: no certificate issuer is explicitly authorized")
    for tag, value in authorized:
        if value not in approved:
            failures.append(f"CAA: unapproved {tag} issuer {value}")

    for record_type, number in (("DS", 43), ("DNSKEY", 48)):
        result = evidence.get("dns", {}).get(record_type, {})
        answers = result.get("Answer", []) if result.get("Status") == 0 else []
        if not result.get("AD") or not any(item.get("type") == number for item in answers):
            failures.append(f"DNSSEC: validated {record_type} evidence is absent")

    result = evidence.get("http", {}).get("security_txt", {})
    if result.get("status") != 200:
        failures.append("security.txt: expected HTTP 200")
    fields = security_txt_fields(result.get("body", ""))
    if not fields.get("contact"):
        failures.append("security.txt: Contact is absent")
    if policy["security_txt_canonical"] not in fields.get("canonical", []):
        failures.append("security.txt: Canonical is absent or wrong")
    if policy["security_policy_url"] not in fields.get("policy", []):
        failures.append("security.txt: Policy is absent or wrong")
    expiries = fields.get("expires", [])
    try:
        expiry = datetime.fromisoformat(expiries[0].replace("Z", "+00:00"))
        if expiry <= now:
            failures.append("security.txt: Expires is not in the future")
    except (IndexError, ValueError):
        failures.append("security.txt: Expires is absent or invalid")

    return failures


def self_test(policy: dict[str, Any]) -> None:
    future = "2027-08-01T00:00:00Z"
    redirect = {
        "status": 301,
        "headers": {
            "location": policy["expected_redirect_url"],
            "strict-transport-security": "max-age=86400",
        },
        "body": "",
    }
    origin = policy["expected_redirect_url"].rstrip("/")
    probes = policy["redirect_path_probes"]
    path_ok = {
        host: {
            probe: {
                "status": 302,
                "headers": {"location": origin + probe, "strict-transport-security": "max-age=86400"},
                "body": "",
            }
            for probe in probes
        }
        for host in (policy["domain"], policy["www_domain"])
    }
    evidence: dict[str, Any] = {
        "http_paths": path_ok,
        "http": {
            policy["domain"]: dict(redirect),
            policy["www_domain"]: dict(redirect),
            "security_txt": {
                "status": 200,
                "headers": {"content-type": "text/plain"},
                "body": (
                    "Contact: https://github.com/wrfcoin/infra/issues/new\n"
                    f"Expires: {future}\n"
                    f"Canonical: {policy['security_txt_canonical']}\n"
                    f"Policy: {policy['security_policy_url']}\n"
                ),
            },
        },
        "dns": {
            # Realistic Cloudflare shape: an approved issuer carrying a CAA
            # parameter. The control must PASS — the issuer domain is what
            # decides authorization (RFC 8659 §4.2), not the parameters.
            "CAA": {"Status": 0, "AD": True, "Answer": [{"type": 257, "data": '0 issue "pki.goog; cansignhttpexchanges=yes"'}]},
            "DS": {"Status": 0, "AD": True, "Answer": [{"type": 43, "data": "fixture"}]},
            "DNSKEY": {"Status": 0, "AD": True, "Answer": [{"type": 48, "data": "fixture"}]},
        },
    }
    frozen = datetime(2026, 8, 17, tzinfo=timezone.utc)
    if verify(policy, evidence, frozen):
        raise AssertionError("unmutated evidence did not pass")

    mutations = {
        "wrong redirect": lambda e: e["http"][policy["domain"]]["headers"].update(location="https://evil.example/"),
        "missing HSTS": lambda e: e["http"][policy["www_domain"]]["headers"].pop("strict-transport-security"),
        "HSTS preload": lambda e: e["http"][policy["domain"]]["headers"].update(
            {"strict-transport-security": "max-age=31536000; preload"}
        ),
        "unapproved CAA": lambda e: e["dns"]["CAA"].update(Answer=[{"type": 257, "data": '0 issue "evil.example"'}]),
        "missing DS": lambda e: e["dns"]["DS"].update(Answer=[]),
        "unvalidated DNSKEY": lambda e: e["dns"]["DNSKEY"].update(AD=False),
        "target drops path": lambda e: e["http_paths"][policy["domain"]][probes[0]]["headers"].update(
            location=origin + "/"
        ),
        "target drops query": lambda e: e["http_paths"][policy["domain"]][probes[1]]["headers"].update(
            location=origin + probes[1].split("?")[0]
        ),
        "path redirect wrong host": lambda e: e["http_paths"][policy["domain"]][probes[0]]["headers"].update(
            location="https://evil.example" + probes[0]
        ),
        "www drops query only": lambda e: e["http_paths"][policy["www_domain"]][probes[1]]["headers"].update(
            location=origin + probes[1].split("?")[0]
        ),
        "encoded char decoded": lambda e: e["http_paths"][policy["www_domain"]][probes[2]]["headers"].update(
            location=origin + probes[2].replace("%C3%A9", "é")
        ),
        "path probe not redirected": lambda e: e["http_paths"][policy["www_domain"]][probes[0]].update(status=200),
        "missing security Contact": lambda e: e["http"]["security_txt"].update(body=f"Expires: {future}\n"),
    }
    for label, mutate in mutations.items():
        candidate = json.loads(json.dumps(evidence))
        mutate(candidate)
        if not verify(policy, candidate, frozen):
            raise AssertionError(f"mutation survived: {label}")
        print(f"  ok   mutation rejected: {label}")
    print(f"SELF-TEST PASS: control plus {len(mutations)} fail-closed mutations")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--attempts", type=int, default=3)
    parser.add_argument("--evidence", type=Path, help="verify a previously captured JSON artifact")
    parser.add_argument("--output", type=Path, help="write freshly collected evidence as JSON")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    policy = json.loads(args.policy.read_text(encoding="utf-8"))
    if args.self_test:
        self_test(policy)
        return 0

    if args.attempts < 1 or args.attempts > 5:
        parser.error("--attempts must be between 1 and 5")
    evidence = (
        json.loads(args.evidence.read_text(encoding="utf-8"))
        if args.evidence
        else collect_live(policy, args.timeout, args.attempts)
    )
    if args.output:
        args.output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    failures = verify(policy, evidence)
    if failures:
        print(f"VERDICT: FAIL — {len(failures)} public-domain gate(s) failed")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("VERDICT: PASS — redirects, HSTS, CAA, DNSSEC, and security.txt are verified")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"VERDICT: ERROR — evidence could not be collected or parsed: {error}", file=sys.stderr)
        raise SystemExit(2)
