# Legacy collector scripts (unsupported)

These scripts come from an earlier design of WRFCoin. They do **not** submit to the
chain 888 testnet, they are not part of any deployed service, and running them does
not earn testnet WRF. They are kept for reference only.

- `acurite-auto-collector.js`: multi-source weather polling against the old API.
- `compute-auto-collector.js`: compute-task client for an old API.
- `nas-auto-collector.js`: NAS discovery and storage client for an old API.

Any reward figure these scripts print comes from the server they talk to; none of
those servers is part of the current testnet.

## Supported ways to contribute weather data today

- **Ambient Weather station:** connect it on the website's **Connect a station**
  page at [wrfcoin.com](https://wrfcoin.com).
- **Phone as a station:** the Android app, once its signed release is published.

See the [docs quickstart](https://github.com/wrfcoin/docs/blob/main/testnet/quickstart.md).
A registered station or uploaded observation is not proof of a reward payment.
