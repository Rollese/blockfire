# M7-P2 Art Pipeline — Track B: Muzzle Flash VFX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a brief, pooled muzzle-flash effect at the muzzle of every shot — local and remote — so gunfire reads visually (pairs with the already-merged combat audio), without touching netcode, the sim, or `client_main`.

**Architecture:** A new `client/art/muzzle_flash_kit.gd` (`class_name MuzzleFlashKit`) owns the flash mesh (an emissive, unshaded, alpha-blended quad-ish box) and a pure `alpha_for()` fade helper — both unit-tested headlessly, following the established `client/art/*_kit.gd` pattern. `world_renderer.gd` gains a small fixed flash pool (mirroring its existing tracer pool) and spawns a flash from inside `_spawn_tracer()` — the single funnel that both local fire (`fire_tracer`) and remote `SHOT_FX` (`tracer_from`) already pass through — then ages it out in `update()`. No `client_main`, `shared/`, server, bot, or `project.godot` changes.

**Tech Stack:** Godot 4.6 / GDScript. Tests: `godot --headless --path . -- --test [--filter=<substr>]`, classes extend the global `TestCase` (`tests/*_test.gd`).

**Spec:** [`docs/specs/art-pipeline.md`](../../specs/art-pipeline.md) §4.1 (buildable-now VFX). **Milestone:** [`M7-art-ux.md`](../../milestones/M7-art-ux.md) (P2).

---

## Scope (read first)

**In scope:** a muzzle-flash effect for local + remote shots, spawned at the existing tracer seam.

**Deferred (NOT this plan):** **weapon-tinted / per-weapon tracers and flashes.** The remote `SHOT_FX` message carries only `(origin, dir)` — no weapon id (same wire gap as Track C's `shooter_id`). Per-weapon visual differentiation needs a `shared/net/protocol.gd` field, which is **shared with the in-flight `m11-destructible-buildings` branch** — so it's deferred/coordinated, not done here. Also deferred (other Track B increments): hit-spark/impact puffs, death/hit-feedback polish.

**Why this is conflict-free with M11:** the only existing file touched is `client/world_renderer.gd`, and only its **tracer/VFX region** (`setup()` pool init, `_spawn_tracer`, `update`, plus new `_spawn_flash`/`_age_flashes`). M11 edits the *structure* path; the recently-merged LOD work edited `_make_entity_mesh` — all different functions. No `shared/`, server, bot, `client_main`, or `project.godot` edits. No 128-bot fleet gate (client-render only), so no contention for the `game2` host M11 holds.

## Established facts the plan relies on (verified, do not re-derive)
- `client/world_renderer.gd` already has a **tracer pool** as the pattern to mirror:
  - State (near line 31): `var _tracers: Array = []` (entries `{node, mat, die}`), `var _tracer_idx: int = 0`, `const TRACER_POOL := 16`, `const TRACER_COLOR := Color(1.0, 0.85, 0.35)`.
  - `setup()` builds the tracer pool in a `for _i in TRACER_POOL:` loop (emissive, unshaded, `TRANSPARENCY_ALPHA`, `SHADOW_CASTING_SETTING_OFF`, `visible = false`).
  - `func _spawn_tracer(origin: Vector3, fwd: Vector3, now: float)` — **the single funnel**: `fire_tracer()` (local) computes a muzzle `origin` then calls it; `tracer_from()` (remote `SHOT_FX`) calls it with the shooter's origin.
  - `func _age_tracers(now: float)` — fades alpha by `remaining / TRACER_TTL`; `update()` calls `_age_tracers(now)` once per frame.
- Fire/remote seams in `client/client_main.gd` already call the renderer (`:175` `fire_tracer`, `:470` `tracer_from`) — **no edit needed there**; spawning the flash inside `_spawn_tracer` covers both paths.
- `client/art/art_palette.gd` exists (`class_name ArtPalette`) — the kit may reuse its `_flat`/material conventions but the flash needs an **emissive unshaded** material, so it builds its own (mirroring the tracer material), same as the tracer code does inline.

## GDScript / Godot gotchas (every task)
- After adding a new `class_name` script, run `godot --headless --path . --import` once before tests. NEVER pipe `godot` through `tail`/`head` — redirect to a file.
- Tests in `tests/*_test.gd` extend the global `TestCase`; run `godot --headless --path . -- --test --filter=muzzle`. The harness FAILS any test with zero assertions — every test must assert.
- GDScript 4.6 rejects `var x := <Dictionary access>` (Variant) — annotate types explicitly.
- Assert on **property values** (mesh `.size`, material flags, pure return values), never rendered pixels — headless-safe (AGENTS.md §10). The renderer pool itself (like the existing tracer pool) is validated by **scene smoke + owner playtest**, not unit tests.
- `git add -A` for `.uid` sidecars. Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## File map

| File | Create/Modify | Responsibility |
|---|---|---|
| `client/art/muzzle_flash_kit.gd` | Create | `MuzzleFlashKit` — `build()` emissive flash mesh + `alpha_for()` pure fade + flash constants. Presentation-only, unit-tested. |
| `tests/art_muzzle_flash_kit_test.gd` | Create | Headless tests: mesh geometry/material, pure fade curve + clamping. |
| `client/world_renderer.gd` | **Modify** (tracer/VFX region only) | Flash pool in `setup()`, `_spawn_flash()` called from `_spawn_tracer()`, `_age_flashes()` called from `update()`. |

---

## Task 1: `MuzzleFlashKit.build()` — emissive flash mesh

**Files:**
- Create: `client/art/muzzle_flash_kit.gd`
- Test: `tests/art_muzzle_flash_kit_test.gd`

- [ ] **Step 1: Write the failing test** — `tests/art_muzzle_flash_kit_test.gd`:

```gdscript
extends TestCase

func test_build_returns_emissive_unshaded_mesh() -> void:
	var flash := MuzzleFlashKit.build()
	assert_true(flash is MeshInstance3D, "returns a MeshInstance3D")
	assert_true(flash.mesh is BoxMesh, "uses a box mesh (welded-primitive kit style)")
	var mat := flash.material_override as StandardMaterial3D
	assert_true(mat != null, "carries a material override")
	assert_true(mat.emission_enabled, "emissive so it reads as a bright flash")
	assert_eq(mat.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED, "unshaded — full brightness")
	assert_eq(mat.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA, "alpha-blended for the fade-out")

func test_build_mesh_is_small_and_no_shadow() -> void:
	var flash := MuzzleFlashKit.build()
	var size := (flash.mesh as BoxMesh).size
	assert_almost_eq(size.x, MuzzleFlashKit.SIZE, 0.001, "flash width == SIZE")
	assert_true(size.z < size.x, "flash is a thin facing plate, not a cube")
	assert_eq(flash.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "a flash casts no shadow")
```

- [ ] **Step 2: Run, verify it fails** — `godot --headless --path . --import` then `godot --headless --path . -- --test --filter=muzzle`. Expected: FAIL (`MuzzleFlashKit` not found).

- [ ] **Step 3: Implement** — `client/art/muzzle_flash_kit.gd`:

```gdscript
class_name MuzzleFlashKit
extends Object
## Procedural muzzle-flash effect. Presentation-only (AGENTS.md §7). A small emissive, unshaded,
## alpha-blended plate spawned at the muzzle for a few frames when a shot is fired (local or remote).
## The renderer pools these and drives the fade via alpha_for(). Mirrors the tracer material style.

const COLOR := Color(1.0, 0.85, 0.5)   # warm muzzle-flash tint
const SIZE := 0.4                      # plate width/height, metres
const THICK := 0.08                    # thin along its facing axis (a plate, not a cube)
const TTL := 0.045                     # seconds visible — a brief flash

static func build() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "MuzzleFlash"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(SIZE, SIZE, THICK)
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = COLOR
	mat.emission_enabled = true
	mat.emission = COLOR
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
```

- [ ] **Step 4: Run, verify pass** — `godot --headless --path . -- --test --filter=muzzle`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(m7-p2): MuzzleFlashKit emissive flash mesh

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `MuzzleFlashKit.alpha_for()` — pure fade

**Files:**
- Modify: `client/art/muzzle_flash_kit.gd`
- Test: `tests/art_muzzle_flash_kit_test.gd` (append)

Pure linear fade of remaining-life over TTL, clamped to `[0,1]` — the renderer calls this each frame to drive the flash's alpha. Pure → unit-tested.

- [ ] **Step 1: Write the failing test** — append to `tests/art_muzzle_flash_kit_test.gd`:

```gdscript
func test_alpha_for_is_linear_and_clamped() -> void:
	var ttl := MuzzleFlashKit.TTL
	assert_almost_eq(MuzzleFlashKit.alpha_for(ttl, ttl), 1.0, 0.001, "full life = fully opaque")
	assert_almost_eq(MuzzleFlashKit.alpha_for(0.0, ttl), 0.0, 0.001, "no life left = invisible")
	assert_almost_eq(MuzzleFlashKit.alpha_for(ttl * 0.5, ttl), 0.5, 0.001, "half life = half alpha")
	assert_almost_eq(MuzzleFlashKit.alpha_for(ttl * 2.0, ttl), 1.0, 0.001, "over-full clamps to 1")
	assert_almost_eq(MuzzleFlashKit.alpha_for(-1.0, ttl), 0.0, 0.001, "negative clamps to 0")

func test_alpha_for_handles_zero_ttl() -> void:
	assert_almost_eq(MuzzleFlashKit.alpha_for(1.0, 0.0), 0.0, 0.001, "zero/invalid ttl -> 0, never divide-by-zero")
```

- [ ] **Step 2: Run, verify it fails** — `--test --filter=muzzle`. Expected: FAIL (`alpha_for` not found).

- [ ] **Step 3: Implement** — append to `client/art/muzzle_flash_kit.gd`:

```gdscript
## Linear fade: fraction of TTL remaining, clamped to [0,1]. Pure. Guards a non-positive ttl.
static func alpha_for(remaining: float, ttl: float) -> float:
	if ttl <= 0.0:
		return 0.0
	return clampf(remaining / ttl, 0.0, 1.0)
```

- [ ] **Step 4: Run, verify pass** — `--test --filter=muzzle`. Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(m7-p2): MuzzleFlashKit.alpha_for pure fade

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Wire the flash pool into the renderer

**Files:**
- Modify: `client/world_renderer.gd` — tracer/VFX region only (pool state, `setup()`, `_spawn_tracer()`, `update()`, new `_spawn_flash`/`_age_flashes`)

Mirror the existing tracer pool. The flash spawns from inside `_spawn_tracer()` (the funnel both local and remote shots pass through) at the muzzle `origin`, and ages out in `update()` next to the tracers. Do NOT touch `_make_entity_mesh`, the structure pool, the vehicle pool, `client_main`, or any non-renderer file.

- [ ] **Step 1: Add pool state.** Next to the tracer state (after `var _tracer_idx: int = 0`), add:

```gdscript
# -- muzzle flash pool (MuzzleFlashKit; mirrors the tracer pool) ---------------
const FLASH_POOL := 16
var _flashes: Array = []          # [{node: MeshInstance3D, mat: StandardMaterial3D, die: float}]
var _flash_idx: int = 0
```

- [ ] **Step 2: Build the flash pool in `setup()`.** Immediately after the existing tracer-pool `for _i in TRACER_POOL:` loop (before the viewmodel block), add:

```gdscript
	# Muzzle flash pool — brief emissive plates at the muzzle, hidden until a shot is fired.
	for _i in FLASH_POOL:
		var fn := MuzzleFlashKit.build()
		fn.visible = false
		add_child(fn)
		_flashes.append({"node": fn, "mat": fn.material_override, "die": 0.0})
```

- [ ] **Step 3: Spawn a flash from `_spawn_tracer()`.** At the END of `_spawn_tracer(origin, fwd, now)` (after the tracer is positioned/shown), add one line:

```gdscript
	_spawn_flash(origin, fwd, now)
```

- [ ] **Step 4: Add `_spawn_flash()` and `_age_flashes()`** (place them right after `_age_tracers()`):

```gdscript
func _spawn_flash(origin: Vector3, fwd: Vector3, now: float) -> void:
	if _flashes.is_empty():
		return
	var up := Vector3.UP if absf(fwd.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var f: Dictionary = _flashes[_flash_idx]
	_flash_idx = (_flash_idx + 1) % _flashes.size()
	var node: MeshInstance3D = f["node"]
	node.global_transform = Transform3D(Basis.looking_at(fwd, up), origin)
	var c := MuzzleFlashKit.COLOR
	c.a = 1.0
	(f["mat"] as StandardMaterial3D).albedo_color = c
	node.visible = true
	f["die"] = now + MuzzleFlashKit.TTL


func _age_flashes(now: float) -> void:
	for f: Dictionary in _flashes:
		var node: MeshInstance3D = f["node"]
		if not node.visible:
			continue
		var remaining: float = float(f["die"]) - now
		if remaining <= 0.0:
			node.visible = false
		else:
			var c := MuzzleFlashKit.COLOR
			c.a = MuzzleFlashKit.alpha_for(remaining, MuzzleFlashKit.TTL)
			(f["mat"] as StandardMaterial3D).albedo_color = c
```

- [ ] **Step 5: Age the flashes each frame.** In `update()`, directly after the existing `_age_tracers(now)` call, add:

```gdscript
	_age_flashes(now)
```

- [ ] **Step 6: Import + run the FULL unit suite** — `godot --headless --path . --import` then `godot --headless --path . -- --test 2>&1 | tee /tmp/full.log`. Expected: **all tests green** (existing suite + `muzzle` tests), zero regressions.

- [ ] **Step 7: Headless scene-load smoke** — `godot --headless --path . client/art/preview/kit_preview.tscn --quit-after 2 2>&1 | tee /tmp/preview.log`. Expected: clean exit, no `SCRIPT ERROR` / `Parse Error`. (Pre-existing leaked-instance warnings are fine.)

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(m7-p2): pooled muzzle flash at the tracer spawn seam

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 9 (owner playtest gate):** Owner runs a live match (client on the home laptop → server+bots on `game2`, per [`docs/runbooks/running-client.md`](../../runbooks/running-client.md)) and confirms: own gunfire and other players' fire show a brief muzzle flash at the barrel that reads well and is not distracting/too large/too persistent. Tune `MuzzleFlashKit.SIZE` / `TTL` / `COLOR` per feel — playtest knobs, not blockers. Record sign-off on [`M7-art-ux.md`](../../milestones/M7-art-ux.md).

---

## Self-review checklist (run before handoff)
- **Spec coverage (§4.1 muzzle flash):** emissive flash mesh (T1), fade (T2), spawned at local + remote shot seam + aged per frame (T3). Tracer weapon-tinting / impact / death-feedback explicitly deferred (Scope) — other Track B increments / wire-gated.
- **Isolation / conflict-free with M11:** only `client/world_renderer.gd`'s tracer/VFX region is modified; new `client/art/muzzle_flash_kit.gd` + test are additive. No edit to `_make_entity_mesh`, the structure/vehicle pools, `client_main`, `shared/`, server, bot, or `project.godot`. Verify with `git diff --name-only master` before Task 3's commit — only the kit + test until then, plus `client/world_renderer.gd` at Task 3.
- **No placeholders:** every code step is complete, runnable GDScript; every test asserts.
- **Type consistency:** `MuzzleFlashKit.build()`/`alpha_for()` and consts `COLOR`/`SIZE`/`THICK`/`TTL` are stable across tasks; the pool dict shape `{node, mat, die}` matches the tracer pool; `_spawn_flash`/`_age_flashes` signatures match their call sites.
- **Determinism/testability:** kit tests assert geometry/material/pure values; renderer pool is scene-smoke + playtest validated (consistent with the existing untested tracer pool) — headless-safe (AGENTS.md §10).

## Execution handoff
Run with **superpowers:subagent-driven-development** (group the two kit tasks T1+T2 into one implementer dispatch; give the renderer-integration T3 a read-only spec review — it is the only existing-file edit) or **superpowers:executing-plans**. All tasks run now on a branch off `master`; none waits on M11.
