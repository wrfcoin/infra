#!/usr/bin/env bash
# Guard committed env templates and nearby config against accidental secrets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "FAIL: gitleaks is required for env hygiene scanning" >&2
  exit 1
fi

if git -C "${REPO_ROOT}" ls-files | grep -Eq '(^|/)\.env.*\.archive$'; then
  echo "FAIL: archived env files must not be tracked" >&2
  git -C "${REPO_ROOT}" ls-files | grep -E '(^|/)\.env.*\.archive$' >&2
  exit 1
fi

if ! git -C "${REPO_ROOT}" check-ignore --no-index --quiet testnet/.env.testnet1.archive; then
  echo "FAIL: testnet/.env.testnet1.archive is not covered by gitignore" >&2
  exit 1
fi

if git -C "${REPO_ROOT}" grep -n -E '^(.*(PASSWORD|SECRET|TOKEN|KEY).*)=changeme$' -- \
  '.env.example' 'config/*.env.example' 'testnet/.env.testnet.example'; then
  echo "FAIL: secret-bearing env examples must use REPLACE_* placeholders" >&2
  exit 1
fi

gitleaks detect \
  --source "${REPO_ROOT}" \
  --config "${REPO_ROOT}/.gitleaks.toml" \
  --no-git \
  --no-banner \
  --redact \
  --exit-code 1

echo "PASS: env hygiene scan passed"
