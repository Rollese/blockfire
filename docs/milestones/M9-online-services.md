# M9 — Online Services (Accounts, Anti-Cheat Detection, Matchmaking)

**Status:** **deferred — Beta / post-1.0** ([ADR-0007](../adr/0007-battlebit-divergences.md) §4, 2026-06-18) · **Blocked by:** M7 gate (needs Steam auth + rendered client) · **not considered until every other milestone is finished**

**Objective:** Stand up the project's first persistent backend so players authenticate via Steam, get matched by skill into the right server tier, and cheaters are detected from server-side telemetry. Decision: [ADR-0004](../adr/0004-anti-cheat-and-skill-matchmaking.md). Design: [anti-cheat-matchmaking spec](../specs/anti-cheat-matchmaking.md).

## Scope
- **Backend service** (first stateful infra): auth-gateway, Steam Web API worker, rating-service, matchmaker, datastore. Keyed by **SteamID** — no separate player login.
- **Layer 4 anti-cheat — server-side statistical detection**: aim-snap/flick consistency, reaction-time, headshot ratio, fire-pattern analysis over recorded input/combat telemetry → per-SteamID suspicion signal + review queue. Runs out-of-band; no game-tick cost.
- **Hidden objective-weighted rating** (Glicko-2 / OpenSkill); fast-converging placement as primary smurf defense.
- **Soft matchmaking + dynamic tier-merge** so 128-slot servers always fill.
- **Smurf handling**: `GetPlayerBans` hard signal; soft Steam priors (privacy-limited) nudge initial uncertainty only.
- **Trust model**: only official, authenticated servers submit **signed match reports** that affect rating; community servers may run for fun without affecting rating.
- **Cheater containment (shadow pool)**: silently route accounts with a VAC ban in the last 5 years (`GetPlayerBans` `DaysSinceLastBan ≤ 1825`) and Layer-4-flagged accounts into a separate official server pool, matched only with each other. Reversible, expires at 5 years, appeal path.

## Gate
A player authenticates via Steam, is placed into a rating tier, and is matched (with dynamic tier-merge under low population) into an official 128-slot server; match results flow back as signed reports and update the rating; a seeded cheat-like input trace is flagged by Layer 4 with measured false-positive rate on legitimate traces; forged/community match reports are rejected; an account with a VAC ban inside 5 years is routed to the shadow pool and never co-matched with clean accounts.

## Specs required
- [`docs/specs/anti-cheat-matchmaking.md`](../specs/anti-cheat-matchmaking.md) (written)
- `docs/specs/backend-architecture.md` (service boundaries, datastore schema, deploy/ops) — brainstorm before coding

## Depends on / cross-milestone notes
- **M5+**: server-side **input validation** (anti-cheat Layer 2), rules in `shared/`, covering vehicle inputs.
- **M7**: **Steam auth (session tickets) + VAC** baseline, and **LOS culling** (Layer 3). M9's auth-gateway builds on M7's Steam auth.
- **M4**: building/destruction should keep occlusion data queryable so M7 LOS culling is feasible (flagged dependency).
