# M9-P2 Rating Service — Gate Evidence (PASS)

**Date:** 2026-07-12 · **Milestone:** M9 P2 · **Spec:** [rating-service design](../superpowers/specs/2026-07-12-m9-p2-rating-service-design.md) §9 · **Decision:** [ADR-0012](../adr/0012-rating-service.md) · **Harness:** `docker/m9_p2_rating_gate.sh`

## What was proven

The rating service computes a hidden OpenSkill rating **only from trusted match reports**, exactly once per match, deterministically reproducible, and exposes it admin-only. End-to-end over the real Godot game server + StatsReporter + backend worker (compose project `bf-m9-p2`, game port 28423):

1. A fresh backend (db + api + worker) is brought up with `INGEST_SIGNING_KEYS="game2-dev-1:***"`, `REQUIRE_SIGNED_INGEST=false`, rating trust-gating at its default (`RATING_REQUIRE_TRUSTED=true`).
2. **3 signed** 24-bot two-team `conquest_town` matches are played (HMAC-signed ingest → `matches.trusted=t`).
3. **1 unsigned** match is played (→ `matches.trusted=f`).
4. The worker `run_cycle` step 5 rates the trusted matches; assertions run against Postgres.

## Result: `GATE PASS`

### Matches table — trusted matches rated, unsigned match not
```
    match_id     | trusted | complete | rated | winner
-----------------+---------+----------+-------+--------
 1783865911-8067 | t       | t        | t     | team_1
 1783865987-1933 | t       | t        | t     | team_1
 1783866063-2840 | t       | t        | t     | team_1
 1783866124-1323 | f       | t        | f     | team_1   ← unsigned: trusted=f, never rated
```

### Worker rated the trusted matches (step 5)
```
worker-1 | [worker] rated 1 matches
worker-1 | [worker] rated 1 matches
worker-1 | [worker] rated 1 matches
```

### player_ratings sample (24 rows total)
```
 player_key  |   mu    | sigma  | ordinal |  tier  | matches_rated
-------------+---------+--------+---------+--------+---------------
 name:bot-17 | 29.6562 | 8.1694 |  5.1479 | Bronze |             3
 name:bot-7  | 28.2250 | 8.1694 |  3.7167 | Bronze |             3
 name:bot-9  | 27.8013 | 8.1694 |  3.2930 | Bronze |             3
 name:bot-1  | 27.5894 | 8.1694 |  3.0812 | Bronze |             3
 ...
```
(μ moved off the 25.0 seed per performance; σ shrank below the 25/3≈8.333 seed after 3 rated matches; ordinal = μ − 3σ; tier from the ordinal breakpoints.)

### Assertions (all PASS)
```
PASS (a)  player_ratings populated (24 rows)
PASS (b)  all trusted+complete matches rated (0 unrated)
PASS (c1) untrusted match present (1 trusted=f row)
PASS (c2) untrusted match NOT rated (0)
PASS (d1) no null/empty tiers
PASS (d2) distinct tiers present (1)
PASS (g1) ordinal spread widened (>0): 7.5054
PASS (g2) mean sigma below seed: 8.16941 < 8.33333
PASS (e)  exactly-once: idle worker cycle did NOT re-rate
          (max(updated_at) unchanged 14:22:27.279141 before==after; trusted-unrated=0)
PASS (f)  rebuild determinism: dump → rebuild_ratings() → dump byte-identical (24 players)
GATE_EXIT=0
```

- **Trust gate (a/b/c):** rating rows exist and every trusted+complete match flipped to `rated=t`, while the unsigned (`trusted=f`) match was never rated — this is the P1→P2 contract: only signed reports affect rating.
- **Exactly-once (e):** a second, idle worker cycle re-scanned and rated 0; `player_ratings.updated_at` did not advance — the `matches.rated` guard holds.
- **Determinism (f):** `rebuild_ratings()` (truncate + replay in chronological order) reproduced every player's μ/σ byte-for-byte — the order-dependent update is reproducible.
- **Convergence (g):** after 3 matches the population's ordinal spread is 7.51 and mean σ fell below the seed — ratings are moving/converging. (Bots rotate teams across matches, so this is the deterministic spread/σ signal from the plan rather than a single dominant cohort.)

## Reproduce
```bash
# from the worktree root, with the native encoder .so copied in (see script header)
GODOT=/usr/bin/godot ./docker/m9_p2_rating_gate.sh
```
The script brings the stack up fresh, plays the matches, asserts, and tears down (`down -v`) on exit.

## Companion evidence
- Backend unit/integration suite: **241 passed** (python:3.11 container vs compose Postgres), including the OpenSkill rating math oracle-pinned against `openskill` 6.2.0 (1v1/2v1/2v2 golden vectors), the apply-layer trust-gate/exactly-once/rebuild tests, and the admin-surface 403/200 auth-gate + XSS tests.
