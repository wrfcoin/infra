#!/usr/bin/env python3
"""Fail-closed checks for infra#658's public onboarding edge.

The allowlist lives in public_onboarding.caddy (infra#657), shared by BOTH
public edges: Caddyfile (direct 443) and Caddyfile.funnel (loopback :8444
behind Tailscale Funnel). This verifier pins the snippet contents AND that
every edge actually imports it — a boundary nobody imports protects nothing.
"""

from __future__ import annotations

import re
import shutil
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

# Files verify() reads, relative to a tree root (parametrized for --self-test).
RELATIVE_FILES = (
    "testnet/edge/Caddyfile",
    "testnet/edge/Caddyfile.funnel",
    "testnet/edge/public_onboarding.caddy",
    "testnet/edge/route-ledger.yml",
    "testnet/nginx-frontend.conf",
    "testnet/docker-compose.edge.yml",
    "testnet/docker-compose.funnel-edge.yml",
)

# Every approved route pins THREE things: the method, the matcher directive, and
# the exact handler directives. The handler is part of the approval, not an
# implementation detail — a route approved to reach the backend and a route
# approved to serve files are different exposures, and swapping one for the
# other must fail this gate.
BACKEND = ("reverse_proxy wrfcoin-testnet-backend:4001",)
# Station owner-action relay (infra#1095): the same backend proxy, behind an 8 KiB edge body cap.
BACKEND_CAPPED_8KIB = ("request_body {", "max_size 8KiB", "}") + BACKEND

EXPECTED = {
    "wallet_nonce": ("GET", "path_regexp ^/api/auth/nonce/0x[0-9A-Fa-f]{40}$", BACKEND),
    "wallet_login": ("POST", "path /api/auth/wallet-login", BACKEND),
    "wallet_refresh": ("POST", "path /api/auth/refresh", BACKEND),
    "faucet_challenge": ("POST", "path /api/onboarding/faucet/challenge", BACKEND),
    "faucet_claim": ("POST", "path /api/onboarding/faucet/claim", BACKEND),
    # Self-serve bond grant (spec 2026-10-23, section 2): a ~1 KiB signed request, capped at 8 KiB at the edge.
    "faucet_bond_grant": ("POST", "path /api/faucet/bond-grant", BACKEND_CAPPED_8KIB),
    "faucet_bond_grants": ("GET", "path /api/faucet/bond-grants", BACKEND),
    "station_verify": ("POST", "path /api/weather/stations/verify-key", BACKEND),
    "station_register": ("POST", "path /api/weather/stations", BACKEND),
    "station_reward_progress": (
        "GET",
        "path_regexp ^/api/weather/stations/[A-Za-z0-9_-]{1,64}/reward-progress$",
        BACKEND,
    ),
    # Owner ruling 2026-10-02 (frontend#463, W28): the signed-in wallet's OWN phone-station status.
    # weather-routes.js GET /stations/mobile -> getMobileStationStatus(req.user.address): 401 without a
    # wallet session, 404 NOT_REGISTERED, else only the caller's row (station id, status, 0.1-degree cell,
    # timestamps). Exact path, GET only, no query (QUERY_LOCK); POST /stations/mobile (phone registration)
    # and /stations/mobile/challenge stay off the public edge. Counted by the `onboarding` rate zone.
    "station_mobile_status": ("GET", "path /api/weather/stations/mobile", BACKEND),
    # infra#886 — APPROVED PUBLIC EXPOSURE, owner ruling 2026-08-31.
    #
    # The snapshot-join path (infra#843, feat(#587)) exists so a NEW node can
    # fetch the join manifest and snapshot WITHOUT credentials. Unauthenticated
    # public reachability is the feature, not a leak. It shipped 2026-08-16 and
    # was simply never added to this pin, which is why this file has been RED on
    # main ever since — the route was correct and the approval record was not.
    #
    # This and public_status are the file-serving entries; all other handlers
    # reach the backend. Join artifacts come from /srv/join, populated by
    # testnet/publish-join-snapshot.sh into the volume the funnel edge mounts.
    # The handler is pinned here exactly, so widening it (directory listing, a
    # different root, dropping strip_prefix) fails this gate rather than
    # passing as "already approved".
    #
    # Scope of the approval: the MATCHER is two exact paths, so only those two
    # reach the file_server. `root * /srv/join` is the file-serving root, not
    # the exposed surface — an unrelated file dropped into /srv/join is not
    # reachable unless a matcher change also lands, which this gate would catch.
    "join_artifacts": (
        "GET",
        "path /join/manifest.json /join/snapshot.tar.gz",
        ("root * /srv/join", "uri strip_prefix /join", "file_server"),
    ),
    # infra#976 — APPROVED PUBLIC EXPOSURE, owner ruling 2026-09-21, recorded
    # at https://github.com/wrfcoin/infra/pull/998#issuecomment-5769368355
    # (four redacted fields: status, checked_at, consecutive_failures,
    # chain_id; closed schema testnet/edge/status.schema.json). This publishes
    # only the redacted uptime artifact produced by probe_public_uptime.sh.
    # The MATCHER is one exact GET path, so only /status.json reaches the file
    # server; an unrelated file dropped into /srv/status remains unreachable
    # unless a matcher change also lands, which this gate would catch.
    "public_status": (
        "GET",
        "path /status.json",
        ("root * /srv/status", "file_server"),
    ),
    # sonnet-r1 (docs/plans/2026-09-09-sonnet-r1.md) — read-only public viewer
    # surface. GET-only, safety-audited: no per-address balances/positions, no
    # PII. Explicitly excluded from this expansion (see the route ledger doc):
    # GET /api/weather/stations remains excluded even after backend#1113 stripped
    # owner/reward fields: the anonymous projection still serializes exact
    # coordinates. Browser-side rounding cannot protect the edge response.
    #
    # Also excluded: GET /api/blockchain/blocks/{height} (single-block detail).
    # Cross-provider review (Luna, Codex) caught that the backend handler
    # passes through raw block `transactions` and `metadata`, and core4 embeds
    # per-address `reward_entries` in that metadata for reward-bearing blocks
    # — the same #1841/#1113 hazard class. Do not re-add a `chain_block_detail`
    # entry here without a safe-projection fix in the backend AND an explicit
    # owner decision.
    "chain_status": ("GET", "path /api/blockchain/status", BACKEND),
    "chain_blocks": ("GET", "path /api/blockchain/blocks", BACKEND),
    "chain_transactions": ("GET", "path /api/blockchain/transactions", BACKEND),
    "chain_transaction_detail": (
        "GET",
        "path_regexp ^/api/blockchain/transactions/(0x)?[0-9A-Fa-f]{64}$",
        BACKEND,
    ),
    "chain_validators": ("GET", "path /api/blockchain/validators", BACKEND),
    "chain_stats": ("GET", "path /api/blockchain/stats", BACKEND),
    "weather_coverage_zones": ("GET", "path /api/weather/coverage-zones", BACKEND),
    # infra#968 / infra#992 — public build-freshness probe. Two EXACT paths,
    # GET only (HEAD and every other method fall through to the /api/* 404),
    # no prefix: /api/builds and /api/build/x stay refused. Backend source
    # (server/routes/capabilities-routes.ts @ backend 256a56cf) audited before
    # admission: /api/build returns only {available, revision (40-hex git SHA),
    # created (ISO time), source} or a fixed 503 error; /api/capabilities
    # returns the static feature inventory (fixed reason strings, env var
    # NAMES but never values), readiness classes, version and build profile.
    # The mounted router uses the default empty evidence provider, so no
    # observation source/detail or provider error text (which could carry an
    # internal URL) is ever serialized. No tokens, hostnames, IPs or env dumps.
    # Re-audit before widening either handler or wiring an evidence provider.
    "public_build": ("GET", "path /api/build", BACKEND),
    "public_capabilities": ("GET", "path /api/capabilities", BACKEND),
    # infra#983 — Stage 1.5 read-only station reads, owner ruling 2026-09-26:
    # build them fully, ship them OFF. Both are GATED (see GATED below): the
    # matcher also requires PUBLIC_READONLY_API=on in the edge container, and
    # both compose overlays default it to `off`, so the deployed edge keeps
    # 404ing them. They stay off until the backend's anonymous 0.01-degree
    # coordinate projection (backend#1222/#1220) is deployed; GET
    # /api/weather/stations serializes exact home coordinates before that, and
    # these handlers proxy the backend response unchanged. The detail regex is
    # anchored to exactly three leaves (station-detail-routes.ts, mounted at
    # enhanced_unified_api_optimized.ts:262). `earnings` (backend#1232) is its OWN
    # gated matcher below because it admits no query string; every other sibling
    # stays 404 even with the gate on.
    "public_readonly_stations": ("GET", "path /api/weather/stations", BACKEND),
    "public_readonly_station_detail": (
        "GET",
        "path_regexp ^/api/stations/[A-Za-z0-9_-]{1,64}/(observations|quality|submissions)$",
        BACKEND,
    ),
    "public_readonly_station_earnings": (
        "GET",
        "path_regexp ^/api/stations/[A-Za-z0-9_-]{1,64}/earnings$",
        BACKEND,
    ),
    # Owner ruling 2026-10-06 (backend#1456, frontend#535): the weather leaderboard is
    # public read-only, behind the same gate and with an exact-grammar query lock.
    "public_readonly_weather_leaderboard": ("GET", "path_regexp ^/api/weather/leaderboard$", BACKEND),
    # backend#1481 merged contract: public role amounts, opaque profiles only.
    "public_readonly_earnings_leaderboard": ("GET", "path_regexp ^/api/earnings/leaderboard$", BACKEND),
    "public_readonly_operator_profile": ("GET", "path_regexp ^/api/operators/c_[0-9a-f]{24}/profile$", BACKEND),
    # Public forecaster pages (frontend publicReadonlyApi.ts, backend forecasters-routes.ts):
    # the list with the frontend's exact period/limit grammar, the detail by opaque c_ key only.
    "public_readonly_forecasters": ("GET", "path_regexp ^/api/forecasters$", BACKEND),
    "public_readonly_forecaster_profile": ("GET", "path_regexp ^/api/forecasters/c_[0-9a-f]{24}$", BACKEND),
    # Mobile explorer summary (explorer-routes.js): one cached aggregate, exact path, no query.
    "public_readonly_explorer_summary": ("GET", "path /api/explorer/summary", BACKEND),
    # Producers and bonded nodes page (network-nodes-routes.ts): one cached snapshot, exact path, no query.
    "public_readonly_network_nodes": ("GET", "path /api/network/nodes", BACKEND),
    # Proof card for one station reading (backend#229): commit id only, optional height hint.
    "public_readonly_proof_card": ("GET", "path_regexp ^/api/proofs/[0-9a-f]{64}$", BACKEND),
    # Station calibration certificate status (core4#388/#435): public alias only, no query; the
    # signed submit/revoke POSTs stay off the edge.
    "public_readonly_calibration_certificate": (
        "GET", "path_regexp ^/api/calibration-certificates/station/st_[0-9a-f]{12}$", BACKEND,
    ),
    # Station theft protection (core4#3345/#3347, infra#1095). Both address a station by its public
    # ALIAS only (st_ + 12 lowercase hex), with no query string. The relay is a POST (the backend
    # authenticates per kind and never signs or alters the tx) behind an 8 KiB body cap and its own
    # tight rate zone; the ownership read is GET, gated like the other station reads.
    "station_owner_actions": ("POST", "path_regexp ^/api/stations/st_[0-9a-f]{12}/owner-actions$", BACKEND_CAPPED_8KIB),
    "public_readonly_station_ownership": ("GET", "path_regexp ^/api/stations/st_[0-9a-f]{12}/ownership$", BACKEND),
    # S1 + S2 website-parity reads (all gated by PUBLIC_READONLY_API, GET only, exact paths, locked query).
    # Own-wallet reads: wallet-routes.js requireAuth (l.29) + requireOwnAddress; the edge also demands a Bearer header.
    "public_wallet_send": ("POST", "path /api/wallet/send", ("request_body {", "max_size 4096", "}", *BACKEND)),
    "public_wallet_send_nonce": ("GET", "path_regexp ^/api/wallet/0x[0-9a-f]{40}/nonce$", BACKEND),
    # backend#21 self-proving passkey transfer: NO bearer (the assertion is the authorization), exact paths, 32 KiB cap.
    "public_wallet_send_passkey": (
        "POST",
        "path_regexp ^/api/wallet/send-passkey$",
        ("request_body {", "max_size 32768", "}", *BACKEND),
    ),
    "public_wallet_send_passkey_nonce": ("GET", "path_regexp ^/api/wallet/send-passkey/nonce/0x[0-9a-f]{40}$", BACKEND),
    # backend#30 public balance read for the passkey wallet: no bearer, GET, exact path, no query.
    "public_balance_read": ("GET", "path_regexp ^/api/public/balance/0x[0-9a-fA-F]{40}$", BACKEND),
    # Owner ruling 2026-11-01: bring-your-own-key Wolfram reading check. POST, exact path, JSON only,
    # no query, 2 KiB body cap, its own rate zone; the caller's AppID rides in the body.
    "wolfram_reading_check": (
        "POST",
        "path /api/integrations/wolfram/reading-check",
        ("request_body {", "max_size 2KiB", "}", *BACKEND),
    ),
    "public_readonly_wallet_info": ("GET", "path_regexp ^/api/wallet/0x[0-9A-Fa-f]{40}$", BACKEND),
    "public_readonly_wallet_transactions": ("GET", "path_regexp ^/api/wallet/0x[0-9A-Fa-f]{40}/transactions$", BACKEND),
    # governance-routes.ts l.231 / l.275 (PROPOSAL_ID_RE l.273) / l.564.
    "public_readonly_governance_proposals": ("GET", "path /api/governance/proposals", BACKEND),
    "public_readonly_governance_proposal": ("GET", "path_regexp ^/api/governance/proposals/[A-Za-z0-9_-]{1,128}$", BACKEND),
    "public_readonly_governance_treasury": ("GET", "path /api/governance/treasury", BACKEND),
    # weather-routes.js l.188 / l.193: coordinates at exactly one decimal (the app's 0.1-degree cell).
    "public_readonly_weather_current": (
        "GET",
        r"path_regexp ^/api/weather/current/-?[0-9]{1,2}\.[0-9],-?[0-9]{1,3}\.[0-9]$",
        BACKEND,
    ),
    "public_readonly_weather_forecast": (
        "GET",
        r"path_regexp ^/api/weather/forecast/-?[0-9]{1,2}\.[0-9],-?[0-9]{1,3}\.[0-9]$",
        BACKEND,
    ),
    # Weekly forecast competition (backend#251): the list, this week, or one ISO week; no query.
    "public_readonly_competitions": (
        "GET", "path_regexp ^/api/competitions(/(current|[0-9]{4}-W(0[1-9]|[1-4][0-9]|5[0-3])))?$", BACKEND,
    ),
    # Payout notifications (backend#389): no email, no user URL. Config is public; subscription writes and
    # reads need the wallet-login Bearer; unsubscribe is by possession of the endpoint or topic.
    "public_notifications_config": ("GET", "path /api/notifications/config", BACKEND),
    "public_notifications_subscribe": ("POST", "path /api/notifications/subscriptions", ("request_body {", "max_size 4096", "}", *BACKEND)),
    "public_notifications_list": ("GET", "path_regexp ^/api/notifications/subscriptions/0x[0-9a-fA-F]{40}$", BACKEND),
    "public_notifications_delete": ("DELETE", "path_regexp ^/api/notifications/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", BACKEND),
    "public_notifications_test": (
        "POST", "path_regexp ^/api/notifications/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/test$", ("request_body {", "max_size 1024", "}", *BACKEND),
    ),
    "public_notifications_unsubscribe": ("POST", "path /api/notifications/unsubscribe", ("request_body {", "max_size 4096", "}", *BACKEND)),
}

# infra#983: routes admitted ONLY while the edge container's environment
# carries PUBLIC_READONLY_API=on exactly (Caddy's vars matcher compares the
# resolved placeholder byte-for-byte: unset, `ON`, `true` and ` on` do not
# match — measured on the pinned image). Every gated route carries the same
# third matcher directive, and no ungated route may carry it.
READONLY_GATE = "vars {env.PUBLIC_READONLY_API} on"
GATED = frozenset({
    "public_wallet_send",
    "public_wallet_send_nonce",
    "public_wallet_send_passkey",
    "public_wallet_send_passkey_nonce",
    "public_balance_read",
    "wolfram_reading_check",
    "public_readonly_stations",
    "public_readonly_station_detail",
    "public_readonly_station_earnings",
    "public_readonly_weather_leaderboard",
    "public_readonly_earnings_leaderboard",
    "public_readonly_operator_profile",
    "public_readonly_forecasters",
    "public_readonly_forecaster_profile",
    "public_readonly_explorer_summary",
    "public_readonly_proof_card",
    "public_readonly_network_nodes",
    "public_readonly_competitions",
    "public_notifications_config",
    "public_notifications_subscribe",
    "public_notifications_list",
    "public_notifications_delete",
    "public_notifications_test",
    "public_notifications_unsubscribe",
    "public_readonly_calibration_certificate",
    "public_readonly_station_ownership",
    "public_readonly_wallet_info",
    "public_readonly_wallet_transactions",
    "public_readonly_governance_proposals",
    "public_readonly_governance_proposal",
    "public_readonly_governance_treasury",
    "public_readonly_weather_current",
    "public_readonly_weather_forecast",
})
# The own-wallet reads are only proxied when the request carries a Bearer credential
# (authMiddleware.js:40 accepts only the `Bearer ` prefix). Directive is last in the matcher.
BEARER_LOCK = {
    "public_wallet_send": 'header Authorization "Bearer *"',
    "public_wallet_send_nonce": 'header Authorization "Bearer *"',
    "public_readonly_wallet_info": 'header Authorization "Bearer *"',
    "public_readonly_wallet_transactions": 'header Authorization "Bearer *"',
    "public_notifications_subscribe": 'header Authorization "Bearer *"',
    "public_notifications_list": 'header Authorization "Bearer *"',
    "public_notifications_delete": 'header Authorization "Bearer *"',
    "public_notifications_test": 'header Authorization "Bearer *"',
}
# JSON-body writes: the matcher also pins Content-Type (last directive).
JSON_BODY = frozenset({"public_wallet_send", "public_wallet_send_passkey", "wolfram_reading_check", "public_notifications_subscribe", "public_notifications_unsubscribe"})
# The ONLY query the frontend sends (useWeatherLeaderboard / GlobalLeaderboard): metric, period, limit,
# in that order, no geo (the backend 400s earnings+geo and anonymous geo is never admitted), limit 1..30.
LEADERBOARD_QUERY_LOCK = (
    "expression `{query}.matches('^metric=(earnings|submissions|quality_score|streak)"
    "&period=(7d|30d|all)&limit=([1-9]|[12][0-9]|30)$')`"
)
EARNINGS_QUERY_LOCK = (
    "expression `{query}.matches('^role=(contribution|attester|producer|node|forecast)"
    "&period=(all|7d|30d)&limit=([1-9]|[12][0-9]|30)$')`"
)
FORECASTERS_QUERY_LOCK = (
    "expression `{query}.matches('^period=(7d|30d|all)&limit=([1-9]|[1-9][0-9]|100)$')`"
)
PROOF_CARD_QUERY_LOCK = "expression `{query} == \"\" || {query}.matches('^h=[1-9][0-9]{0,11}$')`"
# Query lock (stage15 readiness): every gated read also admits only the exact
# query string the Stage 1.5 build sends. The station list takes none, because
# `?lat=&lng=` (or `lat[]=`) switches weather-routes.js to the outbound NOAA
# nearby-station lookup; the detail reads take none or exactly `limit=1`, so
# `/submissions?limit=100` cannot fan out to 100 core4 reads per request.
READONLY_QUERY_LOCK = {
    "public_wallet_send": 'expression `{query} == ""`',
    "public_wallet_send_nonce": 'expression `{query} == ""`',
    "public_wallet_send_passkey": 'expression `{query} == ""`',
    "public_wallet_send_passkey_nonce": 'expression `{query} == ""`',
    "public_balance_read": 'expression `{query} == ""`',
    "wolfram_reading_check": 'expression `{query} == ""`',
    "public_readonly_stations": 'expression `{query} == ""`',
    "public_readonly_station_detail": 'expression `{query} == "" || {query} == "limit=1"`',
    # earnings takes NO query (the frontend sends none; `limit` sizes a core4 read fan-out).
    "public_readonly_station_earnings": 'expression `{query} == ""`',
    "public_readonly_weather_leaderboard": LEADERBOARD_QUERY_LOCK,
    "public_readonly_earnings_leaderboard": EARNINGS_QUERY_LOCK,
    "public_readonly_operator_profile": 'expression `{query} == ""`',
    # frontend forecastersPath(): period then limit, limit clamped to 1..100 (backend MAX_LIMIT).
    "public_readonly_forecasters": FORECASTERS_QUERY_LOCK,
    "public_readonly_forecaster_profile": 'expression `{query} == ""`',
    "public_readonly_explorer_summary": 'expression `{query} == ""`',
    # frontend proofCardPath(): no query, or exactly the share link's block height hint.
    "public_readonly_proof_card": PROOF_CARD_QUERY_LOCK,
    "public_readonly_network_nodes": 'expression `{query} == ""`',
    # frontend COMPETITIONS_PATH / COMPETITION_CURRENT_PATH / competitionWeekPath(): never a query.
    "public_readonly_competitions": 'expression `{query} == ""`',
    "public_notifications_config": 'expression `{query} == ""`',
    "public_notifications_subscribe": 'expression `{query} == ""`',
    "public_notifications_list": 'expression `{query} == ""`',
    "public_notifications_delete": 'expression `{query} == ""`',
    "public_notifications_test": 'expression `{query} == ""`',
    "public_notifications_unsubscribe": 'expression `{query} == ""`',
    "public_readonly_calibration_certificate": 'expression `{query} == ""`',
    "public_readonly_station_ownership": 'expression `{query} == ""`',
    "public_readonly_wallet_info": 'expression `{query} == ""`',
    # mobile walletTransactions shape: limit then offset; backend clamps 1..100, edge admits 1..50.
    "public_readonly_wallet_transactions": (
        "expression `{query}.matches('^limit=([1-9]|[1-4][0-9]|50)&offset=[0-9]{1,6}$')`"
    ),
    "public_readonly_governance_proposals": (
        "expression `{query} == \"\" || {query}.matches('^limit=([1-9]|[1-9][0-9]|100)&offset=[0-9]{1,6}$')`"
    ),
    "public_readonly_governance_proposal": 'expression `{query} == ""`',
    "public_readonly_governance_treasury": 'expression `{query} == ""`',
    "public_readonly_weather_current": 'expression `{query} == ""`',
    # mobile weatherForecastHourlyQuery / weatherForecastDailyQuery, exactly.
    "public_readonly_weather_forecast": 'expression `{query} == "type=hourly&days=1" || {query} == "days=14"`',
}
# Ungated routes that are approved with no query string at all (owner ruling 2026-10-02, frontend#463).
QUERY_LOCK = {
    "station_mobile_status": 'expression `{query} == ""`',
    "station_owner_actions": 'expression `{query} == ""`',
}
# Both edge overlays must pass the toggle with an `off` default; a missing
# line would also be off (unset), but a default of `on` would turn the reads
# on at the next recreate without anyone choosing to.
READONLY_COMPOSE_LINE = "PUBLIC_READONLY_API: ${PUBLIC_READONLY_API:-off}"


# infra#1051 — the non-canonical-path guard. Caddy matches a CLEANED path but
# reverse_proxy forwards the RAW URI and Express does not resolve dot segments,
# so without this guard `/api/node-control/x/../../weather/coverage-zones`
# matches an allowlisted read and lands in an unlisted backend router. It is
# pinned byte-exact AND positionally: it must be the first matcher/handler in
# (public_onboarding_api), ahead of every allowlisted route.
NONCANONICAL_MATCHER = (
    "vars_regexp {http.request.orig_uri} "
    r"`^(?:[^/]|[^?]*(?:#|/\.\.?(?:[/?]|$)|(?i:%(?:2e|2f|5c|25|00))|\\|//))`"
)
NONCANONICAL_HANDLER = ('respond "Bad request" 400',)

# Frontend CSP (infra#548; owner ruling 2026-09-27 for the Stage 1.5 map). The
# SPA's nginx sends it on the server block AND on the static-asset location
# (add_header does not inherit there), so there are exactly two lines, and they
# must be byte-identical and equal to this. The one third-party origin anywhere
# in it is the /map basemap tile host, in img-src only; https only, no wildcard.
FRONTEND_CSP = (
    "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
    "font-src 'self' data:; img-src 'self' data: blob: https://tile.openstreetmap.org; "
    "connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; "
    "object-src 'none'"
)
FRONTEND_CSP_LINE = f'add_header Content-Security-Policy "{FRONTEND_CSP}" always;'


def block(source: str, marker: str) -> str:
    match = re.search(rf"(?m)^(?!\s*#)\s*{re.escape(marker)}\s*(?=\{{)", source)
    if match is None:
        raise AssertionError(f"missing block marker: {marker}")
    start = match.start()
    opening = source.find("{", start)
    if opening < 0:
        raise AssertionError(f"missing opening brace: {marker}")
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1 : index]
    raise AssertionError(f"unterminated block: {marker}")


def directives(source: str) -> list[str]:
    return [line.strip() for line in source.splitlines() if line.strip() and not line.lstrip().startswith("#")]


def verify(root: Path = ROOT) -> None:
    caddy = (root / "testnet" / "edge" / "Caddyfile").read_text(encoding="utf-8")
    funnel = (root / "testnet" / "edge" / "Caddyfile.funnel").read_text(encoding="utf-8")
    snippets = (root / "testnet" / "edge" / "public_onboarding.caddy").read_text(encoding="utf-8")
    ledger = (root / "testnet" / "edge" / "route-ledger.yml").read_text(encoding="utf-8")
    nginx = (root / "testnet" / "nginx-frontend.conf").read_text(encoding="utf-8")
    edge_compose = (root / "testnet" / "docker-compose.edge.yml").read_text(encoding="utf-8")
    funnel_compose = (root / "testnet" / "docker-compose.funnel-edge.yml").read_text(encoding="utf-8")
    policy = block(snippets, "(public_onboarding_api)")

    names = set(re.findall(r"(?m)^\s+@([a-z_]+)\s*\{", policy))
    if names != set(EXPECTED) | {"noncanonical_uri"}:
        raise AssertionError(f"public matcher set drifted: {sorted(names)}")

    # infra#1051: non-canonical raw paths are refused before any route matches.
    if directives(block(policy, "@noncanonical_uri")) != [NONCANONICAL_MATCHER]:
        raise AssertionError("@noncanonical_uri is not the exact approved raw-path guard")
    if directives(block(policy, "handle @noncanonical_uri")) != list(NONCANONICAL_HANDLER):
        raise AssertionError("@noncanonical_uri must terminate with a 400")
    policy_lines = directives(policy)
    if policy_lines[:1] != ["@noncanonical_uri {"] or policy_lines[2:4] != ["}", "handle @noncanonical_uri {"]:
        raise AssertionError("@noncanonical_uri guard must be the FIRST matcher and handler in the allowlist")
    for name, expected in EXPECTED.items():
        approved = [f"method {expected[0]}", expected[1]] + (
            [READONLY_GATE, READONLY_QUERY_LOCK[name]] if name in GATED else []
        ) + ([QUERY_LOCK[name]] if name in QUERY_LOCK else []) + ([BEARER_LOCK[name]] if name in BEARER_LOCK else [])
        if name in JSON_BODY:
            approved += ['header Content-Type application/json']
        if directives(block(policy, f"@{name}")) != approved:
            raise AssertionError(
                f"@{name} is not the exact approved method/path"
                + (" + PUBLIC_READONLY_API gate + query lock" if name in GATED else "")
            )
        if directives(block(policy, f"handle @{name}")) != list(expected[2]):
            raise AssertionError(f"@{name} has a handler other than its approved one")

    for denied in ("handle /api/*", "handle /ws*"):
        if directives(block(policy, denied)) != ['respond "Not found" 404']:
            raise AssertionError(f"{denied} must terminate with 404")

    for ledger_entry in (
        "transaction list/detail",
        "validator list",
        "blockchain stats",
        "GET /api/weather/stations stays OFF",
        "build stamp and capability inventory",
        "PUBLIC_READONLY_API",
        "station owner-action relay",
    ):
        if ledger_entry not in ledger:
            raise AssertionError(f"route ledger is missing: {ledger_entry}")

    for label, text in (("Caddyfile", caddy), ("Caddyfile.funnel", funnel), ("snippets", snippets)):
        if "explorer.{$WRFCOIN_PUBLIC_DOMAIN}" in text or "faucet.{$WRFCOIN_PUBLIC_DOMAIN}" in text:
            raise AssertionError(f"explorer or faucet service has a public host ({label})")
        if "reverse_proxy wrfcoin-testnet-explorer:8081" in text or "reverse_proxy wrfcoin-testnet-faucet:8080" in text:
            raise AssertionError(f"a non-frontend service is reachable at the edge ({label})")

    # Every backend proxy must sit inside the shared allowlist — the per-edge
    # files may only proxy the frontend fallback. The expected count is derived
    # from the approved handlers, not from len(EXPECTED): infra#886 added
    # join_artifacts, which serves files instead of proxying, so an entry count
    # would now overcount by one and this check would fail on a correct tree.
    approved_backend_routes = sum(1 for entry in EXPECTED.values() if tuple(entry[2][-1:]) == BACKEND)
    if snippets.count("reverse_proxy wrfcoin-testnet-backend:4001") != approved_backend_routes:
        raise AssertionError("unexpected generic backend proxy in the shared allowlist")
    for label, text in (("Caddyfile", caddy), ("Caddyfile.funnel", funnel)):
        if "reverse_proxy wrfcoin-testnet-backend:4001" in text:
            raise AssertionError(f"{label} proxies the backend outside the shared allowlist")

    # The boundary protects nothing unless every edge imports it.
    for label, text, hosts in (("Caddyfile", caddy, 2), ("Caddyfile.funnel", funnel, 1)):
        if not re.search(r"(?m)^\s*import public_onboarding\.caddy\s*$", text):
            raise AssertionError(f"{label} does not import the shared public_onboarding.caddy")
        if len(re.findall(r"(?m)^\s*import public_onboarding_api\s*$", text)) != hosts:
            raise AssertionError(f"allowlist must protect every public host in {label}")
        if len(re.findall(r"(?m)^\s*import public_onboarding_limits\s*$", text)) != hosts:
            raise AssertionError(f"rate limits must protect every public host in {label}")

    limits = block(snippets, "(public_onboarding_limits)")
    rate_limit = block(limits, "rate_limit")
    zone_names = set(re.findall(r"(?m)^\s*zone\s+([a-z_]+)\s*\{", rate_limit))
    # infra#886: join_snapshot arrived with the same snapshot-join change
    # (infra#843) that added the join_artifacts route and was likewise never
    # pinned. It is the LIMITER on that approved exposure — `path /join/*`,
    # key {client_ip}, 10 per minute — so recording it is recording a
    # protection, not widening one. Note this pin fixes only the zone NAME set;
    # zone bodies are unpinned, so a change to those events/window/key values
    # would not fail this gate.
    if zone_names != {"onboarding", "faucet_claim", "join_snapshot", "public_read", "station_owner_actions", "weather_noaa", "wallet_send", "wolfram_reading_check", "notify_write"}:
        raise AssertionError(f"rate-limit zone set drifted: {sorted(zone_names)}")
    expected_zones = {
        "wallet_send": ["match {", "method POST", "path /api/wallet/send", "}", "key {client_ip}", "events 5", "window 1m"],
        "onboarding": [
            "match {",
            "path /api/auth/* /api/onboarding/* /api/weather/stations*",
            "}",
            "key {client_ip}",
            "events 30",
            "window 1m",
        ],
        "faucet_claim": [
            "match {",
            "path /api/onboarding/faucet/claim /api/faucet/bond-grant",
            "}",
            "key {client_ip}",
            "events 5",
            "window 1m",
        ],
        "public_read": [
            "match {",
            "path /api/faucet/bond-grants /api/blockchain/* /api/weather/coverage-zones /api/build /api/capabilities /api/stations/* /api/weather/leaderboard /api/earnings/leaderboard /api/operators/c_*/profile /api/wallet/* /api/governance/* /api/public/balance/* /api/forecasters /api/forecasters/c_* /api/explorer/summary /api/proofs/* /api/network/nodes /api/competitions /api/competitions/* /api/notifications/config /api/calibration-certificates/station/*",
            "}",
            "key {client_ip}",
            "events 30",
            "window 1m",
        ],
        # S2b: the NOAA-fanout weather reads, tight and separate from public_read.
        "weather_noaa": [
            "match {",
            "path /api/weather/current/* /api/weather/forecast/*",
            "}",
            "key {client_ip}",
            "events 10",
            "window 1m",
        ],
        # backend#389: payout-notification writes, 10/min per client.
        "notify_write": [
            "match {",
            "path /api/notifications/subscriptions /api/notifications/subscriptions/* /api/notifications/unsubscribe",
            "}",
            "key {client_ip}",
            "events 10",
            "window 1m",
        ],
        # Owner ruling 2026-11-01: the Wolfram reading check's own tight per-IP zone.
        "wolfram_reading_check": [
            "match {",
            "method POST",
            "path /api/integrations/wolfram/reading-check",
            "}",
            "key {client_ip}",
            "events 6",
            "window 1m",
        ],
        # infra#1095: the owner-action relay's own tight per-IP zone.
        "station_owner_actions": [
            "match {",
            "method POST",
            "path_regexp ^/api/stations/st_[0-9a-f]{12}/owner-actions$",
            "}",
            "key {client_ip}",
            "events 10",
            "window 10m",
        ],
    }
    for zone, expected in expected_zones.items():
        if directives(block(rate_limit, f"zone {zone}")) != expected:
            raise AssertionError(f"rate-limit zone {zone} is not exact")

    # Funnel edge posture: loopback-only host bind, funnel-origin CORS, and
    # both Caddy files actually mounted (an unmounted import fails at boot).
    if not re.search(r'"127\.0\.0\.1:8444:8444"', funnel_compose):
        raise AssertionError("funnel-edge must bind 127.0.0.1 only")
    if "CORS_ORIGIN: ${WRFCOIN_FUNNEL_ORIGIN:" not in funnel_compose:
        raise AssertionError("funnel edge must set the exact funnel-origin backend CORS origin")
    for compose_label, compose_text, config in (
        ("docker-compose.edge.yml", edge_compose, "Caddyfile"),
        ("docker-compose.funnel-edge.yml", funnel_compose, "Caddyfile.funnel"),
    ):
        if f"./edge/{config}:/etc/caddy/Caddyfile:ro" not in compose_text:
            raise AssertionError(f"{compose_label} does not mount {config}")
        if "./edge/public_onboarding.caddy:/etc/caddy/public_onboarding.caddy:ro" not in compose_text:
            raise AssertionError(f"{compose_label} does not mount the shared allowlist file")
        # infra#983: the Stage 1.5 toggle ships OFF on both edges.
        toggles = [line.strip() for line in compose_text.splitlines() if "PUBLIC_READONLY_API" in line and not line.lstrip().startswith("#")]
        if toggles != [READONLY_COMPOSE_LINE]:
            raise AssertionError(f"{compose_label} must pass exactly `{READONLY_COMPOSE_LINE}` (default OFF), got {toggles}")

    csp_lines = [line.strip() for line in nginx.splitlines()
                 if "Content-Security-Policy" in line and not line.lstrip().startswith("#")]
    if csp_lines != [FRONTEND_CSP_LINE, FRONTEND_CSP_LINE]:
        raise AssertionError(
            "frontend CSP drifted: need exactly 2 byte-identical add_header lines equal to the approved policy "
            f"(img-src adds only https://tile.openstreetmap.org); got {len(csp_lines)} line(s)"
        )

    if "location /api/" not in nginx or "location /ws" not in nginx:
        raise AssertionError("frontend proxy topology changed; re-audit edge denials")
    if "CORS_ORIGIN: https://${WRFCOIN_PUBLIC_DOMAIN:" not in edge_compose:
        raise AssertionError("public edge must set an exact non-localhost backend CORS origin")

    print(
        "PASS public exposure boundary: exact API allowlist shared by both edges, "
        "denied backend bypasses, no public faucet/explorer, rate limits, and "
        "funnel edge pinned to loopback with both configs mounted"
    )


def self_test() -> None:
    """RED controls: verify() must reject each boundary-weakening mutation."""

    def build_tree(mutate: str | None = None, apply=None) -> Path:
        tree = Path(tempfile.mkdtemp(prefix="boundary-selftest-"))
        for rel in RELATIVE_FILES:
            src = ROOT / rel
            dst = tree / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(src, dst)
        if mutate is not None:
            target = tree / mutate
            target.write_text(apply(target.read_text(encoding="utf-8")), encoding="utf-8")
        return tree

    mutations = {
        "bond grant method widened": ("testnet/edge/public_onboarding.caddy", lambda s: s.replace("method POST\n\t\tpath /api/faucet/bond-grant", "method GET POST\n\t\tpath /api/faucet/bond-grant")),
        "bond audit path widened": ("testnet/edge/public_onboarding.caddy", lambda s: s.replace("path /api/faucet/bond-grants\n", "path /api/faucet/bond-grants*\n")),
        "bond grant dropped from limiter": ("testnet/edge/public_onboarding.caddy", lambda s: s.replace("path /api/onboarding/faucet/claim /api/faucet/bond-grant", "path /api/onboarding/faucet/claim")),
        "bond audit dropped from limiter": ("testnet/edge/public_onboarding.caddy", lambda s: s.replace("path /api/faucet/bond-grants /api/blockchain/*", "path /api/blockchain/*")),
        "S9 submit method widened": ("testnet/edge/public_onboarding.caddy", lambda s: s.replace("method POST\n\t\tpath /api/wallet/send", "method GET\n\t\tpath /api/wallet/send")),
        "S9 submit Bearer removed": ("testnet/edge/public_onboarding.caddy", lambda s: s.replace('header Authorization "Bearer *"\n\t\theader Content-Type application/json', 'header Content-Type application/json')),
        "S9 submit query lock removed": ("testnet/edge/public_onboarding.caddy", lambda s: s.replace('expression `{query} == ""`\n\t\theader Authorization "Bearer *"\n\t\theader Content-Type application/json', 'header Authorization "Bearer *"\n\t\theader Content-Type application/json')),
        "S9 submit body cap widened": ("testnet/edge/public_onboarding.caddy", lambda s: s.replace("max_size 4096", "max_size 2MB")),
        "S9 submit content type removed": ("testnet/edge/public_onboarding.caddy", lambda s: s.replace("\t\theader Content-Type application/json\n", "")),
        "S9 submit gate removed": ("testnet/edge/public_onboarding.caddy", lambda s: s.replace("path /api/wallet/send\n\t\tvars {env.PUBLIC_READONLY_API} on", "path /api/wallet/send")),
        "S9 nonce path widened": ("testnet/edge/public_onboarding.caddy", lambda s: s.replace("^/api/wallet/0x[0-9a-f]{40}/nonce$", "^/api/wallet/.*/nonce$")),
        "S9 submit rate loosened": ("testnet/edge/public_onboarding.caddy", lambda s: s.replace("zone wallet_send {", "zone wallet_send_removed {")),
        "widened API route (new matcher outside the approved set)": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "(public_onboarding_api) {",
                "(public_onboarding_api) {\n\t@evil {\n\t\tmethod GET\n\t\tpath /api/*\n\t}\n\thandle @evil {\n\t\treverse_proxy wrfcoin-testnet-backend:4001\n\t}",
            ),
        ),
        "terminal /api/* 404 removed": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace('\thandle /api/* {\n\t\trespond "Not found" 404\n\t}\n', ""),
        ),
        "new public read widened beyond GET": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "@chain_transactions {\n\t\tmethod GET",
                "@chain_transactions {\n\t\tmethod GET POST",
            ),
        ),
        "build read widened to a prefix (path /api/build*)": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("\t\tpath /api/build\n", "\t\tpath /api/build*\n"),
        ),
        "capabilities read widened beyond GET": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "@public_capabilities {\n\t\tmethod GET",
                "@public_capabilities {\n\t\tmethod GET POST",
            ),
        ),
        "build/capabilities dropped from the public-read rate limit": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(" /api/build /api/capabilities ", " "),
        ),
        "backend#1456 leaderboard dropped from the public-read limiter": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(" /api/weather/leaderboard ", " "),
        ),
        "public-read ledger row deleted": (
            "testnet/edge/route-ledger.yml",
            lambda s: s.replace("transaction list/detail", "transaction routes"),
        ),
        "funnel edge drops the shared import (raw-frontend shape)": (
            "testnet/edge/Caddyfile.funnel",
            lambda s: s.replace("import public_onboarding.caddy", "")
            .replace("import public_onboarding_api", "")
            .replace("import public_onboarding_limits", ""),
        ),
        "rate-limit key widened back to remote_host": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("{client_ip}", "{remote_host}"),
        ),
        "infra#1051 dot-segment guard removed (pre-fix shape)": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: re.sub(
                r"\t@noncanonical_uri \{.*?\n\t\}\n\thandle @noncanonical_uri \{.*?\n\t\}\n",
                "",
                s,
                count=1,
                flags=re.S,
            ),
        ),
        "infra#1051 guard stops rejecting double-encoding (%25 dropped)": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("2e|2f|5c|25|00", "2e|2f|5c|00"),
        ),
        "infra#1051 guard stops scanning at a literal # (9084b02 shape)": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("[^?]*(?:#|/\\.\\.?(?:[/?]|$)", "[^?#]*(?:/\\.\\.?(?:[/?#]|$)"),
        ),
        "infra#1051 guard no longer rejects a literal #": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("[^?]*(?:#|/", "[^?]*(?:/"),
        ),
        "infra#1051 guard made case-sensitive": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("(?i:%(?:2e", "(?:%(?:2e"),
        ),
        "infra#1051 guard downgraded to a pass-through handler": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace('respond "Bad request" 400', "reverse_proxy wrfcoin-testnet-frontend:5000"),
        ),
        "infra#1051 guard moved after the allowlist": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: (lambda m: s.replace(m, "").replace(
                "\thandle /api/* {", m + "\thandle /api/* {"
            ))(re.search(r"\t@noncanonical_uri \{.*?\n\t\}\n\thandle @noncanonical_uri \{.*?\n\t\}\n", s, re.S).group(0)),
        ),
        "infra#983 station-detail gate removed (reads admitted unconditionally)": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "(observations|quality|submissions)$\n\t\tvars {env.PUBLIC_READONLY_API} on\n",
                "(observations|quality|submissions)$\n",
            ),
        ),
        "infra#983 station-list gate loosened to accept `true`": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "path /api/weather/stations\n\t\tvars {env.PUBLIC_READONLY_API} on\n",
                "path /api/weather/stations\n\t\tvars {env.PUBLIC_READONLY_API} on true\n",
            ),
        ),
        "infra#983 station-detail regex unanchored (prefix admit)": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("(observations|quality|submissions)$", "(observations|quality|submissions)"),
        ),
        "infra#983 station-detail regex widened to /earnings": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("(observations|quality|submissions)$", "(observations|quality|submissions|earnings)$"),
        ),
        "backend#1232 earnings gate removed (read admitted unconditionally)": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "earnings$\n\t\tvars {env.PUBLIC_READONLY_API} on\n",
                "earnings$\n",
            ),
        ),
        "backend#1232 earnings query lock widened to admit limit=1": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "path_regexp ^/api/stations/[A-Za-z0-9_-]{1,64}/earnings$\n\t\tvars {env.PUBLIC_READONLY_API} on\n\t\texpression `{query} == \"\"`",
                "path_regexp ^/api/stations/[A-Za-z0-9_-]{1,64}/earnings$\n\t\tvars {env.PUBLIC_READONLY_API} on\n\t\texpression `{query} == \"\" || {query} == \"limit=1\"`",
            ),
        ),
        "backend#1232 earnings query lock removed (any query admitted)": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "earnings$\n\t\tvars {env.PUBLIC_READONLY_API} on\n\t\texpression `{query} == \"\"`\n",
                "earnings$\n\t\tvars {env.PUBLIC_READONLY_API} on\n",
            ),
        ),
        "backend#1232 earnings regex unanchored (prefix admit)": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("/earnings$\n", "/earnings\n"),
        ),
        "backend#1232 earnings widened beyond GET": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "@public_readonly_station_earnings {\n\t\tmethod GET",
                "@public_readonly_station_earnings {\n\t\tmethod GET POST",
            ),
        ),
        "backend#1232 earnings station-id length widened to 65+": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("{1,64}/earnings$", "{1,65}/earnings$"),
        ),
        "backend#1456 leaderboard gate removed (read admitted unconditionally)": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "path_regexp ^/api/weather/leaderboard$\n\t\tvars {env.PUBLIC_READONLY_API} on\n",
                "path_regexp ^/api/weather/leaderboard$\n",
            ),
        ),
        "backend#1456 leaderboard query lock removed (any query admitted)": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: re.sub(
                r"(path_regexp \^/api/weather/leaderboard\$\n\t\tvars \{env.PUBLIC_READONLY_API\} on\n)\t\texpression `[^\n]*`\n", r"\1", s
            ),
        ),
        "backend#1456 leaderboard limit widened past 30": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("[12][0-9]|30)$", "[12][0-9]|30|100)$"),
        ),
        "backend#1456 leaderboard geo param admitted": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("limit=([1-9]|[12][0-9]|30)$", "limit=([1-9]|[12][0-9]|30)(&country=[A-Z]{2})?$"),
        ),
        "backend#1456 leaderboard query regex unanchored": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("'^metric=", "'metric="),
        ),
        "backend#1456 leaderboard widened beyond GET": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "@public_readonly_weather_leaderboard {\n\t\tmethod GET",
                "@public_readonly_weather_leaderboard {\n\t\tmethod GET POST",
            ),
        ),
        "S1 wallet info Bearer requirement removed": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "\t\texpression `{query} == \"\"`\n\t\theader Authorization \"Bearer *\"\n\t}\n\thandle @public_readonly_wallet_info",
                "\t\texpression `{query} == \"\"`\n\t}\n\thandle @public_readonly_wallet_info",
            ),
        ),
        "S1 wallet transactions Bearer requirement removed": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("\t\theader Authorization \"Bearer *\"\n\t}\n\thandle @public_readonly_wallet_transactions", "\t}\n\thandle @public_readonly_wallet_transactions"),
        ),
        "S1 wallet address regex widened to any path segment": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("^/api/wallet/0x[0-9A-Fa-f]{40}$", "^/api/wallet/[^/]+$"),
        ),
        "S1 wallet transactions limit widened to 100": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("limit=([1-9]|[1-4][0-9]|50)&offset", "limit=([1-9]|[1-9][0-9]|100)&offset"),
        ),
        "S1 wallet gate removed": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "path_regexp ^/api/wallet/0x[0-9A-Fa-f]{40}$\n\t\tvars {env.PUBLIC_READONLY_API} on\n",
                "path_regexp ^/api/wallet/0x[0-9A-Fa-f]{40}$\n",
            ),
        ),
        "S2a governance proposal id charset widened": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("proposals/[A-Za-z0-9_-]{1,128}$", "proposals/[^/]+$"),
        ),
        "S2a governance proposals widened to a prefix": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("path /api/governance/proposals\n", "path /api/governance/proposals*\n"),
        ),
        "S2a governance treasury widened to a prefix": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("path /api/governance/treasury\n", "path /api/governance/treasury*\n"),
        ),
        "S2b weather coordinates widened to two decimals": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("forecast/-?[0-9]{1,2}\\.[0-9],", "forecast/-?[0-9]{1,2}\\.[0-9]+,"),
        ),
        "S2b weather forecast query lock removed": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(" || {query} == \"days=14\"`", " || {query} == \"days=14\" || {query} != \"\"`"),
        ),
        "S2b weather dropped from its tight NOAA rate zone": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("path /api/weather/current/* /api/weather/forecast/*", "path /api/weather/current/*"),
        ),
        "S2b weather data/historical admitted": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("^/api/weather/current/-?", "^/api/weather/(current|data)/-?"),
        ),
        "backend#21 passkey send widened to a prefix": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("path_regexp ^/api/wallet/send-passkey$", "path_regexp ^/api/wallet/send-passkey"),
        ),
        "backend#21 passkey send body cap removed": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("\t\t\tmax_size 32768\n", "\t\t\tmax_size 4GiB\n"),
        ),
        "backend#21 passkey send acquires a bearer requirement": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "path_regexp ^/api/wallet/send-passkey$\n\t\tvars {env.PUBLIC_READONLY_API} on\n\t\texpression `{query} == \"\"`\n",
                "path_regexp ^/api/wallet/send-passkey$\n\t\tvars {env.PUBLIC_READONLY_API} on\n\t\texpression `{query} == \"\"`\n\t\theader Authorization \"Bearer *\"\n",
            ),
        ),
        "backend#21 passkey nonce accepts uppercase or any-length address": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("send-passkey/nonce/0x[0-9a-f]{40}$", "send-passkey/nonce/0x[0-9a-fA-F]+$"),
        ),
        "backend#21 passkey nonce widened beyond GET": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "@public_wallet_send_passkey_nonce {\n\t\tmethod GET",
                "@public_wallet_send_passkey_nonce {\n\t\tmethod GET POST",
            ),
        ),
        "backend#30 public balance widened to a prefix": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("path_regexp ^/api/public/balance/0x[0-9a-fA-F]{40}$", "path_regexp ^/api/public/balance/"),
        ),
        "backend#30 public balance widened beyond GET": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("@public_balance_read {\n\t\tmethod GET", "@public_balance_read {\n\t\tmethod GET POST"),
        ),
        "backend#30 public balance ungated": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "path_regexp ^/api/public/balance/0x[0-9a-fA-F]{40}$\n\t\tvars {env.PUBLIC_READONLY_API} on\n",
                "path_regexp ^/api/public/balance/0x[0-9a-fA-F]{40}$\n",
            ),
        ),
        "wolfram reading check widened to the integrations prefix": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "path /api/integrations/wolfram/reading-check\n\t\tvars", "path /api/integrations/*\n\t\tvars"
            ),
        ),
        "wolfram reading check widened beyond POST": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("@wolfram_reading_check {\n\t\tmethod POST", "@wolfram_reading_check {\n\t\tmethod POST GET"),
        ),
        "wolfram reading check ungated": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "path /api/integrations/wolfram/reading-check\n\t\tvars {env.PUBLIC_READONLY_API} on\n",
                "path /api/integrations/wolfram/reading-check\n",
            ),
        ),
        "wolfram reading check admits a query (the AppID would reach access logs)": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "path /api/integrations/wolfram/reading-check\n\t\tvars {env.PUBLIC_READONLY_API} on\n\t\texpression `{query} == \"\"`",
                "path /api/integrations/wolfram/reading-check\n\t\tvars {env.PUBLIC_READONLY_API} on\n\t\texpression `true`",
            ),
        ),
        "wolfram reading check body cap removed": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "handle @wolfram_reading_check {\n\t\trequest_body {\n\t\t\tmax_size 2KiB\n\t\t}\n",
                "handle @wolfram_reading_check {\n",
            ),
        ),
        "wolfram reading check rate zone loosened": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "path /api/integrations/wolfram/reading-check\n\t\t\t}\n\t\t\tkey {client_ip}\n\t\t\tevents 6",
                "path /api/integrations/wolfram/reading-check\n\t\t\t}\n\t\t\tkey {client_ip}\n\t\t\tevents 600",
            ),
        ),
        "forecasters list widened to a prefix": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("path_regexp ^/api/forecasters$", "path_regexp ^/api/forecasters"),
        ),
        "forecaster profile admits a raw address": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "path_regexp ^/api/forecasters/c_[0-9a-f]{24}$", "path_regexp ^/api/forecasters/(c_[0-9a-f]{24}|0x[0-9a-fA-F]{40})$"
            ),
        ),
        "forecasters list query unlocked": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "expression `{query}.matches('^period=(7d|30d|all)&limit=([1-9]|[1-9][0-9]|100)$')`",
                "expression `{query}.matches('^period=')`",
            ),
        ),
        "forecasters list widened beyond GET": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("@public_readonly_forecasters {\n\t\tmethod GET", "@public_readonly_forecasters {\n\t\tmethod GET POST"),
        ),
        "explorer summary widened to the explorer prefix": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("path /api/explorer/summary\n\t\tvars", "path /api/explorer/*\n\t\tvars"),
        ),
        "network nodes widened to the network prefix": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("path /api/network/nodes\n\t\tvars", "path /api/network/*\n\t\tvars"),
        ),
        "network nodes ungated": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("path /api/network/nodes\n\t\tvars {env.PUBLIC_READONLY_API} on\n", "path /api/network/nodes\n"),
        ),
        "network nodes widened beyond GET": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("@public_readonly_network_nodes {\n\t\tmethod GET", "@public_readonly_network_nodes {\n\t\tmethod GET POST"),
        ),
        "competitions widened to any week segment": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("(current|[0-9]{4}-W(0[1-9]|[1-4][0-9]|5[0-3]))", "[^/]+"),
        ),
        "competitions ungated": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("5[0-3])))?$\n\t\tvars {env.PUBLIC_READONLY_API} on\n", "5[0-3])))?$\n"),
        ),
        "notification subscribe Bearer removed": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "path /api/notifications/subscriptions\n\t\tvars {env.PUBLIC_READONLY_API} on\n\t\texpression `{query} == \"\"`\n\t\theader Authorization \"Bearer *\"\n",
                "path /api/notifications/subscriptions\n\t\tvars {env.PUBLIC_READONLY_API} on\n\t\texpression `{query} == \"\"`\n",
            ),
        ),
        "notification subscribe body cap widened": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("handle @public_notifications_subscribe {\n\t\trequest_body {\n\t\t\tmax_size 4096", "handle @public_notifications_subscribe {\n\t\trequest_body {\n\t\t\tmax_size 1MB"),
        ),
        "notification list widened to any segment": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("^/api/notifications/subscriptions/0x[0-9a-fA-F]{40}$", "^/api/notifications/subscriptions/.+$"),
        ),
        "notification delete widened to GET": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("@public_notifications_delete {\n\t\tmethod DELETE", "@public_notifications_delete {\n\t\tmethod DELETE GET"),
        ),
        "notify_write zone removed": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: re.sub(r"\t\tzone notify_write \{.*?\n\t\t\}\n", "", s, count=1, flags=re.S),
        ),
        "calibration certificate widened to any segment": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "path_regexp ^/api/calibration-certificates/station/st_[0-9a-f]{12}$",
                "path_regexp ^/api/calibration-certificates/station/[^/]+$",
            ),
        ),
        "calibration certificate widened beyond GET": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "@public_readonly_calibration_certificate {\n\t\tmethod GET",
                "@public_readonly_calibration_certificate {\n\t\tmethod GET POST",
            ),
        ),
        "calibration certificate ungated": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "path_regexp ^/api/calibration-certificates/station/st_[0-9a-f]{12}$\n\t\tvars {env.PUBLIC_READONLY_API} on\n",
                "path_regexp ^/api/calibration-certificates/station/st_[0-9a-f]{12}$\n",
            ),
        ),
        "calibration certificate query unlocked": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "path_regexp ^/api/calibration-certificates/station/st_[0-9a-f]{12}$\n\t\tvars {env.PUBLIC_READONLY_API} on\n\t\texpression `{query} == \"\"`",
                "path_regexp ^/api/calibration-certificates/station/st_[0-9a-f]{12}$\n\t\tvars {env.PUBLIC_READONLY_API} on",
            ),
        ),
        "proof card widened to any segment": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("path_regexp ^/api/proofs/[0-9a-f]{64}$", "path_regexp ^/api/proofs/[^/]+$"),
        ),
        "proof card query unlocked": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "expression `{query} == \"\" || {query}.matches('^h=[1-9][0-9]{0,11}$')`",
                "expression `{query}.matches('^h=')`",
            ),
        ),
        "proof card widened beyond GET": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("@public_readonly_proof_card {\n\t\tmethod GET", "@public_readonly_proof_card {\n\t\tmethod GET POST"),
        ),
        "proof card ungated": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "path_regexp ^/api/proofs/[0-9a-f]{64}$\n\t\tvars {env.PUBLIC_READONLY_API} on\n", "path_regexp ^/api/proofs/[0-9a-f]{64}$\n"
            ),
        ),
        "explorer summary ungated": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("path /api/explorer/summary\n\t\tvars {env.PUBLIC_READONLY_API} on\n", "path /api/explorer/summary\n"),
        ),
        "infra#1095 owner-action relay widened beyond POST": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("@station_owner_actions {\n\t\tmethod POST", "@station_owner_actions {\n\t\tmethod POST GET"),
        ),
        "bond-grant POST edge body cap removed": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "handle @faucet_bond_grant {\n\t\trequest_body {\n\t\t\tmax_size 8KiB\n\t\t}\n",
                "handle @faucet_bond_grant {\n",
            ),
        ),
        "bond-grant POST edge body cap widened": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "handle @faucet_bond_grant {\n\t\trequest_body {\n\t\t\tmax_size 8KiB",
                "handle @faucet_bond_grant {\n\t\trequest_body {\n\t\t\tmax_size 2MB",
            ),
        ),
        # Scoped to the owner-action handler: the bond-grant handler carries the same 8 KiB cap, and a
        # file-wide replace would be rejected for the bond-grant route instead of this one.
        "infra#1095 owner-action relay edge body cap removed": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "handle @station_owner_actions {\n\t\trequest_body {\n\t\t\tmax_size 8KiB\n\t\t}\n",
                "handle @station_owner_actions {\n",
            ),
        ),
        "infra#1095 owner-action relay edge body cap widened": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "handle @station_owner_actions {\n\t\trequest_body {\n\t\t\tmax_size 8KiB",
                "handle @station_owner_actions {\n\t\trequest_body {\n\t\t\tmax_size 2MB",
            ),
        ),
        "infra#1095 owner-action relay query lock removed": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: re.sub(
                r"(path_regexp \^/api/stations/st_\[0-9a-f\]\{12\}/owner-actions\$\n)\t\texpression `[^\n]*`\n", r"\1", s, count=1
            ),
        ),
        "infra#1095 owner-action relay path widened to raw station ids": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "^/api/stations/st_[0-9a-f]{12}/owner-actions$\n\t\texpression",
                "^/api/weather/stations/[A-Za-z0-9_-]{1,64}/owner-actions$\n\t\texpression",
            ),
        ),
        "infra#1095 owner-action relay rate zone removed": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: re.sub(r"\t\tzone station_owner_actions \{.*?\n\t\t\}\n", "", s, count=1, flags=re.S),
        ),
        "infra#1095 owner-action relay rate zone loosened": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("events 10\n\t\t\twindow 10m", "events 1000\n\t\t\twindow 10m"),
        ),
        "infra#1095 ownership read gate removed (admitted unconditionally)": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "owner-actions$\n", "owner-actions$\n"
            ).replace(
                "/ownership$\n\t\tvars {env.PUBLIC_READONLY_API} on\n", "/ownership$\n"
            ),
        ),
        "infra#1095 ownership read query lock removed": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "/ownership$\n\t\tvars {env.PUBLIC_READONLY_API} on\n\t\texpression `{query} == \"\"`\n",
                "/ownership$\n\t\tvars {env.PUBLIC_READONLY_API} on\n",
            ),
        ),
        "infra#1095 ownership read widened beyond GET": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "@public_readonly_station_ownership {\n\t\tmethod GET",
                "@public_readonly_station_ownership {\n\t\tmethod GET POST",
            ),
        ),
        "infra#1095 route ledger entry deleted": (
            "testnet/edge/route-ledger.yml",
            lambda s: s.replace("station owner-action relay", "station routes"),
        ),
        "infra#983 station list widened beyond GET": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "@public_readonly_stations {\n\t\tmethod GET",
                "@public_readonly_stations {\n\t\tmethod GET POST",
            ),
        ),
        "infra#983 gate borrowed by an ungated route (chain_stats)": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "path /api/blockchain/stats\n",
                "path /api/blockchain/stats\n\t\tvars {env.PUBLIC_READONLY_API} on\n",
            ),
        ),
        "phone-station status widened to a prefix (/api/weather/stations/mobile*)": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace("\t\tpath /api/weather/stations/mobile\n", "\t\tpath /api/weather/stations/mobile*\n"),
        ),
        "phone-station status widened beyond GET (phone registration reachable)": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "@station_mobile_status {\n\t\tmethod GET",
                "@station_mobile_status {\n\t\tmethod GET POST",
            ),
        ),
        "phone-station status query lock removed": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(
                "path /api/weather/stations/mobile\n\t\texpression `{query} == \"\"`\n",
                "path /api/weather/stations/mobile\n",
            ),
        ),
        "stage15 station-list query lock removed (?lat=&lng= reaches NOAA)": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace('\t\texpression `{query} == ""`\n', ""),
        ),
        "stage15 station-detail query lock widened to any limit": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace('{query} == "limit=1"', '{query}.startsWith("limit=")'),
        ),
        "stage15 query lock borrowed as a widening OR on the station list": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace('expression `{query} == ""`', 'expression `{query} == "" || true`'),
        ),
        "infra#983 station-detail reads dropped from the public-read limiter": (
            "testnet/edge/public_onboarding.caddy",
            lambda s: s.replace(" /api/stations/* ", " "),
        ),
        "infra#983 funnel toggle defaults ON": (
            "testnet/docker-compose.funnel-edge.yml",
            lambda s: s.replace("${PUBLIC_READONLY_API:-off}", "${PUBLIC_READONLY_API:-on}"),
        ),
        "infra#983 direct-edge toggle hardcoded on": (
            "testnet/docker-compose.edge.yml",
            lambda s: s.replace("PUBLIC_READONLY_API: ${PUBLIC_READONLY_API:-off}", "PUBLIC_READONLY_API: \"on\""),
        ),
        "infra#983 ledger row for the gated reads deleted": (
            "testnet/edge/route-ledger.yml",
            lambda s: s.replace("PUBLIC_READONLY_API", "READONLY_TOGGLE"),
        ),
        "frontend CSP img-src widened to any https origin": (
            "testnet/nginx-frontend.conf",
            lambda s: s.replace("blob: https://tile.openstreetmap.org;", "blob: https:;"),
        ),
        "frontend CSP tile origin widened to a wildcard subdomain": (
            "testnet/nginx-frontend.conf",
            lambda s: s.replace("https://tile.openstreetmap.org", "https://*.openstreetmap.org"),
        ),
        "frontend CSP tile origin downgraded to http": (
            "testnet/nginx-frontend.conf",
            lambda s: s.replace("https://tile.openstreetmap.org", "http://tile.openstreetmap.org"),
        ),
        "frontend CSP tile origin leaked into connect-src": (
            "testnet/nginx-frontend.conf",
            lambda s: s.replace("connect-src 'self';", "connect-src 'self' https://tile.openstreetmap.org;"),
        ),
        "frontend CSP asset-location copy drifted from the server copy": (
            "testnet/nginx-frontend.conf",
            lambda s: (lambda i: s[:i] + s[i:].replace(
                "https://tile.openstreetmap.org;", "https://tile.openstreetmap.org https://a.tile.openstreetmap.org;", 1
            ))(s.rindex("add_header Content-Security-Policy")),
        ),
        "frontend CSP dropped from the static-asset location": (
            "testnet/nginx-frontend.conf",
            lambda s: (lambda i: s[:i] + s[i:].replace("add_header Content-Security-Policy", "# add_header Content-Security-Policy", 1))(
                s.rindex("add_header Content-Security-Policy")
            ),
        ),
        "funnel edge bound publicly instead of loopback": (
            "testnet/docker-compose.funnel-edge.yml",
            lambda s: s.replace('"127.0.0.1:8444:8444"', '"8444:8444"'),
        ),
    }

    for route, path in (
        ("earnings_leaderboard", "^/api/earnings/leaderboard$"),
        ("operator_profile", "^/api/operators/c_[0-9a-f]{24}/profile$"),
    ):
        prefix = f"@public_readonly_{route} {{\n\t\tmethod GET"
        mutations[f"B2 {route} non-GET admitted"] = (
            "testnet/edge/public_onboarding.caddy", lambda s, prefix=prefix: s.replace(prefix, prefix + " POST"),
        )
        gate = f"path_regexp {path}\n\t\tvars {{env.PUBLIC_READONLY_API}} on\n"
        mutations[f"B2 {route} gate removed"] = (
            "testnet/edge/public_onboarding.caddy", lambda s, gate=gate: s.replace(gate, gate.split("\n")[0] + "\n"),
        )
    mutations["B2 earnings reordered grammar"] = (
        "testnet/edge/public_onboarding.caddy",
        lambda s: s.replace("^role=(contribution|attester|producer|node|forecast)&period=(all|7d|30d)",
                            "^period=(all|7d|30d)&role=(contribution|attester|producer|node|forecast)"),
    )
    mutations["B2 profile widened to raw addresses"] = (
        "testnet/edge/public_onboarding.caddy",
        lambda s: s.replace("^/api/operators/c_[0-9a-f]{24}/profile$", "^/api/operators/[^/]+/profile$"),
    )
    mutations["B2 reads removed from limiter"] = (
        "testnet/edge/public_onboarding.caddy",
        lambda s: s.replace(" /api/earnings/leaderboard /api/operators/c_*/profile", ""),
    )

    clean = build_tree()
    try:
        verify(clean)
    finally:
        shutil.rmtree(clean, ignore_errors=True)
    print("  ok   unmutated copy passes (control)")

    failures = []
    for label, (rel, apply) in mutations.items():
        tree = build_tree(rel, apply)
        try:
            verify(tree)
            failures.append(label)
            print(f"  BAD  mutation survived: {label}")
        except AssertionError as error:
            print(f"  ok   mutation rejected: {label} ({error})")
        finally:
            shutil.rmtree(tree, ignore_errors=True)

    if failures:
        raise AssertionError(f"{len(failures)} mutation(s) survived the boundary verifier")
    print("SELF-TEST PASS: all boundary-weakening mutations are rejected")


if __name__ == "__main__":
    try:
        if "--self-test" in sys.argv[1:]:
            self_test()
        else:
            verify()
    except AssertionError as error:
        print(f"FAIL public exposure boundary: {error}", file=sys.stderr)
        raise SystemExit(1)
