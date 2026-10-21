# GFS Fetcher Health Response

This runbook covers the reusable GFS fetcher sidecar health check that probes NOAA NOMADS for
the `execution-engine` fetch contract.

## Signals

The probe exports:

- `gfs_fetch_health_up`
- `gfs_fetch_health_latency_seconds`
- `gfs_fetch_health_last_success_unixtime`
- `gfs_fetch_health_last_probe_unixtime`

The sidecar logs the most recent failure reason in plain text and as a comment in the textfile
collector output.

## Probe Down

Alert: `GfsFetcherProbeDown`

1. Inspect the sidecar logs to confirm whether the failure was HTTP, timeout, HTML payload, or bad GRIB magic.
2. If the failure is HTTP-based, verify the NOAA NOMADS endpoint is reachable from the environment running the sidecar.
3. If the failure is format-based, compare the failing payload with the current `execution-engine` contract in `core4/execution-engine/src/models/gfs_fetch.rs`.
4. If a format change is confirmed, pause automated GFS-dependent model scheduling until the fetch contract is updated.

## Latency High

Alert: `GfsFetcherLatencyHigh`

1. Check recent sidecar latency trends in Prometheus for transient versus sustained slowness.
2. Confirm whether elevated latency is isolated to the local network path or is broadly reproducible against NOMADS.
3. If latency remains high, increase fetch timeout only as a temporary mitigation and track the external dependency incident.

## Last Success Stale

Alert: `GfsFetcherLastSuccessStale`

1. Check whether the sidecar is still running and writing to the textfile collector volume.
2. Confirm that Node Exporter is scraping the shared textfile collector path.
3. If the sidecar is running but success is stale, inspect the latest failure reason and treat it as either an endpoint outage or a payload-contract change.
