# Wire-protocol registry

**Authoritative source:** `shared/net/protocol.gd` (single codec for all three roles — AGENTS.md §7).
This doc is the human-readable index so an agent allocating a message id or auditing the wire
doesn't have to reverse-engineer an 850-line file. **Update this table in the same commit as any
`Msg` enum change.**

- **`Protocol.VERSION` = 2** (2026-07-02, deploy-ref re-base). Policy (see `protocol.gd` header):
  bump on ANY wire change — format *or* meaning. The HELLO handshake rejects mismatches; there is
  no other cross-build compat mechanism. Never add `get_available_bytes()` trailing-field guards
  inside repeated records (only sound at message tail).
- **Channels** (`shared/net/net_host.gd`): `CONTROL` (reliable control traffic), `SNAPSHOT`
  (unreliable state), `INPUT` (client commands).
- **Next free message id: 45.**

| id | Msg | direction | purpose | since |
|---|---|---|---|---|
| 1 | HELLO | c→s | protocol version + display name (+ auto_deploy) | M0 |
| 2 | WELCOME | s→c | assigned peer id + tick rate (+ map name) | M0 |
| 3 | REJECT | s→c | rejection reason, then disconnect | M0 |
| 4 | INPUT | c→s | input command frame bundle (`input_command.gd`) | M1 |
| 5 | SNAPSHOT | s→c | baseline+delta entity/vehicle snapshot (`snapshot.gd`) | M1 |
| 6 | KILL | s→c* | kill event (victim, killer, weapon, headshot) | M2 |
| 7 | MATCH_STATE | s→c* | conquest points/tickets/win | M3 |
| 8 | BUILD_REQUEST | c→s | place a fortification piece | M4 |
| 9 | BUILD_REMOVE | c→s | remove an owned piece by id | M4 |
| 10 | STRUCTURE_DELTA | s→c* | piece placed/damaged/removed (op byte) | M4 |
| 11 | STRUCTURE_BASELINE | s→c | all pieces in a region on interest entry | M4 |
| 12 | GRENADE_THROW | c→s | throw a grenade (type byte) in look dir | M4 |
| 13 | DETONATION | s→h | cosmetic explosion VFX at pos | M7 |
| 14 | SMOKE_DEPLOYED | s→c* | smoke zone created (pos/radius/expire) | M4 |
| 15 | REVIVE_ACTION | c→s | begin/stop reviving a downed teammate | M4.5 |
| 16 | SELF_BANDAGE | c→s | bandage self to halt bleed | M4.5 |
| 17 | GADGET_ACTION | c→s | C4/mine/RPG/bag/active-give (action byte) | M4.5 |
| 18 | VEHICLE_ACTION | c→s | enter/exit a vehicle seat | M5 |
| 19 | VEHICLE_DESTROYED | s→c* | a vehicle was destroyed (vid) | M5 |
| 20 | DEPLOY_REQUEST | c→s | deploy at spawn_ref (u16; see `DeploySpawn` ref spaces) | M7 |
| 21 | DAMAGE_EVENT | s→c | damage taken: bearing + amount | M7 |
| 22 | SELF_STATE | s→c(owner) | authoritative ammo/reload/suppression/blind/bandage/repair + trailing-optional reconcile bytes `stamina, vel_y, grounded, vaulting, vault_tick, regen_cooldown` (append-only, `get_available_bytes`-guarded; regen_cooldown added 2026-07-05 for the C6 stamina reconcile) | M7 |
| 23 | HITMARKER | s→shooter | your shot hit (headshot/lethal flags) | M7 |
| 24 | GIVE_UP | c→s | while downed, skip bleed-out and die | M7 |
| 25 | ROSTER | s→c* | name/team/squad/K/D/score rows (1 Hz) | M7 |
| 26 | SET_SQUAD | c→s | join/switch squad | M7 |
| 27 | DEATH_INFO | s→victim | death recap payload | M7 |
| 28 | SHOT_FX | s→h | remote tracer origin+dir (+shooter id) | M7 |
| 29 | COLLAPSE | s→c* | building collapsed (building_id) → rubble | M11 |
| 30 | ROCKET_FX | s→h | RPG launch → cosmetic flying rocket | M7 |
| 31 | SET_FIRE_MODE | c→s | AUTO/SEMI/BURST for current weapon | M5.5 |
| 32 | SWAP_WEAPON | c→s | quick-swap slot 0/1 (server forces snapshot re-ENTER) | M5.5 |
| 33 | MELEE | c→s | melee swing (knife/sledge); zero payload | M5.5 |
| 34 | IMPACT_FX | s→h | bullet hit world geometry → impact puff | M7 |
| 35 | GRENADE_FX | s→h | remote grenade throw → arcing cosmetic | M7 |
| 36 | GADGET_LIST | s→h | deployed C4/mine/bag list (rebuilt-list pattern) | M7 |
| 37 | SUPPORT_LIST | s→h | active heal/ammo/repair/revive links → beams | M7 |
| 38 | PLACE_FOB | c→s | squad leader requests a FOB build site | M12 |
| 39 | REMOVE_FOB | c→s | squad leader removes their squad's FOB | M12 |
| 40 | FOB_LIST | s→h | team's FOBs {squad, structure_id, uc, enabled} | M12 |
| 41 | RELOAD_FX | s→h | remote reload started → reload pose | M7 |
| 42 | MELEE_FX | s→h | remote melee swing → swing pose | M7 |
| 43 | VAULT_FX | s→h | remote vault → mantle pose | M7 |
| 44 | DOWNED_LIST | s→h | downed pawns {id, bleed_frac, halted} → revive urgency | M7 |

Direction key: `c→s` client to server · `s→c` server to one client · `s→c*` server broadcast ·
`s→h` server to **human** clients only (cosmetic; bots skip decode).

## Shared patterns

- **Rebuilt-list messages** (GADGET_LIST 36, SUPPORT_LIST 37, FOB_LIST 40, DOWNED_LIST 44):
  server rebuilds the full list from live stores each tick and sends on change + periodic
  heartbeat; the client mirrors wholesale (no per-entry remove hooks). Copy this pattern for
  any new "render a set of server-owned things" need; if a fifth appears, consider a generic
  list codec.
- **Deploy spawn refs** (DEPLOY_REQUEST): u16, keyed by entity identity, ordered spaces —
  point `1..999` (index+1; 0 = HQ), squadmate `1000+pawn_id` (≤ `MAX_SQUADMATE_ID`),
  vehicle `40000+slot`, FOB `50000+squad`. See `shared/sim/deploy_spawn.gd`.
- **Entity id spaces in SNAPSHOT**: pawns use raw server ids; vehicles are offset by
  `Vehicle.ID_BASE = 0x40000000` (disjoint ranges multiplexed into one record stream).
- Every encoder/decoder lives in `protocol.gd` (the last two strays — HELLO, REJECT — moved
  in 2026-07-02's codec dedup). Shared field codecs `put_pos10/get_pos10` (0.1 m i16) and
  `put_dir10k/get_dir10k` (1e-4 i16, clamped) pack every pos/dir payload; normalize at the
  call site when the message wants a unit vector.
