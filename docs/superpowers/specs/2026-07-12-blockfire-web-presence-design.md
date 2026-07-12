# blockfire.cc Web Presence + Email — Design

_Date: 2026-07-12 · Status: approved (design), pre-implementation · Branch: `blockfire-web-presence`_

## Goal

Stand up the public web presence for the newly-purchased **blockfire.cc** domain:

1. A fast-loading **static marketing front page** at `blockfire.cc` (project pitch,
   screenshots, "Wishlist on Steam / Coming Soon" CTA).
2. The **M20 player-stats site** (already built, `backend/`) served at
   `stats.blockfire.cc` — no code changes.
3. **Email** for the domain (send + receive) via the existing docker-mailserver on
   the `rapid.rolandot.com` VPS, with correct deliverability records.

All of it reuses the **existing single unraid Caddy** as the internet edge and the
existing MikroTik `:443` port-forward — no new ingress components, no tunnel.

## Non-goals

- No changes to the game (server/client/shared) or to the M20 app code.
- No production cutover in the initial rollout — dev runs on **game2**; a later step
  re-points the two Caddy upstreams to unraid for prod.
- No CI/CD pipeline for the site (hand static files, no build step).

## Current state (verified)

- **M20 backend is complete and on master** (P1 ingest+DB, P2 player website incl.
  Steam OpenID login, P3 admin dashboards, P4 anomaly detection) plus M9 trust
  hardening. The app serves everything from **root**: `/`, `/players/*`, `/api/*`,
  `/admin/*`, `/login` — and the Steam OpenID realm/return URL is built from
  `SITE_BASE_URL`. This is why stats must live on a **subdomain**, not a subpath.
- **game2** is the dev host (this session runs on it). Front-page + stats containers
  run here for dev.
- **unraid** (`192.168.1.10`, production) runs the single edge Caddy that reverse-
  proxies all hosted sites and manages certs; MikroTik forwards `:443` to it.
- **VPS** `rapid.rolandot.com` runs `ghcr.io/docker-mailserver/docker-mailserver`.
  Passwordless SSH from game2 → VPS is now working.

## Architecture

### Domains

| Host | Serves | Dev upstream (game2) | Prod upstream (unraid) |
|---|---|---|---|
| `blockfire.cc`, `www.blockfire.cc` | static marketing page (`www` → apex redirect) | `game2:<WEB_PORT>` | unraid-local |
| `stats.blockfire.cc` | M20 stats app | `game2:8000` | unraid-local:8000 |
| `mail.blockfire.cc` | MX target (VPS docker-mailserver) | — | — |

### Ingress (unchanged pattern)

MikroTik `:443` → unraid Caddy → two new `reverse_proxy` site blocks appended to the
existing live Caddyfile. Dev upstreams point at game2's LAN IP; a later prod step
re-points the same two lines. **TLS/cert method and Cloudflare proxy (orange/grey)
choice are matched to whatever the existing sites in that Caddyfile already use** —
read it first. Per owner decision: agent prepares the block + reload command; owner
applies it to production (no agent write to live prod config).

### DNS (Cloudflare, scoped API token)

- `A blockfire.cc` → home public IP (proxy setting matched to existing sites)
- `www`, `stats` → same target/proxy as apex
- **Email records, DNS-only (grey cloud):** `MX blockfire.cc` → `mail.blockfire.cc`;
  `A mail` → VPS IP; SPF `TXT`; DKIM `TXT` (value from VPS keygen); DMARC `TXT`.

### Marketing site (`web/` — new dir in repo)

- Hand-authored static **HTML/CSS**, minimal JS, no build step.
- Sections: hero (logo + tagline + "Wishlist on Steam / Coming Soon" CTA), feature
  highlights (128-player conquest · destructible buildings · tactical combat),
  optimized screenshot gallery (from `~/bf-shots`), short "what is Blockfire" blurb,
  footer (link to `stats.blockfire.cc`, `hello@blockfire.cc`).
- Served by a tiny `caddy:*-alpine` `file_server` container — **same image dev and
  prod**, only the edge upstream differs.
- Visual pass uses the frontend-design skill toward the BattleBit north-star look,
  iterated via the existing game2-Xvfb / desktop screenshot loop (`~/bf-shots`).

### M20 stats deploy (no code change)

`backend/docker-compose.yml` on game2 with prod-correct env from the start:
`SITE_BASE_URL=https://stats.blockfire.cc`, a real `SESSION_SECRET`, real
`INGEST_TOKEN`, `ADMIN_STEAM_IDS=<owner SteamID64>`, `ADMIN_DEV_OPEN` unset/false,
`REQUIRE_SIGNED_INGEST=true`. Because the internet-facing box is a **dev** host, the
prod-safety env must be correct on day one.

### Email (VPS docker-mailserver)

Add domain `blockfire.cc`; create `hello@blockfire.cc`; catch-all
`*@blockfire.cc` → `hello@`; generate DKIM; publish DKIM/SPF/DMARC in Cloudflare.
Verify with mail-tester.com (target 10/10) and a live send+receive round-trip.

## Phasing

- **P1 — Plumbing.** CF zone baseline (apex/www/stats A records). Read existing
  Caddyfile, author + hand over the two site blocks. Prove a placeholder page loads
  over HTTPS through the domain (validates DNS + edge + cert).
- **P2 — Stats live.** Deploy M20 on game2 with prod env; `stats.blockfire.cc` up;
  Steam OpenID round-trip succeeds; `/healthz` green through the domain.
- **P3 — Front page.** Build the marketing site; deploy the `file_server` container
  on game2; `blockfire.cc` live; `www` → apex redirect works.
- **P4 — Email.** Add domain + catch-all mailbox + DKIM on the VPS; publish
  DKIM/SPF/DMARC; verify deliverability (mail-tester) and a send/receive round-trip.
- **Later — Prod cutover.** Move both compose stacks to unraid; re-point the two
  Caddy upstreams to unraid-local; confirm.

## Verification per phase

- P1: `dig`/CF confirmation of records; `curl -I https://blockfire.cc` → valid cert +
  placeholder.
- P2: `curl https://stats.blockfire.cc/healthz` → ok; manual Steam login round-trip;
  `/admin` 403 for non-admin.
- P3: front page loads, screenshots render, CTA link correct, `www`→apex redirect.
- P4: mail-tester.com score; send from `hello@` to an external inbox and reply back.

## What lands in the repo vs. external systems

- **In repo (committed on this branch):** `web/` static site + its compose; the M20
  prod env template / notes; a `docs/runbooks/` runbook capturing the Caddy block,
  Cloudflare record table, and the VPS email setup commands.
- **External (not in repo):** live Cloudflare records, the appended unraid Caddy
  block (owner applies), VPS mailserver domain/mailbox/DKIM.

## Secrets / access needed to implement

- **Cloudflare API token** — scoped to `Zone.DNS:Edit` for `blockfire.cc` (owner to
  provide; used for DNS records and, if existing sites use it, Caddy DNS-01).
- **VPS SSH** — confirmed working (game2 → `root@rapid.rolandot.com`).
- **Existing unraid Caddyfile** — owner to paste (or grant read) so new blocks match
  conventions exactly.
- **Owner SteamID64** — for `ADMIN_STEAM_IDS`.

## Open items to resolve at implementation time

- Home public IP / whether existing records are proxied (orange) or DNS-only (grey) —
  read from the CF zone once the token is available; match apex/stats to siblings.
- Exact TLS mechanism in the existing Caddyfile (DNS-01 plugin vs HTTP-01) — match it.
- MX hostname convention already used by the VPS for its other domains — reuse.
