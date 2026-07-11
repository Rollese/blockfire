# M19 P2b-medic: STIM + SMOKE_WALL gadgets

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`).

**Goal:** Ship the two Medic gadgets from spec §B/§D — **STIM** (Combat Stim: finite refillable charges granting a timed buff = +move speed, suppression immunity, faster stamina regen, **damage resist** [owner-approved]) and **SMOKE_WALL** (a larger, longer-lasting *placed* smoke cloud reusing the existing smoke-zone render) — making both selectable.

**Architecture:** STIM buff state lives on the pawn as `stim_until_tick` (mirrors `blind_until_tick`). The server owns charges (`_clients[id]["stim_charges"]`), applies damage-resist in `_apply_pawn_damage`, zeroes suppression while stimmed, and injects a `stimmed` flag into the movement `cmd` so `pawn.step` applies the speed + stamina-regen buff **identically on server and (predicted) client**. SMOKE_WALL reuses the `SMOKE_DEPLOYED` wire + client `SmokeCloud` render — the server just places a bigger/longer zone on a cooldown. Wire **VERSION 8 → 9**.

**Key de-risking fact:** there is **no client class-select UI yet** (that's P3), so today every human is class 0 (Assault) and cannot equip a Medic gadget. STIM/SMOKE_WALL are exercised **by bots server-side** (the server injects the `stimmed` flag for bot pawns — bots are not client-predicted). The client wiring in Task 6 is therefore **plumbing for P3**, mirrored on existing patterns; do not over-invest in client prediction validation it can't reach yet.

**Tech Stack:** GDScript / Godot 4. Server `server/server_main.gd`, `server/support.gd`; shared `shared/sim/` (`pawn.gd`, `gadget.gd`, `loadout.gd`); wire `shared/net/protocol.gd`; client `client/client_main.gd`. Tests: `godot --headless --path . -- --test [--filter=X]`; new `class_name` scripts need a real import (`godot --headless --import --path .`) before the class cache knows them; new test files are directory-discovered.

**Scope (do NOT do here):** No BREACH/REPAIR (sibling P2b-structure plan, already landed). No LMG-Nest/Grapple/Riot/Sandbag. No P3 client class-select SCREEN or HUD polish beyond minimal send/read plumbing. STIM v1 is **self-inject only** (spec allows self/teammate; teammate-inject is a noted deferral). SMOKE_WALL is visual/cover only (server smoke is cosmetic; no LOS/AI changes — confirmed, and BattleBit-faithful).

**Verified facts (do not re-derive):**
- IDs already reserved: `Loadout.GADGET_STIM = 6`, `Loadout.GADGET_SMOKE_WALL = 7` (`shared/sim/loadout.gd:24-25`). `gadget_options(MEDIC)` = `[GADGET_HEAL, GADGET_STIM, GADGET_SMOKE_WALL]` (line 57). `IMPLEMENTED_GADGETS` currently `[GADGET_C4, GADGET_HEAL, GADGET_AMMO, GADGET_RPG, GADGET_REPAIR, GADGET_BREACH]` (line 38, after P2b-structure).
- `Gadget.KIND_*` 0–5 + `KIND_BREACH=8`; `_KINDS` string→int (gadget.gd). Catalog `data/gadgets.json` keyed by kind; `Gadget.def_of_kind(kind)`.
- `shared/net/protocol.gd`: `const VERSION := 8`. GADGET_ACTION sub-actions end at `GA_BREACH_PLACE := 9`. `encode_gadget_action(action, pos, dir, target_id)` / `decode_gadget_action` → `{action, pos, dir, target_id}`. `encode_self_state(...)` is append-only (older decoders ignore trailing bytes); `decode_self_state` reads each trailing field guarded by `if r.get_available_bytes() > 0`. `encode_smoke_deployed(pos, radius, expire_tick, vel=ZERO)` / `decode_smoke_deployed`.
- `shared/sim/pawn.gd`: `var blind_until_tick: int = 0` (the timed-status template). `step(dt, cmd, world_half)` computes `var speed := Stance.speed(stance) * (SPRINT_MULT if sprinting else 1.0) * Armor.speed_mult(armor_class)`; stamina regen path `stamina += STAMINA_REGEN * dt` (guarded by `_regen_cooldown`). `const SPRINT_MULT`, `const STAMINA_REGEN := 12.0` are pawn consts.
- `server/server_main.gd`: `_apply_pawn_damage(vid, victim, dmg, headshot, source, killer_id, weapon_id)` — after the `Armor.body_mult`/headshot block computes final `dmg`, and BEFORE `victim.health -= dmg`, is the damage-resist insertion point. The per-tick suppression-decay loop `for sid in _sim.world.pawns: ... sp.suppression = Suppress.decay(...)` (~line 444) is where suppression-immunity zeroes it. `_apply_loadout_to_client(c, p)` re-derives per-spawn state (seed `stim_charges` here). The Pawn.step call site in `SimLoop`/server applies `cmd` — find where `p.step(DT, cmd, ...)` / the sim advances pawns and inject `cmd["stimmed"]`.
- `_begin_smoke(g)` creates a zone `{"pos","radius","expire_tick"}`, appends to `_smoke_zones`, and broadcasts `encode_smoke_deployed(...)` to every client. `SMOKE_DURATION_TICKS := 390`, `SMOKE_RADIUS := 6.0`, `GRENADE_COOLDOWN_TICKS := 300`.
- `server/support.gd`: `give_ammo(target_id, period)` tops up mag+reserve+bandages for a resupplied teammate — the refill hook for stim charges. `_step_bags`/bag path similar.
- Client mirrors SELF_STATE scalars into fields (`_suppression`, `_blind_ticks`, …) and applies them; the local predicted pawn is `_pred.predicted`. Client sends gadget actions via the `is_action_just_pressed("gadget")` block, already branched on `Loadout.default_gadget(_my_class)` (P2b-structure added the branch).
- Test fixture `tests/server_fixture.gd`: `Fixture.make_server()`, `add_pawn`, `add_client` (seeds `loadout=default_loadout(ASSAULT)`, `class=ASSAULT`). Load `Weapon.load_from_file("res://data/weapons.json")` in `setup()`, `Weapon.reset_registry()` in `teardown()`.

---

## Task 1: Register STIM + SMOKE_WALL, add catalog defs

**Files:** `shared/sim/gadget.gd`, `shared/sim/loadout.gd:38`, `data/gadgets.json`; Test: `tests/gadget_catalog_test.gd` + `tests/loadout_sanitize_test.gd` (both exist from P2b-structure).

- [ ] **Step 1: Failing tests.** Add to `tests/loadout_sanitize_test.gd`:
```gdscript
func test_stim_and_smokewall_implemented() -> void:
	assert_true(Loadout.GADGET_STIM in Loadout.IMPLEMENTED_GADGETS, "STIM selectable")
	assert_true(Loadout.GADGET_SMOKE_WALL in Loadout.IMPLEMENTED_GADGETS, "SMOKE_WALL selectable")
func test_medic_stim_survives_sanitize() -> void:
	var cfg := Loadout.default_loadout(Loadout.MEDIC)
	cfg["gadget"] = Loadout.GADGET_STIM
	assert_eq(int(Loadout.sanitize(cfg, _attach())["gadget"]), Loadout.GADGET_STIM)   # match sanitize's real (cfg, attach) sig
func test_medic_smokewall_survives_sanitize() -> void:
	var cfg := Loadout.default_loadout(Loadout.MEDIC)
	cfg["gadget"] = Loadout.GADGET_SMOKE_WALL
	assert_eq(int(Loadout.sanitize(cfg, _attach())["gadget"]), Loadout.GADGET_SMOKE_WALL)
```
Add to `tests/gadget_catalog_test.gd`:
```gdscript
func test_stim_and_smokewall_defs_present() -> void:
	var cat := Gadget.load_file("res://data/gadgets.json")
	var s := cat.def_of_kind(Gadget.KIND_STIM)
	assert_false(s.is_empty(), "stim def loads")
	assert_true(int(s["charges"]) > 0 and int(s["duration_ticks"]) > 0, "stim charges + duration")
	assert_true(float(s["resist"]) < 1.0, "stim damage resist < 1.0")
	var w := cat.def_of_kind(Gadget.KIND_SMOKE_WALL)
	assert_false(w.is_empty(), "smokewall def loads")
	assert_true(float(w["radius"]) > 6.0, "smokewall bigger than a grenade cloud")
```

- [ ] **Step 2: Run to fail.** `godot --headless --import --path .` then `--test --filter=loadout_sanitize` / `--filter=gadget_catalog`. FAIL: KIND_STIM/KIND_SMOKE_WALL undefined, not implemented, defs missing.

- [ ] **Step 3: Implement.** In `shared/sim/gadget.gd` after `const KIND_BREACH := 8`:
```gdscript
const KIND_STIM := 6         # matches Loadout.GADGET_STIM (Medic combat stim)
const KIND_SMOKE_WALL := 7   # matches Loadout.GADGET_SMOKE_WALL (Medic placed smoke)
```
Extend `_KINDS` with `"stim": KIND_STIM, "smokewall": KIND_SMOKE_WALL`.
In `data/gadgets.json` add:
```json
    {"id": "stim", "kind": "stim", "charges": 3, "duration_ticks": 150, "resist": 0.8, "refill": 3, "use_cooldown_ticks": 30},
    {"id": "smokewall", "kind": "smokewall", "radius": 9.0, "duration_ticks": 600, "cooldown_ticks": 450, "place_range": 2.5}
```
In `shared/sim/loadout.gd:38` append `, GADGET_STIM, GADGET_SMOKE_WALL` to `IMPLEMENTED_GADGETS`.

- [ ] **Step 4: Pass.** Re-run both filters + full `--test` (0 failures).
- [ ] **Step 5: Commit.** `git commit -m "feat(m19): register STIM+SMOKE_WALL gadgets (implemented list + catalog defs)"`

---

## Task 2: Wire — VERSION bump, GA codes, SELF_STATE stim bytes

**Files:** `shared/net/protocol.gd`; Test: `tests/protocol_test.gd` (+ the SELF_STATE round-trip test — grep `decode_self_state` in tests/).

- [ ] **Step 1: Failing tests.** In the gadget-action round-trip test add STIM_USE + SMOKE_WALL_PLACE round-trips (mirror the BREACH one). In the SELF_STATE round-trip test, add:
```gdscript
func test_self_state_stim_fields_roundtrip() -> void:
	var b := Protocol.encode_self_state(30, false, 0, 0, [], false, 0.0, 0, 0, false, 0.0, 0.0, 100.0, 0.0, true, false, 0, 0.0, false, 0, false, 0, 0, 2, 144)
	var d := Protocol.decode_self_state(b)
	assert_eq(int(d["stim_charges"]), 2)
	assert_eq(int(d["stim_ticks"]), 144)
```
> IMPLEMENTER: the exact positional arg list of `encode_self_state` is long — READ the real signature and append the two new params at the END (`stim_charges: int = 0, stim_ticks: int = 0`); build the test call from the real defaults rather than copying the arg count above verbatim.

- [ ] **Step 2: Run to fail.**
- [ ] **Step 3: Implement.**
  - `const VERSION := 9   # 9: M19 P2b-medic — STIM charges/duration in SELF_STATE + GA_STIM_USE/GA_SMOKE_WALL_PLACE` (update the trailing comment).
  - After `const GA_BREACH_PLACE := 9`: `const GA_STIM_USE := 10` and `const GA_SMOKE_WALL_PLACE := 11`.
  - `encode_self_state(...)`: add trailing params `stim_charges: int = 0, stim_ticks: int = 0` and append `buf.put_u8(clampi(stim_charges, 0, 255))` then `buf.put_u16(clampi(stim_ticks, 0, 65535))` at the very end (after the last existing put).
  - `decode_self_state(...)`: initialise `var stim_charges := 0` / `var stim_ticks := 0` near the other defaults; append guarded reads at the end (`if r.get_available_bytes() > 0: stim_charges = r.get_u8()` then `if r.get_available_bytes() >= 2: stim_ticks = r.get_u16()`); add `"stim_charges": stim_charges, "stim_ticks": stim_ticks` to the returned dict.
- [ ] **Step 4: Pass.** Filters + full `--test`.
- [ ] **Step 5: Commit.** `git commit -m "feat(m19): wire VERSION 9 — GA_STIM_USE/GA_SMOKE_WALL_PLACE + SELF_STATE stim charges/ticks"`

---

## Task 3: Pawn stim buff — field + speed + stamina via cmd flag

**Files:** `shared/sim/pawn.gd`; Test: `tests/pawn_stim_test.gd` (create; pure Pawn, no server).

- [ ] **Step 1: Failing tests.** Pure-pawn tests that a `stimmed` cmd flag raises move speed + stamina regen. Read an existing `tests/pawn_*_test.gd` for how they build a `cmd` dict and call `p.step(dt, cmd)`.
```gdscript
func test_stim_flag_increases_move_speed() -> void:
	var base := _step_speed(false)
	var boosted := _step_speed(true)
	assert_true(boosted > base * 1.05, "stimmed pawn moves faster")
# _step_speed(stimmed): make a standing Pawn, cmd = {move_x:0, move_y:1, buttons:0, stimmed:stimmed}; p.step(0.1, cmd); return p.velocity.length()
func test_stim_flag_boosts_stamina_regen() -> void:
	# drain stamina, run one regen step with stimmed=false vs true past the regen delay, assert stimmed gained more
	...
```

- [ ] **Step 2: Run to fail** (Pawn ignores `stimmed`).
- [ ] **Step 3: Implement** in `shared/sim/pawn.gd`:
  - Add `var stim_until_tick: int = 0   # M19: Combat Stim buff active until this tick (server-set; mirrors blind_until_tick)`.
  - Add consts `const STIM_SPEED_MULT := 1.15` and `const STIM_STAMINA_MULT := 2.0`.
  - In `step`, read `var stimmed := bool(cmd.get("stimmed", false))`. Multiply the computed `speed` by `(STIM_SPEED_MULT if stimmed else 1.0)`. In the stamina-regen line multiply `STAMINA_REGEN * dt` by `(STIM_STAMINA_MULT if stimmed else 1.0)`.
  > `stim_until_tick` is the authoritative state the SERVER (and P3 client prediction) uses to DERIVE the `stimmed` flag each tick; `pawn.step` itself only reads the flag (it has no tick param). This keeps step pure and prediction-consistent.
- [ ] **Step 4: Pass.** `--import` (new test file) + `--test --filter=pawn_stim` + full `--test`.
- [ ] **Step 5: Commit.** `git commit -m "feat(m19): pawn Combat Stim buff — stim_until_tick + speed/stamina via cmd flag"`

---

## Task 4: STIM server — charges, use, damage-resist, suppression-immunity, refill

**Files:** `server/server_main.gd`, `server/support.gd`; Test: `tests/stim_test.gd` (create; server-fixture).

- [ ] **Step 1: Failing tests** (server-fixture; Medic client with `loadout.gadget=GADGET_STIM`):
  - `test_stim_use_consumes_charge_and_buffs`: seed `c["stim_charges"]=3`; call `srv._use_stim(1)`; assert `c["stim_charges"]==2` AND `pawn.stim_until_tick > srv._sim.tick`.
  - `test_stim_use_gated_on_gadget`: gadget=GADGET_HEAL → `_use_stim` no-ops (charges unchanged, no buff).
  - `test_stim_use_blocked_when_empty`: charges=0 → no buff.
  - `test_stim_damage_resist`: stim a pawn (`pawn.stim_until_tick = tick+100`); `_apply_pawn_damage(vid, victim, 50, false, BULLET, 0, 0)`; assert the HP lost is < 50 (resisted). Compare against an un-stimmed control taking the same hit.
  - `test_stim_suppression_immunity`: set `pawn.suppression=0.8` and stim it; run the suppression-decay loop tick (call the per-tick step or the decay loop directly if extractable); assert suppression == 0.
  - `test_stim_refill_from_giveammo`: Medic with `stim_charges=0` gets `support.give_ammo(...)` → charges restored to max (`refill`).
  > IMPLEMENTER: mirror `tests/breach_test.gd`/`tests/repair_structure_test.gd` setup. For the decay-loop assert, if the loop isn't directly callable, drive `srv._step()`/the smallest tick entry that runs it, or extract the immunity into a tiny helper you can call. Keep it deterministic.

- [ ] **Step 2: Run to fail.**
- [ ] **Step 3: Implement** in `server/server_main.gd`:
  - Seed charges in `_apply_loadout_to_client(c, p)`: `c["stim_charges"] = int(_gadgets.def_of_kind(Gadget.KIND_STIM)["charges"]) if int(c["loadout"]["gadget"]) == Loadout.GADGET_STIM else 0`. Also add `"stim_charges": 0` to the connect-record literal for safety.
  - `_use_stim(id)`: gate `_clients[id]["loadout"]["gadget"] == GADGET_STIM`; pawn alive/not-downed; `charges > 0`; a short `use_cooldown_ticks` gate (store `c["stim_ready_tick"]`); decrement `stim_charges`; `p.stim_until_tick = _sim.tick + duration_ticks`; optional `_stats` counter.
  - Dispatch `Protocol.GA_STIM_USE: _use_stim(id)` in `_handle_gadget_action`.
  - Damage-resist in `_apply_pawn_damage`: after the `Armor.body_mult`/headshot dmg computation and BEFORE `victim.health -= dmg`, add:
    ```gdscript
    if _sim.tick < victim.stim_until_tick:
        dmg = int(round(float(dmg) * float(_gadgets.def_of_kind(Gadget.KIND_STIM)["resist"])))
    ```
  - Suppression-immunity in the per-tick decay loop: `if _sim.tick < sp.stim_until_tick: sp.suppression = 0.0` (before/after the `Suppress.decay`, net effect zero while stimmed).
  - **Inject the `stimmed` flag** at the pawn-step call site: before advancing each pawn, set `cmd["stimmed"] = _sim.tick < p.stim_until_tick` (find where the server builds/passes the movement `cmd` to `p.step` — likely in `SimLoop` or a server input-apply path; the flag must be set for BOTH bots and humans server-side).
  In `server/support.gd` `give_ammo(target_id, period)`: if the target is a Medic with `loadout.gadget == GADGET_STIM`, top up `stim_charges` to the catalog `refill` (mirror the reserve top-up; gate on the period cadence like the rest).
- [ ] **Step 4: Pass.** `--import` + `--test --filter=stim` + full `--test`.
- [ ] **Step 5: Commit.** `git commit -m "feat(m19): STIM server — charges/use/damage-resist/suppression-immunity/refill + stimmed cmd inject"`

---

## Task 5: SMOKE_WALL server — placed cloud on cooldown

**Files:** `server/server_main.gd`; Test: `tests/smoke_wall_test.gd` (create; server-fixture).

- [ ] **Step 1: Failing tests:**
  - `test_smoke_wall_places_zone_and_broadcasts`: Medic with `loadout.gadget=GADGET_SMOKE_WALL`; record `_smoke_zones.size()` before; `srv._place_smoke_wall(1, p, pos)`; assert a zone was added with the catalog radius (`>6`) and a `SMOKE_DEPLOYED` packet was sent (`srv._net.bytes_of(Protocol.Msg.SMOKE_DEPLOYED).size() > 0`).
  - `test_smoke_wall_gated_on_gadget`: gadget=GADGET_HEAL → no zone, no packet.
  - `test_smoke_wall_cooldown`: two back-to-back places → only ONE zone (second blocked by cooldown); advance past `cooldown_ticks` → a third succeeds.

- [ ] **Step 2: Run to fail.**
- [ ] **Step 3: Implement** `_place_smoke_wall(id, p, pos)` in `server/server_main.gd`:
  - gate `loadout.gadget == GADGET_SMOKE_WALL`; pawn alive/not-downed; `p.pos.distance_to(pos) <= place_range`; cooldown gate via `c["smokewall_ready_tick"]` (init 0 in the connect literal / spawn).
  - read `wdef := _gadgets.def_of_kind(Gadget.KIND_SMOKE_WALL)`; create `zone := {"pos": pos, "radius": float(wdef["radius"]), "expire_tick": _sim.tick + int(wdef["duration_ticks"])}`; append to `_smoke_zones`; broadcast `encode_smoke_deployed(pos, wdef["radius"], zone["expire_tick"])` to all clients (mirror `_begin_smoke`'s send loop); `_stats.smokes += 1`; set `c["smokewall_ready_tick"] = _sim.tick + int(wdef["cooldown_ticks"])`.
  - Dispatch `Protocol.GA_SMOKE_WALL_PLACE: _place_smoke_wall(id, p, d["pos"])`.
  (No `_step_*` needed — `_expire_smoke_zones` already drops it on expiry.)
- [ ] **Step 4: Pass.** `--import` + `--test --filter=smoke_wall` + full `--test`.
- [ ] **Step 5: Commit.** `git commit -m "feat(m19): SMOKE_WALL server — placed larger/longer smoke zone on cooldown"`

---

## Task 6: Client plumbing — send actions + read stim SELF_STATE

**Files:** `client/client_main.gd`; no unit test (client input) — verify via headless client connect-smoke.

- [ ] **Step 1: Read** the `is_action_just_pressed("gadget")` branch (P2b-structure left it switching on `Loadout.default_gadget(_my_class)`), and the SELF_STATE-consume block that stores `_suppression`/`_blind_ticks`.
- [ ] **Step 2: Implement (minimal):**
  - In the gadget-action branch add:
    * `GADGET_STIM` → send `encode_gadget_action(Protocol.GA_STIM_USE, _pred.predicted.pos, <aim dir>, 0)`.
    * `GADGET_SMOKE_WALL` → send `encode_gadget_action(Protocol.GA_SMOKE_WALL_PLACE, _pred.predicted.pos, <aim dir>, 0)`.
  - In the SELF_STATE consume: store `_stim_charges = int(d["stim_charges"])` and `_stim_ticks = int(d["stim_ticks"])`; set `_pred.predicted.stim_until_tick = <current predicted tick> + _stim_ticks` so predicted movement gets the speed buff (mirror how `blind_ticks`→`blind_until_tick` is applied if such a mapping exists; if the client applies remaining-ticks differently, follow that pattern). Add the two `var _stim_charges := 0` / `var _stim_ticks := 0` fields.
  - If the client injects `cmd` for local prediction, set `cmd["stimmed"] = <predicted tick> < _pred.predicted.stim_until_tick` in the prediction step (same derivation as the server). If wiring that cleanly is non-trivial, it is acceptable to set the field + leave a `# P3: inject stimmed into predicted cmd` TODO — no human can equip STIM until P3 anyway (document as DONE_WITH_CONCERNS).
- [ ] **Step 3: Verify.** `godot --headless --import --path .`; run the CI connect-smoke (grep `ci/`); full `--test`. No parse/script errors.
- [ ] **Step 4: Commit.** `git commit -m "feat(m19): client plumbing — emit STIM/SMOKE_WALL actions + read stim SELF_STATE"`

---

## Task 7: Bots field STIM/SMOKE_WALL + restrained use

**Files:** `shared/sim/loadout.gd` (`bot_gadget` medic rotation), `bots/exercisers.gd` + `bots/bot_driver.gd`; Test: `tests/loadout_bot_test.gd`.

- [ ] **Step 1: Failing test** — extend `test_bot_matrix_covers_*` (or add):
```gdscript
func test_bot_matrix_covers_stim_and_smokewall() -> void:
	var seen := {}
	for i in 128: seen[int(Loadout.bot_loadout(i)["gadget"])] = true
	assert_true(seen.has(Loadout.GADGET_STIM), "some bot fields STIM")
	assert_true(seen.has(Loadout.GADGET_SMOKE_WALL), "some bot fields SMOKE_WALL")
```
- [ ] **Step 2: Run to fail.**
- [ ] **Step 3: Implement:**
  - `bot_gadget(id, MEDIC)` rotates HEAL/STIM/SMOKE_WALL (`id % 3`) so all three appear across 0–127.
  - `bots/exercisers.gd` (+ driver state, mirror the BREACH/REPAIR pattern P2b-structure added): a STIM medic bot uses stim on a cadence when in combat / low-ish health (harmless — self-buff); a SMOKE_WALL medic bot places a wall rarely (cooldown-gated, e.g. when advancing on an objective), matching the restraint used for BREACH. Both self-gate on `bot_gadget`.
- [ ] **Step 4: Pass.** `--test --filter=loadout_bot` + full `--test`.
- [ ] **Step 5: Commit.** `git commit -m "feat(m19): bot coverage for STIM/SMOKE_WALL + restrained bot use"`

---

## Task 8: Docs + fleet gate + land

- [ ] **Step 1: Full suite** `godot --headless --path . -- --test` → 0 failures.
- [ ] **Step 2: Fleet gate** on game2: `cd docker && SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 TICKETS=200 ./run-m19-gate.sh`. PASS = valid winner, peak tick < 33.3 ms, ended on tickets, `cap_events >= 1`, `script_errors = 0`.
- [ ] **Step 3: Docs** — update the M19 row in `docs/TASKS.md` (P2b-medic done; next = P3 client screen).
- [ ] **Step 4: Commit** docs + gate note + any new test `.uid`.
- [ ] **Step 5: Finish** via superpowers:finishing-a-development-branch — **fetch origin first** (the M20 stats track and others push concurrently); merge origin/master, re-run the suite on the merged tree (remember the class-cache import gotcha: run `godot --headless --import --path .` if new `class_name`s fail to resolve), then merge to master, push, verify `HEAD == origin/master`, delete branch.

---

## Self-review checklist (before Task 1)
- **Spec coverage:** STIM finite refillable charges + timed buff (speed/suppression-immunity/stamina/**resist**) §B ✓ Task 3+4; SMOKE_WALL larger longer placed cloud §D ✓ Task 5; both in IMPLEMENTED_GADGETS ✓ Task 1. Teammate-inject + client HUD deferred to P3 (documented).
- **Wire:** VERSION 8→9; SELF_STATE append-only (backward-safe); new GA codes 10/11. ✓
- **Prediction safety:** speed/stamina buff derived from the SAME `stimmed` flag on server + client (identical rule); server injects for bots too. Human STIM unreachable until P3 (de-risks client prediction). ✓
- **Type consistency:** `KIND_STIM=GADGET_STIM=6`, `KIND_SMOKE_WALL=GADGET_SMOKE_WALL=7`; `stim_until_tick` server-set / step-read; catalog keys (`charges,duration_ticks,resist,refill` / `radius,duration_ticks,cooldown_ticks,place_range`) used identically in producer + consumer. ✓
