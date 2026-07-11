# Spec: Class Select & Player Loadouts (M18)

**Status:** approved (design) · **Date:** 2026-07-11 · **Milestone:** M18 · **Supersedes part of:** M12-P1 class-refit (`shared/sim/loadout.gd` derivation), M5.5-P2 armor (class-derived → player-picked).

Turns the deterministic, class-derived loadout into a **player-chosen, server-validated, session-persistent loadout** with a client class-select screen. Removes the "humans never pick Engineer" restriction and the random class roll for humans. All rules live in `shared/` so client prediction and server authority cannot diverge (AGENTS.md §5, §7). Bot-fleet-gated + deterministically proven (AGENTS.md §10).

## Design decisions (ratified this session — owner-approved)

| Decision | Choice | Rationale |
|---|---|---|
| Who picks | **Humans pick class + loadout on a deploy-screen panel**; bots keep the deterministic derivation | Removes the random roll + Engineer exclusion; one struct feeds both paths. |
| Perks | **Passive class traits only** (no perk menu) | BattleBit-faithful; centralize the traits already scattered across the sim. |
| Weapon roster | **Existing 5 weapons + new LMG**; pick primary among class-allowed archetypes | No large content/balance effort; keeps the minimal-sandbox philosophy. |
| Attachments | **Player-picked per primary** (optic/barrel/underbarrel) | The `Attachment` catalog + `effective_def` already exist. |
| Armor | **Player-picked slot** (Light/Medium/Heavy), all classes | Was class-derived (M5.5-P2); becomes a real trade-off: damage-reduction vs move speed. |
| Grenade | **Player-picked slot** (Frag/Smoke/Flash), all classes | All three already exist (`Grenade.FRAG/SMOKE/FLASHBANG`); replaces the runtime frag↔smoke cycle. |
| Gadget | **Three per class, always one selected** | Symmetric slot count survives adding the Engineer Repair Tool; gives each class a real pick. Built across phases. |
| Gadget design tenet | **Active use or visible counterplay — no hidden passive kills** | Rules out claymore-style play; shapes every gadget (§ matrix). |
| RPG | **Engineer gadget** (not a weapon-primary) | Frees Engineer to carry a real click-fire gun; RPG is a deliberate launcher choice. |
| Claymore | **Removed entirely** | Fire-and-forget lethality with poor counterplay; violates the design tenet. No AP mine ships. |
| Repair Tool | **Engineer gadget** (structures/FOB now, vehicles later) | The gadget that motivated 3-per-class; forward-compatible with the deferred vehicle track. |
| LMG Nest | **Support gadget — manned emplacement** (own phase) | Static, visible, arc-limited firing platform; infantry fortification content, not a vehicle. |
| Persistence | **Per-connection, survives death** | Matches BattleBit; server stores `_clients[id]["loadout"]`, re-applies each respawn. |
| Loadout change timing | **Applies on next spawn only** (never mid-life) | BattleBit rule; store-and-apply avoids reject-while-alive edge cases. |

---

## Final class & loadout matrix

### Universal slots (every class picks)
| Slot | Options | Effect |
|---|---|---|
| **Armor** | Light / Medium / Heavy | Damage-reduction 1.0 / 0.85 / 0.7 (body_mult, unchanged). **Move speed 1.2 / 1.0 / 0.8** (widened from M5.5's 1.0/0.95/0.9 per owner). Helmet headshot-save stays Heavy-only. |
| **Grenade** | Frag / Smoke / Flash | The single throwable type carried. Count = **3** (Support **5**). |
| **Secondary** | Pistol | Universal sidearm (v1). |
| **Attachments** | per-primary optic/barrel/underbarrel | Via existing `Attachment` catalog; `effective_def` applies multipliers at loadout time. |

### Per-class
Three gadgets per class (pick one). See §D for the full gadget roster + build phasing.
| Class | Primary options | Gadgets (pick one) | Passive identity |
|---|---|---|---|
| **Assault** | AR · SMG · DMR | **C4 · Grappling Hook · Breaching Charge** | DMR access · **Combat Vigor** (faster health regen) |
| **Medic** | AR · SMG | **Medkit · Combat Stim** (3 charges, refillable) **· Smoke Wall** | faster revive · 20 bandages |
| **Engineer** | AR · SMG | **RPG · C4 · Repair Tool** | sledgehammer · **+20% explosive blast radius** |
| **Support** | AR · SMG · **LMG** | **Ammo Bag · Riot Shield · LMG Nest** | +reserve ammo · LMG suppression · **5 grenades** |

**Weapon locks** (`can_equip`): `DMR ⇒ Assault`, `LMG ⇒ Support`. All other primaries (AR/SMG) unrestricted. RPG is no longer a primary (it is a gadget), so its old `RPG ⇒ Engineer` weapon-lock is retired.

**Gadget design tenet (ratified):** *every gadget requires active use or gives clear, visible counterplay — no hidden passive kills.* This is why the **Claymore/AP-mine is removed entirely** (fire-and-forget lethality with poor counterplay, routinely tucked into walls/stairs); the sim code stays in the tree but is unreachable via loadout. The tenet also shapes the new gadgets: the LMG Nest is static/visible with a limited arc, Breaching Charge is an active placement, Deployable Cover is visible + destructible, etc. Deliberately **no AP proximity mine ships**.

---

## A. Data model — `LoadoutConfig` (`shared/sim/loadout.gd`)

One plain `Dictionary`, the single loadout representation for humans **and** bots:

```
LoadoutConfig := {
    "class":     int,     # Loadout.ASSAULT..SUPPORT
    "primary":   int,     # Weapon id (class-gated)
    "secondary": int,     # Weapon.PISTOL (v1)
    "gadget":    int,     # a Loadout.GADGET_* value from the class's option set
    "armor":     int,     # Armor.LIGHT..HEAVY
    "grenade":   int,     # Grenade.FRAG/SMOKE/FLASHBANG
    "attachments": { "optic": String, "barrel": String, "underbarrel": String },
}
```

### `Loadout.sanitize(cfg, attach_catalog) -> LoadoutConfig`
The single authority (called by **both** client and server):
- clamp `class` to `[0,3]`; unknown → `ASSAULT`.
- `primary`: if `not primary_allowed(class, primary)` → `default_primary(class)`. (`primary_allowed` folds `can_equip` + the per-class option lists below.)
- `secondary` → `Weapon.PISTOL` (v1 fixed).
- `gadget`: if `gadget not in gadget_options(class)` → `gadget_options(class)[0]`.
- `armor`: clamp to `[0,2]`; unknown → `MEDIUM`.
- `grenade`: if not in `{FRAG,SMOKE,FLASHBANG}` → `FRAG`.
- `attachments`: per slot, drop any id the catalog doesn't know **or** whose `slot` doesn't match, and drop optics/barrels illegal for the weapon (v1: catalog membership only) → fall back to `Loadout.default_attachments()` per missing slot.

Sanitize is **idempotent** and **total** (never returns an invalid config), so a malicious/older client can never inject an illegal loadout — the server always re-sanitizes.

### Option tables (`shared/sim/loadout.gd`)
- `primary_options(cls) -> Array[int]`: Assault `[AR,SMG,DMR]`, Medic `[AR,SMG]`, Engineer `[AR,SMG]`, Support `[AR,SMG,LMG]`.
- `gadget_options(cls) -> Array[int]` (the **target** 3-per-class roster): Assault `[GADGET_C4, GADGET_GRAPPLE, GADGET_BREACH]`, Medic `[GADGET_MEDKIT, GADGET_STIM, GADGET_SMOKE_WALL]`, Engineer `[GADGET_RPG, GADGET_C4, GADGET_REPAIR]`, Support `[GADGET_AMMO, GADGET_RIOT_SHIELD, GADGET_LMG_NEST]`.
- **Phased availability:** `Loadout.IMPLEMENTED_GADGETS` is the set of gadgets actually built so far; it **grows per phase** (§D/§L). `sanitize` treats an option that is not yet in `IMPLEMENTED_GADGETS` as invalid → falls back to the class default, and the client screen hides/greys unbuilt options. So `gadget_options` can name the full vision while only the built gadgets are selectable. Each class's `gadget_options[0]` is an already-built gadget (C4 / Medkit / RPG / Ammo), so every class has a working default from P1.
- `default_primary(cls)`, `default_gadget(cls)` = first of each list. `default_armor(cls)` = `MEDIUM`. `default_loadout(cls)` assembles a full valid config (used for the initial per-connection loadout and the bot path).
- New gadget id constants: `GADGET_RPG`, `GADGET_MEDKIT` (rename of HEAL), `GADGET_STIM`, `GADGET_SMOKE_WALL`, `GADGET_BREACH`, `GADGET_REPAIR`, `GADGET_GRAPPLE`, `GADGET_RIOT_SHIELD`, `GADGET_LMG_NEST`, `GADGET_SANDBAG` (interim cover, §D) alongside existing `GADGET_C4`, `GADGET_AMMO`. `GADGET_MINE` (claymore) is **removed** from all option sets (sim retained but unreachable — the design tenet, above).

### Bot path (unchanged behavior)
`Loadout.bot_loadout(id) -> LoadoutConfig` reproduces today's deterministic derivation (`random_class`, engineer/assault variant rolls) but emits a `LoadoutConfig`. Bots that used the **RPG primary** now take the **RPG gadget** + a normal SMG/AR primary. One spawn code path for both humans and bots.

## B. Class traits — centralize the "perks" (`shared/sim/loadout.gd`)

`Loadout.class_traits(cls) -> Dictionary` is the single source the server reads **and** the class-select screen displays (what you see = what you get). Folds in the currently-scattered logic and the new perks:

| Trait key | Assault | Medic | Engineer | Support | Read by |
|---|---|---|---|---|---|
| `revive_fast` | – | ✓ | – | – | `Revive.revive_ticks` |
| `bandages` | (base) | 20 | (base) | (base) | `Revive.bandage_count_for` |
| `sledgehammer` | – | – | ✓ | – | `Loadout.has_sledgehammer` |
| `blast_mult` | 1.0 | 1.0 | **1.2** | 1.0 | explosion resolution (C4/RPG/frag) |
| `regen_scale` | **fast** | 1.0 | 1.0 | 1.0 | pawn health-regen (Combat Vigor) |
| `grenade_count` | 3 | 3 | 3 | **5** | spawn grenade inventory |
| `reserve_bonus` | 1.0 | 1.0 | 1.0 | **>1.0** | `Weapon.reserve_ammo` at spawn |

Existing helpers (`armor_for`, `has_sledgehammer`, `bandage_count_for`) are refactored to read this table (or are superseded where the value is now player-picked, e.g. `armor_for` is deleted — armor comes from `LoadoutConfig.armor`).

### New trait wiring
- **Combat Vigor (Assault):** shorten the pawn regen delay + raise regen rate when `regen_scale == fast`. Applied in the existing regen step (`_regen_cooldown` path on `pawn.gd`), gated on the owner's class.
- **+20% explosive blast (Engineer):** multiply blast radius by `blast_mult` at explosion resolution for explosives owned by an Engineer (C4, RPG, frag). Damage falloff uses the scaled radius.
- **Combat Stim (Medic gadget):** a finite-charge gadget. On use (short-range inject of self/teammate), grant a timed buff: `+move speed`, `suppression immunity`, `faster stamina regen`, brief `damage resist`. Charges start at `STIM_CHARGES` (3), decrement per use, and **refill from Ammo Bags / resupply** exactly like a reserve-ammo top-up. Buff state rides the existing pawn status plumbing (mirrors suppression/blind timed bytes).
- **Support grenades = 5 / reserve bonus:** applied at spawn from `grenade_count` / `reserve_bonus`.

## C. LMG weapon (`shared/sim/weapon.gd`, `data/attachments.json` unaffected)

New `Weapon.LMG` enum entry + `_DEFS` row. BattleBit LMG feel, conservative placeholders (gate-tuned):
- large `mag_size` (~100), high `reserve_ammo`, AR-ish `damage_body`, higher `spread_base`/`spread_bloom` and `recoil_pitch` (harder to control), `rpm` ~700, `fire_modes: [AUTO]`.
- **Higher suppression:** the LMG applies more suppression per shot than other primaries. Suppression is already a per-shot effect in combat; add a per-weapon `suppression_mult` (default 1.0; LMG >1.0) read at suppression application. Bipod attachment (`bipod`, already in the catalog) pairs naturally (prone spread-zero).
- `can_equip(SUPPORT, LMG) == true`; every other class false.

## D. Gadget roster (`shared/sim/` gadget system, `server/server_main.gd`)

Twelve gadget *ids* across four classes (3 each), built across phases. Grouped by build cost:

**Already built (P1-usable):** `C4`, `RPG` (→gadget, below), `MEDKIT` (=existing HEAL), `AMMO`.

**Cheap new — reuse an existing system (P2):**
- `STIM` — Combat Stim (Medic). Finite refillable charges; timed buff. Reuses status plumbing. See §B.
- `SMOKE_WALL` — Medic. A larger, longer-lasting deployable smoke emitter for covering revives/pushes. Reuses the smoke-zone system (`SmokeCloud`), bigger radius + longer expire; placed, not thrown.
- `BREACH` — Breaching Charge (Assault). An **active** placed charge that blows a *walkable hole* in a wall/floor. Reuses the M11/M13 destruction + hole-aware geometry — it is a targeted structure-carve, distinct from C4's remote pocket charge.
- `REPAIR` — Repair Tool (Engineer). Repairs **structures/FOB now** (ranged/faster than the universal shovel) and **vehicles once they exist** (M5+). A held-use tool like the shovel; solo-allowed. This is the gadget that motivated the move to 3-per-class.
- `SANDBAG` — Deployable Cover. **Interim only**: a visible, destructible cover piece (reuses the M4/M12 build/structure system) that stands in for a class's not-yet-built gadget so every class has a working second/third option before the heavy gadgets land.

**Heavy new — need genuinely new mechanics (own phase / follow-up milestone):**
- `GRAPPLE` — Grappling Hook (Assault): vertical/flank mobility. New movement mechanic.
- `RIOT_SHIELD` — Support: carried bulletproof cover. New carried-collision mechanic.
- `LMG_NEST` — Support: manned emplacement (its own subsection below).

Until a gadget is in `IMPLEMENTED_GADGETS` it is unselectable (sanitize + client hide it) and its class falls back to the built default (§A).

### RPG as a gadget
RPG moves from **weapon-primary slot** to the **gadget system**:
- `GADGET_RPG` is an Engineer gadget option. When selected, the launcher is equippable via the gadget/weapon-wheel path, firing rockets with the existing rocket pool + cooldown (`rockets`, `last_rocket_tick`, `KIND_RPG` ammo).
- The primary weapon slot for an RPG-Engineer is now a real gun (AR/SMG) — the "broken weapon" human-exclusion (`random_class_no_engineer`) is **deleted**; humans pick Engineer freely.
- Server spawn: rocket pool is seeded when `gadget == GADGET_RPG` (not when `weapon == RPG`). The `Weapon.RPG` enum entry stays for the projectile/def, but it is never a `primary` in a sanitized loadout.

> **Implementation note:** RPG-as-gadget is the one genuine sim rework in the P1 framework. Keep the rocket firing/projectile path identical; only the *ownership/slot* changes (gadget selection seeds the launcher instead of the primary weapon id). Covered by the P1 gate + unit tests.

### LMG Nest (`GADGET_LMG_NEST`, Support) — its own phase / candidate follow-up milestone
A **manned static emplacement** — a built structure the occupant enters to fire their own primary from behind hard cover. Framed as **infantry fortification/destruction content, not a vehicle** (it fits the AGENTS.md §12 infantry+maps+destruction priority; it is not the deferred vehicle track), but it reuses a slice of the parked mounted-gun/turret plumbing, rebuilt at infantry scope.

- **Placement:** deployed like a build piece (snap-to-ground, bounds/occupancy validated); becomes a completed structure with collision + cover + HP (reuses M4/M12 construction + M4 destruction).
- **Manning:** a Support-owned (v1: any friendly) player **enters a seat** (enter/exit like a vehicle seat) and fires their **own equipped primary** (LMG *or* AR) — **no new weapon**. While seated:
  - **Bipod bonus:** heavy recoil + spread reduction (reuse `prone_spread_zero` + a recoil multiplier) → extreme accuracy.
  - **Aim clamp:** yaw limited to a **~90° forward arc** + limited pitch; the occupant cannot spin to cover flanks.
  - **Frontal cover:** the occupant takes small-arms damage only through the firing slit — heavily protected from the front, fully exposed to flanks/rear.
- **Damage-type profile (structure):** small-arms (AR/SMG/LMG/pistol bullets) **heavily resisted**; **explosives (RPG/C4/frag) and DMR do full or bonus** damage. This is the counterplay: flank the arc, DMR the exposed gunner's head, or blow the nest. Destroyed via the normal M4 path; occupant is ejected/killed on destruction.
- **Replication/wire:** it is a structure (rides the existing structure delta) plus a seat-occupancy bit. Firing-from-seat uses the normal input/fire path with the bipod/clamp applied server-side. Details finalized when this phase is planned.
- **Why deferred:** biggest single gadget (structure + seat + arc-clamp + modified fire + damage profile + client model/enter-exit UI). Support ships earlier phases with `AMMO` + interim `SANDBAG`; the Nest replaces the interim when built.

## E. Wire protocol (`shared/net/protocol.gd`, **VERSION 7 → 8**)

- New `Msg.SET_LOADOUT = 48` (client→server, CHANNEL_CONTROL, reliable): encodes a `LoadoutConfig` (class/primary/secondary/gadget/armor/grenade bytes + 3 attachment string ids, bounded per the wire-string rules). Server **re-sanitizes**, stores in `_clients[id]["loadout"]`, applies on **next spawn**. Always accepted (store-and-apply); no reject path.
- `WELCOME` carries the initial default **class** for HUD bootstrap (unchanged). The client seeds its class-select screen locally from `Loadout.default_loadout(class)`; the server is the source of truth for the stored loadout (it re-sanitizes every `SET_LOADOUT`), so no loadout echo-back is needed. This keeps `WELCOME` unchanged and puts all loadout state on the one `SET_LOADOUT` path.
- No per-tick SNAPSHOT field changes. `SELF_STATE` already carries weapon/ammo/reserve/throwables — extend `_throwables_for` to reflect the single chosen grenade type + count, and add the **stim charge count** as one byte on `SELF_STATE` so the HUD can show it.
- Bump `VERSION` to 8 (wire change). Update the wire-registry / next-msg-id note (next free id after 48 = 49).

## F. Server integration (`server/server_main.gd`)

- **HELLO:** stop rolling a random class + weapon. Assign `_clients[id]["loadout"] = Loadout.default_loadout(default_class)` for humans (a sensible starting class, e.g. Assault) or `Loadout.bot_loadout(id)` for bots. Remove the `random_class_no_engineer`, `id % 3` RPG/DMR bot pokes, and `_human_rpg` special-case (fold `--human-rpg` into a debug loadout override that sets the RPG gadget).
- **Spawn (`_spawn`/deploy path):** build the pawn's weapon/ammo/reserve/armor/gadget/grenade/bandages **from `_clients[id]["loadout"]`** via the sanitize'd config, applying `class_traits` (regen scale, grenade count, reserve bonus, blast mult owner-tag). `p.armor_class = loadout.armor` (no longer `armor_for(cls)`).
- **`SET_LOADOUT` handler:** decode → `Loadout.sanitize` → store. No immediate pawn mutation (applies next spawn).
- Gadget dispatch (`gadget_for_player`, C4/mine handlers, support gadget kind) reads the **stored loadout gadget** instead of the id-parity derivation.

## G. Client class-select screen (`client/menus/`, integrates with `deploy_menu.gd`)

- New `ClassSelectPanel` (own file) shown as part of the deploy flow — resolves the `deploy_menu.gd` TODO ("move to a class-select screen when that exists").
- Layout: **class column** (4 classes, each showing its passive-trait blurb from `class_traits`), **primary picker** (class-allowed archetypes), **attachment pickers** (3 slots), **armor picker** (L/M/H with the speed/dmg trade-off shown), **grenade picker** (Frag/Smoke/Flash), **gadget picker** (2 options). Pre-filled from the persisted loadout.
- On any change → `client_main` builds a `LoadoutConfig`, runs `Loadout.sanitize` locally (grey-out illegal combos), sends `Msg.SET_LOADOUT`. Spawn buttons unchanged; deploying uses the last-sent loadout.
- Real-GPU screenshot QA on `.116` / `.194` (llvmpipe unreliable for UI colour — memory).

## H. Bot AI (`bots/bot_driver.gd`, `bots/exercisers.gd`)

- Bots build a `LoadoutConfig` via `Loadout.bot_loadout(id)`; RPG-wanting bots take the **RPG gadget**; Support bots roll the **LMG** sometimes (exercise the new weapon + suppression). Armor is rolled across L/M/H so the fleet exercises all three speed/dmg tiers.
- No behavior regression expected (same combat/gadget behaviors, new ownership plumbing). Deterministic exerciser: a scripted drill that spawns one of each class with each armor tier and fires/uses each gadget, so the gate exercises the full matrix every match.

## I. Constants (initial; gate-tuned)

| Const | Value | Meaning |
|---|---|---|
| `Armor._SPEED_MULT` | `{L:1.2, M:1.0, H:0.8}` | widened move-speed multiplier by armor tier |
| `STIM_CHARGES` | 3 | medic Combat Stim starting charges (refillable) |
| `STIM_BUFF_TICKS` | tune (~5 s) | Combat Stim buff duration |
| `STIM_SPEED_MULT` | tune (~1.15) | move-speed bonus while stimmed |
| `ASSAULT_REGEN_DELAY_SCALE` | tune (<1.0) | Combat Vigor: shorter regen delay |
| `ASSAULT_REGEN_RATE_SCALE` | tune (>1.0) | Combat Vigor: faster regen rate |
| `ENGINEER_BLAST_MULT` | 1.2 | +20% explosive blast radius |
| `SUPPORT_GRENADES` | 5 | Support grenade count (others 3) |
| `SUPPORT_RESERVE_MULT` | tune (~1.25) | Support reserve-ammo bonus |
| `LMG_MAG` / `LMG_SUPPRESSION_MULT` | ~100 / >1.0 | LMG mag size / suppression multiplier |
| `SMOKE_WALL_RADIUS` / `_EXPIRE` | tune (> grenade smoke) | deployable smoke-wall size / lifetime |
| `NEST_ARC_DEG` | ~90 | LMG Nest forward yaw-clamp arc |
| `NEST_SMALL_ARMS_MULT` | tune (≪1.0) | small-arms damage the nest structure absorbs |
| `NEST_EXPLOSIVE_MULT` / `NEST_DMR_MULT` | tune (≥1.0) | explosive / DMR damage vs the nest (counterplay) |
| `NEST_BIPOD_RECOIL_MULT` | tune (≪1.0) | recoil reduction while manning the nest |

## J. Testing (`tests/`)

**Unit (`TestCase`):**
- `loadout_sanitize`: sanitize is total + idempotent; rejects DMR for non-Assault, LMG for non-Support; snaps an out-of-set gadget to the class default; clamps armor/class/grenade; drops unknown/mismatched attachment ids; RPG never appears as a `primary`.
- `loadout_options`: `primary_options`/`gadget_options` per class match the matrix (3 gadgets each); each class's `gadget_options[0]` is in `IMPLEMENTED_GADGETS`; an unbuilt gadget id is rejected by sanitize → class default; `default_loadout` is self-consistent (passes sanitize unchanged).
- `class_traits`: blast_mult=1.2 Engineer only; grenade_count=5 Support only; regen fast Assault only; reserve bonus Support only.
- `armor`: speed_mult 1.2/1.0/0.8; body_mult unchanged; heavy-only headshot save unchanged.
- `weapon_lmg`: LMG def present; big mag; suppression_mult>1; AUTO-only; `can_equip` Support-only.
- `rpg_gadget`: an Engineer with `GADGET_RPG` seeds the rocket pool + can fire rockets; an Engineer without it has no rockets; RPG is never a sanitized primary.
- `stim`: charges start at 3, decrement per use, refill at an ammo bag; buff grants the timed status and expires.
- `protocol`: `SET_LOADOUT` round-trips a full config; server re-sanitize equals client sanitize (determinism); VERSION==8.
- `persistence`: a stored loadout survives a simulated death/respawn and re-applies; a mid-life `SET_LOADOUT` does not mutate the live pawn.

Per-gadget unit tests as each lands: `breach` (opens a walkable hole via the destruction path), `repair` (restores structure/FOB HP, solo-allowed), `smoke_wall` (larger/longer smoke zone), `lmg_nest` (enter/exit seat; ~90° yaw clamp rejects out-of-arc aim; bipod recoil reduction; small-arms resisted while explosive/DMR do full/bonus; occupant ejected on destruction).

**Integration / gate (per phase):**
- **P1:** 128-bot match on `conquest_town` exercising every class × every armor tier × each *built* gadget (incl. RPG gadget + LMG), tick mean **< 33.3 ms** at 30 Hz, bandwidth unchanged (no per-tick additions), Conquest reaches a winner. Fleet gate on game2.
- **P2:** trait correctness in-sim (blast radius, regen, stim buff, grenade counts) + the cheap new gadgets (Breach, Repair, Smoke Wall) via the deterministic drill.
- **P3:** client class-select screen — screenshot QA + owner playtest (visual FEEL deferred to owner, project norm).
- **P4 (LMG Nest):** a scripted drill builds a nest, a bot mans it and fires within the arc, an enemy destroys it with explosives/DMR — arc clamp, bipod accuracy, damage profile, and enter/exit all proven under the tick budget. Grapple/Riot-Shield gated similarly if/when built.

## K. Budgets

- **Server tick:** no new per-tick stream. Spawn-time loadout application is O(1). Combat Stim buff decay folds into the existing status-tick (like suppression/blind). Blast-mult is a single multiply at explosion resolution. Expect no `snap`/tick regression — profile P1 to confirm.
- **Bandwidth:** `SET_LOADOUT` is a rare reliable control message (a handful of bytes on change). `SELF_STATE` gains the stim-charge byte + reflects the single grenade type — negligible. No SNAPSHOT change.

## L. Phasing

- **P1 — Sim + wire framework.** `LoadoutConfig` + `sanitize` + option/trait tables; `IMPLEMENTED_GADGETS` gating; LMG weapon; RPG-as-gadget; armor/grenade/gadget as player-picked; `SET_LOADOUT` (VERSION 8); per-connection persistence; server applies on spawn; bots on the unified path (with the interim `SANDBAG` filling any not-yet-built slot). Deterministic tests + 128-bot fleet gate. **No client screen yet** (auto/`--loadout=` debug arg drives it headless).
- **P2 — Class traits + cheap new gadgets.** Combat Vigor, +20% blast, Combat Stim (refillable), Support grenades/reserve, LMG suppression, plus `BREACH` / `REPAIR` / `SMOKE_WALL` (each `IMPLEMENTED_GADGETS`-added as it lands) — wired to `class_traits` and gate-proven via the drill.
- **P3 — Client class-select screen.** The UI (class column + primary/attachment/armor/grenade/gadget pickers + trait blurbs) + screenshot QA + owner playtest.
- **P4 — LMG Nest.** The manned emplacement (§D) — its own phase, and a candidate standalone follow-up milestone given its size.
- **Later (own phases):** `GRAPPLE` (Assault) and `RIOT_SHIELD` (Support) — new movement / carried-collision mechanics; the interim `SANDBAG` covers those slots until then.

*(P1 and P2 may merge if the trait wiring is small; the gate boundary is what matters. P4/later gadgets are independent and can be resequenced.)*

## M. Out of scope (explicit)

- **Grappling Hook (Assault), Riot Shield (Support), LMG Nest (Support)** — the heavy gadgets needing new mechanics; each is its own phase (§D/§L), not part of the P1–P3 framework. The interim `SANDBAG` cover fills those slots until they land.
- **Vehicle repair by the Repair Tool** — the tool ships repairing structures/FOB; vehicle repair activates only once vehicles exist (deferred track).
- **Expanded weapon roster** (multiple named ARs/SMGs) — the archetype set stays 5 + LMG.
- **Secondary-weapon choice** — Pistol is the only sidearm in v1.
- **Cross-session / account persistence** — loadout persists per *connection* only.
- **Binoculars / spotting system** — not built; the medic's team utility is the Combat Stim + Smoke Wall.
- **Claymore / AP proximity mine** — removed entirely per the gadget design tenet (sim code retained but unreachable via loadout); no AP mine ships.
- **Armor cosmetic differences / helmet models** — visual only, deferred to art.
