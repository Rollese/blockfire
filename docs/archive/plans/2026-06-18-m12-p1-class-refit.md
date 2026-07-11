# M12-P1 — Class Refit (Recon removal) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the Recon class (4 classes: Assault/Medic/Engineer/Support), restrict the DMR to Assault, move the claymore to the Engineer as a per-player pick-one with C4 — all at the sim layer, leaving the project compiling and the unit suite green.

**Architecture:** All class/weapon/gadget rules live in the pure `shared/sim/loadout.gd` module (no node, no state). The Engineer's C4-vs-claymore choice is a **deterministic pure function of player id** (`gadget_for_player`) so the server and bots derive the same gadget with **zero replication** — no protocol/welcome change, keeping P1 independent of the in-flight M11 (which touches `protocol.gd` / `STRUCTURE_DELTA`). The server's authoritative gadget gates and the bot AI's placement gates both call that function.

**Tech Stack:** Godot 4.6 GDScript; headless test runner (`godot --headless --path . -- --test`), auto-discovers `tests/**/*_test.gd`, runs each `test_*` method on a `TestCase` subclass.

> **Scope:** This is M12 **Phase 1** only (per [`docs/specs/squad-fob-class-refit.md`](../../specs/squad-fob-class-refit.md) §A and [`M12`](../../milestones/M12-squad-fob-class-refit.md)). P2 (shovel construction) and P3 (FOB) are separate plans, sequenced after the M11 merge. P1 has **no shovel** and **no protocol change**.

**Godot binary:** examples below use `godot`; if the project's wrapper differs, use the same binary the `ci/*.sh` scripts invoke as `$GODOT` (Godot 4.6).

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `shared/sim/loadout.gd` | Pure class→weapon/gadget mapping + loadout validation | **Modify** — remove `RECON`; add `gadget_options`, `is_valid_gadget`, `gadget_for_player`; DMR rule in `can_equip`; `random_class` → `%4` |
| `tests/loadout_test.gd` | Unit tests for `Loadout` | **Modify** — add new-API tests (Task 1); rewrite the Recon-referencing tests (Task 2) |
| `server/server_main.gd` | Authoritative deploy + gadget gates | **Modify** — C4/mine gates use `gadget_for_player`; assign DMR to some Assault bots so the fleet exercises the Assault-only path |
| `bots/bot_driver.gd` | Bot AI gadget placement | **Modify** — C4/mine placement gate on `gadget_for_player`; drop `Loadout.RECON` |

No new files. No `.uid` churn (only existing files edited).

---

### Task 1: Loadout — additive API (gadget options, per-player gadget, DMR restriction)

Non-breaking: `RECON` stays in the enum this task, so the project keeps compiling and every other test is unaffected. We only **add** functions and one `can_equip` rule.

**Files:**
- Modify: `shared/sim/loadout.gd`
- Test: `tests/loadout_test.gd`

- [ ] **Step 1: Append the failing tests**

Add these functions to the end of `tests/loadout_test.gd`:

```gdscript
func test_dmr_only_assault_can_equip() -> void:
	assert_true(Loadout.can_equip(Loadout.ASSAULT, Weapon.DMR), "Assault may equip DMR")
	assert_false(Loadout.can_equip(Loadout.MEDIC, Weapon.DMR), "Medic may not")
	assert_false(Loadout.can_equip(Loadout.ENGINEER, Weapon.DMR), "Engineer may not")
	assert_false(Loadout.can_equip(Loadout.SUPPORT, Weapon.DMR), "Support may not")

func test_engineer_gadget_options_c4_or_mine() -> void:
	assert_eq(Loadout.gadget_options(Loadout.ENGINEER), [Loadout.GADGET_C4, Loadout.GADGET_MINE])
	assert_true(Loadout.is_valid_gadget(Loadout.ENGINEER, Loadout.GADGET_C4))
	assert_true(Loadout.is_valid_gadget(Loadout.ENGINEER, Loadout.GADGET_MINE))
	assert_false(Loadout.is_valid_gadget(Loadout.ENGINEER, Loadout.GADGET_HEAL), "engineer can't pick heal")

func test_single_gadget_classes_validate() -> void:
	assert_true(Loadout.is_valid_gadget(Loadout.MEDIC, Loadout.GADGET_HEAL))
	assert_false(Loadout.is_valid_gadget(Loadout.MEDIC, Loadout.GADGET_C4))
	assert_true(Loadout.is_valid_gadget(Loadout.SUPPORT, Loadout.GADGET_AMMO))

func test_gadget_for_player_engineer_splits_by_id() -> void:
	# Engineers alternate C4 / claymore by id parity so the fleet exercises both.
	assert_eq(Loadout.gadget_for_player(Loadout.ENGINEER, 2), Loadout.GADGET_C4)
	assert_eq(Loadout.gadget_for_player(Loadout.ENGINEER, 3), Loadout.GADGET_MINE)
	# Non-engineers ignore id and use their single gadget.
	assert_eq(Loadout.gadget_for_player(Loadout.MEDIC, 3), Loadout.GADGET_HEAL)
	assert_eq(Loadout.gadget_for_player(Loadout.ASSAULT, 7), Loadout.GADGET_NONE)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `godot --headless --path . -- --test --filter=loadout`
Expected: FAIL — the new tests error/fail because `gadget_options`, `is_valid_gadget`, `gadget_for_player` don't exist yet and `can_equip` doesn't restrict the DMR (so `can_equip(MEDIC, DMR)` returns `true`, failing `assert_false`).

- [ ] **Step 3: Add the new API to `loadout.gd`**

In `shared/sim/loadout.gd`, add the DMR rule to `can_equip` (place the DMR check before the final `return true`):

```gdscript
static func can_equip(cls: int, weapon_id: int) -> bool:
	if weapon_id == Weapon.RPG:
		return cls == ENGINEER
	if weapon_id == Weapon.DMR:
		return cls == ASSAULT
	return true
```

And add these three new functions (anywhere among the statics, e.g. after `gadget_for`):

```gdscript
## The gadgets a class may choose between at the deploy screen. ENGINEER picks one of
## C4 / claymore; every other class has a single gadget (or none).
static func gadget_options(cls: int) -> Array:
	match cls:
		ENGINEER: return [GADGET_C4, GADGET_MINE]
		MEDIC: return [GADGET_HEAL]
		SUPPORT: return [GADGET_AMMO]
		_: return [GADGET_NONE]   # assault

static func is_valid_gadget(cls: int, gadget: int) -> bool:
	return gadget in gadget_options(cls)

## Deterministic per-player gadget selection (used by both server and bots, so they agree with
## no replication): the ENGINEER alternates C4 / claymore by id parity so the fleet exercises
## both; every other class uses its single gadget. Human deploy-screen selection wires in later
## (M7 client / M12-P3).
static func gadget_for_player(cls: int, id: int) -> int:
	if cls == ENGINEER:
		return GADGET_C4 if (id % 2 == 0) else GADGET_MINE
	return gadget_for(cls)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `godot --headless --path . -- --test --filter=loadout`
Expected: PASS — all `loadout` tests green (the new ones plus the still-present Recon ones).

- [ ] **Step 5: Commit**

```bash
git add shared/sim/loadout.gd tests/loadout_test.gd
git commit -m "feat(m12-p1): Loadout gadget options + per-player gadget + DMR Assault-only (additive)"
```

---

### Task 2: Remove Recon and rewire every caller

This is one **atomic** change: removing `RECON` from the enum makes `Loadout.RECON` references in `bot_driver.gd` and `loadout_test.gd` fail to parse, so all three files must change together for the project to compile. There is no intermediate test run between Step 3's edits — the project does not parse cleanly until all `RECON` references are gone.

**Files:**
- Modify: `shared/sim/loadout.gd`
- Modify: `tests/loadout_test.gd`
- Modify: `server/server_main.gd`
- Modify: `bots/bot_driver.gd`

- [ ] **Step 1: Rewrite the Recon-referencing tests in `tests/loadout_test.gd`**

Replace the existing functions `test_each_class_maps_to_a_weapon`, `test_human_class_roll_never_engineer`, `test_recon_uses_dmr_engineer_uses_smg`, `test_gadget_per_class`, `test_rpg_only_engineer_can_equip`, and the trailing `can_equip` test (the ones that mention `Loadout.RECON`) with:

```gdscript
func test_each_class_maps_to_a_weapon() -> void:
	for c in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER, Loadout.SUPPORT]:
		var wid := Loadout.weapon_for(c)
		assert_true(wid in [Weapon.AR, Weapon.SMG], "valid default weapon for class %d" % c)

func test_human_class_roll_never_engineer() -> void:
	for _i in 300:
		var c := Loadout.random_class_no_engineer()
		assert_true(c != Loadout.ENGINEER, "human roll never ENGINEER")
		assert_true(c in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.SUPPORT], "valid non-engineer class")

func test_class_roll_in_range_no_recon() -> void:
	for _i in 300:
		var c := Loadout.random_class()
		assert_true(c >= Loadout.ASSAULT and c <= Loadout.SUPPORT, "class in 0..3 (no Recon)")

func test_default_weapons() -> void:
	assert_eq(Loadout.weapon_for(Loadout.ENGINEER), Weapon.SMG)
	assert_eq(Loadout.weapon_for(Loadout.ASSAULT), Weapon.AR)
	assert_eq(Loadout.weapon_for(Loadout.MEDIC), Weapon.AR)
	assert_eq(Loadout.weapon_for(Loadout.SUPPORT), Weapon.AR)

func test_gadget_per_class_default() -> void:
	assert_eq(Loadout.gadget_for(Loadout.ENGINEER), Loadout.GADGET_C4)   # default option; claymore via gadget_for_player
	assert_eq(Loadout.gadget_for(Loadout.MEDIC), Loadout.GADGET_HEAL)
	assert_eq(Loadout.gadget_for(Loadout.SUPPORT), Loadout.GADGET_AMMO)
	assert_eq(Loadout.gadget_for(Loadout.ASSAULT), Loadout.GADGET_NONE)

func test_rpg_only_engineer_can_equip() -> void:
	assert_true(Loadout.can_equip(Loadout.ENGINEER, Weapon.RPG))
	assert_false(Loadout.can_equip(Loadout.ASSAULT, Weapon.RPG))
	assert_true(Loadout.can_equip(Loadout.ASSAULT, Weapon.AR), "AR unrestricted")
```

Keep the Task-1 functions (`test_dmr_only_assault_can_equip`, etc.) — they have no `RECON` reference.

- [ ] **Step 2: Run loadout tests to verify the new red**

Run: `godot --headless --path . -- --test --filter=loadout`
Expected: FAIL — `test_class_roll_in_range_no_recon` can fail because the current `random_class()` is `randi() % 5` (may return `4`). (`RECON` still exists in the enum at this point, so the project still parses and the runner still starts.)

- [ ] **Step 3: Make the atomic edits (no test run between sub-edits)**

**3a. `shared/sim/loadout.gd`** — remove `RECON` everywhere:

```gdscript
enum { ASSAULT = 0, MEDIC = 1, ENGINEER = 2, SUPPORT = 3 }
```

```gdscript
static func weapon_for(cls: int) -> int:
	match cls:
		ENGINEER: return Weapon.SMG
		_: return Weapon.AR   # assault/medic/support
```

```gdscript
static func gadget_for(cls: int) -> int:
	match cls:
		ENGINEER: return GADGET_C4   # default; claymore alternative via gadget_for_player
		MEDIC: return GADGET_HEAL
		SUPPORT: return GADGET_AMMO
		_: return GADGET_NONE   # assault
```

```gdscript
static func random_class() -> int:
	return randi() % 4

static func random_class_no_engineer() -> int:
	var pool := [ASSAULT, MEDIC, SUPPORT]
	return pool[randi() % pool.size()]
```

Also update the stale comment above `random_class_no_engineer` if it lists Recon — it should read that the pool is Assault/Medic/Support.

**3b. `server/server_main.gd`** — switch the two gadget gates to the per-player function. Change `_place_c4`:

```gdscript
func _place_c4(id: int, p: Pawn, pos: Vector3) -> void:
	if Loadout.gadget_for_player(int(_clients[id]["class"]), id) != Loadout.GADGET_C4: return
```

Change `_place_mine`:

```gdscript
func _place_mine(id: int, p: Pawn, pos: Vector3, facing: Vector3) -> void:
	if Loadout.gadget_for_player(int(_clients[id]["class"]), id) != Loadout.GADGET_MINE: return
```

(Leave `_giver_kind`'s `Loadout.gadget_for(cls)` as-is — Medic/Support are single-gadget; Engineer's default C4 correctly maps to "no give tool".)

**3c. `server/server_main.gd`** — keep the DMR exercised by the fleet (mirrors the engineer-RPG idiom). In `_handle_hello`, immediately after the existing engineer-RPG block (`if cls == Loadout.ENGINEER and id % 3 == 0 and auto_deploy: wid = Weapon.RPG`) and **before** the `if not Loadout.can_equip(...)` guard, add:

```gdscript
	# Hand a third of Assault bots the DMR so the fleet exercises the Assault-only marksman path.
	if cls == Loadout.ASSAULT and id % 3 == 0 and auto_deploy:
		wid = Weapon.DMR
```

(The existing `if not Loadout.can_equip(cls, wid): wid = Loadout.weapon_for(cls)` guard stays — it now also catches any DMR/RPG mis-assignment authoritatively.)

**3d. `bots/bot_driver.gd`** — gate C4 placement on the engineer's chosen gadget. In `_maybe_c4`, change the first line:

```gdscript
func _maybe_c4(bot: Dictionary, me: EntityState, target: EntityState) -> void:
	if Loadout.gadget_for_player(int(bot["class"]), int(bot["id"])) != Loadout.GADGET_C4: return
```

**3e. `bots/bot_driver.gd`** — replace the Recon mine gate. In `_maybe_mine`, change the first line and the doc comment above it (it currently says "Recon claymore"):

```gdscript
## Engineer claymore: an engineer who chose the claymore (gadget_for_player → MINE) drops one
## facing `toward` (the current enemy when fighting, else the contested objective). Re-placed each
## life, so claymores keep appearing along the front.
func _maybe_mine(bot: Dictionary, me: EntityState, toward: Vector3) -> void:
	if Loadout.gadget_for_player(int(bot["class"]), int(bot["id"])) != Loadout.GADGET_MINE or bool(bot["mine_placed"]): return
```

(`_maybe_rpg`'s `if bot["class"] != Loadout.ENGINEER: return` stays — the RPG is a weapon-slot choice, independent of the C4/claymore gadget pick.)

- [ ] **Step 4: Verify the project parses and the full unit suite is green**

Run: `godot --headless --path . --import`
Expected: completes with no GDScript parse errors (confirms `bot_driver.gd` / `server_main.gd` no longer reference the removed `RECON`).

Run: `godot --headless --path . -- --test`
Expected: PASS — entire unit suite green (no remaining `Loadout.RECON` reference anywhere; loadout tests assert the 4-class refit).

- [ ] **Step 5: Verify no Recon references remain**

Run: `grep -rn "Loadout.RECON\|RECON = 4\|RECON:" --include="*.gd" .`
Expected: no output (the `RECON_*` reconciliation constants in `client/client_main.gd` are unrelated and must NOT appear in this grep — it matches only the class form).

- [ ] **Step 6: Commit**

```bash
git add shared/sim/loadout.gd tests/loadout_test.gd server/server_main.gd bots/bot_driver.gd
git commit -m "feat(m12-p1): remove Recon class; DMR Assault-only; claymore -> Engineer (pick-one)"
```

---

### Task 3: Integration check — gadget routing still fires under bot load

The unit tests prove the pure `Loadout` contract. This task proves the server/bot rewiring didn't break live gadget routing: engineers still place C4, claymore-engineers still place mines, and the match still reaches a winner — with no Recon and no script errors.

**Files:**
- No code changes. Runs the existing ≤48-bot smoke (`ci/m4.5_p2_test.sh`), which exercises C4 + mines + gadgets.

- [ ] **Step 1: Run the combat-depth smoke**

Run: `ci/m4.5_p2_test.sh`
(Defaults to ≤48 bots on the local host — see the script header. Use the same host you normally run smokes on.)

- [ ] **Step 2: Confirm the smoke passes and gadget routing is intact**

Expected in the run output / server log:
- the match reaches a declared winner (`[match] OVER winner=...`);
- `c4=` counter ≥ 1 (engineers still place + detonate C4 — proves the `gadget_for_player`→C4 gate works live);
- no GDScript errors in the server or bot logs (`grep -iE "SCRIPT ERROR|Parser Error" <logs>` → empty);
- `mines=` is **report-only** at 48-bot density (a point-blank claymore trip is rare at this scale — do not gate on it here; mine *placement* by odd-id engineers is covered by the bot logic + the 128-bot milestone gate).

If the smoke fails or shows script errors, use superpowers:systematic-debugging before proceeding.

- [ ] **Step 3: Record the result**

Note the smoke result (winner, `c4`, tick) in the M12 milestone doc under a P1 evidence line, or hand it to the operator for the milestone close.

---

## Milestone gate (operator-run on game2 — not a per-task code step)

The authoritative M12-P1 gate is the 128-bot fleet run on `game2` (AGENTS.md §8), proving the refit at full count:

```bash
# on game2, in the repo:
cd docker && docker build -t blockfire:latest -f Dockerfile ..
SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 BOT_REPLICAS=16 BOT_COUNT=8 ./run-gate.sh   # or the current run-*-gate.sh
```

Gate assertions (per [M12 §Gate, P1](../../milestones/M12-squad-fob-class-refit.md#gate)): a winner is declared; **no Recon class** exists (4-class roster); the unit suite's `can_equip` tests prove DMR is Assault-only and the claymore is Engineer-selectable; mines + C4 both fire at 128-bot density (`mines≥1`, `c4≥1`); peak-window mean tick < 33.3 ms. Record the log path + numbers in the milestone doc as the P1 close evidence.

---

## Notes for the executor

- **No protocol/`welcome` change** in P1 — the Engineer's gadget is derived identically on server and bot from `(class, id)` via `Loadout.gadget_for_player`. Do not add a `gadget` field to the welcome message; that would couple P1 to `protocol.gd` (shared with M11).
- **DMR is not auto-assigned to humans** — `weapon_for` never returns DMR; only the explicit Assault-bot assignment (Step 3c) and the future deploy UI request it. `can_equip` is the authoritative guard.
- **Do not** touch the shovel/construction (P2) or FOB (P3) systems here. If a step seems to require them, stop — it belongs in a later phase.
