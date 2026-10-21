# Container health watcher: owner opt-in at boot

Refs #902. `boot-heal.sh` already discovers the health-watch overlay; the watcher
now requires `COMPOSE_PROFILES=container-health-watch` (or that name in the
existing comma-separated profile list). Default, `full`, `seed` and unrelated
profiles leave it off. The boot service selector also enforces this policy:
some Compose versions list inactive services, and explicitly naming a service
in `up` would otherwise bypass its profile. Explicit `*` means all profiles.

Owner only: stage the reviewed overlay/boot source with the existing stack,
prepare the cached watcher image deliberately, verify the existing receiver
delivery configuration and then opt into the profile through the deployment's
existing reviewed profile mechanism. Boot uses `--no-build`; stage the image
locally before enabling. This source change retains the stack's pull policy.
No timer, host or stack was changed by this PR.

The watcher retains the healthy alert-receiver dependency, private network,
bounded resources, read-only root/socket mount, dropped capabilities and
no-new-privileges. The Docker socket still conveys Engine privileges even with
a read-only filesystem mount; enabling this profile accepts that existing
tradeoff. Delivery continues through the existing receiver; local tests do not
claim live notification delivery or installed boot integration.

Dropping the profile prevents future boot selection. It does not stop an
already-running watcher; the owner must use the existing reviewed stack change
procedure to stop just that service if desired. No node/attester recreation is
part of this source change.
