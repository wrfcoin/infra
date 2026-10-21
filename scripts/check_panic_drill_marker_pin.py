#!/usr/bin/env python3
"""Fail closed when the pinned drill marker no longer matches the core4 being built (infra#1034 N1).

The Node Image Ship-Feature Guard proves a shipped `launch_api` carries no `panic-drill`
build by scanning it for the drill's trigger literal, `PANIC_DRILL_MARKER` in core4's
`scripts/check_release_endpoints.py` at the pinned CHECKER_SHA. That proof is only as good
as the literal. If core4 renames the trigger (or the feature) and CHECKER_SHA is not
bumped, the scan looks for a string no build can contain and passes blind.

So the BUILD source must agree with the pinned checker, in both directions:

"Marker in native-chain/src" means: the exact marker as a string literal (plain, raw or byte)
in code that compiles into a non-test build -- comments, doc comments, `#[cfg(test)]` items
and modules, `#![cfg(test)]` files and `tests/`/`benches/`/`tests.rs`-style files do not count.
A rename that leaves `// formerly <MARKER>` behind is therefore still a rename (#1037 review B1).
A literal bound to a named `const`/`static` must also be READ: if that name is never referenced from live code
in native-chain/src, the const is dead and the scan is as blind as after a rename (infra#1038 R1; a by-name
check, it cannot prove the referencing code is itself reachable). A `cfg(..)` counts as test-only only when it
can never hold outside a test build: `test` and `all(.., test, ..)`, not `any(test, feature = "x")` (R2). A literal anywhere inside a const/static initializer (`= { "m" }`, `= ["m"]`) belongs to that item and must be read; an invalid `cfg(..)` fails the check closed.

  feature declared in native-chain/Cargo.toml   marker in native-chain/src   verdict
  yes                                            yes                           OK (scan is live)
  no                                             no                            OK, announced VACUOUS
                                                                               (source predates the drill)
  yes                                            no                            FAIL: marker renamed
  no                                             yes                           FAIL: feature renamed

    python3 scripts/check_panic_drill_marker_pin.py --core4 wrfcoin/core4 \
        --checker core4-checker/scripts/check_release_endpoints.py
"""

from __future__ import annotations

import argparse
import importlib.util
import re
import sys
from pathlib import Path


def load_checker(checker: Path) -> tuple[str, str]:
    spec = importlib.util.spec_from_file_location("core4_check_release_endpoints", checker)
    if spec is None or spec.loader is None:
        raise ValueError(f"{checker}: cannot load as a Python module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    feature = getattr(module, "PANIC_DRILL_FEATURE", None)
    marker = getattr(module, "PANIC_DRILL_MARKER", None)
    if not feature or not marker:
        raise ValueError(f"{checker}: no PANIC_DRILL_FEATURE / PANIC_DRILL_MARKER; cannot pin the scan")
    return feature, marker


# Files that only ever compile into tests: `tests/`/`benches/` trees and the conventional
# `tests.rs`/`test.rs`/`*_test(s).rs` modules pulled in by `#[cfg(test)] mod tests;`.
TEST_DIRS = {"tests", "benches"}
TEST_FILE = re.compile(r"^(tests?|.*_tests?)\.rs$")
_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_CHAR = re.compile(r"'(?:\\(?:x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]{1,6}\}|.)|[^\\'\n])'")
_RAW = re.compile(r'(b?r)(#*)"')


def _tokens(text: str):
    """Minimal Rust lexer: yields ('str', value), ('id', name), ('attr', inner, is_inner) and ('p', one of `{}()[];=`).

    Comments (line, doc, nested block) are dropped. String, raw-string and byte-string literals
    are yielded with their raw contents; char literals and lifetimes are skipped.
    """
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if text.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif text.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            yield ("str", text[i + 1:j])
            i = j + 1
        elif c == "'":
            m = _CHAR.match(text, i)
            i = m.end() if m else i + 1  # char literal, or the quote of a lifetime
        elif c.isalpha() or c == "_":
            m = _RAW.match(text, i)
            if m and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == "_")):
                close = '"' + m.group(2)
                j = text.find(close, m.end())
                j = n if j < 0 else j
                yield ("str", text[m.end():j])
                i = j + len(close)
                continue
            m = _IDENT.match(text, i)
            i = m.end()
            if m.group(0) == "b" and i < n and text[i] in "\"'":
                continue  # b"..." / b'.' : the literal itself is lexed next
            yield ("id", m.group(0))
        elif c == "#" and (text.startswith("#[", i) or text.startswith("#![", i)):
            inner = text.startswith("#![", i)
            j = i + (3 if inner else 2)
            depth, start = 1, j
            while j < n and depth:
                if text[j] == "[":
                    depth += 1
                elif text[j] == "]":
                    depth -= 1
                elif text[j] == '"':
                    j += 1
                    while j < n and text[j] != '"':
                        j += 2 if text[j] == "\\" else 1
                j += 1
            yield ("attr", text[start:j - 1], inner)
            i = j
        else:
            if c in "{}();[]=":
                yield ("p", c)
            i += 1


class CfgError(ValueError):
    """A `cfg(..)` attribute that is not valid cfg grammar: the checker cannot tell test-only from live."""


_CFG_TOKEN = re.compile(r'\s*(?:([A-Za-z_]\w*)|(""|[(),=]))')


def _cfg_tokens(body: str) -> list[str]:
    text, pos, out = re.sub(r'"[^"]*"', '""', body), 0, []
    while text[pos:].strip():
        m = _CFG_TOKEN.match(text, pos)
        if m is None:
            raise CfgError(f"unexpected character {text[pos:].strip()[0]!r}")
        out.append(m.group(1) or m.group(2))
        pos = m.end()
    return out


def _cfg_pred(toks: list[str], i: int) -> tuple[bool, int]:
    """Parse one cfg predicate at toks[i]; (can_only_hold_in_tests, next index). Raises CfgError.

    Grammar: ident | ident = "str" | (all|any|not) ( pred {, pred} [,] ). `test` and `all(.. test ..)`
    are test-only; `any(..)` only when every arm is (so `any(test, feature = "x")` is live, infra#1038 R2);
    `not(..)` and `key = "value"` are live.
    """
    if i >= len(toks) or not re.fullmatch(r"[A-Za-z_]\w*", toks[i]):
        raise CfgError("expected a cfg predicate")
    name = toks[i]
    nxt = toks[i + 1] if i + 1 < len(toks) else None
    if nxt == "=":
        if i + 2 >= len(toks) or toks[i + 2] != '""':
            raise CfgError(f"`{name} =` needs a string value")
        return False, i + 3
    if nxt == "(":
        if name not in ("all", "any", "not"):
            raise CfgError(f"unknown cfg predicate `{name}(..)`")
        i += 2
        arms: list[bool] = []
        while True:
            if i >= len(toks):
                raise CfgError(f"unclosed `{name}(`")
            if toks[i] == ")":
                break
            verdict, i = _cfg_pred(toks, i)
            arms.append(verdict)
            if i < len(toks) and toks[i] == ",":
                i += 1
            elif i >= len(toks) or toks[i] != ")":
                raise CfgError(f"missing `,` or `)` in `{name}(..)`")
        if name == "not" and len(arms) != 1:
            raise CfgError("`not(..)` takes exactly one predicate")
        if name == "all":
            return any(arms), i + 1
        if name == "any":
            return bool(arms) and all(arms), i + 1
        return False, i + 1
    if name in ("all", "any", "not"):
        raise CfgError(f"`{name}` needs `(..)`")
    return name == "test", i + 1


def _is_test_cfg(attr: str) -> bool:
    """True when `cfg(..)` can only hold in a test build; raises CfgError on invalid cfg grammar."""
    m = re.fullmatch(r"\s*cfg\s*\((.*)\)\s*", attr, re.S)
    if m is None:
        return False
    toks = _cfg_tokens(m.group(1))
    verdict, end = _cfg_pred(toks, 0)
    if end < len(toks) and toks[end] == ",":
        end += 1  # `cfg(test,)`: one trailing comma is legal
    if end != len(toks):
        raise CfgError(f"unexpected `{toks[end]}` after the predicate")
    return verdict


def live_string_literals(text: str) -> list[str]:
    """String literals that compile into a non-test build: comments dropped, #[cfg(test)] items skipped."""
    return [tok[1] for tok in live_tokens(text) if tok[0] == "str"]


def live_tokens(text: str) -> list[tuple]:
    """('str', value), ('id', name) and ('p', c) tokens of the code that compiles into a non-test build."""
    out: list[tuple] = []
    tokens = list(_tokens(text))
    k, depth = 0, 0
    while k < len(tokens):
        tok = tokens[k]
        if tok[0] == "attr" and _is_test_cfg(tok[1]):
            if tok[2]:  # #![cfg(test)]: the enclosing module (or file) is test-only
                if depth == 0:
                    return out
                level = depth
                while k < len(tokens) and depth >= level:
                    k += 1
                    if k < len(tokens) and tokens[k] == ("p", "{"):
                        depth += 1
                    elif k < len(tokens) and tokens[k] == ("p", "}"):
                        depth -= 1
                k += 1
                continue
            # #[cfg(test)] on an item: skip further attrs, then the item: a `const`/`static` runs to its
            # `;` (braces and brackets in the type or initializer nest), anything else to `;` or a `{...}` body.
            k += 1
            while k < len(tokens) and tokens[k][0] == "attr":
                k += 1
            lead = []
            for t in tokens[k:k + 8]:
                if t[0] != "id":
                    break
                lead.append(t[1])
            initialised = bool({"const", "static"} & set(lead)) and "fn" not in lead
            nest, seen_eq = 0, False
            while k < len(tokens):
                t = tokens[k]
                if t[0] != "p":
                    k += 1
                    continue
                if t[1] in "([":
                    nest += 1
                elif t[1] in ")]":
                    nest -= 1
                elif t[1] == "{":
                    if nest <= 0 and not (initialised and seen_eq):
                        break
                    nest += 1
                elif t[1] == "}":
                    nest -= 1
                elif t[1] == "=" and nest <= 0:
                    seen_eq = True
                elif t[1] == ";" and nest <= 0:
                    break
                k += 1
            if k < len(tokens) and tokens[k] == ("p", "{"):
                level = 1
                while level and k + 1 < len(tokens):
                    k += 1
                    if tokens[k] == ("p", "{"):
                        level += 1
                    elif tokens[k] == ("p", "}"):
                        level -= 1
            k += 1
            continue
        if tok == ("p", "{"):
            depth += 1
        elif tok == ("p", "}"):
            depth -= 1
        if tok[0] in ("str", "id", "p"):
            out.append(tok)
        k += 1
    return out


_ITEM_PREV = {("p", ";"), ("p", "}"), ("p", "{"), ("p", ")"), ("id", "pub")}
_NOT_ITEM = {"fn", "unsafe", "extern", "async", "impl", "trait"}


def _bindings(tokens: list[tuple]) -> dict[int, str]:
    """token index -> name of the innermost `const`/`static` item whose initializer contains it.

    The initializer runs from the item's first `=` to its `;`, however deeply braces, parens and
    brackets nest inside (`= { "m" }`, `= ["m"]`, `= if c { "a" } else { "m" }` all belong to the item).
    """
    out: dict[int, str] = {}
    for k, tok in enumerate(tokens):
        if tok not in (("id", "const"), ("id", "static")):
            continue
        if k and tokens[k - 1] not in _ITEM_PREV:
            continue  # `<const N: usize>`, `&'static str`: not an item
        j = k + 1
        if j < len(tokens) and tokens[j] == ("id", "mut"):
            j += 1
        if j >= len(tokens) or tokens[j][0] != "id" or tokens[j][1] in _NOT_ITEM:
            continue
        name, nest, j = tokens[j][1], 0, j + 1
        while j < len(tokens):  # find the `=`; a `;` first means no initializer
            t = tokens[j]
            if t[0] == "p":
                if t[1] in "([{":
                    nest += 1
                elif t[1] in ")]}":
                    nest -= 1
                elif nest == 0 and t[1] in ";=":
                    break
            j += 1
        if j >= len(tokens) or tokens[j] != ("p", "="):
            continue
        nest, j = 0, j + 1
        while j < len(tokens):
            t = tokens[j]
            if t[0] == "p":
                if t[1] in "([{":
                    nest += 1
                elif t[1] in ")]}":
                    nest -= 1
                    if nest < 0:
                        break
                elif nest == 0 and t[1] == ";":
                    break
            out[j] = name
            j += 1
    return out


def _defining(tokens: list[tuple], idx: int) -> bool:
    """True when the identifier at `idx` is the name being declared by a `const`/`static` item."""
    j = idx - 1
    if j >= 0 and tokens[j] == ("id", "mut"):
        j -= 1
    return j >= 0 and tokens[j][0] == "id" and tokens[j][1] in ("const", "static")


def _live_tokens_in(path: Path, text: str) -> list[tuple]:
    try:
        return live_tokens(text)
    except CfgError as error:
        raise CfgError(f"{path}: malformed cfg(..) attribute: {error}") from error


def scan_marker(src: Path, marker: str) -> tuple[list[Path], list[Path]]:
    """(live, dead) non-test source files carrying `marker` as an exact, live string literal.

    A literal bound to a named `const`/`static` is only LIVE when that name is referenced from live
    code somewhere in `src`; an unreferenced one is DEAD: it satisfies a grep but nothing can read it,
    so the drill trigger is not actually shipped (infra#1038 R1). The check is by name across the
    crate and cannot prove the referencing code is itself reachable.
    """
    files: dict[Path, list[tuple]] = {}
    for path in sorted(src.rglob("*.rs")):
        rel = path.relative_to(src)
        if not path.is_file() or TEST_DIRS & set(rel.parts[:-1]) or TEST_FILE.match(path.name):
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        if marker in text:
            files[path] = _live_tokens_in(path, text)
    marked = {p: t for p, t in files.items() if ("str", marker) in t}
    bound = {p: _bindings(t) for p, t in marked.items()}
    names = {n for p, t in marked.items() for i, tok in enumerate(t) if tok == ("str", marker)
             if (n := bound[p].get(i))}
    refs = dict.fromkeys(names, 0)
    if names:
        for path in sorted(src.rglob("*.rs")):
            rel = path.relative_to(src)
            if not path.is_file() or TEST_DIRS & set(rel.parts[:-1]) or TEST_FILE.match(path.name):
                continue
            toks = files.get(path) or _live_tokens_in(path, path.read_text(encoding="utf-8", errors="replace"))
            for i, tok in enumerate(toks):
                if tok[0] == "id" and tok[1] in refs and not _defining(toks, i):
                    refs[tok[1]] += 1
    live: list[Path] = []
    dead: list[Path] = []
    for path, toks in marked.items():
        used = False
        for i, tok in enumerate(toks):
            if tok == ("str", marker):
                name = bound[path].get(i)
                used = used or name is None or refs[name] > 0
        (live if used else dead).append(path)
    return live, dead


def marker_in_sources(src: Path, marker: str) -> list[Path]:
    """Non-test source files carrying `marker` as a live, referenced string literal."""
    return scan_marker(src, marker)[0]


def check(core4: Path, checker: Path) -> tuple[int, list[str]]:
    lines: list[str] = []
    try:
        feature, marker = load_checker(checker)
    except (OSError, ValueError, SyntaxError) as error:
        return 1, [f"ERROR: {error}"]
    manifest = core4 / "native-chain/Cargo.toml"
    src = core4 / "native-chain/src"
    if not manifest.is_file() or not src.is_dir():
        return 1, [f"ERROR: {core4} has no native-chain/Cargo.toml or native-chain/src; not a core4 checkout"]
    declared = re.search(
        rf"^{re.escape(feature)}\s*=\s*\[", manifest.read_text(encoding="utf-8"), re.MULTILINE
    ) is not None
    try:
        hits, dead = scan_marker(src, marker)
    except CfgError as error:
        return 1, [f"ERROR: {error}; cannot tell test-only code from live code, so the marker scan fails closed"]
    if declared and hits:
        lines.append(
            f"OK: `{feature}` is declared and its trigger {marker!r} is in "
            f"{', '.join(str(p.relative_to(core4)) for p in hits)}: the binary scan is live"
        )
        return 0, lines
    if not declared and not (hits or dead):
        lines.append(
            f"VACUOUS: this core4 declares no `{feature}` feature and carries no {marker!r}; "
            "the drill half of the binary scan cannot fire at this source (dev-endpoints half still applies)"
        )
        return 0, lines
    if declared and dead:
        lines.append(
            f"ERROR: native-chain/Cargo.toml declares `{feature}` and {', '.join(str(p.relative_to(core4)) for p in dead)} "
            f"defines the trigger {marker!r}, but no live code references that const/static: the trigger is dead, "
            "so the binary scan is blind. Wire it back into the drill path, or bump CHECKER_SHA to the new name."
        )
    elif declared:
        lines.append(
            f"ERROR: native-chain/Cargo.toml declares `{feature}` but no non-test native-chain/src code carries "
            f"the pinned trigger {marker!r} as a string literal: the marker was renamed, so the binary scan is blind. "
            "Bump CHECKER_SHA to a core4 whose checker knows the new name."
        )
    else:
        lines.append(
            f"ERROR: non-test native-chain/src code carries the drill trigger {marker!r} but Cargo.toml declares no "
            f"`{feature}` feature: the feature was renamed and the pinned checker's forbidden list is stale. "
            "Bump CHECKER_SHA."
        )
    return 1, lines


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--core4", type=Path, required=True, help="core4 build-source checkout")
    parser.add_argument("--checker", type=Path, required=True, help="pinned check_release_endpoints.py")
    args = parser.parse_args(argv)
    rc, lines = check(args.core4, args.checker)
    for line in lines:
        print(line, file=sys.stderr if rc else sys.stdout)
    return rc


if __name__ == "__main__":
    sys.exit(main())
