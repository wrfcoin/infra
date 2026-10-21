# SDR Ingest Service — Experimental RTL-SDR Weather Enrichment

> **Status**: EXPERIMENTAL. This service is an enrichment-only contributor, not a blockchain peer. It supplements the core 3-peer testnet with localized weather observations from RTL-SDR hardware.

## Overview

The SDR Ingest service captures RF-transmitted weather observations using an RTL-SDR dongle, normalizes the raw sensor data to WRF schema, and forwards normalized observations to the WRF ingestion endpoint. The service acts as a sensor client, not a network peer.

### Supported Protocols

- **Acurite** — 5n1 sensors (temperature, humidity, battery)
- **Oregon Scientific** — WGR918 and similar (temperature, humidity, pressure, wind)
- **Fine Offset** — WH1080/WH1081 (temperature, humidity, wind, rain)

Observations from other protocols are silently dropped.

## Hardware Requirements

### Minimum Setup

- **RTL-SDR dongle**: DVB-T USB stick (cost: $20–40)
  - Models: RTL2832U-based (e.g., NooElec NESDR Nano Plus, Nooelec NESDR SMArTee XTR)
  - Antenna: 433 MHz dipole or generic monopole
- **Raspberry Pi 4** or x86-64 Linux host (4GB+ RAM recommended)
- **Weatherproof enclosure** (optional, for outdoor deployment)

### Supported Platforms

- **Linux only** — rtl_433 requires libusb and kernel usbfs access
- **Windows/macOS** — not supported in production (rtl_433 support is experimental)
- **WSL2** — requires USB passthrough; see [WSL USB docs](https://learn.microsoft.com/en-us/windows/wsl/connect-usb)

## Usage

### Mode 1: Live RTL-SDR Hardware

```bash
docker-compose -f docker-compose.testnet.yml \
  --profile experimental up sdr-ingest
```

Assumes an RTL-SDR dongle is physically present on the host and accessible via `/dev/bus/usb`.

**Environment Variables** (optional):
- `WRF_INGEST_URL` — Target WRF endpoint (default: `http://localhost:8080/ingest`)
- `SDR_POLL_INTERVAL` — Seconds between rtl_433 polls (default: `5`)
- `SDR_PROTOCOLS` — Comma-separated allowed protocols (default: `acurite,oregon,fine_offset`)
- `LOG_LEVEL` — `debug|info|warn|error` (default: `info`)

### Mode 2: Fixture File (Development/Testing)

```bash
docker run -e SDR_FIXTURE_FILE=/app/fixtures/sample_rtl433.jsonl \
  sdr-ingest:latest
```

The service will read observations from the fixture file, normalize them, POST them to the WRF endpoint, and exit.

## Troubleshooting

### Service won't start / rtl_433 not found

- Ensure rtl-sdr kernel module is loaded: `lsmod | grep rtl`
- Check USB permissions: `ls -la /dev/bus/usb/*/`
- On Linux, add user to `dialout` group: `sudo usermod -aG dialout $USER`

### No observations captured

- Verify rtl_433 works standalone: `rtl_433 -F json`
- Check antenna placement and orientation
- Ensure allowed protocol matches your sensors: `SDR_PROTOCOLS=acurite,* ...`

### Health check failing

```bash
curl http://localhost:9000/health
```

The service is healthy if:
1. At least one observation ingested successfully
2. Last successful ingest was within 2 minutes

## Architecture Notes

### Data Flow

```
[Hardware: RTL-SDR Sensor] 
        ↓ (RF 433 MHz)
[rtl_433 JSON stream]
        ↓
[Filter by protocol]
        ↓
[Normalize to WRF schema]
        ↓
[POST to WRF /ingest endpoint]
        ↓
[WRF storage/processing]
```

### WRF Schema Normalization

Each captured observation is normalized to this schema before submission:

```json
{
  "timestamp": "2026-04-11T16:00:00Z",
  "source": {
    "type": "sdr",
    "device_id": "sensor_model_id",
    "protocol": "Acurite|Oregon|Fine Offset",
    "rssi": -85
  },
  "observations": {
    "temperature_c": 22.5,
    "humidity": 65,
    "pressure_mb": null,
    "wind_speed_ms": null,
    "wind_direction_deg": null,
    "rain_mm": null,
    "battery": 1
  }
}
```

Unknown fields are omitted; protocol-specific fields are included when available.

### Trust and Limitations

- **No peer identity**: SDR observations are not signed and cannot be attributed to a specific WRFCoin peer. They are enrichment-only.
- **Local hardware only**: A compromised host or rtl_433 process can inject false observations.
- **Timestamp resolution**: Hardware timestamps are approximate; received time is used if not provided.
- **No replay protection**: Observations can be replayed; the WRF ingestion endpoint should apply deduplication by (device_id, timestamp) tuple.

## Compose Profile Integration

The service is **gated behind the `experimental` profile** to keep it out of default testnet runs:

```yaml
sdr-ingest:
  profiles: ["experimental"]
  # ... rest of config
```

To activate: `docker-compose --profile experimental up`

## Next Steps (Future Work)

- [ ] Add geographic coordinates (latitude/longitude) to observations
- [ ] Support additional protocols (e.g., Ambient Weather, Davis Instruments)
- [ ] Implement buffering/retry logic for WRF endpoint downtime
- [ ] Add metrics export (Prometheus) for observation rate and ingestion latency
- [ ] Cross-reference rtl_433 observations with peer-submitted weather data for validation

## References

- [rtl_433 documentation](https://github.com/merbanan/rtl_433)
- [RTL-SDR getting started](https://www.rtl-sdr.com/about-rtl-sdr/)
- WRF Weather Schema: See `wrfcoin/core4/docs/weather-schema.md`
