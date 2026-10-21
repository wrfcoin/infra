#!/usr/bin/env bash
# Render reproducible release-candidate evidence from clean, exact-head checkouts.
set -euo pipefail

# Public artifact catalog mode; legacy deployment evidence is unchanged.
if [[ "${1:-}" == "--downloads" ]]; then
  shift
  exec python3 "$(dirname "${BASH_SOURCE[0]}")/public_release.py" "$@"
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKSPACE="$(cd "${ROOT}/.." && pwd)"
PINS="${ROOT}/testnet/release-pins.env"
CUT_PINS="${ROOT}/testnet/cut-pins.env"
MAX_AGE_HOURS=24
OUT="${ROOT}/testnet/release-manifest.json"

COMPOSE_FILES=()
COMPOSE_ENV_FILE=""
COMPOSE_CONFIG=""
CHECK_RUNNING=0
VERIFY=""
EXEMPT_FILE=""
RELEASE_TREES=()
REQUIRE_TREES=()
STORAGE=0

usage() {
  cat <<'USAGE'
usage: render-release-manifest.sh [--workspace DIR] [--pins FILE] [--out FILE]
         (-f|--compose-file FILE [-f FILE ...] [--env-file FILE] | --compose-config FILE)
         [--check-running] [--exempt FILE] [--release-tree NAME=DIR ...] [--storage]
       render-release-manifest.sh --verify MANIFEST [--pins FILE] [--cut-pins FILE]
         [--max-age-hours N] [--storage]

The gated images are derived from the given compose render: every service
built from Dockerfile.core, .backend-api, .backend, .frontend, .caddy or
testnet/services/faucet/Dockerfile, and every service running a tag they
produce. The faucet is a required service (infra#1121), so render with the
host's COMPOSE_PROFILES (its .env) or the faucet profile active. Pass the same
files (and env file) the host deploys with, including any host-local override.
--compose-config takes an already rendered `docker compose config --format json`.
--check-running (post-deploy) also requires every gated service's container to
use exactly its tag's image (one-shot services: exited 0 from it). The manifest
records the mode; only a check_running manifest is post-deploy evidence.
--verify checks that an existing manifest is a consistent, FRESH check_running
manifest for the CURRENT release (exit 0) and fails (exit 1) on anything else:
every pinned group's revision must equal the current pins (--pins, default
testnet/release-pins.env; core4 must also equal --cut-pins, default
testnet/cut-pins.env), the edge and faucet revisions must be in this infra
checkout with their build context (testnet/edge/, testnet/services/faucet/)
unchanged, and generated_at must be no older than
--max-age-hours (default 24, at most 72) and not in the future. --pins and
--cut-pins must name this checkout's own files, as for a render; any other
file is refused (exit 1). Unreadable manifest or pins,
or a bad --max-age-hours, is VOID (exit 2). A manifest with exemptions (below)
passes only if every exempt record is consistent with its declaration.

With --verify, --exempt FILE must be the same exemption file the manifest was
rendered with (its sha256 and entries are compared, and each exempt revision's
ancestry to the core4 pin is re-checked in --workspace's core4, default the
checkout's parent); --require-release-tree NAME (repeatable) requires that the
manifest was rendered with a verified --release-tree for NAME.

--exempt FILE (infra#1047) names identity-owner services that this release
deliberately leaves on an older core4 image, because recreating them is
forbidden (boot-heal custody). One line per service:
    <service> <sha256:image-id> <40-hex org.opencontainers.image.revision>
Only softhsm-init, softhsm-seed-init and wrfcoin-seed can be exempted. Each
exemption must match the rendered tag's exact image Id and revision label, the
revision must be an ancestor of the core4 pin, the tag must not be shared with
any gated service, and (--check-running) the service's container must run that
exact image, except that wrfcoin-seed (a full core4 node) must NOT be running:
exited from that image, or absent. The exact image Id is the anchor; the
revision label and ancestry are cross-checks. The file is a reviewed, dated
artifact: re-review it for every release instead of carrying it forward.
Exempt services are recorded as EXEMPT, never as FRESH; any
mismatch makes the manifest UNAVAILABLE/STALE, and a malformed, unknown or
unrendered exemption refuses the run.

--storage (infra#944) adds the opt-in `storage` group for the r20 IPFS images:
ipfs-kubo (upstream, never built: the local image must carry the digest pinned by
WRFCOIN_RC_IPFS_KUBO_DIGEST in the pins file) and storage-node (built locally from
storage-providers, whose revision label must equal WRFCOIN_RC_STORAGE_PROVIDERS_COMMIT).
Render with the ipfs-storage profile active. The storage-providers checkout is then
bound like core4/backend/frontend (HEAD == pin, clean, on origin/main). The weather
archive worker runs the backend image and stays in backend-services. Without --storage
nothing changes: the group, the repo and the pins are neither read nor written.
With --verify, --storage requires the manifest to carry a verified storage group (a
manifest that has one is always verified, flag or not).

--release-tree NAME=DIR (infra#1047) binds a non-git deployed tree (a
`git archive` extraction such as CT101's core4.releases/<sha>) to the pinned
workspace checkout NAME: every file `git archive HEAD` of that checkout
produces must exist in DIR with identical bytes, mode and symlink target.
Untracked extra files are allowed and listed. A mismatch refuses the run.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --pins) PINS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -f|--compose-file) COMPOSE_FILES+=("$(realpath -m -- "$2")"); shift 2 ;;
    --env-file) COMPOSE_ENV_FILE="$(realpath -m -- "$2")"; shift 2 ;;
    --compose-config) COMPOSE_CONFIG="$(realpath -m -- "$2")"; shift 2 ;;
    --check-running) CHECK_RUNNING=1; shift ;;
    --exempt) EXEMPT_FILE="$(realpath -m -- "$2")"; shift 2 ;;
    --release-tree) RELEASE_TREES+=("$2"); shift 2 ;;
    --require-release-tree) REQUIRE_TREES+=("$2"); shift 2 ;;
    --storage) STORAGE=1; shift ;;
    --verify) VERIFY="$2"; shift 2 ;;
    --cut-pins) CUT_PINS="$2"; shift 2 ;;
    --max-age-hours) MAX_AGE_HOURS="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "RELEASE_MANIFEST=FAIL unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n "$VERIFY" ]]; then
  exec python3 - "$VERIFY" "$PINS" "$CUT_PINS" "$MAX_AGE_HOURS" "$ROOT" "$WORKSPACE" "$EXEMPT_FILE" \
    "$(printf '%s\n' "${REQUIRE_TREES[@]+"${REQUIRE_TREES[@]}"}")" "$STORAGE" <<'VERIFY_PY'
import hashlib
import datetime
import json
import os
import re
import subprocess
import sys

GROUPS = ("core4", "backend", "backend-services", "frontend", "edge", "faucet")
PINNED_GROUPS = {
    "core4": "WRFCOIN_RC_CORE4_COMMIT",
    "backend": "WRFCOIN_RC_BACKEND_COMMIT",
    "backend-services": "WRFCOIN_RC_BACKEND_COMMIT",
    "frontend": "WRFCOIN_RC_FRONTEND_COMMIT",
}
PINNED_REPOS = {
    "core4": "WRFCOIN_RC_CORE4_COMMIT",
    "backend": "WRFCOIN_RC_BACKEND_COMMIT",
    "frontend": "WRFCOIN_RC_FRONTEND_COMMIT",
}
# Groups built from this infra checkout, which cannot pin itself: what each
# image bakes must be unchanged between its revision and the infra HEAD.
INFRA_BUILD_CONTEXTS = {"edge": "testnet/edge/", "faucet": "testnet/services/faucet/"}
# A clock-skew allowance for "not in the future"; an age bound is not a clock.
FUTURE_SKEW = datetime.timedelta(minutes=5)
SHA = re.compile(r"[0-9a-f]{40}")
path, pins_path, cut_pins_path, max_age_raw, infra_root, workspace, exempt_file, required_trees_raw, require_storage = sys.argv[1:]
required_trees = [line for line in required_trees_raw.splitlines() if line]


def void(message):
    print(f"RELEASE_MANIFEST_VERIFY=VOID {message}")
    raise SystemExit(2)


# A post-deploy manifest is evidence about the containers running now; beyond
# a few days it says nothing about them, so the window is bounded.
MAX_AGE_CAP_HOURS = 72
try:
    hours = float(max_age_raw)
    if not 0 < hours <= MAX_AGE_CAP_HOURS:
        raise ValueError(f"must be > 0 and <= {MAX_AGE_CAP_HOURS}")
    max_age = datetime.timedelta(hours=hours)
except (ValueError, OverflowError) as error:
    void(f"--max-age-hours {max_age_raw!r}: {error}")


def fail_now(message):
    print(f"RELEASE_MANIFEST_VERIFY_FINDING {message}", file=sys.stderr)
    print(f"RELEASE_MANIFEST_VERIFY=FAIL manifest={path} findings=1")
    raise SystemExit(1)


def read_env(env_path):
    values = {}
    with open(env_path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                values[key] = value
    return values


# The current release is what the manifest must be bound to: the pins, not the
# manifest's own copy of them, and only this checkout's own pins files (as the
# renderer requires). A stale copy of an earlier release's pins, anywhere, must
# not be able to vouch for that release's manifest.
for option, given, own in (
    ("--pins", pins_path, "release-pins.env"),
    ("--cut-pins", cut_pins_path, "cut-pins.env"),
):
    expected = os.path.realpath(os.path.join(infra_root, "testnet", own))
    if os.path.exists(given) and os.path.realpath(given) != expected:
        fail_now(f"{option} {given} refused: it must be this checkout's {expected}")
try:
    pins = read_env(pins_path)
    cut_pins = read_env(cut_pins_path)
except (OSError, UnicodeDecodeError) as error:
    void(f"cannot read the current pins: {error}")
missing = [key for key in [*PINNED_REPOS.values(), "WRFCOIN_RC_MIN_PUBLIC_BUILD_DATE"] if not pins.get(key)]
if missing:
    void(f"pins {pins_path} lack {', '.join(missing)}")
bad = [key for key in PINNED_REPOS.values() if not SHA.fullmatch(pins[key])]
if bad:
    void(f"pins {pins_path}: {', '.join(bad)} not a full lowercase 40-hex SHA")

try:
    with open(path, encoding="utf-8") as handle:
        manifest = json.load(handle)
    images = manifest["images"]
except (OSError, ValueError, KeyError, TypeError) as error:
    void(f"unreadable manifest {path}: {error}")

# infra#944: the opt-in storage group. A manifest that carries one is verified
# whether or not --storage was given; --storage additionally requires it.
KUBO_REPOSITORY = "ipfs/kubo"
if require_storage == "1" or (isinstance(images, dict) and "storage" in images):
    storage_key, kubo_key = "WRFCOIN_RC_STORAGE_PROVIDERS_COMMIT", "WRFCOIN_RC_IPFS_KUBO_DIGEST"
    if not SHA.fullmatch(pins.get(storage_key, "")):
        void(f"pins {pins_path}: {storage_key} missing or not a full lowercase 40-hex SHA")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", pins.get(kubo_key, "")):
        void(f"pins {pins_path}: {kubo_key} missing or not sha256:<64 hex>")
    GROUPS = (*GROUPS, "storage")
    PINNED_GROUPS["storage"] = storage_key
    PINNED_REPOS["storage-providers"] = storage_key

problems = []


def git(*args):
    return subprocess.run(
        ["git", "-C", infra_root, *args],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )


def check_generated_at(value):
    if not isinstance(value, str):
        return f"generated_at {value!r} is missing or not a string"
    try:
        generated = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return f"generated_at {value!r} is not an ISO-8601 timestamp"
    if generated.tzinfo is None:
        return f"generated_at {value!r} has no timezone"
    now = datetime.datetime.now(datetime.timezone.utc)
    if generated > now + FUTURE_SKEW:
        return f"generated_at {value} is in the future (now {now.isoformat()})"
    if now - generated > max_age:
        return (
            f"generated_at {value} is older than the {max_age_raw}h window "
            f"(now {now.isoformat()}; --max-age-hours to change)"
        )
    return None


def check_infra_revision(revision, context):
    """An infra-built image (edge, faucet) must be built from this infra
    checkout's line with an unchanged build context, exactly as the renderer
    requires."""
    if not isinstance(revision, str) or not SHA.fullmatch(revision):
        return f"revision {revision!r} is not a full SHA"
    head = git("rev-parse", "HEAD")
    if head.returncode != 0:
        return f"cannot resolve the infra HEAD in {infra_root}"
    head = head.stdout.strip()
    if git("merge-base", "--is-ancestor", revision, head).returncode != 0:
        return f"revision {revision} is not contained in infra HEAD {head}"
    changed = git("diff", "--quiet", revision, head, "--", context).returncode
    if changed != 0:
        return f"{context} differs between revision {revision} and infra HEAD {head}"
    return None


def verify():
    if not isinstance(manifest, dict) or not isinstance(images, dict):
        problems.append("manifest or its images is not a JSON object")
        return
    if manifest.get("mode") != "check_running" or manifest.get("check_running") is not True:
        problems.append(f"mode is {manifest.get('mode')!r}, not a check_running manifest")
    if manifest.get("classification") != "FRESH":
        problems.append(f"classification is {manifest.get('classification')!r}")
    if manifest.get("membership_problems") != []:
        problems.append(f"membership_problems is {manifest.get('membership_problems')!r}, not []")
    if manifest.get("config_problems") != []:
        problems.append(f"config_problems is {manifest.get('config_problems')!r}, not []")
    age_problem = check_generated_at(manifest.get("generated_at"))
    if age_problem:
        problems.append(age_problem)
    if manifest.get("minimum_public_build_date") != pins["WRFCOIN_RC_MIN_PUBLIC_BUILD_DATE"]:
        problems.append(
            f"minimum_public_build_date {manifest.get('minimum_public_build_date')!r} != "
            f"current pin {pins['WRFCOIN_RC_MIN_PUBLIC_BUILD_DATE']}"
        )
    cut_core4 = cut_pins.get("WRFCOIN_CUT_CORE4_COMMIT")
    if pins["WRFCOIN_RC_CORE4_COMMIT"] != cut_core4:
        problems.append(f"current core4 pin != WRFCOIN_CUT_CORE4_COMMIT ({cut_core4})")

    repos = manifest.get("repos")
    if not isinstance(repos, dict):
        problems.append("repos is missing or not an object")
        repos = {}
    for repo, key in PINNED_REPOS.items():
        entry = repos.get(repo)
        if not isinstance(entry, dict):
            problems.append(f"repos.{repo}: missing or not an object")
            continue
        for field in ("pinned", "head"):
            if entry.get(field) != pins[key]:
                problems.append(f"repos.{repo}.{field} {entry.get(field)!r} != current {key} {pins[key]}")
    for repo in (*PINNED_REPOS, "infra"):
        entry = repos.get(repo)
        if isinstance(entry, dict) and entry.get("clean") is not True:
            problems.append(f"repos.{repo}.clean is {entry.get('clean')!r}, not true")
    infra = repos.get("infra")
    infra_head = infra.get("head") if isinstance(infra, dict) else None
    current = git("rev-parse", "HEAD")
    if not isinstance(infra_head, str) or not SHA.fullmatch(infra_head):
        problems.append(f"repos.infra.head {infra_head!r} is not a full SHA")
    elif current.returncode != 0:
        problems.append(f"cannot resolve the infra HEAD in {infra_root}")
    elif git("merge-base", "--is-ancestor", infra_head, current.stdout.strip()).returncode != 0:
        problems.append(f"repos.infra.head {infra_head} is not contained in infra HEAD {current.stdout.strip()}")

    for group in GROUPS:
        summary = images.get(group)
        if not isinstance(summary, dict):
            problems.append(f"{group}: missing")
            continue
        if summary.get("freshness") != "FRESH" or summary.get("problems") != []:
            problems.append(f"{group}: freshness {summary.get('freshness')!r}, problems {summary.get('problems')!r}")
        key = PINNED_GROUPS.get(group)
        if key and summary.get("expected_revision") != pins[key]:
            problems.append(f"{group}: expected_revision {summary.get('expected_revision')!r} != current {key} {pins[key]}")
        tags = summary.get("tags")
        if not isinstance(tags, dict) or not tags:
            problems.append(f"{group}: no gated tags")
            continue
        for tag, record in tags.items():
            verify_tag(group, key, tag, record)
        if group == "storage":
            upstream = [r for r in tags.values() if isinstance(r, dict) and r.get("upstream") is True]
            built = [r for r in tags.values() if isinstance(r, dict) and r.get("upstream") is not True]
            if len(upstream) != 1 or not built:
                problems.append("storage: expected the upstream ipfs-kubo image and a built storage-node image")
    verify_exemptions()
    verify_release_trees()


EXEMPTABLE = {"softhsm-init", "softhsm-seed-init", "wrfcoin-seed"}
listed = []
declarations = {}


def verify_exemptions():
    """infra#1047: exempt identity owners must be exactly the listed ones, each an
    EXEMPT core4 record whose declared image is the one its containers run."""
    global listed
    exemptions = manifest.get("exemptions")
    names_listed = exemptions.get("services") if isinstance(exemptions, dict) else None
    if not isinstance(names_listed, list) or not set(names_listed) <= EXEMPTABLE:
        problems.append(f"exemptions: malformed or not identity owners: {exemptions!r}")
        names_listed = []
    listed = sorted(names_listed)
    seen = []
    for group in GROUPS:
        summary = images.get(group)
        exempt = summary.get("exempt", {}) if isinstance(summary, dict) else {}
        if not isinstance(exempt, dict):
            problems.append(f"{group}: exempt is not a mapping")
            continue
        for tag, record in exempt.items():
            where = f"{group} {tag}"
            if not isinstance(record, dict):
                problems.append(f"{where}: exempt record is not an object")
                continue
            names = record.get("services")
            image_id = record.get("image_id")
            if group != "core4" or record.get("freshness") != "EXEMPT" or not isinstance(names, list) or not names:
                problems.append(f"{where}: exemption {record.get('freshness')!r} for {names!r}")
                continue
            seen.extend(names)
            declared = record.get("declared") if isinstance(record.get("declared"), dict) else {}
            if not re.fullmatch(r"sha256:[0-9a-f]{64}", str(image_id)) or any(
                not isinstance(declared.get(n), dict) or declared[n].get("image_id") != image_id for n in names
            ):
                problems.append(f"{where}: exempt image_id {image_id!r} does not match its declaration")
            containers = record.get("containers")
            if not isinstance(containers, list) or not all(isinstance(c, dict) for c in containers) or sorted(
                str(c.get("service")) for c in containers
            ) != sorted(names):
                problems.append(f"{where}: exempt container records do not cover {names}")
                continue
            for c in containers:
                problem = exempt_container_problem(c, image_id)
                if problem:
                    problems.append(f"{where}: {problem}")
            revision = record.get("revision")
            if any(not isinstance(declared.get(n), dict) or declared[n].get("revision") != revision for n in names):
                problems.append(f"{where}: exempt revision {revision!r} does not match its declaration")
            elif not isinstance(revision, str) or not SHA.fullmatch(revision) or subprocess.run(
                ["git", "-C", os.path.join(workspace, "core4"), "merge-base", "--is-ancestor",
                 revision, pins["WRFCOIN_RC_CORE4_COMMIT"]],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            ).returncode != 0:
                problems.append(
                    f"{where}: exempt revision {revision!r} is not an ancestor of the current core4 pin "
                    f"(checked in {os.path.join(workspace, 'core4')})"
                )
            for n in names:
                if isinstance(declared.get(n), dict):
                    declarations[n] = (declared[n].get("image_id"), declared[n].get("revision"))
    if sorted(seen) != listed:
        problems.append(f"exemptions: listed {listed} but exempt records cover {sorted(seen)}")
    if listed:
        check_exemption_file(exemptions, declarations)


def exempt_container_problem(c, image_id):
    """wrfcoin-seed is a full core4 node: exempt only while it is not running
    (exited from the exempt image, or absent). The HSM init owners must run the
    exempt image."""
    if c.get("service") == "wrfcoin-seed":
        if c.get("running") is not False:
            return f"exempt seed {c.get('container')} running={c.get('running')!r}; it must not be running"
        if c.get("present") is False and c.get("container_image_id") is None:
            return None
    if c.get("container_image_id") != image_id:
        return f"exempt {c.get('container')} image {c.get('container_image_id')} != {image_id}"
    return None


def check_exemption_file(exemptions, declarations):
    """The manifest must name the reviewed exemption file it was rendered with."""
    if not exempt_file:
        problems.append("exemptions: the manifest has exemptions; pass the same --exempt FILE to --verify")
        return
    try:
        raw = open(exempt_file, "rb").read()
    except OSError as error:
        problems.append(f"exemptions: cannot read --exempt {exempt_file}: {error}")
        return
    digest = hashlib.sha256(raw).hexdigest()
    if digest != exemptions.get("sha256"):
        problems.append(f"exemptions: --exempt {exempt_file} sha256 {digest} != recorded {exemptions.get('sha256')!r}")
    entries = {}
    for line in raw.decode("utf-8", "replace").splitlines():
        fields = line.split("#", 1)[0].split()
        if fields:
            entries[fields[0]] = tuple(fields[1:3]) if len(fields) == 3 else None
    if entries != declarations:
        problems.append(f"exemptions: --exempt entries {entries} != manifest declarations {declarations}")


def verify_release_trees():
    trees = manifest.get("release_trees")
    repos = manifest.get("repos") if isinstance(manifest.get("repos"), dict) else {}
    for name in required_trees:
        entry = repos.get(name) if isinstance(repos.get(name), dict) else {}
        tree = entry.get("release_tree")
        if not isinstance(trees, list) or name not in trees or not isinstance(tree, dict) or not tree.get("path"):
            problems.append(f"release tree {name}: required, but the manifest was not rendered with --release-tree {name}=DIR")


def verify_tag(group, key, tag, record):
    where = f"{group} {tag}"
    if not isinstance(record, dict):
        problems.append(f"{where}: record is not an object")
        return
    image_id = record.get("image_id")
    if record.get("freshness") != "FRESH" or not re.fullmatch(r"sha256:[0-9a-f]{64}", str(image_id)):
        problems.append(f"{where}: freshness {record.get('freshness')!r}, image_id {image_id!r}")
    revision = record.get("revision")
    if group == "storage" and (record.get("upstream") is True or tag.split("@", 1)[0].rsplit(":", 1)[0] == KUBO_REPOSITORY):
        # Upstream image, never built here: pinned by digest, and the local image must carry it.
        digest = pins["WRFCOIN_RC_IPFS_KUBO_DIGEST"]
        if tag.split("@", 1)[0].rsplit(":", 1)[0] != KUBO_REPOSITORY or record.get("upstream") is not True:
            problems.append(f"{where}: only {KUBO_REPOSITORY} is an upstream storage image")
        if record.get("pinned_digest") != digest:
            problems.append(f"{where}: pinned_digest {record.get('pinned_digest')!r} != current pin {digest}")
        if f"{KUBO_REPOSITORY}@{digest}" not in (record.get("repo_digests") or []):
            problems.append(f"{where}: local image does not carry {KUBO_REPOSITORY}@{digest}")
    elif key:
        if revision != pins[key]:
            problems.append(f"{where}: revision {revision!r} != current {key} {pins[key]}")
    else:
        infra_problem = check_infra_revision(revision, INFRA_BUILD_CONTEXTS[group])
        if infra_problem:
            problems.append(f"{where}: {infra_problem}")
    services = record.get("services")
    if not isinstance(services, list) or not services or not all(isinstance(s, str) and s for s in services):
        problems.append(f"{where}: services {services!r} is not a non-empty list of names")
        return
    containers = record.get("containers")
    if containers is None:
        problems.append(f"{where}: no container records (a pre_deploy manifest)")
        return
    if not isinstance(containers, list) or not containers or not all(isinstance(c, dict) for c in containers):
        problems.append(f"{where}: containers {containers!r} is not a non-empty list of container records")
        return
    covered = [c.get("service") for c in containers]
    if not all(isinstance(s, str) for s in covered) or sorted(covered) != sorted(services):
        problems.append(f"{where}: container records {covered!r} do not cover services {services}")
    for c in containers:
        if c.get("container_image_id") != image_id:
            problems.append(f"{where}: {c.get('container')} image {c.get('container_image_id')} != {image_id}")
        elif c.get("one_shot") and (c.get("running") is not False or c.get("exit_code") != 0):
            problems.append(f"{where}: one-shot {c.get('container')} running={c.get('running')} exit={c.get('exit_code')}")
        elif not c.get("one_shot") and c.get("running") is not True:
            problems.append(f"{where}: {c.get('container')} not running")


try:
    verify()
except Exception as error:  # a shape the checks above missed still fails closed, with a FAIL line
    problems.append(f"malformed manifest: {type(error).__name__}: {error}")
for problem in problems:
    print(f"RELEASE_MANIFEST_VERIFY_FINDING {problem}", file=sys.stderr)
if problems:
    print(f"RELEASE_MANIFEST_VERIFY=FAIL manifest={path} findings={len(problems)}")
    raise SystemExit(1)
print(
    f"RELEASE_MANIFEST_VERIFY=PASS manifest={path} mode=check_running "
    f"generated_at={manifest.get('generated_at')} pins={pins_path} max_age_hours={max_age_raw} "
    f"exempt={','.join(listed) or 'none'}"
)
VERIFY_PY
fi

# A manifest from an earlier run must never outlive a run that fails before
# writing a new one (the new one is written atomically below).
rm -f -- "$OUT"

[[ -r "$PINS" ]] || { echo "RELEASE_MANIFEST=VOID pins file missing: $PINS" >&2; exit 2; }
if [[ -n "$COMPOSE_CONFIG" && ${#COMPOSE_FILES[@]} -gt 0 ]]; then
  echo 'RELEASE_MANIFEST=FAIL pass either --compose-file or --compose-config, not both' >&2
  exit 2
fi
if [[ -z "$COMPOSE_CONFIG" && ${#COMPOSE_FILES[@]} -eq 0 ]]; then
  echo 'RELEASE_MANIFEST=VOID no compose file set: the gated image tags come from the deployed compose render' >&2
  usage >&2
  exit 2
fi
mkdir -p "$(dirname "$OUT")"

export RC_COMPOSE_CONFIG="$COMPOSE_CONFIG" RC_COMPOSE_ENV_FILE="$COMPOSE_ENV_FILE" RC_CHECK_RUNNING="$CHECK_RUNNING"
export RC_CORS_POLICY="$ROOT/testnet/scripts/cors_origin_policy.py"
export RC_EXEMPT_FILE="$EXEMPT_FILE" RC_STORAGE="$STORAGE"
RC_RELEASE_TREES="$(printf '%s\n' "${RELEASE_TREES[@]+"${RELEASE_TREES[@]}"}")"
export RC_RELEASE_TREES
RC_COMPOSE_FILES="$(printf '%s\n' "${COMPOSE_FILES[@]+"${COMPOSE_FILES[@]}"}")"
export RC_COMPOSE_FILES

python3 - "$WORKSPACE" "$PINS" "$OUT" "$ROOT/testnet/cut-pins.env" <<'PY'
import datetime
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile

workspace, pins_path, output_path, cut_pins_path = sys.argv[1:]
required_frontend_commit = os.environ.get(
    "WRFCOIN_RC_REQUIRED_FRONTEND_COMMIT",
    "f7448139ea6b0c5bb0f99b40c9c11db327db9209",  # frontend #363
)
required = {
    "core4": "WRFCOIN_RC_CORE4_COMMIT",
    "backend": "WRFCOIN_RC_BACKEND_COMMIT",
    "frontend": "WRFCOIN_RC_FRONTEND_COMMIT",
}
# infra#944: the opt-in storage group (--storage). Without it nothing below changes.
storage = os.environ.get("RC_STORAGE") == "1"
STORAGE_PIN, KUBO_DIGEST_PIN = "WRFCOIN_RC_STORAGE_PROVIDERS_COMMIT", "WRFCOIN_RC_IPFS_KUBO_DIGEST"
KUBO_REPOSITORY = "ipfs/kubo"
if storage:
    required["storage-providers"] = STORAGE_PIN
pins = {}
for raw in open(pins_path, encoding="utf-8"):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if "=" not in line:
        print(f"RELEASE_MANIFEST=FAIL malformed pins line: {line}", file=sys.stderr)
        raise SystemExit(1)
    key, value = line.split("=", 1)
    pins[key] = value

missing_keys = [key for key in [*required.values(), "WRFCOIN_RC_MIN_PUBLIC_BUILD_DATE", *([KUBO_DIGEST_PIN] if storage else [])] if key not in pins]
if missing_keys:
    print(f"RELEASE_MANIFEST=FAIL missing pins: {', '.join(missing_keys)}", file=sys.stderr)
    raise SystemExit(1)

cut_pins = {}
for raw in open(cut_pins_path, encoding="utf-8"):
    line = raw.strip()
    if line and not line.startswith("#") and "=" in line:
        key, value = line.split("=", 1)
        cut_pins[key] = value
cut_core4 = cut_pins.get("WRFCOIN_CUT_CORE4_COMMIT")
if pins["WRFCOIN_RC_CORE4_COMMIT"] != cut_core4:
    print(
        "RELEASE_MANIFEST=FAIL release core4 pin must equal "
        f"WRFCOIN_CUT_CORE4_COMMIT ({cut_core4})",
        file=sys.stderr,
    )
    raise SystemExit(1)

repos = {}
for name, key in required.items():
    path = os.path.join(workspace, name)
    if not os.path.isdir(path):
        print(f"RELEASE_MANIFEST=VOID repository missing: {path}", file=sys.stderr)
        raise SystemExit(2)
    pinned = pins[key]
    if not re.fullmatch(r"[0-9a-f]{40}", pinned):
        print(f"RELEASE_MANIFEST=FAIL {key} is not a full lowercase 40-hex SHA", file=sys.stderr)
        raise SystemExit(1)
    try:
        head = subprocess.check_output(["git", "-C", path, "rev-parse", "HEAD"], text=True).strip()
        status = subprocess.check_output(["git", "-C", path, "status", "--porcelain"], text=True)
        resolved_pin = subprocess.check_output(
            ["git", "-C", path, "rev-parse", f"{pinned}^{{commit}}"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        origin_main = subprocess.check_output(
            ["git", "-C", path, "rev-parse", "origin/main^{commit}"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except subprocess.CalledProcessError as error:
        print(f"RELEASE_MANIFEST=VOID cannot inspect {path}: {error}", file=sys.stderr)
        raise SystemExit(2)
    clean = status == ""
    repos[name] = {
        "pinned": pinned,
        "resolved_pin": resolved_pin,
        "origin_main": origin_main,
        "head": head,
        "clean": clean,
    }
    if resolved_pin != pinned:
        print(f"RELEASE_MANIFEST=FAIL {name} pin {pinned} did not resolve exactly", file=sys.stderr)
        raise SystemExit(1)
    on_main = subprocess.run(
        ["git", "-C", path, "merge-base", "--is-ancestor", pinned, origin_main]
    )
    if on_main.returncode != 0:
        print(
            f"RELEASE_MANIFEST=FAIL {name} pin {pinned} is not contained in origin/main {origin_main}",
            file=sys.stderr,
        )
        raise SystemExit(1)
    if head != pinned:
        print(f"RELEASE_MANIFEST=FAIL {name} HEAD {head} != pinned {pinned}", file=sys.stderr)
        raise SystemExit(1)
    if not clean:
        print(f"RELEASE_MANIFEST=FAIL {name} worktree is dirty", file=sys.stderr)
        raise SystemExit(1)

frontend_path = os.path.join(workspace, "frontend")
try:
    subprocess.check_output(
        ["git", "-C", frontend_path, "rev-parse", f"{required_frontend_commit}^{{commit}}"],
        text=True,
        stderr=subprocess.DEVNULL,
    )
except subprocess.CalledProcessError:
    print(
        f"RELEASE_MANIFEST=FAIL frontend required #363 commit {required_frontend_commit} is unavailable",
        file=sys.stderr,
    )
    raise SystemExit(1)
contains_required_frontend = subprocess.run(
    [
        "git", "-C", frontend_path, "merge-base", "--is-ancestor",
        required_frontend_commit, pins["WRFCOIN_RC_FRONTEND_COMMIT"],
    ]
)
if contains_required_frontend.returncode != 0:
    print(
        "RELEASE_MANIFEST=FAIL selected frontend pin does not contain #363 "
        f"({required_frontend_commit})",
        file=sys.stderr,
    )
    raise SystemExit(1)
repos["frontend"]["contains_frontend_363"] = required_frontend_commit

# Infra is the checkout executing this renderer. Its release-pins file cannot
# name its own commit without creating an impossible self-reference. Record its
# exact HEAD and require a clean checkout containing the pins instead.
infra_path = os.path.join(workspace, "infra")
expected_pins = os.path.realpath(os.path.join(infra_path, "testnet", "release-pins.env"))
if not os.path.isdir(infra_path):
    print(f"RELEASE_MANIFEST=VOID repository missing: {infra_path}", file=sys.stderr)
    raise SystemExit(2)
if not os.path.isfile(expected_pins) or os.path.realpath(pins_path) != expected_pins:
    print(
        "RELEASE_MANIFEST=FAIL infra checkout must contain and use testnet/release-pins.env",
        file=sys.stderr,
    )
    raise SystemExit(1)
try:
    infra_head = subprocess.check_output(
        ["git", "-C", infra_path, "rev-parse", "HEAD"], text=True
    ).strip()
    infra_status = subprocess.check_output(
        ["git", "-C", infra_path, "status", "--porcelain"], text=True
    )
except subprocess.CalledProcessError as error:
    print(f"RELEASE_MANIFEST=VOID cannot inspect {infra_path}: {error}", file=sys.stderr)
    raise SystemExit(2)
if infra_status:
    print("RELEASE_MANIFEST=FAIL infra worktree is dirty", file=sys.stderr)
    raise SystemExit(1)
repos["infra"] = {
    "head": infra_head,
    "clean": True,
    "source": "renderer_checkout",
}

# ---- --release-tree NAME=DIR (infra#1047): a non-git deployed tree must be
# byte-identical to what `git archive HEAD` of the pinned workspace checkout
# produces. The checkout itself was verified above (HEAD == pin, clean, on
# origin/main), so this ties the extracted tree to the pin without trusting any
# file inside the tree.
def git_blob_digest(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def verify_release_tree(name, tree_dir):
    checkout = os.path.join(workspace, name)
    if os.path.realpath(tree_dir) == os.path.realpath(checkout):
        return None, "is the workspace checkout itself, not a separate release tree"
    if not os.path.isdir(tree_dir):
        return None, "is not a directory"
    archive = subprocess.Popen(
        ["git", "-C", checkout, "archive", "--format=tar", "HEAD"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    expected = set()
    mismatches = []
    with tarfile.open(fileobj=archive.stdout, mode="r|") as tar:
        for member in tar:
            rel = member.name.rstrip("/")
            if rel in ("", "pax_global_header") or member.type == tarfile.XGLTYPE:
                continue
            path = os.path.join(tree_dir, rel)
            if member.isdir():
                expected.add(rel)
                if not os.path.isdir(path) or os.path.islink(path):
                    mismatches.append(f"{rel}: directory missing")
                continue
            expected.add(rel)
            if member.issym():
                if not os.path.islink(path) or os.readlink(path) != member.linkname:
                    mismatches.append(f"{rel}: symlink differs")
                continue
            if not member.isfile():
                mismatches.append(f"{rel}: unsupported archive member type")
                continue
            if os.path.islink(path) or not os.path.isfile(path):
                mismatches.append(f"{rel}: missing")
                continue
            want = tar.extractfile(member).read()
            with open(path, "rb") as handle:
                have = handle.read()
            if git_blob_digest(have) != git_blob_digest(want):
                mismatches.append(f"{rel}: content differs")
            elif bool(member.mode & 0o111) != bool(os.stat(path).st_mode & stat.S_IXUSR):
                mismatches.append(f"{rel}: executable bit differs")
    if archive.wait() != 0:
        return None, f"git archive HEAD of {checkout} failed"
    if not expected:
        return None, f"git archive HEAD of {checkout} produced no entries"
    if mismatches:
        return None, f"differs from git archive of {name} HEAD: " + "; ".join(mismatches[:10]) + (
            f" (+{len(mismatches) - 10} more)" if len(mismatches) > 10 else ""
        )
    extra = []
    for base, dirs, files in os.walk(tree_dir):
        for entry in dirs + files:
            rel = os.path.relpath(os.path.join(base, entry), tree_dir)
            if rel not in expected:
                extra.append(rel)
        dirs[:] = [d for d in dirs if os.path.relpath(os.path.join(base, d), tree_dir) in expected]
    extra.sort()
    return {
        "path": os.path.realpath(tree_dir),
        "verified_against": repos[name].get("pinned") or repos[name]["head"],
        "archive_entries": len(expected),
        "untracked_extra": extra[:50],
        "untracked_extra_count": len(extra),
    }, None


for spec in [line for line in os.environ.get("RC_RELEASE_TREES", "").splitlines() if line]:
    name, sep, tree_dir = spec.partition("=")
    if not sep or name not in repos or not tree_dir:
        print(f"RELEASE_MANIFEST=FAIL --release-tree must be NAME=DIR with NAME in {sorted(repos)}: {spec}", file=sys.stderr)
        raise SystemExit(1)
    if "release_tree" in repos[name]:
        print(f"RELEASE_MANIFEST=FAIL --release-tree {name} given twice", file=sys.stderr)
        raise SystemExit(1)
    record, error = verify_release_tree(name, tree_dir)
    if error:
        print(f"RELEASE_MANIFEST=FAIL release tree {name}={tree_dir} {error}", file=sys.stderr)
        raise SystemExit(1)
    repos[name]["release_tree"] = record

# ---- --exempt FILE (infra#1047): identity owners left on an older core4 image.
EXEMPTABLE_SERVICES = {"softhsm-init", "softhsm-seed-init", "wrfcoin-seed"}
# The seed is a full core4 node: exempt only while stopped (exited or absent).
EXEMPT_MUST_NOT_RUN = {"wrfcoin-seed"}
exemptions = {}
exempt_file = os.environ.get("RC_EXEMPT_FILE", "")
exempt_file_sha256 = None
if exempt_file:
    try:
        raw_exempt = open(exempt_file, "rb").read()
    except OSError as error:
        print(f"RELEASE_MANIFEST=FAIL cannot read exemption file {exempt_file}: {error}", file=sys.stderr)
        raise SystemExit(1)
    exempt_file_sha256 = hashlib.sha256(raw_exempt).hexdigest()
    for number, raw in enumerate(raw_exempt.decode("utf-8", "replace").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = line.split()
        if (
            len(fields) != 3
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", fields[1])
            or not re.fullmatch(r"[0-9a-f]{40}", fields[2])
        ):
            print(
                f"RELEASE_MANIFEST=FAIL exemption line {number} is not "
                "'<service> <sha256:64-hex image id> <40-hex revision>'",
                file=sys.stderr,
            )
            raise SystemExit(1)
        service, image_id, revision = fields
        if service not in EXEMPTABLE_SERVICES:
            print(
                f"RELEASE_MANIFEST=FAIL exemption for {service} refused: only the identity owners "
                f"{sorted(EXEMPTABLE_SERVICES)} can be exempted",
                file=sys.stderr,
            )
            raise SystemExit(1)
        if service in exemptions:
            print(f"RELEASE_MANIFEST=FAIL exemption for {service} listed twice", file=sys.stderr)
            raise SystemExit(1)
        exemptions[service] = {"image_id": image_id, "revision": revision}
    if not exemptions:
        print(f"RELEASE_MANIFEST=FAIL exemption file {exempt_file} lists no service", file=sys.stderr)
        raise SystemExit(1)

if storage and not re.fullmatch(r"sha256:[0-9a-f]{64}", pins[KUBO_DIGEST_PIN]):
    print(f"RELEASE_MANIFEST=FAIL {KUBO_DIGEST_PIN} is not sha256:<64 lowercase hex>", file=sys.stderr)
    raise SystemExit(1)

minimum = datetime.datetime.fromisoformat(
    pins["WRFCOIN_RC_MIN_PUBLIC_BUILD_DATE"]
).replace(tzinfo=datetime.timezone.utc)
# Revision each image must carry. core4/backend/frontend must be the exact
# reviewed pin; an image built recently from an older commit is still stale.
# The edge and the faucet are built from infra, which cannot pin itself (see
# above), so their revision must be a commit contained in the renderer's infra
# HEAD whose build context (INFRA_BUILD_CONTEXTS) is identical to HEAD's.
expected_revision = {
    "core4": pins["WRFCOIN_RC_CORE4_COMMIT"],
    "backend": pins["WRFCOIN_RC_BACKEND_COMMIT"],
    "frontend": pins["WRFCOIN_RC_FRONTEND_COMMIT"],
    # wrfcoin/backend (Dockerfile.backend: db-migrate, governance, iot,
    # weather-earnings, ...) is built from the same backend checkout.
    "backend-services": pins["WRFCOIN_RC_BACKEND_COMMIT"],
}


# Gate groups, keyed by the release Dockerfile a rendered service builds from.
# The service set is derived from the compose render: every service built from
# one of these Dockerfiles, plus every service running a tag they produce.
GATE_DOCKERFILES = {
    "Dockerfile.core": "core4",
    "Dockerfile.backend-api": "backend",
    "Dockerfile.backend": "backend-services",
    "Dockerfile.frontend": "frontend",
    "Dockerfile.caddy": "edge",
}
# The faucet's Dockerfile has the generic name `Dockerfile`, so it is matched by
# its path inside the infra tree (infra#1121: CT101 ran a July faucet image,
# unlabelled, while the gate said FRESH).
GATE_DOCKERFILE_PATHS = {"testnet/services/faucet/Dockerfile": "faucet"}
GATE_GROUPS = ("core4", "backend", "backend-services", "frontend", "edge", "faucet")
GROUP_DOCKERFILE = {group: dockerfile for dockerfile, group in GATE_DOCKERFILES.items()}
GROUP_DOCKERFILE.update({group: path for path, group in GATE_DOCKERFILE_PATHS.items()})
# Membership is fail-closed. These services are gated by NAME, whatever their
# build:/image: (a host override may point one at a pre-built tag)...
BASELINE_SERVICES = {
    "wrfcoin-node": "core4",
    "wrfcoin-backend": "backend",
    "db-migrate": "backend-services",
    "wrfcoin-governance": "backend-services",
    "wrfcoin-iot": "backend-services",
    "wrfcoin-weather-earnings": "backend-services",
    "wrfcoin-frontend": "frontend",
    "funnel-edge": "edge",
    "edge": "edge",
    "wrfcoin-faucet": "faucet",
}
# ...and must be rendered (the edge needs one of its two service names).
REQUIRED_SERVICES = [
    ("wrfcoin-node",), ("wrfcoin-backend",), ("db-migrate",), ("wrfcoin-governance",),
    ("wrfcoin-iot",), ("wrfcoin-weather-earnings",), ("wrfcoin-frontend",), ("funnel-edge", "edge"),
    ("wrfcoin-faucet",),
]
# ...plus every service running an image from a release repository, any tag.
RELEASE_REPOSITORIES = {
    "wrfcoin/native-chain": "core4",
    "wrfcoin/backend-api": "backend",
    "wrfcoin/backend": "backend-services",
    "wrfcoin/frontend": "frontend",
    "wrfcoin/edge-caddy": "edge",
    "wrfcoin/faucet": "faucet",
}
# A build inside a pinned repository's tree that maps to no gate is unmapped.
PINNED_TREES = {"core4": "core4", "backend": "backend", "frontend": "frontend"}
# So is any build from infra's release Dockerfile directory (infra/docker/, built
# from the workspace root as infra/infra/docker/...): a new Dockerfile there is a
# new release image until it is given a gate (infra#1039).
RELEASE_DOCKERFILE_DIR = ("infra", "docker")
# What each infra-built image bakes. The edge bakes only its build context (the
# Caddyfile is mounted); the faucet COPYs only testnet/services/faucet/ files.
INFRA_BUILD_CONTEXTS = {"edge": "testnet/edge/", "faucet": "testnet/services/faucet/"}
if storage:
    # Opt-in (infra#944): ipfs-kubo is upstream (digest-pinned, never built); storage-node is built
    # from storage-providers. The weather archive worker runs wrfcoin/backend and so is already gated
    # in backend-services (same backend pin) by its image repository: it needs nothing here.
    expected_revision["storage"] = pins[STORAGE_PIN]
    GATE_DOCKERFILES["Dockerfile.storage"] = "storage"
    GATE_GROUPS = (*GATE_GROUPS, "storage")
    GROUP_DOCKERFILE["storage"] = "Dockerfile.storage"
    BASELINE_SERVICES.update({"storage-node": "storage", "ipfs-kubo": "storage"})
    REQUIRED_SERVICES += [("storage-node",), ("ipfs-kubo",)]
    RELEASE_REPOSITORIES.update({"wrfcoin/storage-node": "storage", KUBO_REPOSITORY: "storage"})
docker = shutil.which("docker")
check_running = os.environ.get("RC_CHECK_RUNNING") == "1"


def load_compose():
    """Return (services, project, error) from the deployed compose render."""
    config_path = os.environ.get("RC_COMPOSE_CONFIG", "")
    try:
        if config_path:
            with open(config_path, encoding="utf-8") as handle:
                rendered = json.load(handle)
        else:
            files = [line for line in os.environ.get("RC_COMPOSE_FILES", "").splitlines() if line]
            if not docker:
                return None, None, "docker unavailable: cannot render compose config"
            command = [docker, "compose"]
            if os.environ.get("RC_COMPOSE_ENV_FILE"):
                command += ["--env-file", os.environ["RC_COMPOSE_ENV_FILE"]]
            for path in files:
                command += ["-f", path]
            command += ["config", "--format", "json"]
            result = subprocess.run(
                command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                cwd=os.path.dirname(files[0]),
            )
            if result.returncode != 0:
                detail = (result.stderr.strip().splitlines() or ["no output"])[-1]
                return None, None, f"docker compose config failed: {detail}"
            rendered = json.loads(result.stdout)
        services = rendered["services"]
        if not isinstance(services, dict):
            raise TypeError("services is not a mapping")
        return services, rendered.get("name") or "testnet", None
    except (OSError, ValueError, KeyError, TypeError) as error:
        return None, None, f"compose config unreadable: {error}"


def parse_time(value):
    observed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if observed.tzinfo is None:
        observed = observed.replace(tzinfo=datetime.timezone.utc)
    return observed


def inspect_json(kind, name):
    """`docker <kind> inspect NAME` -> (object, reason). Never raises."""
    if not docker:
        return None, "docker unavailable"
    result = subprocess.run(
        [docker, kind, "inspect", name], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        return None, f"{kind} {name} not present locally"
    try:
        payload = json.loads(result.stdout)
        if not isinstance(payload, list) or len(payload) != 1 or not isinstance(payload[0], dict):
            raise TypeError("expected a one-element list of objects")
        return payload[0], None
    except (ValueError, TypeError) as error:
        return None, f"docker {kind} inspect returned malformed output: {error}"


def revision_verdict(group, revision):
    """Return (freshness, reason) for an image whose creation date passed."""
    if not re.fullmatch(r"[0-9a-f]{40}", revision or ""):
        return "UNAVAILABLE", "org.opencontainers.image.revision label missing or not a full SHA"
    if group in expected_revision:
        if revision != expected_revision[group]:
            return "STALE", f"revision {revision} is not the pinned {expected_revision[group]}"
        return "FRESH", None
    contained = subprocess.run(
        ["git", "-C", infra_path, "merge-base", "--is-ancestor", revision, infra_head],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if contained.returncode != 0:
        return "STALE", f"revision {revision} is not contained in infra HEAD {infra_head}"
    # Ancestry alone admits any old commit. The image is current only if what it
    # bakes is unchanged between its revision and the infra HEAD being released.
    context = INFRA_BUILD_CONTEXTS[group]
    unchanged = subprocess.run(
        ["git", "-C", infra_path, "diff", "--quiet", revision, infra_head, "--", context],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if unchanged.returncode == 1:
        return "STALE", f"{context} changed between revision {revision} and infra HEAD {infra_head}"
    if unchanged.returncode != 0:
        return "UNAVAILABLE", f"cannot compare {context} at revision {revision}"
    return "FRESH", None


FRONTEND_LABEL_PREFIX = "org.wrfcoin.frontend."
FRONTEND_VARIANT_LABEL = FRONTEND_LABEL_PREFIX + "variant"


def frontend_variant_verdict(labels):
    """infra#974 (frontend#348/#381): only a public build with every internal-
    surface flag label empty may ship. Pattern-based, so a flag label added to
    Dockerfile.frontend later is covered. Returns (freshness, reason)."""
    flags = sorted(
        f"{key}={value}" for key, value in labels.items()
        if key.startswith(FRONTEND_LABEL_PREFIX) and key != FRONTEND_VARIANT_LABEL
        and value not in (None, "")
    )
    variant = labels.get(FRONTEND_VARIANT_LABEL)
    if variant not in (None, "", "public"):
        return "STALE", f"frontend image is a variant {variant!r} build, not public ({', '.join(flags) or 'no flags'})"
    if flags:
        return "STALE", f"frontend image built with internal-surface flags: {', '.join(flags)}"
    if variant != "public":
        return "UNAVAILABLE", (
            f"{FRONTEND_VARIANT_LABEL} label missing (built before infra#974); "
            "rebuild from testnet/Dockerfile.frontend"
        )
    return "FRESH", None


def classify_upstream(record, payload):
    """infra#944: an upstream image (ipfs-kubo) is never built here, so it has no revision label
    to check. It is FRESH only when the local image carries the digest pinned in the pins file."""
    digest = pins[KUBO_DIGEST_PIN]
    image_id = payload.get("Id")
    repo_digests = payload.get("RepoDigests")
    if not isinstance(image_id, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id):
        record["reason"] = "docker image inspect returned no sha256 image Id"
        return
    if not isinstance(repo_digests, list) or not all(isinstance(item, str) for item in repo_digests):
        record["reason"] = "docker image inspect returned malformed RepoDigests"
        return
    record.update({
        "image_id": image_id, "created": payload.get("Created"), "evidence": "LOCAL_INSPECT",
        "upstream": True, "pinned_digest": digest, "repo_digests": sorted(repo_digests),
    })
    if f"{KUBO_REPOSITORY}@{digest}" in repo_digests:
        record["freshness"], record["reason"] = "FRESH", None
    else:
        record["freshness"] = "STALE"
        record["reason"] = f"local image does not carry the pinned digest {KUBO_REPOSITORY}@{digest}"


def classify_image(group, record):
    payload, reason = inspect_json("image", record["image"])
    if payload is None:
        record["reason"] = reason
        return
    if group == "storage" and image_repository(record["image"]) == KUBO_REPOSITORY:
        classify_upstream(record, payload)
        return
    try:
        config = payload.get("Config") or {}
        labels = config.get("Labels") or {}
        if not isinstance(config, dict) or not isinstance(labels, dict):
            raise TypeError("Config/Labels is not a mapping")
        docker_created = payload.get("Created")
        label_created = labels.get("org.opencontainers.image.created") or None
        revision = labels.get("org.opencontainers.image.revision")
        image_id = payload.get("Id")
    except (AttributeError, TypeError) as error:
        record["reason"] = f"docker image inspect returned malformed output: {error}"
        return
    if not isinstance(image_id, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id):
        record["reason"] = "docker image inspect returned no sha256 image Id"
        return
    record.update({
        "image_id": image_id,
        "created": docker_created,
        "label_created": label_created,
        "revision": revision,
        "evidence": "LOCAL_INSPECT",
        "reason": None,
    })
    # Docker's own Created is authoritative. The label comes from the build
    # environment, so it may only make the image look older, never newer.
    try:
        observed = parse_time(docker_created)
        if label_created is not None:
            observed = min(observed, parse_time(label_created))
    except (AttributeError, TypeError, ValueError):
        record["freshness"] = "UNAVAILABLE"
        record["reason"] = "image creation time missing or unparseable"
        return
    if observed < minimum:
        record["freshness"] = "STALE"
        record["reason"] = (
            f"created {observed.isoformat()} predates minimum public build date "
            f"{pins['WRFCOIN_RC_MIN_PUBLIC_BUILD_DATE']}"
        )
        return
    record["freshness"], record["reason"] = revision_verdict(group, revision)
    if group == "frontend" and record["freshness"] == "FRESH":
        record["frontend_variant"] = labels.get(FRONTEND_VARIANT_LABEL)
        record["freshness"], record["reason"] = frontend_variant_verdict(labels)


def check_container(record, service, container, one_shot):
    """Post-deploy: the service's container must use exactly the tag's image.
    A one-shot service (another service waits for it to complete) must have
    exited 0 from that image. Returns (freshness, reason)."""
    entry = {
        "service": service, "container": container, "one_shot": one_shot,
        "container_image_id": None, "running": None, "exit_code": None,
    }
    record["containers"].append(entry)
    payload, reason = inspect_json("container", container)
    if payload is None:
        return "UNAVAILABLE", f"running container: {reason}"
    state = payload.get("State") if isinstance(payload.get("State"), dict) else {}
    entry.update({
        "container_image_id": payload.get("Image"),
        "running": state.get("Running"),
        "exit_code": state.get("ExitCode"),
    })
    if entry["container_image_id"] != record["image_id"]:
        return "STALE", (
            f"container {container} running an old image {entry['container_image_id']} "
            f"(tag {record['image']} is {record['image_id']})"
        )
    if one_shot:
        if entry["running"]:
            return "UNAVAILABLE", f"one-shot {container} is still running"
        if entry["exit_code"] != 0:
            return "STALE", f"one-shot {container} exited {entry['exit_code']}"
        return "FRESH", None
    if not entry["running"]:
        return "UNAVAILABLE", f"container {container} is not running"
    return "FRESH", None


RANK = {"FRESH": 0, "UNAVAILABLE": 1, "STALE": 2}


def image_repository(reference):
    """wrfcoin/backend for wrfcoin/backend:tag, ghcr.io/wrfcoin/backend:tag@sha256:..."""
    name = str(reference).split("@", 1)[0]
    head, _, last = name.rpartition("/")
    last = last.split(":", 1)[0]
    parts = [part for part in (head.split("/") if head else [])] + [last]
    if len(parts) > 1 and ("." in parts[0] or ":" in parts[0] or parts[0] == "localhost"):
        parts = parts[1:]
    return "/".join(parts)


def pinned_tree(build):
    """The pinned repository a build context/dockerfile lies in, if any."""
    context = str(build.get("context") or "").rstrip("/")
    if os.path.basename(context) in PINNED_TREES:
        return PINNED_TREES[os.path.basename(context)]
    dockerfile = str(build.get("dockerfile") or "")
    if not os.path.isabs(dockerfile):
        first = dockerfile.split("/", 1)[0]
        if first in PINNED_TREES and "/" in dockerfile:
            return PINNED_TREES[first]
    return None


def in_release_dockerfile_dir(build):
    """True when the build's Dockerfile resolves into an .../infra/docker/
    directory or any subdirectory of one."""
    dockerfile = str(build.get("dockerfile") or "Dockerfile")
    if not os.path.isabs(dockerfile):
        dockerfile = os.path.join(str(build.get("context") or ""), dockerfile)
    parts = os.path.dirname(os.path.normpath(dockerfile)).split(os.sep)
    return any(tuple(parts[i:i + 2]) == RELEASE_DOCKERFILE_DIR for i in range(len(parts) - 1))


def cors_origin_problems(services):
    """[{service, reason}, ...] for rendered CORS_ORIGIN values no browser can be
    served from (infra#1056: CT101 ran http://localhost:5000 because compose
    defaulted it). Compose has no default and, because of the #762 join trap, no
    `:?` guard either, so an unset value renders empty. The policy is the ONE
    shared validator (testnet/scripts/cors_origin_policy.py) that the pre-`up`
    env gate also uses. It is loaded from the renderer's own checkout, and a
    missing module aborts the run rather than skipping the check."""
    import importlib.util
    path = os.environ["RC_CORS_POLICY"]
    spec = importlib.util.spec_from_file_location("cors_origin_policy", path)
    if spec is None or not os.path.isfile(path):
        print(f"RELEASE_MANIFEST=FAIL CORS policy module missing: {path}", file=sys.stderr)
        raise SystemExit(1)
    policy = importlib.util.module_from_spec(spec)
    # No __pycache__: a byte-compiled file would make the renderer's own infra
    # checkout dirty, and the clean-tree gate would then refuse it.
    sys.dont_write_bytecode = True
    spec.loader.exec_module(policy)
    problems = []
    for name, value in policy.rendered_readers(services).items():
        for entry, key in policy.value_problems(value):
            problems.append({"service": name, "reason": policy.describe(entry, key)})
    return problems

def build_group(build):
    """The gate group a build's Dockerfile belongs to, if any: by release
    Dockerfile name, else by its path (resolved against the context) ending in
    a gated infra Dockerfile path."""
    dockerfile = str(build.get("dockerfile") or "Dockerfile")
    group = GATE_DOCKERFILES.get(os.path.basename(dockerfile))
    if group:
        return group
    if not os.path.isabs(dockerfile):
        dockerfile = os.path.join(str(build.get("context") or ""), dockerfile)
    resolved = os.path.normpath(dockerfile).replace(os.sep, "/")
    for path, group in GATE_DOCKERFILE_PATHS.items():
        if resolved == path or resolved.endswith("/" + path):
            return group
    return None


def gate_groups(services, project):
    """({group: {tag: [service, ...]}}, {group: [{service, reason}, ...]},
    [{service, reason}, ...] for release builds that belong to no group)."""
    groups = {group: {} for group in GATE_GROUPS}
    problems = {group: [] for group in GATE_GROUPS}
    membership = []
    specs = {name: spec for name, spec in services.items() if isinstance(spec, dict)}
    produced = {}
    for name, spec in specs.items():
        build = spec.get("build") if isinstance(spec.get("build"), dict) else None
        if build:
            group = build_group(build)
            if group:
                produced[spec.get("image") or f"{project}-{name}"] = group
    for name, spec in sorted(specs.items()):
        tag = spec.get("image") or f"{project}-{name}"
        build = spec.get("build") if isinstance(spec.get("build"), dict) else None
        dockerfile = os.path.basename(str(build.get("dockerfile") or "Dockerfile")) if build else None
        built_group = build_group(build) if build else None
        group = (
            BASELINE_SERVICES.get(name)
            or RELEASE_REPOSITORIES.get(image_repository(tag))
            or built_group
            or produced.get(tag)
        )
        if group is None:
            tree = pinned_tree(build) if build else None
            if tree:
                problems[tree].append({"service": name, "reason": f"unmapped release build ({dockerfile})"})
            elif build and in_release_dockerfile_dir(build):
                membership.append({"service": name, "reason": f"unmapped release build ({dockerfile})"})
            continue
        if build and built_group != group:
            problems[group].append({
                "service": name,
                "reason": f"built from {dockerfile}, not {GROUP_DOCKERFILE[group]}",
            })
            continue
        groups[group].setdefault(tag, []).append(name)
    for names in REQUIRED_SERVICES:
        if not any(name in specs for name in names):
            problems[BASELINE_SERVICES[names[0]]].append({
                "service": "/".join(names), "reason": "required service is not rendered",
            })
    # Exempt identity owners leave the gated tag set only when their tag serves
    # no gated service; a shared tag stays gated for everyone (fail-closed).
    exempt = {group: {} for group in GATE_GROUPS}
    for service in sorted(exemptions):
        found = [
            (group, tag) for group in GATE_GROUPS
            for tag, names in groups[group].items() if service in names
        ]
        if not found:
            continue  # unrendered or ungated: refused by the caller
        group, tag = found[0]
        gated = [name for name in groups[group][tag] if name not in exemptions]
        if group != "core4" or gated:
            problems[group].append({
                "service": service,
                "reason": (
                    f"exemption refused: tag {tag} also serves gated service(s) {gated}"
                    if gated else f"exemption refused: {service} is in group {group}, not core4"
                ),
            })
            continue
        exempt[group].setdefault(tag, []).append(service)
    for group in GATE_GROUPS:
        for tag, names in exempt[group].items():
            remaining = [name for name in groups[group][tag] if name not in names]
            if remaining:
                groups[group][tag] = remaining
            else:
                del groups[group][tag]
    return groups, problems, membership, exempt


services, project, compose_error = load_compose()
one_shot_services = set()
if services is not None:
    for spec in services.values():
        depends = spec.get("depends_on") if isinstance(spec, dict) else None
        if isinstance(depends, dict):
            one_shot_services.update(
                dep for dep, cond in depends.items()
                if isinstance(cond, dict) and cond.get("condition") == "service_completed_successfully"
            )
    # restart: "no" marks a run-to-completion job even with no waiting consumer.
    one_shot_services.update(
        name for name, spec in services.items()
        if isinstance(spec, dict) and str(spec.get("restart")) == "no"
    )
groups, group_problems, membership_problems, exempt_groups = (
    gate_groups(services, project) if services is not None else (None, None, [], None)
)
config_problems = cors_origin_problems(services) if services is not None else []
if services is not None and exemptions:
    rendered_gated = {name for group in GATE_GROUPS for names in groups[group].values() for name in names}
    rendered_exempt = {name for group in GATE_GROUPS for names in exempt_groups[group].values() for name in names}
    refused = {p["service"] for group in GATE_GROUPS for p in group_problems[group]}
    unrendered = sorted(set(exemptions) - rendered_exempt - rendered_gated - refused)
    if unrendered:
        # A stale exemption is worse than none: it would bless whatever a later
        # render puts under that name.
        print(
            f"RELEASE_MANIFEST=FAIL exemption for {', '.join(unrendered)} names no rendered gated service",
            file=sys.stderr,
        )
        raise SystemExit(1)


def container_confirmed_absent(name):
    """True only when docker positively lists all containers and NAME is not one
    of them; an inspect failure alone never counts as absence."""
    if not docker:
        return False
    listing = subprocess.run(
        [docker, "container", "ls", "-a", "--format", "{{.Names}}"],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    return listing.returncode == 0 and name not in listing.stdout.split()


def classify_exempt(group, tag, names):
    """Return an EXEMPT record, or one whose freshness says why it is not."""
    record = {
        "image": tag,
        "services": names,
        "image_id": None,
        "revision": None,
        "declared": {name: exemptions[name] for name in names},
        "freshness": "UNAVAILABLE",
        "reason": None,
        "containers": [] if check_running else None,
    }
    payload, reason = inspect_json("image", tag)
    if payload is None:
        record["reason"] = reason
        return record
    labels = ((payload.get("Config") or {}).get("Labels") or {}) if isinstance(payload.get("Config") or {}, dict) else {}
    image_id = payload.get("Id")
    revision = labels.get("org.opencontainers.image.revision") if isinstance(labels, dict) else None
    record.update({"image_id": image_id, "revision": revision})
    for name in names:
        declared = exemptions[name]
        if image_id != declared["image_id"]:
            record["freshness"], record["reason"] = "STALE", (
                f"exempt {name}: tag {tag} is image {image_id}, not the exempted {declared['image_id']}"
            )
            return record
        if revision != declared["revision"]:
            record["freshness"], record["reason"] = "STALE", (
                f"exempt {name}: revision label {revision!r} is not the exempted {declared['revision']}"
            )
            return record
    ancestor = subprocess.run(
        ["git", "-C", os.path.join(workspace, "core4"), "merge-base", "--is-ancestor",
         revision, pins["WRFCOIN_RC_CORE4_COMMIT"]],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if ancestor.returncode != 0:
        record["freshness"], record["reason"] = "STALE", (
            f"exempt revision {revision} is not an ancestor of the core4 pin {pins['WRFCOIN_RC_CORE4_COMMIT']}"
        )
        return record
    if check_running:
        for name in names:
            container = services[name].get("container_name") or f"{project}-{name}-1"
            must_not_run = name in EXEMPT_MUST_NOT_RUN
            entry = {"service": name, "container": container, "container_image_id": None,
                     "running": None, "exit_code": None, "present": None,
                     "required_state": "not_running" if must_not_run else "runs_exempt_image"}
            record["containers"].append(entry)
            payload, reason = inspect_json("container", container)
            if payload is None:
                if must_not_run and container_confirmed_absent(container):
                    # An absent seed is not running anything: nothing to exempt.
                    entry.update({"present": False, "running": False})
                    continue
                record["reason"] = f"exempt container: {reason}"
                return record
            entry["present"] = True
            state = payload.get("State") if isinstance(payload.get("State"), dict) else {}
            entry.update({"container_image_id": payload.get("Image"),
                          "running": state.get("Running"), "exit_code": state.get("ExitCode")})
            if must_not_run and entry["running"] is not False:
                record["freshness"], record["reason"] = "STALE", (
                    f"exempt {name} container {container} is running (a full core4 node on an "
                    f"unreleased image); it must stay stopped to be exempt"
                )
                return record
            if entry["container_image_id"] != image_id:
                record["freshness"], record["reason"] = "STALE", (
                    f"exempt container {container} runs {entry['container_image_id']}, not the exempted {image_id}"
                )
                return record
    record["freshness"], record["reason"] = "EXEMPT", None
    return record

images = {}
stale = []
unavailable = []
findings = []
for group in GATE_GROUPS:
    summary = {
        "compose_services": [],
        "expected_revision": expected_revision.get(group, f"infra {infra_head} ({INFRA_BUILD_CONTEXTS.get(group)} unchanged)"),
        "tags": {},
        "problems": group_problems[group] if group_problems is not None else [],
        "freshness": "UNAVAILABLE",
        "reason": compose_error,
        "exempt": {},
    }
    tags = groups[group] if groups is not None else {}
    for tag, names in (exempt_groups[group] if exempt_groups is not None else {}).items():
        summary["exempt"][tag] = classify_exempt(group, tag, names)
    if groups is not None and not tags and not summary["problems"]:
        summary["reason"] = f"no rendered service builds or runs the {group} image"
    for tag, names in tags.items():
        record = {
            "image": tag,
            "services": names,
            "image_id": None,
            "created": None,
            "label_created": None,
            "revision": None,
            "freshness": "UNAVAILABLE",
            "evidence": "UNAVAILABLE",
            "reason": None,
            "containers": [] if check_running else None,
        }
        classify_image(group, record)
        if check_running and record["freshness"] == "FRESH":
            for name in names:
                spec = services[name]
                verdict, reason = check_container(
                    record, name, spec.get("container_name") or f"{project}-{name}-1",
                    name in one_shot_services,
                )
                if RANK[verdict] > RANK[record["freshness"]]:
                    record["freshness"], record["reason"] = verdict, reason
        summary["tags"][tag] = record
        summary["compose_services"].extend(names)
    summary["compose_services"].sort()
    if summary["tags"]:
        worst = max(summary["tags"].values(), key=lambda item: RANK[item["freshness"]])
        summary["freshness"] = worst["freshness"]
        summary["reason"] = None if worst["freshness"] == "FRESH" else worst["reason"]
        for record in summary["tags"].values():
            if record["freshness"] != "FRESH":
                findings.append(
                    f"{group} ({record['image']}; {','.join(record['services'])}): "
                    f"{record['freshness']}: {record['reason']}"
                )
    elif not summary["problems"]:
        findings.append(f"{group}: UNAVAILABLE: {summary['reason']}")
    for record in summary["exempt"].values():
        if record["freshness"] != "EXEMPT":
            findings.append(
                f"{group} ({record['image']}; {','.join(record['services'])}): "
                f"{record['freshness']} exemption: {record['reason']}"
            )
            if RANK[record["freshness"]] > RANK.get(summary["freshness"], 0) or summary["freshness"] == "FRESH":
                summary["freshness"] = record["freshness"]
                summary["reason"] = record["reason"]
    for problem in summary["problems"]:
        findings.append(f"{group}: UNAVAILABLE: {problem['service']}: {problem['reason']}")
        if summary["freshness"] == "FRESH" or not summary["tags"]:
            summary["freshness"] = "UNAVAILABLE"
            summary["reason"] = f"{problem['service']}: {problem['reason']}"
    if summary["freshness"] == "STALE":
        stale.append(group)
    elif summary["freshness"] == "UNAVAILABLE":
        unavailable.append(group)
    images[group] = summary

for problem in membership_problems:
    findings.append(f"membership: UNAVAILABLE: {problem['service']}: {problem['reason']}")
if membership_problems:
    unavailable.append("membership")
for problem in config_problems:
    findings.append(f"config: UNAVAILABLE: {problem['service']}: {problem['reason']}")
if config_problems:
    unavailable.append("config")
classification = "STALE" if stale else ("UNAVAILABLE" if unavailable else "FRESH")

mode = "check_running" if check_running else "pre_deploy"
manifest = {
    "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    # pre_deploy: tag-level only. check_running: every gated container was also
    # verified; only a check_running manifest is post-deploy release evidence.
    "mode": mode,
    "check_running": check_running,
    "minimum_public_build_date": pins["WRFCOIN_RC_MIN_PUBLIC_BUILD_DATE"],
    "repos": repos,
    "images": images,
    # Release builds that map to no gate group (always [] when FRESH).
    "membership_problems": membership_problems,
    # Rendered configuration a release must not ship (always [] when FRESH).
    "config_problems": config_problems,
    "classification": classification,
    "findings": findings,
    # Exempt services are never FRESH: they are recorded here and per group
    # under "exempt", and named in the summary line.
    # Which deployed non-git trees were bound with --release-tree (infra#1047).
    "release_trees": sorted(name for name, entry in repos.items() if "release_tree" in entry),
    "exemptions": {
        "file": exempt_file or None,
        "sha256": exempt_file_sha256,
        "services": sorted(exemptions),
    },
}
directory = os.path.dirname(os.path.abspath(output_path))
fd, temporary = tempfile.mkstemp(prefix=".release-manifest.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, output_path)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
for finding in findings:
    print(f"RELEASE_MANIFEST_FINDING {finding}", file=sys.stderr)
print(
    f"RELEASE_MANIFEST={classification} mode={mode} output={output_path} "
    f"repos={len(repos)} stale={','.join(stale) or 'none'} "
    f"unavailable={','.join(unavailable) or 'none'} "
    f"exempt={','.join(sorted(exemptions)) or 'none'}"
)
raise SystemExit(0 if classification == "FRESH" else (1 if classification == "STALE" else 2))
PY
