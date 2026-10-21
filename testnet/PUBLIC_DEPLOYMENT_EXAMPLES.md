# Public deployment overlay examples

These optional overlays preserve the service wiring of the internal local-path
and pcscd configurations without carrying installation paths or device inventory.
Internal overlays remain in the private archive. These examples do not provision
keys, grant a producer seat, configure peer access or authorize a deployment.

| Public file | Purpose | Required installation variables |
|---|---|---|
| [docker-compose.local-paths.example.yml](docker-compose.local-paths.example.yml) | Source build contexts and named data volumes | `WRFCOIN_ROOT` |
| [docker-compose.yubikey.pcsc.example.yml](docker-compose.yubikey.pcsc.example.yml) | Node signer through a host pcscd socket | `WRFCOIN_PCSC_SOCKET_DIR`, `WRFCOIN_HSM_TOKEN_LABEL`, `WRFCOIN_HSM_PIN` |
| [docker-compose.oracle-attester-yubikey.pcsc.example.yml](docker-compose.oracle-attester-yubikey.pcsc.example.yml) | Attester transport through pcscd | `WRFCOIN_PCSC_SOCKET_DIR`; signer inputs required by the base attester overlay |

`WRFCOIN_ROOT` is an absolute directory containing sibling `core4`, `backend`,
`frontend` and `infra` source checkouts. `WRFCOIN_PCSC_SOCKET_DIR` is the host
pcscd directory made accessible to this deployment. Neither has a default.
The node example retains distinct snapshot and producer key labels and retains
separate seed SoftHSM settings. The operator must verify actual key roles and
access; the example is not custody evidence.

Supply secrets through the operator's existing configuration mechanism. Never
commit populated environment files, PINs or tokens. The base Compose files have
additional required settings; these overlays do not replace them.

From the repository root, a configuration-only render has this shape:

```bash
docker compose --env-file /absolute/operator-state/testnet.env \
  -f testnet/docker-compose.testnet.yml \
  -f testnet/docker-compose.override.yml \
  -f testnet/docker-compose.local-paths.example.yml config --quiet
```

Add the node pcscd example only for a provisioned hardware signer. For the
attester, layer its pcscd example after
[docker-compose.oracle-attester.yml](docker-compose.oracle-attester.yml).
Compose must support the `!reset` tag used by the existing overlays.

A successful render proves only configuration syntax and required inputs.
Before deployment, obtain bootstrap peer addresses, trusted signer pins,
release pins and an approved operating procedure from the testnet operator.
The public snapshot still needs a review of retained base configuration and
operational scripts; these examples alone are not publication clearance.

Offline example checks use an isolated synthetic base and an empty environment
file; they contact no Docker daemon or node. They verify missing-input refusal
and resulting service wiring, not the full deployment stack.
