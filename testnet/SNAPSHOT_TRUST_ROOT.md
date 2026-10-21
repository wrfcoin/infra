# Native snapshot-sync trust root (Refs infra#1236, core4#3344)

An unset/empty WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS permits native node startup with an empty trust set;
every POST /network/snapshot-sync/ingest then refuses. Malformed public keys or non-Unicode env data are fatal.
The base Compose node/seed explicitly preserve that empty fallback. It is not a startup-fatal absence guard.

This fleet ALREADY has an owner-approved native public signer pin in testnet/cut-pins.env (infra#1117, attested9C).
The canonical testnet/scripts/render-cut-overlay.sh states that exact pin for the node. By default the cut overlay
requires only wrfcoin-node, preserving node-only bases. A separately owner-reviewed public cut pin
WRFCOIN_CUT_INCLUDE_SEED=1 requires BOTH a base defining wrfcoin-seed and a nonempty
WRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS public cut pin. The renderer refuses seed-without-pin before changing
an overlay or custody record; the seed and node then receive the same literal pinned trust. Setting only a shell
WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS does not supply the cut pin. Absent/empty trust still permits a node-only cut.
Absent/empty/0 emits no seed block; any other or duplicate selector refuses before output. Existing cut pins are
unchanged and do not opt in. The base seed keeps its explicit env/empty fallback; if an owner enables a seed,
review its native env/pin equality and final Compose precedence, or adopt the reviewed optional seed cut pin.
It reads pins as data, not shell code; an absent/empty synthetic pin renders literal empty with the refusal comment.
No live env, pin, signing key, genesis or schedule is changed. A nonempty pin is validated as comma-separated64hex;
the native runtime still performs its own ed25519 parsing/validation. No new cryptographic key authority is created.

The native9C trust pin is DISTINCT from the later dedicated join-archive key (infra#1198). Do not clear the native
allowlist while waiting for archive ceremony, and never copy a join-archive key into native ingest trust implicitly.
The earlier check-env-completeness gate still requires native env/pin set equality; run it through approved owner steps.
A mismatching owner env is a refusal, even though the final cut overlay protects the rendered node trust selection.

Because the cut writer/overlay bytes change, previously emitted custody records are stale. Follow the reviewed
scripts/CUT_OVERLAY_CUSTODY.md staging/diff/adoption procedure; retain both overlay and record, run --check,
and have CR-2/owner review the changed trust lines before any owner consumption. No in-place node recreation is
part of this source PR. r19 remains app-only and retains the node/attesters regardless of selected infra source.
Check final Compose precedence: this canonical cut overlay must actually be included after the base, and any later
owner overlay overriding native trust requires its own exact-value review. A source pin is not runtime observation.

Custody-related Scripts Tests gates (.github/workflows/scripts-tests.yml) include Snapshot trusted-signer env,
Genesis faucet cut pin, Cut-pins overlay renderer, Snapshot-signer attestation record, P2P advertised-address config,
Infra snapshot-move preflight and the discovered boot-heal-compose-custody/build-provenance suites. Re-run the
whole job, including Python suites and every discovered shell suite, after changing writer/pins/overlay bytes.
