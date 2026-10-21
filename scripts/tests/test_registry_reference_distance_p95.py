"""Owner P95 tool for WRFCOIN_ATTESTER_MAX_REFERENCE_KM (core4#3240, owner ruling 2026-10-05).

Loopback fixtures only: a 127.0.0.1 http.server stands in for api.weather.gov. No real
station coordinates appear in this file; points are synthetic.
"""
import importlib.util
import json
import math
import os
import re
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
TOOL = os.path.join(ROOT, "scripts", "registry-reference-distance-p95.py")
spec = importlib.util.spec_from_file_location("p95tool", TOOL)
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)

KM_PER_DEG = 111.19492664455873  # R * pi / 180, R = 6371


def synthetic_registry(n=21):
    """Point i sits on the 0.01-degree grid; its nearest reference is i+1 km due north."""
    pts = [(round(30.07 + 0.37 * i, 2), round(41.13 + 0.29 * i, 2)) for i in range(n)]
    refs = {f"{la:.2f},{lo:.2f}": (la + (i + 1) / KM_PER_DEG, lo) for i, (la, lo) in enumerate(pts)}
    return pts, refs


@pytest.fixture
def nws():
    state = {"refs": {}, "hits": 0}

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            state["hits"] += 1
            m = re.match(r"^/points/(-?[\d.]+,-?[\d.]+)$", self.path)
            s = re.match(r"^/gridpoints/(-?[\d.]+,-?[\d.]+)/stations$", self.path)
            if m and m.group(1) in state["refs"]:
                # absolute URL on a foreign host: the tool must re-root it onto the base
                body = {"properties": {"observationStations": f"https://example.invalid/gridpoints/{m.group(1)}/stations"}}
            elif s and s.group(1) in state["refs"]:
                la, lo = state["refs"][s.group(1)]
                body = {"features": [
                    {"properties": {"stationIdentifier": " "}, "geometry": {"coordinates": [0, 0]}},  # unusable: skipped
                    {"properties": {"stationIdentifier": "TEST"}, "geometry": {"coordinates": [lo, la]}},
                ]}
            else:
                self.send_response(404)
                self.end_headers()
                return
            data = json.dumps(body).encode()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(data)

    srv = HTTPServer(("127.0.0.1", 0), H)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    state["base"] = f"http://127.0.0.1:{srv.server_port}"
    yield state
    srv.shutdown()
    srv.server_close()


def run(registry_text, base, *extra):
    return subprocess.run([sys.executable, TOOL, "--nws-base-url", base, *extra], input=registry_text,
                          capture_output=True, text=True, timeout=60)


def as_json(pts):
    return json.dumps({"stations": [{"id": f"s{i}", "name": f"name{i}", "latitude": la, "longitude": lo}
                                    for i, (la, lo) in enumerate(pts)]})


def test_haversine_matches_core4_known_pairs():
    # Pinned from core4 shared-protocol station_reference.rs great_circle_km_known_pairs_3240
    assert tool.haversine_km((46.7867, -92.1005), (46.8369, -92.1833)) == pytest.approx(8.418, abs=1e-3)
    assert tool.haversine_km((46.8369, -92.1833), (44.8848, -93.2223)) == pytest.approx(231.489, abs=1e-3)
    assert tool.haversine_km((0, 0), (0, 1)) == pytest.approx(111.194_926_644_558_7, abs=1e-6)
    assert tool.haversine_km((0, 179.5), (0, -179.5)) == pytest.approx(111.194_926_644_559, abs=1e-6)


def test_percentile_linear_interpolation():
    assert tool.percentile([1, 2, 3, 4, 5], 0.5) == 3
    assert tool.percentile([1, 2, 3, 4, 5], 0.95) == pytest.approx(4.8)
    assert tool.percentile([], 0.95) is None


def test_end_to_end_p50_p95_max_and_cap_counts(nws):
    pts, refs = synthetic_registry(21)
    nws["refs"] = refs
    r = run(as_json(pts), nws["base"], "--caps", "3.4,12,25")
    assert r.returncode == 0, r.stderr
    out = r.stdout
    assert "stations in listing      : 21" in out and "resolved                 : 21" in out
    assert "P50 km : 11.0" in out and "P95 km : 20.0" in out and "max km : 21.0" in out
    assert "farther than 3.4 km: 18 of 21" in out
    assert "farther than 12 km: 9 of 21" in out
    assert "farther than 25 km: 0 of 21" in out
    assert "suggested WRFCOIN_ATTESTER_MAX_REFERENCE_KM (P95 rounded up to 0.1): 20.0" in out
    assert "WARNING" not in out  # N >= 20


def test_few_stations_warns(nws):
    pts, refs = synthetic_registry(2)
    nws["refs"] = refs
    out = run(as_json(pts), nws["base"]).stdout
    assert "WARNING: only 2 resolved" in out


def test_output_never_contains_coordinates_ids_or_names(nws):
    pts, refs = synthetic_registry(21)
    nws["refs"] = refs
    nws["refs"].pop(f"{pts[3][0]:.2f},{pts[3][1]:.2f}")  # one unresolved station
    r = run(as_json(pts), nws["base"])
    text = r.stdout + r.stderr
    assert "unresolved               : 1" in text
    # every number printed is an integer or has exactly one decimal: nothing coordinate-like
    for tok in re.findall(r"-?\d+\.?\d*", text):
        assert re.fullmatch(r"-?\d+(\.\d)?", tok), tok
    for la, lo in pts:
        for v in (la, lo, f"{la:.2f}", f"{lo:.2f}"):
            assert str(v) not in text
    assert not re.search(r"\bs\d+\b|\bname\d+\b|\bTEST\b|127\.0\.0\.1|example\.invalid", text)


def test_unreachable_and_malformed_inputs_leak_nothing():
    r = run("[{\"latitude\": 12.34, \"longitude\": 56.78}]", "http://127.0.0.1:9")
    assert r.returncode == 1 and "no station resolved" in r.stdout
    assert "12.34" not in r.stdout + r.stderr and "56.78" not in r.stdout + r.stderr
    bad = run("{not json", "http://127.0.0.1:9")
    assert bad.returncode == 2 and "withheld" in bad.stderr


def test_lat_lon_lines_input(nws):
    pts, refs = synthetic_registry(3)
    nws["refs"] = refs
    r = run("\n".join(f"{la},{lo}" for la, lo in pts), nws["base"])
    assert "resolved                 : 3" in r.stdout


def test_lookup_is_cached_per_coarse_point(nws):
    pts, refs = synthetic_registry(1)
    nws["refs"] = refs
    la, lo = pts[0]
    run(as_json([(la, lo), (la + 0.001, lo - 0.001)]), nws["base"])  # same 0.01 degree cell
    assert nws["hits"] == 2  # one /points and one stations call for both stations
