# WRFCoin Testnet — Restore Drill Checklist

Use this checklist to restore from a backup created by `backup.sh`.
Run a restore drill periodically to verify backups are usable.

For PostgreSQL point-in-time recovery from WAL archives, use
[`POSTGRES_PITR_RUNBOOK.md`](POSTGRES_PITR_RUNBOOK.md) and `scripts/pg-restore-pitr.sh`.

---

## Prerequisites

- A backup directory from `backup.sh` (e.g., `/mnt/tank/backups/testnet/20260323_030000/`)
- Docker and Docker Compose installed
- Access to the testnet compose stack

Set the backup path:

```bash
BACKUP=/mnt/tank/backups/testnet/<TIMESTAMP>
ls -lh "$BACKUP/"
```

---

## Restore Procedure

### Step 1: Stop all services

```bash
cd ~/wrfcoin/infra/testnet
docker compose down
```

- [ ] All containers stopped (verify with `docker compose ps`)

### Step 2: Restore PostgreSQL

```bash
# Start only postgres
docker compose up -d postgres
sleep 10

# Drop and recreate the database
docker compose exec -T postgres psql -U wrfcoin -d postgres \
  -c "DROP DATABASE IF EXISTS wrfcoin;"
docker compose exec -T postgres psql -U wrfcoin -d postgres \
  -c "CREATE DATABASE wrfcoin OWNER wrfcoin;"

# Restore from dump
cat "$BACKUP/postgres.sql" | docker compose exec -T postgres psql -U wrfcoin wrfcoin
# Alternative: the custom-format dump (backups made after 2026-09-27). Its
# contents are listed in $BACKUP/postgres.dump.list, and it allows a selective
# restore (pg_restore -L / -t):
#   docker compose exec -T postgres pg_restore --list < "$BACKUP/postgres.dump" | head
#   docker compose exec -T postgres pg_restore -U wrfcoin -d wrfcoin --no-owner < "$BACKUP/postgres.dump"

# Verify
docker compose exec -T postgres psql -U wrfcoin wrfcoin \
  -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'public';"
```

- [ ] Database restored without errors
- [ ] Table count matches expectations

### Step 3: Restore blockchain data

**Option A — ZFS rollback (reference node):**

```bash
# Check which snapshot to restore
cat "$BACKUP/zfs-snapshot.txt"
# Output: tank/blockchain@backup-20260323_030000

# Stop postgres (already up from Step 2 — leave it)
# Roll back the blockchain dataset on the Proxmox host:
ssh <node-host> zfs rollback tank/blockchain@backup-20260323_030000
```

**Option B — Docker volume restore (generic operator):**

```bash
# Get the volume name
VOLUME=$(docker compose config --format json | python3 -c \
  "import sys,json; c=json.load(sys.stdin); print(c['services']['wrfcoin-node']['volumes'][0].split(':')[0])")

# Clear existing data and restore
docker run --rm \
  -v "${VOLUME}:/data" \
  -v "$BACKUP:/backup:ro" \
  alpine sh -c "rm -rf /data/* && tar xzf /backup/blockchain-data.tar.gz -C /data"
```

- [ ] Blockchain data restored

### Step 4: Restore Redis

```bash
# Stop redis if running
docker compose stop redis 2>/dev/null || true

# Copy RDB file into the Redis data volume
docker compose cp "$BACKUP/redis.rdb" redis:/data/dump.rdb

# Start redis (it will load the RDB on startup)
docker compose up -d redis
sleep 5
```

- [ ] Redis restored and healthy (`docker compose ps redis`)

### Step 5: Restore configuration (if needed)

Only needed if `.env` was lost or corrupted:

```bash
cp "$BACKUP/env.bak" ~/wrfcoin/infra/testnet/.env
chmod 600 ~/wrfcoin/infra/testnet/.env
```

- [ ] Configuration restored (or skipped — still intact)

### Step 6: Start all services

```bash
cd ~/wrfcoin/infra/testnet

# Start in dependency order
docker compose up -d postgres redis
docker compose up -d wrfcoin-node

# Wait for node health
echo "Waiting for node..."
until curl -sf http://localhost:8556/readyz > /dev/null 2>&1; do sleep 5; done
echo "Node healthy"

# Start backend services and frontend
docker compose up -d wrfcoin-backend wrfcoin-governance \
  wrfcoin-iot wrfcoin-weather-earnings
docker compose up -d wrfcoin-frontend

# Start monitoring
docker compose up -d prometheus grafana alertmanager node-exporter
```

- [ ] All services started

### Step 7: Verify data integrity

```bash
# Block height
curl -s http://localhost:8556/blockchain | jq '{height: .height}'

# Backend health (includes DB and Redis status)
curl -s http://localhost:4001/health | jq .

# Peer connectivity (may take a few minutes to reconnect)
curl -s http://localhost:8556/network/info | jq '.connected_peers'

# PostgreSQL table check
docker compose exec -T postgres psql -U wrfcoin wrfcoin \
  -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'public';"
```

- [ ] Block height matches pre-backup height (or is within a few blocks)
- [ ] Backend health returns `{"status":"healthy",...}`
- [ ] Peers reconnecting
- [ ] PostgreSQL tables intact

---

## Post-Drill

Record the drill results:

| Field | Value |
|-------|-------|
| Date | |
| Backup used | |
| Operator | |
| Restore time (minutes) | |
| Block height before | |
| Block height after | |
| All services healthy? | Yes / No |
| Issues encountered | |

If issues were found, file a GitHub issue at `wrfcoin/infra` and update this checklist.
