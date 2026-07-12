# M19-P5 Riot Shield Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the Support Riot Shield gadget — a carried, directional bullet-block: while a held input bit is set, frontal small-arms fire is absorbed into a finite server-owned shield-HP pool at the cost of move speed and primary fire; flanks/explosives/melee/back-stabs bypass.

**Architecture:** A pure `shared/sim/riot_shield.gd` module owns the arc geometry + HP arithmetic (shared by the damage path and tests). The *cost* (slower move, no sprint, no fire) is a shared `Pawn.step` rule driven by an injected `cmd["shielded"]` flag — mirroring the existing `stimmed` pattern — so it predicts identically on client and server. The *block* + HP pool live server-side in `_apply_pawn_damage`, where the source bearing is already computed. Wire footprint is one new button bit + one trailing SELF_STATE byte (`VERSION` 10→11); no SNAPSHOT change.

**Tech Stack:** Godot 4.6 GDScript; `TestCase`/`tests/server_fixture.gd` harness; Rust native encoder untouched (no SNAPSHOT change). Design: `docs/superpowers/specs/2026-07-12-riot-shield-design.md`.

---

## File map

- **Create** `shared/sim/riot_shield.gd` — pure arc/HP module (`blocks`, `is_small_arms`, constants).
- **Modify** `shared/net/input_command.gd` — add `BTN_SHIELD = 1024`.
- **Modify** `shared/net/protocol.gd` — `VERSION` 10→11; `encode_self_state`/`decode_self_state` gain trailing `shield_hp_frac` byte; header history line.
- **Modify** `shared/sim/pawn.gd` — shield fields + movement/sprint/fire-lockout rule from `cmd["shielded"]`.
- **Modify** `server/server_main.gd` — shield HP lifecycle, `_apply_pawn_damage` block, `cmd["shielded"]` injection, regen step, respawn + `_apply_loadout_to_client` reset, SELF_STATE arg.
- **Modify** `server/fire.gd` — suppress firing while the shooter is shield-up.
- **Modify** `shared/sim/loadout.gd` — add `GADGET_RIOT_SHIELD` to `IMPLEMENTED_GADGETS`.
- **Modify** `client/client_main.gd` — set `BTN_SHIELD` from input + inject `cmd["shielded"]`; HUD shield bar from SELF_STATE.
- **Modify** `client/weapon_predictor.gd` (or the client fire-predict site) — mirror the fire-lockout.
- **Modify** `client/menus/class_select_panel.gd` — un-grey Riot Shield + blurb.
- **Modify** `bots/exercisers.gd` (+ `bots/bot_driver.gd` if needed) — shield-Support bots raise the shield under fire; deterministic drill.
- **Create** tests: `tests/riot_shield_geometry_test.gd`, `tests/pawn_riot_shield_test.gd`, `tests/riot_shield_server_test.gd`, `tests/protocol_riot_shield_test.gd`, `tests/loadout_riot_shield_test.gd`, `tests/riot_shield_gate_test.gd`.
- **Modify** `docs/TASKS.md`, `docs/STATUS.md`.

Constants (design §D, gate-tunable): `SHIELD_HP=300`, `SHIELD_ARC_DEG=75` (half-angle), `SHIELD_SPEED_MULT=0.7`, `SHIELD_REGEN_DELAY_TICKS=90`, `SHIELD_REGEN_PER_TICK=2` (≈60 hp/s @30Hz), `SHIELD_BREAK_TICKS=150`. Tick rate is 30 Hz (confirm via `Sim`/`SimLoop` `TICK`/`dt` when wiring regen).

---

## Task 1: Pure `riot_shield.gd` module (arc geometry + small-arms classifier)

**Files:**
- Create: `shared/sim/riot_shield.gd`
- Test: `tests/riot_shield_geometry_test.gd`

- [ ] **Step 1: Write the failing test**

```gdscript
# tests/riot_shield_geometry_test.gd
extends TestCase
## M19 P5: pure Riot Shield arc geometry + small-arms classifier.

func test_blocks_dead_ahead() -> void:
	# victim facing +Z (yaw 0); source directly in front -> bearing 0 -> blocked.
	assert_true(RiotShield.blocks(0.0, 0.0), "dead-ahead is blocked")

func test_blocks_at_arc_edge_and_beyond() -> void:
	var edge := deg_to_rad(RiotShield.SHIELD_ARC_DEG)
	assert_true(RiotShield.blocks(0.0, edge - 0.01), "just inside the arc is blocked")
	assert_false(RiotShield.blocks(0.0, edge + 0.01), "just past the arc is open")

func test_open_from_behind() -> void:
	assert_false(RiotShield.blocks(0.0, PI), "directly behind is open")

func test_symmetric_left_right() -> void:
	var a := deg_to_rad(RiotShield.SHIELD_ARC_DEG) - 0.05
	assert_true(RiotShield.blocks(0.0, a), "right side inside arc blocked")
	assert_true(RiotShield.blocks(0.0, -a), "left side inside arc blocked")

func test_wraps_across_pi() -> void:
	# victim facing yaw ~PI; a source bearing near -PI is the same direction -> blocked.
	assert_true(RiotShield.blocks(PI - 0.02, -PI + 0.02), "wrap-around front is blocked")

func test_small_arms_classifier() -> void:
	assert_true(RiotShield.is_small_arms(Revive.Source.BULLET, false), "front bullet is small-arms")
	assert_false(RiotShield.is_small_arms(Revive.Source.BULLET, true), "back-stab bypasses")
	assert_false(RiotShield.is_small_arms(Revive.Source.BLAST, false), "explosive bypasses")
	assert_false(RiotShield.is_small_arms(Revive.Source.FALL, false), "fall bypasses")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter riot_shield_geometry`
Expected: FAIL — `RiotShield` not found. (If `--filter` isn't supported, run the full `--test` suite and confirm this file errors.)

- [ ] **Step 3: Implement the module**

```gdscript
# shared/sim/riot_shield.gd
class_name RiotShield
extends Object
## Pure Support Riot Shield rules: the frontal-arc bullet block + the shield-HP pool constants.
## Geometry matches DamageDir.bearing's atan2(dx,dz) convention (yaw 0 faces +Z).

const SHIELD_HP := 300              # full shield pool (server-owned)
const SHIELD_ARC_DEG := 75.0        # half-angle of the protected frontal arc (150 deg cover)
const SHIELD_SPEED_MULT := 0.7      # move-speed multiplier while shield up
const SHIELD_REGEN_DELAY_TICKS := 90  # no-hit delay before the pool regenerates (~3 s @30Hz)
const SHIELD_REGEN_PER_TICK := 2    # pool refill per tick once regen starts (~60 hp/s)
const SHIELD_BREAK_TICKS := 150     # forced-down lockout after a full break (~5 s)

## True when a source at `bearing` (radians, from DamageDir.bearing) lies within the frontal
## arc of a victim facing `facing_yaw`. Uses shortest signed angular difference (wraps ±PI).
static func blocks(facing_yaw: float, bearing: float) -> bool:
	var d: float = wrapf(bearing - facing_yaw, -PI, PI)
	return absf(d) <= deg_to_rad(SHIELD_ARC_DEG)

## True only for direct small-arms fire (bullets), excluding back-stabs. Explosive/blast/melee/
## fall all return false -> they bypass the shield entirely (design counterplay).
static func is_small_arms(source: int, backstab: bool) -> bool:
	return source == Revive.Source.BULLET and not backstab
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter riot_shield_geometry`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add shared/sim/riot_shield.gd tests/riot_shield_geometry_test.gd
git commit -m "feat(m19-p5): pure RiotShield arc/HP module + geometry tests"
```

**Note for executor:** verify `Revive.Source.BULLET`/`BLAST`/`FALL`/`MELEE` exist (grep `enum Source` in `shared/sim/revive.gd`) and that back-stab is a distinct flag (grep `backstab` in `server/`). If back-stab is encoded as a `source` value rather than a bool, change `is_small_arms(source, backstab)` to test `source != Source.BACKSTAB` and update the call site + test accordingly.

---

## Task 2: Wire — `BTN_SHIELD`, SELF_STATE `shield_hp_frac`, VERSION 10→11

**Files:**
- Modify: `shared/net/input_command.gd`
- Modify: `shared/net/protocol.gd`
- Test: `tests/protocol_riot_shield_test.gd`

- [ ] **Step 1: Write the failing test**

```gdscript
# tests/protocol_riot_shield_test.gd
extends TestCase
## M19 P5: wire — BTN_SHIELD round-trips; SELF_STATE carries the shield-HP fraction; VERSION==11.

func test_version_is_11() -> void:
	assert_eq(Protocol.VERSION, 11, "VERSION bumped for the shield wire")

func test_btn_shield_round_trips() -> void:
	var f := {"move_x": 0.0, "move_y": 0.0, "yaw": 0.0, "pitch": 0.0,
		"buttons": InputCommand.BTN_SHIELD | InputCommand.BTN_AIM, "seq": 1}
	var bytes := InputCommand.encode([f])
	var dec: Dictionary = InputCommand.decode(bytes)
	var frames: Array = dec["frames"] if dec.has("frames") else [dec]
	var got: int = int(frames[0]["buttons"])
	assert_true((got & InputCommand.BTN_SHIELD) != 0, "BTN_SHIELD survives the wire")

func test_self_state_carries_shield_frac() -> void:
	# 255 == full pool; decode must read it back off the trailing byte.
	var bytes := Protocol.encode_self_state(30, false, 0, 0, [], false, 0.0, 0, 0, false,
		0.0, 0.0, 100.0, 0.0, true, false, 0, 0.0, false, 0, false, 0, 0, 0, 0, 0, 0, false, 255)
	var d: Dictionary = Protocol.decode_self_state(bytes)
	assert_eq(int(d["shield_hp_frac"]), 255, "shield fraction round-trips")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter protocol_riot_shield`
Expected: FAIL — `BTN_SHIELD` undefined / VERSION != 11 / wrong self_state arity.

- [ ] **Step 3: Implement**

In `shared/net/input_command.gd`, after `const BTN_SHOVEL := 512`:
```gdscript
const BTN_SHIELD := 1024   # bit 10: hold to raise the Support riot shield (client-gated on the equipped gadget)
```
The buttons field is already a `u16` on the wire (`put_u16(... & 0xFFFF)`), so bit 10 needs no frame-size change — confirm `FRAME_SIZE` stays 18.

In `shared/net/protocol.gd`:
1. `const VERSION := 11` and prepend a header history line:
   `# 11: M19 P5 riot shield — BTN_SHIELD bit + SELF_STATE trailing shield_hp_frac u8 (2026-07-12)`
2. Append `shield_hp_frac: int = 0` as the **last** parameter of `encode_self_state(...)` and `buf.put_u8(shield_hp_frac & 0xFF)` as the **last** write (after the M19-P4 mount tail), with a comment: `# Owner-only shield-HP fraction (0-255), appended last so older decoders ignore it.`
3. In `decode_self_state`, guard-read the trailing byte the same way the mount tail is read: `d["shield_hp_frac"] = buf.get_u8() if buf.get_available_bytes() >= 1 else 0`.

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter protocol_riot_shield`
Expected: PASS (3 tests). Then run the existing `tests/protocol_*` self-state tests to confirm no regression: `godot --headless --path . -- --test --filter protocol`.

**Note:** `encode_self_state` has many positional args. Grep every call site (`grep -rn "encode_self_state" server/`) — because the new arg has a default (`= 0`), existing calls still compile, but the real send site in `server_main.gd` is updated in Task 4. Update the test's positional call to match the true current arity if it drifted.

- [ ] **Step 5: Commit**

```bash
git add shared/net/input_command.gd shared/net/protocol.gd tests/protocol_riot_shield_test.gd
git commit -m "feat(m19-p5): wire — BTN_SHIELD + SELF_STATE shield_hp_frac, VERSION 10->11"
```

---

## Task 3: Shared movement/fire-lockout rule in `Pawn.step`

**Files:**
- Modify: `shared/sim/pawn.gd`
- Test: `tests/pawn_riot_shield_test.gd`

- [ ] **Step 1: Write the failing test** (model on `tests/pawn_stim_test.gd`)

```gdscript
# tests/pawn_riot_shield_test.gd
extends TestCase
## M19 P5: shared Pawn.step riot-shield cost — slower move, no sprint, no fire, driven by cmd["shielded"].

func _cmd(buttons: int, shielded: bool) -> Dictionary:
	return {"move_x": 0.0, "move_y": 1.0, "yaw": 0.0, "pitch": 0.0, "buttons": buttons,
		"shielded": shielded}

func test_shield_slows_movement() -> void:
	var base := Pawn.new(); base.pos = Vector3.ZERO; base.stamina = 100.0
	var sh := Pawn.new(); sh.pos = Vector3.ZERO; sh.stamina = 100.0
	base.step(_cmd(0, false), 0.1, 1000.0)
	sh.step(_cmd(0, true), 0.1, 1000.0)
	assert_true(sh.pos.distance_to(Vector3.ZERO) < base.pos.distance_to(Vector3.ZERO) - 0.001,
		"shield-up pawn moves slower")

func test_shield_blocks_sprint() -> void:
	var sh := Pawn.new(); sh.pos = Vector3.ZERO; sh.stamina = 100.0
	var slow := sh.step(_cmd(InputCommand.BTN_SPRINT, true), 0.1, 1000.0)
	var sh2 := Pawn.new(); sh2.pos = Vector3.ZERO; sh2.stamina = 100.0
	var walk := sh2.step(_cmd(0, true), 0.1, 1000.0)
	assert_true(sh.pos.distance_to(Vector3.ZERO) <= sh2.pos.distance_to(Vector3.ZERO) + 0.001,
		"sprint gives no speed bonus while shield up")

func test_shielded_wants_no_fire() -> void:
	var sh := Pawn.new()
	assert_true(sh.fire_suppressed_by_shield(InputCommand.BTN_FIRE, true), "fire suppressed while shield up")
	assert_false(sh.fire_suppressed_by_shield(InputCommand.BTN_FIRE, false), "fire allowed with shield down")
```

Adjust the `Pawn.step`/`Pawn.new` construction to the real fixture (grep `tests/pawn_stim_test.gd` for how it builds a pawn + reads a result). If `step` returns void, assert on `pawn.pos` deltas instead of a returned value (as above).

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter pawn_riot_shield`
Expected: FAIL — `fire_suppressed_by_shield` undefined / no speed difference.

- [ ] **Step 3: Implement in `shared/sim/pawn.gd`**

At the `var sprinting :=` line (currently pawn.gd:104), fold shield into sprint + speed:
```gdscript
	var shielded := bool(cmd.get("shielded", false))
	var sprinting := bool(buttons & InputCommand.BTN_SPRINT) and stance == Stance.STAND and stamina > 0.0 and has_move and not _sprint_locked and not shielded
	var speed := Stance.speed(stance) * (SPRINT_MULT if sprinting else 1.0) * Armor.speed_mult(armor_class) * (STIM_SPEED_MULT if stimmed else 1.0) * (RiotShield.SHIELD_SPEED_MULT if shielded else 1.0)
```
Add a small pure helper the fire path + tests share:
```gdscript
## True when a shield-up pawn's primary fire is locked out (they're holding the shield).
static func fire_suppressed_by_shield(buttons: int, shielded: bool) -> bool:
	return shielded and (buttons & InputCommand.BTN_FIRE) != 0
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter pawn_riot_shield`
Expected: PASS (3 tests). Run `--filter pawn` to confirm no movement-test regression.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/pawn.gd tests/pawn_riot_shield_test.gd
git commit -m "feat(m19-p5): shared Pawn.step shield cost — slower move, no sprint, fire lockout"
```

---

## Task 4: Server damage block + shield-HP lifecycle + injection

**Files:**
- Modify: `server/server_main.gd` (pawn fields, `_apply_pawn_damage`, injection loop, regen step, `_handle_respawns`, `_apply_loadout_to_client`, SELF_STATE send)
- Modify: `server/fire.gd` (fire lockout)
- Modify: `shared/sim/pawn.gd` (shield state fields)
- Test: `tests/riot_shield_server_test.gd`

- [ ] **Step 1: Write the failing test** (model on `tests/stim_test.gd`, real server via `server_fixture.gd`)

```gdscript
# tests/riot_shield_server_test.gd
extends TestCase
const F := preload("res://tests/server_fixture.gd")

func setup() -> void:
	Weapon.reset_registry()
	assert_true(Weapon.load_from_file("res://data/weapons.json")["ok"], "weapons load")
func teardown() -> void:
	Weapon.reset_registry()

func _srv() -> Node:
	var srv = autofree(F.make_server())
	srv._gadgets = Gadget.load_file("res://data/gadgets.json")
	return srv

# A Support client with the shield gadget, shield raised, facing +Z (yaw 0), full pool.
func _shield_client(srv, id: int, pos: Vector3) -> Pawn:
	var c := F.add_client(srv, id, 0, false)
	c["class"] = Loadout.SUPPORT
	c["loadout"]["class"] = Loadout.SUPPORT
	c["loadout"]["gadget"] = Loadout.GADGET_RIOT_SHIELD
	var p: Pawn = srv._sim.world.get_pawn(id)
	srv._apply_loadout_to_client(c, p)   # seeds shield_hp full
	p.pos = pos; p.yaw = 0.0; p.alive = true; p.health = 100
	p.shield_up = true   # server-derived normally; forced here for a deterministic hit
	return p

func test_frontal_bullet_absorbed_into_pool() -> void:
	var srv = _srv()
	var v := _shield_client(srv, 1, Vector3.ZERO)
	# attacker dead ahead (+Z): source pos in front of the victim
	var atk := srv._sim.world.get_pawn(F.add_client(srv, 2, 1, false)["id"] if false else 2)
	# ensure attacker pawn exists at +Z
	F.add_client(srv, 2, 1, false)
	srv._sim.world.get_pawn(2).pos = Vector3(0, 0, 5)
	var hp0 := v.health; var pool0 := v.shield_hp
	srv._apply_pawn_damage(1, v, 40, false, Revive.Source.BULLET, 2, 0)
	assert_eq(v.health, hp0, "health unchanged — frontal bullet blocked")
	assert_eq(v.shield_hp, pool0 - 40, "pool absorbed the damage")

func test_flank_bullet_hits_health() -> void:
	var srv = _srv()
	var v := _shield_client(srv, 1, Vector3.ZERO)
	F.add_client(srv, 2, 1, false)
	srv._sim.world.get_pawn(2).pos = Vector3(5, 0, 0)  # 90 deg to the side -> outside a 75deg half-arc
	var hp0 := v.health
	srv._apply_pawn_damage(1, v, 40, false, Revive.Source.BULLET, 2, 0)
	assert_true(v.health < hp0, "flank bullet bypasses the shield")

func test_explosive_bypasses_frontally() -> void:
	var srv = _srv()
	var v := _shield_client(srv, 1, Vector3.ZERO)
	F.add_client(srv, 2, 1, false)
	srv._sim.world.get_pawn(2).pos = Vector3(0, 0, 5)
	var hp0 := v.health
	srv._apply_pawn_damage(1, v, 40, false, Revive.Source.BLAST, 2, 0)
	assert_true(v.health < hp0, "frontal explosive bypasses the shield")

func test_break_forces_down_no_overflow_to_health() -> void:
	var srv = _srv()
	var v := _shield_client(srv, 1, Vector3.ZERO)
	v.shield_hp = 30
	F.add_client(srv, 2, 1, false)
	srv._sim.world.get_pawn(2).pos = Vector3(0, 0, 5)
	var hp0 := v.health
	srv._apply_pawn_damage(1, v, 100, false, Revive.Source.BULLET, 2, 0)  # overkills the 30 pool
	assert_eq(v.health, hp0, "the shot that breaks the shield does not spill into health")
	assert_eq(v.shield_hp, 0, "pool emptied")
	assert_true(v.shield_broken_until_tick > srv._sim.tick, "break lockout armed")

func test_respawn_rearms_shield() -> void:
	var srv = _srv()
	var v := _shield_client(srv, 1, Vector3.ZERO)
	v.shield_hp = 0; v.shield_broken_until_tick = srv._sim.tick + 999
	v.alive = false
	srv._clients[1]["respawn_tick"] = srv._sim.tick
	srv._handle_respawns()
	assert_eq(v.shield_hp, RiotShield.SHIELD_HP, "respawn restores the pool")
	assert_eq(v.shield_broken_until_tick, 0, "respawn clears the break lockout")
```

**Executor:** `server_fixture.gd`'s exact `add_client` return shape and pawn-id wiring may differ — read `tests/stim_test.gd` + `tests/server_fixture.gd` and adapt the attacker-pawn construction (the `if false else` scaffolding above is a placeholder to be replaced with the real two-client setup used in `stim_test.gd`). Keep the six behavioral assertions.

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter riot_shield_server`
Expected: FAIL — `shield_up`/`shield_hp`/`shield_broken_until_tick` undefined.

- [ ] **Step 3a: Add pawn shield state fields** (`shared/sim/pawn.gd`, near `stim_until_tick`):

```gdscript
var shield_up: bool = false            # M19 P5: derived per-tick server-side (gadget + BTN_SHIELD + not broken); not replicated
var shield_hp: int = RiotShield.SHIELD_HP   # server-owned frontal-block pool
var shield_last_hit_tick: int = 0      # last tick the shield absorbed a hit (gates regen)
var shield_broken_until_tick: int = 0  # forced-down lockout after a full break
```

- [ ] **Step 3b: Damage block** in `server/server_main.gd::_apply_pawn_damage`, inserted right after the `if victim.is_downed: return` guard and **before** the armor/headshot block (uses the `bearing` — compute it here from the source, mirroring the existing `DamageDir.bearing` use lower in the function):

```gdscript
	# M19 P5 riot shield: a raised shield absorbs frontal small-arms into its own pool.
	if victim.shield_up and RiotShield.is_small_arms(source, headshot and source == Revive.Source.BULLET and false):
		var atk: Pawn = _sim.world.get_pawn(killer_id)
		if atk != null and RiotShield.blocks(victim.yaw, DamageDir.bearing(victim.pos, atk.pos)):
			victim.shield_last_hit_tick = _sim.tick
			victim.combat_until_tick = _sim.tick + COMBAT_FLAG_TICKS
			if victim.shield_hp > dmg:
				victim.shield_hp -= dmg
				_stats.shield_blocks = int(_stats.get("shield_blocks", 0)) + 1
				return   # fully absorbed — no health loss, no bleed, no ledger
			# the breaking shot: empty the pool, force down, arm the lockout; no overflow to health
			victim.shield_hp = 0
			victim.shield_up = false
			victim.shield_broken_until_tick = _sim.tick + RiotShield.SHIELD_BREAK_TICKS
			_stats.shield_breaks = int(_stats.get("shield_breaks", 0)) + 1
			return
```

**Executor:** resolve the back-stab argument to `is_small_arms` against the real back-stab encoding found in Task 1's note (do NOT ship the `and false` placeholder — replace it with the true back-stab predicate). Confirm `_stats` is a Dictionary-like counter bag (grep `_stats.` in `server_main.gd`); if it's a typed object, add explicit `shield_blocks`/`shield_breaks` fields instead of `.get`.

- [ ] **Step 3c: `cmd["shielded"]` injection** — extend the existing stim-injection loop (`server_main.gd` ~589) so the same pass derives shield-up and injects it. Replace the loop body:

```gdscript
	for id in inputs:
		var sp: Pawn = _sim.world.pawns.get(id)
		if sp == null:
			continue
		var want_shield := false
		if _clients.has(id) and int(_clients[id]["loadout"]["gadget"]) == Loadout.GADGET_RIOT_SHIELD:
			var btns := int((inputs[id] as Dictionary).get("buttons", 0))
			if (btns & InputCommand.BTN_SHIELD) != 0 and _sim.tick >= sp.shield_broken_until_tick and sp.shield_hp > 0:
				want_shield = true
		sp.shield_up = want_shield
		if (_sim.tick < sp.stim_until_tick) or want_shield:
			var mod_cmd: Dictionary = (inputs[id] as Dictionary).duplicate()
			if _sim.tick < sp.stim_until_tick:
				mod_cmd["stimmed"] = true
			if want_shield:
				mod_cmd["shielded"] = true
			inputs[id] = mod_cmd
```

- [ ] **Step 3d: Shield regen step** — add a per-tick pass (call it near where stim/suppression decay runs; grep `_step_suppression_decay` for the call site). Add:

```gdscript
func _step_shield_regen() -> void:
	for id in _clients:
		var p: Pawn = _sim.world.get_pawn(id)
		if p == null or not p.alive: continue
		if p.shield_broken_until_tick > 0 and _sim.tick >= p.shield_broken_until_tick:
			p.shield_broken_until_tick = 0
			p.shield_hp = RiotShield.SHIELD_HP   # clean re-arm to full after the lockout
		elif p.shield_broken_until_tick == 0 and p.shield_hp < RiotShield.SHIELD_HP \
				and (_sim.tick - p.shield_last_hit_tick) >= RiotShield.SHIELD_REGEN_DELAY_TICKS:
			p.shield_hp = mini(RiotShield.SHIELD_HP, p.shield_hp + RiotShield.SHIELD_REGEN_PER_TICK)
```
and invoke `_step_shield_regen()` once per tick in the main server tick (same neighborhood as the stim/suppression steps).

- [ ] **Step 3e: Respawn + loadout reset.** In `_handle_respawns` (server_main.gd ~903-916, the block that resets `p.suppression`, `p.bleeding`…), add:
```gdscript
			p.shield_hp = RiotShield.SHIELD_HP
			p.shield_up = false
			p.shield_last_hit_tick = 0
			p.shield_broken_until_tick = 0
```
In `_apply_loadout_to_client`, in the `if p != null:` tail, add the same reset (so a mid-life respec to/from the shield seeds a clean pool):
```gdscript
		p.shield_hp = RiotShield.SHIELD_HP
		p.shield_up = false
		p.shield_broken_until_tick = 0
```

- [ ] **Step 3f: Fire lockout** in `server/fire.gd`. At both fire gates (lines ~29 and ~143 where `buttons & BTN_FIRE` is tested), also require the shooter is not shield-up. The cleanest: fetch the shooter pawn (already in scope as the firing pawn) and skip when `shooter_pawn.shield_up`. Add to the guard, e.g. line 29:
```gdscript
		if inp == null or (int(inp["buttons"]) & InputCommand.BTN_FIRE) == 0 or shooter_pawn.shield_up: continue
```
Match the actual pawn variable name in each loop (grep the surrounding lines).

- [ ] **Step 3g: SELF_STATE send.** At the `encode_self_state(...)` call in `server_main.gd` (grep it — one authoritative send site), pass the shield fraction as the new trailing arg:
```gdscript
		var _shield_frac := int(round(255.0 * float(p.shield_hp) / float(RiotShield.SHIELD_HP)))
```
and append `_shield_frac` as the final argument.

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter riot_shield_server`
Expected: PASS (6 tests). Then full suite: `godot --headless --path . -- --test` — expect no regression (record the run/fail counts).

- [ ] **Step 5: Commit**

```bash
git add server/server_main.gd server/fire.gd shared/sim/pawn.gd tests/riot_shield_server_test.gd
git commit -m "feat(m19-p5): server shield block + HP lifecycle + injection + fire lockout"
```

---

## Task 5: Un-grey the gadget in the loadout registry

**Files:**
- Modify: `shared/sim/loadout.gd`
- Test: `tests/loadout_riot_shield_test.gd`

- [ ] **Step 1: Write the failing test**

```gdscript
# tests/loadout_riot_shield_test.gd
extends TestCase
func test_riot_shield_is_implemented() -> void:
	assert_true(Loadout.GADGET_RIOT_SHIELD in Loadout.IMPLEMENTED_GADGETS, "riot shield is built")
func test_support_can_select_riot_shield() -> void:
	var lo := Loadout.default_loadout(Loadout.SUPPORT)
	lo["gadget"] = Loadout.GADGET_RIOT_SHIELD
	var san := Loadout.sanitize(lo)
	assert_eq(int(san["gadget"]), Loadout.GADGET_RIOT_SHIELD, "sanitize keeps a Support riot shield")
func test_non_support_cannot() -> void:
	var lo := Loadout.default_loadout(Loadout.ASSAULT)
	lo["gadget"] = Loadout.GADGET_RIOT_SHIELD
	var san := Loadout.sanitize(lo)
	assert_true(int(san["gadget"]) != Loadout.GADGET_RIOT_SHIELD, "riot shield not offered to Assault")
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --path . -- --test --filter loadout_riot_shield`
Expected: FAIL — shield not in `IMPLEMENTED_GADGETS`.

- [ ] **Step 3: Implement.** In `shared/sim/loadout.gd`, add `GADGET_RIOT_SHIELD` to `IMPLEMENTED_GADGETS`:
```gdscript
const IMPLEMENTED_GADGETS := [GADGET_C4, GADGET_HEAL, GADGET_AMMO, GADGET_RPG, GADGET_REPAIR, GADGET_BREACH, GADGET_STIM, GADGET_SMOKE_WALL, GADGET_LMG_NEST, GADGET_RIOT_SHIELD]
```

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter loadout_riot_shield`
Expected: PASS (3 tests). Run `--filter loadout` — no regression.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/loadout.gd tests/loadout_riot_shield_test.gd
git commit -m "feat(m19-p5): add GADGET_RIOT_SHIELD to IMPLEMENTED_GADGETS"
```

---

## Task 6: Client input + HUD + class-select un-grey

**Files:**
- Modify: `client/client_main.gd` (set `BTN_SHIELD`, inject `cmd["shielded"]`, HUD shield bar)
- Modify: `client/weapon_predictor.gd` (or the client fire-predict site) — mirror the fire lockout
- Modify: `client/menus/class_select_panel.gd` (un-grey + blurb)

- [ ] **Step 1 (no unit test — client render/feel deferred per project norm; wire correctness is covered by Tasks 2-4 and the gate).** Implement:

**a.** In `client/client_main.gd::_produce_input_frame` (near the `stimmed` inject at ~590), set the button + flag from the local shield intent, gated on the equipped gadget:
```gdscript
	if int(_loadout.get("gadget", -1)) == Loadout.GADGET_RIOT_SHIELD and _shield_held:
		cmd["buttons"] = int(cmd["buttons"]) | InputCommand.BTN_SHIELD
		cmd["shielded"] = true
```
Add a `var _shield_held := false` toggled by an input action in `_unhandled_input`/`_read_input` (bind to a key, e.g. the gadget/secondary-use action or a dedicated `shield` action — match how ADS/prone are read). Ship it as a **toggle** (press flips `_shield_held`) for ergonomics; the sim only sees the held bit.

**b.** Mirror the fire lockout so the HUD doesn't predict phantom shots: in the client fire-predict path, gate firing with `Pawn.fire_suppressed_by_shield(buttons, _shield_held and int(_loadout.get("gadget",-1))==Loadout.GADGET_RIOT_SHIELD)` — i.e. suppress the predicted shot when the shield is up.

**c.** HUD: read `shield_hp_frac` off the decoded SELF_STATE and drive a small shield bar (reuse the heat/stamina bar widget pattern). If `_loadout.gadget != RIOT_SHIELD`, hide it. Visual polish/feel deferred to owner playtest — a functional bar is enough here.

**d.** In `client/menus/class_select_panel.gd`, remove the Riot Shield "(coming soon)" grey-out (it's now in `IMPLEMENTED_GADGETS`, so if the greying is data-driven off that list it may already be un-greyed — verify) and add the one-line blurb: `"Riot Shield — bulletproof frontal cover; slower, no primary fire."`

- [ ] **Step 2: Verify boot + connect smoke.** Launch a headless server + one bot + the client headless-connect smoke used elsewhere (grep `ci/*connect*` / `--connect-smoke`), confirm VERSION-11 handshake succeeds and no script errors. Record output.

- [ ] **Step 3: Commit**

```bash
git add client/client_main.gd client/weapon_predictor.gd client/menus/class_select_panel.gd
git commit -m "feat(m19-p5): client shield input (toggle->held bit), HUD bar, class-select un-grey"
```

---

## Task 7: Bot exerciser + deterministic gate drill

**Files:**
- Modify: `bots/exercisers.gd` (+ `bots/bot_driver.gd` if the shield bit needs forwarding)
- Test: `tests/riot_shield_gate_test.gd`

- [ ] **Step 1: Write the failing deterministic drill** (model on `tests/emplacement_gate_test.gd`)

```gdscript
# tests/riot_shield_gate_test.gd
extends TestCase
const F := preload("res://tests/server_fixture.gd")
## Deterministic drill: a shield-Support blocks a frontal burst, a flank shot lands, a heavy
## burst breaks the shield, and it re-arms after the lockout. Server paths only, no AI.

func setup() -> void:
	Weapon.reset_registry(); Weapon.load_from_file("res://data/weapons.json")
func teardown() -> void:
	Weapon.reset_registry()

func test_shield_drill_end_to_end() -> void:
	var srv = autofree(F.make_server()); srv._gadgets = Gadget.load_file("res://data/gadgets.json")
	# ... build a shield-Support (id 1, yaw 0) + attacker (id 2) reusing the Task-4 helpers ...
	# 1) frontal burst -> health intact, pool drained
	# 2) move attacker to the flank -> a bullet lands on health
	# 3) frontal overkill burst -> shield_up false + shield_broken_until_tick armed, no health overflow
	# 4) advance srv._sim.tick past the lockout + run _step_shield_regen -> shield_hp restored
	assert_true(true, "replace with the four-phase drive above")
```
Flesh out the four phases using the Task-4 helpers (copy them into a shared `tests/riot_shield_harness.gd` if reused, mirroring `tests/emplacement_harness.gd`).

- [ ] **Step 2: Run to verify it fails, then implement the drill + bot behavior.**

Bot behavior (`bots/exercisers.gd`): when a bot's loadout gadget is `GADGET_RIOT_SHIELD`, set `BTN_SHIELD` in its outgoing buttons while it is taking fire / advancing on a capture point (reuse the existing "under fire" / avoid-danger signal). Keep it restrained (not permanently up) so combat still resolves. Ensure `bots/bot_driver.gd` forwards `BTN_SHIELD` (it already forwards non-fire intent buttons at line ~576 — confirm `BTN_SHIELD` isn't masked out).

- [ ] **Step 3: Run to verify it passes**

Run: `godot --headless --path . -- --test --filter riot_shield_gate`
Expected: PASS. Full suite green.

- [ ] **Step 4: Commit**

```bash
git add bots/exercisers.gd bots/bot_driver.gd tests/riot_shield_gate_test.gd tests/riot_shield_harness.gd
git commit -m "feat(m19-p5): shield bot exerciser + deterministic gate drill"
```

---

## Task 8: Fleet gate + docs + land

**Files:**
- Modify: `docs/TASKS.md`, `docs/STATUS.md`

- [ ] **Step 1: Full unit suite.** `godot --headless --path . -- --test` → record `N run / 0 failed`.

- [ ] **Step 2: Native encoder present** (no SNAPSHOT change, but the gate host needs the .so): `cargo build --release --manifest-path native/snapshot_encoder/Cargo.toml`.

- [ ] **Step 3: 128-bot fleet gate** on game2, `conquest_town`, with shield-Support bots in the roster. Use the established stress/gate path (grep `docker/run-*gate*.sh` / `docker/stress.sh`). Success criteria: tick mean < 33.3 ms, `script_errors=0`, Conquest reaches a winner, and the reported shield counters (`shield_blocks`/`shield_breaks`) are > 0. Save evidence to `docs/gate-evidence/<ts>-m19-p5-riot-shield.txt`.

- [ ] **Step 4: Update docs.** In `docs/TASKS.md` M19 row + `docs/STATUS.md`: mark P5 Riot Shield done with the gate evidence line; note only Grapple (Assault) remains. Update the memory index topic `blockfire-m19-class-select-loadouts.md`.

- [ ] **Step 5: Land (AGENTS.md §11/§13).** `git fetch origin`; confirm nothing bumped `Protocol.VERSION` past 10 (coordinate if the M9-P2 agent touched protocol — unlikely); reconcile; merge `m19-p5-riot-shield` → `master` `--no-ff`; `git push origin master`. Run `/graphify --update` so the graph reflects the new module.

```bash
git add docs/TASKS.md docs/STATUS.md
git commit -m "docs(m19-p5): riot shield done — gate evidence, only Grapple remains"
git fetch origin && git checkout master && git merge --no-ff m19-p5-riot-shield && git push origin master
```

---

## Self-review notes

- **Spec coverage:** §B held-bit → Task 2/3/4/6; §C movement/fire → Task 3 + 4f; §D block + HP lifecycle → Task 4; §E wire → Task 2 + 4g; §F loadout/class-select → Task 5 + 6d; §G bots + drill → Task 7; §H tests → Tasks 1-7; §I budgets → verified at Task 8 gate. Deferred items (sidearm-while-shield, remote render) are documented, not tasked — correct.
- **Type consistency:** `shield_up`/`shield_hp`/`shield_last_hit_tick`/`shield_broken_until_tick` (pawn fields), `cmd["shielded"]` (injected flag), `BTN_SHIELD`, `shield_hp_frac` (wire), `RiotShield.blocks`/`is_small_arms`/`fire_suppressed_by_shield` — used consistently across tasks.
- **Executor unknowns flagged inline:** back-stab encoding (Task 1/4b), `server_fixture.gd` client/attacker shape (Task 4), `_stats` counter type (Task 4b), exact fire-path pawn var names (Task 4f), the SELF_STATE send-site arity (Task 4g), class-select greying data-source (Task 6d). Each task tells the executor to grep-and-adapt rather than assume.
