# Testnet oracle-attester cutover

This packet deploys the service carrier for Core4 #2464/#2746. It does not
authorize an agent to generate keys or change the live oracle set. The Core4
oracle ceremony remains owner-operated; private keys, HSM PINs, and API tokens
must never appear in this repository, shell history, CI, or a review transcript.

## Topology and stopping condition

| identity | host | service | custody |
|---|---|---|---|
| registered oracle 2 or 3 | N5 CT101 | `oracle-attester` | one existing ceremony YubiKey |
| the other of oracle 2 or 3 | workstation | `oracle-attester` | the other existing ceremony YubiKey |
| registered oracle 1 | offline | none | cold; its token also carries a standby producer key |

The owner must confirm which physical token is attached to which host before
filling either host's labels. Do not infer the mapping from this document.
Existing oracle 2 and 3 are the preferred first activation path because they
already form the registered 2-of-3 quorum and avoid oracle 1's role
co-location. An epoch-2 SoftHSM re-key is an alternative custody decision, not
a technical prerequisite for automation.

Mango is a peer, not an oracle in this cut. Quorum is live only when the chain
accepts attestations from two distinct registered public keys for a genuine
observation. Two processes or two labels backed by one key do not count.

## Phase 0 — non-mutating preflight

1. Pin the deployment tree to reviewed Core4 and infra SHAs. The running nodes
   must include Core4 #2746; an older healthy node has no pending-work route and
   cannot support this service.
2. Build without starting anything:

   ```bash
   docker compose \
     -f docker-compose.testnet.yml \
     -f docker-compose.override.yml \
     -f docker-compose.oracle-attester.yml \
     --profile attester build wrfcoin-node oracle-attester oracle-softhsm-init
   ```

3. Confirm the ordinary runtime image still starts
   `/usr/local/bin/hsm-entrypoint.sh`, while the explicit
   `oracle-attester-runtime` target starts `/usr/local/bin/oracle_attester`.
4. Render with the real host's secret environment and inspect variable names,
   mounts, image IDs, and profiles without printing values. Both attester
   services must mount only `oracle-attester-data:/app/data`; neither may mount
   `node-data` or contain a software-key variable.
   Set `WRFCOIN_ATTESTER_NWS_STATION` deliberately for each host: use the
   deployment's NWS station id (`KDLH` for the existing Duluth fleet), or the
   literal `PHYSICS_ONLY`. The sentinel is removed by the service entrypoint so
   the attester starts in its loud, capped no-reference mode; an empty or absent
   choice must make Compose refuse the render.
5. Capture node/seed/workstation/Mango height, peer count, health, running image
   ID, genesis hash, and a common-height state-root baseline before recreation.

Abort if the two quorum hosts do not agree on chain/network/genesis identity,
if the node route is absent, or if the attester overlay renders without every
required custody-inventory variable. In particular, the snapshot public key is
still owner input: do not invent it, derive it from a private key, or substitute
the snapshot signing private-key environment value. The daemon must stay off
until `WRFCOIN_ATTESTER_FORBID_SNAPSHOT_PUBKEY` contains the verified public
inventory value.

## Phase 1 — deploy the merged node API, attesters still off

Recreate the node processes in the normal coordinated testnet upgrade window,
leaving profile `attester` disabled. Prove the new running image ID, health,
height progression, peer topology, and common-height state root before moving
on. Roll back the node image if any peer diverges or block production stalls.

This phase changes no oracle key and submits no attestation. A green node is
necessary but not evidence that quorum works.

## Phase 2 — owner-only key ceremony

Follow Core4's `docs/security/ORACLE_KEY_CEREMONY.md` and
`docs/oracle-attester-deployment.md`. Agents may prepare and verify public
inputs; they do not generate, read, import, copy, or derive private material.

The owner first chooses between the existing ceremony YubiKeys and an epoch-2
SoftHSM re-key. The host-specific YubiKey overlays only provide transport; the
base overlay still requires the intended token/key labels and PIN. If SoftHSM
is chosen, use a different token label, key label, user PIN, SO-PIN, and named
volume per host. Its default posture is:

```text
WRFCOIN_ATTESTER_HSM_PROVISION=0
```

With an empty dedicated volume the SoftHSM init service must fail. During the attended
owner ceremony only, the owner may set it to `1` and start only
`oracle-softhsm-init` with profile `attester-softhsm`. That authorizes generation on that host. Return it to
`0` immediately after the token/key exists; subsequent restarts verify the
existing object and refuse to generate a replacement.

Record only the two public oracle keys and possession-proof transcript. Verify
they differ from each other and from governance, snapshot, and every producer
public key before constructing an epoch-2 registration artifact.

Do not submit a registration until the current-main route, epoch rules,
governance custody, complete absolute N=3/K=2 set, and rollback/abort boundary
have been independently reviewed. Registration changes consensus state.

## Phase 3 — register, confirm, then activate

1. Owner builds and independently verifies the governance-authorized epoch-2
   registration artifact using the current Core4 ceremony tooling.
2. If and only if re-keying was chosen, submit it once through the
   Operator-gated registration endpoint. Existing registered YubiKey identities
   require no new registration. Confirm any registration
   is mined and that every node reports the same oracle set, quorum, height, and
   state root. Stop if any peer rejects or fails to converge.
3. For SoftHSM, set `WRFCOIN_ATTESTER_HSM_PROVISION=0` on both hosts. For
   existing YubiKeys, include the matching desktop/CT101 transport overlay and
   do not start the SoftHSM profile.
4. Run one host at a time with `docker compose run`, not `up`: the service's
   normal `restart: unless-stopped` policy would otherwise turn
   `WRFCOIN_ATTESTER_ONCE=1` into an unattended restart loop. Include the base
   files and that host's YubiKey transport overlay. For CT101 execute the
   command below; on the workstation replace only the final `-f` value with
   `docker-compose.oracle-attester-yubikey.desktop.yml`:

   ```bash
   WRFCOIN_ATTESTER_ONCE=1 docker compose \
     -f docker-compose.testnet.yml \
     -f docker-compose.oracle-attester.yml \
     -f docker-compose.oracle-attester-yubikey.n5.yml \
     --profile attester run --rm --no-deps oracle-attester
   ```

   This is an activation action: if pending work exists, the cycle can submit
   a real attestation. Require successful chain-identity/custody checks and the
   expected public oracle id in logs before enabling the long-running service.
5. Start both long-running services with the `attester` profile. Keep oracle 1
   offline.

Stopping either attester is the immediate service rollback. Do not delete its
volume or rotate its key during incident response. A registration rollback is
not equivalent to stopping a container and requires a separately authorized
consensus action.

## Phase 4 — proof, not inference

Do not call the quorum live until all of these are directly observed:

- the two running services report different registered oracle ids;
- one genuine, non-synthetic Steven reveal carries both distinct attestations;
- `oracle_reward_quorum_commit_count > 0` and
  `rewards_minted_count > 0` for that contribution;
- Steven's contributor address increases `earned_balance_total` by a nonzero
  amount;
- CT101, seed, workstation, and Mango converge after the rewarded block;
- the credit survives peer replay and a planned restart;
- missing-quorum and persistent attester-cycle failures are visible to the
  operator. Until alert coverage exists, this last item is a manual watch and
  must be reported as such.

Anything less is `RUNTIME_UNVERIFIED`, even if both containers are healthy.
