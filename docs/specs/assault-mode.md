# Spec: Assault game mode (asymmetric attack/defend)

**Status:** plan of record (design approved) · **Date:** 2026-06-18 · **Milestone:** [M13](../milestones/M13-assault-mode.md) · **Decision:** [ADR-0007](../adr/0007-battlebit-divergences.md)

A second match mode beside Conquest: one team **Defends** territory, the other **Attacks** it. Builds on the existing `ConquestState` capture/ticket machinery (M3) — Assault is a **rules variant of conquest stepping**, not a new sim. Server-authoritative; shared rules in `shared/sim/`. **Implementation is deferred** until the core mechanics + rendered client are solid (post-M7/M7.5/M8) — this spec is the plan of record, not a build-now task.

## Design decisions (ratified — see ADR-0007 §3)

| Decision | Choice | Rationale |
|---|---|---|
| Sides | **Defenders vs Attackers** (asymmetric) | The point of the mode — an attack/defend experience on top of symmetric Conquest. |
| Opening ownership | **Defenders own all CPs; Attackers own only an uncap** | Defenders hold the ground; attackers must take it. |
| Uncaps | **Attackers have an uncap; Defenders have none** | Defenders rely on CPs + FOBs/squadmates to spawn; losing all CPs strands them — enables the attacker default-win. |
| Defender bleed | **No ticket bleed until ALL CPs are attacker-held** | Defenders are punished only once fully pushed off the map; holding even one CP stops the bleed. |
| Ticket pools | **Attackers ≈ 2× Defenders** (gate-tuned) | Attacking is harder/costlier; the larger pool funds repeated assaults. |
| Capture order | **Any order** (Conquest-on-attack) | Reuses the M3 neutralize-then-take per-point machinery; minimal new code. |
| Recapture | **Defenders may retake lost CPs** | Keeps the front dynamic; makes the "all CPs held" attacker-win a live, losable state. |
| Attacker default-win | **All CPs held + no living defender** | With no uncap and no usable FOB/squadmate, defenders cannot respawn → match decided. |
| Ticket win (both) | **Drain enemy tickets to 0** as in Conquest | Either side can still win the normal way. |

## A. Mode selection & map data

- **Mode is a match/server setting** (`mode ∈ {CONQUEST, ASSAULT}`), chosen at match start. Default stays Conquest.
- **Map data** (`maps/*.json`) gains an optional Assault block per map (or a separate Assault map variant): which **team is the Defender** (owns all CPs at start) and which is the **Attacker** (uncap only). Reuses the existing `points[]` + `bases[]` schema:
  - All `points` get `start_owner = <defender team>`.
  - The **attacker base** is the only uncap; the **defender base entry is omitted / flagged non-spawn** (defenders have no uncap). Loader validates: exactly one uncap (attacker), defender side has ≥1 CP.

## B. Conquest-state variant (`shared/sim/conquest.gd`, extends M3 §B)

`ConquestState` gains a `mode` and (for Assault) `attacker_team` / `defender_team`. The per-point capture/neutralize machinery (presence count, contest freeze, neutralize-then-take, multi-attacker rate scaling, empty-point decay) is **unchanged**. Only ticket/bleed/win logic forks on `mode`:

**Bleed (Assault):**
- `all_cps_taken := every point.owner == attacker_team`.
- **Defender bleed:** `tickets[defender] -= ASSAULT_DEFENDER_BLEED * dt` **only while `all_cps_taken`** (defenders holding ≥1 CP do not bleed). Recapturing any CP immediately stops the bleed.
- **Attacker bleed:** attackers do **not** flag-bleed (they hold no "deficit" in the conquest sense); attacker tickets fall via **death cost only** (each attacker death −`DEATH_TICKET_COST`). *(Optionally a small attacker time-bleed could be added at gate-tuning to force progress — left out of v1 unless matches stall.)*
- Defender death cost (`−DEATH_TICKET_COST` per defender death) applies in both modes.

**Win check (Assault), in priority order each step:**
1. **Attacker default-win:** `all_cps_taken` **and** no living defender pawn exists (none alive on the field) → `match_over`, `winner = attacker`. (With no defender uncap and no usable FOB/squadmate spawn, defenders cannot return — see §C.)
2. **Ticket depletion:** either team `tickets ≤ 0` → that team loses, other wins (as Conquest).
3. **Time fail-safe** (`MATCH_TIME_LIMIT`): on expiry, **defenders win** if they still hold ≥1 CP (they successfully defended); else more-tickets wins. (Defending = holding ground for the clock.)

## C. Spawning in Assault (extends M3 §E + [M12 FOB](./squad-fob-class-refit.md))

- **Attackers:** uncap base + owned (captured) CPs + squad FOB (when enabled) + alive squadmate.
- **Defenders:** owned CPs + squad FOB (when enabled) + alive squadmate — **no uncap**. As attackers capture CPs, defender spawn options shrink; once all CPs fall, defenders can only spawn via a still-enabled FOB or an alive squadmate. When those are gone too, no living defender + all CPs held ⇒ the attacker default-win (§B.1).
- This makes the **M12 FOB and squadmate-fallback the defenders' last-ditch foothold** after losing all CPs — and gives attackers a concrete objective (clear the FOBs / wipe the squad) to force the default-win rather than waiting out tickets.

## D. Wire protocol

- `MATCH_STATE` (M3 §F) gains a **mode byte** and (for Assault) the attacker/defender team assignment, so clients/bots render the correct attack/defend HUD and choose spawn/objective behaviour. Point-owner/ticket payload is otherwise unchanged.
- No new per-tick stream; `MATCH_STATE` cadence unchanged (2 Hz, reliable on match end).

## E. Bot AI (`bots/bot_driver.gd`)

- Read `mode` + side from `MATCH_STATE`. **Attacker bots:** objective = nearest CP not owned by attackers (always pushing). **Defender bots:** objective = defend the nearest still-owned CP; retake the nearest attacker-held CP when pushed off (recapture). Otherwise reuse M3 objective/path/capture/respawn logic.
- Gate exerciser: bots must drive the match to **at least one full "all CPs taken" window** so the defender-bleed and the attacker default-win path are exercised deterministically (scripted scenario in the integration test, per AGENTS.md §10).

## F. Constants (initial; gate-tuned — attackers > defenders)

| Const | Value | Meaning |
|---|---|---|
| `ASSAULT_DEFENDER_TICKETS` | 200 | defender starting pool |
| `ASSAULT_ATTACKER_TICKETS` | 400 (≈2×) | attacker starting pool |
| `ASSAULT_DEFENDER_BLEED` | 1.0–2.0 /s | defender bleed once all CPs taken (tune so a fully-pushed defense loses in a sane window) |
| `DEATH_TICKET_COST` | 1 | per-death ticket cost (both sides, as M3) |
| `MATCH_TIME_LIMIT` | 1200 s | fail-safe; defenders win on expiry if holding ≥1 CP |

## G. Budgets

- **Server tick:** unchanged budget (< 33.3 ms at 128). Assault adds only a couple of O(points) / O(alive defenders) checks per step (all-CPs-taken test, living-defender test) — negligible vs `snap`.
- **Bandwidth:** `MATCH_STATE` +1 mode byte (+ a couple of bytes for side assignment), 2 Hz — negligible.

## H. Testing

**Unit (`TestCase`):**
- Assault map load: all CPs start defender-owned; exactly one (attacker) uncap; defender has no uncap.
- conquest (Assault mode): defenders **don't** bleed while holding ≥1 CP; **do** bleed once all CPs attacker-held; bleed stops on recapture; attacker tickets fall on death only; win-priority order (default-win > tickets > time fail-safe); time-fail-safe favors defenders when holding ≥1 CP.
- attacker default-win: all CPs attacker-held **and** zero living defenders ⇒ `match_over`, `winner = attacker`; not triggered while any defender is alive or any CP is defender-held.
- spawn: defender source set excludes an uncap; attacker source set includes the uncap; FOB/squadmate fallbacks behave per M12.
- protocol: `MATCH_STATE` round-trips the mode byte + side assignment.

**Integration / gate:** see [M13 gate](../milestones/M13-assault-mode.md#gate) — a 128-bot Assault match that reaches an all-CPs-taken window (defender bleed exercised), produces both an attacker win (default-win path or ticket drain) and, in a separate run, a defender win (attacker tickets drained / time fail-safe while holding a CP), with the tick + bandwidth budget held.

## I. Out of scope (explicit)

- **Sequential-sector capture / locked one-way capture** — rejected in favour of any-order + recapturable (ADR-0007). Could be a later Breakthrough variant if wanted.
- **Attacker time-bleed** — omitted from v1; add at gate-tuning only if matches stall.
- New maps/art for Assault — uses existing map schema + a side-assignment block; bespoke Assault maps are an M7+/content task.
- Client attack/defend HUD theming — M7+ (this spec replicates the mode/side data the HUD needs).
