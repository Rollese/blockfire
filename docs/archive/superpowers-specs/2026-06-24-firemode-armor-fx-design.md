# Fire-mode HUD indicator + armor visual diffs — design (M7 presentation deferrals)

**Date:** 2026-06-24 · **Branch:** `m7-firemode-armor-fx` · **Owner:** claude (autonomous)
**Closes:** two M5.5 → M7 presentation deferrals — the **fire-mode HUD indicator** and **armor
visual diffs** (art-pipeline.md §95). Both make replicated M5.5 combat state legible to the player.

## A. Fire-mode HUD indicator

The sim already supports fire modes (`weapon.gd` AUTO/SEMI/BURST + per-weapon allowed `fire_modes`)
and the wire already has `SET_FIRE_MODE` (client→server) — but **nothing client-side selects or
shows it**: no input, no tracking, no HUD. So this feature is client-only (no wire change).

- **`WeaponPredictor`** gains `fire_mode` (init to `Weapon.default_mode(weapon)`; reset to the new
  weapon's default in `set_weapon()`) and `cycle_fire_mode()` → advances to the next entry in the
  weapon's `fire_modes` list (wraps; single-mode weapons like DMR/PISTOL are a no-op). Pure, tested.
- **Input:** a new `fire_select` action (default key **B**, BattleBit-style). On press, the client
  cycles its predicted `fire_mode` and sends `SET_FIRE_MODE` so the server's gating matches. The
  server already reads `c.fire_mode` per command, so the client must also stamp the active mode into
  the input command each tick (it already builds the command dict in `client_main`).
- **HUD:** `HudModel.build()` adds the mode label to the `ammo` block (e.g. `"AUTO"`/`"SEMI"`/
  `"BURST"`); `HudView` draws it near the ammo readout (hidden while downed/dead with the rest of the
  combat HUD). Single-mode weapons still show their mode (informative, not interactive).

**Test:** `WeaponPredictor` cycle (wraps; respects `fire_modes`; resets on swap); `HudModel` surfaces
the mode string. Screenshot: HUD shows the glyph; pressing the key cycles it (visual QA flag forces a
mode for a deterministic shot, see below).

## B. Armor visual diffs

Armor tier is class-derived and **immutable per life** (`Loadout.armor_for(class)`, set at spawn in
`pawn.gd`), but it is **not replicated** — `EntityState` has no class/armor, so the renderer cannot
tell a remote pawn's tier. Add a minimal replication path + a renderer visual.

**Replication (immutable → ENTER-only, no field-mask growth):**
- `EntityState.armor_class` (+ in `clone()`); `Pawn.to_state()` copies `armor_class`.
- `Snapshot`: since the field mask (u8) and state byte are both full, and armor never changes within
  a life, append **one byte to ENTER records only** (after `_put_fields(…, F_ALL)`), and read it in
  `decode_apply` when `flags & FLAG_ENTER`. The decoded `EntityState` is retained across later
  CHANGED records (decode reuses the view entry), so the cached tier persists. Cost: 1 byte per
  spawn / first-sighting; zero per-tick. CHANGED/LEAVE records are unchanged.

**Renderer visual (`client/art/armor_visual.gd`, new):**
- `ArmorVisual.apply(node, tier)` overrides the soldier's **Torso** child material with a shared,
  per-tier "vest" material and scales the **Helmet** child by tier — HEAVY = dark heavy vest + larger
  helmet, MEDIUM = mid vest, LIGHT = light vest + small/no helmet. Shared static materials (3, reused
  across all entities) so no per-entity allocation. Idempotent.
- **Not team-tinted** — armor shade is a separate axis from friend/foe (which stays the blue
  triangle marker, per BattleBit identity). Tier shades are greys/olive, never the team blue/red.
- Applied in `world_renderer._pose_entity` guarded by a per-id last-tier cache (re-apply only when a
  pooled node's tier changes), so recycled nodes get the right tier. Procedural path (the default,
  `use_model_characters=false`) is the validated target; GLB path gets a safe best-effort root tint
  (full GLB armor visual is a follow-up).

**Test:** snapshot codec round-trip carries `armor_class` on ENTER and retains it across CHANGED;
`ArmorVisual` maps each tier to a distinct material + helmet scale on a built procedural node.
Screenshot: bots of mixed classes show distinct vests; a `--armor-demo` QA flag spawns three dummy
soldiers (LIGHT/MEDIUM/HEAVY) in front of the camera for a clean deterministic A/B/C grab.

## Scope / YAGNI
- No new gameplay rules; both read already-authoritative state. Fire-mode is client-only; armor adds
  one immutable replicated byte. No screen shake, no GLB-rig armor attachments (follow-up).
- Feel/exact shades + key choice are owner playtest follow-ups (AGENTS.md §10); the seams are in
  place and trivially tunable.

## Risks
- **Snapshot codec is netcode-sensitive.** Mitigation: ENTER-only append (no mask change, no delta
  path touched); explicit round-trip unit test incl. ENTER→CHANGED retention; full suite must stay
  green; a loopback smoke confirms no decode desync.
- **Pooled-node re-tint correctness** — covered by the per-id last-tier cache + idempotent apply.
