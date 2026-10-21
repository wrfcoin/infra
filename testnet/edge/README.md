# WRFCoin public-internet edge (infra#636)

Reverse-proxy edge that lets the testnet go **public** without rebinding any
existing service to `0.0.0.0`. It is the single public entry point: it
terminates TLS (Let's Encrypt), rate-limits, and proxies to the loopback/
tailnet services over the internal Docker network.

> **Status: drafted, not deployed.** Placeholders (`WRFCOIN_PUBLIC_DOMAIN`,
> `ACME_EMAIL`) are unset by default, so nothing is exposed until an operator
> deliberately fills them in and applies the overlay. The Caddyfile is
> validated (`caddy validate`) and the compose overlay is validated
> (`docker compose config`); what remains is a human decision + live cutover.

## What it exposes (and what it does NOT)

| Public URL | → internal service | Rate limit / IP |
|---|---|---|
| `WRFCOIN_PUBLIC_DOMAIN` | frontend, plus 8 exact onboarding contracts | onboarding 30/min; claim 5/min |
| `api.WRFCOIN_PUBLIC_DOMAIN` | the same 8 exact onboarding contracts | onboarding 30/min; claim 5/min |

The backend is **not** blanket-published. The only permitted method/path pairs
are wallet nonce/login/refresh, faucet challenge/claim, station verification
and registration, and station reward progress. Every other `/api/*` path is
404; `/ws*` is also 404 before the frontend nginx can use its internal backend
proxy. Direct weather submission remains private rather than becoming a public
abuse surface.

When the overlay is enabled, it also sets the backend's `CORS_ORIGIN` to the
exact HTTPS apex origin instead of the tailnet stack's localhost default. This
does not claim to prove CSRF handling: that remains a request-level backend
auth/session verification requirement before public cutover.

**Never proxied — stay internal/tailnet:** node API `:8556`, wallet `:4000`,
governance `:8000`, IoT `:3002`, weather-earnings `:8001`, cross-chain `:3000`,
compute `:6000`, ML `:6001`, node-discovery, Grafana/
Prometheus/exporters, SoftHSM, postgres, redis. **P2P `:9000/:9001`** stays a
direct TCP bind (it isn't HTTP and doesn't go through the proxy).

Explorer and the faucet service have **no public host**. Node API `:8556`,
backend `:4001`, explorer `:8081`, and faucet `:8080` retain their loopback or
internal-only bindings; the edge is the sole public listener.

## Files

- `Caddyfile` — routing, TLS, exact API allowlist, rate limits, and terminal
  denials for all other API/WebSocket routes.
- `verify_public_exposure_boundary.py` — static fail-closed policy check. It
  proves the configured edge boundary, not an external-network probe.
- `Dockerfile.caddy` — builds Caddy with the `caddy-ratelimit` plugin (the
  vanilla image errors on `rate_limit`). Local build only — no registry push.
- `../docker-compose.edge.yml` — runs the edge, publishes 80/443, joins the
  base stack network.

## Cutover procedure (the human-gated part)

Going public is deliberate and hard to reverse. In order:

1. **Decide the domain.** Pick `WRFCOIN_PUBLIC_DOMAIN`; create DNS A/AAAA
   record for the apex and, only if a separate API hostname is needed, `api.`.
   Do not create `explorer.` or `faucet.` records.
2. **Open the firewall.** Inbound TCP **80** and **443** (and UDP 443 for
   HTTP/3) to this host. Port 80 is required for the ACME HTTP-01 challenge and
   must stay open for renewals. Do **not** open any other service port.
3. **Set the env.** In `testnet/.env.testnet`:
   ```
   WRFCOIN_PUBLIC_DOMAIN=your.domain
   ACME_EMAIL=you@your.domain
   ```
4. **Validate without exposing anything:**
   ```bash
   # Caddyfile syntax (uses the plugin image). Both edges import the shared
   # public_onboarding.caddy, so it must be mounted alongside each config.
   docker build -f testnet/edge/Dockerfile.caddy -t wrfcoin/edge-caddy:testnet-local testnet/edge
   docker run --rm -e WRFCOIN_PUBLIC_DOMAIN=your.domain -e ACME_EMAIL=you@your.domain \
     -v "$PWD/testnet/edge/Caddyfile:/etc/caddy/Caddyfile:ro" \
     -v "$PWD/testnet/edge/public_onboarding.caddy:/etc/caddy/public_onboarding.caddy:ro" \
     wrfcoin/edge-caddy:testnet-local caddy validate --config /etc/caddy/Caddyfile
   docker run --rm \
     -v "$PWD/testnet/edge/Caddyfile.funnel:/etc/caddy/Caddyfile:ro" \
     -v "$PWD/testnet/edge/public_onboarding.caddy:/etc/caddy/public_onboarding.caddy:ro" \
     wrfcoin/edge-caddy:testnet-local caddy validate --config /etc/caddy/Caddyfile

   python3 testnet/edge/verify_public_exposure_boundary.py
   python3 testnet/edge/verify_public_exposure_boundary.py --self-test  # RED controls
   python3 testnet/edge/verify_public_exposure_runtime.py               # both edges + RED control

   # Compose merge + confirm ONLY the edge (80/443) + P2P (9000/9001) are public
   docker compose -f testnet/docker-compose.testnet.yml -f testnet/docker-compose.edge.yml config
   ```
5. **Dry-run certs first (recommended).** Uncomment the `acme_ca` staging line
   in the `Caddyfile` global block, bring the edge up, confirm DNS + challenge
   work end to end (you'll get untrusted staging certs), then re-comment it and
   restart so Caddy fetches real certs. This avoids burning Let's Encrypt
   production rate limits on a misconfiguration.
6. **Bring it up as an overlay on the running stack:**
   ```bash
   docker compose \
     -f testnet/docker-compose.testnet.yml \
     -f testnet/docker-compose.edge.yml \
     up -d --build edge
   ```
7. **Verify from outside the tailnet:** `curl -I https://your.domain` (200 +
   valid cert), confirm unsupported API and `/ws` paths are 404, make a sixth
   faucet-claim request within one minute and observe 429, then prove direct
   `:4001`, `:8081`, `:8080`, and `:8556` are unreachable. This PR does not
   substitute its static check for that external rejection proof.

## Rollback

`docker compose -f testnet/docker-compose.testnet.yml -f testnet/docker-compose.edge.yml stop edge`
(then close 80/443 at the firewall). The base services were never rebound, so
the stack returns to tailnet-only with the edge stopped. Issued certs persist
in the `edge-caddy-data` volume for the next bring-up.

## Notes / tuning

- **Rate limits** (`events`/`window` per zone in the Caddyfile) are starting
  points — tune against observed load. `caddy-ratelimit` is a distributed-
  capable in-memory limiter; a single edge instance is fine for one N5 host.
- **Monitoring stays private.** Grafana/Prometheus are intentionally not on the
  edge; reach them over tailnet. Don't add them to the Caddyfile without at
  least basic-auth + a strict limit.
- Supersedes the "testers reach the testnet over Tailscale only" language in
  `testnet/README.md` once the edge is live. `infra#598` (internal API gateway)
  is a different component; this is the public TLS edge its scope didn't cover.
