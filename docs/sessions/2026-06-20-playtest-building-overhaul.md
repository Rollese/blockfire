# Session 2026-06-20 — Building/Art Overhaul + Combined Playtest

Branch `m14-walkable-multifloor` (58 commits over `master` 0546385), merged to **master** at the end
of this session. This doc is the handover for continuing in a fresh session.

## What this session produced

Started as an autonomous building/art program; turned into a live combined playtest of conquest_town
with an interactive screenshot loop. All original procedural geometry / CC0 assets only (no ripped
commercial assets — standing constraint).

### Performance
- **`150763a` FPS fix** — the client re-acquired + re-posed every structure piece every frame
  (~6000 pieces on conquest_town = 35 ms/frame, ~21 FPS on an RX 9070 XT). `WorldView` now bumps a
  `_structs_version` on each structure mutation and `WorldRenderer._sync_structure_pool` skips the
  O(N) walk while unchanged. Owner-confirmed "much better." Remaining dips = on-change re-walk during
  firefights + 8.6k draw calls (future MultiMesh batching).

### Audio
- **`354b013` real weapon audio** — owner-supplied **CC0** pack. AR/SMG/DMR fire (5.56 / 9mm / 7.62×54R
  single-shot) + reload wired into `assets/audio/sfx/`. `AudioDirector._stream_for` loads
  `res://assets/audio/sfx/<def.stream>.wav` (from `data/sounds.json` `stream`), falls back to the synth
  tone for events with no asset. Full pack still on the laptop `~/projects/blockfire/sounds/`.
  - **Gotcha:** "no audio at all" was a **PipeWire per-app MUTE** on the "Blockfire" stream, not a bug.
    `pactl list sink-inputs` → find Blockfire → `pactl set-sink-input-mute <idx> 0`.

### Net
- **`d63af09` server→client map adoption** — server sends the map basename in WELCOME; client loads it
  before building the scene. No more launching the client with a matching `--map` (the "no roads" bug:
  buildings stream from the server but roads/points/bases come from the client's local MapDef). `--map`
  stays a valid override.

### FX
- **`9b6342d` visible RPG rocket** — the rocket was server-side only (`_rockets` not replicated). Now
  the shooter renders a cosmetic rocket immediately + the server broadcasts `ROCKET_FX` (origin+dir,
  like SHOT_FX) so others see it. Flies the shared `Grenade` ballistic arc, smoke trail, impact puff,
  muzzle flash. **No RPG/explosion SOUND** (not in the CC0 pack).

### Buildings / art (the bulk)
The authored `buildings/*.json` are the source of truth (the old `build()` driver is gone). All
post-processing is `tools/build_fix.py` (idempotent) + `tools/parking_gen.py`. Key fixes:
- **`2b83d5c` ground-floor slabs** (interior cells only — one-piece-per-cell stamp), **`246b6d8` interior props**,
  **`99d4764` taller** (footprint-based: large 8 m / medium 6 m), **`a21df32` yaw fix** (height-bump added
  walls with yaw=0 → 90° rotation + gaps on E/W faces).
- **`231de3b` + `32b2ddf` parking** rebuilt as a coherent walled garage with an open **4 m drive-in**
  front (was a 1.8 m bay header clipping heads).
- **`394e271`** rubble = light tilted concrete-chunk piles (`_chunk`, full-tint) not dark boxes; buildings
  lifted onto a thin foundation (`STRUCT_LIFT`) so floors don't z-fight grass; bfloor slab top raised so
  roofs swallow the wall top (was "walls clipping roof").
- **`5cf8261`/`a668c18`/`63080e1` corner closure** — new **`bwall_corner`** piece (kit renders a cross
  walling both faces; one per cell, no stamp collision). `build_fix.close_corners` swaps solid-wall
  corner cells. Two edge-cases fixed: roof-footprint over-fired on wings (use full plan), and free
  wall-ends got crosses (require a wall neighbour on BOTH axes = a turning corner + convex).

### Map
- **conquest_town** (densified earlier): roads/districts/5 points/2 bases/77 buildings, walkable
  `test_twostory` at the **central square / point C**. `tools/map_gen.py`.

### Tooling (reusable)
- **`75d31f3` 9-direction + iso QA sweep** — `building_preview --full=true` renders
  `{n,ne,e,se,s,sw,w,nw,top,iso}`. `/tmp/shotfull.sh <name>`. **Mandatory for any new block/template**
  (runbook `docs/runbooks/building-kit.md`). Plus the deterministic `build_fix.validate_wall_yaw` flag.
- **`95b0c35`/`5b2258c` in-client screenshots** — F12/F9 saves a PNG (HUD incl.) to `~/bf-shots/` on the
  desktop (polled in `_process`, not `_unhandled_input` — the HUD swallowed the key). A persistent Monitor
  on game2 auto-pulls new shots for analysis. **Watcher MUST use `find ... -printf '%f\n'`, not `ls`**
  (the desktop's `ls` emits ANSI colour codes that break the match + scp). `/tmp/getshots.sh` = manual pull.
- **`c6d6ac7` F8 photo/free-fly mode** — detached fast camera (WASD + jump/crouch up-down, sprint=faster),
  hides viewmodel + HUD, freezes the pawn. F8 because F = vehicle-enter / revive.

## Still OPEN (pick up next session)
1. **Floor doesn't reach the walls** — ~1 m no-floor strip just inside walls (perimeter cells are taken
   by walls; one-piece-per-cell means the floor only goes on interior cells). Proper fix = a
   wall-with-floor-skirt piece placed on perimeter cells at floor-deck levels (new piece + generator
   logic). Owner flagged; NOT yet done.
2. **Walkable 2-story is cramped** — `test_twostory` floors are still 2 m (head-clip). Needs the M14 4 m
   floor + multi-flight-stair redesign (must be walked to validate the climb — don't author blind).
3. **`bwall_corner` corners read as pillars / the "+" is structurally needed** — could refine free
   look, but it's acceptable.
4. **`STRUCT_LIFT` makes pawns sink ~0.1 m into upper floors** (visual only) — tune if it bothers.
5. RPG/explosion sound missing. Bots fight robotically / low contact on the big 5-point map. Dense-map
   FPS dips during firefights (draw-call batching).

## Runbook — relaunch the playtest (game2 = 192.168.1.166, desktop = 192.168.1.194)
**CRITICAL: launch the server as a BARE `godot --server` via the Bash tool's `run_in_background:true`
+ `dangerouslyDisableSandbox:true`.** Do NOT use `setsid`, and do NOT wrap it with an ssh/pkill prefix
in the same command — both put the ENet socket in the Bash sandbox's network namespace → nothing can
connect (client stuck "connecting…"/grey screen). Do NOT `pkill` a server that's already up between
relaunches (you'll kill the running one). Verify with: local bots connect → `players>0`.
```
# server (bare, run_in_background, sandbox off):
godot --headless --path . -- --server --port=27015 --map=conquest_town --human-rpg --tickets=800 --time-limit=1800
# bots (bare, run_in_background):
godot --headless --path . -- --bots --bot-count=28 --connect=127.0.0.1 --port=27015 --map=conquest_town
# client on desktop (ssh, run_in_background; NO --map needed now):
ssh roland@192.168.1.194 'bash -lc "cd ~/projects/blockfire && WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 godot --path . -- --connect=192.168.1.166 --port=27015 --name=Roland"'
```
Match ends on ticket bleed (~15 min at 800). `--human-rpg` = humans spawn Engineer+RPG. Screenshot
watcher + error monitor are Monitors; re-arm each session. See memory `blockfire-playtest-2026-06-20-fixes`.
