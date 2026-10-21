# WRFCoin Testnet Gateway/API Onboarding

Use this guide for household weather contributors and other friends-and-family devices that should
submit weather data without running the full WRFCoin node stack locally.

If you are bringing up a peer operator node, use
[`core4/docs/TESTNET_OPERATOR_GUIDE_v3.md`](https://github.com/wrfcoin/core4/blob/main/docs/TESTNET_OPERATOR_GUIDE_v3.md)
(canonical; `TESTNET_OPERATOR_GUIDE.md` in this repo is retired) and
[`GETTING_STARTED.md`](GETTING_STARTED.md) instead.

---

## What This Path Is For

The short-term rollout keeps device enrollment behind a managed gateway or API bridge. That keeps
family devices out of the `postgres` + `redis` + `wrfcoin-node` maintenance loop while the peer
network is still stabilizing.

Supported contributor device families include:

- Ambient Weather
- Ecowitt
- AcuRite
- Similar home weather stations that can post through a local bridge or vendor integration

## Responsibility Split

| Layer | Responsibility |
|-------|----------------|
| Gateway | Device enrollment, station ownership checks, payload normalization, and rate limiting |
| Backend auth | Wallet identity, JWT issuance and refresh, and contributor account binding |
| Node | Peer discovery, consensus, and block propagation |

Use the gateway to keep the device and station relationship explicit. The backend should know which
wallet owns the contributor account, and the gateway should reject submissions from devices that
have not been registered to that station.

## Recommended Flow

1. Register the station in the gateway and confirm the owner.
2. Bind the contributor's wallet identity in the backend auth flow.
3. Issue a JWT for the contributor session.
4. Point the device, collector, or local bridge at the gateway/API endpoint.
5. Verify the gateway forwards normalized submissions to the backend without requiring local
   `postgres`, `redis`, or `wrfcoin-node` services.

## Operator Boundaries

- Do not ask each household to forward TCP `9000`.
- Do not require contributors to manage Docker or compose files on the family machine.
- Do not turn a contributor station into a peer operator until there is a separate reason to do so.
- Move to the full node operator guide only if that device later graduates into a real peer role.

## Handoff Notes

When you hand this path to a contributor, give them:

- The gateway/API URL they should target
- The wallet address that will own the station
- The station ID used for ownership tracking
- The support contact for re-issuing a JWT or moving the station to a new device

If the contributor later needs a direct node path, move them over to the peer operator docs rather
than expanding this onboarding flow into a full node installation guide.
