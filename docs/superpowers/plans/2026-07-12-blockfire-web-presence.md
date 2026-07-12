# blockfire.cc Web Presence + Email — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish blockfire.cc — a static marketing front page + legal pages, the existing M20 stats app on `stats.blockfire.cc`, and working send/receive email — reusing the existing unraid Caddy edge and the `rapid.rolandot.com` docker-mailserver.

**Architecture:** One internet-facing unraid Caddy (TLS via Cloudflare DNS-01, Cloudflare-proxied/orange) reverse-proxies two internal upstreams on game2 (dev): a tiny `nginx:alpine` static-file container (`:8080`) for the marketing site and the M20 FastAPI app (`:8000`) for stats. Email is added as a new domain to the existing multi-domain docker-mailserver, MX pointing at `mail.rolandot.com`. Nothing in the game engine changes; the M20 app code is unchanged.

**Tech Stack:** Cloudflare API (DNS), Caddy (edge, existing), Docker Compose, `nginx:alpine` (static), FastAPI+Postgres (existing `backend/`), docker-mailserver, static HTML/CSS.

**Design spec:** `docs/superpowers/specs/2026-07-12-blockfire-web-presence-design.md`

---

## Concrete values (used throughout — no placeholders)

```
CF_ZONE_ID   = 0804e36218b5e084483ec6d1a3200c77
CF_TOKEN     = (read at runtime: cat ~/.cf_blockfire_token   # game2, chmod 600, never commit)
HOME_IP      = 178.174.157.185          # apex/www/stats origin (Cloudflare-proxied)
VPS_IP       = 188.68.247.11            # rapid.rolandot.com
MAIL_HOST    = mail.rolandot.com        # blockfire.cc MX target (existing, valid rDNS+cert)
GAME2_IP     = 192.168.1.166            # dev upstream host (this session runs here)
WEB_PORT     = 8080                     # static site container, game2
STATS_PORT   = 8000                     # M20 app, game2
DMS_DIR      = /srv/docker-mailserver   # on VPS
OWNER_STEAMID= 76561197991773727        # ADMIN_STEAM_IDS
```

**Owner-supplied legal identity** (fill into the legal pages during Task 3.5; these are the only intentional fill-ins — genuine legal facts only the owner can state):
```
{{OPERATOR_LEGAL_NAME}}   e.g. "Roland <Surname>" or a company name
{{OPERATOR_JURISDICTION}} e.g. "Sweden" — governing law + Impressum locale
{{OPERATOR_ADDRESS}}      public contact address (may be a city/country + email if a personal site)
```
If not yet provided at execution time, leave the `{{...}}` markers verbatim and flag them to the owner rather than inventing values.

**Secrets never committed:** `~/.cf_blockfire_token`, `backend/.env`, mailbox password, `SESSION_SECRET`, `INGEST_TOKEN`. `backend/.gitignore` already ignores `.env`. The static site and plan/runbook contain no secrets.

**File structure created by this plan:**
```
web/
  site/                     # nginx web root (the only served files)
    index.html              # marketing landing
    contact.html            # contact + legal notice
    privacy.html            # Privacy Policy
    terms.html              # Terms of Service
    assets/style.css        # shared styles
    assets/                 # logo, favicon, optimized screenshots
  docker-compose.yml        # nginx:alpine serving ./site on :8080
  README.md                 # how to run/deploy the static site
docs/runbooks/
  blockfire-web-presence.md # owner-applied bits: Caddy block, DNS table, email steps, prod cutover
backend/.env                # (untracked) prod env for the M20 stack on game2
```

---

## Phase 0 — Preflight (no changes yet)

### Task 0.1: Confirm the edge Caddy's ACME token can issue for blockfire.cc

The unraid Caddyfile issues every cert via `acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}`. That **env token (in the Caddy container) is separate from `~/.cf_blockfire_token`** and must be able to write DNS TXT records for `blockfire.cc`, or the cert fails. This is the single most likely blocker — verify before touching anything.

**Files:** none (verification only).

- [ ] **Step 1: Ask the owner to check the Caddy container's token scope.** Provide this command for the owner to run on unraid (agent does not touch prod):

```bash
# On unraid, find the token the Caddy container uses, then verify it can see blockfire.cc:
CADDY_TOKEN=$(docker exec <caddy_container_name> printenv CLOUDFLARE_API_TOKEN)
curl -s -H "Authorization: Bearer $CADDY_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones?name=blockfire.cc" | python3 -m json.tool | grep -E '"id"|"count"|"name"'
```

Expected: a JSON result containing the `blockfire.cc` zone id. If it returns `"count": 0`, the token is scoped to other zones only.

- [ ] **Step 2: If the token can't see blockfire.cc**, the owner adds the zone to that token in the Cloudflare dashboard (My Profile → API Tokens → edit the Caddy token → add `blockfire.cc` under Zone Resources), or switches it to All Zones. No Caddy restart needed — the token value is unchanged. Re-run Step 1 to confirm `count: 1`.

- [ ] **Step 3: Record the result** in `docs/runbooks/blockfire-web-presence.md` (created in Task 1.4) under a "Preflight" note.

**Gate:** Do not start Phase 1's Caddy block hand-off until this returns the zone. (DNS record creation in Task 1.1 uses the separate blockfire-scoped token and is unaffected — it can proceed in parallel.)

---

## Phase 1 — DNS + edge plumbing + placeholder (prove HTTPS end-to-end)

### Task 1.1: Create apex/www/stats DNS records (Cloudflare-proxied)

**Files:** none in repo (records created via API); values recorded in runbook (Task 1.4).

- [ ] **Step 1: Create the three proxied A records.** Run on game2:

```bash
TOKEN=$(cat ~/.cf_blockfire_token); ZID=0804e36218b5e084483ec6d1a3200c77; IP=178.174.157.185
for NAME in blockfire.cc www.blockfire.cc stats.blockfire.cc; do
  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZID/dns_records" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"$NAME\",\"content\":\"$IP\",\"proxied\":true,\"ttl\":1}" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print("OK" if d["success"] else d["errors"], d.get("result",{}).get("name"))'
done
```

Expected: `OK blockfire.cc`, `OK www.blockfire.cc`, `OK stats.blockfire.cc`.

- [ ] **Step 2: Verify records exist and are proxied.**

```bash
TOKEN=$(cat ~/.cf_blockfire_token); ZID=0804e36218b5e084483ec6d1a3200c77
curl -s -H "Authorization: Bearer $TOKEN" "https://api.cloudflare.com/client/v4/zones/$ZID/dns_records" \
  | python3 -c 'import sys,json;[print(x["type"],x["name"],x["content"],"proxied="+str(x["proxied"])) for x in json.load(sys.stdin)["result"]]'
```

Expected: three A records → `178.174.157.185`, `proxied=True`.

- [ ] **Step 3: Confirm public resolution (Cloudflare edge IPs, since proxied).**

```bash
dig +short blockfire.cc @1.1.1.1; dig +short stats.blockfire.cc @1.1.1.1
```

Expected: Cloudflare anycast IPs (e.g. `104.x`/`172.x`), **not** `178.174.157.185` (proxy hides origin). Empty means propagation still in flight — recheck in a minute.

### Task 1.2: Bring up the static container on game2 with a placeholder page

Standing up the container now (with a placeholder) lets Phase 1 prove the whole path; Task 3 replaces the placeholder with the real site.

**Files:**
- Create: `web/site/index.html` (placeholder, replaced in Task 3)
- Create: `web/docker-compose.yml`
- Create: `web/README.md`

- [ ] **Step 1: Create the web root with a placeholder.** `web/site/index.html`:

```html
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Blockfire</title></head>
<body style="background:#111;color:#eee;font-family:sans-serif;text-align:center;padding:4rem">
<h1>Blockfire</h1><p>Coming soon.</p>
</body></html>
```

- [ ] **Step 2: Create `web/docker-compose.yml`.**

```yaml
services:
  web:
    image: nginx:alpine
    restart: unless-stopped
    ports:
      - "8080:80"
    volumes:
      - ./site:/usr/share/nginx/html:ro
```

- [ ] **Step 3: Create `web/README.md`.**

```markdown
# Blockfire marketing site (static)

Plain static HTML/CSS served by `nginx:alpine`. No build step.

## Run (dev, game2)
    cd web && docker compose up -d --build
    curl -sI localhost:8080        # 200 OK

The unraid edge Caddy reverse-proxies blockfire.cc -> game2:8080 (see
docs/runbooks/blockfire-web-presence.md). Edit files under site/ and they are
served live (read-only bind mount).
```

- [ ] **Step 4: Start it and verify locally.**

```bash
cd web && docker compose up -d && sleep 2 && curl -sI localhost:8080 | head -1
```

Expected: `HTTP/1.1 200 OK`.

- [ ] **Step 5: Commit.**

```bash
git add web/ && git commit -m "feat(web): static site container + placeholder page"
```

### Task 1.3: Author the edge Caddy blocks and hand off to owner

Per the design, the agent prepares the block; the **owner applies it to the production unraid Caddyfile** and reloads. Matches the existing `import cloudflare` orange-proxied pattern verbatim.

**Files:**
- Create/append: `docs/runbooks/blockfire-web-presence.md` (the block + reload command)

- [ ] **Step 1: Write the exact Caddy blocks** into the runbook (see Task 1.4 for the full runbook). The blocks:

```caddy
blockfire.cc {
	import cloudflare
	handle @cloudflare {
		reverse_proxy http://192.168.1.166:8080 {
			header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
		}
	}
	handle { respond "Access Denied" 403 }
}

www.blockfire.cc {
	redir https://blockfire.cc{uri}
}

stats.blockfire.cc {
	import cloudflare
	handle @cloudflare {
		reverse_proxy http://192.168.1.166:8000 {
			header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
		}
	}
	handle { respond "Access Denied" 403 }
}
```

- [ ] **Step 2: Owner applies + reloads.** Runbook instructs the owner:

```bash
# On unraid: append the three blocks to the live Caddyfile, then validate + reload:
docker exec <caddy_container_name> caddy validate --config /etc/caddy/Caddyfile
docker exec <caddy_container_name> caddy reload  --config /etc/caddy/Caddyfile
# (or the container's documented reload path; do NOT restart if reload works)
```

Expected: `validate` prints "Valid configuration"; `reload` exits 0. Caddy fetches the cert via DNS-01 on first request (needs Task 0.1 green).

- [ ] **Step 3: Verify HTTPS end-to-end through the domain** (after owner confirms reload):

```bash
curl -sSI https://blockfire.cc | head -3
curl -sS  https://blockfire.cc | grep -i coming
```

Expected: `HTTP/2 200`, valid cert (no `curl` TLS error), body contains "Coming soon." A `502` means the edge can't reach game2:8080 (check container/firewall); a TLS error means the cert didn't issue (recheck Task 0.1).

### Task 1.4: Write the runbook document

**Files:**
- Create: `docs/runbooks/blockfire-web-presence.md`

- [ ] **Step 1: Create the runbook** containing: the Preflight note (Task 0.1), the full DNS record table (apex/www/stats + the email records added in Phase 4), the Caddy blocks + reload command (Task 1.3), and a "Prod cutover" section (Phase 5). Include the concrete-values table from this plan (minus secrets).

- [ ] **Step 2: Commit.**

```bash
git add docs/runbooks/blockfire-web-presence.md && git commit -m "docs(web): runbook — DNS, edge Caddy blocks, reload"
```

**Phase 1 gate:** `https://blockfire.cc` serves the placeholder over a valid cert.

---

## Phase 2 — M20 stats live on stats.blockfire.cc (no app code change)

### Task 2.1: Create the production env for the M20 stack on game2

**Files:**
- Create: `backend/.env` (untracked — verify it's git-ignored)

- [ ] **Step 1: Generate strong secrets and write `backend/.env`.**

```bash
cd backend
SESSION_SECRET=$(openssl rand -hex 32)
INGEST_TOKEN=$(openssl rand -hex 24)
cat > .env <<EOF
SITE_BASE_URL=https://stats.blockfire.cc
SESSION_SECRET=$SESSION_SECRET
INGEST_TOKEN=$INGEST_TOKEN
ADMIN_STEAM_IDS=76561197991773727
ADMIN_DEV_OPEN=false
REQUIRE_SIGNED_INGEST=true
STEAM_WEB_API_KEY=
EOF
chmod 600 .env
```

Note: `STEAM_WEB_API_KEY` left empty ⇒ Steam name/avatar enrichment stays dormant (fine); login still works via OpenID. `REQUIRE_SIGNED_INGEST=true` means only HMAC-signed game-server reports are accepted — set the matching `INGEST_SIGNING_KEYS` when a real game server reports; for now the site/leaderboard works without ingest.

- [ ] **Step 2: Confirm `.env` is ignored (must print nothing / "ignored").**

```bash
cd backend && git check-ignore .env && echo "IGNORED-OK"
```

Expected: `.env` then `IGNORED-OK`.

### Task 2.2: Deploy the stack and verify through the domain

**Files:** none (uses existing `backend/docker-compose.yml`).

- [ ] **Step 1: Bring the stack up on game2.**

```bash
cd backend && docker compose --env-file .env up -d --build && sleep 8
```

- [ ] **Step 2: Local health + admin-gate checks.**

```bash
curl -s localhost:8000/healthz
curl -s -o /dev/null -w "%{http_code}\n" localhost:8000/admin      # expect 403 (not admin, ADMIN_DEV_OPEN=false)
curl -s -o /dev/null -w "%{http_code}\n" localhost:8000/           # expect 200 (public leaderboard)
```

Expected: `{"status":"ok"}`, `403`, `200`.

- [ ] **Step 3: Verify through the public domain** (edge block from Task 1.3 already routes stats):

```bash
curl -sS https://stats.blockfire.cc/healthz
curl -sSI https://stats.blockfire.cc/ | head -1
```

Expected: `{"status":"ok"}`, `HTTP/2 200`, valid cert.

- [ ] **Step 4: Manual Steam OpenID round-trip (owner or agent-with-browser).** Visit `https://stats.blockfire.cc/login` → redirects to Steam → after auth returns to `stats.blockfire.cc`, sets `bf_session`, and (since SteamID64 is in `ADMIN_STEAM_IDS`) the nav shows the **Admin** link; `/admin` now returns 200 for that session. Record the result in the runbook.

**Phase 2 gate:** `stats.blockfire.cc` healthy over HTTPS; `/admin` 403 for anonymous, 200 after owner Steam login; OpenID realm correct (built from `SITE_BASE_URL`).

---

## Phase 3 — Marketing front page + legal pages

Build the real static site into `web/site/`, replacing the placeholder. Visual polish uses the **frontend-design skill** and iterates via the game2 Xvfb / desktop screenshot loop (`~/bf-shots`); each task below has objective acceptance criteria so "done" is verifiable, not just subjective.

### Task 3.1: Shared shell — head, header, footer, CSS

**Files:**
- Create: `web/site/assets/style.css`
- Create: `web/site/assets/favicon.svg`

- [ ] **Step 1: Write `assets/style.css`** with CSS custom properties for the palette (BattleBit north-star: muted military greens/tans, high-contrast dark base, one accent), system-font stack, a max-width content column, responsive (mobile-first, fl/grid), and shared header/nav + footer styles. Keep it one file, no framework, no external fonts (self-host or system stack — the edge is Cloudflare-proxied but keep it dependency-free for speed).

- [ ] **Step 2: Define the shared footer markup** (copied into every page — this is a 4-page static site, no templating): links to `Home`, `stats.blockfire.cc` ("Stats"), `Contact`, `Privacy`, `Terms`, plus the disclaimer line: `Not affiliated with or endorsed by Valve Corporation. Steam and the Steam logo are trademarks of Valve Corporation.`

- [ ] **Step 3: Verify CSS loads / no 404s** once a page references it (checked in Task 3.2). Commit with Task 3.2.

### Task 3.2: index.html — the landing page

**Files:**
- Modify: `web/site/index.html` (replace placeholder)

- [ ] **Step 1: Build the landing page** with these sections (semantic HTML5, shared header/footer):
  - **Hero:** logo/wordmark, tagline (e.g. "128-player destructible warfare"), primary CTA button **"Wishlist on Steam · Coming Soon"** (links to `#` / Steam store URL once it exists — leave `href="#"` with a `data-note` comment, not a fake URL), secondary "View player stats" → `https://stats.blockfire.cc`.
  - **Features:** 3–4 cards — 128-player Conquest · destructible buildings · tactical combat & classes · dedicated servers.
  - **Screenshot gallery:** responsive grid of optimized screenshots (Task 3.4 supplies the images).
  - **What is Blockfire:** 2–3 sentence blurb drawn from `docs/STATUS.md` line 1 (LAN-playable Godot 4 BattleBit-style, server-authoritative 128p Conquest, destruction, tactical bots).
  - Shared footer.

- [ ] **Step 2: Verify structure locally.**

```bash
curl -s localhost:8080/ | grep -iE "wishlist|stats.blockfire.cc|privacy" | head
```

Expected: matches for the CTA, the stats link, and the footer privacy link.

- [ ] **Step 3: Commit.**

```bash
git add web/site/ && git commit -m "feat(web): landing page + shared shell/styles"
```

### Task 3.3: Legal pages — privacy.html, terms.html, contact.html

Content is grounded in what the M20 app actually does (see spec §"Static site pages, legal & compliance"). Drafts below are good-faith templates, **not legal advice** — owner owns final wording.

**Files:**
- Create: `web/site/privacy.html`, `web/site/terms.html`, `web/site/contact.html`

- [ ] **Step 1: `privacy.html`** — shared shell + these sections, worded from the code's real behaviour:
  - **What we collect:** SteamID64; in-game match/event stats; Steam display-name & avatar (only if Steam Web API enrichment is enabled); IP addresses in server/web logs; a single `bf_session` login cookie.
  - **Why / legal basis:** operating the game service, leaderboards/profiles, and anti-cheat/anomaly detection (legitimate interest).
  - **Retention:** raw events pruned after 90 days (`RAW_EVENT_RETENTION_DAYS`); aggregates kept while the service runs.
  - **Who we share with (sub-processors):** Valve/Steam (OpenID + Web API), Cloudflare (edge/proxy), self-hosted infrastructure, our mail host.
  - **Cookies:** one strictly-necessary session cookie; no tracking/ads; no consent banner required.
  - **Your rights:** access, correction, and **deletion** ("right to be forgotten") by emailing `privacy@blockfire.cc`; deletion is performed manually by player key.
  - **Controller & contact:** `{{OPERATOR_LEGAL_NAME}}`, `{{OPERATOR_JURISDICTION}}`, `{{OPERATOR_ADDRESS}}`, `privacy@blockfire.cc`.
  - **Last updated:** the date this ships.

- [ ] **Step 2: `terms.html`** — shared shell + concise sections: acceptable use / conduct; that cheating or manipulation may lead to **stat removal or bans** (ties to anomaly detection); the service is provided "as is" with no warranty; limitation of liability; that stats are public; governing law `{{OPERATOR_JURISDICTION}}`; contact `hello@blockfire.cc`.

- [ ] **Step 3: `contact.html`** — shared shell + operator identity (`{{OPERATOR_LEGAL_NAME}}`, `{{OPERATOR_ADDRESS}}`), `hello@blockfire.cc` (general) and `privacy@blockfire.cc` (data requests) as `mailto:` links, and a one-line legal-notice / Impressum statement.

- [ ] **Step 4: Verify all four pages return 200 and cross-link.**

```bash
for p in "" contact.html privacy.html terms.html; do
  echo -n "/$p -> "; curl -s -o /dev/null -w "%{http_code}\n" "localhost:8080/$p"; done
curl -s localhost:8080/privacy.html | grep -iE "SteamID|deletion|privacy@blockfire.cc" | head
```

Expected: four `200`s; privacy page mentions SteamID, deletion, and the privacy@ address.

- [ ] **Step 5: Flag any remaining `{{...}}` markers to the owner** (grep and report; do not invent legal identity):

```bash
grep -rno "{{[A-Z_]*}}" web/site/ || echo "no placeholders remain"
```

- [ ] **Step 6: Commit.**

```bash
git add web/site/ && git commit -m "feat(web): privacy, terms, contact (legal/compliance) pages"
```

### Task 3.4: Screenshots — collect, optimize, embed

**Files:**
- Create: `web/site/assets/shots/*.webp` (or `.jpg`)

- [ ] **Step 1: Pick 4–6 strong screenshots** from `~/bf-shots/` (e.g. `m19-p4-lmg-nest`, `m11-current-feel`, the standalone `shot_2026-07-06_*.png`). Prefer combat/scale shots.

- [ ] **Step 2: Optimize for web** (resize to ≤1600px wide, convert to WebP, target <200 KB each). Example:

```bash
mkdir -p web/site/assets/shots
# requires cwebp (libwebp) or imagemagick; install if missing: apt-get install -y webp
cwebp -q 80 -resize 1600 0 ~/bf-shots/m19-p4-lmg-nest/<file>.png -o web/site/assets/shots/01.webp
# ...repeat per chosen shot (02.webp ...)
```

- [ ] **Step 3: Wire the gallery** in `index.html` to `assets/shots/NN.webp` with `loading="lazy"`, `width`/`height` set (avoid layout shift), and descriptive `alt` text.

- [ ] **Step 4: Verify images load and are small.**

```bash
for f in web/site/assets/shots/*.webp; do echo "$(du -h "$f" | cut -f1)  $f"; done
curl -s -o /dev/null -w "%{http_code}\n" localhost:8080/assets/shots/01.webp   # 200
```

Expected: each <200 KB; `200`.

- [ ] **Step 5: Commit.**

```bash
git add web/site/assets/shots/ web/site/index.html && git commit -m "feat(web): optimized screenshot gallery"
```

### Task 3.5: Visual pass + publish-through-domain verification

**Files:** iterate on `web/site/*` and `assets/style.css`.

- [ ] **Step 1: Invoke the frontend-design skill** for the visual pass (typography scale, spacing rhythm, hero impact, feature-card and gallery polish), staying in the BattleBit north-star direction.

- [ ] **Step 2: Screenshot-iterate** using the established game2 loop (Xvfb + a headless browser or the project screenshot harness) or deliver A/B PNGs to `~/bf-shots/web/` and to the desktop per the owner's screenshot workflow. Iterate until the landing page reads as intentional, not templated.

- [ ] **Step 3: Verify the live domain serves the real site** (edge already routing from Phase 1):

```bash
curl -s https://blockfire.cc/ | grep -iE "wishlist|features|blockfire" | head
for p in contact privacy terms; do echo -n "$p: "; curl -s -o /dev/null -w "%{http_code}\n" "https://blockfire.cc/$p.html"; done
curl -sI https://www.blockfire.cc/ | grep -iE "location|HTTP"   # www -> apex redirect
```

Expected: landing content served over HTTPS; three `200`s; `www` returns a redirect to `https://blockfire.cc`.

- [ ] **Step 4: Commit** any polish changes.

```bash
git add web/site/ && git commit -m "polish(web): visual pass on landing + pages"
```

**Phase 3 gate:** `blockfire.cc` serves the real marketing site over HTTPS; all four pages load and cross-link; `www`→apex redirect works; screenshots render and are lightweight; no `{{...}}` markers remain unflagged.

---

## Phase 4 — Email for blockfire.cc (send + receive, catch-all)

Add blockfire.cc as a new domain to the existing multi-domain docker-mailserver on the VPS, create `hello@blockfire.cc` with a catch-all, generate DKIM, and publish the deliverability records via the Cloudflare API. All VPS steps run over the working `root@rapid.rolandot.com` SSH.

### Task 4.1: Create the mailbox + catch-all on the VPS

**Files:** none in repo (changes live on the VPS under `/srv/docker-mailserver`).

- [ ] **Step 1: Detect the docker-mailserver `setup` entrypoint** (newer images use `setup ...`, older `./setup.sh ...`):

```bash
ssh root@rapid.rolandot.com 'docker exec mailserver setup help >/dev/null 2>&1 && echo "USE: docker exec mailserver setup" || echo "USE: legacy ./setup.sh"'
```

- [ ] **Step 2: Create the `hello@blockfire.cc` account** (generate a strong password; store it in the owner's password manager — do NOT commit). Using the `setup` entrypoint:

```bash
PW=$(openssl rand -base64 18)
ssh root@rapid.rolandot.com "docker exec mailserver setup email add hello@blockfire.cc '$PW'"
echo "mailbox password for hello@blockfire.cc: $PW   # give to owner, then clear scrollback"
```

- [ ] **Step 3: Add the catch-all alias** so anything@blockfire.cc lands in hello@:

```bash
ssh root@rapid.rolandot.com "docker exec mailserver setup alias add @blockfire.cc hello@blockfire.cc"
```

- [ ] **Step 4: Verify the account + alias exist.**

```bash
ssh root@rapid.rolandot.com "docker exec mailserver setup email list; docker exec mailserver setup alias list" | grep -i blockfire
```

Expected: `hello@blockfire.cc` listed; alias `@blockfire.cc -> hello@blockfire.cc`.

### Task 4.2: Generate DKIM for blockfire.cc

**Files:** none in repo (key stored on VPS).

- [ ] **Step 1: Generate the DKIM key** (docker-mailserver picks OpenDKIM vs rspamd automatically; `setup config dkim` handles it):

```bash
ssh root@rapid.rolandot.com "docker exec mailserver setup config dkim domain blockfire.cc"
```

- [ ] **Step 2: Read the published DKIM DNS value** (selector is `mail` for OpenDKIM builds; path differs for rspamd — try both):

```bash
ssh root@rapid.rolandot.com '
  cat "/srv/docker-mailserver/config/opendkim/keys/blockfire.cc/mail.txt" 2>/dev/null \
  || cat "/srv/docker-mailserver/config/rspamd/dkim/blockfire.cc."*".public" 2>/dev/null \
  || find /srv/docker-mailserver -path "*blockfire.cc*" -name "*.txt" -o -path "*blockfire.cc*" -name "*.public" 2>/dev/null'
```

Expected: the DKIM public key material. Note the **selector** (OpenDKIM default `mail` ⇒ record name `mail._domainkey.blockfire.cc`). Capture the `p=...` value (may be split across quoted strings — concatenate into one TXT value).

### Task 4.3: Publish MX / SPF / DKIM / DMARC via Cloudflare (DNS-only / grey)

**Files:** none in repo; record the final table in the runbook.

- [ ] **Step 1: Create the MX record** → `mail.rolandot.com` (reuses the existing valid host; **no `mail.blockfire.cc` A-record needed**):

```bash
TOKEN=$(cat ~/.cf_blockfire_token); ZID=0804e36218b5e084483ec6d1a3200c77
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZID/dns_records" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data '{"type":"MX","name":"blockfire.cc","content":"mail.rolandot.com","priority":10,"ttl":1}' \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("OK" if d["success"] else d["errors"])'
```

- [ ] **Step 2: Create SPF, DMARC, and DKIM TXT records.** (MX/TXT are never proxied — they have no `proxied` field.)

```bash
TOKEN=$(cat ~/.cf_blockfire_token); ZID=0804e36218b5e084483ec6d1a3200c77
mk_txt(){ curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZID/dns_records" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data "{\"type\":\"TXT\",\"name\":\"$1\",\"content\":$2,\"ttl\":1}" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("OK" if d["success"] else d["errors"])'; }
# SPF: authorize the hosts in blockfire.cc's MX (mail.rolandot.com -> 188.68.247.11)
mk_txt "blockfire.cc" '"v=spf1 mx -all"'
# DMARC: start at quarantine; aggregate reports to the catch-all
mk_txt "_dmarc.blockfire.cc" '"v=DMARC1; p=quarantine; rua=mailto:postmaster@blockfire.cc; adkim=s; aspf=s"'
# DKIM: paste the exact p=... value captured in Task 4.2 (selector 'mail' assumed)
mk_txt "mail._domainkey.blockfire.cc" '"v=DKIM1; h=sha256; k=rsa; p=<PASTE_DKIM_PUBLIC_KEY>"'
```

- [ ] **Step 3: Verify all records resolve.**

```bash
dig +short MX  blockfire.cc @1.1.1.1
dig +short TXT blockfire.cc @1.1.1.1
dig +short TXT _dmarc.blockfire.cc @1.1.1.1
dig +short TXT mail._domainkey.blockfire.cc @1.1.1.1
```

Expected: MX `10 mail.rolandot.com`; SPF `v=spf1 mx -all`; DMARC present; DKIM `v=DKIM1;...p=...`.

### Task 4.4: Verify deliverability (send + receive)

**Files:** none (record results in runbook).

- [ ] **Step 1: mail-tester.** Get an address from https://mail-tester.com, then send from the VPS-hosted account (via webmail if configured, or `swaks` from any host authenticating as `hello@blockfire.cc`):

```bash
# from a host with swaks; uses SMTP submission (587, STARTTLS) authenticating as hello@
swaks --to test-XXXX@srv1.mail-tester.com --from hello@blockfire.cc \
  --server mail.rolandot.com:587 --tls --auth LOGIN --auth-user hello@blockfire.cc \
  --auth-password '<mailbox_pw>' --header "Subject: blockfire deliverability" --body "hello from blockfire.cc"
```

Expected: mail-tester score **10/10** (SPF/DKIM/DMARC all pass, PTR valid via mail.rolandot.com). Investigate any deduction (usually a DKIM value pasted with a line-break, or DMARC misalignment).

- [ ] **Step 2: Receive test.** Send an email from an external account (e.g. a personal Gmail) to `anything@blockfire.cc` and confirm it lands in the `hello@blockfire.cc` mailbox (via webmail/IMAP). Confirms MX + catch-all.

- [ ] **Step 3: Record results** (mail-tester score, send+receive confirmation) in the runbook.

**Phase 4 gate:** `hello@blockfire.cc` sends (10/10 deliverability) and the catch-all receives; MX/SPF/DKIM/DMARC verified in DNS.

---

## Phase 5 — Land + prod cutover runbook

### Task 5.1: Finish the runbook (prod cutover section)

**Files:**
- Modify: `docs/runbooks/blockfire-web-presence.md`

- [ ] **Step 1: Document the unraid prod cutover** (for when the stacks move off game2): (a) run `backend/` compose + `web/` compose on unraid; (b) change the two `reverse_proxy` upstreams in the Caddyfile from `192.168.1.166:{8000,8080}` to the unraid-local addresses; (c) validate+reload Caddy; (d) re-verify Phase 1–3 gates. Note that DNS/email records do **not** change on cutover.

- [ ] **Step 2: Confirm the final DNS table** (apex/www/stats A + MX/SPF/DKIM/DMARC) is recorded in the runbook, values matching what's live.

- [ ] **Step 3: Commit.**

```bash
git add docs/runbooks/blockfire-web-presence.md && git commit -m "docs(web): prod cutover runbook + final DNS table"
```

### Task 5.2: Land the branch (AGENTS.md §11)

- [ ] **Step 1: Verify the tree is clean and no secrets are staged.**

```bash
git status --short
git ls-files | grep -E 'backend/\.env$|\.cf_blockfire_token' && echo "SECRET LEAKED — STOP" || echo "no secrets tracked"
```

Expected: clean tree; `no secrets tracked`.

- [ ] **Step 2: Run requesting-code-review** on the branch (static site + runbook + plan/spec) before merge.

- [ ] **Step 3: Reconcile onto latest master and merge.**

```bash
git fetch origin -q
git rebase origin/master        # or merge --ff-only if already current
git checkout master && git merge --ff-only blockfire-web-presence
git push origin master
```

- [ ] **Step 4: Confirm push landed.**

```bash
git log origin/master --oneline -5
```

**Phase 5 gate:** `web/`, runbook, spec, and plan are on `origin/master`; no secrets tracked; all prior phase gates green.

---

## Self-review notes

- **Spec coverage:** subdomain stats (P2) ✓ · reuse edge Caddy DNS-01/orange, matching conventions (P1) ✓ · static container not a 2nd edge (P1/P3) ✓ · catch-all mailbox (P4) ✓ · Wishlist CTA (P3.2) ✓ · legal/compliance pages incl. deletion path + Steam disclaimer (P3.3) ✓ · MX→mail.rolandot.com refinement (P4) ✓ · prod-safety env from day one (P2.1) ✓ · prod cutover (P5) ✓ · land to master (P5.2) ✓.
- **Placeholders:** the only intentional fill-ins are the owner's legal identity `{{...}}`, which Task 3.3 Step 5 greps for and flags rather than inventing. DKIM `p=...` value and mailbox password are runtime-captured secrets, not plan gaps.
- **Consistency:** upstreams `game2:8000` (stats) / `game2:8080` (web) used identically in the Caddy block, compose, and verifications; zone id / IPs / mail host reused verbatim from the concrete-values table.
