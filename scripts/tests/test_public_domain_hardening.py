"""Offline tests for the wrfcoin.com public-domain gate."""

import importlib.util
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "verify-public-domain-hardening.py"
SPEC = importlib.util.spec_from_file_location("public_domain_hardening", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def policy():
    return json.loads((ROOT / "testnet" / "edge" / "public-domain-hardening.json").read_text())


def test_mutation_matrix_rejects_every_weakened_boundary():
    MODULE.self_test(policy())


def test_hsts_parser_requires_a_real_max_age_directive():
    assert MODULE.hsts_max_age("max-age=86400; includeSubDomains") == 86400
    assert MODULE.hsts_max_age("not-max-age=86400") is None
    assert MODULE.hsts_max_age("max-age=oops") is None


def test_caa_parser_ignores_unrelated_and_malformed_records():
    assert MODULE.caa_entries(
        [
            {"type": 1, "data": "192.0.2.1"},
            {"type": 257, "data": '0 issue "pki.goog"'},
            {"type": 257, "data": "malformed"},
        ]
    ) == [("issue", "pki.goog")]


def test_caa_parser_reads_the_issuer_domain_ignoring_rfc8659_parameters():
    # Cloudflare emits `issue "pki.goog; cansignhttpexchanges=yes"`; the issuer
    # domain alone decides authorization (RFC 8659 §4.2). Without this the gate
    # false-REDs a correctly configured CAA record.
    assert MODULE.caa_entries(
        [
            {"type": 257, "data": '0 issue "pki.goog; cansignhttpexchanges=yes"'},
            {"type": 257, "data": '0 issuewild "pki.goog;cansignhttpexchanges=yes"'},
        ]
    ) == [("issue", "pki.goog"), ("issuewild", "pki.goog")]


def _path_evidence(pol, mutate=None):
    origin = pol["expected_redirect_url"].rstrip("/")
    hosts = (pol["domain"], pol["www_domain"])
    ev = {
        "http_paths": {
            h: {p: {"status": 302, "headers": {"location": origin + p}} for p in pol["redirect_path_probes"]}
            for h in hosts
        }
    }
    if mutate:
        mutate(ev, origin)
    return ev


def test_path_gate_passes_for_preserving_redirects_on_both_hosts():
    pol = policy()
    assert MODULE.path_preservation_failures(pol, _path_evidence(pol)) == []


def test_path_gate_probes_cover_path_query_and_percent_encoding():
    probes = policy()["redirect_path_probes"]
    assert "/wallet" in probes
    assert "/governance?limit=20&offset=0" in probes
    assert any("%" in p for p in probes)


def test_path_gate_fails_when_static_target_drops_path_and_query():
    # The #1330 bug: every deep link lands on the funnel root.
    pol = policy()

    def mutate(ev, origin):
        for host in ev["http_paths"].values():
            for probe in host.values():
                probe["headers"]["location"] = origin + "/"

    failures = MODULE.path_preservation_failures(pol, _path_evidence(pol, mutate))
    assert len(failures) >= 2 * len(pol["redirect_path_probes"]) - 2
    assert any("www.wrfcoin.com/wallet" in f and "path" in f for f in failures)


def test_path_gate_fails_when_only_www_drops_the_query():
    pol = policy()
    probe = "/governance?limit=20&offset=0"

    def mutate(ev, origin):
        ev["http_paths"][pol["www_domain"]][probe]["headers"]["location"] = origin + "/governance"

    failures = MODULE.path_preservation_failures(pol, _path_evidence(pol, mutate))
    assert len(failures) == 1 and failures[0].startswith(pol["www_domain"]) and "query" in failures[0]


def test_path_gate_fails_on_wrong_host_and_on_decoded_percent_escape():
    pol = policy()
    enc = [p for p in pol["redirect_path_probes"] if "%" in p][0]

    def mutate(ev, origin):
        ev["http_paths"][pol["domain"]]["/wallet"]["headers"]["location"] = "https://evil.example/wallet"
        ev["http_paths"][pol["domain"]][enc]["headers"]["location"] = origin + enc.replace("%C3%A9", "é")

    failures = MODULE.path_preservation_failures(pol, _path_evidence(pol, mutate))
    assert any("host" in f for f in failures) and any("path" in f for f in failures)


def test_path_gate_fails_closed_on_missing_evidence():
    pol = policy()
    assert MODULE.path_preservation_failures(pol, {})
