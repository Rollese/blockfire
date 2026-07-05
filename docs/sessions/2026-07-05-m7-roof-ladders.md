# Session log — 2026-07-05 (pm) — M7 roof ladders (B1/B2) + tick-lead spec

Autonomous follow-up to the M7 playtest rounds 4–5. Goal: clear the still-unresolved deferred
items from that session's handoff, validating without a live playtest where possible. Work
branched from `master` (`97e0460`); ladders **merged to master (`1cf0bd2`, pushed)**; suite **1259/0**.

## Done — B1/B2 red roof-access ladders (merged `1cf0bd2`)

The round-4/5 session left inert `_make_ladder` render scaffolding (`50e8447`) but no wiring and
no map data. Finished it:

- **Finding:** every multi-storey building in `conquest_town` has a walkable `bfloor` roof deck
  (`floor_height_at` supports it) but — except the one `twostory_house` (interior `bstair`) — **no
  way up**. That is the "high ground / fall damage untestable" gap the ladders were for.
- **`tools/map_gen.py`** (the town's generator — source of truth, JSON is regenerated): generate a
  ladder per tall landmark (roof ≥ 8 m: apartment/office_tower/warehouse/factory/hangar/parking/
  silo/supermarket) at the street-facing (min-z) roof-deck cell, pushed **0.75 m to the outer
  face** so it reads as an exterior ladder standing clear of the wall while staying inside the cell
  (so the top still lands on the deck — `floor_height_at` maps the same cell). **33 ladders.**
- **`client/world_renderer.gd`**: added the render loop `for ld in map.ladders: _make_ladder(ld)`
  (the scaffolding is now driven). Climb volumes were already fully wired server-side
  (`_sim.ladders = _map.ladders`, `Ladder.capture/climb_step`, `MapDef` ladder parse incl. yaw).
- **`tests/map_ladders_test.gd`** (new, deterministic): expands the town's prefabs into a
  `StructureStore` exactly as `server_main._start_match` does, then asserts **every** ladder top is
  supported by a real roof deck (`floor_height_at ≈ top.y`) + bottom at ground + the pure
  `Ladder.climb_step` loop reaches the top. Guards against generator/geometry drift dropping a
  ladder top over thin air.
- **`client/art/preview/map_preview.gd`**: render ladders + a street-side close-up view for
  screenshot validation.

**Validation (no owner playtest needed):** suite 1259/0; game2 Xvfb close-up shows clean exterior
red ladders ground→roof beside each entrance (`/tmp/townlad3_closeup.png`); a live 24-bot server
boot on `conquest_town` parsed the ladders with **zero errors** (`struct=8419`, tick ~2 ms). Bots
don't path to ladders (no ladder-seeking AI — expected; `climbs=0`), so bot climbing is not a gate;
the human climb is proven deterministically.

## Specced (not implemented) — explicit tick-lead netcode

The root of the connection-dependent movement micro-snap (round-5 diagnosis). Wrote
**`docs/specs/netcode-tick-lead.md`**: adaptive input-buffer clock sync — the server reports its
per-client `InputBuffer` occupancy in a new trailing `SELF_STATE u8 input_buf_depth` (append-only,
`Protocol.VERSION` bump + registry entry), and the owner client nudges its input-production clock
(small integer hold/catch-up, GAIN ≈ 0.05) to hold the buffer at `TICK_LEAD_TARGET = 2`, so
starvation/coalescing (the discontinuity source) become rare and the reconcile-replay length stops
wandering. **Deliberately left as a spec, not implemented this session** — the owner asked for this
to be done "with the fleet gate, not by live trial-and-error", and it is feel-critical; cramming a
delicate netcode change into the pre-playtest window risks the afternoon test. It wants its own TDD
+ fleet-gate + owner-feel pass (control-law unit test → loopback jitter → 128-bot gate → playtest).

## Still deferred (not started)

- **Tick-lead implementation** (spec ready above).
- **Manual vehicle turret** — mounted gun is still server-auto-fire; feel-gated + touches the
  authoritative fire path, wants a deliberate pass.

## Notes for next / owner

- Ladders are on master for the afternoon playtest: enter any tall building (or approach the
  street-side red ladder), climb to the roof, test fall damage on the way down. If exterior
  climb-from-outside feels off, the alternative is a small landing platform at ladder tops (needs a
  `platforms` entry per ladder) — deferred pending feel feedback.
- Run the server/bots in **detached tmux** (session-bound bg tasks get SIGKILLed on teardown).
