# M20 Stats Backend — P2: Player Website (rollups + profiles + Steam login)

- **Date:** 2026-07-11
- **Milestone:** M20 — Online Stats & Analytics, phase **P2**
- **Design spec:** `docs/superpowers/specs/2026-07-11-stats-analytics-backend-design.md` (§3 data model, §7 phasing)
- **Builds on:** P1-A ingest API + Postgres (`backend/`, master `0d67240`), P1-B game-server `StatsReporter` (`b0e9c08`)
- **Scope note:** **Backend-only. Zero GDScript changes.** All work is under `backend/` + `docs/`. This cannot
  collide with the concurrent M19 game-code work.

## Owner-ratified decisions (this session)

1. **P2 delivers profiles for ALL players now**, keyed on the existing `player_key` STRING identity
   (`steam:<id>` | `name:<name>`). Works immediately for the bot/LAN `name:` players already in Postgres.
   Steam OpenID login + avatar enrichment are **built but degrade gracefully** until real Steam users exist.
2. **Frontend = FastAPI + Jinja2 server-rendered HTML** (no SPA, no JS build toolchain). Minimal inline/served CSS.
3. **Steam Web API enrichment** (display name + avatar via `GetPlayerSummaries`) is wired via a
   `STEAM_WEB_API_KEY` env var. Owner will supply the key. When unset, enrichment is a no-op and pages show
   the `player_key`/name without an avatar.

## Ground truth (P1 reality the plan MUST match — NOT the spec's original SteamID-PK assumption)

- Identity is **`player_key` STRING PK**, not SteamID. `Player(player_key, steam_id|None, name|None, first_seen, last_seen)`.
- Tables: `players`, `matches`, `match_players` (PK `match_id,player_key`), `match_player_weapons`
  (PK `match_id,player_key,weapon_id`), `events`, `ingested_batches`. Models in `backend/app/models.py`.
- `match_players` columns: team, kills, deaths, assists, downs, revives, captures, neutralizes, xp_earned,
  longest_kill_m, playtime_s, result (`"win"`/`"loss"`/`""`). `match_player_weapons`: shots, hits, kills,
  headshots, damage, time_used_s.
- `backend/app/db.py`: `init_db()` does `Base.metadata.create_all` under an advisory lock. **`create_all`
  only creates MISSING tables**, so new additive tables need no Alembic. Keep Alembic deferred; note it.
- App factory `create_app(settings, sessionmaker)` in `backend/app/main.py`; ingest routes registered via
  `register_ingest_routes(app)` from `backend/app/routes.py`. `app.state.settings` / `app.state.sessionmaker`.
- Config: `backend/app/config.py` pydantic-settings `Settings` (`database_url`, `ingest_token`,
  `raw_event_retention_days`). `.env` file support, `extra="ignore"`.
- Worker: `backend/worker/run.py` — async loop, `prune_old_events` each `PRUNE_INTERVAL_S=3600`, try/except-guarded.
- Tests: **integration-style against a real Postgres**. `backend/tests/conftest.py` provides `app_and_sessionmaker`
  (drops+recreates all tables) and an authed `client` (httpx `ASGITransport`, `Bearer test-token`). `asyncio_mode=auto`.
- P1 deferrals still true: `time_used_s`, assists/captures/neutralizes/xp/playtime often 0; draws mark `"loss"`.

## How to run the backend tests (host has only Python 3.14 + Docker → tests run in a 3.11 container)

The compose Postgres must be up (project `bf-p2`), then run pytest inside `python:3.11-slim` on the compose network:

```bash
cd backend
docker compose -p bf-p2 up -d db        # once; already healthy during this session
docker run --rm --network bf-p2_default -v "$PWD:/srv" -w /srv \
  -v bf-p2-pipcache:/root/.cache/pip python:3.11-slim bash -c \
  "pip install -q -e '.[dev]'; DATABASE_URL='postgresql+asyncpg://blockfire:blockfire@db:5432/blockfire_stats' \
   INGEST_TOKEN='test-token' python -m pytest -q"
```

Baseline before P2: **22 passed**.

## New runtime dependencies (added in Task 10 wiring; pin in `pyproject.toml`)

- `jinja2>=3.1` (templates), `httpx>=0.27` (promote from dev → runtime; Steam Web API + OpenID verify),
  `itsdangerous>=2.1` (signed session cookie).

---

## Task 1 — P2 data model: `player_profiles` + `player_weapon_totals`

**Files:** `backend/app/models.py`, `backend/tests/test_models.py` (extend).

Add two SQLAlchemy models (mirror existing style — `Mapped`/`mapped_column`, timezone-aware datetimes):

- **`PlayerProfile`** `__tablename__="player_profiles"`, PK `player_key: str`. Columns:
  `steam_id: int|None`, `display_name: str|None`, `avatar_url: str|None`,
  `total_kills/total_deaths/total_assists/total_downs/total_revives/total_captures/total_neutralizes: int (default 0)`,
  `wins/losses/matches_played: int (default 0)`, `xp_total: int (default 0)`, `kd_ratio: float (default 0.0)`,
  `total_shots/total_hits/total_headshots: int (default 0)`, `overall_hit_rate: float (default 0.0)`,
  `longest_kill_m: float (default 0.0)`, `favorite_weapon_id: str|None`, `total_playtime_s: int (default 0)`,
  `updated_at: datetime` (timezone-aware).
- **`PlayerWeaponTotal`** `__tablename__="player_weapon_totals"`, PK (`player_key: str`, `weapon_id: str`).
  Columns: `shots/hits/kills/headshots/damage/time_used_s: int (default 0)`, `matches_used: int (default 0)`.

No FK required (rollup tables are derived; keep them decoupled like `events`). Update the `init_db` docstring
note in `db.py` only if needed to say additive rollup tables are created by `create_all` (Alembic still deferred).

**Tests:** extend `test_models.py` — create a `PlayerProfile` and `PlayerWeaponTotal`, commit via the test
sessionmaker, read back, assert columns round-trip and PKs behave (composite PK on weapon totals).

**Acceptance:** models import; tables created by `init_db`; round-trip test passes; full suite green.

---

## Task 2 — Rollup computation core (`rollups.py`)

**Files:** `backend/app/rollups.py` (new), `backend/tests/test_rollups.py` (new).

Implement `async def recompute_profiles(session: AsyncSession, now: datetime | None = None) -> int` that
rebuilds all rollups from `players` + `match_players` + `match_player_weapons`. Returns number of profiles written.

Aggregation (use SQLAlchemy Core `select(func.sum(...))` grouped by `player_key`; a single pass is fine at dev scale):

- Per `player_key` from `match_players`: sum kills, deaths, assists, downs, revives, captures, neutralizes,
  xp_earned, playtime_s; `max(longest_kill_m)`; `matches_played = count(distinct match_id)`;
  `wins = count(result=='win')`, `losses = count(result=='loss')`.
- Per (`player_key`,`weapon_id`) from `match_player_weapons`: sum shots, hits, kills, headshots, damage,
  time_used_s; `matches_used = count(distinct match_id)` → upsert `player_weapon_totals`.
- Per `player_key` weapon totals: `total_shots = Σshots`, `total_hits = Σhits`, `total_headshots = Σheadshots`.
- Derived: `kd_ratio = round(total_kills / max(total_deaths,1), 3)`;
  `overall_hit_rate = round(total_hits/total_shots, 4)` if `total_shots>0` else `0.0`;
  `favorite_weapon_id` = the player's weapon with the most **shots** (tiebreak: most kills, then weapon_id
  asc for determinism); `None` if the player fired nothing.
- `display_name` default = `players.name` (fallback identity label). `steam_id` copied from `players`.
- **Idempotent upsert**: insert new `PlayerProfile`/`PlayerWeaponTotal` rows or update existing in place.
  On UPDATE of an existing profile, **do NOT overwrite `avatar_url`** and only set `display_name` when it is
  currently NULL (Steam enrichment in Task 4 owns those two fields for steam players and must not be clobbered
  by a later recompute). Always refresh `updated_at`.

**Tests (`test_rollups.py`):** seed via the ingest layer or direct model inserts — 2 matches, 2–3 players
(mix of `name:` keys), multiple weapons. Call `recompute_profiles`. Assert: summed kills/deaths; `kd_ratio`;
`wins`/`losses`; `matches_played`; `overall_hit_rate` (e.g. 150 hits / 420 shots = 0.3571); `favorite_weapon_id`
picks the highest-shots weapon; `player_weapon_totals` rows correct. Assert a second `recompute_profiles` call is
idempotent (same numbers, no duplicate rows) and preserves a manually-set `avatar_url`.

**Acceptance:** rollup math correct + idempotent + avatar preservation; suite green.

---

## Task 3 — Config additions

**Files:** `backend/app/config.py`, `backend/tests/test_config.py` (extend), `backend/.env.example` (extend).

Add to `Settings` (all with dev-safe defaults so tests and no-config dev boots don't break):
- `steam_web_api_key: str | None = None`
- `session_secret: str = "dev-insecure-change-me"`
- `site_base_url: str = "http://localhost:8000"` (OpenID realm / return_to base)

Add the three keys to `.env.example` with comments (key blank/commented). **Tests:** defaults apply when unset;
env overrides parse. Full suite green.

---

## Task 4 — Steam Web API enrichment (`steam_api.py`)

**Files:** `backend/app/steam_api.py` (new), `backend/tests/test_steam_api.py` (new).

- `async def fetch_summaries(client: httpx.AsyncClient, api_key: str, steam_ids: list[int]) -> dict[int, dict]`
  → calls `https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/?key=..&steamids=csv` (batch ≤100 ids
  per call; chunk if more). Returns `{steam_id: {"display_name": personaname, "avatar_url": avatarfull}}`.
  Tolerate missing players / partial responses.
- `async def enrich_profiles(session, api_key: str | None, client_factory=...) -> int` — selects
  `player_profiles` rows with a non-null `steam_id`, fetches summaries, updates `display_name` + `avatar_url`.
  **No-op returning 0 when `api_key` is falsy** (the current all-`name:` state). Returns count enriched.

**Tests:** inject a fake httpx client / transport returning a canned `GetPlayerSummaries` JSON; assert profiles
with a `steam_id` get `display_name`/`avatar_url` set; assert `enrich_profiles(..., api_key=None)` returns 0 and
touches nothing; assert `name:`-only profiles (steam_id NULL) are skipped. No real network in tests.

**Acceptance:** enrichment updates steam rows, is a clean no-op without a key, never hits the network in tests; suite green.

---

## Task 5 — Worker rollup + enrichment pass

**Files:** `backend/worker/run.py`, `backend/tests/test_worker.py` (new).

Refactor the worker loop for testability without changing prune behavior:
- Extract `async def run_cycle(session_factory, settings) -> dict` that: (a) prunes old events, (b) calls
  `recompute_profiles`, (c) calls `enrich_profiles` (no-op without key). Each step try/except-guarded and logged;
  a failure in one step must not skip the others. Returns a small stats dict (`{pruned, profiles, enriched}`).
- `main()` loop calls `run_cycle` every `ROLLUP_INTERVAL_S` (add constant, e.g. 30s for dev responsiveness;
  keep prune effectively hourly by only pruning every N cycles, OR just prune every cycle — pruning is cheap and
  idempotent, so prune-every-cycle is acceptable and simpler; choose the simpler and note it).

**Tests:** seed a match, run `run_cycle` once against the test DB, assert `player_profiles` populated and the
returned stats dict reflects it. Assert a raised error inside recompute (monkeypatched) still lets prune/enrich run.

**Acceptance:** one cycle produces rollups; step isolation holds; suite green.

---

## Task 6 — Profile read layer (`profiles.py`)

**Files:** `backend/app/profiles.py` (new), `backend/tests/test_profiles.py` (new).

Pure read helpers returning plain dicts (no ORM leakage to the view layer):
- `get_profile(session, player_key) -> dict | None`
- `list_leaderboard(session, limit=50, sort="kills") -> list[dict]` — sortable by `kills`/`kd`/`hit_rate`/`wins`;
  reads `player_profiles`. Deterministic tiebreak (player_key asc).
- `get_weapon_totals(session, player_key) -> list[dict]` — from `player_weapon_totals`, each with a computed
  per-weapon `hit_rate`, sorted by shots desc.
- `get_recent_matches(session, player_key, limit=10) -> list[dict]` — join `match_players`+`matches`, newest
  first (`matches.ended_at` desc, nulls last), returning map/mode/result/kills/deaths/ended_at.

**Tests:** seed + `recompute_profiles`, assert each helper's shape/ordering/values; `get_profile` returns None
for an unknown key.

**Acceptance:** helpers correct + deterministic ordering; suite green.

---

## Task 7 — JSON API routes

**Files:** `backend/app/web_api.py` (new) with `register_api_routes(app)`, `backend/tests/test_web_api.py` (new).

Public (no auth) JSON endpoints consuming Task 6 helpers:
- `GET /api/leaderboard?sort=&limit=` → `{players: [...]}`.
- `GET /api/players/{player_key:path}` → profile + `weapons` + `recent_matches`; **404** when unknown.

Use the `{player_key:path}` converter so `name:BotAlpha` (contains `:`) routes correctly. **Tests:** seed +
recompute, hit endpoints via an unauthenticated httpx client (note: existing `client` fixture sends a bearer
header — that's harmless for public routes; add a plain client or reuse `client`), assert JSON shape + 404.

**Acceptance:** endpoints return correct JSON, 404 on miss, `:`-keys route; suite green.

---

## Task 8 — Jinja2 templates + web page routes

**Files:** `backend/app/web.py` (new) with `register_web_routes(app)`, `backend/app/templates/{base,index,profile}.html`,
`backend/app/static/style.css`, `backend/tests/test_web_pages.py` (new). Add `jinja2` usage (dep pinned in Task 10).

- Configure `Jinja2Templates(directory=.../templates)`; mount `/static`.
- `GET /` → leaderboard table (top players: name/key, kills, deaths, K/D, hit-rate, wins). Links to profiles.
- `GET /players/{player_key:path}` → profile page: header (avatar if present, else placeholder; display_name/key),
  summary stat grid, weapon breakdown table (weapon_id, shots, hits, hit-rate, kills, headshots), recent matches.
  **404** page for unknown key.
- Templates use `base.html` (title, `/static/style.css` link, nav with login state — see Task 9; until then a
  plain nav). Keep CSS minimal, dark, readable; theme not critical.

**Tests:** seed + recompute, GET `/` asserts 200 + a seeded player's name in HTML; GET `/players/<key>` asserts
200 + a weapon label + a stat value; unknown key → 404.

**Acceptance:** pages render with real data; suite green.

---

## Task 9 — Steam OpenID 2.0 login (dormant-ready)

**Files:** `backend/app/steam_openid.py` (new) with `register_auth_routes(app)`, `backend/tests/test_openid.py` (new).
Deps `httpx` + `itsdangerous` (pinned Task 10).

Standard "Sign in through Steam" flow:
- `GET /login` → 302 to `https://steamcommunity.com/openid/login` with OpenID 2.0 params
  (`openid.ns`, `openid.mode=checkid_setup`, `openid.return_to = {site_base_url}/login/return`,
  `openid.realm = {site_base_url}`, identifier + claimed_id = the OP identifier select URL).
- `GET /login/return` → verify the assertion by POSTing the params back with `openid.mode=check_authentication`
  to Steam and requiring `is_valid:true`; extract the 64-bit SteamID from `openid.claimed_id`
  (`https://steamcommunity.com/openid/id/<steamid64>`). On success set a signed session cookie
  (`itsdangerous.URLSafeSerializer(session_secret)` storing `{"steam_id": <int>}`), redirect to
  `/players/steam:<id>`. On failure → 401/redirect to `/`.
- `GET /logout` → clear the cookie, redirect `/`.
- Helper `current_steam_id(request) -> int | None` reads+verifies the cookie (for nav "your profile" highlight).
  Public pages never require login.

**Tests:** monkeypatch the verify HTTP call to return `is_valid:true`/`false`; assert claimed_id parsing yields
the right steam_id; assert a valid return sets a signed cookie and redirects to the steam profile; assert an
invalid assertion is rejected; assert `current_steam_id` round-trips a signed cookie and rejects a tampered one.
No real network.

**Acceptance:** login flow correct + safely signed + verification enforced (mocked); suite green.

---

## Task 10 — Integration wiring

**Files:** `backend/app/main.py`, `backend/pyproject.toml`, `backend/docker-compose.yml`, `backend/.env.example`,
`backend/README.md`, `backend/tests/test_health.py` (or a new `test_app_wiring.py`).

- `create_app` also calls `register_api_routes`, `register_web_routes`, `register_auth_routes`. Mount `/static`.
- `pyproject.toml`: add runtime deps `jinja2>=3.1`, `httpx>=0.27`, `itsdangerous>=2.1` (remove `httpx` from
  dev-only if promoting; keep pytest/pytest-asyncio in dev). Ensure `templates`/`static` ship in the image
  (add `COPY app ./app` already covers them since they live under `app/`; verify Dockerfile copies them —
  they're under `app/` so the existing `COPY app ./app` suffices).
- `docker-compose.yml`: pass `STEAM_WEB_API_KEY`, `SESSION_SECRET`, `SITE_BASE_URL` env to `api` + `worker`
  (worker needs `STEAM_WEB_API_KEY` for enrichment). Use `${VAR:-default}` form.
- `.env.example`: document the three new vars.
- `README.md`: add a "P2 — Player website" section (routes, how to view `/`, login flow, env vars).
- **Tests:** app boots with all routers; `/healthz` still ok; `/` and `/api/leaderboard` reachable on a fresh
  (empty) DB (return empty gracefully, not 500).

**Acceptance:** full app wires up; empty-DB pages don't 500; suite green.

---

## Task 11 — Live gate + evidence

**Files:** `docker/run-stats-p2-gate.sh` (new, reuse P1 gate infra for the bot match), `docs/gate-evidence/2026-07-11-stats-p2.md` (new).

Gate (run on game2): `docker compose -p bf-p2 up --build` (db+api+worker). Play one bot match on conquest_town
with the game server's `StatsReporter` pointed at `http://localhost:8000` (reuse the P1-B gate's server+bot
two-process launch; a fresh worktree needs the native snapshot-encoder `.so` copied in — `target/` is gitignored).
Wait for the worker to roll up (≤ one `ROLLUP_INTERVAL_S`). Then assert:
- `GET /api/leaderboard` returns the bot players with non-zero kills.
- `GET /api/players/name:<bot>` returns a profile whose `total_kills` etc. **equal a direct SQL aggregate** over
  `match_players` for that key (prove the rollup is faithful).
- `GET /` and `GET /players/name:<bot>` return 200 HTML containing the player and a weapon.
- Enrichment path is a clean no-op with no `STEAM_WEB_API_KEY` (log shows `enriched=0`), and the login route
  redirects to Steam (302) — dormant-but-present.
Capture queries + outputs + a PASS/FAIL verdict in the evidence doc.

**Acceptance:** live bot match → rollups → web/JSON pages serve faithful numbers; evidence committed.

---

## Landing (AGENTS.md §11, after Task 11 green)

Backend-only diff → conflicts with the concurrent M19 game work are near-impossible. `git fetch`; reconcile onto
whatever `origin/master` is then (detached-HEAD `--no-ff` merge so the M19 agent's main checkout is never touched,
per the P1-B landing pattern); full backend suite green + gate PASS; `git push origin HEAD:master`. Update the
M20 memory + index. Remove the worktree.
```
