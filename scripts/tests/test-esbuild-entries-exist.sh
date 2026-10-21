#!/usr/bin/env bash
# Verify that backend bundle inputs exist and every rendered Node dist command
# has a matching esbuild output. Live mode reads a backend Git object database;
# CI uses a source-SHA-pinned ls-tree fixture.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_SCRIPT="${ESBUILD_SCRIPT:-${ROOT}/infra/docker/esbuild-backend.sh}"
COMPOSE_FILE="${COMPOSE_FILE:-${ROOT}/testnet/docker-compose.testnet.yml}"
FIXTURE="${ESBUILD_ENTRY_FIXTURE:-}"

fail() {
  printf 'ESBUILD_ENTRY_GATE=FAIL %s\n' "$*" >&2
  exit 1
}

extract_entries() {
  awk '
    /^ALL_ENTRIES="/ { inside=1; next }
    inside && /^"$/ { exit }
    inside && NF { print }
  ' "$1"
}

check_gate() (
  local source_script compose_file fixture
  source_script="${ESBUILD_SCRIPT:-${ROOT}/infra/docker/esbuild-backend.sh}"
  compose_file="${COMPOSE_FILE:-${ROOT}/testnet/docker-compose.testnet.yml}"
  fixture="${ESBUILD_ENTRY_FIXTURE:-${FIXTURE:-}}"
  [[ -r "$source_script" ]] || fail "entry script is not readable: ${source_script}"
  [[ -r "$compose_file" ]] || fail "compose file is not readable: ${compose_file}"

  local tmp entries outputs rendered commands backend_ref source output
  local scanned scan_files file service kind path
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' EXIT
  entries="${tmp}/entries.txt"
  outputs="${tmp}/outputs.txt"
  rendered="${tmp}/compose.json"
  commands="${tmp}/compose-outputs.txt"
  extract_entries "$source_script" > "$entries"
  [[ -s "$entries" ]] || fail "ALL_ENTRIES is empty or could not be parsed"

  cut -d: -f2- "$entries" | sort -u > "$outputs"
  [[ "$(wc -l < "$entries")" -eq "$(sort -u "$entries" | wc -l)" ]] || \
    fail "ALL_ENTRIES contains duplicate source/output pairs"

  if [[ -n "$fixture" ]]; then
    [[ -r "$fixture" ]] || fail "fixture is not readable: ${fixture}"
    while IFS=: read -r source output; do
      grep -Fxq "$source" "$fixture" || fail "bundle source absent from fixture: ${source}"
    done < "$entries"
    backend_ref="fixture:$(head -n 1 "$fixture")"
  elif [[ -n "${BACKEND_DIR:-}" ]]; then
    [[ -d "${BACKEND_DIR}/.git" || -f "${BACKEND_DIR}/.git" ]] || \
      fail "BACKEND_DIR is not a Git worktree: ${BACKEND_DIR}"
    backend_ref="${BACKEND_REF:-}"
    if [[ -z "$backend_ref" && -r "${ROOT}/testnet/release-pins.env" ]]; then
      backend_ref="$(sed -n 's/^WRFCOIN_RC_BACKEND_COMMIT=//p' "${ROOT}/testnet/release-pins.env" | tail -n 1)"
    fi
    backend_ref="${backend_ref:-origin/main}"
    while IFS=: read -r source output; do
      git -C "$BACKEND_DIR" cat-file -e "${backend_ref}:${source}" 2>/dev/null || \
        fail "bundle source absent from ${backend_ref}: ${source}"
    done < "$entries"
  else
    printf '%s\n' 'ESBUILD_ENTRY_GATE=VOID provide BACKEND_DIR or --fixture' >&2
    return 2
  fi

  bash "${ROOT}/testnet/tests/render-testnet-compose.sh" \
    --env-file "${ROOT}/testnet/.env.testnet.example" --profile '*' \
    -f "$compose_file" config --format json > "$rendered" || fail "compose render failed: ${compose_file}"
  python3 - "$rendered" > "$commands" <<'PY' || fail "rendered command scan failed (see above)"
import json
import sys

services = json.load(open(sys.argv[1], encoding="utf-8"))["services"]
for name, service in sorted(services.items()):
    command = service.get("command") or []
    if isinstance(command, str):
        command = command.split()
    if len(command) >= 2 and command[0] == "node" and command[1].startswith("dist/") and command[1].endswith(".cjs"):
        print(f"{name}:{command[1]}")
PY
  while IFS=: read -r service output; do
    [[ -n "$output" ]] || continue
    grep -Fxq "$output" "$outputs" || \
      fail "rendered compose service ${service} runs unbundled output: ${output}"
  done < "$commands"

  # Every tracked compose file, not only the testnet one: a dev or legacy
  # stack that runs `node dist/<x>.cjs` or `node backend/<path>` must name a
  # bundle output or a backend source that exists. (The retired wallet stanza
  # in infra/docker/docker-compose.yml ran `node backend/server/wallet_server.js`
  # for months after the file was gone, and this gate could not see it.)
  scanned="${tmp}/scanned.txt"
  scan_files="${tmp}/scan-files.txt"
  if [[ -n "${COMPOSE_SCAN_FILES:-}" ]]; then
    printf '%s\n' $COMPOSE_SCAN_FILES > "$scan_files"
  else
    git -C "$ROOT" ls-files -- '*compose*.yml' '*compose*.yaml' | sed "s#^#${ROOT}/#" > "$scan_files"
  fi
  [[ -s "$scan_files" ]] || fail "no compose files to scan"
  python3 - "$scan_files" "$ROOT" "${ESBUILD_SHELL_EXCEPTIONS-${ROOT}/scripts/tests/fixtures/esbuild-entries/shell-exceptions.json}" > "$scanned" <<'PY' || fail "compose scan failed (see above)"
import json
import os
import re
import shlex
import sys

import yaml


class TagTolerantLoader(yaml.SafeLoader):
    pass


def _untagged(loader, _suffix, node):
    # Compose merge tags (!reset, !override) wrap ordinary nodes.
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node, deep=True)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node, deep=True)
    return loader.construct_scalar(node)


TagTolerantLoader.add_multi_constructor("!", _untagged)

SHELLS = {"sh", "bash", "dash", "ash", "zsh", "busybox"}
# Node options that consume the NEXT argv token (node --help, Node 20/24).
NODE_ARG_FLAGS = {
    "-r", "--require", "--import", "--loader", "--experimental-loader", "-C", "--conditions",
    "--input-type", "--env-file", "--inspect-port", "--title", "--watch-path", "--openssl-config",
    "--icu-data-dir", "--redirect-warnings", "--report-dir", "--report-directory", "--report-filename",
    "--report-signal", "--diagnostic-dir", "--unhandled-rejections", "--dns-result-order",
    "--heapsnapshot-signal", "--cpu-prof-dir", "--cpu-prof-name", "--heap-prof-dir", "--heap-prof-name",
    "--secure-heap", "--secure-heap-min", "--tls-cipher-list", "--max-http-header-size",
    "--disable-warning", "--experimental-config-file",
}
NODE_EVAL_FLAGS = {"-e", "--eval", "-p", "--print"}


class Ambiguous(Exception):
    pass


# A build-hygiene gate for our own, trusted compose files, NOT a security
# boundary. The grammar is deliberately narrow (infra#1155 review, lead
# direction).
#
# Trigger: a plain substring test. Any shell string or exec token that contains
# the characters `node` ANYWHERE (inside quotes, glued to other text) enters
# strict mode; so does one that contains them once quote characters,
# backslashes and line joins are removed (n''ode, no\<newline>de). False
# positives (nodemon, node_modules) are accepted.
#
# Strict mode: the command must be ONE simple command whose argv[0] is exactly
# `node` or an absolute path ending in `/node`, made only of plain words and
# simple quoted literals: no operators, no redirects, no substitutions, no line
# joins, no prefix words (exec, env assignments), no nested shells. Every token
# that decides which file node runs must be a plain word. Anything else fails,
# with no partial analysis, unless the command is on the reviewed exception
# list, matched byte for byte (ESBUILD_SHELL_EXCEPTIONS).
PLAIN_CHARS = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./:=@+-")
PLAIN_WORD = re.compile(r"[A-Za-z0-9_./:=@+-]+")
NODE_PROGRAM = re.compile(r"node|/(?:[A-Za-z0-9_.@+-]+/)*node")


def mentions_node(text):
    """The strict-mode trigger: the substring `node`, raw or with quote
    characters, backslashes and line joins removed."""
    if "node" in text:
        return True
    return "node" in re.sub(r"[\\'\"]", "", re.sub(r"\\\r?\n", "", text))


def is_node_program(token):
    return NODE_PROGRAM.fullmatch(token) is not None


def require_plain(token, what):
    if not PLAIN_WORD.fullmatch(token):
        raise Ambiguous(f"{what} {token!r} is not a plain word (allowlist grammar)")


def basename(token):
    return token.rsplit("/", 1)[-1]


def relevant(token):
    return (token.startswith("dist/") and token.endswith(".cjs")) or token.startswith("backend/")


def node_script(args):
    """The script of `node <args...>`, None for inline code or a bare REPL.
    Every token this examines (options, option arguments, the script) must be
    a plain word."""
    i, unknown_flag = 0, False
    while i < len(args) and args[i].startswith("-") and args[i] != "-":
        flag = args[i]
        require_plain(flag, "node option")
        if flag == "--":
            i += 1
            break
        if flag in NODE_EVAL_FLAGS:
            return None
        if "=" in flag:
            i += 1
        elif flag in NODE_ARG_FLAGS:
            if i + 1 >= len(args):
                raise Ambiguous(f"node option {flag} has no argument")
            require_plain(args[i + 1], f"argument of {flag}")
            i += 2
        else:
            unknown_flag = True
            i += 1
    script = args[i] if i < len(args) else None
    if script is not None:
        require_plain(script, "node script")
    if unknown_flag and (script is None or not relevant(script)) and any(relevant(a) for a in args[i:]):
        raise Ambiguous("an unknown node option may take the next token; cannot tell which token is the script")
    return script


def simple_command_words(script):
    """The words of a shell string that must be ONE simple command: plain
    characters, single-quoted literals, and double-quoted literals with no $,
    backtick or backslash, separated by spaces or tabs. Surrounding whitespace
    (a YAML block's final newline) is ignored. Anything else is Ambiguous."""
    text = script.strip(" \t\r\n")
    words, word, started, i = [], [], False, 0
    while i < len(text):
        c = text[i]
        if c in " \t":
            if started:
                words.append("".join(word))
            word, started = [], False
            i += 1
        elif c == "'":
            close = text.find("'", i + 1)
            if close < 0:
                raise Ambiguous("unterminated single quote")
            word.append(text[i + 1:close])
            started = True
            i = close + 1
        elif c == '"':
            close = text.find('"', i + 1)
            if close < 0:
                raise Ambiguous("unterminated double quote")
            literal = text[i + 1:close]
            if any(ch in literal for ch in "$`\\"):
                raise Ambiguous("a double-quoted word with $, backtick or backslash")
            word.append(literal)
            started = True
            i = close + 1
        elif c in PLAIN_CHARS:
            word.append(c)
            started = True
            i += 1
        else:
            raise Ambiguous(
                f"{c!r} in a shell string that runs node: only one simple command of plain "
                "words and simple quoted literals is analysed"
            )
    if started:
        words.append("".join(word))
    return words


def load_exceptions(path):
    if not path:
        return set()
    try:
        entries = json.load(open(path, encoding="utf-8"))
    except FileNotFoundError:
        return set()
    allowed = set()
    for entry in entries:
        if not all(isinstance(entry.get(k), str) and entry.get(k) for k in ("file", "service", "command", "reason")):
            raise SystemExit(f"invalid shell exception entry (file, service, command, reason): {entry!r}")
        allowed.add((entry["file"], entry["service"], entry["command"]))
    return allowed


EXCEPTIONS = load_exceptions(sys.argv[3] if len(sys.argv) > 3 else "")
CURRENT = {"file": "", "service": ""}


def excepted(command):
    # Reviewed by hand and matched byte for byte: not analysed.
    return (CURRENT["file"], CURRENT["service"], command) in EXCEPTIONS


def node_command(words, what):
    """Strict mode: `words` must be `node ...` (argv[0] exactly node or an
    absolute path ending in /node). Returns the script, None for inline code."""
    if not words:
        raise Ambiguous(f"{what} mentions node but is empty")
    if not is_node_program(words[0]):
        raise Ambiguous(
            f"{what} mentions node but argv[0] is {words[0]!r}, not node or an absolute path ending in /node"
        )
    return node_script(words[1:])


def targets_in_script(script):
    """A shell string (the script of sh -c)."""
    if not mentions_node(script) or excepted(script):
        return []
    script_target = node_command(simple_command_words(script), "a shell string")
    return [script_target] if script_target else []


def targets_in_argv(argv):
    """An exec-form command. Without a token that mentions node it is not
    analysed; with one it must be `node ...` or `<shell> -c '<script>'` whose
    script is the only token that mentions node."""
    if not any(mentions_node(token) for token in argv):
        return []
    if excepted(json.dumps(argv)):
        return []
    if basename(argv[0]) in SHELLS and not mentions_node(argv[0]):
        for k, token in enumerate(argv[1:], start=1):
            if token.startswith("-") and not token.startswith("--") and "c" in token[1:]:
                if k + 1 >= len(argv):
                    raise Ambiguous(f"{argv[0]} {token} has no script")
                for j, other in enumerate(argv):
                    if j != k + 1 and mentions_node(other):
                        raise Ambiguous(f"a token outside the {argv[0]} -c script mentions node: {other!r}")
                return targets_in_script(argv[k + 1])
            require_plain(token, f"{argv[0]} option")
        raise Ambiguous(f"{argv[0]} without -c runs a command that mentions node")
    script = node_command(argv, "an exec command")
    return [script] if script else []


def as_argv(value):
    if value is None:
        return []
    if isinstance(value, str):
        try:
            return shlex.split(value)
        except ValueError as error:
            raise Ambiguous(f"command string does not tokenize: {error}") from None
    if isinstance(value, list):
        return [str(token) for token in value]
    return []


def node_targets(service):
    entrypoint, command = as_argv(service.get("entrypoint")), as_argv(service.get("command"))
    if not entrypoint:
        return sorted(set(targets_in_argv(command)))
    if any(mentions_node(token) for token in entrypoint) or basename(entrypoint[0]) in SHELLS:
        # The entrypoint is the program (or the shell whose -c script the
        # command may supply): the whole argv is one command.
        return sorted(set(targets_in_argv(entrypoint + command)))
    # A wrapper entrypoint that never mentions node (docker-entrypoint.sh)
    # execs its arguments: the command is analysed on its own.
    return sorted(set(targets_in_argv(command)))


files = [line for line in open(sys.argv[1], encoding="utf-8").read().split("\n") if line]
for path in files:
    try:
        document = yaml.load(open(path, encoding="utf-8"), Loader=TagTolerantLoader)
    except Exception as error:  # noqa: BLE001 - name the file, then fail the gate
        print(f"ERROR\t{path}\t-\t{type(error).__name__}: {error}".replace("\n", " "))
        continue
    services = (document or {}).get("services") if isinstance(document, dict) else None
    if not isinstance(services, dict):
        continue
    for name, service in sorted(services.items()):
        if not isinstance(service, dict):
            continue
        CURRENT["file"], CURRENT["service"] = os.path.relpath(path, sys.argv[2]), str(name)
        try:
            targets = node_targets(service)
        except Ambiguous as error:
            print(f"AMBIGUOUS\t{path}\t{name}\t{error}")
            continue
        for target in targets:
            if target.startswith("dist/") and target.endswith(".cjs"):
                print(f"dist\t{path}\t{name}\t{target}")
            elif target.startswith("backend/"):
                print(f"source\t{path}\t{name}\t{target[len('backend/'):]}")
PY
  while IFS=$'\t' read -r kind file service path; do
    case "$kind" in
      ERROR) fail "compose file does not parse: ${file}: ${path}" ;;
      AMBIGUOUS) fail "compose service ${service} in ${file#"${ROOT}"/} runs node ambiguously (failing closed): ${path}" ;;
      dist)
        grep -Fxq "$path" "$outputs" || \
          fail "compose service ${service} in ${file#"${ROOT}"/} runs unbundled output: ${path}"
        ;;
      source)
        if [[ -n "$fixture" ]]; then
          grep -Fxq "$path" "$fixture" || \
            fail "compose service ${service} in ${file#"${ROOT}"/} runs a backend file absent from the fixture: backend/${path}"
        else
          git -C "$BACKEND_DIR" cat-file -e "${backend_ref}:${path}" 2>/dev/null || \
            fail "compose service ${service} in ${file#"${ROOT}"/} runs a backend file absent from ${backend_ref}: backend/${path}"
        fi
        ;;
    esac
  done < "$scanned"

  printf 'ESBUILD_ENTRY_GATE=PASS entries=%s compose_commands=%s compose_files_scanned=%s compose_node_targets=%s source=%s\n' \
    "$(wc -l < "$entries")" "$(wc -l < "$commands")" "$(wc -l < "$scan_files")" \
    "$(grep -c . "$scanned" || true)" "$backend_ref"
)

self_test() (
  local tmp fixture rc
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' EXIT
  fixture="${ROOT}/scripts/tests/fixtures/esbuild-entries/backend-tree.txt"

  echo 'entries_all_present_fixture'
  ESBUILD_ENTRY_FIXTURE="$fixture" check_gate

  echo 'mutation_missing_entry'
  sed '/server\/easy_node_discovery.js:dist\/easy_node_discovery.cjs/a server/does_not_exist.js:dist/x.cjs' \
    "$SOURCE_SCRIPT" > "${tmp}/missing-entry.sh"
  set +e
  ESBUILD_SCRIPT="${tmp}/missing-entry.sh" ESBUILD_ENTRY_FIXTURE="$fixture" check_gate \
    >"${tmp}/missing.out" 2>&1
  rc=$?
  set -e
  [[ $rc -eq 1 ]] || fail "missing-entry mutation returned ${rc}, expected 1"
  grep -Fq 'server/does_not_exist.js' "${tmp}/missing.out" || \
    fail 'missing-entry mutation did not name the absent path'

  echo 'mutation_orphan_compose_command'
  cat > "${tmp}/orphan-compose.yml" <<'YAML'
services:
  orphan:
    image: node:20-alpine
    command: ["node", "dist/wallet_server.cjs"]
YAML
  set +e
  COMPOSE_FILE="${tmp}/orphan-compose.yml" ESBUILD_ENTRY_FIXTURE="$fixture" check_gate \
    >"${tmp}/orphan.out" 2>&1
  rc=$?
  set -e
  [[ $rc -eq 1 ]] || fail "orphan-compose mutation returned ${rc}, expected 1"
  grep -Fq 'dist/wallet_server.cjs' "${tmp}/orphan.out" || \
    fail 'orphan-compose mutation did not name the unbundled output'

  echo 'mutation_dangling_source_in_any_tracked_compose'
  cat > "${tmp}/dev-compose.yml" <<'YAML'
services:
  wallet:
    image: node:20-alpine
    command: ['node', 'backend/server/wallet_server.js']
YAML
  set +e
  COMPOSE_SCAN_FILES="${tmp}/dev-compose.yml" ESBUILD_ENTRY_FIXTURE="$fixture" check_gate \
    >"${tmp}/dev.out" 2>&1
  rc=$?
  set -e
  [[ $rc -eq 1 ]] || fail "dangling-source mutation returned ${rc}, expected 1"
  grep -Fq 'backend/server/wallet_server.js' "${tmp}/dev.out" || \
    fail 'dangling-source mutation did not name the absent backend file'

  echo 'mutation_unbundled_output_in_shell_string'
  cat > "${tmp}/shell-compose.yml" <<'YAML'
services:
  legacy:
    image: node:20-alpine
    entrypoint: ["sh", "-c"]
    command: ["node dist/wallet_server.cjs"]
YAML
  set +e
  COMPOSE_SCAN_FILES="${tmp}/shell-compose.yml" ESBUILD_ENTRY_FIXTURE="$fixture" check_gate \
    >"${tmp}/shell.out" 2>&1
  rc=$?
  set -e
  [[ $rc -eq 1 ]] || fail "shell-string mutation returned ${rc}, expected 1"
  grep -Fq 'dist/wallet_server.cjs' "${tmp}/shell.out" || \
    fail 'shell-string mutation did not name the unbundled output'

  echo 'compose_merge_tags_parse'
  cat > "${tmp}/tagged-compose.yml" <<'YAML'
services:
  governance:
    ports: !reset []
    command: !override ['node', 'dist/governance_server.cjs']
YAML
  COMPOSE_SCAN_FILES="${tmp}/tagged-compose.yml" ESBUILD_ENTRY_FIXTURE="$fixture" check_gate

  echo 'node_invocation_table'
  # core4-style table: expected gate result | compose line | text the
  # failure must contain. REDs name a retired target; each has a valid
  # counterpart naming a real entry. (infra#1155 review: shell delimiters,
  # quotes and Node options used to hide the script.)
  local row expect line want rest n=0 got
  # expect = before the first '|', want = after the last '|' (the compose
  # line itself may contain '|' or '||').
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    expect="${row%%|*}"
    rest="${row#*|}"
    want="${rest##*|}"
    line="${rest%|*}"
    n=$((n + 1))
    printf 'services:\n  case%s:\n    image: node:20-alpine\n    %s\n' "$n" "$line" > "${tmp}/case-${n}.yml"
    set +e
    COMPOSE_SCAN_FILES="${tmp}/case-${n}.yml" ESBUILD_ENTRY_FIXTURE="$fixture" check_gate \
      >"${tmp}/case-${n}.out" 2>&1
    rc=$?
    set -e
    got=PASS
    [[ $rc -eq 0 ]] || got=FAIL
    [[ $rc -eq 0 || $rc -eq 1 ]] || fail "case ${n} returned ${rc}: ${line}"
    [[ "$got" == "$expect" ]] || fail "case ${n} expected ${expect}, got ${got}: ${line}"
    if [[ -n "$want" ]]; then
      grep -Fq -- "$want" "${tmp}/case-${n}.out" || fail "case ${n} did not report '${want}': ${line}"
    fi
  done <<'CASES'
FAIL|command: [sh, -c, 'node dist/wallet_server.cjs']|unbundled output: dist/wallet_server.cjs
FAIL|command: [sh, -c, 'node "dist/wallet_server.cjs"']|unbundled output: dist/wallet_server.cjs
FAIL|command: [node, --enable-source-maps, backend/server/wallet_server.js]|backend/server/wallet_server.js
FAIL|command: [node, --enable-source-maps, dist/wallet_server.cjs]|unbundled output: dist/wallet_server.cjs
FAIL|command: [sh, -c, 'node --enable-source-maps dist/wallet_server.cjs']|unbundled output: dist/wallet_server.cjs
FAIL|command: [sh, -ec, 'exec node dist/wallet_server.cjs']|ambiguously (failing closed)
FAIL|command: [tini, --, node, dist/wallet_server.cjs]|ambiguously (failing closed)
FAIL|command: [node, -r, ./tracing.js, dist/wallet_server.cjs]|unbundled output: dist/wallet_server.cjs
FAIL|command: "node dist/wallet_server.cjs"|unbundled output: dist/wallet_server.cjs
PASS|command: [sh, -c, 'node dist/governance_server.cjs']|
PASS|command: [sh, -c, "node 'dist/governance_server.cjs'"]|
PASS|command: [bash, -lc, 'node "dist/governance_server.cjs"']|
PASS|command: [node, --enable-source-maps, backend/server/governance_server.js]|
PASS|command: [node, --enable-source-maps, dist/governance_server.cjs]|
PASS|command: [sh, -c, 'node --enable-source-maps dist/governance_server.cjs']|
FAIL|command: [sh, -ec, 'exec NODE_ENV=production node dist/governance_server.cjs']|ambiguously (failing closed)
PASS|command: [node, -r, ./tracing.js, dist/governance_server.cjs]|
PASS|command: [node, -e, 'require("x")']|
PASS|command: [node, server.js]|
PASS|command: [sh, -c, 'echo ready; sleep 5']|
FAIL|command: [node, --weird-flag, foo, dist/wallet_server.cjs]|ambiguously (failing closed)
FAIL|command: [node, --require]|ambiguously (failing closed)
FAIL|command: [sh, -c, 'node "dist/governance_server.cjs']|ambiguously (failing closed)
FAIL|command: [sh, -c, 'node dist/governance_server.cjs;']|ambiguously (failing closed)
FAIL|command: [sh, -c, 'cd /app && node dist/governance_server.cjs']|ambiguously (failing closed)
FAIL|command: ['-c', 'while true; do node dist/governance_server.cjs || true; sleep 5; done']|ambiguously (failing closed)
FAIL|command: [sh, -c, "node \\\ndist/governance_server.cjs"]|ambiguously (failing closed)
FAIL|command: [sh, -c, "node dist/governance_server.cjs\nnode dist/governance_server.cjs"]|ambiguously (failing closed)
FAIL|command: [sh, -c, 'node >/dev/null dist/governance_server.cjs']|ambiguously (failing closed)
FAIL|command: [sh, -c, 'node 2>&1 dist/governance_server.cjs']|ambiguously (failing closed)
FAIL|command: [sh, -c, 'node dist/governance_server.cjs <<EOF']|ambiguously (failing closed)
FAIL|command: [bash, -lc, 'node dist/governance_server.cjs > "$(node dist/wallet_server.cjs)"']|ambiguously (failing closed)
FAIL|command: [bash, -lc, 'node dist/governance_server.cjs <`node backend/server/wallet_server.js`']|ambiguously (failing closed)
FAIL|command: [bash, -lc, 'node dist/governance_server.cjs >>"$OUTPUT"']|ambiguously (failing closed)
FAIL|command: [bash, -lc, "node $'dist/wallet_server.cjs'"]|ambiguously (failing closed)
FAIL|command: [bash, -lc, "node $'backend/server/wallet_server.js'"]|ambiguously (failing closed)
FAIL|command: [sh, -c, 'node dist/wallet_server.cj?']|ambiguously (failing closed)
FAIL|command: [sh, -c, 'node dist/{wallet,governance}_server.cjs']|ambiguously (failing closed)
FAIL|command: [sh, -c, 'node "$BUNDLE"']|ambiguously (failing closed)
FAIL|command: [sh, -c, 'node `echo dist/wallet_server.cjs`']|ambiguously (failing closed)
FAIL|command: [sh, -c, 'node ~/dist/wallet_server.cjs']|ambiguously (failing closed)
FAIL|command: [sh, -c, 'sh -c "node dist/governance_server.cjs"']|ambiguously (failing closed)
FAIL|command: [node, '${BUNDLE}']|ambiguously (failing closed)
FAIL|command: [node, "dist/wallet_server.cjs\n"]|ambiguously (failing closed)
FAIL|command: [node, "dist/governance_server.cjs\n"]|ambiguously (failing closed)
FAIL|command: [node, -r, "./tracing.js\n", dist/governance_server.cjs]|ambiguously (failing closed)
FAIL|command: [sh, -c, "node 'dist/wallet_server.cjs\n'"]|ambiguously (failing closed)
FAIL|command: [sh, -c, "'node' dist/wallet_server.cjs"]|unbundled output: dist/wallet_server.cjs
FAIL|command: [sh, -c, '"node" dist/wallet_server.cjs']|unbundled output: dist/wallet_server.cjs
FAIL|command: [sh, -c, "n''ode dist/wallet_server.cjs"]|unbundled output: dist/wallet_server.cjs
PASS|command: [sh, -c, "'node' dist/governance_server.cjs"]|
FAIL|command: [sh, -c, "x=1; 'node' dist/governance_server.cjs"]|ambiguously (failing closed)
FAIL|command: [sh, -c, "exec 'node' dist/governance_server.cjs"]|ambiguously (failing closed)
FAIL|command: [sh, -c, "echo n''ode; true"]|ambiguously (failing closed)
FAIL|command: [sh, -c, '/usr/bin/env node dist/governance_server.cjs']|ambiguously (failing closed)
PASS|command: [sh, -c, '/usr/local/bin/node dist/governance_server.cjs']|
FAIL|command: [sh, -c, '/usr/local/bin/node dist/wallet_server.cjs']|unbundled output: dist/wallet_server.cjs
FAIL|command: [sh, -c, './node dist/governance_server.cjs']|ambiguously (failing closed)
FAIL|command: [sh, -c, 'nodejs dist/governance_server.cjs']|ambiguously (failing closed)
FAIL|command: [sh, -c, 'npx nodemon dist/governance_server.cjs']|ambiguously (failing closed)
FAIL|command: ["'node'", dist/wallet_server.cjs]|ambiguously (failing closed)
FAIL|command: [sh, -c, 'node dist/governance_server.cjs', node]|ambiguously (failing closed)
FAIL|command: [sh, -c, 'n""ode backend/server/wallet_server.js']|backend/server/wallet_server.js
FAIL|command: [sh, -c, "n'o'de dist/wallet_server.cjs"]|unbundled output: dist/wallet_server.cjs
FAIL|command: [sh, -c, "n'o'de dist/governance_server.cjs >/dev/null"]|ambiguously (failing closed)
FAIL|command: [n''ode, dist/governance_server.cjs]|ambiguously (failing closed)
CASES
  [[ $n -eq 66 ]] || fail "node invocation table ran ${n} cases, expected 66"

  echo 'yaml_blocks'
  # A literal or folded block that is one simple command is analysed; a block
  # with more than one line of shell is ambiguous.
  local style target
  # infra#1155 r5: literal-quoted program spellings are node too, in literal
  # and folded blocks alike; each is checked, never skipped.
  local program
  for program in node "n''ode" "n'o'de" 'n""ode'; do
  for style in '|' '>'; do
    for target in dist/wallet_server.cjs dist/governance_server.cjs; do
      printf 'services:\n  block:\n    image: node:20-alpine\n    entrypoint: [bash, -lc]\n    command:\n      - %s\n        %s %s\n' \
        "$style" "$program" "$target" > "${tmp}/block.yml"
      set +e
      COMPOSE_SCAN_FILES="${tmp}/block.yml" ESBUILD_ENTRY_FIXTURE="$fixture" check_gate >"${tmp}/block.out" 2>&1
      rc=$?
      set -e
      if [[ "$target" == dist/wallet_server.cjs ]]; then
        [[ $rc -eq 1 ]] && grep -Fq "unbundled output: ${target}" "${tmp}/block.out" ||
          fail "'${style}' block ${program} ${target} returned ${rc}, expected an unbundled-output failure"
      else
        [[ $rc -eq 0 ]] || fail "'${style}' block ${program} ${target} returned ${rc}, expected 0: $(cat "${tmp}/block.out")"
      fi
    done
  done
  done
  printf 'services:\n  block:\n    image: node:20-alpine\n    entrypoint: [bash, -lc]\n    command:\n      - |\n        cd /app\n        node dist/governance_server.cjs\n' > "${tmp}/block2.yml"
  set +e
  COMPOSE_SCAN_FILES="${tmp}/block2.yml" ESBUILD_ENTRY_FIXTURE="$fixture" check_gate >"${tmp}/block2.out" 2>&1
  rc=$?
  set -e
  [[ $rc -eq 1 ]] && grep -Fq 'ambiguously (failing closed)' "${tmp}/block2.out" ||
    fail "a two-line block returned ${rc}, expected an ambiguity failure"

  echo 'tracked_dev_compose_with_injected_commands'
  # The real tracked dev compose, with one injected service each way.
  local tracked="${ROOT}/infra/docker/docker-compose.yml" inject expected
  for inject in "node dist/wallet_server.cjs|unbundled output: dist/wallet_server.cjs" \
                "node dist/governance_server.cjs|" \
                "node \$'backend/server/wallet_server.js'|ambiguously (failing closed)" \
                "node dist/governance_server.cjs >\"\$(node dist/wallet_server.cjs)\"|ambiguously (failing closed)"; do
    expected="${inject#*|}"
    inject="${inject%%|*}"
    python3 - "$tracked" "${tmp}/tracked.yml" "$inject" <<'INJECT'
import sys
src, out, script = sys.argv[1:4]
text = open(src, encoding="utf-8").read()
quoted = "'" + script.replace("'", "''") + "'"
injected = text.replace("services:\n", "services:\n  injected:\n    image: node:20-alpine\n    command: [bash, -lc, " + quoted + "]\n", 1)
assert injected != text, "no services: line to inject after"
open(out, "w", encoding="utf-8").write(injected)
INJECT
    set +e
    COMPOSE_SCAN_FILES="${tmp}/tracked.yml" ESBUILD_ENTRY_FIXTURE="$fixture" check_gate >"${tmp}/tracked.out" 2>&1
    rc=$?
    set -e
    if [[ -z "$expected" ]]; then
      [[ $rc -eq 0 ]] || fail "tracked compose with '${inject}' returned ${rc}, expected 0: $(cat "${tmp}/tracked.out")"
    else
      [[ $rc -eq 1 ]] && grep -Fq -- "$expected" "${tmp}/tracked.out" ||
        fail "tracked compose with '${inject}' returned ${rc}, expected a failure naming '${expected}'"
    fi
  done

  echo 'shell_exception_list'
  # The reviewed exception list matches file + service + command byte for
  # byte: an exact entry is not analysed, a one-byte difference is ambiguous,
  # and an entry without a reason is refused.
  printf 'services:\n  loop:\n    image: node:20-alpine\n    command: [sh, -c, "while true; do node dist/governance_server.cjs; done"]\n' \
    > "${tmp}/exc.yml"
  local exc_file="${tmp}/exceptions.json" rel
  rel="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "${tmp}/exc.yml" "$ROOT")"
  printf '[{"file": "%s", "service": "loop", "command": "while true; do node dist/governance_server.cjs; done", "reason": "test"}]\n' \
    "$rel" > "$exc_file"
  COMPOSE_SCAN_FILES="${tmp}/exc.yml" ESBUILD_SHELL_EXCEPTIONS="$exc_file" ESBUILD_ENTRY_FIXTURE="$fixture" check_gate
  printf '[{"file": "%s", "service": "loop", "command": "while true; do node dist/governance_server.cjs;  done", "reason": "test"}]\n' \
    "$rel" > "$exc_file"
  set +e
  COMPOSE_SCAN_FILES="${tmp}/exc.yml" ESBUILD_SHELL_EXCEPTIONS="$exc_file" ESBUILD_ENTRY_FIXTURE="$fixture" check_gate \
    >"${tmp}/exc.out" 2>&1
  rc=$?
  set -e
  [[ $rc -eq 1 ]] && grep -Fq 'ambiguously (failing closed)' "${tmp}/exc.out" ||
    fail "a near-miss exception returned ${rc}, expected an ambiguity failure"
  printf '[{"file": "%s", "service": "loop", "command": "x", "reason": ""}]\n' "$rel" > "$exc_file"
  set +e
  COMPOSE_SCAN_FILES="${tmp}/exc.yml" ESBUILD_SHELL_EXCEPTIONS="$exc_file" ESBUILD_ENTRY_FIXTURE="$fixture" check_gate \
    >"${tmp}/exc2.out" 2>&1
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail 'an exception without a reason was accepted'

  echo 'void_without_inputs'
  set +e
  # FIXTURE too: it is initialised from ESBUILD_ENTRY_FIXTURE at startup, so
  # under CI's exported fixture this case was not input-free at all.
  FIXTURE='' ESBUILD_ENTRY_FIXTURE='' BACKEND_DIR='' check_gate >"${tmp}/void.out" 2>&1
  rc=$?
  set -e
  [[ $rc -eq 2 ]] || fail "input-free run returned ${rc}, expected 2"

  echo 'entries_all_present_restored'
  ESBUILD_ENTRY_FIXTURE="$fixture" check_gate

  echo 'ESBUILD_ENTRY_GATE_SELF_TEST=PASS'
)

case "${1:-}" in
  --fixture)
    [[ $# -eq 2 ]] || fail 'usage: --fixture PATH'
    FIXTURE="$2"
    check_gate
    ;;
  --self-test)
    self_test
    ;;
  '')
    check_gate
    ;;
  *)
    fail "unknown argument: $1"
    ;;
esac
