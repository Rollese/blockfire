# Blockfire Stats Backend (P1 — ingest + DB)

Python/FastAPI + PostgreSQL ingest service for match/event data. See the design spec
`docs/superpowers/specs/2026-07-11-stats-analytics-backend-design.md`.

> **For agents doing game work:** this directory is out of scope — see the root `AGENTS.md`.

## Run (dev, on game2 or locally)
```bash
cd backend
export INGEST_TOKEN=dev-secret
docker compose up --build       # db + api (:8000) + worker
curl -s localhost:8000/healthz  # {"status":"ok"}
```

## Test
```bash
cd backend
docker compose up -d db
export DATABASE_URL='postgresql+asyncpg://blockfire:blockfire@localhost:5432/blockfire_stats'
export INGEST_TOKEN='test-token'
pip install -e '.[dev]'
python -m pytest -v
```

## P2 — Player website

Server-rendered leaderboard + per-player profiles, a public JSON API, and a
dormant-ready "Sign in through Steam" login. All served by the same `api`
service; a background `worker` recomputes rollups from raw events.

### Routes
- `GET /` — HTML leaderboard (top players).
- `GET /players/<player_key>` — HTML player profile (weapon totals + recent
  matches). `player_key` contains a colon, e.g. `name:BotAlpha`,
  `steam:7656...`.
- `GET /api/leaderboard` — JSON leaderboard (`?sort=`, `?limit=`).
- `GET /api/players/<player_key>` — JSON profile (404 if unknown).
- `GET /login` → 302 to Steam OpenID; `GET /login/return` verifies with Steam
  and sets a signed session cookie; `GET /logout` clears it.

### Rollup worker
`python -m worker.run` (the compose `worker` service) periodically rolls raw
ingested events into the per-player/leaderboard views and enriches Steam
identities via the Steam Web API. Enrichment is a no-op without
`STEAM_WEB_API_KEY`.

### Env vars (see `.env.example`)
- `STEAM_WEB_API_KEY` — Steam Web API key for display-name/avatar enrichment
  (worker) and login. Unset ⇒ enrichment dormant.
- `SESSION_SECRET` — signs the `bf_session` login cookie. Default is
  dev-insecure; set a real secret in prod.
- `SITE_BASE_URL` — public base URL used to build the OpenID return/realm.

Login is dormant until a real Steam key + real Steam users exist; the nav shows
"Sign in through Steam" and the public pages work fully without any of these.

### View locally
```bash
cd backend
docker compose up --build
open http://localhost:8000/          # leaderboard
open http://localhost:8000/api/leaderboard
```

## P3 — Admin dashboards

Server-rendered, read-only analytics dashboards for weapon balance, combat
distance/hitzone breakdowns, and a filterable kill-event explorer. Gated
behind an admin auth check; not part of the public site nav unless you're
an admin.

### Routes
- `GET /admin` — overview: weapon balance table + usage distribution +
  headline totals (matches, kill events, ...).
- `GET /admin/combat` — kill-distance histogram, hitzone breakdown, longest
  kills.
- `GET /admin/events` — filterable kill-event explorer
  (`?weapon_id=`, `?min_distance_m=`, `?hitzone=`, `?order=`, `?limit=`).
- `GET /admin/api/*` — the same data as the pages above, as JSON
  (`app/admin_api.py`); useful for scripting or a future SPA.

All `/admin*` routes require `require_admin` (see `app/admin_auth.py`) and
403 for non-admin callers.

### Auth model
Two ways to be recognized as an admin, checked by `is_admin()`:
- **SteamID allowlist**: sign in through Steam (see P2 login above), and
  have your SteamID64 listed in `ADMIN_STEAM_IDS` (comma/space-separated).
- **`ADMIN_DEV_OPEN=1`**: bypasses Steam auth entirely — every caller is
  treated as an admin. **dev/LAN only — this MUST stay false (or unset) in
  any internet-facing deployment**, since it removes all access control from
  `/admin*`.

When signed in (or `ADMIN_DEV_OPEN=1`), the site nav shows an "Admin" link
to `/admin`; it's hidden for everyone else.

### Reach `/admin` locally
```bash
cd backend
ADMIN_DEV_OPEN=1 docker compose up --build
open http://localhost:8000/admin
```

## P4 — Anomaly / cheat detection

The `worker` cycle (and the on-demand `POST /admin/api/anomaly/scan`) flags
outlier **K/D**, **headshot-rate**, and **hit-rate** players into the
`anomaly_flags` review queue. This is the analytics precursor to M9's Layer-4
statistical detection — see
`docs/superpowers/specs/2026-07-11-stats-analytics-backend-design.md` §7 (P4).

### How detection decides
Per metric, a player must first pass a **min-sample gate**
(min deaths+kills for K/D, min hits for hit-rate, min shots for
headshot/hit-rate), then is flagged when its value is
`>= max(absolute_floor, median + K · 1.4826 · MAD)` over the qualifying
population — a robust population statistic (median + scaled MAD) rather than
mean/stddev. When the qualifying population is below `ANOMALY_MIN_POPULATION`
the robust term is skipped and only the absolute floor applies. Severity
(high / med / low) is graded by how far the value sits past the threshold.

### Idempotency
Re-scans update an existing OPEN flag in place (no duplicate rows) and never
resurrect a `confirmed` or `dismissed` flag — triage decisions are final.

### Admin surface
- `GET /admin/api/anomalies` — current flags as JSON.
- `POST /admin/api/anomaly/scan` — run detection on demand.
- `POST /admin/api/anomalies/{id}/review` — confirm/dismiss a flag.
- `GET /admin/anomalies` — HTML review queue (Confirm/Dismiss triage plus a
  "Run scan now" button).

All of these sit behind the same `require_admin` gate as the P3 dashboards
(SteamID allowlist ∪ `ADMIN_DEV_OPEN`).

### Tuning knobs (see `.env.example`)
The detection thresholds, all `${VAR:-default}` in `docker-compose.yml`:
- `ANOMALY_KD_FLOOR` (4.0) — absolute K/D floor.
- `ANOMALY_HEADSHOT_RATE_FLOOR` (0.6) — absolute headshot-rate floor.
- `ANOMALY_HIT_RATE_FLOOR` (0.55) — absolute hit-rate floor.
- `ANOMALY_MIN_DEATHS` (5) / `ANOMALY_MIN_KILLS` (10) — K/D sample gate.
- `ANOMALY_MIN_HITS` (40) — hit-rate sample gate.
- `ANOMALY_MIN_SHOTS` (100) — headshot/hit-rate sample gate.
- `ANOMALY_MIN_POPULATION` (5) — min flagged population before MAD scoring.
- `ANOMALY_MAD_K` (3.5) — modified z-score (MAD) cutoff.
