# M9 — Online Services (Accounts, Anti-Cheat Detection, Matchmaking)

**Status:** **STARTED 2026-07-12** (owner elected to start early, attaching trust-hardening to the shipped M20 stats datastore — [design](../superpowers/specs/2026-07-11-stats-analytics-backend-design.md)) · originally deferred Beta / post-1.0 ([ADR-0007](../adr/0007-battlebit-divergences.md) §4, 2026-06-18)

**Objective:** Stand up the project's first persistent backend so players authenticate via Steam, get matched by skill into the right server tier, and cheaters are detected from server-side telemetry. Decision: [ADR-0004](../adr/0004-anti-cheat-and-skill-matchmaking.md). Design: [anti-cheat-matchmaking spec](../specs/anti-cheat-matchmaking.md).

## Phasing (allocated 2026-07-12)

M9 attaches rating + matchmaking + trust-hardening to the M20 `backend/` datastore (nothing there is discarded). Phases, smallest-and-most-foundational first:

| Phase | Scope | Depends on | Status |
|---|---|---|---|
| **P1 — Signed match reports** | Game server signs `/ingest/events` + `/ingest/match`; backend verifies (HMAC-SHA256, per-server keys) and records a durable `matches.trusted` flag. Hardens the M20 ingest contract in place. Design: [`2026-07-12-m9-p1-signed-match-reports-design`](../superpowers/specs/2026-07-12-m9-p1-signed-match-reports-design.md) · Decision: [ADR-0011](../adr/0011-signed-match-reports.md). | M20 P1 | **in-progress** |
| **P2 — Rating service** | Objective-weighted hidden rating (Glicko-2 / OpenSkill) + uncertainty + tier bucket over **P1-trusted** reports; fast-converging placement. | P1 | planned |
| **P3 — Layer-4 statistical detection** | Extend the M20-P4 anomaly engine (aim-snap/flick consistency, reaction-time, headshot ratio, fire-pattern regularity) over `events` → suspicion signal + review queue. | P1 (+ M20 P4) | planned |
| **P4 — Steam auth gateway + ownership** | Client session ticket → server `BeginAuthSession` → backend auth-gateway → `steam:`-keyed session; `GetPlayerBans` hard signal + soft priors. Carries the GodotSteam + $100 Steam Direct external dependency. | P1 | planned |
| **P5 — Matchmaker + tier-merge + shadow pool** | Soft rating buckets, dynamic tier-merge under low population, VAC-ban (`DaysSinceLastBan ≤ 1825`) + Layer-4-flag routing to a silent shadow pool. | P2, P3, P4 | planned |

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
- [`docs/specs/client-packaging-release-hardening.md`](../specs/client-packaging-release-hardening.md) (written) — client-side release hardening ([ADR-0010](../adr/0010-client-packaging-drm-hardening.md)): server-side Steam **ownership** validation, export hygiene (no secrets/server-only code in the client `.pck`), DTLS, wire/DoS hardening, PII retention. Pairs with this milestone's backend auth.
- `docs/specs/backend-architecture.md` (service boundaries, datastore schema, deploy/ops) — brainstorm before coding

## Depends on / cross-milestone notes
- **M5+**: server-side **input validation** (anti-cheat Layer 2), rules in `shared/`, covering vehicle inputs.
- **M7**: **Steam auth (session tickets) + VAC** baseline, and **LOS culling** (Layer 3). M9's auth-gateway builds on M7's Steam auth.
- **M4**: building/destruction should keep occlusion data queryable so M7 LOS culling is feasible (flagged dependency).
- **Release hardening ([ADR-0010](../adr/0010-client-packaging-drm-hardening.md))**: the backend auth-gateway is the server side of ownership validation — clients never gate ownership locally (Goldberg-emulator resilient); the Steam Web API publisher key + match-report signing keys live in the backend, **never** in the client `.pck`; SteamID-keyed stats carry the PII/retention obligations (privacy policy, 90-day retention, deletion path).
