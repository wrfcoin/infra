# WRFCoin Testnet PostgreSQL WAL + PITR Runbook

Issue: `wrfcoin/infra#121`

## Overview

The testnet postgres service now archives WAL continuously into a named Docker
volume and supports physical base backups + point-in-time recovery (PITR).

- Base backup path (inside postgres container):
  `/var/lib/postgresql/data/backup/base/<timestamp>/`
- WAL archive path (inside postgres container):
  `/var/lib/postgresql/data/backup/wal/`
- WAL/PITR config file:
  `testnet/postgresql.wal.conf`

## 1. Verify WAL archiving is enabled

```bash
cd /root/wrfcoin/infra/testnet
docker compose -f docker-compose.testnet.yml up -d postgres
docker compose -f docker-compose.testnet.yml exec -T postgres psql -U postgres -d postgres -c "SHOW archive_mode;"
docker compose -f docker-compose.testnet.yml exec -T postgres psql -U postgres -d postgres -c "SHOW archive_command;"
```

Expected:

- `archive_mode` = `on`
- `archive_command` points at `/var/lib/postgresql/data/backup/wal`

## 2. Run a base backup manually

```bash
cd /root/wrfcoin/infra
bash testnet/scripts/pg-basebackup.sh
```

The script will:

- create a new physical backup directory under `.../backup/base/`
- keep only the newest `PG_BASEBACKUP_KEEP_COUNT` backups (default `3`)
- prune archived WAL older than the oldest kept base backup (`scripts/pg-wal-prune.sh`)

The PITR window runs from the oldest kept base backup to now: nightly with 3 kept
is about 3 days. To see what pruning would do without changing anything:

```bash
bash testnet/scripts/pg-wal-prune.sh            # dry run
bash testnet/scripts/pg-wal-prune.sh --apply    # delete
```

Pruning deletes only WAL older than that backup. It deletes nothing and exits 3 when
there is no base backup, any base backup fails `pg_verifybackup`, or the archive has
a gap after the anchor segment.

## 3. Schedule nightly base backup (02:00)

```cron
0 2 * * * cd /root/wrfcoin/infra && bash testnet/scripts/pg-basebackup.sh >> /var/log/wrfcoin-pg-basebackup.log 2>&1
```

Optional retention tuning in `testnet/.env`:

```bash
PG_BASEBACKUP_KEEP_COUNT=3
```

## 4. Perform PITR restore

Warning: this is destructive to the current postgres-data volume.

```bash
cd /root/wrfcoin/infra
bash testnet/scripts/pg-restore-pitr.sh \
  --target-time "2026-04-08 02:15:00+00" \
  --confirm
```

Optional:

```bash
bash testnet/scripts/pg-restore-pitr.sh \
  --base-backup 20260408_020001 \
  --target-time "2026-04-08 02:15:00+00" \
  --confirm
```

What restore does:

1. Stops the testnet stack.
2. Restores `postgres-data` from the selected base backup.
3. Writes recovery settings + `recovery.signal`.
4. Starts postgres and replays WAL up to `--target-time`.
5. Starts the full stack after promotion.

## 5. Post-restore checks

```bash
cd /root/wrfcoin/infra/testnet
docker compose -f docker-compose.testnet.yml exec -T postgres psql -U postgres -d postgres -c "SELECT pg_is_in_recovery();"
docker compose -f docker-compose.testnet.yml exec -T postgres psql -U postgres -d wrfcoin -c "SELECT now();"
docker compose -f docker-compose.testnet.yml ps
```

Expected:

- `pg_is_in_recovery` returns `f`
- postgres and dependent services are healthy
