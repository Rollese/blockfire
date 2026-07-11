# M19 P2a — Wire the passive class traits into the sim

> **For agentic workers:** REQUIRED SUB-SKILL: execute this via superpowers:subagent-driven-development, task-by-task, TDD. Steps use checkbox syntax for tracking.

**Goal:** Make the server actually *read* the four not-yet-wired passive traits already defined in `Loadout.class_traits(cls)` — `blast_mult` (Engineer +20% explosive radius), `reserve_mult` (Support extra spare ammo), `grenade_count` (Support 5 / everyone finite), `regen_fast` (Assault Combat Vigor) — plus the LMG `suppression_mult`. All server-authoritative, deterministic, unit- + fleet-gated. No client screen (that is P3); no new gadgets (that is P2b).

**Architecture:** Every trait is a *read* of the existing `class_traits` table at an existing sim chokepoint, keyed off the owner's class via `_clients[owner]["class"]`. Two traits (`regen_fast`, `grenade_count`) have no existing mechanic to hook, so they introduce a small server-only mechanic (an out-of-combat health-regen loop; a finite per-life grenade pool) — both BattleBit-faithful, both driven by the trait value. `blast_mult`/`reserve_mult`/`suppression_mult` are pure wiring into single funnel functions. `trait_blurbs` (the P3 display strings) already names all of these, so no display change is needed.

**Tech Stack:** Godot 4 / GDScript; `TestCase` harness (`godot --headless --path . -- --test [--filter=X]`); real-server integration tests via `tests/server_fixture.gd`. Health is server-authoritative (not client-predicted), so the regen loop lives server-side and needs no prediction/reconcile change.

---

## Context every implementer needs (read before starting)

- **The trait table** is `Loadout.class_traits(cls) -> Dictionary` at `shared/sim/loadout.gd:168-181`. Keys: `revive_fast`(bool), `bandages`(int), `sledgehammer`(bool), `blast_mult`(float), `regen_fast`(bool), `grenade_count`(int), `reserve_mult`(float). Values today: Engineer `blast_mult=1.2`; Support `grenade_count=5, reserve_mult=1.25`; Assault `regen_fast=true`; everyone else the neutral defaults (`1.0`/`3`/`false`). **Do not change these values** — this plan only wires reads.
- **Owner → class path:** `Pawn.id` == the `_clients` key. Given an owner id, `int(_clients[owner]["class"])` is the class (cached; kept in sync with `_clients[owner]["loadout"]["class"]` by `_apply_loadout_to_client`). Always guard with `_clients.has(owner)` — a blast can be owned by a since-disconnected id.
- **Per-tick sequence** is in `ServerMain._step()` around `server/server_main.gd:437-474`. The suppression-decay pawn loop is at lines 441-444; new per-tick pawn loops (health regen) belong right after it.
- **`SimLoop.DT` = 1/30** (`shared/sim/sim_loop.gd:8`).
- **Integration-test pattern:** model new server tests on `tests/loadout_server_test.gd`. Build a server with `ServerFixture.make_server()`, add a client with `ServerFixture.add_client(srv, id, team, human)` (its record is minimal — `class`/`weapon`/`loadout`/`team`/`auto_deploy` only), add a pawn with `ServerFixture.add_pawn(srv, id, team, pos)`, then call the real server method. `add_client` sets `loadout = Loadout.default_loadout(ASSAULT)`; override `c["loadout"]` + `c["class"]` (or re-`sanitize`) to test other classes. Many server methods assume a fully-built client record (`slots`, `rockets`, `last_grenade_tick`, `grenades`…); call `srv._apply_loadout_to_client(c, p)` first to populate weapon/slot/pool fields, and set any throw/rocket bookkeeping the specific method reads (see each task).
- **Weapon-variants registry:** `class_traits`/blast/reserve/regen/grenade paths do **not** touch the variant registry, but `_apply_loadout_to_client` resolves `default_primary`, which needs the registry loaded. Server tests that spawn go through `default_loadout(ASSAULT)` whose `default_primary` degrades gracefully to the base AR id when the registry is unloaded (`Weapon.default_variant` returns the archetype id if no variants) — so these tests need **no** registry bootstrap unless they assert a specific variant. Do not add registry setup/teardown unless a test actually reads a variant id.
- **Constants** live at the top of `server/server_main.gd` (e.g. `COMBAT_FLAG_TICKS := 300` at line 38, `GRENADE_COOLDOWN_TICKS := 300` at line 56). Add the new P2a constants in that block with a short comment each.

---

### Task 1: LMG suppression multiplier

The LMG def already carries `"suppression_mult": 1.6` (`shared/sim/weapon.gd:25`) and `Weapon.suppression_mult(id)` exists (`weapon.gd:35-36`) but nothing reads it — suppression accrual in `server/fire.gd` ignores the firing weapon. Wire it in.

**Files:**
- Modify: `shared/sim/suppress.gd` (add an optional multiplier to `accrue`)
- Modify: `server/fire.gd:241-244` (pass the firing weapon's `suppression_mult`)
- Test: `tests/suppress_test.gd` (extend)

- [ ] **Step 1: Write the failing test.** In `tests/suppress_test.gd`, add:

```gdscript
func test_accrue_scales_by_multiplier() -> void:
	# Same near-miss distance, mult 2.0 => twice the increment vs baseline (both below the clamp).
	var base := Suppress.accrue(0.0, 1.25)          # closeness 0.5 -> +0.075
	var boosted := Suppress.accrue(0.0, 1.25, 2.0)  # -> +0.15
	assert_true(absf(boosted - 2.0 * base) < 1e-6, "mult scales the accrued increment")

func test_accrue_mult_default_is_unchanged() -> void:
	assert_eq(Suppress.accrue(0.3, 1.25), Suppress.accrue(0.3, 1.25, 1.0))

func test_accrue_mult_still_clamps_to_one() -> void:
	# A huge multiplier cannot push suppression above 1.0.
	assert_eq(Suppress.accrue(0.9, 0.1, 100.0), 1.0)
```

Run: `godot --headless --path . -- --test --filter=suppress`
Expected: FAIL — `accrue` currently takes only `(current, dist)`, so the 3-arg calls error / the scaling assertion fails.

- [ ] **Step 2: Add the multiplier to `Suppress.accrue`.** Replace `shared/sim/suppress.gd:13-18` with:

```gdscript
## Add suppression for a near-miss at `dist` metres (closer = more), clamped to [0,1]. `mult` scales
## the per-shot increment (M19: a Support LMG suppresses harder — Weapon.suppression_mult); default 1.0.
static func accrue(current: float, dist: float, mult: float = 1.0) -> float:
	if dist >= SUPPRESS_RADIUS:
		return current
	var closeness := 1.0 - (dist / SUPPRESS_RADIUS)
	return clampf(current + SUPPRESS_PER_NEARMISS * closeness * mult, 0.0, 1.0)
```

Run: `godot --headless --path . -- --test --filter=suppress`
Expected: PASS.

- [ ] **Step 3: Wire the call site.** In `server/fire.gd`, the accrual is at line 243 inside `step_projectiles`; the firing weapon id is already read as `wid` at line 197 (`var wid: int = int(pr["weapon_id"])`). Change:

```gdscript
	if miss < Suppress.SUPPRESS_RADIUS:
		tgt.suppression = Suppress.accrue(tgt.suppression, miss)
		srv._stats.suppress_events += 1
```
to:
```gdscript
	if miss < Suppress.SUPPRESS_RADIUS:
		tgt.suppression = Suppress.accrue(tgt.suppression, miss, Weapon.suppression_mult(wid))
		srv._stats.suppress_events += 1
```

- [ ] **Step 4: Run the full suite** to confirm no suppression/fire test regressed.

Run: `godot --headless --path . -- --test`
Expected: same green baseline as master (report exact pass/fail counts).

- [ ] **Step 5: Commit.**
```bash
git add shared/sim/suppress.gd server/fire.gd tests/suppress_test.gd
git commit -m "feat(loadout): LMG suppresses harder — wire Weapon.suppression_mult into accrual"
```

---

### Task 2: Engineer +20% explosive blast radius

All three explosives (C4, RPG, frag) — and the inert mine — funnel through one function, `_blast_at(center, owner, team, pawn_dmg, pawn_radius, struct_dmg, struct_radius, veh_dmg, carve_normal)` at `server/server_main.gd:1912`. Scale the pawn and struct radii by the owner's `blast_mult` at the top of that one function, so an Engineer's explosives get a 20% larger radius (and its distance-falloff uses the larger radius, per spec §B). Callers are unchanged.

**Files:**
- Modify: `server/server_main.gd:1912-1928` (scale radii by owner `blast_mult`)
- Test: `tests/engineer_blast_test.gd` (new, server-fixture)

- [ ] **Step 1: Write the failing test.** Create `tests/engineer_blast_test.gd`:

```gdscript
extends TestCase

const ServerFixture := preload("res://tests/server_fixture.gd")

# A victim placed just OUTSIDE the base pawn_radius but INSIDE the Engineer-scaled (×1.2) radius
# takes blast damage only when the owner is an Engineer. Uses the real _blast_at.
func _server_with_owner(cls: int) -> Node:
	var srv = ServerFixture.make_server()
	var owner := ServerFixture.add_client(srv, 1, 0, false)
	owner["class"] = cls
	owner["loadout"] = Loadout.sanitize({"class": cls}, null)
	ServerFixture.add_pawn(srv, 1, 0, Vector3.ZERO)         # the thrower/placer (team 0)
	return srv

func test_engineer_blast_reaches_farther() -> void:
	# base pawn_radius 8.0; place an enemy at 9.0 m (outside base, inside 8.0*1.2 = 9.6).
	var srv = _server_with_owner(Loadout.ENGINEER)
	var victim := ServerFixture.add_pawn(srv, 2, 1, Vector3(9.0, 0.0, 0.0))
	ServerFixture.add_client(srv, 2, 1, false)
	var hits := srv._blast_at(Vector3.ZERO, 1, 0, 100, 8.0, 0, 0.0)
	assert_eq(hits, 1, "Engineer's 20%-larger blast reaches an enemy at 9 m")
	assert_true(victim.health < 100, "victim took falloff damage")

func test_non_engineer_blast_does_not_reach() -> void:
	var srv = _server_with_owner(Loadout.ASSAULT)
	var victim := ServerFixture.add_pawn(srv, 2, 1, Vector3(9.0, 0.0, 0.0))
	ServerFixture.add_client(srv, 2, 1, false)
	var hits := srv._blast_at(Vector3.ZERO, 1, 0, 100, 8.0, 0, 0.0)
	assert_eq(hits, 0, "Assault's un-scaled blast stops short of 9 m")
	assert_eq(victim.health, 100, "victim unharmed")

func test_unknown_owner_uses_baseline() -> void:
	# owner id with no client record => blast_mult defaults to 1.0 (no crash).
	var srv = ServerFixture.make_server()
	var victim := ServerFixture.add_pawn(srv, 2, 1, Vector3(9.0, 0.0, 0.0))
	ServerFixture.add_client(srv, 2, 1, false)
	var hits := srv._blast_at(Vector3.ZERO, 999, 0, 100, 8.0, 0, 0.0)
	assert_eq(hits, 0, "no-record owner falls back to baseline radius")
```

Run: `godot --headless --path . -- --test --filter=engineer_blast`
Expected: FAIL — `test_engineer_blast_reaches_farther` fails (base radius not yet scaled; victim at 9 m unharmed).

> Note: `Loadout.sanitize({...}, null)` is safe here — attachments fall back to defaults when the catalog is null. If `sanitize` on a null catalog fails in this environment, set `owner["loadout"] = Loadout.default_loadout(cls)` and `owner["class"] = cls` instead; the test only reads `owner["class"]`.

- [ ] **Step 2: Scale the radii in `_blast_at`.** At the very top of `_blast_at` (immediately after the signature, `server/server_main.gd:1913`, before the `if struct_dmg > 0` block), insert:

```gdscript
	# M19: an Engineer's explosives get +20% blast radius (class_traits.blast_mult); everyone else ×1.0.
	# One multiply here covers C4/RPG/frag (all route through _blast_at); the scaled radius also widens
	# the distance-falloff (spec §B). Guard: a blast can be owned by a since-disconnected id.
	if _clients.has(owner):
		var bm := float(Loadout.class_traits(int(_clients[owner]["class"]))["blast_mult"])
		pawn_radius *= bm
		struct_radius *= bm
```
(`pawn_radius`/`struct_radius` are value parameters — reassigning them is local to the call.)

Run: `godot --headless --path . -- --test --filter=engineer_blast`
Expected: PASS (all four).

- [ ] **Step 3: Full suite.** Run `godot --headless --path . -- --test`. Expected: green baseline (report counts). Watch for any grenade/C4/RPG damage test that hard-codes a radius boundary — none should break since the default owner class is Assault (`blast_mult=1.0`), but confirm.

- [ ] **Step 4: Commit.**
```bash
git add server/server_main.gd tests/engineer_blast_test.gd
git commit -m "feat(loadout): Engineer +20% explosive blast radius (class_traits.blast_mult in _blast_at)"
```

---

### Task 3: Support extra reserve ammo

`reserve_mult` (Support 1.25) scales the spare-bullet pool a pawn is given **at spawn** and topped back up to **on resupply** (so a Support that resupplies keeps its larger capacity — otherwise an ammo bag would clamp them back to base and silently strip the perk). Add one helper and use it at every reserve-set/cap site.

**Files:**
- Modify: `server/server_main.gd` — add `_spawn_reserve(wid, cls)`; use at the primary-spawn site (`_apply_loadout_to_client`, line 1394), the secondary-slot site (`_build_weapon_slots`, line 1329), the respawn refill (`_reset_weapon_loadout`, line 1415), and the two resupply cap sites (ammo-bag `_step_bags` and active give `server/support.gd`).
- Modify: `server/support.gd` (`give_ammo` reserve cap)
- Test: `tests/server_reserve_ammo_test.gd` (extend)

- [ ] **Step 1: Locate the two resupply cap sites.** Read `server/server_main.gd` around `_step_bags` (the ammo branch ~lines 2144-2155, where `reserve_max := int(Weapon.reserve_ammo(...))` and `tc["reserve"] = reserve_max`) and `server/support.gd` `give_ammo` (~lines 196-208, where `tc["reserve"] = reserve_max`). Confirm exact line numbers before editing.

- [ ] **Step 2: Write the failing test.** In `tests/server_reserve_ammo_test.gd`, add:

```gdscript
const _SF := preload("res://tests/server_fixture.gd")

func _spawn_class(srv, id: int, cls: int) -> Dictionary:
	var c := _SF.add_client(srv, id, 0, false)
	c["loadout"] = Loadout.default_loadout(cls)
	c["class"] = cls
	var p := _SF.add_pawn(srv, id, 0, Vector3.ZERO)
	srv._apply_loadout_to_client(c, p)
	return c

func test_support_spawns_with_boosted_reserve() -> void:
	var srv = _SF.make_server()
	var c := _spawn_class(srv, 1, Loadout.SUPPORT)
	var wid := int(c["weapon"])
	var expected := int(round(float(Weapon.reserve_ammo(wid)) * 1.25))
	assert_eq(int(c["reserve"]), expected, "Support reserve = base × 1.25")
	assert_eq(int(c["slots"][0]["reserve"]), expected, "primary slot reflects the boost")

func test_assault_reserve_unchanged() -> void:
	var srv = _SF.make_server()
	var c := _spawn_class(srv, 1, Loadout.ASSAULT)
	assert_eq(int(c["reserve"]), int(Weapon.reserve_ammo(int(c["weapon"]))), "Assault ×1.0")
```

Run: `godot --headless --path . -- --test --filter=server_reserve_ammo`
Expected: FAIL — `test_support_spawns_with_boosted_reserve` fails (reserve still base value).

- [ ] **Step 3: Add the helper.** Near the other spawn helpers in `server/server_main.gd` (just above `_apply_loadout_to_client`, ~line 1380), add:

```gdscript
## Spawn/resupply reserve pool for weapon `wid` held by class `cls`, scaled by the class reserve_mult
## trait (Support carries extra spare ammo; every other class ×1.0). M19 P2a — used at every point a
## fresh reserve pool or a resupply cap is set, so the Support bonus is consistent across spawn + refill.
func _spawn_reserve(wid: int, cls: int) -> int:
	return int(round(float(Weapon.reserve_ammo(wid)) * float(Loadout.class_traits(cls)["reserve_mult"])))
```

- [ ] **Step 4: Use it at the spawn sites.**
  - `_apply_loadout_to_client`, line 1394: change `c["reserve"] = int(Weapon.reserve_ammo(wid))` to `c["reserve"] = _spawn_reserve(wid, cls)` (`cls` is already in scope there).
  - `_build_weapon_slots`, line 1329 (secondary slot): change `"reserve": int(Weapon.reserve_ammo(swid)),` to `"reserve": _spawn_reserve(swid, int(c["class"])),`.
  - `_reset_weapon_loadout`, line 1415: change `slot["reserve"] = int(Weapon.reserve_ammo(swid))` to `slot["reserve"] = _spawn_reserve(swid, int(c["class"]))`.

- [ ] **Step 5: Use it at the two resupply cap sites** (so resupply tops to the *scaled* max, not base):
  - `_step_bags` ammo branch: change `var reserve_max := int(Weapon.reserve_ammo(int(tc["weapon"])))` to `var reserve_max := _spawn_reserve(int(tc["weapon"]), int(tc["class"]))`. (Confirm `tc` is the target's client record and has `"class"`; every `_clients` record does after connect.)
  - `server/support.gd` `give_ammo`: it computes `reserve_max` similarly — change it to `srv._spawn_reserve(int(tc["weapon"]), int(tc["class"]))` (use whatever the server reference is named in that file — grep for how support.gd calls back into the server, e.g. `srv.` or a stored ref). If `support.gd` cannot reach `_spawn_reserve`, inline the same `int(round(Weapon.reserve_ammo(...) * Loadout.class_traits(int(tc["class"]))["reserve_mult"]))`.

Run: `godot --headless --path . -- --test --filter=server_reserve_ammo`
Expected: PASS.

- [ ] **Step 6: Add a resupply-keeps-boost test** (guards the cap sites). In the same file:

```gdscript
func test_support_resupply_keeps_boost() -> void:
	# After spending reserve, an ammo top-up restores to the SCALED max, not base.
	var srv = _SF.make_server()
	var c := _spawn_class(srv, 1, Loadout.SUPPORT)
	var wid := int(c["weapon"])
	var scaled := int(round(float(Weapon.reserve_ammo(wid)) * 1.25))
	assert_eq(srv._spawn_reserve(wid, Loadout.SUPPORT), scaled, "resupply cap uses the scaled max")
	assert_true(scaled > Weapon.reserve_ammo(wid), "scaled max exceeds base")
```

Run the filter again; expected PASS.

- [ ] **Step 7: Full suite** → `godot --headless --path . -- --test`. Expected green baseline (report counts; watch M17 reserve-ammo tests — default class is Assault ×1.0 so they should be unaffected).

- [ ] **Step 8: Commit.**
```bash
git add server/server_main.gd server/support.gd tests/server_reserve_ammo_test.gd
git commit -m "feat(loadout): Support extra reserve ammo (reserve_mult at spawn + resupply cap)"
```

---

### Task 4: Finite grenade pool (Support 5, everyone else 3)

Today grenades are **unlimited** (cooldown-only — no counter). `grenade_count` introduces a finite per-life pool: a fresh pawn gets `class_traits(cls)["grenade_count"]` throwables (Support 5, others 3), each throw spends one, and the pool refills to full on the next spawn. The pool is shared across frag/smoke (the runtime cycle is unchanged; single-type selection stays a P3 concern — spec §E deferral). Report the remaining count to the HUD so it reflects the pool, not just the cooldown.

**Files:**
- Modify: `server/server_main.gd` — init `c["grenades"]` at spawn (`_apply_loadout_to_client`); decrement + gate in `_handle_grenade_throw` (line 1449); cap the reported counts in `_throwables_for` (line 1236).
- Test: `tests/grenade_pool_test.gd` (new, server-fixture)

- [ ] **Step 1: Write the failing test.** Create `tests/grenade_pool_test.gd`:

```gdscript
extends TestCase

const _SF := preload("res://tests/server_fixture.gd")

func _spawned(cls: int) -> Array:   # [srv, client, pawn]
	var srv = _SF.make_server()
	var c := _SF.add_client(srv, 1, 0, false)
	c["loadout"] = Loadout.default_loadout(cls)
	c["class"] = cls
	var p := _SF.add_pawn(srv, 1, 0, Vector3.ZERO)
	srv._apply_loadout_to_client(c, p)
	c["last_grenade_tick"] = -100000   # off cooldown
	return [srv, c, p]

func test_pool_size_by_class() -> void:
	assert_eq(int(_spawned(Loadout.ASSAULT)[1]["grenades"]), 3, "non-support gets 3")
	assert_eq(int(_spawned(Loadout.SUPPORT)[1]["grenades"]), 5, "support gets 5")

func test_throw_decrements_pool() -> void:
	var s = _spawned(Loadout.ASSAULT)
	var srv = s[0]; var c = s[1]
	var before := int(c["grenades"])
	# Build a valid GRENADE_THROW packet (dir + charge + type) and dispatch via the real handler.
	var bytes := Protocol.encode_grenade_throw(Vector3(1,0,0), 1.0, Grenade.FRAG)
	c["peer"] = null
	srv._peer_to_id[null] = 1
	srv._handle_grenade_throw(null, bytes)
	assert_eq(int(c["grenades"]), before - 1, "one throw spends one grenade")
	assert_eq(srv._grenades.size(), 1, "grenade was actually spawned")

func test_empty_pool_rejects_throw() -> void:
	var s = _spawned(Loadout.ASSAULT)
	var srv = s[0]; var c = s[1]
	c["grenades"] = 0
	var bytes := Protocol.encode_grenade_throw(Vector3(1,0,0), 1.0, Grenade.FRAG)
	c["peer"] = null
	srv._peer_to_id[null] = 1
	srv._handle_grenade_throw(null, bytes)
	assert_eq(srv._grenades.size(), 0, "empty pool throws nothing")

func test_throwables_report_caps_by_pool() -> void:
	var s = _spawned(Loadout.ASSAULT)
	var srv = s[0]; var c = s[1]
	c["grenades"] = 0
	for entry in srv._throwables_for(c):
		if int(entry["kind"]) == Grenade.FRAG or int(entry["kind"]) == Grenade.SMOKE:
			assert_eq(int(entry["count"]), 0, "empty pool reports 0 ready even off cooldown")
```

> Check `Protocol.encode_grenade_throw`'s exact signature/arg order before finalizing the test (grep `func encode_grenade_throw` / `decode_grenade_throw` in `shared/net/protocol.gd`); adjust the call to match. If dispatching through `_handle_grenade_throw` with a `null` peer is awkward, the decrement/gate can also be exercised by calling the handler’s post-decode effect directly — but prefer the real handler.

Run: `godot --headless --path . -- --test --filter=grenade_pool`
Expected: FAIL — `c["grenades"]` doesn't exist yet (throw doesn't decrement; report ignores the pool).

- [ ] **Step 2: Initialise the pool at spawn.** In `_apply_loadout_to_client` (`server/server_main.gd:1381`), add — after `c["class"] = cls` (line 1387) — the pool from the trait:

```gdscript
	c["grenades"] = int(Loadout.class_traits(cls)["grenade_count"])   # M19: finite per-life throwable pool
```
Also seed it in the connect record literal so a client record always has the key even before the first `_apply_loadout_to_client` (defensive): in the `_clients[id] = { ... }` literal (~line 1183, alongside `"last_grenade_tick": -100000,`), add `"grenades": 3,` (overwritten by `_apply_loadout_to_client(_clients[id], p)` at line 1196).

- [ ] **Step 3: Spend + gate in the throw handler.** In `_handle_grenade_throw` (`server/server_main.gd:1449`), after the cooldown gate (line 1455) and before appending to `_grenades`, add a pool check, and decrement on a committed throw. Change the cooldown-gate region to:

```gdscript
	if _sim.tick - int(c["last_grenade_tick"]) < _grenade_cooldown_ticks(c): return
	if int(c.get("grenades", 0)) <= 0: return   # M19: finite grenade pool exhausted this life
	var d := Protocol.decode_grenade_throw(bytes)
	var dir: Vector3 = d["dir"]
	if dir.length() < 0.001: return
	c["last_grenade_tick"] = _sim.tick
	c["grenades"] = int(c["grenades"]) - 1   # spend one from the pool
```
(Keep the rest of the handler — `gtype` clamp, `_grenades.append`, FX broadcast — unchanged. The decrement goes after the `dir` validity check so a zero-dir no-op does not consume a grenade.)

- [ ] **Step 4: Cap the reported counts by the pool.** In `_throwables_for` (`server/server_main.gd:1236`), the FRAG/SMOKE `count` currently equals `ready` (0/1 from cooldown). Make it also reflect the pool so the HUD greys out when empty:

```gdscript
func _throwables_for(c: Dictionary) -> Array:
	var pool := int(c.get("grenades", 0))
	var ready := 1 if (_sim.tick - int(c["last_grenade_tick"]) >= _grenade_cooldown_ticks(c) and pool > 0) else 0
	var list: Array = [{"kind": Grenade.FRAG, "count": ready}, {"kind": Grenade.SMOKE, "count": ready}]
	if int(c["loadout"]["gadget"]) == Loadout.GADGET_RPG:
		list.append({"kind": 100, "count": int(c["rockets"])})
	return list
```
(This keeps the existing 0/1 "ready" semantics for the HUD but forces 0 when the pool is empty. The pool count itself is not a new wire field — SELF_STATE already carries this throwables list; no protocol/VERSION change.)

Run: `godot --headless --path . -- --test --filter=grenade_pool`
Expected: PASS.

- [ ] **Step 5: Full suite** → `godot --headless --path . -- --test`. Expected green baseline. **Watch `tests/grenade_test.gd` / `tests/grenade_gate_test.gd`** — if any test throws grenades through the real handler without seeding `c["grenades"]`, it will now no-op. Fix such a test by seeding the pool (`c["grenades"] = 3`) or calling `_apply_loadout_to_client` first — this is a legitimate test-setup update, not a production change. Report any that needed it.

- [ ] **Step 6: Commit.**
```bash
git add server/server_main.gd tests/grenade_pool_test.gd
git commit -m "feat(loadout): finite grenade pool (Support 5 / others 3, grenade_count trait)"
```

---

### Task 5: Combat Vigor — out-of-combat health regen (Assault faster)

There is **no** passive health regen today (only stamina regen + medic heal-bags). `regen_fast` (Combat Vigor, Assault) presupposes a baseline regen to be "faster" than, so introduce a modest BattleBit-style out-of-combat health regen for **all** classes, with Assault getting a shorter delay + higher rate. Server-authoritative (health isn't predicted), so it's a per-tick server loop plus a "recently damaged" block set at the damage site. All constants gate-tunable.

**Files:**
- Modify: `server/server_main.gd` — add constants; a `_step_health_regen()` loop called each tick; set `regen_block_until` at the damage site (`_apply_pawn_damage`, line 769); reset the two regen fields at spawn (`_apply_loadout_to_client`).
- Test: `tests/health_regen_test.gd` (new, server-fixture)

- [ ] **Step 1: Add constants.** In the constant block near `server/server_main.gd:38`, add:

```gdscript
const HEALTH_REGEN_DELAY_TICKS := 150     # 5s @30Hz out-of-combat before health regen begins (BattleBit-ish)
const HEALTH_REGEN_RATE := 10.0           # HP/sec once regen is active (baseline; gate-tunable)
const ASSAULT_REGEN_DELAY_SCALE := 0.5    # Combat Vigor: half the regen delay (spec §I)
const ASSAULT_REGEN_RATE_SCALE := 1.6     # Combat Vigor: 60% faster regen (spec §I)
```

- [ ] **Step 2: Write the failing test.** Create `tests/health_regen_test.gd`:

```gdscript
extends TestCase

const _SF := preload("res://tests/server_fixture.gd")

func _spawned(cls: int, hp: int) -> Array:   # [srv, client, pawn]
	var srv = _SF.make_server()
	var c := _SF.add_client(srv, 1, 0, false)
	c["loadout"] = Loadout.default_loadout(cls)
	c["class"] = cls
	var p := _SF.add_pawn(srv, 1, 0, Vector3.ZERO)
	srv._apply_loadout_to_client(c, p)
	p.health = hp
	return [srv, c, p]

func _advance(srv, ticks: int) -> void:
	for i in ticks:
		srv._step_health_regen()
		srv._sim.tick += 1

func test_regen_blocked_during_delay() -> void:
	var s = _spawned(Loadout.SUPPORT, 40)   # non-Assault: full 150-tick delay
	var srv = s[0]; var c = s[1]; var p = s[2]
	c["regen_block_until"] = srv._sim.tick + ServerMain.HEALTH_REGEN_DELAY_TICKS
	_advance(srv, 100)   # still inside the block window
	assert_eq(p.health, 40, "no regen while recently in combat")

func test_regen_after_delay() -> void:
	var s = _spawned(Loadout.SUPPORT, 40)
	var srv = s[0]; var c = s[1]; var p = s[2]
	c["regen_block_until"] = 0
	_advance(srv, 60)    # 2s at 10 HP/s ≈ +20
	assert_true(p.health >= 55 and p.health <= 65, "≈+20 HP after 2s out of combat, got %d" % p.health)

func test_assault_regenerates_faster() -> void:
	var a = _spawned(Loadout.ASSAULT, 40); var sup = _spawned(Loadout.SUPPORT, 40)
	a[1]["regen_block_until"] = 0; sup[1]["regen_block_until"] = 0
	_advance(a[0], 60); _advance(sup[0], 60)
	assert_true(int(a[2].health) > int(sup[2].health), "Combat Vigor heals more in the same window")

func test_no_regen_at_full_health() -> void:
	var s = _spawned(Loadout.ASSAULT, 100)
	s[1]["regen_block_until"] = 0
	_advance(s[0], 60)
	assert_eq(int(s[2].health), 100, "never overheals")

func test_no_regen_when_dead_or_downed() -> void:
	var s = _spawned(Loadout.ASSAULT, 30)
	s[1]["regen_block_until"] = 0
	s[2].alive = false
	_advance(s[0], 60)
	assert_eq(int(s[2].health), 30, "dead pawns don't regen")
	s[2].alive = true; s[2].is_downed = true
	_advance(s[0], 60)
	assert_eq(int(s[2].health), 30, "downed pawns don't regen")
```

> If `ServerMain.HEALTH_REGEN_DELAY_TICKS` isn't reachable as a class-const from the test, hard-code `150` in the test with a comment, or read it via the instance. Use whatever the runner accepts for other server consts.

Run: `godot --headless --path . -- --test --filter=health_regen`
Expected: FAIL — `_step_health_regen` doesn't exist.

- [ ] **Step 3: Add the regen loop.** Add the method (near the other `_step_*` helpers, e.g. after `_step_mines`), server-only, health-authoritative:

```gdscript
## M19 Combat Vigor / baseline out-of-combat health regen. Server-authoritative (health is not
## client-predicted): once a pawn has been out of combat for its class regen delay, restore health at
## its class rate up to 100. Assault (regen_fast) has a shorter delay + higher rate. A fractional
## accumulator on the client record avoids int-truncation at low rates. O(pawns)/tick.
func _step_health_regen() -> void:
	for sid in _sim.world.pawns:
		if not _clients.has(sid): continue
		var sp: Pawn = _sim.world.pawns[sid]
		if not sp.alive or sp.is_downed or sp.health >= 100: continue
		var c: Dictionary = _clients[sid]
		if _sim.tick < int(c.get("regen_block_until", 0)): continue
		var fast := bool(Loadout.class_traits(int(c["class"]))["regen_fast"])
		var rate := HEALTH_REGEN_RATE * (ASSAULT_REGEN_RATE_SCALE if fast else 1.0)
		var acc := float(c.get("regen_accum", 0.0)) + rate * SimLoop.DT
		var whole := int(floor(acc))
		if whole > 0:
			sp.health = mini(100, sp.health + whole)
			acc -= float(whole)
		c["regen_accum"] = acc
```

- [ ] **Step 4: Call it each tick.** In `_step()`, right after the suppression-decay loop (`server/server_main.gd:444`), add:

```gdscript
	_step_health_regen()   # M19 Combat Vigor / out-of-combat health regen (after suppression decay)
```

- [ ] **Step 5: Block regen on taking damage.** In `_apply_pawn_damage`, inside the existing `if _clients.has(vid):` block (`server/server_main.gd:772`), set the regen block using the victim's class delay:

```gdscript
	if _clients.has(vid):
		var vc: Dictionary = _clients[vid]
		var vfast := bool(Loadout.class_traits(int(vc["class"]))["regen_fast"])
		vc["regen_block_until"] = _sim.tick + int(round(HEALTH_REGEN_DELAY_TICKS * (ASSAULT_REGEN_DELAY_SCALE if vfast else 1.0)))
		vc["regen_accum"] = 0.0   # a hit interrupts any in-progress fractional heal
		# ... existing damage-event send / kill-credit code continues here ...
```
(Insert at the top of the existing `if _clients.has(vid):` body; keep everything already there.)

- [ ] **Step 6: Reset regen state at spawn.** In `_apply_loadout_to_client`, alongside the other fresh-life resets (after `c["grenades"] = ...` from Task 4), add:

```gdscript
	c["regen_block_until"] = 0
	c["regen_accum"] = 0.0
```

Run: `godot --headless --path . -- --test --filter=health_regen`
Expected: PASS (all cases).

- [ ] **Step 7: Full suite** → `godot --headless --path . -- --test`. Expected green baseline. This adds a per-tick O(pawns) loop — confirm no test times out. Report counts.

- [ ] **Step 8: Commit.**
```bash
git add server/server_main.gd tests/health_regen_test.gd
git commit -m "feat(loadout): out-of-combat health regen + Assault Combat Vigor (regen_fast)"
```

---

### Task 6: Fleet gate + docs/memory

- [ ] **Step 1: Run the 128-bot fleet gate on `conquest_town`** (the P2a traits are live for every bot — Engineer blast, Support reserve/grenades, Assault regen, LMG suppression). From `docker/` on game2:

Run: `TICKETS=200 ./run-m19-gate.sh`
Expected: `M19 P1b GATE: PASS` — valid winner, peak-window mean tick < 33.3 ms, ended on tickets, `script_errors=0`. (Gate script is generic to the M19 loadout fleet; `TICKETS=200` avoids the known `cap_events` liveness flake at 80.) Record winner / elapsed / cap_events / peak tick / script_errors.

- [ ] **Step 2: Update `docs/TASKS.md`** — mark the M19 P2a row (traits) done with the gate numbers.

- [ ] **Step 3: Commit the gate note.**
```bash
git add docs/TASKS.md
git commit -m "gate(loadout): M19 P2a class traits PASS 128p conquest_town (tick <N>ms, script_errors=0)"
```

---

## Not in this plan (P2b, next increment)

The four cheap new gadgets — `STIM` (Combat Stim: timed buff + refillable charges), `SMOKE_WALL` (larger placed smoke; **visual-only** reuse — the smoke system is cosmetic, gameplay LOS-blocking is a separate deferral), `BREACH` (active placed wall-carve via the destruction path), `REPAIR` (structure/FOB HP restore via `repair_chunks`) — each adding its `GADGET_*` to `IMPLEMENTED_GADGETS` as it lands, plus the STIM damage-resist branch and its `SELF_STATE` charge byte. Then the P2b fleet gate.
