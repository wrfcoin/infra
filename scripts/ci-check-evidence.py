#!/usr/bin/env python3
"""Read-only PR check evidence; VOID is never admission. Refs infra#1248."""
import argparse
import json
import os
import re
import selectors
import subprocess
import time

SHA = re.compile(r"^[0-9a-f]{40}$")
# A reviewer still has to confirm the check actually covers this PR's paths.
WRAPPER = re.compile(r"summary|terminal guard", re.I)
PROVIDER_STEP = re.compile(r"^(set up job|complete job|post |checkout|run actions/checkout|install |set up |setup |cache |restore |report |summari)", re.I)


class Unavailable(RuntimeError):
    pass


class GitHub:
    def api(self, endpoint):
        for _ in range(2):
            try:
                result = subprocess.run(["gh", "api", endpoint], capture_output=True,
                                        text=True, timeout=30, check=True)
                return json.loads(result.stdout)
            except (OSError, ValueError, subprocess.SubprocessError):
                pass
        raise Unavailable(f"GitHub evidence unavailable after two attempts: {endpoint}")

    def checkout(self, repo, job_id):
        """Consume at most256KiB of checkout prefix; retain only its commit hash."""
        process = subprocess.Popen(["gh", "api", f"repos/{repo}/actions/jobs/{job_id}/logs"],
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        prefix = b""
        deadline = time.monotonic() + 30
        try:
            while len(prefix) < 262144 and time.monotonic() < deadline:
                if not selector.select(timeout=1):
                    continue
                chunk = os.read(process.stdout.fileno(), min(4096, 262144 - len(prefix)))
                if not chunk:
                    break
                prefix += chunk
                match = re.search(rb"git log -1 --format=(?:'|\")?%H(?:'|\")?[^\n]*\n[^\n]*?\b([0-9a-f]{40})\b", prefix)
                if match:
                    return match.group(1).decode()
            return None
        finally:
            selector.close()
            process.stdout.close()
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


def all_checks(api, repo, head):
    checks = []
    total = None
    for page in range(1, 101):
        response = api(f"repos/{repo}/commits/{head}/check-runs?per_page=100&filter=all&page={page}")
        count = response.get("total_count")
        part = response.get("check_runs")
        if (type(count) is not int or not 0 <= count <= 10000 or not isinstance(part, list)
                or len(part) > 100 or (total is not None and count != total)):
            raise Unavailable("incomplete or changing check pagination")
        total = count
        checks.extend(part)
        ids = [x.get("id") for x in checks]
        if (any(type(x) is not int for x in ids) or len(set(ids)) != len(ids)
                or len(checks) > total):
            raise Unavailable("duplicate or malformed check page")
        if len(checks) == total:
            return checks
        if len(part) != 100:
            raise Unavailable("truncated check page")
    raise Unavailable("check pagination budget exceeded")


def executed(steps):
    if not isinstance(steps, list) or any(not isinstance(s, dict) for s in steps):
        return []
    return [s for s in steps if s.get("status") == "completed"
            and s.get("conclusion") in ("success", "failure")
            and isinstance(s.get("started_at"), str) and s["started_at"]
            and isinstance(s.get("completed_at"), str) and s["completed_at"]]


def classify(check, job, pull, relevant, checkout_sha=None, parents=()):
    steps = executed(job.get("steps"))
    row = {"id": check.get("id"), "name": check.get("name"),
           "runner": job.get("runner_name"), "executed_steps": len(steps),
           "conclusion": check.get("conclusion"), "class": "VOID", "reason": ""}
    head = pull["head"]["sha"]
    reason = None
    if check.get("head_sha") != head or job.get("head_sha") != head:
        reason = "stale head"
    elif not isinstance(row["runner"], str) or not row["runner"].strip():
        reason = "missing runner identity"
    elif not steps:
        reason = "zero executed steps"
    elif check.get("status") != "completed" or job.get("status") != "completed":
        reason = "incomplete check/job"
    elif check.get("conclusion") != job.get("conclusion"):
        reason = "check/job disagreement"
    elif check.get("conclusion") not in ("success", "failure", "timed_out"):
        reason = "skipped/cancelled/nonterminal evidence"
    elif WRAPPER.search(check.get("name", "")) or not any(
            not PROVIDER_STEP.search(s.get("name", "")) for s in steps):
        reason = "wrapper/provider-only execution"
    elif not relevant:
        reason = "path relevance needs reviewer confirmation (--relevant-check)"
    elif not checkout_sha or not (checkout_sha == head or
                                  (head in parents and pull["base"]["sha"] in parents)):
        reason = "missing/stale materialized checkout identity"
    if reason:
        row["reason"] = reason
    else:
        failed = job["conclusion"] != "success" or any(
            s["conclusion"] == "failure" and not PROVIDER_STEP.search(s.get("name", ""))
            for s in steps)
        row.update({"class": "REAL-RED" if failed else "REAL-GREEN",
                    "reason": "current tree, confirmed relevant check, named runner, executed steps",
                    "checkout_sha": checkout_sha})
    return row


def inspect(github, repo, number, relevant_names):
    endpoint = f"repos/{repo}/pulls/{number}"
    pull = github.api(endpoint)
    head, base = pull["head"]["sha"], pull["base"]["sha"]
    if not SHA.fullmatch(head) or not SHA.fullmatch(base):
        raise Unavailable("invalid PR identity")
    checks = all_checks(github.api, repo, head)
    rows = []
    for check in checks:
        route = re.fullmatch(r"https://github.com/" + re.escape(repo) +
                             r"/actions/runs/(\d+)/job/(\d+)", check.get("details_url") or "")
        if not route:
            row = classify(check, {}, pull, False)
            row["reason"] = "no verifiable Actions job identity"
        else:
            run_id, job_id = map(int, route.groups())
            job = github.api(f"repos/{repo}/actions/jobs/{job_id}")
            if (job.get("id") != job_id or job.get("run_id") != run_id or
                    job.get("check_run_url") != f"https://api.github.com/repos/{repo}/check-runs/{check['id']}"
                    or job.get("name") != check.get("name")):
                raise Unavailable("check/job binding mismatch")
            relevant = check.get("name") in relevant_names
            checkout, parents = None, []
            if relevant and job.get("status") == "completed" and executed(job.get("steps")):
                checkout = github.checkout(repo, job_id)
                if checkout and checkout != head:
                    commit = github.api(f"repos/{repo}/git/commits/{checkout}")
                    if commit.get("sha") != checkout:
                        raise Unavailable("checkout commit binding mismatch")
                    parents = [p["sha"] for p in commit["parents"]]
            row = classify(check, job, pull, relevant, checkout, parents)
            row["run_id"] = run_id
        rows.append(row)
    refreshed = github.api(endpoint)
    if (refreshed["head"]["sha"], refreshed["base"]["sha"]) != (head, base):
        raise Unavailable("PR head/base moved during inspection")
    if not rows:
        rows = [{"id": None, "name": "MISSING", "runner": None, "executed_steps": 0,
                 "class": "VOID", "reason": "no checks at current head"}]
    # All history remains listed. Admission considers the newest check ID for each audited context.
    selected = [max((r for r in rows if r["name"] == name), key=lambda r: r["id"] or 0,
                    default={"class": "VOID"}) for name in relevant_names]
    admitted = bool(selected) and all(r["class"] == "REAL-GREEN" for r in selected)
    return {"repo": repo, "pr": number, "head": head, "base": base, "checks": rows,
            "admissible_checks": admitted, "relevant_checks": sorted(relevant_names)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo", help="repository or owner/repository")
    parser.add_argument("pr", type=int)
    parser.add_argument("--relevant-check", action="append", default=[],
                        help="exact context whose assertions the reviewer verified cover this PR")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    repo = args.repo if "/" in args.repo else "wrfcoin/" + args.repo
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo) or args.pr <= 0:
        parser.error("invalid repository/PR")
    try:
        result = inspect(GitHub(), repo, args.pr, set(args.relevant_check))
    except (Unavailable, KeyError, TypeError, AttributeError, OSError, ValueError) as error:
        print(json.dumps({"class": "UNKNOWN", "admissible_checks": False, "error": str(error)}))
        return 3
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"{repo}#{args.pr} HEAD {result['head']} BASE {result['base']}")
        for row in result["checks"]:
            print(f"{row['id']}\t{row['class']}\t{row['runner'] or '-'}\t"
                  f"{row['executed_steps']}\t{row['name']}\t{row['reason']}")
        print("CHECKS-ADMISSIBLE" if result["admissible_checks"] else "DO-NOT-ADMIT")
    return 0 if result["admissible_checks"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
