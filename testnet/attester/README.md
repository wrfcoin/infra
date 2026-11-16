# Attester settings (chain 888)

`attester-888.conf` is the public, versioned copy of the settings the house attesters run with. A new
attester copies it instead of anyone reading a house container's environment. Nothing in it is secret.

- **Format:** `KEY=VALUE` lines, `#` comments, LF line endings, no quoting. Readers must ignore keys they
  do not know and must refuse a file without `WRFCOIN_ATTESTER_SETTINGS_VERSION` (a positive integer).
- **Versioning:** raise `WRFCOIN_ATTESTER_SETTINGS_VERSION` on any change. An attester application names
  the version it runs (`settings_version`, see
  `testnet/services/claim-mailbox/ATTESTER_APPLICATIONS.md`), so the owner sees who is behind.
- **Per-site keys are not in the file:** `WRFCOIN_ATTESTER_NWS_STATION` (pick the reference station
  nearest the attester) and `WRFCOIN_ATTESTER_DEM_ELEVATIONS_FILE` (a local path).

## Where it is served

`GET https://wrfcoin.com/api/attester/settings` on the funnel edge (`@public_attester_settings` in
`testnet/edge/public_onboarding.caddy`): exact path, GET only, no query, served as
`text/plain; charset=utf-8` from the file mounted read-only at `/srv/attester/attester-888.conf`
(`docker-compose.funnel-edge.yml`). It is **off by default**: the matcher needs
`ATTESTER_SETTINGS_PUBLIC=on` in the edge env (compose default `off`), a switch of its own, so
turning on the other public reads (`PUBLIC_READONLY_API`) does not publish it. On the direct-443 edge
there is no mount, so the path 404s there (fail closed).

## Changelog

| Version | Change |
|---|---|
| 1 | First public copy: the values the three house attesters ran with on 2026-11-16 |
