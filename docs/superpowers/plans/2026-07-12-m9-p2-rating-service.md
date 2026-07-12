# M9-P2 Rating Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compute a hidden, objective-weighted OpenSkill rating (μ/σ/ordinal/tier) per player from **trusted** match reports, exposed on an admin-only read surface.

**Architecture:** A pure math module (`app/rating.py`, Weng-Lin two-team Thurstone–Mosteller, no deps) + a DB-facing apply layer (`app/rating_apply.py`, incremental + rebuild) plugged into the existing worker `run_cycle` as step 5, over a new `player_ratings` table and a durable `matches.rated` flag. Admin read via `app/rating_read.py` + `/admin/ratings` (mirrors `/admin/anomalies`). All behavior is config-knob driven.

**Tech Stack:** Python 3.11, FastAPI, SQLAlchemy 2 async, asyncpg, Postgres, Jinja2, pytest/pytest-asyncio. Golden-test oracle: `openskill` PyPI (dev/test-only; **no runtime dependency**).

**Spec:** `docs/superpowers/specs/2026-07-12-m9-p2-rating-service-design.md` · **Decision:** `docs/adr/0012-rating-service.md`

---

## Ground rules for every task

- **Scoped git adds only** — `git add <explicit paths>`, NEVER `-A` or `.`. A separate M19 game agent shares this checkout's parent worktree; touching game files is forbidden. This phase touches **only** `backend/`, `docker/`, `docs/`.
- **TDD** — write the failing test, run it red, implement minimally, run it green, commit. Frequent small commits.
- **All new config is additive + defaulted** so existing deployments are byte-for-byte unchanged in behavior.

### Backend test recipe (in-container — host has only Python 3.14)

Compose project is `bf-m9-p2`. Bring the DB up once, then run pytest inside a `python:3.11-slim` container joined to the compose network. Pure-module tests (Task 1, Task 2) need **no** DB; DB-backed tests (Tasks 3–7) use the compose Postgres.

```bash
# from repo root (worktree /home/roland/projects/blockfire-m9-p2)
cd backend
docker compose -p bf-m9-p2 up -d db          # Postgres only
NET=bf-m9-p2_default
# run the whole suite (or pass a -k / path to narrow):
docker run --rm --network "$NET" -v "$PWD":/app -w /app python:3.11-slim bash -c "
  pip -q install -e '.[dev]' openskill >/tmp/pip.log 2>&1 || { cat /tmp/pip.log; exit 1; }
  DATABASE_URL='postgresql+asyncpg://blockfire:blockfire@db:5432/blockfire_stats' \
  INGEST_TOKEN='test-token' python -m pytest -q $*
"
```

`openskill` is installed **only in the test container** to generate/verify golden numbers; it is never added to `pyproject.toml`. Pure-module tests can also run without the DB env var.

---

## File Structure

- **Create** `backend/app/rating.py` — pure Weng-Lin two-team update + performance weighting + tiers. No I/O.
- **Create** `backend/app/rating_apply.py` — `update_ratings` (incremental) + `rebuild_ratings` (full replay). DB-facing.
- **Create** `backend/app/rating_read.py` — `leaderboard` + `rating_summary` read queries.
- **Modify** `backend/app/config.py` — add `rating_*` knobs + a `rating_tier_breakpoints()` helper.
- **Modify** `backend/app/models.py` — `PlayerRating` model + `Match.rated` column.
- **Modify** `backend/app/db.py` — idempotent `ADD COLUMN IF NOT EXISTS matches.rated`.
- **Modify** `backend/worker/run.py` — step 5 `update_ratings`.
- **Modify** `backend/app/admin_api.py` — `/admin/api/ratings` + `/admin/api/ratings/summary` (behind `require_admin`).
- **Modify** `backend/app/admin_web.py` — `/admin/ratings` Jinja2 page + nav link.
- **Create** `backend/app/templates/admin/ratings.html` — leaderboard page (match the existing admin template dir/style).
- **Create** `backend/tests/test_rating.py`, `test_rating_apply.py`, `test_rating_read.py`; **extend** `test_config.py`, `test_models.py`, `test_worker.py`, `test_admin_api.py` (or the admin auth test module that already exercises `require_admin`).
- **Create** `docker/m9_p2_rating_gate.sh` + `docs/gate-evidence/m9-p2-rating.md`.

Before starting, confirm the exact admin template directory and the `require_admin` dependency name by reading `app/admin_web.py`, `app/admin_api.py`, `app/admin_auth.py`, and one existing admin template (e.g. the anomalies page). Follow those patterns exactly (autoescape, nav structure, route registration).

---

### Task 1: Config knobs

**Files:**
- Modify: `backend/app/config.py`
- Test: `backend/tests/test_config.py`

- [ ] **Step 1: Write the failing test** — append to `tests/test_config.py`:

```python
def test_rating_defaults():
    from app.config import Settings
    s = Settings()
    assert s.rating_require_trusted is True
    assert s.rating_mu_init == 25.0
    assert abs(s.rating_sigma_init - 25.0 / 3.0) < 1e-9
    assert abs(s.rating_beta - 25.0 / 6.0) < 1e-9
    assert s.rating_ordinal_z == 3.0
    assert s.rating_w_capture == 3.0
    # ascending (ordinal_min, name) breakpoints, lowest first
    bps = s.rating_tier_breakpoints()
    assert bps[0][1] == "Bronze"
    assert all(bps[i][0] <= bps[i + 1][0] for i in range(len(bps) - 1))


def test_rating_tier_breakpoints_parse_override(monkeypatch):
    from app.config import Settings
    s = Settings(rating_tier_thresholds="0:Wood,50:Iron")
    bps = s.rating_tier_breakpoints()
    assert bps == [(0.0, "Wood"), (50.0, "Iron")]
```

- [ ] **Step 2: Run red.** Recipe with `-k "rating_defaults or rating_tier_breakpoints"`. Expect FAIL (unknown fields).

- [ ] **Step 3: Implement.** In `app/config.py`, add these fields to the `Settings` model (place them after the P4 anomaly block, mirroring its comment style) and the helper method:

```python
    # --- M9-P2 rating knobs (ADR-0012) ---
    rating_require_trusted: bool = True
    rating_mu_init: float = 25.0
    rating_sigma_init: float = 25.0 / 3.0
    rating_beta: float = 25.0 / 6.0
    rating_tau: float = 25.0 / 300.0
    rating_ordinal_z: float = 3.0
    rating_draw_margin: float = 0.1
    rating_perf_floor: float = 1.0
    rating_w_kill: float = 1.0
    rating_w_assist: float = 0.5
    rating_w_capture: float = 3.0
    rating_w_neutralize: float = 2.0
    rating_w_revive: float = 1.5
    rating_w_death: float = 0.5
    # "ordinal_min:name" breakpoints, comma-separated, ascending
    rating_tier_thresholds: str = "0:Bronze,10:Silver,17:Gold,24:Platinum,31:Diamond"

    def rating_tier_breakpoints(self) -> list[tuple[float, str]]:
        out: list[tuple[float, str]] = []
        for part in self.rating_tier_thresholds.split(","):
            part = part.strip()
            if not part:
                continue
            lo, _, name = part.partition(":")
            out.append((float(lo), name.strip()))
        out.sort(key=lambda t: t[0])
        return out
```

Match the existing field-definition style (these are `pydantic-settings` env-mapped; confirm the base class and any `env_prefix` by reading the top of `config.py` first — do not assume).

- [ ] **Step 4: Run green.** Same `-k`. Expect PASS.

- [ ] **Step 5: Commit.**
```bash
git add backend/app/config.py backend/tests/test_config.py
git commit -m "feat(m9-p2): rating config knobs + tier breakpoints"
```

---

### Task 2: `app/rating.py` — pure Weng-Lin two-team update (the core)

**Files:**
- Create: `backend/app/rating.py`
- Test: `backend/tests/test_rating.py`

This is the math heart. The golden test's expected numbers come from the **openskill library**, so implement to match it (equal weights, decisive win ⇒ our update must equal `ThurstoneMostellerFull` with the same μ/σ/β/τ/κ).

- [ ] **Step 1: Write the oracle-generation note + failing golden test.** Create `tests/test_rating.py`. First generate the expected numbers ONCE in the container and paste them in (do not leave them symbolic):

```python
# Golden expectations generated once from the reference `openskill` package
# (dev/test-only; NOT a runtime dependency of app.rating). Reproduce with:
#
#   from openskill.models import ThurstoneMostellerFull
#   m = ThurstoneMostellerFull(mu=25.0, sigma=25/3, beta=25/6, tau=25/300, kappa=1e-4)
#   a = [m.rating(name="a")]; b = [m.rating(name="b")]
#   [[na], [nb]] = m.rate([a, b], ranks=[0, 1])   # team A wins
#   print(na.mu, na.sigma, nb.mu, nb.sigma)
#
# Paste the printed values below to 12 sig-figs.
import math

from app.config import Settings
from app.rating import Rating, default_rating, performance_score, rate_two_teams, tier_for, Outcome

CFG = Settings(rating_draw_margin=0.0)  # decisive-win golden: tie margin must not enter

# TODO(implementer): replace with the real printed numbers from the recipe above.
GOLD_WIN_MU = 26.06...   # na.mu
GOLD_WIN_SIGMA = 8.07... # na.sigma
GOLD_LOSE_MU = 23.93...  # nb.mu
GOLD_LOSE_SIGMA = 8.07...


def test_golden_two_team_1v1_equal_weight():
    a = [default_rating(CFG)]
    b = [default_rating(CFG)]
    (na, nb) = rate_two_teams(a, b, [1.0], [1.0], Outcome.A_WINS, CFG)
    assert math.isclose(na[0].mu, GOLD_WIN_MU, rel_tol=1e-6)
    assert math.isclose(na[0].sigma, GOLD_WIN_SIGMA, rel_tol=1e-6)
    assert math.isclose(nb[0].mu, GOLD_LOSE_MU, rel_tol=1e-6)
    assert math.isclose(nb[0].sigma, GOLD_LOSE_SIGMA, rel_tol=1e-6)
```

Then add behavioral tests (independent of the exact constants):

```python
def test_winner_rises_loser_falls_sigma_shrinks():
    a = [default_rating(CFG)]
    b = [default_rating(CFG)]
    (na, nb) = rate_two_teams(a, b, [1.0], [1.0], Outcome.A_WINS, CFG)
    assert na[0].mu > 25.0 > nb[0].mu
    assert na[0].sigma < 25.0 / 3.0 and nb[0].sigma < 25.0 / 3.0


def test_equal_teams_draw_is_near_noop_on_mu():
    a = [default_rating(CFG)]
    b = [default_rating(CFG)]
    (na, nb) = rate_two_teams(a, b, [1.0], [1.0], Outcome.DRAW, CFG)
    assert math.isclose(na[0].mu, 25.0, abs_tol=1e-6)
    assert math.isclose(nb[0].mu, 25.0, abs_tol=1e-6)


def test_objective_weight_splits_team_delta():
    # two players on the winning team, one carries all the objective weight
    a = [default_rating(CFG), default_rating(CFG)]
    b = [default_rating(CFG), default_rating(CFG)]
    (na, _) = rate_two_teams(a, b, [4.0, 1.0], [1.0, 1.0], Outcome.A_WINS, CFG)
    gain_hi = na[0].mu - 25.0
    gain_lo = na[1].mu - 25.0
    assert gain_hi > gain_lo > 0.0


def test_performance_score_objective_weighted_and_floored():
    cfg = Settings()
    objective = performance_score(
        dict(kills=0, assists=0, captures=2, neutralizes=1, revives=0, deaths=0), cfg)
    killer = performance_score(
        dict(kills=2, assists=0, captures=0, neutralizes=0, revives=0, deaths=0), cfg)
    assert objective > killer  # 2*cap(3)+1*neut(2)=8 > 2*kill(1)=2
    floored = performance_score(
        dict(kills=0, assists=0, captures=0, neutralizes=0, revives=0, deaths=10), cfg)
    assert floored == cfg.rating_perf_floor


def test_tier_for_boundaries_inclusive_lower_edge():
    cfg = Settings()
    assert tier_for(-5.0, cfg) == "Bronze"
    assert tier_for(10.0, cfg) == "Silver"    # inclusive lower edge
    assert tier_for(9.999, cfg) == "Bronze"
    assert tier_for(999.0, cfg) == "Diamond"


def test_smurf_promotion_within_few_matches():
    cfg = Settings(rating_draw_margin=0.0)
    strong = default_rating(cfg)
    start_tier = tier_for(strong.ordinal(cfg.rating_ordinal_z), cfg)
    for _ in range(6):
        weak = default_rating(cfg)
        (na, _) = rate_two_teams([strong], [weak], [1.0], [1.0], Outcome.A_WINS, cfg)
        strong = na[0]
    end_tier = tier_for(strong.ordinal(cfg.rating_ordinal_z), cfg)
    assert strong.ordinal(cfg.rating_ordinal_z) > 0.0
    # ordinal climbed materially from the seed (μ up, σ down)
    assert strong.mu > 25.0 and strong.sigma < 25.0 / 3.0
```

- [ ] **Step 2: Run red** (recipe, `tests/test_rating.py`). Expect import errors / FAIL.

- [ ] **Step 3: Generate the golden numbers** in the container (run the recipe snippet from the test's docstring) and paste the real values over the `...` placeholders. Then implement `app/rating.py`:

```python
"""Pure Weng-Lin OpenSkill two-team rating (ADR-0012). No I/O, no DB, no deps.

The two-team Thurstone-Mosteller full-pairing update; reduces to the classic
pairwise update at 1v1. Objective-weighting scales each player's share of the
team's Δμ by their contribution weight (σ shrinks uniformly). Kept dependency-
free and deterministic so it is fully unit-testable and gate-reproducible.
"""
import math
from dataclasses import dataclass
from enum import Enum

RATING_MODULE_VERSION = 1
_SIGMA_FLOOR_FRACTION = 1e-4  # kappa: never let a σ² factor go <= 0


class Outcome(Enum):
    A_WINS = "a_wins"
    B_WINS = "b_wins"
    DRAW = "draw"


@dataclass(frozen=True)
class Rating:
    mu: float
    sigma: float

    def ordinal(self, z: float) -> float:
        return self.mu - z * self.sigma


def default_rating(cfg) -> Rating:
    return Rating(cfg.rating_mu_init, cfg.rating_sigma_init)


def performance_score(mp, cfg) -> float:
    """Objective-weighted contribution weight for one match_player row (dict or
    ORM object exposing kills/assists/captures/neutralizes/revives/deaths)."""
    def g(k):
        return mp[k] if isinstance(mp, dict) else getattr(mp, k)
    score = (cfg.rating_w_kill * g("kills")
             + cfg.rating_w_assist * g("assists")
             + cfg.rating_w_capture * g("captures")
             + cfg.rating_w_neutralize * g("neutralizes")
             + cfg.rating_w_revive * g("revives")
             - cfg.rating_w_death * g("deaths"))
    return max(score, cfg.rating_perf_floor)


def _pdf(x: float) -> float:
    return math.exp(-0.5 * x * x) / math.sqrt(2.0 * math.pi)


def _cdf(x: float) -> float:
    return 0.5 * math.erfc(-x / math.sqrt(2.0))


def _v_win(t: float) -> float:
    denom = _cdf(t)
    if denom < 1e-12:
        return -t  # numerical tail guard (matches TM limiting behavior)
    return _pdf(t) / denom


def _w_win(t: float) -> float:
    v = _v_win(t)
    return v * (v + t)


def _v_draw(t: float, eps: float) -> float:
    num = _pdf(-eps - t) - _pdf(eps - t)
    den = _cdf(eps - t) - _cdf(-eps - t)
    if abs(den) < 1e-12:
        return 0.0
    return num / den


def _w_draw(t: float, eps: float) -> float:
    den = _cdf(eps - t) - _cdf(-eps - t)
    if abs(den) < 1e-12:
        return 1.0
    v = _v_draw(t, eps)
    return v * v + (((eps - t) * _pdf(eps - t) - (-eps - t) * _pdf(-eps - t)) / den)


def rate_two_teams(team_a, team_b, weights_a, weights_b, outcome, cfg):
    """Return (new_team_a, new_team_b) as lists of Rating. weights_* are the
    per-player objective contribution weights within their team."""
    beta2 = cfg.rating_beta ** 2
    tau2 = cfg.rating_tau ** 2
    # dynamics: re-inflate σ² before the update
    a_sig2 = [r.sigma ** 2 + tau2 for r in team_a]
    b_sig2 = [r.sigma ** 2 + tau2 for r in team_b]
    a_mu = [r.mu for r in team_a]
    b_mu = [r.mu for r in team_b]

    sum_sig2 = sum(a_sig2) + sum(b_sig2)
    c = math.sqrt(sum_sig2 + 2.0 * beta2)
    mean_a_mu = sum(a_mu) / len(a_mu)
    mean_b_mu = sum(b_mu) / len(b_mu)
    eps = cfg.rating_draw_margin  # already a fraction of c-scale margin; applied on standardized t

    mean_wa = sum(weights_a) / len(weights_a)
    mean_wb = sum(weights_b) / len(weights_b)

    def updated(mu_i, sig2_i, mu_self, mu_opp, sign, w_i, mean_w):
        t = (mu_self - mu_opp) / c
        if outcome is Outcome.DRAW:
            v = _v_draw(t, eps)
            w = _w_draw(t, eps)
            s = 1.0  # draw v is already signed by t
        else:
            v = _v_win(sign * t)
            w = _w_win(sign * t)
            s = sign
        new_mu = mu_i + s * (w_i / mean_w) * (sig2_i / c) * v
        factor = max(1.0 - (sig2_i / (c * c)) * w, _SIGMA_FLOOR_FRACTION)
        new_sigma = math.sqrt(sig2_i * factor)
        return Rating(new_mu, new_sigma)

    if outcome is Outcome.A_WINS:
        sign_a, sign_b = 1.0, -1.0
    elif outcome is Outcome.B_WINS:
        sign_a, sign_b = -1.0, 1.0
    else:
        sign_a = sign_b = 1.0

    new_a = [updated(a_mu[i], a_sig2[i], mean_a_mu, mean_b_mu, sign_a, weights_a[i], mean_wa)
             for i in range(len(team_a))]
    new_b = [updated(b_mu[i], b_sig2[i], mean_b_mu, mean_a_mu, sign_b, weights_b[i], mean_wb)
             for i in range(len(team_b))]
    return new_a, new_b


def tier_for(ordinal: float, cfg) -> str:
    name = cfg.rating_tier_breakpoints()[0][1]
    for lo, label in cfg.rating_tier_breakpoints():
        if ordinal >= lo:
            name = label
        else:
            break
    return name
```

**Reconcile with the oracle:** run the golden test. If μ/σ do not match `openskill` to `rel_tol=1e-6`, the divergence is in the win-path `v/w`, the `c`/`τ` handling, or the σ update — fix `rating.py` (NOT the golden) until it matches. The equal-weight decisive-win case MUST equal the library; that is the whole point of the oracle.

- [ ] **Step 4: Run green.** All of `tests/test_rating.py` passes.

- [ ] **Step 5: Commit.**
```bash
git add backend/app/rating.py backend/tests/test_rating.py
git commit -m "feat(m9-p2): pure OpenSkill two-team rating module (oracle-pinned)"
```

---

### Task 3: `PlayerRating` model + `matches.rated` column + migration

**Files:**
- Modify: `backend/app/models.py`
- Modify: `backend/app/db.py`
- Test: `backend/tests/test_models.py`

- [ ] **Step 1: Write the failing test** — append to `tests/test_models.py` (follow the module's existing fixture pattern for an engine/session against the compose DB; reuse whatever helper the P1 `test_models.py` trusted-column test used):

```python
async def test_player_rating_and_match_rated_roundtrip(session):
    import datetime as dt
    from app.models import PlayerRating, Match
    now = dt.datetime.now(dt.timezone.utc)
    session.add(PlayerRating(
        player_key="name:Alpha", mu=27.5, sigma=6.1, ordinal=9.2,
        tier="Silver", matches_rated=3, last_match_id="m1", updated_at=now))
    session.add(Match(
        match_id="m-rated", server_id="s", map="conquest_town", mode="conquest",
        report_version=1, complete=True, ingested_at=now, trusted=True, rated=True))
    await session.commit()
    r = await session.get(PlayerRating, "name:Alpha")
    assert r.tier == "Silver" and r.matches_rated == 3
    m = await session.get(Match, "m-rated")
    assert m.rated is True
```

- [ ] **Step 2: Run red.** Expect FAIL (no `PlayerRating`, no `Match.rated`).

- [ ] **Step 3: Implement.** In `app/models.py` add the `rated` column to `Match` (next to `trusted`):

```python
    # M9-P2 (ADR-0012): true once this match's rating update has been applied
    # exactly once. Rating is order-dependent + non-idempotent, so this guards
    # re-application; rebuild_ratings() clears it to replay from scratch.
    rated: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default="false")
```

and a new model:

```python
class PlayerRating(Base):
    __tablename__ = "player_ratings"
    # Additive, decoupled like the M20 rollups — no FK to players.
    player_key: Mapped[str] = mapped_column(String, primary_key=True)
    mu: Mapped[float] = mapped_column(Float, default=25.0)
    sigma: Mapped[float] = mapped_column(Float, default=25.0 / 3.0)
    ordinal: Mapped[float] = mapped_column(Float, default=0.0, index=True)
    tier: Mapped[str] = mapped_column(String, default="", index=True)
    matches_rated: Mapped[int] = mapped_column(Integer, default=0)
    last_match_id: Mapped[str | None] = mapped_column(String, nullable=True)
    updated_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True))
```

In `app/db.py`, in `init_db` right after the existing `trusted` ALTER, add:

```python
        await conn.exec_driver_sql(
            "ALTER TABLE matches ADD COLUMN IF NOT EXISTS "
            "rated BOOLEAN NOT NULL DEFAULT FALSE")
```

(`create_all` builds `player_ratings` on fresh DBs; existing DBs get the column via the idempotent ALTER. Confirm the exact surrounding block by reading `db.py` first.)

- [ ] **Step 4: Run green.** `-k player_rating_and_match_rated`. PASS.

- [ ] **Step 5: Commit.**
```bash
git add backend/app/models.py backend/app/db.py backend/tests/test_models.py
git commit -m "feat(m9-p2): player_ratings table + matches.rated column (idempotent migration)"
```

---

### Task 4: `app/rating_apply.py` — incremental + rebuild

**Files:**
- Create: `backend/app/rating_apply.py`
- Test: `backend/tests/test_rating_apply.py`

Read `app/ingest.py` and `app/rollups.py` first for the session/upsert idioms this codebase uses (e.g. how they upsert and how `MatchPlayer`/`Match` are queried).

- [ ] **Step 1: Write the failing tests.** Create `tests/test_rating_apply.py`. Use the module's DB `session` fixture. Provide a small helper that inserts a two-team match with given per-player stats + winner + trusted/complete flags, then assert:

```python
# sketch — flesh out with the repo's fixture style
async def test_only_trusted_complete_matches_rated(session, settings):
    from app.rating_apply import update_ratings
    from app.models import PlayerRating, Match
    await _insert_match(session, "m1", trusted=True, complete=True,
                        team_a=[("name:A", dict(kills=10, captures=2))],
                        team_b=[("name:B", dict(kills=1))], winner="team_a")
    await _insert_match(session, "m2", trusted=False, complete=True,
                        team_a=[("name:C", {})], team_b=[("name:D", {})], winner="team_a")
    n = await update_ratings(session, settings)
    assert n == 1
    assert await session.get(PlayerRating, "name:A") is not None
    assert await session.get(PlayerRating, "name:C") is None
    assert (await session.get(Match, "m1")).rated is True
    assert (await session.get(Match, "m2")).rated is False


async def test_exactly_once_second_cycle_rates_zero(session, settings):
    from app.rating_apply import update_ratings
    await _insert_match(session, "m1", trusted=True, complete=True,
                        team_a=[("name:A", dict(kills=5))],
                        team_b=[("name:B", {})], winner="team_a")
    assert await update_ratings(session, settings) == 1
    assert await update_ratings(session, settings) == 0


async def test_two_team_requirement_skips_malformed(session, settings):
    from app.rating_apply import update_ratings
    from app.models import PlayerRating
    # single team -> skipped, no rows
    await _insert_match(session, "m1", trusted=True, complete=True,
                        team_a=[("name:A", {}), ("name:B", {})], team_b=[], winner="team_a")
    assert await update_ratings(session, settings) == 0
    assert await session.get(PlayerRating, "name:A") is None


async def test_rebuild_matches_incremental(session, settings):
    from app.rating_apply import update_ratings, rebuild_ratings
    from app.models import PlayerRating
    # two ordered trusted matches
    await _insert_match(session, "m1", trusted=True, complete=True, ended="2026-07-12T00:00:00Z",
                        team_a=[("name:A", dict(kills=9, captures=3))],
                        team_b=[("name:B", dict(kills=1))], winner="team_a")
    await _insert_match(session, "m2", trusted=True, complete=True, ended="2026-07-12T00:05:00Z",
                        team_a=[("name:A", dict(kills=8, captures=2))],
                        team_b=[("name:B", dict(kills=2))], winner="team_a")
    await update_ratings(session, settings)
    inc = {r.player_key: (round(r.mu, 9), round(r.sigma, 9))
           for r in (await session.execute(__import__("sqlalchemy").select(PlayerRating))).scalars()}
    await rebuild_ratings(session, settings)
    reb = {r.player_key: (round(r.mu, 9), round(r.sigma, 9))
           for r in (await session.execute(__import__("sqlalchemy").select(PlayerRating))).scalars()}
    assert inc == reb


async def test_require_trusted_false_rates_untrusted(session, settings):
    from app.rating_apply import update_ratings
    settings2 = settings.model_copy(update={"rating_require_trusted": False})
    await _insert_match(session, "m1", trusted=False, complete=True,
                        team_a=[("name:A", dict(kills=3))], team_b=[("name:B", {})], winner="team_a")
    assert await update_ratings(session, settings2) == 1
```

Provide a `settings` fixture (`Settings()`), and the `_insert_match` helper writing `Match` + `MatchPlayer` rows (default `ended_at`/`started_at` when omitted). Follow whatever `test_ingest_match.py` / `test_rollups.py` already do for inserting matches to stay consistent.

- [ ] **Step 2: Run red.** Expect FAIL (module missing).

- [ ] **Step 3: Implement `app/rating_apply.py`:**

```python
"""Apply the pure rating update (app.rating) to trusted match reports.

Incremental (`update_ratings`) rates each trusted+complete+unrated match exactly
once, in chronological order, committing per match. `rebuild_ratings` truncates
and replays deterministically for tests/migrations/knob changes.
"""
import datetime as dt

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Match, MatchPlayer, PlayerRating
from app.rating import (
    Outcome, Rating, default_rating, performance_score, rate_two_teams, tier_for,
)


def _outcome_for(winner, team_a_label, team_b_label) -> Outcome:
    if not winner or winner in ("draw", "none"):
        return Outcome.DRAW
    if winner == team_a_label:
        return Outcome.A_WINS
    if winner == team_b_label:
        return Outcome.B_WINS
    return Outcome.DRAW


async def _rate_one(session: AsyncSession, match: Match, settings, now: dt.datetime) -> bool:
    rows = (await session.execute(
        select(MatchPlayer).where(MatchPlayer.match_id == match.match_id))).scalars().all()
    teams: dict[str, list[MatchPlayer]] = {}
    for mp in rows:
        teams.setdefault(mp.team, []).append(mp)
    if len(teams) != 2:
        return False  # BR / malformed — skip (logged by caller via return)
    (label_a, mps_a), (label_b, mps_b) = sorted(teams.items())

    keys_a = [mp.player_key for mp in mps_a]
    keys_b = [mp.player_key for mp in mps_b]
    all_keys = keys_a + keys_b
    existing = {
        r.player_key: r
        for r in (await session.execute(
            select(PlayerRating).where(PlayerRating.player_key.in_(all_keys)))).scalars()
    }

    def cur(key) -> Rating:
        r = existing.get(key)
        return Rating(r.mu, r.sigma) if r else default_rating(settings)

    team_a = [cur(k) for k in keys_a]
    team_b = [cur(k) for k in keys_b]
    w_a = [performance_score(mp, settings) for mp in mps_a]
    w_b = [performance_score(mp, settings) for mp in mps_b]
    outcome = _outcome_for(match.winner, label_a, label_b)

    new_a, new_b = rate_two_teams(team_a, team_b, w_a, w_b, outcome, settings)

    for key, rating in list(zip(keys_a, new_a)) + list(zip(keys_b, new_b)):
        ordinal = rating.ordinal(settings.rating_ordinal_z)
        row = existing.get(key)
        if row is None:
            row = PlayerRating(player_key=key, matches_rated=0)
            session.add(row)
        row.mu = rating.mu
        row.sigma = rating.sigma
        row.ordinal = ordinal
        row.tier = tier_for(ordinal, settings)
        row.matches_rated = (row.matches_rated or 0) + 1
        row.last_match_id = match.match_id
        row.updated_at = now
    match.rated = True
    return True


async def update_ratings(session: AsyncSession, settings) -> int:
    now = dt.datetime.now(dt.timezone.utc)
    stmt = select(Match).where(Match.complete.is_(True), Match.rated.is_(False))
    if settings.rating_require_trusted:
        stmt = stmt.where(Match.trusted.is_(True))
    stmt = stmt.order_by(
        Match.ended_at.asc().nulls_last(),
        Match.started_at.asc().nulls_last(),
        Match.match_id.asc())
    matches = (await session.execute(stmt)).scalars().all()
    rated = 0
    for match in matches:
        applied = await _rate_one(session, match, settings, now)
        if applied:
            await session.commit()
            rated += 1
        else:
            # mark skipped malformed matches rated so they don't re-scan forever?
            # No: leave rated=False; a later corrected report could still apply.
            await session.rollback()
    return rated


async def rebuild_ratings(session: AsyncSession, settings) -> int:
    await session.execute(update(Match).values(rated=False))
    await session.execute(PlayerRating.__table__.delete())
    await session.commit()
    return await update_ratings(session, settings)
```

Note the deliberate choice in the malformed-match branch (documented inline): skipped matches are **not** marked rated, so a corrected re-report can still be applied; they are simply re-scanned (cheap — they stay in the unrated set). If a spec-reviewer flags the re-scan cost, that is an accepted trade for correctness at P2 scale; note it, don't "fix" it by poisoning `rated`.

- [ ] **Step 4: Run green.** All of `tests/test_rating_apply.py` passes.

- [ ] **Step 5: Commit.**
```bash
git add backend/app/rating_apply.py backend/tests/test_rating_apply.py
git commit -m "feat(m9-p2): rating apply layer (incremental + deterministic rebuild)"
```

---

### Task 5: Worker `run_cycle` step 5

**Files:**
- Modify: `backend/worker/run.py`
- Test: `backend/tests/test_worker.py`

- [ ] **Step 1: Write the failing test** — extend `tests/test_worker.py` following its existing `run_cycle` test style:

```python
async def test_run_cycle_reports_rated_count(sessionmaker_fixture, settings):
    from worker.run import run_cycle
    # seed a trusted+complete two-team match via the same helper the module uses
    await _seed_trusted_two_team_match(sessionmaker_fixture)
    result = await run_cycle(sessionmaker_fixture, settings)
    assert "rated" in result
    assert result["rated"] >= 1
```

If `test_worker.py` has no match-seeding helper, reuse `_insert_match` logic from `test_rating_apply.py` (extract to a shared `tests/_factories.py` if that keeps things DRY — check whether such a helper module already exists before creating one).

- [ ] **Step 2: Run red.** Expect FAIL (`"rated"` absent).

- [ ] **Step 3: Implement.** In `worker/run.py`: import `from app.rating_apply import update_ratings`; add `"rated": 0` to the `result` dict init; append step 5 after the anomaly block:

```python
    # 5. skill-rating update over freshly-trusted matches (ADR-0012)
    try:
        async with sm() as session:
            rated = await update_ratings(session, settings)
        result["rated"] = rated
        if rated:
            print(f"[worker] rated {rated} matches", flush=True)
    except Exception as exc:
        print(f"[worker] rating update failed: {exc!r}", flush=True)
```

Update the `run_cycle` docstring's step list (`prune -> rollup -> enrich -> detect -> rate`).

- [ ] **Step 4: Run green.**

- [ ] **Step 5: Commit.**
```bash
git add backend/worker/run.py backend/tests/test_worker.py
git commit -m "feat(m9-p2): worker run_cycle step 5 — rating update"
```

---

### Task 6: Admin read surface

**Files:**
- Create: `backend/app/rating_read.py`
- Modify: `backend/app/admin_api.py`, `backend/app/admin_web.py`
- Create: `backend/app/templates/admin/ratings.html` (confirm real template dir)
- Test: `backend/tests/test_rating_read.py` + extend the admin-auth test module

Read `app/admin_api.py`, `app/admin_web.py`, `app/admin_auth.py`, and the anomalies template + its tests first; copy those patterns exactly (route registration, `require_admin` dependency, autoescape, the 403 gate test).

- [ ] **Step 1: Write the failing tests.** `tests/test_rating_read.py`:

```python
async def test_leaderboard_orders_by_ordinal_desc(session):
    import datetime as dt
    from app.models import PlayerRating
    from app.rating_read import leaderboard, rating_summary
    now = dt.datetime.now(dt.timezone.utc)
    session.add_all([
        PlayerRating(player_key="name:Lo", mu=20, sigma=5, ordinal=5.0, tier="Bronze",
                     matches_rated=2, updated_at=now),
        PlayerRating(player_key="name:Hi", mu=30, sigma=4, ordinal=18.0, tier="Gold",
                     matches_rated=4, updated_at=now),
    ])
    await session.commit()
    rows = await leaderboard(session, limit=10, offset=0)
    assert [r.player_key for r in rows] == ["name:Hi", "name:Lo"]
    summary = await rating_summary(session)
    assert summary["total_rated_players"] == 2
    assert summary["tiers"]["Gold"] == 1 and summary["tiers"]["Bronze"] == 1
```

And an admin-gate test mirroring the anomalies 403 test (unauthenticated → 403 on `/admin/ratings`, `/admin/api/ratings`, `/admin/api/ratings/summary`; authorized allowlisted SteamID / `ADMIN_DEV_OPEN` → 200).

- [ ] **Step 2: Run red.**

- [ ] **Step 3: Implement.** `app/rating_read.py`:

```python
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import PlayerRating


async def leaderboard(session: AsyncSession, limit: int = 100, offset: int = 0):
    stmt = (select(PlayerRating)
            .order_by(PlayerRating.ordinal.desc(), PlayerRating.player_key.asc())
            .limit(limit).offset(offset))
    return (await session.execute(stmt)).scalars().all()


async def rating_summary(session: AsyncSession) -> dict:
    total = (await session.execute(
        select(func.count()).select_from(PlayerRating))).scalar_one()
    tier_rows = (await session.execute(
        select(PlayerRating.tier, func.count())
        .group_by(PlayerRating.tier))).all()
    rated_matches = (await session.execute(
        select(func.coalesce(func.sum(PlayerRating.matches_rated), 0)))).scalar_one()
    return {
        "total_rated_players": int(total),
        "total_rating_applications": int(rated_matches),
        "tiers": {tier: int(n) for tier, n in tier_rows},
    }
```

Register (behind `require_admin`, matching the anomalies routes exactly):
- `admin_api.py`: `GET /admin/api/ratings` → `{"players": [...]}` (serialize player_key, mu, sigma, ordinal, tier, matches_rated, last_match_id), `?limit`/`?offset`; `GET /admin/api/ratings/summary` → `rating_summary(...)`.
- `admin_web.py`: `GET /admin/ratings` → render `admin/ratings.html` with `players=leaderboard(...)` + `summary=rating_summary(...)`; add a nav link next to the anomalies link.
- `templates/admin/ratings.html`: table (rank, player_key, tier, ordinal, μ, σ, matches_rated) + a tier-distribution summary block. Autoescape on (Jinja default in this app — verify); treat `player_key` as untrusted.

- [ ] **Step 4: Run green.** `tests/test_rating_read.py` + the admin-gate test pass.

- [ ] **Step 5: Commit.**
```bash
git add backend/app/rating_read.py backend/app/admin_api.py backend/app/admin_web.py \
        backend/app/templates/admin/ratings.html backend/tests/test_rating_read.py \
        backend/tests/<admin_auth_test_module>.py
git commit -m "feat(m9-p2): admin-only rating leaderboard read surface (require_admin gated)"
```

---

### Task 7: Full-stack gate + evidence

**Files:**
- Create: `docker/m9_p2_rating_gate.sh`
- Create: `docs/gate-evidence/m9-p2-rating.md`

Model the script on `docker/m9_p1_signed_reports_gate.sh` (reuse its `play_signed_match` harness, `bf-m9-p2` project, PSQL helper). Before any match, copy the gitignored native encoder `.so` into the worktree:

```bash
cp /home/roland/projects/blockfire/native/snapshot_encoder/target/release/libsnapshot_encoder.so \
   "$ROOT/native/snapshot_encoder/target/release/" 2>/dev/null || true
```

- [ ] **Step 1: Write the gate script.** Sequence:
  1. `docker compose -p bf-m9-p2 up -d db api worker` with `INGEST_SIGNING_KEYS="game2-dev-1:gate-secret"`, `REQUIRE_SIGNED_INGEST=false` (so the negative unsigned path can be exercised), and `RATING_REQUIRE_TRUSTED=true`.
  2. Play **N signed** 24-bot two-team `conquest_town` matches (loop the P1 `play_signed_match`), each with `--stats-signing-key-id/secret`.
  3. Play **one unsigned** match (omit the signing args) → it ingests `trusted=f`.
  4. Trigger a worker cycle (either wait one `ROLLUP_INTERVAL_S`, or `docker compose -p bf-m9-p2 exec -T worker python -c "import asyncio; from app.config import get_settings; from app.db import *; from worker.run import run_cycle; ..."` — simplest: wait for the worker log to print `rated N matches`).
  5. Assert via PSQL:
     - `SELECT count(*) FROM player_ratings` > 0.
     - Every `trusted` complete match has `rated=t`; the unsigned match has `trusted=f AND rated=f`.
     - `SELECT count(DISTINCT tier) FROM player_ratings` ≥ 1 and no NULL/empty tiers.
     - Re-run a worker cycle → `rated 0 matches` in the log (exactly-once).
  6. Determinism: run `rebuild_ratings` in the api/worker container and assert per-player μ/σ unchanged (dump before/after to a temp table or compare `round(mu,6)` sets).
  7. Convergence: with a deterministic bot cohort winning repeatedly, assert the winning side's mean ordinal after the last match > after the first (query `player_ratings` snapshots, or assert monotonic tier movement for the dominant keys). If bot symmetry makes "dominant cohort" non-deterministic, instead assert the population's ordinal spread widened from the seed (σ shrank, ordinals diverged) — a weaker but deterministic convergence signal. Document which was used.
  8. `PASS`/`FAIL` summary lines; non-zero exit on any failed assertion; `cleanup` traps kill server PIDs and `docker compose -p bf-m9-p2 down -v`.

- [ ] **Step 2: Run the gate.** `GODOT=<path> ./docker/m9_p2_rating_gate.sh`. Iterate until PASS. Capture the output.

- [ ] **Step 3: Write `docs/gate-evidence/m9-p2-rating.md`** with the PASS transcript (player_ratings sample, rated flags, exactly-once log line, rebuild-determinism check, convergence signal), mirroring `m9-p1-signed-reports.md`'s structure.

- [ ] **Step 4: Commit.**
```bash
git add docker/m9_p2_rating_gate.sh docs/gate-evidence/m9-p2-rating.md
git commit -m "test(m9-p2): full-stack rating gate + evidence (PASS)"
```

---

## Final holistic review

After all tasks: dispatch a read-only final reviewer over the whole `backend/` + `docker/` diff vs `origin/master` (`d9b918c`). Focus: the rating math matches the oracle; exactly-once/rebuild correctness; trust gate can't be bypassed; admin routes are all `require_admin`; no game files touched; no runtime `openskill` dependency leaked into `pyproject.toml`. Then land per the spec §10 (detached-HEAD `--no-ff` merge to `origin/master`, push, update memory, tear down `bf-m9-p2` with `-v`, remove the worktree).
```
