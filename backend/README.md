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
