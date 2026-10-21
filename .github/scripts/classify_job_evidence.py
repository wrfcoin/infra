#!/usr/bin/env python3
"""Classify a workflow job's EVIDENCE, not merely its conclusion (infra#894).

A GitHub job conclusion of ``failure`` conflates four different things:

  REAL-RED      the job ran on a real runner, executed steps, and a step failed.
                This is evidence about the code. It must block.
  VOID          the job never started: ``runner_name`` empty and/or zero steps
                (exhausted hosted minutes, no matching runner, billing failure).
                This is evidence about NOTHING and must not block -- but it must
                be impossible to mistake for a pass.
  ENV-REFUSED   the job ran, but the only thing that failed was a declared
                environment preflight (e.g. no Docker daemon). This is evidence
                about the runner, not the code. It must not block, and it must
                not read as a code failure -- the exact misattribution that made
                core4#2958's docker socket fault look like an execution-engine
                test bug.
  UNKNOWN       we could not retrieve the record. Fails closed: absence of
                evidence never admits.

Why this lives OUTSIDE the job it classifies: a checker cannot detect a fault
that also prevents the checker from running. This script therefore runs on a
runner class that is known to execute (the self-hosted CT102 infra runner),
while the job it inspects runs on the class that is currently VOID. Hosting it
inside ``runtime-edge`` would make it vacuous by construction.

Exit codes:
  0  REAL-GREEN, VOID, ENV-REFUSED, CANCELLED, SKIPPED  (non-blocking)
  1  REAL-RED, UNKNOWN                                   (blocking)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any


REAL_GREEN = "REAL-GREEN"
REAL_RED = "REAL-RED"
VOID = "VOID"
ENV_REFUSED = "ENV-REFUSED"
CANCELLED = "CANCELLED"
SKIPPED = "SKIPPED"
UNKNOWN = "UNKNOWN"

BLOCKING = {REAL_RED, UNKNOWN}

FAILED_CONCLUSIONS = {"failure", "timed_out"}


def blocks(classification: str, expect_real_evidence: bool = False) -> bool:
    """Does this classification fail the gate?

    REAL-RED and UNKNOWN always block. VOID blocks ONLY under
    ``--expect-real-evidence``, which asserts that the caller knows the job
    should have produced a real result. That assertion is not derivable from the
    job record: a VOID job carries no reason for its own absence, so nothing here
    can tell "the runner legitimately could not serve this" from "the runner
    should have and did not". The flag is how a caller supplies the knowledge the
    record lacks -- it is not a heuristic this script can infer.
    """
    if classification in BLOCKING:
        return True
    return expect_real_evidence and classification == VOID


def classify(
    job: dict[str, Any] | None,
    environment_steps: frozenset[str],
    env_unavailable: bool = False,
) -> tuple[str, str]:
    """Return ``(classification, human reason)`` for one job record."""
    if job is None:
        return UNKNOWN, "no job record matched the requested name in this run attempt"

    status = job.get("status")
    if status != "completed":
        return UNKNOWN, f"job is not completed (status={status!r}); no verdict is available yet"

    runner = (job.get("runner_name") or "").strip()
    steps = job.get("steps") or []
    conclusion = job.get("conclusion")

    # SKIPPED IS CHECKED FIRST, DELIBERATELY. A skipped job also has an empty
    # runner_name and zero steps, so the VOID rule below would otherwise swallow
    # it and report "nothing executed it" for a job that was never meant to run.
    # The two are different facts and must not collapse.
    if conclusion == "skipped":
        if env_unavailable:
            return ENV_REFUSED, (
                "job was skipped because the environment probe reported the runner "
                "cannot serve it. The gate did not run and did not fail: there is no "
                "runtime evidence for this commit, and no code defect is implied."
            )
        return SKIPPED, "job was skipped; a skip is not success evidence"

    if not runner and not steps:
        return VOID, (
            "job never started: runner_name is empty AND zero steps executed. "
            "No runner picked this job up (exhausted hosted minutes, billing "
            "failure, or no runner matches its labels)."
        )
    if not runner:
        return VOID, "job has no runner_name; nothing executed it"
    if not steps:
        return VOID, f"job reports runner {runner!r} but executed zero steps"

    failed = [s for s in steps if s.get("conclusion") in FAILED_CONCLUSIONS]

    if failed:
        names = [s.get("name", "") for s in failed]
        if all(name in environment_steps for name in names):
            return ENV_REFUSED, (
                "the only failing step(s) are declared environment preflights "
                f"({', '.join(repr(n) for n in names)}). The runner could not "
                "provide what the job needs. This is not evidence about the code."
            )
        code_failures = [n for n in names if n not in environment_steps]
        return REAL_RED, (
            f"executed {len(steps)} step(s) on runner {runner!r} and "
            f"{len(code_failures)} non-environment step(s) failed: "
            f"{', '.join(repr(n) for n in code_failures)}"
        )

    if conclusion in FAILED_CONCLUSIONS:
        return REAL_RED, (
            f"job conclusion is {conclusion!r} on runner {runner!r} with "
            f"{len(steps)} executed step(s) and no individually failing step"
        )
    if conclusion == "cancelled":
        return CANCELLED, "job was cancelled; a cancelled run is a null result, not a pass"
    if conclusion == "success":
        return REAL_GREEN, f"executed {len(steps)} step(s) on runner {runner!r}, all passed"
    return UNKNOWN, f"unrecognised conclusion {conclusion!r}"


def find_job(jobs: list[dict[str, Any]], job_name: str) -> dict[str, Any] | None:
    """Match a job by exact name, then by prefix.

    Matrix and reusable-workflow jobs append suffixes to the configured name, so
    an exact match alone is too brittle; a prefix match alone would let a
    rename silently select the wrong job. Exact wins when present.
    """
    for job in jobs:
        if job.get("name") == job_name:
            return job
    prefixed = [j for j in jobs if str(j.get("name", "")).startswith(job_name)]
    if len(prefixed) == 1:
        return prefixed[0]
    return None


def emit(classification: str, reason: str, job_name: str, expect_real_evidence: bool = False) -> None:
    blocking = blocks(classification, expect_real_evidence)
    headline = f"{classification}: {job_name}"

    if classification == REAL_GREEN:
        marker = "notice"
    elif blocking:
        marker = "error"
    else:
        marker = "warning"
    print(f"::{marker} title={headline}::{reason}")

    print(f"\n{'=' * 72}\n{headline}\n{'=' * 72}\n{reason}\n")
    if classification == VOID:
        print(
            "VOID IS NOT A PASS AND NOT A FAILURE.\n"
            "This gate has produced no runtime evidence for this commit. Do not\n"
            "cite this run as coverage in either direction. See infra#894.\n"
        )
    if classification == ENV_REFUSED:
        print(
            "ENVIRONMENT REFUSAL, NOT A CODE FAILURE.\n"
            "The runner could not supply a prerequisite. Do not open a code bug\n"
            "from this result; repair the runner. See core4#2958.\n"
        )

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        icon = {
            REAL_GREEN: "PASS",
            REAL_RED: "BLOCKING FAILURE",
            VOID: "NO EVIDENCE",
            ENV_REFUSED: "NO EVIDENCE (runner)",
            CANCELLED: "NULL RESULT",
            SKIPPED: "NULL RESULT",
            UNKNOWN: "BLOCKING UNKNOWN",
        }[classification]
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.write(
                f"### Runtime edge evidence: {classification}\n\n"
                f"**{icon}** — {reason}\n\n"
                f"Blocking: {'yes' if blocking else 'no'}\n\n"
            )


def _job(name="j", runner="n5pro-ct102-infra", steps=None, conclusion="success", status="completed"):
    if steps is None:
        steps = [{"name": "Set up job", "conclusion": "success"}]
    return {"name": name, "runner_name": runner, "steps": steps, "conclusion": conclusion, "status": status}


def self_test() -> int:
    """RED controls: prove each distinction actually distinguishes.

    A classifier that returned one constant would satisfy any single case, so
    every case below asserts a value the others do not share.
    """
    env_steps = frozenset({"Docker preflight"})
    cases: list[tuple[str, dict[str, Any] | None, str]] = [
        (
            "runnerless + zero steps is VOID, not RED",
            _job(runner="", steps=[], conclusion="failure"),
            VOID,
        ),
        (
            "named runner but zero steps is VOID",
            _job(runner="ubuntu-latest", steps=[], conclusion="failure"),
            VOID,
        ),
        (
            "runnerless but with steps is still VOID",
            _job(runner="", steps=[{"name": "Set up job", "conclusion": "success"}]),
            VOID,
        ),
        (
            "a failing code step is REAL-RED",
            _job(
                steps=[
                    {"name": "Set up job", "conclusion": "success"},
                    {"name": "Run runtime verifier and RED controls", "conclusion": "failure"},
                ],
                conclusion="failure",
            ),
            REAL_RED,
        ),
        (
            "a failing environment preflight is ENV-REFUSED, not REAL-RED",
            _job(
                steps=[
                    {"name": "Set up job", "conclusion": "success"},
                    {"name": "Docker preflight", "conclusion": "failure"},
                    {"name": "Run runtime verifier and RED controls", "conclusion": "skipped"},
                ],
                conclusion="failure",
            ),
            ENV_REFUSED,
        ),
        (
            "environment preflight PLUS a real code failure is REAL-RED, not excused",
            _job(
                steps=[
                    {"name": "Docker preflight", "conclusion": "failure"},
                    {"name": "Run runtime verifier and RED controls", "conclusion": "failure"},
                ],
                conclusion="failure",
            ),
            REAL_RED,
        ),
        (
            "job-level failure with no failing step is still REAL-RED",
            _job(steps=[{"name": "Set up job", "conclusion": "success"}], conclusion="failure"),
            REAL_RED,
        ),
        (
            "continue-on-error masking the conclusion does not hide a failing step",
            _job(
                steps=[{"name": "Run runtime verifier and RED controls", "conclusion": "failure"}],
                conclusion="success",
            ),
            REAL_RED,
        ),
        (
            "a SKIPPED job is SKIPPED, not VOID (it also has no runner and no steps)",
            _job(runner="", steps=[], conclusion="skipped"),
            SKIPPED,
        ),
        ("a real all-green job is REAL-GREEN", _job(), REAL_GREEN),
        ("cancelled is a null result", _job(conclusion="cancelled"), CANCELLED),
        ("skipped is a null result", _job(conclusion="skipped"), SKIPPED),
        ("an incomplete job is UNKNOWN", _job(status="in_progress", conclusion=None), UNKNOWN),
        ("a missing job record is UNKNOWN", None, UNKNOWN),
    ]

    failures = 0
    for label, job, expected in cases:
        actual, reason = classify(job, env_steps)
        ok = actual == expected
        print(f"  [{'ok' if ok else 'FAIL'}] {label}: expected {expected}, got {actual}")
        if not ok:
            print(f"         reason: {reason}")
            failures += 1

    # env_unavailable turns an unexplained skip into a named environment refusal.
    got, _ = classify(_job(runner="", steps=[], conclusion="skipped"), env_steps, env_unavailable=True)
    if got != ENV_REFUSED:
        print(f"  [FAIL] skip + env_unavailable must be ENV-REFUSED, got {got}")
        failures += 1
    else:
        print("  [ok] skip under a refusing environment probe is ENV-REFUSED, not a bare skip")

    # The blocking decision, which is the whole contract with the workflow.
    for cls, expect, want in [
        (REAL_RED, False, True), (UNKNOWN, False, True),
        (ENV_REFUSED, False, False), (VOID, False, False),
        (SKIPPED, False, False), (CANCELLED, False, False), (REAL_GREEN, False, False),
        (VOID, True, True), (ENV_REFUSED, True, False), (REAL_GREEN, True, False),
    ]:
        got_block = blocks(cls, expect)
        if got_block != want:
            print(f"  [FAIL] blocks({cls}, expect_real_evidence={expect}) = {got_block}, want {want}")
            failures += 1
    print("  [ok] blocking contract: REAL-RED/UNKNOWN always block; ENV-REFUSED/VOID/SKIPPED do not")
    print("  [ok] --expect-real-evidence upgrades VOID to blocking, and nothing else")

    blocking_expected = {REAL_RED, UNKNOWN}
    if BLOCKING != blocking_expected:
        print(f"  [FAIL] BLOCKING set drifted: {BLOCKING} != {blocking_expected}")
        failures += 1
    else:
        print(f"  [ok] only {sorted(blocking_expected)} block the gate")

    # find_job must not silently pick a wrong job when the name is ambiguous.
    ambiguous = [{"name": "Runtime x"}, {"name": "Runtime y"}]
    if find_job(ambiguous, "Runtime") is not None:
        print("  [FAIL] ambiguous prefix match must return None, not a guess")
        failures += 1
    else:
        print("  [ok] ambiguous prefix match refuses to guess")

    if find_job([{"name": "Runtime public exposure harness"}], "Runtime public exposure harness") is None:
        print("  [FAIL] exact match must be found")
        failures += 1
    else:
        print("  [ok] exact name match resolves")

    print(f"\nself-test: {'PASS' if failures == 0 else f'{failures} FAILURE(S)'}")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--jobs-file", help="JSON from GET /actions/runs/{id}/attempts/{n}/jobs")
    parser.add_argument("--job-name", help="the job whose evidence is being classified")
    parser.add_argument(
        "--environment-step",
        action="append",
        default=[],
        metavar="NAME",
        help="step name whose failure means the RUNNER could not serve the job, "
             "not that the code is broken. Repeatable.",
    )
    parser.add_argument(
        "--env-unavailable",
        action="store_true",
        help="the environment probe reported the runner cannot serve this job, so a "
             "SKIPPED result means environment refusal rather than an unexplained skip",
    )
    parser.add_argument(
        "--expect-real-evidence",
        action="store_true",
        help="assert the job SHOULD have produced a real result, making VOID blocking. "
             "Off by default: a VOID record carries no reason for its own absence.",
    )
    parser.add_argument("--self-test", action="store_true", help="run RED controls and exit")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    if not args.jobs_file or not args.job_name:
        parser.error("--jobs-file and --job-name are required unless --self-test is given")

    try:
        with open(args.jobs_file, encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        # Fail closed: a retrieval failure is UNKNOWN, and UNKNOWN blocks.
        emit(UNKNOWN, f"could not read job records: {exc}", args.job_name, args.expect_real_evidence)
        return 1

    jobs = payload.get("jobs")
    if not isinstance(jobs, list):
        emit(UNKNOWN, "job records payload has no 'jobs' array", args.job_name, args.expect_real_evidence)
        return 1

    classification, reason = classify(
        find_job(jobs, args.job_name),
        frozenset(args.environment_step),
        env_unavailable=args.env_unavailable,
    )
    emit(classification, reason, args.job_name, expect_real_evidence=args.expect_real_evidence)
    return 1 if blocks(classification, args.expect_real_evidence) else 0


if __name__ == "__main__":
    sys.exit(main())
