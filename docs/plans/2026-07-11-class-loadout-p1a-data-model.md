# Class Select & Loadout — P1a (Data Model) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the shared, server-authoritative loadout data model — a validated `LoadoutConfig`, per-class weapon/gadget option tables, a centralized class-trait ("perk") table with display blurbs, a new Support-only LMG weapon, and widened armor move-speed — all as pure `shared/sim/` logic with a full unit-test suite.

**Architecture:** Everything lives in `shared/sim/` so client prediction and server authority read the same rules (AGENTS.md §5, §7). This slice is **pure data + pure functions with no netcode and no server changes** — it is additive (existing `Loadout`/`Weapon`/`Armor` functions and their 13 callers keep working). A later plan (P1b) wires `SET_LOADOUT`, per-connection persistence, RPG-as-gadget, and the bot path onto this foundation.

**Tech Stack:** Godot 4 / GDScript. Tests use the repo's `TestCase` harness (`tests/*_test.gd`), run headless via `godot --headless --path . -- --test [--filter=SUBSTR]`.

**Spec:** `docs/specs/class-select-loadout.md` (§A data model, §B traits, §C LMG, §I constants, §J testing). This plan implements the P1 *shared-sim* portion only.

**Conventions for every task below:**
- Run a single test file with: `godot --headless --path . -- --test --filter=<file-substr>` (substitute your Godot 4 binary; the CI scripts read `$GODOT`). If a brand-new test file isn't picked up, run `godot --headless --path . --import` once first, then re-run.
- A `TestCase` passes only when it has ≥1 assertion and 0 failures. Assertions available: `assert_true/assert_false/assert_eq/assert_ne/assert_gt/assert_contains/assert_almost_eq`.
- Commit after each task with the shown message.

---

## File Structure

- `shared/sim/armor.gd` — **modify**: widen `_SPEED_MULT` to `{L:1.2, M:1.0, H:0.8}`.
- `shared/sim/weapon.gd` — **modify**: add `LMG` enum + `_DEFS` row + `suppression_mult()` helper.
- `shared/sim/attachment.gd` — **modify**: add public `slot_of(id)` accessor (needed by loadout sanitize).
- `shared/sim/loadout.gd` — **modify**: add gadget id constants, `IMPLEMENTED_GADGETS`, `primary_options`, repurpose `gadget_options`/`is_valid_gadget`, `primary_allowed`, `default_primary/default_gadget/default_armor`, `class_traits`, `trait_blurbs`, `sanitize`, `default_loadout`. (Existing `weapon_for/gadget_for/gadget_for_player/can_equip/armor_for/random_class*/has_sledgehammer/secondary_for/default_attachments` are kept unchanged except `can_equip` gains one LMG rule.)
- `tests/armor_test.gd` — **modify**: update the light-armor speed assertion.
- `tests/loadout_test.gd` — **modify**: update the one test that asserted the old (claymore-era) `gadget_options`.
- `tests/weapon_lmg_test.gd` — **create**: LMG weapon def tests.
- `tests/loadout_config_test.gd` — **create**: option tables, traits, blurbs, sanitize, default_loadout tests.

---

## Task 1: Widen armor move-speed by tier

**Files:**
- Modify: `shared/sim/armor.gd:13`
- Test: `tests/armor_test.gd:10`

- [ ] **Step 1: Update the failing assertion in the existing armor test**

In `tests/armor_test.gd`, change the light-armor assertion (line 10) from `1.0` to `1.2`:

```gdscript
func test_speed_mult_decreases_with_tier() -> void:
	assert_almost_eq(Armor.speed_mult(Armor.LIGHT), 1.2)
	assert_true(Armor.speed_mult(Armor.HEAVY) < Armor.speed_mult(Armor.MEDIUM))
	assert_true(Armor.speed_mult(Armor.MEDIUM) < Armor.speed_mult(Armor.LIGHT))
```

- [ ] **Step 2: Run the test to verify it now FAILS (impl not changed yet)**

Run: `godot --headless --path . -- --test --filter=armor_test`
Expected: FAIL — `assert_almost_eq: 1 vs 1.2` (impl still returns 1.0 for LIGHT).

- [ ] **Step 3: Widen the speed multipliers**

In `shared/sim/armor.gd`, replace the `_SPEED_MULT` line (currently `const _SPEED_MULT := {LIGHT: 1.0, MEDIUM: 0.95, HEAVY: 0.9}`):

```gdscript
# Move-speed multiplier by armor tier (M18: player-picked armor is a real trade-off — widened from
# the M5.5 1.0/0.95/0.9 so Light is a genuine speed pick and Heavy a genuine tank pick).
const _SPEED_MULT := {LIGHT: 1.2, MEDIUM: 1.0, HEAVY: 0.8}
```

- [ ] **Step 4: Run the armor test to verify it PASSES**

Run: `godot --headless --path . -- --test --filter=armor_test`
Expected: PASS for all `armor_test` methods.

> **Caveat:** widening the multipliers changes actual move speed (Medium 0.95→1.0, Heavy 0.9→0.8, Light 1.0→1.2). If a movement/pawn/reconcile test elsewhere asserts an *absolute* speed value derived from `Armor.speed_mult`, it may now fail — the full-suite run in Task 8 is the backstop. Update any such assertion to the new multiplier (this is an intended gameplay change, not a bug).

- [ ] **Step 5: Commit**

```bash
git add shared/sim/armor.gd tests/armor_test.gd
git commit -m "feat(loadout): widen armor move-speed to 1.2/1.0/0.8 (M18 P1a)"
```

---

## Task 2: Add the Support LMG weapon

**Files:**
- Modify: `shared/sim/weapon.gd:5` (enum), `:12-23` (`_DEFS`), add `suppression_mult()`
- Test: `tests/weapon_lmg_test.gd` (create)

- [ ] **Step 1: Write the failing test**

Create `tests/weapon_lmg_test.gd`:

```gdscript
extends TestCase

func test_lmg_enum_and_def_exist() -> void:
	assert_eq(Weapon.LMG, 5, "LMG is the next weapon id after PISTOL")
	var d := Weapon.get_def(Weapon.LMG)
	assert_eq(String(d["name"]), "LMG")

func test_lmg_has_large_mag() -> void:
	assert_gt(int(Weapon.get_def(Weapon.LMG)["mag_size"]), 90, "LMG mag is very large")

func test_lmg_is_full_auto_only() -> void:
	assert_true(Weapon.mode_allowed(Weapon.LMG, Weapon.MODE_AUTO))
	assert_false(Weapon.mode_allowed(Weapon.LMG, Weapon.MODE_SEMI), "LMG is auto-only")

func test_lmg_suppresses_harder_than_ar() -> void:
	assert_gt(Weapon.suppression_mult(Weapon.LMG), Weapon.suppression_mult(Weapon.AR),
		"LMG suppression multiplier exceeds the AR baseline")

func test_default_weapon_suppression_is_one() -> void:
	assert_almost_eq(Weapon.suppression_mult(Weapon.AR), 1.0)
	assert_almost_eq(Weapon.suppression_mult(Weapon.SMG), 1.0)
```

- [ ] **Step 2: Run to verify it FAILS**

Run: `godot --headless --path . --import` then `godot --headless --path . -- --test --filter=weapon_lmg`
Expected: FAIL — `Weapon.LMG` not defined / `suppression_mult` nonexistent.

- [ ] **Step 3: Add the LMG enum entry**

In `shared/sim/weapon.gd`, change the enum (line 5) to add `LMG`:

```gdscript
enum { AR = 0, SMG = 1, DMR = 2, RPG = 3, PISTOL = 4, LMG = 5 }
```

- [ ] **Step 4: Add the LMG `_DEFS` row**

In `shared/sim/weapon.gd`, inside `const _DEFS := { ... }`, add this row after the `PISTOL:` line (note the new `suppression_mult` field; AR-ish damage, ~100 mag, harder to control, auto-only):

```gdscript
	# M18: Support-only LMG. Very large mag + higher suppression, but heavier spread/recoil so it's a
	# hold-the-lane weapon, not a run-and-gun. Bipod attachment (prone_spread_zero) pairs naturally.
	LMG:    {"name": "LMG",    "damage_body": 24, "headshot_mult": 1.8, "rpm": 700, "mag_size": 100, "reserve_ammo": 300, "reload_secs": 4.5, "spread_base_deg": 1.2, "spread_bloom_deg": 0.9, "recoil_pitch_deg": 0.6, "range_m": 250.0, "muzzle_velocity": 750.0, "gravity_scale": 0.5, "fire_modes": [MODE_AUTO], "burst_count": 3, "suppression_mult": 1.6},
```

- [ ] **Step 5: Add the `suppression_mult()` helper**

In `shared/sim/weapon.gd`, add after `reserve_ammo()` (near line 28):

```gdscript
## Per-weapon suppression multiplier (M18): how much more/less this weapon suppresses vs the
## baseline. Defaults to 1.0 for weapons that don't specify it (all but the LMG today).
static func suppression_mult(weapon_id: int) -> float:
	return float(get_def(weapon_id).get("suppression_mult", 1.0))
```

- [ ] **Step 6: Run to verify it PASSES**

Run: `godot --headless --path . -- --test --filter=weapon_lmg`
Expected: PASS for all `weapon_lmg` methods.

- [ ] **Step 7: Run the existing weapon test to confirm no regression**

Run: `godot --headless --path . -- --test --filter=weapon_test`
Expected: PASS (the new field/enum entry is additive).

- [ ] **Step 8: Commit**

```bash
git add shared/sim/weapon.gd tests/weapon_lmg_test.gd
git commit -m "feat(loadout): add Support-only LMG weapon + suppression_mult (M18 P1a)"
```

---

## Task 3: Add a public `slot_of` accessor to the attachment catalog

**Files:**
- Modify: `shared/sim/attachment.gd`
- Test: covered indirectly by Task 7 sanitize tests; add a direct assertion here.

- [ ] **Step 1: Write the failing test**

Create `tests/attachment_slot_test.gd`:

```gdscript
extends TestCase

func _catalog() -> Attachment:
	var res := Attachment.from_dict({"attachments": [
		{"id": "reddot", "slot": "optic"},
		{"id": "brake", "slot": "barrel"},
	]})
	return res["catalog"]

func test_slot_of_known_id() -> void:
	var c := _catalog()
	assert_eq(c.slot_of("reddot"), "optic")
	assert_eq(c.slot_of("brake"), "barrel")

func test_slot_of_unknown_id_is_empty() -> void:
	assert_eq(_catalog().slot_of("does_not_exist"), "")
```

- [ ] **Step 2: Run to verify it FAILS**

Run: `godot --headless --path . --import` then `godot --headless --path . -- --test --filter=attachment_slot`
Expected: FAIL — `slot_of` nonexistent.

- [ ] **Step 3: Add the accessor**

In `shared/sim/attachment.gd`, add after `multipliers()`:

```gdscript
## The slot ("optic"/"barrel"/"underbarrel") an attachment id belongs to, or "" if unknown.
## Public read accessor over the private catalog so loadout sanitize can validate slot membership.
func slot_of(id: String) -> String:
	var a = _by_id.get(id, null)
	return String(a["slot"]) if a != null else ""

func has_id(id: String) -> bool:
	return _by_id.has(id)
```

- [ ] **Step 4: Run to verify it PASSES**

Run: `godot --headless --path . -- --test --filter=attachment_slot`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/attachment.gd tests/attachment_slot_test.gd
git commit -m "feat(loadout): Attachment.slot_of/has_id accessors (M18 P1a)"
```

---

## Task 4: Loadout gadget constants + option tables + defaults

**Files:**
- Modify: `shared/sim/loadout.gd`
- Test: `tests/loadout_config_test.gd` (create), `tests/loadout_test.gd` (update one test)

- [ ] **Step 1: Write the failing test**

Create `tests/loadout_config_test.gd`:

```gdscript
extends TestCase

const ALL_CLASSES := [Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER, Loadout.SUPPORT]

func test_primary_options_match_matrix() -> void:
	assert_eq(Loadout.primary_options(Loadout.ASSAULT), [Weapon.AR, Weapon.SMG, Weapon.DMR])
	assert_eq(Loadout.primary_options(Loadout.MEDIC), [Weapon.AR, Weapon.SMG])
	assert_eq(Loadout.primary_options(Loadout.ENGINEER), [Weapon.AR, Weapon.SMG])
	assert_eq(Loadout.primary_options(Loadout.SUPPORT), [Weapon.AR, Weapon.SMG, Weapon.LMG])

func test_gadget_options_match_matrix() -> void:
	assert_eq(Loadout.gadget_options(Loadout.ASSAULT), [Loadout.GADGET_C4, Loadout.GADGET_GRAPPLE, Loadout.GADGET_BREACH])
	assert_eq(Loadout.gadget_options(Loadout.MEDIC), [Loadout.GADGET_HEAL, Loadout.GADGET_STIM, Loadout.GADGET_SMOKE_WALL])
	assert_eq(Loadout.gadget_options(Loadout.ENGINEER), [Loadout.GADGET_RPG, Loadout.GADGET_C4, Loadout.GADGET_REPAIR])
	assert_eq(Loadout.gadget_options(Loadout.SUPPORT), [Loadout.GADGET_AMMO, Loadout.GADGET_RIOT_SHIELD, Loadout.GADGET_LMG_NEST])

func test_every_class_has_three_gadget_options() -> void:
	for c in ALL_CLASSES:
		assert_eq(Loadout.gadget_options(c).size(), 3, "class %d has 3 gadgets" % c)

func test_default_gadget_is_always_implemented() -> void:
	# Each class's default gadget must be a built one so every class works from P1.
	for c in ALL_CLASSES:
		assert_contains(Loadout.IMPLEMENTED_GADGETS, Loadout.default_gadget(c))

func test_default_gadget_picks_first_implemented_option() -> void:
	# Engineer's first option (RPG) is not yet implemented in P1a, so its default falls to C4.
	assert_eq(Loadout.default_gadget(Loadout.ENGINEER), Loadout.GADGET_C4)
	assert_eq(Loadout.default_gadget(Loadout.ASSAULT), Loadout.GADGET_C4)
	assert_eq(Loadout.default_gadget(Loadout.MEDIC), Loadout.GADGET_HEAL)
	assert_eq(Loadout.default_gadget(Loadout.SUPPORT), Loadout.GADGET_AMMO)

func test_default_primary_is_ar_for_all() -> void:
	for c in ALL_CLASSES:
		assert_eq(Loadout.default_primary(c), Weapon.AR)

func test_default_armor_is_medium() -> void:
	for c in ALL_CLASSES:
		assert_eq(Loadout.default_armor(c), Armor.MEDIUM)

func test_primary_allowed_enforces_locks() -> void:
	assert_true(Loadout.primary_allowed(Loadout.ASSAULT, Weapon.DMR), "Assault may take DMR")
	assert_false(Loadout.primary_allowed(Loadout.MEDIC, Weapon.DMR), "Medic may not take DMR")
	assert_true(Loadout.primary_allowed(Loadout.SUPPORT, Weapon.LMG), "Support may take LMG")
	assert_false(Loadout.primary_allowed(Loadout.ASSAULT, Weapon.LMG), "only Support takes LMG")
	assert_false(Loadout.primary_allowed(Loadout.ENGINEER, Weapon.RPG), "RPG is never a primary")

func test_lmg_can_equip_support_only() -> void:
	assert_true(Loadout.can_equip(Loadout.SUPPORT, Weapon.LMG))
	assert_false(Loadout.can_equip(Loadout.ASSAULT, Weapon.LMG))
	assert_false(Loadout.can_equip(Loadout.MEDIC, Weapon.LMG))
```

- [ ] **Step 2: Run to verify it FAILS**

Run: `godot --headless --path . --import` then `godot --headless --path . -- --test --filter=loadout_config`
Expected: FAIL — `primary_options`/`GADGET_GRAPPLE`/etc. nonexistent.

- [ ] **Step 3: Add gadget constants + IMPLEMENTED_GADGETS**

In `shared/sim/loadout.gd`, after the existing gadget-kind constants (the `GADGET_C4/MINE/HEAL/AMMO` block near line 10-14), add:

```gdscript
# M18 gadget ids. The 0-5 values mirror Gadget.KIND_* so a loadout gadget maps 1:1 to a gadget
# entity; the 6+ ids are M18-new gadgets whose entities land in later phases. GADGET_MEDKIT is a
# display alias of HEAL.
const GADGET_RPG := 2          # mirrors Gadget.KIND_RPG (RPG is a gadget now, not a primary)
const GADGET_REPAIR := 5       # mirrors Gadget.KIND_REPAIR
const GADGET_MEDKIT := GADGET_HEAL   # display alias
const GADGET_STIM := 6
const GADGET_SMOKE_WALL := 7
const GADGET_BREACH := 8
const GADGET_GRAPPLE := 9
const GADGET_RIOT_SHIELD := 10
const GADGET_SANDBAG := 11
const GADGET_LMG_NEST := 12

# Gadgets whose selection is actually supported so far. GROWS PER PHASE (spec §D/§L): P1b adds RPG;
# P2 adds STIM/BREACH/SMOKE_WALL/REPAIR/SANDBAG; P4 adds LMG_NEST; later GRAPPLE/RIOT_SHIELD. An
# unbuilt gadget is not selectable (sanitize + client hide it) and its class falls back to the
# first BUILT option (default_gadget).
const IMPLEMENTED_GADGETS := [GADGET_C4, GADGET_HEAL, GADGET_AMMO]
```

- [ ] **Step 4: Add the option tables + defaults + `primary_allowed`**

In `shared/sim/loadout.gd`, add these functions (place them near the existing `gadget_options`; you will replace the old `gadget_options`/`is_valid_gadget` bodies in the next step):

```gdscript
## Primary-weapon archetypes selectable per class (spec §A matrix).
static func primary_options(cls: int) -> Array:
	match cls:
		ASSAULT: return [Weapon.AR, Weapon.SMG, Weapon.DMR]
		SUPPORT: return [Weapon.AR, Weapon.SMG, Weapon.LMG]
		_: return [Weapon.AR, Weapon.SMG]   # medic, engineer

## True if a class may take this primary: it's in the class's archetype list AND passes can_equip.
static func primary_allowed(cls: int, weapon_id: int) -> bool:
	return (weapon_id in primary_options(cls)) and can_equip(cls, weapon_id)

## First primary archetype (AR for every class today).
static func default_primary(cls: int) -> int:
	return primary_options(cls)[0]

## The first gadget option that is actually built (in IMPLEMENTED_GADGETS). Guarantees a working
## default even while later options are still unimplemented. Every class's gadget_options has at
## least one implemented entry (invariant covered by the tests).
static func default_gadget(cls: int) -> int:
	for g in gadget_options(cls):
		if g in IMPLEMENTED_GADGETS:
			return g
	return GADGET_C4   # unreachable given the invariant; safe fallback

## Armor tier a fresh loadout starts on.
static func default_armor(_cls: int) -> int:
	return Armor.MEDIUM
```

- [ ] **Step 5: Repurpose `gadget_options` + `is_valid_gadget` to the M18 roster**

In `shared/sim/loadout.gd`, replace the existing `gadget_options` and `is_valid_gadget` bodies (the claymore-era versions — they have no non-test callers) with:

```gdscript
## The three gadgets a class may choose between (spec §A). The target roster; availability is
## gated by IMPLEMENTED_GADGETS (see sanitize/default_gadget).
static func gadget_options(cls: int) -> Array:
	match cls:
		ASSAULT: return [GADGET_C4, GADGET_GRAPPLE, GADGET_BREACH]
		MEDIC: return [GADGET_HEAL, GADGET_STIM, GADGET_SMOKE_WALL]
		ENGINEER: return [GADGET_RPG, GADGET_C4, GADGET_REPAIR]
		SUPPORT: return [GADGET_AMMO, GADGET_RIOT_SHIELD, GADGET_LMG_NEST]
		_: return [GADGET_C4]

static func is_valid_gadget(cls: int, gadget: int) -> bool:
	return gadget in gadget_options(cls)
```

- [ ] **Step 6: Add the LMG rule to `can_equip`**

In `shared/sim/loadout.gd`, in `can_equip`, add the LMG lock alongside the existing RPG/DMR rules:

```gdscript
static func can_equip(cls: int, weapon_id: int) -> bool:
	if weapon_id == Weapon.RPG:
		return cls == ENGINEER
	if weapon_id == Weapon.DMR:
		return cls == ASSAULT
	if weapon_id == Weapon.LMG:
		return cls == SUPPORT
	return true
```

- [ ] **Step 7: Fix the one existing loadout_test that asserted old gadget_options**

In `tests/loadout_test.gd`, replace `test_engineer_gadget_options_c4_or_mine` with the M18 roster (the other `loadout_test` methods still pass — `gadget_for`/`gadget_for_player` are unchanged):

```gdscript
func test_engineer_gadget_options_are_rpg_c4_repair() -> void:
	assert_eq(Loadout.gadget_options(Loadout.ENGINEER), [Loadout.GADGET_RPG, Loadout.GADGET_C4, Loadout.GADGET_REPAIR])
	assert_true(Loadout.is_valid_gadget(Loadout.ENGINEER, Loadout.GADGET_C4))
	assert_false(Loadout.is_valid_gadget(Loadout.ENGINEER, Loadout.GADGET_HEAL), "engineer can't pick heal")
```

- [ ] **Step 8: Run both test files to verify PASS**

Run: `godot --headless --path . -- --test --filter=loadout_config`
Expected: PASS for all `loadout_config` methods.
Run: `godot --headless --path . -- --test --filter=loadout_test`
Expected: PASS for all `loadout_test` methods.

- [ ] **Step 9: Commit**

```bash
git add shared/sim/loadout.gd tests/loadout_config_test.gd tests/loadout_test.gd
git commit -m "feat(loadout): M18 gadget ids, option tables, defaults, LMG lock (P1a)"
```

---

## Task 5: Class-trait ("perk") table

**Files:**
- Modify: `shared/sim/loadout.gd`
- Test: `tests/loadout_config_test.gd` (append)

- [ ] **Step 1: Write the failing test (append to `tests/loadout_config_test.gd`)**

```gdscript
func test_class_traits_blast_engineer_only() -> void:
	assert_almost_eq(float(Loadout.class_traits(Loadout.ENGINEER)["blast_mult"]), 1.2)
	for c in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.SUPPORT]:
		assert_almost_eq(float(Loadout.class_traits(c)["blast_mult"]), 1.0)

func test_class_traits_grenades_support_five_others_three() -> void:
	assert_eq(int(Loadout.class_traits(Loadout.SUPPORT)["grenade_count"]), 5)
	for c in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER]:
		assert_eq(int(Loadout.class_traits(c)["grenade_count"]), 3)

func test_class_traits_regen_fast_assault_only() -> void:
	assert_true(bool(Loadout.class_traits(Loadout.ASSAULT)["regen_fast"]))
	for c in [Loadout.MEDIC, Loadout.ENGINEER, Loadout.SUPPORT]:
		assert_false(bool(Loadout.class_traits(c)["regen_fast"]))

func test_class_traits_reserve_bonus_support_only() -> void:
	assert_gt(float(Loadout.class_traits(Loadout.SUPPORT)["reserve_mult"]), 1.0)
	for c in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER]:
		assert_almost_eq(float(Loadout.class_traits(c)["reserve_mult"]), 1.0)

func test_class_traits_medic_and_engineer_signatures() -> void:
	assert_true(bool(Loadout.class_traits(Loadout.MEDIC)["revive_fast"]))
	assert_eq(int(Loadout.class_traits(Loadout.MEDIC)["bandages"]), Revive.MEDIC_BANDAGE_COUNT)
	assert_eq(int(Loadout.class_traits(Loadout.ASSAULT)["bandages"]), Revive.BANDAGE_COUNT)
	assert_true(bool(Loadout.class_traits(Loadout.ENGINEER)["sledgehammer"]))
	assert_false(bool(Loadout.class_traits(Loadout.ASSAULT)["sledgehammer"]))
```

- [ ] **Step 2: Run to verify it FAILS**

Run: `godot --headless --path . -- --test --filter=loadout_config`
Expected: FAIL — `class_traits` nonexistent.

- [ ] **Step 3: Add the trait table**

In `shared/sim/loadout.gd`, add (pulls existing constants from `Revive` so the numbers stay single-sourced):

```gdscript
## Centralized passive class traits ("perks") — the single source the server reads (P1b) and the
## class-select screen displays (P3) so what you see equals what you get. Keys:
##   revive_fast(bool) bandages(int) sledgehammer(bool) blast_mult(float)
##   regen_fast(bool)  grenade_count(int) reserve_mult(float)
static func class_traits(cls: int) -> Dictionary:
	match cls:
		MEDIC:
			return {"revive_fast": true, "bandages": Revive.MEDIC_BANDAGE_COUNT, "sledgehammer": false,
				"blast_mult": 1.0, "regen_fast": false, "grenade_count": 3, "reserve_mult": 1.0}
		ENGINEER:
			return {"revive_fast": false, "bandages": Revive.BANDAGE_COUNT, "sledgehammer": true,
				"blast_mult": 1.2, "regen_fast": false, "grenade_count": 3, "reserve_mult": 1.0}
		SUPPORT:
			return {"revive_fast": false, "bandages": Revive.BANDAGE_COUNT, "sledgehammer": false,
				"blast_mult": 1.0, "regen_fast": false, "grenade_count": 5, "reserve_mult": 1.25}
		_:  # ASSAULT (and unknown)
			return {"revive_fast": false, "bandages": Revive.BANDAGE_COUNT, "sledgehammer": false,
				"blast_mult": 1.0, "regen_fast": true, "grenade_count": 3, "reserve_mult": 1.0}
```

- [ ] **Step 4: Run to verify it PASSES**

Run: `godot --headless --path . -- --test --filter=loadout_config`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/loadout.gd tests/loadout_config_test.gd
git commit -m "feat(loadout): centralized class_traits perk table (M18 P1a)"
```

---

## Task 6: Trait display blurbs (self-documenting perks)

**Files:**
- Modify: `shared/sim/loadout.gd`
- Test: `tests/loadout_config_test.gd` (append)

- [ ] **Step 1: Write the failing test (append)**

```gdscript
func test_trait_blurbs_nonempty_for_all_classes() -> void:
	for c in ALL_CLASSES:
		assert_gt(Loadout.trait_blurbs(c).size(), 0, "class %d has blurbs" % c)

func _joined(cls: int) -> String:
	return " || ".join(Loadout.trait_blurbs(cls))

func test_trait_blurbs_mention_each_signature_perk() -> void:
	# Blurbs are generated from class_traits so display can't drift from the sim.
	assert_contains(_joined(Loadout.ASSAULT), "Combat Vigor")
	assert_contains(_joined(Loadout.ASSAULT), "DMR")
	assert_contains(_joined(Loadout.MEDIC), "revive")
	assert_contains(_joined(Loadout.MEDIC), "20")
	assert_contains(_joined(Loadout.ENGINEER), "blast")
	assert_contains(_joined(Loadout.ENGINEER), "Sledgehammer")
	assert_contains(_joined(Loadout.SUPPORT), "LMG")
	assert_contains(_joined(Loadout.SUPPORT), "grenade")

func test_trait_blurbs_cover_every_active_trait() -> void:
	# Every non-neutral trait in class_traits must surface at least one blurb line.
	for c in ALL_CLASSES:
		var t := Loadout.class_traits(c)
		var active := 0
		if bool(t["regen_fast"]): active += 1
		if bool(t["revive_fast"]): active += 1
		if bool(t["sledgehammer"]): active += 1
		if float(t["blast_mult"]) > 1.0: active += 1
		if int(t["grenade_count"]) > 3: active += 1
		if float(t["reserve_mult"]) > 1.0: active += 1
		assert_true(Loadout.trait_blurbs(c).size() >= active,
			"class %d: %d blurbs >= %d active traits" % [c, Loadout.trait_blurbs(c).size(), active])
```

- [ ] **Step 2: Run to verify it FAILS**

Run: `godot --headless --path . -- --test --filter=loadout_config`
Expected: FAIL — `trait_blurbs` nonexistent.

- [ ] **Step 3: Add `trait_blurbs`**

In `shared/sim/loadout.gd`, add (derives strings from `class_traits` + weapon access so it can't drift):

```gdscript
## Plain-language perk lines for the class-select screen (spec §G) — generated from class_traits so
## the display can never disagree with the sim. Order: signature perk(s) first, then utility.
static func trait_blurbs(cls: int) -> Array:
	var t := class_traits(cls)
	var out: Array = []
	if bool(t["regen_fast"]):
		out.append("Combat Vigor — heals faster after taking damage")
	if bool(t["revive_fast"]):
		out.append("Field Medic — revives teammates faster")
	if int(t["bandages"]) > Revive.BANDAGE_COUNT:
		out.append("Carries %d bandages" % int(t["bandages"]))
	if bool(t["sledgehammer"]):
		out.append("Sledgehammer melee — smashes through structures")
	if float(t["blast_mult"]) > 1.0:
		out.append("Demolitions — +%d%% explosive blast radius" % int(round((float(t["blast_mult"]) - 1.0) * 100.0)))
	if int(t["grenade_count"]) > 3:
		out.append("Ammo Hauler — carries %d grenades" % int(t["grenade_count"]))
	if float(t["reserve_mult"]) > 1.0:
		out.append("Extra reserve ammo")
	# Weapon-access lines (derived from the primary list so they track the matrix).
	if Weapon.DMR in primary_options(cls):
		out.append("Can equip the DMR (marksman)")
	if Weapon.LMG in primary_options(cls):
		out.append("Can equip the LMG (heavy suppression)")
	return out
```

- [ ] **Step 4: Run to verify it PASSES**

Run: `godot --headless --path . -- --test --filter=loadout_config`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/loadout.gd tests/loadout_config_test.gd
git commit -m "feat(loadout): trait_blurbs — self-documenting perks from class_traits (M18 P1a)"
```

---

## Task 7: `sanitize` + `default_loadout` (the validation authority)

**Files:**
- Modify: `shared/sim/loadout.gd`
- Test: `tests/loadout_config_test.gd` (append)

- [ ] **Step 1: Write the failing test (append)**

```gdscript
func _attach() -> Attachment:
	# Minimal catalog covering the default ids used by default_attachments().
	var res := Attachment.from_dict({"attachments": [
		{"id": "iron", "slot": "optic"},
		{"id": "reddot", "slot": "optic"},
		{"id": "standard", "slot": "barrel"},
		{"id": "none_ub", "slot": "underbarrel"},
	]})
	return res["catalog"]

func test_default_loadout_is_self_consistent() -> void:
	# sanitize(default_loadout) must equal default_loadout — the round-trip invariant.
	for c in ALL_CLASSES:
		var d := Loadout.default_loadout(c)
		assert_eq(Loadout.sanitize(d, _attach()), d, "default_loadout(%d) is stable under sanitize" % c)

func test_sanitize_is_idempotent() -> void:
	var raw := {"class": Loadout.SUPPORT, "primary": Weapon.LMG, "secondary": Weapon.PISTOL,
		"gadget": Loadout.GADGET_AMMO, "armor": Armor.HEAVY, "grenade": Grenade.SMOKE,
		"attachments": {"optic": "reddot", "barrel": "standard", "underbarrel": "none_ub"}}
	var once := Loadout.sanitize(raw, _attach())
	assert_eq(Loadout.sanitize(once, _attach()), once, "sanitize twice == once")

func test_sanitize_rejects_illegal_primary() -> void:
	# Medic can't take the DMR -> falls back to the class default primary (AR).
	var out := Loadout.sanitize({"class": Loadout.MEDIC, "primary": Weapon.DMR}, _attach())
	assert_eq(int(out["primary"]), Weapon.AR)

func test_sanitize_rpg_never_a_primary() -> void:
	var out := Loadout.sanitize({"class": Loadout.ENGINEER, "primary": Weapon.RPG}, _attach())
	assert_ne(int(out["primary"]), Weapon.RPG)

func test_sanitize_unbuilt_gadget_falls_to_default() -> void:
	# Support's Riot Shield is not implemented yet -> default gadget (Ammo Bag).
	var out := Loadout.sanitize({"class": Loadout.SUPPORT, "gadget": Loadout.GADGET_RIOT_SHIELD}, _attach())
	assert_eq(int(out["gadget"]), Loadout.GADGET_AMMO)

func test_sanitize_out_of_set_gadget_falls_to_default() -> void:
	# Heal is not a Support gadget at all.
	var out := Loadout.sanitize({"class": Loadout.SUPPORT, "gadget": Loadout.GADGET_HEAL}, _attach())
	assert_eq(int(out["gadget"]), Loadout.GADGET_AMMO)

func test_sanitize_clamps_class_armor_grenade() -> void:
	var out := Loadout.sanitize({"class": 99, "armor": 99, "grenade": 99}, _attach())
	assert_eq(int(out["class"]), Loadout.ASSAULT)
	assert_eq(int(out["armor"]), Armor.MEDIUM)
	assert_eq(int(out["grenade"]), Grenade.FRAG)

func test_sanitize_drops_bad_attachment_ids() -> void:
	var out := Loadout.sanitize({"class": Loadout.ASSAULT,
		"attachments": {"optic": "not_a_real_id", "barrel": "none_ub", "underbarrel": "none_ub"}}, _attach())
	# unknown optic -> default optic; "none_ub" is an underbarrel id in the wrong (barrel) slot -> default barrel.
	assert_eq(String(out["attachments"]["optic"]), String(Loadout.default_attachments()["optic"]))
	assert_eq(String(out["attachments"]["barrel"]), String(Loadout.default_attachments()["barrel"]))

func test_sanitize_secondary_is_always_pistol() -> void:
	var out := Loadout.sanitize({"class": Loadout.ASSAULT, "secondary": Weapon.AR}, _attach())
	assert_eq(int(out["secondary"]), Weapon.PISTOL)
```

- [ ] **Step 2: Run to verify it FAILS**

Run: `godot --headless --path . -- --test --filter=loadout_config`
Expected: FAIL — `sanitize`/`default_loadout` nonexistent.

- [ ] **Step 3: Add `default_loadout`, `sanitize`, and the attachment helper**

In `shared/sim/loadout.gd`, add:

```gdscript
## A full, valid starting loadout for a class (server per-connection default + client screen seed).
static func default_loadout(cls: int) -> Dictionary:
	return {
		"class": cls,
		"primary": default_primary(cls),
		"secondary": Weapon.PISTOL,
		"gadget": default_gadget(cls),
		"armor": default_armor(cls),
		"grenade": Grenade.FRAG,
		"attachments": default_attachments(),
	}

## THE loadout validation authority — called by BOTH client (grey-out) and server (authoritative).
## Total (never returns an invalid config) and idempotent. `attach` is the Attachment catalog.
static func sanitize(cfg: Dictionary, attach: Attachment) -> Dictionary:
	var cls: int = clampi(int(cfg.get("class", ASSAULT)), 0, 3)
	var primary: int = int(cfg.get("primary", default_primary(cls)))
	if not primary_allowed(cls, primary):
		primary = default_primary(cls)
	var gadget: int = int(cfg.get("gadget", default_gadget(cls)))
	if not ((gadget in gadget_options(cls)) and (gadget in IMPLEMENTED_GADGETS)):
		gadget = default_gadget(cls)
	var armor: int = clampi(int(cfg.get("armor", Armor.MEDIUM)), 0, 2)
	var grenade: int = int(cfg.get("grenade", Grenade.FRAG))
	if not (grenade in [Grenade.FRAG, Grenade.SMOKE, Grenade.FLASHBANG]):
		grenade = Grenade.FRAG
	return {
		"class": cls,
		"primary": primary,
		"secondary": Weapon.PISTOL,   # v1: universal sidearm, never client-chosen
		"gadget": gadget,
		"armor": armor,
		"grenade": grenade,
		"attachments": _sanitize_attachments(cfg.get("attachments", {}), attach),
	}

## Per-slot: keep a chosen attachment only if the catalog knows it AND it belongs to that slot;
## otherwise fall back to the slot default. Guarantees all three slots are present + valid.
static func _sanitize_attachments(raw, attach: Attachment) -> Dictionary:
	var defaults := default_attachments()
	var out := {}
	if not (raw is Dictionary):
		raw = {}
	for slot in Attachment.SLOTS:
		var chosen := String((raw as Dictionary).get(slot, ""))
		if chosen != "" and attach != null and attach.slot_of(chosen) == slot:
			out[slot] = chosen
		else:
			out[slot] = String(defaults[slot])
	return out
```

- [ ] **Step 4: Run to verify it PASSES**

Run: `godot --headless --path . -- --test --filter=loadout_config`
Expected: PASS for all `loadout_config` methods.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/loadout.gd tests/loadout_config_test.gd
git commit -m "feat(loadout): sanitize (validation authority) + default_loadout (M18 P1a)"
```

---

## Task 8: Full-suite green + close-out

**Files:** none (verification only)

- [ ] **Step 1: Run the ENTIRE test suite**

Run: `godot --headless --path . -- --test`
Expected: final line `TESTS: N run, 0 failed`. If any pre-existing test regressed, fix it before continuing (the P1a changes are additive except the two intentionally-updated tests in Tasks 1 & 4).

- [ ] **Step 2: Confirm no stray references to removed behavior**

Run: `grep -rn "gadget_options" server/ bots/ client/ | grep -v "_test.gd"`
Expected: no output (the repurposed `gadget_options` still has no non-test callers, so nothing in server/bots/client depends on its old claymore semantics).

- [ ] **Step 3: Commit any fixes from Step 1 (if needed), else no-op**

```bash
git add -A && git commit -m "test(loadout): P1a full suite green" || echo "nothing to commit"
```

---

## Done / Next

P1a delivers the validated loadout **data model** — options, traits, blurbs, LMG, armor speed — unit-tested end to end. Nothing is wired to the running game yet (by design); the 13 existing `Loadout` callers are untouched.

**Weapon-variants integration (P1b, BLOCKED on the weapon-variants registry API landing on master):**
- P1a already added the `Loadout._archetype_of(id)` seam (identity today) + `allowed_archetypes(cls)`. When `Weapon.archetype_of/variants_of/default_variant/is_variant` land (owned by the weapon-variants track; only its design doc is on master today), flip `_archetype_of` to `Weapon.archetype_of`, expand `primary_options` to `concat(Weapon.variants_of(a) for a in allowed_archetypes(cls))`, set `default_primary = Weapon.default_variant(allowed_archetypes(cls)[0])`, and add `Weapon.is_variant(primary)` to `is_primary_allowed`. Update the `primary_options`/`default_primary` tests (they currently assert archetype ids) to variant ids. `primary` stays `u8` on the wire. Contract: `docs/superpowers/specs/2026-07-11-weapon-variants-design.md` §3–§4 + §A "Weapon variants integration" of this milestone's spec.

**P1b (next plan) builds on this:**
- `Msg.SET_LOADOUT` (VERSION 7→8) encode/decode + client send + server handler (`shared/net/protocol.gd`, `client/client_main.gd`, `server/server_main.gd`).
- Per-connection `_clients[id]["loadout"]` storage; server applies the sanitized config at spawn (weapon/ammo/reserve/armor/grenade/bandages + `class_traits`).
- **RPG-as-gadget** rework (add `GADGET_RPG` to `IMPLEMENTED_GADGETS`; seed the rocket pool from the gadget, not the primary; delete the `random_class_no_engineer` human-exclusion).
- `bot_loadout(id)` on the unified path + `--loadout=` headless debug arg.
- 128-bot fleet gate on `conquest_town` (tick < 33.3 ms, bandwidth unchanged, winner declared).

**Then P2** (traits wired + cheap gadgets), **P3** (client class-select screen), **P4** (LMG Nest).
