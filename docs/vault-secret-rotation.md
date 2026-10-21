# Vault Secret Rotation Runbook

Runbook for rotating WRFCoin secrets stored in HashiCorp Vault. Covers JWT_SECRET,
DATABASE_URL password, ENCRYPTION_KEY, and REDIS_URL password, with pre/post-rotation
verification, rollback, and automation via systemd timer.

---

## Pre-rotation Checklist

Complete all steps before starting rotation:

- [ ] **Back up current secrets**: run `scripts/rotate-secrets.sh --dry-run --secret-type=all`
  to confirm Vault connectivity and log the rotation plan.
- [ ] **Snapshot Vault KV**: `vault kv metadata get -mount=secret -format=json wrfcoin/production/ > /tmp/vault-snapshot-$(date +%Y%m%d).json`
- [ ] **Notify team** of the maintenance window (rotation causes brief service restarts).
- [ ] **Confirm Vault is healthy**:
  ```bash
  vault status          # expect: Initialized: true, Sealed: false
  vault token lookup    # verify token has write access to secret/wrfcoin/production/*
  ```
- [ ] **Confirm testnet stack is running and healthy** before rotation:
  ```bash
  docker compose -f testnet/docker-compose.testnet.yml ps
  curl -sf http://127.0.0.1:8556/health | jq .status   # wrfcoin-node
  curl -sf http://127.0.0.1:4001/health | jq .status   # wrfcoin-backend
  ```
- [ ] **Check for active user sessions** (for JWT rotation, active sessions will be invalidated):
  ```bash
  # Optional: notify users of session reset
  ```
- [ ] **Schedule maintenance window**: JWT and DB rotations restart services. Expect 30–120 s
  of downtime per service.

---

## Per-Secret Rotation Steps

### JWT_SECRET

**Effect**: all active JWT sessions are immediately invalidated. Users must re-login.

1. Run rotation:
   ```bash
   export VAULT_ADDR=https://vault.wrfcoin.io
   export VAULT_TOKEN=<operator-token>
   ./scripts/rotate-secrets.sh --secret-type=jwt
   ```
2. Restart the backend to pick up the new secret:
   ```bash
   docker compose -f testnet/docker-compose.testnet.yml restart wrfcoin-backend
   ```
3. Verify the backend re-started cleanly:
   ```bash
   docker compose -f testnet/docker-compose.testnet.yml logs --tail=30 wrfcoin-backend
   curl -sf http://127.0.0.1:4001/health | jq .
   ```
4. Confirm JWT is working by issuing a test login:
   ```bash
   curl -sf -X POST http://127.0.0.1:4001/api/auth/login \
     -H 'Content-Type: application/json' \
     -d '{"username":"<test-user>","password":"<test-password>"}' | jq .token
   ```

---

### DATABASE_URL Password (PostgreSQL)

**Effect**: existing connections using the old password fail. Docker Compose services reconnect
with the new password on restart.

1. Rotate via Vault's database secrets engine (if configured) or manual path:
   ```bash
   ./scripts/rotate-secrets.sh --secret-type=database
   ```
2. Read the new password from Vault and update PostgreSQL:
   ```bash
   NEW_PASS="$(vault kv get -field=password secret/wrfcoin/production/database/wrfcoin-production)"
   docker compose -f testnet/docker-compose.testnet.yml exec postgres \
     psql -U wrfcoin -c "ALTER USER wrfcoin WITH PASSWORD '${NEW_PASS}';"
   ```
3. Update the `.env` file (or re-inject via Vault agent / environment injection):
   ```bash
   # If using a local .env on the operator node:
   sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${NEW_PASS}/" testnet/.env
   ```
4. Rolling restart — postgres clients first, then postgres itself if needed:
   ```bash
   docker compose -f testnet/docker-compose.testnet.yml restart wrfcoin-backend wrfcoin-node
   sleep 10
   docker compose -f testnet/docker-compose.testnet.yml logs --tail=20 wrfcoin-backend | grep -i "error\|connect"
   ```
5. Verify DB connectivity:
   ```bash
   curl -sf http://127.0.0.1:4001/health | jq .database
   ```

---

### ENCRYPTION_KEY (API_KEY_ENCRYPTION_KEY)

**Effect**: data encrypted with the old key becomes unreadable after rotation. Requires
re-encryption of stored data before rotating the key. **Do not rotate without a re-encryption pass.**

1. Identify what data is encrypted with this key (search backend codebase for `API_KEY_ENCRYPTION_KEY`).
2. Export all encrypted records in plaintext before rotation (using the existing key):
   ```bash
   # Run any backend migration/export script to re-encrypt data with the new key
   # Consult backend/CLAUDE.md for the correct migration path
   ```
3. Rotate the key in Vault:
   ```bash
   ./scripts/rotate-secrets.sh --secret-type=api-keys
   # Note: update ENCRYPTION_KEY separately if it is a distinct Vault path
   vault kv put secret/wrfcoin/production/encryption-key \
     value="$(openssl rand -base64 32)"
   ```
4. Update `.env` and restart backend:
   ```bash
   docker compose -f testnet/docker-compose.testnet.yml restart wrfcoin-backend
   ```
5. Verify no decryption errors in logs:
   ```bash
   docker compose -f testnet/docker-compose.testnet.yml logs --tail=50 wrfcoin-backend | grep -i "decrypt\|encrypt\|error"
   ```

---

### REDIS_URL Password

**Effect**: all Redis connections fail until services are restarted with the new password.

1. Update the Redis password:
   ```bash
   NEW_REDIS_PASS="$(openssl rand -base64 24)"
   # Store in Vault
   vault kv put secret/wrfcoin/production/redis password="${NEW_REDIS_PASS}"
   # Update Redis itself (requires CONFIG REWRITE or redis restart):
   docker compose -f testnet/docker-compose.testnet.yml exec redis \
     redis-cli -a "${OLD_REDIS_PASS}" CONFIG SET requirepass "${NEW_REDIS_PASS}"
   ```
2. Update `.env`:
   ```bash
   sed -i "s/^REDIS_PASSWORD=.*/REDIS_PASSWORD=${NEW_REDIS_PASS}/" testnet/.env
   ```
3. Restart services that use Redis:
   ```bash
   docker compose -f testnet/docker-compose.testnet.yml restart wrfcoin-backend
   ```
4. Verify:
   ```bash
   docker compose -f testnet/docker-compose.testnet.yml exec redis \
     redis-cli -a "${NEW_REDIS_PASS}" ping
   # Expected: PONG
   ```

---

## Post-rotation Verification

Run after ALL secrets are rotated:

```bash
# 1. All services healthy
docker compose -f testnet/docker-compose.testnet.yml ps
# All: Status "Up" and "(healthy)"

# 2. Node API
curl -sf http://127.0.0.1:8556/health | jq .
# Expect: {"status":"ok"} or similar

# 3. Backend API
curl -sf http://127.0.0.1:4001/health | jq .
# Expect: {"status":"ok","database":"connected","redis":"connected"}

# 4. No auth failures in last 5 minutes
docker compose -f testnet/docker-compose.testnet.yml logs --since=5m 2>&1 | \
  grep -iE "auth fail|unauthorized|invalid token|connect ECONNREFUSED" | wc -l
# Expect: 0

# 5. Vault lease TTLs (should all be > 1 hour)
vault kv metadata get -mount=secret -format=json wrfcoin/production/jwt-secret | \
  jq '.data.updated_time'
```

---

## Rollback Procedure

If any service fails health checks after rotation:

1. The `rotate-secrets.sh` script automatically rolls back Vault writes on failure
   (via the `perform_rollback` trap). Check logs:
   ```bash
   ls -lt logs/secret-rotation-*.log | head -3
   tail -50 logs/secret-rotation-<timestamp>.log
   ```

2. If automatic rollback ran but services still fail, manually restore from the pre-rotation
   Vault snapshot:
   ```bash
   # Re-read old values from snapshot
   cat /tmp/vault-snapshot-<date>.json | jq '.data.data'
   # Write them back
   vault kv put secret/wrfcoin/production/jwt-secret value="<old-value>"
   vault kv put secret/wrfcoin/production/database/wrfcoin-production password="<old-value>"
   vault kv put secret/wrfcoin/production/redis password="<old-value>"
   ```

3. Re-inject old values into `.env` and redeploy:
   ```bash
   # Update .env with old values, then:
   docker compose -f testnet/docker-compose.testnet.yml up -d --force-recreate
   ```

4. Verify full stack health before closing the incident.

5. File a post-mortem in `logs/secret-rotation-audit.jsonl` with `"success": false` entry.

---

## Automated Rotation Schedule

Issue #117 tracks adding a systemd timer and post-rotation restart hook. The planned schedule:

| Secret | Frequency | Script flag |
|--------|-----------|-------------|
| JWT_SECRET | Every 7 days | `--secret-type=jwt` |
| Database credentials | Every 14 days | `--secret-type=database` |
| API keys | Every 30 days | `--secret-type=api-keys` |

See `scripts/rotate-secrets.sh` for the current rotation logic. The `--post-rotate-restart`
flag (stub, issue #117) will add rolling service restarts with health-check verification.

The `KeyRotationOverdue` Prometheus alert fires after 30 days without rotation
(`infra/monitoring/alert-rules-enhanced.yml`). The systemd timer prevents this alert from firing.

### Systemd Timer Files (to be deployed on N5 Pro)

```ini
# /etc/systemd/system/wrfcoin-secret-rotation.service
[Unit]
Description=WRFCoin Secret Rotation
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=wrfcoin
WorkingDirectory=/opt/wrfcoin/infra
EnvironmentFile=/etc/wrfcoin/vault.env
ExecStart=/opt/wrfcoin/infra/scripts/rotate-secrets.sh --secret-type=all --post-rotate-restart
StandardOutput=journal
StandardError=journal
```

```ini
# /etc/systemd/system/wrfcoin-secret-rotation.timer
[Unit]
Description=WRFCoin Secret Rotation Timer
Requires=wrfcoin-secret-rotation.service

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=3600

[Install]
WantedBy=timers.target
```

---

## Audit Log

All rotations append to `logs/secret-rotation-audit.jsonl`. Format:

```json
{
  "timestamp": "2026-04-05T12:00:00Z",
  "secret_type": "jwt",
  "dry_run": false,
  "success": true,
  "vault_path": "wrfcoin/production/jwt-secret",
  "restart_status": {
    "wrfcoin-backend": "healthy",
    "wrfcoin-node": "not_restarted"
  },
  "operator": "dan"
}
```

---

## References

- `scripts/rotate-secrets.sh` — rotation script (extend for `--post-rotate-restart` flag)
- `scripts/vault-setup.js` — Vault initialization and AppRole configuration
- `infra/monitoring/alert-rules-enhanced.yml` — `KeyRotationOverdue` alert rule
- `testnet/docker-compose.testnet.yml` — service definitions and health check endpoints
- `backend/CLAUDE.md` — Vault AppRole auth integration details
