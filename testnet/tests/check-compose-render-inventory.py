#!/usr/bin/env python3
"""Fail closed on raw testnet Compose renders outside the canonical helper."""
from __future__ import annotations

import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

try:
    import yaml
except ImportError as error:  # A parser-free fallback would hide malformed YAML.
    raise SystemExit(f"Compose render guard: FAIL (PyYAML required: {error})")

class ComposeYAMLLoader(yaml.SafeLoader):
    """SafeLoader plus exactly Docker Compose's two merge tags. Compose override
    files (`build: !reset null`, `ports: !override [...]`) are valid YAML that
    plain safe_load rejects with ConstructorError; any OTHER tag, and any real
    syntax error, is still reported as malformed."""


def _compose_tag(loader: yaml.SafeLoader, node: yaml.Node):
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    return loader.construct_scalar(node)


for _tag in ("!reset", "!override"):
    ComposeYAMLLoader.add_constructor(_tag, _compose_tag)

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "testnet/tests/render-testnet-compose.sh"
MARKER = re.compile(r"^\s*#\s*(positive-compose-render|compose-render-negative-control|dynamic-payload-reviewed|raw-render-reviewed):\s*([a-z0-9-]+)")
FUNCTION_BLOCK = re.compile(r"(?ms)^\s*(?:function\s+)?(?P<name>[A-Za-z_][A-Za-z0-9_]*)(?:\s*\(\))?\s*\{(?P<body>[\s\S]{0,2000}?)^\s*\}")
INTERPRETERS = {"python", "python3", "perl", "ruby", "node", "nodejs", "php"}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
MAX_ANALYSIS_DEPTH = 8
UNRESOLVED_PAYLOAD = re.compile(r"^\$(\{[^{}]*\}|[A-Za-z_][A-Za-z0-9_]*|[0-9@*])$")  # one whole expansion
SHELLS = {"sh", "bash", "dash", "zsh", "ksh"}
UNRESOLVED_HEREDOC = 'eval "$UNRESOLVED_EXECUTABLE_HEREDOC"'  # classified dynamic -> fail closed
MAX_COMMAND_TOKENS = 256


def sources() -> list[Path]:
    names = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", ".github", "scripts", "testnet/tests"],
        check=True, text=True, stdout=subprocess.PIPE,
    ).stdout.splitlines()
    return [ROOT / name for name in names if Path(name).suffix in {".sh", ".yml", ".yaml"}]


def scalar_strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from scalar_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from scalar_strings(item)


def scan_stack(text: str, on_char=None, comment_spans=None, heredoc_starts=None, continuations=None) -> list[str]:
    """Walk text with the context stack; call on_char(index, char, depth_empty)
    for every character that is NOT consumed as part of an escape. Returns the
    final stack (non-empty means unterminated quoting/substitution).

    A `#` that begins a word outside quotes is a comment (infra#1118): it runs to
    the newline, its characters (quotes included) open nothing and are not passed
    to on_char, and its (start, end) span is appended to comment_spans."""
    stack: list[str] = []
    index = 0
    while index < len(text):
        char = text[index]
        top = stack[-1] if stack else None
        if (char == "#" and top in (None, "P")
                and (index == 0 or text[index - 1] in " \t\n;&|(")):
            end = text.find("\n", index)
            end = len(text) if end == -1 else end
            if comment_spans is not None:
                comment_spans.append((index, end))
            index = end
            continue
        if heredoc_starts is not None and top in (None, "P") and HEREDOC_ANY.match(text, index):
            heredoc_starts.append(index)
        if on_char:
            on_char(index, char, not stack)
        if top == "S":
            if char == "'":
                stack.pop()
        elif top == "D":
            if char == "\\" and index + 1 < len(text):
                if continuations is not None and text[index + 1] == "\n":
                    continuations.append(index)
                if on_char:
                    on_char(index + 1, text[index + 1], False)
                index += 2
                continue
            if char == '"':
                stack.pop()
            elif char == "$" and index + 1 < len(text) and text[index + 1] == "(":
                stack.append("P")
                if on_char:
                    on_char(index + 1, "(", False)
                index += 2
                continue
        else:  # top level or inside a substitution
            if char == "\\" and index + 1 < len(text):
                if continuations is not None and text[index + 1] == "\n":
                    continuations.append(index)
                if on_char:
                    on_char(index + 1, text[index + 1], False)
                index += 2
                continue
            if char == "'":
                stack.append("S")
            elif char == '"':
                stack.append("D")
            elif char in "$<>" and index + 1 < len(text) and text[index + 1] == "(":
                stack.append("P")
                if on_char:
                    on_char(index + 1, "(", False)
                index += 2
                continue
            elif char == ")" and top == "P":
                stack.pop()
        index += 1
    return stack


def matching_close(text: str, start: int):
    """Index of the `)` that closes a substitution whose body starts at `start`,
    honouring quotes and nested substitutions inside it (codex round 62: a
    quoted `)` must not end the body). None when unterminated."""
    stack = ["P"]
    index = start
    while index < len(text):
        char = text[index]
        top = stack[-1]
        if top == "S":
            if char == "'":
                stack.pop()
        elif top == "D":
            if char == "\\" and index + 1 < len(text):
                index += 2
                continue
            if char == '"':
                stack.pop()
            elif char == "$" and index + 1 < len(text) and text[index + 1] == "(":
                stack.append("P")
                index += 2
                continue
        else:
            if char == "\\" and index + 1 < len(text):
                index += 2
                continue
            if char == "'":
                stack.append("S")
            elif char == '"':
                stack.append("D")
            elif char in "$<>" and index + 1 < len(text) and text[index + 1] == "(":
                stack.append("P")
                index += 2
                continue
            elif char == "(":
                stack.append("G")  # a plain group/subshell inside the body
            elif char == ")":
                stack.pop()
                if not stack:
                    return index
        index += 1
    return None


HEREDOC_OP = re.compile(r"(?<!<)<<(?!<)(-?)[ \t]*(?:'([^'\n]*)'|\"([^\"\n]*)\"|\\?([^\s;&|<>()'\"\\]+))")
HEREDOC_ANY = re.compile(r"(?<!<)<<(?!<)")


def shell_continuations(text: str) -> tuple[str, bool]:
    """Remove only lexical backslash-newline pairs; comments/single quotes and
    an escaped backslash do not continue a shell command."""
    escaped = []
    scan_stack(text + "\n", continuations=escaped)
    continued = len(text) - 1 in escaped
    for index in reversed(escaped):
        if index + 1 < len(text):
            text = text[:index] + text[index + 2:]
    return text, continued


def heredoc_layout(text: str):
    """Shared lexical layout for command discovery and marker recognition.

    Collect every redirection across escaped newlines before reading bodies in
    shell order. Operators in quotes/comments are data. Preserve physical line
    numbers; blank bodies and exact terminators in the command text. Unsupported
    delimiters mask the remainder and produce a fail-closed command.
    """
    out, bodies, current = [], [], []
    pending = []  # (delimiter, strip_tabs, quoted, consumer, first_body_line, effective)
    seen = set()
    body = []
    for number, line in enumerate(text.split("\n"), 1):
        if pending:
            delimiter, strip_tabs, quoted, consumer, first, effective = pending[0]
            out.append("")
            if current:
                current.append("")
            candidate = line.lstrip("\t") if strip_tabs else line
            if candidate == delimiter:
                bodies.append((delimiter, quoted, consumer, first, "\n".join(body), effective))
                pending.pop(0)
                body = []
                if pending:
                    d, tabs, q, c, _, e = pending[0]
                    pending[0] = (d, tabs, q, c, number + 1, e)
            else:
                body.append(line)
            continue
        out.append(line)
        current.append(line)
        joined = "\n".join(current)
        # Bash removes backslash-newline before tokenization. Do not read a
        # body while its declaration is still continued or inside a quote.
        logical, continued = shell_continuations(joined)
        operators = []
        stack = scan_stack(logical, heredoc_starts=operators)
        if continued or (stack and stack[-1] in {"S", "D"}):
            continue
        # Only the rightmost stdin heredoc of each simple command feeds its
        # script. Nested substitutions and non-stdin fd forms stay conservative.
        groups = {}
        for start in operators:
            prefix = logical[:start]
            fd = re.search(r"(?:^|[\s;&|])([0-9]+)$", prefix)
            if scan_stack(prefix) or (fd and fd.group(1) != "0"):
                continue
            span = next((span for span in command_segment_ranges(logical)
                         if span[0] <= start < span[1]), None)
            if span is not None:
                groups[start] = span
        last = {span: start for start, span in groups.items()}
        for start in operators:
            if start in seen:
                continue
            match = HEREDOC_OP.match(logical, start)
            follow = logical[match.end():match.end() + 1] if match else ""
            if match is None or (follow and follow not in " \t\n;&|<>)"):
                out.extend([""] * (len(text.split("\n")) - number))
                return "\n".join(out), bodies, number
            delimiter = next(g for g in match.group(2, 3, 4) if g is not None)
            quoted = match.group(2) is not None or match.group(3) is not None or "\\" in match.group(0)
            effective = start not in groups or last[groups[start]] == start
            pending.append((delimiter, match.group(1) == "-", quoted, joined, number + 1, effective))
            seen.add(start)
        if not stack:
            current, seen = [], set()
    return "\n".join(out), bodies, (pending[0][4] if pending else None)


def mask_heredocs(text: str) -> tuple[str, bool]:
    masked, _bodies, unsupported = heredoc_layout(text)
    return masked, unsupported is not None


def shell_comment_lines(text: str) -> set[int]:
    """1-based numbers of the lines whose first non-blank character starts a real
    shell comment in the lexical context (not inside quotes, a substitution or a
    heredoc body/terminator). A `#` line inside a multi-line quoted string or a
    heredoc is data, so a marker there must never be honoured (infra#1140 review)."""
    masked, _unsupported = mask_heredocs(text)
    spans: list[tuple[int, int]] = []
    scan_stack(masked, None, spans)
    lines: set[int] = set()
    for start, _end in spans:
        line_start = masked.rfind("\n", 0, start) + 1
        if masked[line_start:start].strip() == "":
            lines.add(masked.count("\n", 0, start) + 1)
    return lines


def strip_shell_comments(text: str) -> str:
    """text without shell comments (the newline that ends each one is kept)."""
    spans: list[tuple[int, int]] = []
    scan_stack(text, None, spans)
    out, last = [], 0
    for start, end in spans:
        out.append(text[last:start])
        last = end
    out.append(text[last:])
    return "".join(out)


def shell_syntax_open(text: str) -> bool:
    """Keep multi-line quoted strings and command substitutions in one command."""
    return bool(scan_stack(text))


def heredoc_substitutions(body: str):
    """Substitutions that run when an UNQUOTED heredoc body is expanded. Quotes
    are literal text in such a body (`it's` opens nothing); only a backslash
    escapes. Each $() body is extracted quote-aware (a fresh context); an
    unterminated one yields None (fail closed)."""
    index = 0
    while index < len(body):
        char = body[index]
        if char == "\\" and index + 1 < len(body):
            index += 2
            continue
        if char == "$" and index + 1 < len(body) and body[index + 1] == "(":
            end = matching_close(body, index + 2)
            if end is None:
                yield None
                return
            yield body[index + 2:end]
            index = end + 1
            continue
        if char == "`":
            start, index = index + 1, index + 1
            while index < len(body) and body[index] != "`":
                index += 2 if body[index] == "\\" else 1
            if index >= len(body):
                yield None
                return
            yield body[start:index]
        index += 1


def heredoc_consumer_runs_script(command: str, delimiter: str) -> bool | None:
    """True when the command consuming the heredoc executes it as a script
    (a shell reading stdin, `source /dev/stdin`); False for data consumers;
    None when the consumer cannot be identified (caller fails closed)."""
    # A heredoc opened inside a still-unclosed substitution (`x="$(cmd <<'EOF'`)
    # belongs to the command inside that substitution: descend into it.
    operator = command.find("<<")
    if operator != -1:
        prefix = command[:operator]
        for opener in reversed([m.start() for m in re.finditer(r"[$<>]\(", prefix)]):
            if matching_close(prefix, opener + 2) is None:
                return heredoc_consumer_runs_script(command[opener + 2:], delimiter)
    for segment in split_command_segments(command):
        if "<<" not in segment or delimiter not in segment:
            continue
        words = executable_words(shell_words(segment))
        if not words:
            return None
        name = Path(words[0][0]).name
        if name in {"source", "."}:
            return any(word in {"/dev/stdin", "/proc/self/fd/0"} for word, _ in words[1:])
        if name in INTERPRETERS:
            # A python/perl/ruby/node script fed on stdin can shell out to docker
            # (infra#1107); unidentifiable as a Compose render, so fail closed
            # (the caller flags it only when the body mentions docker/compose).
            return None if not any(not w.startswith("-") and w != "-" and not w.startswith("<") for w, _ in words[1:]) else False
        if name not in SHELLS:
            return False
        for word, _ in words[1:]:
            if word.startswith("<<") or word.startswith("<"):
                break
            if word in {"-c", "--command"} or (word.startswith("-") and not word.startswith("--") and "c" in word[1:]):
                return False  # -c: the payload is argv, stdin is data
            if not word.startswith("-"):
                return False  # a script path: stdin is that script's data
        return True
    return None


def _uncommented(joined: str) -> str:
    """One logical command on one line, comments removed; "" for a comment-only one."""
    lines = [line.rstrip() for line in strip_shell_comments(joined).split("\n")]
    return " ".join(line for line in lines if line.strip())


def shell_commands(text: str, offset: int = 0, depth: int = 0):
    """Discover commands from the same heredoc layout used to authenticate markers.
    Shell-fed bodies and unquoted-body substitutions are executable; quoted data
    stays data. Unknown consumers/delimiters and open syntax fail closed.
    """
    masked, bodies, unsupported = heredoc_layout(text)
    current, start = [], 1
    for number, line in enumerate(masked.splitlines(), 1):
        if not current:
            start = number
        current.append(line)
        joined = "\n".join(current)
        logical, continued = shell_continuations(joined)
        if continued or shell_syntax_open(logical):
            continue
        command = _uncommented(logical)
        if command:
            yield offset + start, command
        current = []
    if unsupported is not None:
        yield offset + unsupported, UNRESOLVED_HEREDOC
    if current and any(line.strip() for line in current):
        yield offset + start, UNRESOLVED_HEREDOC
    for delimiter, quoted, consumer, first, body, effective in bodies:
        runs = heredoc_consumer_runs_script(consumer, delimiter) if effective else False
        if runs is None or depth >= MAX_ANALYSIS_DEPTH:
            if any(token in body for token in ("docker", "compose", "$(", "`")):
                yield offset + first - 1, UNRESOLVED_HEREDOC
        elif runs:
            yield from shell_commands(body, offset + first - 1, depth + 1)
        elif not quoted:
            for inner in heredoc_substitutions(body):
                yield offset + first, (UNRESOLVED_HEREDOC if inner is None else inner)


def command_segment_ranges(text: str):
    """Offsets split only at unquoted, top-level command separators."""
    cuts: list[tuple[int, int]] = []  # (start of separator, length)

    def on_char(index: int, char: str, top_level: bool) -> None:
        if top_level and char in ";\n|&":
            length = 2 if char in "|&" and index + 1 < len(text) and text[index + 1] == char else 1
            if not cuts or cuts[-1][0] + cuts[-1][1] <= index:
                cuts.append((index, length))

    scan_stack(text, on_char)
    start = 0
    for index, length in cuts:
        if text[start:index].strip():
            yield start, index
        start = index + length
    if text[start:].strip():
        yield start, len(text)


def split_command_segments(text: str):
    for start, end in command_segment_ranges(text):
        yield text[start:end].strip()


def shell_words(segment: str):
    """Return shell words with quote/substitution provenance, without executing them."""
    words, current, quoted, quote, index = [], [], False, None, 0
    while index < len(segment):
        char = segment[index]
        if quote:
            if char == "\\" and quote == '"' and index + 1 < len(segment):
                current.extend((char, segment[index + 1]))
                index += 2
                continue
            if char == quote:
                quote = None
            else:
                current.append(char)
        elif char in "'\"":
            quoted, quote = True, char
        elif char.isspace():
            if current:
                words.append(("".join(current), quoted))
                current, quoted = [], False
        elif char in "$<>" and index + 1 < len(segment) and segment[index + 1] == "(":
            depth = 1
            current.extend((char, "("))
            index += 2
            while index < len(segment) and depth:
                nested = segment[index]
                current.append(nested)
                if nested == "(":
                    depth += 1
                elif nested == ")":
                    depth -= 1
                index += 1
            continue
        elif char == "`":
            current.append(char)
            index += 1
            while index < len(segment):
                nested = segment[index]
                current.append(nested)
                index += 1
                if nested == "`":
                    break
            continue
        else:
            current.append(char)
        index += 1
    if current:
        words.append(("".join(current), quoted))
    return words


def executable_words(words):
    """Drop shell control/assignment prefixes and return the executed command words."""
    index = 0
    while index < len(words) and (words[index][0] in {"if", "then", "do", "!", "{"} or words[index][0].endswith("()")):
        index += 1  # control words, a group opener, and a one-line `name() {` function header
    while index < len(words) and ASSIGNMENT.match(words[index][0]):
        index += 1
    while index < len(words):
        command = words[index][0]
        if command == "env":
            index += 1
            while index < len(words) and (words[index][0].startswith("-") or ASSIGNMENT.match(words[index][0])):
                index += 1
        elif command == "command":
            index += 1
            while index < len(words) and words[index][0].startswith("-"):
                index += 1
        elif command == "exec" or command == "nohup":
            index += 1
        elif command == "sudo":
            index += 1
            while index < len(words) and words[index][0].startswith("-"):
                option = words[index][0]
                index += 1
                if option in {"-u", "-g", "-h", "-p", "-r", "-t", "-C"} and index < len(words):
                    index += 1
        elif command == "timeout":
            index += 1
            while index < len(words) and words[index][0].startswith("-"):
                option = words[index][0]
                index += 1
                if option in {"-k", "--kill-after", "--signal"} and index < len(words):
                    index += 1
            if index < len(words):
                index += 1
        elif command == "nice":
            index += 1
            while index < len(words) and words[index][0].startswith("-"):
                option = words[index][0]
                index += 1
                if option in {"-n", "--adjustment"} and index < len(words):
                    index += 1
        else:
            break
    return words[index:]


def is_action(word: str) -> bool:
    return word == "config" or word == "--print" or word == "--dry-run"


def substitution_bodies(text: str):
    """Yield executable $()/<()/>() and backtick bodies (not in single quotes).
    Body extraction is quote-aware via matching_close; an unterminated body
    yields None (fail closed)."""
    quote, index = None, 0
    while index < len(text):
        char = text[index]
        if quote == "'":
            if char == "'":
                quote = None
            index += 1
            continue
        if char == "\\" and index + 1 < len(text):
            index += 2
            continue
        if quote == '"' and char == '"':
            quote = None
            index += 1
            continue
        if quote is None and char in "'\"":
            quote = char
            index += 1
            continue
        opener = char == "$" or (quote is None and char in "<>")
        if opener and index + 1 < len(text) and text[index + 1] == "(":
            end = matching_close(text, index + 2)
            if end is None:
                yield None
                return
            yield text[index + 2:end]
            index = end + 1
            continue
        if char == "`":
            start, index = index + 1, index + 1
            while index < len(text) and text[index] != "`":
                if text[index] == "\\" and index + 1 < len(text):
                    index += 2
                else:
                    index += 1
            if index >= len(text):
                yield None
                return
            yield text[start:index]
            index += 1
            continue
        index += 1


def shell_payloads(words):
    """Yield supported shell -c payloads; unsupported payload syntax fails closed."""
    if not words:
        return
    command = Path(words[0][0]).name
    if command not in {"sh", "bash", "dash", "zsh", "ksh"}:
        return
    index = 1
    while index < len(words):
        argument = words[index][0]
        if argument == "-c" or argument == "--command":
            if index + 1 >= len(words) or UNRESOLVED_PAYLOAD.match(words[index + 1][0]):
                yield None  # missing, or a bare variable (`sh -c "$cmd"`): fail closed
            else:
                yield words[index + 1][0]
            return
        if argument.startswith("-"):
            if "c" in argument[1:]:
                if index + 1 >= len(words) or UNRESOLVED_PAYLOAD.match(words[index + 1][0]):
                    yield None
                else:
                    yield words[index + 1][0]
                return
            index += 1
            continue
        # Script-path invocations are not shell payload evaluation. An
        # unrecognized form carrying an apparent Compose program is fail-closed.
        if "docker compose" in " ".join(word for word, _ in words[index:]):
            yield None
        return


def command_classification(segment: str, depth: int = 0) -> tuple[bool, bool]:
    """Return (dynamic-executable, raw-literal-render) for one command segment."""
    if depth >= MAX_ANALYSIS_DEPTH:
        return True, False
    original_words = shell_words(segment)
    if len(original_words) > MAX_COMMAND_TOKENS:
        return True, False
    words = executable_words(original_words)
    recursive_dynamic, recursive_raw = False, False
    for body in substitution_bodies(segment):
        if body is None:
            recursive_dynamic = True
            continue
        for nested in split_command_segments(body):
            dynamic, raw = command_classification(nested, depth + 1)
            recursive_dynamic = recursive_dynamic or dynamic
            recursive_raw = recursive_raw or raw
    if not words:
        return recursive_dynamic, recursive_raw
    for payload in shell_payloads(words):
        if payload is None:
            recursive_dynamic = True
            continue
        for nested in split_command_segments(payload):
            dynamic, raw = command_classification(nested, depth + 1)
            recursive_dynamic = recursive_dynamic or dynamic
            recursive_raw = recursive_raw or raw
    command = words[0][0]
    if command == "alias":
        return recursive_dynamic or any("docker" in word or "compose" in word for word, _ in words[1:]), recursive_raw
    if command == "eval":
        # codex round 62: `cmd='docker compose ... config'; eval "$cmd"`. A
        # payload with any expansion cannot be resolved here: fail closed. A
        # fully literal payload is analysed as the command it is.
        arguments = [word for word, _ in words[1:]]
        if any("$" in word or "`" in word for word in arguments):
            return True, recursive_raw
        if any("docker" in word or "compose" in word for word in arguments):
            payload = " ".join(arguments)
            for nested in split_command_segments(payload):
                dynamic, raw = command_classification(nested, depth + 1)
                recursive_dynamic = recursive_dynamic or dynamic
                recursive_raw = recursive_raw or raw
            return True, recursive_raw
        return recursive_dynamic, recursive_raw
    # infra#1107: wrapper shapes that reach a Compose render without the literal
    # `docker compose` prefix. Each is either classified or fails closed.
    program = Path(command).name
    if program == "docker-compose":  # the v1 binary name: a raw render outside the helper
        if any(is_action(word) for word, _ in words[1:]):
            return recursive_dynamic, True
        return recursive_dynamic, recursive_raw
    if program in {"xargs", "find"} and any("docker" in word or "compose" in word for word, _ in words[1:]):
        return True, recursive_raw  # xargs docker ..., find -exec docker ...: not resolvable here
    if "[@]" in command or "[*]" in command or command in {"$@", "$*"}:
        return True, recursive_raw  # an array/"$@" expansion is the executable: unresolvable
    if len(words) < 2 or words[1][0] != "compose":
        return recursive_dynamic, recursive_raw
    action = any(is_action(word) for word, _ in words[2:])
    if not action:
        return recursive_dynamic, recursive_raw
    executable, quoted = words[0]
    dynamic = quoted or executable.startswith("$") or "$(" in executable or "`" in executable
    return recursive_dynamic or dynamic, recursive_raw or executable == "docker"


def literal_compose_invocation(segment: str) -> bool:
    words = executable_words(shell_words(segment))
    return len(words) >= 2 and words[0][0] == "docker" and words[1][0] == "compose"


def dynamic_compose_invocation(segment: str) -> bool:
    words = executable_words(shell_words(segment))
    if len(words) < 2 or words[1][0] != "compose":
        return False
    executable, quoted = words[0]
    return quoted or executable.startswith("$") or "$(" in executable or "`" in executable


def command_results(text: str, depth: int = 0):
    for segment in split_command_segments(text):
        yield segment, command_classification(segment, depth)


def marker_near(lines: list[str], line: int, comment_lines: set[int] | None = None) -> tuple[str, str] | None:
    for offset, candidate in enumerate(reversed(lines[max(0, line - 8):line])):
        number = line - offset
        match = MARKER.match(candidate)
        if match and (comment_lines is None or number in comment_lines):
            return match.group(1), match.group(2)
    return None


def reviewed_marker_for(lines: list[str], line: int, kind: str = "dynamic-payload-reviewed",
                        comment_lines: set[int] | None = None) -> tuple[str, int] | None:
    """The `# <kind>: <id>` marker (default dynamic-payload-reviewed) BOUND to the command that
    starts on `line` (1-based): walking up from the line above, only blank or
    comment lines may separate the marker from its command (infra#1107). Any
    other line breaks the binding, so a marker can never reach past another
    command. Returns (id, marker line) or None."""
    index = line - 2
    while index >= 0:
        text = lines[index]
        match = MARKER.match(text)
        if match and match.group(1) == kind and (comment_lines is None or index + 1 in comment_lines):
            return match.group(2), index + 1
        if text.strip() == "" or text.lstrip().startswith("#"):
            index -= 1
            continue
        return None
    return None


def main() -> int:
    paths = sources()
    extra = os.environ.get("WRFCOIN_RENDER_DISCOVERY_EXTRA")
    if extra:
        paths.append(Path(extra))
    failures: list[str] = []
    ids: dict[str, list[str]] = defaultdict(list)
    raw_count = 0
    marker_uses: dict[tuple[str, str], list[int]] = defaultdict(list)
    for path in paths:
        text = path.read_text(encoding="utf-8")
        lines = text.splitlines()
        comment_lines = shell_comment_lines(text) if path.suffix not in {".yml", ".yaml"} else None
        for number, line in enumerate(lines, 1):
            match = MARKER.match(line)
            if match and (comment_lines is None or number in comment_lines):
                ids[match.group(2)].append(f"{path}:{number}")
        target = path == HELPER or "docker-compose.testnet.yml" in text
        reviewer_fixture = path == ROOT / "testnet/tests/test_p2p_external_addr_config.sh"
        if path.suffix in {".yml", ".yaml"}:
            try:
                parsed = yaml.load(text, Loader=ComposeYAMLLoader)  # noqa: S506 (SafeLoader subclass)
            except yaml.YAMLError as error:
                failures.append(f"malformed workflow YAML: {path}: {error.__class__.__name__}")
                continue
            if target:
                for value in scalar_strings(parsed):
                    for _, (dynamic, raw) in command_results(value):
                        if path != HELPER and dynamic:
                            failures.append(f"nonliteral Docker executable or dynamic invocation in workflow YAML: {path}")
                        if raw:
                            raw_count += 1
                            failures.append(f"raw testnet Compose render in workflow YAML: {path}")
        elif target:
            for function in FUNCTION_BLOCK.finditer(text):
                body = function.group("body")
                name = function.group("name")
                invoked_as_render = re.search(
                    rf"(?m)^\s*(?:if\s+)?{re.escape(name)}\b[^\n]*(?:\bconfig\b|--print\b|--dry-run\b)", text[function.end():])
                if any(literal_compose_invocation(segment) or dynamic_compose_invocation(segment) for segment in split_command_segments(body)) and invoked_as_render and "compose-render-negative-control" not in body:
                    failures.append(f"raw Compose wrapper outside helper: {path}")
            for number, command in shell_commands(text):
                stripped = command.lstrip()
                if stripped.startswith("#"):
                    continue
                for _, (dynamic, raw) in command_results(command):
                    if not reviewer_fixture and dynamic:
                        # Unresolvable payloads fail closed. The only way past is a
                        # reviewed, id-unique `# dynamic-payload-reviewed: <id>`
                        # marker BOUND to this exact command (only blank/comment
                        # lines between) that clears exactly ONE dynamic
                        # invocation (infra#1107).
                        bound = reviewed_marker_for(lines, number, comment_lines=comment_lines)
                        if bound is None:
                            failures.append(f"nonliteral Docker executable or dynamic invocation outside helper: {path}:{number}")
                        else:
                            marker_uses[(str(path), bound[0])].append(number)
                    if not raw:
                        continue
                    raw_count += 1
                    if path == HELPER:
                        continue
                    marker = marker_near(lines, number, comment_lines)
                    if marker and marker[0] == "compose-render-negative-control":
                        continue
                    # A test whose subject is the UNFORCED render (the helper injects
                    # the documentation P2P addresses, which would hide exactly what
                    # it checks) may carry a reviewed, id-unique, command-bound,
                    # single-use `# raw-render-reviewed: <id>` marker (infra#1118).
                    bound_raw = reviewed_marker_for(lines, number, "raw-render-reviewed", comment_lines)
                    if bound_raw is not None:
                        marker_uses[(str(path), bound_raw[0])].append(number)
                        continue
                    failures.append(f"raw positive testnet Compose render outside helper: {path}:{number}")
    for (marker_path, marker_id), uses in marker_uses.items():
        if len(uses) != 1:
            failures.append(
                f"reviewed marker {marker_id} would clear {len(uses)} invocations "
                f"({marker_path}:{', '.join(map(str, uses))}); one marker reviews exactly one command")
    for marker, locations in ids.items():
        if len(locations) != 1:
            failures.append(f"duplicate classification id {marker}: {', '.join(locations)}")
    if failures:
        print("Compose render guard: FAIL", file=sys.stderr)
        print("\n".join(f"- {item}" for item in failures), file=sys.stderr)
        return 1
    print(f"Compose render guard: PASS ({raw_count} raw render commands; canonical helper only)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
