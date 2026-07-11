# M19 P1b-2 — SET_LOADOUT wire + server apply-at-spawn + RPG-as-gadget + bots (sim+wire framework)

> **For agentic workers:** REQUIRED SUB-SKILL: execute via superpowers:subagent-driven-development, task-by-task, TDD. Checkbox steps track progress.

**Goal:** Turn the player-chosen loadout (now variant-aware after P1b-1) into live, server-authoritative behavior: a client (or headless debug arg / bot) sends `SET_LOADOUT`; the server sanitizes + persists it per connection and applies weapon/ammo/reserve/armor/gadget/grenade **at spawn**; RPG stops being a primary and becomes the Engineer's gadget; bots run the same unified path; a 128-bot fleet gate proves no tick/bandwidth regression.

**Architecture:** `LoadoutConfig` and `Loadout.sanitize` (the validation authority) already exist. This phase adds the wire message, a per-connection `_clients[id]["loadout"]` store, and rewrites the server spawn/gadget paths to read that store instead of the legacy per-class derivations (`weapon_for`/`armor_for`/`gadget_for_player` id-parity). RPG becomes gadget-only. Bots get `Loadout.bot_loadout(id)`. **No client screen** (that's P3) — a `--loadout=` debug arg + `bot_loadout` drive it headless. **Traits (Combat Vigor/blast/stim/reserve/grenade-count) are P2, NOT here** — this phase only makes the *selection* live; the grenade *type* is player-picked but grenade *count* stays as-is until P2.

**Tech stack:** Godot 4 / GDScript; `shared/net/protocol.gd` wire; `server/server_main.gd` authoritative sim; `bots/`; `TestCase`. Wire `VERSION 7 → 8`.

**Scope boundary (spec §L P1 only):** IN — wire+persistence+spawn-apply+RPG-gadget+bots+gate. OUT (P2) — Combat Vigor regen scaling, +20% blast, Combat Stim, Support reserve bonus + 5-grenades, LMG suppression wiring, and the SELF_STATE stim byte. OUT (P3) — the client class-select screen.

---

## Shared context (every implementer reads this)

**Server integration map (verified against current `server/server_main.gd`):**
- `_clients := {}` declared `server_main.gd:174`, keyed by integer client id; cleared `:367`; `_peer_to_id` populated `:1180`, erased `:2418`/`:2430`.
- Client record literal built in `_handle_hello` at `server_main.gd:1181-1194` (fields: `team, squad, class, weapon, weapon_def, rockets, ammo, reserve, reloading, fire_mode, name`, …). **Add `"loadout"` here.**
- `_build_weapon_slots` `:1320-1333` → `c["slots"] = [primary, secondary]`.
- `_handle_hello` `:1133-1216`: class roll `:1159` (`random_class()` bots / `random_class_no_engineer()` humans); bot RPG/DMR poke `:1164-1168` (`id % 3 == 0 and auto_deploy`); `--human-rpg` special `:1171-1173`; `can_equip` guard `:1174`; spawn `:1198`; `p.armor_class = Loadout.armor_for(cls)` `:1203`; `p.bandage_count = Revive.bandage_count_for(cls == MEDIC)` `:1204`.
- Spawn/refill helpers: `_reset_weapon_loadout` `:1374-1388` (ammo=mag_size `:1379`, reserve=`Weapon.reserve_ammo` `:1380`); auto-respawn `_handle_respawns` `:813-844` (`_reset_weapon_loadout` `:841`, rockets `:843`); manual deploy `_handle_deploy_request` `:1251-1297` (`_reset_weapon_loadout` `:1293`, rockets `:1295`).
- Reload refill per tick `:543-552` uses `Weapon.reload_fill`.
- Gadget identity derived on demand via `Loadout.gadget_for_player(cls, id)` at `:1697, :1708` (C4/mine); **change to read `c["loadout"]["gadget"]`.**
- RPG fired as gadget: `_handle_gadget_action` `:1502-1503` routes `GA_RPG_FIRE` → `_fire_rocket` `:1578-1589`, which checks `int(c["weapon"]) != Weapon.RPG` `:1580` and decrements `c["rockets"]` `:1588`. Rocket sim `_step_rockets` `:1941-1984`. Rocket refill checks at `:545, :843, :1295`.
- Packet dispatch: `_on_packet` `:1112-1131`, `match Protocol.msg_type(bytes)`. Handler prologue pattern (peer→id + guard): `_handle_set_fire_mode` `:1311-1316`, `_handle_swap_weapon` `:1390-1393`.
- Boot: `Weapon.load_from_file(WEAPONS_PATH)` `server_main.gd:240`, `client_main.gd:257` — registry is loaded before connections.

**Wire codec references (mirror these):** `encode/decode_revive_action` `protocol.gd:444-454`; `encode/decode_bandage_action` `:458-468`; `encode_hello` `:96-102` + `decode_hello` `:162-183` (bounded name string via `_sanitize_name`, `MAX_NAME_LEN=24`); `body_reader(bytes)` skips the `msg_type` byte (`:134-135`). Client send sites: `client_main.gd` `encode_hello` `:1201-1203`, `encode_swap_weapon` `:1033`, all via `_net.send_to(peer, NetHost.CHANNEL_CONTROL, ..., ENetPacketPeer.FLAG_RELIABLE)`.

**Bot map:** bots HELLO with `auto_deploy=true` (`bot_driver.gd:234`); learn class from WELCOME (`bot_driver.gd:681-685`); gadget/behavior from `Loadout.gadget_for_player(cls,id)` (`exercisers.gd:520, 538`); RPG firing `exercisers.gd:410-444` (`maybe_rpg`) + `:483-515`, keyed off having the RPG weapon today — **rekey off the RPG gadget.**

**Invariants (must hold):**
- `Loadout.sanitize` is the ONLY validation authority; the server calls it on every `SET_LOADOUT` and trusts nothing else. Bots and the debug arg also pass through `sanitize` (via `bot_loadout` / handler).
- Registry is loaded at boot before any loadout is built (spawn reads variant stats).
- No per-tick SNAPSHOT byte added in this phase (bandwidth unchanged — the gate checks this).
- Determinism: server re-sanitize of a config equals the client's local sanitize of the same config (same code path).

---

### Task 1: `SET_LOADOUT` wire codec + VERSION 8

**Files:** Modify `shared/net/protocol.gd`; Create `tests/protocol_set_loadout_test.gd`.

Add `SET_LOADOUT = 48` to `enum Msg` (after `BLEEDING_LIST = 47`). Bump `const VERSION := 7` → `8` and prepend a history line:
`# 8: M19 SET_LOADOUT (48) client->server player loadout; store-and-apply-at-spawn (2026-07-11)`.
Update the "next free msg id" note to 49.

Encode a `LoadoutConfig`: six `u8` fields in fixed order `class, primary, secondary, gadget, armor, grenade`, then the three attachment ids as **bounded strings in fixed slot order `optic, barrel, underbarrel`**. For each attachment id mirror the HELLO name bounding: `put_u8(len)` (cap at a new `const MAX_ATTACH_LEN := 24`; a longer id is truncated/dropped to "") then the UTF-8 bytes. Decode reverses it; an overlong/garbage length yields `""` for that slot (sanitize then restores the default). `gadget`/`armor` are small ints (fit `u8`); `primary` is a variant id ≤ 32 today (`u8`, 255 headroom).

```gdscript
static func encode_set_loadout(cfg: Dictionary) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.SET_LOADOUT)
	buf.put_u8(int(cfg.get("class", 0)))
	buf.put_u8(int(cfg.get("primary", 0)))
	buf.put_u8(int(cfg.get("secondary", 0)))
	buf.put_u8(int(cfg.get("gadget", 0)))
	buf.put_u8(int(cfg.get("armor", 0)))
	buf.put_u8(int(cfg.get("grenade", 0)))
	var att: Dictionary = cfg.get("attachments", {})
	for slot in ["optic", "barrel", "underbarrel"]:
		_put_bounded_string(buf, String(att.get(slot, "")), MAX_ATTACH_LEN)
	return buf.data_array

static func decode_set_loadout(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)   # positioned past the msg_type byte
	var cfg := {
		"class": r.get_u8(), "primary": r.get_u8(), "secondary": r.get_u8(),
		"gadget": r.get_u8(), "armor": r.get_u8(), "grenade": r.get_u8(),
	}
	var att := {}
	for slot in ["optic", "barrel", "underbarrel"]:
		att[slot] = _get_bounded_string(r, MAX_ATTACH_LEN)
	cfg["attachments"] = att
	return cfg
```
If `protocol.gd` already has a bounded-string helper (the HELLO name path), REUSE it and drop the `_put/_get_bounded_string` names above; otherwise add small private helpers modeled exactly on the HELLO name encode/decode (length byte + UTF-8, cap `max`, return `""` if the reader underruns or the length exceeds `max`). Do NOT read past the buffer — guard with the reader's remaining bytes like the HELLO decoder does.

**Test** `tests/protocol_set_loadout_test.gd`:
- `test_version_is_8`: `assert_eq(Protocol.VERSION, 8)`.
- `test_set_loadout_round_trips`: build a full cfg (e.g. `{class:SUPPORT, primary:29, secondary:PISTOL, gadget:AMMO, armor:HEAVY, grenade:SMOKE, attachments:{optic:"reddot", barrel:"standard", underbarrel:"none_ub"}}`), `decode(encode(cfg))` equals it field-for-field (attachments included).
- `test_decode_truncated_is_safe`: `decode_set_loadout(PackedByteArray([Msg.SET_LOADOUT]))` (only the type byte) returns a dict with the six int fields (0-defaulted) and three `""` attachment slots — never a crash. (This is what `sanitize` will normalize.)
- `test_overlong_attachment_id_bounded`: encode a cfg whose optic id is 300 chars; decode yields an id no longer than `MAX_ATTACH_LEN` (or `""`), proving the bound.

- [ ] Step 1: Write `tests/protocol_set_loadout_test.gd`; `godot --headless --path . --import` (new test file). Run `--filter=protocol_set_loadout` → FAIL (encode/decode + VERSION not yet 8).
- [ ] Step 2: Implement in `protocol.gd`. Re-run filter → PASS.
- [ ] Step 3: Full suite `godot --headless --path . -- --test`. Any test asserting `VERSION == 7` must move to 8 (search `VERSION` in tests/). Report counts.
- [ ] Step 4: Commit `feat(netcode): SET_LOADOUT=48 client->server loadout msg (VERSION 7->8)`.

---

### Task 2: `Loadout.bot_loadout(id)` + promote RPG gadget to implemented

**Files:** Modify `shared/sim/loadout.gd`; Create `tests/loadout_bot_test.gd`.

Add `GADGET_RPG` to `IMPLEMENTED_GADGETS` (P1b promotes it per the file's own comment): `const IMPLEMENTED_GADGETS := [GADGET_C4, GADGET_HEAL, GADGET_AMMO, GADGET_RPG]`.

Add a deterministic per-id bot loadout that exercises the whole matrix and is always `sanitize`-stable. It must NOT use `randi()` (determinism); derive everything from `id`. Class cycles all four; armor cycles L/M/H; Engineers with `id % 2 == 0` take the RPG gadget (else C4); Support with `id % 2 == 0` take an LMG primary (else default AR variant); others take their default gadget/primary.

```gdscript
## Deterministic per-id bot loadout — exercises every class × armor tier × built gadget so the
## fleet gate covers the matrix without replication. Registry must be loaded (variant primaries).
## Always returns a sanitize-stable config (built through default_loadout + sanitize).
static func bot_loadout(id: int, attach: Attachment) -> Dictionary:
	var cls := id % 4
	var cfg := default_loadout(cls)
	cfg["armor"] = [Armor.LIGHT, Armor.MEDIUM, Armor.HEAVY][id % 3]
	if cls == ENGINEER:
		cfg["gadget"] = GADGET_RPG if (id % 2 == 0) else GADGET_C4
	if cls == SUPPORT and (id % 2 == 0):
		var lmgs := Weapon.variants_of(Weapon.LMG)
		if not lmgs.is_empty():
			cfg["primary"] = int(lmgs[id % lmgs.size()])
	return sanitize(cfg, attach)
```
(`attach` is the server's Attachment catalog, threaded in — same one `sanitize` needs. If server code has no catalog handy at the bot-seeding site, the map shows `_handle_hello` has access to the sanitize catalog used elsewhere; pass it. If truly unavailable there, add an `Attachment`-less overload that uses `default_attachments()` and document it — but prefer threading the real catalog.)

**Test** `tests/loadout_bot_test.gd` (load registry in `setup()`, reset in `teardown()`, build an `Attachment` fixture like `loadout_config_test.gd`):
- `test_bot_loadout_is_sanitize_stable`: for `id in range(0, 64)`, `sanitize(bot_loadout(id), attach) == bot_loadout(id)`.
- `test_bot_loadout_covers_matrix`: over `id in range(0, 64)` the set of classes == all 4, the set of armor tiers == all 3, at least one Engineer has `gadget == GADGET_RPG`, at least one Support has an LMG-archetype primary (`Weapon.archetype_of(primary) == Weapon.LMG`).
- `test_bot_loadout_every_gadget_implemented`: every returned `gadget` is in `IMPLEMENTED_GADGETS`.
- `test_rpg_gadget_now_implemented`: `assert_contains(IMPLEMENTED_GADGETS, GADGET_RPG)`.

- [ ] Step 1: write the test, `--import`, run filter → FAIL. Step 2: implement → PASS. Step 3: full suite (a `loadout_test.gd`/`default_gadget` test may now see RPG as implemented — reconcile only genuine identity assertions). Step 4: commit `feat(loadout): deterministic bot_loadout(id) + RPG gadget implemented`.

---

### Task 3: Per-connection loadout persistence + `SET_LOADOUT` handler

**Files:** Modify `server/server_main.gd`.

1. In the `_handle_hello` client record (`:1181-1194`) add `"loadout": <cfg>` where `<cfg>` = `Loadout.bot_loadout(id, <catalog>)` for bots (`auto_deploy`) or `Loadout.default_loadout(Loadout.ASSAULT)` for humans (a sane starting class; the human overrides via `SET_LOADOUT`/screen later). Seed the derived `class`/`weapon`/`ammo`/`reserve` fields FROM this loadout (see Task 4) rather than the old rolls — but keep this task limited to *storing* the loadout + wiring the handler; Task 4 makes spawn *read* it. To keep the suite green between tasks, in THIS task also set `c["class"] = cfg["class"]` and leave the existing weapon derivation as-is (Task 4 replaces it).
2. Add the dispatch arm in `_on_packet` (`:1112-1131`): `Protocol.Msg.SET_LOADOUT: _handle_set_loadout(peer, bytes)`.
3. Add the handler, mirroring `_handle_set_fire_mode`'s prologue:
```gdscript
func _handle_set_loadout(peer: int, bytes: PackedByteArray) -> void:
	var id: int = _peer_to_id.get(peer, -1)
	if id < 0 or not _clients.has(id):
		return
	var raw := Protocol.decode_set_loadout(bytes)
	var cfg := Loadout.sanitize(raw, <catalog>)
	_clients[id]["loadout"] = cfg
	_clients[id]["class"] = int(cfg["class"])   # class-select can change class; applies next spawn
	# No live-pawn mutation — applies on next spawn (store-and-apply).
```
`<catalog>` is the server's `Attachment` catalog instance (find how `sanitize`/attachments are already accessed on the server; the map notes attachments are catalog-driven — reuse that instance; if the server holds it as e.g. `_attachments`, use it).

**Tests** (add to a new `tests/loadout_persistence_test.gd` OR extend an existing server-sim test if one instantiates the server headless — check `tests/` for a server harness; if none, unit-test the handler logic indirectly is hard, so test at the sim level in Task 7). For THIS task, the acceptance is: full suite stays green and a manual headless boot accepts a `SET_LOADOUT` without error. Defer the persistence assertions to Task 7's integration test.

- [ ] Step 1: implement the three edits. Step 2: `godot --headless --path . -- --test` green. Step 3: smoke — boot the server headless briefly with bots and confirm no parse/runtime error (`godot --headless --path . --script server/... ` per the project's existing smoke pattern, or the stress harness dry-run). Step 4: commit `feat(server): persist per-connection loadout + SET_LOADOUT handler (store-and-apply)`.

---

### Task 4: Spawn applies the stored loadout (weapon/ammo/reserve/armor/gadget/grenade-type)

**Files:** Modify `server/server_main.gd`.

Rewrite the spawn/refill paths to read `_clients[id]["loadout"]` instead of the per-class legacy derivations:
- `_handle_hello` spawn (`:1160-1204`): `wid = int(loadout["primary"])`; `c["weapon"] = wid`; `c["ammo"] = Weapon.get_def(wid)["mag_size"]`; `c["reserve"] = Weapon.reserve_ammo(wid)`; `p.armor_class = int(loadout["armor"])` (was `armor_for(cls)`). Keep `bandage_count` as `Revive.bandage_count_for(cls == MEDIC)` (trait counts stay P2). Remove the `random_class` weapon roll, the `id % 3` RPG/DMR poke (`:1164-1168`), and the `--human-rpg` primary special (`:1171-1173`) — RPG is no longer a primary (Task 5); fold `--human-rpg` into Task 6's debug loadout.
- `_build_weapon_slots` (`:1320-1333`): primary slot = `loadout["primary"]`, secondary = `loadout["secondary"]` (PISTOL). Ammo/reserve per slot from the variant defs.
- `_reset_weapon_loadout` (`:1374-1388`): read the primary/secondary from the stored loadout (not a class default).
- Grenade TYPE: where the server picks the grenade kind for a throw (map: `_handle_grenade_throw` ~`:1426-1440` / `_throwables_for` `:1244-1249`), use `loadout["grenade"]` as the thrown type. Grenade COUNT stays the current cooldown behavior (count trait is P2).
- Gadget dispatch (`gadget_for_player` callers `:1697, :1708`): read `int(_clients[id]["loadout"]["gadget"])` instead of the id-parity derivation. (Leave `Loadout.gadget_for_player` in place for now if other callers exist, but the C4/mine dispatch reads the stored gadget.)

**Acceptance:** existing gameplay behavior preserved for a default-loadout pawn (Assault/AR/MEDIUM/C4 → same as before except armor: humans were MEDIUM via `armor_for(ASSAULT)`, still MEDIUM; Medic was LIGHT via `armor_for`, now the loadout default is MEDIUM — this is an intended behavior change per spec §F: armor is player-picked, default MEDIUM). Bots via `bot_loadout` now field varied armor/weapons.

- [ ] Step 1: implement. Step 2: full suite green (fix only tests asserting the *legacy* per-class armor/weapon at spawn — e.g. a test expecting Medic=LIGHT at spawn must update to the loadout default, MEDIUM, OR set the bot/debug loadout explicitly; if a test encodes real gameplay intent that this breaks, STOP and report). Step 3: headless smoke with bots — no errors, bots spawn with varied loadouts. Step 4: commit `feat(server): apply stored loadout at spawn (weapon/armor/gadget/grenade from LoadoutConfig)`.

---

### Task 5: RPG becomes gadget-only

**Files:** Modify `shared/sim/loadout.gd`, `server/server_main.gd`, `bots/exercisers.gd`.

- `loadout.gd can_equip`: remove the `if arch == Weapon.RPG: return cls == ENGINEER` branch (RPG is no longer a selectable primary archetype — it isn't in any `allowed_archetypes`, and `is_variant` gating already blocks it; dropping the branch removes the dead legacy gate). Update the docstring. `secondary_for` unchanged (PISTOL).
- `server_main.gd _fire_rocket` (`:1578-1589`): replace the `int(c["weapon"]) != Weapon.RPG` gate with `int(c["loadout"]["gadget"]) != Loadout.GADGET_RPG`. Rocket pool: at spawn, `c["rockets"] = <starting rockets> if int(loadout["gadget"]) == Loadout.GADGET_RPG else 0` (find the current starting-rocket constant; keep it). Rocket refill checks (`:545, :843, :1295`) gate on the same gadget condition.
- `bots/exercisers.gd maybe_rpg` (`:410-444`) + `maybe_rpg_building` (`:483-515`): rekey the "has RPG" test from the RPG weapon to the RPG gadget (the bot's stored loadout gadget == `GADGET_RPG`). Thread the gadget in from wherever the exerciser knows the bot's loadout/class (map: exercisers already read `Loadout.gadget_for_player`; switch that read to the bot's stored gadget or pass it through).

**Tests:** add `tests/rpg_gadget_test.gd`:
- `test_rpg_never_a_valid_primary`: for every class, `is_primary_allowed(cls, Weapon.RPG) == false` and `sanitize({class:ENGINEER, primary:Weapon.RPG})["primary"] != Weapon.RPG`.
- `test_engineer_rpg_gadget_valid`: `GADGET_RPG in gadget_options(ENGINEER)` and `sanitize({class:ENGINEER, gadget:GADGET_RPG})["gadget"] == GADGET_RPG` (now that it's implemented).
- (The fire-path assertion — rockets present iff gadget==RPG — is Task 7's sim integration test.)

- [ ] Step 1: tests → FAIL where appropriate. Step 2: implement the three files. Step 3: full suite green + headless bot smoke (RPG bots still fire rockets). Step 4: commit `feat: RPG is Engineer gadget-only (drop RPG primary path; rocket pool gated on GADGET_RPG)`.

---

### Task 6: `--loadout=` debug arg (headless loadout override)

**Files:** Modify `server/server_main.gd` (arg parsing).

Add a CLI arg parsed at boot that overrides a connection's loadout for headless testing without a client screen. Accept a compact form, e.g. `--loadout=class,primary,gadget,armor,grenade` (ints), applied to the next human connection (or all humans). Route it through `Loadout.sanitize`. Fold the old `--human-rpg` flag into this (`--human-rpg` ⇒ a loadout with `gadget=GADGET_RPG` on an Engineer). Document the arg in the server's arg help/comment block near the other flags.

**Acceptance:** `godot --headless --path . <server-launch> --loadout=2,16,2,2,0` boots and a connecting client/pawn gets an Engineer(2)/M4A2(16)/RPG-gadget(2)/HEAVY(2)/FRAG(0) loadout (sanitized). No test needed beyond a headless boot check; add a tiny unit test for the arg *parser* function if it's factored out as a pure `static func _parse_loadout_arg(s) -> Dictionary`.

- [ ] Step 1: factor a pure `_parse_loadout_arg` + unit-test it (round-trips a valid string; garbage → `{}`/default). Step 2: wire it into boot + connection seeding. Step 3: full suite green + headless boot with the arg. Step 4: commit `feat(server): --loadout= debug arg (folds in --human-rpg)`.

---

### Task 7: Persistence + RPG-gadget sim integration tests

**Files:** Create `tests/loadout_persistence_test.gd` (use the project's headless server-sim test harness — find an existing `tests/*sim*` or server-instantiating test to copy the setup from; if the server can't be unit-instantiated, drive the sim through the same entry the other integration tests use).

Prove, at the sim level:
- `test_loadout_survives_respawn`: set a client's stored loadout (e.g. Support/LMG/HEAVY), spawn, kill, respawn → the respawned pawn has the LMG primary + HEAVY armor again (persistence).
- `test_midlife_set_loadout_does_not_mutate_pawn`: with a live pawn, apply a `SET_LOADOUT` changing class/weapon → the LIVE pawn is unchanged; only the NEXT spawn reflects it.
- `test_server_sanitize_equals_client_sanitize`: the same raw cfg through `Loadout.sanitize` twice (the server and client call the identical function) is equal — determinism guard.
- `test_engineer_with_rpg_gadget_has_rockets`: an Engineer whose loadout gadget is `GADGET_RPG` spawns with rockets > 0 and can fire; an Engineer with `GADGET_C4` spawns with 0 rockets and cannot fire a rocket.

If a full server instance is impractical in `TestCase`, assert the equivalent via the smallest real seams (e.g. a helper that computes "spawn weapon/armor/rockets from a loadout") — but prefer exercising the real spawn path.

- [ ] Step 1: write tests (import). Step 2: they pass against Tasks 3–5. Step 3: full suite green. Step 4: commit `test(loadout): persistence + rpg-gadget spawn integration`.

---

### Task 8: 128-bot fleet gate (game2, `conquest_town`)

**Not a code task — a validation gate. Run on the fleet-gate host (game2).**

- Run the stress harness at 128 bots on `conquest_town` (memory: validate M11-adjacent work on `conquest_town`, NOT `proving_grounds`; RPG bots chew the map otherwise). Bots now field the full matrix via `bot_loadout`.
- **Pass criteria (spec §J P1):** tick mean **< 33.3 ms** at 30 Hz on the E-core budget host; **bandwidth unchanged** vs the pre-P1b baseline (no per-tick byte added — confirm aggregate Mbit/s ≈ the 30 Hz snapshot baseline ~47 Mbit/s); Conquest reaches a winner; no degrade-ladder steps triggered; zero runtime SCRIPT/parse errors in the log.
- Capture the tick-mean + agg Mbit/s numbers for the gate commit message (project norm: `gate(...)` commit with the measured numbers).

- [ ] Step 1: run the gate on game2 (dev session runs on game2 — run `docker/stress.sh` / the harness directly per project ops). Step 2: record numbers; if FAIL (tick or bandwidth regression), profile and STOP to triage before landing. Step 3: commit the gate note `gate(netcode): M19 P1b loadout framework PASS <tick>ms (agg <x> Mbit/s, 128p conquest_town)`.

---

## Landing

After Task 8 PASS: final holistic review of the whole branch, then reconcile with master + merge + push (land-your-work). Update `docs/TASKS.md` M19 row and the `blockfire-m19-class-select-loadouts` memory (P1b DONE, P2 next). P2 (traits + cheap gadgets) is the next phase.
