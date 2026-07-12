# ADR-0012: Skill-rating service — OpenSkill (Weng-Lin), objective-weighted, over trusted reports

- **Status:** Accepted
- **Date:** 2026-07-12
- **Context milestone:** M9 P2 (see [design](../superpowers/specs/2026-07-12-m9-p2-rating-service-design.md))
- **Extends:** [ADR-0004](0004-anti-cheat-and-skill-matchmaking.md) (which left the algorithm as "Glicko-2 / OpenSkill" and the weights/boundaries to M9 tuning) and [ADR-0011](0011-signed-match-reports.md) (`matches.trusted`).

## Context

ADR-0004 ratified a hidden, objective-weighted rating with uncertainty as the skill metric and fast-converging placement as the primary smurf defense, but deliberately left two things open: **which** rating algorithm, and the exact objective weights/tier boundaries. P1 landed signed match reports and a durable `matches.trusted` flag; P2 is the first consumer of that flag and must now close the algorithm question.

Forces:
- Conquest is a **team** game (two teams, up to 64 a side). A rating update consumes a team-vs-team outcome and must distribute credit across each team's players by contribution.
- The backend keeps a **minimal-dependency, pure-module** posture (`signing.py`, `anomaly.py` are dependency-free and fully unit-tested); [deterministic testing is a project value](../superpowers/specs/2026-07-12-m9-p2-rating-service-design.md) over blind tuning.
- Rating math must be exactly reproducible for tests, gates, and future appeals.

## Decision

1. **Algorithm: Weng-Lin OpenSkill, two-team Thurstone–Mosteller update — not Glicko-2.** OpenSkill is natively multi-team with a per-player (μ, σ); its two-team full-pairing update has a clean closed form, converges fast under high initial σ, and reduces exactly to 1v1. Glicko-2 is 1v1-native (chess) and would need an ad-hoc team adaptation.
2. **Self-implemented, no new dependency.** The update lives in a pure `app/rating.py`, pinned by a hand-checked golden unit test. This keeps the minimal-dependency posture, makes the math fully deterministic/testable, and lets objective-weighting hook directly into the per-player step (a library would force weighting to be bolted on around it).
3. **Objective-weighting via per-player contribution weights.** Each player's share of their team's Δμ/Δσ scales with an objective-weighted performance score (kills, assists, captures, neutralizes, revives, minus deaths; captures/neutralizes weighted highest, matching the Conquest win condition). Objective play on a losing team loses less; a passenger on a winning team gains less.
4. **Only trusted matches affect rating** (`RATING_REQUIRE_TRUSTED`, default true) — the reason P1 exists. Applied exactly once, in chronological order, guarded by a durable `matches.rated` flag; a `rebuild` path replays deterministically.
5. **Fast-converging placement:** seed μ=25, σ=25/3 (high uncertainty). Primary smurf defense, per ADR-0004.
6. **Weights and tier boundaries are config knobs, not constants**, so ADR-0004's "tune with real data" holds without code changes. Rating stays **hidden** (ADR-0004): P2's only read surface is the admin dashboard.

## Alternatives considered

- **Glicko-2** — rejected: 1v1-native; team adaptation (average-team-rating hacks) is exactly the ad-hoc complexity OpenSkill avoids.
- **The `openskill` PyPI library** — rejected for P2: adds a dependency and still requires bolting objective-weighting around its API; the two-team closed form is small enough to own and pin with a golden test. Revisit if we ever need the full N-team Plackett-Luce model (BR / >2 teams), which is the documented deferral.
- **Raw K/D or XP thresholds** — rejected by ADR-0004 (rewards camping over objectives; gameable).

## Consequences

- Adds `player_ratings` (current μ/σ/ordinal/tier per player) and one durable `matches.rated` column (idempotent `ADD COLUMN IF NOT EXISTS`, Alembic still not adopted).
- Adds a worker `run_cycle` step 5 (`update_ratings`) in the established own-session/own-try-except shape; no game-tick cost (out-of-band, per ADR-0004).
- Rating is order-dependent and non-idempotent per match (unlike the M20 rollups) — hence the `rated` flag + `rebuild` replay; the gate asserts exactly-once and rebuild determinism.
- **Two-team only** in P2: BR / >2-team matches are skipped and logged; N-team Plackett-Luce is deferred.
- Supersede if a player-facing rating display is ever adopted (would reopen ADR-0004's "hidden" decision) or if kernel/again a different rating model is chosen.

## Links

- Design: [M9-P2 Rating Service](../superpowers/specs/2026-07-12-m9-p2-rating-service-design.md)
- Extends: [ADR-0004](0004-anti-cheat-and-skill-matchmaking.md), [ADR-0011](0011-signed-match-reports.md)
- Milestone: [M9 — Online Services](../milestones/M9-online-services.md)
