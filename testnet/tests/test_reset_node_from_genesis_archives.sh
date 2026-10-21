#!/usr/bin/env bash
# Exercise the archive commands on a disposable local directory.  The fake
# Docker boundary still executes the script's /bin/sh payload and real mv/rm
# commands, so the failure injection covers the partial-move recovery window.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/reset-node-from-genesis.sh
source "${SCRIPT_DIR}/../scripts/reset-node-from-genesis.sh"

# Archive-only tests do not exercise advertised-address validation; keep the
# reset script's node-start guard satisfied while testing archive recovery.
require_p2p_guard() {
  :
}

PASS_COUNT=0
FAIL_COUNT=0
DATA_DIR="$(mktemp -d)"
INJECT_SECOND_MOVE_FAILURE=0
INJECT_SECOND_MOVE_SIGNAL=0
trap 'rm -rf "${DATA_DIR}"' EXIT

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS  %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL  %s\n' "$1"
}

assert_file_contents() {
  local name="$1"
  local path="$2"
  local expected="$3"
  if [ -f "${path}" ] && [ "$(<"${path}")" = "${expected}" ]; then
    pass "${name}"
  else
    fail "${name}"
  fi
}

write_live_state() {
  local label="$1"
  printf '%s-wrfcoin\n' "${label}" >"${DATA_DIR}/wrfcoin.redb"
  printf '%s-evidence\n' "${label}" >"${DATA_DIR}/equivocation_evidence.redb"
}

docker() {
  case "$1" in
    run)
      local command="" stamp="" previous=""
      shift
      for arg in "$@"; do
        if [ "${previous}" = "-c" ]; then
          command="${arg}"
        fi
        previous="${arg}"
        stamp="${arg}"
      done
      command="${command//\/app\/data/${DATA_DIR}}"
      if [ "${INJECT_SECOND_MOVE_SIGNAL}" -eq 1 ]; then
        command='mv() { if [ "$1" = "'"${DATA_DIR}"'/equivocation_evidence.redb" ]; then kill -TERM "$$"; fi; command mv "$@"; }; '"${command}"
      elif [ "${INJECT_SECOND_MOVE_FAILURE}" -eq 1 ]; then
        command='mv() { if [ "$1" = "'"${DATA_DIR}"'/equivocation_evidence.redb" ]; then return 75; fi; command mv "$@"; }; '"${command}"
      fi
      /bin/sh -c "${command}" sh "${stamp}"
      ;;
    stop|start)
      return 0
      ;;
    *)
      printf 'unexpected docker invocation: %s\n' "$*" >&2
      return 1
      ;;
  esac
}

wait_for_health() {
  :
}

mkdir -p "${DATA_DIR}/reset-backups"
# shellcheck disable=SC2034 # consumed by the sourced script's docker-run argv
NODE_IMAGE="local-disposable-image"

# Two archive runs get the same original second.  Each reservation uses mkdir
# as its create-exclusive operation, so neither run can overwrite the other.
RESET_STAMP=20260726T120000Z
write_live_state first
first_backup="$(reserve_archive_directory)"
RESET_STAMP="${first_backup}"
if archive_chain_state; then
  pass "first same-second archive succeeds"
else
  fail "first same-second archive succeeds"
fi

write_live_state second
RESET_STAMP=20260726T120000Z
second_backup="$(reserve_archive_directory)"
RESET_STAMP="${second_backup}"
if archive_chain_state; then
  pass "second same-second archive succeeds"
else
  fail "second same-second archive succeeds"
fi
if [ "${first_backup}" != "${second_backup}" ]; then
  pass "same-second runs reserve distinct backup directories"
else
  fail "same-second runs reserve distinct backup directories"
fi
assert_file_contents "first backup survives second archive" \
  "${DATA_DIR}/reset-backups/${first_backup}/wrfcoin.redb" first-wrfcoin
assert_file_contents "second backup retains its database" \
  "${DATA_DIR}/reset-backups/${second_backup}/wrfcoin.redb" second-wrfcoin

# The primary move succeeds; the injected second move fails.  rollback must
# restore the primary database and leave the still-live evidence untouched.
write_live_state partial
RESET_STAMP=20260726T120001Z
RESET_STAMP="$(reserve_archive_directory)"
INJECT_SECOND_MOVE_FAILURE=1
if archive_chain_state; then
  fail "injected second archive move fails"
else
  pass "injected second archive move fails after moving wrfcoin.redb"
fi
if [ ! -e "${DATA_DIR}/wrfcoin.redb" ]; then
  pass "failure injection reached the missing-live-database window"
else
  fail "failure injection reached the missing-live-database window"
fi
INJECT_SECOND_MOVE_FAILURE=0
rollback
assert_file_contents "rollback restores wrfcoin.redb after second-move failure" \
  "${DATA_DIR}/wrfcoin.redb" partial-wrfcoin
assert_file_contents "rollback preserves unarchived evidence after second-move failure" \
  "${DATA_DIR}/equivocation_evidence.redb" partial-evidence

# A killed archive container has the same partial state: wrfcoin.redb has
# already moved, but the second move never occurs.  The outer reset process
# receives the failed docker command and restores the registered archive.
write_live_state killed
RESET_STAMP=20260726T120001Z
RESET_STAMP="$(reserve_archive_directory)"
INJECT_SECOND_MOVE_SIGNAL=1
if archive_chain_state; then
  fail "signal-killed second archive move fails"
else
  pass "signal-killed second archive move fails after moving wrfcoin.redb"
fi
if [ ! -e "${DATA_DIR}/wrfcoin.redb" ]; then
  pass "signal injection reached the partial archive window"
else
  fail "signal injection reached the partial archive window"
fi
INJECT_SECOND_MOVE_SIGNAL=0
rollback
assert_file_contents "rollback restores wrfcoin.redb after signal-killed archive" \
  "${DATA_DIR}/wrfcoin.redb" killed-wrfcoin
assert_file_contents "rollback preserves evidence after signal-killed archive" \
  "${DATA_DIR}/equivocation_evidence.redb" killed-evidence

# An empty state has no primary database to archive and fails closed.
rm -f "${DATA_DIR}/wrfcoin.redb" "${DATA_DIR}/equivocation_evidence.redb"
RESET_STAMP=20260726T120002Z
# shellcheck disable=SC2034 # read by the sourced script's archive_chain_state
RESET_STAMP="$(reserve_archive_directory)"
if archive_chain_state; then
  fail "empty database fails closed"
else
  pass "empty database fails closed"
fi

if [ "${FAIL_COUNT}" -gt 0 ]; then
  printf '\nFailed %d of %d assertions\n' "${FAIL_COUNT}" "$((PASS_COUNT + FAIL_COUNT))"
  exit 1
fi
printf '\nPassed %d assertions\n' "${PASS_COUNT}"
