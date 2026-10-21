#!/usr/bin/env python3
"""
Adversarial Simulation Regression Checker

Reads cargo test output from the adversarial simulation suite and checks for
regressions in test count and execution time.

Usage:
    python3 scripts/check-adversarial-regression.py <test-output-file>

Exit codes:
    0 - No regressions detected
    1 - Regression detected or parse error
"""

import re
import sys
import json
import os

# Thresholds
MIN_EXPECTED_TESTS = 26
MAX_EXECUTION_TIME_MS = 30_000  # 30 seconds max for all adversarial tests
TIME_REGRESSION_PERCENT = 20  # Alert if execution time increases by 20%

BASELINE_FILE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    ".adversarial-baseline.json",
)


def parse_test_output(filepath: str) -> dict:
    """Parse cargo test output and extract metrics."""
    with open(filepath, "r") as f:
        content = f.read()

    # Count passed/failed tests
    passed = len(re.findall(r"^test .+ \.\.\. ok$", content, re.MULTILINE))
    failed = len(re.findall(r"^test .+ \.\.\. FAILED$", content, re.MULTILINE))
    ignored = len(re.findall(r"^test .+ \.\.\. ignored$", content, re.MULTILINE))

    # Extract summary line: "test result: ok. 26 passed; 0 failed; ..."
    summary_match = re.search(
        r"test result: \w+\. (\d+) passed; (\d+) failed; (\d+) ignored; "
        r"\d+ measured; \d+ filtered out; finished in ([\d.]+)s",
        content,
    )

    execution_time_s = 0.0
    if summary_match:
        passed = int(summary_match.group(1))
        failed = int(summary_match.group(2))
        ignored = int(summary_match.group(3))
        execution_time_s = float(summary_match.group(4))

    # Extract individual test names for tracking
    test_names = re.findall(r"^test (\S+) \.\.\. \w+$", content, re.MULTILINE)

    return {
        "passed": passed,
        "failed": failed,
        "ignored": ignored,
        "total": passed + failed + ignored,
        "execution_time_s": execution_time_s,
        "test_names": sorted(test_names),
    }


def load_baseline() -> dict | None:
    """Load previous baseline if it exists."""
    if os.path.exists(BASELINE_FILE):
        with open(BASELINE_FILE, "r") as f:
            return json.load(f)
    return None


def save_baseline(metrics: dict) -> None:
    """Save current metrics as the new baseline."""
    baseline = {
        "passed": metrics["passed"],
        "total": metrics["total"],
        "execution_time_s": metrics["execution_time_s"],
        "test_names": metrics["test_names"],
    }
    with open(BASELINE_FILE, "w") as f:
        json.dump(baseline, f, indent=2)


def check_regressions(metrics: dict, baseline: dict | None) -> list[str]:
    """Check for regressions against baseline and absolute thresholds."""
    issues = []

    # Absolute checks
    if metrics["failed"] > 0:
        issues.append(f"FAIL: {metrics['failed']} test(s) failed")

    if metrics["passed"] < MIN_EXPECTED_TESTS:
        issues.append(
            f"FAIL: Only {metrics['passed']} tests passed "
            f"(minimum expected: {MIN_EXPECTED_TESTS})"
        )

    execution_time_ms = metrics["execution_time_s"] * 1000
    if execution_time_ms > MAX_EXECUTION_TIME_MS:
        issues.append(
            f"WARN: Execution time {execution_time_ms:.0f}ms exceeds "
            f"threshold {MAX_EXECUTION_TIME_MS}ms"
        )

    # Relative checks against baseline
    if baseline:
        # Test count regression
        if metrics["passed"] < baseline["passed"]:
            delta = baseline["passed"] - metrics["passed"]
            pct = (delta / baseline["passed"]) * 100
            issues.append(
                f"FAIL: {delta} fewer tests passed vs baseline "
                f"({metrics['passed']} vs {baseline['passed']}, -{pct:.1f}%)"
            )

        # Execution time regression
        if baseline["execution_time_s"] > 0 and metrics["execution_time_s"] > 0:
            time_increase_pct = (
                (metrics["execution_time_s"] - baseline["execution_time_s"])
                / baseline["execution_time_s"]
            ) * 100
            if time_increase_pct > TIME_REGRESSION_PERCENT:
                issues.append(
                    f"WARN: Execution time increased by {time_increase_pct:.1f}% "
                    f"({baseline['execution_time_s']:.2f}s -> "
                    f"{metrics['execution_time_s']:.2f}s)"
                )

        # Check for missing tests
        if baseline.get("test_names"):
            baseline_set = set(baseline["test_names"])
            current_set = set(metrics["test_names"])
            removed = baseline_set - current_set
            if removed:
                issues.append(
                    f"WARN: Tests removed since baseline: {', '.join(sorted(removed))}"
                )

    return issues


def main() -> int:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <test-output-file>")
        return 1

    filepath = sys.argv[1]
    if not os.path.exists(filepath):
        print(f"Error: File not found: {filepath}")
        return 1

    print(f"Parsing test output from: {filepath}")
    metrics = parse_test_output(filepath)

    print(f"\nAdversarial Test Results:")
    print(f"  Passed:  {metrics['passed']}")
    print(f"  Failed:  {metrics['failed']}")
    print(f"  Ignored: {metrics['ignored']}")
    print(f"  Total:   {metrics['total']}")
    print(f"  Time:    {metrics['execution_time_s']:.2f}s")
    print(f"  Tests:   {len(metrics['test_names'])} identified")

    baseline = load_baseline()
    if baseline:
        print(f"\nBaseline comparison:")
        print(f"  Previous passed: {baseline['passed']}")
        print(f"  Previous time:   {baseline['execution_time_s']:.2f}s")

    issues = check_regressions(metrics, baseline)

    if issues:
        print(f"\nIssues detected:")
        has_failure = False
        for issue in issues:
            print(f"  {issue}")
            if issue.startswith("FAIL:"):
                has_failure = True

        if has_failure:
            print("\nRegression check FAILED")
            return 1
        else:
            print("\nWarnings only, no blocking regressions")

    # Update baseline on success
    if metrics["failed"] == 0 and metrics["passed"] >= MIN_EXPECTED_TESTS:
        save_baseline(metrics)
        print(f"\nBaseline updated: {BASELINE_FILE}")

    print("\nRegression check PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
