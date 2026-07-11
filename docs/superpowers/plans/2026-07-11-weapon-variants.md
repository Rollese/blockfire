# Weapon Variants Implementation Plan

> **STATUS: ✅ COMPLETE (2026-07-11, on `origin/master`).** All 8 tasks implemented via
> subagent-driven development (spec + quality review per task, final holistic review). Task 7 (LMG
> variants) unblocked once the M19 loadout track merged its LMG archetype; integrated cleanly (zero
> conflicts — disjoint `weapon.gd` edits). Result: 17 named variants (ids 16–32), wire unchanged
> (`weapon` stays `u8`), full suite green modulo the pre-existing unbuilt-native-lib failures.
> One in-flight fix during Task 5: `Weapon.archetype_of` now maps base ids by enum membership (RPG
> had no `_DEFS` row). Integration smoke + fleet gate fold into the loadout track's P1 gate per spec §5.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn each weapon category into a set of named, mechanically-distinct variants (17 guns), selectable as ordinary weapon ids, driven by a new `data/weapons.json` catalog.

**Architecture:** Each named gun is its own `weapon_id` (int ≥ 16) tagged to an archetype, stored in `data/weapons.json` and loaded into a static registry on `Weapon`. The registry adds `archetype_of` / `variants_of` / `default_variant` / `display_name` / `is_variant` and extends `Weapon.get_def` to resolve variant ids. Every existing sim/HUD/art path already keys off `weapon_id` / `get_def`, so it resolves variants transparently. The wire is unchanged (weapon stays `u8`). The parallel **Class Select & Loadouts** agent owns weapon→class gating and the LMG archetype; this plan owns the variant registry + content (spec §4).

**Tech Stack:** Godot 4 / GDScript. JSON catalog loaded via `FileAccess.get_file_as_string` + `JSON.parse_string`, mirroring `shared/sim/attachment.gd`. Tests are `extends TestCase` (`tests/`).

**Spec:** `docs/superpowers/specs/2026-07-11-weapon-variants-design.md`

**Execution note:** Run this plan in an isolated git worktree (project practice — the main tree is shared with live agents). Create it via `superpowers:using-git-worktrees` before Task 1.

**Coordination gate:** Tasks 1–6 are independent of the loadout agent and can land now. **Task 7 (LMG variants) is BLOCKED** until the loadout agent's `LMG` archetype (`Weapon.LMG` enum + base `_DEFS` row + `suppression_mult` field on defs) is merged to master. Rebase before starting Task 7.

---

## File Structure

- **`data/weapons.json`** (create) — the variant catalog. Small-arms (AR/SMG/DMR/Pistol) in Task 3; LMG appended in Task 7.
- **`shared/sim/weapon.gd`** (modify) — add the static registry (`_VARIANTS`, `_BY_ARCHETYPE`), the loader (`load_from_dict`/`load_from_file`), the resolution API, and extend `get_def`. This is the only shared-sim file this plan modifies; the loadout agent edits a disjoint region (enum/`_DEFS`/`can_equip`), so keep additions grouped at the end of the file to minimize merge overlap.
- **`server/server_main.gd`** (modify) — load the catalog at boot; refuse to start on an invalid catalog.
- **`client/client_main.gd`** (modify) — load the catalog at client boot.
- **`client/art/weapon_kit.gd`** (modify) — resolve the viewmodel via `archetype_of(variant)`.
- **`client/hud/hud_model.gd`** (modify) — surface `display_name(weapon_id)` for the kill-feed / death-recap.
- **`tests/weapon_registry_test.gd`** (create) — loader + resolution API unit tests.
- **`tests/weapons_catalog_test.gd`** (create) — real-file well-formedness + roster-shape tests.

---

## Task 1: Registry loader + validation on `Weapon`

**Files:**
- Modify: `shared/sim/weapon.gd` (append after existing statics)
- Test: `tests/weapon_registry_test.gd` (create)

- [ ] **Step 1: Write the failing test**

Create `tests/weapon_registry_test.gd`:

```gdscript
extends TestCase

# A minimal in-memory catalog (two AR variants) so tests never touch the real file.
const _FIX := {"weapons": [
	{"id": 16, "key": "m4a2", "name": "M4A2", "archetype": "AR",
	 "damage_body": 24, "headshot_mult": 2.0, "rpm": 700, "mag_size": 30,
	 "reserve_ammo": 180, "reload_secs": 2.2, "spread_base_deg": 0.55,
	 "spread_bloom_deg": 0.5, "recoil_pitch_deg": 0.35, "range_m": 300.0,
	 "muzzle_velocity": 880.0, "gravity_scale": 0.5,
	 "fire_modes": ["AUTO", "SEMI", "BURST"], "burst_count": 3},
	{"id": 17, "key": "akm74", "name": "AKM-74", "archetype": "AR",
	 "damage_body": 30, "headshot_mult": 2.0, "rpm": 580, "mag_size": 30,
	 "reserve_ammo": 180, "reload_secs": 2.4, "spread_base_deg": 0.65,
	 "spread_bloom_deg": 0.5, "recoil_pitch_deg": 0.55, "range_m": 280.0,
	 "muzzle_velocity": 715.0, "gravity_scale": 0.5,
	 "fire_modes": ["AUTO", "SEMI"], "burst_count": 3},
]}

func test_load_ok_populates_registry() -> void:
	var res := Weapon.load_from_dict(_FIX)
	assert_true(res["ok"], "valid catalog loads: %s" % res["error"])
	var d := Weapon.get_def(16)
	assert_eq(int(d["damage_body"]), 24, "variant 16 damage")
	assert_eq(int(d["rpm"]), 700, "variant 16 rpm")

func test_fire_modes_parsed_to_ints() -> void:
	Weapon.load_from_dict(_FIX)
	var modes: Array = Weapon.get_def(16)["fire_modes"]
	assert_true(modes[0] is int, "fire_modes are ints after load")
	assert_eq(int(modes[0]), Weapon.MODE_AUTO, "AUTO string -> MODE_AUTO")

func test_reject_duplicate_id() -> void:
	var bad := {"weapons": [_FIX["weapons"][0], _FIX["weapons"][0]]}
	assert_false(Weapon.load_from_dict(bad)["ok"], "duplicate id rejected")

func test_reject_id_below_16() -> void:
	var e = _FIX["weapons"][0].duplicate(); e["id"] = 3
	assert_false(Weapon.load_from_dict({"weapons": [e]})["ok"], "id < 16 collides with archetype enum")

func test_reject_bad_archetype() -> void:
	var e = _FIX["weapons"][0].duplicate(); e["archetype"] = "BAZOOKA"
	assert_false(Weapon.load_from_dict({"weapons": [e]})["ok"], "unknown archetype rejected")

func test_reject_empty() -> void:
	assert_false(Weapon.load_from_dict({"weapons": []})["ok"], "empty catalog rejected")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=weapon_registry` (use this repo's test entrypoint; if unsure, run the full suite the same way the CI script `ci/*.sh` does).
Expected: FAIL — `Weapon.load_from_dict` does not exist.

- [ ] **Step 3: Implement the loader in `shared/sim/weapon.gd`**

Append to `shared/sim/weapon.gd` (after `effective_def`):

```gdscript
# --- Named-variant registry (data/weapons.json). Ids >= 16 so they never collide with the
# archetype enum (0..5). Loaded once at boot by server + client; tests load a fixture dict. ---
static var _VARIANTS: Dictionary = {}       # id(int) -> resolved def (fire_modes+archetype as ints)
static var _BY_ARCHETYPE: Dictionary = {}   # archetype(int) -> ordered Array[int] of variant ids

const _ARCH := {"AR": AR, "SMG": SMG, "DMR": DMR, "RPG": RPG, "PISTOL": PISTOL, "LMG": 5}
const _MODE := {"AUTO": MODE_AUTO, "SEMI": MODE_SEMI, "BURST": MODE_BURST}
const _FLOAT_FIELDS := ["headshot_mult", "reload_secs", "spread_base_deg", "spread_bloom_deg",
	"recoil_pitch_deg", "range_m", "muzzle_velocity", "gravity_scale"]

static func load_from_dict(data: Dictionary) -> Dictionary:
	var raw = data.get("weapons", [])
	if typeof(raw) != TYPE_ARRAY or raw.is_empty():
		return {"ok": false, "error": "weapons must be a non-empty array"}
	var variants := {}
	var by_arch := {}
	for w in raw:
		if not (w is Dictionary):
			return {"ok": false, "error": "each weapon must be an object"}
		var id := int(w.get("id", -1))
		if id < 16:
			return {"ok": false, "error": "weapon id must be an int >= 16 (got %d)" % id}
		if variants.has(id):
			return {"ok": false, "error": "duplicate weapon id %d" % id}
		var key := String(w.get("key", ""))
		if key == "":
			return {"ok": false, "error": "weapon %d missing key" % id}
		var arch_s := String(w.get("archetype", ""))
		if not _ARCH.has(arch_s):
			return {"ok": false, "error": "weapon %s: unknown archetype '%s'" % [key, arch_s]}
		var modes := []
		for m in w.get("fire_modes", []):
			if not _MODE.has(String(m)):
				return {"ok": false, "error": "weapon %s: bad fire mode '%s'" % [key, m]}
			modes.append(_MODE[String(m)])
		if modes.is_empty():
			return {"ok": false, "error": "weapon %s: fire_modes empty" % key}
		if int(w.get("mag_size", 0)) <= 0 or int(w.get("rpm", 0)) <= 0 \
				or float(w.get("range_m", 0.0)) <= 0.0 or float(w.get("muzzle_velocity", 0.0)) <= 0.0:
			return {"ok": false, "error": "weapon %s: mag_size/rpm/range/muzzle must be > 0" % key}
		var def := {
			"key": key, "name": String(w.get("name", key)), "archetype": int(_ARCH[arch_s]),
			"damage_body": int(w.get("damage_body", 0)), "rpm": int(w.get("rpm", 0)),
			"mag_size": int(w.get("mag_size", 0)), "reserve_ammo": int(w.get("reserve_ammo", 0)),
			"fire_modes": modes, "burst_count": int(w.get("burst_count", DEFAULT_BURST)),
			"suppression_mult": float(w.get("suppression_mult", 1.0)),
		}
		for f in _FLOAT_FIELDS:
			def[f] = float(w.get(f, 0.0))
		variants[id] = def
		var a := int(_ARCH[arch_s])
		if not by_arch.has(a):
			by_arch[a] = []
		by_arch[a].append(id)
	_VARIANTS = variants
	_BY_ARCHETYPE = by_arch
	return {"ok": true, "error": ""}

static func load_from_file(path := "res://data/weapons.json") -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		return {"ok": false, "error": "cannot read %s" % path}
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "error": "root of %s is not an object" % path}
	return load_from_dict(data)
```

- [ ] **Step 4: Extend `get_def` to resolve variant ids**

In `shared/sim/weapon.gd`, replace the existing `get_def`:

```gdscript
static func get_def(weapon_id: int) -> Dictionary:
	if _VARIANTS.has(weapon_id):
		return _VARIANTS[weapon_id]
	return _DEFS.get(weapon_id, _DEFS[AR])
```

- [ ] **Step 5: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=weapon_registry`
Expected: PASS (all 6 tests).

- [ ] **Step 6: Commit**

```bash
git add shared/sim/weapon.gd tests/weapon_registry_test.gd
git commit -m "feat(weapon): variant registry loader + validation over data/weapons.json"
```

---

## Task 2: Resolution API (`archetype_of` / `variants_of` / `default_variant` / `display_name` / `is_variant`)

**Files:**
- Modify: `shared/sim/weapon.gd`
- Test: `tests/weapon_registry_test.gd` (extend)

- [ ] **Step 1: Add the failing tests**

Append to `tests/weapon_registry_test.gd`:

```gdscript
func test_archetype_of() -> void:
	Weapon.load_from_dict(_FIX)
	assert_eq(Weapon.archetype_of(16), Weapon.AR, "variant -> its archetype")
	assert_eq(Weapon.archetype_of(Weapon.DMR), Weapon.DMR, "base id maps to itself")

func test_variants_of_default_first() -> void:
	Weapon.load_from_dict(_FIX)
	var ar := Weapon.variants_of(Weapon.AR)
	assert_eq(ar[0], 16, "catalog order: default (M4A2) first")
	assert_eq(Weapon.default_variant(Weapon.AR), 16, "default_variant == variants_of[0]")

func test_default_variant_degrades_when_empty() -> void:
	Weapon.load_from_dict(_FIX)
	# SMG has no variants in the fixture -> degrade to the archetype id.
	assert_true(Weapon.variants_of(Weapon.SMG).is_empty(), "no SMG variants loaded")
	assert_eq(Weapon.default_variant(Weapon.SMG), Weapon.SMG, "degrades to archetype default")

func test_is_variant_and_display_name() -> void:
	Weapon.load_from_dict(_FIX)
	assert_true(Weapon.is_variant(16), "16 is a variant")
	assert_false(Weapon.is_variant(Weapon.AR), "base id is not a variant")
	assert_eq(Weapon.display_name(17), "AKM-74", "variant display name")
```

- [ ] **Step 2: Run to verify failure**

Run: `godot --headless --path . -- --test --filter=weapon_registry`
Expected: FAIL — `archetype_of` undefined.

- [ ] **Step 3: Implement the API**

Append to `shared/sim/weapon.gd`:

```gdscript
static func is_variant(id: int) -> bool:
	return _VARIANTS.has(id)

static func archetype_of(id: int) -> int:
	if _VARIANTS.has(id):
		return int(_VARIANTS[id]["archetype"])
	if _DEFS.has(id):
		return id
	return AR

static func variants_of(archetype: int) -> Array:
	return _BY_ARCHETYPE.get(archetype, [])

static func default_variant(archetype: int) -> int:
	var v: Array = _BY_ARCHETYPE.get(archetype, [])
	return int(v[0]) if not v.is_empty() else archetype

static func display_name(id: int) -> String:
	if _VARIANTS.has(id):
		return String(_VARIANTS[id]["name"])
	return String(_DEFS.get(id, _DEFS[AR]).get("name", "?"))
```

- [ ] **Step 4: Run to verify pass**

Run: `godot --headless --path . -- --test --filter=weapon_registry`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/weapon.gd tests/weapon_registry_test.gd
git commit -m "feat(weapon): archetype_of/variants_of/default_variant/display_name/is_variant"
```

---

## Task 3: The catalog file + well-formedness & roster-shape tests

**Files:**
- Create: `data/weapons.json`
- Test: `tests/weapons_catalog_test.gd` (create)

- [ ] **Step 1: Create `data/weapons.json`** (13 small-arms variants; default listed first per category, lowest id in its block)

```json
{ "weapons": [
  { "id": 16, "key": "m4a2", "name": "M4A2", "archetype": "AR", "damage_body": 24, "headshot_mult": 2.0, "rpm": 700, "mag_size": 30, "reserve_ammo": 180, "reload_secs": 2.2, "spread_base_deg": 0.55, "spread_bloom_deg": 0.5, "recoil_pitch_deg": 0.35, "range_m": 300.0, "muzzle_velocity": 880.0, "gravity_scale": 0.5, "fire_modes": ["AUTO","SEMI","BURST"], "burst_count": 3 },
  { "id": 17, "key": "akm74", "name": "AKM-74", "archetype": "AR", "damage_body": 30, "headshot_mult": 2.0, "rpm": 580, "mag_size": 30, "reserve_ammo": 180, "reload_secs": 2.4, "spread_base_deg": 0.65, "spread_bloom_deg": 0.5, "recoil_pitch_deg": 0.55, "range_m": 280.0, "muzzle_velocity": 715.0, "gravity_scale": 0.5, "fire_modes": ["AUTO","SEMI"], "burst_count": 3 },
  { "id": 18, "key": "fl40", "name": "FL-40", "archetype": "AR", "damage_body": 40, "headshot_mult": 2.0, "rpm": 500, "mag_size": 20, "reserve_ammo": 160, "reload_secs": 2.5, "spread_base_deg": 0.50, "spread_bloom_deg": 0.5, "recoil_pitch_deg": 0.70, "range_m": 340.0, "muzzle_velocity": 840.0, "gravity_scale": 0.5, "fire_modes": ["SEMI","AUTO"], "burst_count": 3 },

  { "id": 19, "key": "mp5x", "name": "MP-5X", "archetype": "SMG", "damage_body": 20, "headshot_mult": 1.8, "rpm": 800, "mag_size": 30, "reserve_ammo": 210, "reload_secs": 2.0, "spread_base_deg": 0.80, "spread_bloom_deg": 0.6, "recoil_pitch_deg": 0.28, "range_m": 165.0, "muzzle_velocity": 400.0, "gravity_scale": 0.7, "fire_modes": ["AUTO","SEMI","BURST"], "burst_count": 3 },
  { "id": 20, "key": "skorpion61", "name": "Skorpion-61", "archetype": "SMG", "damage_body": 14, "headshot_mult": 1.8, "rpm": 860, "mag_size": 20, "reserve_ammo": 200, "reload_secs": 1.9, "spread_base_deg": 0.90, "spread_bloom_deg": 0.6, "recoil_pitch_deg": 0.20, "range_m": 100.0, "muzzle_velocity": 320.0, "gravity_scale": 0.7, "fire_modes": ["AUTO"], "burst_count": 3 },
  { "id": 21, "key": "uz9", "name": "UZ-9", "archetype": "SMG", "damage_body": 21, "headshot_mult": 1.8, "rpm": 1050, "mag_size": 25, "reserve_ammo": 200, "reload_secs": 2.0, "spread_base_deg": 1.05, "spread_bloom_deg": 0.6, "recoil_pitch_deg": 0.42, "range_m": 120.0, "muzzle_velocity": 400.0, "gravity_scale": 0.7, "fire_modes": ["AUTO","SEMI"], "burst_count": 3 },

  { "id": 22, "key": "svdk", "name": "SVD-K", "archetype": "DMR", "damage_body": 48, "headshot_mult": 2.0, "rpm": 240, "mag_size": 10, "reserve_ammo": 100, "reload_secs": 2.6, "spread_base_deg": 0.20, "spread_bloom_deg": 0.3, "recoil_pitch_deg": 0.85, "range_m": 480.0, "muzzle_velocity": 830.0, "gravity_scale": 0.35, "fire_modes": ["SEMI"], "burst_count": 1 },
  { "id": 23, "key": "sk45", "name": "SK-45", "archetype": "DMR", "damage_body": 42, "headshot_mult": 2.0, "rpm": 330, "mag_size": 10, "reserve_ammo": 100, "reload_secs": 2.4, "spread_base_deg": 0.22, "spread_bloom_deg": 0.3, "recoil_pitch_deg": 0.60, "range_m": 420.0, "muzzle_velocity": 735.0, "gravity_scale": 0.35, "fire_modes": ["SEMI"], "burst_count": 1 },
  { "id": 24, "key": "m14ebr", "name": "M14-EBR", "archetype": "DMR", "damage_body": 55, "headshot_mult": 2.0, "rpm": 220, "mag_size": 20, "reserve_ammo": 140, "reload_secs": 2.6, "spread_base_deg": 0.25, "spread_bloom_deg": 0.3, "recoil_pitch_deg": 1.00, "range_m": 500.0, "muzzle_velocity": 850.0, "gravity_scale": 0.35, "fire_modes": ["SEMI"], "burst_count": 1 },

  { "id": 25, "key": "m9", "name": "M9", "archetype": "PISTOL", "damage_body": 17, "headshot_mult": 1.9, "rpm": 450, "mag_size": 15, "reserve_ammo": 60, "reload_secs": 1.6, "spread_base_deg": 0.80, "spread_bloom_deg": 0.5, "recoil_pitch_deg": 0.45, "range_m": 75.0, "muzzle_velocity": 380.0, "gravity_scale": 0.8, "fire_modes": ["SEMI"], "burst_count": 1 },
  { "id": 26, "key": "gk18", "name": "GK-18", "archetype": "PISTOL", "damage_body": 15, "headshot_mult": 1.9, "rpm": 480, "mag_size": 17, "reserve_ammo": 68, "reload_secs": 1.6, "spread_base_deg": 0.85, "spread_bloom_deg": 0.5, "recoil_pitch_deg": 0.40, "range_m": 70.0, "muzzle_velocity": 375.0, "gravity_scale": 0.8, "fire_modes": ["SEMI"], "burst_count": 1 },
  { "id": 27, "key": "p229", "name": "P-229", "archetype": "PISTOL", "damage_body": 18, "headshot_mult": 1.9, "rpm": 430, "mag_size": 15, "reserve_ammo": 60, "reload_secs": 1.7, "spread_base_deg": 0.60, "spread_bloom_deg": 0.5, "recoil_pitch_deg": 0.40, "range_m": 85.0, "muzzle_velocity": 390.0, "gravity_scale": 0.8, "fire_modes": ["SEMI"], "burst_count": 1 },
  { "id": 28, "key": "d50", "name": "D-50 Hawk", "archetype": "PISTOL", "damage_body": 40, "headshot_mult": 1.9, "rpm": 250, "mag_size": 7, "reserve_ammo": 42, "reload_secs": 2.0, "spread_base_deg": 0.70, "spread_bloom_deg": 0.5, "recoil_pitch_deg": 0.90, "range_m": 90.0, "muzzle_velocity": 470.0, "gravity_scale": 0.8, "fire_modes": ["SEMI"], "burst_count": 1 }
] }
```

- [ ] **Step 2: Write the catalog tests**

Create `tests/weapons_catalog_test.gd`:

```gdscript
extends TestCase

func _load() -> void:
	var res := Weapon.load_from_file("res://data/weapons.json")
	assert_true(res["ok"], "real catalog loads: %s" % res["error"])

func _by_key(archetype: int) -> Dictionary:
	var m := {}
	for id in Weapon.variants_of(archetype):
		m[String(Weapon.get_def(id)["key"])] = Weapon.get_def(id)
	return m

func test_catalog_wellformed() -> void:
	_load()
	var seen := {}
	for arch in [Weapon.AR, Weapon.SMG, Weapon.DMR, Weapon.PISTOL]:
		var ids := Weapon.variants_of(arch)
		assert_true(ids.size() >= 3, "archetype %d has >=3 variants" % arch)
		for id in ids:
			assert_true(int(id) >= 16, "id >= 16")
			assert_false(seen.has(id), "unique id %d" % id)
			seen[id] = true
			assert_eq(Weapon.archetype_of(id), arch, "id %d resolves to its archetype" % id)

func test_defaults_are_first() -> void:
	_load()
	assert_eq(String(Weapon.get_def(Weapon.default_variant(Weapon.AR))["key"]), "m4a2", "AR default")
	assert_eq(String(Weapon.get_def(Weapon.default_variant(Weapon.SMG))["key"]), "mp5x", "SMG default")
	assert_eq(String(Weapon.get_def(Weapon.default_variant(Weapon.DMR))["key"]), "svdk", "DMR default")
	assert_eq(String(Weapon.get_def(Weapon.default_variant(Weapon.PISTOL))["key"]), "m9", "Pistol default")

func test_ar_role_axis() -> void:
	_load()
	var ar := _by_key(Weapon.AR)
	assert_true(int(ar["m4a2"]["damage_body"]) < int(ar["akm74"]["damage_body"]), "AR dmg M4<AK")
	assert_true(int(ar["akm74"]["damage_body"]) < int(ar["fl40"]["damage_body"]), "AR dmg AK<FAL")
	assert_true(int(ar["m4a2"]["rpm"]) > int(ar["akm74"]["rpm"]), "AR rpm M4>AK")
	assert_true(int(ar["akm74"]["rpm"]) > int(ar["fl40"]["rpm"]), "AR rpm AK>FAL")

func test_smg_role_axis() -> void:
	_load()
	var s := _by_key(Weapon.SMG)
	assert_true(int(s["uz9"]["rpm"]) > int(s["skorpion61"]["rpm"]), "SMG UZ fastest > Skorpion")
	assert_true(int(s["skorpion61"]["rpm"]) > int(s["mp5x"]["rpm"]), "Skorpion > MP5")
	assert_true(int(s["skorpion61"]["damage_body"]) < int(s["mp5x"]["damage_body"]), "Skorpion lowest dmg")

func test_dmr_role_axis() -> void:
	_load()
	var d := _by_key(Weapon.DMR)
	assert_true(int(d["sk45"]["rpm"]) > int(d["svdk"]["rpm"]), "DMR SK fastest")
	assert_true(int(d["svdk"]["rpm"]) > int(d["m14ebr"]["rpm"]), "DMR SVD > Mk14")
	assert_true(int(d["sk45"]["damage_body"]) < int(d["m14ebr"]["damage_body"]), "DMR SK < Mk14 dmg")

func test_pistol_role_axis() -> void:
	_load()
	var p := _by_key(Weapon.PISTOL)
	assert_eq(int(p["d50"]["mag_size"]), 7, "Deagle smallest mag")
	assert_true(int(p["d50"]["damage_body"]) > int(p["p229"]["damage_body"]), "Deagle hand-cannon dmg")

func test_effective_def_applies_to_variant() -> void:
	# effective_def duplicates get_def(id) and applies attachment multipliers; it must work on a
	# variant id (attachment compatibility is category-level, resolved via archetype elsewhere).
	_load()
	var base := Weapon.get_def(18)   # FL-40 (AR variant), spread_base 0.50
	var eff := Weapon.effective_def(18, {"spread_mult": 0.5, "recoil_mult": 1.0, "range_mult": 1.0})
	assert_almost_eq(float(eff["spread_base_deg"]), float(base["spread_base_deg"]) * 0.5, 0.0001, "spread mult applied to variant")
	assert_eq(int(eff["damage_body"]), int(base["damage_body"]), "damage untouched by these mults")
```

- [ ] **Step 3: Run the tests**

Run: `godot --headless --path . -- --test --filter=weapons_catalog`
Expected: PASS (all 7).

- [ ] **Step 4: Commit**

```bash
git add data/weapons.json tests/weapons_catalog_test.gd
git commit -m "feat(weapon): add 13 small-arms variants (AR/SMG/DMR/Pistol) + catalog tests"
```

---

## Task 4: Load the catalog at boot (server + client)

**Files:**
- Modify: `server/server_main.gd` (const block near line 72; `_ready` near line 236)
- Modify: `client/client_main.gd`

- [ ] **Step 1: Add the const + load-or-quit in the server**

In `server/server_main.gd`, add beside `ATTACHMENTS_PATH` (line ~73):

```gdscript
const WEAPONS_PATH := "res://data/weapons.json"
```

In `_ready`, immediately after the attachments load block (after line ~238), add:

```gdscript
	var wres := Weapon.load_from_file(WEAPONS_PATH)
	if not wres["ok"]:
		push_error("[server] failed to load weapons %s: %s" % [WEAPONS_PATH, wres["error"]]); get_tree().quit(1); return
```

- [ ] **Step 2: Load in the client**

`client/client_main.gd` already loads catalogs in `_ready` (`MapDef.load_file` @243, `PieceCatalog.load_file` @256, `_acat.load_from("res://data/sounds.json")` @1625). Add the weapon load right after the `PieceCatalog` load (~line 256):

```gdscript
	var wres := Weapon.load_from_file("res://data/weapons.json")
	if not wres["ok"]:
		push_error("[client] failed to load weapons: %s" % wres["error"])
```

The client only `push_error`s (doesn't quit) — a client with a bad catalog still renders via the archetype fallback in `get_def`; the authoritative server is the one that refuses to start.

- [ ] **Step 3: Verify the server boots with the catalog**

Run the server smoke the way CI does (e.g. `bash ci/smoke.sh` or the project's headless server launch). 
Expected: server starts; log shows no `failed to load weapons`. Temporarily rename `data/weapons.json` and confirm the server exits with the weapons error, then restore it.

- [ ] **Step 4: Commit**

```bash
git add server/server_main.gd client/client_main.gd
git commit -m "feat(weapon): load data/weapons.json at server+client boot (refuse invalid on server)"
```

---

## Task 5: Resolve the viewmodel via `archetype_of`

**Files:**
- Modify: `client/art/weapon_kit.gd:14-15`
- Test: `tests/art_weapon_kit_test.gd` (extend — this test file already exists)

- [ ] **Step 1: Write the failing test**

Append to `tests/art_weapon_kit_test.gd`. Use a **non-AR** variant (id 22 = SVD-K, a DMR) so the test actually fails before the fix: today `build(22)` hits `_SPEC.get(22, _SPEC[Weapon.AR])` → the AR fallback (barrel 0.35), which is *wrong* for a DMR (barrel 0.55). After the fix it resolves to the DMR spec. `_SPEC` distinguishes AR vs DMR by barrel length, so the model's `aabb` z-length differs:

```gdscript
func test_variant_uses_archetype_viewmodel() -> void:
	Weapon.load_from_file("res://data/weapons.json")
	var svdk_len := WeaponKit.aabb(autofree(WeaponKit.build(22))).size.z   # DMR variant
	var dmr_len := WeaponKit.aabb(autofree(WeaponKit.build(Weapon.DMR))).size.z
	var ar_len := WeaponKit.aabb(autofree(WeaponKit.build(Weapon.AR))).size.z
	assert_almost_eq(svdk_len, dmr_len, 0.001, "DMR variant builds the DMR viewmodel")
	assert_true(absf(svdk_len - ar_len) > 0.001, "DMR variant is NOT the AR fallback")
```

- [ ] **Step 2: Run to verify failure**

Run: `godot --headless --path . -- --test --filter=art_weapon_kit`
Expected: FAIL — before the fix `build(22)` uses the AR fallback, so `svdk_len == ar_len` and the DMR assertion fails.

- [ ] **Step 3: Route through `archetype_of`**

In `client/art/weapon_kit.gd`, change line 15:

```gdscript
	var spec: Dictionary = _SPEC.get(Weapon.archetype_of(weapon_id), _SPEC[Weapon.AR])
```

- [ ] **Step 4: Run to verify pass**

Run: `godot --headless --path . -- --test --filter=art_weapon_kit`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add client/art/weapon_kit.gd tests/art_weapon_kit_test.gd
git commit -m "feat(weapon): viewmodel resolves variant -> archetype via archetype_of"
```

---

## Task 6: Kill-feed / death-recap show the real gun name

**Files:**
- Modify: `client/hud/hud_model.gd`

- [ ] **Step 1: Locate where the kill-feed and death-recap turn a weapon id into text**

Run: `grep -n "killfeed\|weapon\|display" client/hud/hud_model.gd`
The kill-feed entries store `weapon` as an int (line ~41); the death-recap builds a dict with `weapon` (line ~336). Find where these are rendered to a label (the HUD *view*, likely `client/hud/`), then:

Run: `grep -rn "killfeed\|death_info\|\"weapon\"" client/hud/`

- [ ] **Step 2: Use `Weapon.display_name` at the render site**

At the render site, replace the weapon-label source with:

```gdscript
	var weapon_label := Weapon.display_name(int(entry["weapon"]))
```

and use `weapon_label` where the feed/recap prints the weapon. If the current HUD does not render a weapon name at all, add it to the kill-feed row using `Weapon.display_name`.

- [ ] **Step 3: Manual verify**

Launch a local match (server + client) per the playtest runbook; get a kill and confirm the feed names the equipped variant (e.g. "AKM-74"), and the death recap shows the killer's gun name.

- [ ] **Step 4: Commit**

```bash
git add client/hud/
git commit -m "feat(hud): kill-feed and death-recap show the variant display name"
```

---

## Task 7: LMG variants — BLOCKED on the loadout agent's LMG archetype

> **Do not start until** `Weapon.LMG` (enum), the base LMG `_DEFS` row, and the `suppression_mult` field on defs are merged to master. Rebase this worktree onto master first. Confirm with: `grep -n "LMG" shared/sim/weapon.gd` (expect the enum entry) before proceeding.

**Files:**
- Modify: `data/weapons.json` (append 4 LMG entries)
- Test: `tests/weapons_catalog_test.gd` (extend)

- [ ] **Step 1: Append the LMG variants to `data/weapons.json`** (default PKP first; ids 29–32)

Add these objects to the `weapons` array (align `suppression_mult`/base numbers with the loadout agent's finalized LMG archetype):

```json
  { "id": 29, "key": "pkp", "name": "PKP", "archetype": "LMG", "damage_body": 30, "headshot_mult": 1.9, "rpm": 700, "mag_size": 100, "reserve_ammo": 400, "reload_secs": 5.5, "spread_base_deg": 0.85, "spread_bloom_deg": 0.7, "recoil_pitch_deg": 0.65, "range_m": 300.0, "muzzle_velocity": 800.0, "gravity_scale": 0.5, "suppression_mult": 1.40, "fire_modes": ["AUTO"], "burst_count": 3 },
  { "id": 30, "key": "m250", "name": "M250", "archetype": "LMG", "damage_body": 32, "headshot_mult": 1.9, "rpm": 650, "mag_size": 100, "reserve_ammo": 400, "reload_secs": 6.0, "spread_base_deg": 0.90, "spread_bloom_deg": 0.7, "recoil_pitch_deg": 0.70, "range_m": 320.0, "muzzle_velocity": 800.0, "gravity_scale": 0.5, "suppression_mult": 1.50, "fire_modes": ["AUTO"], "burst_count": 3 },
  { "id": 31, "key": "l7a3", "name": "L7A3", "archetype": "LMG", "damage_body": 30, "headshot_mult": 1.9, "rpm": 750, "mag_size": 100, "reserve_ammo": 400, "reload_secs": 5.5, "spread_base_deg": 0.80, "spread_bloom_deg": 0.7, "recoil_pitch_deg": 0.60, "range_m": 300.0, "muzzle_velocity": 800.0, "gravity_scale": 0.5, "suppression_mult": 1.35, "fire_modes": ["AUTO"], "burst_count": 3 },
  { "id": 32, "key": "m245", "name": "M245 SAW", "archetype": "LMG", "damage_body": 24, "headshot_mult": 1.9, "rpm": 800, "mag_size": 100, "reserve_ammo": 400, "reload_secs": 5.0, "spread_base_deg": 0.75, "spread_bloom_deg": 0.7, "recoil_pitch_deg": 0.50, "range_m": 260.0, "muzzle_velocity": 850.0, "gravity_scale": 0.5, "suppression_mult": 1.25, "fire_modes": ["AUTO"], "burst_count": 3 }
```

- [ ] **Step 2: Add the LMG test**

Append to `tests/weapons_catalog_test.gd`:

```gdscript
func test_lmg_variants() -> void:
	_load()
	var ids := Weapon.variants_of(Weapon.LMG)
	assert_true(ids.size() >= 3, "LMG has >=3 variants")
	assert_eq(String(Weapon.get_def(Weapon.default_variant(Weapon.LMG))["key"]), "pkp", "LMG default PKP")
	for id in ids:
		assert_eq(Weapon.archetype_of(id), Weapon.LMG, "id %d is an LMG" % id)
		assert_true(float(Weapon.get_def(id)["suppression_mult"]) > 1.0, "LMG suppresses harder")
	var l := _by_key(Weapon.LMG)
	assert_true(int(l["m245"]["rpm"]) > int(l["m250"]["rpm"]), "SAW faster than M240")
	assert_true(int(l["m250"]["damage_body"]) > int(l["m245"]["damage_body"]), "M240 hits harder than SAW")
```

- [ ] **Step 3: Run the catalog tests**

Run: `godot --headless --path . -- --test --filter=weapons_catalog`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add data/weapons.json tests/weapons_catalog_test.gd
git commit -m "feat(weapon): add 4 LMG variants (PKP/M250/L7A3/M245 SAW) on the loadout LMG archetype"
```

---

## Task 8: Full-suite regression + integration check

**Files:** none (verification only)

- [ ] **Step 1: Run the entire unit suite**

Run the full test suite the way CI does (`ci/*.sh` or the project's headless test entrypoint).
Expected: all green, including pre-existing `combat_test`, `art_weapon_kit_test`, `server_reserve_ammo_test` (these exercise `Weapon.get_def` and must be unaffected by the registry).

- [ ] **Step 2: Local integration smoke**

Launch server + one client (playtest runbook). Deploy with a non-default variant primary (drive via the loadout agent's `--loadout=` debug arg if merged, else temporarily set a bot/spawn to a variant id), fire and reload, and confirm: correct mag size + reserve behavior, kill-feed names the variant, ENTER-snapshot silhouette renders. No errors in the server/client logs.

- [ ] **Step 3: Confirm no wire change**

Confirm the `weapon` field is still `u8` on every path (no protocol VERSION bump from this plan): `grep -n "weapon" shared/net/protocol.gd shared/net/snapshot.gd` — the encode/decode remain `put_u8`/`get_u8`. This is an assertion, not a change.

- [ ] **Step 4: Fleet gate (folds into the loadout agent's P1)**

Per the spec, this plan does not carry its own 128-bot gate — variant coverage folds into the loadout agent's P1 fleet gate on `game2` (which exercises every class × weapon). Once both tracks are merged, confirm at that gate: variant ids flow through snapshot / kill-feed / self-state at 30 Hz with zero bandwidth change and no tick-budget regression (registry lookups are O(1) dict reads). No separate gate run is owned by this plan.

---

## Post-plan / deferred (not in this plan)

- **Weapon→class gating, `primary_options`, `sanitize`, class-select screen** — owned by the loadout agent (spec §4; API contract already handed off).
- **Per-gun viewmodels / muzzle-flash / audio** — art-pipeline track (variants share archetype art here).
- **Per-gun attachment trees, unlocks/progression** — later gameplay pass.
- **Bot variant selection** — the loadout agent's `bot_loadout` picks variants via `Weapon.variants_of`; this plan only provides the pool.
