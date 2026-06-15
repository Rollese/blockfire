# ADR-0004: Anti-cheat strategy & skill-tier matchmaking

- **Status:** Accepted
- **Date:** 2026-06-15
- **Context milestone:** M5+ / M7 / M9 (see spec)

> Note: ADR-0003 is reserved by [ADR-0001](0001-core-runtime-language.md) for a future GDExtension hot-path escalation; this decision takes the next free number.

## Context

Blockfire targets a **Steam release**. We need (a) a cheat-resistance strategy and (b) a way to match players by skill so new players aren't stomped. The game is already **server-authoritative** (AGENTS.md §7) with interest culling and a bounded relevance cap, and the server already records per-tick input + combat telemetry.

Key forces:
- Server-side anti-cheat (authority, input validation, information minimization, statistical detection) runs on hardware we control — cheapest and most effective, and partly built already.
- Third-party kernel anti-cheat (VAC/EAC/BattlEye) only protects the *client*, only matters once a rendered client ships (M7), has no official Godot binding, and (EAC) ties Linux/Proton support to an EOS rework. It is a complement, not a substitute.
- Skill tiering by **raw K/D with hard public thresholds** would reward camping over objectives (fighting the Conquest win condition), invite deliberate de-ranking, and fragment a 128-player population at launch.
- Smurf detection via Steam metadata is undermined by profile privacy; `GetPlayerBans` is the only always-public reliable signal.
- Any rating system is only as honest as the servers reporting results; community hosting (BattleBit-style) is desirable but untrusted for stats.

## Decision

1. **Anti-cheat is layered, server-side first; kernel AC deferred.** Build Layers 1–4 (authority ✅, input validation M5+, LOS culling M7, statistical detection M9). Add **Steam auth + VAC** as the free baseline at M7. Defer EAC/BattlEye until observed cheating + player base justify the integration + ops cost (EAC-via-EOS is the free escalation; weaker on Linux/Proton).
2. **Skill tiers use a hidden, objective-weighted rating** (Glicko-2 / OpenSkill), not raw K/D. Inputs weight objective play alongside kills, win-adjusted. **Fast-converging placement (high initial uncertainty) is the primary smurf defense.**
3. **Tier enforcement is soft** — matchmaker prefers a player's rating bucket but **merges adjacent tiers under low population** so 128-slot servers always fill. No hard public thresholds.
4. **Identity is SteamID; no separate web login.** A new **persistent backend** (auth-gateway, Steam Web API worker, rating-service, matchmaker, datastore) holds stats keyed by SteamID. `GetPlayerBans` is a hard smurf/ban signal; owned-games/level/age are soft, privacy-limited priors only.
5. **Only official, authenticated servers report rating-affecting results** (signed match reports). Community may host for fun without affecting rating.

## Rationale

- **Highest ROI, lowest cost:** the server-side layers reuse existing architecture and telemetry and carry no licensing cost; they stop the cheat classes that matter most (client-trusted state, then wallhack/aimbot).
- **Aligned incentives:** an objective-weighted hidden rating rewards the behaviour the Conquest mode is built around, and resists the gaming/de-ranking that a public K/D gate invites.
- **Launch-viable:** soft matchmaking with dynamic merge keeps servers full at low concurrency — an existential concern for a 128-player indie title.
- **Trustworthy stats without closing the ecosystem:** official-only rating reporting preserves data integrity while still allowing community servers.
- **No premature dependency:** kernel AC (no official Godot binding; EOS rework for EAC) is deferred until evidence justifies it — consistent with the project's YAGNI/gate-driven posture (cf. ADR-0001).

## Consequences

- Introduces the project's **first persistent stateful backend** (M9) and a dependency on the **Steam Web API publisher key** + GodotSteam (M7). GodotSteam stays at the client/server edge — never in `shared/`.
- M5+ work must add server-side input validation (incl. vehicle inputs) with rules in `shared/`; covered by unit tests + the bot-fleet gate.
- M4 building/destruction should keep occlusion data queryable so **Layer 3 LOS culling** is feasible at M7 (flagged dependency, not owned by M4).
- We accept that VAC alone is weak and that Linux/Proton protection (if EAC is ever added) is weaker than Windows kernel mode.
- Rating weights and tier boundaries are deliberately left to M9 tuning with real data.
- Supersede with a new ADR if kernel AC (EAC/BattlEye) is later adopted.

## Links

- Spec: [Anti-Cheat & Skill-Tier Matchmaking](../specs/anti-cheat-matchmaking.md)
- Milestone: [M9 — Online Services](../milestones/M9-online-services.md)
- Related: [ADR-0001](0001-core-runtime-language.md) (GDExtension escalation reserves ADR-0003)
