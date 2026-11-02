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

The postgres role is the compose file's `POSTGRES_USER`, read inside the container.

```bash
cd /root/wrfcoin/infra/testnet
docker compose -f docker-compose.testnet.yml exec -T --user postgres postgres sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -XAtc "SHOW archive_mode" -c "SHOW archive_command" -c "SELECT archived_count, failed_count, last_failed_time FROM pg_stat_archiver"'
```

Expected:

- `archive_mode` = `on`
- `archive_command` points at `/var/lib/postgresql/data/backup/wal`
- `failed_count` is not growing

If `failed_count` keeps growing and the Postgres log shows `cmp` reporting a difference,
the archive already holds a file with that segment's name and different bytes. Postgres
retries that segment forever and archives nothing after it, and WAL piles up in `pg_wal`.
Nothing overwrites the file, because it may be the good copy. Compare the two, then move
the wrong one out of `backup/wal` by hand. An interrupted copy no longer causes this: it
leaves only a hidden `.<segment>.tmp`, which the next attempt overwrites.

A new `postgres-backup` volume is root-owned, and the archiver runs as `postgres`. Until
the directory belongs to `postgres`, every attempt fails with `Permission denied`, and
WAL piles up in `pg_wal`. `pg-basebackup.sh` fixes the ownership on each run, so run it
once after creating the volume.

## 2. Run a base backup manually

```bash
cd /root/wrfcoin/infra
bash testnet/scripts/pg-basebackup.sh
```

The script will:

- create a new physical backup directory under `.../backup/base/`, without a restart or
  a heavy lock
- check it with `pg_verifybackup`, and on failure remove it and leave older backups alone
- keep only the newest `PG_BASEBACKUP_KEEP_COUNT` backups (default `3`)
- leave the WAL archive alone, unless you pass `--prune-wal`

Pruning is opt-in, so that scheduling backups cannot start deleting WAL before a restore
has been proven on that host. After that, `--prune-wal` runs `scripts/pg-wal-prune.sh
--apply` after the backup. The PITR window then runs from the oldest kept base backup to
now: nightly with 3 kept is about 3 days. To see what pruning would do without changing
anything:

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

## 4. Test a backup: restore into a scratch volume

This doesn't touch or stop the live database. The copy runs in a new container with no
network, the backup volume mounted read-only and archiving off.

```bash
cd /root/wrfcoin/infra
bash testnet/scripts/pg-restore-pitr.sh --scratch-volume pg-restore-scratch
```

Optional: `--base-backup 20260408_020001` (default: the newest) and
`--target-time "2026-04-08 02:15:00+00"` (default: all archived WAL).

The scratch container `pg-restore-scratch-pg` stays up for checking. Remove it, by exact
name, when done. Cleanup only removes a container and volume labelled as scratch:

```bash
bash testnet/scripts/pg-restore-pitr.sh --cleanup-scratch --scratch-volume pg-restore-scratch
```

## 5. Restore over the live database

Warning: this replaces the running database. With no target, or with a target or
confirmation that doesn't match, the script changes nothing and exits 3.

First stop the services that write to the database. Then name the volume the postgres
container runs on, twice:

```bash
cd /root/wrfcoin/infra
docker volume ls --filter name=postgres-data
bash testnet/scripts/pg-restore-pitr.sh --live \
  --target-volume testnet_postgres-data \
  --confirm-overwrite testnet_postgres-data \
  --target-time "2026-04-08 02:15:00+00"
```

What it does:

1. Verifies the base backup, before stopping anything.
2. Stops only the postgres container.
3. Copies the backup to `pgdata` on the volume and writes the recovery settings. The old
   data stays beside it as `pgdata.pre-restore-<time>`.
4. Starts the same container and waits until it has left recovery.

It doesn't recreate any container or start other services. Start those through your normal
deploy path, with the same compose file set they were created from. Delete
`pgdata.pre-restore-<time>` once you are satisfied.

## 6. Post-restore checks

```bash
cd /root/wrfcoin/infra/testnet
docker compose -f docker-compose.testnet.yml exec -T --user postgres postgres sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -XAtc "SELECT pg_is_in_recovery()" -c "SELECT now()"'
docker compose -f docker-compose.testnet.yml ps
```

Expected:

- `pg_is_in_recovery` returns `f`
- postgres and dependent services are healthy
