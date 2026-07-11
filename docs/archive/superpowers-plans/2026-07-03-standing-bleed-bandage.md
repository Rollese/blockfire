# Standing-Bleed + Bandage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a BattleBit-style standing bleed — a below-threshold bullet/blast hit starts a health-draining bleed that ends only when bandaged (self or teammate) via an all-or-nothing timed channel; medic bandages 2× faster and carries 20 bandages; revive now also spends a bandage.

**Architecture:** Pure rules live in `shared/sim/` (`Bleed`, `Bandage`) so client prediction and server authority can't diverge. The server drives a per-tick `step_bleed()` drain and a latched `step_bandage()` channel (mirroring the existing revive/give latches in `ServerSupport`). A standing bleed-out routes into the *existing* DBNO/halving-bleedout path so it counts as a down. New wire messages `BANDAGE_ACTION` (45, client→server) and `BLEEDING_LIST` (46, server→clients) plus extended `SELF_STATE` carry it. Client uses the one-button (F) interaction resolver for self/teammate bandage; HUD shows a bleeding vignette + cast-bar + teammate marker.

**Tech Stack:** Godot 4 / GDScript; custom headless `TestCase` runner (`godot --headless --path . -- --test --filter=<substr>`); server-integration tests via `tests/server_fixture.gd`; 128-bot fleet gate via `docker/`.

**⚠️ Concurrency:** A second agent is landing the *halving-bleedout* rework (`docs/superpowers/specs/2026-07-03-halving-bleedout-design.md`) uncommitted on `master`. This plan is on branch `worktree-m16-bleeding-system` (branched from `origin/master` 2b3b86a, before their work). Their changes and these are complementary but touch overlapping files — see the spec's §Coordination table. **Never edit their halving-bleedout lines** (`bleedout_window`, `bleed_step`, `bleed_floor`, `down_count`, downed self-bandage removal). This plan consumes only stable shared `Revive` APIs.

**Spec:** `docs/superpowers/specs/2026-07-03-standing-bleed-bandage-design.md`

---

## File Structure

**New pure sim units (shared/, deterministic):**
- `shared/sim/bleed.gd` (`Bleed`) — standing-bleed trigger predicate + drain cadence + constants.
- `shared/sim/bandage.gd` (`Bandage`) — channel timing + `pick_source` charge economy + constants.

**Modified sim/server:**
- `shared/sim/pawn.gd` — add `bleeding`, `bleed_by`, `bleed_weapon` fields.
- `shared/sim/revive.gd` — medic bandage count → 20 (`MEDIC_BANDAGE_COUNT`).
- `shared/sim/support_links.gd` — add `BANDAGE` link kind.
- `server/support.gd` — `bandaging` latch, `step_bleed()`, `step_bandage()`, `handle_bandage_action()`, `drop_bandage_for()`; revive-costs-a-bandage in `step_revives`/`complete_revive`.
- `server/server_main.gd` — bleed trigger in `_apply_pawn_damage`, `_bleed_out_standing()`, respawn reset, tick-loop step calls, `_broadcast_bleeding_list()`, SELF_STATE send, BANDAGE_ACTION route, damage-interrupt hook.
- `server/stats.gd` — `bleeds_started`, `bandages`, `bleed_downs` counters + telemetry line.
- `shared/net/protocol.gd` — `BANDAGE_ACTION` (45), `BLEEDING_LIST` (46), extend `SELF_STATE`.

**Bots / client (visual, self-validated):**
- `bots/ai/behaviors/support.gd`, `bots/bot_driver.gd` — standing-bandage AI.
- `client/client_main.gd`, `client/hud/hud_view.gd` (+ renderer/worldview) — F-bandage input, prompt, vignette, cast-bar, marker, blood VFX.

**Tests:** `tests/bleed_test.gd`, `tests/bandage_test.gd`, `tests/server_bleed_test.gd`, `tests/server_bandage_test.gd`, additions to `tests/protocol_*`/`tests/server_dbno_test.gd`.

**Gate:** `docker/run-bleed-gate.sh`.

---

## Task 1: `Bleed` pure class

**Files:**
- Create: `shared/sim/bleed.gd`
- Test: `tests/bleed_test.gd`

- [ ] **Step 1: Write the failing test**

Create `tests/bleed_test.gd`:

```gdscript
extends TestCase
## Standing-bleed pure rules (shared/sim/bleed.gd). No server/pawn refs — the server holds
## the flag on Pawn and calls these to decide the transition + drain cadence.

func test_below_threshold_bullet_starts_bleed() -> void:
	assert_true(Bleed.should_start(59, Revive.Source.BULLET), "a survived hit leaving <60 HP bleeds")

func test_at_threshold_does_not_bleed() -> void:
	assert_false(Bleed.should_start(60, Revive.Source.BULLET), "exactly at the threshold is a graze")

func test_healthy_graze_does_not_bleed() -> void:
	assert_false(Bleed.should_start(90, Revive.Source.BULLET))

func test_dead_or_downed_hp_does_not_bleed() -> void:
	assert_false(Bleed.should_start(0, Revive.Source.BULLET), "a lethal/down hit isn't a standing bleed")

func test_blast_below_threshold_bleeds() -> void:
	assert_true(Bleed.should_start(30, Revive.Source.BLAST), "shrapnel bleeds")

func test_fall_never_bleeds() -> void:
	assert_false(Bleed.should_start(20, Revive.Source.FALL), "fall damage never bleeds")

func test_drain_cadence_hits_on_period_boundaries() -> void:
	assert_true(Bleed.drain_this_tick(0), "tick 0 drains")
	assert_false(Bleed.drain_this_tick(1))
	assert_true(Bleed.drain_this_tick(Bleed.BLEED_RATE_TICKS), "every BLEED_RATE_TICKS drains 1 HP")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=bleed_test`
Expected: FAIL — `Bleed` not defined / file failed to parse.

- [ ] **Step 3: Write minimal implementation**

Create `shared/sim/bleed.gd`:

```gdscript
class_name Bleed
extends Object
## Pure standing-bleed rules (M16). A non-lethal bullet/blast hit that leaves a pawn wounded
## (below BLEED_THRESHOLD HP) starts a bleed that drains the main health pool until bandaged.
## No side effects and no Pawn refs — the server holds `bleeding` on Pawn and calls these.
## Distinct from Revive's DOWNED bleed-out (bleed_health/bleed_floor). See
## docs/superpowers/specs/2026-07-03-standing-bleed-bandage-design.md.

const BLEED_THRESHOLD := 60      # post-hit HP below which a qualifying hit starts a bleed
const BLEED_RATE_TICKS := 6      # ticks per 1 HP lost while standing-bleeding (~5 HP/s @30 Hz)

## True when a hit that left the pawn ALIVE (post_hit_hp > 0) and wounded (< threshold) should
## start/refresh a standing bleed. Bullets and blasts bleed; fall damage never does.
static func should_start(post_hit_hp: int, source: int) -> bool:
	if post_hit_hp <= 0 or post_hit_hp >= BLEED_THRESHOLD:
		return false
	return source == Revive.Source.BULLET or source == Revive.Source.BLAST

## True on the ticks a standing-bleeding pawn loses 1 HP (server calls once/tick with the sim tick).
static func drain_this_tick(tick: int) -> bool:
	return tick % BLEED_RATE_TICKS == 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=bleed_test`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add shared/sim/bleed.gd tests/bleed_test.gd
git commit -m "feat(sim): Bleed pure rules — standing-bleed trigger + drain cadence"
```

---

## Task 2: `Bandage` pure class

**Files:**
- Create: `shared/sim/bandage.gd`
- Test: `tests/bandage_test.gd`

- [ ] **Step 1: Write the failing test**

Create `tests/bandage_test.gd`:

```gdscript
extends TestCase
## Bandage channel timing + "first-aid kit on your chest" charge economy (shared/sim/bandage.gd).

func test_channel_medic_is_half() -> void:
	assert_eq(Bandage.channel_ticks(false), Bandage.BANDAGE_TICKS)
	assert_eq(Bandage.channel_ticks(true), Bandage.BANDAGE_TICKS / 2, "medic bandages 2x faster")

func test_pick_source_prefers_victim() -> void:
	assert_eq(Bandage.pick_source(3, 3), 0, "spend the victim's kit first")

func test_pick_source_falls_back_to_helper() -> void:
	assert_eq(Bandage.pick_source(0, 2), 1, "victim empty -> helper pays")

func test_pick_source_none_when_both_empty() -> void:
	assert_eq(Bandage.pick_source(0, 0), -1, "no bandage available")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=bandage_test`
Expected: FAIL — `Bandage` not defined.

- [ ] **Step 3: Write minimal implementation**

Create `shared/sim/bandage.gd`:

```gdscript
class_name Bandage
extends Object
## Pure bandage rules (M16): the timed-channel duration (medic 2x) and the victim-first->helper
## charge economy. No side effects — the server holds the latch/progress and decrements the pouch
## the pure picker names. See the standing-bleed design doc.

const BANDAGE_TICKS := 150   # channel duration, non-medic (5 s @30 Hz); medic = half
const BANDAGE_HEAL := 25     # HP restored on a completed bandage (server caps at 100)
const BANDAGE_RANGE := 3.0   # max range (m) to bandage a teammate (matches Revive.REVIVE_RANGE)

## Channel hold duration in ticks; Medic is 2x speed (mirrors Revive.revive_ticks).
static func channel_ticks(is_medic: bool) -> int:
	return (BANDAGE_TICKS / 2) if is_medic else BANDAGE_TICKS

## Which pouch pays for a bandage: 0 = victim, 1 = helper, -1 = neither has one.
## "First-aid kit on your chest": the wounded pawn's own kit is spent first, then the helper's.
static func pick_source(victim_bandages: int, helper_bandages: int) -> int:
	if victim_bandages > 0:
		return 0
	if helper_bandages > 0:
		return 1
	return -1
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=bandage_test`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add shared/sim/bandage.gd tests/bandage_test.gd
git commit -m "feat(sim): Bandage pure rules — channel timing + victim-first charge economy"
```

---

## Task 3: Medic bandage count → 20

**Files:**
- Modify: `shared/sim/revive.gd` (constants block + `bandage_count_for`)
- Test: `tests/bandage_test.gd` (append)

> **Coordination:** this touches the `revive.gd` constants block the halving-bleedout branch also edits. Keep your change to exactly the lines below (the medic count) — do not touch `INITIAL_BLEEDOUT_TICKS` / `BLEED_RATE` / the `bleed_step`/`window` helpers.

- [ ] **Step 1: Write the failing test**

Append to `tests/bandage_test.gd`:

```gdscript
func test_bandage_count_medic_vs_others() -> void:
	assert_eq(Revive.bandage_count_for(false), 3, "non-medic spawns with 3 bandages")
	assert_eq(Revive.bandage_count_for(true), 20, "medic spawns with 20 bandages")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=bandage_test`
Expected: FAIL — medic returns 5 (`3 + 2`), not 20.

- [ ] **Step 3: Write minimal implementation**

In `shared/sim/revive.gd`, replace the `MEDIC_EXTRA_BANDAGES` constant:

```gdscript
const BANDAGE_COUNT := 3         # bandages per spawn, non-medic
const MEDIC_BANDAGE_COUNT := 20  # bandages per spawn, Medic (standing-bleed economy, M16)
```

And replace `bandage_count_for`:

```gdscript
## Bandages a class spawns with (Medic carries far more for the standing-bleed economy).
static func bandage_count_for(is_medic: bool) -> int:
	return MEDIC_BANDAGE_COUNT if is_medic else BANDAGE_COUNT
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=bandage_test`
Expected: PASS (6 tests). Also run `--filter=revive_test` to confirm no revive regression.

- [ ] **Step 5: Commit**

```bash
git add shared/sim/revive.gd tests/bandage_test.gd
git commit -m "feat(sim): Medic spawns with 20 bandages (was 5); base stays 3"
```

---

## Task 4: Pawn standing-bleed fields

**Files:**
- Modify: `shared/sim/pawn.gd:33-36` (field block near `is_downed`)
- Test: covered by Task 6 integration test (fields are plain state).

- [ ] **Step 1: Add the fields**

In `shared/sim/pawn.gd`, immediately after the existing `bandage_count` field, add three fields (do **not** remove or reorder the halving-bleedout fields `down_count`/`bleed_floor`/`bleed_halted` if they are already present from a merge):

```gdscript
var bleeding: bool = false         # M16: standing bleed active (drains `health`, distinct from bleed_health)
var bleed_by: int = 0              # attacker id credited if this standing bleed downs the pawn
var bleed_weapon: int = 0          # weapon id of the bleed source, for the down/kill recap
```

- [ ] **Step 2: Verify it parses**

Run: `godot --headless --path . -- --test --filter=pawn`
Expected: existing pawn tests still PASS (no behavior change yet).

- [ ] **Step 3: Commit**

```bash
git add shared/sim/pawn.gd
git commit -m "feat(sim): Pawn standing-bleed state (bleeding, bleed_by, bleed_weapon)"
```

---

## Task 5: Bleed trigger + respawn reset in the damage pipeline

**Files:**
- Modify: `server/server_main.gd` `_apply_pawn_damage` (survive branch) + `_handle_respawns` reset
- Test: `tests/server_bleed_test.gd`

- [ ] **Step 1: Write the failing test**

Create `tests/server_bleed_test.gd`:

```gdscript
extends TestCase
## Standing-bleed through the REAL server damage path (tests/server_fixture.gd). Default pawns are
## Armor.LIGHT (body_mult 1.0) so damage lands unscaled.

const F := preload("res://tests/server_fixture.gd")

func _apply(srv, victim: Pawn, dmg: int, source := Revive.Source.BULLET, killer_id := 2) -> void:
	srv._apply_pawn_damage(victim.id, victim, dmg, false, source, killer_id, Weapon.AR)

func test_below_threshold_hit_starts_bleed() -> void:
	var srv = autofree(F.make_server())
	var p := F.add_pawn(srv, 1)
	p.health = 100
	_apply(srv, p, 50, Revive.Source.BULLET, 2)   # -> 50 HP, below 60
	assert_true(p.bleeding, "a hit leaving <60 HP starts a bleed")
	assert_eq(p.bleed_by, 2, "bleed credits the attacker")

func test_graze_does_not_bleed() -> void:
	var srv = autofree(F.make_server())
	var p := F.add_pawn(srv, 1)
	p.health = 100
	_apply(srv, p, 20, Revive.Source.BULLET, 2)   # -> 80 HP, above threshold
	assert_false(p.bleeding)

func test_respawn_clears_bleed() -> void:
	var srv = autofree(F.make_server())
	var c := F.add_client(srv, 1)
	var p := F.add_pawn(srv, 1)
	p.bleeding = true; p.bleed_by = 2; p.bleed_weapon = Weapon.AR
	p.alive = false
	c["respawn_tick"] = 1
	srv._sim.tick = 5
	srv._handle_respawns()
	assert_false(p.bleeding, "respawn clears the standing bleed")
	assert_eq(p.bleed_by, 0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=server_bleed_test`
Expected: FAIL — `p.bleeding` stays false (no trigger yet).

- [ ] **Step 3: Write minimal implementation**

In `server/server_main.gd` `_apply_pawn_damage`, find the survive early-return:

```gdscript
	if victim.health > 0:
		return
```

Replace it with (start the bleed *before* returning on survival):

```gdscript
	if victim.health > 0:
		if Bleed.should_start(victim.health, source):
			victim.bleeding = true
			victim.bleed_by = killer_id
			victim.bleed_weapon = weapon_id
		return
```

In `_handle_respawns`, in the respawn block (near `p.bleed_halted = false`), add:

```gdscript
			p.bleeding = false     # M16: fresh life starts un-wounded
			p.bleed_by = 0
			p.bleed_weapon = 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=server_bleed_test`
Expected: PASS (3 tests). Run `--filter=server_dbno_test` to confirm no down/kill regression.

- [ ] **Step 5: Commit**

```bash
git add server/server_main.gd tests/server_bleed_test.gd
git commit -m "feat(server): start a standing bleed on a below-threshold non-lethal hit"
```

---

## Task 6: Bleed drain → DBNO (`step_bleed` + `_bleed_out_standing`) + stats

**Files:**
- Modify: `server/support.gd` (add `step_bleed`)
- Modify: `server/server_main.gd` (add `_bleed_out_standing`, call `step_bleed` in the tick loop)
- Modify: `server/stats.gd` (add `bleeds_started`, `bleed_downs` counters + telemetry)
- Test: `tests/server_bleed_test.gd` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/server_bleed_test.gd`:

```gdscript
func test_bleed_drains_health_over_ticks() -> void:
	var srv = autofree(F.make_server())
	var c := F.add_client(srv, 1)
	var p := F.add_pawn(srv, 1)
	p.health = 30; p.bleeding = true; p.bleed_by = 2
	# BLEED_RATE_TICKS ticks -> lose exactly 1 HP.
	for t in Bleed.BLEED_RATE_TICKS:
		srv._sim.tick = t
		srv._support.step_bleed()
	assert_eq(p.health, 29, "one HP lost per BLEED_RATE_TICKS window")

func test_bleed_to_zero_downs_and_credits_attacker() -> void:
	var srv = autofree(F.make_server())
	var c := F.add_client(srv, 1)
	var p := F.add_pawn(srv, 1)
	p.health = 1; p.bleeding = true; p.bleed_by = 2; p.bleed_weapon = Weapon.AR
	srv._sim.tick = 0            # a drain tick
	srv._support.step_bleed()
	assert_true(p.is_downed, "a standing bleed-out downs the pawn")
	assert_true(p.alive, "downed, not dead")
	assert_eq(int(c.get("downed_by", 0)), 2, "the bleed source is credited for the down")

func test_bandaged_pawn_stops_draining() -> void:
	var srv = autofree(F.make_server())
	var c := F.add_client(srv, 1)
	var p := F.add_pawn(srv, 1)
	p.health = 20; p.bleeding = false     # already cured
	srv._sim.tick = 0
	srv._support.step_bleed()
	assert_eq(p.health, 20, "a non-bleeding pawn never drains")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=server_bleed_test`
Expected: FAIL — `step_bleed` not defined.

- [ ] **Step 3: Write minimal implementation**

In `server/support.gd`, add after `step_downed()`:

```gdscript
## M16 standing bleed: every alive, non-downed, bleeding pawn loses 1 HP on the drain ticks.
## Reaching 0 routes into the normal down/kill decision (credited to the bleed source), so a
## standing bleed-out counts as a DOWN and feeds the halving-bleedout window.
func step_bleed() -> void:
	if not Bleed.drain_this_tick(srv._sim.tick):
		return
	for id in srv._clients:
		var p: Pawn = srv._sim.world.get_pawn(id)
		if p == null or not p.alive or p.is_downed or not p.bleeding:
			continue
		p.health -= 1
		if p.health <= 0:
			p.health = 0
			srv._bleed_out_standing(id, p)
```

In `server/server_main.gd`, add a helper next to `_apply_pawn_damage` (mirrors its death branch but skips armor — the drain HP is already post-armor — and always uses BULLET framing):

```gdscript
## A standing bleed reached 0 HP. Route it through the same down/kill decision as a lethal shot,
## credited to the bleed source. Uses the shared Revive helpers so it stays consistent with the
## halving-bleedout window (a heavily re-downed pawn dies outright instead of entering DBNO).
func _bleed_out_standing(vid: int, victim: Pawn) -> void:
	victim.bleeding = false
	var killer_id := victim.bleed_by
	var weapon_id := victim.bleed_weapon
	_stats.bleed_downs += 1
	if Revive.bleedout_window(victim.down_count + 1) <= 0:
		_kill_pawn(vid, victim, killer_id, weapon_id, false, Revive.Source.BULLET)
	else:
		if _clients.has(vid) and killer_id != 0:
			var dk: Pawn = _sim.world.get_pawn(killer_id)
			_clients[vid]["downed_by"] = killer_id
			_clients[vid]["downed_by_weapon"] = weapon_id
			_clients[vid]["downed_by_hp"] = int(dk.health) if dk != null else 0
			_clients[vid]["downed_by_dist"] = victim.pos.distance_to(dk.pos) if dk != null else 0.0
		_down_pawn(victim)
```

> If the halving-bleedout branch is NOT yet merged when you implement this, `victim.down_count` and `Revive.bleedout_window` won't exist. In that case, temporarily use the pre-merge form `if Revive.is_instant_kill(false, Revive.Source.BULLET): ... else: _down_pawn(victim)` (which is just `_down_pawn`), and leave a `# TODO(merge halving-bleedout): gate outright-kill on bleedout_window` comment. The merge reconciles to the form above.

In the tick loop, after `_support.step_downed()` (line ~370), add:

```gdscript
	_support.step_bleed()
```

In `server/stats.gd`, add counters after `revives`:

```gdscript
var bleeds_started := 0      # M16: standing bleeds started
var bandages := 0            # M16: standing bleeds cured by a bandage
var bleed_downs := 0         # M16: pawns downed by an untreated standing bleed
```

Add ` bleeds=%d bandages=%d bleeddowns=%d` to the telemetry format string right after `revives=%d`, and add `bleeds_started, bandages, bleed_downs` to the `%` arg list right after `revives`. Add them to `reset_window()` next to `revives = 0`:

```gdscript
	bleeds_started = 0; bandages = 0; bleed_downs = 0
```

Finally, increment `bleeds_started` where the bleed starts — in `server/server_main.gd` `_apply_pawn_damage`, change the Task-5 trigger to only count a *newly* started bleed:

```gdscript
	if victim.health > 0:
		if Bleed.should_start(victim.health, source):
			if not victim.bleeding:
				_stats.bleeds_started += 1
			victim.bleeding = true
			victim.bleed_by = killer_id
			victim.bleed_weapon = weapon_id
		return
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=server_bleed_test`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add server/support.gd server/server_main.gd server/stats.gd tests/server_bleed_test.gd
git commit -m "feat(server): standing-bleed drain routes to DBNO; bleed stats counters"
```

---

## Task 7: Wire — `BANDAGE_ACTION` (45) codec

**Files:**
- Modify: `shared/net/protocol.gd` (Msg enum + encode/decode)
- Test: `tests/protocol_bandage_test.gd`

- [ ] **Step 1: Write the failing test**

Create `tests/protocol_bandage_test.gd`:

```gdscript
extends TestCase
## BANDAGE_ACTION (45) round-trip. Mirrors REVIVE_ACTION's shape (target + active bit).

func test_bandage_action_roundtrip_active() -> void:
	var pkt := Protocol.encode_bandage_action(7, true)
	assert_eq(pkt[0], Protocol.Msg.BANDAGE_ACTION)
	var d := Protocol.decode_bandage_action(pkt)
	assert_eq(int(d["target"]), 7)
	assert_true(bool(d["active"]))

func test_bandage_action_roundtrip_stop() -> void:
	var d := Protocol.decode_bandage_action(Protocol.encode_bandage_action(3, false))
	assert_eq(int(d["target"]), 3)
	assert_false(bool(d["active"]))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=protocol_bandage_test`
Expected: FAIL — `Msg.BANDAGE_ACTION` / `encode_bandage_action` undefined.

- [ ] **Step 3: Write minimal implementation**

In `shared/net/protocol.gd` `enum Msg`, after `DOWNED_LIST = 44,`:

```gdscript
	BANDAGE_ACTION = 45,    ## client -> server: begin/continue (active) or stop bandaging a bleeding pawn (self or teammate)
	BLEEDING_LIST = 46,     ## server -> human clients: standing-bleeding allied pawns {id} -> bleed marker + bandage prompt
```

Add the codec (next to `encode_revive_action`):

```gdscript
static func encode_bandage_action(target_id: int, active: bool) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.BANDAGE_ACTION)
	buf.put_u32(target_id)
	buf.put_u8(1 if active else 0)
	return buf.data_array

static func decode_bandage_action(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	return {"target": r.get_u32(), "active": r.get_u8() == 1}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=protocol_bandage_test`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add shared/net/protocol.gd tests/protocol_bandage_test.gd
git commit -m "feat(wire): BANDAGE_ACTION (45) + reserve BLEEDING_LIST (46)"
```

---

## Task 8: Bandage channel — latch, `step_bandage`, `handle_bandage_action`, damage interrupt

**Files:**
- Modify: `server/support.gd` (latch fields, `step_bandage`, `handle_bandage_action`, `drop_bandage_for`)
- Modify: `server/server_main.gd` (route `BANDAGE_ACTION`, call `step_bandage` in tick loop, damage-interrupt hook, `bandages` stat)
- Modify: `shared/sim/support_links.gd` (add `BANDAGE` kind)
- Test: `tests/server_bandage_test.gd`

- [ ] **Step 1: Write the failing test**

Create `tests/server_bandage_test.gd`:

```gdscript
extends TestCase
## Standing-bandage channel through the REAL server (tests/server_fixture.gd): completion heals +
## stops the bleed, medic is 2x faster, the pouch economy is victim-first, and any interruption
## (out of range / sprint / fire / damage) hard-resets progress.

const F := preload("res://tests/server_fixture.gd")

func _bleeding_pawn(srv, id: int, hp := 40) -> Pawn:
	F.add_client(srv, id)
	var p := F.add_pawn(srv, id)
	p.health = hp; p.bleeding = true; p.bandage_count = 3
	return p

func _channel(srv, healer_id: int, target_id: int, ticks: int) -> void:
	srv._support.bandaging[healer_id] = target_id
	for t in ticks:
		srv._sim.tick = t
		srv._support.step_bandage()

func test_self_bandage_completes_heals_and_stops_bleed() -> void:
	var srv = autofree(F.make_server())
	var p := _bleeding_pawn(srv, 1, 40)
	_channel(srv, 1, 1, Bandage.channel_ticks(false))
	assert_false(p.bleeding, "bleed cured on completion")
	assert_eq(p.health, 40 + Bandage.BANDAGE_HEAL, "bandage restores HP")
	assert_eq(p.bandage_count, 2, "victim's own kit spent")

func test_medic_channel_is_half_length() -> void:
	var srv = autofree(F.make_server())
	var c := F.add_client(srv, 1); c["class"] = Loadout.MEDIC
	var p := F.add_pawn(srv, 1); p.health = 40; p.bleeding = true; p.bandage_count = 3
	_channel(srv, 1, 1, Bandage.channel_ticks(true))
	assert_false(p.bleeding, "medic completes in half the ticks")

func test_teammate_bandage_spends_victim_then_helper() -> void:
	var srv = autofree(F.make_server())
	var patient := _bleeding_pawn(srv, 1, 40); patient.bandage_count = 0
	var medic_c := F.add_client(srv, 2); medic_c["class"] = Loadout.MEDIC
	var medic := F.add_pawn(srv, 2); medic.bandage_count = 20
	patient.pos = Vector3.ZERO; medic.pos = Vector3(1, 0, 0)   # in range
	_channel(srv, 2, 1, Bandage.channel_ticks(true))
	assert_false(patient.bleeding, "medic bandaged the patient")
	assert_eq(patient.bandage_count, 0, "patient had none")
	assert_eq(medic.bandage_count, 19, "helper's kit paid")

func test_out_of_range_teammate_resets_progress() -> void:
	var srv = autofree(F.make_server())
	var patient := _bleeding_pawn(srv, 1, 40)
	var medic := F.add_pawn(srv, 2); F.add_client(srv, 2); medic.bandage_count = 3
	patient.pos = Vector3.ZERO; medic.pos = Vector3(50, 0, 0)   # far
	_channel(srv, 2, 1, Bandage.channel_ticks(false))
	assert_true(patient.bleeding, "no progress out of range")
	assert_false(srv._support.bandaging.has(2), "latch dropped")

func test_damage_mid_channel_hard_cancels() -> void:
	var srv = autofree(F.make_server())
	var p := _bleeding_pawn(srv, 1, 40)
	srv._support.bandaging[1] = 1
	srv._sim.tick = 0; srv._support.step_bandage()   # 1 tick of progress
	assert_eq(int(srv._support.bandage_ticks.get(1, 0)), 1)
	srv._support.drop_bandage_for(1)                 # simulate a hit interrupting
	assert_false(srv._support.bandaging.has(1), "latch cancelled by damage")
	assert_eq(int(srv._support.bandage_ticks.get(1, 0)), 0, "progress reset to zero")

func test_no_bandage_available_cannot_complete() -> void:
	var srv = autofree(F.make_server())
	var p := _bleeding_pawn(srv, 1, 40); p.bandage_count = 0
	_channel(srv, 1, 1, Bandage.channel_ticks(false) + 2)
	assert_true(p.bleeding, "no charge -> bleed persists")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=server_bandage_test`
Expected: FAIL — `bandaging` / `step_bandage` / `drop_bandage_for` undefined.

- [ ] **Step 3: Write minimal implementation**

In `server/support.gd`, add latch fields near the other latches (after `repair_cd`):

```gdscript
var bandaging := {}            # healer_id -> target_id, latched by BANDAGE_ACTION(active)
var bandage_ticks := {}        # target_id -> accumulated channel ticks (one healer advances a target)
```

Add the handler (next to `handle_revive_action`):

```gdscript
func handle_bandage_action(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = srv._peer_to_id.get(peer, 0)
	if id == 0 or not srv._clients.has(id): return
	var d := Protocol.decode_bandage_action(bytes)
	if bool(d["active"]):
		bandaging[id] = int(d["target"])
	else:
		bandaging.erase(id)
		bandage_ticks.erase(int(d["target"]))
```

Add the hard-cancel helper (called from `_apply_pawn_damage` when a pawn takes damage — drops any channel where `id` is the healer or the target):

```gdscript
## Hard-cancel any standing-bandage channel involving `id` (as healer or as target) and reset its
## progress. Called when `id` takes damage — the channel is all-or-nothing (BattleBit-style).
func drop_bandage_for(id: int) -> void:
	if bandaging.has(id):
		bandage_ticks.erase(int(bandaging[id]))
		bandaging.erase(id)
	bandage_ticks.erase(id)
	for healer in bandaging.keys():
		if int(bandaging[healer]) == id:
			bandaging.erase(healer)
```

Add the step (mirrors `step_revives` but all-or-nothing — any invalid drops the latch + resets):

```gdscript
## M16 standing bandage: a latched healer channels a bleeding target (self or an in-range teammate).
## All-or-nothing: out-of-range / sprint / fire / damage / invalid target hard-cancels and resets.
## On completion the bleed is cured, HP restored, and one bandage spent (victim-first -> helper).
func step_bandage() -> void:
	var done: Array = []
	for hid in bandaging:
		var tid: int = bandaging[hid]
		var h: Pawn = srv._sim.world.get_pawn(hid)
		var t: Pawn = srv._sim.world.get_pawn(tid)
		# Validity — any failure hard-cancels (no held progress).
		if h == null or not h.alive or h.is_downed: done.append(hid); continue
		if t == null or not t.alive or t.is_downed or not t.bleeding: done.append(hid); continue
		if h.team != t.team: done.append(hid); continue
		if hid != tid and h.pos.distance_to(t.pos) > Bandage.BANDAGE_RANGE: done.append(hid); continue
		if h.sprinting or h.stance == Stance.PRONE and false: pass   # (placeholder; see sprint/fire below)
		if h.sprinting: done.append(hid); continue
		if hid != tid:
			srv._support_link(hid, tid, SupportLinks.BANDAGE)   # teammate beam (self-links are dropped)
		bandage_ticks[tid] = int(bandage_ticks.get(tid, 0)) + 1
		if bandage_ticks[tid] >= Bandage.channel_ticks(is_medic(hid)):
			_complete_bandage(hid, tid, t)
			done.append(hid)
	for hid in done:
		var tid2 = bandaging.get(hid, 0)
		bandaging.erase(hid)
		bandage_ticks.erase(int(tid2))

func _complete_bandage(healer_id: int, target_id: int, t: Pawn) -> void:
	var helper: Pawn = srv._sim.world.get_pawn(healer_id)
	var helper_bandages := t.bandage_count if healer_id == target_id else (helper.bandage_count if helper != null else 0)
	var src := Bandage.pick_source(t.bandage_count, helper_bandages)
	if src == -1:
		return   # both pouches empty — cannot cure; latch drops, bleed persists
	if src == 0 or healer_id == target_id:
		t.bandage_count -= 1
	elif helper != null:
		helper.bandage_count -= 1
	t.bleeding = false
	t.health = mini(100, t.health + Bandage.BANDAGE_HEAL)
	srv._stats.bandages += 1
```

> **Fire interrupt:** firing is a per-tick event, not a Pawn flag; the server already routes the interrupt through damage on the *target* and through `drop_bandage_for` on the healer when the healer's own fire path runs. Wire the healer-fired cancel where the server processes a fire INPUT for `id`: call `_support.drop_bandage_for(id)` there (search the fire-handling in `server_main.gd`). Add that one line in Step 3b below.

> **Sprint flag:** the test uses `h.sprinting`. Confirm Pawn exposes `sprinting` (it is set in `Pawn.step`). If it is a local var rather than a field, add `var sprinting: bool = false` to Pawn and set it in `step()` where sprint is resolved. Grep `sprinting` in `shared/sim/pawn.gd` first; if already a field, skip. Remove the dead `stance == Stance.PRONE and false` placeholder line — it was only a reminder; keep just the `if h.sprinting: done.append(hid); continue`.

- [ ] **Step 3b: Server wiring**

In `server/server_main.gd`:

1. Route the message — in `_on_packet`, next to the `REVIVE_ACTION` case:

```gdscript
		Protocol.Msg.BANDAGE_ACTION: _support.handle_bandage_action(peer, bytes)
```

2. Call the step in the tick loop, right after `_support.step_bleed()`:

```gdscript
	_support.step_bandage()
```

Order: place `step_bandage()` **before** `step_bleed()` is not required, but keeping `step_bleed()` then `step_bandage()` means a cure this tick still shows one final drain — acceptable. (If you prefer cure-before-drain, swap so `step_bandage()` precedes `step_bleed()`.)

3. Add a `_support_link` convenience if one does not already exist (many call sites append to `links_this_tick` directly — match the local idiom; if there is no helper, append inline instead):

```gdscript
func _support_link(giver: int, target: int, kind: int) -> void:
	_support.links_this_tick.append({"giver": giver, "target": target, "kind": kind})
```

> If `server_main.gd` has no such helper and `links_this_tick` is only appended from within `support.gd`, replace the `srv._support_link(...)` call in `step_bandage` with a direct `links_this_tick.append({"giver": hid, "target": tid, "kind": SupportLinks.BANDAGE})` (that array is a field on `ServerSupport`).

4. Damage interrupt — in `_apply_pawn_damage`, at the very top (after the `if victim.is_downed: return`), cancel any channel the victim is in:

```gdscript
	_support.drop_bandage_for(vid)
```

And where a healer fires (fire-input handling for `id`), add `_support.drop_bandage_for(id)`.

In `shared/sim/support_links.gd`, add the kind:

```gdscript
const BANDAGE := 4  # a pawn bandaging a bleeding teammate -> red-cross beam
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=server_bandage_test`
Expected: PASS (6 tests). Run `--filter=server_bleed_test` and `--filter=server_dbno_test` to confirm no regression.

- [ ] **Step 5: Commit**

```bash
git add server/support.gd server/server_main.gd shared/sim/support_links.gd tests/server_bandage_test.gd
git commit -m "feat(server): all-or-nothing standing-bandage channel (self/teammate, medic 2x, victim-first pouch)"
```

---

## Task 9: Revive now costs a bandage (victim-first → reviver; fails when both empty)

**Files:**
- Modify: `server/support.gd` (`step_revives` gate + `complete_revive` consumption)
- Test: `tests/server_bandage_test.gd` (append)

> **Coordination:** `step_revives`/`complete_revive` are NOT touched by the halving-bleedout branch (they only changed `step_downed`). Low conflict risk.

- [ ] **Step 1: Write the failing test**

Append to `tests/server_bandage_test.gd`:

```gdscript
func test_revive_spends_a_bandage_victim_first() -> void:
	var srv = autofree(F.make_server())
	var downed := _bleeding_pawn(srv, 1, 0); downed.is_downed = true; downed.bleeding = false
	downed.bandage_count = 2
	var reviver := F.add_pawn(srv, 2); F.add_client(srv, 2); reviver.bandage_count = 3
	downed.pos = Vector3.ZERO; reviver.pos = Vector3(1, 0, 0)
	srv._support.reviving[2] = 1
	for t in Revive.revive_ticks(false):
		srv._sim.tick = t
		srv._support.step_revives()
	assert_false(downed.is_downed, "revive completed")
	assert_eq(downed.bandage_count, 1, "the downed pawn's own kit paid")
	assert_eq(reviver.bandage_count, 3, "reviver's kit untouched while victim had one")

func test_revive_impossible_when_both_empty() -> void:
	var srv = autofree(F.make_server())
	var downed := _bleeding_pawn(srv, 1, 0); downed.is_downed = true; downed.bleeding = false
	downed.bandage_count = 0
	var reviver := F.add_pawn(srv, 2); F.add_client(srv, 2); reviver.bandage_count = 0
	downed.pos = Vector3.ZERO; reviver.pos = Vector3(1, 0, 0)
	srv._support.reviving[2] = 1
	for t in Revive.revive_ticks(false) + 2:
		srv._sim.tick = t
		srv._support.step_revives()
	assert_true(downed.is_downed, "no bandage anywhere -> cannot revive; pawn keeps bleeding out")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=server_bandage_test`
Expected: FAIL — revive still completes for free / bandage counts unchanged.

- [ ] **Step 3: Write minimal implementation**

In `server/support.gd` `step_revives`, gate the advance on bandage availability. Where a valid in-range reviver is confirmed (`active_targets[target_id] = reviver_id`), guard it:

```gdscript
		if rp.pos.distance_to(tp.pos) > Revive.REVIVE_RANGE: continue    # transient: hold latch
		# M16: a revive spends a bandage (victim-first -> reviver). No bandage anywhere -> cannot revive.
		if Bandage.pick_source(tp.bandage_count, rp.bandage_count) == -1:
			done.append(reviver_id); continue
		active_targets[target_id] = reviver_id
```

Change `complete_revive` to take the reviver and spend the pouch. Update the signature and the call site (`step_revives` calls `complete_revive(target_id)` → `complete_revive(target_id, reviver_id)`):

```gdscript
func complete_revive(target_id: int, reviver_id: int) -> void:
	var p: Pawn = srv._sim.world.get_pawn(target_id)
	if p == null: return
	# M16: spend a bandage — the downed pawn's own kit first, then the reviver's.
	var r: Pawn = srv._sim.world.get_pawn(reviver_id)
	var src := Bandage.pick_source(p.bandage_count, r.bandage_count if r != null else 0)
	if src == 0:
		p.bandage_count -= 1
	elif src == 1 and r != null:
		r.bandage_count -= 1
	p.is_downed = false
	p.health = Revive.REVIVE_HP
	p.bleed_health = 0
	p.bleed_halted = false
	# ... (keep the rest of the existing body verbatim: dmg_ledger reset, downed_by erase, revives++)
```

In `step_revives`, update the completion call:

```gdscript
			if revive_ticks[target_id] >= Revive.revive_ticks(is_medic(reviver_id)):
				complete_revive(target_id, reviver_id)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=server_bandage_test`
Expected: PASS. Run `--filter=server_dbno_test` and `--filter=revive` for regressions.

- [ ] **Step 5: Commit**

```bash
git add server/support.gd tests/server_bandage_test.gd
git commit -m "feat(server): revive spends a bandage (victim-first->reviver, fails when both empty)"
```

---

## Task 10: Wire — extend `SELF_STATE` with `bleeding` + `bandage_progress`

**Files:**
- Modify: `shared/net/protocol.gd` (`encode_self_state` / `decode_self_state`)
- Modify: `server/server_main.gd` (SELF_STATE send site ~line 823 passes the new args)
- Test: `tests/protocol_bandage_test.gd` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/protocol_bandage_test.gd`:

```gdscript
func test_self_state_carries_bleeding_and_progress() -> void:
	var pkt := Protocol.encode_self_state(30, false, 0, Weapon.AR, [], false, 0.0, 0, 5, false, 0.0, 0.0, true, 128)
	var d := Protocol.decode_self_state(pkt)
	assert_true(bool(d["bleeding"]), "bleeding bit round-trips")
	assert_eq(int(d["bandage_progress"]), 128, "channel progress round-trips")

func test_self_state_defaults_when_absent() -> void:
	# An older-style packet (no trailing bleed fields) decodes to safe defaults.
	var pkt := Protocol.encode_self_state(30, false, 0, Weapon.AR)
	var d := Protocol.decode_self_state(pkt)
	assert_false(bool(d["bleeding"]))
	assert_eq(int(d["bandage_progress"]), 0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=protocol_bandage_test`
Expected: FAIL — `encode_self_state` has no such params; `d["bleeding"]` missing.

- [ ] **Step 3: Write minimal implementation**

In `shared/net/protocol.gd` `encode_self_state`, add two params at the end of the signature:

```gdscript
static func encode_self_state(mag: int, reloading: bool, reload_remaining: int, weapon: int, throwables: Array = [], being_revived: bool = false, suppression: float = 0.0, blind_ticks: int = 0, bandage_count: int = 0, bleed_halted: bool = false, repair_heat: float = 0.0, repair_cooldown: float = 0.0, bleeding: bool = false, bandage_progress: int = 0) -> PackedByteArray:
```

Append after the `repair_cooldown` byte (still last, so older decoders ignore them):

```gdscript
	# M16 standing-bleed: owner-only bleeding flag + current bandage channel progress (0..255).
	buf.put_u8(1 if bleeding else 0)
	buf.put_u8(clampi(bandage_progress, 0, 255))
```

In `decode_self_state`, add defaults and trailing reads before the return, and add them to the returned dict:

```gdscript
	var bleeding := false
	var bandage_progress := 0
	# ... after the repair_cooldown read block:
	if r.get_available_bytes() > 0:
		bleeding = r.get_u8() == 1
	if r.get_available_bytes() > 0:
		bandage_progress = r.get_u8()
	return {..., "bleeding": bleeding, "bandage_progress": bandage_progress}
```

(Add the two keys to the existing returned dictionary literal.)

In `server/server_main.gd`, the SELF_STATE send (~line 823) — compute the owner's bandage progress and pass the new args. Before the send, add:

```gdscript
	var bprog := 0
	if _support.bandage_ticks.has(id):
		bprog = clampi(int(round(float(_support.bandage_ticks[id]) / float(Bandage.channel_ticks(_support.is_medic(id))) * 255.0)), 0, 255)
```

Then append `, self_pawn.bleeding, bprog` to the `encode_self_state(...)` argument list.

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=protocol_bandage_test`
Expected: PASS (4 tests). Run `--filter=self_state` and `--filter=protocol` for round-trip regressions.

- [ ] **Step 5: Commit**

```bash
git add shared/net/protocol.gd server/server_main.gd tests/protocol_bandage_test.gd
git commit -m "feat(wire): SELF_STATE carries owner bleeding flag + bandage progress"
```

---

## Task 11: Wire — `BLEEDING_LIST` (46) + broadcast

**Files:**
- Modify: `shared/net/protocol.gd` (`encode_bleeding_list` / `decode_bleeding_list`)
- Modify: `server/server_main.gd` (`_broadcast_bleeding_list` + tick call + a `ReliableList`)
- Test: `tests/protocol_bandage_test.gd` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/protocol_bandage_test.gd`:

```gdscript
func test_bleeding_list_roundtrip() -> void:
	var pkt := Protocol.encode_bleeding_list([11, 22, 33])
	assert_eq(pkt[0], Protocol.Msg.BLEEDING_LIST)
	var ids := Protocol.decode_bleeding_list(pkt)
	assert_eq(ids.size(), 3)
	assert_eq(int(ids[0]), 11)
	assert_eq(int(ids[2]), 33)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=protocol_bandage_test`
Expected: FAIL — `encode_bleeding_list` undefined.

- [ ] **Step 3: Write minimal implementation**

In `shared/net/protocol.gd` (near `encode_downed_list`):

```gdscript
## Standing-bleeding allied pawn ids (M16). Ally-only; used to draw the bleed marker + bandage prompt.
static func encode_bleeding_list(ids: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.BLEEDING_LIST)
	var n: int = mini(ids.size(), 255)
	buf.put_u8(n)
	for i in range(n):
		buf.put_u32(int(ids[i]))
	return buf.data_array

static func decode_bleeding_list(bytes: PackedByteArray) -> Array:
	var r := body_reader(bytes)
	var n := r.get_u8()
	var out: Array = []
	for _i in n:
		out.append(r.get_u32())
	return out
```

In `server/server_main.gd`, add a `ReliableList` field next to `_downed_rl`:

```gdscript
var _bleeding_rl := ReliableList.new()  # BLEEDING_LIST
```

Add the broadcast (model it on `_broadcast_downed_list`; ally-filtered per recipient — follow whatever per-team fan-out `_broadcast_downed_list` uses, or, if `DOWNED_LIST` is sent to all human clients and the client filters by team, do the same):

```gdscript
func _broadcast_bleeding_list() -> void:
	var ids: Array = []
	for id in _sim.world.pawns:
		var p: Pawn = _sim.world.pawns[id]
		if p.alive and not p.is_downed and p.bleeding:
			ids.append(id)
	var pkt := Protocol.encode_bleeding_list(ids)
	if not _bleeding_rl.should_send(pkt, ids.size() > 0, _sim.tick):
		return
	for cid in _human_ids:
		_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_CONTROL, pkt, ENetPacketPeer.FLAG_RELIABLE)
```

> Match `_broadcast_downed_list`'s exact recipient loop and `should_send` signature — copy its structure verbatim and swap the list builder. Do not invent a new fan-out.

In the tick loop, after `_broadcast_downed_list()`:

```gdscript
	_broadcast_bleeding_list()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=protocol_bandage_test`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add shared/net/protocol.gd server/server_main.gd tests/protocol_bandage_test.gd
git commit -m "feat(wire): BLEEDING_LIST (46) broadcast of standing-bleeding allies"
```

---

## Task 12: Bots — standing-bandage AI

**Files:**
- Modify: `bots/ai/behaviors/support.gd` (decision helpers)
- Modify: `bots/bot_driver.gd` (send BANDAGE_ACTION)
- Test: `tests/ai_support_bandage_test.gd`

> **Coordination:** the halving-bleedout branch REMOVES the downed self-bandage bot branch (`should_self_bandage` + the downed send). This task ADDS a *standing*-bandage branch — a different code path. If both are present at merge, keep this one and drop theirs per their design.

- [ ] **Step 1: Write the failing test**

Create `tests/ai_support_bandage_test.gd`:

```gdscript
extends TestCase
## Standing-bandage bot decisions (pure, in AiSupport).

func test_self_bandage_when_bleeding_and_safe() -> void:
	assert_true(AiSupport.should_self_bandage_standing(true, false), "bleeding + no enemy near -> bandage")

func test_no_self_bandage_when_enemy_near() -> void:
	assert_false(AiSupport.should_self_bandage_standing(true, true), "don't bandage under fire")

func test_no_self_bandage_when_not_bleeding() -> void:
	assert_false(AiSupport.should_self_bandage_standing(false, false))

func test_pick_bleeding_mate_in_range() -> void:
	var mates := [{"id": 7, "dist": 2.0}, {"id": 9, "dist": 40.0}]
	assert_eq(int(AiSupport.pick_bandage_target(mates).get("id", 0)), 7, "nearest in-range mate")

func test_no_bleeding_mate_out_of_range() -> void:
	assert_true(AiSupport.pick_bandage_target([{"id": 9, "dist": 40.0}]).is_empty())
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=ai_support_bandage_test`
Expected: FAIL — helpers undefined.

- [ ] **Step 3: Write minimal implementation**

In `bots/ai/behaviors/support.gd`, add:

```gdscript
const BANDAGE_MATE_RANGE := 3.0   # matches Bandage.BANDAGE_RANGE

## A bot self-bandages a standing bleed only when it is bleeding and no enemy is near (safe to channel).
static func should_self_bandage_standing(bleeding: bool, enemy_near: bool) -> bool:
	return bleeding and not enemy_near

## bleeding_mates: [{id, dist}] (allied bleeding pawns from the BLEEDING_LIST mirror). Nearest in range.
static func pick_bandage_target(bleeding_mates: Array) -> Dictionary:
	var best: Dictionary = {}
	for m in bleeding_mates:
		if float(m["dist"]) <= BANDAGE_MATE_RANGE and (best.is_empty() or float(m["dist"]) < float(best["dist"])):
			best = m
	return best
```

In `bots/bot_driver.gd`, in the alive (non-downed) support decision area, latch a BANDAGE_ACTION like the revive latch. Add a `bot["bandaging_id"]` state (init to 0 alongside `reviving_id` at ~line 110, reset at respawn ~line 160). Where the bot is alive and holds still to help:

```gdscript
	# M16 standing-bandage: prefer a bleeding mate in range, else self if bleeding & safe.
	var want_bid := 0
	var self_state := bot.get("self_state", {})
	var enemy_near: bool = _ex.enemy_near(bot, me)   # reuse existing threat check; else compute from view
	var mate := AiSupport.pick_bandage_target(bot.get("bleeding_mates", []))
	if not mate.is_empty():
		want_bid = int(mate["id"])
	elif AiSupport.should_self_bandage_standing(bool(self_state.get("bleeding", false)), enemy_near):
		want_bid = int(bot["id"])
	var cur_bid: int = int(bot.get("bandaging_id", 0))
	if want_bid != cur_bid:
		if cur_bid != 0:
			(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT, Protocol.encode_bandage_action(cur_bid, false), 0)
		if want_bid != 0:
			(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT, Protocol.encode_bandage_action(want_bid, true), 0)
		bot["bandaging_id"] = want_bid
```

> Populate `bot["bleeding_mates"]` from the `BLEEDING_LIST` the bot receives (mirror how `downed_allies`/`gadgets` are captured in `bot_driver`'s packet handling — find where `DOWNED_LIST` is decoded into `bot` and add a `BLEEDING_LIST` case producing `[{id, dist}]` against known ally positions). If `_ex.enemy_near` does not exist, use the bot's existing nearest-enemy computation (grep `enemy` in `bot_driver.gd`) and treat "within ~25 m and visible" as `enemy_near`.

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=ai_support_bandage_test`
Expected: PASS (5 tests). Run `--filter=ai_` for AI regressions.

- [ ] **Step 5: Commit**

```bash
git add bots/ai/behaviors/support.gd bots/bot_driver.gd tests/ai_support_bandage_test.gd
git commit -m "feat(bots): standing-bandage AI (self when safe, bleeding mate in range)"
```

---

## Task 13: Client — F-bandage input, prompt, and HUD feedback

**Files:**
- Modify: `client/hud/hud_view.gd` (`_build_interaction_prompt` — add "bandage" action; cast-bar; bleeding vignette; marker)
- Modify: `client/client_main.gd` (F handling for bandage self/teammate; consume `bleeding`/`bandage_progress` from SELF_STATE; consume BLEEDING_LIST)
- Modify: renderer/worldview as needed for the bleeding marker + remote blood VFX (follow the DOWNED_LIST revive-marker path)

> **Visual task — validated by screenshot, not unit tests** (project deterministic-testing discipline: mechanics are proven in Tasks 1–12; this is presentation). Keep pure/logic bits (prompt selection, progress math) small and obvious.

- [ ] **Step 1: Decode the new wire fields (client_main.gd)**

Where SELF_STATE is decoded into the client model, read `bleeding` and `bandage_progress` (already in the decoded dict from Task 10) and store them (e.g. `_bleeding`, `_bandage_progress`). Where `DOWNED_LIST` is handled, add a `BLEEDING_LIST` case: `Protocol.decode_bleeding_list(bytes)` → store the ally id set (e.g. `_bleeding_ids`) for the renderer/prompt.

- [ ] **Step 2: Interaction prompt (hud_view.gd `_build_interaction_prompt`)**

Add "bandage" as a context action. In the resolver priority (after vehicle/downed-revive checks, before falling through), if the aimed-at target is an allied pawn whose id is in `_bleeding_ids` and within `Bandage.BANDAGE_RANGE`, set the prompt `{action="bandage", target=<id>}` with label "Bandage". If no world prompt applies and the local player `_bleeding` is true, set `{action="bandage", target=<self_id>}` label "Bandage self".

- [ ] **Step 3: F handling (client_main.gd)**

In the interaction block (near the existing `"revive"` branch, lines ~690), add a `"bandage"` branch that mirrors revive's hold-to-send but uses `encode_bandage_action`:

```gdscript
			if ip != null and String(ip.get("action", "")) == "bandage" and interact_held and _peer != null:
				_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
					Protocol.encode_bandage_action(int(ip["target"]), true), ENetPacketPeer.FLAG_RELIABLE)
			elif ip != null and String(ip.get("action", "")) == "bandage" and _peer != null and not interact_held:
				_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
					Protocol.encode_bandage_action(int(ip["target"]), false), ENetPacketPeer.FLAG_RELIABLE)
```

(Since the server channel is all-or-nothing, releasing F sends the stop; re-holding restarts from zero server-side.)

- [ ] **Step 4: HUD feedback (hud_view.gd)**

- **Cast-bar:** when `_bandage_progress > 0`, draw a radial/linear progress bar from `_bandage_progress / 255.0` (reuse `set_revive_progress`'s widget style).
- **Bleeding vignette:** when `_bleeding`, drive a red pulsing screen tint. Reuse the suppression screen-shader canvas pattern (see the M7 suppression FX). Intensity can pulse on a fixed sine; no wire needed beyond the bit.
- **Bleeding teammate marker:** for each id in `_bleeding_ids`, draw a distinct world-space marker (copy the revive-marker path used for `DOWNED_LIST`; use a different colour/icon — e.g. a red cross — so it reads apart from the downed revive marker).
- **Remote blood VFX (optional, low priority):** small drip particles on bleeding remote pawns; defer if time-boxed.

- [ ] **Step 5: Self-validate with a screenshot**

Follow the game2 Xvfb recipe (memory `blockfire-game2-screenshot-xvfb`): launch a local server + a few bots, join the render client, and confirm: (a) taking a below-threshold hit shows the red vignette; (b) holding F self-bandages with a visible cast-bar; (c) a bleeding bot mate shows the red marker + "Bandage" prompt. Save shots to `~/bf-shots`.

- [ ] **Step 6: Commit**

```bash
git add client/
git commit -m "feat(client): F-bandage input + prompt, bleeding vignette, cast-bar, bleed marker"
```

---

## Task 14: Fleet gate — 128-bot assertions

**Files:**
- Create: `docker/run-bleed-gate.sh` (model on `docker/run-m7.5-gate.sh`)

- [ ] **Step 1: Write the gate script**

Create `docker/run-bleed-gate.sh` modeled on `docker/run-m7.5-gate.sh`: run the standard 128-bot match on a combat-dense map (e.g. `conquest_town`), then read the new counters with the existing `maxof` helper and assert:

```bash
bleeds="$(maxof bleeds)"; bandages="$(maxof bandages)"; bleeddowns="$(maxof bleeddowns)"
echo "[bleed] bleeds=${bleeds:-0} bandages=${bandages:-0} bleeddowns=${bleeddowns:-0}"
[ "${bleeds:-0}" -ge 1 ]     || { echo "FAIL: no standing bleeds started (AI density/threshold?)"; ok=0; }
[ "${bandages:-0}" -ge 1 ]   || { echo "FAIL: no bandages applied (bot bandage AI inert?)"; ok=0; }
[ "${bleeddowns:-0}" -ge 1 ] || { echo "FAIL: no untreated bleed-outs (bleed too slow / all bandaged?)"; ok=0; }
```

Keep the existing tick-budget and match-completion assertions from the base gate (the standing bleed must not blow the ~17 ms cap).

- [ ] **Step 2: Run the gate**

Run: `bash docker/run-bleed-gate.sh` (on game2 directly — do not ssh; see memory). Watch tick_mean/p99 stay within budget and the three counters fire.
Expected: PASS with `bleeds ≥ 1`, `bandages ≥ 1`, `bleeddowns ≥ 1`, a match winner, tick within cap.

> If `bandages = 0`, the bot bandage AI (Task 12) or the `bleeding_mates`/`enemy_near` plumbing is inert — debug there, not by loosening the bleed numbers. If tick budget regresses, profile `step_bleed`/`step_bandage` (both are O(clients); the drain early-outs off `drain_this_tick`).

- [ ] **Step 3: Commit**

```bash
git add docker/run-bleed-gate.sh
git commit -m "test(gate): 128-bot standing-bleed/bandage assertions"
```

---

## Task 15: Docs — wire registry + milestone note + full suite

**Files:**
- Modify: `docs/specs/wire-protocol-registry.md` (register 45/46 + SELF_STATE growth)
- Modify: the standing-bleed spec status → implemented

- [ ] **Step 1: Update the wire registry**

Add `BANDAGE_ACTION = 45` (client→server) and `BLEEDING_LIST = 46` (server→clients) to `docs/specs/wire-protocol-registry.md`, and note the two appended `SELF_STATE` trailing bytes (`bleeding` u8, `bandage_progress` u8). Set the "next free msg id" to 47.

- [ ] **Step 2: Run the FULL suite**

Run: `godot --headless --path . -- --test`
Expected: all tests PASS, **0 script errors** (the runner treats a parse error / runtime SCRIPT ERROR as a failure). Confirm the total grew by the new test files and nothing regressed.

- [ ] **Step 3: Mark the spec implemented + commit**

Change the spec header `Status:` to `implemented 2026-07-03`. Commit:

```bash
git add docs/specs/wire-protocol-registry.md docs/superpowers/specs/2026-07-03-standing-bleed-bandage-design.md
git commit -m "docs: register bleed wire ids (45/46), mark standing-bleed spec implemented"
```

- [ ] **Step 4: Finish the branch**

Use `superpowers:finishing-a-development-branch` to decide integration (merge/PR). **Before merging to master, `git fetch` and reconcile with the halving-bleedout branch** per the spec's §Coordination table (expect conflicts in `pawn.gd`, `revive.gd`, `support.gd`, `server_main.gd`, bots, client — all additive; resolve by keeping both concerns).

---

## Self-Review

**Spec coverage:**
- Trigger (below-threshold bullet/blast, no fall) → Task 1 (`Bleed.should_start`) + Task 5 (server trigger). ✔
- Drain → DBNO feeding halving window → Task 6 (`step_bleed` + `_bleed_out_standing`). ✔
- Timed channel, medic ½, heals `BANDAGE_HEAL` → Task 2 + Task 8. ✔
- All-or-nothing hard-cancel (range/sprint/fire/damage) → Task 8 (`step_bandage` validity + `drop_bandage_for` + fire hook). ✔
- Victim-first→helper economy → Task 2 (`pick_source`) + Task 8 (self/teammate) + Task 9 (revive). ✔
- Revive costs a bandage, fails when both empty → Task 9. ✔
- Counts 3 / 20 → Task 3. ✔
- One-button F (self + teammate + priority) → Task 13. ✔
- Replication: SELF_STATE bits → Task 10; BLEEDING_LIST → Task 11; teammate beam (`SupportLinks.BANDAGE`) → Task 8. ✔
- Bots → Task 12. Stats → Task 6. Gate → Task 14. Wire registry → Task 15. ✔

**Placeholder scan:** Task 8 flags two verify-first spots (Pawn `sprinting` field; `_support_link` idiom) with concrete fallbacks — resolved by grep, not left vague. Task 12/13 reference existing plumbing (`enemy_near`, DOWNED_LIST decode path) with exact "grep X, mirror it" instructions. No bare TODOs remain in shipped code except the explicit merge-ordering TODO in Task 6's pre-merge fallback.

**Type consistency:** `Bleed.should_start(post_hit_hp, source)`, `Bleed.drain_this_tick(tick)`, `Bandage.channel_ticks(is_medic)`, `Bandage.pick_source(v,h)→0/1/-1`, `Revive.bandage_count_for(is_medic)`, Pawn `bleeding/bleed_by/bleed_weapon`, `ServerSupport.bandaging/bandage_ticks/step_bleed/step_bandage/handle_bandage_action/drop_bandage_for/complete_revive(target,reviver)`, `_bleed_out_standing(vid,victim)`, `_broadcast_bleeding_list`, `Msg.BANDAGE_ACTION=45`/`BLEEDING_LIST=46`, `SupportLinks.BANDAGE=4`, stats `bleeds_started/bandages/bleed_downs` — used identically across tasks. ✔
