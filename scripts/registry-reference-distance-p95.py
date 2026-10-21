#!/usr/bin/env python3
"""Owner tool: derive WRFCOIN_ATTESTER_MAX_REFERENCE_KM from the station registry.

Owner ruling 2026-10-05: the attester reference-check shadow run uses a cap equal
to the registry's P95 nearest-reference distance, NOT the runbook's unsourced
3.4 km. Refs wrfcoin/core4#3240.

Input (stdin or --input FILE): a registry station listing as JSON, either a
list or {"stations": [...]}, each element carrying `latitude` and `longitude`
(or `location: {latitude, longitude}`), or plain `lat,lon` lines.

For each station this repeats the attester's reference lookup (core4
native-chain/src/bin/oracle_attester.rs, #3240): coarsen to 0.01 degrees, key
`{lat:.2},{lon:.2}`, GET /points/{key}, follow properties.observationStations
re-rooted onto the base URL, take the first usable feature as the nearest NWS
station, then the haversine distance (R = 6371 km) from the registered point.

OUTPUT IS COUNTS AND DISTANCES ONLY: N, resolved/unresolved counts, P50, P95,
max in km (1 decimal) and how many stations exceed each candidate cap. It never
prints a coordinate, id or name, including on errors.

  python3 scripts/registry-reference-distance-p95.py --input registry.json
  python3 scripts/registry-reference-distance-p95.py --nws-base-url http://127.0.0.1:PORT < registry.json
"""
import argparse, json, math, re, sys, time, urllib.request, urllib.error

EARTH_KM = 6371.0
DEFAULT_CAPS = (3.4, 11.0, 12.0, 15.0, 20.0)


def haversine_km(a, b):
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dl = math.radians(b[1] - a[1])
    h = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return EARTH_KM * 2 * math.asin(math.sqrt(h))


def coarse(v):
    return round(v * 100) / 100  # same 0.01 degree rounding as the pending surface


def percentile(sorted_vals, q):
    """Linear interpolation between closest ranks (numpy default)."""
    if not sorted_vals:
        return None
    pos = (len(sorted_vals) - 1) * q
    lo, hi = math.floor(pos), math.ceil(pos)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (pos - lo)


def parse_points(text):
    pts = []
    text = text.strip()
    if text[:1] in "[{":
        doc = json.loads(text)
        items = doc.get("stations", []) if isinstance(doc, dict) else doc
        for it in items:
            loc = it.get("location", it) if isinstance(it, dict) else {}
            try:
                lat, lon = float(loc["latitude"]), float(loc["longitude"])
            except (KeyError, TypeError, ValueError):
                pts.append(None)
                continue
            pts.append((lat, lon) if math.isfinite(lat) and math.isfinite(lon) else None)
    else:
        for line in text.splitlines():
            if not line.strip():
                continue
            try:
                lat, lon = (float(x) for x in line.split(",")[:2])
                pts.append((lat, lon))
            except ValueError:
                pts.append(None)
    return pts


def rebase(base, url):
    if url.startswith(base):
        return url
    m = re.match(r"^https?://[^/]+(/.*)?$", url)
    if m:
        return base + (m.group(1) or "/")
    if url.startswith("/"):
        return base + url
    raise ValueError("unusable URL")


def http_get(url, timeout=15, retries=3):
    req = urllib.request.Request(url, headers={"User-Agent": "wrfcoin-owner-registry-p95", "Accept": "application/geo+json"})
    for i in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read().decode()
        except urllib.error.HTTPError as e:
            if e.code in (429, 503) and i + 1 < retries:
                time.sleep(2 * (i + 1))
                continue
            raise
    raise RuntimeError("unreachable")


def nearest_station(base, point, get=http_get, cache=None):
    """First usable feature of the NWS station list for the coarse point."""
    key = f"{coarse(point[0]):.2f},{coarse(point[1]):.2f}"
    if cache is not None and key in cache:
        return cache[key]
    pts = json.loads(get(f"{base}/points/{key}"))
    stations_url = rebase(base, pts["properties"]["observationStations"])
    feats = json.loads(get(stations_url)).get("features", [])
    for f in feats:
        try:
            if not f["properties"]["stationIdentifier"].strip():
                continue
            lon, lat = float(f["geometry"]["coordinates"][0]), float(f["geometry"]["coordinates"][1])
        except (KeyError, TypeError, ValueError, IndexError):
            continue
        if math.isfinite(lat) and math.isfinite(lon):
            if cache is not None:
                cache[key] = (lat, lon)
            return (lat, lon)
    raise LookupError("no usable station")


def compute(points, base, get=http_get):
    """Returns (sorted distances, unresolved count). Never keeps ids."""
    dists, unresolved, cache = [], 0, {}
    for p in points:
        if p is None:
            unresolved += 1
            continue
        try:
            ref = nearest_station(base, p, get, cache)
        except Exception:  # message may embed a URL with coordinates: drop it
            unresolved += 1
            continue
        dists.append(haversine_km((coarse(p[0]), coarse(p[1])), ref))
    return sorted(dists), unresolved


def report(dists, unresolved, caps):
    n = len(dists) + unresolved
    lines = [f"stations in listing      : {n}", f"resolved                 : {len(dists)}", f"unresolved               : {unresolved}"]
    if dists:
        p95 = percentile(dists, 0.95)
        lines += [f"nearest-reference P50 km : {percentile(dists, 0.5):.1f}",
                  f"nearest-reference P95 km : {p95:.1f}",
                  f"nearest-reference max km : {dists[-1]:.1f}"]
        for c in caps:
            lines.append(f"stations farther than {c:g} km: {sum(1 for d in dists if round(d, 6) > c)} of {len(dists)}")
        lines.append(f"suggested WRFCOIN_ATTESTER_MAX_REFERENCE_KM (P95 rounded up to 0.1): {math.ceil(round(p95, 6) * 10) / 10:.1f}")
        if len(dists) < 20:
            lines.append(f"WARNING: only {len(dists)} resolved station(s); a P95 over so few points is weak evidence. Owner judgement required.")
    else:
        lines.append("no station resolved: no percentile available")
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--input", help="registry listing file (default: stdin)")
    ap.add_argument("--nws-base-url", default="https://api.weather.gov")
    ap.add_argument("--caps", default=",".join(f"{c:g}" for c in DEFAULT_CAPS))
    a = ap.parse_args(argv)
    text = open(a.input).read() if a.input else sys.stdin.read()
    try:
        pts = parse_points(text)
    except Exception:
        print("input is not a recognisable registry listing (details withheld)", file=sys.stderr)
        return 2
    dists, bad = compute(pts, a.nws_base_url.rstrip("/"))
    print(report(dists, bad, [float(c) for c in a.caps.split(",")]))
    return 0 if dists else 1


if __name__ == "__main__":
    sys.exit(main())
