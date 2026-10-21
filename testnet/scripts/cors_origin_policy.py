#!/usr/bin/env python3
"""The one CORS_ORIGIN policy for the testnet gates (infra#1056).

Both testnet/check-env-completeness.sh (pre-`up`) and
testnet/scripts/render-release-manifest.sh (release gate) import this. There is
deliberately no second copy: two copies of an origin parser drift, and codex's
review of #1060 found exactly that kind of gap in the string-matching versions
this replaces.

A value is the backend's format: a comma-separated list, each entry trimmed.
Each entry must be an ORIGIN a real browser can be served from:

  * syntax    https://host[:port]. No userinfo, path, query, fragment, or
              wildcard, and the port must be 1-65535.
  * scheme    https only. There is no http exception: every testnet browser
              origin is TLS (funnel host, public edge). Local development uses
              config/dev.env.example, which neither gate reads.
  * host      not loopback, not unspecified, not `localhost`/`*.localhost`,
              and not a wildcard. IP literals are normalised the way browsers
              normalise them (WHATWG URL host parsing), so every one of these is
              recognised as loopback:
              [0:0:0:0:0:0:0:1], [::ffff:127.0.0.1], 127.1, 0x7f.0.0.1,
              2130706433 and LOCALHOST.

CLI:
  cors_origin_policy.py --env-gate RENDERED.json
      prints check-env-completeness lines; exit 1 on any problem
  cors_origin_policy.py --check VALUE
      prints one line per bad entry; exit 1 on any problem
"""
import ipaddress
import json
import re
import sys

_ORIGIN = re.compile(
    r"^(?P<scheme>[A-Za-z][A-Za-z0-9+.-]*)://"
    r"(?P<host>\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+)"
    r"(?::(?P<port>[0-9]{1,5}))?$"
)
_NUMBER = re.compile(r"^(0[xX][0-9A-Fa-f]*|0[0-7]*|[1-9][0-9]*)$")

LOOPBACK, UNSPECIFIED, SYNTAX, SCHEME = "loopback", "unspecified", "syntax", "scheme"
REASONS = {
    SYNTAX: "is not a scheme://host[:port] origin (no wildcard, no path)",
    LOOPBACK: "is a loopback origin; no real browser is served from it (infra#1056)",
    UNSPECIFIED: "is an unspecified-address origin; no real browser is served from it (infra#1056)",
    SCHEME: "is not an https origin (testnet browser origins are TLS)",
}


def _whatwg_ipv4(host):
    """The IPv4 address a browser would parse `host` as, None if it is a domain,
    or False if it ends in a number but is not a valid IPv4 (the URL is invalid)."""
    parts = host.split(".")
    if parts and parts[-1] == "":
        parts = parts[:-1]
    if not parts or not _NUMBER.match(parts[-1]) and not re.fullmatch(r"[0-9]+", parts[-1]):
        return None
    if len(parts) > 4:
        return False
    numbers = []
    for part in parts:
        if not _NUMBER.match(part):
            return False
        if part[:2] in ("0x", "0X"):
            numbers.append(int(part[2:] or "0", 16))
        elif len(part) > 1 and part[0] == "0":
            numbers.append(int(part, 8))
        else:
            numbers.append(int(part))
    if any(n > 255 for n in numbers[:-1]) or numbers[-1] >= 256 ** (5 - len(numbers)):
        return False
    value = numbers[-1]
    for i, n in enumerate(numbers[:-1]):
        value += n * 256 ** (3 - i)
    return ipaddress.IPv4Address(value)


def _classify_ip(address):
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped is not None:
        address = address.ipv4_mapped
    if address.is_loopback:
        return LOOPBACK
    if address.is_unspecified or (
        isinstance(address, ipaddress.IPv4Address) and address in ipaddress.IPv4Network("0.0.0.0/8")
    ):
        return UNSPECIFIED
    return None


def entry_problem(entry):
    """None when `entry` is an acceptable origin, else one of the REASONS keys."""
    match = _ORIGIN.match(entry)
    if not match:
        return SYNTAX
    host = match.group("host").lower()
    port = match.group("port")
    if port is not None and not 1 <= int(port) <= 65535:
        return SYNTAX
    if host.startswith("["):
        try:
            verdict = _classify_ip(ipaddress.IPv6Address(host[1:-1]))
        except ValueError:
            return SYNTAX
    else:
        ipv4 = _whatwg_ipv4(host)
        if ipv4 is False:
            return SYNTAX
        if ipv4 is not None:
            verdict = _classify_ip(ipv4)
        else:
            name = host.rstrip(".")
            if not name or any(not label for label in name.split(".")):
                return SYNTAX
            verdict = LOOPBACK if name == "localhost" or name.endswith(".localhost") else None
    if verdict:
        return verdict
    if match.group("scheme").lower() != "https":
        return SCHEME
    return None


def value_problems(value):
    """[(entry, reason-key)] for a CORS_ORIGIN value; an empty value is one problem."""
    if not str(value or "").strip():
        return [("", "empty")]
    out = []
    for entry in (e.strip() for e in str(value).split(",")):
        problem = entry_problem(entry)
        if problem:
            out.append((entry, problem))
    return out


def rendered_readers(services):
    """{service: CORS_ORIGIN} for every rendered service whose environment has it."""
    readers = {}
    for name, spec in sorted((services or {}).items()):
        env = spec.get("environment") if isinstance(spec, dict) else None
        if isinstance(env, dict) and "CORS_ORIGIN" in env:
            readers[name] = str(env.get("CORS_ORIGIN") or "")
    return readers


def describe(entry, key):
    if key == "empty":
        return "CORS_ORIGIN is empty (no default since infra#1056)"
    return f"CORS_ORIGIN entry {entry!r} {REASONS[key]}"


def _env_gate(path):
    with open(path, encoding="utf-8") as handle:
        services = json.load(handle).get("services") or {}
    readers = rendered_readers(services)
    problems, good = {}, set()
    for name, value in readers.items():
        bad = value_problems(value)
        for entry, key in bad:
            if key == "empty":
                line = "  MISSING or EMPTY: CORS_ORIGIN (rendered empty; no default since infra#1056)"
            else:
                line = f"  UNSAFE CORS_ORIGIN: '{entry}' {REASONS[key]}"
            problems.setdefault(line, []).append(name)
        good.update(e.strip() for e in value.split(",") if e.strip() and not entry_problem(e.strip()))
    for line, names in problems.items():
        print(f"{line} [effective in: {', '.join(names)}]")
    if not problems:
        print(f"  CORS_ORIGIN: {len(good)} non-loopback origin(s) (effective render, {len(readers)} reader(s))")
    return 1 if problems else 0


def main(argv):
    if len(argv) == 3 and argv[1] == "--env-gate":
        return _env_gate(argv[2])
    if len(argv) == 3 and argv[1] == "--check":
        bad = value_problems(argv[2])
        for entry, key in bad:
            print(describe(entry, key))
        return 1 if bad else 0
    print(__doc__.split("CLI:")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
