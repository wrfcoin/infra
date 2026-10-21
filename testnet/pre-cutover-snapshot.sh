#!/usr/bin/env bash
# WRFCoin Testnet — pre-cutover safety net (infra#628)
#
# Creates the `@pre-upgrade` ZFS snapshot(s) the UPGRADE_RUNBOOK / CUTOVER_RUNBOOK
# rollback steps reference, and preserves the currently-running node image as
# `wrfcoin/native-chain:testnet-rollback` so a rollback has a local image to
# restore WITHOUT any registry pull (deploy policy: local builds only).
#
# Run this on the host that owns the ZFS pool + Docker (CT 101 / reference node)
# IMMEDIATELY BEFORE an atomic both-node cutover.
#
# Usage:
#   bash pre-cutover-snapshot.sh                 # snapshot default datasets + tag image
#   ZFS_DATASETS="tank/blockchain tank/postgres" bash pre-cutover-snapshot.sh
#   ROLLBACK_IMAGE_SRC=wrfcoin/native-chain:testnet-local bash pre-cutover-snapshot.sh
#
# Idempotent: an existing `@pre-upgrade` snapshot is replaced so the rollback
# target always reflects the state right before THIS cutover.
set -euo pipefail

SNAP_SUFFIX="${SNAP_SUFFIX:-pre-upgrade}"
# Datasets that back the stack's named Docker volumes. Only those that actually
# exist on this host are snapshotted; the rest are skipped with a note.
ZFS_DATASETS="${ZFS_DATASETS:-tank/blockchain tank/postgres tank/redis}"
ROLLBACK_IMAGE_SRC="${ROLLBACK_IMAGE_SRC:-wrfcoin/native-chain:testnet-local}"
ROLLBACK_IMAGE_DST="${ROLLBACK_IMAGE_DST:-wrfcoin/native-chain:testnet-rollback}"

log() { printf '[pre-cutover] %s\n' "$*"; }
err() { printf '[pre-cutover] ERROR: %s\n' "$*" >&2; }

# ---- 1. ZFS pre-upgrade snapshots -----------------------------------------
snapped=0
if command -v zfs > /dev/null 2>&1; then
  for ds in ${ZFS_DATASETS}; do
    if zfs list "${ds}" > /dev/null 2>&1; then
      snap="${ds}@${SNAP_SUFFIX}"
      # Replace any stale @pre-upgrade so the rollback target is current.
      if zfs list -t snapshot "${snap}" > /dev/null 2>&1; then
        log "Replacing existing snapshot ${snap}"
        zfs destroy "${snap}"
      fi
      if zfs snapshot "${snap}"; then
        log "Created ${snap}"
        snapped=$((snapped + 1))
      else
        err "Failed to snapshot ${ds}"
      fi
    else
      log "Dataset ${ds} not present on this host — skipping"
    fi
  done
  if [ "${snapped}" -eq 0 ]; then
    err "No ZFS datasets matched — no @${SNAP_SUFFIX} snapshot created. Fall back to the file-based backup (bash backup.sh) for rollback."
  fi
else
  log "zfs not available — skipping ZFS snapshots (Docker-volume host)."
  log "Rollback will rely on the file-based backup (bash backup.sh) + the retained image below."
fi

# ---- 2. Preserve the current node image as :testnet-rollback ---------------
if command -v docker > /dev/null 2>&1; then
  if docker image inspect "${ROLLBACK_IMAGE_SRC}" > /dev/null 2>&1; then
    docker tag "${ROLLBACK_IMAGE_SRC}" "${ROLLBACK_IMAGE_DST}"
    log "Tagged ${ROLLBACK_IMAGE_SRC} -> ${ROLLBACK_IMAGE_DST} (rollback image)"
  else
    err "Image ${ROLLBACK_IMAGE_SRC} not found locally — cannot create ${ROLLBACK_IMAGE_DST}."
    err "Build it first (docker compose ... build wrfcoin-node) then re-run, or rollback must rebuild from the previous source SHA."
  fi
else
  err "docker not available — cannot tag ${ROLLBACK_IMAGE_DST}."
fi

log "Pre-cutover snapshot complete. Rollback references: @${SNAP_SUFFIX} snapshots + ${ROLLBACK_IMAGE_DST}."
