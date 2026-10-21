# Opt-in daily weather archive worker

This overlay depends on the reviewed `ipfs-storage` base profile and the backend daily temperature archive worker. Merge those before this image-entry change: the ordinary backend image build requires the worker source file.

The backend image bundles `server/weather-ipfs-archive-worker.ts` as `dist/weather_ipfs_archive.cjs` and creates `/app/weather-archive` before assigning app ownership to uid/gid 1001. An empty named receipt volume inherits that mount point's ownership. Existing volumes must already be writable by 1001:1001; operators should verify volume ownership before owner-approved enablement.

`testnet/docker-compose.weather-archive.yml` defines the separate `weather-archive` profile. It starts only when an owner explicitly includes the overlay and enables both `ipfs-storage` and `weather-archive`. Default and full startup do not enable it. The worker waits for `db-migrate` to complete successfully; this overlay requires migration0028 in that image's freshness check so an older image cannot satisfy the barrier. The worker has no port, serves no health endpoint and disables the backend image's API healthcheck.

It reads existing public releases through a PostgreSQL connection configured read-only with a five-second statement timeout. It records each first daily snapshot's acknowledged CID in `weather-ipfs-receipts`, mounted at `/app/weather-archive`, and retries unavailable days on hourly sweeps. The latest 14 published days are considered; older dates require an explicit UTC date argument. Retain and back up this volume together with Kubo data. Published coordinates are integer tenths; fine coordinates and contributor identities are excluded. Temperature summaries retain the existing 0.5C/count-bucket policy. Suppressed cells are omitted completely so their presence remains indistinguishable from absent cells; all-suppressed days create no archive.

Owner deployment procedure: rebuild the reviewed backend and storage-node images, apply backend migration `0028_weather_archive_day_index` after the existing release-table migration, check volume ownership, then decide whether to include the overlay and profiles. The new index is required before worker enablement and its build blocks table writes during the migration transaction. This PR runs no deployment and changes no release pin or schedule. The legacy mock service's retirement remains backend#1117's prerequisite decision.

Render only, without env-file contents or daemon access:

```sh
docker compose --env-file /dev/null -f testnet/docker-compose.testnet.yml -f testnet/docker-compose.weather-archive.yml --profile ipfs-storage --profile weather-archive config --no-interpolate
pytest -q scripts/tests/test_weather_archive_profile.py
```
