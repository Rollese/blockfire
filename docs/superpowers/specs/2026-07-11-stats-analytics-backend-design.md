# Stats & Analytics Backend — player profiles + internal balancing platform — design

- **Date:** 2026-07-11
- **Status:** approved (design)
- **Milestone:** **M20 — Online Stats & Analytics** (sibling to, and a strict datastore subset of,
  [M9 — Online Services](../../milestones/M9-online-services.md)). (M15–M19 are all assigned;
  M19 is Class Select & Player Loadouts.)
- **Relationship to M9 / [ADR-0004](../../adr/0004-anti-cheat-and-skill-matchmaking.md):** M9 already
  specs the project's first persistent backend (SteamID-keyed datastore + rating + matchmaker +
  Layer-4 cheat detection), but is **deferred post-1.0** and focused on *matchmaking*. This milestone
  builds the **datastore + ingest + analytics** foundation that M9 later attaches rating/matchmaking
  to — nothing here is thrown away when M9 lands. See [`anti-cheat-matchmaking.md`](../../specs/anti-cheat-matchmaking.md)
  (Subsystem B draws `backend/` in-repo).
- **Related:** [ADR-0002](../../adr/0002-project-structure.md) (single-source-of-truth ethos),
  [`telemetry.md`](../../specs/telemetry.md) (per-window stdout counters — the *live-ops* surface,
  distinct from this *historical* store), the weapon-variants work (`data/weapons.json` — the
  `weapon_id` source of truth this backend joins against).

## 1. Goal and scope

Stand up a centralized API + web server + web interface that records Blockfire match data for two
audiences:

1. **Players** — public profile pages: XP, K/D, wins, longest kill, most-used weapon, hit rate.
2. **Developers** — internal admin dashboards for balancing (weapon usage/effectiveness, edge-case
   hunting) and anomaly/cheat detection (outlier K/D, headshot%, hit-rate).

The driving *near-term* need is **development analytics** — gathering balancing data from current bot
+ LAN playtests while the weapon-variants roster is being tuned — so the build order front-loads data
capture and defers UI.

### Ratified decisions (this brainstorming session, owner-approved)

| Decision | Choice | Rationale |
|---|---|---|
| Positioning | **Full stack (Choice C), delivered in two trust tiers** | Deliver public profiles *and* internal analytics without waking M9's deferred matchmaking/anti-cheat backend. |
| Identity — this milestone | **SteamID, client-asserted** (dev **App ID 480 "Spacewar"**, no $100 yet) | Real SteamID attribution now; spoofable, which is fine for balancing data + friends. |
| Identity — deferred to M9 | Cryptographic ownership tickets, VAC, **signed match reports**, rating, matchmaking, shadow-pool | Trust hardening — analytics doesn't need it; competitive integrity does. |
| Web sign-in | **Steam OpenID 2.0** (the "Sign in through Steam" button) | No SDK, no App ID, no publisher key — a well-trodden library path (~days). Distinct from in-game Steam SDK auth. |
| Data granularity | **Hybrid: raw high-value events + rolled-up counters** | Forensic depth on kills/damage; hit-rate/usage from cheap per-match counters. |
| Per-shot logging | **No** — hit-rate comes from per-match counters | Every shot as a row = hundreds of thousands of rows/match for marginal gain. |
| Backend stack | **Python + FastAPI + PostgreSQL** | Owner knows Python; one language for the API *and* the data-exploration (pandas/notebooks) that is the internal half's whole point. Postgres for window functions / JSONB / analytics. |
| Repo layout | **Monorepo**, new top-level `backend/` dir, own Docker build | Event schema is a producer/consumer contract → atomic cross-cutting changes, no version skew; reuses in-repo registries. Matches M9 spec's `backend/`. |
| Agent context cost | **`AGENTS.md` scoping note** + directory boundary | Keeps game-focused agents out of the Python web code without a separate repo. |
| Dev/prod hosting | **docker-compose**; dev on **game2**, prod later on **unraid** (isolated, `/mnt/app/blockfire`) | Same shape as the owner's nginx+php-fpm+mariadb experience; unraid is production, so build/test on game2 first. |
| Build order | **Phased; P1 = ingest + DB from game2** | Front-load data capture; UI phases follow. |

## 2. Architecture

### Data flow (end to end)

```
GAME SERVER (game2 dev → unraid prod)
  server_main.gd ─▶ StatsReporter (new, server-only)
     • buffers kill/damage/objective events during the match
     • builds per-match counters + a match summary at match end
     • HTTP POST (bearer token) ──▶ ingest API
     • on failure: append to local NDJSON, drain-and-retry on recovery (no data loss)
                                     │ https
BACKEND (repo backend/, docker-compose)  ▼
  [ api ]  FastAPI/Uvicorn — /ingest (P1), /profile (P2), /admin (P3)
     │ writes                         ╲ reads
  [ db ]  PostgreSQL            [ worker ]  rollups · retention prune · anomaly jobs
     • events (90d)                         │
     • match_player_weapons (∞)             │
     • player_profiles (∞) ◀──recompute─────┘
                                     │ reverse-proxy (prod: unraid SWAG/NPM, TLS)
CONSUMERS                            ▼
  • Public site — Steam OpenID login, player profile pages   (P2)
  • Dev admin  — balancing dashboards, anomaly review queue  (P3/P4)
```

### Components

- **`StatsReporter`** (game server, GDScript, server-only) — taps the *same* combat-resolution point
  the existing `Telemetry` autoload already uses (which already counts kills/shots/hits per window),
  but captures per-player-per-weapon counters and per-kill events (attacker, victim, weapon, distance,
  hitzone, positions) that the sim already has at kill time. Buffers, batches, POSTs, and falls back
  to local NDJSON on failure. Must **not** add measurable game-tick cost (batch + async send).
- **`api`** — FastAPI under Uvicorn/Gunicorn. Stateless; scales by adding workers. Pydantic models
  validate every ingest payload at the boundary.
- **`db`** — PostgreSQL, one persistent named volume (`pgdata`). The only stateful piece.
- **`worker`** — scheduled/background jobs: recompute profile rollups (P2), prune `events` past
  retention (P1), run anomaly detection (P4). Keeps heavy queries off the request path.
- **`reverse-proxy`** — reuse unraid's existing SWAG/Nginx-Proxy-Manager for TLS + public hostname in
  prod; not a new container.

*Not now (YAGNI):* Redis (add only if a real job queue / shared cache is later needed); a columnar
analytics DB like ClickHouse/DuckDB (Postgres handles the volume; revisit if event volume explodes).

## 3. Data model (PostgreSQL)

`■ P1` = built first · `□ P2+` = later phases.

- **`■ players`** — one per SteamID. `steam_id` PK · `first_seen` · `last_seen` ·
  (`□ display_name`, `□ avatar_url` filled P2 from Steam Web API `GetPlayerSummaries`).
- **`■ matches`** — one per match. `match_id` PK (**server-generated UUID = idempotency key**) ·
  `server_id` · `map` · `mode` · `started_at` · `ended_at` · `duration_s` · `winner` ·
  `report_version` · `ingested_at` · `complete` (bool — false if no end-summary arrived).
- **`■ match_players`** — one per (match, player) [PK `match_id, steam_id`]. `team` · `kills` ·
  `deaths` · `assists` · `downs` · `revives` · `captures` · `neutralizes` · `xp_earned` ·
  `longest_kill_m` · `playtime_s` · `result`.
- **`■ match_player_weapons`** — the **counter layer** [PK `match_id, steam_id, weapon_id`].
  `shots` · `hits` · `kills` · `headshots` · `damage` · `time_used_s`. Powers hit-rate, most-used
  weapon, weapon balance without a shot firehose.
- **`■ events`** — the **raw forensic layer**, 90-day retention (`RAW_EVENT_RETENTION_DAYS`, default
  90), time-partitioned. `event_id` ·
  `match_id` · `tick` · `seq` · `type` · `actor_steam_id` · `target_steam_id` · `weapon_id` ·
  **`payload JSONB`** {`distance_m`, `hitzone`, `actor_pos`, `target_pos`, `damage`, `objective_id`…}.
  Types: `kill` · `damage` · `down` · `revive` · `capture` · `spawn` · `session_start`/`session_end`.
  Powers longest kill, kill-distance distributions, position heatmaps, cheat forensics, edge cases.
- **`□ player_profiles`** (P2) — lifetime rollup, cached [PK `steam_id`]. `total_kills/deaths/assists`
  · `wins/losses` · `matches_played` · `xp_total` · `kd_ratio` · `overall_hit_rate` ·
  `longest_kill_m` · `favorite_weapon_id` · `total_playtime_s` · `updated_at`.
- **`□ player_weapon_totals`** (P2) — per (player, weapon) lifetime [PK `steam_id, weapon_id`], for
  profile weapon breakdowns.

`weapon_id`, `map`, `mode` are TEXT keys matching the in-repo registries (`data/weapons.json`, map
metadata) — the backend loads those for display labels. One source of truth, no duplication.

## 4. Ingest contract

Two endpoints, **bearer-token auth** (shared secret, env var, rotatable). Only game servers may POST.

**During the match — `POST /ingest/events`** (periodic batch — bounds payload size *and* is
crash-resilient; already-sent events survive a mid-match server crash):

```json
{ "match_id": "…", "batch_seq": 7, "events": [
  {"tick":1234,"type":"kill","actor":765…,"target":765…,"weapon_id":"m4a1",
   "distance_m":142.3,"hitzone":"head","actor_pos":[x,y,z],"target_pos":[x,y,z]} ] }
```

**At match end — `POST /ingest/match`** (summary + counters):

```json
{ "report_version": 1,
  "match": {"match_id":"…","server_id":"game2-dev-1","map":"…","mode":"conquest",
            "started_at":"…","ended_at":"…","winner":"team_a"},
  "players": [ {"steam_id":765…,"team":"team_a","kills":12,"deaths":8,"assists":3,
    "downs":5,"revives":2,"captures":2,"xp_earned":3400,"longest_kill_m":214.5,
    "playtime_s":1180,"result":"win",
    "weapons":[{"weapon_id":"m4a1","shots":420,"hits":150,"kills":8,"headshots":3,"damage":2100}]} ] }
```

**Properties:**
- **Idempotent** — `(match_id, batch_seq)` for events and `match_id` upsert for the summary; retries
  and NDJSON replays never double-count.
- **Additive schema evolution** — `report_version` gates parsing; new fields are appended, never
  reordered/removed (mirrors the [`telemetry.md`](../../specs/telemetry.md) stability contract).

## 5. Reliability & error handling

- **Backend down during a match** → `StatsReporter` appends batches to a local NDJSON file; a drain
  loop re-POSTs once the backend answers. No data loss.
- **Server crash mid-match** → already-POSTed events remain in Postgres; the `matches` row stays
  `complete = false` (no end-summary). Acceptable for P1 — forensic events survive.
- **Malformed payload** → Pydantic validation at the boundary → `4xx`, logged, never partially
  written.
- **Unauthenticated POST** → `401`.
- **Prod migrations** → DB backup before any schema migration on unraid; stack confined to
  `/mnt/app/blockfire`, own compose project + volumes, never disturbing the live game server.

## 6. Security

- Ingest bearer token (env var, rotatable) — only game servers can write.
- Public site (P2) exposes only public Steam data (name/avatar) + game stats; no sensitive PII.
- Admin dashboards (P3) behind a **SteamID allowlist**; P1 has no UI surface to protect.
- Basic ingest rate-limiting is deferred (YAGNI for trusted dev servers); revisit for public prod.

## 7. Phasing

- **▶ P1 — Ingest + DB (build first).** `StatsReporter` in the game server; ingest API; Postgres
  schema (`players`, `matches`, `match_players`, `match_player_weapons`, `events`); backend skeleton +
  `docker-compose.yml`; `AGENTS.md` scoping note. Match reports + raw events flow from a game2 match
  into Postgres, verifiably queryable. **No UI.**
- **P2 — Player website.** Steam OpenID sign-in; public profile pages from `player_profiles` /
  `player_weapon_totals` rollups (computed by the worker on ingest); Steam name/avatar via Web API.
- **P3 — Dev admin dashboards.** Weapon balance tables, usage/hit-rate distributions, kill-distance
  and edge-case explorers over `events`; admin auth.
- **P4 — Anomaly / cheat detection.** Worker jobs flag outliers (K/D, headshot%, hit-rate) into an
  admin review queue — the analytics precursor to M9's Layer-4 statistical detection.

### P1 definition of done (gate)

A bot match on **game2** with `StatsReporter` pointed at the docker-compose backend produces
`matches`, `match_players`, `match_player_weapons`, and `events` rows in Postgres; a sample weapon
**hit-rate query returns correct numbers**; killing the backend mid-match loses **no data** (NDJSON
replay reconciles on recovery); unauthenticated/malformed POSTs are rejected. Backend skeleton,
`docker-compose.yml`, and the `AGENTS.md` scoping note are landed. `StatsReporter` adds no measurable
game-tick cost (verify via `[perf]`/`[telemetry]`).

## 8. Testing

- **Backend (pytest):** ingest validation; idempotency (double-POST → single row); counter/rollup
  math; an integration test spins a throwaway Postgres, POSTs a sample match report, asserts rows.
- **Game server (`tests/*_test.gd`):** `StatsReporter` buffers events, builds a well-formed report,
  and falls back to NDJSON when the POST fails.
- **Gate:** the P1 definition-of-done run above, captured as `docs/gate-evidence` per project custom.

## 9. Out of scope (deferred)

- Cryptographic Steam ownership tickets, VAC, signed match reports, rating (Glicko-2/OpenSkill),
  matchmaking, shadow-pool — all **M9** (this backend is the datastore they attach to).
- In-game rendered-client Steam SDK integration beyond reading the local SteamID — **M7/M9**.
- Columnar analytics DB, Redis, per-shot event logging — until a consumer justifies them.

## 10. References

- [M9 — Online Services](../../milestones/M9-online-services.md) ·
  [ADR-0004](../../adr/0004-anti-cheat-and-skill-matchmaking.md) ·
  [anti-cheat-matchmaking spec](../../specs/anti-cheat-matchmaking.md) (Subsystem B)
- [`telemetry.md`](../../specs/telemetry.md) — live-ops stdout counters (distinct surface)
- Steam OpenID 2.0 (web sign-in), Steam Web API `GetPlayerSummaries` / `GetPlayerBans`,
  test App ID 480 "Spacewar", GodotSteam (in-game SDK, deferred)
