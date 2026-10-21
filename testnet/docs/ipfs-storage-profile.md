# Opt-in testnet IPFS storage

Refs infra#944, backend#1117, storage-providers#65. Owner ruling: IPFS only.

The `ipfs-storage` profile adds `storage-node` and `ipfs-kubo` to the testnet compose. Default and `full` profile startup omit both services. Starting this profile remains an owner deployment decision; this change performs no deployment.

The daemon image uses the existing `infra/infra/docker/Dockerfile.storage` with the workspace root build context. `WRFCOIN_ROOT` can identify a workspace containing both infra and storage-providers. Its default relative context is the workspace above the infra checkout. Rebuild the daemon image from the reviewed storage-providers source before an approved rollout; no registry publication is required.

Internal backend clients use `http://storage-node:7001` (`WRFCOIN_STORAGE_NODE_URL` default). `POST /api/store` accepts JSON/base64 with provider `ipfs`; `GET /api/retrieve/ipfs:CID` returns bytes. GET `/health` returns 503 when Kubo cannot be reached. The distroless daemon contains neither shell nor curl, so health probes run from a client rather than a container healthcheck.

Neither daemon nor Kubo has a host port. Kubo belongs only to the internal `ipfs-private` network; its administrative API is reachable by the storage daemon. The daemon also joins `wrfcoin-testnet` for app clients. Kubo data persists in the `testnet-ipfs-data` named volume. Storage remains local to this self-hosted node: the private network has no Internet/P2P route, remote availability or paid pinning guarantee. No Filecoin, Arweave or remote pinning credentials are configured.

The legacy `wrfcoin-storage` full-profile backend service and its edge route are removed by the storage-mock retirement (`testnet/docs/storage-mock-retirement.md`; merge order: infra first, then the paired backend change, backend#1117). Until that change is merged and an owner-run `full` recreate happens, a running legacy service never routed to this daemon. Do not treat legacy probes as evidence for this profile. The daily-summary archive worker with durable per-day CID receipts is merged (backend#1423) and has its own opt-in compose file (`testnet/docker-compose.weather-archive.yml`); enabling it remains a separate owner decision.

Render-only validation (no images built, downloaded or started):

```sh
docker compose --env-file /dev/null -f testnet/docker-compose.testnet.yml --profile ipfs-storage config --no-interpolate
pytest -q scripts/tests/test_testnet_ipfs_profile.py
bash scripts/tests/test-storage-compose-ipfs-only.sh
```

No release pin, env-completeness script, database migration or feature schedule changes accompany this profile.
