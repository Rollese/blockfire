# Combined-build code review — 2026-06-18/19 (pre-playtest)

Autonomous headless review of the day's combined `master` merge (base `b0ff265` → tip `7aae1c3`,
130 commits: M6 voice, M7.5 bot AI, M7-P2 GLB art, M11 P1+P2+P3 destructible buildings, M12-P1 class
refit). Method: full unit suite + headless server boots on both maps + **7 parallel deep-review
agents** (one per subsystem) + adversarial verification of every finding acted on.

**Build health:** unit suite **615/0** on `master`; **618/0** after the fixes below (on branch
`playtest-fixes-2026-06-18`). Server boots clean on `conquest_proving_grounds`, `conquest_dev_arena`,
and `conquest_arena_buildings`. No removed-API callers, no protocol encode/decode asymmetry, no
crash-class integration bug in the server tick loop.

---

## FIXED tonight (on branch `playtest-fixes-2026-06-18`, unit-verified, NOT merged)

These are in addition to the 4 playtest fixes from the earlier session (bot engage movement, GLB-char
default flag, viewmodel offset, building palette).

| # | Sev | Area | Bug | Fix |
|---|-----|------|-----|-----|
| A | **Critical** | Client art | `GlbCharacterKit.build()` had no null-guard on `load()` — a missing/stale character GLB import → `ps.instantiate()` hard-crashes the client on first remote spawn. **Now live-relevant** because tonight's flag-flip makes the GLB path the default. | Fall back to procedural `CharacterKit.build()` on null (mirrors `GlbWeaponKit`). `glb_character_kit.gd` |
| B | Important | Bot AI | Target prioritization was dead code: `AiCombat.pick_target` blends `hp_frac`/`priority`, but `Perception` never wrote them → every bot targets **nearest-only**, ignoring wounded enemies. | Populate `hp_frac = health/100` on each enemy record. `perception.gd`. (`priority`/objective tags still default 0 — see follow-up.) |
| C | Important | Bot AI | `take_cover` with no known cover called `pick_cover()` → returns self-position → **bot roots crouched in the open under fire** and dies (no flee fallback, unlike `retreat`). Visible at scale as clumps of stationary crouchers. | Flee (break LOS away from nearest enemy) when `w.cover` is empty. `ai_driver.gd` |
| D | Important | Server | `_handle_build_request` passed the client's raw `yaw` byte (0–255) into `place()` unvalidated (the map path validates; the player path did not). Enables out-of-range/aliased yaw incl. the latent chunk-geometry bug below. | Reject `yaw < 0 || yaw >= BuildGrid.YAW_STEPS`. `server_main.gd` |
| E | Minor | Client art | Double-collapse of a building → `_spawn_rubble_for` defaults centroid to `Vector3.ZERO` → stray rubble slab at world origin. (Currently guarded server-side, so latent.) | Return early when centroid unknown. `world_renderer.gd` |

New tests: `ai_perception_test` (hp_frac populated; wounded-over-closer targeting), `ai_driver_test`
(take_cover flees with no cover). Suite 618/0.

---

## FOUND, NOT fixed — needs your judgment (proposed fixes included)

### Critical / Important

**1. Chunk-mask U-axis is wrong for yaw 4 (180°) and yaw 6 (270°)** — `shared/sim/chunk_mask.gd`
(`chunk_center`/`bit_at`/`clear_in_radius`). Chunks are laid out from `cell_min` along `+U`; for yaw
4/6 `+U` points into the negative neighbour cell, so chunk centres land ~2 m outside the piece's
axis-aligned hit AABB. Result on a rotated chunked piece: wrong/asymmetric bullet carving and wrong
hole geometry. **Latent today** — all shipped prefabs use yaw 0/2 (safe), and Fix D now blocks
player walls at yaw 4/6 — but it will mis-carve the instant any building/prefab uses yaw 4 or 6.
*Fix:* offset the face origin to the cell corner that `+U` sweeps from (or rotate about cell centre)
so `+U` always crosses the cell interior; add yaw-4/6 chunk_mask tests. **Not fixed:** the geometry
change is easy to get subtly wrong and can't be eyeball-verified headless — wants care + a visual check.

**2. Voice jitter buffer permanently stalls on u16 sequence wraparound** — `client/voice/voice_jitter.gd`
+ `shared/net/voice_packet.gd`. `seq` is u16; `insert()` drops `seq <= _last_popped`. After ~65 536
frames (~22 min continuous speech) the post-wrap small seqs are all treated as "late" → speaker goes
permanently silent to that listener, unrecoverable. *Fix:* RFC-1982 serial comparison
(`((seq - last) & 0xFFFF) < 0x8000`) in both `insert` and the sort comparator. **Not fixed:** voice
isn't exercised in tomorrow's playtest (native `.so` unbuilt) — no playtest payoff, deferred to keep
the branch focused. Ready-to-apply.

**3. Voice routing-table double-buffer torn read** — `server/voice_routing_table.gd:24-28`. `read()`
captures `_active` under the mutex but dereferences `_buffers[idx]` **after** unlocking; `publish()`
reassigns slots outside the lock. Two publishes in the window return the wrong snapshot. Latent (the
relay reader thread is deferred), but the file header asserts a safety invariant that doesn't hold.
*Fix:* copy the ref inside the lock (`lock; t=_buffers[_active]; unlock; return t`). Also guard
`process_frame` (`voice_relay.gd:20-21`) with `if not table.has(id): continue` (missing-key → null
deref crash). **Not fixed:** deferred-thread-gated; fix before Phase 2 wires the relay thread.

### Minor / hardening (report-only)

- **Bot AI** (`ai_driver.gd`/`perception.gd`): reaction gate is skipped on re-acquisition within the
  90-tick memory window (weakens anti-aimbot fairness); `retreat` can path toward the enemy via the
  nearest cover when that cover sits between bot and threat; `_aim_ticks` isn't reset on leaving
  `engage` (first-shot aim-error skipped on quick re-engage); `suppress` aims at feet (no eye/body
  height) vs `engage`'s body-centre.
- **Protocol** (`shared/net/`): `decode_*` server→client paths have no buffer bounds checks (garbage,
  not crash, over reliable ENet — acceptable since server is trusted; the one untrusted decoder,
  `VoicePacket.decode`, *is* guarded). `voice_packet.speaker_id` is u16 while player ids are u32
  monotonic — truncation on a very long-lived server. `client/world_view.gd` silently drops an
  OP_CHUNK for an unknown id with no resync trigger (self-heals via the later baseline today).
- **Client render** (`world_renderer.gd`): no renderer reset/teardown across matches — `_struct_active`,
  `_building_centroid`, rubble children, free-lists all persist for the renderer's life; leaks **iff**
  the renderer is ever reused across a map change (not currently done). `_struct_dying` tweens free
  only inside `update()`, so destroy-pops stall if the render loop pauses (e.g. match-end screen).
- **Voice pool** (`client/audio/voice_pool.gd`): `request()` returns `evicted == slot` (ambiguous);
  `release()` has no slot-generation guard against double-free into a recycled slot.
- **Bots** (`bot_driver.gd`): non-RPG engineers still emit `GA_RPG_FIRE` packets every opportunity
  (server drops them — wasted bandwidth, pre-existing, not a refit regression).

### Class refit (M12-P1) — clean
No Critical/Important issues. No lingering Recon refs, no class-index off-by-one, `gadget_for_player`
is byte-identical server↔bot (both read class+id from WELCOME, no replication), `can_equip`
(DMR=Assault, RPG=Engineer) is correct and authoritative. Only note: which engineers carry C4 vs
claymore is by network-id parity (connection order), not a balanced split — intentional per spec.

---

## Dangerous test gaps (recommend adding)
- No yaw≠0/2 chunk-mask test (hides finding #1).
- No voice jitter seq-wraparound test (hides finding #2); no `VoiceRoutingTable` concurrency test
  (#3); no voice relay thread/port-lifecycle tests at all (all deferred).
- No COLLAPSE→client-mirror integration test (the `building_id==0` sentinel that protects loose
  pieces is untested — a regression would erase all loose pieces on any collapse).
- No GlbCharacterKit load-failure test (now covered behaviourally by Fix A's fallback, but untested).
- No server↔bot `gadget_for_player` cross-derivation test (determinism rests on a shared pure fn).

---

## Bottom line for tomorrow's playtest
The combined build is **structurally sound** — green suite, clean boots, no crash/desync-class
integration bug. The two findings that would have visibly degraded the playtest (nearest-only
targeting, stationary crouchers) and the one that could crash the now-default GLB path are **fixed on
the branch**. Everything else is latent (voice not exercised; yaw 4/6 unused by shipped content) or
minor. Merge the branch (or cherry-pick) before the session; nothing here blocks playing.
