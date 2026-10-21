#!/usr/bin/env python3
"""Assert the canonical workspace ignore file against classic Docker semantics."""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "testnet" / "workspace.dockerignore"


@dataclass(frozen=True)
class Rule:
    source: str
    negated: bool
    regex: re.Pattern[str]


def glob_regex(pattern: str) -> str:
    """Translate the Docker glob forms used by the canonical template."""
    result: list[str] = []
    index = 0
    while index < len(pattern):
        char = pattern[index]
        if char == "*":
            if index + 1 < len(pattern) and pattern[index + 1] == "*":
                index += 2
                if index < len(pattern) and pattern[index] == "/":
                    result.append("(?:.*/)?")
                    index += 1
                else:
                    result.append(".*")
                continue
            result.append("[^/]*")
        elif char == "?":
            result.append("[^/]")
        else:
            result.append(re.escape(char))
        index += 1
    return "".join(result)


def compile_rules(lines: list[str]) -> list[Rule]:
    rules: list[Rule] = []
    for raw_line in lines:
        source = raw_line.strip()
        if not source or source.startswith("#"):
            continue

        negated = source.startswith("!")
        pattern = source[1:] if negated else source
        anchored = pattern.startswith("/")
        pattern = pattern.lstrip("/").rstrip("/")
        if not pattern:
            continue

        translated = glob_regex(pattern)
        if anchored or "/" in pattern:
            expression = rf"^{translated}(?:/.*)?$"
        else:
            expression = rf"^(?:.*/)?{translated}(?:/.*)?$"
        rules.append(Rule(source, negated, re.compile(expression)))
    return rules


def last_match(path: str, rules: list[Rule]) -> tuple[bool, str]:
    result = True
    matching_rule = "<default include>"
    for rule in rules:
        if rule.regex.fullmatch(path):
            result = rule.negated
            matching_rule = rule.source
    return result, matching_rule


def included(path: str, rules: list[Rule]) -> tuple[bool, str]:
    normalized = path.strip("/")
    parts = normalized.split("/")

    # Classic Docker prunes an excluded directory before it can inspect a later
    # negation for a child. Its scratch-context oracle therefore excludes
    # core4/target/.env.example even though a flat last-match evaluation reaches
    # !**/.env.example. BuildKit was not part of that oracle and may differ.
    for depth in range(1, len(parts)):
        parent = "/".join(parts[:depth])
        parent_included, parent_match = last_match(parent, rules)
        if not parent_included:
            return False, f"{parent_match} (excluded parent: {parent})"

    return last_match(normalized, rules)


def assert_paths(rules: list[Rule], expected: bool, paths: list[str]) -> int:
    failures = 0
    disposition = "included" if expected else "excluded"
    for path in paths:
        actual, last_match = included(path, rules)
        if actual == expected:
            print(f"PASS {disposition:8} {path}  (last match: {last_match})")
        else:
            print(
                f"FAIL expected {disposition}: {path}  "
                f"(last match: {last_match})",
                file=sys.stderr,
            )
            failures += 1
    return failures


def assert_real_template_red_control(template_lines: list[str]) -> int:
    """Append the original ordering bug to the real template, then restore it."""
    dangerous_paths = [
        "core4/target/debug/libwrfcoin.rlib",
        "core4/target-aarch64/release/launch_api",
        "backend/node_modules/typescript/index.js",
        "backend/.env",
        "core4/.git/config",
        "backend/dist/server.js",
    ]
    original_length = len(template_lines)
    template_lines.extend(
        [
            "",
            "# RED control: reproduce the broad-allowlist ordering inversion.",
            "!/core4/**",
            "!/backend/**",
        ]
    )
    mutated_rules = compile_rules(template_lines)
    failures = 0

    for dangerous_path in dangerous_paths:
        is_included, matching_rule = included(dangerous_path, mutated_rules)
        if is_included:
            print(
                f"PASS RED control mutates real template: {dangerous_path} "
                f"is re-included by {matching_rule}"
            )
        else:
            print(
                "FAIL real-template RED control did not reproduce inversion: "
                f"{dangerous_path} (last match: {matching_rule})",
                file=sys.stderr,
            )
            failures += 1

    # Restore the loaded real-template lines, then prove every path returns to
    # the safe disposition. The repository file itself is never rewritten.
    del template_lines[original_length:]
    restored_rules = compile_rules(template_lines)
    for dangerous_path in dangerous_paths:
        is_included, matching_rule = included(dangerous_path, restored_rules)
        if not is_included:
            print(
                f"PASS RED control restores real template: {dangerous_path} "
                f"is excluded by {matching_rule}"
            )
        else:
            print(
                "FAIL real-template RED control did not restore exclusion: "
                f"{dangerous_path} (last match: {matching_rule})",
                file=sys.stderr,
            )
            failures += 1

    return failures


def main() -> int:
    template_lines = TEMPLATE.read_text(encoding="utf-8").splitlines()
    rules = compile_rules(template_lines)
    failures = 0

    failures += assert_paths(
        rules,
        True,
        [
            ".dockerignore",
            ".env.example",
            ".env.testnet.example",
            "core4/Cargo.toml",
            "backend/package.json",
            "frontend/src/index.ts",
            "infra/docker/Dockerfile.core",
            # infra#1016: Dockerfile.core COPYs this key; excluding it breaks the build.
            "infra/infra/docker/apt-keys/yubico-stable-ppa.asc",
            "infra/testnet/.env.example",
            "core4/.env.testnet.example",
        ],
    )
    failures += assert_paths(
        rules,
        False,
        [
            "core4/target/debug/libwrfcoin.rlib",
            "core4/target-aarch64/release/launch_api",
            "core4/target/.env.example",
            "backend/node_modules/typescript/index.js",
            "backend/.env",
            "infra/testnet/.env",
            "infra/testnet/.env.bak-20260727",
            "core4/.git/config",
            "frontend/.cache/bundle",
            "backend/dist/server.js",
            "instrument-maker/README.md",
            "instrument-maker/build/unrelated.bin",
            "worktrees/core4-dan/target/debug/cache",
        ],
    )

    failures += assert_real_template_red_control(template_lines)

    if failures:
        print(f"\nworkspace dockerignore semantics: {failures} failure(s)", file=sys.stderr)
        return 1
    print("\nworkspace dockerignore semantics: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
