# M9-P2 — Rating Service Design

**Status:** approved (design) · **Date:** 2026-07-12 · **Milestone:** [M9](../../milestones/M9-online-services.md) P2 · **Decision:** [ADR-0012](../../adr/0012-rating-service.md) · **Depends on:** M9-P1 ([signed match reports](2026-07-12-m9-p1-signed-match-reports-design.md), `matches.trusted`) · **Builds on:** [M20 stats backend](2026-07-11-stats-analytics-backend-design.md)

## 1. Goal

Give every player a hidden, objective-weighted skill rating with an uncertainty band and a tier bucket, computed **only from trusted match reports**. This is the first consumer of the `matches.trusted` flag P1 introduced, and the data foundation the P5 matchmaker will bucket on. Rating is **hidden from players** (ADR-0004) — the read surface in this phase is admin-only.

Non-goals (later phases): matchmaking / server assignment (P5), tier-merge under low population (P5), shadow-pool routing (P5), Layer-4 statistical detection (P3), any player-facing rating display.

## 2. Why OpenSkill (not Glicko-2)

Conquest is a **team** game (two teams, up to 64 a side); a rating update must consume a team-vs-team outcome and distribute credit across each team's players. Glicko-2 is 1v1-native (chess) and needs an ad-hoc team adaptation. The Weng-Lin **OpenSkill** family is natively multi-team with a per-player (μ, σ); the two-team **Thurstone–Mosteller full-pairing** update has a clean closed form, converges fast under high initial σ (the primary smurf defense ADR-0004 calls for), and reduces exactly to the 1v1 case. We implement it self-contained (no new dependency — consistent with `signing.py`/`anomaly.py`), which keeps the update fully deterministic and unit-testable and lets objective-weighting hook directly into the per-player step. Decision + rationale + alternatives: **ADR-0012**.

## 3. The rating model

### 3.1 Per-player state — `player_ratings`

New table (additive, decoupled like the M20 rollups — no FK to `players`):

| column | type | meaning |
|---|---|---|
| `player_key` | String PK | identity (`steam:` \| `name:`) |
| `mu` | Float | skill estimate (seed `RATING_MU_INIT`, default 25.0) |
| `sigma` | Float | uncertainty (seed `RATING_SIGMA_INIT`, default 25/3 ≈ 8.333) |
| `ordinal` | Float | conservative display rating = `mu - RATING_ORDINAL_Z * sigma` |
| `tier` | String | bucket name derived from `ordinal` (see §3.4) |
| `matches_rated` | Integer | count of trusted matches applied to this player |
| `last_match_id` | String \| null | most-recent trusted match applied |
| `updated_at` | DateTime(tz) | last write |

`ordinal`/`tier` are stored (not computed on read) so the admin surface and the future matchmaker read them directly.

### 3.2 Exactly-once application — `matches.rated`

Rating is **order-dependent and not idempotent per match** (unlike the M20 rollups, which are a full recompute). Each trusted match must be applied exactly once, in chronological order. Add one durable column, mirroring how P1 added `trusted`:

- `matches.rated: Boolean NOT NULL DEFAULT FALSE` — set true when the match's rating update has been committed.
- Idempotent DDL: `ALTER TABLE matches ADD COLUMN IF NOT EXISTS rated BOOLEAN NOT NULL DEFAULT FALSE` in `init_db` (create_all covers fresh DBs; the ALTER covers existing ones — Alembic still not adopted, per P1).

### 3.3 The update — `app/rating.py` (pure module)

```
RATING_MODULE_VERSION = 1   # bump when the math changes; recorded per rating row's context is out of scope P2
```

Pure functions, no DB, no I/O (like `signing.py`):

- `class Rating: mu: float, sigma: float` (frozen dataclass) with `ordinal(z)` helper.
- `default_rating(cfg) -> Rating` — seeds from `RATING_MU_INIT` / `RATING_SIGMA_INIT`.
- `performance_score(mp_row, cfg) -> float` — objective-weighted contribution:
  `w_kill·kills + w_assist·assists + w_capture·captures + w_neutralize·neutralizes + w_revive·revives − w_death·deaths`, then `max(score, RATING_PERF_FLOOR)` so every participant keeps a small positive weight (a player who only died still absorbs a little of the outcome, and weights never go non-positive).
- `rate_two_teams(team_a: list[Rating], team_b: list[Rating], weights_a, weights_b, outcome, cfg) -> (list[Rating], list[Rating])` — the Thurstone–Mosteller two-team update. `outcome ∈ {A_WINS, B_WINS, DRAW}`. Per-player weights scale each player's share of their team's Δμ/Δσ (partial-play weighting): a player's μ moves by `weight_i / mean(team_weights)` times the team delta, so high-objective players on a losing team lose **less** and passengers on a winning team gain **less**. σ shrinks toward the team update regardless of weight (uncertainty always decreases with a played match).

The closed form is the Weng-Lin **Thurstone–Mosteller full-pairing** two-team update (`β = RATING_BETA`, `τ = RATING_TAU`). Per match, with team A's aggregate `Σσ²_A = Σ_{i∈A} σ_i²` (likewise B):

```
# 0. dynamics — re-inflate every player's σ before the update
σ_i² ← σ_i² + τ²                    for all players, both teams

# 1. shared normalizer and standardized margin
c   = sqrt( Σσ²_A + Σσ²_B + 2·β² )
μ_A = mean(team_a μ);  μ_B = mean(team_b μ)
ε   = RATING_DRAW_MARGIN · c        # draw margin

# 2. pairing functions (winner-minus-loser margin t, standardized by c)
#    win/loss:  v(t) = pdf(t) / cdf(t),   w(t) = v·(v + t)          # ε does NOT enter the win path
#    draw:      symmetric two-sided v_draw(t, ε/c), w_draw(t, ε/c)  # ε is the tie margin only
# 3. per team T (opponent O), sign s = +1 winner / −1 loser / 0 draw:
t = s · (μ_T − μ_O) / c
for player i on team T with individual weight ω_i:
    μ_i ← μ_i + s · (ω_i / mean_ω_T) · (σ_i² / c) · v(t)
    σ_i ← sqrt( σ_i² · max( 1 − (σ_i² / c²) · w(t), κ ) )   # κ = small floor, e.g. 1e-4
```

Winner μ rises, loser μ falls; every σ shrinks (a played match always reduces uncertainty). The `ω_i / mean_ω_T` factor is the only objective-weighting hook — it scales **μ** movement by contribution while σ shrinks uniformly. The exact `v`/`w`/`v_draw`/`w_draw` forms are the published Weng-Lin equations; `pdf`/`cdf` are the standard normal density and CDF (`cdf(x) = 0.5·erfc(−x/√2)` via `math.erf`). See §8 for how the golden test's expected numbers are produced from an independent oracle.

`τ` (dynamics factor, default 0.0833 ≈ σ_init/100) re-inflates σ slightly each match so a long-idle player's rating can move again; `β` (default 25/6 ≈ 4.167) is the per-player skill-to-outcome noise.

### 3.4 Tiers — `tier_for(ordinal, cfg) -> str`

`RATING_TIER_THRESHOLDS` is an ascending list of `(ordinal_min, name)` breakpoints (default: Bronze < 10, Silver 10–17, Gold 17–24, Platinum 24–31, Diamond ≥ 31 on the default μ/σ scale). Pure function; the highest breakpoint whose `ordinal_min ≤ ordinal` wins. Tiers are **soft** and admin-only in P2 — no gating, no player display.

## 4. Applying it — `app/rating_apply.py`

DB-facing layer (like `rollups.py` / `anomaly.py`), two entry points:

- `async def update_ratings(session, settings) -> int` — **incremental**. Select `trusted AND complete AND NOT rated` matches, ordered by `(ended_at NULLS LAST, started_at NULLS LAST, match_id)` for a stable deterministic sequence. For each match, in order:
  1. Load its `match_players` grouped by `team`. Skip (log) any match not having **exactly two** teams (BR / malformed) — N-team support is a documented deferral.
  2. Determine `outcome` from `matches.winner` vs the two team labels (`DRAW` if winner is null/empty/"draw").
  3. Load current `Rating` for each player (seed default if absent).
  4. Compute per-player weights via `performance_score`.
  5. `rate_two_teams(...)`, upsert every player's `player_ratings` row (recompute `ordinal`, `tier`, bump `matches_rated`, set `last_match_id`), set `matches.rated = True`.
  6. Commit per match (so a mid-batch failure leaves a consistent prefix applied; the `rated` flag makes the next cycle resume cleanly).
  Returns the number of matches rated this call.
- `async def rebuild_ratings(session, settings) -> int` — **full replay** for tests/migrations/knob changes: truncate `player_ratings`, clear `matches.rated`, then run the incremental pass over all trusted matches. Deterministic given match order.

**Trust gate is mandatory:** `RATING_REQUIRE_TRUSTED` (default `True`) — when true, untrusted matches are never rated. A knob (not a constant) so a fully-local dev deployment with no signing keys can still exercise rating if it opts in, exactly mirroring `REQUIRE_SIGNED_INGEST`'s inverse role.

## 5. Worker integration

`worker/run.py::run_cycle` gains **step 5**, after anomaly detection, in the same shape as the existing steps (own fresh session, own try/except, count into the returned dict):

```python
# 5. skill-rating update over freshly-trusted matches
try:
    async with sm() as session:
        rated = await update_ratings(session, settings)
    result["rated"] = rated
    if rated:
        print(f"[worker] rated {rated} matches", flush=True)
except Exception as exc:
    print(f"[worker] rating update failed: {exc!r}", flush=True)
```

`result` initial dict gains `"rated": 0`. Rating reads the source-of-truth match tables directly (not the rollups), so its placement among the independent steps doesn't matter; it goes last to keep the diff localized.

## 6. Read surface (admin-only)

Mirror the existing `/admin/anomalies` pattern (SteamID-allowlist `require_admin`, Jinja2 autoescape):

- `app/rating_read.py` — `async def leaderboard(session, limit, offset)`, `async def rating_summary(session)` (counts per tier, μ/σ/ordinal distribution, total rated matches).
- `GET /admin/api/ratings` (JSON) + `GET /admin/api/ratings/summary` — behind `require_admin`.
- `GET /admin/ratings` — Jinja2 leaderboard page (player_key, tier, ordinal, μ, σ, matches_rated), tier-distribution summary. XSS-safe (autoescape; `player_key` is already whitelisted upstream but treated as untrusted here).

No public-website surface (rating is hidden). No change to `web/` player pages.

## 7. Config knobs (`app/config.py`)

All additive, all defaulted so existing deployments are unchanged:

| knob | default | meaning |
|---|---|---|
| `rating_require_trusted` | `True` | only trusted matches affect rating |
| `rating_mu_init` | `25.0` | seed μ |
| `rating_sigma_init` | `8.3333` | seed σ (25/3) — high → fast placement |
| `rating_beta` | `4.1667` | skill→outcome noise (25/6) |
| `rating_tau` | `0.0833` | per-match σ re-inflation (dynamics) |
| `rating_ordinal_z` | `3.0` | conservatism of display ordinal (`μ − z·σ`) |
| `rating_draw_margin` | `0.1` | draw sensitivity (fraction of `c`) |
| `rating_perf_floor` | `1.0` | min per-player contribution weight |
| `rating_w_kill` | `1.0` | objective weights … |
| `rating_w_assist` | `0.5` | |
| `rating_w_capture` | `3.0` | captures weighted high (Conquest win condition) |
| `rating_w_neutralize` | `2.0` | |
| `rating_w_revive` | `1.5` | |
| `rating_w_death` | `0.5` | subtracted |
| `rating_tier_thresholds` | see §3.4 | ascending `ordinal_min:name` breakpoints |

Weights follow the project's BattleBit-faithful, objective-first posture (captures/neutralizes dominate kills). They are **knobs, not constants** precisely because ADR-0004 defers final tuning to real data.

## 8. Testing

**Unit (`app/rating.py`, pure):**
- Golden vector: a two-team update (fixed μ/σ/**equal** weights, one team wins) asserts exact post μ/σ — pins the math against refactors. **Expected numbers come from an independent oracle, not from our own code:** generate them once with the reference `openskill` PyPI package (dev/test-only, e.g. `ThurstoneMostellerFull` with matching β/τ and equal weights) and hard-code the results in the test. `rating.py` carries **no** runtime dependency on `openskill`; the library is only an offline source of truth for the golden expectations (documented in a test comment). This makes the self-implementation trustworthy rather than self-confirming.
- `performance_score` weighting: objective-heavy vs kill-heavy rows; floor applied.
- Winner μ rises, loser μ falls, both σ shrink; a draw between equal teams is ~no-op on μ; higher-weight player on the winning team gains more than a low-weight teammate.
- 1v1 reduces to the classic pairwise update.
- `tier_for` breakpoint boundaries (inclusive lower edge).
- Fast convergence: a much-stronger player beating weak teams crosses into a higher tier within a small N (the smurf-promotion property).

**Apply (`app/rating_apply.py`, vs compose PG):**
- Only trusted+complete matches rated; untrusted/incomplete skipped; `rated` flag flips and blocks re-application (idempotent across two cycles → second cycle rates 0).
- Deterministic order (two matches with set timestamps apply in chronological order).
- Two-team requirement: a 1-team / 3-team match is skipped with no rating rows written.
- `rebuild_ratings` reproduces the incremental result exactly.
- `RATING_REQUIRE_TRUSTED=False` rates untrusted matches.

**Worker:** `run_cycle` returns a `rated` count and the failure of the rating step is isolated (poisoned session in step 5 doesn't affect steps 1-4's committed results).

**Read/admin:** `require_admin` gates `/admin/ratings` and both APIs (403 without allowlisted SteamID / dev hatch); leaderboard orders by ordinal desc; summary tier counts are correct.

**Backend tests run in a `python:3.11-slim` container against a compose Postgres** (host has only 3.14), fresh compose project `bf-m9-p2`.

## 9. Full-stack gate (`docker/m9_p2_rating_gate.sh` + `docs/gate-evidence/m9-p2-rating.md`)

Mirrors the P1 gate. Bring up compose (project `bf-m9-p2`) with signing keys configured, run a **signed** 24-bot two-team `conquest_town` match through the real game server + StatsReporter, then run one worker cycle and assert:
1. `player_ratings` populated for the match's players; every rated match has `matches.rated = t`.
2. Tiers assigned; the ordinal ordering is sane (top performers above passengers).
3. An **unsigned** (untrusted) match in the same DB is **not** rated (`matches.rated = f`, no rating delta from it).
4. Re-running the worker cycle rates **0** new matches (exactly-once).
5. `rebuild_ratings` reproduces the same final μ/σ per player (determinism).
6. Convergence: across several signed matches a consistently-dominant bot cohort's mean ordinal rises monotonically into a higher tier (smurf-promotion property, deterministic bot script).

Copy the gitignored native snapshot-encoder `.so` into the worktree before the match (per P1).

## 10. Landing

Scoped `git add` of `backend/` (+ `docker/`, `docs/`) only — **never** `-A`/`.`; the M19 game agent shares this checkout's parent. Detached-HEAD `--no-ff` merge to `origin/master` so the M19 checkout is never touched, push, update `blockfire-m9-online-services.md` memory + MEMORY.md index, tear down compose with volume, remove the worktree.

## 11. Deferrals (documented, not built)

- **N-team rating** (BR / >2 teams) — Plackett-Luce generalization; P2 skips non-two-team matches.
- **Per-match rating audit trail** (μ/σ before→after per player per match) — useful for debugging/appeals; P2 stores only current state + `matches_rated`/`last_match_id`.
- **Rating decay** over inactivity beyond τ's mild re-inflation.
- **Player-facing display** — stays hidden until/unless a product decision changes ADR-0004.
- **Matchmaker consumption** of `tier` — P5.
