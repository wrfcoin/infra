# Testnet Secrets Rotation Runbook

This runbook rotates the core secrets used by local `testnet` services:

- `POSTGRES_PASSWORD`
- `REDIS_PASSWORD`
- `JWT_SECRET`
- `OAUTH_STATE_SECRET`
- `API_KEY_ENCRYPTION_KEY`
- `RPC_API_KEY`
- `ADMIN_TOKEN`
- `GRAFANA_ADMIN_PASSWORD`
- `PROMETHEUS_ADMIN_PASSWORD`
- `PROMETHEUS_BEARER_TOKEN`
- `WRFCOIN_OPERATOR_TOKEN`
- `WRFCOIN_CONTRIBUTOR_TOKEN`
- `WRFCOIN_ORACLE_TOKEN`
- `WRFCOIN_READER_TOKEN`
- `WRFCOIN_SNAPSHOT_SIGNER_PRIVATE_KEY`
- `WRFCOIN_STORAGE_ENCRYPTION_KEY`

Scope note: optional external integration credentials such as weather provider
API keys, captcha secrets, faucet wallet keys, and per-node HSM PINs are not
rotated by the base sweep below. Rotate those with their owning provider or
hardware-token procedure after the core stack is contained.

HSM PIN rotation is a separate operator action because the value must match the
token state, not only `.env`. If a deploy helper, transcript, shell history, or
operator note exposed `WRFCOIN_HSM_PIN`, rotate the token before launch:

```bash
NEW_WRFCOIN_HSM_PIN="$(openssl rand -hex 16)"
pkcs11-tool --module "${WRFCOIN_HSM_MODULE_PATH:-/usr/lib/softhsm/libsofthsm2.so}" \
  --login --login-type so --so-pin "${WRFCOIN_HSM_SO_PIN:-0000}" \
  --init-pin --new-pin "$NEW_WRFCOIN_HSM_PIN"
sed -i "s|^WRFCOIN_HSM_PIN=.*|WRFCOIN_HSM_PIN=${NEW_WRFCOIN_HSM_PIN}|" .env
unset NEW_WRFCOIN_HSM_PIN
```

For the N5 Pro reference node, run the command inside CT 101 from
`<repo-root>/infra/testnet`, then restart only the services that
consume the HSM environment. Do not paste the old PIN into tickets, PRs, logs,
or terminal transcripts.

Run all commands from `infra/testnet`.

Set a compose command alias once per shell:

```bash
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
else
  COMPOSE_CMD="docker-compose"
fi
```

## 1) Pre-Rotation Checklist

1. Confirm the stack is healthy before rotating:

```bash
${COMPOSE_CMD} -f docker-compose.testnet.yml -f docker-compose.override.yml ps
bash scripts/tdd/credential-smoke.sh
```

2. Snapshot current values and create a local archive:

```bash
TS="$(date -u +%Y%m%dT%H%M%SZ)"
cp .env ".env.pre-rotation.${TS}.archive"
chmod 600 ".env.pre-rotation.${TS}.archive"
```

3. Capture current values in shell variables (for rejection checks later):

```bash
OLD_POSTGRES_PASSWORD="$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)"
OLD_REDIS_PASSWORD="$(grep '^REDIS_PASSWORD=' .env | cut -d= -f2-)"
OLD_JWT_SECRET="$(grep '^JWT_SECRET=' .env | cut -d= -f2-)"
OLD_OAUTH_STATE_SECRET="$(grep '^OAUTH_STATE_SECRET=' .env | cut -d= -f2-)"
OLD_API_KEY_ENCRYPTION_KEY="$(grep '^API_KEY_ENCRYPTION_KEY=' .env | cut -d= -f2-)"
OLD_RPC_API_KEY="$(grep '^RPC_API_KEY=' .env | cut -d= -f2-)"
OLD_ADMIN_TOKEN="$(grep '^ADMIN_TOKEN=' .env | cut -d= -f2-)"
OLD_GRAFANA_ADMIN_PASSWORD="$(grep '^GRAFANA_ADMIN_PASSWORD=' .env | cut -d= -f2-)"
OLD_PROMETHEUS_ADMIN_PASSWORD="$(grep '^PROMETHEUS_ADMIN_PASSWORD=' .env | cut -d= -f2-)"
OLD_WRFCOIN_OPERATOR_TOKEN="$(grep '^WRFCOIN_OPERATOR_TOKEN=' .env | cut -d= -f2-)"
OLD_WRFCOIN_CONTRIBUTOR_TOKEN="$(grep '^WRFCOIN_CONTRIBUTOR_TOKEN=' .env | cut -d= -f2-)"
OLD_WRFCOIN_ORACLE_TOKEN="$(grep '^WRFCOIN_ORACLE_TOKEN=' .env | cut -d= -f2-)"
OLD_WRFCOIN_READER_TOKEN="$(grep '^WRFCOIN_READER_TOKEN=' .env | cut -d= -f2-)"
OLD_WRFCOIN_SNAPSHOT_SIGNER_PRIVATE_KEY="$(grep '^WRFCOIN_SNAPSHOT_SIGNER_PRIVATE_KEY=' .env | cut -d= -f2-)"
OLD_WRFCOIN_STORAGE_ENCRYPTION_KEY="$(grep '^WRFCOIN_STORAGE_ENCRYPTION_KEY=' .env | cut -d= -f2-)"
```

## 2) Generate New Secret Values

```bash
NEW_POSTGRES_PASSWORD="$(openssl rand -hex 16)"
NEW_REDIS_PASSWORD="$(openssl rand -hex 16)"
NEW_JWT_SECRET="$(openssl rand -hex 64)"
NEW_OAUTH_STATE_SECRET="$(openssl rand -hex 64)"
NEW_API_KEY_ENCRYPTION_KEY="$(openssl rand -hex 64)"
NEW_RPC_API_KEY="$(openssl rand -hex 32)"
NEW_ADMIN_TOKEN="$(openssl rand -hex 32)"
NEW_GRAFANA_ADMIN_PASSWORD="$(openssl rand -hex 16)"
NEW_PROMETHEUS_ADMIN_PASSWORD="$(openssl rand -hex 16)"
NEW_PROMETHEUS_BEARER_TOKEN="$(openssl rand -hex 32)"
NEW_WRFCOIN_OPERATOR_TOKEN="$(openssl rand -hex 32)"
NEW_WRFCOIN_CONTRIBUTOR_TOKEN="$(openssl rand -hex 32)"
NEW_WRFCOIN_ORACLE_TOKEN="$(openssl rand -hex 32)"
NEW_WRFCOIN_READER_TOKEN="$(openssl rand -hex 32)"
NEW_WRFCOIN_SNAPSHOT_SIGNER_PRIVATE_KEY="$(openssl rand -hex 32)"
NEW_WRFCOIN_STORAGE_ENCRYPTION_KEY="$(openssl rand -hex 32)"
```

If signed snapshots are already active and the private key format changes in
core4, generate `NEW_WRFCOIN_SNAPSHOT_SIGNER_PRIVATE_KEY` with the current
core4 signer utility instead of raw `openssl` bytes. The value in `.env` must
remain hex-encoded.

## 3) Apply the New Values

1. Rotate the Postgres role password inside the existing database volume before
   restarting dependents. Updating `.env` alone does not change the password
   stored in an initialized `postgres-data` volume.

```bash
${COMPOSE_CMD} -f docker-compose.testnet.yml -f docker-compose.override.yml exec -T postgres \
  sh -lc "PGPASSWORD='${OLD_POSTGRES_PASSWORD}' psql -h 127.0.0.1 -U wrfcoin -d wrfcoin -v ON_ERROR_STOP=1 -c \"ALTER ROLE wrfcoin WITH PASSWORD '${NEW_POSTGRES_PASSWORD}';\""
```

2. Update `.env` in place:

```bash
set_env() {
  local key="$1"
  local value="$2"
  sed -i "s|^${key}=.*|${key}=${value}|" .env
}

set_env POSTGRES_PASSWORD "$NEW_POSTGRES_PASSWORD"
set_env REDIS_PASSWORD "$NEW_REDIS_PASSWORD"
set_env JWT_SECRET "$NEW_JWT_SECRET"
set_env OAUTH_STATE_SECRET "$NEW_OAUTH_STATE_SECRET"
set_env API_KEY_ENCRYPTION_KEY "$NEW_API_KEY_ENCRYPTION_KEY"
set_env RPC_API_KEY "$NEW_RPC_API_KEY"
set_env ADMIN_TOKEN "$NEW_ADMIN_TOKEN"
set_env GRAFANA_ADMIN_PASSWORD "$NEW_GRAFANA_ADMIN_PASSWORD"
set_env PROMETHEUS_ADMIN_PASSWORD "$NEW_PROMETHEUS_ADMIN_PASSWORD"
set_env PROMETHEUS_BEARER_TOKEN "$NEW_PROMETHEUS_BEARER_TOKEN"
set_env WRFCOIN_OPERATOR_TOKEN "$NEW_WRFCOIN_OPERATOR_TOKEN"
set_env WRFCOIN_CONTRIBUTOR_TOKEN "$NEW_WRFCOIN_CONTRIBUTOR_TOKEN"
set_env WRFCOIN_ORACLE_TOKEN "$NEW_WRFCOIN_ORACLE_TOKEN"
set_env WRFCOIN_READER_TOKEN "$NEW_WRFCOIN_READER_TOKEN"
set_env WRFCOIN_SNAPSHOT_SIGNER_PRIVATE_KEY "$NEW_WRFCOIN_SNAPSHOT_SIGNER_PRIVATE_KEY"
set_env WRFCOIN_STORAGE_ENCRYPTION_KEY "$NEW_WRFCOIN_STORAGE_ENCRYPTION_KEY"
```

3. Regenerate the derived Prometheus auth files:

```bash
make_prometheus_container_readable() {
  local file="$1"
  local gid="${PROMETHEUS_CONTAINER_GID:-65534}"

  if chgrp "$gid" "$file" 2>/dev/null; then
    chmod 640 "$file"
  else
    chmod 644 "$file"
    echo "WARNING: could not chgrp ${file} to gid ${gid}; using mode 0644 so prom/prometheus can read the bind mount." >&2
  fi
}

PROM_HASH="$(htpasswd -nbBC 10 "" "$NEW_PROMETHEUS_ADMIN_PASSWORD" | cut -d: -f2)"
cat > prometheus-web.yml <<EOF
basic_auth_users:
  admin: ${PROM_HASH}
EOF
printf '%s' "$NEW_PROMETHEUS_BEARER_TOKEN" > prometheus-bearer-token

make_prometheus_container_readable prometheus-web.yml
make_prometheus_container_readable prometheus-bearer-token
```

If `htpasswd` is unavailable, use `python3 + bcrypt` and follow `setup-env.sh`.

```bash
PROM_HASH="$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'${NEW_PROMETHEUS_ADMIN_PASSWORD}', bcrypt.gensalt(rounds=10)).decode())")"
cat > prometheus-web.yml <<EOF
basic_auth_users:
  admin: ${PROM_HASH}
EOF
make_prometheus_container_readable prometheus-web.yml
printf '%s' "$NEW_PROMETHEUS_BEARER_TOKEN" > prometheus-bearer-token
make_prometheus_container_readable prometheus-bearer-token
```

## 4) Restart Sequence (Dependency-Safe)

```bash
${COMPOSE_CMD} -f docker-compose.testnet.yml -f docker-compose.override.yml up -d postgres redis prometheus grafana
${COMPOSE_CMD} -f docker-compose.testnet.yml -f docker-compose.override.yml exec -T grafana \
  grafana-cli admin reset-admin-password "$NEW_GRAFANA_ADMIN_PASSWORD"
${COMPOSE_CMD} -f docker-compose.testnet.yml -f docker-compose.override.yml up -d wrfcoin-node wrfcoin-backend
${COMPOSE_CMD} -f docker-compose.testnet.yml -f docker-compose.override.yml up -d
```

## 5) Verification (Credential Paths + Old Secret Rejection)

1. Core stack and credential path checks:

```bash
${COMPOSE_CMD} -f docker-compose.testnet.yml -f docker-compose.override.yml ps
bash scripts/tdd/credential-smoke.sh
bash scripts/sustained-test-preflight.sh
```

2. New Postgres password should pass and old Postgres password should fail:

```bash
${COMPOSE_CMD} -f docker-compose.testnet.yml -f docker-compose.override.yml exec -T postgres \
  sh -lc "PGPASSWORD=\"${NEW_POSTGRES_PASSWORD}\" psql -h 127.0.0.1 -U wrfcoin -d wrfcoin -c 'select 1'"
```

```bash
${COMPOSE_CMD} -f docker-compose.testnet.yml -f docker-compose.override.yml exec -T postgres \
  sh -lc "PGPASSWORD=\"${OLD_POSTGRES_PASSWORD}\" psql -h 127.0.0.1 -U wrfcoin -d wrfcoin -c 'select 1'"
```

Expected: authentication failure.

3. New Redis password should pass and old Redis password should fail:

```bash
${COMPOSE_CMD} -f docker-compose.testnet.yml -f docker-compose.override.yml exec -T redis \
  sh -lc "REDISCLI_AUTH=\"${NEW_REDIS_PASSWORD}\" redis-cli --no-auth-warning ping"
```

```bash
${COMPOSE_CMD} -f docker-compose.testnet.yml -f docker-compose.override.yml exec -T redis \
  sh -lc "REDISCLI_AUTH=\"${OLD_REDIS_PASSWORD}\" redis-cli --no-auth-warning ping"
```

Expected: `WRONGPASS` / auth failure.

4. New Grafana/Prometheus admin credentials should pass and old admin
   credentials should fail:

```bash
printf 'Authorization: Basic %s\n' "$(printf 'admin:%s' "${NEW_GRAFANA_ADMIN_PASSWORD}" | base64 | tr -d '\n')" | curl -s -o /dev/null -w "%{http_code}\n" -H @- http://127.0.0.1:3100/api/user
printf 'Authorization: Basic %s\n' "$(printf 'admin:%s' "${NEW_PROMETHEUS_ADMIN_PASSWORD}" | base64 | tr -d '\n')" | curl -s -o /dev/null -w "%{http_code}\n" -H @- http://127.0.0.1:9090/-/ready
```

Expected: `200` for Grafana and `200` or `401` for Prometheus depending on
whether the endpoint is ready before auth is challenged; Prometheus must not
return a file-read or startup failure.

```bash
printf 'Authorization: Basic %s\n' "$(printf 'admin:%s' "${OLD_GRAFANA_ADMIN_PASSWORD}" | base64 | tr -d '\n')" | curl -s -o /dev/null -w "%{http_code}\n" -H @- http://127.0.0.1:3100/api/user
printf 'Authorization: Basic %s\n' "$(printf 'admin:%s' "${OLD_PROMETHEUS_ADMIN_PASSWORD}" | base64 | tr -d '\n')" | curl -s -o /dev/null -w "%{http_code}\n" -H @- http://127.0.0.1:9090/-/ready
```

Expected: `401` for both old credentials.

5. Confirm the restarted node has the new WRFCoin role tokens, snapshot signer,
   and storage encryption key and no old values in its environment:

```bash
${COMPOSE_CMD} -f docker-compose.testnet.yml -f docker-compose.override.yml exec -T wrfcoin-node \
  sh -lc 'tr "\0" "\n" </proc/1/environ | grep -E "^WRFCOIN_.*(_TOKEN|_KEY|PRIVATE_KEY)="'
```

Expected: the output contains the new `WRFCOIN_OPERATOR_TOKEN`,
`WRFCOIN_CONTRIBUTOR_TOKEN`, `WRFCOIN_ORACLE_TOKEN`, and
`WRFCOIN_READER_TOKEN` values, plus the new snapshot/storage key values, and
does not contain any captured old values.

```bash
NODE_TOKEN_ENV="$(${COMPOSE_CMD} -f docker-compose.testnet.yml -f docker-compose.override.yml exec -T wrfcoin-node \
  sh -lc 'tr "\0" "\n" </proc/1/environ | grep -E "^WRFCOIN_.*(_TOKEN|_KEY|PRIVATE_KEY)="')"
printf '%s\n' "$NODE_TOKEN_ENV" | grep -qF "$NEW_WRFCOIN_OPERATOR_TOKEN"
printf '%s\n' "$NODE_TOKEN_ENV" | grep -qF "$NEW_WRFCOIN_CONTRIBUTOR_TOKEN"
printf '%s\n' "$NODE_TOKEN_ENV" | grep -qF "$NEW_WRFCOIN_ORACLE_TOKEN"
printf '%s\n' "$NODE_TOKEN_ENV" | grep -qF "$NEW_WRFCOIN_READER_TOKEN"
printf '%s\n' "$NODE_TOKEN_ENV" | grep -qF "$NEW_WRFCOIN_SNAPSHOT_SIGNER_PRIVATE_KEY"
printf '%s\n' "$NODE_TOKEN_ENV" | grep -qF "$NEW_WRFCOIN_STORAGE_ENCRYPTION_KEY"
for old_value in \
  "$OLD_WRFCOIN_OPERATOR_TOKEN" \
  "$OLD_WRFCOIN_CONTRIBUTOR_TOKEN" \
  "$OLD_WRFCOIN_ORACLE_TOKEN" \
  "$OLD_WRFCOIN_READER_TOKEN" \
  "$OLD_WRFCOIN_SNAPSHOT_SIGNER_PRIVATE_KEY" \
  "$OLD_WRFCOIN_STORAGE_ENCRYPTION_KEY"; do
  if [ -n "$old_value" ] && printf '%s\n' "$NODE_TOKEN_ENV" | grep -qF "$old_value"; then
    echo "ERROR: old WRFCoin secret still present in wrfcoin-node environment" >&2
    exit 1
  fi
done
```

6. Confirm the restarted backend has the new app/API credentials and no old
   values in its environment:

```bash
BACKEND_SECRET_ENV="$(${COMPOSE_CMD} -f docker-compose.testnet.yml -f docker-compose.override.yml exec -T wrfcoin-backend \
  sh -lc 'tr "\0" "\n" </proc/1/environ | grep -E "^(JWT_SECRET|OAUTH_STATE_SECRET|API_KEY_ENCRYPTION_KEY|RPC_API_KEY|ADMIN_TOKEN)="')"
printf '%s\n' "$BACKEND_SECRET_ENV" | grep -qF "$NEW_JWT_SECRET"
printf '%s\n' "$BACKEND_SECRET_ENV" | grep -qF "$NEW_OAUTH_STATE_SECRET"
printf '%s\n' "$BACKEND_SECRET_ENV" | grep -qF "$NEW_API_KEY_ENCRYPTION_KEY"
printf '%s\n' "$BACKEND_SECRET_ENV" | grep -qF "$NEW_RPC_API_KEY"
printf '%s\n' "$BACKEND_SECRET_ENV" | grep -qF "$NEW_ADMIN_TOKEN"
for old_value in \
  "$OLD_JWT_SECRET" \
  "$OLD_OAUTH_STATE_SECRET" \
  "$OLD_API_KEY_ENCRYPTION_KEY" \
  "$OLD_RPC_API_KEY" \
  "$OLD_ADMIN_TOKEN"; do
  if [ -n "$old_value" ] && printf '%s\n' "$BACKEND_SECRET_ENV" | grep -qF "$old_value"; then
    echo "ERROR: old backend app/API secret still present in wrfcoin-backend environment" >&2
    exit 1
  fi
done
```

7. Exercise token-backed local paths where the infra repo has probes:

```bash
bash scripts/sustained-test-preflight.sh
```

Expected: contributor/operator authenticated commit/reveal preflight succeeds
with the new token set. The infra repo does not currently include isolated
offline acceptance/rejection probes for every core4 role token endpoint. Treat
oracle/reader endpoint-level rejection testing as a core4-side validation item;
this infra runbook verifies that the old values are removed from the local
compose environment and that available local token-backed smoke paths work
after restart.

## 6) Archive Hygiene

After the post-rotation checks pass:

1. Remove historical archive files with plaintext credentials:

```bash
rm -f .env.testnet1.archive .env.pre-rotation.*.archive
```

2. Keep `*.archive` ignored in `testnet/.gitignore` to prevent accidental commits.

If policy requires retention, move encrypted archives out of repo checkout.

## 7) Incident Fast Path (Suspected Compromise Mid-Sprint)

1. Rotate immediately using steps 2-4 above.
2. Restart services with `${COMPOSE_CMD} ... up -d` right away.
3. Revoke old credentials by deleting all `.env*.archive` plaintext copies.
4. Run verification in section 5 and capture outputs in the incident log.
5. Backfill post-incident notes after containment.

## 8) Cross-Repo Reference

This runbook is the infra-side companion to the core4 operator-token checklist
tracked in `wrfcoin/core4#1561` and
`core4/docs/operations/security-operations.md`. Issue #480 also requires a
core4-side cross-reference back to this infra runbook; that link must land in
the core4 repository because this infra branch cannot modify `wrfcoin/core4`.
