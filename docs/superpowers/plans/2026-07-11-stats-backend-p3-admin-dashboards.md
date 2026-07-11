# M20 Stats Backend — P3: Dev Admin Dashboards (weapon balance + combat/kill-distance + edge-case explorer)

- **Date:** 2026-07-11
- **Milestone:** M20 — Online Stats & Analytics, phase **P3**
- **Design spec:** `docs/superpowers/specs/2026-07-11-stats-analytics-backend-design.md` (§3 data model, §6 security, §7 phasing: "P3 — Dev admin dashboards. Weapon balance tables, usage/hit-rate distributions, kill-distance and edge-case explorers over `events`; admin auth.")
- **Builds on:** P1 ingest+PG (`0d67240`/`b0e9c08`), P2 website (rollups/profiles/JSON/Jinja2/Steam OpenID, master `280b5bb`).
- **Scope note:** **Backend-only. Zero GDScript changes.** All work is under `backend/` + `docs/`. Cannot
  collide with the concurrent M19 game-code work (different files, different subtree).

## Owner-ratified direction (carried from M20 memory)

- Near-term driver is **dev balancing analytics** from bot/LAN playtests. Players in Postgres right now are
  `name:` keys (bots/LAN); there are **no real Steam users yet**, so a pure SteamID-allowlist admin gate is
  unreachable in the current dev environment. P3 therefore ships the spec's SteamID allowlist **plus** a
  dev-only escape hatch (see Task 1) so the dashboards are usable/gate-testable today and lock down cleanly
  in prod. This mirrors P2's "built but degrades gracefully until real Steam users exist" pattern.
- Frontend stays **FastAPI + Jinja2 server-rendered** (no SPA / JS build). Reuse the P2 `base.html` + `style.css`.

## Ground truth (P2 reality the plan MUST match)

- **Identity** is `player_key` STRING (`steam:<id>` | `name:<name>`), never a SteamID PK.
- Tables (`backend/app/models.py`): `players`, `matches`, `match_players` (PK `match_id,player_key`),
  `match_player_weapons` (PK `match_id,player_key,weapon_id`: `shots,hits,kills,headshots,damage,time_used_s`),
  `events`, `player_profiles`, `player_weapon_totals`, `ingested_batches`.
- **`events`** columns: `event_id` (BigInt PK autoincrement), `match_id` (String, indexed), `tick` (Int),
  `type` (String, indexed), `actor_key` / `target_key` (String|None), `weapon_id` (String|None),
  `payload` (**JSONB**), `created_at` (tz-aware, indexed). NO FK.
- **Producer reality (P1-B `server/stats/stats_buffer.gd`):** the only event type currently emitted is
  **`type="kill"`**. Its `payload` = `{"distance_m": float, "hitzone": "head"|"body",
  "actor_pos": [x,y,z], "target_pos": [x,y,z]}`. `weapon_id` = the **variant** key lowercased
  (`m4a2`, `m245 saw`, …). Headshot info lives in BOTH `match_player_weapons.headshots` (counter layer)
  and `events.payload.hitzone == "head"` (forensic layer). Plan the events read layer around kill events;
  write it type-agnostically (filter `type=='kill'`) so future event types don't break it.
- **App factory** `create_app(settings, sessionmaker)` in `main.py`; routes registered via
  `register_ingest_routes` / `register_api_routes` / `register_auth_routes` / `register_web_routes`.
  `app.state.settings`, `app.state.sessionmaker`. Each web/api route opens its own `async with sm() as session`.
- **Auth building blocks (P2 `steam_openid.py`):** `current_steam_id(request) -> int | None` reads the signed
  `bf_session` cookie. Reuse it verbatim for admin identity.
- **Config** (`config.py`, pydantic-settings, `.env` support, `extra="ignore"`): `database_url`, `ingest_token`,
  `raw_event_retention_days`, `steam_web_api_key`, `session_secret`, `site_base_url`.
- **Read-layer convention (P2 `profiles.py`):** pure async helpers return plain dicts / lists of dicts, no ORM
  objects leaked. `player_key:path` route converter keeps the colon in one path segment. Templates autoescape
  (no `|safe`), None-guarded. Follow all of this.
- P1 deferrals still true: `time_used_s`/assists/captures/xp/playtime often 0; draws mark `"loss"`; fall/sentinel
  weapon → `"ar"` key. The dashboards must render gracefully over sparse/zero columns.

## How to run the backend tests (host has only Python 3.14 + Docker → tests run in a 3.11 container)

Use a **fresh compose project `bf-p3`** (isolated from the leftover `bf-p2` volumes). Bring up Postgres, then
run pytest inside `python:3.11-slim` on the compose network:

```bash
cd backend
docker compose -p bf-p3 up -d db
docker run --rm --network bf-p3_default -v "$PWD:/srv" -w /srv \
  -v bf-p3-pipcache:/root/.cache/pip python:3.11-slim bash -c \
  "pip install -q -e '.[dev]'; DATABASE_URL='postgresql+asyncpg://blockfire:blockfire@db:5432/blockfire_stats' \
   INGEST_TOKEN='test-token' python -m pytest -q"
```

`docker-compose.yml` default POSTGRES creds are `blockfire:blockfire` / db `blockfire_stats`. Baseline before
P3 = the full P2 suite (**73 passed** expected; re-run to confirm the clean baseline before Task 1).

## No new runtime dependencies

P3 reuses jinja2 / itsdangerous / httpx already pinned in P2. Do **not** add packages.

## Test style

Integration-style against real Postgres via `conftest.py` (`app_and_sessionmaker` drops+recreates tables;
authed `client` = httpx `ASGITransport`, `Bearer test-token`; `asyncio_mode=auto`). Seed admin-analytics tests
by inserting `Match` / `MatchPlayer` / `MatchPlayerWeapon` / `Event` rows directly via the test sessionmaker
(same as `test_rollups.py`). For admin-gate tests, drive the ASGI `client` with/without a valid `bf_session`
cookie and with `admin_dev_open` on/off.

---

## Task 1 — Config: admin allowlist + dev-open escape hatch

**Files:** `backend/app/config.py`, `backend/tests/test_config.py` (extend), `backend/.env.example` (extend).

Add to `Settings` (dev-safe defaults so tests/no-config boots don't break):

- `admin_steam_ids: str = ""` — a **comma/space-separated** list of admin SteamID64s as raw env string
  (pydantic-settings can't parse a bare CSV into `set[int]` reliably, so keep the field a `str` and expose a
  parsed accessor). Add a method/property `admin_steam_id_set(self) -> frozenset[int]` that splits on commas
  and whitespace, ignores blanks, and `int()`s each token (skip/raise-free on empties). Return `frozenset`.
- `admin_dev_open: bool = False` — when `True`, admin routes are open **without** Steam auth. **Dev/LAN only.**
  Document in a comment that this MUST stay `False` in any internet-facing deploy.

Extend `.env.example` with both keys (blank/commented) and the dev-open warning.

**Tests:** `admin_steam_id_set` parses `"7656119..., 7656119..."` → frozenset of ints; empty string → empty
frozenset; whitespace/trailing-comma tolerated. `admin_dev_open` defaults False; env override parses truthy.

**Acceptance:** config parses; accessor correct; full suite green.

---

## Task 2 — Admin auth guard (`admin_auth.py`)

**Files:** `backend/app/admin_auth.py` (new), `backend/tests/test_admin_auth.py` (new).

Implement, reusing P2's `current_steam_id`:

- `def is_admin(request: Request) -> bool` — returns `True` iff
  `request.app.state.settings.admin_dev_open` **OR** `current_steam_id(request)` is not None and is in
  `request.app.state.settings.admin_steam_id_set()`. No DB access.
- `def require_admin(request: Request) -> None` — a FastAPI dependency that calls `is_admin`; on False raises
  `HTTPException(status_code=403, detail="admin access required")`. (403 not 401/redirect: admin is an API-ish
  surface; unauthenticated humans still see a clear refusal. HTML pages may catch and render a friendly 403 —
  handled in Task 6, but the dependency itself just raises 403.)

**Tests (`test_admin_auth.py`):** build an app/request via a small helper or the ASGI `client`:
- `admin_dev_open=True` → `is_admin` True even with no cookie.
- `admin_dev_open=False`, no cookie → False.
- `admin_dev_open=False`, valid `bf_session` cookie for a steam_id **in** the allowlist → True; **not in** → False.
  (Sign a cookie with the same `URLSafeSerializer(secret, salt="session")` P2 uses; import `COOKIE_NAME` /
  `_serializer` from `steam_openid` or reconstruct with the settings `session_secret`.)

**Acceptance:** all gate truth-table cases pass; suite green.

---

## Task 3 — Weapon-balance read layer (`admin_stats.py`)

**Files:** `backend/app/admin_stats.py` (new), `backend/tests/test_admin_stats.py` (new).

Pure async read helpers returning dicts (mirror `profiles.py`). Aggregate over **all** `match_player_weapons`
(the counter layer — no shot firehose needed):

- `async def weapon_balance(session) -> list[dict]` — GROUP BY `weapon_id`, one row per weapon:
  - `weapon_id`
  - `total_shots`, `total_hits`, `total_kills`, `total_headshots`, `total_damage` (SUMs)
  - `users` = `count(distinct player_key)`
  - `matches` = `count(distinct match_id)`
  - `hit_rate` = `round(hits/shots, 4)` (0.0 if shots==0)
  - `headshot_rate` = `round(headshots/hits, 4)` (0.0 if hits==0)  — share of hits that were headshots
  - `damage_per_hit` = `round(damage/hits, 2)` (0.0 if hits==0)
  - `kills_per_match` = `round(kills/matches, 3)` (0.0 if matches==0)
  - `usage_pct` = `round(shots / TOTAL_shots_all_weapons, 4)` (0.0 if grand total 0) — usage distribution
  Order by `total_kills` DESC, then `weapon_id` ASC (deterministic).
  Do the SUM/COUNT-distinct in SQL (SQLAlchemy Core `func.sum`, `func.count(distinct(...))`); compute the
  derived ratios + `usage_pct` in Python from the fetched rows (needs the grand-total pass — fetch rows once,
  then compute the grand total and per-row ratios). Keep it a single query + Python post-pass.

**Tests:** seed 2 matches, ≥2 players, ≥2 weapons with known shots/hits/kills/headshots/damage. Assert the SUMs,
`users`/`matches` distinct counts, `hit_rate`/`headshot_rate`/`damage_per_hit`/`kills_per_match`/`usage_pct` math,
and the kills-DESC ordering. Assert an all-zero / empty table → `[]` (no divide-by-zero).

**Acceptance:** aggregate + ratio math correct; empty-safe; suite green.

---

## Task 4 — Combat / events read layer (extend `admin_stats.py`)

**Files:** `backend/app/admin_stats.py` (extend), `backend/tests/test_admin_stats.py` (extend).

Read helpers over the **`events`** forensic layer (filter `Event.type == "kill"`; write type-agnostically so
new event types later don't crash these). Read `distance_m`/`hitzone` out of the JSONB `payload`.

- `async def kill_distance_stats(session) -> dict` — over all kill events:
  `count`, `avg_m`, `min_m`, `max_m`, and percentiles `p50_m`, `p90_m`, `p99_m`, plus a `histogram`:
  a list of `{"bucket": "0-10", "count": N}` over fixed distance bands
  (`0-10, 10-25, 25-50, 50-100, 100-200, 200+` metres). Prefer computing avg/min/max in SQL
  (`func.avg/min/max` on `(payload->>'distance_m')::float`); percentiles + histogram can be Python over the
  fetched distances (dev-scale data — a single `SELECT (payload->>'distance_m')::float` list is fine). Round
  metres to 1 dp. Empty → `{"count": 0, ...zeros..., "histogram": []}`.
- `async def hitzone_breakdown(session) -> dict` — over kill events: `total`, `head`, `body`,
  `headshot_rate` = `round(head/total, 4)` (0.0 if total 0). (Cross-check vs the counter layer's headshots.)
- `async def longest_kills(session, limit: int = 20) -> list[dict]` — top kill events by `distance_m` DESC:
  each `{match_id, weapon_id, actor_key, target_key, distance_m, hitzone, tick}`. `limit` clamped `1..100`.

**Tests:** seed kill events with known distances (e.g. 5, 12, 40, 150, 300) + hitzones. Assert `count`,
`avg_m`, `min_m`/`max_m`, `p50/p90/p99` on the known set, histogram bucket counts, hitzone `head`/`body`/rate,
and `longest_kills` ordering + limit clamp. Assert empty-events → zeroed dict / `[]`.

**Acceptance:** distance stats + histogram + hitzone + longest-kills correct and empty-safe; suite green.

---

## Task 5 — Edge-case explorer read layer (extend `admin_stats.py`)

**Files:** `backend/app/admin_stats.py` (extend), `backend/tests/test_admin_stats.py` (extend).

A parameterized kill-event query surface for hunting balance/forensic edge cases (the read side of what P4 will
later automate). No flagging/queue here (that is P4) — just filtered reads.

- `async def query_kill_events(session, *, weapon_id: str | None = None, min_distance_m: float | None = None,
  hitzone: str | None = None, order: str = "distance", limit: int = 50) -> list[dict]` —
  filter kill events by optional `weapon_id`, `min_distance_m` (`(payload->>'distance_m')::float >= x`),
  and `hitzone`. `order` ∈ {`"distance"` (payload distance DESC), `"recent"` (`created_at` DESC / `tick` DESC)},
  unknown → `"distance"`. `limit` clamped `1..200`. Rows same shape as `longest_kills` plus `created_at`.
  Deterministic tiebreak by `event_id`.
- `async def weapon_outliers(session) -> list[dict]` — reuse `weapon_balance` and surface per-weapon
  ratios useful for outlier spotting: return each weapon's `weapon_id, hit_rate, headshot_rate, kills_per_match,
  users, total_kills` sorted by `headshot_rate` DESC (a classic cheat/edge signal) then `hit_rate` DESC.
  (Thin projection over Task 3 — do not re-query; call `weapon_balance` and reshape.)

**Tests:** seed varied kill events; assert `query_kill_events` filters (weapon, min_distance, hitzone), both
orderings, and limit clamp; assert `weapon_outliers` ordering by headshot_rate. Empty-safe.

**Acceptance:** filtered explorer + outlier projection correct; suite green.

---

## Task 6 — Admin JSON API (`admin_api.py`)

**Files:** `backend/app/admin_api.py` (new), `backend/tests/test_admin_api.py` (new).

`def register_admin_api_routes(app)`, all routes **`Depends(require_admin)`** and under `/admin/api`:

- `GET /admin/api/weapons` → `{"weapons": weapon_balance(...)}`
- `GET /admin/api/combat` → `{"kill_distance": kill_distance_stats(...), "hitzone": hitzone_breakdown(...),
  "longest_kills": longest_kills(...)}`
- `GET /admin/api/events?weapon_id=&min_distance_m=&hitzone=&order=&limit=` → `{"events": query_kill_events(...)}`
  (coerce/validate query params; clamp limit in the read layer).
- `GET /admin/api/outliers` → `{"weapons": weapon_outliers(...)}`

Each opens its own `async with request.app.state.sessionmaker() as session`. Register in `main.py` (Task 7).

**Tests (`test_admin_api.py`):** with `admin_dev_open=True` (set on the test `Settings`) → 200 + expected JSON
shape after seeding. With `admin_dev_open=False` and no cookie → **403** for every `/admin/api/*` route. With a
signed cookie for an allowlisted steam_id → 200. (The `conftest` `client` app is built from a `Settings` you may
need to parameterize — add a fixture or build a second app with `admin_dev_open=True` via `create_app(settings=…,
sessionmaker=sm)` sharing the same `sm`, so seeded data is visible. Document the approach in the test.)

**Acceptance:** JSON shapes correct; 403 gate enforced on all admin API routes; suite green.

---

## Task 7 — Admin HTML dashboards (`admin_web.py` + templates)

**Files:** `backend/app/admin_web.py` (new), `backend/app/templates/admin_base.html`,
`admin_index.html`, `admin_combat.html`, `admin_events.html` (new), `backend/app/static/style.css` (extend),
`backend/tests/test_admin_web.py` (new).

`def register_admin_web_routes(app)` — Jinja2 (reuse the `Jinja2Templates(directory=app/templates)` pattern;
`admin_base.html` extends the P2 look via the shared `/static/style.css`). All routes `Depends(require_admin)`:

- `GET /admin` → dashboard home: the **weapon balance table** (all columns from Task 3) + a compact
  usage-distribution view (usage_pct bar or sorted list) + headline totals (matches, players, kills, events).
  Add a tiny `admin_summary(session)` helper (counts) either in `admin_stats.py` or inline in the route.
- `GET /admin/combat` → kill-distance stats + histogram (render buckets as simple bars via inline width %,
  no JS) + hitzone breakdown + longest-kills table.
- `GET /admin/events` → edge-case explorer: an HTML `<form method=get>` with weapon_id / min_distance_m /
  hitzone / order / limit inputs, rendering `query_kill_events` results in a table. Preserve submitted filter
  values in the form.

Templates: autoescape (no `|safe`), None-guard every optional field, `{% if not rows %}` empty states. Reuse
`table.stats` / `.stat-grid` / `.stat` classes; add a minimal `.bar`/`.admin-nav` rule set to `style.css`.
Add an admin nav strip (links: Overview / Combat / Events explorer). Do **not** URL-encode raw weapon keys into
`min_distance` links — the explorer is a GET form, values flow as query params (safe).

**Tests (`test_admin_web.py`):** `admin_dev_open=True` → `GET /admin`, `/admin/combat`, `/admin/events` return
200 `text/html` containing seeded weapon_id and expected headers; `/admin/events?weapon_id=…&min_distance_m=…`
filters the rendered rows. `admin_dev_open=False`, no cookie → **403** for all three. Empty-DB → 200 with empty
states (no crash).

**Acceptance:** pages render with real data, filter form works, 403 gate enforced, empty-safe; suite green.

---

## Task 8 — Integration wiring + docs

**Files:** `backend/app/main.py`, `backend/app/web.py` (nav slot only), `backend/app/templates/base.html`,
`backend/docker-compose.yml`, `backend/.env.example`, `backend/README.md`.

- `main.py`: import + call `register_admin_api_routes(app)` and `register_admin_web_routes(app)` (after the P2
  route registrations). Keep local-import-inside-factory style to avoid cycles.
- `base.html`: in the `nav`, show an **Admin** link only when the viewer is an admin. The web routes already
  pass `current_steam_id`; add an `is_admin` boolean to the `/` and `/players/...` template contexts
  (`web.py`) computed via `admin_auth.is_admin(request)`, and render `{% if is_admin %}<a href="/admin">Admin</a>{% endif %}`.
- `docker-compose.yml`: pass `ADMIN_STEAM_IDS` and `ADMIN_DEV_OPEN` env through to the `api` service
  (default unset/false), mirroring how P2 passed `STEAM_WEB_API_KEY` etc.
- `.env.example`: ensure both admin keys present with the dev-open warning (from Task 1; confirm here).
- `README.md`: add a **P3 — Admin dashboards** section: routes list, the SteamID-allowlist + `ADMIN_DEV_OPEN`
  auth model (with the "dev/LAN only" warning), and how to reach `/admin` locally (`ADMIN_DEV_OPEN=1`).

**Tests:** existing suite still green; add a small assertion that the `/` page shows the Admin link when
`admin_dev_open=True` and hides it when False (extend `test_admin_web.py` or `test_health`/web test).

**Acceptance:** routes wired; nav gates on admin; docs updated; **full suite green**.

---

## Task 9 — Full-stack P3 gate + evidence

**Files:** `docker/run-stats-p3-gate.sh` (new), `docs/gate-evidence/2026-07-11-stats-p3.md` (new).

Mirror the P2 gate (`docker/run-stats-p2-gate.sh`) but exercise the admin surface. Under compose project
`bf-p3`, distinct game port (e.g. `28323`, clear of P1 `28123` / P2 `28223`):

1. Bring up `db` + `api` (+ `worker`) with `ADMIN_DEV_OPEN=1` (dev gate), `INGEST_TOKEN`, endpoint env.
2. Truncate stats tables; play a bot match on `conquest_town` (server + separate `--bots` process, same
   `--port`/`--map`; copy the native snapshot-encoder `.so` into the worktree first — `target/` is gitignored).
   Point the server at the ingest API via `--stats-endpoint`/`--stats-token`.
3. Assert **events landed**: `SELECT count(*) FROM events WHERE type='kill'` > 0.
4. Assert `/admin/api/weapons` (dev-open) returns weapons with `total_kills>0` and a sane `hit_rate`.
5. Assert `/admin/api/combat` returns `kill_distance.count>0` and a non-empty histogram; `hitzone.total>0`.
6. **Faithfulness check:** admin API `weapon_balance` SUM(total_kills) across weapons == direct SQL
   `SELECT sum(kills) FROM match_player_weapons`. And kill-event count == `/admin/api/combat` `kill_distance.count`.
7. Assert the **auth gate**: with `ADMIN_DEV_OPEN` effectively off (hit a second api instance or unset —
   simplest: curl `/admin/api/weapons` against an api booted with `ADMIN_DEV_OPEN=0` and no cookie → **403**).
   If standing up a second instance is heavy, assert 403 by clearing the env on a restart. Document whichever.
8. Assert HTML: `GET /admin` and `/admin/combat` → 200 containing a seeded weapon_id.

Write `docs/gate-evidence/2026-07-11-stats-p3.md` with the commands + captured output + **GATE RESULT: PASS/FAIL**.

**Acceptance:** end-to-end pipeline (match → events/weapons in PG → admin dashboards) proven, faithfulness
verified, 403 gate demonstrated. Gate PASS recorded.

---

## Definition of done (P3)

- All 8 code tasks green; full backend suite passes in the `bf-p3` 3.11 container.
- Admin dashboards render weapon-balance + usage, kill-distance distributions + longest kills + hitzone, and a
  working edge-case events explorer — all behind `require_admin` (SteamID allowlist ∪ `ADMIN_DEV_OPEN`).
- Full-stack gate PASS with faithfulness + 403-gate evidence.
- Landed to `origin/master` per AGENTS.md §11 (detached-HEAD `--no-ff` merge so the concurrent M19 checkout is
  never touched), memory updated. **P4 (anomaly/cheat detection + review queue) remains out of scope.**
