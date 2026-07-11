# Spec: Rendered Client — Prediction, Reconciliation & Netcode (M7 P1)

**Status:** approved (design) · **Date:** 2026-06-16 · **Milestone:** [M7](../milestones/M7-art-ux.md) Phase 1 · **ADR:** [0005 renderer](../adr/0005-client-renderer.md) · **Related:** [hud-ui](hud-ui.md), [netcode-replication](m1-netcode-core.md), [anti-cheat-matchmaking](anti-cheat-matchmaking.md)

Turns the headless client **stub** (`client/client_main.gd` — connects, sends *zeroed* input, applies snapshots, reconciles its own pawn) into a **rendered, predicted first-person client**. The simulation already lives in `shared/sim/`; this spec is about **predicting, interpolating, rendering, and sending intent** — never about re-deciding gameplay.

## Guiding rule (AGENTS.md §7)

**The client is a view + a predictor + an intent sender. It owns no authority.** Movement, combat, vehicle physics, ammo rules, spawn placement, and damage are decided server-side or by the *shared* sim re-run identically on the client. No gameplay/decision logic enters `client/`. This is what keeps prediction and authority from diverging. Anti-cheat is unaffected: hit resolution stays server-authoritative + lag-compensated (spec Layer 1, already built); the client predicts *feel and ammo*, never *hits*.

## Scope (P1)

In: rendered first-person client; real keyboard/mouse input; local-pawn prediction/reconciliation (full movement state); client ammo/fire/reload prediction; local-vehicle prediction; remote pawn + vehicle interpolation; placeholder-primitive rendering of world + entities; new netcode messages (`DEPLOY_REQUEST`, `DAMAGE_EVENT`, `SELF_STATE`) + a `HELLO.auto_deploy` flag.

Out (later phases): the low-poly art kit + LOD (P2); audio/visual *polish* beyond essential cues (P2); full rebindable keybindings (P2 polish); Steam auth/VAC and L3 LOS culling (deferred online/anti-cheat track).

## Client module architecture (`client/`)

Grows the monolith into small, single-purpose, independently testable units. The composition root (`client_main.gd`) wires them each frame; everything below it is a focused unit with one job.

| Module | Responsibility | Depends on |
|---|---|---|
| `net_client.gd` | ENet transport + protocol I/O: connect, send `InputCommand`/`DEPLOY_REQUEST`/squad intent, receive `SNAPSHOT`/`KILL`/`DAMAGE_EVENT`/structure & smoke events. | `shared/net/` |
| `predictor.gd` | Local-pawn + local-vehicle prediction & reconciliation by stepping **shared** `Pawn`/`Vehicle`; ammo/fire/reload prediction. (Extends today's `prediction.gd`.) | `shared/sim/` |
| `world_view.gd` | Client mirror of authoritative data: applies snapshots into the entity view, holds interpolated remotes, exposes read-only "what exists / where / what state" to renderer + HUD. | `Snapshot`, `Interpolation` |
| `input_controller.gd` | Keyboard/mouse → `InputCommand` buttons + look; applies sensitivity/FOV/invert from settings. | settings, `InputCommand` |
| `world_renderer.gd` | Builds/updates the Godot 3D scene (entity node pool, static world from `MapDef`/structures, camera, viewmodel) from `world_view` + `predictor`. Pure presentation. | `world_view`, `predictor`, `MapDef` |
| `hud/` | HUD state model + Control drawing (see [hud-ui](hud-ui.md)). | `world_view`, `predictor` |
| `menus/` | Deploy / squad / settings screens (see [hud-ui](hud-ui.md)). | `net_client` |
| `client_main.gd` | Thin composition root; per-tick (`_physics_process`) input→predict→send, per-frame (`_process`) render + HUD. | all of the above |

`prediction.gd` and `interpolation.gd` are retained and extended, not replaced.

## Prediction & reconciliation

### Local pawn
Per simulation tick (`_physics_process`, 30 Hz, `SimLoop.DT`):
1. `input_controller` builds the real command dict (`move_x/move_y`, `yaw/pitch`, `buttons`).
2. `predictor` steps the **shared** `Pawn` with that command and **buffers** it `{tick, cmd}` (ascending), tracking the full predicted state the shared `Pawn` owns: pos, velocity, yaw/pitch, stance, lean, stamina, grounded/jump, `climbing`/`vaulting`, DBNO/crawl.
3. `net_client` sends the `InputCommand` (look + buttons + `view_server_tick` + last-acked seq).

On each snapshot, for the local id:
1. Snap predicted state to the authoritative pos/yaw (and other reconciled fields) from the snapshot.
2. Drop buffered commands with `tick <= last_input_tick`; **re-simulate** the remaining tail through `Pawn.step` to reach "now".
3. **Correct smoothly:** if the corrected state differs from the pre-correction predicted state beyond an epsilon, decay the visual error over a few frames rather than snapping (the snap-vs-smooth epsilon + decay rate is a feel knob, tuned in playtest). Below epsilon, accept silently.

Reconciliation must cover the movement extensions added since M2 — stances/lean/stamina (M2), DBNO/crawl (M4.5-P1), ladder/vault (M4.5-P3) — because all of them run in the shared `Pawn`/`SimLoop` the client re-steps.

### Ammo / fire / reload (closes the tracked M2/M7 gap)
The client predicts **feel + ammo**, not hits:
- On a fire input that the **shared** `Weapon` model says is allowed (cadence, mag > 0, not mid-reload), decrement the predicted mag, and trigger instant local effects (muzzle flash, recoil kick, spread bloom via the *shared* spread model so it can't diverge, tracer, gun audio).
- On reload input, run the predicted reload timer and mag/reserve transfer using the shared `Weapon` reload rules.
- **Hits are never predicted.** The server resolves them lag-compensated and authoritative; the client shows a **hitmarker only on server confirmation** (a hit/kill signal — see "Hit confirmation" below). On the LAN P1 setup (client↔game2, sub-ms) this is effectively instant.
- Predicted ammo **reconciles** against the authoritative `ammo` carried in the snapshot (`EntityState.ammo`, below): on mismatch, snap predicted ammo to authoritative.

### Local vehicle
When the local player is the **driver**, predict the vehicle by stepping the **shared** `Vehicle` physics with throttle/steer input and reconcile against the vehicle records in the snapshot, exactly like the pawn. **Passenger/gunner** seats are position-slaved by the server, so those clients interpolate the vehicle rather than predict it. Remote vehicles interpolate like remote pawns.

## Interpolation (extends `interpolation.gd`)
Remote pawns and vehicles render from `Interpolation.sample(now - DELAY)` (existing 100 ms render delay), lerping pos + `lerp_angle` yaw between the two surrounding snapshots. Extend to:
- carry the presentation-relevant `EntityState` fields needed to pose a remote (stance, lean, `is_downed`, `climbing`, team, alive) — interpolated where continuous (pos/yaw), stepped where discrete (stance/flags).
- include vehicle records (pos/yaw/seat occupancy) in the buffered view.

The **local** pawn/vehicle always render from *prediction* (zero added latency on your own movement/look); **remotes** always from *interpolation*. This predict-self / interpolate-others split is the standard model and is already scaffolded.

## New netcode (client/server edge only — no rule logic in `client/`)

### `SELF_STATE` (server → owning client) — ammo/reload reconciliation
The client reconciles predicted ammo against the **server-authoritative** weapon state. The server already tracks this per client (`c["ammo"]`, `c["reloading"]`, `c["reload_done_tick"]`, `c["weapon"]` in `_resolve_fires`). It is transported as a dedicated lightweight `SELF_STATE{mag, reloading, reload_remaining, weapon}` message sent to each owning client (at the snapshot stride), **not** as a field on the shared `EntityState`.

*Why not `EntityState.ammo`:* the entity delta `field_mask` is a full 8-bit byte (bits 0–7 all used: pos×3, yaw, pitch, state, health, squad), so a 9th field would force widening the hot delta codec to `u16` — and ammo is self-only anyway. A separate self-message is **self-only by construction** and leaves the per-entity codec untouched.

*Reserve ammo:* > Superseded by M17 (`docs/specs/reserve-ammo.md`, VERSION 6): the sim now carries a finite `reserve` pool and `SELF_STATE` gains a trailing `reserve` u16. (P1 shipped with reload refilling the full mag — reserve effectively infinite — until M17 added the finite economy.)

*Throwables block (Checkpoint 3):* `SELF_STATE` carries a `being_revived` bit (1 = a teammate is actively reviving the downed local player this tick, from the server's revive-in-progress set) followed by a **variable-length** `throwables` list `[{kind, count}]` so the HUD selector shows live counts. Both are **append-only and back-compatible** — decode reads each only if bytes remain (defaults `false` / `[]`). The throwable list is **data-driven** (frag/smoke share the grenade cooldown → `count = 1` when ready else `0`; RPG appends `{kind:100, count:rockets}`), so M5.5 throwables (flashbang/impact) slot in by adding list entries with no UI/wire rewrite. `kind:100` is a UI-only RPG tag pending M5.5 formalization. The `being_revived` bit drives the downed-screen "Being revived — hold on!" cue.

### `DEPLOY_REQUEST` (client → server)
Today the server **auto-spawns** every client alive at `HELLO` and auto-respawns after a fixed delay (`_handle_respawns` → `SpawnSelect`). Bots and humans connect identically, so the server distinguishes them with a new **`auto_deploy` flag on `HELLO`** (default `true` = today's behavior, so bots and the 128-bot fleet path are untouched; the rendered client sends `false`). For a human deploy screen:
- An `auto_deploy=false` client is **held un-deployed** (pawn spawned but `alive=false`, `respawn_tick=0` so `_handle_respawns` leaves it down) until it sends `DEPLOY_REQUEST{spawn_ref}`. On death it returns to the deploy screen instead of auto-respawning.
- A new pure `DeploySpawn` helper (`shared/sim/`) **enumerates** valid refs and **resolves/validates** a ref → position. The ref scheme: `0` = HQ; `1..N` = owned capture point; `SQUADMATE_BASE(200) + pawn_id` = spawn on that squadmate; `VEHICLE_BASE(400) + slot` = spawn on that friendly vehicle (`slot = vid − Vehicle.ID_BASE`). Squadmate/vehicle refs landed in Checkpoint 3 and are **keyed by stable entity identity (pawn id / vehicle slot), NOT array position** — the client and server build their candidate arrays in different order/membership (the client only includes mates currently in its interpolated view), so a positional index aliased to the wrong entity across the wire; id/slot keying removes that. `spawn_ref` is therefore a **u16** (squadmate refs reach 201..328). Validity rules live **in `DeploySpawn`** (shared): a squadmate ref is valid only if the mate is alive + standing + same-team; a vehicle ref only if same-team + has a free seat. The server and client each pass candidate arrays (`squadmates` `{id,pos,team,alive,downed}` / `vehicles` `{slot,pos,team,free_seats}`). The client lists `DeploySpawn.enumerate(...)`; the server **re-validates** the requested ref via `DeploySpawn.is_valid(...)` against its **authoritative** candidate arrays and places the pawn, or ignores it (mate died / vehicle filled / point lost) and the client re-prompts (the deploy menu un-sticks its "awaiting" overlay after a few snapshots). A human death also starts a **respawn cooldown** (`deploy_ready_tick`); the server rejects `DEPLOY_REQUEST` until it elapses and the deploy screen shows a countdown. **No spawn-placement logic moves to the client** — it only sends intent over choices the server re-validates.
- Initial join and every death return an `auto_deploy=false` client to the deploy screen.

### `SET_SQUAD` (client → server) — minimal (landed Checkpoint 3)
Lets a human join/switch squad, backed by the existing server `SquadManager`. `SET_SQUAD{squad}` is validated server-side via the public, capacity-checked `SquadManager.join(client_id, team, squad_id) -> bool` (no private-state poking); a full target squad is a silent no-op. On success the server updates both `SquadManager` and the pawn's replicated `squad`, which propagates to clients in the next `ROSTER` + `EntityState.squad`. Minimal in P1 (enough to see + pick a squad, since squad-spawn depends on it).

### `ROSTER` (server → clients) — names + per-client K/D/score (Checkpoint 3)
Carries one row per connected client `{id, name, team, squad, kills, deaths, score}`, broadcast reliably on a fixed stride (`ROSTER_STRIDE_TICKS`). The client only knows entity ids from snapshots; `ROSTER` supplies the **names + squads** the squad list and TAB scoreboard need, and the per-client K/D/score the scoreboard shows. The server credits a kill (killer `kills+1`, `score+KILL_SCORE`; victim `deaths+1`; suicides credit no kill) in `_kill_pawn`. **Presentation/identity only** — no gameplay decision is made from it client-side.

### `DEATH_INFO` (server → victim) — death-recap payload (Checkpoint 3)
Sent reliably to the **victim** on true death: `{killer_id, weapon, distance, killer_hp, attackers:[{id, dmg}]}`. The server keeps a **per-life damage ledger** (`attacker_id → applied dmg`, accrued in `_apply_pawn_damage` for tracked clients only, skipping no-attacker/world damage id 0), cleared at the start of each life **and on revive** (so the recap reflects the lethal sequence, ~one health bar, not damage accumulated across a multi-revive life). Ordered by the pure `DeathRecap.attackers_sorted` (damage desc, id asc) into the `attackers` list. **Killer attribution:** a direct kill credits the attacker live; a **bleed-out / give-up** death credits the attacker who **downed** the victim (stored as `downed_by`), not the victim themselves — and uses the killer's HP + range **snapshotted at down-time** (`downed_by_hp`/`downed_by_dist`), since by bleed-out the attacker may be dead/respawned (the live read gave "0 HP"). The downer also receives the kill credit. **Presentation only** — it does not affect authoritative state; names are resolved client-side from `ROSTER`. Projectile-compatible (no hit-scan assumption). No position reveal, no killcam.

### `DAMAGE_EVENT` (server → client)
On dealing damage to a pawn, the server sends that **victim** a lightweight `DAMAGE_EVENT{amount, source_dir_or_pos}` to drive the HUD vignette + directional arc. **Presentation only** — it does not change the authoritative `health` already carried in the snapshot, and grants no gameplay effect. Sent only on hits (event-driven, off the per-tick hot path).

All additions are encoded in `shared/net/protocol.gd` (wire format) but **consumed at the client/server edge**; no gameplay decision is made from them inside `client/`.

## Rendering data-feed (logic only; visuals in playtest — see ADR-0005)
The renderer is fed by, and only by, `world_view` (interpolated remotes) + `predictor` (local). Tested logic (not pixels):
- entity **enter/leave** as ids appear/disappear from interest → node pool acquire/release;
- **stance/flags → pose** mapping (stand/crouch/prone/lean/downed/climbing) is a pure function asserted in tests;
- static world built from `MapDef` geometry + structure store; structure add/remove driven by `STRUCTURE_DELTA` events;
- camera parented to predicted local `Pawn.eye_position()` (stance-aware, already exists), look applied from local input immediately.
Placeholder primitives sit **behind a swappable node interface** so P2 swaps meshes without touching netcode/prediction.

## Test plan (deterministic, headless on game2 — the authoritative proof per AGENTS.md §10)
- **Reconciliation convergence:** a recorded input sequence stepped through `predictor` vs the same sequence through the server's `SimLoop` reach the same final state (pos/yaw/stance/stamina); within float epsilon.
- **Correction absorption:** inject an authoritative state mid-stream that differs from prediction; assert the unacked-tail replay produces the correct corrected state and that the buffer is trimmed at `last_input_tick`.
- **Movement-extension coverage:** reconciliation holds across a jump, a stance change, a ladder climb, and a vault (states that live in shared `Pawn`/`SimLoop`).
- **Ammo prediction:** a fire-burst + reload sequence stepped through the client `WeaponPredictor` (mirroring server fire-gating) yields predicted `mag` equal to the server-authoritative ammo; an injected mismatch reconciles (snaps) to the `SELF_STATE` value.
- **Vehicle prediction:** driver throttle/steer stepped via `predictor` converges with the server `Vehicle` step; a passenger view interpolates (does not predict).
- **`DEPLOY_REQUEST`:** server places the pawn only at a server-valid spawn; an invalid/lost spawn is rejected and no pawn is placed; a human client is not in the world before requesting; bots still auto-deploy.
- **`DAMAGE_EVENT`:** emitted to the victim on damage with a correct direction toward the attacker; carries no health change beyond the snapshot's.
- **Interpolation/view:** sampling at `now-DELAY` lerps between bracketing snapshots; entity enter/leave handled; stance→pose mapping correct.
- **`SELF_STATE`/`DEPLOY_REQUEST`/`HELLO.auto_deploy` codecs:** round-trip through `Protocol` encode/decode; `auto_deploy` defaults true for a pre-flag HELLO.

Rendering, gunplay/movement *feel*, reconciliation smoothness, vehicle handling, and HUD readability are validated by **human playtest** (M7 is collaborative — AGENTS.md §10), not headless gates.

## Budget & determinism notes
- Server-side additions are **off / cheap on the per-tick hot path**: `DEPLOY_REQUEST`/`SET_SQUAD` are rare/event-driven; `DAMAGE_EVENT` fires only on hits; `SELF_STATE` is one tiny fixed-size packet per client per snapshot stride (no per-entity codec change). No new per-tick O(N) work; re-check `[perf]` after they land (handover watch-item — `snap`≈16 ms is the dominant cost and is untouched).
- The heavy **rendering** cost is entirely client-side (the player's desktop GPU), not on the server tick.
- All prediction re-runs the **shared** sim; no rule forks (AGENTS.md §7).

## Out of scope (this spec)
- HUD element layout/drawing + menus detail → [hud-ui](hud-ui.md).
- Art kit, LOD, audio/visual polish → P2 (`art-pipeline.md`, written when reached).
- Steam auth/VAC, L3 LOS culling → deferred online/anti-cheat track ([anti-cheat-matchmaking](anti-cheat-matchmaking.md)).
