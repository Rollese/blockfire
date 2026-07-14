# M2 BattleBit Ammo / Magazine System — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace M17's flat reserve-int with BattleBit-faithful individual magazines — each spare mag remembers its round count, reload is FIFO, hold-R fast-reload drops a recoverable owner-only world mag, a hold-key redistribute (5s/mag) consolidates partials, and ammo boxes refill slowly (1 mag / 5s). HUD shows the loaded mag as a number plus a grey→white mag-glyph strip; **no reserve total**.

**Architecture:** `c["ammo"]` stays the loaded-mag count. The per-slot flat `c["reserve"]` int is joined by `c["spare_mags"]` — a FIFO `Array[int]` of spare-mag round-counts. `reserve` becomes a *derived* `sum(spare_mags)` used only server-side (resupply caps) and on the wire for back-compat, never shown. Pure deterministic helpers in `shared/sim/weapon.gd` are shared by the server and the client `WeaponPredictor` so the HUD never drifts (same seam as the existing `reload_fill`). Dropped mags are a server-owned per-owner entity list (ReliableList pattern, like C4/nests/ladders).

**Tech Stack:** Godot 4 / GDScript. Headless deterministic tests (`godot --headless --path . -- --test`). Wire = hand-rolled `StreamPeerBuffer` in `shared/net/protocol.gd`. Reference spec: `docs/superpowers/specs/2026-07-14-m2-ammo-magazine-system-design.md`.

**Wire version:** `Protocol.VERSION` 12 → 13.

---

## File Structure

- `shared/sim/weapon.gd` — **modify**: add pure mag helpers (`spawn_mags`, `has_loadable_spare`, `reload_swap`, `load_next`, `redistribute_step`, `resupply_step`).
- `shared/net/input_command.gd` — **modify**: add `BTN_FAST_RELOAD` (2048), `BTN_REDISTRIBUTE` (4096).
- `shared/net/protocol.gd` — **modify**: `VERSION` 13; SELF_STATE `spare_mags` tail; `Msg.PICKUP_MAG=53`, `Msg.DROPPED_MAG_LIST=54` + encode/decode.
- `server/dropped_mags.gd` — **create**: `ServerDroppedMags` owner-keyed dropped-mag store (spawn/pickup/sweep/TTL + per-owner reliable broadcast).
- `server/fire.gd` — **modify**: reload-start handles tap vs fast; fire-lock while redistributing.
- `server/server_main.gd` — **modify**: `_SLOT_FIELDS` + `spare_mags`; spawn/reset build mags; reload-complete FIFO/fast; redistribute state machine; `_drop_mag`; `PICKUP_MAG` handler; DROPPED_MAG_LIST broadcast; sweeps; SELF_STATE send; slow bag resupply.
- `server/support.gd` — **modify**: `give_ammo` slow (1 mag / 5s) via `resupply_step`.
- `client/weapon_predictor.gd` — **modify**: `spare_mags`; predict FIFO/fast/redistribute; reconcile.
- `client/input_map.gd`, `client/client_main.gd` — **modify**: hold-vs-tap reload, redistribute key, pickup F; predictor wiring; SELF_STATE spare_mags reconcile; dropped-mag list handling.
- `client/hud/hud_model.gd`, `client/hud/hud_view.gd` — **modify**: mag-glyph strip; drop reserve number; dropped-mag "F to pick up" prompt.
- `bots/exercisers.gd` — **modify**: exercise fast-reload / redistribute / pickup.
- Tests: `tests/weapon_test.gd`, `tests/weapon_predictor_test.gd`, `tests/protocol_test.gd`, `tests/server_reserve_ammo_test.gd`, plus a new `tests/server_dropped_mag_test.gd`.

Run the whole suite any time with: `godot --headless --path . -- --test`

---

## Task 1: Sim — pure magazine helpers

**Files:**
- Modify: `shared/sim/weapon.gd` (after `reload_fill`, ~line 46)
- Test: `tests/weapon_test.gd`

- [ ] **Step 1: Write failing tests** — append to `tests/weapon_test.gd`:

```gdscript
func test_spawn_mags_builds_full_spare_mags() -> void:
	# Reserve divides evenly into whole spare mags; each starts full. Loaded mag is tracked separately.
	for wid in [Weapon.AR, Weapon.SMG, Weapon.DMR, Weapon.PISTOL, Weapon.LMG]:
		var ms := int(Weapon.get_def(wid)["mag_size"])
		var expected_n := Weapon.reserve_ammo(wid) / ms
		var mags := Weapon.spawn_mags(wid)
		assert_eq(mags.size(), expected_n, "spare mag count for w %d" % wid)
		for m in mags:
			assert_eq(int(m), ms, "each spare mag full for w %d" % wid)

func test_spawn_mags_scales_with_reserve_mult() -> void:
	var ms := int(Weapon.get_def(Weapon.AR)["mag_size"])
	var base := Weapon.spawn_mags(Weapon.AR, 1.0).size()
	var boosted := Weapon.spawn_mags(Weapon.AR, 1.5).size()
	assert_eq(boosted, int(round(Weapon.reserve_ammo(Weapon.AR) * 1.5)) / ms)
	assert_true(boosted > base)

func test_has_loadable_spare() -> void:
	assert_false(Weapon.has_loadable_spare([]))
	assert_false(Weapon.has_loadable_spare([0, 0]))
	assert_true(Weapon.has_loadable_spare([0, 5]))

func test_reload_swap_is_fifo_and_returns_partial_to_tail() -> void:
	# Loaded mag has 8 left; spares [30, 30]. Tap reload: 8 goes to tail, load head 30.
	var res := Weapon.reload_swap(8, [30, 30])
	assert_eq(int(res[0]), 30)          # new loaded mag
	assert_eq(res[1], [30, 8])          # partial returned to the tail
	assert_true(bool(res[2]))           # ok

func test_reload_swap_skips_empty_mags() -> void:
	# Never chamber an empty: leading 0-mags are discarded until a non-empty head is found.
	var res := Weapon.reload_swap(5, [0, 0, 20])
	assert_eq(int(res[0]), 20)
	assert_eq(res[1], [5])              # the two empties discarded; partial 5 kept at tail
	assert_true(bool(res[2]))

func test_load_next_loads_head_without_returning_current() -> void:
	# Fast reload: current mag was dropped by the caller, so no partial returns to the tail.
	var res := Weapon.load_next([30, 12])
	assert_eq(int(res[0]), 30)
	assert_eq(res[1], [12])
	assert_true(bool(res[2]))

func test_load_next_reports_not_ok_when_no_spare() -> void:
	var res := Weapon.load_next([0, 0])
	assert_false(bool(res[2]))

func test_redistribute_step_pours_emptiest_into_fullest() -> void:
	# mag_size 30. Emptiest non-empty (5) pours into fullest non-full (20) -> [25], 5-mag emptied+dropped.
	var out := Weapon.redistribute_step([20, 5], 30)
	assert_eq(out, [25])

func test_redistribute_step_leaves_partial_when_dest_fills() -> void:
	# 25 into 20 (space 10): dest fills to 30, src keeps remainder 15 (not emptied, not dropped).
	var out := Weapon.redistribute_step([20, 25], 30)
	assert_eq(out, [30, 15])

func test_redistribute_step_noop_when_nothing_to_consolidate() -> void:
	assert_eq(Weapon.redistribute_step([30, 30], 30), [30, 30])
	assert_eq(Weapon.redistribute_step([7], 30), [7])

func test_resupply_step_tops_loaded_then_fills_emptiest_first() -> void:
	# One mag (30) of rounds: top loaded 10->30 (20 used), remaining 10 into emptiest spare (0->10).
	var res := Weapon.resupply_step(10, [0, 30], Weapon.AR)
	assert_eq(int(res[0]), 30)
	assert_eq(res[1], [10, 30])

func test_resupply_step_caps_at_max_mag_count() -> void:
	# Full loaded + full spares already at max: adding rounds cannot exceed the spawn count.
	var full := Weapon.spawn_mags(Weapon.AR)
	var res := Weapon.resupply_step(30, full, Weapon.AR)
	assert_eq(int(res[0]), 30)
	assert_eq(res[1].size(), full.size())
```

- [ ] **Step 2: Run — expect FAIL** (functions not defined):

`godot --headless --path . -- --test 2>&1 | grep -iE "spawn_mags|reload_swap|redistribute|resupply|FAIL"`

- [ ] **Step 3: Implement** — insert into `shared/sim/weapon.gd` immediately after `reload_fill` (line 46):

```gdscript
## --- BattleBit individual-magazine model (M2 backlog) ---------------------------------------
## Loaded mag is tracked separately (c["ammo"] / WeaponPredictor.mag). These helpers operate on the
## FIFO spare-mag list (Array of per-mag round counts). Pure + deterministic — shared by the server's
## authoritative reload/resupply and the client WeaponPredictor so the HUD never drifts.

## Build the full spare-mag FIFO for a fresh loadout: reserve_ammo (scaled by the class reserve_mult)
## divided into whole full mags. Reserves divide evenly for every weapon (AR 6/SMG 6/DMR 7/PISTOL
## 4/LMG 3). Returns [] for a weapon with no mag (e.g. RPG).
static func spawn_mags(weapon_id: int, reserve_mult: float = 1.0) -> Array:
	var mag_size: int = int(get_def(weapon_id)["mag_size"])
	if mag_size <= 0:
		return []
	var n: int = int(round(float(reserve_ammo(weapon_id)) * reserve_mult)) / mag_size
	var out: Array = []
	for _i in n:
		out.append(mag_size)
	return out

## True if any spare mag has rounds — the reload-start guard (never start a reload that can't load).
static func has_loadable_spare(spare_mags: Array) -> bool:
	for m in spare_mags:
		if int(m) > 0:
			return true
	return false

## FIFO tap-reload: the current partial mag returns to the tail, then the first non-empty spare is
## popped from the head (leading empties discarded — never chamber an empty). Returns
## [new_mag, new_spare_mags, ok]; ok=false (state unchanged) if no non-empty spare exists.
static func reload_swap(mag: int, spare_mags: Array) -> Array:
	var spares: Array = spare_mags.duplicate()
	spares.append(maxi(mag, 0))
	return _pop_first_nonempty(spares, mag, spare_mags)

## Fast-reload load: the current mag was DROPPED by the caller (not returned to the tail), so just
## pop the first non-empty spare from the head. Returns [new_mag, new_spare_mags, ok].
static func load_next(spare_mags: Array) -> Array:
	var spares: Array = spare_mags.duplicate()
	return _pop_first_nonempty(spares, 0, spare_mags)

static func _pop_first_nonempty(spares: Array, fallback_mag: int, orig: Array) -> Array:
	while not spares.is_empty():
		var head: int = int(spares.pop_front())
		if head > 0:
			return [head, spares, true]
	return [fallback_mag, orig.duplicate(), false]

## One redistribution step: pour the emptiest non-empty spare into the fullest non-full spare; drop
## the source mag if it empties (leaving empties behind is the point). Returns the new spare list
## (unchanged if nothing can be consolidated). Called once per 5 s while the redistribute key is held.
static func redistribute_step(spare_mags: Array, mag_size: int) -> Array:
	var spares: Array = spare_mags.duplicate()
	var dest: int = -1
	for i in spares.size():
		var v: int = int(spares[i])
		if v < mag_size and (dest < 0 or v > int(spares[dest])):
			dest = i
	var src: int = -1
	for i in spares.size():
		if i == dest:
			continue
		var v: int = int(spares[i])
		if v > 0 and (src < 0 or v < int(spares[src])):
			src = i
	if dest < 0 or src < 0:
		return spares
	var move: int = mini(mag_size - int(spares[dest]), int(spares[src]))
	spares[dest] = int(spares[dest]) + move
	spares[src] = int(spares[src]) - move
	if int(spares[src]) == 0:
		spares.remove_at(src)
	return spares

## Resupply one mag's worth of rounds: top the loaded mag first, then fill existing spare mags
## emptiest-first, then add a new full-ish mag if rounds remain and we're under the spawn mag count.
## Returns [new_mag, new_spare_mags]. Called on a 5 s cadence by ammo boxes / bags / medic give.
static func resupply_step(mag: int, spare_mags: Array, weapon_id: int, reserve_mult: float = 1.0) -> Array:
	var mag_size: int = int(get_def(weapon_id)["mag_size"])
	if mag_size <= 0:
		return [mag, spare_mags.duplicate()]
	var max_spares: int = int(round(float(reserve_ammo(weapon_id)) * reserve_mult)) / mag_size
	var spares: Array = spare_mags.duplicate()
	var budget: int = mag_size
	var top: int = mini(mag_size - mag, budget)
	mag += top
	budget -= top
	while budget > 0:
		var dest: int = -1
		for i in spares.size():
			if int(spares[i]) < mag_size and (dest < 0 or int(spares[i]) < int(spares[dest])):
				dest = i
		if dest < 0:
			break
		var add: int = mini(mag_size - int(spares[dest]), budget)
		spares[dest] = int(spares[dest]) + add
		budget -= add
	while budget > 0 and spares.size() < max_spares:
		var add2: int = mini(mag_size, budget)
		spares.append(add2)
		budget -= add2
	return [mag, spares]
```

- [ ] **Step 4: Run — expect PASS**: `godot --headless --path . -- --test 2>&1 | grep -iE "TESTS:|FAIL"`
- [ ] **Step 5: Commit**: `git add shared/sim/weapon.gd tests/weapon_test.gd* && git commit -m "feat(m2): pure individual-magazine sim helpers (spawn/reload_swap/redistribute/resupply)"`

---

## Task 2: Wire — SELF_STATE spare_mags tail + VERSION 13

**Files:**
- Modify: `shared/net/protocol.gd` (`VERSION`; `encode_self_state` ~944; `decode_self_state` ~1119-1122)
- Test: `tests/protocol_test.gd`

- [ ] **Step 1: Write failing tests** — append to `tests/protocol_test.gd`:

```gdscript
func test_self_state_carries_spare_mags() -> void:
	var bytes := Protocol.encode_self_state(30, false, 0, Weapon.AR, [], false, 0.0, 0, 0, false,
		0.0, 0.0, 100.0, 0.0, true, false, 0, 0.0, false, 0, false, 0, 90, 0, 0, 0, 0, 0, false, 0, 0,
		[30, 12, 0])
	var d := Protocol.decode_self_state(bytes)
	assert_eq(d["spare_mags"], [30, 12, 0])

func test_self_state_spare_mags_absent_decodes_empty() -> void:
	# A packet with no spare-mag tail (older sender) decodes to [] rather than misaligning.
	var bytes := Protocol.encode_self_state(30, false, 0, Weapon.AR)
	var d := Protocol.decode_self_state(bytes)
	assert_eq(d["spare_mags"], [])

func test_protocol_version_is_13() -> void:
	assert_eq(Protocol.VERSION, 13)
```

- [ ] **Step 2: Run — expect FAIL**: `godot --headless --path . -- --test 2>&1 | grep -iE "spare_mags|version_is_13|FAIL"`

- [ ] **Step 3a: Bump VERSION** — `shared/net/protocol.gd:19`:

```gdscript
const VERSION := 13   # 13: M2 ammo — SELF_STATE spare_mags tail + DROPPED_MAG_LIST/PICKUP_MAG + BTN_FAST_RELOAD/BTN_REDISTRIBUTE (2026-07-14)
```

- [ ] **Step 3b: Encode** — add `spare_mags: Array = []` as the final param of `encode_self_state` (after `grapple_charges: int = 0`), and before `return buf.data_array` (line 1026) append:

```gdscript
	# M2 ammo: owner-only active-slot spare-mag round counts (FIFO order), appended last so older
	# decoders ignore it. Count byte + one byte per mag (mag_size <= 100 fits a u8).
	buf.put_u8(mini(spare_mags.size(), 255))
	for i in mini(spare_mags.size(), 255):
		buf.put_u8(clampi(int(spare_mags[i]), 0, 255))
```

- [ ] **Step 3c: Decode** — in `decode_self_state`, after the `grapple_charges` block (line 1121), before the `return {...}`:

```gdscript
	# M2 ammo: active-slot spare mags; absent (older/short packet) -> [] rather than misaligning.
	var spare_mags: Array = []
	if r.get_available_bytes() >= 1:
		var sm := r.get_u8()
		for _i in sm:
			if r.get_available_bytes() >= 1:
				spare_mags.append(r.get_u8())
```

Then add `"spare_mags": spare_mags` to the returned dictionary (line 1122).

- [ ] **Step 4: Run — expect PASS**: `godot --headless --path . -- --test 2>&1 | grep -iE "TESTS:|FAIL"`
- [ ] **Step 5: Commit**: `git add shared/net/protocol.gd tests/protocol_test.gd* && git commit -m "feat(m2): SELF_STATE spare_mags tail + VERSION 13"`

---

## Task 3: Wire — DROPPED_MAG_LIST / PICKUP_MAG + input bits

**Files:**
- Modify: `shared/net/input_command.gd` (after `BTN_SHIELD`, line 26)
- Modify: `shared/net/protocol.gd` (`Msg` enum ~46-81; new encode/decode near `encode_cut_ladder` ~779)
- Test: `tests/protocol_test.gd`

- [ ] **Step 1: Write failing tests** — append to `tests/protocol_test.gd`:

```gdscript
func test_dropped_mag_list_roundtrip() -> void:
	var lst := [{"id": 7, "pos": Vector3(12.3, 4.5, -6.7), "rounds": 18}]
	var out := Protocol.decode_dropped_mag_list(Protocol.encode_dropped_mag_list(lst))
	assert_eq(out.size(), 1)
	assert_eq(int(out[0]["id"]), 7)
	assert_eq(int(out[0]["rounds"]), 18)
	assert_almost_eq(float(out[0]["pos"].x), 12.3, 0.1)

func test_pickup_mag_roundtrip() -> void:
	var d := Protocol.decode_pickup_mag(Protocol.encode_pickup_mag(42))
	assert_eq(int(d["mag_id"]), 42)

func test_new_input_bits_distinct() -> void:
	assert_eq(InputCommand.BTN_FAST_RELOAD, 2048)
	assert_eq(InputCommand.BTN_REDISTRIBUTE, 4096)
	# no collision with existing bits
	assert_eq(InputCommand.BTN_FAST_RELOAD & InputCommand.BTN_SHIELD, 0)
```

- [ ] **Step 2: Run — expect FAIL**: `godot --headless --path . -- --test 2>&1 | grep -iE "dropped_mag|pickup_mag|input_bits|FAIL"`

- [ ] **Step 3a: Input bits** — `shared/net/input_command.gd` after line 26:

```gdscript
const BTN_FAST_RELOAD := 2048   # bit 11: hold-R fast reload — drops the current mag (M2 ammo)
const BTN_REDISTRIBUTE := 4096  # bit 12: hold to consolidate partial spare mags (M2 ammo)
```

- [ ] **Step 3b: Msg codes** — `shared/net/protocol.gd`, in the `Msg` enum after `CUT_LADDER = 52` (line 81):

```gdscript
	PICKUP_MAG = 53,            ## client -> server (M2 ammo): reclaim a dropped mag <id> (server-validated: owner + look-ray + range + alive)
	DROPPED_MAG_LIST = 54,      ## server -> owner client (M2 ammo): the owner's own dropped mags {id,pos,rounds} -> world marker + "F to pick up"
```

- [ ] **Step 3c: encode/decode** — add after `decode_cut_ladder` (line 786):

```gdscript
## M2 ammo: the owner's own dropped magazines (owner-only — each client gets only their mags).
## Rebuilt + sent on change like GADGET_LIST. Per mag: id u32, pos ×10, rounds u8.
static func encode_dropped_mag_list(list: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.DROPPED_MAG_LIST)
	var n: int = mini(list.size(), 255)
	buf.put_u8(n)
	for i in range(n):
		var m: Dictionary = list[i]
		buf.put_u32(int(m["id"]))
		put_pos10(buf, m["pos"])
		buf.put_u8(clampi(int(m["rounds"]), 0, 255))
	return buf.data_array

static func decode_dropped_mag_list(bytes: PackedByteArray) -> Array:
	var r := body_reader(bytes)
	var n := r.get_u8()
	var out: Array = []
	for _i in range(n):
		out.append({"id": r.get_u32(), "pos": get_pos10(r), "rounds": r.get_u8()})
	return out

static func encode_pickup_mag(mag_id: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.PICKUP_MAG)
	buf.put_u32(mag_id)
	return buf.data_array

static func decode_pickup_mag(bytes: PackedByteArray) -> Dictionary:
	return {"mag_id": body_reader(bytes).get_u32()}
```

- [ ] **Step 4: Run — expect PASS**: `godot --headless --path . -- --test 2>&1 | grep -iE "TESTS:|FAIL"`
- [ ] **Step 5: Commit**: `git add shared/net/protocol.gd shared/net/input_command.gd tests/protocol_test.gd* && git commit -m "feat(m2): DROPPED_MAG_LIST/PICKUP_MAG wire + fast-reload/redistribute input bits"`

---

## Task 4: Server — spare_mags model + FIFO tap reload

**Files:**
- Modify: `server/server_main.gd` (`_SLOT_FIELDS` line 86; spawn ~1314; `_reset_weapon_slots`/`_reset_weapon_loadout` ~1544/1571; reload-complete ~588-595; SELF_STATE send ~1157; `_spawn_reserve` ~1526)
- Modify: `server/fire.gd` (reload-start ~146-152)
- Test: `tests/server_reserve_ammo_test.gd`

- [ ] **Step 1: Write failing test** — append to `tests/server_reserve_ammo_test.gd` (follow the file's existing server-harness setup; it already builds a server + client dict):

```gdscript
func test_tap_reload_is_fifo_and_banks_partial() -> void:
	var srv := _make_server()
	var id := _add_client(srv, Weapon.AR)
	var c = srv._clients[id]
	c["ammo"] = 8
	c["spare_mags"] = [30, 30]
	# Simulate reload-complete directly (reload already in flight, tap).
	c["reloading"] = true
	c["reload_fast"] = false
	c["reload_done_tick"] = srv._sim.tick
	srv._complete_reloads()   # extracted helper wrapping the reload-complete block
	assert_eq(int(c["ammo"]), 30)
	assert_eq(c["spare_mags"], [30, 8])

func test_spawn_builds_full_spare_mags() -> void:
	var srv := _make_server()
	var id := _add_client(srv, Weapon.AR)
	var c = srv._clients[id]
	assert_eq(c["spare_mags"].size(), Weapon.reserve_ammo(Weapon.AR) / int(Weapon.get_def(Weapon.AR)["mag_size"]))
	for m in c["spare_mags"]:
		assert_eq(int(m), int(Weapon.get_def(Weapon.AR)["mag_size"]))
```

> If `_make_server`/`_add_client` helpers don't exist in this test file, mirror the setup already used by the neighbouring tests in `tests/server_reserve_ammo_test.gd` (they construct the server the same way). Extract the reload-complete block (Step 3c) into a `func _complete_reloads()` so the test can call it deterministically.

- [ ] **Step 2: Run — expect FAIL**: `godot --headless --path . -- --test 2>&1 | grep -iE "tap_reload_is_fifo|spawn_builds_full|FAIL"`

- [ ] **Step 3a: Slot field + spawn mags helper** — `server/server_main.gd`:
  - Line 86, add `"spare_mags"` and `"reload_fast"` to `_SLOT_FIELDS`:
    ```gdscript
    const _SLOT_FIELDS := ["weapon", "weapon_def", "ammo", "reserve", "spare_mags", "reloading", "reload_fast", "reload_done_tick", "last_fire_time", "shot_index", "fire_mode"]
    ```
  - After `_spawn_reserve` (line 1527) add a companion:
    ```gdscript
    ## Spawn/resupply spare-mag FIFO for weapon `wid` held by class `cls`, scaled by the class
    ## reserve_mult trait (Support carries extra spare mags). M2 ammo — used everywhere a fresh
    ## spare-mag set is built (spawn / respawn / secondary slot).
    func _spawn_mags(wid: int, cls: int) -> Array:
    	return Weapon.spawn_mags(wid, float(Loadout.class_traits(cls)["reserve_mult"]))
    ```

- [ ] **Step 3b: Build mags on spawn + resets** — set `spare_mags` alongside every place `reserve` is set:
  - Spawn dict (~line 1315, after `"reserve": Weapon.reserve_ammo(wid),`): add `"spare_mags": _spawn_mags(wid, int(c["class"])), "reload_fast": false,`
  - Secondary slot (~line 1471, after `"reserve": _spawn_reserve(swid, int(c["class"])),`): add `"spare_mags": _spawn_mags(swid, int(c["class"])), "reload_fast": false,`
  - `_reset_weapon_loadout` per-slot reset (~line 1577, after `slot["reserve"] = _spawn_reserve(...)`): add `slot["spare_mags"] = _spawn_mags(swid, int(c["class"]))` and `slot["reload_fast"] = false`
  - Active-weapon reset (~line 1545, after `c["reserve"] = _spawn_reserve(wid, cls)`): add `c["spare_mags"] = _spawn_mags(wid, cls)` and `c["reload_fast"] = false`

- [ ] **Step 3c: Reload-complete FIFO/fast** — replace the reload-complete block in `server/server_main.gd` (lines 588-595). Extract into a helper called from the same spot in the per-client loop:

```gdscript
		if c["reloading"] and _sim.tick >= c["reload_done_tick"]:
			_finish_reload(c)
```

and add the method (near the other per-client helpers):

```gdscript
## M2 ammo reload-complete: FIFO tap-reload banks the current partial to the tail and loads the next
## non-empty spare; fast reload already dropped the current mag at reload-start, so it just loads the
## next spare. `reserve` is kept as the derived sum for the resupply caps + wire back-compat.
func _finish_reload(c: Dictionary) -> void:
	c["reloading"] = false
	var spares: Array = c.get("spare_mags", [])
	var res: Array
	if bool(c.get("reload_fast", false)):
		res = Weapon.load_next(spares)
	else:
		res = Weapon.reload_swap(int(c["ammo"]), spares)
	if bool(res[2]):
		c["ammo"] = int(res[0])
		c["spare_mags"] = res[1]
	c["reload_fast"] = false
	c["reserve"] = _sum_mags(c["spare_mags"])
```

Add a tiny helper once (top-level in the class):

```gdscript
func _sum_mags(spare_mags: Array) -> int:
	var s := 0
	for m in spare_mags:
		s += int(m)
	return s
```

Provide the test seam from Step 1 (`_complete_reloads`) as a thin wrapper:

```gdscript
## Test seam: run reload-completion for every client this tick (mirrors the per-client loop guard).
func _complete_reloads() -> void:
	for id in _clients:
		var c = _clients[id]
		if c.get("reloading", false) and _sim.tick >= int(c["reload_done_tick"]):
			_finish_reload(c)
```

- [ ] **Step 3d: Reload-start tap vs fast** — replace `server/fire.gd` lines 146-151:

```gdscript
				# M2 ammo: tap-R (BTN_RELOAD, keep mag) or hold-R fast reload (BTN_FAST_RELOAD, drop mag,
				# 0.75x time). Both require a loadable spare; fast reload drops the current mag now.
				var _spares: Array = c.get("spare_mags", [])
				var _want_tap: bool = (inp["buttons"] & InputCommand.BTN_RELOAD) != 0
				var _want_fast: bool = (inp["buttons"] & InputCommand.BTN_FAST_RELOAD) != 0
				if (_want_tap or _want_fast) and not c["reloading"] \
						and c["ammo"] < Weapon.get_def(c["weapon"])["mag_size"] \
						and Weapon.has_loadable_spare(_spares):
					c["reloading"] = true
					c["reload_fast"] = _want_fast
					var _base: int = int(round(Weapon.get_def(c["weapon"])["reload_secs"] * srv.TICK_RATE))
					c["reload_done_tick"] = srv._sim.tick + (int(round(_base * 0.75)) if _want_fast else _base)
					if _want_fast:
						srv._drop_mag(id, c)   # spawns the recoverable dropped-mag entity (Task 5)
					srv._broadcast_reload_fx(id, int(c["reload_done_tick"]) - srv._sim.tick)
```

> `srv._drop_mag` is added in Task 5. To keep Task 4 compiling+testable on its own, add a temporary no-op stub `func _drop_mag(_id: int, _c: Dictionary) -> void: pass` now and replace it in Task 5.

- [ ] **Step 3e: SELF_STATE send** — `server/server_main.gd` line 1157, append `int(c.get("reserve", 0))`-style — add `c.get("spare_mags", [])` as the new final argument to `Protocol.encode_self_state(...)` (after `int(c.get("grapple_charges", 0))`).

- [ ] **Step 4: Run — expect PASS**: `godot --headless --path . -- --test 2>&1 | grep -iE "TESTS:|FAIL"`
- [ ] **Step 5: Commit**: `git add server/server_main.gd server/fire.gd tests/server_reserve_ammo_test.gd* && git commit -m "feat(m2): server spare-mag model + FIFO tap/fast reload-complete"`

---

## Task 5: Server — fast-reload drop + dropped-mag entity + PICKUP_MAG + sweeps

**Files:**
- Create: `server/dropped_mags.gd`
- Modify: `server/server_main.gd` (`_drop_mag`; `_handle_pickup_mag`; dispatch ~1259; per-tick broadcast; sweeps ~1505/1571/2818; instantiate the store in `_ready`)
- Test: `tests/server_dropped_mag_test.gd` (new)

- [ ] **Step 1: Write failing test** — create `tests/server_dropped_mag_test.gd`:

```gdscript
extends TestCase

const Weapon := preload("res://shared/sim/weapon.gd")

func test_drop_then_pickup_restores_mag() -> void:
	var srv := _make_server()
	var id := _add_client(srv, Weapon.AR)
	var c = srv._clients[id]
	c["ammo"] = 17
	var n_before: int = c["spare_mags"].size()
	srv._drop_mag(id, c)
	var lst := srv._dropped_mags.for_owner(id)
	assert_eq(lst.size(), 1)
	assert_eq(int(lst[0]["rounds"]), 17)
	# Force the pawn to look at the mag + be in range, then pick it up.
	var mag_id := int(lst[0]["id"])
	srv._dropped_mags.set_pos(mag_id, srv._pawns[id].position)   # colocate for the range/look check
	srv._pickup_mag_for(id, mag_id)
	assert_eq(srv._dropped_mags.for_owner(id).size(), 0)
	assert_eq(c["spare_mags"].size(), n_before + 1)
	assert_true(c["spare_mags"].has(17))

func test_other_player_cannot_pick_up_your_mag() -> void:
	var srv := _make_server()
	var owner := _add_client(srv, Weapon.AR)
	var thief := _add_client(srv, Weapon.AR)
	srv._drop_mag(owner, srv._clients[owner])
	var mag_id := int(srv._dropped_mags.for_owner(owner)[0]["id"])
	srv._pickup_mag_for(thief, mag_id)   # wrong owner -> rejected
	assert_eq(srv._dropped_mags.for_owner(owner).size(), 1)

func test_respawn_sweeps_dropped_mags() -> void:
	var srv := _make_server()
	var id := _add_client(srv, Weapon.AR)
	srv._drop_mag(id, srv._clients[id])
	assert_eq(srv._dropped_mags.for_owner(id).size(), 1)
	srv._reset_weapon_loadout(srv._clients[id])
	assert_eq(srv._dropped_mags.for_owner(id).size(), 0)

func test_ttl_despawns_stale_mags() -> void:
	var srv := _make_server()
	var id := _add_client(srv, Weapon.AR)
	srv._drop_mag(id, srv._clients[id])
	srv._dropped_mags.step(srv._sim.tick + ServerDroppedMags.TTL_TICKS + 1)
	assert_eq(srv._dropped_mags.for_owner(id).size(), 0)
```

> Reuse the `_make_server`/`_add_client` helpers from `tests/server_reserve_ammo_test.gd` (copy them or a shared test helper if one exists). `_pickup_mag_for(id, mag_id)` is the server-validated pickup path (Step 3c) with the packet decoding already done.

- [ ] **Step 2: Run — expect FAIL**: `godot --headless --path . -- --test 2>&1 | grep -iE "drop_then_pickup|cannot_pick_up|sweeps_dropped|ttl_despawns|FAIL"`

- [ ] **Step 3a: Create `server/dropped_mags.gd`**:

```gdscript
class_name ServerDroppedMags
extends RefCounted
## M2 ammo: server-owned recoverable dropped magazines from hold-R fast reloads. Owner-keyed;
## only the owner can see/pick up their mags. Rebuilt-on-change per-owner reliable broadcast
## (ReliableList pattern). Mags reset on death/respawn (ammo resets on death) and after a TTL.

const ReliableList := preload("res://server/reliable_list.gd")

const TTL_TICKS := 1800   # ~60 s @30 Hz safety despawn

var _mags: Dictionary = {}          # id -> {id, owner, pos, rounds, spawn_tick}
var _next_id: int = 1
var _rl_by_owner: Dictionary = {}   # owner_id -> ReliableList

func spawn(owner: int, pos: Vector3, rounds: int, tick: int) -> int:
	var id := _next_id
	_next_id += 1
	_mags[id] = {"id": id, "owner": owner, "pos": pos, "rounds": rounds, "spawn_tick": tick}
	return id

func get_mag(id: int) -> Dictionary:
	return _mags.get(id, {})

func remove(id: int) -> void:
	_mags.erase(id)

## Remove all of an owner's mags (death/respawn/disconnect sweep).
func remove_owner(owner: int) -> void:
	for id in _mags.keys():
		if int(_mags[id]["owner"]) == owner:
			_mags.erase(id)
	_rl_by_owner.erase(owner)

## TTL despawn — call each tick.
func step(tick: int) -> void:
	for id in _mags.keys():
		if tick - int(_mags[id]["spawn_tick"]) >= TTL_TICKS:
			_mags.erase(id)

func for_owner(owner: int) -> Array:
	var out: Array = []
	for id in _mags:
		if int(_mags[id]["owner"]) == owner:
			out.append(_mags[id])
	return out

## Decide-to-send latch for one owner's list (ReliableList content compare + heartbeat).
func should_send(owner: int, payload: PackedByteArray, non_empty: bool, tick: int) -> bool:
	if not _rl_by_owner.has(owner):
		_rl_by_owner[owner] = ReliableList.new()
	return _rl_by_owner[owner].should_send(payload, non_empty, tick)

## Test helper — reposition a mag (used to colocate for the range/look check in tests).
func set_pos(id: int, pos: Vector3) -> void:
	if _mags.has(id):
		_mags[id]["pos"] = pos
```

- [ ] **Step 3b: Instantiate + drop** — `server/server_main.gd`:
  - Near the other server subsystem members (where `_grapples`/`_emplacements` are declared), add:
    ```gdscript
    const ServerDroppedMagsC := preload("res://server/dropped_mags.gd")
    var _dropped_mags: ServerDroppedMags = ServerDroppedMagsC.new()
    ```
  - Replace the Task-4 stub `_drop_mag` with:
    ```gdscript
    ## M2 ammo: hold-R fast reload drops the current mag as a recoverable world entity at the pawn's
    ## feet. Its rounds leave the loaded mag (which _finish_reload replaces with the next spare).
    func _drop_mag(id: int, c: Dictionary) -> void:
    	var pawn = _pawns.get(id, null)
    	if pawn == null:
    		return
    	var rounds := int(c["ammo"])
    	if rounds <= 0:
    		return   # nothing worth dropping
    	_dropped_mags.spawn(id, pawn.position, rounds, _sim.tick)
    ```

- [ ] **Step 3c: Pickup path + dispatch** — add the handler and the validated core:
  - Dispatch, `server/server_main.gd:1259` (after `CUT_LADDER`):
    ```gdscript
    		Protocol.Msg.PICKUP_MAG: _handle_pickup_mag(peer, bytes)
    ```
  - Handlers:
    ```gdscript
    func _handle_pickup_mag(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
    	var id := _peer_id.get(peer, 0)
    	if id == 0:
    		return
    	_pickup_mag_for(id, int(Protocol.decode_pickup_mag(bytes)["mag_id"]))

    ## Server-validated dropped-mag pickup: owner-only, pawn alive, mag within reach, roughly aimed at.
    func _pickup_mag_for(id: int, mag_id: int) -> void:
    	var m := _dropped_mags.get_mag(mag_id)
    	if m.is_empty() or int(m["owner"]) != id:
    		return
    	var pawn = _pawns.get(id, null)
    	if pawn == null or not pawn.alive:
    		return
    	var to: Vector3 = (m["pos"] as Vector3) - pawn.eye_position()
    	if to.length() > PICKUP_MAG_RANGE:
    		return
    	if to.length() > 0.5 and to.normalized().dot(Combat._forward(pawn.yaw, pawn.pitch)) < PICKUP_MAG_DOT:
    		return
    	var c = _clients.get(id, {})
    	if c.is_empty():
    		return
    	c["spare_mags"] = (c.get("spare_mags", []) as Array).duplicate()
    	c["spare_mags"].append(int(m["rounds"]))
    	c["reserve"] = _sum_mags(c["spare_mags"])
    	_dropped_mags.remove(mag_id)
    ```
  - Add the two constants near the other tuning consts at the top of the class:
    ```gdscript
    const PICKUP_MAG_RANGE := 2.5   # metres: how close you must be to reclaim a dropped mag
    const PICKUP_MAG_DOT := 0.6     # must be roughly looking at it
    ```
  > Use the same peer→id map the other handlers use — check how `_handle_cut_ladder` resolves `id` from `peer` and mirror it (the snippet assumes `_peer_id`; match the real member name). Likewise confirm the pawn eye/forward helpers (`eye_position()`, `Combat._forward`) match what `fire.gd` uses.

- [ ] **Step 3d: Per-tick TTL + broadcast** — in the main server tick, after the other reliable-list broadcasts (near `EMPLACEMENT_LIST`/`DEPLOYED_LADDER_LIST` sends), add:

```gdscript
	_dropped_mags.step(_sim.tick)
	for hid in _human_ids():   # the same helper/loop used for other owner-only reliable sends
		var lst := _dropped_mags.for_owner(hid)
		var payload := Protocol.encode_dropped_mag_list(lst)
		if _dropped_mags.should_send(hid, payload, not lst.is_empty(), _sim.tick):
			_send_reliable(hid, payload)   # match the existing owner-only reliable send helper
```

> Match `_human_ids()` / `_send_reliable(...)` to whatever the file already uses to send an owner-only reliable message (e.g. how SELF_STATE or FOB_LIST reach a single client). Do not invent new net plumbing.

- [ ] **Step 3e: Sweeps** — remove an owner's dropped mags wherever ammo resets:
  - `_on_peer_disconnected` (~line 2818, beside `_emplacements.remove_owner(id)`): `_dropped_mags.remove_owner(id)`
  - `_reset_weapon_loadout` (respawn/deploy, ~line 1571): at the top, `_dropped_mags.remove_owner(int(c["id"]))` (use whatever id field the client dict carries; if the fn lacks the id, sweep at the call site right after it, where the pawn/id is known — e.g. in the death/respawn path).
  - Death path (`_apply_pawn_damage` when the victim dies, ~line 853): sweep `_dropped_mags.remove_owner(vid)` on the death transition.

- [ ] **Step 4: Run — expect PASS**: `godot --headless --path . -- --test 2>&1 | grep -iE "TESTS:|FAIL"`
- [ ] **Step 5: Commit**: `git add server/dropped_mags.gd* server/server_main.gd server/fire.gd tests/server_dropped_mag_test.gd* && git commit -m "feat(m2): recoverable dropped-mag entity + owner-only PICKUP_MAG + sweeps"`

---

## Task 6: Server — redistribute state machine

**Files:**
- Modify: `server/server_main.gd` (per-tick client loop; `_apply_pawn_damage` cancel; consts)
- Modify: `server/fire.gd` (fire-lock while redistributing)
- Test: `tests/server_reserve_ammo_test.gd`

- [ ] **Step 1: Write failing test** — append to `tests/server_reserve_ammo_test.gd`:

```gdscript
func test_redistribute_consolidates_one_mag_per_period() -> void:
	var srv := _make_server()
	var id := _add_client(srv, Weapon.AR)
	var c = srv._clients[id]
	c["spare_mags"] = [20, 5, 30]
	c["redist_next_tick"] = 0
	srv._step_redistribute(c, true, srv._sim.tick)   # held
	assert_eq(c["spare_mags"], [25, 30])             # 5 poured into 20; empty dropped
	# Cadence: a second call before the 5 s period does nothing.
	srv._step_redistribute(c, true, srv._sim.tick + 1)
	assert_eq(c["spare_mags"], [25, 30])

func test_redistribute_resets_cadence_on_release() -> void:
	var srv := _make_server()
	var id := _add_client(srv, Weapon.AR)
	var c = srv._clients[id]
	c["redist_next_tick"] = srv._sim.tick + 999
	srv._step_redistribute(c, false, srv._sim.tick)   # released
	assert_eq(int(c["redist_next_tick"]), 0)
```

- [ ] **Step 2: Run — expect FAIL**: `godot --headless --path . -- --test 2>&1 | grep -iE "redistribute_consolidates|resets_cadence|FAIL"`

- [ ] **Step 3a: Consts + step method** — `server/server_main.gd`:

```gdscript
const REDISTRIBUTE_PERIOD_TICKS := 150   # 5 s @30 Hz: consolidate one mag per period while held

## M2 ammo: hold-BTN_REDISTRIBUTE consolidates one partial spare mag every REDISTRIBUTE_PERIOD_TICKS
## (fire is locked in fire.gd while held). Releasing — or taking damage (see _apply_pawn_damage) —
## resets the cadence so a fresh 5 s must elapse. Idempotent: safe to call every tick.
func _step_redistribute(c: Dictionary, held: bool, tick: int) -> void:
	if not held:
		c["redist_next_tick"] = 0
		return
	if int(c.get("redist_next_tick", 0)) <= 0:
		c["redist_next_tick"] = tick + REDISTRIBUTE_PERIOD_TICKS
		return
	if tick >= int(c["redist_next_tick"]):
		var mag_size := int(Weapon.get_def(c["weapon"])["mag_size"])
		c["spare_mags"] = Weapon.redistribute_step(c.get("spare_mags", []), mag_size)
		c["reserve"] = _sum_mags(c["spare_mags"])
		c["redist_next_tick"] = tick + REDISTRIBUTE_PERIOD_TICKS
```

- [ ] **Step 3b: Drive it from the per-tick loop** — in the same per-client loop that handles reload-complete/stim (server_main ~588), after `_finish_reload`, add:

```gdscript
			var _redist_held: bool = (int(c["last_input"]["buttons"]) & InputCommand.BTN_REDISTRIBUTE) != 0 if c.get("last_input", null) != null else false
			_step_redistribute(c, _redist_held and not c["reloading"], _sim.tick)
```

- [ ] **Step 3c: Cancel on damage** — in `_apply_pawn_damage` (~line 853), when the victim is a live client taking damage, reset: `if _clients.has(vid): _clients[vid]["redist_next_tick"] = 0`.

- [ ] **Step 3d: Fire-lock while redistributing** — `server/fire.gd`, at the top of the per-shooter fire branch (near line 140 where other fire gates live), skip firing when redistributing:

```gdscript
			if inp["buttons"] & InputCommand.BTN_REDISTRIBUTE: continue   # M2 ammo: no fire while consolidating mags
```

- [ ] **Step 4: Run — expect PASS**: `godot --headless --path . -- --test 2>&1 | grep -iE "TESTS:|FAIL"`
- [ ] **Step 5: Commit**: `git add server/server_main.gd server/fire.gd tests/server_reserve_ammo_test.gd* && git commit -m "feat(m2): redistribute state machine (5s/mag, fire-lock, damage-cancel)"`

---

## Task 7: Server — slow resupply (1 mag / 5s)

**Files:**
- Modify: `server/support.gd` (`give_ammo` ~225-244)
- Modify: `server/server_main.gd` (ammo-bag block ~2477-2493)
- Test: `tests/server_reserve_ammo_test.gd`

- [ ] **Step 1: Write failing test** — append to `tests/server_reserve_ammo_test.gd`:

```gdscript
func test_give_ammo_adds_one_mag_per_period_not_instant() -> void:
	var srv := _make_server()
	var id := _add_client(srv, Weapon.AR)
	var c = srv._clients[id]
	c["ammo"] = 0
	c["spare_mags"] = []   # bone dry
	# One resupply tick on the 5 s cadence: at most one mag worth of rounds appears.
	srv._support.give_ammo(id, 8)
	var total := int(c["ammo"]) + _sum(c["spare_mags"])
	assert_true(total <= int(Weapon.get_def(Weapon.AR)["mag_size"]), "no more than one mag per period")
	assert_true(total > 0, "some ammo dispensed")

func _sum(a: Array) -> int:
	var s := 0
	for v in a: s += int(v)
	return s
```

> If `give_ammo` gates its own cadence internally, call it on a tick where the cadence fires (align `srv._sim.tick` accordingly), matching how the existing `give_ammo` tests in this file drive it.

- [ ] **Step 2: Run — expect FAIL**: `godot --headless --path . -- --test 2>&1 | grep -iE "one_mag_per_period|FAIL"`

- [ ] **Step 3a: `give_ammo` slow** — `server/support.gd`, replace the instant `tc["ammo"] = cap` / `tc["reserve"] = reserve_max` refill (lines ~243-244) with a cadenced `resupply_step`:

```gdscript
	# M2 ammo: refill slowly — one mag's worth of rounds per RESUPPLY_PERIOD, emptiest-mag-first,
	# instead of topping to full instantly. reserve stays the derived sum for the fullness early-out.
	if srv._sim.tick % ServerMain.RESUPPLY_PERIOD_TICKS != 0:
		# still allow the non-ammo dispenses (bandages/stim/grapple/shield) to run below
		pass
	else:
		var _mult: float = float(Loadout.class_traits(int(tc["class"]))["reserve_mult"])
		var _r: Array = Weapon.resupply_step(int(tc["ammo"]), tc.get("spare_mags", []), int(tc["weapon"]), _mult)
		tc["ammo"] = int(_r[0])
		tc["spare_mags"] = _r[1]
		tc["reserve"] = 0
		for _m in tc["spare_mags"]:
			tc["reserve"] += int(_m)
```

> Adjust the ammo-fullness early-out at line 242 so it compares against a **full** state using `spare_mags` (loaded == cap AND `spare_mags` == a full spawn set) rather than the old `reserve >= reserve_max`, so resupply keeps running until mags are actually full. Keep the shield-rearm / bandage / stim / grapple branches intact.

- [ ] **Step 3b: Add the shared cadence const** — `server/server_main.gd` (near the other tuning consts):

```gdscript
const RESUPPLY_PERIOD_TICKS := 150   # 5 s @30 Hz: ammo box / bag / medic give dispense one mag per period (M2 ammo)
```

- [ ] **Step 3c: Static ammo-bag block** — `server/server_main.gd` lines ~2477-2493: replace the instant `tc["ammo"] = cap` / `tc["reserve"] = reserve_max` with the same `RESUPPLY_PERIOD_TICKS`-cadenced `Weapon.resupply_step(...)` call (mirror Step 3a), keeping the `needs_shield_rearm` branch. Update the fullness early-out the same way.

- [ ] **Step 4: Run — expect PASS**: `godot --headless --path . -- --test 2>&1 | grep -iE "TESTS:|FAIL"`
- [ ] **Step 5: Commit**: `git add server/support.gd server/server_main.gd tests/server_reserve_ammo_test.gd* && git commit -m "feat(m2): slow ammo-box/bag/medic resupply (1 mag / 5s)"`

---

## Task 8: Client — WeaponPredictor spare_mags

**Files:**
- Modify: `client/weapon_predictor.gd`
- Test: `tests/weapon_predictor_test.gd`

- [ ] **Step 1: Write failing tests** — append to `tests/weapon_predictor_test.gd`:

```gdscript
func test_predictor_tap_reload_fifo() -> void:
	var wp := WeaponPredictor.new()
	wp.set_weapon(Weapon.AR)
	wp.mag = 8
	wp.spare_mags = [30, 30]
	wp.begin_reload(0, false)
	wp.step(wp.reload_remaining(0) + 1, false, false, false)   # advance past reload-done
	assert_eq(wp.mag, 30)
	assert_eq(wp.spare_mags, [30, 8])

func test_predictor_fast_reload_drops_current() -> void:
	var wp := WeaponPredictor.new()
	wp.set_weapon(Weapon.AR)
	wp.mag = 8
	wp.spare_mags = [30]
	wp.begin_reload(0, true)   # fast: 0.75x + drop current
	assert_true(wp.reload_remaining(0) < int(round(float(Weapon.get_def(Weapon.AR)["reload_secs"]) / SimLoop.DT)))
	wp.step(wp.reload_remaining(0) + 1, false, false, false)
	assert_eq(wp.mag, 30)
	assert_eq(wp.spare_mags, [])   # the 8-round mag was dropped, not banked

func test_predictor_reconcile_snaps_spare_mags() -> void:
	var wp := WeaponPredictor.new()
	wp.set_weapon(Weapon.AR)
	wp.spare_mags = [1, 2]
	wp.reconcile_spare_mags([30, 30, 30])
	assert_eq(wp.spare_mags, [30, 30, 30])

func test_predictor_set_weapon_builds_full_spare_mags() -> void:
	var wp := WeaponPredictor.new()
	wp.set_weapon(Weapon.AR)
	assert_eq(wp.spare_mags.size(), Weapon.reserve_ammo(Weapon.AR) / int(Weapon.get_def(Weapon.AR)["mag_size"]))
```

- [ ] **Step 2: Run — expect FAIL**: `godot --headless --path . -- --test 2>&1 | grep -iE "predictor_tap_reload_fifo|fast_reload_drops|snaps_spare_mags|FAIL"`

- [ ] **Step 3: Implement** — `client/weapon_predictor.gd`:
  - Add member: `var spare_mags: Array = []   # spare-mag FIFO round counts (M2 ammo); reconciled from SELF_STATE`
  - Also add `var _reload_fast: bool = false`
  - `set_weapon` (line 18-25): after `reserve = Weapon.reserve_ammo(w)` add `spare_mags = Weapon.spawn_mags(w)`
  - Replace `step`'s reload-complete (lines 42-48):
    ```gdscript
    	if reloading and tick >= _reload_done_tick:
    		reloading = false
    		var res: Array = Weapon.load_next(spare_mags) if _reload_fast else Weapon.reload_swap(mag, spare_mags)
    		if bool(res[2]):
    			mag = int(res[0])
    			spare_mags = res[1]
    		reserve = _sum_spare()
    		_reload_fast = false
    ```
  - Add helper:
    ```gdscript
    func _sum_spare() -> int:
    	var s := 0
    	for m in spare_mags: s += int(m)
    	return s
    ```
  - Replace `begin_reload` (lines 69-73) to take a `fast` flag and guard on a loadable spare:
    ```gdscript
    func begin_reload(tick: int, fast: bool = false) -> void:
    	if reloading or mag >= int(Weapon.get_def(weapon)["mag_size"]) or not Weapon.has_loadable_spare(spare_mags):
    		return
    	reloading = true
    	_reload_fast = fast
    	var base := int(round(float(Weapon.get_def(weapon)["reload_secs"]) / SimLoop.DT))
    	_reload_done_tick = tick + (int(round(base * 0.75)) if fast else base)
    	if fast and mag > 0:
    		mag = 0   # fast reload drops the current mag immediately (server spawns the pickup)
    ```
  - Add reconcile:
    ```gdscript
    ## Snap the spare-mag FIFO to authority (SELF_STATE). Like reserve, spares only change on
    ## reload/resupply/respawn, so just take authority when present (absent = empty tail from an old
    ## server; leave the local prediction alone in that case).
    func reconcile_spare_mags(auth: Array) -> void:
    	spare_mags = auth.duplicate()
    ```

- [ ] **Step 4: Run — expect PASS**: `godot --headless --path . -- --test 2>&1 | grep -iE "TESTS:|FAIL"`
- [ ] **Step 5: Commit**: `git add client/weapon_predictor.gd tests/weapon_predictor_test.gd* && git commit -m "feat(m2): WeaponPredictor spare-mag FIFO + fast-reload drop + reconcile"`

---

## Task 9: Client — input (hold-vs-tap reload, redistribute, pickup)

**Files:**
- Modify: `client/input_map.gd` (bind redistribute)
- Modify: `client/client_main.gd` (hold-vs-tap reload → BTN_RELOAD/BTN_FAST_RELOAD; BTN_REDISTRIBUTE; PICKUP_MAG on F; predictor `begin_reload(fast)`; SELF_STATE reconcile; DROPPED_MAG_LIST intake)
- Test: manual (input timing is not unit-tested; covered by the gate). No new headless test — but keep the suite green.

- [ ] **Step 1: Bind keys** — `client/input_map.gd`: add `"redistribute": InputCommand.BTN_REDISTRIBUTE,` to the map. Ensure the project has input actions `redistribute` (suggest default key **T**) and reuse the existing interact/`use` action for mag pickup (the same F used for bandage/interact). If an action must be registered, add it in the project input settings the same way `reload`/`aim` are.

- [ ] **Step 2: Hold-vs-tap reload** — `client/client_main.gd`, replace the reload handling at lines 664-672. Track the reload key's hold duration; a short press = tap (keep mag), a hold past a threshold = fast (drop mag):

```gdscript
	# M2 ammo: distinguish tap-R (tactical, keep mag) from hold-R (fast, drop mag). We detect the hold
	# locally and pick the button bit; the predictor mirrors the same choice so the HUD matches.
	var _reload_down: bool = (buttons & InputCommand.BTN_RELOAD) != 0
	if _reload_down:
		_reload_held_ticks += 1
	if _reload_down and _reload_held_ticks == FAST_RELOAD_HOLD_TICKS and not _wpred.reloading:
		# crossed the hold threshold -> promote this reload to a fast reload
		buttons = (buttons & ~InputCommand.BTN_RELOAD) | InputCommand.BTN_FAST_RELOAD
		var _was := _wpred.reloading
		_wpred.begin_reload(_client_tick, true)
		if not _was and _wpred.reloading and _renderer != null:
			_renderer.play_viewmodel_reload(_elapsed, _wpred.reload_remaining(_client_tick) * SimLoop.DT)
	elif not _reload_down and _reload_held_ticks > 0:
		# key released before the threshold -> a tap (tactical) reload
		if _reload_held_ticks < FAST_RELOAD_HOLD_TICKS:
			var _was := _wpred.reloading
			_wpred.begin_reload(_client_tick, false)
			if not _was and _wpred.reloading:
				if _renderer != null:
					_renderer.play_viewmodel_reload(_elapsed, _wpred.reload_remaining(_client_tick) * SimLoop.DT)
				if _audio != null:
					_audio.play_2d("reload")
		_reload_held_ticks = 0
```

Add members near the other input state: `var _reload_held_ticks := 0` and `const FAST_RELOAD_HOLD_TICKS := 9   # ~0.3 s @30 Hz hold to promote a reload to fast`. On a tap, we must **not** also send `BTN_RELOAD` to the server as a fast reload — the server's tap path is fine; for the fast case we swapped the bit above so the server sees `BTN_FAST_RELOAD`. Confirm the `buttons` local is the one appended to `_input_history` (line 682).

- [ ] **Step 3: Redistribute passthrough** — the `redistribute` bind (Step 1) flows through the normal button-mask into `buttons`; no extra client logic needed (server runs the state machine). Ensure build-mode/MG-mount masks (client_main ~571-585) also strip `BTN_REDISTRIBUTE` and `BTN_FAST_RELOAD` where they strip `BTN_RELOAD`.

- [ ] **Step 4: Mag pickup on F** — when a DROPPED_MAG_LIST marker is aimed at within range, pressing the interact key sends `PICKUP_MAG`:

```gdscript
	if _use_pressed_edge and _aimed_dropped_mag_id != 0:
		_net_send_reliable(Protocol.encode_pickup_mag(_aimed_dropped_mag_id))
```

`_aimed_dropped_mag_id` is computed in Task 10 from the mirrored dropped-mag list + camera ray. Use the same reliable-send helper the client already uses for `encode_cut_ladder` / `encode_pickup`-style messages.

- [ ] **Step 5: Reconcile SELF_STATE spare_mags + intake list** — where the client applies decoded SELF_STATE to `_wpred` (search for `reconcile_reserve(`), add:

```gdscript
	if ss.has("spare_mags"):
		_wpred.reconcile_spare_mags(ss["spare_mags"])
```

And in `_on_packet`/message dispatch, handle the new list:

```gdscript
	Protocol.Msg.DROPPED_MAG_LIST:
		_dropped_mags = Protocol.decode_dropped_mag_list(bytes)   # Array of {id,pos,rounds}; consumed by HUD + pickup ray (Task 10)
```

with a member `var _dropped_mags: Array = []`.

- [ ] **Step 6: Run the suite — expect green (no regressions)**: `godot --headless --path . -- --test 2>&1 | grep -iE "TESTS:|FAIL"`
- [ ] **Step 7: Commit**: `git add client/client_main.gd client/input_map.gd && git commit -m "feat(m2): client hold-vs-tap reload, redistribute key, mag pickup + spare_mags reconcile"`

---

## Task 10: Client — HUD mag-glyph strip + dropped-mag prompt

**Files:**
- Modify: `client/hud/hud_model.gd` (`_ammo` ~305-319; add dropped-mag aim resolve)
- Modify: `client/hud/hud_view.gd` (ammo label = number only; draw mag-glyph strip; "F to pick up" prompt)
- Test: `tests/hud_weapon_label_test.gd`

- [ ] **Step 1: Write failing test** — append to `tests/hud_weapon_label_test.gd` (mirror how that file builds the HUD ctx today):

```gdscript
func test_ammo_model_exposes_spare_mags_and_no_reserve_number() -> void:
	var wp := WeaponPredictor.new()
	wp.set_weapon(Weapon.AR)
	wp.mag = 17
	wp.spare_mags = [30, 12, 0]
	var ctx := {"wpred": wp, "tick": 0}
	var m := HudModel.new()
	var a := m._ammo(ctx)
	assert_eq(int(a["mag"]), 17)
	assert_eq(a["spare_mags"], [30, 12, 0])
	# mag_size present so the view can compute each glyph's fill fraction.
	assert_eq(int(a["mag_size"]), int(Weapon.get_def(Weapon.AR)["mag_size"]))
```

> Match the real `HudModel` construction / ctx keys used by the existing tests in this file — the snippet's `HudModel.new()` and `_ammo(ctx)` call should mirror them.

- [ ] **Step 2: Run — expect FAIL**: `godot --headless --path . -- --test 2>&1 | grep -iE "exposes_spare_mags|FAIL"`

- [ ] **Step 3a: Model** — `client/hud/hud_model.gd`, in `_ammo` (the non-RPG return ~313-319) add `spare_mags` + `mag_size`, and drop reliance on `reserve` for display:

```gdscript
	var mag_size := int(Weapon.get_def(wp.weapon)["mag_size"])
	return {
		"mag": wp.mag,
		"spare_mags": wp.spare_mags,   # M2 ammo: per-spare-mag round counts for the glyph strip
		"mag_size": mag_size,
		"reloading": wp.reloading,
		"reload_remaining": wp.reload_remaining(int(ctx.get("tick", 0))),
		"low": wp.mag <= int(ceil(mag_size * LOW_AMMO_FRAC)),
		"fire_mode": Weapon.mode_name(wp.fire_mode) if Weapon.get_def(wp.weapon)["fire_modes"].size() > 1 else "",
	}
```

Keep the RPG branch (line 312) and the empty-default (line 305) as-is but they no longer need a meaningful `reserve` (harmless to leave `reserve` out — the view stops reading it in Step 3b).

- [ ] **Step 3b: View** — `client/hud/hud_view.gd`:
  - Change the ammo label to the **number only** (loaded mag). Find where the ammo text is composed from `mag`/`reserve` (the `_ammo_label` update) and set it to `"%d" % ammo["mag"]` (plus the existing reloading/fire-mode affordances). **Remove the `/ reserve` portion entirely.**
  - Add a **mag-glyph strip** beside the ammo label: for each entry in `ammo["spare_mags"]`, draw a small vertical rounded-rect that is fully grey, over-filled from the bottom up to `rounds / ammo["mag_size"]` in white. Follow the file's existing procedural-draw idiom (e.g. `_BandageGlyph`, `_draw_rect`). Example draw core inside the view's `_draw()`/glyph node:

```gdscript
func _draw_mag_strip(spare_mags: Array, mag_size: int, origin: Vector2) -> void:
	var w := 6.0
	var h := 16.0
	var gap := 4.0
	for i in spare_mags.size():
		var frac: float = clampf(float(spare_mags[i]) / float(max(mag_size, 1)), 0.0, 1.0)
		var x := origin.x + i * (w + gap)
		draw_rect(Rect2(x, origin.y, w, h), Color(0.30, 0.30, 0.30, 0.9))          # empty = grey
		var fill_h := h * frac
		draw_rect(Rect2(x, origin.y + (h - fill_h), w, fill_h), Color(0.95, 0.95, 0.95, 0.95))  # full = white, bottom-up
```

  - **Dropped-mag prompt**: when the model reports an aimed dropped mag, show the existing interaction-prompt affordance with text "Pick up mag (F)".

- [ ] **Step 3c: Aimed-mag resolve** — in `hud_model.gd` add a small helper that, given the mirrored `_dropped_mags` list (passed into ctx as `ctx["dropped_mags"]`) and the camera ray (already available for other interaction prompts), returns the nearest mag id within `PICKUP` range/angle, or 0. Store it so `client_main` (Task 9 Step 4) reads `_aimed_dropped_mag_id`. Wire the value from `hud_model` back to `client_main` the same way the existing interaction-prompt target id is surfaced (follow `_interaction_prompt`).

- [ ] **Step 4: Run — expect PASS + suite green**: `godot --headless --path . -- --test 2>&1 | grep -iE "TESTS:|FAIL"`
- [ ] **Step 5: Commit**: `git add client/hud/hud_model.gd client/hud/hud_view.gd tests/hud_weapon_label_test.gd* && git commit -m "feat(m2): HUD mag-glyph strip (grey->white, bottom-up), drop reserve number, pickup prompt"`

---

## Task 11: Bots — exercise fast reload / redistribute / pickup

**Files:**
- Modify: `bots/exercisers.gd`
- Modify: `server/server_main.gd` (telemetry counters `mags_dropped`/`mags_picked`/`redistributes` on `_stats`, printed in the gate line)
- Test: `tests/server_reserve_ammo_test.gd` (assert a bot path increments a counter deterministically) or extend an existing bot-exerciser test.

- [ ] **Step 1: Write failing test** — append to `tests/server_reserve_ammo_test.gd`:

```gdscript
func test_stats_track_mag_events() -> void:
	var srv := _make_server()
	var id := _add_client(srv, Weapon.AR)
	srv._drop_mag(id, srv._clients[id])
	assert_true(srv._stats.mags_dropped >= 1)
```

> Increment `_stats.mags_dropped` inside `_drop_mag` (Task 5) — add that one line here if not already present. `_stats.mags_picked` in `_pickup_mag_for`, `_stats.redistributes` in `_step_redistribute` on a real consolidation.

- [ ] **Step 2: Run — expect FAIL**: `godot --headless --path . -- --test 2>&1 | grep -iE "track_mag_events|FAIL"`

- [ ] **Step 3a: Stats fields** — in `server/stats.gd` (the `ServerStats` record), add `var mags_dropped := 0`, `var mags_picked := 0`, `var redistributes := 0`. Increment them in `_drop_mag`, `_pickup_mag_for`, and `_step_redistribute` (only when `redistribute_step` actually changed the list). Add all three to the telemetry/gate print line next to the existing counters (search for where `shield_blk`/`nests_dep` are printed).

- [ ] **Step 3b: Bot behaviour** — `bots/exercisers.gd`: for a fraction of gun-bots, occasionally set `BTN_FAST_RELOAD` instead of `BTN_RELOAD` when reloading (so mags drop), then later steer the bot to walk back over its own drop and press the interact bit to pick up. For a small fraction, hold `BTN_REDISTRIBUTE` for ~5–15 s while safe (not in a firefight) so consolidation fires. Follow the existing restrained-exerciser style (latches, cooldowns) used for BREACH/grapple so behaviour is bounded and the sim stays stable. Keep the default gun-bot reload as tap so combat density is unchanged.

- [ ] **Step 4: Run — expect PASS + suite green**: `godot --headless --path . -- --test 2>&1 | grep -iE "TESTS:|FAIL"`
- [ ] **Step 5: Commit**: `git add bots/exercisers.gd server/server_main.gd server/stats.gd tests/server_reserve_ammo_test.gd* && git commit -m "feat(m2): bot exercisers + telemetry for fast-reload/redistribute/pickup"`

---

## Task 12: Fleet gate + docs

**Files:**
- Run: the 128-bot `conquest_town` fleet gate (per memory `blockfire-test-host-game2` / the repo's gate script)
- Modify: `docs/TASKS.md` (mark the M2 backlog item done), `docs/superpowers/specs/2026-07-14-m2-ammo-magazine-system-design.md` (status → implemented)

- [ ] **Step 1: Full suite** — `godot --headless --path . -- --test 2>&1 | tail -5` — expect `TESTS: N run, 0 failed`.

- [ ] **Step 2: Connect smoke** — start the server + a couple of bots and confirm a clean handshake at VERSION 13 (mirror the smoke check used by M17/M19 in prior sessions). Expect 0 script errors and the SELF_STATE mag list arriving.

- [ ] **Step 3: 128-bot gate on `conquest_town`** — run the fleet gate exactly as prior milestones did (128 bots, conquest_town; see `docs/gate-evidence/` for the format). Capture evidence to `docs/gate-evidence/<ts>-m2-ammo-magazine.txt`. Expect: `winner` set, `peak tick < 33.3ms`, `script_errors=0`, and non-zero `mags_dropped` / `mags_picked` / `redistributes`.

- [ ] **Step 4: Update docs** — flip the M2 backlog row in `docs/TASKS.md` to done with the gate evidence line; set the spec status to implemented. Commit:

```bash
git add docs/TASKS.md docs/superpowers/specs/2026-07-14-m2-ammo-magazine-system-design.md docs/gate-evidence/*m2-ammo-magazine.txt
git commit -m "docs(m2): BattleBit ammo/magazine system landed — suite green + 128-bot gate PASS"
```

- [ ] **Step 5: Land** — per `blockfire-land-your-work`: reconcile with master, merge, and push (AGENTS.md §11). Confirm `git log origin/master` shows the merge.

---

## Self-Review (completed during authoring)

- **Spec coverage:** (1) individual mags → Task 1/4/8; (2) FIFO reload skip-empty → Task 1 `reload_swap`, Task 4/8; (3) fast reload 0.75× drop-recoverable owner-only → Task 3 bit, Task 4 start, Task 5 entity+pickup+sweeps, Task 8 predictor, Task 9 hold-detect, Task 10 prompt; (4) redistribute 5s/mag hold, fire-lock, damage-cancel → Task 6; (5) slow resupply 1 mag/5s → Task 7; wire VERSION 13 + SELF_STATE mag list + DROPPED_MAG_LIST/PICKUP_MAG → Task 2/3; HUD number-only + grey→white bottom-up glyph strip, no reserve number → Task 10; bots + gate → Task 11/12. All spec sections map to a task.
- **Placeholder scan:** no TBD/TODO; every code step shows the code. Integration steps that depend on file-local member names (peer→id map, reliable-send helper, human-id loop) explicitly instruct the executor to match the existing idiom rather than guess — flagged, not hand-waved.
- **Type consistency:** `spare_mags` is `Array[int]` everywhere; helper names consistent (`spawn_mags`, `has_loadable_spare`, `reload_swap`, `load_next`, `redistribute_step`, `resupply_step`); `begin_reload(tick, fast)` matches predictor + client caller; `reserve` retained as derived sum on both server (`_sum_mags`) and predictor (`_sum_spare`).
