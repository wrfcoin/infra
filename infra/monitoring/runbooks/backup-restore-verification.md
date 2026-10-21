# Runbook — Backup Restore Verification

**Issue:** [core4#753](https://github.com/wrfcoin/core4/issues/753)
**Script:** `infra/testnet/scripts/backup-restore-verification.sh`
**Related docs:** `infra/testnet/RESTORE_DRILL.md` (manual checklist),
`infra/testnet/backup.sh` (PR #220)
**Classification:** Human Required — destructive-to-state, must be supervised
**Expected runtime:** ~10 minutes

---

## Purpose

The testnet operator guide has documented backup (`backup.sh`) and restore
(`RESTORE_DRILL.md`) procedures since PR #220, but **no one has ever run a
restore against a real backup**. Untested backups are not backups.

This runbook wraps that end-to-end drill in a single bash entrypoint. It:

1. Captures pre-backup chain state (height, tip hash, state root)
2. Runs `backup.sh` — the existing documented procedure
3. Stops the stack and **moves** (does not delete) the named Docker
   volumes to a timestamped side location
4. Restores from the fresh backup using the documented procedure
5. Starts the stack, waits for `/readyz`
6. Asserts height, tip, and state root match the pre-backup values
7. On success: prints exactly how to reclaim the side-location disk space
   (a manual step — the script never deletes the safety net)
8. On failure: leaves the side-location volumes intact and prints the
   exact rollback commands

---

## When to run

| Trigger                                         | Required |
|-------------------------------------------------|:--------:|
| Before inviting external operators to testnet   | Yes      |
| After any change to `backup.sh` or `RESTORE_DRILL.md` | Yes |
| After any PostgreSQL schema migration           | Yes      |
| After any on-disk format change to node-data    | Yes      |
| Monthly on the reference node                   | Recommended |

---

## Pre-conditions

- The testnet stack is running and `/readyz` returns 200 on the node
- `backup.sh` is executable and at `infra/testnet/backup.sh`
- There is free disk space equal to at least the current state of all
  Docker volumes in the compose project (the side location holds a full
  copy until the human deletes it)
- You are prepared to be without testnet service for ~10 minutes
- You have SSH access to the host and can tail the log in real time

---

## Invocation

### Primary path (N5 Pro reference node, via SSH)

```bash
ssh <node-host>
pct enter 101

cd /root/wrfcoin/infra/testnet
./scripts/backup-restore-verification.sh --i-understand 2>&1 \
  | tee /var/log/wrfcoin-restore-drill/console.log
```

The `--i-understand` flag (or env var `I_UNDERSTAND=1`) is mandatory.
Without it the script refuses to run and prints the safety notice.

### Dry-reading the pre-flight (without running)

There's no true dry-run — the backup phase is non-destructive and the
script will safely abort before touching volumes if any earlier step
fails. To "preview" the actions, read the script header:

```bash
./scripts/backup-restore-verification.sh --help
```

### Custom backup directory

```bash
./scripts/backup-restore-verification.sh --i-understand \
  --backup-dir /mnt/tank/backups/testnet
```

---

## Success criteria

The script exits `0` and prints `SUCCESS` only if **all** of these hold:

- `backup.sh` exits 0 and creates a new timestamped directory under
  `BACKUP_DIR`
- Every named project volume is successfully archived to the side location
- Every volume is successfully removed (detached) after archive
- PostgreSQL restore completes without errors (if `postgres.sql` is in the
  backup)
- Blockchain data restore completes (either via tar.gz or ZFS snapshot ref)
- Node `/readyz` returns 200 within `RESTORE_TIMEOUT_SECS` (default 600s)
- Post-restore `height >= before_height` (delta >= 0). Delta may be
  positive if the node has advanced the chain since the backup was taken;
  any negative delta is a failure.
- If delta == 0, post-restore `tip_hash` must match pre-backup exactly.
- If delta > 0, the tip diverges by design — the drill still passes as
  long as the chain is consistent.

---

## Expected output

```
[2026-04-04T14:10:22Z] === WRFCoin backup restore verification ===
[2026-04-04T14:10:22Z] === Pre-flight ===
...
[2026-04-04T14:10:25Z] pre-backup: height=1555 tip=0xabcd... state_root=0x1234...
[2026-04-04T14:10:25Z] === Running backup.sh ===
...
[2026-04-04T14:13:40Z] fresh backup: /mnt/tank/backups/testnet/20260404_141025
[2026-04-04T14:13:45Z] === Simulating disaster: stopping stack and moving volumes aside ===
...
[2026-04-04T14:17:10Z] === Restoring from /mnt/tank/backups/testnet/20260404_141025 ===
...
[2026-04-04T14:19:50Z] waiting up to 600s for node /readyz...
[2026-04-04T14:20:35Z] node is ready
[2026-04-04T14:20:37Z] post-restore: height=1555 tip=0xabcd... state_root=0x1234...
[2026-04-04T14:20:37Z] tip hash matches exactly
[2026-04-04T14:20:37Z] === SUCCESS ===
[2026-04-04T14:20:37Z] restore verification PASSED
...
To reclaim disk (MANUAL STEP):
  rm -rf '/var/log/wrfcoin-restore-drill/side-volumes-20260404_141022'
```

---

## Failure handling / emergency rollback

The script is designed to fail **safely** — the side-location volumes are
never deleted automatically. If the restore fails after volumes have been
moved aside, the script prints the exact rollback commands. A conservative
general procedure:

```bash
SIDE=/var/log/wrfcoin-restore-drill/side-volumes-<TIMESTAMP>   # from the failed run

# 1. Stop the (failed) stack
cd /root/wrfcoin/infra/testnet
docker compose down

# 2. For each tarball in the side location, restore the volume
for tar in "$SIDE"/*.tar; do
  vol="$(basename "$tar" .tar)"
  docker volume rm "$vol" 2>/dev/null || true
  docker volume create "$vol"
  docker run --rm \
    -v "$vol:/dest" \
    -v "$SIDE:/src:ro" \
    alpine sh -c "cd /dest && tar xf /src/$vol.tar"
done

# 3. Bring the stack back up on the restored state
docker compose up -d

# 4. Verify
curl -s http://127.0.0.1:8556/readyz
curl -s http://127.0.0.1:8556/blockchain | jq '{height, tip}'
```

Do **not** delete the side location until you have verified the stack is
running on the restored state and serving blocks. Keep the side location
indefinitely until the root cause is understood — it is the only path back
to the pre-drill state.

---

## Reclaiming side-location disk (post-success)

The final step is manual and the human operator's responsibility:

```bash
# Only after verifying the drill passed and the node is serving blocks normally
rm -rf '/var/log/wrfcoin-restore-drill/side-volumes-<TIMESTAMP>'
```

---

## Post-drill audit log

After a successful drill, append an entry to the audit table at the bottom
of `infra/testnet/RESTORE_DRILL.md`:

```
| Date | 2026-04-04 |
| Backup used | /mnt/tank/backups/testnet/20260404_141025 |
| Operator | <your-handle> |
| Restore time (minutes) | ~10 |
| Block height before | 1555 |
| Block height after | 1555 |
| State root match | yes |
| All services healthy? | yes |
| Issues encountered | (none / link to issue) |
```

If the drill uncovered any issues with `backup.sh` or `RESTORE_DRILL.md`,
file a bug in `wrfcoin/infra` and update the docs in the same PR as the fix.

---

## Deployment notes

- The reference node (N5 Pro, CT 101) uses ZFS-backed volumes for some
  datasets. For these the backup is a ZFS snapshot reference
  (`zfs-snapshot.txt`) and restore must be invoked via
  `ssh <node-host> zfs rollback tank/blockchain@backup-<TIMESTAMP>`
  out-of-band. The script detects this case and logs a warning rather
  than attempting the rollback itself (which requires host-level access
  it does not have from inside the LXC).
- Operators running the generic (Docker-volume-only) deployment can use
  the script end-to-end without any ZFS step.
- All testnet deployment is local builds via SSH to the N5 Pro — the
  script never pulls or pushes images to any registry.

---

## Related runbooks

- [`sustained-operation-test.md`](./sustained-operation-test.md) — the
  other pre-launch "Human Required" procedure (issue core4#758)
- [`testnet/RESTORE_DRILL.md`](../../../testnet/RESTORE_DRILL.md) — the
  manual restore checklist that this script automates
- [`testnet/backup.sh`](../../../testnet/backup.sh) — the documented
  backup procedure (PR #220)
