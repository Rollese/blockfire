# M7-P2 Art Pipeline — GLB Soldier: Weapon-in-Hand Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make rendered GLB soldiers visibly carry a rifle — attach a `WeaponKit` weapon to the character's hand node and use the GLB's two-handed "holding" pose when stationary — so a soldier reads as an armed combatant instead of an unarmed civilian idle.

**Architecture:** The Kenney GLB is a **node-transform-animated** hierarchy (verified: no `Skeleton3D`; the hand is the `arm-right` `MeshInstance3D` node, animated by transform tracks). So a weapon **parented under `arm-right`** follows the hand through any clip — no bone attachment. `GlbCharacterKit` gains `attach_weapon()` (used by `build()` to attach a default AR after height-normalization) and `CharacterAnim` maps the stationary-alive state to the `holding-both` clip. Both are client-only, presentation-only, and unit-tested for structure; the in-hand **placement** (offset/rotation/scale) is playtest-tuned. No `world_renderer` change is needed — `build()` attaches the weapon, and it composes with the already-merged entity LOD (the weapon meshes get visibility ranges like any other part).

**Tech Stack:** Godot 4.6 / GDScript. Tests: `godot --headless --path . -- --test [--filter=<substr>]`, classes extend the global `TestCase` (`tests/*_test.gd`).

**Spec:** [`docs/specs/art-pipeline.md`](../specs/art-pipeline.md) §5 (Track C, animation/character). **Milestone:** [`M7-art-ux.md`](../milestones/M7-art-ux.md) (P2 — GLB character increment follow-ups).

---

## Scope (read first)

**In scope:** attach a default rifle to the GLB soldier's hand + use the two-handed holding pose when stationary.

**Deferred (NOT this plan):** per-entity weapon variety (the weapon class isn't replicated per remote entity — all soldiers carry a default AR for now); the procedural `CharacterKit` already has a `GunMount` box so it is out of scope; remote **fire/shoot** animation (`holding-*-shoot`) needs a per-shot signal identifying the shooter — that is the wire-gated Track C Layer 2 (`SHOT_FX` has no `shooter_id`), coordinated with M11's `protocol.gd`; precise in-hand placement is a playtest tuning step, not a code gate.

**Why conflict-free with M11:** edits only `client/art/glb_character_kit.gd` and `client/art/character_anim.gd` (+ their tests). No `world_renderer`, `shared/`, server, bot, `client_main`, or `project.godot` changes. M11 owns the structure path. No fleet gate (client-render only).

## Verified facts (do not re-derive)
- GLB node tree (from `GlbCharacterKit.build()`): `wrapper → character-a2 → character-a → root → {leg-left, leg-right, torso → {arm-left, arm-right, head}}` + an `AnimationPlayer`. The hand node is **`arm-right`** (a `MeshInstance3D`). There is **no `Skeleton3D`** — animations are node-transform tracks, so a child of `arm-right` follows the hand.
- GLB clip names (27 total) include: `idle, walk, sprint, static, sit, die, holding-both, holding-left, holding-right, holding-both-shoot, holding-left-shoot, holding-right-shoot, …`. **No `crouch`/`prone` clip exists** (crouch/prone stay the `_pose_entity` shrink/tip).
- `client/art/weapon_kit.gd`: `class_name WeaponKit`, `static func build(weapon_id: int) -> Node3D` returns a multi-part rifle (parts like `Receiver`/`Barrel`/`Mag`).
- `shared/sim/weapon.gd`: `class_name Weapon`, `enum { AR = 0, SMG = 1, DMR = 2, RPG = 3 }` → use `Weapon.AR`.
- `client/art/glb_character_kit.gd`: `build()` computes `world_aabb` to normalize height **before** wrapping; `anim_player(node)` finds the `AnimationPlayer` recursively. **The weapon must be attached AFTER the `world_aabb` normalization**, or it inflates the height calc.
- `client/art/character_anim.gd`: `static func clip_for(downed: bool, speed: float, _stance: int) -> Dictionary` returns `{"clip", "loop"}`. Today stationary-alive → `idle`. `CharacterDriver.drive()` no-ops if the clip is missing (safe).

## GDScript / Godot gotchas (every task)
- After editing a `class_name` script, run `godot --headless --path . --import` once before tests. NEVER pipe `godot` through `tail`/`head` — redirect to a file.
- Tests extend global `TestCase`; run `--test --filter=<substr>`. The harness FAILS zero-assertion tests.
- Annotate `var` types explicitly (no Variant `:=` from Dictionary access). `find_child(pattern, recursive := true, owned := false)` — use `owned = false`, GLB-instanced children aren't script-owned.
- `git add -A` for `.uid` sidecars. Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## File map

| File | Create/Modify | Responsibility |
|---|---|---|
| `client/art/glb_character_kit.gd` | **Modify** | `attach_weapon()` + placement consts; `build()` attaches a default AR after normalization. |
| `tests/art_glb_character_kit_test.gd` | **Modify** (append) | Structure tests: weapon attached under `arm-right`; build includes it; no-hand path safe. |
| `client/art/character_anim.gd` | **Modify** | Stationary-alive → `holding-both` (two-handed ready). |
| `tests/art_character_anim_test.gd` | **Modify** | Update the stationary expectation to `holding-both`. |

---

## Task 1: Attach a weapon to the GLB soldier's hand

**Files:**
- Modify: `client/art/glb_character_kit.gd`
- Test: `tests/art_glb_character_kit_test.gd` (append)

`attach_weapon(root, weapon_id)` finds the `arm-right` node anywhere under `root` and parents a `WeaponKit` weapon (named `HeldWeapon`) under it at a default offset/rotation/scale. Returns `false` (no crash) if there is no hand node. `build()` calls it with `Weapon.AR` after the height normalization. Placement consts are **playtest knobs** (the model's normalization scale and arm axis aren't derivable headlessly).

- [ ] **Step 1: Write the failing tests** — append to `tests/art_glb_character_kit_test.gd`:

```gdscript
func test_attach_weapon_parents_a_weapon_under_the_hand() -> void:
	var soldier := GlbCharacterKit.build()      # build already attaches a default weapon
	var hand := soldier.find_child(GlbCharacterKit.HAND_NODE, true, false)
	assert_true(hand != null, "the GLB exposes the '%s' hand node" % GlbCharacterKit.HAND_NODE)
	var held := hand.find_child("HeldWeapon", false, false)
	assert_true(held != null, "a HeldWeapon is parented directly under the hand node")
	assert_true(held is Node3D, "the held weapon is a Node3D")
	assert_true(held.get_child_count() >= 2, "the weapon is the multi-part WeaponKit model")

func test_build_includes_a_held_weapon_by_default() -> void:
	var soldier := GlbCharacterKit.build()
	assert_true(soldier.find_child("HeldWeapon", true, false) != null,
		"GlbCharacterKit.build() arms the soldier with a default weapon")

func test_attach_weapon_is_safe_without_a_hand_node() -> void:
	var bare := Node3D.new()
	var ok := GlbCharacterKit.attach_weapon(bare, Weapon.AR)
	assert_false(ok, "no hand node -> returns false, no crash")
	assert_true(bare.find_child("HeldWeapon", true, false) == null, "nothing attached")

func test_held_weapon_does_not_break_height_normalization() -> void:
	# The weapon is attached AFTER world_aabb normalization, so the soldier's overall standing
	# height still matches STAND_HEIGHT (the gun must not inflate the figure's height).
	var soldier := GlbCharacterKit.build()
	var h := GlbCharacterKit.world_aabb(soldier).size.y
	assert_almost_eq(h, GlbCharacterKit.STAND_HEIGHT, 0.35,
		"standing height stays ~STAND_HEIGHT despite the held weapon")
```

- [ ] **Step 2: Run, verify it fails** — `godot --headless --path . --import` then `godot --headless --path . -- --test --filter=art_glb_character_kit`. Expected: FAIL (`HAND_NODE`/`attach_weapon` not found).

- [ ] **Step 3: Implement** — in `client/art/glb_character_kit.gd`:

Add these consts after `const STAND_HEIGHT := 1.8`:
```gdscript
const HAND_NODE := "arm-right"                  # the GLB node the weapon is parented under (the hand)
# In-hand placement, in the hand node's LOCAL space. PLAYTEST KNOBS — tune by eye, not derivable
# headlessly (depends on the model's normalization scale + arm axis). Starting guesses below.
const WEAPON_OFFSET := Vector3(0.0, -0.35, 0.15)   # down toward the hand, slightly forward
const WEAPON_ROT := Vector3(0.0, 0.0, 0.0)         # barrel orientation (radians); tune at playtest
const WEAPON_SCALE := 1.0                          # compensate for the model's normalization scale
```

Add this function (e.g. after `build()`):
```gdscript
## Parent a WeaponKit weapon under the model's hand node so the soldier visibly carries it. The GLB
## is node-transform animated (no skeleton), so a child of the hand node follows the hand through
## every clip. Returns true if attached. Placement is a playtest knob (see consts). Presentation-only.
static func attach_weapon(root: Node3D, weapon_id: int) -> bool:
	var hand := root.find_child(HAND_NODE, true, false)
	if hand == null:
		return false
	var weapon := WeaponKit.build(weapon_id)
	weapon.name = "HeldWeapon"
	weapon.position = WEAPON_OFFSET
	weapon.rotation = WEAPON_ROT
	weapon.scale = Vector3(WEAPON_SCALE, WEAPON_SCALE, WEAPON_SCALE)
	hand.add_child(weapon)
	return true
```

In `build()`, attach the default weapon to the wrapper **after** the normalization/wrap is done, just before `return wrapper`:
```gdscript
	attach_weapon(wrapper, Weapon.AR)
	return wrapper
```

- [ ] **Step 4: Run, verify pass** — `godot --headless --path . -- --test --filter=art_glb_character_kit`. Expected: all PASS. (If `test_held_weapon_does_not_break_height_normalization` fails, confirm the `attach_weapon(wrapper, Weapon.AR)` call is placed AFTER the `world_aabb`/scale lines, not before.)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(m7-p2): arm the GLB soldier with a held weapon (parented to the hand node)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Use the two-handed holding pose when stationary

**Files:**
- Modify: `client/art/character_anim.gd`
- Test: `tests/art_character_anim_test.gd`

A stationary, alive soldier should stand in the `holding-both` two-handed ready pose (so the held weapon reads as gripped) instead of the arms-down `idle`. Movement keeps `walk`/`sprint`; downed keeps the calm lying `idle`. Pure mapping change.

- [ ] **Step 1: Update the test** — in `tests/art_character_anim_test.gd`, change `test_idle_when_still_and_alive` to expect the holding pose:

```gdscript
func test_holding_pose_when_still_and_alive() -> void:
	var r := CharacterAnim.clip_for(false, 0.0, Stance.STAND)
	assert_eq(r["clip"], "holding-both", "still + armed -> two-handed weapon-ready hold")
	assert_true(r["loop"], "the ready hold loops (breathing)")
```
(Leave `test_walk_above_walk_threshold`, `test_sprint_above_sprint_threshold`, `test_downed_uses_calm_lying_pose`, and `test_downed_overrides_movement` unchanged — they still pass.)

- [ ] **Step 2: Run, verify it fails** — `godot --headless --path . --import` then `godot --headless --path . -- --test --filter=art_character_anim`. Expected: FAIL (still returns `idle`).

- [ ] **Step 3: Implement** — in `client/art/character_anim.gd`, change the stationary fallthrough. The function becomes:

```gdscript
static func clip_for(downed: bool, speed: float, _stance: int) -> Dictionary:
	if downed:
		# DBNO: alive but incapacitated. The renderer lays the body on its back (face-up); a calm
		# looping idle reads as "downed, breathing" — not the `die` collapse clip (arm-flail).
		return {"clip": "idle", "loop": true}
	if speed >= SPRINT_SPEED:
		return {"clip": "sprint", "loop": true}
	if speed >= WALK_SPEED:
		return {"clip": "walk", "loop": true}
	# Stationary + alive: two-handed weapon-ready hold (the soldier carries a HeldWeapon), so it reads
	# as an armed combatant rather than an arms-down civilian idle.
	return {"clip": "holding-both", "loop": true}
```
Also update the file's header comment line that says crouch/prone shape stays in `_pose_entity` to note the stationary clip is now `holding-both` (a one-word doc fix; keep the rest).

- [ ] **Step 4: Run, verify pass** — `godot --headless --path . -- --test --filter=art_character_anim`. Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(m7-p2): stationary GLB soldier uses the two-handed holding pose

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Full-suite regression + scene smoke

**Files:** none (verification only)

- [ ] **Step 1: Import + full unit suite** — `godot --headless --path . --import` then `godot --headless --path . -- --test 2>&1 | tee /tmp/full.log`. Expected: **all green** (existing suite + the updated anim/GLB tests), zero regressions. Report the `TESTS: N run, M failed` line.

- [ ] **Step 2: Headless scene smoke** — `godot --headless --path . client/art/preview/kit_preview.tscn --quit-after 2 2>&1 | tee /tmp/preview.log`. Expected: clean, no `SCRIPT ERROR`/`Parse Error` (pre-existing leaked-instance warnings are fine).

- [ ] **Step 3 (owner playtest gate):** Owner runs a live match with **GLB characters enabled** (client on the home laptop → server+bots on `game2`, per [`docs/runbooks/running-client.md`](../runbooks/running-client.md)) and confirms soldiers visibly carry a rifle that sits in the hand and points forward, and the stationary hold reads well. **Tune the placement knobs** in `GlbCharacterKit` — `WEAPON_OFFSET` / `WEAPON_ROT` / `WEAPON_SCALE` — until the gun sits right (expect iteration here; the headless tests only guarantee it's attached, not aimed). Record sign-off on [`M7-art-ux.md`](../milestones/M7-art-ux.md).

---

## Self-review checklist (run before handoff)
- **Spec coverage:** weapon visibly in-hand (T1), weapon-ready pose (T2), regression + playtest (T3). Per-entity weapon variety, shoot anim, and exact placement are explicitly deferred (Scope).
- **Isolation / conflict-free with M11:** only `client/art/glb_character_kit.gd` + `client/art/character_anim.gd` (+ their tests) change. No `world_renderer`, `shared/`, server, bot, `client_main`, `project.godot`. Verify `git diff --name-only master` lists only those four files.
- **No placeholders:** every code step is complete, runnable GDScript; every test asserts.
- **Type consistency:** `GlbCharacterKit.attach_weapon(root, weapon_id) -> bool`, consts `HAND_NODE`/`WEAPON_OFFSET`/`WEAPON_ROT`/`WEAPON_SCALE`; `WeaponKit.build(int)`, `Weapon.AR`; `CharacterAnim.clip_for(...)` shape `{clip, loop}` unchanged. `HeldWeapon` is the stable attached-node name across tasks/tests.
- **Determinism/testability:** GLB tests assert node structure + that height normalization is preserved; the anim test asserts the pure clip string; placement is playtest-tuned, not asserted — headless-safe (AGENTS.md §10).
- **Composition with LOD:** the held weapon is a child mesh subtree, so `Lod.apply_to_character` (run by the renderer after `build()`) gives its meshes visibility ranges automatically — no extra wiring, no conflict.

## Execution handoff
Run with **superpowers:subagent-driven-development** — one implementer dispatch covers Tasks 1+2 (two small client-art files, fully unit-tested), then Task 3 verification. No `world_renderer`/shared-file edit, so no integration review subagent is needed beyond the controller reading the committed diffs. All tasks run now on a branch off `master`; none waits on M11.
