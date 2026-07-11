# Standing-Bleed + Bandage — design

**Date:** 2026-07-03 · **Status:** approved-pending-review · **Area:** sim / gameplay (shared + server + bot + client + wire)
**Branch/worktree:** `worktree-m16-bleeding-system`

## Problem

Blockfire has no *bleeding-while-standing* mechanic. Taking non-lethal fire has no lasting cost:
health only ever comes back on respawn or a medic heal-gadget, and the `bandage_count` item is (as of
the 2026-07-03 halving-bleedout rework) an **inert reserved resource** with no consumer. BattleBit's
core survivability loop — get hit, start bleeding, drain out unless you or a squadmate bandages you —
is missing.

## Goal

Add a **standing bleed**: a bullet/blast hit that leaves you *wounded* (below a health threshold)
starts a bleed that drains the main `health` pool over time. It ends only when **bandaged** — by
yourself or a teammate — via a **timed channel**. An ignored bleed drains to 0 and routes into the
existing DBNO/halving-bleedout flow (i.e. it can down you). **Medic** bandages twice as fast and
carries far more bandages. The `bandage` item finally has a purpose; **revive** now also spends one.

This is the exact feature the halving-bleedout design
(`docs/superpowers/specs/2026-07-03-halving-bleedout-design.md`) named as out-of-scope and *reserved
the bandage item for*. The two designs are complementary; §"Coordination" tracks the shared surface.

## Decisions (owner-ratified 2026-07-03)

- **Trigger = threshold, not every graze.** A bleed starts only when a non-lethal **bullet or blast**
  hit leaves the pawn **below `BLEED_THRESHOLD` HP**. Fall damage never bleeds. Grazes that leave you
  healthy don't bleed.
- **Bleed can down you.** The drain reduces the standing `health` pool; at 0 the pawn goes DBNO
  through the existing `_down_pawn` path (so a standing bleed-out **counts as a down** and shrinks the
  next halving window). It is not a floor-and-weaken.
- **Bandage is a timed channel that also heals.** Hold-to-bandage over `BANDAGE_TICKS`; **medic ½
  time**. On completion it stops the bleed **and** restores `BANDAGE_HEAL` HP (capped at 100).
- **All-or-nothing channel (BattleBit-style).** The channel must run to completion uninterrupted. It
  **hard-cancels and resets to zero** (must be restarted) the moment the healer or target moves out of
  `BANDAGE_RANGE`, the healer **sprints or fires**, the healer or target **takes damage**, or the
  target stops being a valid patient. No progress is retained across an interruption.
- **One button for everything.** All context actions use **F** (interact) — enter vehicle, revive a
  downed mate, bandage a bleeding mate, and (when no world prompt applies and you are bleeding)
  self-bandage. No dedicated bandage key.
- **"First-aid kit on your chest" economy.** Bandaging spends the **victim's** `bandage_count` first;
  if the victim is empty, the **helper's** charge is spent; if both are empty, the bandage cannot
  complete. Counts: **base 3 / medic 20**.
- **Revive now costs a bandage too.** Reviving a downed teammate spends a bandage under the same
  victim-first→reviver rule and **fails (cannot complete) when both are empty**. This is intentional:
  bots that run dry stop revive-looping in the same spot and finally resolve. (Change to the
  previously-free revive; see §"Coordination".)
- **No downed self-bandage / no teammate halt of a downed bleed.** The halving-bleedout design removed
  downed self-heal (BattleBit has none; downed resolves only by revive or bleed-out). This design does
  **not** reintroduce it. Bandaging applies to *standing* bleeds only; the downed-player parity the
  owner asked for is delivered entirely by revive-costs-a-bandage above.

### Proposed tunables (all gate-adjustable)

| Constant | Value | Meaning |
|---|---|---|
| `BLEED_THRESHOLD` | 60 | post-hit HP below which a qualifying hit starts a bleed |
| `BLEED_RATE_TICKS` | 6 | ticks per 1 HP lost while standing-bleeding (≈5 HP/s @30 Hz) |
| `BANDAGE_TICKS` | 150 | channel duration, non-medic (5 s); medic = 75 (2.5 s) |
| `BANDAGE_HEAL` | 25 | HP restored on a completed bandage (capped at 100) |
| `BANDAGE_RANGE` | 3.0 | max range (m) to bandage a teammate (matches `REVIVE_RANGE`) |
| `BANDAGE_COUNT` | 3 | bandages per spawn, non-medic (unchanged) |
| `MEDIC_BANDAGE_COUNT` | 20 | bandages per spawn, medic (was 5) |

## Mechanic

### New pure units (shared/, deterministic — AGENTS.md §7)

- **`shared/sim/bleed.gd` (`Bleed`)** — standing-bleed rules, no side effects:
  - `const BLEED_THRESHOLD := 60`, `const BLEED_RATE_TICKS := 6`.
  - `should_start(post_hit_hp: int, source: int) -> bool` → `post_hit_hp > 0 and post_hit_hp <
    BLEED_THRESHOLD and (source == Revive.Source.BULLET or source == Revive.Source.BLAST)`.
  - `drain_this_tick(tick: int) -> bool` → `tick % BLEED_RATE_TICKS == 0` (1 HP on those ticks).
- **`shared/sim/bandage.gd` (`Bandage`)** — channel timing + resource rule:
  - `const BANDAGE_TICKS := 150`, `const BANDAGE_HEAL := 25`, `const BANDAGE_RANGE := 3.0`.
  - `channel_ticks(is_medic: bool) -> int` → `BANDAGE_TICKS / 2` if medic else `BANDAGE_TICKS`
    (mirrors `Revive.revive_ticks`).
  - `pick_source(victim_bandages: int, helper_bandages: int) -> int` → returns which pouch pays:
    `0` victim, `1` helper, `-1` none available. Pure; the server decrements the chosen pouch. The
    same helper backs both standing-bandage completion and revive completion.

Medic count: add `const MEDIC_BANDAGE_COUNT := 20` in `revive.gd` (next to `BANDAGE_COUNT := 3`) and
change the medic branch of the existing `Revive.bandage_count_for(is_medic)` to return it (was `3 + 2
= 5`). This keeps the single existing call site — spawn/respawn/resupply — untouched and confines the
change to two lines in the constants area (see §"Coordination"). `MEDIC_EXTRA_BANDAGES` becomes dead
and is removed.

### Pawn state (shared/sim/pawn.gd)

New fields (additive; distinct from the halving-bleedout `bleed_health`/`bleed_floor`/`down_count`):

- `bleeding: bool = false` — standing bleed active.
- `bleed_by: int = 0` — attacker id credited if this bleed downs the pawn (mirrors `downed_by`).
- `bleed_weapon: int = 0` — weapon id of the bleed source, for the eventual down/kill recap.

All three reset on spawn/respawn (`bleeding=false`, `bleed_by=0`, `bleed_weapon=0`). `bandage_count`
is already reset there.

### Trigger (server/server_main.gd `_apply_pawn_damage`)

In the **survive branch** — after `victim.health -= dmg`, before the existing `if victim.health > 0:
return` — add:

```gdscript
if victim.health > 0 and Bleed.should_start(victim.health, source):
    victim.bleeding = true
    victim.bleed_by = killer_id
    victim.bleed_weapon = weapon_id
```

Idempotent: re-hits refresh the credit. This sits *above* the halving-bleedout death-branch edit (a
different location in the same function — see §"Coordination").

### Drain (server/support.gd `step_bleed()`, new — sibling to `step_downed()`)

Each tick, for every **alive, non-downed, `bleeding`** pawn, on `Bleed.drain_this_tick(tick)` lose 1
HP. When the loss would reach `health <= 0`, route the pawn into the existing down/kill decision via a
new self-contained server helper `_bleed_out_standing(id, p)` that mirrors the death branch of
`_apply_pawn_damage` (credit `bleed_by`/`bleed_weapon`; instant-kill when
`Revive.bleedout_window(p.down_count + 1) <= 0`, else `_down_pawn`). Reuses the shared `Revive`
helpers so it never diverges from the halving formula. `_stats.bleed_downs += 1` on a bleed-driven
down. A non-lethal tick just decrements `health` (no per-tick `DAMAGE_EVENT` spam).

### Bandage channel (server/support.gd — latch like revive/give)

- New latch `bandaging := {}` (`healer_id -> target_id`) + progress `bandage_ticks := {}`
  (`target_id -> ticks`), matching the `reviving`/`revive_ticks` pattern.
- New wire message **`BANDAGE_ACTION` (45)** — active-bit + target id (mirror `REVIVE_ACTION`).
  `target == healer_id` ⇒ self-bandage; else a teammate. Handler `handle_bandage_action` sets/clears
  the latch.
- `step_bandage()` per tick, for each latched healer:
  - **All-or-nothing validation (hard-cancel + reset on any failure — unlike revive's hold-through-
    transient latch):** the latch is dropped and `bandage_ticks[target]` erased the instant any of
    these fails — healer alive & not downed; target alive & not downed & `bleeding`; same team; within
    `BANDAGE_RANGE`; healer **not sprinting and not firing** this tick; a bandage available
    (`Bandage.pick_source(...) != -1`). There is no "hold without advancing" state.
  - **Damage interrupt:** the healer *or* target taking damage also hard-cancels — enforced in
    `_apply_pawn_damage` by dropping any `bandaging` latch and `bandage_ticks` keyed on that id (as
    healer or as target).
  - Otherwise advance `bandage_ticks[target] += 1`. On reaching `Bandage.channel_ticks(is_medic(healer))`:
    complete — `Bandage.pick_source` decides the pouch, decrement it, `target.bleeding = false`,
    `target.health = min(100, target.health + Bandage.BANDAGE_HEAL)`, `_stats.bandages += 1`, drop the
    latch. Emit a support link (`SupportLinks` — see §Replication) for the beam/aura.
- `SELF_BANDAGE (16)` stays retired/unused (halving-bleedout removed it); this feature deliberately
  uses the new `BANDAGE_ACTION` channel, not the old one-shot.

### Revive-costs-a-bandage (server/support.gd `step_revives` / `complete_revive`)

- Gate the hold: `step_revives` only advances a target when `Bandage.pick_source(victim, reviver) !=
  -1`. If neither has a bandage, the latch is dropped (revive impossible) and the pawn keeps bleeding
  out — bots run dry and resolve instead of looping.
- On completion (`complete_revive`), decrement the chosen pouch (victim-first→reviver). `complete_revive`
  gains the `reviver_id` argument (currently only takes `target_id`).

## Replication & HUD

- **Owner — `SELF_STATE` (22):** append a `bleeding` bit and a `bandage_progress` u8 (0..255, current
  channel fraction for the owner as target). Drives a **red bleeding vignette** (reuse the suppression
  screen-shader canvas pattern) + a **bandage cast-bar**. Append-only field growth; `decode_self_state`
  already tolerates trailing fields.
- **Teammates — `BLEEDING_LIST` (46):** new ally-only reliable-list (same `ReliableList` pattern as
  `DOWNED_LIST`) of standing-bleeding teammate ids → a distinct **bleeding marker** + "hold interact
  to bandage" prompt; remote **blood-drip VFX** on bleeding pawns.
- **Support beam:** a completing/active bandage emits a `SupportLinks` entry so the existing
  `SUPPORT_LIST` beam/aura renders the bandager→patient link (reuse; no new list needed for the beam).
- **Input — F for everything.** The existing interaction resolver already maps **F** to the
  context-appropriate action (enter vehicle, revive a downed mate). Extend it: looking at a bleeding
  mate in range → prompt "Bandage" → hold F sends `BANDAGE_ACTION(active, mate_id)`; if no world
  prompt applies and the player is themselves `bleeding` → hold F self-bandages (sends
  `BANDAGE_ACTION(active, self_id)`). Priority order matches BattleBit: world target (vehicle / downed
  / bleeding mate) before self-bandage. Releasing F (or any hard-cancel above) drops the latch.

Wire ids reconciled against `docs/specs/wire-protocol-registry.md`; **45 `BANDAGE_ACTION`**, **46
`BLEEDING_LIST`** are the next free ids (halving-bleedout adds none).

## Bots, stats, testing

- **Bots (`bots/ai/behaviors/support.gd`):** extend the M7.5-P3 support behaviour so a bot **self-
  bandages when `bleeding` and safe** (no near enemy) and **bandages a bleeding squadmate** in range.
  This is what exercises the path under the fleet gate. (The halving-bleedout change *removed* the
  downed self-bandage bot branch from the same file — these are different branches; see §Coordination.)
- **Stats (`server/stats.gd`):** `bleeds_started`, `bandages`, `bleed_downs`.
- **Testing (deterministic — AGENTS.md §10):**
  - `tests/bleed_test.gd`: `should_start` threshold + source gating; `drain_this_tick` cadence.
  - `tests/bandage_test.gd`: `channel_ticks` medic-halving; `pick_source` victim-first→helper→none.
  - Server integration: a below-threshold bullet starts a bleed; the bleed drains to a **down** (feeds
    `down_count`); a full channel stops the bleed + heals + spends the right pouch; damage mid-channel
    resets progress; revive fails when both pouches are empty.
  - **128-bot fleet gate:** assert `bleeds_started > 0`, `bandages > 0`, `bleed_downs > 0`, matches
    still reach a winner, tick within the ~17 ms budget. Client feel deferred to owner playtest
    (project deterministic-testing discipline).

## Coordination with the halving-bleedout branch (uncommitted on `master`)

Both branches touch these files; changes are additive and in different concerns, but the merge needs
care. **Do not edit the halving-bleedout owner's lines.**

| File | Halving-bleedout (theirs) | Standing-bleed (this) | Merge |
|---|---|---|---|
| `shared/sim/revive.gd` | `bleed_step/floor/window/frac`, `INITIAL_BLEEDOUT_TICKS` | change medic count → 20 (`MEDIC_BANDAGE_COUNT`) in the constants block + `bandage_count_for` | adjacent constant edits; keep mine to the medic-count line |
| `shared/sim/pawn.gd` | `down_count`, `bleed_floor`, `bleed_halted` inert | add `bleeding`, `bleed_by`, `bleed_weapon` | different field lines |
| `server/support.gd` | `step_downed` floor sig; removed `handle_self_bandage` | add `step_bleed`, `bandaging`+`step_bandage`, `handle_bandage_action`; revive-costs-bandage in `step_revives`/`complete_revive` | new funcs; my revive edit is in funcs they didn't touch |
| `server/server_main.gd` | `_down_pawn`, death-branch `window<=0` kill, respawn reset, dropped `SELF_BANDAGE` route | survive-branch bleed trigger, `step_bleed`/`_bleed_out_standing` calls, `BANDAGE_ACTION` route, respawn reset of bleed fields, `BLEEDING_LIST` broadcast | different branches/lines in shared functions |
| `bots/…/support.gd`, `bots/bot_driver.gd` | removed downed self-bandage branch | add standing self/teammate bandage branch | different branches |
| `client/…` | removed downed bandage prompt/"Stabilized" latch | bleeding vignette, cast-bar, teammate prompt, blood VFX | different UI paths |
| `shared/net/protocol.gd` | `SELF_BANDAGE` reserved-unused | add `BANDAGE_ACTION (45)`, `BLEEDING_LIST (46)`, extend `SELF_STATE` | append-only ids |

**Interaction contract:** a standing bleed-out is a *down* → it calls their `_down_pawn`, increments
their `down_count`, and obeys their `window<=0 → instant kill` rule via the shared `Revive` helpers.
This design consumes only shared, stable `Revive` APIs and never reimplements the halving formula.

## Out of scope

- Reintroducing any downed self-heal / teammate halt of a downed bleed (halving-bleedout owns downed).
- Bleed intensity stacking / multiple simultaneous bleed rates (single latched flag + flat rate).
- Client feel-tuning of the vignette/VFX curves and final keybind (owner-gated at playtest).
- Armor durability / a binary "stopped vs penetrated" armor model (armor stays a flat multiplier;
  "penetrates armor" is realised as the below-threshold trigger).
