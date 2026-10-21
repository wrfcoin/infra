#!/usr/bin/env bash
# =============================================================================
# Tailnet-only full-API route for the mobile app (mobile#44, "option C")
# =============================================================================
# The public funnel edge admits only the onboarding allowlist
# (public_onboarding.caddy), so a phone pointed at the funnel host gets 404 for
# /api/wallet/*, /api/oracle/submit-data and GET /api/weather/stations, and the
# on-device earn loop cannot run. This script manages ONE `tailscale serve`
# route that gives tailnet devices the full /api:
#
#   https://<node>.ts.net:9444/api/*  ->  http://127.0.0.1:5000/api/*
#       (tailscale serve, TLS)            (frontend nginx -> wrfcoin-backend:4001)
#
# The hop is the same frontend-nginx -> backend path the dashboard's /api uses,
# so rate-limit identity sees the same proxy chain (backend#1230, infra#1063).
#
# WHAT KEEPS IT TAILNET-ONLY (no single property does it alone)
#   - This script never runs `tailscale funnel`, and never `serve reset`. A reset
#     would also delete the approved faucet serve on 8080.
#     Beware: `tailscale funnel 9444` does NOT fail. Its positional argument is
#     the upstream, so it would publish Funnel's own 443 proxying to
#     localhost:9444. Never run it.
#   - `verify` checks the live Serve config. :9444 must be exactly the route
#     below, with no AllowFunnel. It also fails if ANY Funnel-enabled handler
#     proxies to the frontend upstream, loopback port 5000 in any spelling:
#     localhost., LOCALHOST, 127.1, [::1], [::ffff:127.0.0.1], 0.0.0.0, and so on.
#   - The tailnet ACL scopes :9444 to the owner's own Tailscale login (user-scoped
#     grant, owner ruling 2026-09-27; no device tags). This is REQUIRED, and it
#     is an owner step in the window; see TAILNET_API_ROUTE-mobile44.md.
#   - From outside the tailnet, probe_public_exposure_external.sh requires 9444
#     to be closed.
#
# WRITES ARE TRANSACTIONAL (enable, disable)
#   - ONE WRITER: an exclusive flock on $TAILNET_API_LOCK (default
#     ~/.wrfcoin-tailnet-api/serve.lock) is held for the whole transaction. A
#     second run refuses immediately instead of interleaving.
#   - EVIDENCE: the pre-write Serve config is saved to an evidence directory
#     ($TAILNET_API_EVIDENCE_DIR, default ~/.wrfcoin-tailnet-api/<utc>-<cmd>)
#     before anything is written. If that fails, nothing is written. Later
#     evidence writes are best-effort and never block a rollback; a failed one
#     is named in the final report.
#   - STRICT READS: every status read is schema-checked (TCP / Web / Handlers /
#     AllowFunnel shapes). A malformed config is a failure, never a crash.
#   - ONE RECOVERY BOUNDARY: after the write, ANY failure goes through one
#     recovery routine, including an unexpected exception. Recovery:
#       1. turns :9444 off (scoped);
#       2. restores an unrelated entry ONLY if it still equals what this
#          script's own write left there (the snapshot after the write). Before
#          EVERY mutating restore command it re-reads the port and requires
#          exactly the state this run's previous command left: absent after an
#          `off`, and each handler added so far after an add. Anything else is
#          another writer. Recovery then stops, writes nothing more, never
#          adopts that state as its own, and reports a conflict;
#       3. re-reads and compares with the saved config.
#     It reports ROLLED_BACK only on an exact match, and never claims "removed"
#     when `off` failed. Otherwise it reports ROLLBACK_INCOMPLETE, naming what
#     differs, with the evidence directory for a manual restore (never
#     `serve reset`).
#   - Residual: an external edit that lands between the pre-write read and this
#     script's own write cannot be told apart from drift the write caused. The
#     lock rules out a second copy of this script; the owner runs it in a
#     window.
#
# USAGE (on CT101, owner present; see TAILNET_API_ROUTE-mobile44.md)
#   tailnet-api-serve.sh status                 # show the 9444 state, read-only
#   tailnet-api-serve.sh verify [--probe-url https://<node>.ts.net:9444]
#   tailnet-api-serve.sh enable [--skip-upstream-check]
#   tailnet-api-serve.sh disable
#
# enable and disable are idempotent. enable refuses to overwrite a different
# 9444 config. Exit codes: 0 ok, 1 refused/failed (after recovery), 2 usage.
#
# TAILSCALE_BIN / CURL_BIN override the binaries (tests use stubs).
# TAILNET_API_TEST_FAULT is a test-only fault seam. It MUST stay unset in any
# real run. enable/disable refuse to start if it is set while TAILSCALE_BIN is
# not overridden, i.e. against the real tailscale CLI (see the runbook).
# =============================================================================
set -uo pipefail

case "${1:-}" in
  status|verify|enable|disable) ;;
  *) sed -n '2,/^set -uo pipefail$/p' "$0" | sed '$d' >&2; exit 2 ;;
esac
command -v python3 >/dev/null 2>&1 || { echo "TAILNET_API_ROUTE=FAIL python3 is required" >&2; exit 1; }

exec python3 - "$@" <<'PY'
import datetime, fcntl, ipaddress, json, os, socket, subprocess, sys, urllib.parse

PORT, MOUNT = "9444", "/api"
UPSTREAM = "http://127.0.0.1:5000/api"
UPSTREAM_PROBE = "http://127.0.0.1:5000/api/build"
FRONTEND_PORT = 5000
TS = os.environ.get("TAILSCALE_BIN", "tailscale")
CURL = os.environ.get("CURL_BIN", "curl")
SUFFIX = ":" + PORT
STATE_ROOT = os.path.join(os.path.expanduser("~"), ".wrfcoin-tailnet-api")


class Fail(Exception):
    pass


class StopRecovery(Exception):
    """Recovery met a state it did not produce; nothing further is written."""


def out(line):
    print(line, flush=True)


def err(line):
    print(line, file=sys.stderr, flush=True)


def usage():
    err("usage: tailnet-api-serve.sh status | verify [--probe-url URL] | enable [--skip-upstream-check] | disable")
    sys.exit(2)


def ts(*args):
    try:
        return subprocess.run([TS, *args], capture_output=True, text=True)
    except OSError as error:
        return subprocess.CompletedProcess([TS, *args], 127, "", str(error))


# --- strict Serve config reads ---------------------------------------------------
def _check_schema(data):
    """Raise Fail unless `data` has the ipn.ServeConfig shapes this script reads."""
    def need(cond, what):
        if not cond:
            raise Fail(f"'tailscale serve status --json' is malformed: {what}")
    need(isinstance(data, dict), "not a JSON object")
    tcp = data.get("TCP", {})
    need(isinstance(tcp, dict), "TCP is not an object")
    for port, entry in tcp.items():
        need(isinstance(port, str) and port.isdigit(), f"TCP key {port!r} is not a port")
        need(isinstance(entry, dict), f"TCP[{port}] is not an object")
        for key in ("HTTPS", "HTTP"):
            need(key not in entry or isinstance(entry[key], bool), f"TCP[{port}].{key} is not a boolean")
        for key in ("TCPForward", "TerminateTLS"):
            need(key not in entry or isinstance(entry[key], str), f"TCP[{port}].{key} is not a string")
    web = data.get("Web", {})
    need(isinstance(web, dict), "Web is not an object")
    for host, cfg in web.items():
        need(isinstance(host, str) and ":" in host, f"Web key {host!r} is not host:port")
        need(isinstance(cfg, dict), f"Web[{host}] is not an object")
        handlers = cfg.get("Handlers", {})
        need(isinstance(handlers, dict), f"Web[{host}].Handlers is not an object")
        for path, h in handlers.items():
            need(isinstance(path, str) and path.startswith("/"), f"Web[{host}] handler path {path!r}")
            need(isinstance(h, dict), f"Web[{host}].Handlers[{path}] is not an object")
            need("Proxy" not in h or isinstance(h["Proxy"], str), f"Web[{host}].Handlers[{path}].Proxy is not a string")
    funnel = data.get("AllowFunnel", {})
    need(isinstance(funnel, dict), "AllowFunnel is not an object")
    for key, value in funnel.items():
        need(isinstance(value, bool), f"AllowFunnel[{key}] is not a boolean")


def snapshot():
    """The live Serve config as a schema-checked dict. Raises Fail; never partial."""
    r = ts("serve", "status", "--json")
    if r.returncode != 0:
        tail = (r.stderr.strip().splitlines() or ["no output"])[-1]
        raise Fail(f"cannot read 'tailscale serve status --json' (exit {r.returncode}): {tail}")
    text = r.stdout.strip() or "{}"
    try:
        data = json.loads(text)
    except ValueError:
        raise Fail("'tailscale serve status --json' returned malformed JSON")
    _check_schema(data)
    return data


def ours(data):
    tcp = (data.get("TCP") or {}).get(PORT)
    web = {k: v for k, v in (data.get("Web") or {}).items() if k.endswith(SUFFIX)}
    funnel = {k: v for k, v in (data.get("AllowFunnel") or {}).items() if k.endswith(SUFFIX)}
    return tcp, web, funnel


def others(data):
    """Everything except the :9444 entries, with emptied containers dropped."""
    copy = json.loads(json.dumps(data))
    (copy.get("TCP") or {}).pop(PORT, None)
    for key in ("Web", "AllowFunnel"):
        section = copy.get(key) or {}
        for k in [k for k in section if k.endswith(SUFFIX)]:
            del section[k]
    return {k: v for k, v in copy.items() if v not in ({}, None, [])}


def state(data):
    tcp, web, funnel = ours(data)
    if any(funnel.values()):
        return f"funnel: AllowFunnel is set for {sorted(k for k, v in funnel.items() if v)}"
    if tcp is None and not web:
        return "absent"
    if tcp is None or tcp.get("HTTPS") is not True or tcp.get("TCPForward"):
        return f"conflict: TCP[{PORT}] is {tcp!r}, not an HTTPS web serve"
    if len(web) != 1:
        return f"conflict: {len(web)} web hosts on :{PORT}, expected exactly 1"
    handlers = (next(iter(web.values())) or {}).get("Handlers") or {}
    if handlers == {MOUNT: {"Proxy": UPSTREAM}}:
        return "exact"
    return f"conflict: handlers are {handlers!r}, expected {{{MOUNT!r}: Proxy {UPSTREAM}}}"


# --- Funnel exposure of the frontend upstream -------------------------------------
def _local_ip(host):
    """True when `host` names this machine: loopback or unspecified, any spelling."""
    host = host.lower().rstrip(".")
    if host == "localhost" or host.endswith(".localhost"):
        return True
    if host.startswith("[") and host.endswith("]"):
        host = host[1:-1]
    try:
        address = ipaddress.ip_address(host.split("%", 1)[0])
    except ValueError:
        try:  # inet_aton accepts the browser/libc shorthands: 127.1, 0x7f.0.0.1, 2130706433
            address = ipaddress.IPv4Address(socket.inet_aton(host))
        except (OSError, ValueError):
            return False
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped is not None:
        address = address.ipv4_mapped
    return address.is_loopback or address.is_unspecified or (
        isinstance(address, ipaddress.IPv4Address) and address in ipaddress.IPv4Network("0.0.0.0/8"))


def targets_frontend(proxy):
    """True when a Serve Proxy target reaches this host's port 5000."""
    text = proxy.strip()
    if "://" not in text:
        text = ("http://127.0.0.1:" + text) if text.isdigit() else ("http://" + text)
    try:
        parts = urllib.parse.urlsplit(text)
        port = parts.port or {"http": 80, "https": 443}.get(parts.scheme.lower())
    except ValueError:
        return True  # an unparseable Funnel target is treated as exposure, never as safe
    host = parts.netloc.rsplit("@", 1)[-1]
    host = host[:host.rindex("]") + 1] if host.startswith("[") else host.rsplit(":", 1)[0]
    return port == FRONTEND_PORT and _local_ip(host)


def funnel_exposure(data):
    """Funnel-enabled handlers whose target is this host's port 5000."""
    allowed = {k for k, v in (data.get("AllowFunnel") or {}).items() if v}
    hits = []
    for host in sorted(allowed):
        handlers = ((data.get("Web") or {}).get(host) or {}).get("Handlers") or {}
        for path, h in sorted(handlers.items()):
            proxy = h.get("Proxy")
            if isinstance(proxy, str) and targets_frontend(proxy):
                hits.append(f"{host}{path} -> {proxy}")
    return hits


# --- one writer, best-effort evidence -----------------------------------------------
def refuse_test_seam_in_production():
    if os.environ.get("TAILNET_API_TEST_FAULT") and not os.environ.get("TAILSCALE_BIN"):
        raise Fail("TAILNET_API_TEST_FAULT is set, but it is a test-only fault seam and must stay "
                   "unset against the real tailscale CLI; unset it. Nothing written")


def take_lock():
    path = os.environ.get("TAILNET_API_LOCK") or os.path.join(STATE_ROOT, "serve.lock")
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise Fail(f"another tailnet-api-serve run holds {path}; nothing written")
    except OSError as error:
        raise Fail(f"cannot take the lock {path}: {error}; nothing written")
    return fd  # held until the process exits


class Evidence:
    def __init__(self, command):
        root = os.environ.get("TAILNET_API_EVIDENCE_DIR") or STATE_ROOT
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        self.dir = os.path.join(root, f"{stamp}-{command}")
        self.failed = []
        try:
            os.makedirs(self.dir, mode=0o700)
        except OSError as error:
            raise Fail(f"cannot create evidence directory {self.dir}: {error}; nothing written")

    def save(self, name, data, required=False):
        try:
            with open(os.path.join(self.dir, name), "w", encoding="utf-8") as fh:
                json.dump(data, fh, indent=2, sort_keys=True)
                fh.write("\n")
        except OSError as error:
            if required:
                raise Fail(f"cannot write evidence {name}: {error}; nothing written")
            self.failed.append(f"{name} ({error.__class__.__name__})")

    def log(self, line):
        try:
            with open(os.path.join(self.dir, "restore.log"), "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except OSError as error:
            if not any(f.startswith("restore.log") for f in self.failed):
                self.failed.append(f"restore.log ({error.__class__.__name__})")

    def note(self):
        where = f"Evidence: {self.dir}"
        return where + (f" (evidence writes FAILED: {', '.join(self.failed)})" if self.failed else "")


# --- recovery ---------------------------------------------------------------------
def port_kind(entry):
    if not isinstance(entry, dict):
        return None
    if entry.get("TCPForward"):
        return "tls-terminated-tcp" if entry.get("TerminateTLS") else "tcp"
    if entry.get("HTTPS"):
        return "https"
    if entry.get("HTTP"):
        return "http"
    return None


def port_view(data, port):
    """Everything the config says about one unrelated port: its TCP entry and web hosts."""
    return {
        "tcp": (data.get("TCP") or {}).get(port),
        "web": {k: v for k, v in (data.get("Web") or {}).items() if k.rsplit(":", 1)[-1] == port},
    }


def port_commands(target_view, current_view, port):
    """(steps, unrestorable) that turn this one port from current into target.
    Each step is (command, the port_view that command leaves when nobody else
    writes), so recovery can check, before EVERY command, that the port is
    still exactly what this run's previous command left. Nothing is planned for
    a port that cannot be restored exactly; a partial restore is never started."""
    steps, bad = [], []
    empty = {"tcp": None, "web": {}}
    entry = target_view["tcp"]
    kind = port_kind(entry)
    adds = []
    if entry is None:
        pass
    elif kind in ("tcp", "tls-terminated-tcp"):
        if target_view["web"]:
            bad.append(f"TCP[{port}] forwards TCP but also has web handlers; not restorable exactly")
        adds.append((["serve", "--bg", f"--{kind}={port}", f"tcp://{entry['TCPForward']}"],
                     {"tcp": entry, "web": {}}))
    elif kind in ("https", "http"):
        hosts = sorted(target_view["web"].items())
        if entry != {kind.upper(): True}:
            bad.append(f"TCP[{port}] = {entry!r} carries fields the serve CLI cannot set")
        if len(hosts) != 1:
            bad.append(f":{port} has {len(hosts)} web hosts; the serve CLI restores exactly one")
        else:
            host, cfg = hosts[0]
            handlers = {}
            for path, h in sorted(((cfg or {}).get("Handlers") or {}).items()):
                if set(h) != {"Proxy"}:
                    bad.append(f"{host}{path}: handler {h!r} is not a plain Proxy")
                    continue
                handlers = dict(handlers, **{path: {"Proxy": h["Proxy"]}})
                adds.append((["serve", "--bg", f"--{kind}={port}", f"--set-path={path}", h["Proxy"]],
                             {"tcp": {kind.upper(): True}, "web": {host: {"Handlers": dict(handlers)}}}))
    else:
        bad.append(f"TCP[{port}] = {entry!r} has no known serve form")
    if bad:
        return [], bad
    current_kind = port_kind(current_view["tcp"])
    if current_kind:
        steps.append((["serve", f"--{current_kind}={port}", "off"], empty))
    return steps + adds, bad


def recover(before, evidence, reason, owned):
    """Return the config to `before` minus :9444, restoring only entries this
    script's own write changed. `owned` is the snapshot taken right after that
    write (None when it could not be read, so no drift can be attributed).
    Always exits 1: the operation failed. The message says whether recovery
    was complete."""
    err(f"TAILNET_API_ROUTE=FAIL {reason}")
    r = ts("serve", f"--https={PORT}", "off")
    evidence.log(f"serve --https={PORT} off -> exit {r.returncode} {r.stderr.strip()}")
    why = [] if r.returncode == 0 else [f"`serve --https={PORT} off` failed (exit {r.returncode}); :{PORT} was NOT removed"]
    restored = 0
    try:
        current = snapshot()
        evidence.save("after-off.json", current)
        target = others(before)
        ports = sorted({p for d in (target, others(current)) for p in (d.get("TCP") or {})}, key=lambda p: (len(p), p))
        for port in ports:
            want, have = port_view(target, port), port_view(others(current), port)
            if want == have:
                continue
            if owned is None:
                why.append(f"TCP[{port}] differs from before.json but the post-write state was unreadable, so the change cannot be attributed to this run; left as is")
                continue
            if have != port_view(others(owned), port):
                why.append(f"TCP[{port}] was changed by another writer after this run's write; left as is (conflict)")
                continue
            steps, bad = port_commands(want, have, port)
            why += bad
            expected = have
            for cmd, leaves in steps:
                # Before EVERY mutating command, the port must be exactly what this
                # run's previous command left (or, before the first, what this
                # run's write left). Anything else is another writer: stop, change
                # nothing more, and never adopt that state as ours.
                live = port_view(others(snapshot()), port)
                if live != expected:
                    why.append(f"TCP[{port}] changed by another writer during recovery (before `{' '.join(cmd)}`); "
                               "left as is and recovery stopped (conflict)")
                    raise StopRecovery()
                rc = ts(*cmd)
                evidence.log(f"{' '.join(cmd)} -> exit {rc.returncode} {rc.stderr.strip()}")
                restored += 1
                if rc.returncode != 0:
                    why.append(f"`{' '.join(cmd)}` failed (exit {rc.returncode}); recovery stopped")
                    raise StopRecovery()
                expected = leaves
        final = snapshot()
        evidence.save("final.json", final)
    except StopRecovery:
        try:
            final = snapshot()
            evidence.save("final.json", final)
        except Exception:  # noqa: BLE001 - the report below is the evidence
            pass
        err(f"TAILNET_API_ROUTE=ROLLBACK_INCOMPLETE {'; '.join(why)}. {evidence.note()} "
            "(before.json is the config to restore by hand; never serve reset)")
        sys.exit(1)
    except Exception as error:  # noqa: BLE001 - recovery must report, never crash
        detail = str(error) if isinstance(error, Fail) else f"{error.__class__.__name__}: {error}"
        why.append(f"recovery could not verify the result: {detail}")
        err(f"TAILNET_API_ROUTE=ROLLBACK_INCOMPLETE {'; '.join(why)}. {evidence.note()} "
            "(before.json is the config to restore by hand; never serve reset)")
        sys.exit(1)
    if state(final) != "absent" and r.returncode == 0:
        why.append(f":{PORT} state is still '{state(final)}'")
    if others(final) != others(before) and not any("differs" in w or "conflict" in w for w in why):
        why.append("unrelated entries still differ from before.json")
    if not why:
        extra = f"; restored {restored} serve command(s) for unrelated entries" if restored else ""
        err(f"TAILNET_API_ROUTE=ROLLED_BACK :{PORT} removed and the serve config equals the pre-write "
            f"snapshot{extra}. {evidence.note()}")
    else:
        err(f"TAILNET_API_ROUTE=ROLLBACK_INCOMPLETE {'; '.join(why)}. {evidence.note()} "
            "(before.json is the config to restore by hand; never serve reset)")
    sys.exit(1)


# --- commands --------------------------------------------------------------------
def probe(url):
    try:
        r = subprocess.run([CURL, "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "10", url],
                           capture_output=True, text=True)
    except OSError:
        return "000"
    return r.stdout.strip() or "000"


def cmd_status(args):
    if args:
        usage()
    data = snapshot()
    st = state(data)
    out(f"TAILNET_API_ROUTE_STATE={st} port={PORT} mount={MOUNT} upstream={UPSTREAM}")
    exposure = funnel_exposure(data)
    for hit in exposure:
        out(f"TAILNET_API_ROUTE_EXPOSURE a Funnel-enabled handler reaches the frontend upstream: {hit}")
    return 0 if st in ("absent", "exact") and not exposure else 1


def cmd_verify(args):
    probe_url = None
    while args:
        if args[0] == "--probe-url" and len(args) >= 2:
            probe_url, args = args[1], args[2:]
        else:
            usage()
    data = snapshot()
    st = state(data)
    if st != "exact":
        raise Fail(f"state is '{st}', expected exact tailnet-only route")
    exposure = funnel_exposure(data)
    if exposure:
        raise Fail(f"a Funnel-enabled handler reaches the frontend upstream: {exposure}")
    out(f"  ok serve config: :{PORT}{MOUNT} -> {UPSTREAM}, no AllowFunnel, no Funnel to the upstream")
    if probe_url:
        base = probe_url.rstrip("/")
        host = base.split("://", 1)[-1]
        if not (base.startswith("https://") and host.endswith(".ts.net" + SUFFIX)):
            raise Fail(f"--probe-url must be https://<node>.ts.net:{PORT}, got {probe_url}")
        code = probe(base + "/api/build")
        if code != "200":
            raise Fail(f"{base}/api/build answered {code}, expected 200 (backend via frontend nginx)")
        out(f"  ok {base}/api/build -> 200")
        code = probe(base + "/")
        if code != "404":
            raise Fail(f"{base}/ answered {code}, expected 404 (only {MOUNT} is mounted)")
        out(f"  ok {base}/ -> 404 (only {MOUNT} mounted)")
    out("TAILNET_API_ROUTE=VERIFIED")
    return 0


def cmd_enable(args):
    check_upstream = True
    for a in args:
        if a == "--skip-upstream-check":
            check_upstream = False
        else:
            usage()
    refuse_test_seam_in_production()
    take_lock()
    before = snapshot()
    st = state(before)
    if st == "exact":
        out(f"TAILNET_API_ROUTE=UNCHANGED already enabled on :{PORT}")
        return 0
    if st != "absent":
        raise Fail(f"refusing to overwrite :{PORT} ({st}); inspect 'tailscale serve status' and disable deliberately")
    if check_upstream:
        code = probe(UPSTREAM_PROBE)
        if code != "200":
            raise Fail(f"upstream {UPSTREAM_PROBE} answered {code}; is wrfcoin-frontend up on 127.0.0.1:5000?")
    evidence = Evidence("enable")
    evidence.save("before.json", before, required=True)
    owned = None
    try:
        r = ts("serve", "--bg", f"--https={PORT}", f"--set-path={MOUNT}", UPSTREAM)
        evidence.log(f"serve --bg --https={PORT} --set-path={MOUNT} {UPSTREAM} -> exit {r.returncode} {r.stderr.strip()}")
        # Test-only fault seam (unset in any real run): proves that an unexpected,
        # non-Fail exception after the write still goes through recovery.
        if os.environ.get("TAILNET_API_TEST_FAULT") == "after-write":
            raise RuntimeError("injected fault after the serve write")
        owned = snapshot()
        evidence.save("after-write.json", owned)
        if r.returncode != 0:
            raise Fail(f"'tailscale serve' exited {r.returncode}")
        st = state(owned)
        if st != "exact":
            raise Fail(f"after enable the state is '{st}', not exact")
        if others(owned) != others(before):
            raise Fail(f"enable changed a serve entry other than :{PORT}")
        exposure = funnel_exposure(owned)
        if exposure:
            raise Fail(f"a Funnel-enabled handler reaches the frontend upstream: {exposure}")
    except Exception as error:  # noqa: BLE001 - every post-write failure is recovered
        detail = str(error) if isinstance(error, Fail) else f"{error.__class__.__name__}: {error}"
        recover(before, evidence, f"after enable: {detail}", owned)
    out(f"TAILNET_API_ROUTE=ENABLED :{PORT}{MOUNT} -> {UPSTREAM} (serve only, no Funnel). {evidence.note()}")
    return 0


def cmd_disable(args):
    if args:
        usage()
    refuse_test_seam_in_production()
    take_lock()
    before = snapshot()
    if state(before) == "absent":
        out(f"TAILNET_API_ROUTE=UNCHANGED already absent on :{PORT}")
        return 0
    evidence = Evidence("disable")
    evidence.save("before.json", before, required=True)
    owned = None
    try:
        r = ts("serve", f"--https={PORT}", "off")
        evidence.log(f"serve --https={PORT} off -> exit {r.returncode} {r.stderr.strip()}")
        owned = snapshot()
        evidence.save("after-off.json", owned)
        if r.returncode != 0 or state(owned) != "absent" or others(owned) != others(before):
            raise Fail(f"disable did not leave exactly the pre-disable config minus :{PORT} "
                       f"(off exit {r.returncode}, state '{state(owned)}')")
    except Exception as error:  # noqa: BLE001
        detail = str(error) if isinstance(error, Fail) else f"{error.__class__.__name__}: {error}"
        recover(before, evidence, f"after disable: {detail}", owned)
    out(f"TAILNET_API_ROUTE=DISABLED :{PORT}. {evidence.note()}")
    return 0


def main(argv):
    command, args = argv[0], argv[1:]
    handler = {"status": cmd_status, "verify": cmd_verify, "enable": cmd_enable, "disable": cmd_disable}[command]
    try:
        return handler(args)
    except Fail as error:
        err(f"TAILNET_API_ROUTE=FAIL {error}")
        return 1


sys.exit(main(sys.argv[1:]))
PY
