# WRFCoin Testnet Experimental SDR Ingest

This is the radio-weather prototype path for `infra#314`.

Use it only after the 3-peer testnet is stable and the regular gateway/API weather path is
already working. The goal is to keep SDR-derived observations separate from peer identity,
validator operations, and the core node rollout.

---

## Chosen Pilot

### First SDR source

Start with 433 MHz household weather broadcasts collected through an RTL-SDR dongle and
`rtl_433`.

Why this first:

- the hardware is already listed in the N5 Pro setup guide
- `operator-install.sh` already detects RTL-SDR dongles as optional radio-weather hardware
- 433 MHz weather sensors are a natural fit for a first normalization pass

### Host machine

Use a USB-capable host for the decoder. CT101 is an unprivileged LXC and currently does
not expose `/dev/bus/usb`; its N5 compose overlay deliberately removes the SDR device mount.
Do not enable the experimental SDR profile on CT101 expecting a dongle to appear.

Recommended split:

- physical host: N5 Pro at `<NODE_LAN_IP>`
- runtime boundary: CT 101 or another isolated container on the N5 Pro
- do not run the SDR decoder on a peer laptop or on a contributor device

This keeps the SDR path on the stable always-on box without turning the SDR host into a peer.

---

## Proposed Service Shape

The prototype should look like this:

```text
RTL-SDR dongle
  -> rtl_433 decode
  -> local normalizer / adapter
  -> WRFCoin weather ingest API or queue
```

Suggested container split:

- `rtl433-ingest`: reads the USB dongle and emits JSON observations
- `sdr-normalizer`: stamps UTC timestamps, normalizes units, and preserves raw payloads
- `weather-ingest-adapter`: forwards the normalized observation to the backend weather pipeline

A future compose sketch would mount the USB device into the decoder container and keep the
normalizer on the same private network as the backend adapter.

Example shape only:

```yaml
services:
  rtl433-ingest:
    image: hertzg/rtl_433:latest
    command: ["-F", "json", "-M", "time:utc"]
    devices:
      - /dev/bus/usb:/dev/bus/usb

  sdr-normalizer:
    image: wrfcoin/sdr-normalizer:dev
    environment:
      INPUT_MODE: rtl_433-json
      OUTPUT_MODE: weather-observation
      UTC_ONLY: "true"
```

Do not treat this as production-ready compose. It is a planning slice that documents the
boundary and the expected shape of the later implementation.

---

## Normalization Rules

Keep the record model narrow and explicit:

- capture `observed_at` from the SDR payload when available
- stamp `received_at` when the collector sees the packet
- normalize units to SI or clearly named meteorological units
- retain the raw decode blob for debugging and provenance
- carry a stable device identifier, but do not let it become node identity

Minimum useful fields:

- `source_type`: `sdr`
- `sensor_family`: `433mhz-weather`
- `device_id`: stable sensor identifier
- `observed_at`: original or best-effort event time
- `received_at`: collector arrival time in UTC
- `signal_quality`: optional RSSI / SNR / decode metadata
- `raw_payload`: original `rtl_433` JSON
- `normalized_readings`: weather fields ready for downstream ingestion

---

## Trust And Limits

- The dongle host is a local bridge, not a blockchain authority.
- Radio packets may be duplicated, noisy, or partially decoded.
- Time sync matters more here than it does for gateway/API weather devices.
- The path should stay experimental until the testnet can absorb the data without confusing it
  with peer health or validator status.

---

## Operator Overhead

Expect to manage:

- USB placement and antenna quality
- local RF interference and range tuning
- `rtl_433` version pinning
- packet duplication and noisy decodes
- container restart behavior after host reboots

If the SDR path starts behaving like a maintenance burden, pause it. The testnet peer rollout
still takes priority over enrichment hardware.

---

## Handoff Checklist

When you hand this path to another operator, include:

- the chosen host machine
- the USB dongle model and port path
- the first sensor family being decoded
- the normalization rules in use
- the backend endpoint or queue that will receive the observations

For the broader node rollout, see [`GETTING_STARTED.md`](GETTING_STARTED.md) and
[`core4/docs/TESTNET_OPERATOR_GUIDE_v3.md`](https://github.com/wrfcoin/core4/blob/main/docs/TESTNET_OPERATOR_GUIDE_v3.md)
(canonical; `TESTNET_OPERATOR_GUIDE.md` in this repo is retired).
