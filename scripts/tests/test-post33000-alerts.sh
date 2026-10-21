#!/usr/bin/env bash
# Real Prometheus evaluator; no downloads or live services.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUNDLE="$ROOT/infra/monitoring/post33000"
if [[ -n "${PROMTOOL:-}" ]]; then
  "$PROMTOOL" check rules "$BUNDLE/alerts.yml"
  "$PROMTOOL" test rules "$BUNDLE/alerts.test.yml"
elif command -v promtool >/dev/null 2>&1; then
  promtool check rules "$BUNDLE/alerts.yml"
  promtool test rules "$BUNDLE/alerts.test.yml"
else
  IMAGE=prom/prometheus:v3.1.0
  docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo 'POST33000=UNVERIFIED cached promtool absent'; exit 77; }
  docker run --rm --pull never --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
    --cpus 1 --memory 256m --tmpfs /tmp:rw,noexec,nosuid,size=64m -v "$BUNDLE:/rules:ro" --entrypoint promtool "$IMAGE" check rules /rules/alerts.yml
  docker run --rm --pull never --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
    --cpus 1 --memory 256m --tmpfs /tmp:rw,noexec,nosuid,size=64m -v "$BUNDLE:/rules:ro" --entrypoint promtool "$IMAGE" test rules /rules/alerts.test.yml
fi
printf 'POST33000=PASS real Prometheus rules and boundary scenarios\n'
