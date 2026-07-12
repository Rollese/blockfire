# M20 Stats Backend — P4: Anomaly / Cheat Detection (worker jobs → admin review queue)

- **Date:** 2026-07-12
- **Milestone:** M20 — Online Stats & Analytics, phase **P4** (final phase).
- **Design spec:** `docs/superpowers/specs/2026-07-11-stats-analytics-backend-design.md` — §7 phasing:
  "**P4 — Anomaly / cheat detection.** Worker jobs flag outliers (K/D, headshot%, hit-rate) into an admin
  review queue — the analytics precursor to M9's Layer-4 statistical detection." (§2 architecture lists
  the `worker` running "anomaly jobs"; §6 admin surface behind SteamID allowlist.)
- **Builds on:** P1 ingest+PG (`0d67240`), P2 website + `worker` package (`280b5bb`), P3 admin dashboards +
  `require_admin` gate + `weapon_outliers` read-side precursor (master `e019475`).
- **Scope note:** **Backend-only. Zero GDScript changes.** All work is under `backend/` + `docs/`. Cannot
  collide with the concurrent M19 game-code work (different subtree). Land via detached-HEAD `--no-ff` merge
  so the M19 checkout is never touched.

## Owner-ratified direction (autonomous, grounded in the codebase — carried from M20 memory)

Owner wants fully autonomous work; these are the engineering defaults chosen for P4, documented for the record:

- **Detection substrate = the existing `player_profiles` rollup** (lifetime per-player aggregates the P2
  worker already recomputes every cycle). It already carries `kd_ratio`, `overall_hit_rate`, `total_kills`,
  `total_deaths`, `total_shots`, `total_hits`, `total_headshots` — everything the three named detectors need,
  with no new aggregation query. Headshot-rate = `total_headshots / total_hits` (computed; not stored).
- **Detectors (exactly the spec's three):** `kd` (kills/deaths), `headshot_rate` (headshots/hits),
  `hit_rate` (hits/shots).
- **Detection rule = min-sample gate + robust population statistic + absolute floor** (an explainable
  *analytics precursor*, NOT M9-grade statistical detection):
  1. **Min-sample gate** per metric so a 3-kills-0-deaths player is never flagged (thresholds in config).
  2. **Robust population threshold:** over the qualifying population, `median + K·1.4826·MAD` (median +
     scaled median-absolute-deviation — robust to the very outliers we hunt). Requires ≥ `MIN_POP`
     qualifying players; below that the population stat is undefined and only the absolute floor applies.
  3. **Absolute floor** per metric (a hard "this is suspicious regardless of population" line).
  4. **Flag** any qualifying player whose metric ≥ `max(absolute_floor, population_threshold)`.
  - **Severity** from `value / effective_threshold`: `≥1.5 → high`, `≥1.2 → med`, else `low`.
- **Where it runs:** a new `detect_anomalies()` becomes the **4th step of the existing `worker.run.run_cycle`**
  (prune → rollup → enrich → **detect**), same try/except-isolated pattern, returning an `"anomalies"` count.
  Plus an **admin-triggered `POST /admin/api/anomaly/scan`** for on-demand runs (gate + dev convenience).
- **Review queue = new `anomaly_flags` table** (additive, created by `create_all` under the existing advisory
  lock — no Alembic, same as every M20 table so far). Triage states `open | confirmed | dismissed`.
- **Idempotency (critical — the worker re-scans every 30s):** a flag's *signature* = `(player_key, metric)`.
  On re-scan: if an **open** flag with that signature exists, **update it in place** (refresh value / sample /
  severity / context / `last_seen_at`) — never insert a duplicate. If a `confirmed`/`dismissed` flag exists
  for that signature, **skip** (respect the reviewer's decision; don't resurrect a triaged flag). If the
  player no longer breaches, leave existing open flags as-is (they age out via retention/manual dismissal) —
  P4 does not auto-close (documented deferral).
- **`ANOMALY_DETECTOR_VERSION`** constant gates detector-logic evolution (mirrors `report_version`).
- **Auth:** reuse P3 `require_admin` verbatim (SteamID allowlist ∪ `ADMIN_DEV_OPEN`). No new auth code.
- Frontend stays **FastAPI + Jinja2 server-rendered**, reusing `admin_base.html` + `/static/style.css`.

## Ground truth (P1–P3 reality the plan MUST match)

- **Identity** is `player_key` STRING (`steam:<id>` | `name:<name>`), never a SteamID PK. Bots/LAN are
  `name:` keys; **no real Steam users exist yet** → the `ADMIN_DEV_OPEN` escape hatch (P3 Task 1) is how the
  gate is exercised today.
- **Models** (`app/models.py`): `players`, `matches`, `match_players`, `match_player_weapons`, `events`,
  `player_profiles` (PK `player_key`; has `kd_ratio`, `overall_hit_rate`, `total_kills/deaths/shots/hits/
  headshots`, `matches_played`, `updated_at`), `player_weapon_totals`, `ingested_batches`. All ORM via
  `Mapped`/`mapped_column` on `app.db.Base`. New tables land via `Base.metadata.create_all` in `init_db`
  (advisory-lock-serialized, `app/db.py`). **P4 adds ONE new table: `anomaly_flags`.**
- **Worker** (`worker/run.py`): `run_cycle(sm, settings) -> dict` opens a fresh session per step, each step
  `try/except`-guarded so one failure can't poison the others, returns per-step counts (0 for a raised step).
  `main()` loops it every `ROLLUP_INTERVAL_S=30`. `test_worker.py` drives `run.run_cycle` and monkeypatches
  `run.recompute_profiles` to prove step isolation.
- **Read-layer convention** (`app/profiles.py`, `app/admin_stats.py`): pure `async def` helpers taking a
  `session`, returning plain dicts / lists of dicts — **no ORM objects leaked to routes/templates**.
- **Admin API** (`app/admin_api.py`): `register_admin_api_routes(app)`, every route
  `dependencies=[Depends(require_admin)]`, each opens its own `async with request.app.state.sessionmaker()
  as session`. **Admin web** (`app/admin_web.py`): `register_admin_web_routes(app)`, `Jinja2Templates`,
  templates autoescape (no `|safe`), None-guarded, empty states, `.stat-grid`/`table.stats` classes, an
  `.admin-nav` strip. Both already registered in `main.py`'s `create_app`.
- **Auth** (`app/admin_auth.py`): `is_admin(request) -> bool`, `require_admin(request)` raises
  `HTTPException(403, "admin access required")`. `steam_openid.current_steam_id(request)` reads the signed
  `bf_session` cookie; tests sign one with `URLSafeSerializer(session_secret, salt="session")`.
- **Config** (`app/config.py`, pydantic-settings, `.env`, `extra="ignore"`): existing fields incl.
  `admin_steam_ids`, `admin_dev_open`. P4 appends anomaly-threshold fields (all with dev-safe defaults).
- Sparse-data reality: `time_used_s`/assists/xp/playtime often 0; draws → `result="loss"`; fall/sentinel
  weapon → `"ar"`. Detection must be robust to zeros and to a tiny population (dev data is small).

## How to run the backend tests (host = Python 3.14 + Docker → tests run in a 3.11 container)

Fresh compose project **`bf-p4`** (isolated from P1/P2/P3 volumes). Bring up Postgres, run pytest in
`python:3.11-slim` on the compose network:

```bash
cd backend
docker compose -p bf-p4 up -d db
docker run --rm --network bf-p4_default -v "$PWD:/srv" -w /srv \
  -v bf-p4-pipcache:/root/.cache/pip python:3.11-slim bash -c \
  "pip install -q -e '.[dev]'; DATABASE_URL='postgresql+asyncpg://blockfire:blockfire@db:5432/blockfire_stats' \
   INGEST_TOKEN='test-token' python -m pytest -q"
```

**Baseline before Task 1 = the full P3 suite: `136 passed` (confirmed clean on this worktree).**

## No new runtime dependencies

P4 reuses sqlalchemy / fastapi / jinja2 / itsdangerous already pinned. The MAD/median math is pure Python
(`statistics.median`) over fetched rows — no numpy/scipy. Do **not** add packages.

## Test style

Integration-style against real Postgres via `conftest.py` (`app_and_sessionmaker` drops+recreates tables;
authed `client` = httpx `ASGITransport`, `Bearer test-token`; `asyncio_mode=auto`). Seed detection tests by
inserting `PlayerProfile` rows directly (a normal population + a clear outlier). For admin-gate tests, build a
second app with `admin_dev_open=True` sharing the same sessionmaker (the P3 `test_admin_api.py` pattern), and
sign a `bf_session` cookie for an allowlisted steam_id for the cookie path.

---

## Task 1 — `anomaly_flags` model + config thresholds

**Files:** `backend/app/models.py` (extend), `backend/app/config.py` (extend),
`backend/tests/test_models.py` (extend), `backend/tests/test_config.py` (extend), `backend/.env.example`.

**`AnomalyFlag` model** (`app/models.py`) — additive, no FK (decoupled like `events`/`player_profiles`):

- `flag_id: BigInteger` PK autoincrement
- `player_key: str` (String, **indexed**)
- `metric: str` (String, **indexed**) — `"kd" | "headshot_rate" | "hit_rate"`
- `value: float` (Float) — observed metric value
- `threshold: float` (Float) — effective threshold it met/exceeded (explainability)
- `sample_size: int` (Integer) — supporting sample for the metric (deaths for kd, hits for headshot_rate,
  shots for hit_rate)
- `severity: str` (String) — `"low" | "med" | "high"`
- `status: str` (String, **indexed**, default `"open"`) — `"open" | "confirmed" | "dismissed"`
- `detector_version: int` (Integer, default `ANOMALY_DETECTOR_VERSION`)
- `context: dict` (JSONB, default dict) — `{population_median, population_mad, absolute_floor, kills,
  deaths, shots, hits, headshots, matches_played, ...}` for the reviewer
- `created_at: datetime` (DateTime(tz), **indexed**)
- `last_seen_at: datetime` (DateTime(tz)) — updated on every re-scan that still breaches
- `reviewed_at: datetime | None` (nullable)
- `reviewed_by: str | None` (nullable) — admin steam_id or `"dev"`
- `notes: str | None` (nullable)

**Config** (`app/config.py`) — append to `Settings` (all with defaults; env-overridable):

- `anomaly_kd_floor: float = 4.0`
- `anomaly_headshot_rate_floor: float = 0.6`
- `anomaly_hit_rate_floor: float = 0.55`
- `anomaly_min_deaths: int = 5` · `anomaly_min_kills: int = 10` (kd gate)
- `anomaly_min_hits: int = 40` (headshot_rate gate)
- `anomaly_min_shots: int = 100` (hit_rate gate)
- `anomaly_min_population: int = 5` (below this, only the absolute floor applies)
- `anomaly_mad_k: float = 3.5` (population threshold = `median + K·1.4826·MAD`)

Define `ANOMALY_DETECTOR_VERSION = 1` (module constant in `app/anomaly.py`, imported by the model default —
to avoid a cycle, keep the constant in `anomaly.py` and set the model default via a small
`default=` referencing an int literal `1` with a code comment pointing at `ANOMALY_DETECTOR_VERSION`; the
literal and the constant MUST agree — assert this in a test).

Extend `.env.example` with the anomaly keys (commented, showing defaults).

**Tests:** `test_models.py`: insert an `AnomalyFlag`, read it back, assert defaults (`status=="open"`,
`detector_version==1`, `context=={}` default). `test_config.py`: assert the new fields' defaults and one env
override (e.g. `ANOMALY_KD_FLOOR=6.5` parses to float). Assert the model default `detector_version` equals
`ANOMALY_DETECTOR_VERSION`.

**Acceptance:** table creates under `init_db`; config parses; suite green.

---

## Task 2 — Detection engine (`app/anomaly.py::detect_anomalies`)

**Files:** `backend/app/anomaly.py` (new), `backend/tests/test_anomaly_detect.py` (new).

`ANOMALY_DETECTOR_VERSION = 1` module constant. Implement:

```python
async def detect_anomalies(session, settings, now=None) -> int
```

- `now = now or dt.datetime.now(dt.timezone.utc)` (accept injected `now` for deterministic tests — same
  pattern as `recompute_profiles`/`prune_old_events`).
- Load all `PlayerProfile` rows. For each of the three metrics, build the **qualifying population**
  (profiles meeting that metric's min-sample gate) as `(player_key, value, sample, profile)` tuples where:
  - `kd`: value=`kd_ratio`, gate `total_deaths ≥ min_deaths AND total_kills ≥ min_kills`, sample=`total_deaths`.
  - `headshot_rate`: value=`round(total_headshots/total_hits,4)` (skip if `total_hits==0`), gate
    `total_hits ≥ min_hits`, sample=`total_hits`.
  - `hit_rate`: value=`overall_hit_rate`, gate `total_shots ≥ min_shots`, sample=`total_shots`.
- **Effective threshold** per metric: `floor = settings.<metric>_floor`. If
  `len(population) ≥ min_population`: `pop_thr = median(values) + mad_k · 1.4826 · MAD(values)` where
  `MAD = median(|v - median(values)|)`; `effective = max(floor, pop_thr)`. Else `effective = floor`,
  `pop_median = pop_mad = None`.
- **Flag** each qualifying player with `value ≥ effective`. Severity from `value/effective`
  (`≥1.5 high`, `≥1.2 med`, else `low`). Build `context` = `{population_median, population_mad,
  absolute_floor, population_size, kills, deaths, shots, hits, headshots, matches_played}`.
- **Idempotent upsert** by signature `(player_key, metric)`: query existing flag for that signature
  (any status). If none → insert (`status="open"`, `created_at=now`, `last_seen_at=now`,
  `detector_version=ANOMALY_DETECTOR_VERSION`). If exactly one **open** → update `value`, `threshold`,
  `sample_size`, `severity`, `context`, `last_seen_at=now` in place (keep `created_at`). If a
  `confirmed`/`dismissed` exists → **skip** (don't resurrect). Commit once at the end. Return the number of
  flags **written** (inserted + updated-open).
- Robust to empty tables (return 0), zero divisions (guarded by gates), and small populations (floor-only).
- **Determinism:** iterate profiles in `player_key`-sorted order so repeated runs are stable.

**Tests (`test_anomaly_detect.py`)** — seed `PlayerProfile` rows directly:
- **Population + outlier:** ~8 "normal" profiles (kd≈1.0, hs≈0.15, hr≈0.35, ample sample) + 1 egregious
  cheater (kd 25, hs 0.95, hr 0.9, ample sample) → cheater flagged on all three metrics; a normal profile
  flagged on none. Assert `severity=="high"`, `context` populated, `threshold` sane.
- **Min-sample gate:** a profile with kd 99 but only 2 kills / 1 death → NOT flagged (below `min_kills`/
  `min_deaths`). Likewise headshot_rate 1.0 with 3 hits → not flagged.
- **Small-population floor-only:** with < `min_population` qualifying, only floor applies — a value above
  floor flags, one below does not; assert `context.population_median is None`.
- **Idempotent re-scan:** run twice → second run does NOT create duplicate rows (same count of flags in the
  table); an open flag's `last_seen_at` advances while `created_at` stays.
- **No resurrection:** mark a cheater's flag `dismissed`, re-scan → it stays `dismissed`, no new open flag
  for that `(player_key, metric)`.
- **Empty DB:** `detect_anomalies` returns 0, no rows.

**Acceptance:** detection math, gating, robust population stat, idempotency + no-resurrection all correct;
empty-safe; suite green.

---

## Task 3 — Review-queue read + triage helpers (extend `app/anomaly.py`)

**Files:** `backend/app/anomaly.py` (extend), `backend/tests/test_anomaly_queue.py` (new).

Pure helpers returning dicts (no ORM leak):

- `async def list_flags(session, *, status=None, metric=None, limit=100) -> list[dict]` — filter by optional
  `status` and `metric`; order `severity` (high→med→low) then `value` DESC then `flag_id` (deterministic);
  `limit` clamped `1..500`. Each dict: `flag_id, player_key, metric, value, threshold, sample_size,
  severity, status, detector_version, context, created_at, last_seen_at, reviewed_at, reviewed_by, notes`.
- `async def flag_summary(session) -> dict` — `{total, by_status: {open, confirmed, dismissed}, by_metric:
  {kd, headshot_rate, hit_rate}, open_high}` (counts; zero-safe).
- `async def set_flag_status(session, flag_id, status, *, reviewed_by=None, notes=None, now=None) -> dict |
  None` — validate `status ∈ {"open","confirmed","dismissed"}` (else `ValueError`); load the flag; if
  missing return `None`; set `status`, `reviewed_at=now` (None when reverting to `"open"`), `reviewed_by`,
  `notes`; commit; return the updated flag as a dict. Severity ordering for `list_flags` via a
  `case`/rank map (`high=0,med=1,low=2`).

**Tests (`test_anomaly_queue.py`):** seed `AnomalyFlag` rows across statuses/metrics/severities; assert
`list_flags` filtering + ordering + limit clamp; `flag_summary` counts; `set_flag_status` transitions
(open→confirmed sets `reviewed_at`/`reviewed_by`/`notes`; confirmed→open clears `reviewed_at`), invalid
status raises `ValueError`, missing `flag_id` → `None`. Empty-safe.

**Acceptance:** read + triage helpers correct, deterministic, empty-safe; suite green.

---

## Task 4 — Worker wiring: anomaly step in `run_cycle`

**Files:** `backend/worker/run.py` (extend), `backend/tests/test_worker.py` (extend).

Add **step 4** to `run_cycle` after enrich, same isolated `try/except` shape, fresh session:

```python
# 4. anomaly / cheat detection over the freshly-recomputed rollups
try:
    async with sm() as session:
        anomalies = await detect_anomalies(session, settings)
    result["anomalies"] = anomalies
    print(f"[worker] wrote {anomalies} anomaly flags", flush=True)
except Exception as exc:
    print(f"[worker] anomaly detection failed: {exc!r}", flush=True)
```

Initialise `result = {"pruned": 0, "profiles": 0, "enriched": 0, "anomalies": 0}`. Import
`from app.anomaly import detect_anomalies` at module top (alongside the other `app.*` imports) so
`test_worker.py` can `monkeypatch.setattr(run, "detect_anomalies", ...)`. Order matters: detection runs
**after** rollup so it sees fresh `player_profiles`.

**Tests (`test_worker.py`):** extend the happy-path test to assert `result["anomalies"] >= 0` and that a
seeded egregious-cheater profile produces ≥1 flag row after a cycle. Add an isolation test: monkeypatch
`run.detect_anomalies` to raise → `run_cycle` still returns, `result["anomalies"]==0`, and the prune/rollup
results are unaffected (mirror the existing `recompute_profiles` isolation test).

**Acceptance:** cycle runs prune→rollup→enrich→detect; detection failure is isolated; a cheater profile
yields a flag through the cycle; suite green.

---

## Task 5 — Admin JSON API: review-queue + scan + triage (extend `app/admin_api.py`)

**Files:** `backend/app/admin_api.py` (extend), `backend/tests/test_admin_api.py` (extend, or new
`test_admin_anomaly_api.py`).

Add to `register_admin_api_routes`, all `dependencies=[Depends(require_admin)]`, each opening its own
`async with request.app.state.sessionmaker() as session` (local import of `app.anomaly` helpers inside the
function, matching the file's existing `from app.admin_stats import ...` style):

- `GET /admin/api/anomalies?status=&metric=&limit=` → `{"flags": list_flags(...), "summary": flag_summary(...)}`.
- `POST /admin/api/anomaly/scan` → runs `detect_anomalies(session, request.app.state.settings)`; returns
  `{"written": N}`. (On-demand scan for the gate + dev.)
- `POST /admin/api/anomalies/{flag_id}/review` — JSON body `{"status": "...", "notes": "..."}` (a small
  Pydantic model); calls `set_flag_status(..., reviewed_by=<current admin steam_id or "dev">, ...)`; returns
  the updated flag, or **404** if the flag_id is unknown, or **400** on invalid status (catch `ValueError`).
  `reviewed_by` = `str(current_steam_id(request))` if present else `"dev"`.

**Tests:** with `admin_dev_open=True` (second app sharing the sessionmaker) → all routes 200 with expected
shape after seeding; `scan` creates flags from seeded cheater profiles; `review` flips status and 404s on a
bad id, 400s on bad status. With the default `client` (`admin_dev_open=False`, no cookie) → **403** on every
new `/admin/api/anomal*` route (GET and POST). Cookie path (allowlisted steam_id) → 200 and `reviewed_by`
records the steam_id.

**Acceptance:** JSON shapes correct; scan + triage work; 403 gate on all new routes; suite green.

---

## Task 6 — Admin HTML review-queue page (extend `app/admin_web.py` + template)

**Files:** `backend/app/admin_web.py` (extend), `backend/app/templates/admin_anomalies.html` (new),
`backend/app/templates/admin_base.html` (extend nav), `backend/app/static/style.css` (extend),
`backend/tests/test_admin_web.py` (extend, or new `test_admin_anomaly_web.py`).

Add to `register_admin_web_routes`, all `Depends(require_admin)`:

- `GET /admin/anomalies?status=&metric=` → the **review queue**: `flag_summary` headline counts + a table of
  flags (default `status="open"`) with columns: player (link to `/players/<player_key>`), metric,
  value, threshold, severity (coloured chip), sample, matches, first-seen, last-seen, status. Each **open**
  row carries two POST forms — **Confirm** and **Dismiss** — hitting `POST /admin/anomalies/{flag_id}/review`
  (see below) with a hidden `status` field and an optional `notes` text input. Filter form (status/metric)
  preserves submitted values.
- `POST /admin/anomalies/{flag_id}/review` — form-encoded `status` + `notes`; calls `set_flag_status`
  (`reviewed_by` = current steam_id or `"dev"`); on success **303 redirect** back to `/admin/anomalies`
  (PRG pattern, preserving the current status filter via query string); unknown id → 404; invalid status
  → 400.
- `POST /admin/anomalies/scan` — a "Run scan now" button on the page; runs `detect_anomalies`; 303 back to
  `/admin/anomalies`.

Template `admin_anomalies.html` extends `admin_base.html`; autoescape (NO `|safe`), None-guard every optional
field (`reviewed_by`, `notes`, `context.*`), `{% if not flags %}` empty state. Add nav link
**Anomalies** to `admin_base.html`'s `.admin-nav` (Overview / Combat / Events / **Anomalies**). Add
`.sev-high`/`.sev-med`/`.sev-low` chip rules + a `.flag-actions` inline-form rule to `style.css`.

**Tests:** `admin_dev_open=True` → `GET /admin/anomalies` 200 `text/html` containing a seeded flag's
`player_key` + metric and the summary counts; filtering by `status`/`metric` narrows the rendered rows;
`POST /admin/anomalies/{id}/review` with `status=confirmed` → 303, and a follow-up GET shows the flag out of
the default open list; `POST /admin/anomalies/scan` → 303 and flags appear. `admin_dev_open=False`, no cookie
→ **403** on GET + both POSTs. Empty DB → 200 empty state. Confirm autoescape neutralises a crafted `notes`
value (`"><script>` round-trips escaped).

**Acceptance:** review-queue page renders, triage POST + scan work via the browser flow, 403 gate enforced,
XSS-safe, empty-safe; suite green.

---

## Task 7 — Integration wiring + docs

**Files:** `backend/docker-compose.yml`, `backend/.env.example`, `backend/README.md`,
`backend/tests/test_app_wiring.py` (extend if it asserts route inventory).

- `docker-compose.yml`: pass the anomaly-threshold env vars through to **both** the `api` and `worker`
  services (the worker runs detection; the api serves `scan`), each `${ANOMALY_*:-<default>}` so an unset env
  keeps the code default. (Follow how `ADMIN_STEAM_IDS`/`RAW_EVENT_RETENTION_DAYS` are already threaded.)
- `.env.example`: confirm the anomaly keys are present (from Task 1) with the tuning-knob comment.
- `README.md`: add a **P4 — Anomaly / cheat detection** section: the three detectors, the min-sample +
  robust-population + floor rule, the `worker` cycle step + `POST /admin/api/anomaly/scan`, the
  `/admin/anomalies` review queue + triage states, and the config knobs. Note it's the analytics precursor to
  M9 Layer-4 (link the spec).
- No `main.py` change needed (admin API/web already registered; new routes register inside the existing
  functions).

**Tests:** full suite green; if `test_app_wiring.py` enumerates routes, add the new `/admin/api/anomal*` +
`/admin/anomalies` paths to its expected set.

**Acceptance:** compose threads config to api+worker; docs updated; **full suite green**.

---

## Task 8 — Full-stack P4 gate + evidence

**Files:** `docker/run-stats-p4-gate.sh` (new), `docs/gate-evidence/2026-07-12-stats-p4.md` (new).

Mirror the P3 gate (`docker/run-stats-p3-gate.sh`) under compose project **`bf-p4`**, distinct game port
(e.g. `28423`, clear of P1 `28123` / P2 `28223` / P3 `28323`):

1. Bring up `db` + `api` + `worker` with `ADMIN_DEV_OPEN=1`, `INGEST_TOKEN`, endpoint env. Copy the native
   snapshot-encoder `.so` into the worktree first (`native/snapshot_encoder/target/release/` is gitignored).
2. Truncate stats tables; play a bot match on `conquest_town` (server + `--bots`, same `--port`/`--map`),
   pointing the server at the ingest API (`--stats-endpoint`/`--stats-token`). Let the worker roll up
   profiles.
3. **Inject a synthetic egregious outlier** directly via SQL (a `player_profiles` row with kd≈30, hs≈0.97,
   hr≈0.92, ample sample) — real bots won't reliably breach the floors, and P4 must be *proven* to flag a
   cheater. (Documented in the gate as a deliberate synthetic-cheater injection.)
4. `POST /admin/api/anomaly/scan` (dev-open) → assert `written ≥ 3` (the injected outlier trips all three
   detectors). Assert the real-match profiles did **not** all get flagged (detection is discriminating).
5. `GET /admin/api/anomalies?status=open` → assert the injected `player_key` present with `severity=="high"`
   on all three metrics; `summary.by_status.open ≥ 3`.
6. `GET /admin/anomalies` (HTML) → 200 containing the injected `player_key`.
7. **Triage round-trip:** `POST /admin/anomalies/{flag_id}/review status=confirmed` → 303; re-`GET
   /admin/api/anomalies?status=open` → that flag no longer in the open set; `status=confirmed` list includes
   it with `reviewed_by`.
8. **Idempotency:** run `scan` again → total flag count unchanged (no duplicates); the confirmed flag stays
   confirmed (no resurrection).
9. **Auth gate:** curl `/admin/api/anomalies` and `POST /admin/api/anomaly/scan` against an api booted with
   `ADMIN_DEV_OPEN=0` and no cookie → **403**.

Write `docs/gate-evidence/2026-07-12-stats-p4.md` with commands + captured output + **GATE RESULT: PASS/FAIL**.

**Acceptance:** end-to-end pipeline (match → rollups → detection → review queue → triage) proven; idempotency
+ no-resurrection demonstrated; 403 gate shown. Gate PASS recorded.

---

## Definition of done (P4)

- All 7 code tasks green; full backend suite passes in the `bf-p4` 3.11 container.
- The `worker` cycle detects K/D / headshot% / hit-rate outliers (min-sample-gated, robust population stat +
  absolute floor) into the `anomaly_flags` review queue, idempotently and without resurrecting triaged flags.
- `/admin/anomalies` renders the review queue with Confirm/Dismiss triage + on-demand scan, all behind
  `require_admin`; `/admin/api/anomal*` mirrors it in JSON.
- Full-stack gate PASS with a synthetic-cheater flag, triage round-trip, idempotency, and 403-gate evidence.
- Landed to `origin/master` per AGENTS.md §11 (detached-HEAD `--no-ff` merge so the concurrent M19 checkout is
  never touched), memory updated. **P4 completes M20's planned phasing.**
