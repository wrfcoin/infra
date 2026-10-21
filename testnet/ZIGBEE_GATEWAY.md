# WRFCoin Testnet Zigbee Sensor Gateway

Use this guide after the 3-peer testnet is already stable and you want to add Zigbee-based sensor
coverage without turning the dongle host into another blockchain peer.

If you are still bringing up peer #2 or peer #3, stop here and finish the peer rollout first.
Zigbee is a contributor-enrichment path, not part of the core peer bootstrap.

---

## What This Path Is For

Zigbee devices should feed the weather/contributor pipeline through a gateway layer such as
Zigbee2MQTT or Home Assistant. The coordinator host stays local, the mesh stays behind the gateway,
and the WRFCoin node stack does not need to run on the same machine as every sensor.

This path is a good fit when:

- you already have a stable N5 Pro + desktop + Surface peer network
- the Zigbee dongle is physically attached to a machine that already has reliable uptime
- you want to normalize local sensor readings before they reach the contributor pipeline

## Host Selection

Choose the host with the lowest expected downtime and the simplest USB path to the coordinator.
In practice, that usually means one of:

- the N5 Pro, if it is already the most stable always-on box and the dongle lives there
- the desktop peer, if it is the better permanent USB home for the coordinator

Avoid laptops, sleep-prone desktops, and any box that is still being moved around as part of the
peer rollout. The gateway should be boring and predictable.

## Recommended Stack

Preferred default:

- Zigbee2MQTT as the device bridge
- MQTT or an equivalent local transport for normalized readings
- a small adapter that converts gateway readings into the WRFCoin contributor pipeline

Acceptable alternatives:

- Home Assistant as the bridge if the operator already uses it as the local home hub
- any equivalent gateway that can expose stable, normalized JSON for ingestion

## Initial Sensor Mapping

Start small and keep the first mapping obvious:

| Sensor class | Normalized output | Notes |
|--------------|-------------------|-------|
| Temperature | `temperature_c` | Core weather signal |
| Humidity | `humidity_pct` | Core weather signal |
| Pressure | `pressure_hpa` | Weather enrichment |
| Contact | `state` + metadata | Useful for gateway/device status, not peer identity |
| Motion | `state` + metadata | Useful for occupancy or home context |
| Power / energy | `watts` or `kwh` + metadata | Useful for local telemetry and later enrichment |

Keep the gateway output clearly separate from blockchain peer identity. A Zigbee sensor does not
become a node; it contributes observations through the gateway.

## Trust Assumptions

- The Zigbee coordinator is trusted only as a local bridge, not as a blockchain authority.
- Sensor values may be noisy, intermittent, or duplicated; normalize them before submission.
- The gateway host should be protected like any other home-ops box: local firewall, SSH access,
  and regular backups of coordinator state.

## Operator Overhead

Expect to manage:

- coordinator pairing and re-pairing
- USB placement and interference
- Zigbee network backups and channel changes
- gateway software updates

If the gateway starts becoming flaky, pause sensor expansion rather than pushing it into the
peer rollout. The core network should stay the priority.

## Handoff Notes

When you hand this path to another operator, give them:

- the chosen gateway host
- the coordinator device path
- the bridge software being used
- the normalized sensor classes being emitted
- the ingestion endpoint that will receive the readings

See [`core4/docs/TESTNET_OPERATOR_GUIDE_v3.md`](https://github.com/wrfcoin/core4/blob/main/docs/TESTNET_OPERATOR_GUIDE_v3.md)
(canonical; `TESTNET_OPERATOR_GUIDE.md` in this repo is retired) for the larger testnet operator
context and [`GETTING_STARTED.md`](GETTING_STARTED.md) for the initial bootstrap flow.
