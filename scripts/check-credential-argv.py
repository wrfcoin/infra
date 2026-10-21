#!/usr/bin/env python3
"""infra#1073 ratchet: fail when a credential is expanded into curl/wget argv.

A header passed as `curl -H "Authorization: Bearer $TOKEN"` puts the secret in
the process's argv, where `ps`, /proc/<pid>/cmdline, and sudo/audit logs can
read it. The fix pattern is to feed the header on stdin, since `printf` is a
shell builtin and never execs:

    printf 'Authorization: Bearer %s\\n' "$TOKEN" | curl -H @- URL

or a header file / process substitution (`-H @<(printf ...)`), whose path, not
its contents, is what lands in argv.

THREAT MODEL
------------
The ratchet exists to stop ACCIDENTAL regressions by well-meaning authors:
someone writing or copying an ordinary `curl -H "Authorization: Bearer $T"`
in any of its everyday spellings. It is not a defence against deliberately
obfuscated evasion. Obfuscation-only shapes beyond those listed below are
follow-up issues, not failures of this gate.

WHAT THIS RATCHET GUARANTEES
----------------------------
It is a static, per-file detector for the shapes below. It scans tracked
shell scripts, YAML (compose, workflows), Dockerfiles, and Markdown (operator
examples get copied verbatim).

Each shell LOGICAL line (backslash-newline continuations joined) is split
into shell words, and every word is DEQUOTED the way the shell would do it.
Adjacent '...', "...", $'...' (escapes decoded; like bash, a NUL ends that
$'...' segment) and unquoted/backslash-escaped segments are concatenated into
one word, while expansions ($T, ${X}, $(...), `...`) are kept as literal
placeholder text. Any quoting arrangement of the same word is therefore
classified identically. Nested command text is scanned recursively: $(...)
and `...` bodies, ${...:+...} alternatives, and every COMPLETE dequoted word
that contains whitespace, which covers command strings (sh -c '...' / $'...',
compose CMD-SHELL strings, a double-quoted ssh remote command) however they
are quoted, plus one level of \\" / \\$ escaping.
Diagnostics report the physical line of the flag's word.

A flag is -H/--header or -u/--user, including an attached short-option
argument (-H"...", -u"..."), a flag cluster (-sH "..."), and --opt=value. It
reports:

  header-literal    the dequoted -H argument names a credential header
                    (Authorization, Proxy-Authorization, X-API-Key, API-Key,
                    X-Auth-Token, Private-Token), then a colon, and contains an
                    expansion.
  header-variable   the -H argument is a single expansion of a variable whose
                    name looks like a credential (-H "$auth_header"), OR of a
                    variable/array that THIS FILE assigns a credential-header
                    value with an expansion (the assignment value is dequoted
                    the same way: h='Authorization'": Bearer $T"; -H "$h").
  header-variable-unresolved / header-array-unresolved
                    (infra#1076) the -H argument is a single variable, array
                    or positional expansion whose value this file does not
                    show as literal text: never assigned here (environment,
                    another file), a positional ($1), filled by read /
                    mapfile / readarray / for / printf -v / getopts, or
                    assigned only a pure expansion (h="$1", h="$(f)",
                    h="$OTHER"). Rejected conservatively: a header passed
                    through a variable must be visible in the same file, or
                    go over stdin/a file instead. Array initialisers are
                    collected whole, including name=( ... ) spread over
                    several lines without backslashes (comments allowed).
  user-password     in a curl/wget command, -u/--user user:$PASSWORD or a
                    credential-named variable.

NON-GOALS (known, accepted gaps; a new evasion outside this list is a
follow-up issue, not a failure of the stated scope)
  - eval, `sh -c "$cmd"` built at runtime, and any other dynamically assembled
    command line.
  - Flow sensitivity: a same-file literal assignment anywhere in the file
    resolves the name, even if another path sets it from elsewhere; a -H
    argument mixing literal text with a non-credential header name and an
    expansion (-H "X-Foo: $v") is not a credential header.
  - Credentials hidden by encoding (base64 in the source), by indirection
    (${!name}), or passed as a literal token (no expansion).
  - Tools other than the curl/wget flag spellings above (e.g. httpie, python
    requests); non-shell code (JS/TS fetch headers never reach argv).
  - Commented-out lines, and untracked files.
  - Deliberately obfuscated forms beyond the listed shapes (see THREAT MODEL).

Usage:
  check-credential-argv.py [--root DIR] [PATH ...]   # default: git ls-files
Exit status: 0 clean, 1 findings, 2 usage/IO error.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field

CRED_HEADER = re.compile(
    r"^\s*(?:(?:proxy-)?authorization|x-api-key|api-key|x-auth-token|private-token)\s*:",
    re.IGNORECASE,
)
CRED_VALUE = re.compile(
    r"(?:(?:proxy-)?authorization|x-api-key|api-key|x-auth-token|private-token)\s*:.*[$`]",
    re.IGNORECASE | re.DOTALL,
)
CRED_NAME = re.compile(r"auth|token|bearer|cred|secret|passw|api_?key", re.IGNORECASE)
# A header argument that is exactly one expansion: a named variable or array,
# or a positional/special parameter ($1, ${2}, $@), whose value no file shows.
SINGLE_EXPANSION = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*])(\[[@*]\])?\}?")
ASSIGNMENT = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\+?=(.*)", re.DOTALL)
NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
# Everything that is an expansion; a value that is nothing but expansions
# comes from elsewhere and cannot be inspected here.
EXPANSIONS = re.compile(r"\$\{[^}]*\}|\$\([^)]*\)|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@*#?$!-]|`[^`]*`")
# Builtins that fill a variable with contents this file cannot see, and the
# options of each that consume an argument.
FILLERS = {
    "read": set("dinNptu"),
    "mapfile": set("dnOsuCc"),
    "readarray": set("dnOsuCc"),
}
MAX_INITIALISER_LINES = 200
OPERATORS = set(";&|()<>")
HTTP_CLIENTS = {"curl", "wget"}
MAX_DEPTH = 6

HINTS = {
    "header-array-unresolved": "a header array whose contents this file does not show "
    "(never assigned, or filled by mapfile/read); build the credential header with "
    "printf and pass it as -H @- (stdin) or -H @file",
    "header-variable-unresolved": "a header variable whose value this file does not show "
    "(environment, another file, a positional, read, or a pure expansion); build the "
    "credential header with printf and pass it as -H @- (stdin) or -H @file",
}
FIX = "Feed the header on stdin: printf 'Authorization: Bearer %s\\n' \"$T\" | curl -H @- URL"

SHELL_SUFFIXES = (".sh", ".bash", ".yml", ".yaml", ".md")
SKIP_DIRS = {".git", "node_modules"}

ANSI_C_ESCAPES = {
    "a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n",
    "r": "\r", "t": "\t", "v": "\v", "\\": "\\", "'": "'", '"': '"', "?": "?",
}


# --------------------------------------------------------------------------
# Tokenizer: shell words, dequoted
# --------------------------------------------------------------------------
@dataclass
class Word:
    text: str  # dequoted; expansions kept as literal text
    start: int  # offset of the word's first character in the scanned text


@dataclass
class Tokens:
    items: list = field(default_factory=list)  # Word | str (operator char)
    nested: list = field(default_factory=list)  # (text, offset) to rescan


def _matching(text: str, i: int, open_ch: str, close_ch: str) -> int:
    """Index of the bracket closing text[i] (== open_ch), skipping quotes."""
    depth, j, n = 0, i, len(text)
    while j < n:
        c = text[j]
        if c == "\\":
            j += 2
            continue
        if c == "'" and open_ch != "{":
            k = text.find("'", j + 1)
            j = n if k < 0 else k + 1
            continue
        if c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return n - 1


def _expansion(text: str, i: int, toks: Tokens) -> tuple[str, int]:
    """Read the expansion starting at text[i] == '$'. Returns (literal, next)."""
    n = len(text)
    if i + 1 < n and text[i + 1] in "({":
        open_ch = text[i + 1]
        k = _matching(text, i + 1, open_ch, ")" if open_ch == "(" else "}")
        body, off = text[i + 2 : k], i + 2
        if open_ch == "{":
            # ${name:+words} / ${name:-words} / ...: rescan only the words.
            op = re.match(r"[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?:?[-+=?]", body)
            if op:
                body, off = body[op.end() :], off + op.end()
        toks.nested.append((body, off))
        return text[i : k + 1], k + 1
    m = re.match(r"\$(?:[A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-])", text[i:])
    if m:
        return m.group(0), i + m.end()
    return "$", i + 1


def _codepoint(value: int) -> str:
    """Deterministic policy for a numeric escape: anything that is not a
    Unicode scalar value (above U+10FFFF, e.g. \\U00110000 / \\UFFFFFFFF, or a
    surrogate) becomes U+FFFD and decoding continues, so an odd escape can
    neither abort the scan nor hide the rest of the line."""
    if value > 0x10FFFF or 0xD800 <= value <= 0xDFFF:
        return "�"
    return chr(value)


def _ansi_c(text: str, i: int) -> tuple[str, int]:
    """Decode $'...' starting at text[i] == '$'. Returns (decoded, next).

    Like bash, a decoded NUL (\\0, \\x00, \\u0000, \\c@, ...) ends the value of
    THIS $'...' segment: the rest of it up to the closing quote is dropped,
    while later segments of the same word still concatenate."""
    j, n, out = i + 2, len(text), []
    truncated = False
    while j < n and text[j] != "'":
        c, ch = text[j], None
        step = 1
        if c == "\\" and j + 1 < n:
            e = text[j + 1]
            m = re.match(
                r"x([0-9A-Fa-f]{1,2})|u([0-9A-Fa-f]{1,4})|U([0-9A-Fa-f]{1,8})|([0-7]{1,3})",
                text[j + 1 :],
            )
            if e in ANSI_C_ESCAPES:
                ch, step = ANSI_C_ESCAPES[e], 2
            elif e == "c" and j + 2 < n:
                ch, step = chr(ord(text[j + 2]) & 0x1F), 3
            elif m:
                digits = next(g for g in m.groups() if g)
                ch, step = _codepoint(int(digits, 8 if m.group(4) else 16)), 1 + m.end()
        if ch is None:
            ch = c
        if ch == "\0":
            truncated = True
        if not truncated:
            out.append(ch)
        j += step
    return "".join(out), j + 1


def _backtick(text: str, i: int, toks: Tokens) -> tuple[str, int]:
    k = text.find("`", i + 1)
    k = len(text) if k < 0 else k
    toks.nested.append((text[i + 1 : k], i + 1))
    return text[i : k + 1], k + 1


def tokenize(text: str) -> Tokens:
    """Split text into shell words (dequoted) and operator characters."""
    toks = Tokens()
    cur: list[str] = []
    start = -1
    i, n = 0, len(text)

    def flush():
        nonlocal cur, start
        if start >= 0:
            word = "".join(cur)
            toks.items.append(Word(word, start))
            # A word holding whitespace may be a command string (sh -c,
            # CMD-SHELL, an ssh remote command): rescan the COMPLETE dequoted
            # word, every quote segment and $'...' concatenated.
            if any(ch.isspace() for ch in word):
                toks.nested.append((word, start))
        cur, start = [], -1

    while i < n:
        c = text[i]
        if c in " \t\r\n":
            flush()
            i += 1
            continue
        if c == "#" and start < 0:
            k = text.find("\n", i)  # comment runs to the end of its line
            i = n if k < 0 else k
            continue
        if c in OPERATORS:
            flush()
            toks.items.append(c)
            i += 1
            continue
        if start < 0:
            start = i
        if c == "\\":
            if i + 1 < n:
                cur.append(text[i + 1])
            i += 2
        elif c == "'":
            k = text.find("'", i + 1)
            k = n if k < 0 else k
            cur.append(text[i + 1 : k])
            i = k + 1
        elif c == "$" and i + 1 < n and text[i + 1] == "'":
            seg, i = _ansi_c(text, i)
            cur.append(seg)
        elif c == '"':
            j, seg = i + 1, []
            while j < n and text[j] != '"':
                d = text[j]
                if d == "\\" and j + 1 < n and text[j + 1] in '$`"\\':
                    seg.append(text[j + 1])
                    j += 2
                elif d == "$":
                    lit, j = _expansion(text, j, toks)
                    seg.append(lit)
                elif d == "`":
                    lit, j = _backtick(text, j, toks)
                    seg.append(lit)
                else:
                    seg.append(d)
                    j += 1
            cur.append("".join(seg))
            i = j + 1
        elif c == "$":
            lit, i = _expansion(text, i, toks)
            cur.append(lit)
        elif c == "`":
            lit, i = _backtick(text, i, toks)
            cur.append(lit)
        else:
            cur.append(c)
            i += 1
    flush()
    return toks


def commands(items: list) -> list[list[Word]]:
    """Split a token stream into simple commands at operators."""
    out, cur = [], []
    for it in items:
        if isinstance(it, Word):
            cur.append(it)
        else:
            if cur:
                out.append(cur)
            cur = []
    if cur:
        out.append(cur)
    return out


# --------------------------------------------------------------------------
# Scanning
# --------------------------------------------------------------------------
@dataclass
class Context:
    cred_vars: set = field(default_factory=set)  # assigned a credential header
    inspected: set = field(default_factory=set)  # assigned literal, visible text
    uninspected: set = field(default_factory=set)  # filled from elsewhere


def _nested_variants(text: str) -> list[str]:
    variants = [text]
    un = text.replace('\\"', '"').replace("\\$", "$").replace("\\`", "`")
    if un != text:
        variants.append(un)
    return variants


def walk(text: str, depth: int = 0):
    """Yield (Tokens, base_offset) for text and every nested command text."""
    toks = tokenize(text)
    yield toks, 0
    if depth >= MAX_DEPTH:
        return
    for sub, off in toks.nested:
        if not any(ch.isspace() for ch in sub):
            continue
        for variant in _nested_variants(sub):
            for inner, inner_off in walk(variant, depth + 1):
                yield inner, off + inner_off


def _record_value(ctx: Context, name: str, value: str) -> None:
    if CRED_VALUE.search(value):
        ctx.cred_vars.add(name)
    elif value and not EXPANSIONS.sub("", value).strip():
        ctx.uninspected.add(name)  # e.g. h="$1", h="$(make_header)", h="$OTHER"
    else:
        ctx.inspected.add(name)


def _record_fillers(words: list[Word], ctx: Context) -> None:
    """read/mapfile/readarray/for/printf -v/getopts fill variables with
    contents this file cannot inspect."""
    if not words:
        return
    head = words[0].text
    rest = [w.text for w in words[1:]]
    if head in FILLERS:
        takes_arg, i, names = FILLERS[head], 0, []
        while i < len(rest):
            t = rest[i]
            if t.startswith("-") and len(t) > 1:
                if t[1:] == "a" or t.endswith("a"):  # read -a NAME
                    if i + 1 < len(rest):
                        names.append(rest[i + 1])
                    i += 2
                    continue
                i += 2 if t[-1] in takes_arg and len(t) == 2 else 1
                continue
            names.append(t)
            i += 1
        ctx.uninspected.update(n for n in names if NAME.fullmatch(n))
    elif head == "for" and rest and NAME.fullmatch(rest[0]):
        ctx.uninspected.add(rest[0])
    elif head == "printf" and len(rest) > 1 and rest[0] == "-v":
        ctx.uninspected.add(rest[1])
    elif head == "getopts" and len(rest) > 1:
        ctx.uninspected.add(rest[1])


def collect(text: str, ctx: Context) -> None:
    """Record what this file assigns: credential values, inspectable literal
    values, and values filled from elsewhere. `text` may span several logical
    lines (a whole multiline array initialiser)."""
    for toks, _ in walk(text):
        items = toks.items
        for words in commands(items):
            _record_fillers(words, ctx)
        for idx, it in enumerate(items):
            if not isinstance(it, Word):
                continue
            m = ASSIGNMENT.fullmatch(it.text)
            if not m:
                continue
            name, value = m.group(1), m.group(2)
            if value == "" and idx + 1 < len(items) and items[idx + 1] == "(":
                j, elements = idx + 2, []
                while j < len(items) and items[j] != ")":
                    if isinstance(items[j], Word):
                        elements.append(items[j].text)
                    j += 1
                if any(CRED_VALUE.search(e) for e in elements):
                    ctx.cred_vars.add(name)
                elif any(not EXPANSIONS.sub("", e).strip() for e in elements):
                    ctx.uninspected.add(name)
                else:
                    ctx.inspected.add(name)
            else:
                _record_value(ctx, name, value)


def collection_units(logical: list[str]):
    """Yield the texts to collect from: each logical line, except that an
    array initialiser left open at the end of a line (`name=(` ... `)` over
    several lines, without backslashes) is joined with the following lines
    until its `)` so the whole initialiser is inspected."""
    i = 0
    while i < len(logical):
        text = logical[i]
        items = tokenize(text).items
        opened = any(
            isinstance(it, Word) and ASSIGNMENT.fullmatch(it.text) and it.text.endswith("=")
            and k + 1 < len(items) and items[k + 1] == "("
            for k, it in enumerate(items)
        )
        depth = items.count("(") - items.count(")")
        j = i + 1
        while opened and depth > 0 and j < len(logical) and j - i < MAX_INITIALISER_LINES:
            more = tokenize(logical[j]).items
            depth += more.count("(") - more.count(")")
            text += "\n" + logical[j]
            j += 1
        yield text
        i = j if opened else i + 1


def _flag_arg(words: list[Word], idx: int, long_name: str, short: str):
    """If words[idx] is the flag, return its argument Word, else None."""
    t = words[idx].text
    nxt = words[idx + 1] if idx + 1 < len(words) else None
    if t == f"--{long_name}":
        return nxt
    if t.startswith(f"--{long_name}="):
        return Word(t[len(long_name) + 3 :], words[idx].start)
    if t.startswith("--") or not t.startswith("-"):
        return None
    if re.fullmatch(rf"-[A-Za-z]*{short}", t):
        return nxt
    m = re.fullmatch(rf"-[A-Za-z]*?{short}(.+)", t, re.DOTALL)
    if m:
        return Word(m.group(1), words[idx].start)
    return None


def classify(words: list[Word], ctx: Context):
    """Return (rule, word_start) for the first finding in a simple command."""
    is_http = False
    for idx, w in enumerate(words):
        if os.path.basename(w.text) in HTTP_CLIENTS:
            is_http = True
        arg = _flag_arg(words, idx, "header", "H")
        if arg is not None:
            a = arg.text
            if a.startswith("@"):
                continue
            if CRED_HEADER.match(a) and ("$" in a or "`" in a):
                return "header-literal", w.start
            m = SINGLE_EXPANSION.fullmatch(a)
            if m:
                name, is_array = m.group(1), bool(m.group(2))
                if name in ctx.cred_vars or CRED_NAME.search(name):
                    return "header-variable", w.start
                # Conservative (infra#1076): the value must be visible here.
                if not NAME.fullmatch(name) or name in ctx.uninspected or name not in ctx.inspected:
                    return ("header-array-unresolved" if is_array else "header-variable-unresolved"), w.start
            continue
        if not is_http:
            continue
        arg = _flag_arg(words, idx, "user", "u")
        if arg is not None:
            a = arg.text
            _user, sep, password = a.partition(":")
            if sep and ("$" in password or "`" in password):
                return "user-password", w.start
            m = SINGLE_EXPANSION.fullmatch(a)
            if m and CRED_NAME.search(m.group(1)):
                return "user-password", w.start
    return None


def _end_state(line: str, state: str) -> tuple[str, bool]:
    """Scan one physical line from quote `state` ('', "'", '"', "$'").
    Returns (state at end of line, whether the line ends in an unescaped
    backslash outside a comment)."""
    i, n = 0, len(line)
    word_start = True
    while i < n:
        c = line[i]
        if state == "":
            if c == "\\":
                if i + 1 >= n:
                    return state, True
                i += 2
                word_start = False
                continue
            if c == "#" and word_start:
                return state, False  # comment: a trailing backslash is inert
            if c == "'":
                state = "'"
            elif c == "$" and i + 1 < n and line[i + 1] == "'":
                state, i = "$'", i + 1
            elif c == '"':
                state = '"'
            word_start = c in " \t;&|()<>"
        elif state == "'":
            if c == "'":
                state = ""
        elif state in ('"', "$'"):
            if c == "\\":
                if i + 1 >= n:
                    return state, True
                i += 2
                continue
            if (state == '"' and c == '"') or (state == "$'" and c == "'"):
                state = ""
        i += 1
    return state, state == "'" and line.endswith("\\")


def logical_lines(lines: list[str]):
    """Join physical lines into shell logical lines the way the shell does.

    Unquoted and inside "..." a backslash-newline is REMOVED entirely (no
    space), so `-H "Author\\<nl>ization: ..."`, `--hea\\<nl>der` and a split
    assignment rejoin into the words the shell produces. Inside '...' (and
    $'...') the backslash and newline are literal and the quoted word simply
    continues onto the next line. A backslash ending a comment is inert.

    Yields (text, segments), where segments maps each physical line's start
    offset within text to its 1-based line number (for diagnostics).
    """
    text, segments, state = "", [], ""
    for lineno, raw in enumerate(lines, 1):
        line = raw.rstrip("\n").rstrip("\r")
        segments.append((len(text), lineno))
        state, continued = _end_state(line, state)
        if continued:
            if state in ("'", "$'"):
                text += line + "\n"  # literal inside single quotes
            else:
                text += line[:-1]  # shell removes backslash-newline
            continue
        text += line
        yield text, segments
        text, segments, state = "", [], ""
    if segments:
        yield text, segments


def is_candidate(path: str) -> bool:
    base = os.path.basename(path)
    if base.startswith("Dockerfile") or base.endswith(".dockerfile"):
        return True
    return path.endswith(SHELL_SUFFIXES)


def tracked_files(root: str) -> list[str]:
    try:
        out = subprocess.run(
            ["git", "-C", root, "ls-files", "-z"],
            check=True,
            capture_output=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        print(f"check-credential-argv: cannot list files in {root}: {exc}", file=sys.stderr)
        sys.exit(2)
    return [p for p in out.decode().split("\0") if p]


def scan_file(root: str, rel: str) -> list[tuple[str, int, str, str]]:
    if any(part in SKIP_DIRS for part in rel.split("/")):
        return []
    try:
        with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()
    except OSError:
        return []
    logical = list(logical_lines(lines))
    ctx = Context()
    for unit in collection_units([text for text, _ in logical]):
        collect(unit, ctx)
    findings = []
    for text, segments in logical:
        hit = None
        for toks, base in walk(text):
            for words in commands(toks.items):
                r = classify(words, ctx)
                if r:
                    hit = (r[0], base + r[1])
                    break
            if hit:
                break
        if not hit:
            continue
        rule, start = hit
        # Report the physical line where the flag's word sits.
        lineno = segments[0][1]
        for offset, seg_lineno in segments:
            if offset <= start:
                lineno = seg_lineno
        findings.append((rel, lineno, rule, text.strip()))
    return findings


def main(argv: list[str]) -> int:
    # Diagnostics echo source text (which may hold U+FFFD or other non-ASCII);
    # never let the terminal's encoding turn a finding into a traceback.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="backslashreplace")
        except (AttributeError, ValueError):
            pass
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=".")
    ap.add_argument("paths", nargs="*")
    args = ap.parse_args(argv)
    root = os.path.abspath(args.root)
    paths = args.paths or [p for p in tracked_files(root) if is_candidate(p)]

    findings = []
    for rel in paths:
        findings.extend(scan_file(root, rel))

    for rel, lineno, name, text in findings:
        # Print the shape only up to 160 chars; these are expansions, not values.
        print(f"{rel}:{lineno}: [{name}] {text[:160]}")
    if findings:
        print(
            f"check-credential-argv: {len(findings)} credential-in-argv site(s). {FIX}",
            file=sys.stderr,
        )
        for rule in sorted({name for _, _, name, _ in findings} & HINTS.keys()):
            print(f"check-credential-argv: [{rule}] {HINTS[rule]}", file=sys.stderr)
        return 1
    print(f"check-credential-argv: 0 findings in {len(paths)} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
