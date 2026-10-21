#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR

require_text() {
  local file="$1"
  local text="$2"
  if ! grep -Fq -- "$text" "$ROOT_DIR/$file"; then
    printf 'missing policy: %s: %s\n' "$file" "$text" >&2
    exit 1
  fi
}

reject_text() {
  local file="$1"
  local text="$2"
  if grep -Fq -- "$text" "$ROOT_DIR/$file"; then
    printf 'forbidden policy: %s: %s\n' "$file" "$text" >&2
    exit 1
  fi
}

require_file() {
  local file="$1"
  if [[ ! -f "$ROOT_DIR/$file" ]]; then
    printf 'missing policy file: %s\n' "$file" >&2
    exit 1
  fi
}

for dockerfile in Dockerfile.contract-metrics Dockerfile.dependency-monitor; do
  require_text "$dockerfile" 'COPY package.json package-lock.json ./'
  require_text "$dockerfile" 'RUN npm ci --omit=dev'
  reject_text "$dockerfile" 'RUN npm install'
done

# Keep the source manifest in Dependabot's supported .txt form. It is not
# copied into the image; production installation remains lock-only below.
require_file requirements-webhook.txt
require_text Dockerfile.webhook-handler 'COPY requirements-webhook.lock .'
require_text Dockerfile.webhook-handler 'pip install --no-cache-dir --require-hashes -r requirements-webhook.lock'
reject_text Dockerfile.webhook-handler 'pip install --no-cache-dir -r requirements-webhook.txt'
reject_text Dockerfile.webhook-handler 'requirements-webhook.txt'

require_text Dockerfile.gfs-fetch-healthcheck 'addgroup -g 1001 -S gfshealth'
require_text Dockerfile.gfs-fetch-healthcheck 'adduser -S -D -u 1001 -G gfshealth gfshealth'
require_text Dockerfile.gfs-fetch-healthcheck 'chmod -R a-w /app/testdata'
require_text Dockerfile.gfs-fetch-healthcheck 'chown -R gfshealth:gfshealth /app /var/lib/node_exporter/textfile_collector /var/lib/gfs-fetch-health'
require_text Dockerfile.gfs-fetch-healthcheck 'USER gfshealth'
require_text Dockerfile.gfs-fetch-healthcheck 'HEALTHCHECK'
require_text Dockerfile.gfs-fetch-healthcheck 'last_success_unixtime'
require_text Dockerfile.gfs-fetch-healthcheck "gfs_fetch_health_up 1"

require_text docker-compose.gfs-fetcher-health.yml 'user: "1001:1001"'
require_text docker-compose.alerting.yml 'user: "1001:1001"'

require_gfs_volume_init() {
  local compose_file="$1"
  require_text "$compose_file" 'gfs-fetch-health-init:'
  require_text "$compose_file" 'user: "0:0"'
  require_text "$compose_file" 'chown -R 1001:1001 /var/lib/node_exporter/textfile_collector /var/lib/gfs-fetch-health'
  require_text "$compose_file" 'test -w /var/lib/node_exporter/textfile_collector'
  require_text "$compose_file" 'test -w /var/lib/gfs-fetch-health'
  require_text "$compose_file" 'condition: service_completed_successfully'
  require_text "$compose_file" 'restart: "no"'
}

require_gfs_volume_init docker-compose.gfs-fetcher-health.yml
require_gfs_volume_init docker-compose.alerting.yml

printf 'monitoring image policy: PASS\n'
