# Spec: HUD & Menus (M7 P1)

**Status:** approved (design) · **Date:** 2026-06-16 · **Milestone:** [M7](../milestones/M7-art-ux.md) Phase 1 · **Related:** [client-prediction](client-prediction.md)

Defines the BattleBit-style HUD and the deploy/squad/settings menus for the first rendered client. The design split is deliberate: the HUD **state** is a pure, headless-testable model; the HUD **drawing** is Control-node presentation validated by human playtest.

## Owner's HUD rules (fixed)

- **No health bar. No minimap.** Nothing numeric about your survival is shown.
- Show **ammo, compass, squad members, and a TAB scoreboard.**
- Damage is communicated only by **vignette + directional arc + audio** (no numbers) — see below.
- Defaults to **BattleBit's** balance/feel where applicable (AGENTS.md §9); BattleBit is the reference design.

## Architecture — model / view split

| Unit | Kind | Responsibility |
|---|---|---|
| `hud/hud_model.gd` | Pure (no nodes, no drawing) | Computes the HUD's *data* from `world_view` + `predictor` + buffered events. Headless-testable. |
| `hud/hud_view.gd` | Control nodes | Draws `hud_model`'s output. Layout/feel judged by playtest. |

`hud_model` is recomputed each frame from read-only client state; it holds **no authority** and makes **no gameplay decisions** — it only *presents* what the client already knows.

### `hud_model` output (the testable struct)
- **Ammo:** predicted `{mag, reserve}` for the local weapon (from `predictor`); a `reloading` flag + progress; a `low_ammo` flag.
- **Compass:** local yaw → heading in degrees + cardinal; plus the **screen-space bearing of each objective** (capture point A/B/C…) relative to local yaw, so flags appear as markers on the strip (the objective awareness a minimap would otherwise give). Owned/contested/enemy state per flag.
- **Squad roster:** for each squadmate — name, alive/downed/dead, (optionally) distance/bearing — from `world_view` + squad data.
- **Scoreboard:** per-team rows of `{name, kills, deaths, score}` sorted by score then name; team ticket totals; shown while TAB held.
- **Tickets & capture:** per-team ticket counts; capture-progress (0–1 + direction) for the point the local player currently stands in.
- **Killfeed:** recent `{killer, victim, headshot, weapon}` entries from `KILL`, time-decayed.
- **Damage arcs:** active `{direction, age}` entries from `DAMAGE_EVENT`, fading over a fixed duration; plus a **vignette intensity** scalar from recent damage.
- **Hit/kill confirm:** transient flags raised by server hit/kill confirmation (server-confirmed model — [client-prediction](client-prediction.md)).
- **Interaction prompt:** current contextual action, if any (enter vehicle / hold-to-revive a downed mate / resupply), derived from proximity in `world_view`.

### `hud_view` elements (drawn from the model)
Crosshair (dynamic spread) · ammo (mag/reserve, bottom-right) · compass strip (top-center, bearing + cardinals + flag markers) · squad list (bottom-left) · TAB scoreboard (centered overlay, hold) · killfeed (top-right) · ticket/capture readout · hitmarker + kill-confirm · interaction prompts · DBNO bleed-out UI (when local pawn `is_downed`) · grenade/gadget selector + count · **damage vignette + directional arcs**. Layout echoes BattleBit; exact placement is a playtest call.

## Damage feedback (no health, by design)

When the local pawn takes damage, the client receives a `DAMAGE_EVENT{amount, source_dir}` (server→client, presentation-only — [client-prediction](client-prediction.md)). The HUD shows:
1. a **red screen-edge vignette** flash whose intensity scales with recent damage and decays, and
2. a **directional arc** (red) pointing toward `source_dir`, fading over a fixed duration.

This is the BattleBit cue set: you *feel* the hit and learn roughly *where* it came from, with zero numbers. No health value is ever displayed.

## Menus

### Deploy screen (full-screen, between lives)
Drives `DEPLOY_REQUEST` ([client-prediction](client-prediction.md)). Shows valid spawns and lets the player choose:
- **Checkpoint 1:** HQ + currently-owned capture points.
- **Checkpoint 3 (landed):** on a **squadmate** (`DeploySpawn.SQUADMATE_BASE+i`, valid only if the mate is alive + standing + same-team) and on a **friendly vehicle** with a free seat (`DeploySpawn.VEHICLE_BASE+i`). The deploy menu builds the same `squadmates`/`vehicles` candidate arrays the server uses (mates from `world_view.roster()` ∩ interpolated entities; vehicles from `world_view.vehicles()`), lists `DeploySpawn.enumerate(team, map, conquest, squadmates, vehicles)`, and labels mate refs with the mate's name and vehicle refs with the vehicle type.
Selecting a spawn sends `DEPLOY_REQUEST{spawn_ref}` (unchanged wire across all ref kinds); the server **re-validates** the ref via `DeploySpawn.is_valid(...)` against its authoritative candidate arrays and places the pawn, or rejects (mate died / vehicle filled / point lost) → the deploy screen stays up to re-pick. A non-rendered await/spectator state covers the pre-deploy gap. Shown on initial join and after every death.

### Squad menu (minimal)
View the squad (members + status, reusing the roster data) and **join/switch squad** via `SET_SQUAD` (backed by server `SquadManager`). P1 keeps it minimal — enough to see and pick a squad, since squad-spawn depends on it. Squad creation/leadership niceties are deferred. **Two entry points (C3):** the squad buttons on the deploy screen (between lives), and a standalone **squad-select overlay toggled by `U` while alive** (releases the cursor like the settings menu, sends `SET_SQUAD` on pick, auto-closes on death).

### DBNO / downed screen (C3)
While `is_downed`: bleed-out countdown + **hold-to-give-up** (true death now; the downer is credited). **No self-recovery** — a downed player has no self-bandage/self-revive and is resolved only by a **teammate revive** or by bleeding out (BattleBit-style). When a teammate is actively reviving (server `being_revived` bit in `SELF_STATE`), the screen swaps to a green **"Being revived — hold on!"** cue so the player knows not to give up. The ammo readout + throwable selector are hidden while downed/dead/deploying. The **death-recap card** (left side, vertically centered above the deploy dim, word-wrapped) appears only on **true death**, never on a down (you can still be revived). A **respawn cooldown** ("Respawn in N…") gates redeploy after death.

### Settings menu (essentials + defaults)
Persisted to a local config file:
- **mouse sensitivity, FOV, master volume, invert-Y**, and the **renderer fallback toggle** (ADR-0005).
- **Full rebindable keybindings deferred to P2 polish.** P1 ships BattleBit-like defaults:

| Action | Default | Action | Default |
|---|---|---|---|
| Move | WASD | Reload | R |
| Sprint | Shift | Interact / Enter-Exit vehicle | F |
| Jump | Space | Grenade/gadget | G |
| Crouch | Ctrl (toggle/hold) | Scoreboard | Tab (hold) |
| Prone | X | Menu / deploy-back | Esc |
| Lean L/R | Q / E | Fire / ADS | LMB / RMB |

## Test plan (deterministic, headless on game2)

`hud_model` is asserted against crafted `world_view`/event inputs (no drawing involved):
- **Compass bearing:** an enemy/flag at world-NE relative to a given local yaw yields the expected strip bearing (e.g. 45°); wraps correctly across 0/360.
- **Scoreboard:** rows sort by score then name; ticket totals correct; per-team grouping correct.
- **Squad roster:** each member's alive/downed/dead status reflects `world_view`.
- **Tickets & capture:** capture-progress reported only for the point the local pawn occupies; ticket counts match state.
- **Killfeed:** a `KILL` produces an entry with correct killer/victim/headshot; entries decay out after the configured time.
- **Damage arc:** a `DAMAGE_EVENT` from due-south yields an arc at 180° that fades to zero over the configured duration; vignette intensity rises on damage and decays.
- **Ammo model:** reflects `predictor` mag/reserve; `low_ammo`/`reloading` flags set correctly.
- **Interaction prompt:** correct contextual action selected by proximity (vehicle / downed mate / resupply); none when nothing in range.
- **Deploy/squad intent:** menu selection emits a well-formed `DEPLOY_REQUEST`/`SET_SQUAD`; settings round-trip through the config file.

HUD **layout, readability, and feel** are validated by human playtest (M7 is collaborative — AGENTS.md §10), not headless gates.

## Out of scope (this spec)
- Prediction/reconciliation, rendering pipeline, and the netcode for `DEPLOY_REQUEST`/`DAMAGE_EVENT`/`SET_SQUAD`/`EntityState.ammo` → [client-prediction](client-prediction.md).
- Art kit, LOD, and audio/visual polish (richer SFX, animated feedback) → P2 (`art-pipeline.md`).
- Full keybind-rebinding UI → P2 polish.
