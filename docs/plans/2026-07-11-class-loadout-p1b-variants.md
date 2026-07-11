# M19 P1b-1 — Wire the loadout data model onto the weapon-variants registry

> **For agentic workers:** REQUIRED SUB-SKILL: execute this via superpowers:subagent-driven-development, task-by-task, TDD. Steps use checkbox syntax for tracking.

**Goal:** Now that the weapon-variants registry is on master (`Weapon.archetype_of/variants_of/default_variant/is_variant/display_name`, catalog `data/weapons.json`, ids 16–32), flip the `Loadout` seam so `primary` is a named-variant id instead of a bare archetype id — exactly the §4 contract of `docs/superpowers/specs/2026-07-11-weapon-variants-design.md`.

**Architecture:** Change ONLY the three seam functions the P1a design isolated (`_archetype_of`, `primary_options`, `default_primary`), the two weapon-access lines in `trait_blurbs`, and tighten `sanitize` to require a real variant. Everything else in `loadout.gd` already routes through the seam, so class gating stays correct for both base and variant ids. Pure `shared/sim` change; no wire/server/bot changes here (those are P1b-2).

**Tech stack:** Godot 4 / GDScript; `TestCase` harness. The registry is a process-global static loaded via `Weapon.load_from_file("res://data/weapons.json")` (server+client boot already do this); tests must load it in `setup()` and clear it in `teardown()`.

---

## Context the implementer needs (read before starting)

- `shared/sim/weapon.gd` is the registry. Key API:
  - `Weapon.archetype_of(id)` → variant id → archetype enum; **a base archetype id (0–5) maps to itself**; unknown → `AR`.
  - `Weapon.variants_of(archetype)` → ordered `Array[int]` of variant ids (empty if none loaded).
  - `Weapon.default_variant(archetype)` → `variants_of(a)[0]`, or the archetype id itself if the category has no variants (graceful degrade).
  - `Weapon.is_variant(id)` → true iff `id` is a loaded variant (≥16).
  - Archetype enum: `AR=0 SMG=1 DMR=2 RPG=3 PISTOL=4 LMG=5`.
- Catalog defaults (first per category, lowest id): AR→16 (M4A2), SMG→19 (MP-5X), DMR→22 (SVD-K), PISTOL→25 (M9), LMG→29 (PKP).
- `Loadout.allowed_archetypes(cls)` is the STABLE archetype allow-list — it does NOT change here. Only `primary_options` (concrete ids) and the seam change.
- Registry is a static var shared across tests. `tests/weapon_registry_test.gd` resets it to a fixture. So any test needing the real catalog MUST load it in its own `setup()` and reset in `teardown()` (see `tests/hud_weapon_label_test.gd` for the pattern), to be order-independent.
- `TestCase` provides `func setup()` and `func teardown()`.

---

### Task 1: Flip the `Loadout` seam to variant ids

**Files:**
- Modify: `shared/sim/loadout.gd`
- Modify (tests): `tests/loadout_config_test.gd`

**The five edits to `loadout.gd`:**

1. `_archetype_of(weapon_id)` body → `return Weapon.archetype_of(weapon_id)` (delete the identity `return weapon_id`; update the doc comment to say the seam is now live).

2. `primary_options(cls)` → concatenate variants per allowed archetype:
```gdscript
static func primary_options(cls: int) -> Array:
	var out: Array = []
	for a in allowed_archetypes(cls):
		out.append_array(Weapon.variants_of(a))
	return out
```
(Requires the registry to be loaded; server+client load it at boot and tests load it in `setup()`.)

3. `default_primary(cls)` → the stock gun of the class's first allowed archetype:
```gdscript
static func default_primary(cls: int) -> int:
	return Weapon.default_variant(allowed_archetypes(cls)[0])
```
(First allowed archetype is `AR` for every class → default is M4A2 (16); degrades to `Weapon.AR` (0) if the catalog is unloaded.)

4. In `trait_blurbs(cls)`, the two weapon-access lines currently test `Weapon.DMR in primary_options(cls)` / `Weapon.LMG in primary_options(cls)`. Those archetype ids are no longer in `primary_options` (it now holds variant ids). Change both to test the stable allow-list:
```gdscript
	if Weapon.DMR in allowed_archetypes(cls):
		out.append("Can equip the DMR (marksman)")
	if Weapon.LMG in allowed_archetypes(cls):
		out.append("Can equip the LMG (heavy suppression)")
```

5. In `sanitize`, tighten the primary check to require a real variant (spec §4 contract point 4) — a bare archetype id or garbage falls back to the class default variant:
```gdscript
	var primary: int = int(cfg.get("primary", default_primary(cls)))
	if not (Weapon.is_variant(primary) and is_primary_allowed(cls, primary)):
		primary = default_primary(cls)
```
Leave `is_primary_allowed` itself archetype-based (it accepts base or variant ids by design — the client picker only ever passes variants; `sanitize` adds the `is_variant` gate).

**Test changes in `tests/loadout_config_test.gd`** (the file currently asserts the pre-variant identity behavior):

- Add registry bootstrap so every test sees the real catalog, order-independent:
```gdscript
func setup() -> void:
	Weapon.reset_registry()
	var res := Weapon.load_from_file("res://data/weapons.json")
	assert_true(res["ok"], "weapons.json loads: %s" % res.get("error", ""))

func teardown() -> void:
	Weapon.reset_registry()
```
- `test_primary_options_match_matrix`: rewrite to assert `primary_options(cls)` equals the concatenation of `Weapon.variants_of(a)` over `allowed_archetypes(cls)`, e.g.:
```gdscript
func test_primary_options_are_variants_of_allowed_archetypes() -> void:
	for c in ALL_CLASSES:
		var expected: Array = []
		for a in Loadout.allowed_archetypes(c):
			expected.append_array(Weapon.variants_of(a))
		assert_eq(Loadout.primary_options(c), expected, "class %d primary_options == concatenated variants" % c)
		assert_gt(Loadout.primary_options(c).size(), 0, "class %d has selectable variants" % c)
```
- DELETE `test_primary_options_equal_archetypes_pre_variants` (the seam-identity invariant it guards is intentionally gone).
- `test_default_primary_is_ar_for_all`: change to assert the default is an AR *variant* (the catalog's AR default), not the raw archetype id:
```gdscript
func test_default_primary_is_ar_variant_for_all() -> void:
	for c in ALL_CLASSES:
		assert_eq(Loadout.default_primary(c), Weapon.default_variant(Weapon.AR))
		assert_eq(Weapon.archetype_of(Loadout.default_primary(c)), Weapon.AR)
```
- `test_is_primary_allowed_enforces_locks`: ADD variant-id cases alongside the existing base-id cases (which still pass because base ids resolve to themselves):
```gdscript
	# variant ids gate by archetype exactly like base ids
	assert_true(Loadout.is_primary_allowed(Loadout.ASSAULT, 22), "Assault may take SVD-K (DMR variant)")
	assert_false(Loadout.is_primary_allowed(Loadout.MEDIC, 22), "Medic may not take a DMR variant")
	assert_true(Loadout.is_primary_allowed(Loadout.SUPPORT, 29), "Support may take PKP (LMG variant)")
	assert_false(Loadout.is_primary_allowed(Loadout.ASSAULT, 29), "only Support takes an LMG variant")
```
- `test_sanitize_is_idempotent`: change the raw `primary` from `Weapon.LMG` (a base id, now rejected by the `is_variant` gate) to a real LMG variant `29` (PKP). The rest of the assertion is unchanged (sanitize twice == once).
- `test_sanitize_rejects_illegal_primary`: change the illegal input to a real DMR variant `22` and assert the result is the class default variant:
```gdscript
func test_sanitize_rejects_illegal_primary() -> void:
	var out := Loadout.sanitize({"class": Loadout.MEDIC, "primary": 22}, _attach())
	assert_eq(int(out["primary"]), Loadout.default_primary(Loadout.MEDIC))
	assert_eq(Weapon.archetype_of(int(out["primary"])), Weapon.AR)
```
- ADD a test that a bare archetype id is rejected by the `is_variant` gate:
```gdscript
func test_sanitize_rejects_bare_archetype_primary() -> void:
	# a base archetype id (not a real variant) must normalize to the default variant
	var out := Loadout.sanitize({"class": Loadout.SUPPORT, "primary": Weapon.LMG}, _attach())
	assert_eq(int(out["primary"]), Loadout.default_primary(Loadout.SUPPORT))
	assert_true(Weapon.is_variant(int(out["primary"])), "sanitized primary is always a real variant")
```
- `test_sanitize_rpg_never_a_primary`: keep; `Weapon.RPG` (base id 3) is rejected both because it isn't a variant and because RPG isn't in any class's allowed archetypes. Assertion `!= Weapon.RPG` still holds.
- `test_default_loadout_is_self_consistent`: unchanged in intent but now depends on the loaded registry (the `setup()` above provides it). Verify it still passes.
- `test_trait_blurbs_mention_each_signature_perk`: unchanged (it asserts the "DMR"/"LMG" strings appear — they now come from the `allowed_archetypes` check). Verify Assault still yields "DMR" and Support still yields "LMG".

- [ ] **Step 1:** Update `tests/loadout_config_test.gd` per the changes above (tests first). Run the file's tests — expect failures on the seam-dependent assertions (primary_options, default_primary, sanitize) because `loadout.gd` isn't flipped yet.

Run: `godot --headless --path . -- --test --filter=loadout_config`
Expected: FAILs on primary/default/sanitize tests; blurb/trait tests may already pass.

- [ ] **Step 2:** Apply the five `loadout.gd` edits. Re-run the filtered tests — expect all green.

Run: `godot --headless --path . -- --test --filter=loadout_config`
Expected: PASS (all assertions, 0 failures).

- [ ] **Step 3:** Run the FULL suite to catch any other caller that assumed `primary_options`/`default_primary` returned archetype ids (esp. `tests/loadout_test.gd`, prediction/spawn tests). Fix any fallout **in the test only if it was asserting the old identity behavior**; if a non-test caller breaks, STOP and report (it means a real integration point needs P1b-2, not a test edit).

Run: `godot --headless --path . -- --test`
Expected: same green baseline as master (only the known pre-existing native-lib failures, if any). Report the exact pass/fail counts.

- [ ] **Step 4:** Commit.
```bash
git add shared/sim/loadout.gd tests/loadout_config_test.gd
git commit -m "feat(loadout): primary is a weapon-variant id (flip P1a seam onto the registry)"
```

---

## Not in this plan (P1b-2, next increment)

`SET_LOADOUT` wire message (VERSION 7→8, Msg=48), client send + server handler, per-connection loadout persistence, server applies the sanitized config at spawn (weapon/armor/gadget/mag/reserve/grenade-count), RPG-as-gadget rework, bots routed through the unified sanitized path, and the 128-bot fleet gate on `conquest_town`.
