# Session log — 2026-07-05 (pm) — M7 playtest round 6 (live, laptop .116)

Owner ran a live rendered-client playtest (laptop `thinkpad` at **192.168.1.116** — new DHCP IP this
session; `.128`/`.251`/`.194` were all unreachable). Server + 24 bots hosted on game2 in tmux,
`conquest_town` (roof ladders, no vehicles), high tickets so it didn't end mid-test. Feedback given
in the letter+number checklist format ([[blockfire-playtest-checklist-format]]). Branch
`m7-playtest-round6-fixes`. Suite **1266/0**.

Also this session (separate, landed first): **vehicles deferred** to a post-core milestone +
**vehicle spawns stripped from all maps** (`f7876bf`) — see the TASKS.md banner + AGENTS.md §12.

## Fixed + landed (all with deterministic tests)

- **A1 — no combat while climbing.** Fire / grenade / melee / gadget-RPG-C4 are blocked while
  `Pawn.climbing` (server guards in `fire.gd` + `server_main` grenade/melee/gadget handlers; client
  suppresses predicted fire/ADS/one-shots via `_pred.predicted.climbing`). **Weapon swap stays
  allowed** (owner amendment). **Strafe-off dismount**: lateral input in `_step_climb` slides the
  pawn off the ladder line and releases the climb once it clears the capture volume (shared sim, so
  client predicts it identically). Ladders were "no strafe in v1".
- **B3 — stamina bar** enlarged 120×4 → **260×8 px** (`hud_view`).
- **C3b — "65535 damage" on the death recap.** Instant-kill sentinels (back-stab `100000`,
  vehicle-crush `99999`) were credited raw to the per-attacker damage ledger, then clamped to u16-max
  (`65535`) on the DEATH_INFO wire. Fix: credit `mini(dmg, pre_hit_health)` (`server_main._apply_pawn_damage`)
  — normal hits unchanged, instant kills now show a sane number.
- **C4 — client grenade tunneled through walls.** The cosmetic flew a pure ballistic arc while the
  server bounced the real grenade (explosion appeared ~90° away). `FxPool.age_thrown` now marches the
  segment against the client's synced `StructureStore` and reflects with the same
  `GRENADE_RESTITUTION`/`GRENADE_BOUNCE_SKIN` as `server_main._integrate_grenade` (store threaded via
  `WorldRenderer.set_grenade_collision` from `_rebuild_struct_store`).
- **H1 — ladder left floating after its building was demolished.** Ladders had no building link.
  `tools/map_gen.py` now emits each ladder's `building` (generation index); `MapDef` carries
  `building_index` + `building_id` (index+1); the server re-stamps the authoritative `building_id`
  during placement and drops the climb volume in `_resolve_cascades` on collapse; the client frees the
  red ladder node in the COLLAPSE drain (`world_renderer._free_ladders_for`). Town regenerated.
- **H2 — the ~1 Hz empty-sprint rubberband** (reported earlier, unfixed by the C6 cooldown byte).
  Root cause: at empty stamina, holding sprint produced a single sprint-burst tick every ~31 ticks;
  the server's true stamina on that tick (`0.4`) rounds to `0` on the wire, so the client couldn't
  reproduce the burst and mis-predicted sprint-vs-walk by one tick — a `(9.6−6.0)/30 = 0.12 m` error,
  exactly the reconcile deadzone. Fix (root, also better feel): **BattleBit sprint-lockout
  hysteresis** in `Pawn.step` — once stamina hits 0 you can't sprint until it regens past
  `SPRINT_RESUME = 20`, killing the single-tick burst entirely. The lockout flag rides SELF_STATE
  (new trailing byte, **`Protocol.VERSION` 2→3**) and is reconciled like the C6 cooldown so the client
  predicts the identical rule through the recovery window.
- **C1a — no visible spread/recoil (first pass).** Hip-fire crosshair bloom strengthened (+6/shot,
  cap 26). Added a **recovering visual camera-recoil kick** (`_recoil_kick`, ≤~3.1°, ~150 ms recover)
  applied to the *camera* pitch only — cosmetic, does not touch the authoritative aim, so no
  prediction risk (same philosophy as the viewmodel kick). Feel values owner-tunable.

## Decisions / deferrals

- **C3a killfeed — leave OFF** (owner-confirmed). It was deliberately disabled ("BattleBit has no
  killfeed"); the data path is wired but `_render_killfeed` hides every line on purpose. Not a bug.
  See [[blockfire-no-killfeed]].
- **D1–D3 (map design, building proportions, bot pathfinding/stuck)** → future map-creator +
  AI-pathfinding milestones, dropped from the M7 client checklist (owner-directed).
- **E1/E2 (destruction fidelity, instant-disappear collapse)** → destruction-fidelity milestone.
- **F2 (more scoreboard stats)** → future UI/UX milestone.
- **B4 — jump-apex "second tiny jump"** → deferred with the **tick-lead netcode**. Root cause is a
  client reconcile artifact: `reconcile_full` pins `pos` from the SNAPSHOT and `vel_y` from the
  SELF_STATE, which can be different server ticks; near the apex (vel_y≈0) that reads as a brief
  upward nudge. Same feel-critical netcode class as `docs/specs/netcode-tick-lead.md` — do it
  deliberately (deterministic tests → 128-bot fleet gate → owner feel gate), not a pre-playtest
  hot-patch. Tick-lead is an M7 netcode item, not a separate milestone.
