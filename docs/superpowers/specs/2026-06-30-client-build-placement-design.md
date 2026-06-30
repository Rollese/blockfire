# Client build-placement UI — design (M12 next increment)

**Date:** 2026-06-30 · **Decision:** BattleBit build-tool mode (owner-selected) · **Status:** approved, implementing.

## Goal
Give the human client the interactive loop to **place** a fortification (sandbag / wall / heavy_barricade) or, as squad leader, a **FOB**, then **shovel** it to completion. The server already implements all authority — `BUILD_REQUEST` (msg 8), `PLACE_FOB` (msg 38), `BTN_SHOVEL` (input bit 512, read directly from client input), and build sites already render as rising amber ghosts (2026-06-30, tip d76524d). This adds only the client-side controls + placement preview. View/intent only (server re-validates everything; AGENTS.md §7).

## Control scheme (BattleBit build-tool mode)
- **T** toggles build mode (new `build_mode` action; T = physical key 84, currently free). Leaving build mode (T again, or death/deploy/vehicle/menu) tears down the preview.
- While in build mode, these existing actions are **reinterpreted** (and their normal effect suppressed) — no new bindings beyond `build_mode`:
  - **Mouse wheel** → cycle the selected piece (raw `WHEEL_UP`/`WHEEL_DOWN` in `_input`, so we get direction; normal weapon-swap is moot in build mode).
  - **Reload (R)** → rotate the ghost 90° (`yaw = (yaw+1) % YAW_STEPS`). Reload is meaningless in build mode.
  - **Fire (LMB)**:
    - just-pressed on a **valid empty cell** → send `BUILD_REQUEST(type, cell, yaw)`; for the FOB piece (leader only) send `PLACE_FOB(cell, yaw)`.
    - **held** while aiming at an existing **under-construction site** (own team) → set `BTN_SHOVEL` so the server advances it.
  - Normal `BTN_FIRE` / `BTN_RELOAD` are masked off while in build mode so the player never shoots/reloads.

## Components

### `client/build_controller.gd` (new, pure — unit-tested)
Holds build-mode state and the pure geometry/decision logic. No `Input`, no nodes.
- State: `active: bool`, `piece_index: int`, `yaw: int` (0..`YAW_STEPS`-1).
- Buildable list (type indices into PieceCatalog), built once from the catalog: every **non-structural** piece (`not is_structural`) — sandbag, wall, heavy_barricade — plus **fob** flagged `leader_only`. Skips the FOB entry in the cycle when the player is not a squad leader.
- `toggle()`, `set_active(bool)`, `cycle(dir)`, `rotate()`.
- `current_type(is_leader) -> int` / `current_is_fob(is_leader) -> bool`.
- `aimed_cell(eye, forward) -> Vector3i`: intersect the eye-ray with the ground plane (y=0); if it points up / too far, clamp to a max build reach (`BUILD_REACH`, ~6 m) ahead. Snap with `BuildGrid.cell_of`. Pure.
- `placement_valid(cell, eye, structures, is_leader) -> bool`: client-side optimistic hint for the green/red ghost — in reach, in bounds, cell not already occupied by a known structure/site. The server is authoritative; this only colours the preview.
- `action_at(cell, structures) -> int` (NONE / PLACE / SHOVEL): SHOVEL if a known under-construction site occupies `cell`; else PLACE if `placement_valid`.

### Renderer preview (`world_renderer.gd`)
- `set_build_preview(active, piece_id, bucket, xform, valid)` — a single pooled ghost node (reuse `StructureKit.build` + `_skin_meshes`) re-posed each frame to the aimed cell, skinned **green** (valid) / **red** (invalid), opaque-ish (llvmpipe transparency caveat — see screenshot memory). Hidden when `active=false`.

### `client_main.gd` wiring
- Own a `BuildController`; toggle on `build_mode` just-pressed (only while alive & deployed & not in a vehicle/menu/photo mode).
- Raw wheel + reload→rotate handled in `_input` / per-tick while active.
- After `gather()`, when active: compute aimed cell from the predicted eye + look forward, resolve `action_at`, mask `BTN_FIRE|BTN_RELOAD`, set `BTN_SHOVEL` on a held shovel, and on a fire just-press in PLACE state send `BUILD_REQUEST`/`PLACE_FOB` (rate-limited by the server's `last_build_tick`).
- Each frame, drive `set_build_preview(...)` with the current piece/cell/validity.
- HUD: a small build-mode hint line (selected piece name + "RMB?"/"R rotate"/"wheel cycle") — minimal, reuse existing HUD label patterns; no new health-bar-style UI (design constraint).

## Testing
- **Unit** (`tests/build_controller_test.gd`): cycle wraps + skips FOB when not leader; rotate wraps; `aimed_cell` ground projection + reach clamp + snapping; `placement_valid` rejects occupied/out-of-reach/out-of-bounds; `action_at` returns SHOVEL over a site, PLACE on empty.
- **Visual** (game2 Xvfb): `--build-test` flag pins build mode with a piece selected so a screenshot shows the green ghost at the aimed cell; verify green-on-valid and the rising scaffold after a place.
- Full suite stays green; server boot + loopback smoke clean.

## Out of scope (later)
- 4-class select UI; build/repair HUD radial; dismantling enemy structures from the client (the input path exists server-side via the same shovel-on-enemy-structure; a later pass can surface a prompt); controller/gamepad bindings.
