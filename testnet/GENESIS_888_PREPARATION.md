# Chain 888 preparation (historical)

> **Historical.** The chain 888 cut has been performed and chain 888 is the public
> testnet. This page records the preparation as it stood before the cut, so its
> references to chain 777 describe the pre-cut state; they are not current
> instructions. To join today, follow [JOIN_TESTNET.md](JOIN_TESTNET.md); the
> current pins are in [`cut-pins.env`](cut-pins.env).

This was preparation source, not a deployment receipt. Testnet WRF has no monetary
value. Before the cut, the committed `cut-pins.env` and all runtime defaults stayed
on chain 777 until the owner performed the cut. No script here initiates the cut.

Use `WRFCOIN_CHAIN_ID=888` consistently for Compose, heartbeat, collectors,
station activation, smoke and uptime probes. `setup-env.sh` reads and validates
this identity from the active cut pins before writing new configuration.
Run `check-env-completeness.sh` on existing hosts before recreation: even outside
cut mode it refuses a missing/stale chain selector after the pins move to 888.
Update an enabled `WRFCOIN_GOVERNANCE_CHAIN_ID` to the same chain; the preflight
refuses a stale persisted or exported governance selector. The reset helper also requires it
to agree with the public cut pins. Supply `WRFCOIN_GENESIS_HASH` to the smoke
probe after the cut; its legacy default applies only to the old smoke fixture.

`docker-compose.genesis.yml` is an explicit extra overlay for the cutting nodes.
It forwards the same producer set, oracle set, faucet address, activation schedule
and signing protocol version to node and seed. Missing/empty inputs refuse during
render. It supersedes the schedule/signing passthrough portion of the older cut
toolkit proposals; it does not import their host dispatch or destructive phases.
The ordinary Compose stack is unchanged until this overlay is explicitly selected.

The public 888 template records signing **v1**, flat reward seconds **600**,
faucet allocation **10000000000000 base units (100,000 WRF)**, the owner-selected
public governance key, and node-pay epoch/challenge windows of **512/512 blocks**.
**The owner-ruled flat reward is 2222222222 base units per block**
(22.22222222 WRF, approximately 22.22 WRF). The template records this exact value.
`WRFCOIN_GENESIS_FLAT_REWARD_BASE_UNITS` remains required independently of the
600-second tier; the overlay supplies no implicit amount.

It schedules these eight named gates at block 2 (within the owner's 2–100
window): schedule_extension, reward_gross_outlier_guard,
weather_skew_block_time_allowance, station_active_reward_gate,
station_owner_actions, station_owner_consent, station_registration_nonce,
node_share_settlement. The recorded genesis faucet address supplies the ninth
faucet function; do not schedule the legacy faucet_sink_binding gate on 888.
No other feature is enabled. Producer/oracle sets and
faucet address remain placeholders for the owner to fill.

The overlay also requires the flat reward, allocation, governance and epoch/window
inputs. A successful render proves passthrough only: the reviewed core4 Round R
binary must accept this v1 schedule, enforce it and record all declarations in
block 1. Do not switch signing version to bypass a refusal. Check the recorded
metadata, node pay and 777 differential in rehearsal before the owner cut.

For a render only, with an owner-prepared environment file containing those
public genesis declarations and the other required local configuration:

```sh
docker compose --env-file <prepared-env> -f testnet/docker-compose.testnet.yml -f testnet/docker-compose.genesis.yml config --quiet
```

After the cut, fill `cut-pins.888.env.example` with the reviewed source commit,
observed genesis hash and faucet address, independently verify block-1 metadata,
then publish those values as `cut-pins.env`. The example is deliberately unusable
while placeholders remain. Do not reuse old balances, old snapshots or a 777
node-data volume for 888. Full sync is the fresh-chain default; snapshots remain
optional and must match the selected chain and genesis. Legacy 777 keeps its
snapshot requirement. The separate 888 join-guide PR stays held until the cut.
