# Spec: Rendered Client — Prediction, Reconciliation & Netcode (M7 P1)

**Status:** approved (design) · **Date:** 2026-06-16 · **Milestone:** [M7](../milestones/M7-art-ux.md) Phase 1 · **ADR:** [0005 renderer](../adr/0005-client-renderer.md) · **Related:** [hud-ui](hud-ui.md), [netcode-replication](m1-netcode-core.md), [anti-cheat-matchmaking](anti-cheat-matchmaking.md)

Turns the headless client **stub** (`client/client_main.gd` — connects, sends *zeroed* input, applies snapshots, reconciles its own pawn) into a **rendered, predicted first-person client**. The simulation already lives in `shared/sim/`; this spec is about **predicting, interpolating, rendering, and sending intent** — never about re-deciding gameplay.

## Guiding rule (AGENTS.md §7)

**The client is a view + a predictor + an intent sender. It owns no authority.** Movement, combat, vehicle physics, ammo rules, spawn placement, and damage are decided server-side or by the *shared* sim re-run identically on the client. No gameplay/decision logic enters `client/`. This is what keeps prediction and authority from diverging. Anti-cheat is unaffected: hit resolution stays server-authoritative + lag-compensated (spec Layer 1, already built); the client predicts *feel and ammo*, never *hits*.

## Scope (P1)

In: rendered first-person client; real keyboard/mouse input; local-pawn prediction/reconciliation (full movement state); client ammo/fire/reload prediction; local-vehicle prediction; remote pawn + vehicle interpolation; placeholder-primitive rendering of world + entities; two new netcode messages (`DEPLOY_REQUEST`, `DAMAGE_EVENT`); an `ammo` field on `EntityState`.

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

### `EntityState.ammo`
Add an `ammo` field (packed mag + reserve, e.g. two small ints / quantized) to `EntityState` so the client can reconcile predicted ammo. Replicated for **self** always (needed for reconciliation); for remotes it is not required by gameplay and may be omitted from their state to save bytes (decided in the `Snapshot` codec; default: send only for self).

### `DEPLOY_REQUEST` (client → server)
Today the server **auto-respawns** human-less bots after a fixed delay (`_handle_respawns` → `SpawnSelect`). For a human deploy screen:
- The server **holds a human client un-deployed** (a spectator/await state, not placed in the world) until it receives a `DEPLOY_REQUEST{spawn_ref}`. Bots keep auto-deploy unchanged.
- `spawn_ref` identifies a spawn the client offered (HQ / owned capture point / squadmate / friendly vehicle). The server **re-validates** it against the existing `SpawnSelect`/spawn rules and **places the pawn** — or rejects (e.g. point lost / mate dead) and the client re-prompts. **No spawn-placement logic moves to the client**; it only sends intent over choices the server already considers valid.
- Initial join and every death return the client to the deploy screen.

### `SET_SQUAD` (client → server) — minimal
Lets a human join/switch squad, backed by the existing server `SquadManager`. Validated server-side. Minimal in P1 (enough to see + pick a squad, since squad-spawn depends on it).

### `DAMAGE_EVENT` (server → client)
On dealing damage to a pawn, the server sends that **victim** a lightweight `DAMAGE_EVENT{amount, source_dir_or_pos}` to drive the HUD vignette + directional arc. **Presentation only** — it does not change the authoritative `health` already carried in the snapshot, and grants no gameplay effect. Sent only on hits (event-driven, off the per-tick hot path).

All four additions are encoded in `shared/net/protocol.gd` (wire format) but **consumed at the client/server edge**; no gameplay decision is made from them inside `client/`.

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
- **Ammo prediction:** a fire-burst + reload sequence yields predicted mag/reserve equal to the server-authoritative ammo; an injected ammo mismatch reconciles (snaps) to authoritative.
- **Vehicle prediction:** driver throttle/steer stepped via `predictor` converges with the server `Vehicle` step; a passenger view interpolates (does not predict).
- **`DEPLOY_REQUEST`:** server places the pawn only at a server-valid spawn; an invalid/lost spawn is rejected and no pawn is placed; a human client is not in the world before requesting; bots still auto-deploy.
- **`DAMAGE_EVENT`:** emitted to the victim on damage with a correct direction toward the attacker; carries no health change beyond the snapshot's.
- **Interpolation/view:** sampling at `now-DELAY` lerps between bracketing snapshots; entity enter/leave handled; stance→pose mapping correct.
- **`EntityState.ammo` codec:** round-trips through `Snapshot.encode`/`decode_apply`; self-only replication honored.

Rendering, gunplay/movement *feel*, reconciliation smoothness, vehicle handling, and HUD readability are validated by **human playtest** (M7 is collaborative — AGENTS.md §10), not headless gates.

## Budget & determinism notes
- Server-side additions are **off the per-tick hot path**: `DEPLOY_REQUEST`/`SET_SQUAD` are rare/event-driven; `DAMAGE_EVENT` fires only on hits; the `ammo` field is a few bytes in states the snapshot already sends (self-only). No new per-tick O(N) work; re-check `[perf]` after they land (handover watch-item — `snap`≈16 ms is the dominant cost and is untouched).
- The heavy **rendering** cost is entirely client-side (the player's desktop GPU), not on the server tick.
- All prediction re-runs the **shared** sim; no rule forks (AGENTS.md §7).

## Out of scope (this spec)
- HUD element layout/drawing + menus detail → [hud-ui](hud-ui.md).
- Art kit, LOD, audio/visual polish → P2 (`art-pipeline.md`, written when reached).
- Steam auth/VAC, L3 LOS culling → deferred online/anti-cheat track ([anti-cheat-matchmaking](anti-cheat-matchmaking.md)).
