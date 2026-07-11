# M7 P2 — Procedural Low-Poly Art Kit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the client's placeholder primitives with a **procedurally-generated, in-code low-poly blocky kit** — player characters, weapons, the transport vehicle, fortification structures (with damage-state tinting), and a handful of map props — authored entirely in GDScript so an agentic worker can build and test them without a DCC tool (Blender), then wire them into the renderer behind its existing seams.

> **SUPERSEDED (character only), 2026-06-18:** The player **character** is now an imported animated GLB model — see `docs/plans/2026-06-18-m7-p2-glb-characters.md`. Weapons, vehicles, structures, and props remain procedural per this plan. The "No external meshes / No animation" scope below applies to those remaining categories only.

**Architecture:** Each asset category is a **standalone `class_name` factory** under `client/art/` that builds a composite of primitive `BoxMesh`/`CapsuleMesh`/`CylinderMesh` children parented under one `Node3D` and returns it — the "blocky kit" aesthetic *is* welded boxes. A single `ArtPalette` is the one source of truth for materials/tints so every piece matches. Factories are **presentation-only** (no gameplay/authority logic, AGENTS.md §7) and sized to the sim's real dimensions (`Stance.body_height`, `vehicles.json`, `PieceCatalog`). Geometry is deterministic, so **headless tests assert mesh structure** (child parts, sizes, positions, material tint); **visual quality is the owner's playtest** (AGENTS.md §10). Tasks 0–6 add **only new files** and standalone preview scenes — zero edits to any file the in-flight M7-C3 work owns. **Task 7 (renderer integration) is the sole file that touches C3-owned code and is gated on C3 merging first.**

**Tech Stack:** Godot 4.6 / GDScript. Tests: `godot --headless --path . -- --test [--filter=<substr>]`, classes extend the global `TestCase` (`tests/*_test.gd`).

## Why this is safe to run concurrently with M7-C3

M7-C3 (combat-depth UI, branch `m7-rendered-client`) owns these files: `shared/net/protocol.gd`, `shared/sim/deploy_spawn.gd`, `shared/sim/death_recap.gd`, `client/hud/*`, `client/world_view.gd`, **`client/world_renderer.gd`**, `client/menus/deploy_menu.gd`, `client/client_main.gd`, `server/server_main.gd`, `project.godot`, `tests/*` (C3's own test files).

This plan touches **none of them** in Tasks 0–6:
- All kit code lands under a new `client/art/` dir; all assets under `assets/`; all tests are new `tests/art_*_test.gd` files.
- Preview scenes run **standalone** (`godot --path . client/art/preview/<x>.tscn`) with their own camera + light, so they need **no autoload and no `project.godot` edit**.
- No wire messages, no `project.godot` input actions, no protocol enum values.

**The only collision point** is `client/world_renderer.gd` (Task 7), which C3 modifies to render structures. Task 7 is therefore **deferred until C3 is merged** and is scoped to that one file. Run Tasks 0–6 now, in this worktree, on a branch off the `m7-rendered-client` line (P2 builds on the P1 client, so the worktree must contain `client/world_renderer.gd`, `client/client.tscn`, `shared/sim/stance.gd`, etc.).

## GDScript / Godot gotchas (every task)
- After adding any new `class_name` script, run **`godot --headless --path . --import`** once before tests (don't pipe `godot` through `tail`/`head`; redirect to a file if needed).
- GDScript 4.6 rejects `var x := <Dictionary access>` (Variant) — annotate the type explicitly; don't change logic.
- The harness **fails any test that runs zero assertions** (catches compile-error false-passes), so every test must assert.
- Reading geometry headlessly: `MeshInstance3D.mesh.get_aabb()` and the primitive `.size`/`.height`/`.radius` properties are available with no rendering context — that is what the tests assert against. Do **not** assert on rendered pixels in headless tests.
- `git add -A` to include Godot `.uid` sidecars in commits. Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## Sim dimensions the kit must match (read-only references — do not edit these)
- `shared/sim/stance.gd`: `BODY_RADIUS = 0.35`, `HEAD_RADIUS = 0.15`; `body_height(STAND)=1.8`-class (STAND value in `body_height`), `CROUCH=1.2`, `PRONE=0.5`. The current renderer capsule is `radius 0.3, height 1.0` scaled per-frame to `body_height`.
- `client/world_renderer.gd`: `TEAM_COLOR = [Color(0.2,0.5,1.0) /*blue t0*/, Color(1.0,0.3,0.2) /*red t1*/]`, `NEUTRAL_COLOR = Color(0.6,0.6,0.6)`. Entity local **+Z is forward** (a box at +Z reads as the gun/aim direction). Mesh seams: `_make_entity_mesh()`, `_make_box_mesh()`, `_make_cylinder_marker()`.
- `shared/sim/weapon.gd`: `enum { AR=0, SMG=1, DMR=2, RPG=3 }`.
- `data/vehicles.json`: one vehicle `transport`, `turret_offset [0,2.2,0]`, 5 seats, hull ~ driver/passenger offsets within ±2.5 m.
- `pieces/fortifications.json`: `sandbag` (height `half`, hp 150, material METAL_THIN), `wall` (height `full`, hp 350, material CONCRETE). `StructureStore.bucket_of(health,max)` → 3 pristine (>0.75) / 2 (>0.50) / 1 (>0.25) / 0 heavy.

## Out of scope (explicit — do not silently expand)
- **No Blender / external meshes / GLTF import.** Everything is procedural GDScript primitives.
- **No mesh welding into a single `ArrayMesh`, no LOD, no draw-call batching** — composite-of-boxes is intentional for placeholder-grade blocky art; LOD/batching is a later P2 task tracked separately.
- **No animation** (idle/walk/recoil) — static poses only; animation is a later P2 task.
- **No VFX/audio** (tracers stay the C1 cosmetic beam; muzzle flash, suppression, flashbang, SFX are separate P2 tracks).
- **No renderer wiring until Task 7**, which is gated on C3 merge.

## File map

| File | Create/Modify | Responsibility |
|---|---|---|
| `assets/README.md` | Create | Document that the kit is code-generated; conventions. |
| `client/art/art_palette.gd` | Create | Single source of truth for materials: team tints, neutral, weapon-metal, structure materials, damage-bucket tints. |
| `client/art/character_kit.gd` | Create | Blocky soldier (head/torso/arms/legs/helmet + gun mount), team-tinted, built at STAND height, +Z forward. |
| `client/art/weapon_kit.gd` | Create | Per-weapon blocky silhouette (AR/SMG/DMR/RPG), usable as viewmodel + world model. |
| `client/art/vehicle_kit.gd` | Create | `transport` hull + 4 wheels + turret at `turret_offset`, team-tinted. |
| `client/art/structure_kit.gd` | Create | `sandbag`/`wall` blocky meshes with per-damage-bucket tint. |
| `client/art/prop_kit.gd` | Create | Map set-dressing props (crate, barrel, barrier). |
| `client/art/preview/*.tscn` + `preview_driver.gd` | Create | Standalone runnable scenes that lay out every variant for the owner's visual sign-off. |
| `tests/art_*_test.gd` | Create | One headless structure test per factory. |
| `client/world_renderer.gd` | **Modify (Task 7 only, post-C3)** | Delegate `_make_entity_mesh()`/structure/vehicle drawing to the kits behind the existing seams. |

---

# Part 1 — Palette + kit factories (TDD, all new files)

### Task 0: Asset scaffold + `ArtPalette` materials

**Files:**
- Create: `assets/README.md`
- Create: `client/art/art_palette.gd`
- Test: `tests/art_palette_test.gd`

- [ ] **Step 1: Write the failing test** — `tests/art_palette_test.gd`:

```gdscript
extends TestCase

func test_team_materials_are_distinct_and_tinted() -> void:
	var m0 := ArtPalette.team_material(0)
	var m1 := ArtPalette.team_material(1)
	assert_true(m0 is StandardMaterial3D, "returns a StandardMaterial3D")
	assert_eq(m0.albedo_color, Color(0.2, 0.5, 1.0), "team 0 == renderer blue")
	assert_eq(m1.albedo_color, Color(1.0, 0.3, 0.2), "team 1 == renderer red")
	assert_true(m0.albedo_color != m1.albedo_color, "teams visually distinct")

func test_damage_tint_darkens_as_bucket_drops() -> void:
	var base := Color(0.7, 0.7, 0.7)
	var pristine := ArtPalette.damage_tint(base, 3)
	var heavy := ArtPalette.damage_tint(base, 0)
	assert_eq(pristine, base, "bucket 3 (pristine) is untinted")
	assert_true(heavy.v < pristine.v, "bucket 0 (heavy) is darker")

func test_unknown_team_falls_back_to_neutral() -> void:
	assert_eq(ArtPalette.team_material(99).albedo_color, Color(0.6, 0.6, 0.6), "neutral fallback")
```

- [ ] **Step 2: Run, verify fail** — `godot --headless --path . --import` then `godot --headless --path . -- --test --filter=art_palette`. Expected: FAIL (`ArtPalette` not found).

- [ ] **Step 3: Implement** — `client/art/art_palette.gd`:

```gdscript
class_name ArtPalette
extends Object
## Single source of truth for the procedural art kit's materials and tints. Presentation-only
## (AGENTS.md §7). Colors mirror world_renderer.TEAM_COLOR so kit + placeholder match during the
## P2 swap. Low-poly look: high roughness, no metallic, flat-ish shading.

const TEAM_COLOR := [Color(0.2, 0.5, 1.0), Color(1.0, 0.3, 0.2)]  # [team0=blue, team1=red]
const NEUTRAL := Color(0.6, 0.6, 0.6)
const GUN_METAL := Color(0.08, 0.08, 0.08)
const STRUCT_CONCRETE := Color(0.62, 0.62, 0.60)
const STRUCT_METAL_THIN := Color(0.45, 0.40, 0.30)

static func _flat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.95
	m.metallic = 0.0
	return m

static func team_material(team: int) -> StandardMaterial3D:
	if team < 0 or team >= TEAM_COLOR.size():
		return _flat(NEUTRAL)
	return _flat(TEAM_COLOR[team])

static func gun_material() -> StandardMaterial3D:
	return _flat(GUN_METAL)

static func structure_material(material_tag_color: Color, bucket: int) -> StandardMaterial3D:
	return _flat(damage_tint(material_tag_color, bucket))

## Darken a base color as the damage bucket drops (3 pristine .. 0 heavy). Pure.
static func damage_tint(base: Color, bucket: int) -> Color:
	var factor := [0.45, 0.65, 0.82, 1.0][clampi(bucket, 0, 3)]
	return Color(base.r * factor, base.g * factor, base.b * factor, base.a)
```

- [ ] **Step 4: Run, verify pass** — `godot --headless --path . -- --test --filter=art_palette`.

- [ ] **Step 5: Create `assets/README.md`:**

```markdown
# Assets

The M7 art kit is **procedurally generated in GDScript** (`client/art/*_kit.gd`), not authored
in a DCC tool. There are intentionally no `.glb`/`.obj` files here — the low-poly blocky look is
welded primitive boxes built at runtime, sized to the sim's real dimensions. Visual sign-off is
the owner's playtest of the preview scenes (`client/art/preview/`); geometry is unit-tested
headlessly. See `docs/plans/2026-06-17-m7-p2-art-kit-procedural.md`.
```

- [ ] **Step 6: Commit** — `git add -A && git commit` → `feat(m7-p2): ArtPalette materials + asset kit scaffold`.

---

### Task 1: `CharacterKit` — blocky soldier

**Files:**
- Create: `client/art/character_kit.gd`
- Test: `tests/art_character_kit_test.gd`

The renderer scales the entity root vertically per-frame to `Stance.body_height` (crouch/prone squash). So the kit builds **at STAND height** and exposes `STAND_HEIGHT` so the renderer can compute the scale ratio. Parts are named children so the renderer/tests can find them; the gun mount sits at **+Z** to preserve aim readability (matches the current capsule's gun box).

- [ ] **Step 1: Write the failing test** — `tests/art_character_kit_test.gd`:

```gdscript
extends TestCase

func test_builds_named_body_parts_team_tinted() -> void:
	var soldier := CharacterKit.build(0)
	assert_true(soldier is Node3D, "returns a Node3D root")
	assert_true(soldier.has_node("Torso"), "has a torso")
	assert_true(soldier.has_node("Head"), "has a head")
	assert_true(soldier.has_node("GunMount"), "has the aim-direction gun mount")
	var torso := soldier.get_node("Torso") as MeshInstance3D
	assert_eq((torso.material_override as StandardMaterial3D).albedo_color, Color(0.2, 0.5, 1.0),
		"team 0 tint applied to body")

func test_stand_height_matches_sim_body_height() -> void:
	assert_almost_eq(CharacterKit.STAND_HEIGHT, Stance.body_height(Stance.STAND), 0.01,
		"kit built to the sim's standing body height so renderer scaling stays 1.0 at STAND")
	var soldier := CharacterKit.build(1)
	var aabb := CharacterKit.aabb(soldier)
	assert_almost_eq(aabb.size.y, CharacterKit.STAND_HEIGHT, 0.05, "overall height == STAND_HEIGHT")

func test_gun_mount_points_forward_plus_z() -> void:
	var soldier := CharacterKit.build(0)
	var gun := soldier.get_node("GunMount") as Node3D
	assert_true(gun.position.z > 0.0, "gun mount sits at +Z (forward / aim direction)")
```

- [ ] **Step 2: Run, verify fail** (import first). Expected: FAIL (`CharacterKit` not found).

- [ ] **Step 3: Implement** — `client/art/character_kit.gd`:

```gdscript
class_name CharacterKit
extends Object
## Procedural blocky soldier. Presentation-only. Built at STAND height; the renderer scales the
## root vertically to Stance.body_height each frame. Local +Z is forward (gun mount + aim).

const STAND_HEIGHT := 1.8   # must track Stance.body_height(STAND)

static func build(team: int) -> Node3D:
	var root := Node3D.new()
	var mat := ArtPalette.team_material(team)
	var dark := ArtPalette.gun_material()

	var legs := _box("Legs", Vector3(0.5, 0.8, 0.3), Vector3(0.0, 0.4, 0.0), mat)
	root.add_child(legs)
	var torso := _box("Torso", Vector3(0.55, 0.6, 0.35), Vector3(0.0, 1.1, 0.0), mat)
	root.add_child(torso)
	var arm_l := _box("ArmL", Vector3(0.16, 0.55, 0.16), Vector3(-0.36, 1.1, 0.0), mat)
	root.add_child(arm_l)
	var arm_r := _box("ArmR", Vector3(0.16, 0.55, 0.16), Vector3(0.36, 1.1, 0.0), mat)
	root.add_child(arm_r)
	var head := _box("Head", Vector3(0.28, 0.28, 0.28), Vector3(0.0, 1.55, 0.0), mat)
	root.add_child(head)
	var helmet := _box("Helmet", Vector3(0.32, 0.12, 0.32), Vector3(0.0, 1.72, 0.0), dark)
	root.add_child(helmet)
	# Gun mount: short box at +Z, chest height, right side — same convention as the capsule's barrel.
	var gun := _box("GunMount", Vector3(0.08, 0.08, 0.6), Vector3(0.22, 1.15, 0.45), dark)
	root.add_child(gun)
	return root

static func _box(name: String, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	return mi

## Union AABB of all MeshInstance3D children (local space). Headless-safe (geometry only).
static func aabb(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for child in root.get_children():
		if child is MeshInstance3D:
			var box: AABB = (child as MeshInstance3D).mesh.get_aabb()
			box.position += (child as MeshInstance3D).position
			if first:
				out = box; first = false
			else:
				out = out.merge(box)
	return out
```

- [ ] **Step 4: Run, verify pass** — `--filter=art_character_kit`. (If `STAND_HEIGHT` ≠ `Stance.body_height(STAND)`, set the const to the sim value — don't change the sim.)

- [ ] **Step 5: Commit** — `feat(m7-p2): CharacterKit blocky soldier (team-tinted, +Z aim mount)`.

---

### Task 2: `WeaponKit` — per-weapon blocky silhouettes

**Files:**
- Create: `client/art/weapon_kit.gd`
- Test: `tests/art_weapon_kit_test.gd`

One factory keyed by the `Weapon` enum. Distinct silhouettes by length/shape (DMR longest barrel, SMG shortest, RPG = wide tube + warhead cone). Same node usable as first-person viewmodel and third-person world model. Unknown id falls back to AR.

- [ ] **Step 1: Write the failing test** — `tests/art_weapon_kit_test.gd`:

```gdscript
extends TestCase

func test_builds_a_distinct_model_per_weapon() -> void:
	for w in [Weapon.AR, Weapon.SMG, Weapon.DMR, Weapon.RPG]:
		var node := WeaponKit.build(w)
		assert_true(node is Node3D, "weapon %d returns a Node3D" % w)
		assert_true(node.get_child_count() >= 2, "weapon %d has multiple parts" % w)

func test_relative_lengths_read_as_their_class() -> void:
	var smg_len := WeaponKit.aabb(WeaponKit.build(Weapon.SMG)).size.z
	var ar_len := WeaponKit.aabb(WeaponKit.build(Weapon.AR)).size.z
	var dmr_len := WeaponKit.aabb(WeaponKit.build(Weapon.DMR)).size.z
	assert_true(smg_len < ar_len, "SMG shorter than AR")
	assert_true(dmr_len > ar_len, "DMR longer than AR (marksman barrel)")

func test_rpg_has_a_warhead_cone() -> void:
	var rpg := WeaponKit.build(Weapon.RPG)
	assert_true(rpg.has_node("Warhead"), "RPG carries a visible warhead")

func test_unknown_weapon_falls_back_to_ar() -> void:
	var fallback := WeaponKit.aabb(WeaponKit.build(999)).size
	var ar := WeaponKit.aabb(WeaponKit.build(Weapon.AR)).size
	assert_almost_eq(fallback.z, ar.z, 0.001, "unknown id renders as AR")
```

- [ ] **Step 2: Run, verify fail** (import first).

- [ ] **Step 3: Implement** — `client/art/weapon_kit.gd`:

```gdscript
class_name WeaponKit
extends Object
## Procedural blocky weapons keyed by the Weapon enum. Presentation-only. Barrel runs along +Z
## (muzzle forward), matching the entity/viewmodel forward convention.

# Per-weapon: receiver length, barrel length, has_stock, is_launcher.
const _SPEC := {
	Weapon.AR:  {"receiver": 0.30, "barrel": 0.35, "stock": true,  "launcher": false},
	Weapon.SMG: {"receiver": 0.22, "barrel": 0.18, "stock": false, "launcher": false},
	Weapon.DMR: {"receiver": 0.34, "barrel": 0.55, "stock": true,  "launcher": false},
	Weapon.RPG: {"receiver": 0.40, "barrel": 0.50, "stock": false, "launcher": true},
}

static func build(weapon_id: int) -> Node3D:
	var spec: Dictionary = _SPEC.get(weapon_id, _SPEC[Weapon.AR])
	var root := Node3D.new()
	var metal := ArtPalette.gun_material()
	var receiver_len: float = spec["receiver"]
	var barrel_len: float = spec["barrel"]
	var caliber := 0.10 if bool(spec["launcher"]) else 0.05

	root.add_child(_box("Receiver", Vector3(0.07, 0.12, receiver_len), Vector3(0, 0, 0), metal))
	root.add_child(_box("Barrel", Vector3(caliber, caliber, barrel_len),
		Vector3(0, 0.02, receiver_len * 0.5 + barrel_len * 0.5), metal))
	root.add_child(_box("Mag", Vector3(0.05, 0.18, 0.10), Vector3(0, -0.14, -0.02), metal))
	if bool(spec["stock"]):
		root.add_child(_box("Stock", Vector3(0.06, 0.10, 0.20),
			Vector3(0, -0.02, -receiver_len * 0.5 - 0.10), metal))
	if bool(spec["launcher"]):
		var cone := MeshInstance3D.new()
		cone.name = "Warhead"
		var cm := CylinderMesh.new()
		cm.top_radius = 0.0
		cm.bottom_radius = 0.12
		cm.height = 0.22
		cone.mesh = cm
		cone.rotation = Vector3(PI * 0.5, 0, 0)   # point the cone along +Z
		cone.position = Vector3(0, 0.02, receiver_len * 0.5 + barrel_len + 0.11)
		cone.material_override = ArtPalette.team_material(99)  # neutral grey warhead
		root.add_child(cone)
	return root

static func _box(name: String, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	return mi

static func aabb(root: Node3D) -> AABB:
	return CharacterKit.aabb(root)   # reuse the union-AABB helper
```

- [ ] **Step 4: Run, verify pass** — `--filter=art_weapon_kit`.

- [ ] **Step 5: Commit** — `feat(m7-p2): WeaponKit blocky AR/SMG/DMR/RPG silhouettes`.

---

### Task 3: `VehicleKit` — transport

**Files:**
- Create: `client/art/vehicle_kit.gd`
- Test: `tests/art_vehicle_kit_test.gd`

Sized to `data/vehicles.json` `transport`: hull + 4 wheels + a turret box at `turret_offset` (`[0,2.2,0]`). Team-tinted hull. (Only `transport` exists today; the factory takes a name and falls back to transport, so adding vehicles later is a data+case addition, not a rewrite.)

- [ ] **Step 1: Write the failing test** — `tests/art_vehicle_kit_test.gd`:

```gdscript
extends TestCase

func test_transport_has_hull_four_wheels_and_turret() -> void:
	var v := VehicleKit.build("transport", 0)
	assert_true(v.has_node("Hull"), "has a hull")
	assert_true(v.has_node("Turret"), "has a turret")
	var wheels := 0
	for c in v.get_children():
		if String(c.name).begins_with("Wheel"):
			wheels += 1
	assert_eq(wheels, 4, "four wheels")

func test_turret_sits_at_turret_offset_height() -> void:
	var v := VehicleKit.build("transport", 1)
	var turret := v.get_node("Turret") as Node3D
	assert_almost_eq(turret.position.y, 2.2, 0.1, "turret at vehicles.json turret_offset y")

func test_hull_is_team_tinted() -> void:
	var hull := VehicleKit.build("transport", 1).get_node("Hull") as MeshInstance3D
	assert_eq((hull.material_override as StandardMaterial3D).albedo_color, Color(1.0, 0.3, 0.2),
		"team 1 hull is red")

func test_unknown_vehicle_falls_back_to_transport() -> void:
	assert_true(VehicleKit.build("mystery", 0).has_node("Hull"), "unknown name renders as transport")
```

- [ ] **Step 2: Run, verify fail** (import first).

- [ ] **Step 3: Implement** — `client/art/vehicle_kit.gd`:

```gdscript
class_name VehicleKit
extends Object
## Procedural blocky vehicles. Presentation-only. Sized to data/vehicles.json. Local +Z forward.

static func build(_vehicle_name: String, team: int) -> Node3D:
	# Only 'transport' exists today; all names fall back to it until more are added to vehicles.json.
	var root := Node3D.new()
	var body := ArtPalette.team_material(team)
	var dark := ArtPalette.gun_material()

	root.add_child(_box("Hull", Vector3(2.2, 1.0, 4.0), Vector3(0, 1.0, 0.0), body))
	root.add_child(_box("Cabin", Vector3(1.8, 0.7, 1.6), Vector3(0, 1.7, 0.4), body))
	root.add_child(_box("Turret", Vector3(0.5, 0.5, 1.2), Vector3(0, 2.2, -0.2), dark))
	var wx := 1.05
	var wz := 1.3
	root.add_child(_wheel("WheelFL", Vector3(-wx, 0.45, wz), dark))
	root.add_child(_wheel("WheelFR", Vector3(wx, 0.45, wz), dark))
	root.add_child(_wheel("WheelBL", Vector3(-wx, 0.45, -wz), dark))
	root.add_child(_wheel("WheelBR", Vector3(wx, 0.45, -wz), dark))
	return root

static func _wheel(name: String, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.45
	cyl.bottom_radius = 0.45
	cyl.height = 0.35
	mi.mesh = cyl
	mi.rotation = Vector3(0, 0, PI * 0.5)   # lay the cylinder on its side (axle along X)
	mi.position = pos
	mi.material_override = mat
	return mi

static func _box(name: String, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	return mi
```

- [ ] **Step 4: Run, verify pass** — `--filter=art_vehicle_kit`.

- [ ] **Step 5: Commit** — `feat(m7-p2): VehicleKit transport (hull/wheels/turret, team-tinted)`.

---

### Task 4: `StructureKit` — fortifications with damage tint

**Files:**
- Create: `client/art/structure_kit.gd`
- Test: `tests/art_structure_kit_test.gd`

`sandbag` (half-height) + `wall` (full-height) blocky meshes, tinted per damage bucket (3 pristine → 0 heavy) via `ArtPalette`. The factory keys off the piece **id string** and a bucket int — the renderer reads the id from `PieceCatalog.name_of(type)` and the bucket from `StructureStore.bucket_of(...)` (Task 7). This is the one category whose **rendering** overlaps C3; the kit itself is standalone and safe.

- [ ] **Step 1: Write the failing test** — `tests/art_structure_kit_test.gd`:

```gdscript
extends TestCase

func test_wall_is_full_height_sandbag_is_half() -> void:
	var wall_h := StructureKit.aabb(StructureKit.build("wall", 3)).size.y
	var bag_h := StructureKit.aabb(StructureKit.build("sandbag", 3)).size.y
	assert_true(wall_h > bag_h, "full-height wall taller than half-height sandbag")
	assert_almost_eq(bag_h, wall_h * 0.5, 0.4, "sandbag roughly half the wall height")

func test_heavy_damage_is_darker_than_pristine() -> void:
	var pristine := _albedo(StructureKit.build("wall", 3))
	var heavy := _albedo(StructureKit.build("wall", 0))
	assert_true(heavy.v < pristine.v, "bucket 0 darker than bucket 3")

func test_unknown_piece_falls_back_to_wall() -> void:
	assert_true(StructureKit.build("mystery", 3) is Node3D, "unknown id still builds")

func _albedo(node: Node3D) -> Color:
	for c in node.get_children():
		if c is MeshInstance3D:
			return ((c as MeshInstance3D).material_override as StandardMaterial3D).albedo_color
	return Color.BLACK
```

- [ ] **Step 2: Run, verify fail** (import first).

- [ ] **Step 3: Implement** — `client/art/structure_kit.gd`:

```gdscript
class_name StructureKit
extends Object
## Procedural blocky fortifications with per-damage-bucket tint. Presentation-only. Keyed by the
## PieceCatalog id string + StructureStore damage bucket (3 pristine .. 0 heavy).

# id -> {size, base_color}. base_color mirrors the piece's material tag.
const _SPEC := {
	"wall":    {"size": Vector3(2.0, 2.4, 0.3), "color": ArtPalette.STRUCT_CONCRETE},
	"sandbag": {"size": Vector3(2.0, 1.0, 0.6), "color": ArtPalette.STRUCT_METAL_THIN},
}

static func build(piece_id: String, bucket: int) -> Node3D:
	var spec: Dictionary = _SPEC.get(piece_id, _SPEC["wall"])
	var root := Node3D.new()
	var mat := ArtPalette.structure_material(spec["color"], bucket)
	var size: Vector3 = spec["size"]
	var body := _box("Body", size, Vector3(0, size.y * 0.5, 0), mat)
	root.add_child(body)
	# Heavy damage (bucket <= 1) adds a chipped corner block so damage reads in silhouette, not just tint.
	if bucket <= 1:
		var chip := _box("Chip", Vector3(size.x * 0.4, size.y * 0.3, size.z * 1.05),
			Vector3(size.x * 0.25, size.y * 0.85, 0), mat)
		root.add_child(chip)
	return root

static func _box(name: String, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	return mi

static func aabb(root: Node3D) -> AABB:
	return CharacterKit.aabb(root)
```

- [ ] **Step 4: Run, verify pass** — `--filter=art_structure_kit`.

- [ ] **Step 5: Commit** — `feat(m7-p2): StructureKit fortifications with damage-bucket tint`.

---

### Task 5: `PropKit` — map set-dressing

**Files:**
- Create: `client/art/prop_kit.gd`
- Test: `tests/art_prop_kit_test.gd`

Neutral environment props (crate, barrel, barrier) for visual variety. Purely cosmetic — not gameplay collision (that stays sim-side). Keyed by a prop name; unknown → crate.

- [ ] **Step 1: Write the failing test** — `tests/art_prop_kit_test.gd`:

```gdscript
extends TestCase

func test_known_props_build_with_geometry() -> void:
	for p in ["crate", "barrel", "barrier"]:
		var node := PropKit.build(p)
		assert_true(node is Node3D, "%s returns a Node3D" % p)
		assert_true(PropKit.aabb(node).size.length() > 0.0, "%s has non-zero geometry" % p)

func test_barrel_is_round() -> void:
	var barrel := PropKit.build("barrel")
	var has_cyl := false
	for c in barrel.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh is CylinderMesh:
			has_cyl = true
	assert_true(has_cyl, "barrel uses a cylinder")

func test_unknown_prop_falls_back_to_crate() -> void:
	assert_almost_eq(PropKit.aabb(PropKit.build("???")).size.y,
		PropKit.aabb(PropKit.build("crate")).size.y, 0.001, "unknown -> crate")
```

- [ ] **Step 2: Run, verify fail** (import first).

- [ ] **Step 3: Implement** — `client/art/prop_kit.gd`:

```gdscript
class_name PropKit
extends Object
## Cosmetic map set-dressing props (no gameplay collision — that stays sim-side). Presentation-only.

static func build(prop_name: String) -> Node3D:
	var root := Node3D.new()
	match prop_name:
		"barrel":
			var b := MeshInstance3D.new()
			b.name = "Barrel"
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.3
			cyl.bottom_radius = 0.3
			cyl.height = 0.9
			b.mesh = cyl
			b.position = Vector3(0, 0.45, 0)
			b.material_override = ArtPalette.structure_material(ArtPalette.STRUCT_METAL_THIN, 2)
			root.add_child(b)
		"barrier":
			root.add_child(_box("Barrier", Vector3(1.6, 1.0, 0.25), Vector3(0, 0.5, 0),
				ArtPalette.structure_material(ArtPalette.STRUCT_CONCRETE, 3)))
		_:  # crate (default)
			root.add_child(_box("Crate", Vector3(0.8, 0.8, 0.8), Vector3(0, 0.4, 0),
				ArtPalette.structure_material(ArtPalette.STRUCT_METAL_THIN, 3)))
	return root

static func _box(name: String, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	return mi

static func aabb(root: Node3D) -> AABB:
	return CharacterKit.aabb(root)
```

- [ ] **Step 4: Run, verify pass** — `--filter=art_prop_kit`.

- [ ] **Step 5: Commit** — `feat(m7-p2): PropKit cosmetic map set-dressing`.

---

# Part 2 — Owner visual sign-off (standalone preview, no C3 files)

### Task 6: Preview scenes — lay out every variant for playtest

**Files:**
- Create: `client/art/preview/preview_driver.gd`
- Create: `client/art/preview/kit_preview.tscn`
- Test: `tests/art_preview_driver_test.gd`

A single standalone scene that instantiates every kit variant in labeled rows with a camera + light, so the owner can **run it directly and eyeball the kit** without the full client, server, or any autoload. `godot --path . client/art/preview/kit_preview.tscn`. The driver's layout logic (which variants, how many) is unit-tested; the look is the owner's call.

- [ ] **Step 1: Write the failing test** — `tests/art_preview_driver_test.gd`:

```gdscript
extends TestCase

func test_driver_spawns_one_node_per_catalog_entry() -> void:
	var spawned := PreviewDriver.build_catalog()
	# 2 character teams + 4 weapons + 2 vehicle teams + 2 structures*4 buckets + 3 props = 19
	assert_true(spawned.size() >= 19, "catalog covers all kit variants, got %d" % spawned.size())
	var kinds := {}
	for item in spawned:
		kinds[item["kind"]] = true
	for k in ["character", "weapon", "vehicle", "structure", "prop"]:
		assert_true(kinds.has(k), "catalog includes a %s" % k)

func test_each_catalog_item_carries_a_node_and_label() -> void:
	for item in PreviewDriver.build_catalog():
		assert_true(item["node"] is Node3D, "item has a Node3D")
		assert_true(String(item["label"]).length() > 0, "item is labeled")
```

- [ ] **Step 2: Run, verify fail** (import first).

- [ ] **Step 3: Implement** — `client/art/preview/preview_driver.gd`:

```gdscript
class_name PreviewDriver
extends Node3D
## Standalone art-kit preview. Run: godot --path . client/art/preview/kit_preview.tscn
## Lays out every kit variant in a grid for the owner's visual sign-off. No server/autoload needed.

const SPACING := 3.0

## Pure catalog of every variant to show: [{kind, label, node}]. Unit-tested.
static func build_catalog() -> Array:
	var items: Array = []
	for team in [0, 1]:
		items.append({"kind": "character", "label": "soldier t%d" % team, "node": CharacterKit.build(team)})
	for w in [Weapon.AR, Weapon.SMG, Weapon.DMR, Weapon.RPG]:
		items.append({"kind": "weapon", "label": "weapon %d" % w, "node": WeaponKit.build(w)})
	for team in [0, 1]:
		items.append({"kind": "vehicle", "label": "transport t%d" % team, "node": VehicleKit.build("transport", team)})
	for piece in ["wall", "sandbag"]:
		for bucket in [3, 2, 1, 0]:
			items.append({"kind": "structure", "label": "%s b%d" % [piece, bucket], "node": StructureKit.build(piece, bucket)})
	for p in ["crate", "barrel", "barrier"]:
		items.append({"kind": "prop", "label": p, "node": PropKit.build(p)})
	return items

func _ready() -> void:
	var items := build_catalog()
	var per_row := 6
	for i in items.size():
		var node: Node3D = items[i]["node"]
		node.position = Vector3((i % per_row) * SPACING, 0.0, (i / per_row) * SPACING)
		add_child(node)
		var label := Label3D.new()
		label.text = String(items[i]["label"])
		label.position = node.position + Vector3(0, 2.6, 0)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		add_child(label)
```

- [ ] **Step 4: Create the scene** — `client/art/preview/kit_preview.tscn` (camera looks down the grid; directional light; the driver script as root):

```
[gd_scene load_steps=3 format=3]

[ext_resource type="Script" path="res://client/art/preview/preview_driver.gd" id="1"]

[sub_resource type="Environment" id="Environment_1"]
background_mode = 1
ambient_light_source = 2
ambient_light_color = Color(0.7, 0.72, 0.78, 1)

[node name="KitPreview" type="Node3D"]
script = ExtResource("1")

[node name="Camera3D" type="Camera3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 0.86, 0.5, 0, -0.5, 0.86, 8, 7, 16)

[node name="DirectionalLight3D" type="DirectionalLight3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 0.5, 0.866, 0, -0.866, 0.5, 0, 20, 0)
shadow_enabled = true

[node name="WorldEnvironment" type="WorldEnvironment" parent="."]
environment = SubResource("Environment_1")
```

- [ ] **Step 5: Run, verify pass** — `--filter=art_preview_driver`. Then sanity-load the scene headlessly: `godot --headless --path . client/art/preview/kit_preview.tscn --quit-after 2` and confirm no script/scene errors in the output.

- [ ] **Step 6: Commit** — `feat(m7-p2): art-kit preview scene for owner visual sign-off`.

- [ ] **Step 7 (owner playtest gate):** Owner runs `godot --path . client/art/preview/kit_preview.tscn` on the desktop (per `docs/runbooks/running-client.md` launch conventions) and signs off that the kit reads as a coherent low-poly BattleBit-style set (friend/foe tint clear, weapon classes distinguishable, damage states legible). Record sign-off here. Feel/proportion tweaks are follow-ups, not blockers.

---

# Part 3 — Renderer integration (GATED: run only after M7-C3 merges)

> **⚠️ Coordination gate.** This is the **only** task that edits `client/world_renderer.gd`, which M7-C3 also modifies (it adds structure rendering). **Do not start until C3 is merged into the M7 line.** Then rebase this branch onto the merged tip, resolve any `world_renderer.gd` overlap, and proceed. Everything in Parts 1–2 is mergeable without conflict before this point.

### Task 7: Swap placeholders for the kit behind the renderer seams

**Files:**
- Modify: `client/world_renderer.gd` (the `_make_entity_mesh()` seam + structure/vehicle draw paths)
- Test: existing `tests/*` must stay green; add `tests/world_renderer_art_test.gd` only for any pure helper you extract.

The renderer comment already invites this: *"P2 can swap meshes by changing `_make_entity_mesh()` / `_make_ground_mesh()` etc. without touching netcode or calling code."* Keep all call sites and per-frame pose/scale logic; only change **what mesh is built**.

- [ ] **Step 1: Replace `_make_entity_mesh()`** to return a `CharacterKit` soldier with a `WeaponKit` weapon parented to its gun mount, instead of the capsule+box. Preserve: +Z forward, team tint (pass the entity's team), and the per-frame vertical scale (now `body_height / CharacterKit.STAND_HEIGHT` applied to the root). Example shape:

```gdscript
func _make_entity_mesh(team: int = 0, weapon_id: int = Weapon.AR) -> Node3D:
	var soldier := CharacterKit.build(team)
	var gun := WeaponKit.build(weapon_id)
	var mount := soldier.get_node("GunMount")
	mount.add_child(gun)
	return soldier
```

(Adjust the `_acquire_entity`/`_pose_entity` call sites to pass `team`/`weapon` and to scale by `CharacterKit.STAND_HEIGHT` rather than the old capsule height. Keep the recycling free-list.)

- [ ] **Step 2: Route structures** through `StructureKit.build(PieceCatalog.name_of(type), StructureStore.bucket_of(health, max))` wherever C3's merged code instantiates structure meshes; route the vehicle node through `VehicleKit.build("transport", team)`; sprinkle `PropKit` props from map data if the map carries prop markers (optional).

- [ ] **Step 3: Import + run the FULL suite** — `godot --headless --path . --import` then `godot --headless --path . -- --test`. Expected: all tests green (the C3 suite + the new `art_*` suite), zero regressions.

- [ ] **Step 4: Headless smoke** — run `ci/m5_p1_test.sh` (≤48-bot) and confirm the client still connects and the tick budget is unaffected (rendering is client-only; the headless server/bots don't build meshes).

- [ ] **Step 5: Commit** — `feat(m7-p2): render the procedural art kit behind the world_renderer seams`.

- [ ] **Step 6 (full M7 P2 art gate):** Owner playtests a live match on the desktop vs bots on game2 (per `docs/runbooks/running-client.md`) and confirms the real kit reads correctly in motion — friend/foe, weapon-in-hand, vehicle, damaged structures. Record sign-off + server log on the M7-art-ux milestone.

---

## Self-review checklist (run before handoff)
- **Scope coverage:** characters (T1), weapons (T2), vehicles (T3), structures+damage (T4), environment/props (T5), preview/sign-off (T6), integration (T7) — all four requested categories covered.
- **Isolation:** Tasks 0–6 add only `client/art/**`, `assets/**`, `tests/art_*`. No edit to any C3-owned file. Verify with `git diff --name-only master` before each commit — it must list only new files until Task 7.
- **No placeholders:** every code step has complete, runnable GDScript; every test asserts.
- **Type consistency:** `CharacterKit.aabb()` is the shared union-AABB helper reused by all kits; `build()` signatures are stable across tasks; `STAND_HEIGHT` is the single height contract between kit and renderer.
- **Determinism/testability:** all assertions read geometry (`.size`, `.position`, `mesh.get_aabb()`, `material_override.albedo_color`) — no rendered pixels, headless-safe (AGENTS.md §10).

## Execution handoff
Run with **superpowers:subagent-driven-development** (fresh subagent per task, two-stage review) or **superpowers:executing-plans** (inline with checkpoints). Tasks 0–6 can run start-to-finish now in this worktree; **hold Task 7 until M7-C3 is merged.**
