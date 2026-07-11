# M19 P2b-structure: BREACH + REPAIR gadgets

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship two "cheap-reuse" structure gadgets from spec §D — **BREACH** (Assault: placed charge that carves a walkable hole in a wall/floor after a short arm timer) and **REPAIR** (Engineer: held-use tool that re-fills chunk holes in a structure you aim at) — making both selectable in loadouts.

**Architecture:** Both gadgets reuse existing server systems. BREACH mirrors the `_mines` place/arm loop and calls the existing `_damage_structure(id, SRC_EXPLOSIVE, impact, radius)` carve path. REPAIR extends the existing latched `ServerSupport.step_repairs()` (today vehicle-only) with a structure branch built on `_store.repair_chunks(id, impact, radius)` and aim-marching (like the sledgehammer). No new pawn fields, no SELF_STATE layout change, **no wire VERSION bump** — only two new `GADGET_ACTION` sub-action codes.

**Tech Stack:** GDScript / Godot 4; server-authoritative sim (`server/server_main.gd`, `server/support.gd`); shared rules in `shared/sim/` (`gadget.gd`, `loadout.gd`, `structure.gd`); wire in `shared/net/protocol.gd`. TestCase harness: `godot --headless --path . -- --test [--filter=X]`; new test files need one `godot --headless --path . -- --import` before they're discovered.

**Scope reminders (do NOT do here):** No STIM, no SMOKE_WALL (that's the sibling P2b-medic plan). No LMG Nest, GRAPPLE, RIOT_SHIELD, SANDBAG. No client HUD/model art for the new gadgets beyond the minimum send-path wiring; the client class-select screen is P3. Keep `Weapon.RPG`/GADGET_RPG paths untouched.

**Key facts confirmed from the codebase (do not re-derive):**
- `Loadout.GADGET_REPAIR = 5`, `Loadout.GADGET_BREACH = 8` already exist (`shared/sim/loadout.gd:22,26`). `IMPLEMENTED_GADGETS := [GADGET_C4, GADGET_HEAL, GADGET_AMMO, GADGET_RPG]` (line 38) — a gadget is unselectable until added here.
- `gadget_options`: Assault `[C4, GRAPPLE, BREACH]`, Engineer `[RPG, C4, REPAIR]` (loadout.gd:56,58) — BREACH/REPAIR are already offered, just not implemented.
- `Gadget.KIND_*` currently 0–5 (REPAIR=5). `_KINDS` string→int map (gadget.gd:17). The catalog (`data/gadgets.json`) is keyed by `kind` int; `Gadget.def_of_kind(kind)` reads it. Convention: `KIND_*` value == `Loadout.GADGET_*` value where they overlap.
- `_place_mine(id,p,pos,facing)` (server_main.gd) is the place-template: gates on `int(_clients[id]["loadout"]["gadget"]) != Loadout.GADGET_MINE`, checks `max_active`, checks `place_range`, appends `{owner,team,pos,facing,armed_after_tick: _sim.tick + arm_delay_ticks}` to `_mines`.
- `_damage_structure(id: int, source: int, impact: Vector3, radius: float)` — carve path; `source` uses `PieceCatalog.SRC_EXPLOSIVE = 2`. Sledgehammer already calls it with `SRC_MELEE` after a `_store.march(eye, dir, range)` aim hit.
- `_store.march(origin, dir, max_dist) -> {hit:bool, id:int, dist:float}` (structure.gd:238). `_store.repair_chunks(id, impact, radius) -> {changed:bool, mask:int}` (structure.gd:159) re-fills holes.
- `ServerSupport.step_repairs()` (support.gd) is latched: `repairing[eid]=true` set by `GA_REPAIR_START`, cleared by `GA_REPAIR_STOP`; per tick it repairs `nearest_friendly_damaged_vehicle`; overheat via `Gadget.repair_heat_step(...)` using the `repairkit` def (`rate 6, range 4, overheat_ticks 50, cooldown_ticks 150`). It has **no gadget gate today** (any engineer holding repair repairs vehicles).
- Protocol GA sub-actions end at `GA_REPAIR_STOP = 8` (protocol.gd). `Protocol.encode_gadget_action(action, pos, dir, ??)` / `decode_gadget_action` already carry a pos + dir (used by C4/mine/RPG).
- `_handle_gadget_action` dispatch `match int(d["action"])` (server_main.gd ~1568) routes each GA code.
- Server fixture: `tests/server_fixture.gd` — `ServerFixture.make_server()`, `add_pawn(srv,id,team,pos)`, `add_client(srv,id,team,human)` (seeds `loadout = Loadout.default_loadout(ASSAULT)`). `srv._gadgets` is the loaded `Gadget` catalog; `srv._store` is a `StructureStore`. `SpyNet` records sends; `srv._net.bytes_of(msg)` returns them.

---

## Task 1: Register BREACH + REPAIR as implemented, add catalog defs

**Files:**
- Modify: `shared/sim/gadget.gd` (add `KIND_BREACH`, `_KINDS` entry)
- Modify: `shared/sim/loadout.gd:38` (`IMPLEMENTED_GADGETS`)
- Modify: `data/gadgets.json` (add `breach` def; `repairkit` already exists)
- Test: `tests/gadget_catalog_test.gd` (extend if present, else create) + `tests/loadout_sanitize_test.gd` (extend)

- [ ] **Step 1: Write failing test — BREACH/REPAIR are selectable and have defs**

Add to `tests/loadout_sanitize_test.gd` (a test file that already loads the weapon registry in `setup()` — mirror its `setup()`/`teardown()`; if it doesn't exist, create it and load `data/gadgets.json` + `data/weapons.json` in `setup()`):

```gdscript
func test_breach_and_repair_are_implemented() -> void:
	assert_true(Loadout.GADGET_BREACH in Loadout.IMPLEMENTED_GADGETS, "BREACH selectable")
	assert_true(Loadout.GADGET_REPAIR in Loadout.IMPLEMENTED_GADGETS, "REPAIR selectable")

func test_assault_breach_survives_sanitize() -> void:
	var cfg := Loadout.default_loadout(Loadout.ASSAULT)
	cfg["gadget"] = Loadout.GADGET_BREACH
	var s := Loadout.sanitize(cfg)
	assert_eq(int(s["gadget"]), Loadout.GADGET_BREACH, "Assault keeps BREACH")

func test_engineer_repair_survives_sanitize() -> void:
	var cfg := Loadout.default_loadout(Loadout.ENGINEER)
	cfg["gadget"] = Loadout.GADGET_REPAIR
	var s := Loadout.sanitize(cfg)
	assert_eq(int(s["gadget"]), Loadout.GADGET_REPAIR, "Engineer keeps REPAIR")
```

And add to `tests/gadget_catalog_test.gd` (create if absent, load catalog in `setup()` via `Gadget.load_file("res://data/gadgets.json")`):

```gdscript
func test_breach_def_present() -> void:
	var cat := Gadget.load_file("res://data/gadgets.json")
	var d := cat.def_of_kind(Gadget.KIND_BREACH)
	assert_false(d.is_empty(), "breach def loads")
	assert_true(float(d["struct_radius"]) > 0.0, "breach carve radius")
	assert_true(int(d["arm_delay_ticks"]) > 0, "breach arms after a delay")
```

- [ ] **Step 2: Run to verify failure**

Run: `godot --headless --path . -- --import` (first, so any new test file is discovered), then `godot --headless --path . -- --test --filter=loadout_sanitize` and `--filter=gadget_catalog`.
Expected: FAIL — `KIND_BREACH` not defined / BREACH not in IMPLEMENTED_GADGETS / breach def missing.

- [ ] **Step 3: Implement — gadget kind, catalog def, implemented list**

In `shared/sim/gadget.gd`, after `const KIND_REPAIR := 5`:

```gdscript
const KIND_BREACH := 8   # matches Loadout.GADGET_BREACH (Assault breaching charge)
```

Extend `_KINDS`:

```gdscript
const _KINDS := {"c4": KIND_C4, "mine": KIND_MINE, "rpg": KIND_RPG, "heal": KIND_HEAL, "ammo": KIND_AMMO, "repair": KIND_REPAIR, "breach": KIND_BREACH}
```

In `data/gadgets.json`, add to the `gadgets` array (single-cell walkable-hole carve after a ~1.5 s fuse; struct-only, no pawn damage — it's a breaching tool, not a frag):

```json
    {"id": "breach", "kind": "breach", "max_active": 1, "arm_delay_ticks": 45, "struct_damage": 400, "struct_radius": 1.4, "place_range": 2.5}
```

In `shared/sim/loadout.gd:38`:

```gdscript
const IMPLEMENTED_GADGETS := [GADGET_C4, GADGET_HEAL, GADGET_AMMO, GADGET_RPG, GADGET_REPAIR, GADGET_BREACH]
```

- [ ] **Step 4: Run to verify pass**

Run: `godot --headless --path . -- --test --filter=loadout_sanitize` and `--filter=gadget_catalog`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/gadget.gd shared/sim/loadout.gd data/gadgets.json tests/loadout_sanitize_test.gd tests/gadget_catalog_test.gd
git commit -m "feat(m19): register BREACH+REPAIR gadgets (implemented list + breach catalog def)"
```

---

## Task 2: BREACH wire — new GADGET_ACTION sub-code

**Files:**
- Modify: `shared/net/protocol.gd` (add `GA_BREACH_PLACE`)
- Test: `tests/protocol_gadget_action_test.gd` (extend; else the file that already round-trips `encode_gadget_action`)

- [ ] **Step 1: Write failing test — round-trip a BREACH_PLACE action**

Find the existing gadget-action round-trip test (grep `decode_gadget_action` under `tests/`). Add:

```gdscript
func test_breach_place_roundtrip() -> void:
	var pos := Vector3(3, 0, -4)
	var dir := Vector3(0, 0, -1)
	var b := Protocol.encode_gadget_action(Protocol.GA_BREACH_PLACE, pos, dir, 0)
	var d := Protocol.decode_gadget_action(b)
	assert_eq(int(d["action"]), Protocol.GA_BREACH_PLACE)
	assert_true(d["pos"].distance_to(pos) < 0.01)
	assert_true(d["dir"].distance_to(dir) < 0.01)
```

- [ ] **Step 2: Run to verify failure**

Run: `godot --headless --path . -- --test --filter=protocol_gadget_action` (or the matching filter). Expected: FAIL — `GA_BREACH_PLACE` not defined.

- [ ] **Step 3: Implement — add the sub-action constant**

In `shared/net/protocol.gd`, after `const GA_REPAIR_STOP := 8`:

```gdscript
const GA_BREACH_PLACE := 9   # M19: place an Assault breaching charge (pos + facing dir)
```

(No encode/decode change — `encode_gadget_action` already serializes action+pos+dir. No `VERSION` bump: a new action value in an existing message is backward-shaped.)

- [ ] **Step 4: Run to verify pass**

Run: `godot --headless --path . -- --test --filter=protocol_gadget_action`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add shared/net/protocol.gd tests/protocol_gadget_action_test.gd
git commit -m "feat(m19): GA_BREACH_PLACE gadget-action sub-code"
```

---

## Task 3: BREACH server sim — place, arm, carve

**Files:**
- Modify: `server/server_main.gd` (add `_breaches` array, `_place_breach`, `_step_breaches`, dispatch, per-tick call, spawn/reset clears)
- Test: `tests/breach_test.gd` (create; server-fixture)

- [ ] **Step 1: Write the failing tests**

Create `tests/breach_test.gd`. Model `setup()`/`teardown()` on an existing server-fixture test (e.g. `tests/engineer_blast_test.gd`): load `data/weapons.json` + `data/gadgets.json`, `reset_registry()` in teardown. Build a server, place a structure wall, drive `_place_breach`, advance ticks past the fuse, assert the wall was carved.

```gdscript
const Fixture = preload("res://tests/server_fixture.gd")

var srv

func setup() -> void:
	Weapon.load_from_file("res://data/weapons.json")
	srv = Fixture.make_server()

func teardown() -> void:
	Weapon.reset_registry()

# Place a single structural wall at a known cell and return its id.
func _place_wall(pos: Vector3) -> int:
	# Use the same store API other structure tests use; grep tests/ for a "place a wall" helper
	# (e.g. _store.place / StructureStore build) and mirror it. The piece must be structural so
	# _damage_structure carves chunks.
	return srv._store.place(...)   # IMPLEMENTER: match the real StructureStore place signature

func test_breach_gate_wrong_gadget() -> void:
	var p := Fixture.add_pawn(srv, 1, 0, Vector3(0, 0, 0))
	var c := Fixture.add_client(srv, 1, 0, true)
	c["loadout"]["gadget"] = Loadout.GADGET_C4          # NOT breach
	srv._place_breach(1, p, Vector3(0, 0, -2), Vector3(0, 0, -1))
	assert_eq(srv._breaches.size(), 0, "wrong gadget: no charge placed")

func test_breach_places_and_carves_after_fuse() -> void:
	var wid := _place_wall(Vector3(0, 0, -2))
	var p := Fixture.add_pawn(srv, 1, 0, Vector3(0, 0, 0))
	var c := Fixture.add_client(srv, 1, 0, true)
	c["loadout"]["gadget"] = Loadout.GADGET_BREACH
	var before: int = int(srv._store.get_record(wid)["chunks"])
	srv._place_breach(1, p, Vector3(0, 0, -2), Vector3(0, 0, -1))
	assert_eq(srv._breaches.size(), 1, "charge placed")
	# advance past arm_delay_ticks (45)
	for i in 50:
		srv._sim.tick += 1
		srv._step_breaches()
	assert_eq(srv._breaches.size(), 0, "charge consumed on detonate")
	var after: int = int(srv._store.get_record(wid)["chunks"])
	assert_true(after != before, "wall was carved (chunk mask changed)")

func test_breach_max_active_one() -> void:
	var p := Fixture.add_pawn(srv, 1, 0, Vector3(0, 0, 0))
	var c := Fixture.add_client(srv, 1, 0, true)
	c["loadout"]["gadget"] = Loadout.GADGET_BREACH
	srv._place_breach(1, p, Vector3(0, 0, -2), Vector3(0, 0, -1))
	srv._place_breach(1, p, Vector3(0, 0, -2), Vector3(0, 0, -1))
	assert_eq(srv._breaches.size(), 1, "max_active=1 blocks a second charge")
```

> IMPLEMENTER NOTE: match `_store.place`/wall-building to whatever the existing structure tests use (grep `tests/` for `_store.place`, `damage_chunks`, or a build helper). If placing a structural wall in a unit test is heavy, reuse the exact setup another `_damage_structure`/structure test already uses. The behavioral asserts (gate, place, carve-after-fuse, max_active) are the contract.

- [ ] **Step 2: Run to verify failure**

Run: `godot --headless --path . -- --import` then `godot --headless --path . -- --test --filter=breach`. Expected: FAIL — `_breaches`/`_place_breach`/`_step_breaches` undefined.

- [ ] **Step 3: Implement — server sim**

In `server/server_main.gd`, near the other gadget-entity arrays (grep `var _mines`), add:

```gdscript
var _breaches: Array = []   # [{owner, pos, id, detonate_tick}] — M19 Assault breaching charges (arm-then-carve)
```

Add the place handler (model on `_place_mine`); it re-marches from the pawn's eye to bind an authoritative structure id + impact:

```gdscript
## M19 BREACH: place an Assault breaching charge against the structure under the crosshair. Mirrors
## _place_mine (gadget gate + max_active + range), then re-marches server-side for the authoritative
## target cell/impact. Detonates after arm_delay_ticks in _step_breaches, carving a walkable hole.
func _place_breach(id: int, p: Pawn, pos: Vector3, facing: Vector3) -> void:
	if int(_clients[id]["loadout"]["gadget"]) != Loadout.GADGET_BREACH: return
	var bdef: Dictionary = _gadgets.def_of_kind(Gadget.KIND_BREACH)
	var count := 0
	for b in _breaches:
		if int(b["owner"]) == id: count += 1
	if count >= int(bdef["max_active"]): return
	if p.pos.distance_to(pos) > float(bdef["place_range"]): return
	if _store == null: return
	var dir := facing.normalized() if facing.length() > 0.001 else Vector3(sin(p.yaw), 0.0, cos(p.yaw))
	var m := _store.march(p.eye_position(), dir, float(bdef["place_range"]))
	if not bool(m["hit"]): return   # must be aimed at a structure to breach it
	var impact: Vector3 = p.eye_position() + dir * float(m["dist"])
	_breaches.append({"owner": id, "pos": impact, "id": int(m["id"]),
		"detonate_tick": _sim.tick + int(bdef["arm_delay_ticks"])})
```

Add the per-tick step (model the detonation-broadcast on how `_detonate_c4`/`_step_rockets` announce a blast; reuse the explosion FX event the RPG/C4 path already sends):

```gdscript
## M19 BREACH: detonate armed charges whose fuse elapsed — carve the bound structure (SRC_EXPLOSIVE)
## and announce the blast FX. Struct-only (no pawn damage): it opens a hole, it is not a frag.
func _step_breaches() -> void:
	if _breaches.is_empty(): return
	var bdef: Dictionary = _gadgets.def_of_kind(Gadget.KIND_BREACH)
	var r := float(bdef["struct_radius"])
	var live: Array = []
	for b in _breaches:
		if _sim.tick < int(b["detonate_tick"]):
			live.append(b); continue
		_damage_structure(int(b["id"]), PieceCatalog.SRC_EXPLOSIVE, b["pos"], r)
		_broadcast_explosion_fx(b["pos"])   # IMPLEMENTER: use the exact FX-broadcast helper C4/RPG use
	_breaches = live
```

> IMPLEMENTER NOTE: grep for how `_detonate_c4` / rocket detonation broadcasts the visual explosion (e.g. `encode_detonation` / a `_broadcast_*` helper) and call the same one so the client shows a blast. If C4 uses an inline `for cid in _clients` send, copy that idiom rather than inventing `_broadcast_explosion_fx`.

Dispatch in `_handle_gadget_action` `match`:

```gdscript
		Protocol.GA_BREACH_PLACE: _place_breach(id, p, d["pos"], d["dir"])
```

Call `_step_breaches()` in `_step()` alongside the other gadget steps — grep for `_step_grenades()`/`_step_rockets()` and add `_step_breaches()` next to them.

Clear on reset: wherever `_smoke_zones.clear()` / `_mines` are cleared on match reset (grep `_smoke_zones.clear`), add `_breaches.clear()`.

- [ ] **Step 4: Run to verify pass**

Run: `godot --headless --path . -- --test --filter=breach`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/server_main.gd tests/breach_test.gd
git commit -m "feat(m19): BREACH server sim — place/arm/carve walkable hole (SRC_EXPLOSIVE)"
```

---

## Task 4: REPAIR — gate on selected gadget + repair structures

**Files:**
- Modify: `server/support.gd` (`step_repairs`: gadget gate + structure branch; add `nearest_friendly_damaged_structure` via aim-march)
- Test: `tests/repair_structure_test.gd` (create; server-fixture)

- [ ] **Step 1: Write the failing tests**

Create `tests/repair_structure_test.gd`. Build a server, damage a wall (carve a hole via `_store.damage_chunks`), put an Engineer with `gadget == GADGET_REPAIR` in range aiming at it, latch `repairing[eid]=true`, tick `step_repairs()`, assert the hole shrinks. Add a negative test: an Engineer whose selected gadget is NOT repair does not repair.

```gdscript
const Fixture = preload("res://tests/server_fixture.gd")
var srv

func setup() -> void:
	Weapon.load_from_file("res://data/weapons.json")
	srv = Fixture.make_server()

func teardown() -> void:
	Weapon.reset_registry()

func test_engineer_with_repair_gadget_heals_structure() -> void:
	var wid := _damaged_wall_in_front_of(Vector3(0,0,0))   # IMPLEMENTER: place + damage_chunks a wall ~2m ahead
	var p := Fixture.add_pawn(srv, 1, 0, Vector3(0, 0, 0))
	p.pitch = 0.0; p.yaw = 0.0   # aim toward the wall (-Z or +Z per your placement)
	var c := Fixture.add_client(srv, 1, 0, true)
	c["class"] = Loadout.ENGINEER
	c["loadout"]["gadget"] = Loadout.GADGET_REPAIR
	srv._support.repairing[1] = true
	var before: int = int(srv._store.get_record(wid)["chunks"])
	for i in 30:
		srv._sim.tick += 1
		srv._support.step_repairs()
	var after: int = int(srv._store.get_record(wid)["chunks"])
	assert_true(_popcount(after) > _popcount(before), "hole filled (more chunks alive)")

func test_engineer_without_repair_gadget_does_nothing() -> void:
	var wid := _damaged_wall_in_front_of(Vector3(0,0,0))
	var p := Fixture.add_pawn(srv, 1, 0, Vector3(0, 0, 0))
	var c := Fixture.add_client(srv, 1, 0, true)
	c["class"] = Loadout.ENGINEER
	c["loadout"]["gadget"] = Loadout.GADGET_C4        # not repair
	srv._support.repairing[1] = true
	var before: int = int(srv._store.get_record(wid)["chunks"])
	for i in 30:
		srv._sim.tick += 1
		srv._support.step_repairs()
	assert_eq(int(srv._store.get_record(wid)["chunks"]), before, "no repair without the gadget")

func _popcount(m: int) -> int:
	var n := 0
	while m != 0:
		n += m & 1; m >>= 1
	return n
```

> IMPLEMENTER NOTE: `_damaged_wall_in_front_of` = place a structural wall (same helper as Task 3) then `srv._store.damage_chunks(wid, PieceCatalog.SRC_EXPLOSIVE, impact, radius)` to punch a hole. Ensure the Engineer's aim ray actually hits it (position/orient the pawn to match the wall). Keep the vehicle-repair path's existing tests green.

- [ ] **Step 2: Run to verify failure**

Run: `godot --headless --path . -- --import` then `--test --filter=repair_structure`. Expected: FAIL — structures not repaired (step_repairs is vehicle-only) / no gadget gate.

- [ ] **Step 3: Implement — gate + structure branch in `step_repairs`**

In `server/support.gd`, add a helper (aim-march to a damaged structure the engineer is looking at, within `rng`):

```gdscript
## Structure the engineer is aiming at within `rng`, or 0. Uses the same eye-ray march the
## sledgehammer uses so "look at the wall and hold repair" works. Returns {id, impact} or {}.
func aimed_damaged_structure(ep: Pawn, rng: float) -> Dictionary:
	if srv._store == null: return {}
	var dir := Combat._forward(ep.yaw, ep.pitch)
	var m := srv._store.march(ep.eye_position(), dir, rng)
	if not bool(m["hit"]): return {}
	return {"id": int(m["id"]), "impact": ep.eye_position() + dir * float(m["dist"])}
```

In `step_repairs()`, gate each latched engineer on the selected gadget, and repair a structure when no vehicle is the target. Replace the body of the `for eid in repairing:` loop so it (a) skips engineers whose selected gadget isn't `GADGET_REPAIR`, and (b) after the vehicle branch, if no vehicle was repaired, tries a structure repair:

```gdscript
	for eid in repairing:
		var ep: Pawn = srv._sim.world.get_pawn(eid)
		if ep == null or not ep.alive or ep.is_downed:
			done.append(eid); continue
		# M19: only the REPAIR gadget repairs (an Engineer holding C4/RPG must not).
		if not srv._clients.has(eid) or int(srv._clients[eid]["loadout"]["gadget"]) != Loadout.GADGET_REPAIR:
			done.append(eid); continue
		var v := nearest_friendly_damaged_vehicle(ep, rng)
		var struct := aimed_damaged_structure(ep, rng) if v == null else {}
		var want := v != null or not struct.is_empty()
		var st := Gadget.repair_heat_step(int(repair_heat.get(eid, 0)), int(repair_cd.get(eid, 0)),
			srv._sim.tick, want, overheat, cool)
		repair_heat[eid] = int(st["heat"]); repair_cd[eid] = int(st["cooldown_until"])
		if int(st["cooldown_until"]) > 0 and want:
			srv._stats.repair_overheats += 1
		if not bool(st["repairing"]): continue
		if v != null:
			var before := v.hp
			v.hp = mini(v.max_hp, v.hp + rate)
			srv._stats.repairs += v.hp - before
			links_this_tick.append({"giver": eid, "target": v.id, "kind": SupportLinks.REPAIR})
		elif not struct.is_empty():
			var res := srv._store.repair_chunks(int(struct["id"]), struct["impact"], rng * 0.35)
			if bool(res["changed"]):
				srv._stats.repairs += 1
				links_this_tick.append({"giver": eid, "target": int(struct["id"]), "kind": SupportLinks.REPAIR})
```

> IMPLEMENTER NOTE: keep the surrounding `rdef`/`rate`/`rng`/`overheat`/`cool`/`done` setup and the trailing `for eid in done: repairing.erase(eid)` exactly as they are. `Combat._forward` and `ep.eye_position()` are already used elsewhere in the server. The `rng * 0.35` carve radius keeps repair local to the aimed hole (tune if a test needs it); the important invariant is the aimed hole fills over a few ticks.

- [ ] **Step 4: Run to verify pass**

Run: `godot --headless --path . -- --test --filter=repair_structure`, then the full suite `--test` to confirm the vehicle-repair tests still pass. Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add server/support.gd tests/repair_structure_test.gd
git commit -m "feat(m19): REPAIR gadget repairs aimed structures + gate step_repairs on selected gadget"
```

---

## Task 5: Client send-path — emit BREACH_PLACE / REPAIR hold for the equipped gadget

**Files:**
- Modify: `client/client_main.gd` (gadget-action input: send the sub-action matching the equipped gadget)
- Test: none (client input; covered by the render/CI smoke boot + server unit tests). Keep this task minimal.

- [ ] **Step 1: Read the current gadget-input block**

Read `client/client_main.gd` around the `Input.is_action_just_pressed("gadget")` block (~line 1141) and the RMB/hold handling near the RPG-fire path (~1123). The block currently hard-defaults to `GA_C4_DETONATE`.

- [ ] **Step 2: Route by the local player's equipped gadget**

The client knows its loadout (it sent `SET_LOADOUT` / has it locally — grep for where the client stores its chosen gadget; if it only has class, use the class default from `Loadout.gadget_for`, but prefer the stored loadout gadget). Branch the one-shot "gadget" action:

```gdscript
	if Input.is_action_just_pressed("gadget") and not combat_locked:
		match _equipped_gadget():   # int Loadout.GADGET_* for the local player
			Loadout.GADGET_BREACH:
				_net_send(Protocol.encode_gadget_action(Protocol.GA_BREACH_PLACE,
					_pred.predicted.pos, _aim_dir(), 0))   # IMPLEMENTER: match existing send + aim-dir helpers
			Loadout.GADGET_C4:
				_net_send(Protocol.encode_gadget_action(Protocol.GA_C4_DETONATE,
					_pred.predicted.pos, _aim_dir(), 0))
			_:
				pass
```

And for REPAIR, drive the latched start/stop off the same hold input the Engineer uses (mirror how `GA_GIVE_START/STOP` or the existing repair keybind is sent — grep `GA_REPAIR_START` in `client/`; if the client never sent it, wire the "gadget"/secondary-fire hold for a REPAIR-equipped Engineer to send `GA_REPAIR_START` on press and `GA_REPAIR_STOP` on release).

> IMPLEMENTER NOTE: This task only needs the local player to be able to *trigger* the gadgets; bots exercise the server path directly (Task 6). Do NOT redesign the input scheme. Add `_equipped_gadget()`/`_aim_dir()` helpers only if equivalents don't already exist — reuse what the RPG-fire and C4 paths already use for pos/dir. Keep the change small and follow the file's existing send idiom (`_net_send`/`_send`/whatever it is).

- [ ] **Step 3: Boot-smoke the client headlessly**

Run the repo's client boot smoke (grep `AGENTS.md`/`docs` or CI for the headless client boot command, e.g. `godot --headless --path . -- --client --smoke ...`). Expected: no script/parse errors.

- [ ] **Step 4: Commit**

```bash
git add client/client_main.gd
git commit -m "feat(m19): client emits BREACH_PLACE / REPAIR hold for the equipped gadget"
```

---

## Task 6: Bot loadout coverage + fleet-gate wiring

**Files:**
- Modify: `shared/sim/loadout.gd` (`bot_loadout` / `bot_gadget`) so some bots field BREACH (Assault) and REPAIR (Engineer), exercising both server paths under the 128-bot gate
- Modify: bot AI (grep the file that reads `bot_gadget` / issues gadget actions) so a REPAIR-Engineer bot near a damaged structure latches repair, and a BREACH-Assault bot occasionally places a charge on a wall it's next to
- Test: `tests/bot_loadout_test.gd` (extend if present) — assert the deterministic matrix now yields BREACH/REPAIR for some ids

- [ ] **Step 1: Write failing test — bot matrix includes the new gadgets**

Extend the bot-loadout test (grep `bot_loadout` under `tests/`):

```gdscript
func test_bot_matrix_covers_breach_and_repair() -> void:
	var seen := {}
	for i in 128:
		var l := Loadout.bot_loadout(i)
		seen[int(l["gadget"])] = true
	assert_true(seen.has(Loadout.GADGET_BREACH), "some bot fields BREACH")
	assert_true(seen.has(Loadout.GADGET_REPAIR), "some bot fields REPAIR")
```

- [ ] **Step 2: Run to verify failure**

Run: `godot --headless --path . -- --test --filter=bot_loadout`. Expected: FAIL (matrix never picks BREACH/REPAIR).

- [ ] **Step 3: Implement — extend the deterministic bot matrix + minimal AI use**

In `Loadout.bot_loadout(id)` (grep it), make the gadget selection for Assault ids sometimes `GADGET_BREACH` and for Engineer ids sometimes `GADGET_REPAIR` (deterministic by `id`, e.g. `id % 3`). Keep the existing RPG/C4/LMG/DMR spread — just ensure both new ids appear across 0–127.

In the bot AI, add the minimal exercise:
- REPAIR Engineer bot: if `bot_gadget == GADGET_REPAIR` and a damaged friendly structure is within repair range on its facing, latch `repairing[id]=true` (send/route `GA_REPAIR_START`) like it would hold the tool; release when none.
- BREACH Assault bot: if `bot_gadget == GADGET_BREACH` and the bot is adjacent to an enemy-side wall blocking its path, occasionally call the breach place (cadence-limited like the bot RPG restraint — see `blockfire-bot-rpg-restraint`; do NOT let bots spam-carve the map).

> IMPLEMENTER NOTE: keep bot destruction restrained (memory: bots over-rocketed the map). BREACH bots should place at most rarely and only on a wall directly between them and their objective. The goal is gate *coverage* (server paths execute without errors), not aggressive bot demolition.

- [ ] **Step 4: Run to verify pass**

Run: `godot --headless --path . -- --test --filter=bot_loadout`, then full `--test`. Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/loadout.gd tests/bot_loadout_test.gd <bot AI file>
git commit -m "feat(m19): bot loadout coverage for BREACH/REPAIR + restrained bot use"
```

---

## Task 7: Docs + fleet gate + land

**Files:**
- Modify: `docs/TASKS.md` (M19 row: note P2b-structure done)
- Modify: `docs/specs/class-select-loadout.md` (tick BREACH/REPAIR built in §D if it has a status column)

- [ ] **Step 1: Run the full suite**

Run: `godot --headless --path . -- --test`. Expected: 0 failures (suite count grows by the new tests).

- [ ] **Step 2: Run the 128-bot fleet gate on conquest_town**

On game2 (this dev host), from `docker/`:

```bash
cd docker && SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 TICKETS=200 ./run-m19-gate.sh
```

Expected PASS: valid winner, peak-window mean tick < 33.3 ms, ended on tickets, `cap_events >= 1`, `script_errors = 0`. (Use `TICKETS=200` — `cap_events>=1` is flaky at 80.) If a BREACH/REPAIR path throws, `script_errors` will be non-zero — fix before landing.

- [ ] **Step 3: Update docs**

Update the M19 row in `docs/TASKS.md` to record "P2b-structure done (BREACH + REPAIR live)" with the gate numbers.

- [ ] **Step 4: Commit docs + gate note**

```bash
git add docs/TASKS.md docs/specs/class-select-loadout.md
git commit -m "gate(m19): P2b-structure PASS (BREACH+REPAIR) — <tick>ms 128p conquest_town; docs"
```

- [ ] **Step 5: Finish the branch**

Use superpowers:finishing-a-development-branch → merge to master (`--no-ff`), push, delete branch, verify `git rev-parse HEAD == origin/master`, clean tree.

---

## Self-review checklist (run before dispatching Task 1)
- **Spec coverage:** BREACH (§D active placed wall-carve) ✓ Task 3; REPAIR (§D structure/FOB repair, held-use, solo-allowed) ✓ Task 4; both in IMPLEMENTED_GADGETS ✓ Task 1. LMG-Nest/Grapple/Riot/Sandbag explicitly out of scope ✓.
- **No wire break:** only new GADGET_ACTION sub-codes (`GA_BREACH_PLACE`); SELF_STATE unchanged; no VERSION bump. ✓
- **Type consistency:** `KIND_BREACH == GADGET_BREACH == 8`; `_breaches` dict keys `{owner,pos,id,detonate_tick}` used identically in place + step; `repair_chunks` returns `{changed,mask}`. ✓
- **Placeholders:** the two IMPLEMENTER NOTES (wall-placement helper, explosion-FX broadcast helper) point at existing code to mirror rather than inventing signatures — resolve them by grepping, not guessing.
