# ADR-0008: Destruction fidelity target — "BattleBit-plus" hybrid (volumetric holes + cosmetic physics debris; no authoritative fine-grained physics)

- **Status:** Accepted (owner-directed, 2026-07-03)
- **Date:** 2026-07-03
- **Context milestones:** M4/M11 (existing destruction), future destruction milestones
- **Relates to:** [ADR-0001](0001-core-runtime-language.md) (escalation sequencing), [ADR-0007](0007-battlebit-divergences.md) (deliberate departures from BattleBit), [reviews/2026-07-03-fable-goals-architecture-review.md](../reviews/2026-07-03-fable-goals-architecture-review.md) §C/§E, [specs/destructible-buildings.md](../specs/destructible-buildings.md), [specs/building-overhaul-proposal.md](../specs/building-overhaul-proposal.md)

## Context

The owner's stated future goal is **high-fidelity environment destruction**. The 2026-07-03
architecture review found that the shipped destruction experience is BattleBit-class (piece
removal + support-graph pancake collapse) while the data model is already ahead of it
(25 cm chunk masks, bullet carving on penetrable materials) — but that extra fidelity is
currently invisible and gameplay-inert: holes neither render as holes nor open firing lines.
The review asked the owner to ratify the fidelity ceiling explicitly before more destruction
work lands, so agents don't drift toward a target the architecture cannot honor.

Reference ladder used in the discussion (owner has played BattleBit extensively and Teardown;
project is the owner's take on abandoned BattleBit, improved):

1. **Battlefield-class** — largely scripted destruction set-pieces. Below our current state.
2. **BattleBit-class** — systemic but coarse: large wall panels removed by explosives only,
   whole-building pancake collapse, minimal cosmetic debris. **This is what we shipped** (2 m
   pieces + `support.gd` cascade) — the original project target.
3. **Enlisted-class** — localized breaches where the shell hit; holes affect line-of-sight,
   fire, and movement; debris cosmetic. **Our chunk-mask data model already supports this**;
   the sim/render layers don't yet.
4. **Teardown-class** — continuous ~10 cm voxel carving, every detached fragment a persistent
   physically-simulated object, custom ray-traced voxel renderer. Single-player only, custom
   engine; no networked implementation exists anywhere.

Engine facts (verified 2026-07-03): Godot 4.6 ships **Jolt** as the default 3D physics engine
(good rigid-body throughput for client-side debris); the Godot voxel ecosystem
(`godot_voxel`) is polygon-meshing based and its own docs state Teardown-style raytraced
micro-voxels are out of its scope. A Teardown-class renderer/physics stack in Godot would
mean writing a custom engine inside Godot's shell.

## Decision

**The destruction target is a "BattleBit-plus" hybrid: BattleBit's systemic pancake collapse
+ Enlisted-class shoot-through breaches at finer (volumetric) granularity + a client-side
cosmetic physics-debris spectacle neither reference game has. Teardown-class authoritative
fine-grained physics is permanently out of scope for this architecture.**

Concretely, in delivery order:

1. **Holes become gameplay (Enlisted-class, on the existing masks).** Implement the
   deferred hole-aware paths: `StructureStore.march()` / movement / LOS consult
   `ChunkMask` bits so dead chunks can be shot, seen, and crawled through; implement the
   spec'd per-chunk hole rendering (extending the existing MultiMesh batching). This alone
   moves the shipped experience past BattleBit.
2. **Volumetric mask upgrade (25 cm true voxels).** Extend the per-piece mask from the
   current 64-bit face plane to a volumetric 8×8×8 = 512-bit mask (worst-case 64 B per piece
   on the wire; deltas smaller). Requires a spec + `Protocol.VERSION` bump + wire-registry
   update per the standing rule. Scheduled after (1) proves the hole-aware paths.
3. **Debris spectacle — client-side, cosmetic, Jolt.** Destruction events spawn pooled,
   capped, non-authoritative rigid-body debris on the client (bricks/splinters/rubble using
   Godot 4.6's built-in Jolt). Zero server tick and zero bandwidth cost; presentation-only
   per AGENTS.md §7. This is the same trick AAA multiplayer titles use — players cannot
   tell cosmetic debris from simulated.
4. **Authoritative macro-debris only, sparingly (optional, later).** If detached building
   sections should persist as obstacles, spawn at most a handful of large authoritative
   bodies replicated via the existing vehicle-style entity path — never per-fragment physics.

**Ruled out (each would require a new ADR superseding this one):**

- Authoritative fine-grained physics debris, continuous fracture, or material-stress sim —
  incompatible with the 128-player deterministic shared-sim/replication architecture
  (bandwidth: hundreds of moving bodies × interested clients; determinism: server-stepped
  physics on the 33.3 ms budget).
- A custom voxel renderer (Teardown-style raytraced micro-voxels).
- Terrain deformation (already out of scope per the destruction spec; reaffirmed).

**Design rule retained — breach legibility.** The existing `damage_types` discipline stays
through all phases: bullets carve only penetrable materials (wood, thin metal); masonry and
structural pieces require explosives. Breaches stay shell-sized, not bullet-sized, so cover
remains legible at 128 players — BattleBit's coarseness is partly a feature, and finer
granularity must not turn every wall into a sightline sieve.

**Sequencing constraint (hard).** The native snapshot-encoder escalation (the future
ADR-0003 that ADR-0001 reserves, review §B1) must land **before** hole-aware marching ships:
per-segment chunk-bit tests make every bullet more expensive, and dense-map gate headroom is
currently 3–6 ms. Each phase above re-passes the 128-bot fleet gate on `conquest_town`
before closing.

## Rationale

- **It maximizes what the substrate already paid for.** Chunk masks are tracked, replicated,
  and gated; phases (1)–(2) are extension work explicitly anticipated by the destruction
  spec's own deferrals — not a rewrite.
- **It beats both references without leaving the proven envelope.** Damage stays
  event-replicated and deterministic (the part that demonstrably scales); spectacle moves to
  the client where it's free. The result: BattleBit's pancake + Enlisted's breaches + a
  debris shower neither has.
- **Teardown-class is a different game.** Its fidelity depends on being single-player in a
  bespoke engine; chasing it here would fork the project into engine R&D and break the
  server-authority discipline that every gate to date validates.

## Consequences

- `docs/specs/destructible-buildings.md`'s deferred items (hole-aware march, per-chunk hole
  rendering) become planned work with this ADR as their mandate; the volumetric upgrade and
  client-debris system each get a spec before implementation (AGENTS.md §5).
- Phase (2) is a wire change: `Protocol.VERSION` bump + `wire-protocol-registry.md` update
  in the same commit (standing rule). `OP_CHUNK` payload grows; evaluate plane-wise or XOR
  deltas at that point (full 512-bit masks are 64 B worst case — fine for baselines, wasteful
  for single-bit events).
- Client debris introduces the project's first (client-only) use of engine physics. The
  server and `shared/sim/` remain physics-free; the sim's zero-Godot-physics rule is
  unchanged and debris must never feed back into gameplay state.
- The future ADR-0003 (native snapshot encoder) becomes a prerequisite for destruction
  phase (1), giving it a concrete forcing function beyond general headroom hygiene.
- Milestone planning: phases map naturally onto the existing destruction milestone family
  (M11 cosmetics completion → hole-aware gameplay → volumetric + debris); the board owner
  slots them relative to M7/M7.5 priorities.
