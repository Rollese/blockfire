# Spec: Anti-Cheat & Skill-Tier Matchmaking

**Status:** approved (design) · **Date:** 2026-06-15 (rev. 2026-06-16) · **Milestones:** [M5](../milestones/M5-vehicles.md)+ (input validation), **online/anti-cheat track** (Steam auth + VAC + LOS culling — *deferred out of M7 on 2026-06-16; see note below*), [M9](../milestones/M9-online-services.md) (statistical detection + matchmaking backend)

> **2026-06-16 re-scope:** Layer 3 (LOS culling) and Layer 5 (Steam auth + VAC), originally slated for M7, were **deferred out of M7** to a later online/anti-cheat track. Rationale: the project may stay a LAN game for family/friends, so Steam's cost isn't justified until a published-quality game exists, and anti-wallhack/ESP only matters for untrusted public play (and adds occlusion cost to a tick budget near the edge). The designs below are unchanged; only their landing milestone moved. References to "M7" in this spec should be read as "the deferred online/anti-cheat track."

Defines how Blockfire stays cheat-resistant and matches players by skill for a **Steam release**. Decision record: [ADR-0004](../adr/0004-anti-cheat-and-skill-matchmaking.md).

The guiding principle matches the working agreement (AGENTS.md §7): **the server is authoritative, the client sends intent.** Anti-cheat is therefore built as **layers, server-side first** — the layers that run on hardware we control are both the cheapest and the most effective, and most of the foundation already exists. Third-party kernel anti-cheat (VAC/EAC) is a complementary *last* line that only becomes relevant once the rendered client ships (M7); it is never a substitute for the server-side layers.

## The layered model

| Layer | Stops | Status / lands |
|---|---|---|
| 1. Server authority | Damage/position/state forgery, god-mode | ✅ built (authoritative fire resolution, rays seeded off `_sim.tick`) |
| 2. Server-side input validation | Speedhack, teleport, noclip, fly, rapid-fire, no-recoil | **M5+** (not M4 — M4 is owned by another track) |
| 3. Information minimization (LOS) | Wallhack / ESP / radar | partial today (interest culling + `MAX_SNAPSHOT_ENTITIES=32`); LOS culling at **M7** |
| 4. Server-side statistical detection | Aimbot, triggerbot, flick-snap | **M9** (uses already-recorded input telemetry) |
| 5. Client integrity (Steam auth + VAC) | Memory tampering, injection | **M7** (first rendered client) |

## Design decisions (ratified)

| Decision | Choice | Rationale |
|---|---|---|
| Anti-cheat strategy | **Server-side layers first; kernel AC deferred** | Layers 1–4 run on hardware we control — cheapest and most effective. Defer EAC/BattlEye until observed cheating + player base justify the integration + ops cost. |
| Baseline client integrity | **Steam auth (session tickets) + VAC** | Free with Steamworks; the natural baseline at the first rendered client. VAC is weak alone but a zero-cost deterrent + ban-propagation. |
| Custom AC investment | **Layer 4 statistical detection** | Highest ROI custom work; no licensing cost; catches aimbots kernel ACs miss; reuses recorded inputs/telemetry. |
| Skill metric | **Hidden, objective-weighted rating** (Glicko-2 / OpenSkill) | Not raw K/D. Inputs weight objective play (captures/neutralizes/revives/assists) alongside kills, win-adjusted. Hidden + uncertainty-based so it can't be farmed to a visible number, and aligns with the Conquest win condition (tickets/objectives, not kills). |
| Smurf defense (primary) | **Fast-converging placement** | New accounts start with high rating uncertainty so the rating moves fast — a smurf stomping a low tier is promoted within a handful of matches. Needs no Steam metadata. |
| Smurf defense (secondary) | **`GetPlayerBans` hard signal + soft Steam priors** | `GetPlayerBans` is always-public and reliable (recent VAC/game ban → restrict/flag). Owned-games/level/age are privacy-gutted and gameable → weak priors that only nudge initial uncertainty, never hard gates. |
| Player identity | **SteamID, no separate web login** | Steam session tickets authenticate; a backend keyed by SteamID holds stats. Players never create a second account. |
| Tier enforcement | **Soft matchmaking + dynamic tier-merge** | Matchmaker prefers a player's rating bucket but merges adjacent tiers when population is low, so 128-slot servers always fill — critical for an indie launch. No hard public thresholds (they get gamed via deliberate de-ranking). |
| Stats trust model | **Only official servers count for rating** | Community may host servers for fun; only official, authenticated servers report rating-affecting results. Keeps rating data honest without banning community hosting. |
| Cheater containment | **Silent shadow pool for recent VAC bans (≤5 yr) + Layer-4 flags** | Accounts with a VAC ban in the last 5 years — and accounts the Layer-4 detector flags — are silently routed to a separate "cheater" server pool, matched only with each other. Uses the always-public `GetPlayerBans` signal; reversible; expires at 5 years. |

## Subsystem A — Anti-cheat layers (extends the existing game server)

These live in/around the existing authoritative tick loop (`server/server_main.gd`) and shared sim (`shared/sim/`); no new infrastructure.

- **Layer 2 — input validation (M5+).** Bound-check every input the server already receives, at the sim boundary, before it is applied:
  - max position/move delta per tick (speedhack, teleport, noclip),
  - view-angle rate-of-change sanity,
  - fire cadence vs weapon spec + ammo/reload state (rapid-fire, no-recoil scripts).
  Impossible inputs are rejected (clamped/dropped) and counted in telemetry. Rules live in `shared/` so client prediction and server authority can't diverge (AGENTS.md §7). M5 vehicles introduce new input types (throttle/steer/seat actions) that this validation must also cover, which is why M5 is the earliest landing point.
- **Layer 3 — line-of-sight culling (M7).** Today replication is bounded by distance interest culling + the 32-entity enemy-prioritized relevance cap. Extend to **not replicate an enemy the player has no plausible sight line to**, so wallhack/ESP has nothing to draw. M4 building/destruction changes sight lines dynamically; the M4 occlusion data must be queryable by the relevance step for this to work, so the M4 design should keep that feasible (flagged, not owned here).
- **Layer 4 — statistical detection (M9).** Offline/near-real-time analysis of the input + combat telemetry the server already records: aim-snap and flick consistency, reaction-time distributions, headshot ratios, fire-pattern regularity. Produces a per-SteamID suspicion signal → manual review queue and/or automated action. Runs in the matchmaking backend (Subsystem B), reading match telemetry; it does not add cost to the game tick.
- **Layer 5 — Steam auth + VAC (M7).** See "Steam integration" below.

## Subsystem B — Accounts & Matchmaking backend (new infrastructure, M9)

The **first persistent, stateful service** in the project (today: only stateless game servers + clients). Its own milestone ([M9](../milestones/M9-online-services.md)) and ADR. Components:

```
backend/
  auth-gateway      Validates Steam session tickets (relayed from the dedicated server); issues a backend session keyed by SteamID.
  steam-web-worker  Holds the Steam Web API publisher key. On first sight of a SteamID: GetPlayerBans (hard signal) + best-effort soft priors. Rate-limited, cached.
  rating-service    Glicko-2 / OpenSkill. Consumes signed match reports; updates per-SteamID rating + uncertainty; assigns tier bucket.
  matchmaker        Soft bucketing by rating with dynamic tier-merge under low population; hands clients a server to join.
  datastore         players (steamid, rating, sigma, ban_signal, tier), match_history.
```

### Rating system
- **Algorithm:** Glicko-2 or OpenSkill (both free, well-documented, support rating + uncertainty). Hidden from players (K/D may still be *displayed*, but does not gate servers).
- **Inputs:** per-match, objective-weighted performance — kills **and** captures/neutralizes/revives/assists — adjusted by match outcome (win/loss). Exact weights are a balance knob (M9 task), not fixed here.
- **Placement:** new accounts seed with **high uncertainty** → rating converges in a few matches. This is the primary smurf defense.

### Matchmaking & tiers
- Tiers are **rating buckets**, not K/D thresholds.
- **Soft** assignment: matchmaker prefers a player's bucket; when an adjacent bucket can't fill a 128-slot server, it **merges** buckets so servers always populate. Tier boundaries widen/narrow with live population.

### Trust model (anti-cheat for the stats themselves)
- Match-end flow: **official server → signed match report → backend validates signature + sanity → rating update → tier reassignment.**
- Community-hosted servers may run matches for fun but their reports do **not** affect rating. This closes the stat-manipulation attack surface without banning community hosting.

### Cheater containment (shadow pool)
A separate official server pool that only flagged accounts are matched into — they play *with and against each other*, never with clean players.

- **Who lands in it:**
  1. **Recent VAC ban** — `GetPlayerBans` reports `NumberOfVACBans > 0` with `DaysSinceLastBan ≤ 1825` (5 years). The matchmaker maps the player to the shadow pool on session start.
  2. **Layer-4 flags** — accounts whose statistical-detection suspicion crosses a threshold are routed here as **graduated enforcement** before any hard action, providing a low-stakes containment step.
- **Silent:** the player sees normal matchmaking UI and gets matched normally — they are simply only ever placed in shadow-pool servers. Not telling them reduces ban-evasion churn (re-rolling accounts the moment they're caught).
- **Reversible + expiring:** the VAC-history flag **expires at 5 years** (`DaysSinceLastBan` crosses 1825) and is re-evaluated on session start; Layer-4 flags are clearable on review. An **appeal path** exists.
- **Honest caveat:** `GetPlayerBans` exposes VAC counts + days-since-last-ban but **not which game** the ban came from. So this policy is deliberately strict — it also contains players VAC-banned in *unrelated* games, and can catch shared/second-hand accounts. That over-inclusiveness is the accepted trade for a zero-cost, always-public signal; the appeal path is the relief valve.
- **Orthogonal to tiers:** containment is a separate matchmaking partition; rating/tiers still apply *within* the pool so flagged players of similar skill meet.

## Steam integration (M7)

- **Auth:** client calls Steamworks `GetAuthSessionTicket` → dedicated server validates with `BeginAuthSession` (confirms ownership + not VAC/game-banned). Relayed to the backend auth-gateway to open a SteamID-keyed session. Free with Steamworks.
- **VAC:** flag the app as VAC-secured; Valve runs detection on players connecting to VAC-secured servers and issues bans. Free; user-mode; weak alone — baseline deterrent only.
- **Godot binding:** **[GodotSteam](https://godotsteam.com)** (mature third-party GDExtension wrapping Steamworks, incl. auth + VAC enabling) is the practical path. No code in `shared/` should depend on it (keep it client/server-edge only).
- **Cost:** Steam Direct **$100/app** (recoupable after $1,000 revenue); SDK, auth, and VAC are free.

### Why not EAC/BattlEye now (recorded for completeness)
- **EAC** is free via Epic Online Services, kernel-mode on Windows, but its Linux/Proton support **requires integrating EOS** (not just Steamworks) — a substantial rework — and there is **no official EAC/Godot binding**. On Linux/Proton it runs user-mode (weaker than Windows kernel). BattleBit started on EAC and **moved to a FACEIT "anti-cheat lite"** for Linux/Steam Deck. **BattlEye** is paid (negotiated). Either is a post-M9 escalation justified only by observed cheating; EAC-via-EOS is the free option if/when needed, and gives the Linux/Steam Deck story.

## Budgets & constraints
- **Layer 2** runs inside the existing 30 Hz tick; it must stay within the M-series tick budget (<33.3 ms at 128). It is O(1) per input → negligible; re-profile via `[perf]` telemetry per the handover.
- **Layer 4 + backend** run out-of-band from the game tick; no game-tick cost.
- **No gameplay rule forks:** all validation rules live in `shared/` (AGENTS.md §7).
- **Privacy:** soft Steam signals are best-effort and never hard-gate legitimate private-profile players.

## Test plan
- **Layer 2:** unit tests (`tests/*_test.gd`) feeding crafted impossible inputs (over-speed, teleport, over-cadence fire, vehicle input out of range) and asserting rejection + telemetry counter increments. Bot-fleet run shows no false rejections of legitimate bot inputs.
- **Layer 3 (M7):** test that an entity with no sight line is absent from a client's snapshot; bench the relevance step stays within budget at 128.
- **Layer 4 (M9):** replay recorded cheat-like vs human-like input traces; assert suspicion score separation; measure false-positive rate on legitimate traces.
- **Rating/matchmaking (M9):** simulate match results; assert convergence speed (smurf promoted within N matches), tier-merge triggers under low population, signed-report rejection of forged/community reports.
- **Cheater containment (M9):** a SteamID with `DaysSinceLastBan ≤ 1825` is routed to the shadow pool and never co-matched with clean accounts; a ban older than 1825 days (or cleared) is routed normally; a Layer-4 flag routes to the pool; assert the player observes no UI difference.

## Out of scope (this spec)
- Kernel anti-cheat (EAC/BattlEye) integration — separate future ADR if escalated.
- The M4 building/destruction occlusion model itself (only flagged as a dependency for Layer 3).
- Concrete rating weights and tier boundaries — tuned during M9 with real data.

## References
- EAC free via EOS, paid tiers: [easy.ac/licensing](https://www.easy.ac/licensing), [PC Gamer](https://www.pcgamer.com/epic-has-made-easy-anti-cheat-free-for-game-developers/), [Engadget](https://www.engadget.com/epic-online-services-free-voice-easy-anti-cheat-130055322.html)
- EAC Linux/Proton requires EOS: [ResetEra](https://www.resetera.com/threads/easy-anti-cheat-requires-developers-to-use-epic-online-services-to-enable-proton-linux-support.536969/), [GamingOnLinux](https://steamcommunity.com/groups/gamingonlinux/discussions/0/3200370471671510966/), [BoilingSteam](https://boilingsteam.com/enabling-eac-support-on-linux-now-easier/)
- BattleBit EAC → FACEIT for Linux/Deck: [PCGamesN](https://www.pcgamesn.com/battlebit-remastered/anti-cheat), [Game8](https://game8.co/articles/latest/692)
- Steam Web API privacy (GetOwnedGames empty on private; GetPlayerBans public): [Steamworks IPlayerService](https://partner.steamgames.com/doc/webapi/IPlayerService), [Steam Community](https://steamcommunity.com/discussions/forum/7/1729827777339922602/)
- GodotSteam: [godotsteam.com](https://godotsteam.com)
