# wrfcoin.com public-domain hardening

This is an owner-executed change. The verifier is read-only; it does not edit
Cloudflare, registrar, Tailscale, or the live testnet.

## Admission policy

The public-domain gate is PASS only when all of these are simultaneously true:

- `https://wrfcoin.com/` and `https://www.wrfcoin.com/` redirect to the exact
  approved Funnel URL and both redirect responses carry HSTS for at least one day;
- both hosts preserve path and query: `/wallet`, `/governance?limit=20&offset=0`
  and a percent-encoded path redirect to the same path and query on the Funnel
  origin (probes live in `redirect_path_probes`; see #1330 below);
- CAA explicitly authorizes only the issuer(s) in
  `public-domain-hardening.json`;
- a validating resolver returns authenticated DS and DNSKEY records;
- the deployed RFC 9116 `security.txt` has Contact, future Expires, exact
  Canonical, and exact Policy fields.

Do not treat a Cloudflare dashboard toggle, an unvalidated DNS answer, or the
presence of a source file as runtime proof.

## Safe owner sequence

1. Deploy frontend PR #279 so the policy page and
   `/.well-known/security.txt` exist at the Funnel hostname. Verify them before
   changing DNS controls.
2. Confirm the certificate currently served for `wrfcoin.com`. The certificate
   observed while this policy was authored was issued by Google Trust Services;
   therefore the initial allowlist is `pki.goog`. If the active issuer changes,
   update and review the policy before changing CAA. Cloudflare may create
   additional CAA authorizations for its certificate-authority partners; every
   such issuer must be intentional and added to the reviewed allowlist.
3. Add a CAA `issue` authorization for each reviewed issuer. Do not add broad or
   unrelated issuers. A deliberate `issuewild ";"` denial is compatible with
   the verifier when wildcard certificates are not used.
4. Enable DNSSEC in Cloudflare, publish the supplied DS record at the registrar,
   and wait until both DS and DNSKEY validate externally. A DNSKEY without the
   parent DS chain is not PASS.
5. Enable HSTS at Cloudflare with `max-age=86400`, without `preload` during the
   initial soak. First prove that both apex and `www` are permanently HTTPS-safe.
   Increase max-age only after a separate review and clean soak; do not preload
   the domain as part of this change.
6. Run the external verifier from a normal internet connection and archive its
   JSON output:

   ```bash
   python3 scripts/verify-public-domain-hardening.py \
     --output docs/plans/evidence/public-domain-hardening.json
   ```

Expected terminal result:

```text
VERDICT: PASS — redirects, HSTS, CAA, DNSSEC, and security.txt are verified
```

## Path-preserving redirect (#1330)

Symptom: `https://wrfcoin.com/wallet` redirects to the Funnel **root**, so every
shared deep link lands on the home page. Cause: a Cloudflare rule with a static
target. This repo never edits Cloudflare; the owner performs these steps.

**1. Find the existing rule** (Cloudflare dashboard, zone `wrfcoin.com`). Check
in this order and note which one holds the `wrfcoin-testnet.taila1c049.ts.net`
target:

- *Rules → Redirect Rules* (Single Redirects): a rule whose "Then" is a static
  URL. This is the most likely home.
- *Rules → Page Rules (legacy)*: a "Forwarding URL" rule. Page Rules show a
  fixed destination, optionally with `$1` wildcards; no expression editor.
- *Rules → Bulk Redirects*: a list-based redirect. Entries show a source URL and
  target URL; "Preserve query string" / "Subpath matching" are per-entry options.

Both `wrfcoin.com` and `www.wrfcoin.com` must be covered (one rule matching
either host, or two rules).

**2. Replace it with a Single Redirect** (Rules → Redirect Rules → Create rule):

- When incoming requests match (Edit expression):
  `(http.host eq "wrfcoin.com") or (http.host eq "www.wrfcoin.com")`
- Then: **Dynamic**, expression
  `concat("https://wrfcoin-testnet.taila1c049.ts.net", http.request.uri.path)`
- **Preserve query string: ON** (appends the original `?query` unchanged; do not
  also concatenate `http.request.uri.query`, or the query is doubled)
- Status code: **302** to start. Keep 302 for the soak, then move to **308**
  (or 301) after review. 301/308 are cached by browsers and intermediaries,
  so a wrong or later-changed target is hard to recall; 302 is safe to correct.
  308 keeps the method, 301 may turn POST into GET; the gate accepts either.
- Disable or delete the old static rule only after the new one is saved, to avoid
  a window with no redirect. Rule order matters: the new rule must not be shadowed
  by the old one.

**3. Verify** from a normal internet connection (read-only GETs, never follows
redirects; the new path/query gate must PASS for both hosts):

```bash
python3 scripts/verify-public-domain-hardening.py
```

Quick manual check: `curl -sI 'https://wrfcoin.com/governance?limit=20&offset=0'`
must show `location: https://wrfcoin-testnet.taila1c049.ts.net/governance?limit=20&offset=0`.
Percent escapes must stay encoded exactly as sent.

**Rollback:** re-enable the old static rule (or recreate it with the same static
target) and disable the dynamic rule, then re-run the verifier. The path gate
will be RED again, which is the known #1330 state, but the root redirect, HSTS,
CAA and DNSSEC gates must remain unchanged. If 308/301 was used and the target
was wrong, browsers may cache it; that is why 302 comes first.

## Rollback

- A bad CAA change: restore the last reviewed CAA set immediately; do not remove
  CAA merely to make issuance work.
- A broken DNSSEC chain: follow the registrar/Cloudflare DNSSEC recovery flow
  and keep the public-launch gate RED until validating resolvers agree.
- A redirect/HSTS failure: restore the previous exact redirect rule. HSTS cannot
  be instantly recalled by clients, which is why the first max-age is one day.

Re-run the verifier after every rollback. A dashboard screenshot is not a
substitute for the external PASS artifact.
