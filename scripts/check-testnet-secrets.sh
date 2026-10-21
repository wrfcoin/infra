#!/usr/bin/env bash
set -euo pipefail

TESTNET_DIR="configs/testnet"
TESTNET_GITIGNORE="${TESTNET_DIR}/.gitignore"
ALLOWED_TRACKED="${TESTNET_GITIGNORE}"

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

if [[ ! -f "${TESTNET_GITIGNORE}" ]]; then
  fail "Missing required guard file: ${TESTNET_GITIGNORE}"
fi

if ! grep -Eq '^\*$' "${TESTNET_GITIGNORE}"; then
  fail "${TESTNET_GITIGNORE} must contain '*' to ignore generated artifacts."
fi

if ! grep -Eq '^!\.gitignore$' "${TESTNET_GITIGNORE}"; then
  fail "${TESTNET_GITIGNORE} must contain '!.gitignore' to keep the guard file tracked."
fi

tracked_testnet_files="$(git ls-files -- "${TESTNET_DIR}" | grep -v "^${ALLOWED_TRACKED}$" || true)"
if [[ -n "${tracked_testnet_files}" ]]; then
  fail "Tracked files in ${TESTNET_DIR} are not allowed:\n${tracked_testnet_files}"
fi

sensitive_names=(
  "validators.json"
  "test-accounts.json"
  "faucet.json"
  ".env.testnet"
  "genesis.json"
  "network.json"
  "docker-compose.testnet.yml"
)

not_ignored=()
for name in "${sensitive_names[@]}"; do
  candidate="${TESTNET_DIR}/${name}"
  if [[ -e "${candidate}" ]] && ! git check-ignore -q "${candidate}"; then
    not_ignored+=("${candidate}")
  fi
done

if (( ${#not_ignored[@]} > 0 )); then
  fail "Sensitive testnet files exist but are not ignored:\n$(printf '%s\n' "${not_ignored[@]}")"
fi

staged_files="$(git diff --cached --name-only)"
suspicious_hits=()

while IFS= read -r file; do
  [[ -z "${file}" ]] && continue
  [[ -f "${file}" ]] || continue

  if grep -Eq '"privateKey"[[:space:]]*:[[:space:]]*"0x[[:xdigit:]]{64}"' "${file}"; then
    suspicious_hits+=("${file} (hex_private_key)")
  fi
  if grep -Eq '"mnemonic"[[:space:]]*:[[:space:]]*"[a-z]+([[:space:]][a-z]+){11,23}"' "${file}"; then
    suspicious_hits+=("${file} (mnemonic_phrase)")
  fi
  if grep -Eq 'FAUCET_PRIVATE_KEY=0x[[:xdigit:]]{64}' "${file}"; then
    suspicious_hits+=("${file} (faucet_private_key_env)")
  fi
done <<< "${staged_files}"

if (( ${#suspicious_hits[@]} > 0 )); then
  fail "Staged content matches secret patterns:\n$(printf '%s\n' "${suspicious_hits[@]}")"
fi

echo "OK: testnet secret guard checks passed."
