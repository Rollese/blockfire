# Weapon variants — named roster over the category sim — design

- **Date:** 2026-07-11
- **Status:** **IMPLEMENTED & SHIPPED** (2026-07-11, `origin/master`) — all 17 variants (AR×3, SMG×3,
  DMR×3, Pistol×4, LMG×4; ids 16–32) + registry + boot/art/HUD wiring. Integrated cleanly with the
  M19 loadout track (their LMG archetype merged first; my LMG variants sit on it). Full suite green
  (only pre-existing native-lib failures). See plan `docs/superpowers/plans/2026-07-11-weapon-variants.md`.
- **Depends on / coordinates with:** the parallel **Class Select & Player Loadouts (M18)** spec
  (`~/class-select-loadout.md`, being planned concurrently). That spec owns the class/loadout system,
  the new **LMG archetype**, and turns `LoadoutConfig.primary` into a player-picked weapon id. This
  spec owns the **named-variant content + registry** that `primary` selects from. The shared seam is
  §4.
- **Supersedes:** the single-stat-block-per-category assumption in `shared/sim/weapon.gd` (`_DEFS`).
- **Related:** [ADR-0007](../../adr/0007-battlebit-divergences.md) (§1 — no bolt-action sniper; DMR
  is a marksman option), the art-pipeline track (per-gun viewmodels deferred there).

## 1. Goal and scope

Blockfire ships one generic stat block per weapon category (`AR/SMG/DMR/RPG/PISTOL`, plus the
incoming `LMG`). This turns each category into a set of **named, mechanically-distinct variants** —
at least three per category — so weapons occupy real roles on an axis instead of being reskins.

**Ratified decisions (this brainstorming session, owner-approved):**

| Decision | Choice | Rationale |
|---|---|---|
| Variant depth | **Distinct stat blocks** per gun | The point is that AK vs M4 vs FAL *play* differently; cosmetic-only was rejected. |
| Attachment compat | **Category-level** (unchanged) | Reuse the existing `Attachment` catalog + `effective_def`; per-gun attachment trees are a later pass. |
| Category scope (this pass) | Small-arms only: **AR, SMG, DMR, Pistol, LMG** | Launchers left the weapon slot (RPG is now an Engineer *gadget* in the loadout spec); shotguns skipped; NLAW/AA deferred (need guidance tech / M10 aircraft). |
| Variant representation | **Variant *is* the primary weapon id**; archetype derived via `Weapon.archetype_of(id)` | Reuses the loadout spec's existing `primary:int` field with zero new wire bytes; `weapon_id` is a `u8` everywhere (256-id headroom). Most BattleBit-faithful (you pick a gun, not a category). |
| Registry storage | **`data/weapons.json` catalog** (Approach A) | Matches the project's data-driven catalog convention (`attachments.json`/`gadgets.json`/`vehicles.json`); owner-tunable without code; **isolates my edits** from the loadout agent's `weapon.gd` archetype edits. |
| Stat model | **Full explicit stat block per variant** (no deltas) | Balance reads at a glance; no hidden inheritance surprises. |
| Names | **Lightly fictionalized** (COD-style), recognizable to FPS fans | Sidesteps the more litigious manufacturers' trademarks while staying instantly readable; the `name` field is display-only, decoupled from id/stats, so any name is a one-line change. |
| Real-spec anchoring | Stats **loosely follow real counterparts** | e.g. FAL = slower-firing / harder-hitting than the M4; the Uzi models the *Micro* Uzi (fast), the Skorpion the low-power .32 vz.61. |
| LMG variants | **Coordinated with the loadout agent** (they own the archetype) | The LMG archetype base + `suppression_mult` field are theirs (§C of their spec); my four LMG variants sit on top and merge after their archetype lands. |

**Out of scope (explicit):**

- **Shotguns** — a new category with a new multi-pellet/spread mechanic; owner chose to skip this pass.
- **Machine pistol / revolver** extra sidearms — owner chose to keep four pistols.
- **Launcher variants** (RPG-7/LAW/NLAW) — the launcher left the weapon-primary slot in the loadout
  spec (RPG became an Engineer gadget). AA missiles (Igla/Stinger) wait for **M10** aircraft.
- **Per-gun viewmodels / models / audio** — variants share their archetype's viewmodel in v1;
  distinct art is deferred to the art-pipeline track. This is a **stats/gameplay** pass.
- **Per-gun attachment compatibility, unlocks/progression** — later; attachments stay category-level.
- **Class access / loadout gating** — owned entirely by the loadout spec (see §4).

## 2. The roster (17 guns)

Each category spans a deliberate role axis. **Scrambled name** first; real counterpart in
parentheses. All numbers are **gate-tunable placeholders** — the *shape* (relative roles) is the
design; absolute values are tuned in the balance/gate pass. `modes`: A=AUTO, S=SEMI, B=BURST.

> **Display order ≠ catalog order.** The tables below are sorted by *role axis* for readability. In
> `data/weapons.json` each category's **default is listed first** (and takes the lowest id in its
> block), so `Weapon.variants_of(archetype)[0] == default_variant(archetype)` holds (§3). Defaults:
> **M4A2 · MP-5X · SVD-K · M9 · PKP**.

### AR — *control ↔ hitting power* — default **M4A2**
| Gun | dmg | hs× | rpm | mag | reserve | reload | recoil | spread | range | muzzle | modes | role |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--|---|
| **M4A2** (M4) | 24 | 2.0 | 700 | 30 | 180 | 2.2 | 0.35 | 0.55 | 300 | 880 | A/S/B | balanced all-rounder (default) |
| **AKM-74** (AK-47) | 30 | 2.0 | 580 | 30 | 180 | 2.4 | 0.55 | 0.65 | 280 | 715 | A/S | hard-hitting 7.62, high kick |
| **FL-40** (FAL) | 40 | 2.0 | 500 | 20 | 160 | 2.5 | 0.70 | 0.50 | 340 | 840 | S/A | battle-rifle; big hit, small mag |

### SMG — *fire-rate ↔ punch/range* (real-spec-anchored) — default **MP-5X**
| Gun | dmg | hs× | rpm | mag | reserve | reload | recoil | spread | range | muzzle | modes | role |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--|---|
| **UZ-9** (Micro Uzi) | 21 | 1.8 | 1050 | 25 | 200 | 2.0 | 0.42 | 1.05 | 120 | 400 | A/S | fastest; close-range hose, punishing recoil |
| **Skorpion-61** (vz.61) | 14 | 1.8 | 860 | 20 | 200 | 1.9 | 0.20 | 0.90 | 100 | 320 | A | .32 PDW: low dmg, very low recoil, tiny/mobile |
| **MP-5X** (MP5) | 20 | 1.8 | 800 | 30 | 210 | 2.0 | 0.28 | 0.80 | 165 | 400 | A/S/B | balanced, accurate, best range (default) |

### DMR — *fast ↔ heavy* — default **SVD-K**
| Gun | dmg | hs× | rpm | mag | reserve | reload | recoil | spread | range | muzzle | modes | role |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--|---|
| **SK-45** (SKS) | 42 | 2.0 | 330 | 10 | 100 | 2.4 | 0.60 | 0.22 | 420 | 735 | S | aggressive fast-poke |
| **SVD-K** (SVD) | 48 | 2.0 | 240 | 10 | 100 | 2.6 | 0.85 | 0.20 | 480 | 830 | S | iconic balanced marksman (default) |
| **M14-EBR** (Mk14 EBR) | 55 | 2.0 | 220 | 20 | 140 | 2.6 | 1.00 | 0.25 | 500 | 850 | S | heavy 2-shot bruiser |

### Pistol — *spam ↔ hand-cannon* — default **M9**
| Gun | dmg | hs× | rpm | mag | reserve | reload | recoil | spread | range | muzzle | modes | role |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--|---|
| **GK-18** (Glock 17) | 15 | 1.9 | 480 | 17 | 68 | 1.6 | 0.40 | 0.85 | 70 | 375 | S | high-cap, spammy |
| **M9** (Beretta 92) | 17 | 1.9 | 450 | 15 | 60 | 1.6 | 0.45 | 0.80 | 75 | 380 | S | balanced (default) |
| **P-229** (SIG P226) | 18 | 1.9 | 430 | 15 | 60 | 1.7 | 0.40 | 0.60 | 85 | 390 | S | accurate marksman sidearm |
| **D-50 "Hawk"** (Desert Eagle) | 40 | 1.9 | 250 | 7 | 42 | 2.0 | 0.90 | 0.70 | 90 | 470 | S | hand-cannon; slow, punishing |

### LMG — *heavy ↔ mobile* — default **PKP** — *archetype owned by the loadout agent; §4*
| Gun | dmg | hs× | rpm | mag | reserve | reload | recoil | spread | range | suppr× | modes | role |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--|---|
| **PKP** (PKM) | 30 | 1.9 | 700 | 100 | 400 | 5.5 | 0.65 | 0.85 | 300 | 1.40 | A | balanced (default) |
| **M250** (M240) | 32 | 1.9 | 650 | 100 | 400 | 6.0 | 0.70 | 0.90 | 320 | 1.50 | A | the wall: hardest hit + suppression |
| **L7A3** (L7A2) | 30 | 1.9 | 750 | 100 | 400 | 5.5 | 0.60 | 0.80 | 300 | 1.35 | A | higher rate, British GPMG |
| **M245 SAW** (M249) | 24 | 1.9 | 800 | 100 | 400 | 5.0 | 0.50 | 0.75 | 260 | 1.25 | A | 5.56 light/mobile |

> **Real-spec cross-check (design principle, not a hard rule):** AR — FAL slower-firing/harder-hitting
> than the M4, AK ~580 rpm (real ≈600); SMG — Micro Uzi fastest (real ≈1050–1200), .32 Skorpion
> lowest damage, MP5 ≈800; DMR — SKS the fast low-power poke, Mk14 the heavy hitter; LMG — M249 the
> light 5.56, M240 the heavy 7.62.

## 3. Architecture

### 3.1 Data — `data/weapons.json`
A catalog array, one object per variant. Full explicit stat block; fields mirror the current
`Weapon._DEFS` schema plus `id`/`key`/`name`/`archetype` (and `suppression_mult` for LMGs, a field
introduced by the loadout agent — §4):

```json
[
  { "id": 16, "key": "m4a2", "name": "M4A2", "archetype": "AR",
    "damage_body": 24, "headshot_mult": 2.0, "rpm": 700, "mag_size": 30,
    "reserve_ammo": 180, "reload_secs": 2.2, "spread_base_deg": 0.55,
    "spread_bloom_deg": 0.5, "recoil_pitch_deg": 0.35, "range_m": 300.0,
    "muzzle_velocity": 880.0, "gravity_scale": 0.5,
    "fire_modes": ["AUTO", "SEMI", "BURST"], "burst_count": 3 }
]
```

- `archetype` is a **string tag** resolved to the `Weapon` enum (`"AR"`→`Weapon.AR`, …). The registry
  is the single place strings map to the enum.
- `fire_modes` are strings (`"AUTO"/"SEMI"/"BURST"`) mapped to `Weapon.MODE_*` at load — keeps the
  JSON human-readable and decoupled from the numeric constants.
- **Id space:** archetype enum stays `0–5` (`AR/SMG/DMR/RPG/PISTOL/LMG`). Variant ids occupy a
  **reserved block starting at 16**, so they never collide with an archetype id that other systems
  still reference (e.g. `RPG=3` for the projectile/gadget). Ids are **explicit and stable** in the
  JSON — the wire (`u8` weapon field) and both server/client depend on the same id→variant mapping,
  so ids must not be reordered/reused once shipped.
- **Catalog order = default-first per category.** `variants_of(archetype)` preserves catalog order,
  and each category lists its **default variant first** (lowest id in its block), so
  `variants_of(a)[0] == default_variant(a)`. The §2 display tables are role-sorted and therefore may
  differ from catalog order.

### 3.2 `shared/sim/weapon.gd` — the registry layer (this spec's ownership)
`weapon.gd` keeps its six archetype `_DEFS` rows as **fallback defaults** and gains a loaded registry
plus the API the loadout system consumes:

- `Weapon.load_catalog(path := "res://data/weapons.json")` — parse once into
  `_VARIANTS: Dictionary` (id → resolved def, with `archetype` as an int and `fire_modes` as ints)
  and index `_BY_ARCHETYPE: Dictionary` (archetype → ordered `Array[int]` of variant ids). Called at
  boot by both server and client (deterministic — same file, explicit ids).
- `Weapon.archetype_of(id) -> int` — variant id → archetype enum; an archetype id maps to itself
  (so legacy/base ids still resolve).
- `Weapon.variants_of(archetype) -> Array[int]` — ordered; **index 0 is the class default**.
- `Weapon.default_variant(archetype) -> int` — `variants_of(archetype)[0]` (or the archetype id if a
  category has no variants — e.g. a not-yet-populated LMG during parallel dev).
- `Weapon.display_name(id) -> String` — variant name (or the archetype's short label for a base id).
- `Weapon.get_def(id)` — **extended** to resolve a variant id → its block; unknown id falls back to
  the archetype default (preserving today's behavior and back-compat for base ids).
- `Weapon.is_variant(id) -> bool`.

Every other sim entry point already keys off `weapon_id` / `get_def(weapon_id)` — `fire_interval`,
`projectile_ttl_ticks`, `default_mode`, `mode_allowed`, `mode_name`, `reserve_ammo`, `reload_fill`,
`effective_def` — so they resolve variants transparently once `get_def` does. **`effective_def`
applies attachment multipliers to the variant's block; attachment *compatibility* is resolved by
`archetype_of(id)`** (category-level, as agreed).

### 3.3 Integration touchpoints (minimal churn)
| Site | Change |
|---|---|
| `shared/sim/combat.gd`, `client/weapon_predictor.gd` | none beyond registry resolution — both call `get_def`/`effective_def`/`fire_interval` with the (now variant) id. |
| Server spawn (`server/`) | pawn weapon = `loadout.primary` (a variant id); `reserve_ammo`/`mag_size`/`reload_fill` read the variant block. No new code — same calls, variant ids. |
| `client/hud/hud_model.gd`, kill-feed, `DEATH_INFO` recap | switch the weapon label to `Weapon.display_name(id)` — the feed now names the actual gun (free UX win). Wire unchanged (`u8`). |
| `client/art/weapon_kit.gd`, `glb_weapon_kit.gd` | pick the viewmodel via `archetype_of(variant)`; variants share the archetype model in v1 (per-gun art deferred). |
| `shared/net/snapshot.gd` (ENTER weapon byte), `snapshot_columns.gd`, native encoder | **no change** — the weapon field is already `u8`; it now carries a variant id; the client resolves `archetype_of` for the silhouette. |
| `bots/bot_driver.gd`, `bots/exercisers.gd` | bots pick variants via `variants_of(archetype)` so the fleet exercises the roster (the loadout agent's `bot_loadout` drives this; this spec just provides the variant pool). |

**No wire-protocol version bump is required by this spec** — no field is added or widened; the
`weapon` `u8` simply ranges over more ids. (The loadout spec bumps VERSION for its own `SET_LOADOUT`
message; that is independent.)

## 4. Coordination & sequencing with the loadout agent

The loadout spec and this spec both touch `shared/sim/weapon.gd`. Clean split:

- **Loadout agent owns the archetype layer:** the `LMG` enum entry + base `_DEFS` row, the new
  `suppression_mult` field on defs, `can_equip`, and all class/loadout gating (`primary_options`,
  `sanitize`, `default_primary`, the class-select screen).
- **This spec owns the registry layer:** `data/weapons.json`, the loader, `archetype_of` /
  `variants_of` / `default_variant` / `display_name` / `is_variant`, and the variant-resolving
  branch of `get_def`.

**API contract handed to the loadout agent now** (so their `sanitize`/`primary_options`/
`default_primary`/screen are written against the right shape from the start):

1. `LoadoutConfig.primary` carries a **variant id** (an int ≥ 16), not an archetype id.
2. Weapon→class gating resolves via `Weapon.archetype_of(primary)` (e.g. `DMR⇒Assault` becomes
   `archetype_of(primary) == DMR ⇒ Assault`).
3. `primary_options(cls)` returns variant ids by concatenating `Weapon.variants_of(a)` for each
   archetype `a` the class allows; `default_primary(cls) = Weapon.default_variant(first_allowed)`.
4. `sanitize` accepts `primary` iff `Weapon.is_variant(primary)` **and**
   `archetype_of(primary)` is class-allowed; otherwise → `default_primary(cls)`.

**Merge sequencing (de-risks the mutual dependency):**

- I land the **registry API + the AR/SMG/DMR/Pistol variants first** — fully independent of the LMG —
  so the loadout system can build on a real API immediately (its `variants_of(LMG)` is empty/degrades
  to the archetype default until the LMG variants land).
- The **LMG variants merge after** the loadout agent's LMG archetype + `suppression_mult` field
  exist, with my four LMG `suppression_mult` values aligned to their finalized archetype numbers.
- I work in a **dedicated git worktree** (project practice — the main tree is shared by live agents);
  the archetype layer merges first, then my registry layer rebases on top.

## 5. Testing

**Unit (`tests/`, `TestCase`):**

- `weapons_catalog` — the JSON is well-formed: ids unique and ≥ 16 (no archetype-id collision); every
  `archetype` tag resolves to a valid enum; every required stat field present and sane
  (`mag_size`/`reserve_ammo`/`rpm` > 0, `range_m`/`muzzle_velocity` > 0, `fire_modes` non-empty and
  valid, `burst_count` ≥ 1); LMG entries carry `suppression_mult` > 0.
- `weapon_registry` — `archetype_of` maps every variant to its archetype and a base id to itself;
  `variants_of(a)[0] == default_variant(a)`; `default_variant` is a built variant; `display_name`
  non-empty for every id; `get_def(variant)` returns the variant block; `get_def(unknown)` falls back
  to the archetype default (back-compat); `is_variant` correct for variant vs base ids.
- `weapon_effective_def` — `effective_def(variant, mults)` applies attachment multipliers to the
  variant's numbers; attachment compatibility resolves via `archetype_of`.
- `weapon_roster_shape` — per-category **role-axis sanity** guards against future edits collapsing the
  variety: within each category the variants are distinct on their design axis (e.g. AR damage strictly
  increases M4A2 < AKM-74 < FL-40 while rpm strictly decreases; DMR rpm SK-45 > SVD-K > M14-EBR while
  damage increases). Encodes the intended shape so a careless tune trips a test.
- `weapon_lmg_variants` — every LMG variant's `archetype_of == LMG`, `suppression_mult` present,
  `can_equip(SUPPORT, variant)` true via archetype (runs after the archetype layer merges).

**Integration:**

- A loadout with a variant primary fires, reloads via `reload_fill` (variant `mag_size`), and
  produces a kill whose feed shows `display_name`; the ENTER snapshot carries the variant id and the
  client resolves the archetype silhouette.

**Gate:** folds into the loadout agent's **P1 128-bot fleet gate** (already exercises every class ×
weapon on `game2`). Confirm variant ids flow through snapshot / kill-feed / self-state at 30 Hz with
**zero bandwidth change** (weapon stays `u8`) and no tick-budget regression (registry lookups are
O(1) dictionary reads).

## 6. Rollout / deferred

- **Per-gun viewmodels, muzzle-flash, audio** → art-pipeline track (variants share archetype art in v1).
- **Per-gun attachment trees, weapon unlocks/progression** → later gameplay pass.
- **Shotgun category** (new pellet-spread mechanic), **machine pistol / revolver** sidearms → future
  passes if desired (owner deferred both this session).
- **Launcher variety** (RPG-7/LAW/NLAW) and **AA missiles** (Igla/Stinger) → gated on the loadout
  spec's gadget-launcher path and **M10** aircraft respectively.
