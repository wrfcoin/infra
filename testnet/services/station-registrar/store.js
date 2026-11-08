'use strict';

// The service's record of requests: one JSON file, mode 0600, rewritten
// atomically (temp file, fsync, rename) inside one serialized step, so two
// requests can never both pass a limit. Volume is tiny (20 a day at most).
//
// What a record keeps (STATION_REGISTRAR.md, "What is stored"):
//   stationId, ipHash (salted HMAC, never the address), cell (integer tenths),
//   acceptedAt, releaseAt, status, and while held the signed-by-owner row
//   (its coordinates are already on the 0.1 degree grid). The row is dropped as
//   soon as the registration is submitted or refused. Records that are no
//   longer held are deleted after `retentionSeconds` (30 days).

const fs = require('node:fs');
const path = require('node:path');

const STATUSES = new Set(['held', 'submitted', 'registered', 'refused', 'needs_review']);

function validRecord(r) {
  return r && typeof r === 'object' && typeof r.stationId === 'string' && typeof r.ipHash === 'string'
    && typeof r.cell === 'string' && Number.isSafeInteger(r.acceptedAt) && Number.isSafeInteger(r.releaseAt)
    && STATUSES.has(r.status);
}

function createFileStore(file, { retentionSeconds }) {
  let records = [];
  let queue = Promise.resolve();

  function load() {
    if (!fs.existsSync(file)) {
      records = [];
      return;
    }
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!parsed || parsed.version !== 1 || !Array.isArray(parsed.records) || !parsed.records.every(validRecord)) {
      throw new Error('registrar state file is not readable; refusing to start');
    }
    records = parsed.records;
  }

  function persist(next) {
    const tmp = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.tmp`);
    const fd = fs.openSync(tmp, 'w', 0o600);
    try {
      fs.writeSync(fd, JSON.stringify({ version: 1, records: next }));
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(tmp, file);
  }

  function purge(list, nowSeconds) {
    return list.filter((r) => r.status === 'held' || r.acceptedAt + retentionSeconds > nowSeconds);
  }

  // Run `fn(copy)` alone; whatever it returns is the step's result. If it
  // changed the copy, the copy is written before the step ends. A throw leaves
  // the file and memory untouched.
  function transact(nowSeconds, fn) {
    const step = queue.then(async () => {
      const copy = purge(records, nowSeconds).map((r) => ({ ...r }));
      const before = JSON.stringify(copy);
      const result = await fn(copy);
      const after = JSON.stringify(copy);
      if (after !== before || copy.length !== records.length) {
        persist(copy);
        records = copy;
      }
      return result;
    });
    queue = step.catch(() => {});
    return step;
  }

  function snapshot() {
    return records.map((r) => ({ ...r }));
  }

  return { load, transact, snapshot };
}

module.exports = { createFileStore, STATUSES };
